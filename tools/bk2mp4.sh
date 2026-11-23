#!/bin/zsh
# bk2mp4.sh <in.bk2> [out.mp4]
#
# Converts a Bink 2 (.bk2) or Bink 1 (.bik) video to an H.264 + AAC .mp4, video
# and audio, without any RAD code. It does not use the Bink Player app at all.
#
# Decoding: librempeg (an FFmpeg fork), whose open-source Bink 2 decoder matches
# RAD's output since https://github.com/librempeg/librempeg/pull/217 and
# https://github.com/librempeg/librempeg/pull/218 (bit-exact across 720p, 1080p
# and 1440p KB2n).
# The first run clones and builds a small decode-only librempeg into
# ~/Library/Caches/bink-player-mac (under a minute); later runs reuse it.
#
# Encoding: your normal ffmpeg (brew install ffmpeg), using the Mac's hardware
# H.264 encoder. librempeg pipes raw frames + float PCM to it as NUT.
#
# Env: BK2MP4_BITRATE (default 12M), BK2MP4_FFMPEG (default: ffmpeg on PATH).
set -euo pipefail

REPO=https://github.com/librempeg/librempeg.git
COMMIT=aa917f05ffef2a6fad2c4130011e4b10afee225b   # master with librempeg#217 + #218 merged
SHORT="${COMMIT[1,8]}"
CACHE="${XDG_CACHE_HOME:-$HOME/Library/Caches}/bink-player-mac"
SRC="$CACHE/librempeg-$SHORT"
DEC="$SRC/ffmpeg"

in="${1:-}"
[[ -n "$in" ]] || { echo "usage: $0 <in.bk2> [out.mp4]" >&2; exit 2; }
[[ -f "$in" ]] || { echo "no such file: $in" >&2; exit 1; }

if [[ -n "${2:-}" ]]; then
  out="$2"
else
  dir="$(dirname -- "$in")"
  base="$(basename -- "$in")"
  if [[ "$base" == ?*.* ]]; then
    stem="${base%.*}"
  else
    stem="$base"
  fi
  if [[ "$dir" == "." && "$in" != ./* ]]; then
    out="${stem}.mp4"
  else
    out="${dir}/${stem}.mp4"
  fi
fi

if [[ "${in:A}" == "${out:A}" ]]; then
  echo "error: output path matches input path: $out" >&2
  exit 2
fi

ENC="${BK2MP4_FFMPEG:-$(command -v ffmpeg || true)}"
[[ -n "$ENC" ]] || { echo "needs ffmpeg for encoding: brew install ffmpeg" >&2; exit 1; }

TMP_SRC=""
LOCK_HELD=""
cleanup() {
  [[ -n "$TMP_SRC" ]] && rm -rf "$TMP_SRC"
  [[ -n "$LOCK_HELD" ]] && rmdir "$LOCK_HELD" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -x "$DEC" ]]; then
  echo "building the Bink 2 decoder (first run only) into $SRC" >&2
  mkdir -p "$CACHE"
  TMP_SRC="$(mktemp -d "$CACHE/.librempeg-${SHORT}.XXXXXX")"
  git init -q "$TMP_SRC"
  git -C "$TMP_SRC" fetch -q --depth 1 "$REPO" "$COMMIT"
  git -C "$TMP_SRC" checkout -q FETCH_HEAD
  # Decode-only build: Bink demuxer, Bink/Bink 2 video + Bink audio decoders, and
  # just enough muxers/encoders to hand raw frames and PCM to the real ffmpeg.
  (cd "$TMP_SRC" && ./configure --enable-agpl --disable-everything --disable-doc \
      --disable-network --disable-autodetect --disable-ffplay --disable-ffprobe \
      --enable-decoder='bink2,bink,binkaudio_dct,binkaudio_rdft,rawvideo' --enable-demuxer=bink \
      --enable-protocol='file,pipe' --enable-muxer=nut \
      --enable-encoder='rawvideo,pcm_f32le' \
      --enable-filter='scale,format,null,anull,aresample,asf2sf,aformat' \
      --enable-swscale >"$TMP_SRC/configure.log" 2>&1 \
    && make -j"$(sysctl -n hw.ncpu)" ffmpeg >"$TMP_SRC/build.log" 2>&1) \
    || {
      cp "$TMP_SRC/configure.log" "$CACHE/configure.log" 2>/dev/null || true
      cp "$TMP_SRC/build.log" "$CACHE/build.log" 2>/dev/null || true
      echo "build failed, see $CACHE/build.log and $CACHE/configure.log" >&2
      exit 1
    }
  LOCK="$CACHE/.publish-${SHORT}.lock"
  while ! mkdir "$LOCK" 2>/dev/null; do sleep 0.1; done
  LOCK_HELD="$LOCK"
  if [[ ! -x "$DEC" ]]; then
    rm -rf "$SRC"
    mv "$TMP_SRC" "$SRC"
    TMP_SRC=""
  fi
  rmdir "$LOCK_HELD" 2>/dev/null || true
  LOCK_HELD=""
fi

# Every audio track is kept (game videos often have several, e.g. languages).
"$DEC" -nostdin -hide_banner -loglevel error -i "$in" \
    -map 0:v:0 -map '0:a?' -c:v rawvideo -c:a pcm_f32le -f nut - |
  "$ENC" -nostdin -hide_banner -loglevel error -i - -map 0 \
    -c:v h264_videotoolbox -b:v "${BK2MP4_BITRATE:-12M}" -pix_fmt yuv420p \
    -c:a aac -b:a 192k -movflags +faststart -y "$out"
echo "$out"
