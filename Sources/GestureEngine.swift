import Foundation
import CoreGraphics
import AppKit

enum GestureState: String {
    case idle = "대기 중"
    case pointing = "포인팅"
    case pinching = "클릭/드래그"
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

    // 핀치 임계값 (손바닥 크기 대비 비율)
    var pinchThresholdEnter: CGFloat = 0.28
    var pinchThresholdExit: CGFloat = 0.40

    // 우클릭 임계값
    var rightPinchThreshold: CGFloat = 0.26
    private var lastRightClickTime: CFAbsoluteTime = 0.0

    // 스크롤 모드
    private var lastScrollY: CGFloat?

    // 마우스 상태 & 240Hz 보간 엔진
    private let lock = NSLock()
    private var targetPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var isMoving = false
    private var isPinching = false
    private var lastCursorPoint: CGPoint = .zero
    private(set) var currentState: GestureState = .noHand

    // 필터 (반응 속도 강화를 위해 minCutoff 1.5, beta 0.035로 튜닝)
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

    /// 240Hz 고주사율 디스플레이 보간 스레드 (30fps 센서 입력을 120Hz 화면에서 비단결처럼 부드럽게 글라이딩)
    private func startInterpolationThread() {
        let th = Thread { [weak self] in
            while true {
                guard let self = self else { return }
                self.tick()

                self.lock.lock()
                let idle = !self.isMoving && !self.isPinching
                self.lock.unlock()

                // 정지 시 50Hz 절전, 이동 중 240Hz (4.16ms) 초부드러운 보간
                usleep(idle ? 20_000 : 4_166)
            }
        }
        th.name = "com.song.VisionMouse.interpolator"
        th.qualityOfService = .userInteractive
        th.start()
    }

    private func tick() {
        lock.lock()
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
        // 고응답성 지수 감쇠 보간 (0.52 계수로 240Hz 보간 시 2프레임 내 목표 수렴)
        c.x += dx * 0.52
        c.y += dy * 0.52
        currentPoint = c
        let dragging = isPinching
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

        guard let hand = hand, hand.isValid, let indexTip = hand.indexTip else {
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
        let target = CGPoint(x: targetX, y: targetY)
        lastCursorPoint = target

        // 240Hz 보간 스레드로 목표점 전달
        lock.lock()
        targetPoint = target
        lock.unlock()

        let pinchRatio = hand.pinchRatio ?? 1.0
        let middlePinchRatio = hand.middlePinchRatio ?? 1.0

        // 5. 제스처 판정
        // A. 엄지-중지 우클릭 감지
        if middlePinchRatio < rightPinchThreshold && pinchRatio > pinchThresholdExit {
            if now - lastRightClickTime > 0.6 {
                lastRightClickTime = now
                triggerRightClick(at: target)
                updateState(.rightClicking, point: target, ratio: middlePinchRatio)
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
                updateState(.scrolling, point: target, ratio: fingerDist)
                return
            }
        }
        lastScrollY = nil

        // C. 엄지-검지 핀치 (좌클릭 / 드래그)
        if !isPinching {
            if pinchRatio < pinchThresholdEnter {
                isPinching = true
                postMouseEvent(.leftMouseDown, at: target)
                updateState(.pinching, point: target, ratio: pinchRatio)
            } else {
                updateState(.pointing, point: target, ratio: pinchRatio)
            }
        } else {
            if pinchRatio > pinchThresholdExit {
                isPinching = false
                postMouseEvent(.leftMouseUp, at: target)
                updateState(.pointing, point: target, ratio: pinchRatio)
            } else {
                updateState(.pinching, point: target, ratio: pinchRatio)
            }
        }
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
            postMouseEvent(.leftMouseUp, at: lastCursorPoint)
        }
    }

    private func releaseAll() {
        releaseMouse()
        lock.lock()
        targetPoint = nil
        currentPoint = nil
        isMoving = false
        lock.unlock()
        filterX.reset()
        filterY.reset()
        lastScrollY = nil
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        ev.post(tap: .cghidEventTap)
    }

    private func updateState(_ state: GestureState, point: CGPoint, ratio: CGFloat?) {
        currentState = state
        delegate?.gestureEngine(self, didChangeState: state, point: point, pinchRatio: ratio)
    }
}
