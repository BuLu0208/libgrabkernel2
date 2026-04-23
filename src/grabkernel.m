//
//  grabkernel.m
//  libgrabkernel2
//
//  Created by Alfie on 14/02/2024.
//  Modified: 支持 GitHub Release 镜像直接下载 kernelcache 文件
//

#include "grabkernel.h"
#include <Foundation/Foundation.h>
#include <partial/partial.h>
#include <string.h>
#include <sys/sysctl.h>
#include "appledb.h"
#include "utils.h"

static bool download_kernelcache_for(NSString *boardconfig, NSString *zipURL, bool isOTA, NSString *outPath) {
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

    // .kernelcache ending = direct file download from mirror
    if ([zipURL hasSuffix:@".kernelcache"]) {
        LOG("Downloading kernelcache from mirror...\n");

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block NSData *data = nil;
        __block NSError *taskError = nil;

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60;
        config.timeoutIntervalForResource = 600;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:zipURL]];
        [request setValue:@"libgrabkernel2-mirror/3.0" forHTTPHeaderField:@"User-Agent"];

        [[session dataTaskWithRequest:request completionHandler:^(NSData *taskData, NSURLResponse *response, NSError *err) {
            data = taskData;
            taskError = err;
            dispatch_semaphore_signal(semaphore);
        }] resume];

        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        if (taskError || !data || data.length < 1024 * 100) {
            ERRLOG("Failed to download kernelcache: %s\n",
                   taskError ? taskError.localizedDescription.UTF8String : "file too small");
            return false;
        }

        NSError *writeError = nil;
        if (![data writeToFile:outPath options:NSDataWritingAtomic error:&writeError]) {
            ERRLOG("Failed to write kernelcache: %s\n", writeError.localizedDescription.UTF8String);
            return false;
        }

        LOG("Downloaded kernelcache! (%.1f MB)\n", data.length / 1024.0 / 1024.0);
        return true;
    }

    // Otherwise use Partial ZIP to extract from IPSW
    Partial *zip = [Partial partialZipWithURL:[NSURL URLWithString:zipURL] error:&error];
    if (!zip) {
        ERRLOG("Failed to open zip file! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    LOG("Downloading BuildManifest.plist...\n");

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

    LOG("Downloading %s to %s...\n", kernelCachePath.UTF8String, outPath.UTF8String);

    NSData *kernelCacheData = [zip getFileForPath:kernelCachePath error:&error];
    if (!kernelCacheData) {
        ERRLOG("Failed to download kernelcache! %s\n", error.localizedDescription.UTF8String);
        return false;
    } else {
        LOG("Downloaded kernelcache!\n");
    }

    if (![kernelCacheData writeToFile:outPath options:NSDataWritingAtomic error:&error]) {
        ERRLOG("Failed to write kernelcache to %s! %s\n", outPath.UTF8String, error.localizedDescription.UTF8String);
        return false;
    }

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
