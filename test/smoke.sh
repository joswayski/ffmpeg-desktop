#!/usr/bin/env bash
# Runs a build the way Caper desktop does: compress, poster, playback pipes
# (also over loopback HTTP) and AVIF decoding. Usage: smoke.sh <ffmpeg> <inputs>
set -euo pipefail
ffmpeg="$1" inputs="$2"
work="$(mktemp -d)"
run() { "$ffmpeg" -nostdin -hide_banner -loglevel error "$@"; }
probe() { "$ffmpeg" -nostdin -hide_banner -i "$1" 2>&1 | grep -E "Stream|displaymatrix" || true; }

"$ffmpeg" -hide_banner -version | head -1

# Compress the HDR phone clip exactly as the app does: tone mapped, rotated to
# portrait by FFmpeg, short edge 1080 by expression.
compress() {
  run -y -i "$inputs/phone.mov" -map 0:v:0 -map '0:a:0?' \
    -vf "zscale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)':t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" \
    -c:v "$1" -b:v 6000k -c:a copy -map_metadata -1 -movflags +faststart -f mp4 "$work/out-$1.mp4" || return 1
  probe "$work/out-$1.mp4" | tee "$work/probe.txt"
  grep -q "Video: h264" "$work/probe.txt" && grep -q "1080x1920" "$work/probe.txt"
}
compress libx264
# Windows also tries Media Foundation's hardware encoder first. Machines
# without it (Windows Server without Media Foundation, some VMs) fall back to
# x264 in the app, so here it's reported rather than required.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    if compress h264_mf; then echo "h264_mf: ok"; else echo "::warning::h264_mf unavailable on this machine; the app falls back to libx264"; fi
    ;;
esac

# VP9/Opus to H.264/AAC.
run -y -i "$inputs/browser.webm" -vf "scale=640:360,format=yuv420p" -c:v libx264 -c:a aac -f mp4 "$work/webm.mp4"
probe "$work/webm.mp4" | grep -q "Audio: aac"

# Player pipes: RGBA frames and float PCM.
frames="$(run -i "$work/out-libx264.mp4" -map 0:v:0 -vf "scale=270:480,format=rgba" -r 30 -fps_mode cfr \
  -f rawvideo -pix_fmt rgba pipe:1 | wc -c)"
test "$frames" -ge $((270 * 480 * 4 * 25))
pcm="$(run -i "$work/out-libx264.mp4" -map '0:a:0?' -vn -ac 2 -ar 48000 -c:a pcm_f32le -f f32le pipe:1 | wc -c)"
test "$pcm" -ge $((48000 * 2 * 4 / 2))

# AVIF photo for the viewer.
still="$(run -i "$inputs/photo.avif" -frames:v 1 -vf "scale=1200:800,format=rgba" -f rawvideo -pix_fmt rgba pipe:1 | wc -c)"
test "$still" -eq $((1200 * 800 * 4))

# Loopback HTTP (the app's stream proxy), where Python is available.
# (Windows can have a python3 that is only a Store shortcut, so run it first.)
if python3 -c pass >/dev/null 2>&1; then
  python3 -m http.server 8799 --bind 127.0.0.1 --directory "$work" >/dev/null 2>&1 &
  server=$!
  sleep 2
  http="$(run -i "http://127.0.0.1:8799/out-libx264.mp4" -map 0:v:0 -frames:v 1 -vf "scale=270:480,format=rgba" \
    -f rawvideo -pix_fmt rgba pipe:1 | wc -c)"
  kill "$server"
  test "$http" -eq $((270 * 480 * 4))
fi
rm -rf "$work"
echo "smoke test passed: $ffmpeg"
