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
    private var isScrollMode = false
    private var lastScrollY: CGFloat?

    // 마우스 상태
    private var isPinching = false
    private var lastCursorPoint: CGPoint = .zero
    private(set) var currentState: GestureState = .noHand

    // 필터
    private let filterX = OneEuro(minCutoff: 1.2, beta: 0.02)
    private let filterY = OneEuro(minCutoff: 1.2, beta: 0.02)

    var isEnabled: Bool = true {
        didSet {
            if !isEnabled {
                releaseAll()
            }
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

        // 1. 거울 반전 및 정규화
        // 사용자가 오른손을 오른쪽으로 이동하면 미러링으로 인해 카메라에서는 x가 작아짐 -> 1.0 - x로 보정
        let mirrorX = 1.0 - indexTip.x
        // Vision y는 아래가 0, 위가 1. 화면은 위가 0이므로 반전
        let invertY = 1.0 - indexTip.y

        // 2. Active ROI 매핑 (손을 조금만 움직여도 화면 전체에 도달하도록 스케일링)
        let clampedX = min(max((mirrorX - roiMinX) / (roiMaxX - roiMinX), 0.0), 1.0)
        let clampedY = min(max((invertY - roiMinY) / (roiMaxY - roiMinY), 0.0), 1.0)

        // 3. OneEuro 필터로 떨림 제거
        let smoothX = filterX.filter(Double(clampedX), t: now)
        let smoothY = filterY.filter(Double(clampedY), t: now)

        // 4. 메인 화면 픽셀 좌표 매핑
        let screen = CGDisplayBounds(CGMainDisplayID())
        let targetX = screen.origin.x + CGFloat(smoothX) * screen.width
        let targetY = screen.origin.y + CGFloat(smoothY) * screen.height
        let targetPoint = CGPoint(x: targetX, y: targetY)
        lastCursorPoint = targetPoint

        let pinchRatio = hand.pinchRatio ?? 1.0
        let middlePinchRatio = hand.middlePinchRatio ?? 1.0

        // 5. 제스처 판정
        // A. 엄지-중지 우클릭 감지
        if middlePinchRatio < rightPinchThreshold && pinchRatio > pinchThresholdExit {
            if now - lastRightClickTime > 0.6 {
                lastRightClickTime = now
                triggerRightClick(at: targetPoint)
                updateState(.rightClicking, point: targetPoint, ratio: middlePinchRatio)
                return
            }
        }

        // B. 두 손가락 모음 스크롤 제스처 판정
        // 검지와 중지가 나란히 있고 팁 거리가 가깝고, 엄지는 떨어져 있을 때
        if let midTip = hand.middleTip {
            let fingerDist = hypot(indexTip.x - midTip.x, indexTip.y - midTip.y) / hand.palmScale
            if fingerDist < 0.22 && pinchRatio > 0.42 {
                if let prevY = lastScrollY {
                    let dy = (clampedY - prevY) * 350.0
                    if abs(dy) > 1.0 {
                        scroll(dy: Double(dy))
                    }
                }
                lastScrollY = clampedY
                updateState(.scrolling, point: targetPoint, ratio: fingerDist)
                return
            }
        }
        lastScrollY = nil

        // C. 엄지-검지 핀치 (좌클릭 / 드래그)
        if !isPinching {
            if pinchRatio < pinchThresholdEnter {
                // 핀치 시작 -> 좌클릭 다운
                isPinching = true
                postMouseEvent(.leftMouseDown, at: targetPoint)
                updateState(.pinching, point: targetPoint, ratio: pinchRatio)
            } else {
                // 일반 포인터 이동
                moveCursor(to: targetPoint)
                updateState(.pointing, point: targetPoint, ratio: pinchRatio)
            }
        } else {
            if pinchRatio > pinchThresholdExit {
                // 핀치 해제 -> 좌클릭 업
                isPinching = false
                postMouseEvent(.leftMouseUp, at: targetPoint)
                updateState(.pointing, point: targetPoint, ratio: pinchRatio)
            } else {
                // 핀치 유지 -> 드래그
                postMouseEvent(.leftMouseDragged, at: targetPoint)
                updateState(.pinching, point: targetPoint, ratio: pinchRatio)
            }
        }
    }

    private func moveCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        postMouseEvent(.mouseMoved, at: point)
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
