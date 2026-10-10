# ffmpeg-desktop

A static, trimmed [FFmpeg](https://ffmpeg.org) for the Windows and Linux
desktop app of [Caper](https://caper.chat), a place for your people to chat
about anything ([source](https://github.com/joswayski/caper)). The app runs it
as a separate program to:

- compress videos before upload (H.264/AAC MP4, HDR tone mapped to SDR),
- play videos in the app (raw RGBA frames and float PCM on pipes, streamed
  from the app's loopback HTTP proxy), and
- decode AVIF and HEIC photos for the full-size viewer.

| | |
| --- | --- |
| FFmpeg | 9.0.2 (release tarball, signature checked against the pinned release key) |
| x264 | `stable` at `b35605ac` (8-bit) |
| dav1d | 1.5.4 (VideoLAN release tarball) |
| zimg | 3.0.6 (release tag, commit pinned) |
| Targets | `linux-x64` (glibc), `windows-x64` (mingw-w64, no DLLs; adds Windows' Media Foundation H.264 encoder) |
| Contents | Only the demuxers, decoders, encoders, muxers, filters and protocols listed in `build.sh`; no TLS, no ffprobe/ffplay |
| Size | ≈16.6 MB stripped on Linux (6.1 MB gzipped) |

Every source is pinned by SHA-256 (or tag and commit) in `build.sh`.

## Licence

x264 is GPL, so these builds are **GPL-2.0-or-later**. Each zip carries the
licence texts, `SOURCES.txt` with the exact source links, and this build
recipe (`licenses/build-recipe.sh`). Caper runs the executable as a separate
program and does not link it.

## Releases

Every push to `main` builds both targets on GitHub's Ubuntu runner,
smoke-tests the Linux build there and the Windows build on a Windows runner
(`test/smoke.sh`: the app's exact compress, poster, playback, AVIF and
loopback-HTTP commands, with inputs from `test/inputs.sh`), and publishes
`ffmpeg-desktop-linux-x64.zip` and `ffmpeg-desktop-windows-x64.zip` with their
`.sha256` as the release `ffmpeg-<version>-r<RELEASE_REVISION>`. An existing
release is never replaced: Caper pins each zip's SHA-256, so a rebuild of the
same versions bumps `RELEASE_REVISION`.

## Building locally

On x86_64 Linux with `nasm meson ninja-build mingw-w64 autoconf automake
libtool pkg-config gnupg`:

```sh
./build.sh linux-x64
./build.sh windows-x64
```
