import Foundation
import CoreGraphics
import AppKit

enum SensitivityLevel: String, CaseIterable {
    case veryHigh = "초고감도 (손가락만 살짝)"
    case high = "고감도 (작은 손 움직임)"
    case normal = "보통 (권장)"
    case low = "저감도 (넓게 정밀 조작)"
}

enum GestureState: String {
    case idle = "대기 중"
    case pointing = "포인팅"
    case thumbTouching = "클릭 중 (엄지 붙임)"
    case dragging = "드래그 중"
    case scrolling = "스크롤 중"
    case noHand = "손 감지 안됨"
}

struct EmittedMouseEvent {
    enum Kind: Equatable {
        case move(dx: CGFloat, dy: CGFloat)
        case leftDown(clicks: Int)
        case leftUp(clicks: Int)
        case leftDragged(dx: CGFloat, dy: CGFloat)
        case scroll(dx: Int32, dy: Int32)
        case scrollBegan
        case scrollEnded
    }
    let kind: Kind
    let point: CGPoint
    let timestamp: CFAbsoluteTime
}

protocol GestureEngineDelegate: AnyObject {
    func gestureEngine(_ engine: GestureEngine, didChangeState state: GestureState, point: CGPoint, pinchRatio: CGFloat?)
}

final class GestureEngine {
    weak var delegate: GestureEngineDelegate?

    /// 자동화 테스트 및 이벤트 검증용 훅 (운영 시 nil)
    var onEventEmitted: ((EmittedMouseEvent) -> Void)?
    /// 스크롤 진단 로그 훅 (CSV 한 줄씩). nil이면 기록 안 함. lock 안에서 호출되므로 받는 쪽은 비동기로 써야 함.
    var scrollDebugLog: ((String) -> Void)?
    /// 자동화 테스트 중 실제 OS 커서 이동/클릭 주입을 막고자 할 때 true로 설정
    var suppressSystemEvents: Bool = false

    // 포인터 감도 설정 (기본: 보통)
    var sensitivity: SensitivityLevel = .normal {
        didSet {
            lock.lock()
            applySensitivityLocked(sensitivity)
            lock.unlock()
        }
    }

    // ROI (손의 유효 활동 영역)
    private(set) var roiMinX: CGFloat = 0.20
    private(set) var roiMaxX: CGFloat = 0.80
    private(set) var roiMinY: CGFloat = 0.20
    private(set) var roiMaxY: CGFloat = 0.80

    var currentROIRect: CGRect {
        lock.lock()
        defer { lock.unlock() }
        return CGRect(x: roiMinX, y: roiMinY, width: roiMaxX - roiMinX, height: roiMaxY - roiMinY)
    }

    // 엄지 붙이기 클릭 임계값 (엄지 끝 ~ 검지 꺾은선 거리 / palmScale; L자로 벌림 ~0.6+, 검지에 붙임 <0.25)
    // shortcut: 합성 손 기준 초기값, 실제 손 기록(IMPROVEMENTS #10)으로 보정 필요
    var thumbTouchEnter: CGFloat = 0.25
    var thumbTouchExit: CGFloat = 0.40
    var thumbTouchApproach: CGFloat = 0.50

    /// 클릭 진입 판정에 필요한 엄지 끝 최소 신뢰도 (모션블러·가림 프레임의 오클릭 방지)
    var minClickConfidence: Float = 0.5

    // 시간 기반 확정: 프레임 수만 세면 30fps와 60fps에서 체감 시간이 2배 차이 나므로 "N프레임 그리고 최소 시간"을 함께 요구
    var armMinDuration: CFAbsoluteTime = 0.12        // 엄지를 벌린 상태가 이만큼 이어져야 클릭 무장
    var touchConfirmDuration: CFAbsoluteTime = 0.05  // 엄지 붙임이 이만큼 이어져야 누름 (한 프레임짜리 오인식 차단)
    var scrollConfirmDuration: CFAbsoluteTime = 0.10 // 스크롤 자세가 이만큼 이어져야 스크롤 시작
    var maxFrameGap: CFAbsoluteTime = 0.12           // 프레임이 이보다 오래 끊기면 진행 중이던 확정 단계를 처음부터
    private var thumbOpenSince: CFAbsoluteTime = 0.0
    private var touchStreak = 0
    private var touchSince: CFAbsoluteTime = 0.0
    private var scrollMatchSince: CFAbsoluteTime = 0.0

    // 드래그 진입 거리 (손 크기 palmScale 단위; 화면 해상도·감도와 무관)
    var dragStartDistance: CGFloat = 0.25      // 0.35초 이상 유지 + 이 거리
    var dragStartDistanceSlow: CGFloat = 0.15  // 0.55초 이상 유지 + 이 거리
    private var pressStartHand: CGPoint = .zero

    // 재앵커: 스크롤이 끝나거나 손을 다시 잡을 때 커서는 그 자리에 두고 손↔화면 매핑에 오프셋을 둔다.
    // 오프셋은 손을 움직일수록 0으로 줄어 손과 화면 위치가 영구히 어긋나지 않게 한다.
    private var cursorOffset: CGVector = .zero
    private var needsReanchor = false
    private var lastRawNoOffset: CGPoint?
    /// 손(화면 환산)이 이 거리(px)만큼 움직이면 오프셋이 1/e로 줄어듦
    var reanchorDecayDistance: CGFloat = 500.0

    /// true면 커서 Y를 검지 끝 40% + 검지 MCP 60%로 섞어, 엄지가 검지를 밀 때 생기는 커서 흔들림을 줄인다
    var aimBlendKnuckle: Bool = false

    // HUD 피드백용: 클릭 무장 여부와 엄지가 검지에 다가간 정도(0~1, 누름 중이면 1)
    private var _clickProgress: CGFloat = 0.0
    var clickFeedback: (armed: Bool, progress: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        return (isThumbArmed, _clickProgress)
    }

    // 스크롤 상태 및 서브픽셀 누적기
    private var isScrolling = false
    private var scrollMatchStreak = 0
    private var lastScrollValidTime: CFAbsoluteTime = 0.0
    // 조이스틱 스크롤: 스크롤 자세를 취한 순간의 손 위치가 기준점, 기준점에서 벗어난 방향·거리로 속도 결정
    private var scrollAnchorHand: CGPoint?
    private var scrollScale: CGFloat?   // 스크롤 시작 시점의 손 크기 고정 (매 프레임 palmScale 흔들림이 속도로 새지 않게)
    private var scrollVelocity: CGVector = .zero      // px/s 목표 속도 (dx: 가로 wheel2, dy: 세로 wheel1), 카메라 프레임마다 갱신
    private var scrollVelocitySmoothed: CGVector = .zero  // 240Hz tick에서 목표 속도로 부드럽게 수렴하는 실제 속도
    private var scrollGestureActive = false           // 트랙패드처럼 began → changed → ended 단계를 보냈는지
    /// 목표 속도로 수렴하는 시간 상수 (초). 30fps 속도 계단과 손떨림을 흡수.
    var scrollEaseTime: CFAbsoluteTime = 0.08
    private var scrollRemainder: CGVector = .zero
    private var lastScrollTickTime: CFAbsoluteTime = 0.0
    private var scrollCursorPoint: CGPoint = .zero
    private let scrollFilterX = OneEuro(minCutoff: 1.5, beta: 0.05)
    private let scrollFilterY = OneEuro(minCutoff: 1.5, beta: 0.05)
    /// 기준점 주변 정지 구간 (손 크기 palmScale 단위)
    var scrollDeadZone: CGFloat = 0.25
    /// 정지 구간을 1 palm 넘었을 때의 속도 (px/s)
    var scrollSpeedGain: CGFloat = 1600.0
    var scrollMaxSpeed: CGFloat = 4000.0

    // 마우스 상태 & 240Hz 보간 엔진 (lock으로 보호)
    private let lock = NSLock()
    private var targetPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var isMoving = false
    private var hasSentSettledEvent = false
    private var isApproachingClick = false
    private var postClickFreezeUntil: CFAbsoluteTime = 0.0

    private(set) var isPressed = false
    private var isDragging = false
    /// 손이 처음부터 엄지를 검지에 붙인 채 진입했을 때 오클릭을 막기 위한 무장 플래그 (엄지가 펴진 게 확인돼야 무장)
    private var isThumbArmed = false
    private var thumbOpenStreak = 0
    private var pressStartTime: CFAbsoluteTime = 0.0
    private var lastFrameTime: CFAbsoluteTime = 0.0
    private var pressAnchorPoint: CGPoint = .zero

    // 더블/트리플 클릭 카운터
    private var lastClickTime: CFAbsoluteTime = 0.0
    private var lastClickPoint: CGPoint = .zero
    private var clickCount: Int = 0

    // 히스토리 버퍼 (최근 0.6초)
    private var history: [(t: CFAbsoluteTime, p: CGPoint)] = []
    private var cleanHoverHistory: [(t: CFAbsoluteTime, p: CGPoint)] = []

    private var lastCursorPoint: CGPoint = .zero
    private var _currentState: GestureState = .noHand
    var currentState: GestureState {
        lock.lock()
        defer { lock.unlock() }
        return _currentState
    }

    // 디스플레이 캐시
    private var cachedMainBounds: CGRect = CGDisplayBounds(CGMainDisplayID())
    private var lastDisplayCacheTime: CFAbsoluteTime = 0.0

    // CGEventSource: Warp 후 0.25초 이벤트 억제(suppression) 현상 제거
    private let eventSource: CGEventSource? = {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0.0
        return src
    }()

    // 필터
    private let filterX = OneEuro(minCutoff: 1.4, beta: 0.032)
    private let filterY = OneEuro(minCutoff: 1.4, beta: 0.032)

    private var _isEnabled: Bool = true
    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set {
            lock.lock()
            let changed = (_isEnabled != newValue)
            _isEnabled = newValue
            lock.unlock()
            if changed && !newValue {
                releaseAll()
            }
        }
    }

    init(startInterpolator: Bool = true) {
        if startInterpolator {
            startInterpolationThread()
        }
    }

    private func applySensitivityLocked(_ level: SensitivityLevel) {
        switch level {
        case .veryHigh:
            roiMinX = 0.36; roiMaxX = 0.64
            roiMinY = 0.36; roiMaxY = 0.64
            filterX.beta = 0.050; filterY.beta = 0.050
        case .high:
            roiMinX = 0.28; roiMaxX = 0.72
            roiMinY = 0.28; roiMaxY = 0.72
            filterX.beta = 0.040; filterY.beta = 0.040
        case .normal:
            roiMinX = 0.20; roiMaxX = 0.80
            roiMinY = 0.20; roiMaxY = 0.80
            filterX.beta = 0.032; filterY.beta = 0.032
        case .low:
            roiMinX = 0.10; roiMaxX = 0.90
            roiMinY = 0.10; roiMaxY = 0.90
            filterX.beta = 0.020; filterY.beta = 0.020
        }
    }

    /// 240Hz 고주사율 디스플레이 보간 스레드
    private func startInterpolationThread() {
        let th = Thread { [weak self] in
            while true {
                guard let self = self else { return }
                self.tick()

                self.lock.lock()
                let idle = !self.isMoving && !self.isPressed && !self.isScrolling
                self.lock.unlock()

                usleep(idle ? 16_666 : 4_166)
            }
        }
        th.name = "com.aimmac.VisionMouse.interpolator"
        th.qualityOfService = .userInteractive
        th.start()
    }

    func tick(nowOverride: CFAbsoluteTime? = nil) {
        lock.lock()
        let now = nowOverride ?? CFAbsoluteTimeGetCurrent()

        // Fail-safe 워치독: 프레임 입력이 1.2초 이상 끊기거나 25초 이상 눌려 있으면 자동 해제
        if isPressed {
            if (lastFrameTime > 0 && now - lastFrameTime > 1.2) || (now - pressStartTime > 25.0) {
                let wasDragging = isDragging
                let releasePt = wasDragging ? (currentPoint ?? lastCursorPoint) : pressAnchorPoint
                isPressed = false
                isDragging = false
                lock.unlock()
                if wasDragging {
                    postMouseUp(at: releasePt, clicks: 1)
                }
                return
            }
        }

        // 클릭 대기(탭) 중이거나 클릭 직후 쿨다운(0.10초) 동안은 앵커 포인트에 커서 고정
        if (isPressed && !isDragging) || (now < postClickFreezeUntil) {
            lock.unlock()
            return
        }

        // 조이스틱 스크롤: 240Hz로 속도 × 경과시간만큼 서브픽셀 누적 후 배출 (카메라 30fps여도 부드럽게)
        if isScrolling {
            let dt = lastScrollTickTime > 0 ? min(max(now - lastScrollTickTime, 0), 0.05) : 0
            lastScrollTickTime = now
            // 프레임이 0.25초 이상 끊기면 마지막 속도로 계속 흘러가지 않게 정지
            let target = (lastFrameTime > 0 && now - lastFrameTime > 0.25) ? .zero : scrollVelocity
            // 지수 수렴: 카메라 프레임마다 바뀌는 목표 속도를 240Hz로 부드럽게 따라감
            let k = dt > 0 ? CGFloat(1 - exp(-dt / scrollEaseTime)) : 0
            let v = CGVector(dx: scrollVelocitySmoothed.dx + (target.dx - scrollVelocitySmoothed.dx) * k,
                             dy: scrollVelocitySmoothed.dy + (target.dy - scrollVelocitySmoothed.dy) * k)
            scrollVelocitySmoothed = v
            let rx = scrollRemainder.dx + v.dx * CGFloat(dt)
            let ry = scrollRemainder.dy + v.dy * CGFloat(dt)
            let sx = Int32(rx.rounded(.towardZero))
            let sy = Int32(ry.rounded(.towardZero))
            scrollRemainder = CGVector(dx: rx - CGFloat(sx), dy: ry - CGFloat(sy))
            scrollDebugLog?(String(format: "tick,%.4f,%.4f,%.1f,%.1f,%d,%d", now, dt, v.dx, v.dy, sx, sy))
            if sx != 0 || sy != 0 {
                // lock 안에서 보내 ended 이후에 changed가 끼어드는 순서 역전을 막는다 (post는 비차단)
                let phase: CGScrollPhase = scrollGestureActive ? .changed : .began
                scrollGestureActive = true
                postScroll(dx: sx, dy: sy, phase: phase, at: scrollCursorPoint)
            }
            lock.unlock()
            return
        }

        guard _isEnabled, let t = targetPoint else {
            lock.unlock()
            return
        }

        var c = currentPoint ?? t
        let dx = t.x - c.x
        let dy = t.y - c.y

        // 커서가 목표 지점에 거의 도달한 경우 (정지 상태)
        if abs(dx) < 0.25 && abs(dy) < 0.25 && currentPoint != nil {
            isMoving = false
            let settledNeeded = !hasSentSettledEvent
            hasSentSettledEvent = true
            lock.unlock()

            // 멈췄을 때 1회의 정지 마우스 이벤트를 전송하여 브라우저가 하이퍼링크 위에서 손모양(pointer) 커서로 갱신하도록 유도
            if settledNeeded {
                postMouseMoved(at: c, dx: 0, dy: 0)
            }
            return
        }

        isMoving = true
        hasSentSettledEvent = false
        // 핀치/접기 직전 손가락이 오므라드는 구간에서는 보간 계수를 낮춰 하이퍼링크 위에서 커서가 밀리지 않도록 브레이킹
        let gain: CGFloat = (isApproachingClick && !isDragging) ? 0.14 : 0.50
        let stepX = dx * gain
        let stepY = dy * gain
        c.x += stepX
        c.y += stepY
        currentPoint = c
        let dragging = isDragging
        lock.unlock()

        if dragging {
            postMouseDragged(at: c, dx: stepX, dy: stepY)
        } else {
            warpCursor(to: c)
            postMouseMoved(at: c, dx: stepX, dy: stepY)
        }
    }

    private func mainDisplayBounds(now: CFAbsoluteTime) -> CGRect {
        if now - lastDisplayCacheTime > 2.0 || cachedMainBounds.width <= 0 {
            cachedMainBounds = CGDisplayBounds(CGMainDisplayID())
            lastDisplayCacheTime = now
        }
        return cachedMainBounds
    }

    func process(hand: HandPoseData?) {
        lock.lock()
        let enabled = _isEnabled
        if !enabled {
            let pt = lastCursorPoint
            lock.unlock()
            updateState(.idle, point: pt, ratio: nil)
            return
        }

        guard let hand = hand, hand.isValid, let indexTip = hand.indexTip, hand.thumbTip != nil else {
            let wasPressed = isPressed
            let wasDragging = isDragging
            let releasePt = wasDragging ? (currentPoint ?? lastCursorPoint) : pressAnchorPoint
            isPressed = false
            isDragging = false
            isScrolling = false
            isThumbArmed = false
            thumbOpenStreak = 0
            touchStreak = 0
            scrollMatchStreak = 0
            _clickProgress = 0
            isApproachingClick = false
            filterX.reset()
            filterY.reset()
            resetScrollLocked()
            // 손을 다시 잡으면 커서가 손 위치로 점프하지 않고 그 자리에서 이어지도록
            needsReanchor = true
            lastRawNoOffset = nil
            let pt = lastCursorPoint
            lock.unlock()

            if wasPressed && wasDragging {
                postMouseUp(at: releasePt, clicks: 1)
            }
            updateState(.noHand, point: pt, ratio: nil)
            return
        }

        let now = hand.timestamp > 0 ? hand.timestamp : CFAbsoluteTimeGetCurrent()
        if lastFrameTime > 0 && now - lastFrameTime > maxFrameGap {
            // 프레임이 끊겼다 돌아오면 이전 프레임과 연속으로 보지 않고 확정 단계를 처음부터
            thumbOpenStreak = 0
            touchStreak = 0
            scrollMatchStreak = 0
        }
        lastFrameTime = now

        // 1. 거울 반전 및 상하 반전 (조준 Y는 옵션에 따라 검지 끝과 MCP를 섞음)
        var aimY = indexTip.y
        if aimBlendKnuckle, let mcp = hand.indexMCP {
            aimY = indexTip.y * 0.4 + mcp.y * 0.6
        }
        let mirrorX = 1.0 - indexTip.x
        let invertY = 1.0 - aimY

        // 2. Active ROI 매핑
        let clampedX = min(max((mirrorX - roiMinX) / (roiMaxX - roiMinX), 0.0), 1.0)
        let clampedY = min(max((invertY - roiMinY) / (roiMaxY - roiMinY), 0.0), 1.0)

        // 3. OneEuro 필터
        let smoothX = filterX.filter(Double(clampedX), t: now)
        let smoothY = filterY.filter(Double(clampedY), t: now)

        // 4. 화면 좌표 매핑
        let screen = mainDisplayBounds(now: now)
        let rawNoOffset = CGPoint(x: screen.origin.x + CGFloat(smoothX) * screen.width,
                                  y: screen.origin.y + CGFloat(smoothY) * screen.height)
        if needsReanchor {
            needsReanchor = false
            if let cur = currentPoint {
                cursorOffset = CGVector(dx: cur.x - rawNoOffset.x, dy: cur.y - rawNoOffset.y)
            }
        } else if let last = lastRawNoOffset, cursorOffset != .zero {
            let moved = hypot(rawNoOffset.x - last.x, rawNoOffset.y - last.y)
            let k = CGFloat(exp(-Double(moved / reanchorDecayDistance)))
            cursorOffset = CGVector(dx: cursorOffset.dx * k, dy: cursorOffset.dy * k)
            if abs(cursorOffset.dx) < 0.5 && abs(cursorOffset.dy) < 0.5 { cursorOffset = .zero }
        }
        lastRawNoOffset = rawNoOffset
        var rawTarget = CGPoint(x: min(max(rawNoOffset.x + cursorOffset.dx, screen.minX), screen.maxX - 1),
                                y: min(max(rawNoOffset.y + cursorOffset.dy, screen.minY), screen.maxY - 1))
        lastCursorPoint = rawTarget

        let thumbRatio = hand.thumbIndexRatio ?? 1.0
        // 신뢰도 게이트는 클릭 '진입'에만 적용. 해제·이동은 그대로 두어 누른 채 끊기는 일을 막는다.
        let thumbReliable = hand.confidence(.thumbTip) >= minClickConfidence

        // 엄지를 벌린 상태가 3프레임 이상 그리고 armMinDuration 이상 이어지면 클릭 무장
        if thumbRatio >= thumbTouchExit {
            if thumbOpenStreak == 0 { thumbOpenSince = now }
            thumbOpenStreak += 1
            if thumbOpenStreak >= 3 && now - thumbOpenSince >= armMinDuration - 1e-6 {
                isThumbArmed = true
            }
        } else if thumbRatio < thumbTouchEnter {
            thumbOpenStreak = 0
        }

        // 엄지 붙임이 2프레임 이상 그리고 touchConfirmDuration 이상 이어져야 누름으로 확정
        if thumbRatio < thumbTouchEnter {
            if touchStreak == 0 { touchSince = now }
            touchStreak += 1
        } else {
            touchStreak = 0
        }
        let touchConfirmed = touchStreak >= 2 && now - touchSince >= touchConfirmDuration - 1e-6

        // 엄지가 검지로 다가오는 중인지 여부 (커서 브레이킹 및 클린 호버 히스토리 분리용)
        isApproachingClick = isThumbArmed && thumbRatio < thumbTouchApproach
        if isPressed {
            _clickProgress = 1
        } else if isThumbArmed {
            let span = max(thumbTouchApproach - thumbTouchEnter, 0.01)
            _clickProgress = min(max((thumbTouchApproach - thumbRatio) / span, 0), 1)
        } else {
            _clickProgress = 0
        }

        // 히스토리 버퍼 업데이트 (최근 0.6초)
        let recordedPoint = currentPoint ?? rawTarget
        history.append((now, recordedPoint))
        if history.count > 60 || (history.first.map { now - $0.t > 0.6 } ?? false) {
            history.removeAll { now - $0.t > 0.6 }
        }
        if !isApproachingClick && !isPressed && !isScrolling {
            cleanHoverHistory.append((now, recordedPoint))
            if cleanHoverHistory.count > 60 || (cleanHoverHistory.first.map { now - $0.t > 0.6 } ?? false) {
                cleanHoverHistory.removeAll { now - $0.t > 0.6 }
            }
        }

        // 5. 제스처 판정

        // B. 두 손가락 조이스틱 스크롤 (검지+중지 나란히 펴고 약지+새끼 접은 자세 = 스크롤 모드)
        //    자세를 취한 순간의 손 위치가 기준점. 손을 옮긴 방향으로, 멀리 옮길수록 빠르게 스크롤.
        let scrollPoseMatched = hand.isTwoFingerScrollPose(currentlyScrolling: isScrolling)
        if scrollPoseMatched {
            if scrollMatchStreak == 0 { scrollMatchSince = now }
            scrollMatchStreak += 1
        } else {
            scrollMatchStreak = 0
        }
        let withinScrollGrace = isScrolling && (now - lastScrollValidTime < 0.06)
        let scrollConfirmed = scrollMatchStreak >= 3 && now - scrollMatchSince >= scrollConfirmDuration - 1e-6
        let shouldScroll = (isScrolling && (scrollPoseMatched || withinScrollGrace)) || (!isScrolling && scrollConfirmed)

        if shouldScroll && !isDragging {
            if !isScrolling {
                resetScrollLocked()
                scrollCursorPoint = currentPoint ?? rawTarget
            }
            if scrollPoseMatched {
                lastScrollValidTime = now
            }
            // 스크롤 자세 진입 직전에 엄지 붙임으로 아직 드래그 전인 isPressed가 걸렸다면 즉시 해제 (mouseDown은 아직 안 나감)
            if isPressed && !isDragging {
                isPressed = false
            }
            isScrolling = true

            // 손 기준점: 검지·중지 MCP 중점 (손가락 끝 떨림과 무관한 손 전체 위치). 거울 반전 + 종횡비 보정 좌표.
            let ref = hand.scrollReferencePoint ?? indexTip
            let hx = CGFloat(scrollFilterX.filter(Double((1.0 - ref.x) * hand.aspectRatio), t: now))
            let hy = CGFloat(scrollFilterY.filter(Double(ref.y), t: now))
            if scrollAnchorHand == nil {
                scrollAnchorHand = CGPoint(x: hx, y: hy)
                scrollScale = hand.palmScale
            }
            let anchorHand = scrollAnchorHand!
            let scale = scrollScale ?? hand.palmScale
            let offset = CGVector(dx: (hx - anchorHand.x) / scale, dy: (hy - anchorHand.y) / scale)
            scrollVelocity = GestureEngine.joystickScrollVelocity(
                offset: offset, deadZone: scrollDeadZone, gain: scrollSpeedGain, maxSpeed: scrollMaxSpeed)
            scrollDebugLog?(String(format: "frame,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,%.1f",
                                   now, ref.x, ref.y, hand.palmScale, offset.dx, offset.dy, scrollVelocity.dx, scrollVelocity.dy))
            let speedRatio = hypot(scrollVelocity.dx, scrollVelocity.dy) / scrollMaxSpeed
            let pt = scrollCursorPoint
            lock.unlock()

            updateState(.scrolling, point: pt, ratio: speedRatio)
            return
        }

        if isScrolling {
            isScrolling = false
            resetScrollLocked()
            // 스크롤 중 손이 기준점에서 벗어나 있으므로, 커서를 스크롤하던 자리에 그대로 두도록 즉시 재앵커
            let cur = scrollCursorPoint
            cursorOffset = CGVector(dx: cur.x - rawNoOffset.x, dy: cur.y - rawNoOffset.y)
            rawTarget = cur
            lastCursorPoint = cur
        }

        // C. 좌클릭 / 드래그 판정: 엄지를 검지에 붙이면 누름, 벌리면 뗌
        // 스크롤 자세(검지+중지 밀착 폄) 중에는 엄지가 검지에 붙어 있어도 클릭하지 않음
        let clickTriggered = isThumbArmed && thumbReliable && !scrollPoseMatched && touchConfirmed

        if !isPressed {
            // 미누름 상태
            if clickTriggered {
                isPressed = true
                isDragging = false
                pressStartTime = now
                pressStartHand = CGPoint(x: (1.0 - indexTip.x) * hand.aspectRatio, y: indexTip.y)

                // 엄지를 붙이기 직전의 안정된 호버 좌표를 앵커로 선택 (엄지가 검지를 밀어 생기는 흔들림 제거)
                // 확정 대기(touchConfirmDuration)만큼 늦게 눌리므로, 엄지가 처음 붙은 시점 기준으로 되돌아본다
                let rollbackTime = touchSince - 0.05
                let anchor = cleanHoverHistory.last(where: { $0.t <= rollbackTime })?.p
                    ?? cleanHoverHistory.last?.p
                    ?? history.last(where: { $0.t <= rollbackTime })?.p
                    ?? currentPoint
                    ?? rawTarget

                pressAnchorPoint = anchor
                targetPoint = anchor
                currentPoint = anchor
                lock.unlock()

                // 앵커 위치로 커서를 옮기고 hover(mouseMoved)만 먼저 보장.
                // 실제 leftMouseDown은 짧은 탭 릴리즈 시점 또는 드래그 확정 시점에 주입하여 하이퍼링크 클릭 씹힘을 원천 방지!
                warpCursor(to: anchor)
                postMouseMoved(at: anchor, dx: 0, dy: 0)
                updateState(.thumbTouching, point: anchor, ratio: thumbRatio)
            } else {
                // 일반 포인팅 이동
                if now >= postClickFreezeUntil {
                    targetPoint = rawTarget
                    if currentPoint == nil {
                        currentPoint = rawTarget
                    }
                }
                let displayPt = (now < postClickFreezeUntil) ? pressAnchorPoint : rawTarget
                lock.unlock()
                updateState(.pointing, point: displayPt, ratio: thumbRatio)
            }
        } else {
            // 이미 엄지를 붙인(홀드) 상태
            let releaseCondition = thumbRatio > thumbTouchExit
            let elapsed = now - pressStartTime
            // 롤백된 pressAnchorPoint가 아니라 누른 시점의 검지 위치 대비 손 이동량(palm 단위)으로 드래그 판정
            let handMoveDist = hypot((1.0 - indexTip.x) * hand.aspectRatio - pressStartHand.x,
                                     indexTip.y - pressStartHand.y) / hand.palmScale

            if releaseCondition {
                isPressed = false
                let wasDragging = isDragging
                isDragging = false
                let anchor = pressAnchorPoint
                let dragReleasePt = currentPoint ?? rawTarget

                if !wasDragging {
                    // 일반 클릭 / 더블클릭: 앵커 포인트에서 흔들림 없이 Down + Up 즉시 발생
                    let clicks = nextClickCountLocked(at: anchor, now: now)
                    postClickFreezeUntil = now + 0.10
                    targetPoint = anchor
                    currentPoint = anchor
                    lock.unlock()

                    warpCursor(to: anchor)
                    postMouseMoved(at: anchor, dx: 0, dy: 0)
                    postMouseDown(at: anchor, clicks: clicks)
                    postMouseUp(at: anchor, clicks: clicks)
                    updateState(.pointing, point: anchor, ratio: thumbRatio)
                } else {
                    // 드래그 종료: 현재 위치에서 MouseUp
                    targetPoint = rawTarget
                    currentPoint = dragReleasePt
                    lock.unlock()

                    postMouseUp(at: dragReleasePt, clicks: 1)
                    updateState(.pointing, point: dragReleasePt, ratio: thumbRatio)
                }
            } else {
                // 엄지를 붙인 채 이동하면 드래그 진입 (0.35초 + 0.25 palm, 또는 0.55초 + 0.15 palm)
                var justStartedDragging = false
                if !isDragging && ((elapsed > 0.35 && handMoveDist > dragStartDistance)
                                   || (elapsed > 0.55 && handMoveDist > dragStartDistanceSlow)) {
                    isDragging = true
                    justStartedDragging = true
                }

                let draggingNow = isDragging
                let anchor = pressAnchorPoint
                if draggingNow {
                    targetPoint = rawTarget
                }
                lock.unlock()

                if justStartedDragging {
                    // 드래그가 확정된 순간 앵커 지점에서 leftMouseDown을 먼저 시작
                    warpCursor(to: anchor)
                    postMouseDown(at: anchor, clicks: 1)
                }

                if draggingNow {
                    updateState(.dragging, point: rawTarget, ratio: thumbRatio)
                } else {
                    updateState(.thumbTouching, point: anchor, ratio: thumbRatio)
                }
            }
        }
    }

    private func nextClickCountLocked(at p: CGPoint, now: CFAbsoluteTime) -> Int {
        let maxInterval = NSEvent.doubleClickInterval
        if now - lastClickTime < maxInterval && hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 16.0 {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickPoint = p
        return clickCount
    }

    // MARK: - Mouse Event Injections

    private func emit(_ kind: EmittedMouseEvent.Kind, at point: CGPoint) {
        onEventEmitted?(EmittedMouseEvent(kind: kind, point: point, timestamp: CFAbsoluteTimeGetCurrent()))
    }

    private func warpCursor(to point: CGPoint) {
        guard !suppressSystemEvents else { return }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func postMouseDown(at point: CGPoint, clicks: Int) {
        emit(.leftDown(clicks: clicks), at: point)
        guard !suppressSystemEvents else { return }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        ev.post(tap: .cghidEventTap)
    }

    private func postMouseUp(at point: CGPoint, clicks: Int) {
        emit(.leftUp(clicks: clicks), at: point)
        guard !suppressSystemEvents else { return }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        ev.post(tap: .cghidEventTap)
    }

    private func postMouseDragged(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        emit(.leftDragged(dx: dx, dy: dy), at: point)
        guard !suppressSystemEvents else { return }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        ev.setDoubleValueField(.mouseEventDeltaX, value: Double(dx))
        ev.setDoubleValueField(.mouseEventDeltaY, value: Double(dy))
        ev.post(tap: .cghidEventTap)
    }

    private func postMouseMoved(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        emit(.move(dx: dx, dy: dy), at: point)
        guard !suppressSystemEvents else { return }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setDoubleValueField(.mouseEventDeltaX, value: Double(dx))
        ev.setDoubleValueField(.mouseEventDeltaY, value: Double(dy))
        ev.post(tap: .cghidEventTap)
    }

    /// 트랙패드와 같은 단계(began/changed/ended)를 실은 픽셀 스크롤. 단계가 없으면 브라우저 등이 이벤트마다
    /// 자체 휠 애니메이션을 걸어 끊겨 보인다. wheel1 = 세로(+위), wheel2 = 가로(+왼쪽).
    private func postScroll(dx: Int32, dy: Int32, phase: CGScrollPhase, at point: CGPoint) {
        if phase == .began { emit(.scrollBegan, at: point) }
        if phase == .ended { emit(.scrollEnded, at: point) } else { emit(.scroll(dx: dx, dy: dy), at: point) }
        guard !suppressSystemEvents else { return }
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        ev.location = point
        ev.post(tap: .cghidEventTap)
    }

    private func resetScrollLocked() {
        if scrollGestureActive {
            postScroll(dx: 0, dy: 0, phase: .ended, at: scrollCursorPoint)
        }
        scrollGestureActive = false
        scrollFilterX.reset()
        scrollFilterY.reset()
        scrollAnchorHand = nil
        scrollScale = nil
        scrollVelocity = .zero
        scrollVelocitySmoothed = .zero
        scrollRemainder = .zero
        lastScrollTickTime = 0.0
    }

    /// 조이스틱 스크롤 속도 (px/s). offset: 기준점 대비 손 이동량(palm 단위, x = 사용자 기준 오른쪽, y = 위).
    /// 반환: dx = 가로 휠(wheel2, +왼쪽), dy = 세로 휠(wheel1, +위). 손을 올리면 위로, 오른쪽으로 옮기면 오른쪽 내용이 보이도록.
    static func joystickScrollVelocity(offset: CGVector, deadZone: CGFloat, gain: CGFloat, maxSpeed: CGFloat) -> CGVector {
        var ox = offset.dx, oy = offset.dy
        // 주축 스냅: 한 축이 다른 축의 절반도 안 되면 버려서 세로 스크롤 중 가로로 새는 것 방지
        if abs(ox) < abs(oy) * 0.5 { ox = 0 }
        if abs(oy) < abs(ox) * 0.5 { oy = 0 }
        let mag = hypot(ox, oy)
        let excess = hypot(offset.dx, offset.dy) - deadZone
        guard mag > 0, excess > 0 else { return .zero }
        // 정지 구간을 넘은 거리에 지수 1.6을 적용해 가까이서는 미세하게, 멀리서는 빠르게
        let speed = min(maxSpeed, gain * pow(excess, 1.6))
        return CGVector(dx: -speed * ox / mag, dy: speed * oy / mag)
    }

    func releaseAll() {
        lock.lock()
        let wasPressed = isPressed
        let wasDragging = isDragging
        let releasePt = wasDragging ? (currentPoint ?? lastCursorPoint) : pressAnchorPoint
        isPressed = false
        isDragging = false
        isScrolling = false
        isThumbArmed = false
        thumbOpenStreak = 0
        touchStreak = 0
        scrollMatchStreak = 0
        _clickProgress = 0
        cursorOffset = .zero
        needsReanchor = false
        lastRawNoOffset = nil
        isApproachingClick = false
        targetPoint = nil
        currentPoint = nil
        isMoving = false
        hasSentSettledEvent = false
        history.removeAll()
        cleanHoverHistory.removeAll()
        filterX.reset()
        filterY.reset()
        resetScrollLocked()
        lock.unlock()

        if wasPressed && wasDragging {
            postMouseUp(at: releasePt, clicks: 1)
        }
    }

    private func updateState(_ state: GestureState, point: CGPoint, ratio: CGFloat?) {
        lock.lock()
        _currentState = state
        lock.unlock()
        delegate?.gestureEngine(self, didChangeState: state, point: point, pinchRatio: ratio)
    }
}
