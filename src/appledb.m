//
//  appledb.m
//  libgrabkernel2
//
//  Created by Dhinak G on 3/4/24.
//  Modified: 所有请求走 CF Worker 代理，移除镜像和直连逻辑
//

#import <Foundation/Foundation.h>
#import "utils.h"

// ============================================================
// 🔧 Worker 代理配置
// ============================================================
#define PROXY_BASE @"https://apple.lengye.top/?url="
#define APPLEDB_BASE @"https://api.appledb.dev/ios/"

// ============================================================
// 网络请求（通过 Worker 代理）
// ============================================================
static NSData *fetchJSONViaProxy(NSString *targetUrl, NSError **error) {
    NSString *encoded = [targetUrl stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet characterSetWithCharactersInString:@":/?=&;"]];
    NSString *proxyUrl = [PROXY_BASE stringByAppendingString:encoded];

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSError *taskError = nil;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    config.timeoutIntervalForResource = 300;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:proxyUrl]];
    [request setValue:@"libgrabkernel2-proxy/4.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:proxyUrl]
                                        completionHandler:^(NSData *taskData, NSURLResponse *response, NSError *err) {
                                            data = taskData;
                                            taskError = err;
                                            dispatch_semaphore_signal(semaphore);
                                        }];
    [task resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (error) *error = taskError;
    return data;
}

static inline NSString *apiURLForBuild(NSString *osStr, NSString *build) {
    return [NSString stringWithFormat:@"%@%@;%@.json", APPLEDB_BASE, osStr, build];
}

// ============================================================
// 固件 URL 查找（原版逻辑，数据源走代理）
// ============================================================
NSArray *hostsNeedingAuth = @[@"adcdownload.apple.com", @"download.developer.apple.com", @"developer.apple.com"];

static NSString *bestLinkFromSources(NSArray<NSDictionary<NSString *, id> *> *sources, NSString *modelIdentifier, bool *isOTA) {
    for (NSDictionary<NSString *, id> *source in sources) {
        if (![source[@"deviceMap"] containsObject:modelIdentifier]) continue;
        if (![@[@"ota", @"ipsw"] containsObject:source[@"type"]]) continue;
        if ([source[@"type"] isEqualToString:@"ota"] && source[@"prerequisiteBuild"]) continue;

        for (NSDictionary<NSString *, id> *link in source[@"links"]) {
            NSURL *url = [NSURL URLWithString:link[@"url"]];
            if ([hostsNeedingAuth containsObject:url.host]) continue;
            if (!link[@"active"]) continue;

            if (isOTA) *isOTA = [source[@"type"] isEqualToString:@"ota"];
            LOG("找到固件 (OTA: %s)\n", *isOTA ? "yes" : "no");
            return link[@"url"];
        }
    }
    return nil;
}

static NSString *getFirmwareURLFromDirect(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    NSError *error = nil;
    NSData *data = fetchJSONViaProxy(apiURLForBuild(osStr, build), &error);
    if (error || !data) {
        ERRLOG("API 查询失败: %s\n", error ? error.localizedDescription.UTF8String : "nil");
        return nil;
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) {
        ERRLOG("API 解析失败\n");
        return nil;
    }

    return bestLinkFromSources(json[@"sources"], modelIdentifier, isOTA);
}

static NSString *getFirmwareURLFromAll(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    DBGLOG("精确查询失败，尝试全量查询...\n");

    NSError *error = nil;
    NSData *compressed = fetchJSONViaProxy(APPLEDB_BASE @"main.json.xz", &error);
    if (error || !compressed) return nil;

    NSData *decompressed = [compressed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZMA error:&error];
    if (error || !decompressed) {
        ERRLOG("全量数据解压失败\n");
        return nil;
    }

    NSArray *json = [NSJSONSerialization JSONObjectWithData:decompressed options:0 error:&error];
    if (error || ![json isKindOfClass:[NSArray class]]) return nil;

    for (NSDictionary<NSString *, id> *firmware in json) {
        if ([firmware[@"osStr"] isEqualToString:osStr] && [firmware[@"build"] isEqualToString:build]) {
            NSString *url = bestLinkFromSources(firmware[@"sources"], modelIdentifier, isOTA);
            if (url) return url;
        }
    }

    return nil;
}

// ============================================================
// 对外接口
// ============================================================
NSString *getFirmwareURLFor(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    NSString *firmwareURL = getFirmwareURLFromDirect(osStr, build, modelIdentifier, isOTA);
    if (!firmwareURL) {
        firmwareURL = getFirmwareURLFromAll(osStr, build, modelIdentifier, isOTA);
    }

    if (!firmwareURL) {
        ERRLOG("无法找到固件 URL\n");
        return nil;
    }

    // 包裹 Worker 代理 URL
    NSString *encoded = [firmwareURL stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet characterSetWithCharactersInString:@":/?=&;"]];
    NSString *proxyUrl = [PROXY_BASE stringByAppendingString:encoded];
    LOG("固件 URL: %s\n", firmwareURL.UTF8String);
    LOG("代理 URL: %s\n", proxyUrl.UTF8String);
    return proxyUrl;
}

NSString *getFirmwareURL(bool *isOTA) {
    NSString *osStr = getOsStr();
    NSString *build = getBuild();
    NSString *modelIdentifier = getModelIdentifier();

    if (!osStr || !build || !modelIdentifier) return nil;

    return getFirmwareURLFor(osStr, build, modelIdentifier, isOTA);
}
