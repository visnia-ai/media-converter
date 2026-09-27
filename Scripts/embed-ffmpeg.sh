#!/bin/bash
set -euo pipefail
SOURCE="$SRCROOT/Sources/MediaCore/Resources/FFmpeg"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
NOTICES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/FFmpeg"
mkdir -p "$DEST" "$NOTICES"
for TOOL in ffmpeg ffprobe; do
    if [ ! -x "$SOURCE/$TOOL" ]; then
        echo "error: Missing bundled $TOOL. Run bash Scripts/build-ffmpeg.sh first."
        exit 1
    fi
    cp "$SOURCE/$TOOL" "$DEST/$TOOL"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime \
        --entitlements "$SRCROOT/Configuration/FFmpeg.entitlements" "$DEST/$TOOL"
done
cp "$SOURCE/NOTICE.txt" "$SOURCE/LICENSE.txt" "$NOTICES/"
cp "$SRCROOT/Configuration/FFmpegCredits.rtf" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Credits.rtf"
