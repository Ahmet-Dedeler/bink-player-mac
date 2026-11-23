#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdio.h>
#import <pthread.h>
#import <AudioToolbox/AudioToolbox.h>

// ---------------------------------------------------------------------------
// Audio volume / mute
// Bink drives its playback clock from the sound track, so BinkSetSoundOnOff(0)
// freezes the video. Instead we interpose AudioQueueNewOutput (the only audio
// output API the RAD player uses), remember every queue, and set its volume.
// ---------------------------------------------------------------------------
#define MAX_QUEUES 32
static AudioQueueRef g_queues[MAX_QUEUES];
static int g_numQueues = 0;
static float g_volume = 1.0f;          // 0..1, persisted
static _Atomic int32_t g_muted_flag = 0;
static pthread_mutex_t g_qlock = PTHREAD_MUTEX_INITIALIZER;

static void apply_volume(void) {
    pthread_mutex_lock(&g_qlock);
    float v = atomic_load(&g_muted_flag) ? 0.0f : g_volume;
    for (int i = 0; i < g_numQueues; i++) AudioQueueSetParameter(g_queues[i], kAudioQueueParam_Volume, v);
    pthread_mutex_unlock(&g_qlock);
}

static OSStatus hud_AudioQueueNewOutput(const AudioStreamBasicDescription *fmt, AudioQueueOutputCallback cb, void *ud,
                                        CFRunLoopRef rl, CFStringRef mode, UInt32 flags, AudioQueueRef *outAQ) {
    OSStatus st = AudioQueueNewOutput(fmt, cb, ud, rl, mode, flags, outAQ);
    if (st == noErr && outAQ && *outAQ) {
        pthread_mutex_lock(&g_qlock);
        if (g_numQueues < MAX_QUEUES) g_queues[g_numQueues++] = *outAQ;
        AudioQueueSetParameter(*outAQ, kAudioQueueParam_Volume, atomic_load(&g_muted_flag) ? 0.0f : g_volume);
        pthread_mutex_unlock(&g_qlock);
    }
    return st;
}

static OSStatus hud_AudioQueueDispose(AudioQueueRef q, Boolean immediate) {
    pthread_mutex_lock(&g_qlock);
    for (int i = 0; i < g_numQueues; i++) {
        if (g_queues[i] == q) { g_queues[i] = g_queues[--g_numQueues]; break; }
    }
    pthread_mutex_unlock(&g_qlock);
    return AudioQueueDispose(q, immediate);
}

__attribute__((used)) static struct { const void *replacement; const void *original; } g_interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)hud_AudioQueueNewOutput, (const void *)AudioQueueNewOutput },
    { (const void *)hud_AudioQueueDispose,   (const void *)AudioQueueDispose },
};

typedef struct {
    uint32_t Width;
    uint32_t Height;
    uint32_t Frames;
    uint32_t FrameNum;
    uint32_t LastFrameNum;
    uint32_t FrameRate;
    uint32_t FrameRateDiv;
} BinkHeader;

typedef void (*BinkPauseFn)(void *bnk, int32_t pause);
typedef void (*BinkGotoFn)(void *bnk, uint32_t frame);
typedef int32_t (*BinkSetSoundOnOffFn)(void *bnk, int32_t onoff);
typedef int32_t (*BinkDoFrameAsyncWaitFn)(void *bnk, int32_t us);
typedef int32_t (*BinkDoFrameAsyncMultiFn)(void *bnk, uint32_t *threads, int32_t num_threads);
typedef void (*TexUpdateFn)(void *tex);

static uintptr_t g_base = 0;
static BinkHeader **g_bink_ptr = NULL;
static BinkHeader *g_bink_captured = NULL;
static void **g_tex_ptr = NULL;
static uint32_t *g_threads_ptr = NULL;
static int32_t *g_num_threads_ptr = NULL;
static int32_t *g_paused_ptr = NULL;
static uint8_t *g_loop_ptr = NULL;
static uint32_t *g_input_flags_ptr = NULL;

static BinkPauseFn fn_BinkPause = NULL;
static BinkGotoFn fn_BinkGoto = NULL;
static BinkSetSoundOnOffFn fn_BinkSetSoundOnOff = NULL;
static BinkDoFrameAsyncWaitFn fn_BinkDoFrameAsyncWait = NULL;
static BinkDoFrameAsyncMultiFn fn_BinkDoFrameAsyncMulti = NULL;

static _Atomic int32_t g_pendingSeekFrame = 0;
static _Atomic int32_t g_pendingSeekExact = 0;
static _Atomic int32_t g_pendingTogglePause = 0;
static _Atomic int32_t g_pendingStepFrame = 0;
static _Atomic int32_t g_pendingToggleMute = 0;
static _Atomic int32_t g_pendingQuit = 0;
#define g_muted g_muted_flag

static NSString *g_videoPath = nil;

// User-facing loop setting. The RAD player is always launched with -l (its own loop byte
// stays 1) because without it the app simply quits when the video ends. We stop on the
// last frame ourselves when the user has looping off, like QuickTime.
static BOOL g_userLoop = NO;
static BOOL g_stoppedAtEnd = NO;
static uint32_t g_lastSeenFrame = 0;
static NSString *const kPrefsSuite = @"com.local.binkplayer.hud";
static NSUserDefaults *prefs(void) {
    // Inside the app bundle the standard domain already is com.local.binkplayer.hud.
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:kPrefsSuite]) return NSUserDefaults.standardUserDefaults;
    static NSUserDefaults *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite]; });
    return d;
}

static BinkHeader *current_bink(void) {
    if (g_bink_ptr) return *g_bink_ptr;
    return g_bink_captured;
}

static uint32_t find_nearest_keyframe(void *bnk, uint32_t targetFrame1) {
    BinkHeader *h = (BinkHeader *)bnk;
    if (!h || h->Frames == 0) return 1;
    if (targetFrame1 < 1) targetFrame1 = 1;
    if (targetFrame1 > h->Frames) targetFrame1 = h->Frames;
    uint64_t *frameOffsets = *(uint64_t **)((uint8_t *)bnk + 0x268);
    if (!frameOffsets) return 1;
    uint32_t idx = targetFrame1 - 1;
    while (idx > 0 && !(frameOffsets[idx] & 1ULL)) {
        idx--;
    }
    return idx + 1;
}

static double bink_fps(BinkHeader *h) {
    if (!h || h->FrameRateDiv == 0 || h->FrameRate == 0) return 30.0;
    return (double)h->FrameRate / (double)h->FrameRateDiv;
}

static NSString *fmt_time(double sec) {
    if (sec < 0) sec = 0;
    int s = (int)sec;
    return [NSString stringWithFormat:@"%02d:%02d", s / 60, s % 60];
}

static void configure_all_audio_tracks(const char *path) {
    if (!path || !g_base) return;
    FILE *f = fopen(path, "rb");
    if (!f) return;
    uint8_t hdr[44];
    size_t n = fread(hdr, 1, sizeof(hdr), f);
    if (n < 44) {
        fclose(f);
        return;
    }

    BOOL hasExtra = (hdr[0] == 'B' && hdr[1] == 'I' && hdr[2] == 'K' && hdr[3] == 'k') ||
                    (hdr[0] == 'K' && hdr[1] == 'B' && hdr[2] == '2' &&
                     (hdr[3] == 'i' || hdr[3] == 'j' || hdr[3] == 'k' || hdr[3] == 'm' || hdr[3] == 'n'));
    size_t trackTableOff = hasExtra ? 48 : 44;
    uint32_t rawTracks = 0;
    memcpy(&rawTracks, hdr + 40, sizeof(rawTracks));
    uint32_t totalTracks = rawTracks & 0xbfffffffU;
    if (totalTracks == 0) {
        *(uint32_t *)(g_base + 0x558dc) = 0;
        fclose(f);
        return;
    }

    size_t idsOff = trackTableOff + 8 * (size_t)totalTracks;
    uint32_t openTracks = totalTracks > 16 ? 16 : totalTracks;
    uint32_t trackIDs[16];
    if (fseeko(f, (off_t)idsOff, SEEK_SET) != 0 ||
        fread(trackIDs, sizeof(uint32_t), openTracks, f) != openTracks) {
        fclose(f);
        return;
    }
    fclose(f);

    uint32_t *g_num_tracks = (uint32_t *)(g_base + 0x558dc);
    uint32_t *g_track_ids  = (uint32_t *)(g_base + 0x55d70);
    *g_num_tracks = openTracks;
    for (uint32_t i = 0; i < openTracks; i++) {
        g_track_ids[i] = trackIDs[i];
    }
}

static void perform_clean_seek(void *bnk, uint32_t targetFrame1, int exact) {
    if (!bnk || !fn_BinkGoto || !fn_BinkDoFrameAsyncWait || !fn_BinkDoFrameAsyncMulti) return;
    BinkHeader *h = (BinkHeader *)bnk;
    if (h->Frames == 0) return;
    if (targetFrame1 < 1) targetFrame1 = 1;
    if (targetFrame1 > h->Frames) targetFrame1 = h->Frames;

    uint32_t kf = find_nearest_keyframe(bnk, targetFrame1);
    if (!exact && targetFrame1 - kf > 150) {
        // Live drag preview: never yank back to a distant keyframe; wait for mouse-up exact seek.
        return;
    }

    void *tex = g_tex_ptr ? *g_tex_ptr : NULL;
    TexUpdateFn startTex  = tex ? *(TexUpdateFn *)((uint8_t *)tex + 0) : NULL;
    TexUpdateFn finishTex = tex ? *(TexUpdateFn *)((uint8_t *)tex + 8) : NULL;
    int32_t nthreads = g_num_threads_ptr ? *g_num_threads_ptr : 0;

    // 1. Finish currently in-flight async decode cleanly
    while (!fn_BinkDoFrameAsyncWait(bnk, 100000)) {}
    uint32_t curFrame = h->FrameNum; // curFrame is now fully decoded in reference buffers!
    if (finishTex) finishTex(tex);

    // 2. Silence Bink's sound while we decode forward (always re-enabled below:
    //    Bink's clock stalls while sound is off; user mute is queue volume)
    int wasMuted = 0;
    if (fn_BinkSetSoundOnOff) {
        fn_BinkSetSoundOnOff(bnk, 0);
    }

    // Decide startFrame and endFrame:
    // - On exact seek (click / slider release / ±5s): ALWAYS land on targetFrame1!
    //   If seeking forward and no keyframe lies between curFrame and targetFrame1,
    //   fast-forward from curFrame + 1 instead of rewinding all the way to frame 1!
    uint32_t startFrame = kf;
    uint32_t endFrame = targetFrame1;

    if (!exact) {
        startFrame = kf;
        endFrame = kf;
    } else {
        if (targetFrame1 > curFrame && kf <= curFrame) {
            startFrame = curFrame + 1;
        } else {
            startFrame = kf;
        }
        // No "too far, land on the keyframe instead" fallback: that is exactly what made
        // seeks near the end of single-keyframe clips jump back to 00:00. Decoding runs
        // at roughly 0.25 ms per 1440p frame, so even a long run is well under a second.
    }

    BOOL willBePaused = g_paused_ptr &&
                        ((*g_paused_ptr != 0) ^ ((g_input_flags_ptr && (*g_input_flags_ptr & 0x2)) != 0));
    BOOL stopAtEnd = (!g_userLoop && h->Frames > 1 && endFrame >= h->Frames);
    BOOL holdFrame = willBePaused || stopAtEnd;

    for (uint32_t f = startFrame; f <= endFrame; f++) {
        if (f == endFrame && fn_BinkSetSoundOnOff && !wasMuted) {
            fn_BinkSetSoundOnOff(bnk, 1);
        }
        fn_BinkGoto(bnk, f);
        if (startTex) startTex(tex);
        fn_BinkDoFrameAsyncMulti(bnk, g_threads_ptr, nthreads);
        while (!fn_BinkDoFrameAsyncWait(bnk, 100000)) {}
        if (f < endFrame || holdFrame) {
            if (finishTex) finishTex(tex);
        }
    }

    g_lastSeenFrame = h->FrameNum;   // a seek is not a wrap-around
    g_stoppedAtEnd = stopAtEnd;
    *(uint32_t *)((uint8_t *)bnk + 0x6e4) = 0;
    *(uint32_t *)((uint8_t *)bnk + 0x6e8) = *(uint32_t *)((uint8_t *)bnk + 0x6d0);
    *(uint32_t *)((uint8_t *)bnk + 0x73c) = 0;

    if (stopAtEnd && !willBePaused && g_input_flags_ptr) {
        // Pause on the final frame without advancing/wrapping to frame 1.
        *g_input_flags_ptr |= 0x2;
    }
}

@interface HUDPanel : NSPanel
@end
@implementation HUDPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface BinkHUDController : NSObject <NSApplicationDelegate>
@property (weak) NSWindow *parentWindow;
@property (strong) HUDPanel *hudWindow;
@property (strong) NSVisualEffectView *hudView;
@property (strong) NSButton *playPauseBtn;
@property (strong) NSButton *muteBtn;
@property (strong) NSButton *loopBtn;
@property (strong) NSSlider *volumeSlider;
@property (assign) int32_t lastSeekTarget;
@property (assign) CFAbsoluteTime lastSeekTime;
@property (strong) NSSlider *scrubber;
@property (strong) NSTextField *timeLabel;
@property (strong) NSTimer *uiTimer;
@property (strong) NSTimer *hideTimer;
@property (assign) BOOL isDraggingScrubber;
@property (assign) BOOL hudVisible;
- (void)attachToWindow:(NSWindow *)win;
- (void)repositionHUD;
- (void)showHUD;
- (void)togglePlayPause;
- (void)toggleMute;
- (void)skipSeconds:(double)delta;
- (void)stepFrame;
- (void)toggleLoop;
- (void)toggleFullscreen;
- (void)switchToVideoPath:(NSString *)newPath;
- (void)openAnotherVideo;
- (void)requestQuit;
- (void)changeVolume:(float)delta;
- (void)requestSeek:(int32_t)frame exact:(int)exact;
@end

static BinkHUDController *g_hud = nil;

@implementation BinkHUDController

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *u in urls) {
        if (u.isFileURL) {
            [self switchToVideoPath:u.path];
            return;
        }
    }
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    if (filenames.count > 0) {
        [self switchToVideoPath:filenames.firstObject];
        [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
    }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    if (filename) {
        [self switchToVideoPath:filename];
        return YES;
    }
    return NO;
}

- (void)switchToVideoPath:(NSString *)newPath {
    if (!newPath) return;
    NSString *selfBin = [[NSProcessInfo processInfo] arguments].firstObject;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:selfBin];
    task.arguments = @[@"-m", @"-l", newPath];
    task.environment = [[NSProcessInfo processInfo] environment];
    [task launchAndReturnError:nil];
    [self requestQuit];
}

- (NSButton *)makeIconButton:(NSString *)symbol size:(CGFloat)ptSize action:(SEL)sel tooltip:(NSString *)tip {
    NSButton *btn = [[NSButton alloc] initWithFrame:NSZeroRect];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.bordered = NO;
    btn.bezelStyle = NSBezelStyleInline;
    btn.buttonType = NSButtonTypeMomentaryChange;
    btn.target = self;
    btn.action = sel;
    btn.toolTip = tip;
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:ptSize weight:NSFontWeightMedium];
    NSImage *img = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] imageWithSymbolConfiguration:cfg];
    btn.image = img;
    btn.contentTintColor = [NSColor whiteColor];
    [btn.widthAnchor constraintEqualToConstant:ptSize + 16].active = YES;
    [btn.heightAnchor constraintEqualToConstant:ptSize + 14].active = YES;
    return btn;
}

- (void)attachToWindow:(NSWindow *)win {
    if (self.hudWindow || !win) return;
    self.parentWindow = win;

    if (!NSApp.delegate) {
        NSApp.delegate = self;
    }

    win.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    win.acceptsMouseMovedEvents = YES;   // needed so moving the mouse brings the HUD back
    [self fitWindowToVideo:win];
    win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    if (g_videoPath) {
        win.title = g_videoPath.lastPathComponent;
    }

    NSRect hudRect = NSMakeRect(0, 0, 600, 76);
    HUDPanel *panel = [[HUDPanel alloc] initWithContentRect:hudRect
                                                  styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = YES;
    panel.ignoresMouseEvents = NO;
    panel.hidesOnDeactivate = NO;
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    self.hudWindow = panel;

    NSVisualEffectView *hud = [[NSVisualEffectView alloc] initWithFrame:hudRect];
    hud.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    hud.material = NSVisualEffectMaterialHUDWindow;
    hud.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    hud.state = NSVisualEffectStateActive;
    hud.wantsLayer = YES;
    hud.layer.cornerRadius = 14.0;
    hud.layer.masksToBounds = YES;
    hud.layer.borderWidth = 0.5;
    hud.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.22] CGColor];
    self.hudView = hud;
    panel.contentView = hud;

    self.scrubber = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.scrubber.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrubber.minValue = 1.0;
    self.scrubber.maxValue = 100.0;
    self.scrubber.doubleValue = 1.0;
    self.scrubber.continuous = YES;
    self.scrubber.target = self;
    self.scrubber.action = @selector(scrubberChanged:);

    self.timeLabel = [NSTextField labelWithString:@"00:00 / 00:00"];
    self.timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    self.timeLabel.textColor = [NSColor colorWithWhite:0.94 alpha:0.95];
    [self.timeLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *openBtn = [self makeIconButton:@"folder" size:15 action:@selector(openClicked:) tooltip:@"Open Another .bk2 (Cmd+O)"];
    NSButton *backBtn = [self makeIconButton:@"gobackward.5" size:16 action:@selector(skipBackClicked:) tooltip:@"Back 5s (Left Arrow)"];
    self.playPauseBtn = [self makeIconButton:@"pause.fill" size:20 action:@selector(playPauseClicked:) tooltip:@"Play / Pause (Space)"];
    NSButton *fwdBtn = [self makeIconButton:@"goforward.5" size:16 action:@selector(skipFwdClicked:) tooltip:@"Forward 5s (Right Arrow)"];
    NSButton *stepBtn = [self makeIconButton:@"forward.frame.fill" size:15 action:@selector(stepClicked:) tooltip:@"Step 1 Frame (.)"];
    self.muteBtn = [self makeIconButton:@"speaker.wave.2.fill" size:15 action:@selector(muteClicked:) tooltip:@"Mute / Unmute (M)"];
    self.loopBtn = [self makeIconButton:@"repeat" size:15 action:@selector(loopClicked:) tooltip:@"Loop (L)"];
    NSButton *fsBtn = [self makeIconButton:@"arrow.up.left.and.arrow.down.right" size:15 action:@selector(fullscreenClicked:) tooltip:@"Toggle Fullscreen (F)"];

    self.volumeSlider = [NSSlider sliderWithValue:g_volume minValue:0 maxValue:1 target:self action:@selector(volumeChanged:)];
    self.volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.volumeSlider.controlSize = NSControlSizeSmall;
    self.volumeSlider.toolTip = @"Volume (Up / Down Arrow)";
    [self.volumeSlider.widthAnchor constraintEqualToConstant:70].active = YES;

    NSStackView *btnRow = [NSStackView stackViewWithViews:@[openBtn, backBtn, self.playPauseBtn, fwdBtn, stepBtn, self.muteBtn, self.volumeSlider, self.loopBtn, fsBtn]];
    btnRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btnRow.spacing = 12;
    btnRow.alignment = NSLayoutAttributeCenterY;
    btnRow.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *scrubRow = [NSStackView stackViewWithViews:@[self.scrubber, self.timeLabel]];
    scrubRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    scrubRow.spacing = 10;
    scrubRow.alignment = NSLayoutAttributeCenterY;
    scrubRow.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *vbox = [NSStackView stackViewWithViews:@[scrubRow, btnRow]];
    vbox.orientation = NSUserInterfaceLayoutOrientationVertical;
    vbox.spacing = 6;
    vbox.alignment = NSLayoutAttributeCenterX;
    vbox.translatesAutoresizingMaskIntoConstraints = NO;

    [hud addSubview:vbox];
    [NSLayoutConstraint activateConstraints:@[
        [vbox.topAnchor constraintEqualToAnchor:hud.topAnchor constant:10],
        [vbox.bottomAnchor constraintEqualToAnchor:hud.bottomAnchor constant:-10],
        [vbox.leadingAnchor constraintEqualToAnchor:hud.leadingAnchor constant:16],
        [vbox.trailingAnchor constraintEqualToAnchor:hud.trailingAnchor constant:-16],
        [scrubRow.widthAnchor constraintEqualToAnchor:vbox.widthAnchor],
    ]];

    [win addChildWindow:panel ordered:NSWindowAbove];
    [self repositionHUD];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(repositionHUD) name:NSWindowDidResizeNotification object:win];
    [nc addObserver:self selector:@selector(repositionHUD) name:NSWindowDidMoveNotification object:win];
    [nc addObserver:self selector:@selector(repositionHUD) name:NSWindowDidEnterFullScreenNotification object:win];
    [nc addObserver:self selector:@selector(repositionHUD) name:NSWindowDidExitFullScreenNotification object:win];

    self.hudVisible = YES;
    [self syncUI];
    [self scheduleAutoHide];

    __weak typeof(self) weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved | NSEventMaskLeftMouseDown) handler:^NSEvent *(NSEvent *ev) {
        if (ev.window == weakSelf.parentWindow || ev.window == weakSelf.hudWindow) {
            [weakSelf showHUD];
        }
        return ev;
    }];

    self.uiTimer = [NSTimer scheduledTimerWithTimeInterval:0.066 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [weakSelf syncUI];
    }];
}

// The RAD player opens big videos at "whole screen" size whatever their shape, which leaves
// wide black bars (e.g. vertical 720x1280 clips). Size the window to the video's aspect,
// fitted inside the visible screen, centered, and keep that aspect while resizing.
- (void)fitWindowToVideo:(NSWindow *)win {
    BinkHeader *h = current_bink();
    if (!h || !h->Width || !h->Height || (win.styleMask & NSWindowStyleMaskFullScreen)) return;
    NSRect vis = (win.screen ?: NSScreen.mainScreen).visibleFrame;
    CGFloat titleH = win.frame.size.height - [win contentRectForFrameRect:win.frame].size.height;
    CGFloat maxW = vis.size.width, maxH = vis.size.height - titleH;
    CGFloat w = h->Width, hh = h->Height;
    CGFloat scale = MIN(1.0, MIN(maxW / w, maxH / hh));
    NSSize content = NSMakeSize(floor(w * scale), floor(hh * scale));
    win.contentAspectRatio = NSMakeSize(w, hh);
    CGFloat minW = MIN(content.width, 320.0);
    win.contentMinSize = NSMakeSize(minW, floor(minW * hh / MAX(w, 1.0)));
    NSRect frame = [win frameRectForContentRect:NSMakeRect(0, 0, content.width, content.height)];
    frame.origin.x = NSMidX(vis) - frame.size.width / 2;
    frame.origin.y = NSMidY(vis) - frame.size.height / 2;
    [win setFrame:frame display:YES];
}

- (void)repositionHUD {
    if (!self.parentWindow || !self.hudWindow) return;
    NSRect pf = [self.parentWindow contentRectForFrameRect:self.parentWindow.frame];
    CGFloat w = MIN(600.0, MAX(460.0, pf.size.width - 24.0));
    CGFloat h = 76.0;
    CGFloat x = pf.origin.x + (pf.size.width - w) * 0.5;
    CGFloat y = pf.origin.y + 22.0;
    [self.hudWindow setFrame:NSMakeRect(x, y, w, h) display:YES];
}

- (void)showHUD {
    if (!self.hudWindow) return;
    if (!self.hudVisible) {
        self.hudVisible = YES;
        self.hudWindow.ignoresMouseEvents = NO;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.18;
            self.hudWindow.animator.alphaValue = 1.0;
        }];
    }
    [self scheduleAutoHide];
}

- (void)scheduleAutoHide {
    [self.hideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:2.6 repeats:NO block:^(NSTimer * _Nonnull timer) {
        if (!weakSelf.hudWindow || !weakSelf.parentWindow) return;
        BOOL paused = (g_paused_ptr && *g_paused_ptr != 0);
        NSPoint mouse = [NSEvent mouseLocation];
        BOOL hoveringHud = NSPointInRect(mouse, weakSelf.hudWindow.frame);
        if (paused || hoveringHud || weakSelf.isDraggingScrubber) {
            [weakSelf scheduleAutoHide];
            return;
        }
        weakSelf.hudVisible = NO;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.35;
            weakSelf.hudWindow.animator.alphaValue = 0.0;
        }];
        weakSelf.hudWindow.ignoresMouseEvents = YES;  // invisible HUD must not eat clicks on the video
        if (weakSelf.parentWindow.styleMask & NSWindowStyleMaskFullScreen) [NSCursor setHiddenUntilMouseMoves:YES];
    }];
}

- (void)syncUI {
    BinkHeader *h = current_bink();
    if (!h) return;
    double fps = bink_fps(h);
    double curSec = (double)h->FrameNum / fps;
    double totSec = (double)h->Frames / fps;
    // If the mouse-up never reached the slider (e.g. released outside the HUD), finish the drag.
    if (self.isDraggingScrubber && [NSEvent pressedMouseButtons] == 0) {
        self.isDraggingScrubber = NO;
        [self requestSeek:(int32_t)self.scrubber.doubleValue exact:1];
    }
    BOOL seekJustRequested = (CFAbsoluteTimeGetCurrent() - self.lastSeekTime) < 0.25;
    if (!self.isDraggingScrubber && atomic_load(&g_pendingSeekFrame) == 0 && !seekJustRequested) {
        self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@", fmt_time(curSec), fmt_time(totSec)];
        if (h->Frames > 1) {
            self.scrubber.maxValue = (double)h->Frames;
            self.scrubber.doubleValue = (double)h->FrameNum;
        }
    } else if (self.isDraggingScrubber) {
        double previewSec = self.scrubber.doubleValue / fps;
        self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@", fmt_time(previewSec), fmt_time(totSec)];
    }

    BOOL paused = (g_paused_ptr && *g_paused_ptr != 0);
    NSString *sym = paused ? @"play.fill" : @"pause.fill";
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:20 weight:NSFontWeightMedium];
    self.playPauseBtn.image = [[NSImage imageWithSystemSymbolName:sym accessibilityDescription:sym] imageWithSymbolConfiguration:cfg];

    BOOL muted = (atomic_load(&g_muted) != 0);
    NSString *msym = muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill";
    NSImageSymbolConfiguration *mcfg = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightMedium];
    self.muteBtn.image = [[NSImage imageWithSystemSymbolName:msym accessibilityDescription:msym] imageWithSymbolConfiguration:mcfg];
    self.muteBtn.contentTintColor = muted ? [NSColor systemRedColor] : [NSColor whiteColor];

    BOOL looping = g_userLoop;
    self.loopBtn.contentTintColor = looping ? [NSColor systemBlueColor] : [NSColor colorWithWhite:0.75 alpha:0.85];

    if (g_videoPath && self.parentWindow && h->Width > 0 && h->Height > 0 && [self.parentWindow.title rangeOfString:@"×"].location == NSNotFound) {
        uint32_t openTracks = *(uint32_t *)((uint8_t *)h + 0x1cc);
        self.parentWindow.title = [NSString stringWithFormat:@"%@  (%u×%u • %u audio)", g_videoPath.lastPathComponent, h->Width, h->Height, openTracks];
    }
}

- (void)scrubberChanged:(NSSlider *)sender {
    NSEvent *ev = [NSApp currentEvent];
    int32_t target = (int32_t)sender.doubleValue;
    if (target < 1) target = 1;

    if (ev.type == NSEventTypeLeftMouseDown || ev.type == NSEventTypeLeftMouseDragged) {
        self.isDraggingScrubber = YES;
        BinkHeader *h = current_bink();
        if (h) {
            uint32_t kf = find_nearest_keyframe(h, (uint32_t)target);
            // Only do live keyframe preview if a keyframe is close (never jump back to 0:00 while dragging!)
            if ((uint32_t)target - kf <= 150 && (kf > 1 || target <= 90)) {
                [self requestSeek:target exact:0];
            }
        }
    } else {
        // Mouse released / click finished -> ALWAYS perform exact frame seek!
        self.isDraggingScrubber = NO;
        [self requestSeek:target exact:1];
    }
    [self showHUD];
}

- (void)requestSeek:(int32_t)frame exact:(int)exact {
    BinkHeader *h = current_bink();
    if (!h || h->Frames == 0) return;
    if (frame < 1) frame = 1;
    if (frame > (int32_t)h->Frames) frame = (int32_t)h->Frames;
    if (exact) {
        self.lastSeekTarget = frame;
        self.lastSeekTime = CFAbsoluteTimeGetCurrent();
        g_stoppedAtEnd = NO;
        self.scrubber.doubleValue = frame;
        double fps = bink_fps(h);
        self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@", fmt_time(frame / fps), fmt_time(h->Frames / fps)];
    }
    atomic_store(&g_pendingSeekExact, exact);
    atomic_store(&g_pendingSeekFrame, frame);
}

- (void)togglePlayPause {
    BinkHeader *h = current_bink();
    BOOL paused = (g_paused_ptr && *g_paused_ptr != 0);
    // QuickTime behaviour: pressing play on the last frame starts over from the beginning.
    if (paused && h && !g_userLoop && h->Frames > 1 && h->FrameNum >= h->Frames) {
        [self requestSeek:1 exact:1];
    }
    g_stoppedAtEnd = NO;
    atomic_store(&g_pendingTogglePause, 1);
    [self showHUD];
}
- (void)playPauseClicked:(id)sender { [self togglePlayPause]; }

- (void)toggleMute {
    // Pure queue-volume change now, so it is safe to apply right away on the main thread.
    atomic_store(&g_muted, atomic_load(&g_muted) ? 0 : 1);
    apply_volume();
    [self syncUI];
    [self showHUD];
}
- (void)muteClicked:(id)sender { [self toggleMute]; }

- (void)skipSeconds:(double)delta {
    BinkHeader *h = current_bink();
    if (!h) return;
    double fps = bink_fps(h);
    // Rapid presses stack: base on the last requested target if it hasn't settled yet
    // (before, pressing Right three times quickly only moved 5 s).
    int64_t base = (CFAbsoluteTimeGetCurrent() - self.lastSeekTime < 0.4 && self.lastSeekTarget > 0)
                   ? self.lastSeekTarget : (int64_t)h->FrameNum;
    int64_t target = base + (int64_t)llround(delta * fps);
    if (target < 1) target = 1;
    if (target > (int64_t)h->Frames) target = (int64_t)h->Frames;
    [self requestSeek:(int32_t)target exact:1];
    [self showHUD];
}
- (void)skipBackClicked:(id)sender { [self skipSeconds:-5.0]; }
- (void)skipFwdClicked:(id)sender { [self skipSeconds:5.0]; }

- (void)stepFrame {
    atomic_store(&g_pendingStepFrame, 1);
    [self showHUD];
}
- (void)stepClicked:(id)sender { [self stepFrame]; }

- (void)toggleLoop {
    g_userLoop = !g_userLoop;
    if (!getenv("BINKHUD_TEST") && !getenv("BINKHUD_EMBED")) [prefs() setBool:g_userLoop forKey:@"loop"];
    [self syncUI];
    [self showHUD];
}

- (void)changeVolume:(float)delta {
    pthread_mutex_lock(&g_qlock);
    g_volume = fminf(1.0f, fmaxf(0.0f, g_volume + delta));
    float vol = g_volume;
    pthread_mutex_unlock(&g_qlock);
    if (vol > 0 && atomic_load(&g_muted)) atomic_store(&g_muted, 0);
    if (!getenv("BINKHUD_TEST") && !getenv("BINKHUD_EMBED")) [prefs() setFloat:vol forKey:@"volume"];
    self.volumeSlider.doubleValue = vol;
    apply_volume();
    [self syncUI];
    [self showHUD];
}
- (void)volumeChanged:(NSSlider *)sender {
    [self changeVolume:(float)sender.doubleValue - g_volume];
}
- (void)loopClicked:(id)sender { [self toggleLoop]; }

- (void)toggleFullscreen {
    if (self.parentWindow) [self.parentWindow toggleFullScreen:nil];
}
- (void)fullscreenClicked:(id)sender { [self toggleFullscreen]; }

- (void)openAnotherVideo {
    BOOL wasPlaying = (g_paused_ptr && *g_paused_ptr == 0);
    if (wasPlaying) [self togglePlayPause];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"bk2", @"bik"];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if (g_videoPath) {
        panel.directoryURL = [NSURL fileURLWithPath:[g_videoPath stringByDeletingLastPathComponent]];
    }
    [panel beginSheetModalForWindow:self.parentWindow completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [self switchToVideoPath:panel.URL.path];
        } else if (wasPlaying) {
            [self togglePlayPause];
        }
    }];
}
- (void)openClicked:(id)sender { [self openAnotherVideo]; }

- (void)requestQuit {
    atomic_store(&g_pendingQuit, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

@end

#include "test_ctl.inc"

static BOOL (*orig_setActivationPolicy)(NSApplication *, SEL, NSApplicationActivationPolicy);

static BOOL background_setActivationPolicy(NSApplication *app, SEL cmd, NSApplicationActivationPolicy policy) {
    if (policy == NSApplicationActivationPolicyRegular) policy = NSApplicationActivationPolicyAccessory;
    return orig_setActivationPolicy(app, cmd, policy);
}

static void prevent_regular_activation(void) {
    if (orig_setActivationPolicy) return;
    // RAD sets Regular during startup, before our queued background policy takes effect.
    Method m = class_getInstanceMethod([NSApplication class], @selector(setActivationPolicy:));
    orig_setActivationPolicy = (void *)method_setImplementation(m, (IMP)background_setActivationPolicy);
}

#include "embed.inc"

static IMP orig_initFromShaders = NULL;
static id swizzled_initFromShaders(id self, SEL _cmd, id shaders, void *bink, void *userPtr) {
    if (bink) g_bink_captured = (BinkHeader *)bink;
    return ((id (*)(id, SEL, id, void *, void *))orig_initFromShaders)(self, _cmd, shaders, bink, userPtr);
}

static IMP orig_drawInMTKView = NULL;
static void swizzled_drawInMTKView(id self, SEL _cmd, MTKView *view) {
    if (g_embed) embed_prepare_view(view);
    else if (!g_hud.hudWindow && view.window) {
        NSWindow *w = view.window;
        dispatch_async(dispatch_get_main_queue(), ^{
            [g_hud attachToWindow:w];
        });
    }

    if (atomic_exchange(&g_pendingQuit, 0)) {
        if (g_input_flags_ptr) *g_input_flags_ptr |= 0x1;
    }
    if (atomic_exchange(&g_pendingTogglePause, 0)) {
        if (g_input_flags_ptr) *g_input_flags_ptr |= 0x2;
    }
    if (atomic_exchange(&g_pendingStepFrame, 0)) {
        if (g_paused_ptr && *g_paused_ptr == 0 && g_input_flags_ptr) {
            *g_input_flags_ptr |= 0x2;
        } else if (g_input_flags_ptr) {
            *g_input_flags_ptr |= 0x4;
        }
    }
    if (atomic_exchange(&g_pendingToggleMute, 0)) {
        atomic_store(&g_muted, atomic_load(&g_muted) ? 0 : 1);
        apply_volume();
    }

    if (g_loop_ptr) *g_loop_ptr = 1;   // RAD's own loop stays on; g_userLoop decides what happens at the end
    // Stop on the last frame instead of wrapping (or quitting) when the user has loop off.
    BinkHeader *eh = current_bink();
    if (eh && eh->Frames > 1 && g_paused_ptr && g_input_flags_ptr && atomic_load(&g_pendingSeekFrame) == 0) {
        BOOL willBePaused = (*g_paused_ptr != 0) ^ ((*g_input_flags_ptr & 0x2) != 0);
        if (!g_userLoop && !willBePaused && !g_stoppedAtEnd) {
            if (eh->FrameNum >= eh->Frames) {
                // Final frame was decoded asynchronously on the previous tick; wait for it and
                // mark textures dirty so orig_drawInMTKView uploads and displays it while paused.
                if (fn_BinkDoFrameAsyncWait) {
                    while (!fn_BinkDoFrameAsyncWait(eh, 100000)) {}
                }
                void *tex = g_tex_ptr ? *g_tex_ptr : NULL;
                TexUpdateFn finishTex = tex ? *(TexUpdateFn *)((uint8_t *)tex + 8) : NULL;
                if (finishTex) finishTex(tex);
                g_stoppedAtEnd = YES;
                *g_input_flags_ptr |= 0x2;          // pause right here, on the final frame
            } else if (eh->FrameNum < g_lastSeenFrame && g_lastSeenFrame + 5 >= eh->Frames && eh->FrameNum < 5) {
                // Wrapped before we caught it: seek back to the last frame, upload it, and pause.
                perform_clean_seek(eh, eh->Frames, 1);
            }
        }
        g_lastSeenFrame = eh->FrameNum;
    }

    int32_t seekTarget = atomic_exchange(&g_pendingSeekFrame, 0);
    if (seekTarget > 0) {
        int exact = atomic_load(&g_pendingSeekExact);
        BinkHeader *bnk = current_bink();
        if (bnk) {
            double t0 = now_ms();
            uint32_t before = bnk->FrameNum;
            perform_clean_seek(bnk, (uint32_t)seekTarget, exact);
            hudlog([NSString stringWithFormat:@"seek target=%d exact=%d from=%u landed=%u ms=%.1f", seekTarget, exact, before, bnk->FrameNum, now_ms()-t0]);
        }
    }

    atomic_store(&g_in_draw, 1);
    ((void (*)(id, SEL, MTKView *))orig_drawInMTKView)(self, _cmd, view);
    atomic_store(&g_in_draw, 0);
}

static void swizzled_mouseDown(id self, SEL _cmd, NSEvent *ev) {
    if (ev.clickCount == 2) {
        [g_hud togglePlayPause];   // undo the single-click toggle from the first click
        [g_hud toggleFullscreen];
    } else if (ev.clickCount == 1) {
        [g_hud togglePlayPause];
    }
}

static void swizzled_keyDown(id self, SEL _cmd, NSEvent *ev) {
    unsigned short kc = ev.keyCode;
    NSEventModifierFlags mods = ev.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *chars = ev.charactersIgnoringModifiers.lowercaseString;

    if ((mods & NSEventModifierFlagCommand) && ([chars isEqualToString:@"q"] || [chars isEqualToString:@"w"])) {
        [g_hud requestQuit]; return;
    }
    if ((mods & NSEventModifierFlagCommand) && [chars isEqualToString:@"o"]) {
        [g_hud openAnotherVideo]; return;
    }
    if (kc == 49) { [g_hud togglePlayPause]; return; }
    if (kc == 123) { [g_hud skipSeconds:-5.0]; return; }
    if (kc == 124) { [g_hud skipSeconds:5.0]; return; }
    if (kc == 36 || kc == 47) { [g_hud stepFrame]; return; }
    if (kc == 126) { [g_hud changeVolume:+0.1f]; return; }
    if (kc == 125) { [g_hud changeVolume:-0.1f]; return; }
    NSEventModifierFlags cmdCtrlOpt = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
    if (!(mods & cmdCtrlOpt)) {
        if ([chars isEqualToString:@"m"]) { [g_hud toggleMute]; return; }
        if ([chars isEqualToString:@"f"]) { [g_hud toggleFullscreen]; return; }
        if ([chars isEqualToString:@"l"]) { [g_hud toggleLoop]; return; }
        if ([chars isEqualToString:@"q"]) { [g_hud requestQuit]; return; }
    }
    if (kc == 53) {
        if (g_hud.parentWindow && (g_hud.parentWindow.styleMask & NSWindowStyleMaskFullScreen)) {
            [g_hud toggleFullscreen];
        }
        return;
    }
}

__attribute__((constructor))
static void bink_hud_init(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (hdr && hdr->filetype == MH_EXECUTE) {
            g_base = (uintptr_t)hdr;
            break;
        }
    }
    if (!g_base) return;

    g_bink_ptr        = (BinkHeader **)(g_base + 0x56f50);
    g_tex_ptr         = (void **)(g_base + 0x56f60);
    g_threads_ptr     = (uint32_t *)(g_base + 0x56f28);
    g_num_threads_ptr = (int32_t *)(g_base + 0x56f48);
    g_paused_ptr      = (int32_t *)(g_base + 0x57068);
    g_loop_ptr        = (uint8_t *)(g_base + 0x56f10);
    g_input_flags_ptr = (uint32_t *)(g_base + 0x57168);

    fn_BinkPause            = (BinkPauseFn)(g_base + 0x758c);
    fn_BinkGoto             = (BinkGotoFn)(g_base + 0x6ea8);
    fn_BinkSetSoundOnOff    = (BinkSetSoundOnOffFn)(g_base + 0x6ce0);
    fn_BinkDoFrameAsyncWait = (BinkDoFrameAsyncWaitFn)(g_base + 0x842c);
    fn_BinkDoFrameAsyncMulti= (BinkDoFrameAsyncMultiFn)(g_base + 0x81c4);

    for (NSString *arg in [[NSProcessInfo processInfo] arguments]) {
        if ([arg.lowercaseString hasSuffix:@".bk2"] || [arg.lowercaseString hasSuffix:@".bik"]) {
            g_videoPath = arg;
            configure_all_audio_tracks(arg.fileSystemRepresentation);
        }
    }

    // Test mode (tests/drive.py): silent from the first audio buffer, never takes focus,
    // window stays behind everything. Prefs are not touched in test or embed mode.
    BOOL isTest = getenv("BINKHUD_TEST") != NULL;
    BOOL isEmbed = getenv("BINKHUD_EMBED") != NULL;
    if (isTest) {
        prevent_regular_activation();
        g_volume = 0.0f;
        Class appCls = [NSApplication class];
        IMP noop = imp_implementationWithBlock(^(id _self, BOOL flag) {});
        Method am = class_getInstanceMethod(appCls, @selector(activateIgnoringOtherApps:));
        if (am) method_setImplementation(am, noop);
        Method am2 = class_getInstanceMethod(appCls, @selector(activate));
        if (am2) method_setImplementation(am2, imp_implementationWithBlock(^(id _self) {}));
        Method mk = class_getInstanceMethod([NSWindow class], @selector(makeKeyAndOrderFront:));
        if (mk) method_setImplementation(mk, imp_implementationWithBlock(^(NSWindow *w, id sender) { [w orderBack:nil]; }));
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; });
    } else if (!isEmbed) {
        if ([prefs() objectForKey:@"volume"]) g_volume = fminf(1.0f, fmaxf(0.0f, [prefs() floatForKey:@"volume"]));
        g_userLoop = [prefs() boolForKey:@"loop"];
    }
    if (getenv("BINKHUD_LOOP")) g_userLoop = atoi(getenv("BINKHUD_LOOP")) != 0;   // tests
    if (g_loop_ptr) *g_loop_ptr = 1;
    embed_init();   // after prefs so BINKHUD_VOLUME wins

    g_hud = [[BinkHUDController alloc] init];
    start_test_ctl();

    Class texCls = objc_getClass("BinkTexMtlTextures");
    if (texCls) {
        Method mt = class_getInstanceMethod(texCls, @selector(initFromShaders:bink:userPtr:));
        if (mt) orig_initFromShaders = method_setImplementation(mt, (IMP)swizzled_initFromShaders);
    }
    Class delCls = objc_getClass("MetalViewDelegate");
    if (delCls) {
        Method m = class_getInstanceMethod(delCls, @selector(drawInMTKView:));
        if (m) orig_drawInMTKView = method_setImplementation(m, (IMP)swizzled_drawInMTKView);
    }
    Class mvCls = objc_getClass("MetalView");
    if (mvCls) {
        Method md = class_getInstanceMethod(mvCls, @selector(mouseDown:));
        if (md) method_setImplementation(md, (IMP)swizzled_mouseDown);
        Method kd = class_getInstanceMethod(mvCls, @selector(keyDown:));
        if (kd) method_setImplementation(kd, (IMP)swizzled_keyDown);
    }
}
