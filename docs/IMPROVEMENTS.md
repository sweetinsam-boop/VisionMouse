# VisionMouse 개선안 (2026-11-11)

참고 저장소 5곳(mac-hand-mouse, Skeleton_Engine, air-mouse-control, HandTrack-MacControl, boostcamp cv-13)과 현재 코드(`f345fd8`)를 비교해 정리했다.

## 0. 먼저 짚을 점: 참고 자료와 현재 코드의 차이

| 참고 자료의 권장 사항 | VisionMouse 현재 상태 | 판단 |
|---|---|---|
| Apple Vision 네이티브 손 추적 | 이미 `VNDetectHumanHandPoseRequest` 사용 | 이미 충족 |
| EMA/칼만 스무딩 | 1€ 필터 + 240Hz 보간 스레드 | EMA보다 낫다. 칼만으로 바꿀 이유 없음 |
| 손쉬운 사용·카메라 권한 | 권한 확인, 프롬프트, TCC 리셋까지 구현 | 이미 충족 |

결론: 기본 파이프라인은 참고 저장소보다 앞서 있다. 남은 개선 여지는 **조준 정밀도, 오인식 방지, 견고성, 튜닝 도구, 확장성** 다섯 축이다.

---

## P0: 작은 수정, 체감 효과 큼

> 상태: 1~5 구현 완료 (2026-11-11). 자체 테스트 11~13 추가, 13/13 통과. 실기기 손 테스트는 아직.

### 1. 프레임 타임스탬프를 카메라 PTS로 교체
- 현재: `HandPoseDetector.process`가 Vision 추론이 **끝난 뒤** `CFAbsoluteTimeGetCurrent()`를 찍는다(`HandPoseDetector.swift:296`). 추론 시간이 흔들리면 1€ 필터의 `dt`도 흔들리고, 속도 추정과 컷오프가 같이 흔들린다.
- 개선: `CMSampleBufferGetPresentationTimeStamp(sampleBuffer)`를 초 단위로 바꿔 넘긴다. 워치독(`lastFrameTime`)은 지금처럼 벽시계 기준으로 둔다.
- 비용: 5줄 안팎.

### 2. 손 고정(chirality lock): 두 번째 손이 들어올 때 커서 튐 방지
- 현재: `maximumHandCount = 1`이고 결과에서 `first`를 쓴다. 다른 손이 화면에 들어오면 다른 손을 잡을 수 있다.
- 개선: `maximumHandCount = 2`로 받은 뒤 ①설정한 손(`observation.chirality`, macOS 12+, 기본 오른손)을 고르고 ②둘 다 같으면 직전 검지 위치에 가까운 손을 고른다.
- 근거: Skeleton_Engine은 손별 라우팅, mac-hand-mouse는 "선택된 손" 개념을 쓴다.

### 3. 신뢰도 기반 제스처 게이팅
- 현재: 관절 신뢰도 0.25만 넘으면 좌표를 쓴다. 엄지·검지 끝 신뢰도가 낮은 프레임(모션블러, 손가락 가림)도 그대로 핀치 판정에 들어가 오클릭이 날 수 있다.
- 개선: 클릭·우클릭 **진입** 판정에만 `thumbTip`/`indexTip`(우클릭은 `middleTip`) 신뢰도 ≥ 0.5를 요구한다. 해제와 커서 이동은 지금 그대로 둔다(누른 채로 끊기는 일 방지).

### 4. 우클릭 재무장(re-arm) 규칙
- 현재: 엄지+중지를 붙인 채 있으면 0.55초마다 우클릭이 반복된다.
- 개선: 한 번 발동하면 `middlePinchRatio`가 해제 임계값(예: 0.40)을 넘을 때까지 다시 쏘지 않는다. mac-hand-mouse의 "손을 다시 펴야 다음 우클릭" 규칙과 같다.

### 5. 전역 단축키를 등록형 핫키로 교체
- 현재: `NSEvent.addGlobalMonitorForEvents`는 손쉬운 사용 권한에 묶여 있고, 키를 가로채지 못해 앞쪽 앱에도 `⌃⌥Space`가 전달된다.
- 개선: Carbon `RegisterEventHotKey`로 등록한다. 별도 권한이 필요 없고 키 입력을 소비한다. mac-hand-mouse가 이 방식을 쓴다.

---

## P1: 조작감과 견고성

### 6. 속도 의존 게인("Steady aim")과 정밀 모드
- 문제: 지금은 ROI→화면 **절대 매핑**이다. 고감도(ROI 28%)에서는 손 1px 떨림이 화면에서 약 3.5배로 커진다. 1€ 필터가 정지 떨림은 잡지만, 작은 버튼을 노리는 느린 미세 이동도 같은 배율로 커진다.
- 개선(두 가지 중 택1, A 권장):
  - **A. 하이브리드 상대 이동**: 프레임 간 손 이동량 `d`에 macOS 포인터 가속 곡선 같은 게인 `g(|v|)`를 곱해 커서에 더한다(느리면 0.3~0.5배, 빠르면 1.5~2배). 손이 ROI 가장자리에 닿으면 절대 위치로 천천히 당겨 드리프트를 막는다.
  - **B. 절대 매핑 유지 + 저속 감쇠**: 목표점과 현재 커서의 차이에 속도 의존 계수를 곱한다. 수정 범위가 작지만 효과도 작다.
- 메뉴에 **정밀 모드**(게인 0.35배 고정) 토글을 추가한다(mac-hand-mouse와 같은 값부터 시작).
- 손을 내렸다가 다시 올리면 커서가 그 자리에서 이어지는 **클러치** 동작은 A를 택하면 따라온다.

### 7. 커서 기준점을 검지 끝 → 검지 MCP(또는 손바닥 중심)로 분리하는 실험
- 문제: 핀치하면 검지 끝 자체가 움직인다. 지금은 롤백 앵커(0.08~0.14초 전 좌표)와 감속(`gain 0.14`)으로 보정하고 있다.
- 개선: 커서는 덜 움직이는 관절(`indexMCP`, 또는 `wrist`·MCP 4개의 중심)로 조준하고, 손끝은 제스처 판정에만 쓴다. 클릭 순간 흔들림이 원리적으로 줄어 롤백 로직을 단순하게 만들 수 있다.
- 주의: 조준 감각이 달라진다. 메뉴 옵션("조준 기준점: 손끝/손 중심")으로 A/B 비교 후 기본값을 정한다.

### 8. 카메라 중단·분리 복구
- 현재: `AVCaptureSession` 중단·런타임 오류 알림을 구독하지 않는다(grep 결과 없음). 덮개를 닫았다 열거나, 다른 앱이 카메라를 점유하거나, 연속성 카메라가 끊기면 조용히 멈춘다.
- 개선: `.AVCaptureSessionWasInterrupted`, `.AVCaptureSessionInterruptionEnded`, `.AVCaptureSessionRuntimeError`, `AVCaptureDevice.wasDisconnectedNotification`을 구독하고, 오류가 나면 세션을 다시 만들고 장치가 사라지면 내장 카메라로 되돌린다. HUD에 "카메라 중단됨"을 표시한다.

### 9. 멀티 디스플레이
- 현재: `CGMainDisplayID()`만 쓴다. 외장 모니터에서는 조작할 수 없다.
- 개선: 메뉴에 "조작 화면: 주 화면 / 현재 커서가 있는 화면 / 전체 화면 묶음"을 추가한다. 디스플레이 변경은 `CGDisplayRegisterReconfigurationCallback`으로 캐시를 무효화한다(지금은 2초 폴링).

---

## P2: 튜닝 도구와 확장

### 10. 랜드마크 기록·재생 (가장 추천)
- 근거: mac-hand-mouse는 랜드마크를 기록하고 분류기에 다시 돌려 판정을 비교하는 진단 도구를 갖고 있다.
- 개선: 메뉴 "진단 기록 시작"을 누르면 프레임마다 `{t, joints, confidences}`를 JSONL로 저장한다(최대 3분). `--replay file.jsonl` 플래그로 `GestureEngine`에 다시 넣고, 실제 이벤트 주입 대신 기존 `onEventEmitted` 훅으로 클릭·드래그·스크롤 시퀀스를 출력한다.
- 효과: 임계값(`pinchThresholdEnter` 0.40, `curlThresholdEnter` 0.46 등)을 실제 손 데이터로 회귀 검증할 수 있다. 오인식 사례를 `SelfTest`의 고정 테스트 데이터로 굳힐 수 있다.
- 지금 `SelfTest.swift`는 합성 손(`makeHand`)만 쓰므로, 실제 데이터로 보완하는 효과가 크다.

### 11. 온보딩 튜토리얼 + 연습 모드
- 첫 실행 때 권한 → 제스처 5종 애니메이션 → 이벤트를 보내지 않는 연습 화면(클릭 타깃, 스크롤 영역) 순서로 안내한다.
- `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`과 투명도 줄이기 설정을 HUD에도 반영한다.

### 12. 대체 클릭 방식: 드웰(Dwell) 클릭
- 손가락 관절이 불편한 사용자를 위해, 커서를 일정 시간(0.8~1.0초) 멈추면 원형 게이지가 차고 클릭되는 모드를 추가한다(mac-hand-mouse 방식). 게이지가 찬 뒤에는 일정 거리를 움직여야 다시 무장한다.
- 기존 `ClickTriggerMode`에 `.dwell` 케이스를 하나 추가하는 정도로 들어간다.

### 13. 제스처 → 단축키·매크로 매핑 (Skeleton_Engine 방식)
- `~/Library/Application Support/VisionMouse/gestures.json`에 `{제스처: {type: keypress|shell|applescript, value, dwell_ms, cooldown_ms}}`를 둔다.
- 후보 제스처: 주먹 유지, 손바닥 펴기 유지, 엄지 올리기, 좌우 스와이프(브라우저 뒤로/앞으로, Mission Control).
- 주의: `shell` 액션은 설정 파일을 쓸 수 있는 누구나 명령을 실행하게 만든다. 넣는다면 기본값은 꺼 두고, 파일 권한(0600)을 확인한다.
- 범위가 크므로 10번(기록·재생)으로 오인식률을 확인한 뒤에 진행한다.

### 14. (보류) 학습 기반 제스처 분류기
- boostcamp 팀은 21×2 키포인트 → MLP로 4클래스를 분류했다. Create ML의 Hand Pose Classifier로 같은 일을 할 수 있다.
- 지금의 규칙 기반 판정도 히스테리시스와 연속 프레임 조건이 잘 다듬어져 있어 당장 바꿀 이유는 없다. 10번으로 데이터가 쌓이고 규칙으로 못 잡는 오인식이 남을 때 다시 검토한다.

---

## 제안 진행 순서

1. **P0 1~5**: 하루 이내. 각각 독립 커밋.
2. **10 기록·재생**: 이후 모든 튜닝의 기준 데이터가 된다.
3. **6 속도 의존 게인** → **7 기준점 실험**: 10의 기록으로 전후를 비교한다.
4. **8, 9 견고성** → **11, 12 접근성** → **13 매핑**.

## 참고
- diegocp01/mac-hand-mouse: Steady aim·정밀 모드(0.35배), 드웰 클릭, 재무장 규칙, 세션 재구성, 진단 기록·재생, 등록형 핫키
- L-ubu/Skeleton_Engine: JSON 제스처→액션 매핑, dwell/cooldown, 연속 채널(볼륨·밝기), 핫 리로드
- Reene444/air-mouse-control: 손가락 굽힘으로 커서 위치 잠금, 가장자리 가속
- bhavyavashisth/HandTrack-MacControl: 창 버튼 근처 감속(정밀 모드)
- boostcampaitech3/final-project-level3-cv-13: 키포인트 MLP 제스처 분류기
