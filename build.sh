#!/bin/bash
# Builds VisionMouse.app for macOS (Apple Silicon & Intel).
#   ./build.sh        build
#   ./build.sh run    build and run
set -euo pipefail
cd "$(dirname "$0")"

APP="build/VisionMouse.app"
pkill -x VisionMouse 2>/dev/null && sleep 0.2 || true
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

# Code signing: 자동으로 Apple Development 인증서를 탐색하여 재빌드 시에도 손쉬운 사용(TCC) 권한이 풀리지 않도록 고정
if [[ -z "${SIGN_ID:-}" ]]; then
  DETECTED_ID=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)
  SIGN_IDENTITY="${DETECTED_ID:--}"
else
  SIGN_IDENTITY="$SIGN_ID"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null

echo "==> Successfully built $APP (signed with: $SIGN_IDENTITY)"

if [[ "${1:-}" == "run" ]]; then
  pkill -x VisionMouse 2>/dev/null || true
  open "$APP"
fi
