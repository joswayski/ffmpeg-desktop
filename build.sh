#!/usr/bin/env bash
# Builds dist/<target>/ffmpeg[.exe]: one static FFmpeg executable for Caper's
# desktop app (Windows and Linux), trimmed to what the app uses:
#
#   - compress a picked video before upload (H.264/AAC MP4, HDR tone mapped to
#     SDR BT.709 with zimg),
#   - play a video in the app (decoded to raw RGBA frames and float PCM on
#     pipes, streamed from a loopback HTTP proxy in the app), and
#   - decode AVIF/HEIC photos for the full-size viewer (dav1d, HEVC).
#
# Usage: ./build.sh linux-x64 | windows-x64   (both build on x86_64 Linux;
# windows-x64 cross-compiles with mingw-w64.)
#
# Sources are exact upstream releases pinned below: FFmpeg by tarball SHA-256
# and its release signature (key pinned by fingerprint), dav1d by VideoLAN's
# release tarball SHA-256, x264 by commit tarball SHA-256, zimg by release tag
# and commit. Nothing else is linked except the C/C++ runtime (Linux: glibc
# and libstdc++; Windows: static, so the .exe needs no DLLs). No TLS: the app
# fetches over HTTPS itself.
#
# Licence: x264 is GPL, so this FFmpeg is GPL-2.0-or-later. Caper runs it as a
# separate program, which leaves the app itself Apache-2.0; every build ships
# the licence texts and SOURCES.txt with the exact source links.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
FFMPEG_VERSION=9.0.2
FFMPEG_SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
FFMPEG_KEY=FCF986EA15E6E293A5644F10B4322F04D67658D8
DAV1D_VERSION=1.5.4
DAV1D_SHA=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
# x264 has no releases; this is the head of its `stable` branch.
X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
X264_SHA=6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224
ZIMG_TAG=release-3.0.6
ZIMG_COMMIT=f819b14e8f39d1282400b0d9543e8ef73c1b2bbd
# Bump to publish a new build of the same versions (flags or script changes).
RELEASE_REVISION=1

TARGET="${1:-}"
case "$TARGET" in
  linux-x64) CROSS=() HOST="" EXE="" ;;
  windows-x64) CROSS=(--cross-prefix=x86_64-w64-mingw32- --arch=x86_64 --target-os=mingw32) HOST=x86_64-w64-mingw32 EXE=.exe ;;
  *) echo "usage: $0 linux-x64|windows-x64" >&2; exit 2 ;;
esac
if [[ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]]; then
  echo "build.sh: build on x86_64 Linux (windows-x64 cross-compiles with mingw-w64)." >&2
  exit 2
fi

BUILD="$ROOT/.build/$TARGET"
PREFIX="$BUILD/prefix"
OUT="$ROOT/dist/$TARGET"
JOBS="$(nproc)"
rm -rf "$BUILD" "$OUT"
mkdir -p "$ROOT/.build" "$BUILD" "$OUT"

fetch() { # url archive sha256
  if [[ ! -f "$2" ]] || ! echo "$3  $2" | sha256sum -c - >/dev/null 2>&1; then
    curl -fLsS --retry 6 --retry-delay 5 --retry-all-errors "$1" -o "$2.partial"
    mv "$2.partial" "$2"
  fi
  if ! echo "$3  $2" | sha256sum -c - >/dev/null 2>&1; then
    echo "build.sh: $(basename "$2") does not match its pinned SHA-256 ($(sha256sum "$2" | cut -d ' ' -f 1))." >&2
    exit 1
  fi
}

# Development only: CAPER_FFMPEG_SYSTEM_DEPS=1 links the build host's static
# libx264.a, libzimg.a and libdav1d.a (for example Ubuntu's -dev packages)
# instead of building the pinned ones. Releases never use it.
if [[ "${CAPER_FFMPEG_SYSTEM_DEPS:-0}" == 1 ]]; then
  [[ "$TARGET" == linux-x64 ]] || { echo "build.sh: system deps exist only for linux-x64." >&2; exit 2; }
  # Static archives only, so the measured size matches a release build.
  mkdir -p "$PREFIX/lib/pkgconfig"
  for lib in x264 zimg dav1d; do
    system="$(pkg-config --variable=libdir "$lib")"
    cp "$system/lib$lib.a" "$PREFIX/lib/"
    sed "s|^libdir=.*|libdir=$PREFIX/lib|" "$system/pkgconfig/$lib.pc" > "$PREFIX/lib/pkgconfig/$lib.pc"
  done
else
  # x264: 8-bit only, static, no CLI.
  fetch "https://code.videolan.org/videolan/x264/-/archive/$X264_COMMIT/x264-$X264_COMMIT.tar.bz2" \
    "$ROOT/.build/x264-$X264_COMMIT.tar.bz2" "$X264_SHA"
  mkdir -p "$BUILD/x264"
  tar -xjf "$ROOT/.build/x264-$X264_COMMIT.tar.bz2" -C "$BUILD/x264" --strip-components=1
  (
    cd "$BUILD/x264"
    ./configure --prefix="$PREFIX" --enable-static --disable-cli --disable-opencl --bit-depth=8 \
      ${HOST:+--host=$HOST --cross-prefix=$HOST-}
    make -j"$JOBS" && make install-lib-static
  )

  # zimg: GitHub serves no signed tarball, so pin the release tag's commit.
  git clone -q --depth 1 --branch "$ZIMG_TAG" --recurse-submodules --shallow-submodules \
    https://github.com/sekrit-twc/zimg "$BUILD/zimg"
  actual="$(git -C "$BUILD/zimg" rev-parse HEAD)"
  if [[ "$actual" != "$ZIMG_COMMIT" ]]; then
    echo "build.sh: zimg $ZIMG_TAG is $actual, not the pinned $ZIMG_COMMIT." >&2
    exit 1
  fi
  (
    cd "$BUILD/zimg"
    ./autogen.sh >/dev/null
    ./configure --prefix="$PREFIX" --enable-static --disable-shared ${HOST:+--host=$HOST}
    make -j"$JOBS" && make install
  )

  # dav1d: the AV1 decoder (AVIF photos, AV1 video). 8-bit and 10-bit.
  fetch "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" \
    "$ROOT/.build/dav1d-$DAV1D_VERSION.tar.xz" "$DAV1D_SHA"
  mkdir -p "$BUILD/dav1d"
  tar -xJf "$ROOT/.build/dav1d-$DAV1D_VERSION.tar.xz" -C "$BUILD/dav1d" --strip-components=1
  cross_file=()
  if [[ -n "$HOST" ]]; then
    cat > "$BUILD/mingw.meson" <<EOF
[binaries]
c = '$HOST-gcc'
ar = '$HOST-ar'
strip = '$HOST-strip'
windres = '$HOST-windres'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
    cross_file=(--cross-file "$BUILD/mingw.meson")
  fi
  meson setup "$BUILD/dav1d/build" "$BUILD/dav1d" "${cross_file[@]}" --prefix="$PREFIX" --libdir=lib \
    --buildtype=release --default-library=static -Denable_tools=false -Denable_tests=false -Denable_examples=false
  ninja -C "$BUILD/dav1d/build" install
fi

# FFmpeg: the signed release tarball.
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$ROOT/.build/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA"
# The signature must come from the release key pinned by fingerprint above.
curl -fLsS --retry 6 --retry-delay 5 --retry-all-errors "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz.asc" \
  -o "$ROOT/.build/ffmpeg-$FFMPEG_VERSION.tar.xz.asc"
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
curl -fLsS --retry 6 --retry-delay 5 --retry-all-errors https://ffmpeg.org/ffmpeg-devel.asc | gpg --batch --quiet --import
gpg --batch --status-fd 1 --verify "$ROOT/.build/ffmpeg-$FFMPEG_VERSION.tar.xz.asc" "$ROOT/.build/ffmpeg-$FFMPEG_VERSION.tar.xz" 2>/dev/null |
  grep -q "^\[GNUPG:\] VALIDSIG $FFMPEG_KEY " || { echo "build.sh: FFmpeg release signature does not verify." >&2; exit 1; }
rm -rf "$GNUPGHOME"
mkdir -p "$BUILD/ffmpeg"
tar -xJf "$ROOT/.build/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$BUILD/ffmpeg" --strip-components=1

# Only the formats phones, cameras, screen recorders and browsers produce.
# Inputs a trimmed build cannot read upload unchanged / open in the browser.
FEATURES=(
  # Files and pipes, plus plain HTTP for the app's loopback stream (no TLS).
  --enable-protocol=file,pipe,http,tcp
  --enable-demuxer=mov,matroska,avi,mpegts,mp3,aac,ogg,wav,flac
  --enable-decoder=h264,hevc,vp8,vp9,libdav1d,mpeg4,mjpeg,aac,mp3,mp3float,opus,vorbis,flac,alac,ac3,eac3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_f32le
  --enable-parser=h264,hevc,vp8,vp9,av1,mpeg4video,mjpeg,aac,mpegaudio,opus,vorbis,flac,ac3
  --enable-bsf=vp9_superframe_split,h264_mp4toannexb,hevc_mp4toannexb
  --enable-encoder=libx264,aac,rawvideo,pcm_f32le
  --enable-muxer=mp4,rawvideo,pcm_f32le,null
  # Scaling, rotation (autorotate inserts transpose/flips), tone mapping and
  # player resampling.
  --enable-filter=scale,format,zscale,tonemap,transpose,hflip,vflip,fps,setsar,null,anull,aresample,aformat
)
WINDOWS_FEATURES=()
# Windows' own H.264 encoder (hardware on most PCs), tried before x264.
[[ "$TARGET" == windows-x64 ]] && WINDOWS_FEATURES=(--enable-mediafoundation --enable-encoder=h264_mf)

(
  cd "$BUILD/ffmpeg"
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" ./configure \
    --prefix="$PREFIX" "${CROSS[@]}" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --extra-ldflags="${HOST:+-static}" --extra-libs=-lm \
    --enable-gpl --enable-static --disable-shared \
    --disable-autodetect --disable-everything --disable-doc --disable-debug \
    --disable-ffplay --disable-ffprobe --disable-iconv \
    --enable-libx264 --enable-libzimg --enable-libdav1d --enable-swscale --enable-swresample \
    "${FEATURES[@]}" "${WINDOWS_FEATURES[@]}"
  make -j"$JOBS" ffmpeg
)
cp "$BUILD/ffmpeg/ffmpeg$EXE" "$OUT/ffmpeg$EXE"
"${HOST:+$HOST-}strip" "$OUT/ffmpeg$EXE"

mkdir -p "$OUT/licenses"
cp "$BUILD/ffmpeg/COPYING.GPLv2" "$OUT/licenses/FFmpeg-COPYING.GPLv2"
cp "$BUILD/ffmpeg/LICENSE.md" "$OUT/licenses/FFmpeg-LICENSE.md"
if [[ -d "$BUILD/x264" ]]; then
  cp "$BUILD/x264/COPYING" "$OUT/licenses/x264-COPYING"
  cp "$BUILD/zimg/COPYING" "$OUT/licenses/zimg-COPYING"
  cp "$BUILD/dav1d/COPYING" "$OUT/licenses/dav1d-COPYING"
fi
# The GPL's "scripts used to control compilation": this recipe travels with
# every build.
cp "$ROOT/build.sh" "$OUT/licenses/build-recipe.sh"
cat > "$OUT/SOURCES.txt" <<EOF
FFmpeg $FFMPEG_VERSION  https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz  sha256 $FFMPEG_SHA
dav1d $DAV1D_VERSION  https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz  sha256 $DAV1D_SHA
x264 $X264_COMMIT  https://code.videolan.org/videolan/x264/-/archive/$X264_COMMIT/x264-$X264_COMMIT.tar.bz2  sha256 $X264_SHA
zimg $ZIMG_TAG ($ZIMG_COMMIT)  https://github.com/sekrit-twc/zimg/tree/$ZIMG_TAG
Build recipe: https://github.com/joswayski/ffmpeg-desktop/blob/main/build.sh (release r$RELEASE_REVISION)
EOF
ls -l "$OUT/ffmpeg$EXE"
