//
//  grabkernel.c
//  libgrabkernel2
//
//  Created by Alfie on 14/02/2024.
//
// 本文件实现了从iOS固件中提取内核缓存的核心功能
// 包括下载固件、解压缩、提取内核缓存等操作

#include "grabkernel.h"
#include <Foundation/Foundation.h>
#include <partial/partial.h>
#include <string.h>
#include <sys/sysctl.h>
#include "appledb.h"
#include "utils.h"

bool download_kernelcache_for(NSString *boardconfig, NSString *zipURL, bool isOTA, NSString *outPath) {
    if (!boardconfig || ![boardconfig isKindOfClass:[NSString class]]) {
        ERRLOG("Invalid boardconfig parameter\n");
        return false;
    }

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

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *outputDir = outPath.stringByDeletingLastPathComponent;
    if (![fileManager isWritableFileAtPath:outputDir]) {
        ERRLOG("Output directory is not writable: %s\n", outputDir.UTF8String);
        return false;
    }

    DBGLOG("Initializing partial zip download from %s\n", zipURL.UTF8String);
    Partial *zip = [Partial partialZipWithURL:[NSURL URLWithString:zipURL] error:&error];
    if (!zip) {
        ERRLOG("Failed to open zip file! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    LOG("Downloading BuildManifest.plist...\n");
    NSString *manifestPath = [pathPrefix stringByAppendingPathComponent:@"BuildManifest.plist"];
    DBGLOG("Manifest path: %s\n", manifestPath.UTF8String);

    NSData *buildManifestData = [zip getFileForPath:manifestPath error:&error];
    if (!buildManifestData) {
        ERRLOG("Failed to download BuildManifest.plist! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    DBGLOG("Parsing BuildManifest.plist...\n");
    NSDictionary *buildManifest = [NSPropertyListSerialization propertyListWithData:buildManifestData options:0 format:NULL error:&error];
    if (error) {
        ERRLOG("Failed to parse BuildManifest.plist! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    NSString *kernelCachePath = nil;
    NSArray *buildIdentities = buildManifest[@"BuildIdentities"];
    if (![buildIdentities isKindOfClass:[NSArray class]]) {
        ERRLOG("Invalid BuildIdentities format in manifest\n");
        return false;
    }

    DBGLOG("Searching for kernelcache path for device: %s\n", boardconfig.UTF8String);
    for (NSDictionary<NSString *, id> *identity in buildIdentities) {
        if (![identity isKindOfClass:[NSDictionary class]]) {
            DBGLOG("Skipping invalid build identity entry\n");
            continue;
        }

        NSDictionary *info = identity[@"Info"];
        if (![info isKindOfClass:[NSDictionary class]]) {
            DBGLOG("Skipping build identity with invalid Info\n");
            continue;
        }

        if ([info[@"Variant"] hasPrefix:@"Research"]) {
            DBGLOG("Skipping Research variant\n");
            continue;
        }

        if ([info[@"DeviceClass"] isEqualToString:boardconfig.lowercaseString]) {
            NSDictionary *manifest = identity[@"Manifest"];
            if (![manifest isKindOfClass:[NSDictionary class]]) {
                DBGLOG("Invalid Manifest format in build identity\n");
                continue;
            }

            NSDictionary *kernelCache = manifest[@"KernelCache"];
            if (![kernelCache isKindOfClass:[NSDictionary class]]) {
                DBGLOG("Invalid KernelCache format in manifest\n");
                continue;
            }

            NSDictionary *kernelInfo = kernelCache[@"Info"];
            if (![kernelInfo isKindOfClass:[NSDictionary class]]) {
                DBGLOG("Invalid KernelCache Info format\n");
                continue;
            }

            kernelCachePath = [pathPrefix stringByAppendingPathComponent:kernelInfo[@"Path"]];
            DBGLOG("Found kernelcache path: %s\n", kernelCachePath.UTF8String);
            break;
        }
    }

    if (!kernelCachePath) {
        ERRLOG("Failed to find kernelcache path in BuildManifest.plist!\n");
        return false;
    }

    LOG("Downloading %s to %s...\n", kernelCachePath.UTF8String, outPath.UTF8String);

    NSData *kernelCacheData = [zip getFileForPath:kernelCachePath error:&error];
    if (!kernelCacheData) {
        ERRLOG("Failed to download kernelcache! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    DBGLOG("Downloaded kernelcache data size: %lu bytes\n", (unsigned long)kernelCacheData.length);
    if (kernelCacheData.length == 0) {
        ERRLOG("Downloaded kernelcache is empty!\n");
        return false;
    }

    LOG("Writing kernelcache to disk...\n");
    if (![kernelCacheData writeToFile:outPath options:NSDataWritingAtomic error:&error]) {
        ERRLOG("Failed to write kernelcache to %s! %s\n", outPath.UTF8String, error.localizedDescription.UTF8String);
        return false;
    }

    LOG("Successfully downloaded and saved kernelcache\n");
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

// TODO: Only require one of model identifier/boardconfig and use API to get the other?
bool grab_kernelcache_for(NSString *osStr, NSString *build, NSString *modelIdentifier, NSString *boardconfig, NSString *outPath) {
    bool isOTA = NO;
    NSString *firmwareURL = getFirmwareURLFor(osStr, build, modelIdentifier, &isOTA);
    if (!firmwareURL) {
        ERRLOG("Failed to get firmware URL!\n");
        return false;
    }

    return download_kernelcache_for(boardconfig, firmwareURL, isOTA, outPath);
}

bool grab_kernelcache(NSString *outPath) {
    bool isOTA = NO;
    NSString *firmwareURL = getFirmwareURL(&isOTA);
    if (!firmwareURL) {
        ERRLOG("Failed to get firmware URL!\n");
        return false;
    }

    return download_kernelcache(firmwareURL, isOTA, outPath);
}

// libgrabkernel compatibility shim
// Note that research kernel grabbing is not currently supported
// 兼容旧版libgrabkernel的接口
// downloadPath: 下载路径
// isResearchKernel: 是否为研究用内核(当前不支持)
// 返回值: 0表示成功，其他值表示失败
int grabkernel(char *downloadPath, int isResearchKernel __unused) {
    NSString *outPath = [NSString stringWithCString:downloadPath encoding:NSUTF8StringEncoding];
    return grab_kernelcache(outPath) ? 0 : -1;
}