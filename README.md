# VisionMouse 👆

> 별도의 센서나 하드웨어 없이, **맥북 내장 FaceTime 카메라** 또는 **iPhone 연속성 카메라**로 손가락 제스처를 인식해 마우스 커서를 제어하는 초경량 온디바이스 에어마우스.

[![macOS](https://img.shields.io/badge/macOS-12.0+-blue.svg)](https://apple.com/macos)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## ✨ 주요 특징 (Key Features)

- **⚡ Apple Neural Engine(ANE) 가속 초저지연 구동**: macOS 내장 `Vision.framework`(`VNDetectHumanHandPoseRequest`)를 활용하여 CPU 점유율 2~4% 미만, 배터리 소모와 발열을 최소화.
- **🎯 240Hz 커서 물리 보간 엔진**: 카메라 센서가 30 FPS로 들어오더라도 전용 고주사율 보간 스레드가 240Hz(4.16ms) 주기로 커서 좌표를 지수 감쇠 보간하여 120Hz Liquid Retina ProMotion 디스플레이에서 비단결처럼 부드럽게 글라이딩.
- **👌 하이퍼링크 클릭 & 더블클릭 완벽 지원**: 엄지를 검지에 붙이는 동안 커서가 밀려 텍스트 드래그로 오판되던 문제를 **타임 트래블 롤백 앵커 고정** 및 **릴리즈 시점 동시 Down/Up 주입**으로 해결. 폴더 열기, 링크 이동, 더블클릭 100% 보장.
- **📜 조이스틱 스크롤**: 검지+중지를 붙여 편 자세에서 손을 기준점에서 옮긴 방향·거리로 세로·가로 스크롤. 240Hz 서브픽셀 누적과 트랙패드식 began/changed/ended 단계로 전송. 포인팅 이동 자세(`👆`, `🖐️`)와의 손 모양 분리로 커서 이동 중 스크롤 오작동 원천 차단.
- **🛡️ 손떨림 제거 (1€ Filter)**: 미세한 손떨림을 정지 시 완벽히 억제하고 빠른 이동 시 즉각 반응.
- **🪟 반투명 미니 뷰어 (Floating HUD)**: 21개 관절 스켈레톤, 실시간 FPS, 감도별 유효 조작 영역(ROI) 점선 가이드 표시. 클릭 관통(`ignoresMouseEvents = true`)으로 화면 구석 조작 방해 방지.
- **⌨️ 전역 단축키 `⌃⌥Space`**: 마우스로 메뉴바를 찾을 필요 없이 `Control + Option + Space`로 즉시 일시정지/재개 (일시정지 시 카메라 꺼짐).
- **🧪 자동화 검증 스위트 내장**: `./build/VisionMouse.app/Contents/MacOS/VisionMouse --self-test` 플래그로 핵심 알고리즘 및 시스템 이벤트 무결성 검증 가능.

---

## 🖐️ 제스처 조작법 (Gesture Guide)

| 동작 | 제스처 및 손 모양 | 설명 |
|---|---|---|
| **커서 이동** | **검지 끝(`👆` 또는 `🖐️`) 이동** | 미니 뷰어 안의 점선 사각형(ROI) 안에서 손을 움직이면 화면 전체 조작 가능 |
| **좌클릭** | **엄지를 검지 옆에 붙였다 떼기** | 검지를 펴고 엄지를 L자로 벌린 채 포인팅하다가, 엄지를 검지 옆면(또는 끝)에 붙이는 순간 커서가 고정되고 뗄 때 클릭 발동. 엄지를 붙인 채 손을 들이밀면 클릭되지 않음(엄지를 한 번 벌려야 무장) |
| **더블클릭** | **엄지 연속 2회 붙였다 떼기** | 폴더 열기, 텍스트 단어 선택 등 정상 지원 |
| **드래그** | **엄지를 검지에 붙인 채 0.35초 이상 유지하며 이동** | 의도적으로 붙이고 움직일 때만 드래그 앤 드롭 모드로 자동 전환 |
| **스크롤 (조이스틱)** | **검지+중지 모아 나란히 펴고(`🤞/✌️`) 손을 기준점에서 이동** | 자세를 취한 순간의 손 위치가 기준점. 손을 위·아래·옆으로 옮긴 방향으로 스크롤되고, 멀리 옮길수록 빨라짐. 기준점으로 돌아오면 정지, 자세를 풀면 종료 (엄지가 검지에 붙어 있어도 클릭 안 됨) |
| **일시정지 / 재개** | **단축키 `Control + Option + Space`** | 메뉴바 클릭 없이 즉시 일시정지/재개 (일시정지 시 카메라 녹색불 꺼짐) |

---

## 💻 요구사항 (Requirements)

- macOS 12.0 (Monterey) 이상 (Apple Silicon M1/M2/M3/M4 및 Intel Mac 지원)
- Mac 내장 FaceTime 카메라 또는 외장 웹캠 / iPhone 연속성 카메라
- 필수 권한:
  - **카메라(Camera) 접근 권한**: 손가락 랜드마크 추적용
  - **손쉬운 사용(Accessibility) 권한**: 마우스 커서 이동 및 클릭/스크롤 이벤트 주입용

---

## 🚀 빠른 시작 (Getting Started)

### 빌드 및 실행

```bash
# 1. 저장소 클론
git clone https://github.com/sweetinsam-boop/VisionMouse.git
cd VisionMouse

# 2. 빌드 및 즉시 실행
./run.sh
```

또는 수동 빌드:

```bash
./build.sh run
```

### 자체 자동화 테스트 실행

```bash
./build.sh
./build/VisionMouse.app/Contents/MacOS/VisionMouse --self-test
```

---

## ⚙️ 설정 (Preferences)

메뉴 막대의 `👆` 아이콘을 클릭하여 다음 설정을 실시간으로 변경할 수 있습니다:
- **카메라 선택**: FaceTime 카메라(30 FPS) 또는 iPhone 연속성 카메라(⚡ 60 FPS) 동적 전환
- **⚡ 초저지연 모드**: 640x480 ANE 가속 모드 (기본 켜짐)
- **미니 뷰어 보기/숨기기** 및 **드래그 이동 허용** (위치 조정용)
- **포인터 감도**: 보통(권장) / 고감도 / 초고감도 / 저감도
- **조준: 검지 끝+관절 혼합**: 커서 Y를 검지 끝 40% + 검지 관절(MCP) 60%로 섞어 엄지를 붙일 때 커서 흔들림을 줄임 (기본 꺼짐)
- **엄지 클릭 보정…**: 4초 동안 엄지를 벌렸다 붙였다 하면 손에 맞는 누름·뗌 임계값을 계산해 저장
- **손 동작 기록 (진단용)**: 손 관절 좌표를 `~/Library/Logs/VisionMouse/record-*.jsonl`에 최대 3분 기록

### 기록 재생 (진단)

```bash
./build/VisionMouse.app/Contents/MacOS/VisionMouse --replay ~/Library/Logs/VisionMouse/record-<시각>.jsonl
```

기록을 제스처 엔진에 다시 넣어 상태 변화, 클릭·드래그·스크롤 결과, 엄지-검지 비율 분포와 보정 제안 값을 출력합니다.

---

## 📄 라이선스 (License)

이 프로젝트는 [MIT License](LICENSE)에 따라 배포됩니다.
