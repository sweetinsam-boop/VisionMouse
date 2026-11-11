import Foundation
import CoreGraphics
import AppKit

enum ClickTriggerMode: String, CaseIterable {
    case both = "둘 다 허용 (약지 접기 + 엄지·검지 핀치, 권장)"
    case fingerCurl = "약지+새끼 접기 전용 (커서 흔들림 제로)"
    case pinch = "엄지+검지 핀치 전용 (기존 꼬집기)"
}

enum SensitivityLevel: String, CaseIterable {
    case veryHigh = "초고감도 (손가락만 살짝)"
    case high = "고감도 (작은 손 움직임)"
    case normal = "보통 (권장)"
    case low = "저감도 (넓게 정밀 조작)"
}

enum GestureState: String {
    case idle = "대기 중"
    case pointing = "포인팅"
    case pinching = "클릭 중 (핀치)"
    case fingerCurled = "클릭 중 (약지 접음)"
    case dragging = "드래그 중"
    case rightClicking = "우클릭"
    case scrolling = "스크롤 중"
    case noHand = "손 감지 안됨"
}

struct EmittedMouseEvent {
    enum Kind: Equatable {
        case move(dx: CGFloat, dy: CGFloat)
        case leftDown(clicks: Int)
        case leftUp(clicks: Int)
        case leftDragged(dx: CGFloat, dy: CGFloat)
        case rightDown
        case rightUp
        case scroll(pixelDeltaY: Int32)
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
    /// 자동화 테스트 중 실제 OS 커서 이동/클릭 주입을 막고자 할 때 true로 설정
    var suppressSystemEvents: Bool = false

    // 클릭 방식 설정 (기본: 약지 접기 + 엄지·검지 핀치 모두 허용)
    var clickTriggerMode: ClickTriggerMode = .both

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

    // 핀치 임계값 (종횡비 보정된 거리 비율 기준)
    var pinchThresholdEnter: CGFloat = 0.40
    var pinchThresholdExit: CGFloat = 0.50
    var pinchRawDistMax: CGFloat = 0.068

    // 약지+새끼 접기 임계값 (관절 직선도 정규화 척도 기준: 펼침 ~0.80+, 접힘 <0.46)
    var curlThresholdEnter: CGFloat = 0.46
    var curlThresholdExit: CGFloat = 0.64

    // 우클릭 임계값
    var rightPinchThreshold: CGFloat = 0.28
    private var lastRightClickTime: CFAbsoluteTime = 0.0

    // 스크롤 상태 및 서브픽셀 누적기
    private var isScrolling = false
    private var scrollMatchStreak = 0
    private var lastScrollY: CGFloat?
    private var scrollRemainderY: CGFloat = 0.0
    private var lastScrollValidTime: CFAbsoluteTime = 0.0
    private let scrollFilterY = OneEuro(minCutoff: 2.8, beta: 0.08)
    var scrollGainPixels: CGFloat = 2100.0

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
    private var isByCurl = false
    /// 손이 처음부터 약지/새끼를 접은 채(👆) 진입했을 때 오클릭을 막기 위한 무장 플래그
    private var isCurlArmed = false
    private var openHandStreak = 0
    private var pressStartTime: CFAbsoluteTime = 0.0
    private var lastFrameTime: CFAbsoluteTime = 0.0
    private var pressAnchorPoint: CGPoint = .zero
    private var pressStartRawPoint: CGPoint = .zero

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
                let idle = !self.isMoving && !self.isPressed
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

        guard _isEnabled, !isScrolling, let t = targetPoint else {
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

        guard let hand = hand, hand.isValid, let indexTip = hand.indexTip, let thumbTip = hand.thumbTip else {
            let wasPressed = isPressed
            let wasDragging = isDragging
            let releasePt = wasDragging ? (currentPoint ?? lastCursorPoint) : pressAnchorPoint
            isPressed = false
            isDragging = false
            isScrolling = false
            isCurlArmed = false
            isApproachingClick = false
            filterX.reset()
            filterY.reset()
            lastScrollY = nil
            scrollRemainderY = 0.0
            let pt = lastCursorPoint
            lock.unlock()

            if wasPressed && wasDragging {
                postMouseUp(at: releasePt, clicks: 1)
            }
            updateState(.noHand, point: pt, ratio: nil)
            return
        }

        let now = hand.timestamp > 0 ? hand.timestamp : CFAbsoluteTimeGetCurrent()
        lastFrameTime = now

        // 1. 거울 반전 및 상하 반전
        let mirrorX = 1.0 - indexTip.x
        let invertY = 1.0 - indexTip.y

        // 2. Active ROI 매핑
        let clampedX = min(max((mirrorX - roiMinX) / (roiMaxX - roiMinX), 0.0), 1.0)
        let clampedY = min(max((invertY - roiMinY) / (roiMaxY - roiMinY), 0.0), 1.0)

        // 3. OneEuro 필터
        let smoothX = filterX.filter(Double(clampedX), t: now)
        let smoothY = filterY.filter(Double(clampedY), t: now)

        // 4. 화면 좌표 매핑
        let screen = mainDisplayBounds(now: now)
        let targetX = screen.origin.x + CGFloat(smoothX) * screen.width
        let targetY = screen.origin.y + CGFloat(smoothY) * screen.height
        let rawTarget = CGPoint(x: targetX, y: targetY)
        lastCursorPoint = rawTarget

        // 거리 및 관절 비율 계산 (종횡비 보정 적용됨)
        let rawDist = hand.distance(indexTip, thumbTip)
        let pinchRatio = hand.pinchRatio ?? 1.0
        let middlePinchRatio = hand.middlePinchRatio ?? 1.0
        let curlRatio = hand.lowerFingerCurlRatio

        // 약지/새끼손가락이 연속 4프레임 이상 확실히 펴진 상태가 확인되면 curl 클릭 무장
        if curlRatio >= curlThresholdExit {
            openHandStreak += 1
            if openHandStreak >= 4 {
                isCurlArmed = true
            }
        } else if curlRatio < curlThresholdEnter {
            openHandStreak = 0
        }

        let mode = clickTriggerMode
        let isPinchActive = (mode == .pinch || mode == .both)
        let isCurlActive = (mode == .fingerCurl || mode == .both)

        // 핀치/접기 접근 중 여부 (커서 브레이킹 및 클린 호버 히스토리 분리용)
        let approachingPinch = isPinchActive && (pinchRatio < 0.55)
        let approachingCurl = isCurlActive && isCurlArmed && (curlRatio < 0.54)
        isApproachingClick = approachingPinch || approachingCurl

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

        // A. 엄지-중지 우클릭 감지 (좌클릭/드래그/스크롤 중이 아닐 때)
        if !isPressed && !isScrolling && middlePinchRatio < rightPinchThreshold && pinchRatio > pinchThresholdEnter {
            if now - lastRightClickTime > 0.55 {
                lastRightClickTime = now
                let clickPt = cleanHoverHistory.last?.p ?? currentPoint ?? rawTarget
                lock.unlock()
                triggerRightClick(at: clickPt)
                updateState(.rightClicking, point: clickPt, ratio: middlePinchRatio)
                return
            }
        }

        // B. 두 손가락 스크롤 제스처 판정 (검지+중지만 나란히 붙여서 펴고, 약지+새끼는 접은 상태에서 상하 이동)
        let scrollPoseMatched = hand.isTwoFingerScrollPose(currentlyScrolling: isScrolling)
        if scrollPoseMatched {
            scrollMatchStreak += 1
        } else {
            scrollMatchStreak = 0
        }
        let withinScrollGrace = isScrolling && (now - lastScrollValidTime < 0.06) && (pinchRatio > 0.40)
        let shouldScroll = (isScrolling && (scrollPoseMatched || withinScrollGrace)) || (!isScrolling && scrollMatchStreak >= 3)

        if shouldScroll && !isDragging {
            if !isScrolling {
                scrollFilterY.reset()
                lastScrollY = nil
                scrollRemainderY = 0.0
            }
            if scrollPoseMatched {
                lastScrollValidTime = now
            }
            // 만약 스크롤 자세 진입 직전에 약지/새끼 접힘 때문에 아직 드래그 전인 isPressed가 걸렸다면 즉시 해제
            if isPressed && !isDragging {
                isPressed = false
            }
            isScrolling = true

            let midY = hand.middleTip?.y ?? indexTip.y
            let avgInvertY = 1.0 - ((indexTip.y + midY) * 0.5)
            let clampedScrollY = min(max((avgInvertY - roiMinY) / (roiMaxY - roiMinY), 0.0), 1.0)
            let currentSmoothY = CGFloat(scrollFilterY.filter(Double(clampedScrollY), t: now))
            var pixelStepsToSend: Int32 = 0
            let scrollAnchor = currentPoint ?? rawTarget

            if let prevY = lastScrollY {
                let dy = currentSmoothY - prevY
                // 미세한 움직임도 버리지 않고 서브픽셀 누적기로 축적하여 1px 단위로 즉시 배출
                if abs(dy) > 0.0001 {
                    let totalPixels = -dy * scrollGainPixels + scrollRemainderY
                    let steps = Int32(totalPixels.rounded(.towardZero))
                    if steps != 0 {
                        pixelStepsToSend = steps
                        scrollRemainderY = totalPixels - CGFloat(steps)
                    } else {
                        scrollRemainderY = totalPixels
                    }
                }
            }
            lastScrollY = currentSmoothY
            let tipRatio = hand.indexMiddleTipRatio ?? 0.3
            lock.unlock()

            if pixelStepsToSend != 0 {
                scroll(pixels: pixelStepsToSend, at: scrollAnchor)
            }
            updateState(.scrolling, point: scrollAnchor, ratio: tipRatio)
            return
        }

        if isScrolling {
            isScrolling = false
            scrollFilterY.reset()
            lastScrollY = nil
            scrollRemainderY = 0.0
        }

        // C. 좌클릭 / 드래그 판정
        // 스크롤 자세(검지+중지 밀착 폄) 진행 중에는 약지/새끼 접힘 클릭을 억제하여 오작동 방지
        let pinchTriggered = isPinchActive && ((pinchRatio < pinchThresholdEnter) || (rawDist < pinchRawDistMax))
        let curlTriggered = isCurlActive && isCurlArmed && !scrollPoseMatched && (curlRatio < curlThresholdEnter)
        let clickTriggered = pinchTriggered || curlTriggered

        if !isPressed {
            // 미누름 상태
            if clickTriggered {
                isPressed = true
                isByCurl = curlTriggered && !pinchTriggered
                isDragging = false
                pressStartTime = now
                pressStartRawPoint = rawTarget

                // 핀치/접기 시작 직전의 안정된 호버 좌표를 앵커로 선택
                let lookback: CFAbsoluteTime = isByCurl ? 0.08 : 0.14
                let rollbackTime = now - lookback
                let anchor = cleanHoverHistory.last(where: { $0.t <= rollbackTime })?.p
                    ?? cleanHoverHistory.last?.p
                    ?? history.last(where: { $0.t <= rollbackTime })?.p
                    ?? currentPoint
                    ?? rawTarget

                pressAnchorPoint = anchor
                targetPoint = anchor
                currentPoint = anchor

                let state: GestureState = isByCurl ? .fingerCurled : .pinching
                let ratioVal = isByCurl ? curlRatio : pinchRatio
                lock.unlock()

                // 앵커 위치로 커서를 옮기고 hover(mouseMoved)만 먼저 보장.
                // 실제 leftMouseDown은 짧은 탭 릴리즈 시점 또는 드래그 확정 시점에 주입하여 하이퍼링크 클릭 씹힘을 원천 방지!
                warpCursor(to: anchor)
                postMouseMoved(at: anchor, dx: 0, dy: 0)
                updateState(state, point: anchor, ratio: ratioVal)
            } else {
                // 일반 포인팅 이동
                if now >= postClickFreezeUntil {
                    targetPoint = rawTarget
                    if currentPoint == nil {
                        currentPoint = rawTarget
                    }
                }
                let displayPt = (now < postClickFreezeUntil) ? pressAnchorPoint : rawTarget
                let ratioVal = isCurlActive ? curlRatio : pinchRatio
                lock.unlock()
                updateState(.pointing, point: displayPt, ratio: ratioVal)
            }
        } else {
            // 이미 제스처 누름(홀드) 유지 중인 상태
            let releaseCondition: Bool
            if isByCurl {
                releaseCondition = curlRatio > curlThresholdExit
            } else {
                releaseCondition = (pinchRatio > pinchThresholdExit) && (rawDist > pinchRawDistMax * 1.22)
            }

            let elapsed = now - pressStartTime
            // 중요: 롤백된 pressAnchorPoint가 아니라 제스처 시작 시점의 손 좌표(pressStartRawPoint) 대비 이동량으로 드래그 판정!
            let handMoveDist = hypot(rawTarget.x - pressStartRawPoint.x, rawTarget.y - pressStartRawPoint.y)

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
                    let ratioVal = isByCurl ? curlRatio : pinchRatio
                    lock.unlock()

                    warpCursor(to: anchor)
                    postMouseMoved(at: anchor, dx: 0, dy: 0)
                    postMouseDown(at: anchor, clicks: clicks)
                    postMouseUp(at: anchor, clicks: clicks)
                    updateState(.pointing, point: anchor, ratio: ratioVal)
                } else {
                    // 드래그 종료: 현재 위치에서 MouseUp
                    targetPoint = rawTarget
                    currentPoint = dragReleasePt
                    let ratioVal = isByCurl ? curlRatio : pinchRatio
                    lock.unlock()

                    postMouseUp(at: dragReleasePt, clicks: 1)
                    updateState(.pointing, point: dragReleasePt, ratio: ratioVal)
                }
            } else {
                // 만약 손을 폈다가(🖐️) 검지만 남기고 주먹을 쥐는(👆) 포인팅 자세로 바꿔 이동 중인 경우:
                // 약지/새끼 접힘(isByCurl)이 0.45초 이상 유지되거나 손을 34px 이상 이동하면 클릭/드래그가 아닌 '👆 포인팅 전환'으로 인식하여 즉시 커서 이동 재개!
                if isByCurl && !isDragging && (handMoveDist > 34.0 || elapsed > 0.48) {
                    isPressed = false
                    isCurlArmed = false
                    openHandStreak = 0
                    targetPoint = rawTarget
                    let ratioVal = isPinchActive ? pinchRatio : curlRatio
                    lock.unlock()
                    updateState(.pointing, point: rawTarget, ratio: ratioVal)
                    return
                }

                // 엄지+검지 핀치 홀드 후 이동 시 드래그 진입 (0.35초 이상 유지 + 36px 이상 이동)
                var justStartedDragging = false
                if !isByCurl && !isDragging && ((elapsed > 0.35 && handMoveDist > 36.0) || (elapsed > 0.55 && handMoveDist > 20.0)) {
                    isDragging = true
                    justStartedDragging = true
                }

                let draggingNow = isDragging
                let anchor = pressAnchorPoint
                let ratioVal = isByCurl ? curlRatio : pinchRatio
                let holdState: GestureState = isByCurl ? .fingerCurled : .pinching

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
                    updateState(.dragging, point: rawTarget, ratio: ratioVal)
                } else {
                    updateState(holdState, point: anchor, ratio: ratioVal)
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

    private func triggerRightClick(at point: CGPoint) {
        warpCursor(to: point)
        postMouseMoved(at: point, dx: 0, dy: 0)
        emit(.rightDown, at: point)
        emit(.rightUp, at: point)
        guard !suppressSystemEvents else { return }
        if let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    private func scroll(pixels: Int32, at point: CGPoint) {
        emit(.scroll(pixelDeltaY: pixels), at: point)
        guard !suppressSystemEvents else { return }
        // PointerEngine.swift와 동일한 픽셀 단위 휠 스크롤 + 현재 커서 위치 지정
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        ev.location = point
        ev.post(tap: .cghidEventTap)
    }

    func releaseAll() {
        lock.lock()
        let wasPressed = isPressed
        let wasDragging = isDragging
        let releasePt = wasDragging ? (currentPoint ?? lastCursorPoint) : pressAnchorPoint
        isPressed = false
        isDragging = false
        isScrolling = false
        isCurlArmed = false
        isApproachingClick = false
        targetPoint = nil
        currentPoint = nil
        isMoving = false
        hasSentSettledEvent = false
        history.removeAll()
        cleanHoverHistory.removeAll()
        filterX.reset()
        filterY.reset()
        lastScrollY = nil
        scrollRemainderY = 0.0
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
