//
//  appledb.m
//  libgrabkernel2
//
//  Created by Dhinak G on 3/4/24.
//  Modified: 走 GitHub Release 镜像下载 kernelcache，通过 Cloudflare Workers 代理加速
//

#import <Foundation/Foundation.h>
#import "utils.h"

// ============================================================
// 🔧 GitHub Release 镜像配置
// ============================================================
#define MIRROR_BASE_URL @"https://github.lengye.top/download"
#define INDEX_IPHONE    MIRROR_BASE_URL @"/iphone-kernelcache/index_iphone.json"
#define INDEX_IPAD      MIRROR_BASE_URL @"/ipad-kernelcache/index_ipad.json"
// ============================================================

static NSData *fetchJSONSync(NSString *url, NSError **error) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSError *taskError = nil;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    config.timeoutIntervalForResource = 120;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:@"libgrabkernel2-mirror/3.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:url]
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

static NSString *getIndexURLForModel(NSString *modelIdentifier) {
    if ([modelIdentifier hasPrefix:@"iPhone"]) {
        return INDEX_IPHONE;
    } else if ([modelIdentifier hasPrefix:@"iPad"]) {
        return INDEX_IPAD;
    }
    return nil;
}

NSString *getFirmwareURLFor(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    NSString *indexURL = getIndexURLForModel(modelIdentifier);
    if (!indexURL) {
        ERRLOG("不支持的设备型号: %s\n", modelIdentifier.UTF8String);
        return nil;
    }

    LOG("正在获取内核缓存索引...\n");

    NSError *error = nil;
    NSData *data = fetchJSONSync(indexURL, &error);
    if (error || !data) {
        ERRLOG("获取索引失败: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    NSArray *index = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![index isKindOfClass:[NSArray class]]) {
        ERRLOG("解析索引失败: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    LOG("正在搜索内核缓存 (build %s)...\n", build.UTF8String);

    for (NSDictionary *entry in index) {
        if ([entry[@"model"] isEqualToString:modelIdentifier] &&
            [entry[@"build"] isEqualToString:build]) {
            NSString *url = (NSString *)entry[@"url"];
            NSString *version = (NSString *)entry[@"version"];
            LOG("找到内核缓存: iOS %s (%.1f MB)\n",
                version.UTF8String, [entry[@"size"] doubleValue] / 1024.0 / 1024.0);
            if (isOTA) *isOTA = NO;
            return url;
        }
    }

    ERRLOG("未找到匹配的内核缓存 (型号=%s build=%s)\n",
           modelIdentifier.UTF8String, build.UTF8String);
    return nil;
}

NSString *getFirmwareURL(bool *isOTA) {
    NSString *osStr = getOsStr();
    NSString *build = getBuild();
    NSString *modelIdentifier = getModelIdentifier();

    if (!osStr || !build || !modelIdentifier) {
        ERRLOG("获取设备信息失败! osStr=%s build=%s model=%s\n",
               osStr.UTF8String ?: "nil", build.UTF8String ?: "nil", modelIdentifier.UTF8String ?: "nil");
        return nil;
    }

    return getFirmwareURLFor(osStr, build, modelIdentifier, isOTA);
}
