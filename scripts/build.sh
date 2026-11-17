#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${INTERVIEW_BUILD_DIR:-$PROJECT_DIR/.build}"
DESTINATION="${INTERVIEW_OUTPUT_DIR:-$PROJECT_DIR/..}"
# Keep one signing identity across updates. Ad-hoc signing binds the app's
# designated requirement to its changing cdhash, invalidating existing TCC grants.
# Require the developer to select a persistent signing identity.
SIGNING_IDENTITY="${INTERVIEW_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "Set INTERVIEW_SIGNING_IDENTITY to a code-signing identity from your Keychain." >&2
    exit 1
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "A persistent code-signing identity is required; ad-hoc signing would reset permissions." >&2
    exit 1
fi
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release
BINARY_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release --show-bin-path)"
APP_PATH="$DESTINATION/Interview.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_DIR/Interview" "$APP_PATH/Contents/MacOS/Interview"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
swift "$PROJECT_DIR/scripts/icon.swift" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$PROJECT_DIR/Interview.entitlements" "$APP_PATH"
codesign --verify --strict "$APP_PATH"
printf '%s\n' "$APP_PATH"
