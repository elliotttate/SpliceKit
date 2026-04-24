// SpliceKitBRAWToolboxCheck.m — Braw Toolbox presence + signature check.

#import "SpliceKitBRAWToolboxCheck.h"

#if 0
#import <CoreServices/CoreServices.h>
#import <Security/Security.h>

static NSString *const kSpliceKitBRAWToolboxBundleID = @"com.latenitefilms.BRAWToolbox";
static NSString *const kSpliceKitBRAWToolboxTeamID   = @"A5HDJTY9X5";
static NSString *const kSpliceKitBRAWToolboxAuthority = @"Apple Mac OS Application Signing";
static NSString *const kSpliceKitBRAWToolboxBypassDefault = @"SpliceKitBypassBRAWToolboxCheck";

static void SpliceKitBRAWToolboxLog(NSString *message) {
    if (message.length == 0) return;
    NSLog(@"[SpliceKit BRAW Toolbox] %@", message);

    // Mirror the BRAW bootstrap log so gated-off BRAW is easy to diagnose.
    NSString *path = @"/tmp/splicekit-braw.log";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSString *line = [NSString stringWithFormat:@"%@ [toolbox-check] %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle || !data) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *e) {
    } @finally {
        [handle closeFile];
    }
}

static BOOL SpliceKitBRAWToolboxValidateURL(NSURL *appURL) {
    SecStaticCodeRef staticCode = NULL;
    OSStatus status = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)appURL, kSecCSDefaultFlags, &staticCode);
    if (status != errSecSuccess || staticCode == NULL) {
        SpliceKitBRAWToolboxLog([NSString stringWithFormat:@"SecStaticCodeCreateWithPath failed (status=%d) for %@",
                                                           (int)status, appURL.path]);
        if (staticCode) CFRelease(staticCode);
        return NO;
    }

    CFDictionaryRef signingInfo = NULL;
    status = SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &signingInfo);
    if (status != errSecSuccess || signingInfo == NULL) {
        SpliceKitBRAWToolboxLog([NSString stringWithFormat:@"SecCodeCopySigningInformation failed (status=%d) for %@",
                                                           (int)status, appURL.path]);
        CFRelease(staticCode);
        if (signingInfo) CFRelease(signingInfo);
        return NO;
    }

    NSDictionary *signingDict = (__bridge NSDictionary *)signingInfo;
    NSString *teamID = signingDict[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    BOOL teamIDMatches = [teamID isEqualToString:kSpliceKitBRAWToolboxTeamID];

    BOOL authorityMatches = NO;
    NSArray *chain = signingDict[(__bridge NSString *)kSecCodeInfoCertificates];
    if (chain.count > 0) {
        SecCertificateRef leaf = (__bridge SecCertificateRef)chain[0];
        CFStringRef commonName = NULL;
        OSStatus certStatus = SecCertificateCopyCommonName(leaf, &commonName);
        if (certStatus == errSecSuccess && commonName != NULL) {
            authorityMatches = [(__bridge NSString *)commonName isEqualToString:kSpliceKitBRAWToolboxAuthority];
            CFRelease(commonName);
        }
    }

    SpliceKitBRAWToolboxLog([NSString stringWithFormat:@"candidate path=%@ team=%@ (%@) authority=%@",
                                                       appURL.path,
                                                       teamID ?: @"(nil)",
                                                       teamIDMatches ? @"match" : @"mismatch",
                                                       authorityMatches ? @"match" : @"mismatch"]);

    CFRelease(signingInfo);
    CFRelease(staticCode);
    return teamIDMatches && authorityMatches;
}

static BOOL SpliceKitBRAWToolboxComputeInstalled(void) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kSpliceKitBRAWToolboxBypassDefault]) {
        SpliceKitBRAWToolboxLog(@"bypass default set — treating Braw Toolbox as installed");
        return YES;
    }

    NSArray *appURLs = (__bridge_transfer NSArray *)LSCopyApplicationURLsForBundleIdentifier(
        (__bridge CFStringRef)kSpliceKitBRAWToolboxBundleID, NULL);

    if (appURLs.count == 0) {
        SpliceKitBRAWToolboxLog(@"no app installed with bundle ID com.latenitefilms.BRAWToolbox");
        return NO;
    }

    for (NSURL *appURL in appURLs) {
        if (SpliceKitBRAWToolboxValidateURL(appURL)) {
            SpliceKitBRAWToolboxLog([NSString stringWithFormat:@"validated Braw Toolbox at %@", appURL.path]);
            return YES;
        }
    }

    SpliceKitBRAWToolboxLog(@"found Braw Toolbox bundle ID but no copy passed signature validation");
    return NO;
}

BOOL SpliceKit_isBRAWToolboxInstalled(void) {
    static dispatch_once_t onceToken;
    static BOOL installed = NO;
    dispatch_once(&onceToken, ^{
        installed = SpliceKitBRAWToolboxComputeInstalled();
    });
    return installed;
}
#endif

BOOL SpliceKit_isBRAWToolboxInstalled(void) {
    // Ownership gate disabled while BRAW support is being tested directly.
    return YES;
}
