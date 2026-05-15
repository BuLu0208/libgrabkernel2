//
//  appledb.m
//  libgrabkernel2
//
//  Created by Dhinak G on 3/4/24.
//

#import <Foundation/Foundation.h>
#import <sys/utsname.h>
#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif
#import <sys/sysctl.h>
#import "appledb.h"
#import "appledb_internal.h"
#import "utils.h"

#define IPSW_API @"https://api.ipsw.me/v4/device/"

@implementation FirmwareLink
@end

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

static FirmwareLink *findFirmwareByBuild(NSArray *firmwares, NSString *targetBuild) {
    for (NSDictionary *fw in firmwares) {
        NSString *buildid = fw[@"buildid"];
        if ([buildid isEqualToString:targetBuild]) {
            NSString *url = fw[@"url"];
            if (url.length) {
                FirmwareLink *fl = [[FirmwareLink alloc] init];
                fl.url = url;
                fl.isOTA = NO;
                fl.isAEA = NO;
                fl.decryptionKey = nil;
                LOG("Found firmware URL: %s (OTA: no, AEA: no, key: no)\n", url.UTF8String);
                return fl;
            }
        }
    }
    return nil;
}

FirmwareLink *getFirmwareLinkFor(NSString *osStr, NSString *build, NSString *modelIdentifier) {
    if (!modelIdentifier || !build) {
        ERRLOG("Missing modelIdentifier or build\n");
        return nil;
    }

    NSString *apiURL = [NSString stringWithFormat:@"%@%@", IPSW_API, modelIdentifier];

    NSError *error = nil;
    NSData *data = makeSynchronousRequest(apiURL, &error);
    if (error) {
        ERRLOG("Failed to fetch firmware data: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) {
        ERRLOG("Failed to parse firmware data\n");
        return nil;
    }

    NSArray *firmwares = json[@"firmwares"];
    if (![firmwares isKindOfClass:[NSArray class]]) {
        ERRLOG("Invalid firmware data\n");
        return nil;
    }

    FirmwareLink *fl = findFirmwareByBuild(firmwares, build);
    if (!fl) {
        ERRLOG("Failed to find firmware for build %s\n", build.UTF8String);
    }
    return fl;
}

FirmwareLink *getFirmwareLink(void) {
    NSString *build = getBuild();
    NSString *modelIdentifier = getModelIdentifier();

    if (!build || !modelIdentifier) {
        return nil;
    }

    return getFirmwareLinkFor(nil, build, modelIdentifier);
}

// Legacy shims preserved for ABI compatibility.
NSString *getFirmwareURLFor(NSString *osStr, NSString *build, NSString *modelIdentifier, bool *isOTA) {
    FirmwareLink *fl = getFirmwareLinkFor(osStr, build, modelIdentifier);
    if (!fl) {
        return nil;
    }
    if (isOTA) {
        *isOTA = fl.isOTA;
    }
    return fl.url;
}

NSString *getFirmwareURL(bool *isOTA) {
    FirmwareLink *fl = getFirmwareLink();
    if (!fl) {
        return nil;
    }
    if (isOTA) {
        *isOTA = fl.isOTA;
    }
    return fl.url;
}
