import Foundation
import CoreGraphics
import AppKit

enum GestureState: String {
    case idle = "대기 중"
    case pointing = "포인팅"
    case pinching = "클릭 (탭)"
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

    // ROI (손의 유효 활동 영역)
    var roiMinX: CGFloat = 0.20
    var roiMaxX: CGFloat = 0.80
    var roiMinY: CGFloat = 0.20
    var roiMaxY: CGFloat = 0.80

    // 핀치 임계값
    var pinchThresholdEnter: CGFloat = 0.38
    var pinchThresholdExit: CGFloat = 0.48
    var pinchRawDistMax: CGFloat = 0.058

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
    private(set) var isPinching = false
    private var isDragging = false
    private var isFrozen = false
    private var freezeUntilTime: CFAbsoluteTime = 0.0

    // 타임 트래블 히스토리 버퍼 (손가락을 오므리기 시작하기 전 위치를 롤백 탐색)
    private var history: [(t: CFAbsoluteTime, p: CGPoint)] = []

    private var pinchStartTime: CFAbsoluteTime = 0.0
    private var pinchAnchorPoint: CGPoint = .zero

    // 더블 클릭 계산
    private var lastClickTime: CFAbsoluteTime = 0.0
    private var lastClickPoint: CGPoint = .zero
    private var clickCount = 0

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

    /// 240Hz 고주사율 디스플레이 보간 스레드
    private func startInterpolationThread() {
        let th = Thread { [weak self] in
            while true {
                guard let self = self else { return }
                self.tick()

                self.lock.lock()
                let idle = !self.isMoving && !self.isPinching
                self.lock.unlock()

                usleep(idle ? 20_000 : 4_166)
            }
        }
        th.name = "com.aimmac.VisionMouse.interpolator"
        th.qualityOfService = .userInteractive
        th.start()
    }

    private func tick() {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()

        // 클릭 앵커 동결(Freeze) 상태인 경우 커서 강제 고정
        if isFrozen || (isPinching && !isDragging) {
            let anchor = pinchAnchorPoint
            currentPoint = anchor
            lock.unlock()
            CGWarpMouseCursorPosition(anchor)
            return
        }

        // 릴리즈 후 반동 억제 쿨다운
        if now < freezeUntilTime {
            let anchor = pinchAnchorPoint
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

        if abs(dx) < 0.15 && abs(dy) < 0.15 && currentPoint != nil {
            isMoving = false
            lock.unlock()
            return
        }

        isMoving = true
        c.x += dx * 0.52
        c.y += dy * 0.52
        currentPoint = c
        let dragging = isDragging
        lock.unlock()

        if dragging {
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
        } else {
            CGWarpMouseCursorPosition(c)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func process(hand: HandPoseData?) {
        guard isEnabled else {
            updateState(.idle, point: lastCursorPoint, ratio: nil)
            return
        }

        guard let hand = hand, hand.isValid, let indexTip = hand.indexTip, let thumbTip = hand.thumbTip else {
            if isPinching {
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

        // 핀치 거리 계산 (상대 비율 및 절대 거리)
        let rawDist = hypot(indexTip.x - thumbTip.x, indexTip.y - thumbTip.y)
        let pinchRatio = hand.pinchRatio ?? 1.0
        let middlePinchRatio = hand.middlePinchRatio ?? 1.0

        // 히스토리 버퍼 업데이트 (최근 0.6초 보관)
        history.append((now, rawTarget))
        if history.count > 60 || (history.first.map { now - $0.t > 0.6 } ?? false) {
            history.removeAll { now - $0.t > 0.6 }
        }

        // 5. 제스처 판정
        // A. 엄지-중지 우클릭 감지
        if middlePinchRatio < rightPinchThreshold && pinchRatio > pinchThresholdExit {
            if now - lastRightClickTime > 0.6 {
                lastRightClickTime = now
                triggerRightClick(at: rawTarget)
                updateState(.rightClicking, point: rawTarget, ratio: middlePinchRatio)
                return
            }
        }

        // B. 두 손가락 스크롤 제스처 판정
        if let midTip = hand.middleTip {
            let fingerDist = hypot(indexTip.x - midTip.x, indexTip.y - midTip.y) / hand.palmScale
            if fingerDist < 0.22 && pinchRatio > 0.42 {
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

        // C. 엄지-검지 핀치 (좌클릭 vs 드래그 상태머신)
        let isPinchCondition = (pinchRatio < pinchThresholdEnter) || (rawDist < pinchRawDistMax)

        if !isPinching {
            // [핵심 기법 1: Pre-Pinch Damping (접근 감속)]
            // 손가락을 모으기 시작하는 구간(0.38 <= pinchRatio < 0.58)에서는 커서 속도를 대폭 줄여 타깃에 딱 붙어있게 만듦
            var filteredTarget = rawTarget
            if pinchRatio < 0.58 {
                let dampFactor = max(0.12, (pinchRatio - 0.38) / (0.58 - 0.38))
                lock.lock()
                let base = currentPoint ?? rawTarget
                filteredTarget = CGPoint(x: base.x + (rawTarget.x - base.x) * dampFactor,
                                         y: base.y + (rawTarget.y - base.y) * dampFactor)
                lock.unlock()
            }

            if isPinchCondition {
                // [핵심 기법 2: Time-Travel Rollback (과거 위치 롤백)]
                // 사용자가 손가락을 모으기 시작하기 직전(약 140ms 전)의 커서 위치를 정확히 탐색하여 앵커로 고정!
                let rollbackTime = now - 0.14
                let bestAnchor = history.last(where: { $0.t <= rollbackTime })?.p ?? history.first?.p ?? filteredTarget

                isPinching = true
                isDragging = false
                isFrozen = true
                pinchStartTime = now
                pinchAnchorPoint = bestAnchor

                lock.lock()
                targetPoint = bestAnchor
                currentPoint = bestAnchor
                lock.unlock()

                CGWarpMouseCursorPosition(bestAnchor)
                updateState(.pinching, point: bestAnchor, ratio: pinchRatio)
            } else {
                // 일반 이동: 240Hz 보간 스레드로 좌표 전달
                lock.lock()
                targetPoint = filteredTarget
                lock.unlock()
                updateState(.pointing, point: filteredTarget, ratio: pinchRatio)
            }
        } else {
            // 이미 핀치 중인 상태
            let isReleaseCondition = (pinchRatio > pinchThresholdExit) && (rawDist > pinchRawDistMax * 1.25)
            let elapsed = now - pinchStartTime
            let moveDist = hypot(rawTarget.x - pinchAnchorPoint.x, rawTarget.y - pinchAnchorPoint.y)

            if isReleaseCondition {
                // 핀치 해제!
                isPinching = false
                isFrozen = false

                if isDragging {
                    // 드래그 종료: 현재 위치에서 마우스 업
                    postMouseEvent(.leftMouseUp, at: rawTarget, clicks: 1)
                    isDragging = false
                } else {
                    // 순수 클릭(Tap): 손가락 모으기 직전의 앵커 포인트에 완벽하게 클릭 전송
                    let clicks = nextClickCount(at: pinchAnchorPoint, now: now)
                    postMouseEvent(.leftMouseDown, at: pinchAnchorPoint, clicks: clicks)
                    postMouseEvent(.leftMouseUp, at: pinchAnchorPoint, clicks: clicks)

                    // [핵심 기법 3: Post-Release Cooldown]
                    // 손을 펼치며 손가락이 튕겨나가는 반동을 막기 위해 0.12초간 위치 고정
                    freezeUntilTime = now + 0.12
                }

                lock.lock()
                targetPoint = rawTarget
                currentPoint = pinchAnchorPoint
                lock.unlock()

                updateState(.pointing, point: pinchAnchorPoint, ratio: pinchRatio)
            } else {
                // 핀치 유지 중: 손을 30픽셀 이상 크게 이동하거나 0.38초 이상 쥐고 있으면 드래그 모드로 진입
                if !isDragging && (elapsed > 0.38 || moveDist > 30.0) {
                    isDragging = true
                    isFrozen = false
                    // 드래그 시작 시점에 마우스 다운 발동
                    postMouseEvent(.leftMouseDown, at: pinchAnchorPoint, clicks: 1)
                }

                if isDragging {
                    // 드래그 이동 중에는 커서가 손을 따라 움직임
                    lock.lock()
                    targetPoint = rawTarget
                    lock.unlock()
                    updateState(.dragging, point: rawTarget, ratio: pinchRatio)
                } else {
                    // 탭 대기 중에는 커서를 앵커 포인트에 단 1픽셀도 흔들리지 않게 고정
                    updateState(.pinching, point: pinchAnchorPoint, ratio: pinchRatio)
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
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                         wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0)
        ev?.post(tap: .cghidEventTap)
    }

    private func releaseMouse() {
        if isPinching {
            isPinching = false
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
        isFrozen = false
        freezeUntilTime = 0.0
        lock.unlock()
        history.removeAll()
        filterX.reset()
        filterY.reset()
        lastScrollY = nil
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        ev.post(tap: .cghidEventTap)
    }

    private func updateState(_ state: GestureState, point: CGPoint, ratio: CGFloat?) {
        currentState = state
        delegate?.gestureEngine(self, didChangeState: state, point: point, pinchRatio: ratio)
    }
}
