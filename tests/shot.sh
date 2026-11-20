#!/bin/zsh
# shot.sh <video> <out.png> [drive cmds before shot] : launch test build, run cmds, screenshot its window via cua-driver
cd "${0:A:h}/.."
V="$1"; OUT="$2"; EXTRA="${3:-0.1}"
( python3 tests/drive.py "$V" "0.6;win;$EXTRA;4" > "$OUT.log" ) &
sleep ${SHOT_DELAY:-2.8}
PID=$(pgrep -n -f "build/Bink Player.app/Contents/MacOS/BinkMacArmPlayer")
WID=$(cua-driver call list_windows "{\"pid\":$PID}" | python3 -c 'import json,sys; ws=json.load(sys.stdin)["windows"]; print(max(ws,key=lambda w:w["bounds"]["height"])["window_id"])')
cua-driver call get_window_state "{\"pid\":$PID,\"window_id\":$WID,\"include_accessibility_tree\":false,\"screenshot_out_file\":\"$OUT\"}" >/dev/null
wait
grep -E "win|seek" "$OUT.log"
