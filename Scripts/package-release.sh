#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TAG="${1:?Usage: package-release.sh vMAJOR.MINOR.PATCH BUILD_NUMBER}"
BUILD_NUMBER="${2:?A positive build number is required}"
[[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Invalid release tag' >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build number' >&2; exit 1; }
VERSION="${TAG#v}"
mkdir -p "$ROOT/build"
TOOLS="$ROOT/build/dmg-tools"
if [ ! -x "$TOOLS/bin/python" ]; then python3 -m venv "$TOOLS"; fi
"$TOOLS/bin/python" -m pip install --disable-pip-version-check --only-binary=:all: \
    --require-hashes -r "$ROOT/Scripts/dmg-requirements.txt"
WORK="$(mktemp -d "$ROOT/build/package.XXXXXX")"
MOUNT="$WORK/mount"
cleanup() {
    if mount | grep -Fq " on $MOUNT "; then hdiutil detach "$MOUNT" -quiet || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
xcodebuild -project MediaConverter.xcodeproj -scheme MediaConverter -configuration Release \
    -derivedDataPath "$ROOT/build/ReleaseXcode" -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build
APP="$ROOT/build/ReleaseXcode/Build/Products/Release/Media Converter.app"
PLIST="$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$BUILD_NUMBER"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")" = AppIcon
test -s "$APP/Contents/Resources/AppIcon.icns"
for BINARY in "$APP/Contents/MacOS/MediaConverter" "$APP/Contents/Helpers/ffmpeg" "$APP/Contents/Helpers/ffprobe"; do
    ARCHITECTURES="$(lipo -archs "$BINARY")"
    [[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]]
    codesign --verify --strict "$BINARY"
    # Release binaries must not depend on Homebrew or build-machine libraries.
    if otool -L "$BINARY" | awk '/compatibility version/ {print $1}' | grep -Ev '^(/System/Library/|/usr/lib/)' ; then
        echo 'Unexpected runtime dependency' >&2; exit 1
    fi
done
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" > "$WORK/entitlements.plist" 2>/dev/null
python3 - "$WORK/entitlements.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file:
    entitlements = plistlib.load(file)
assert entitlements.get('com.apple.security.app-sandbox') is True
assert entitlements.get('com.apple.security.files.user-selected.read-write') is True
assert not entitlements.get('com.apple.security.get-task-allow')
assert not entitlements.get('com.apple.security.network.client')
assert not entitlements.get('com.apple.security.network.server')
PY
mkdir -p "$WORK/stage" "$ROOT/build/release"
ditto "$APP" "$WORK/stage/Media Converter.app"
ln -s /Applications "$WORK/stage/Applications"
cp LICENSE "$WORK/stage/LICENSE.txt"
NAME="Media-Converter-$VERSION-universal"
"$TOOLS/bin/python" -m dmgbuild -s "$ROOT/Scripts/dmg-settings.py" \
    -D "app=$WORK/stage/Media Converter.app" -D "license=$WORK/stage/LICENSE.txt" \
    -D "icon=$ROOT/Configuration/AppIcon.icns" \
    "Media Converter $VERSION" "$ROOT/build/release/$NAME.dmg"
hdiutil verify "$ROOT/build/release/$NAME.dmg"
mkdir -p "$MOUNT"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$ROOT/build/release/$NAME.dmg"
codesign --verify --deep --strict "$MOUNT/Media Converter.app"
test "$(readlink "$MOUNT/Applications")" = /Applications
"$TOOLS/bin/python" "$ROOT/Scripts/verify-dmg-layout.py" "$MOUNT"
hdiutil detach -quiet "$MOUNT"
# Include the unmodified, checksum-verified dependency source and full build recipe.
test -n "$(find build/ThirdPartySources -name 'ffmpeg-*.tar.xz' -print -quit)"
COPYFILE_DISABLE=1 tar -czf "build/release/$NAME-sources.tar.gz" -C build ThirdPartySources
(
    cd build/release
    shasum -a 256 "$NAME.dmg" "$NAME-sources.tar.gz" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
    cat > RELEASE-NOTES.md <<NOTES
Media Converter $VERSION for macOS 15 or later, supporting Apple Silicon and Intel.

Download the DMG, open it, and drag Media Converter into Applications.
The app and its bundled helpers use ad-hoc signatures and are not notarized; macOS may require an explicit security override to open the app.

The matching FFmpeg source and build recipe are included in the sources archive.
Verify downloads against SHA256SUMS.txt.
NOTES
)
echo "Release assets: $ROOT/build/release"
