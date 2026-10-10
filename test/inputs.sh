#!/usr/bin/env bash
# Generates smoke-test inputs with a full FFmpeg (the runner's): what phones,
# cameras and other Caper clients send.
set -euo pipefail
out="$1"
mkdir -p "$out"
f=(ffmpeg -nostdin -hide_banner -loglevel error -y)
# A rotated 4K HEVC HLG phone clip with AAC sound.
"${f[@]}" -f lavfi -i testsrc2=size=3840x2160:rate=30 -f lavfi -i sine=sample_rate=48000 -t 1 \
  -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p10le \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -c:a aac -tag:v hvc1 "$out/hdr.mov"
"${f[@]}" -display_rotation 90 -i "$out/hdr.mov" -c copy "$out/phone.mov"
rm "$out/hdr.mov"
# A browser recording: VP9 and Opus in WebM.
"${f[@]}" -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine -t 1 -c:v libvpx-vp9 -c:a libopus "$out/browser.webm"
# An AV1 still (AVIF), as other clients store photos.
"${f[@]}" -f lavfi -i testsrc2=size=1200x800 -frames:v 1 -c:v libaom-av1 -still-picture 1 "$out/photo.avif"
ls -l "$out"
