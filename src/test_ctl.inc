// ---- Test/diagnostic control channel (inert unless BINKHUD_CTL is set) ----
// BINKHUD_CTL=<fifo path>  : newline commands: seek <sec> | skip <sec> | pause | loop <0|1> | mute | quit | state | key <keycode>
// BINKHUD_LOG=<file path>  : JSON lines with state + timings
static FILE *g_logf = NULL;
static double now_ms(void) { return [[NSDate date] timeIntervalSince1970] * 1000.0; }
static void hudlog(NSString *s) {
    if (!g_logf) return;
    fprintf(g_logf, "%.1f %s\n", now_ms(), s.UTF8String); fflush(g_logf);
}
static void log_state(NSString *tag) {
    BinkHeader *h = current_bink();
    if (!h) { hudlog([NSString stringWithFormat:@"%@ nobink", tag]); return; }
    hudlog([NSString stringWithFormat:@"%@ frame=%u/%u paused=%d loop=%d muted=%d queues=%d vol=%.2f", tag, h->FrameNum, h->Frames,
            g_paused_ptr ? *g_paused_ptr : -1, (int)g_userLoop, (int)atomic_load(&g_muted), g_numQueues, g_volume]);
}
static void start_test_ctl(void) {
    const char *logp = getenv("BINKHUD_LOG");
    if (logp) g_logf = fopen(logp, "a");
    const char *ctl = getenv("BINKHUD_CTL");
    if (!ctl) return;
    NSString *ctlPath = [NSString stringWithUTF8String:ctl];
    [NSThread detachNewThreadWithBlock:^{
        while (1) {
            FILE *f = fopen(ctlPath.fileSystemRepresentation, "r");
            if (!f) { usleep(200000); continue; }
            char line[256];
            while (fgets(line, sizeof line, f)) {
                NSString *cmd = [[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (!cmd || cmd.length == 0) continue;
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSArray *p = [cmd componentsSeparatedByString:@" "];
                    NSString *c = p.firstObject; double v = p.count > 1 ? [p[1] doubleValue] : 0;
                    hudlog([@"cmd " stringByAppendingString:cmd]);
                    BinkHeader *h = current_bink();
                    if ([c isEqualToString:@"state"]) log_state(@"state");
                    else if ([c isEqualToString:@"win"]) {
                        NSWindow *w = g_hud.parentWindow;
                        hudlog([NSString stringWithFormat:@"win frame=%@ screen=%@ visible=%@ hud=%@ hudAlpha=%.2f fs=%d wid=%ld title=%@", NSStringFromRect(w.frame), NSStringFromRect(w.screen.frame), NSStringFromRect(w.screen.visibleFrame), NSStringFromRect(g_hud.hudWindow.frame), g_hud.hudWindow.alphaValue, (int)((w.styleMask & NSWindowStyleMaskFullScreen) != 0), (long)w.windowNumber, w.title]);
                    }
                    else if ([c isEqualToString:@"skip"]) [g_hud skipSeconds:v];
                    else if ([c isEqualToString:@"seek"] && h && h->Frames > 0) {
                        double target = isfinite(v) ? fmin((double)h->Frames, fmax(1.0, v * bink_fps(h))) : 1.0;
                        [g_hud requestSeek:(int32_t)target exact:1];
                    }
                    else if ([c isEqualToString:@"pause"]) [g_hud togglePlayPause];
                    else if ([c isEqualToString:@"loop"]) { if (g_userLoop != (v != 0)) [g_hud toggleLoop]; }
                    else if ([c isEqualToString:@"mute"]) [g_hud toggleMute];
                    else if ([c isEqualToString:@"vol"]) [g_hud changeVolume:(float)v - g_volume];
                    else if ([c isEqualToString:@"quit"]) [g_hud requestQuit];
                    else if ([c isEqualToString:@"key"]) {
                        NSEvent *ev = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:g_hud.parentWindow.windowNumber context:nil characters:(p.count > 2 ? p[2] : @"") charactersIgnoringModifiers:(p.count > 2 ? p[2] : @"") isARepeat:NO keyCode:(unsigned short)v];
                        NSView *mv = g_hud.parentWindow.contentView;
                        [mv keyDown:ev];
                    }
                });
            }
            fclose(f);
        }
    }];
}
