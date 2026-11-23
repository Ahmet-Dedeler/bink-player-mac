#!/bin/zsh
# Build, install to /Applications and make Bink Player the default app for .bk2/.bik.
set -euo pipefail
cd "${0:A:h}"
./build.sh
DST="/Applications/Bink Player.app"
if [[ -d "$DST" ]]; then
  # Swap files atomically so a player that's currently open keeps running.
  mkdir -p "$DST/Contents/MacOS" "$DST/Contents/Resources" "$DST/Contents/_CodeSignature"
  for f in BinkMacArmPlayer libBinkHUD.dylib BinkPlayerLauncher; do
    cp "build/Bink Player.app/Contents/MacOS/$f" "$DST/Contents/MacOS/.$f.new"
    mv -f "$DST/Contents/MacOS/.$f.new" "$DST/Contents/MacOS/$f"
  done
  cp "build/Bink Player.app/Contents/Info.plist" "$DST/Contents/.Info.plist.new"
  mv -f "$DST/Contents/.Info.plist.new" "$DST/Contents/Info.plist"
  cp -R "build/Bink Player.app/Contents/Resources/." "$DST/Contents/Resources/"
  if [[ -f "build/Bink Player.app/Contents/_CodeSignature/CodeResources" ]]; then
    cp "build/Bink Player.app/Contents/_CodeSignature/CodeResources" "$DST/Contents/_CodeSignature/.CodeResources.new"
    mv -f "$DST/Contents/_CodeSignature/.CodeResources.new" "$DST/Contents/_CodeSignature/CodeResources"
  fi
else
  cp -R "build/Bink Player.app" "$DST"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST"
build/set_default_handler 2>/dev/null || true
echo "Installed $DST. Double-click any .bk2 or .bik file to play it."
