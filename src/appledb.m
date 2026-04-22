//
//  appledb.m
//  libgrabkernel2
//
//  Created by Dhinak G on 3/4/24.
//  Modified: 添加腾讯云代理支持（端口9090），解决中国大陆网络问题
//

#import <Foundation/Foundation.h>
#import <sys/utsname.h>
#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif
#import <sys/sysctl.h>
#import "utils.h"

// ============================================================
// 🔧 代理配置
// 设置为空字符串 "" 则直连（不使用代理）
// ============================================================
#define PROXY_BASE_URL @"http://124.221.171.80:9090"
// ============================================================

#define BASE_URL @"https://api.appledb.dev/ios/"
#define ALL_VERSIONS BASE_URL @"main.json.xz"

NSArray *hostsNeedingAuth = @[@"adcdownload.apple.com", @"download.developer.apple.com", @"developer.apple.com"];

static inline NSString *apiURLForBuild(NSString *osStr, NSString *build) {
    return [NSString stringWithFormat:@"https://api.appledb.dev/ios/%@;%@.json", osStr, build];
}

static inline BOOL isProxyEnabled(void) {
    NSString *proxy = PROXY_BASE_URL;
    return (proxy != nil && proxy.length > 0);
}

static NSString *proxyURL(NSString *originalURL) {
    if (!isProxyEnabled()) return originalURL;
    NSString *base = @"https://api.appledb.dev";
    if ([originalURL hasPrefix:base]) {
        NSString *path = [originalURL substringFromIndex:base.length];
        return [NSString stringWithFormat:@"%@%@", PROXY_BASE_URL, path];
    }
    return originalURL;
}

static NSString *proxyFirmwareURL(NSString *originalURL) {
    // Don't proxy firmware URLs - let the iOS device download directly
    // from Apple's Chinese CDN partners (Kunlun/Kingsoft).
    // The Chinese CDN only serves legitimate Apple devices.
    return originalURL;
}

static NSData *makeSynchronousRequest(NSString *url, NSError **error) {
    NSString *requestURL = proxyURL(url);

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSError *taskError = nil;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    config.timeoutIntervalForResource = 120;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:requestURL]];
    [request setValue:@"libgrabkernel2-proxy/2.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:requestURL]
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

static NSString *bestLinkFromSources(NSArray<NSDictionary<NSString *, id> *> *sources, NSString *modelIdentifier, bool *isOTA) {
    for (NSDictionary<NSString *, id> *source in sources) {
        if (![source[@"deviceMap"] containsObject:modelIdentifier]) {
            DBGLOG("Skipping source that does not include device: %s\n", [source[@"deviceMap"] componentsJoinedByString:@", "].UTF8String);
            continue;
        }

        if (![@[@"ota", @"ipsw"] containsObject:source[@"type"]]) {
            DBGLOG("Skipping source type: %s\n", [source[@"type"] UTF8String]);
            continue;
        }

        if ([source[@"type"] isEqualToString:@"ota"] && source[@"prerequisiteBuild"]) {
            DBGLOG("Skipping OTA source with prerequisite build: %s\n", [source[@"prerequisiteBuild"] UTF8String]);
            continue;
        }

        for (NSDictionary<NSString *, id> *link in source[@"links"]) {
            NSURL *url = [NSURL URLWithString:link[@"url"]];
            if ([hostsNeedingAuth containsObject:url.host]) {
                DBGLOG("Skipping link that needs authentication: %s\n", url.absoluteString.UTF8String);
                continue;
            }

            if (!link[@"active"]) {
                DBGLOG("Skipping inactive link: %s\n", url.absoluteString.UTF8String);
                continue;
            }

            if (isOTA) {
                *isOTA = [source[@"type"] isEqualToString:@"ota"];
            }

            NSString *finalURL = proxyFirmwareURL(link[@"url"]);
            LOG("Found firmware URL: %s (OTA: %s)\n", finalURL.UTF8String, *isOTA ? "yes" : "no");
            return finalURL;
        }

        DBGLOG("No suitable links found for source: %s\n", [source[@"name"] UTF8String]);
    }

    return nil;
}

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

static NSString *getFirmwareURLFromDirect(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    NSString *apiURL = apiURLForBuild(osStr, build);
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

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) {
        ERRLOG("Failed to parse API data: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    NSString *firmwareURL = bestLinkFromSources(json[@"sources"], modelIdentifier, isOTA);
    if (!firmwareURL) {
        return nil;
    }

    return firmwareURL;
}

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

NSString *getFirmwareURL(bool *isOTA) {
    NSString *osStr = getOsStr();
    NSString *build = getBuild();
    NSString *modelIdentifier = getModelIdentifier();

    if (!osStr || !build || !modelIdentifier) {
        return nil;
    }

    return getFirmwareURLFor(osStr, build, modelIdentifier, isOTA);
}
