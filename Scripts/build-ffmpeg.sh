#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=8.1.3
SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
WORK="$ROOT/build/ffmpeg"
ARCHIVE="$WORK/source/ffmpeg-$VERSION.tar.xz"
DEST="$ROOT/Sources/MediaCore/Resources/FFmpeg"
mkdir -p "$WORK/source" "$DEST"
if [ ! -f "$ARCHIVE" ]; then
    curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "$ARCHIVE.download" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
    mv "$ARCHIVE.download" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c -
if [ ! -d "$WORK/source/ffmpeg-$VERSION" ]; then
    tar -xf "$ARCHIVE" -C "$WORK/source"
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
JOBS="${FFMPEG_BUILD_JOBS:-8}"
for ARCH in arm64 x86_64; do
    mkdir -p "$WORK/$ARCH"
    (
        cd "$WORK/$ARCH"
        if [ ! -f ffbuild/config.mak ]; then
            "$WORK/source/ffmpeg-$VERSION/configure" \
                --prefix="$WORK/$ARCH/install" --arch="$ARCH" --target-os=darwin --enable-cross-compile \
                --cc="$(xcrun -f clang)" --sysroot="$SDK" \
                --extra-cflags="-arch $ARCH -mmacosx-version-min=15.0" \
                --extra-ldflags="-arch $ARCH -mmacosx-version-min=15.0" \
                --enable-static --disable-shared --disable-autodetect --disable-gpl --disable-nonfree \
                --disable-network --disable-protocols --enable-protocol=file,fd,pipe \
                --disable-doc --disable-debug --disable-ffplay --disable-avdevice --disable-x86asm \
                --disable-encoders --enable-encoder=hevc_videotoolbox,aac,pcm_s16le,mpeg4,mpeg2video,wmv2,flv,h263 \
                --enable-videotoolbox --enable-audiotoolbox
        fi
        make -j "$JOBS" ffmpeg ffprobe > build.log 2>&1 || { tail -80 build.log; exit 1; }
    )
done
for TOOL in ffmpeg ffprobe; do
    lipo -create "$WORK/arm64/$TOOL" "$WORK/x86_64/$TOOL" -output "$DEST/$TOOL"
    chmod 755 "$DEST/$TOOL"
    codesign --force --sign - "$DEST/$TOOL"
done
cp "$WORK/source/ffmpeg-$VERSION/COPYING.LGPLv2.1" "$DEST/LICENSE.txt"
mkdir -p "$ROOT/build/ThirdPartySources"
cp "$ARCHIVE" "$ROOT/build/ThirdPartySources/"
cp "$0" "$ROOT/build/ThirdPartySources/build-ffmpeg.sh"
cp "$DEST/NOTICE.txt" "$DEST/LICENSE.txt" "$DEST/REBUILD.txt" "$ROOT/build/ThirdPartySources/"
printf 'Built universal FFmpeg %s. Matching source: build/ThirdPartySources\n' "$VERSION"
