//
//  grabkernel.m
//  libgrabkernel2
//
//  Created by Alfie on 14/02/2024.
//  Modified: 所有请求走 CF Worker 代理，通过 Partial ZIP 从 IPSW 提取 kernelcache
//

#include "grabkernel.h"
#include <Foundation/Foundation.h>
#include <partial/partial.h>
#include <string.h>
#include <sys/sysctl.h>
#include "appledb.h"
#include "utils.h"

bool download_kernelcache_for(NSString *boardconfig, NSString *zipURL, bool isOTA, NSString *outPath) {
    NSError *error = nil;
    NSString *pathPrefix = isOTA ? @"AssetData/boot" : @"";

    if (!zipURL) {
        ERRLOG("Missing firmware URL!\n");
        return false;
    }

    if (!outPath) {
        ERRLOG("Missing output path!\n");
        return false;
    }

    if (![[NSFileManager defaultManager] isWritableFileAtPath:outPath.stringByDeletingLastPathComponent]) {
        ERRLOG("Output directory is not writable!\n");
        return false;
    }

    // 通过 Worker 代理打开 IPSW（ZIP），Partial ZIP 用 Range 请求提取文件
    LOG("正在打开 IPSW...\n");
    Partial *zip = [Partial partialZipWithURL:[NSURL URLWithString:zipURL] error:&error];
    if (!zip) {
        ERRLOG("Failed to open zip file! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    LOG("正在下载 BuildManifest.plist...\n");

    NSData *buildManifestData = [zip getFileForPath:[pathPrefix stringByAppendingPathComponent:@"BuildManifest.plist"] error:&error];
    if (!buildManifestData) {
        ERRLOG("Failed to download BuildManifest.plist! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    NSDictionary *buildManifest = [NSPropertyListSerialization propertyListWithData:buildManifestData options:0 format:NULL error:&error];
    if (error) {
        ERRLOG("Failed to parse BuildManifest.plist! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    // 用 boardconfig 精确匹配 DeviceClass，跳过 Research 变体
    NSString *kernelCachePath = nil;

    for (NSDictionary<NSString *, id> *identity in buildManifest[@"BuildIdentities"]) {
        if ([identity[@"Info"][@"Variant"] hasPrefix:@"Research"]) {
            continue;
        }
        if ([identity[@"Info"][@"DeviceClass"] isEqualToString:boardconfig.lowercaseString]) {
            kernelCachePath = [pathPrefix stringByAppendingPathComponent:identity[@"Manifest"][@"KernelCache"][@"Info"][@"Path"]];
        }
    }

    if (!kernelCachePath) {
        ERRLOG("Failed to find kernelcache path in BuildManifest.plist!\n");
        return false;
    }

    LOG("正在提取 %s ...\n", kernelCachePath.UTF8String);

    NSData *kernelCacheData = [zip getFileForPath:kernelCachePath error:&error];
    if (!kernelCacheData) {
        ERRLOG("Failed to download kernelcache! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    if (![kernelCacheData writeToFile:outPath options:NSDataWritingAtomic error:&error]) {
        ERRLOG("Failed to write kernelcache to %s! %s\n", outPath.UTF8String, error.localizedDescription.UTF8String);
        return false;
    }

    LOG("Kernelcache 提取成功! (%.1f MB)\n", kernelCacheData.length / 1024.0 / 1024.0);
    return true;
}

bool download_kernelcache(NSString *zipURL, bool isOTA, NSString *outPath) {
    NSString *boardconfig = getBoardconfig();

    if (!boardconfig) {
        ERRLOG("Failed to get boardconfig!\n");
        return false;
    }

    return download_kernelcache_for(boardconfig, zipURL, isOTA, outPath);
}

bool grab_kernelcache_for(NSString *osStr, NSString *build, NSString *modelIdentifier, NSString *boardconfig, NSString *outPath) {
    bool isOTA = NO;
    NSString *firmwareURL = getFirmwareURLFor(osStr, build, modelIdentifier, &isOTA);
    if (!firmwareURL) {
        return false;
    }

    return download_kernelcache_for(boardconfig, firmwareURL, isOTA, outPath);
}

bool grab_kernelcache(NSString *outPath) {
    bool isOTA = NO;
    NSString *firmwareURL = getFirmwareURL(&isOTA);
    if (!firmwareURL) {
        return false;
    }

    return download_kernelcache(firmwareURL, isOTA, outPath);
}

bool grab_kernelcache_for_build_number(NSString *build, NSString *outPath) {
    bool isOTA = NO;
    NSString *firmwareURL = getFirmwareURLFor(getOsStr(), build, getModelIdentifier(), &isOTA);
    if (!firmwareURL) {
        ERRLOG("Failed to get firmware URL for build number: %s\n", build.UTF8String);
        return false;
    }

    return download_kernelcache(firmwareURL, isOTA, outPath);
}

int grabkernel(char *downloadPath, int isResearchKernel __unused) {
    NSString *outPath = [NSString stringWithCString:downloadPath encoding:NSUTF8StringEncoding];
    return grab_kernelcache(outPath) ? 0 : -1;
}
