#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EXECUTABLE_NAME="MeetingAgentApp"
APP_BUNDLE="$REPO_ROOT/dist/MeetingAgent.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
INFO_PLIST="$REPO_ROOT/Sources/MeetingAgentApp/Resources/Info.plist"
RELEASE_EXECUTABLE="$REPO_ROOT/.build/release/$EXECUTABLE_NAME"

if [ ! -f "$INFO_PLIST" ]; then
    echo "Missing app Info.plist at $INFO_PLIST" >&2
    exit 1
fi

cd "$REPO_ROOT"
swift build -c release --product MeetingAgentApp

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$RELEASE_EXECUTABLE" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "Packaged $APP_BUNDLE"
