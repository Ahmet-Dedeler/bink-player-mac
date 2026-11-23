#!/bin/zsh
# shot.sh <video> <out.png> [drive cmds before shot] : launch test build, run cmds, screenshot its window via cua-driver
set -euo pipefail
if [[ $# -lt 2 ]]; then
  echo "usage: $0 <video> <out.png> [drive cmds before shot]" >&2
  exit 2
fi
V="${1:A}"
OUT="${2:A}"
EXTRA="${3:-0.1}"
cd "${0:A:h}/.."
( python3 tests/drive.py "$V" "0.6;win;$EXTRA;4" > "$OUT.log" ) &
DRIVE_PID=$!
sleep "${SHOT_DELAY:-2.8}"
PID="$(pgrep -n -f "build/Bink Player.app/Contents/MacOS/BinkMacArmPlayer" || true)"
if [[ -z "$PID" ]]; then
  echo "error: test player process not found" >&2
  wait "$DRIVE_PID" || true
  exit 1
fi
LIST_ARGS="$(python3 -c 'import json,sys; print(json.dumps({"pid": int(sys.argv[1])}))' "$PID")"
WID="$(cua-driver call list_windows "$LIST_ARGS" | python3 -c 'import json,sys; ws=json.load(sys.stdin)["windows"]; print(max(ws,key=lambda w:w["bounds"]["height"])["window_id"])')"
SHOT_ARGS="$(python3 -c 'import json,sys; print(json.dumps({"pid": int(sys.argv[1]), "window_id": int(sys.argv[2]), "include_accessibility_tree": False, "screenshot_out_file": sys.argv[3]}))' "$PID" "$WID" "$OUT")"
cua-driver call get_window_state "$SHOT_ARGS" >/dev/null
wait "$DRIVE_PID"
grep -E "win|seek" "$OUT.log" || true
