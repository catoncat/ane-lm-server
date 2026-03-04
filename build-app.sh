#!/bin/bash
# build-app.sh — Build ANE-LM Server.app (C++ server + SwiftUI menu bar app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_NAME="ANE-LM Server"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "=== Building ANE-LM Server.app ==="

# Step 1: Build C++ server
echo "[1/3] Building ane-lm-server..."
cmake -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -Wno-dev "$ROOT" 2>&1 | tail -1
cmake --build "$BUILD_DIR" --target ane-lm-server -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3

echo "[2/3] Building Swift app..."
# Step 2: Build Swift app
cd "$ROOT/app/ANELMServer"
swift build -c release 2>&1 | tail -3
SWIFT_BIN="$(swift build -c release --show-bin-path)/ANELMServer"
cd "$ROOT"

# Step 3: Assemble .app bundle
echo "[3/3] Assembling ${APP_NAME}.app..."

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

# Copy binaries
cp "$SWIFT_BIN" "$CONTENTS/MacOS/${APP_NAME}"
cp "$BUILD_DIR/ane-lm-server" "$CONTENTS/Resources/ane-lm-server"
chmod +x "$CONTENTS/Resources/ane-lm-server"

# Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ANE-LM Server</string>
    <key>CFBundleDisplayName</key>
    <string>ANE-LM Server</string>
    <key>CFBundleIdentifier</key>
    <string>com.ane-lm.server</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>ANE-LM Server</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo ""
echo "=== Done ==="
echo "App bundle: $APP_BUNDLE"
echo ""
echo "To run:  open \"$APP_BUNDLE\""
echo "To test: \"$CONTENTS/Resources/ane-lm-server\" --help"

# Verify no external dylibs
EXT_DYLIBS=$(otool -L "$CONTENTS/Resources/ane-lm-server" | grep -v /usr/lib | grep -v /System | grep -v "ane-lm-server:" || true)
if [ -n "$EXT_DYLIBS" ]; then
    echo ""
    echo "WARNING: External dylib dependencies detected:"
    echo "$EXT_DYLIBS"
else
    echo "Server binary: zero external dylib dependencies ✓"
fi
