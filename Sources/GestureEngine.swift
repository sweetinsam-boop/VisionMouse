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
    case pinching = "클릭 중 (핀치)"
    case fingerCurled = "클릭 중 (약지 접음)"
    case dragging = "드래그 중"
    case rightClicking = "우클릭"
    case scrolling = "스크롤 중"
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

    // 핀치 임계값
    var pinchThresholdEnter: CGFloat = 0.38
    var pinchThresholdExit: CGFloat = 0.48
    var pinchRawDistMax: CGFloat = 0.058

    // 약지+새끼 접기 임계값 (손목-팁 거리 비율 기반)
    var curlThresholdEnter: CGFloat = 0.72
    var curlThresholdExit: CGFloat = 0.85

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

    private(set) var isPressed = false
    private var isDragging = false
    private var isByCurl = false
    private var pressStartTime: CFAbsoluteTime = 0.0
    private var pressAnchorPoint: CGPoint = .zero

    private var history: [(t: CFAbsoluteTime, p: CGPoint)] = []

    private var lastCursorPoint: CGPoint = .zero
    private(set) var currentState: GestureState = .noHand

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

    private func tick() {
        lock.lock()

        // 클릭된 채 정지(탭) 상태일 때는 앵커 포인트 고정
        if isPressed && !isDragging {
            let anchor = pressAnchorPoint
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

            // 멈췄을 때 1회의 정지 마우스 이벤트를 전송하여 브라우저가 링크 위에서 손모양(pointer) 커서로 갱신하도록 유도
            if settledNeeded {
                postMouseMoved(at: c, dx: 0, dy: 0)
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
            postMouseDragged(at: c, dx: stepX, dy: stepY)
        } else {
            CGWarpMouseCursorPosition(c)
            postMouseMoved(at: c, dx: stepX, dy: stepY)
        }
    }

    func process(hand: HandPoseData?) {
        guard isEnabled else {
            updateState(.idle, point: lastCursorPoint, ratio: nil)
            return
        }

        guard let hand = hand, hand.isValid, let indexTip = hand.indexTip, let thumbTip = hand.thumbTip else {
            if isPressed {
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

        // 거리 비율 계산
        let rawDist = hypot(indexTip.x - thumbTip.x, indexTip.y - thumbTip.y)
        let pinchRatio = hand.pinchRatio ?? 1.0
        let middlePinchRatio = hand.middlePinchRatio ?? 1.0
        let curlRatio = hand.lowerFingerCurlRatio

        // 히스토리 버퍼 (최근 0.5초)
        history.append((now, rawTarget))
        if history.count > 50 || (history.first.map { now - $0.t > 0.5 } ?? false) {
            history.removeAll { now - $0.t > 0.5 }
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

        // B. 두 손가락 스크롤 제스처 판정 (검지+중지 나란히 펴고 상하 이동)
        if let midTip = hand.middleTip {
            let fingerDist = hypot(indexTip.x - midTip.x, indexTip.y - midTip.y) / hand.palmScale
            // 두 손가락 팁 거리가 0.38 이하이고, 엄지가 떨어져 있을 때
            if fingerDist < 0.38 && pinchRatio > 0.35 && !isPressed {
                if let prevY = lastScrollY {
                    // 손을 위로 올리면 (clampedY 감소) 위로 스크롤, 손을 내리면 아래로 스크롤
                    let dy = clampedY - prevY
                    if abs(dy) > 0.003 {
                        // 웹 브라우저가 확실하게 스크롤되도록 라인 단위 및 픽셀 이벤트 전송
                        let lineSteps = Int32((-dy * 45.0).rounded())
                        if lineSteps != 0 {
                            scroll(lines: lineSteps)
                        }
                    }
                }
                lastScrollY = clampedY
                updateState(.scrolling, point: rawTarget, ratio: fingerDist)
                return
            }
        }
        lastScrollY = nil

        // C. 좌클릭 / 드래그 판정
        let isPinchActive = (clickTriggerMode == .pinch || clickTriggerMode == .both)
        let isCurlActive = (clickTriggerMode == .fingerCurl || clickTriggerMode == .both)

        let pinchTriggered = isPinchActive && ((pinchRatio < pinchThresholdEnter) || (rawDist < pinchRawDistMax))
        let curlTriggered = isCurlActive && (curlRatio < curlThresholdEnter)
        let clickTriggered = pinchTriggered || curlTriggered

        if !isPressed {
            // 미누름 상태
            if clickTriggered {
                // 클릭 시작! (물리 마우스 좌클릭 누름 즉시 발동)
                isPressed = true
                isByCurl = curlTriggered
                isDragging = false
                pressStartTime = now

                // 앵커 좌표 결정
                let anchor: CGPoint
                if isByCurl {
                    anchor = rawTarget
                } else {
                    let rollbackTime = now - 0.14
                    anchor = history.last(where: { $0.t <= rollbackTime })?.p ?? history.first?.p ?? rawTarget
                }
                pressAnchorPoint = anchor

                lock.lock()
                targetPoint = anchor
                currentPoint = anchor
                lock.unlock()

                // 커서 위치 고정 후 마우스 다운 즉시 전송!
                CGWarpMouseCursorPosition(anchor)
                postMouseDown(at: anchor)

                let state: GestureState = isByCurl ? .fingerCurled : .pinching
                let ratioVal = isByCurl ? curlRatio : pinchRatio
                updateState(state, point: anchor, ratio: ratioVal)
            } else {
                // 일반 이동: 240Hz 보간 스레드로 좌표 전달
                lock.lock()
                targetPoint = rawTarget
                lock.unlock()
                updateState(.pointing, point: rawTarget, ratio: isCurlActive ? curlRatio : pinchRatio)
            }
        } else {
            // 이미 마우스 누름(다운) 유지 중인 상태
            let releaseCondition: Bool
            if isByCurl {
                releaseCondition = curlRatio > curlThresholdExit
            } else {
                releaseCondition = (pinchRatio > pinchThresholdExit) && (rawDist > pinchRawDistMax * 1.25)
            }

            let elapsed = now - pressStartTime
            let moveDist = hypot(rawTarget.x - pressAnchorPoint.x, rawTarget.y - pressAnchorPoint.y)

            if releaseCondition {
                // 클릭 뗌 (마우스 업 발동 -> 링크 열림/버튼 클릭 완료!)
                isPressed = false
                let wasDragging = isDragging
                isDragging = false

                let releasePoint = wasDragging ? rawTarget : pressAnchorPoint
                postMouseUp(at: releasePoint)

                lock.lock()
                targetPoint = rawTarget
                currentPoint = releasePoint
                lock.unlock()

                updateState(.pointing, point: releasePoint, ratio: isByCurl ? curlRatio : pinchRatio)
            } else {
                // 누른 채 유지 중: 손을 25픽셀 이상 이동하거나 0.30초 이상 경과하면 드래그 모드로 진입
                if !isDragging && (elapsed > 0.30 || moveDist > 25.0) {
                    isDragging = true
                }

                if isDragging {
                    lock.lock()
                    targetPoint = rawTarget
                    lock.unlock()
                    updateState(.dragging, point: rawTarget, ratio: isByCurl ? curlRatio : pinchRatio)
                } else {
                    updateState(isByCurl ? .fingerCurled : .pinching, point: pressAnchorPoint, ratio: isByCurl ? curlRatio : pinchRatio)
                }
            }
        }
    }

    // MARK: - Mouse Event Injections (시스템 호환: mouseEventSource: nil)

    private func postMouseDown(at point: CGPoint) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        ev.post(tap: .cghidEventTap)
    }

    private func postMouseUp(at point: CGPoint) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        ev.post(tap: .cghidEventTap)
    }

    private func postMouseDragged(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setDoubleValueField(.mouseEventDeltaX, value: Double(dx))
        ev.setDoubleValueField(.mouseEventDeltaY, value: Double(dy))
        ev.post(tap: .cghidEventTap)
    }

    private func postMouseMoved(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setDoubleValueField(.mouseEventDeltaX, value: Double(dx))
        ev.setDoubleValueField(.mouseEventDeltaY, value: Double(dy))
        ev.post(tap: .cghidEventTap)
    }

    private func triggerRightClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        usleep(30_000)
        if let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func scroll(lines: Int32) {
        // macOS 웹 브라우저(Safari, Chrome)에서 완벽히 작동하는 라인 단위 휠 스크롤
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                         wheel1: lines, wheel2: 0, wheel3: 0)
        ev?.post(tap: .cghidEventTap)
    }

    private func releaseMouse() {
        if isPressed {
            isPressed = false
            let p = isDragging ? lastCursorPoint : pressAnchorPoint
            isDragging = false
            postMouseUp(at: p)
        }
    }

    private func releaseAll() {
        releaseMouse()
        lock.lock()
        targetPoint = nil
        currentPoint = nil
        isMoving = false
        hasSentSettledEvent = false
        lock.unlock()
        history.removeAll()
        filterX.reset()
        filterY.reset()
        lastScrollY = nil
    }

    private func updateState(_ state: GestureState, point: CGPoint, ratio: CGFloat?) {
        currentState = state
        delegate?.gestureEngine(self, didChangeState: state, point: point, pinchRatio: ratio)
    }
}
