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
        OSStatus s1 = LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)bk2.identifier, kLSRolesViewer | kLSRolesEditor, bundleID);
        OSStatus s2 = LSSetDefaultRoleHandlerForContentType(CFSTR("com.radgametools.bink2"), kLSRolesAll, bundleID);
        OSStatus s3 = LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)bik.identifier, kLSRolesViewer | kLSRolesEditor, bundleID);
        NSLog(@"LSSetDefaultRoleHandler statuses: %d, %d, %d", (int)s1, (int)s2, (int)s3);

    }
    return 0;
}
