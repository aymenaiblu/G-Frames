#!/bin/bash
# Builds G-Frames.app from source and installs it. Usage:  bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

# Downloaded files carry a quarantine flag; clear it so nothing here is blocked.
xattr -dr com.apple.quarantine . 2>/dev/null || true

echo "==> Checking toolchain"
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift is missing. Install the Command Line Tools with:  xcode-select --install"
    exit 1
fi
swift --version | head -1

echo "==> Compiling (release)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling G-Frames.app"
APP="build/G-Frames.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GFrames" "$APP/Contents/MacOS/GFrames"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "(icon step skipped)"

codesign --force --deep --sign - "$APP"

echo "==> Installing"
DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi
rm -rf "$DEST/G-Frames.app"
# Remove the earlier build under its old name, if present.
rm -rf "/Applications/FrameSift.app" "$HOME/Applications/FrameSift.app" 2>/dev/null || true
cp -R "$APP" "$DEST/"
echo "Installed: $DEST/G-Frames.app"
open "$DEST/G-Frames.app"
