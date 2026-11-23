// Makes Bink Player the default app for .bk2 / .bik files (run by install.sh).
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Cocoa/Cocoa.h>

int main(void) {
    @autoreleasepool {
        CFStringRef bundleID = CFSTR("com.local.binkplayer.hud");
        UTType *bk2 = [UTType typeWithFilenameExtension:@"bk2"];
        UTType *bik = [UTType typeWithFilenameExtension:@"bik"];
        NSLog(@"Resolved UTI for .bk2 = %@, .bik = %@", bk2.identifier, bik.identifier);
        OSStatus s1 = bk2.identifier
            ? LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)bk2.identifier, kLSRolesViewer | kLSRolesEditor, bundleID)
            : noErr;
        OSStatus s2 = LSSetDefaultRoleHandlerForContentType(CFSTR("com.radgametools.bink2"), kLSRolesAll, bundleID);
        OSStatus s3 = bik.identifier
            ? LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)bik.identifier, kLSRolesViewer | kLSRolesEditor, bundleID)
            : noErr;
        OSStatus s4 = LSSetDefaultRoleHandlerForContentType(CFSTR("com.radgametools.bink"), kLSRolesAll, bundleID);
        NSLog(@"LSSetDefaultRoleHandler statuses: %d, %d, %d, %d", (int)s1, (int)s2, (int)s3, (int)s4);

    }
    return 0;
}
