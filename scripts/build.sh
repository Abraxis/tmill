#!/bin/bash
# Build MyMill.app for release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

echo "==> Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

echo "==> Building MyMill.app (Release)..."
xcodebuild build \
    -project MyMill.xcodeproj \
    -scheme MyMill \
    -configuration Release \
    -destination 'platform=macOS' \
    SYMROOT="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -20

APP_PATH="$BUILD_DIR/Release/MyMill.app"

if [ -d "$APP_PATH" ]; then
    echo ""
    echo "==> Build successful!"
    echo "    $APP_PATH"
    echo ""
    echo "    To create a DMG: ./scripts/create-dmg.sh"
else
    echo "==> Build failed!"
    exit 1
fi
