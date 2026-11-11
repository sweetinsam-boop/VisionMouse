#!/bin/bash
# Builds and runs VisionMouse
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

echo "==> Running VisionMouse.app..."
open -n build/VisionMouse.app

echo "==> VisionMouse가 실행되었습니다! 상단 메뉴바의 👆 아이콘과 화면 우측 상단 미니 뷰어를 확인하세요."
