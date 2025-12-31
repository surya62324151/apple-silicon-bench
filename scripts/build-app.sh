#!/bin/bash
set -e

# Build the macOS .app bundle
# Usage: ./scripts/build-app.sh [release|debug]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG="${1:-release}"
APP_NAME="Apple Silicon Bench"
BUNDLE_NAME="$APP_NAME.app"

echo "Building osx-bench ($CONFIG)..."
cd "$ROOT_DIR"
swift build -c "$CONFIG"

# Get version from Package.swift
VERSION=$(grep 'let version = ' Package.swift | sed 's/.*"\(.*\)".*/\1/')
echo "Version: $VERSION"

# Create app bundle structure
echo "Creating app bundle..."
rm -rf "dist/$BUNDLE_NAME"
mkdir -p "dist/$BUNDLE_NAME/Contents/MacOS"
mkdir -p "dist/$BUNDLE_NAME/Contents/Resources"

# Copy binary
cp ".build/$CONFIG/osx-bench" "dist/$BUNDLE_NAME/Contents/MacOS/"

# Strip symbols in release mode
if [ "$CONFIG" = "release" ]; then
    strip "dist/$BUNDLE_NAME/Contents/MacOS/osx-bench"
fi

# Copy resources
cp Resources/Info.plist "dist/$BUNDLE_NAME/Contents/"
cp Resources/AppIcon.icns "dist/$BUNDLE_NAME/Contents/Resources/"

# Update version in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "dist/$BUNDLE_NAME/Contents/Info.plist"

# Ad-hoc code sign
echo "Code signing..."
codesign --force --sign - "dist/$BUNDLE_NAME"

echo "✅ Built: dist/$BUNDLE_NAME"
ls -la "dist/$BUNDLE_NAME/Contents/MacOS/"

# Also create standalone CLI binary
echo ""
echo "Creating standalone CLI binary..."
cp ".build/$CONFIG/osx-bench" "dist/osx-bench"
if [ "$CONFIG" = "release" ]; then
    strip "dist/osx-bench"
fi
codesign --force --sign - "dist/osx-bench"
echo "✅ Built: dist/osx-bench"
