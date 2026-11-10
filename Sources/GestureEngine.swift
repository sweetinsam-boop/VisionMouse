import Foundation
import CoreGraphics
import AppKit

enum ClickTriggerMode: String, CaseIterable {
    case fingerCurl = "약지+새끼 접기 (추천: 커서 흔들림 제로)"
    case pinch = "엄지+검지 핀치 (기존 꼬집기)"
    case both = "둘 다 허용 (약지 접기 or 핀치)"
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
    case pinching = "클릭 (탭)"
    case fingerCurled = "약지 접음 (클릭)"
    case dragging = "드래그 중"
    case rightClicking = "우클릭"
    case scrolling = "스크롤"
    case noHand = "손 감지 안됨"
}

protocol GestureEngineDelegate: AnyObject {
    func gestureEngine(_ engine: GestureEngine, didChangeState state: GestureState, point: CGPoint, pinchRatio: CGFloat?)
}

final class GestureEngine {
    weak var delegate: GestureEngineDelegate?

    // 클릭 방식 설정 (기본: 약지+새끼 접기)
    var clickTriggerMode: ClickTriggerMode = .fingerCurl

    // 포인터 감도 설정 (기본: 보통)
    var sensitivity: SensitivityLevel = .normal {
        didSet {
            applySensitivity(sensitivity)
        }
    }

    // ROI (손의 유효 활동 영역)
    var roiMinX: CGFloat = 0.20
    var roiMaxX: CGFloat = 0.80
    var roiMinY: CGFloat = 0.20
    var roiMaxY: CGFloat = 0.80

    private func applySensitivity(_ level: SensitivityLevel) {
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
            filterX.beta = 0.035; filterY.beta = 0.035
        case .low:
            roiMinX = 0.10; roiMaxX = 0.90
            roiMinY = 0.10; roiMaxY = 0.90
            filterX.beta = 0.020; filterY.beta = 0.020
        }
    }

    // 핀치 임계값
    var pinchThresholdEnter: CGFloat = 0.38
    var pinchThresholdExit: CGFloat = 0.48
    var pinchRawDistMax: CGFloat = 0.058

    // 약지+새끼 접기 임계값
    var curlThresholdEnter: CGFloat = 0.60
    var curlThresholdExit: CGFloat = 0.75

    // 우클릭 임계값
    var rightPinchThreshold: CGFloat = 0.28
    private var lastRightClickTime: CFAbsoluteTime = 0.0

    // 스크롤 모드
    private var lastScrollY: CGFloat?

    // 마우스 상태 & 240Hz 보간 엔진
    private let lock = NSLock()
    private var targetPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var isMoving = false
    private var hasSentSettledEvent = false

    private(set) var isPinching = false
    private(set) var isFingerCurled = false
    private var isDragging = false
    private var isFrozen = false
    private var freezeUntilTime: CFAbsoluteTime = 0.0

    private var history: [(t: CFAbsoluteTime, p: CGPoint)] = []
    private var clickStartTime: CFAbsoluteTime = 0.0
    private var clickAnchorPoint: CGPoint = .zero

    // 더블 클릭 계산
    private var lastClickTime: CFAbsoluteTime = 0.0
    private var lastClickPoint: CGPoint = .zero
    private var clickCount = 0

    private var lastCursorPoint: CGPoint = .zero
    private(set) var currentState: GestureState = .noHand

    private let eventSource = CGEventSource(stateID: .hidSystemState)

    // 필터
    private let filterX = OneEuro(minCutoff: 1.5, beta: 0.035)
    private let filterY = OneEuro(minCutoff: 1.5, beta: 0.035)

    var isEnabled: Bool = true {
        didSet {
            if !isEnabled {
                releaseAll()
            }
        }
    }

    init() {
        startInterpolationThread()
    }

    /// 240Hz 고주사율 디스플레이 보간 스레드
    private func startInterpolationThread() {
        let th = Thread { [weak self] in
            while true {
                guard let self = self else { return }
                self.tick()

                self.lock.lock()
                let idle = !self.isMoving && !self.isPinching && !self.isFingerCurled
                self.lock.unlock()

                usleep(idle ? 16_666 : 4_166)
            }
        }
        th.name = "com.aimmac.VisionMouse.interpolator"
        th.qualityOfService = .userInteractive
        th.start()
    }

    private func tick() {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()

        // 클릭 앵커 동결(Freeze) 상태인 경우 커서 고정
        if isFrozen || ((isPinching || isFingerCurled) && !isDragging) {
            let anchor = clickAnchorPoint
            currentPoint = anchor
            lock.unlock()
            CGWarpMouseCursorPosition(anchor)
            postMouseMovedEvent(at: anchor, dx: 0, dy: 0)
            return
        }

        // 릴리즈 후 반동 억제 쿨다운
        if now < freezeUntilTime {
            let anchor = clickAnchorPoint
            currentPoint = anchor
            lock.unlock()
            CGWarpMouseCursorPosition(anchor)
            return
        }

        guard isEnabled, let t = targetPoint else {
            lock.unlock()
            return
        }

        var c = currentPoint ?? t
        let dx = t.x - c.x
        let dy = t.y - c.y

        // 커서가 목표 지점에 거의 도달한 경우 (정지 상태)
        if abs(dx) < 0.20 && abs(dy) < 0.20 && currentPoint != nil {
            isMoving = false
            let settledNeeded = !hasSentSettledEvent
            hasSentSettledEvent = true
            lock.unlock()

            // [핵심] 멈췄을 때 1회의 정지 마우스 이벤트를 전송해야 브라우저가 링크 위에서 손모양(pointer) 커서로 갱신함!
            if settledNeeded {
                postMouseMovedEvent(at: c, dx: 0, dy: 0)
            }
            return
        }

        isMoving = true
        hasSentSettledEvent = false
        let stepX = dx * 0.52
        let stepY = dy * 0.52
        c.x += stepX
        c.y += stepY
        currentPoint = c
        let dragging = isDragging
        lock.unlock()

        if dragging {
            postMouseDraggedEvent(at: c, dx: stepX, dy: stepY)
        } else {
            CGWarpMouseCursorPosition(c)
            postMouseMovedEvent(at: c, dx: stepX, dy: stepY)
        }
    }

    func process(hand: HandPoseData?) {
        guard isEnabled else {
            updateState(.idle, point: lastCursorPoint, ratio: nil)
            return
        }

        guard let hand = hand, hand.isValid, let indexTip = hand.indexTip, let thumbTip = hand.thumbTip else {
            if isPinching || isFingerCurled {
                releaseMouse()
            }
            filterX.reset()
            filterY.reset()
            lastScrollY = nil
            updateState(.noHand, point: lastCursorPoint, ratio: nil)
            return
        }

        let now = hand.timestamp

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
        let screen = CGDisplayBounds(CGMainDisplayID())
        let targetX = screen.origin.x + CGFloat(smoothX) * screen.width
        let targetY = screen.origin.y + CGFloat(smoothY) * screen.height
        let rawTarget = CGPoint(x: targetX, y: targetY)
        lastCursorPoint = rawTarget

        // 핀치 및 접힘 거리 계산
        let rawDist = hypot(indexTip.x - thumbTip.x, indexTip.y - thumbTip.y)
        let pinchRatio = hand.pinchRatio ?? 1.0
        let middlePinchRatio = hand.middlePinchRatio ?? 1.0
        let curlRatio = hand.lowerFingerCurlRatio

        // 히스토리 버퍼 업데이트
        history.append((now, rawTarget))
        if history.count > 60 || (history.first.map { now - $0.t > 0.6 } ?? false) {
            history.removeAll { now - $0.t > 0.6 }
        }

        // 5. 제스처 판정
        // A. 엄지-중지 우클릭 감지
        if middlePinchRatio < rightPinchThreshold && pinchRatio > pinchThresholdExit && curlRatio > curlThresholdExit {
            if now - lastRightClickTime > 0.6 {
                lastRightClickTime = now
                triggerRightClick(at: rawTarget)
                updateState(.rightClicking, point: rawTarget, ratio: middlePinchRatio)
                return
            }
        }

        // B. 두 손가락 스크롤 제스처 판정 (검지+중지 나란히 펴고 약지/엄지 열림)
        if let midTip = hand.middleTip {
            let fingerDist = hypot(indexTip.x - midTip.x, indexTip.y - midTip.y) / hand.palmScale
            if fingerDist < 0.22 && pinchRatio > 0.42 && curlRatio > 0.65 {
                if let prevY = lastScrollY {
                    let dy = (clampedY - prevY) * 380.0
                    if abs(dy) > 1.0 {
                        scroll(dy: Double(dy))
                    }
                }
                lastScrollY = clampedY
                updateState(.scrolling, point: rawTarget, ratio: fingerDist)
                return
            }
        }
        lastScrollY = nil

        // C. 클릭 제스처 처리 (약지+새끼 접기 vs 핀치)
        let isPinchActive = (clickTriggerMode == .pinch || clickTriggerMode == .both)
        let isCurlActive = (clickTriggerMode == .fingerCurl || clickTriggerMode == .both)

        let pinchEnter = isPinchActive && ((pinchRatio < pinchThresholdEnter) || (rawDist < pinchRawDistMax))
        let curlEnter = isCurlActive && (curlRatio < curlThresholdEnter)

        let isClickTriggered = pinchEnter || curlEnter

        if !isPinching && !isFingerCurled {
            // [모드별 접근 감속]: 핀치 모드일 때만 손가락 모음 감속 적용
            var filteredTarget = rawTarget
            if isPinchActive && pinchRatio < 0.58 {
                let dampFactor = max(0.12, (pinchRatio - 0.38) / (0.58 - 0.38))
                lock.lock()
                let base = currentPoint ?? rawTarget
                filteredTarget = CGPoint(x: base.x + (rawTarget.x - base.x) * dampFactor,
                                         y: base.y + (rawTarget.y - base.y) * dampFactor)
                lock.unlock()
            }

            if isClickTriggered {
                // 클릭 트리거 발동!
                let isByCurl = curlEnter

                // 약지 접기인 경우 검지 끝이 전혀 흔들리지 않으므로 현재 target 사용
                // 핀치인 경우 140ms 전 과거 롤백 위치 사용
                let anchor: CGPoint
                if isByCurl {
                    anchor = rawTarget
                } else {
                    let rollbackTime = now - 0.14
                    anchor = history.last(where: { $0.t <= rollbackTime })?.p ?? history.first?.p ?? filteredTarget
                }

                if isByCurl {
                    isFingerCurled = true
                } else {
                    isPinching = true
                }

                isDragging = false
                isFrozen = true
                clickStartTime = now
                clickAnchorPoint = anchor

                lock.lock()
                targetPoint = anchor
                currentPoint = anchor
                lock.unlock()

                CGWarpMouseCursorPosition(anchor)
                postMouseMovedEvent(at: anchor, dx: 0, dy: 0)

                let state: GestureState = isByCurl ? .fingerCurled : .pinching
                let ratioToShow = isByCurl ? curlRatio : pinchRatio
                updateState(state, point: anchor, ratio: ratioToShow)
            } else {
                // 일반 이동: 240Hz 보간 스레드로 좌표 전달
                lock.lock()
                targetPoint = isPinchActive ? filteredTarget : rawTarget
                lock.unlock()
                updateState(.pointing, point: rawTarget, ratio: isCurlActive ? curlRatio : pinchRatio)
            }
        } else {
            // 이미 클릭(다운) 유지 중인 상태
            let isReleaseCondition: Bool
            if isFingerCurled {
                isReleaseCondition = curlRatio > curlThresholdExit
            } else {
                isReleaseCondition = (pinchRatio > pinchThresholdExit) && (rawDist > pinchRawDistMax * 1.25)
            }

            let elapsed = now - clickStartTime
            let moveDist = hypot(rawTarget.x - clickAnchorPoint.x, rawTarget.y - clickAnchorPoint.y)

            if isReleaseCondition {
                // 클릭 해제!
                let wasCurled = isFingerCurled
                isPinching = false
                isFingerCurled = false
                isFrozen = false

                if isDragging {
                    // 드래그 종료
                    postMouseEvent(.leftMouseUp, at: rawTarget, clicks: 1)
                    isDragging = false
                } else {
                    // 순수 클릭 (탭): 앵커 포인트에 정확한 클릭 전송
                    let clicks = nextClickCount(at: clickAnchorPoint, now: now)
                    postMouseEvent(.leftMouseDown, at: clickAnchorPoint, clicks: clicks)
                    postMouseEvent(.leftMouseUp, at: clickAnchorPoint, clicks: clicks)

                    if !wasCurled {
                        freezeUntilTime = now + 0.12
                    }
                }

                lock.lock()
                targetPoint = rawTarget
                currentPoint = clickAnchorPoint
                lock.unlock()

                updateState(.pointing, point: clickAnchorPoint, ratio: wasCurled ? curlRatio : pinchRatio)
            } else {
                // 클릭 유지 중: 손을 이동하거나 길게 유지하면 드래그로 전환
                let dragDistanceThreshold: CGFloat = isFingerCurled ? 18.0 : 30.0
                let dragTimeThreshold: CFAbsoluteTime = isFingerCurled ? 0.28 : 0.38

                if !isDragging && (elapsed > dragTimeThreshold || moveDist > dragDistanceThreshold) {
                    isDragging = true
                    isFrozen = false
                    postMouseEvent(.leftMouseDown, at: clickAnchorPoint, clicks: 1)
                }

                if isDragging {
                    lock.lock()
                    targetPoint = rawTarget
                    lock.unlock()
                    updateState(.dragging, point: rawTarget, ratio: isFingerCurled ? curlRatio : pinchRatio)
                } else {
                    updateState(isFingerCurled ? .fingerCurled : .pinching, point: clickAnchorPoint, ratio: isFingerCurled ? curlRatio : pinchRatio)
                }
            }
        }
    }

    private func nextClickCount(at p: CGPoint, now: CFAbsoluteTime) -> Int {
        if now - lastClickTime < 0.40 && hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 20 {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickPoint = p
        return clickCount
    }

    private func triggerRightClick(at point: CGPoint) {
        postMouseEvent(.rightMouseDown, at: point, button: .right)
        postMouseEvent(.rightMouseUp, at: point, button: .right)
    }

    private func scroll(dy: Double) {
        let ev = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 1,
                         wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0)
        ev?.post(tap: .cghidEventTap)
    }

    private func postMouseMovedEvent(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard let ev = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setDoubleValueField(.mouseEventDeltaX, value: Double(dx))
        ev.setDoubleValueField(.mouseEventDeltaY, value: Double(dy))
        ev.post(tap: .cghidEventTap)
    }

    private func postMouseDraggedEvent(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard let ev = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setDoubleValueField(.mouseEventDeltaX, value: Double(dx))
        ev.setDoubleValueField(.mouseEventDeltaY, value: Double(dy))
        ev.post(tap: .cghidEventTap)
    }

    private func releaseMouse() {
        if isPinching || isFingerCurled {
            isPinching = false
            isFingerCurled = false
            isFrozen = false
            if isDragging {
                isDragging = false
                postMouseEvent(.leftMouseUp, at: lastCursorPoint, clicks: 1)
            }
        }
    }

    private func releaseAll() {
        releaseMouse()
        lock.lock()
        targetPoint = nil
        currentPoint = nil
        isMoving = false
        hasSentSettledEvent = false
        isFrozen = false
        freezeUntilTime = 0.0
        lock.unlock()
        history.removeAll()
        filterX.reset()
        filterY.reset()
        lastScrollY = nil
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
        guard let ev = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        ev.post(tap: .cghidEventTap)
    }

    private func updateState(_ state: GestureState, point: CGPoint, ratio: CGFloat?) {
        currentState = state
        delegate?.gestureEngine(self, didChangeState: state, point: point, pinchRatio: ratio)
    }
}
