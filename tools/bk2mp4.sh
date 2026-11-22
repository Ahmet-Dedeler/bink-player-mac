#!/bin/sh
# bk2mp4.sh <in.bk2> [out.mp4]
#
# Converts a Bink 2 (.bk2) video to an H.264 + AAC .mp4, video and audio,
# without any RAD code. It does not use the Bink Player app at all.
#
# Decoding: librempeg (an FFmpeg fork), whose open-source Bink 2 decoder matches
# RAD's output since https://github.com/librempeg/librempeg/pull/217 (bit-exact
# on 1080p/1440p KB2n, near-exact on 720p).
# The first run clones and builds a small decode-only librempeg into
# ~/Library/Caches/bink-player-mac (a few minutes); later runs reuse it.
#
# Encoding: your normal ffmpeg (brew install ffmpeg), using the Mac's hardware
# H.264 encoder. librempeg pipes raw frames + float PCM to it as NUT.
#
# Env: BK2MP4_BITRATE (default 12M), BK2MP4_FFMPEG (default: ffmpeg on PATH).
set -e

REPO=https://github.com/librempeg/librempeg.git
COMMIT=dd0e159631af2d7c8b4b643ce64a50b40f95393f   # master with librempeg#217 merged
CACHE="${XDG_CACHE_HOME:-$HOME/Library/Caches}/bink-player-mac"
SRC="$CACHE/librempeg-${COMMIT%"${COMMIT#????????}"}"
DEC="$SRC/ffmpeg"

[ -n "$1" ] || { echo "usage: $0 <in.bk2> [out.mp4]" >&2; exit 2; }
in="$1"; out="${2:-${in%.*}.mp4}"
[ -f "$in" ] || { echo "no such file: $in" >&2; exit 1; }

ENC="${BK2MP4_FFMPEG:-$(command -v ffmpeg || true)}"
[ -n "$ENC" ] || { echo "needs ffmpeg for encoding: brew install ffmpeg" >&2; exit 1; }

if [ ! -x "$DEC" ]; then
  echo "building the Bink 2 decoder (first run only) into $SRC" >&2
  mkdir -p "$CACHE"
  rm -rf "$SRC"
  git init -q "$SRC"
  git -C "$SRC" fetch -q --depth 1 "$REPO" "$COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
  # Decode-only build: Bink demuxer, Bink 2 video + Bink audio decoders, and
  # just enough muxers/encoders to hand raw frames and PCM to the real ffmpeg.
  (cd "$SRC" && ./configure --enable-agpl --disable-everything --disable-doc \
      --disable-network --disable-autodetect --disable-ffplay --disable-ffprobe \
      --enable-decoder='bink2,binkaudio_dct,rawvideo' --enable-demuxer=bink \
      --enable-protocol='file,pipe' --enable-muxer=nut \
      --enable-encoder='rawvideo,pcm_f32le' \
      --enable-filter='scale,format,null,anull,aresample,asf2sf,aformat' \
      --enable-swscale >"$CACHE/configure.log" 2>&1 \
    && make -j"$(sysctl -n hw.ncpu)" ffmpeg >"$CACHE/build.log" 2>&1) \
    || { echo "build failed, see $CACHE/build.log and configure.log" >&2; exit 1; }
fi

# Every audio track is kept (game videos often have several, e.g. languages).
"$DEC" -nostdin -hide_banner -loglevel error -i "$in" \
    -map 0:v:0 -map '0:a?' -c:v rawvideo -c:a pcm_f32le -f nut - |
  "$ENC" -nostdin -hide_banner -loglevel error -i - -map 0 \
    -c:v h264_videotoolbox -b:v "${BK2MP4_BITRATE:-12M}" -pix_fmt yuv420p \
    -c:a aac -b:a 192k -movflags +faststart -y "$out"
echo "$out"
