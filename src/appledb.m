//
//  appledb.m
//  libgrabkernel2
//
//  Created by Dhinak G on 3/4/24.
//
// 本文件主要负责从Apple的固件服务器获取内核缓存文件
// 实现了固件URL的获取、验证和选择最佳下载源的功能

#import <Foundation/Foundation.h>
#import <sys/utsname.h>
#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif
#import <sys/sysctl.h>
#import "utils.h"

// IPSW.me API的基础URL
#define BASE_URL @"https://api.ipsw.me/v4/"
// 获取所有设备固件信息的API端点
#define ALL_VERSIONS BASE_URL @"devices"

// 需要开发者账号认证的Apple下载服务器列表
NSArray *hostsNeedingAuth = @[@"adcdownload.apple.com", @"download.developer.apple.com", @"developer.apple.com"];

// 根据设备标识符构建API URL
static inline NSString *apiURLForBuild(NSString *osStr) {
    return [NSString stringWithFormat:@"https://api.ipsw.me/v4/device/%@", osStr];
}

// 执行同步HTTP请求
// 使用信号量确保异步网络请求同步完成
static NSData *makeSynchronousRequest(NSString *url, NSError **error) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSError *taskError = nil;
    NSURLSession *session = [NSURLSession sharedSession];

    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:url]
                                        completionHandler:^(NSData *taskData, NSURLResponse *response, NSError *error) {
                                            data = taskData;
                                            taskError = error;
                                            dispatch_semaphore_signal(semaphore);
                                        }];
    [task resume];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (error) {
        *error = taskError;
    }

    return data;
}

// 从多个固件源中选择最佳的下载链接
// 会检查设备兼容性、链接有效性，并优先选择非需要认证的源
// sources: 固件源列表
// modelIdentifier: 设备型号标识符
// isOTA: 输出参数，标识是否为OTA更新包
static NSString *bestLinkFromSources(NSArray<NSDictionary<NSString *, id> *> *sources, NSString *modelIdentifier, bool *isOTA) {
    if (!sources || ![sources isKindOfClass:[NSArray class]]) {
        ERRLOG("Invalid sources parameter: null or not an array\n");
        return nil;
    }

    if (!modelIdentifier || ![modelIdentifier isKindOfClass:[NSString class]]) {
        ERRLOG("Invalid modelIdentifier parameter\n");
        return nil;
    }

    DBGLOG("Searching for firmware in %lu sources\n", (unsigned long)sources.count);

    for (NSDictionary<NSString *, id> *source in sources) {
        if (![source isKindOfClass:[NSDictionary class]]) {
            DBGLOG("Skipping invalid source (not a dictionary)\n");
            continue;
        }

        NSArray *deviceMap = source[@"deviceMap"];
        if (![deviceMap isKindOfClass:[NSArray class]]) {
            DBGLOG("Skipping source with invalid deviceMap\n");
            continue;
        }

        if (![deviceMap containsObject:modelIdentifier]) {
            DBGLOG("Skipping source that does not include device: %s\n", [deviceMap componentsJoinedByString:@", "].UTF8String);
            continue;
        }

        NSString *sourceType = source[@"type"];
        if (![sourceType isKindOfClass:[NSString class]]) {
            DBGLOG("Skipping source with invalid type\n");
            continue;
        }

        if (![@[@"ota", @"ipsw"] containsObject:sourceType]) {
            DBGLOG("Skipping source type: %s\n", [sourceType UTF8String]);
            continue;
        }

        if ([sourceType isEqualToString:@"ota"] && source[@"prerequisiteBuild"]) {
            DBGLOG("Skipping OTA source with prerequisite build: %s\n", [source[@"prerequisiteBuild"] UTF8String]);
            continue;
        }

        NSArray *links = source[@"links"];
        if (![links isKindOfClass:[NSArray class]]) {
            DBGLOG("Skipping source with invalid links format\n");
            continue;
        }

        for (NSDictionary<NSString *, id> *link in links) {
            if (![link isKindOfClass:[NSDictionary class]]) {
                DBGLOG("Skipping invalid link entry\n");
                continue;
            }

            NSString *urlString = link[@"url"];
            if (![urlString isKindOfClass:[NSString class]]) {
                DBGLOG("Skipping link with invalid URL\n");
                continue;
            }

            NSURL *url = [NSURL URLWithString:urlString];
            if (!url) {
                DBGLOG("Failed to parse URL: %s\n", [urlString UTF8String]);
                continue;
            }

            if ([hostsNeedingAuth containsObject:url.host]) {
                DBGLOG("Skipping link that needs authentication: %s\n", url.absoluteString.UTF8String);
                continue;
            }

            NSNumber *active = link[@"active"];
            if (![active isKindOfClass:[NSNumber class]] || !active.boolValue) {
                DBGLOG("Skipping inactive link: %s\n", url.absoluteString.UTF8String);
                continue;
            }

            if (isOTA) {
                *isOTA = [sourceType isEqualToString:@"ota"];
            }
            LOG("Found firmware URL: %s (OTA: %s)\n", url.absoluteString.UTF8String, *isOTA ? "yes" : "no");
            return urlString;
        }

        DBGLOG("No suitable links found for source: %s\n", [source[@"name"] UTF8String]);
    }

    ERRLOG("No suitable firmware URL found for device %s\n", modelIdentifier.UTF8String);
    return nil;
}

// 从所有设备固件列表中查找指定版本的固件URL
// 这是一个备用方法，当直接API查询失败时使用
// osStr: 设备标识符
// build: 系统构建版本号
// modelIdentifier: 设备型号标识符
// isOTA: 输出参数，标识是否为OTA更新包
static NSString *getFirmwareURLFromAll(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    NSError *error = nil;
    NSData *compressed = makeSynchronousRequest(ALL_VERSIONS, &error);
    if (error) {
        ERRLOG("Failed to fetch API data: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    NSData *decompressed = [compressed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZMA error:&error];
    if (error) {
        ERRLOG("Failed to decompress API data: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    NSArray *json = [NSJSONSerialization JSONObjectWithData:decompressed options:0 error:&error];
    if (error) {
        ERRLOG("Failed to parse API data: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    for (NSDictionary<NSString *, id> *firmware in json) {
        if ([firmware[@"osStr"] isEqualToString:osStr] && [firmware[@"build"] isEqualToString:build]) {
            NSString *firmwareURL = bestLinkFromSources(firmware[@"sources"], modelIdentifier, isOTA);
            if (!firmwareURL) {
                DBGLOG("No suitable links found for firmware: %s\n", [firmware[@"key"] UTF8String]);
            } else {
                return firmwareURL;
            }
        }
    }

    return nil;
}

// 直接从设备专用API获取固件URL
// 这是首选方法，速度更快，数据量更小
// osStr: 设备标识符
// build: 系统构建版本号
// modelIdentifier: 设备型号标识符
// isOTA: 输出参数，标识是否为OTA更新包
static NSString *getFirmwareURLFromDirect(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    NSString *apiURL = apiURLForBuild(osStr);
    if (!apiURL) {
        ERRLOG("Failed to get API URL!\n");
        return nil;
    }

    NSError *error = nil;
    NSData *data = makeSynchronousRequest(apiURL, &error);
    if (error) {
        ERRLOG("Failed to fetch API data: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    if (!data) {
        ERRLOG("Received empty data from API\n");
        return nil;
    }

    NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) {
        ERRLOG("Failed to parse API data: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    if (![json isKindOfClass:[NSArray class]]) {
        ERRLOG("Unexpected API response format: not an array\n");
        return nil;
    }

    DBGLOG("Searching for build %s in %lu firmware entries\n", build.UTF8String, (unsigned long)json.count);

    for (NSDictionary *firmware in json) {
        if (![firmware isKindOfClass:[NSDictionary class]]) {
            DBGLOG("Skipping invalid firmware entry (not a dictionary)\n");
            continue;
        }

        NSString *buildId = firmware[@"buildid"];
        if (![buildId isKindOfClass:[NSString class]]) {
            DBGLOG("Skipping firmware entry with invalid buildid\n");
            continue;
        }

        if ([buildId isEqualToString:build]) {
            NSArray *sources = firmware[@"sources"];
            if (![sources isKindOfClass:[NSArray class]]) {
                DBGLOG("Firmware entry has invalid sources format\n");
                continue;
            }

            NSString *firmwareURL = bestLinkFromSources(sources, modelIdentifier, isOTA);
            if (firmwareURL) {
                return firmwareURL;
            }
        }
    }

    DBGLOG("No matching firmware found for build %s\n", build.UTF8String);
    return nil;
}

// 获取指定设备和版本的固件URL
// 首先尝试直接API，如果失败则尝试从所有版本列表中查找
// osStr: 设备标识符
// build: 系统构建版本号
// modelIdentifier: 设备型号标识符
// isOTA: 输出参数，标识是否为OTA更新包
NSString *getFirmwareURLFor(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    NSString *firmwareURL = getFirmwareURLFromDirect(osStr, build, modelIdentifier, isOTA);
    if (!firmwareURL) {
        DBGLOG("Failed to get firmware URL from direct API, checking all versions...\n");
        firmwareURL = getFirmwareURLFromAll(osStr, build, modelIdentifier, isOTA);
    }

    if (!firmwareURL) {
        ERRLOG("Failed to find a firmware URL!\n");
        return nil;
    }

    return firmwareURL;
}

// 获取当前设备当前系统版本的固件URL
// 自动获取设备信息，简化调用过程
// isOTA: 输出参数，标识是否为OTA更新包
NSString *getFirmwareURL(bool *isOTA) {
    NSString *modelIdentifier = getModelIdentifier();
    NSString *build = getBuild();

    if (!modelIdentifier || !build) {
        return nil;
    }

    return getFirmwareURLFor(modelIdentifier, build, modelIdentifier, isOTA);
}