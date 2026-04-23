//
//  grabkernel.m
//  libgrabkernel2
//
//  Created by Alfie on 14/02/2024.
//  Modified: 支持 GitHub Release 镜像直接下载 kernelcache 文件，带进度显示
//

#include "grabkernel.h"
#include <Foundation/Foundation.h>
#include <partial/partial.h>
#include <string.h>
#include <sys/sysctl.h>
#include "appledb.h"
#include "utils.h"

#pragma mark - Download Progress Delegate

@interface _KCDownloadDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, assign) long long expectedLength;
@property (nonatomic, assign) long long receivedLength;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, assign) int lastLoggedPct;
@end

@implementation _KCDownloadDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _data = [NSMutableData data];
        _lastLoggedPct = -1;
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    long long length = response.expectedContentLength;
    if (length > 0) {
        _expectedLength = length;
        LOG("下载大小: %.1f MB\n", length / 1024.0 / 1024.0);
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)chunk {
    [_data appendData:chunk];
    _receivedLength += chunk.length;

    if (_expectedLength > 0) {
        int pct = (int)((double)_receivedLength / _expectedLength * 100);
        // Log every 5% to avoid spam
        if (pct / 5 != _lastLoggedPct / 5 || pct == 100) {
            _lastLoggedPct = pct;
            int barCount = pct / 5;
            char bar[22];
            memset(bar, '=', barCount);
            bar[barCount] = '\0';
            LOG("正在下载内核缓存... [%-20s] %d%%\n", bar, pct);
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    _error = error;
}

@end

#pragma mark - Direct Download (GitHub Mirror)

static bool downloadKernelcacheDirect(NSString *url, NSString *outPath) {
    if (!url || !outPath) {
        ERRLOG("缺少下载地址或输出路径!\n");
        return false;
    }

    if (![[NSFileManager defaultManager] isWritableFileAtPath:outPath.stringByDeletingLastPathComponent]) {
        ERRLOG("输出目录不可写!\n");
        return false;
    }

    LOG("开始下载内核缓存...\n");

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    _KCDownloadDelegate *delegate = [[_KCDownloadDelegate alloc] init];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 60;
    config.timeoutIntervalForResource = 600;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:@"libgrabkernel2-mirror/3.0" forHTTPHeaderField:@"User-Agent"];

    [[session dataTaskWithRequest:request completionHandler:^(NSData *taskData, NSURLResponse *response, NSError *error) {
        dispatch_semaphore_signal(semaphore);
    }] resume];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    [session invalidateAndCancel];

    if (delegate.error || delegate.data.length < 1024 * 100) {
        ERRLOG("下载内核缓存失败: %s\n",
               delegate.error ? delegate.error.localizedDescription.UTF8String : "文件过小");
        return false;
    }

    NSError *writeError = nil;
    if (![delegate.data writeToFile:outPath options:NSDataWritingAtomic error:&writeError]) {
        ERRLOG("写入内核缓存失败: %s\n", writeError.localizedDescription.UTF8String);
        return false;
    }

    LOG("内核缓存下载完成! (%.1f MB)\n", delegate.data.length / 1024.0 / 1024.0);
    return true;
}

#pragma mark - Partial ZIP Download (Legacy IPSW)

static bool downloadKernelcacheFromIPSW(NSString *boardconfig, NSString *zipURL, bool isOTA, NSString *outPath) {
    NSError *error = nil;
    NSString *pathPrefix = isOTA ? @"AssetData/boot" : @"";

    if (!zipURL) {
        ERRLOG("缺少固件地址!\n");
        return false;
    }

    if (!outPath) {
        ERRLOG("缺少输出路径!\n");
        return false;
    }

    if (![[NSFileManager defaultManager] isWritableFileAtPath:outPath.stringByDeletingLastPathComponent]) {
        ERRLOG("输出目录不可写!\n");
        return false;
    }

    Partial *zip = [Partial partialZipWithURL:[NSURL URLWithString:zipURL] error:&error];
    if (!zip) {
        ERRLOG("打开固件文件失败! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    LOG("正在下载 BuildManifest.plist...\n");

    NSData *buildManifestData = [zip getFileForPath:[pathPrefix stringByAppendingPathComponent:@"BuildManifest.plist"] error:&error];
    if (!buildManifestData) {
        ERRLOG("下载 BuildManifest.plist 失败! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    NSDictionary *buildManifest = [NSPropertyListSerialization propertyListWithData:buildManifestData options:0 format:NULL error:&error];
    if (error) {
        ERRLOG("解析 BuildManifest.plist 失败! %s\n", error.localizedDescription.UTF8String);
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
        ERRLOG("在 BuildManifest.plist 中未找到内核缓存路径!\n");
        return false;
    }

    LOG("正在下载 %s...\n", kernelCachePath.UTF8String);

    NSData *kernelCacheData = [zip getFileForPath:kernelCachePath error:&error];
    if (!kernelCacheData) {
        ERRLOG("下载内核缓存失败! %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    if (![kernelCacheData writeToFile:outPath options:NSDataWritingAtomic error:&error]) {
        ERRLOG("写入内核缓存失败 %s! %s\n", outPath.UTF8String, error.localizedDescription.UTF8String);
        return false;
    }

    LOG("内核缓存下载完成! (%.1f MB)\n", kernelCacheData.length / 1024.0 / 1024.0);
    return true;
}

#pragma mark - Public API

bool download_kernelcache_for(NSString *boardconfig, NSString *zipURL, bool isOTA, NSString *outPath) {
    if ([zipURL hasSuffix:@".kernelcache"]) {
        return downloadKernelcacheDirect(zipURL, outPath);
    }
    return downloadKernelcacheFromIPSW(boardconfig, zipURL, isOTA, outPath);
}

bool download_kernelcache(NSString *zipURL, bool isOTA, NSString *outPath) {
    NSString *boardconfig = getBoardconfig();

    if (!boardconfig) {
        ERRLOG("获取 boardconfig 失败!\n");
        return false;
    }

    return download_kernelcache_for(boardconfig, zipURL, isOTA, outPath);
}

bool grab_kernelcache_for(NSString *osStr, NSString *build, NSString *modelIdentifier, NSString *boardconfig, NSString *outPath) {
    bool isOTA = NO;
    NSString *firmwareURL = getFirmwareURLFor(osStr, build, modelIdentifier, &isOTA);
    if (!firmwareURL) {
        ERRLOG("获取固件地址失败!\n");
        return false;
    }

    return download_kernelcache_for(boardconfig, firmwareURL, isOTA, outPath);
}

bool grab_kernelcache(NSString *outPath) {
    bool isOTA = NO;
    NSString *firmwareURL = getFirmwareURL(&isOTA);
    if (!firmwareURL) {
        ERRLOG("获取固件地址失败!\n");
        return false;
    }

    return download_kernelcache(firmwareURL, isOTA, outPath);
}

bool grab_kernelcache_for_build_number(NSString *build, NSString *outPath) {
    bool isOTA = NO;
    NSString *firmwareURL = getFirmwareURLFor(getOsStr(), build, getModelIdentifier(), &isOTA);
    if (!firmwareURL) {
        ERRLOG("获取固件地址失败 (build: %s)\n", build.UTF8String);
        return false;
    }

    return download_kernelcache(firmwareURL, isOTA, outPath);
}

int grabkernel(char *downloadPath, int isResearchKernel __unused) {
    NSString *outPath = [NSString stringWithCString:downloadPath encoding:NSUTF8StringEncoding];
    return grab_kernelcache(outPath) ? 0 : -1;
}
