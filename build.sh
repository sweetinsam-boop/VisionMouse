#!/bin/bash
# Builds VisionMouse.app for macOS (Apple Silicon & Intel).
#   ./build.sh        build
#   ./build.sh run    build and run
set -euo pipefail
cd "$(dirname "$0")"

APP="build/VisionMouse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling VisionMouse (Vision & AVFoundation)..."
swiftc -O \
  -o "$APP/Contents/MacOS/VisionMouse" \
  Sources/*.swift \
  -framework AppKit \
  -framework AVFoundation \
  -framework Vision \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ApplicationServices \
  -framework CoreGraphics

cp Info.plist "$APP/Contents/Info.plist"

# Code signing. Use developer ID if provided, otherwise ad-hoc (-).
SIGN_IDENTITY="${SIGN_ID:--}"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null

echo "==> Successfully built $APP (signed with: $SIGN_IDENTITY)"

if [[ "${1:-}" == "run" ]]; then
  pkill -x VisionMouse 2>/dev/null || true
  open "$APP"
fi
