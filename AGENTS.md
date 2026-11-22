# Bink Player

macOS player for RAD Bink 2 (`.bk2`) videos: RAD's `BinkMacArmPlayer` (patched, from the official Mac SDK test player) plus an injected `libBinkHUD.dylib` that adds a QuickTime-style HUD. Installed at `/Applications/Bink Player.app`, default handler for `.bk2`/`.bik`.

## Rules
- Source of truth is `src/`. Never edit the dylib in `/Applications` from a heredoc in `/tmp` (the old workflow lost the source after every build).
- Build: `./build.sh` downloads RAD's player, verifies its SHA-256, patches it and builds `build/Bink Player.app`. Install: `./install.sh` (swaps files via temp name + `mv`, never overwrite a running binary in place).
- Never commit RAD's binary, game files, or .bk2 videos. The repo is public and only contains our code.
- Test with `tests/drive.py <file.bk2> "cmd;sleep;cmd"` (commands: `seek <s>`, `skip <s>`, `pause`, `mute`, `vol <0-1>`, `loop <0|1>`, `state`, `win`). It runs in test mode: silent, never takes focus, window stays behind. Never test by launching the real app or `open`-ing files: that plays sound and steals focus while someone is using the Mac. `tests/shot.sh` screenshots a test window in the background.
- The launcher kills every running `BinkMacArmPlayer` on open, so don't run it in tests.
- Always launch the player with `-l`: without it RAD's player quits at the end of the file. User-facing looping is `g_userLoop` in the dylib.
- Never use `BinkSetSoundOnOff(0)` for mute: Bink's clock follows the audio track and the video freezes. Volume/mute go through the interposed AudioQueue (`apply_volume`).

## Hardcoded binary offsets
All addresses in `bink_hud_init` (globals at `0x56f..`, functions `BinkGoto 0x6ea8`, etc.) and the `BINKSNDTRACK` patch at file offset `0xe44c` only match the RAD build pinned by hash in `build.sh`. Don't swap the RAD binary without re-deriving them.

## Embed mode (`src/embed.inc`)
- `BINKHUD_EMBED=<file>` makes the player a headless decoder for another app (PercyStar's preview panel): invisible click-through window, no HUD, no focus, audio on. Frame/status/command layout is documented at the top of `embed.inc`; PercyStar's `src/bink_embed.rs` is the host side, so change both together.
- Frames are copied by a blit encoded into the player's own command buffer (hooked `presentDrawable:`), so never read the drawable from a separate queue.
- Test it silently with `BINKHUD_VOLUME=0`.


## tools/bk2mp4.sh
- Standalone converter, independent of the player: builds upstream librempeg at the pinned `COMMIT` (master, after #217 merged) into `~/Library/Caches/bink-player-mac` and pipes NUT into Homebrew ffmpeg. Bump `COMMIT` for upstream Bink 2 fixes; the cache dir is keyed on it.
