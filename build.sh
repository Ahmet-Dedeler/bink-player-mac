#!/bin/zsh
# Build "Bink Player.app" into ./build.
#
# RAD's player binary is NOT part of this repo. This script downloads RAD Game Tools'
# free "Bink Video Player for macOS (Apple Silicon)" from radgametools.com, checks its
# SHA-256 (all offsets in src/libBinkHUD.m match exactly this build), applies a 4-byte
# patch, and wraps it with the HUD dylib and a small launcher.
set -euo pipefail
cd "${0:A:h}"

DMG_URL="https://www.radgametools.com/down/Bink/BinkMacArmPlayer.dmg"
RAD_BIN_SHA256="a9496ed44219b2a061cf542bd7c4d565f29d117c8cbe143c85e8901d7b295966"
APP="build/Bink Player.app"
CACHE="build/cache"
mkdir -p "$CACHE"

# 1. Fetch + verify RAD's player
if [[ ! -f "$CACHE/BinkMacArmPlayer" ]] || [[ "$(shasum -a 256 "$CACHE/BinkMacArmPlayer" | cut -d' ' -f1)" != "$RAD_BIN_SHA256" ]]; then
  echo "Downloading RAD Bink Video Player for macOS (Apple Silicon)..."
  curl -fsSL -o "$CACHE/BinkMacArmPlayer.dmg" "$DMG_URL"
  MNT="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$CACHE/BinkMacArmPlayer.dmg" >/dev/null 2>&1
  cp "$MNT/BinkMacArmPlayer.app/Contents/MacOS/BinkMacArmPlayer" "$CACHE/BinkMacArmPlayer"
  cp "$MNT/BinkMacArmPlayer.app/Contents/Resources/BinkMacArmPlayer.icns" "$CACHE/BinkPlayer.icns" 2>/dev/null || true
  hdiutil detach "$MNT" -quiet
  rm -f "$CACHE/BinkMacArmPlayer.dmg"
fi
GOT="$(shasum -a 256 "$CACHE/BinkMacArmPlayer" | cut -d' ' -f1)"
if [[ "$GOT" != "$RAD_BIN_SHA256" ]]; then
  echo "error: RAD's player changed (sha256 $GOT)." >&2
  echo "The hardcoded offsets in src/libBinkHUD.m only fit the known build; they need re-deriving." >&2
  exit 1
fi

# 2. Assemble bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp resources/Info.plist "$APP/Contents/Info.plist"
[[ -f "$CACHE/BinkPlayer.icns" ]] && cp "$CACHE/BinkPlayer.icns" "$APP/Contents/Resources/BinkPlayer.icns"
cp "$CACHE/BinkMacArmPlayer" "$APP/Contents/MacOS/BinkMacArmPlayer"

# 3. Patch: BinkOpen flags 0x400 -> 0x4400 (adds BINKSNDTRACK) so we can open audio
#    tracks whose IDs aren't 0. Without it many game videos play silently.
python3 - "$APP/Contents/MacOS/BinkMacArmPlayer" <<'PY'
import struct, sys
p = sys.argv[1]; b = bytearray(open(p, "rb").read())
OFF, ORIG, NEW = 0xE44C, 0x52808009, 0x52888009   # mov w9,#0x400 -> mov w9,#0x4400
cur = struct.unpack_from("<I", b, OFF)[0]
assert cur == ORIG, f"unexpected instruction {cur:#x} at {OFF:#x}"
struct.pack_into("<I", b, OFF, NEW)
open(p, "wb").write(b)
PY

# 4. Compile our code
CFLAGS=(-arch arm64 -fobjc-arc -O2 -Wall -Wno-deprecated-declarations -mmacosx-version-min=12.0)
clang "${CFLAGS[@]}" -shared -Isrc -framework Cocoa -framework MetalKit -framework QuartzCore -framework AudioToolbox \
  src/libBinkHUD.m -o "$APP/Contents/MacOS/libBinkHUD.dylib"
clang "${CFLAGS[@]}" -framework Cocoa src/BinkPlayerLauncher.m -o "$APP/Contents/MacOS/BinkPlayerLauncher"
clang "${CFLAGS[@]}" -framework Cocoa -framework CoreServices -framework UniformTypeIdentifiers \
  src/set_default_handler.m -o build/set_default_handler

# 5. Ad-hoc sign (no hardened runtime: the launcher injects the dylib via DYLD_INSERT_LIBRARIES)
xattr -cr "$APP"
for f in libBinkHUD.dylib BinkMacArmPlayer BinkPlayerLauncher; do
  codesign --force --sign - "$APP/Contents/MacOS/$f" 2>/dev/null
done
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $APP"
