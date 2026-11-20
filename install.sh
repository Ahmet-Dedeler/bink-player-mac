#!/bin/zsh
# Build (if needed), install to /Applications and make Bink Player the default app for .bk2/.bik.
set -euo pipefail
cd "${0:A:h}"
[[ -d "build/Bink Player.app" ]] || ./build.sh
DST="/Applications/Bink Player.app"
if [[ -d "$DST" ]]; then
  # Swap files atomically so a player that's currently open keeps running.
  for f in BinkMacArmPlayer libBinkHUD.dylib BinkPlayerLauncher; do
    cp "build/Bink Player.app/Contents/MacOS/$f" "$DST/Contents/MacOS/.$f.new"
    mv -f "$DST/Contents/MacOS/.$f.new" "$DST/Contents/MacOS/$f"
  done
  cp "build/Bink Player.app/Contents/Info.plist" "$DST/Contents/Info.plist"
  mkdir -p "$DST/Contents/Resources"
  cp -R "build/Bink Player.app/Contents/Resources/." "$DST/Contents/Resources/"
  codesign --force --sign - "$DST" 2>/dev/null
else
  cp -R "build/Bink Player.app" "$DST"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST"
build/set_default_handler 2>/dev/null || true
echo "Installed $DST. Double-click any .bk2 or .bik file to play it."
