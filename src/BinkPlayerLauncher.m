#import <Cocoa/Cocoa.h>
#import <unistd.h>
#import <signal.h>

@interface LauncherDelegate : NSObject <NSApplicationDelegate>
@property (assign) BOOL launched;
@property (strong) NSOpenPanel *openPanel;
@end

@implementation LauncherDelegate

- (void)launchVideo:(NSString *)path {
    if (self.launched) return;
    self.launched = YES;
    if (self.openPanel) {
        [self.openPanel close];
        self.openPanel = nil;
    }

    // Close any already-running regular GUI BinkMacArmPlayer so audio doesn't overlap
    // when clicking through videos, without killing headless embed/test instances.
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy == NSApplicationActivationPolicyRegular &&
            ([app.localizedName isEqualToString:@"BinkMacArmPlayer"] ||
             [app.executableURL.lastPathComponent isEqualToString:@"BinkMacArmPlayer"])) {
            kill(app.processIdentifier, SIGTERM);
        }
    }

    NSString *macOSDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    NSString *playerBin = [macOSDir stringByAppendingPathComponent:@"BinkMacArmPlayer"];
    NSString *hudDylib = [macOSDir stringByAppendingPathComponent:@"libBinkHUD.dylib"];

    setenv("DYLD_INSERT_LIBRARIES", hudDylib.fileSystemRepresentation, 1);
    const char *argv[] = {
        playerBin.fileSystemRepresentation,
        "-m",
        "-l",
        path.fileSystemRepresentation,
        NULL
    };
    execv(playerBin.fileSystemRepresentation, (char *const *)argv);
    _exit(1);
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *u in urls) {
        if (u.isFileURL) {
            [self launchVideo:u.path];
            return;
        }
    }
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    if (filenames.count > 0) [self launchVideo:filenames.firstObject];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    for (NSUInteger i = 1; i < args.count; i++) {
        NSString *a = args[i];
        BOOL isDir = NO;
        if (![a hasPrefix:@"-"] &&
            [[NSFileManager defaultManager] fileExistsAtPath:a isDirectory:&isDir] &&
            !isDir) {
            [self launchVideo:a];
            return;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.launched) return;
        [NSApp activateIgnoringOtherApps:YES];
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"Choose a Bink (.bk2 / .bik) Video";
        panel.allowedFileTypes = @[@"bk2", @"bik"];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            panel.directoryURL = [NSURL fileURLWithPath:dir];
        }
        self.openPanel = panel;
        [panel beginWithCompletionHandler:^(NSModalResponse result) {
            self.openPanel = nil;
            if (self.launched) return;
            if (result == NSModalResponseOK && panel.URL) {
                [self launchVideo:panel.URL.path];
            } else {
                [NSApp terminate:nil];
            }
        }];
    });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        LauncherDelegate *del = [[LauncherDelegate alloc] init];
        app.delegate = del;
        [app run];
    }
    return 0;
}
