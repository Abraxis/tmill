#!/bin/bash
# Build, package, and create a GitHub release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

# Check gh CLI
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) not installed. Install with: brew install gh"
    exit 1
fi

# Get version
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/release.sh <version>"
    echo "  e.g. ./scripts/release.sh 1.0.0"
    exit 1
fi

echo "==> Releasing MyMill v$VERSION"

# Update version in Info.plist
cd "$PROJECT_DIR"
sed -i '' "s|<string>[0-9]*\.[0-9]*\.[0-9]*</string>|<string>$VERSION</string>|" MyMill/Info.plist

# Build
echo "==> Building..."
"$SCRIPT_DIR/build.sh"

# Package
echo "==> Packaging..."
"$SCRIPT_DIR/create-dmg.sh"

DMG_PATH="$BUILD_DIR/MyMill-${VERSION}-macOS.dmg"
ZIP_PATH="$BUILD_DIR/MyMill-${VERSION}-macOS.zip"

# Tag and push
echo "==> Tagging v$VERSION..."
git add -A
git commit -m "release: v$VERSION" || true
git tag -a "v$VERSION" -m "Release v$VERSION"
git push origin main --tags

# Create GitHub release
echo "==> Creating GitHub release..."
gh release create "v$VERSION" \
    --title "MyMill v$VERSION" \
    --notes "$(cat <<ENDOFBODY
## MyMill v$VERSION

macOS menu bar app for controlling the Merach T25 treadmill.

### Download
- **DMG** (recommended): Drag MyMill.app to Applications
- **ZIP**: Extract and move to Applications

### Requirements
- macOS 13 (Ventura) or later
- Merach T25 treadmill with Bluetooth enabled
ENDOFBODY
)" \
    "$DMG_PATH" \
    "$ZIP_PATH"

echo ""
echo "==> Release v$VERSION published!"
echo "    https://github.com/Abraxis/mymill/releases/tag/v$VERSION"
