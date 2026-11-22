// ---- Embed mode (inert unless BINKHUD_EMBED is set) ----
//
// Lets another app show the video inside its own UI (PercyStar's preview panel) instead of
// in our window. The host creates a file, passes its path in BINKHUD_EMBED and maps/reads it:
//
//   0x00 u32 magic 'KBEM'      0x04 u32 version (1)
//   0x08 u64 seq               frames published so far; latest frame is in slot (seq & 1)
//   0x10 u32 width, height, stride (bytes per row), pixfmt (MTLPixelFormat, BGRA8 = 80)
//   0x20 u32 frame (1-based), frames, fps_num, fps_den
//   0x30 u32 paused, muted; f32 volume; u32 pid
//   0x40 u32 cmd_seq, cmd; f64 arg      <- written by the host, cmd_seq last
//   0x50 u32 loop
//   0x80 slot 0, then slot 1 (stride * height bytes each)
//
// Commands: 1 toggle pause, 2 seek to arg seconds, 3 volume = arg (0..1), 4 toggle mute,
// 5 loop = arg != 0, 6 quit.
//
// The player window stays fully transparent, click-through and behind everything, never takes
// focus and has no HUD. Frames are rendered at the video's native size and copied out with a
// blit encoded into the player's own command buffer, so the copy always sees the finished
// frame. Audio still plays from this process (volume via the interposed AudioQueues).

#import <sys/mman.h>
#import <fcntl.h>
#import <unistd.h>

#define EMBED_MAGIC 0x4D45424Bu   // "KBEM" little-endian
#define EMBED_HDR   0x80

typedef struct {
    uint32_t magic, version;
    _Atomic uint64_t seq;
    uint32_t width, height, stride, pixfmt;
    uint32_t frame, frames, fps_num, fps_den;
    uint32_t paused, muted;
    float volume;
    uint32_t pid;
    uint32_t cmd_seq, cmd;
    double arg;
    uint32_t loop;
} EmbedHdr;
_Static_assert(sizeof(EmbedHdr) <= EMBED_HDR, "embed header too big");

static BOOL g_embed = NO;
static int g_embed_fd = -1;
static uint8_t *g_embed_map = NULL;
static size_t g_embed_len = 0;
static uint32_t g_embed_last_cmd = 0;
static uint32_t g_embed_last_frame = UINT32_MAX;
static int g_embed_idle_draws = 0;
static _Atomic int g_in_draw = 0;
static id<MTLBuffer> g_embed_buf = nil;
static IMP orig_presentDrawable = NULL;

static EmbedHdr *embed_hdr(void) { return (EmbedHdr *)g_embed_map; }

// (Re)size the shared file for width x height frames. Host notices via a changed size.
static BOOL embed_map(uint32_t w, uint32_t h, uint32_t stride, uint32_t pixfmt) {
    size_t need = EMBED_HDR + 2 * (size_t)stride * h;
    EmbedHdr *cur = embed_hdr();
    if (cur && g_embed_len == need && cur->width == w && cur->height == h) return YES;
    if (g_embed_map) { munmap(g_embed_map, g_embed_len); g_embed_map = NULL; }
    if (ftruncate(g_embed_fd, (off_t)need) != 0) return NO;
    void *m = mmap(NULL, need, PROT_READ | PROT_WRITE, MAP_SHARED, g_embed_fd, 0);
    if (m == MAP_FAILED) return NO;
    g_embed_map = m;
    g_embed_len = need;
    EmbedHdr *e = embed_hdr();
    // keep any command the host already queued; reset the rest
    e->magic = EMBED_MAGIC;
    e->version = 1;
    e->width = w; e->height = h; e->stride = stride; e->pixfmt = pixfmt;
    e->pid = (uint32_t)getpid();
    return YES;
}

static void embed_publish_status(void) {
    EmbedHdr *e = embed_hdr();
    BinkHeader *h = current_bink();
    if (!e || !h) return;
    e->frame = h->FrameNum;
    e->frames = h->Frames;
    e->fps_num = h->FrameRate;
    e->fps_den = h->FrameRateDiv;
    e->paused = (g_paused_ptr && *g_paused_ptr != 0) ? 1 : 0;
    e->muted = (uint32_t)atomic_load(&g_muted);
    e->volume = g_volume;
    e->loop = g_userLoop ? 1 : 0;
}

static void embed_poll_commands(void) {
    EmbedHdr *e = embed_hdr();
    if (!e) return;
    uint32_t s = e->cmd_seq;
    if (s == g_embed_last_cmd) return;
    g_embed_last_cmd = s;
    uint32_t cmd = e->cmd;
    double arg = e->arg;
    dispatch_async(dispatch_get_main_queue(), ^{
        BinkHeader *h = current_bink();
        switch (cmd) {
            case 1: [g_hud togglePlayPause]; break;
            case 2:
                if (h) {
                    atomic_store(&g_pendingSeekExact, 1);
                    atomic_store(&g_pendingSeekFrame, (int32_t)MAX(1.0, arg * bink_fps(h)));
                    g_stoppedAtEnd = NO;
                }
                break;
            case 3: g_volume = fminf(1.0f, fmaxf(0.0f, (float)arg)); apply_volume(); break;
            case 4: atomic_store(&g_muted, atomic_load(&g_muted) ? 0 : 1); apply_volume(); break;
            case 5: g_userLoop = arg != 0; break;
            case 6: [g_hud requestQuit]; break;
        }
    });
}

// Encodes texture -> shared buffer into the player's command buffer; copies to the file on completion.
static void embed_capture(id<MTLCommandBuffer> cb, id<MTLTexture> tex) {
    uint32_t w = (uint32_t)tex.width, h = (uint32_t)tex.height, stride = w * 4;
    if (w == 0 || h == 0 || w > 8192 || h > 8192) return;
    if (!embed_map(w, h, stride, (uint32_t)tex.pixelFormat)) return;
    size_t bytes = (size_t)stride * h;
    if (!g_embed_buf || g_embed_buf.length != bytes) {
        g_embed_buf = [cb.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        if (!g_embed_buf) return;
    }
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1) toBuffer:g_embed_buf destinationOffset:0
   destinationBytesPerRow:stride destinationBytesPerImage:bytes];
    [blit endEncoding];
    id<MTLBuffer> buf = g_embed_buf;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        EmbedHdr *e = embed_hdr();
        if (!e || e->width != w || e->height != h) return;
        uint64_t next = atomic_load(&e->seq) + 1;
        memcpy(g_embed_map + EMBED_HDR + (next & 1) * bytes, buf.contents, bytes);
        atomic_store(&e->seq, next);
    }];
}

static void hk_presentDrawable(id self, SEL _cmd, id<MTLDrawable> d) {
    if (g_embed && atomic_load(&g_in_draw) && [d conformsToProtocol:@protocol(CAMetalDrawable)]) {
        BinkHeader *h = current_bink();
        uint32_t fn = h ? h->FrameNum : 0;
        // copy on new frames, and now and then while paused so seeks/first frame always land
        if (fn != g_embed_last_frame || ++g_embed_idle_draws >= 15) {
            g_embed_last_frame = fn;
            g_embed_idle_draws = 0;
            embed_capture((id<MTLCommandBuffer>)self, ((id<CAMetalDrawable>)d).texture);
        }
    }
    ((void (*)(id, SEL, id))orig_presentDrawable)(self, _cmd, d);
}

// Called from the draw hook every frame while embedded.
static void embed_prepare_view(MTKView *view) {
    static BOOL hooked = NO;
    if (!hooked && view.device) {
        hooked = YES;
        id<MTLCommandQueue> q = [view.device newCommandQueue];
        Class cbCls = object_getClass([q commandBuffer]);
        Method m = class_getInstanceMethod(cbCls, @selector(presentDrawable:));
        if (m) orig_presentDrawable = method_setImplementation(m, (IMP)hk_presentDrawable);
    }
    BinkHeader *h = current_bink();
    if (h && h->Width && h->Height) {
        CGSize native = CGSizeMake(h->Width, h->Height);
        view.framebufferOnly = NO;
        view.autoResizeDrawable = NO;
        if (!CGSizeEqualToSize(view.drawableSize, native)) view.drawableSize = native;
    }
    NSWindow *w = view.window;
    if (w && w.alphaValue != 0.0) {
        w.alphaValue = 0.0;
        w.ignoresMouseEvents = YES;
        w.hasShadow = NO;
        w.excludedFromWindowsMenu = YES;
        w.collectionBehavior |= NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorTransient;
        [w orderBack:nil];
    }
    embed_poll_commands();
    embed_publish_status();
}

// From bink_hud_init: no focus, no Dock icon, no prefs; audio stays on.
static void embed_init(void) {
    const char *p = getenv("BINKHUD_EMBED");
    if (!p) return;
    g_embed_fd = open(p, O_RDWR);
    if (g_embed_fd < 0) return;
    g_embed = YES;
    prevent_regular_activation();
    if (getenv("BINKHUD_VOLUME")) g_volume = fminf(1.0f, fmaxf(0.0f, (float)atof(getenv("BINKHUD_VOLUME"))));
    Class appCls = [NSApplication class];
    Method am = class_getInstanceMethod(appCls, @selector(activateIgnoringOtherApps:));
    if (am) method_setImplementation(am, imp_implementationWithBlock(^(id _self, BOOL flag) {}));
    Method am2 = class_getInstanceMethod(appCls, @selector(activate));
    if (am2) method_setImplementation(am2, imp_implementationWithBlock(^(id _self) {}));
    Method mk = class_getInstanceMethod([NSWindow class], @selector(makeKeyAndOrderFront:));
    if (mk) method_setImplementation(mk, imp_implementationWithBlock(^(NSWindow *w, id sender) { w.alphaValue = 0.0; [w orderBack:nil]; }));
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited]; });
}
