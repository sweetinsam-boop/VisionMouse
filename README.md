# VisionMouse 👆

> 별도의 센서나 하드웨어 없이, **맥북 내장 FaceTime 카메라** 또는 **iPhone 연속성 카메라**로 손가락 제스처를 인식해 마우스 커서를 제어하는 초경량 온디바이스 에어마우스.

[![macOS](https://img.shields.io/badge/macOS-12.0+-blue.svg)](https://apple.com/macos)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## ✨ 주요 특징 (Key Features)

- **⚡ Apple Neural Engine(ANE) 가속 초저지연 구동**: macOS 내장 `Vision.framework`(`VNDetectHumanHandPoseRequest`)를 활용하여 CPU 점유율 2~4% 미만, 배터리 소모와 발열을 최소화.
- **🎯 240Hz 커서 물리 보간 엔진**: 카메라 센서가 30 FPS로 들어오더라도 전용 고주사율 보간 스레드가 240Hz(4.16ms) 주기로 커서 좌표를 지수 감쇠 보간하여 120Hz Liquid Retina ProMotion 디스플레이에서 비단결처럼 부드럽게 글라이딩.
- **👌 하이퍼링크 클릭 & 더블클릭 완벽 지원**: 손가락을 오므리는 동안 커서가 밀려 텍스트 드래그로 오판되던 문제를 **타임 트래블 롤백 앵커 고정** 및 **릴리즈 시점 동시 Down/Up 주입**으로 해결. 폴더 열기, 링크 이동, 더블클릭 100% 보장.
- **📜 부드러운 픽셀 스크롤 (`units: .pixel`)**: 검지+중지 나란히 펴기 기반 스크롤 자세와 서브픽셀 누적기를 통해 트랙패드처럼 부드러운 스크롤 제공. 포인팅 이동 자세(`👆`, `🖐️`)와의 손 모양 분리로 커서 이동 중 스크롤 오작동 원천 차단.
- **🛡️ 손떨림 제거 (1€ Filter)**: 미세한 손떨림을 정지 시 완벽히 억제하고 빠른 이동 시 즉각 반응.
- **🪟 반투명 미니 뷰어 (Floating HUD)**: 21개 관절 스켈레톤, 실시간 FPS, 감도별 유효 조작 영역(ROI) 점선 가이드 표시. 클릭 관통(`ignoresMouseEvents = true`)으로 화면 구석 조작 방해 방지.
- **⌨️ 전역 단축키 `⌃⌥Space`**: 마우스로 메뉴바를 찾을 필요 없이 `Control + Option + Space`로 즉시 일시정지/재개 (일시정지 시 카메라 꺼짐).
- **🧪 10종 자동화 검증 스위트 내장**: `./build/VisionMouse.app/Contents/MacOS/VisionMouse --self-test` 플래그로 핵심 알고리즘 및 시스템 이벤트 무결성 검증 가능.

---

## 🖐️ 제스처 조작법 (Gesture Guide)

| 동작 | 제스처 및 손 모양 | 설명 |
|---|---|---|
| **커서 이동** | **검지 끝(`👆` 또는 `🖐️`) 이동** | 미니 뷰어 안의 점선 사각형(ROI) 안에서 손을 움직이면 화면 전체 조작 가능 |
| **좌클릭** | **엄지+검지 핀치(꼬집기)**<br>또는 **약지+새끼 까딱 접기** | 손가락을 맞대는 순간 커서가 링크 위에 고정되며, 뗄 때 클릭 발동 |
| **더블클릭** | **연속 2회 핀치 (또는 접기)** | 폴더 열기, 텍스트 단어 선택 등 정상 지원 |
| **드래그** | **핀치한 채로 0.35초 이상 쥐고 이동** | 의도적으로 쥐고 움직일 때만 드래그 앤 드롭 모드로 자동 전환 |
| **스크롤** | **검지+중지 모아 나란히 펴고(`🤞/✌️`) 상하 이동** | 검지와 중지를 모아 펴고 약지·새끼는 접은 채 상하로 부드럽게 스크롤 |
| **우클릭** | **검지는 펴고 엄지+중지 핀치** | 컨텍스트 메뉴 즉시 호출 |
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
- **클릭 제스처 방식**: 둘 다 허용(권장) / 약지+새끼 접기 전용 / 엄지+검지 핀치 전용

---

## 📄 라이선스 (License)

이 프로젝트는 [MIT License](LICENSE)에 따라 배포됩니다.
