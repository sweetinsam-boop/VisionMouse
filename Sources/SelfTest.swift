import Foundation
import CoreGraphics
import AppKit
import Vision

enum SelfTestRunner {
    // 표준 손 포즈 생성 헬퍼 (정규화 좌표 [0, 1])
    static func makeHand(
        timestamp: CFAbsoluteTime,
        indexTip: CGPoint = CGPoint(x: 0.50, y: 0.65),
        thumbTip: CGPoint = CGPoint(x: 0.34, y: 0.46),  // L자로 벌린 엄지
        middleTip: CGPoint = CGPoint(x: 0.54, y: 0.42),
        ringCurled: Bool = false,
        littleCurled: Bool = false,
        middleExtended: Bool = false,
        includeWrist: Bool = true,
        offset: CGVector = .zero  // 손 전체 평행 이동 (조이스틱 스크롤 테스트용)
    ) -> HandPoseData {
        var hand = HandPoseData(timestamp: timestamp, aspectRatio: 4.0 / 3.0)
        let wrist = CGPoint(x: 0.50, y: 0.20)
        if includeWrist {
            hand.points[.wrist] = wrist
        }

        // 손바닥 MCP 관절 배치 (wrist로부터 약 0.18 거리 -> palmScale ≈ 0.18)
        let indexMCP = CGPoint(x: 0.46, y: 0.38)
        let middleMCP = CGPoint(x: 0.50, y: 0.39)
        let ringMCP = CGPoint(x: 0.54, y: 0.38)
        let littleMCP = CGPoint(x: 0.58, y: 0.36)
        let thumbMP = CGPoint(x: 0.38, y: 0.32)

        hand.points[.indexMCP] = indexMCP
        hand.points[.indexPIP] = CGPoint(x: (indexMCP.x + indexTip.x) * 0.5, y: (indexMCP.y + indexTip.y) * 0.5)
        hand.points[.indexTip] = indexTip

        hand.points[.thumbMP] = thumbMP
        hand.points[.thumbIP] = CGPoint(x: (thumbMP.x + thumbTip.x) * 0.5, y: (thumbMP.y + thumbTip.y) * 0.5)
        hand.points[.thumbTip] = thumbTip

        hand.points[.middleMCP] = middleMCP
        if middleExtended {
            let mTip = middleTip
            hand.points[.middlePIP] = CGPoint(x: (middleMCP.x + mTip.x) * 0.5, y: (middleMCP.y + mTip.y) * 0.5)
            hand.points[.middleTip] = mTip
        } else {
            hand.points[.middlePIP] = CGPoint(x: 0.50, y: 0.48)
            hand.points[.middleTip] = middleTip
        }

        hand.points[.ringMCP] = ringMCP
        if ringCurled {
            // 손가락이 손바닥 쪽으로 굽혀진 상태 (PIP는 위, Tip은 다시 MCP 근처로 꺾임)
            hand.points[.ringPIP] = CGPoint(x: 0.54, y: 0.46)
            hand.points[.ringTip] = CGPoint(x: 0.54, y: 0.39)
        } else {
            hand.points[.ringPIP] = CGPoint(x: 0.54, y: 0.49)
            hand.points[.ringTip] = CGPoint(x: 0.54, y: 0.58)
        }

        hand.points[.littleMCP] = littleMCP
        if littleCurled {
            hand.points[.littlePIP] = CGPoint(x: 0.58, y: 0.43)
            hand.points[.littleTip] = CGPoint(x: 0.58, y: 0.37)
        } else {
            hand.points[.littlePIP] = CGPoint(x: 0.58, y: 0.46)
            hand.points[.littleTip] = CGPoint(x: 0.58, y: 0.54)
        }

        if offset != .zero {
            for (joint, p) in hand.points {
                hand.points[joint] = CGPoint(x: p.x + offset.dx, y: p.y + offset.dy)
            }
        }
        return hand
    }

    /// 엄지 끝을 검지 옆면(MCP~Tip 중간)에 붙인 손
    static func touchingHand(timestamp: CFAbsoluteTime, indexTip: CGPoint = CGPoint(x: 0.50, y: 0.65)) -> HandPoseData {
        let side = CGPoint(x: (0.46 + indexTip.x) * 0.5 - 0.01, y: (0.38 + indexTip.y) * 0.5)
        return makeHand(timestamp: timestamp, indexTip: indexTip, thumbTip: side)
    }

    static func runAll() -> Int32 {
        print("====================================================")
        print("🧪 VisionMouse 자체 자동화 검증 테스트 시작")
        print("====================================================")

        var passed = 0
        var failed = 0

        func check(_ name: String, _ block: () throws -> Void) {
            do {
                try block()
                passed += 1
                print("  ✅ [PASS] \(name)")
            } catch {
                failed += 1
                print("  ❌ [FAIL] \(name): \(error)")
            }
        }

        struct TestFailure: Error, CustomStringConvertible {
            let description: String
            init(_ msg: String) { self.description = msg }
        }

        func assertTrue(_ cond: Bool, _ msg: String) throws {
            if !cond { throw TestFailure(msg) }
        }

        // 1. HandPoseData 기하 보정 및 손목 화면 이탈(Wrist Cutoff) 폴백 검증
        check("1. 종횡비 보정 및 손목 화면 이탈 시 접힘/펼침 판정") {
            let openWithWrist = makeHand(timestamp: 1.0, ringCurled: false, littleCurled: false, includeWrist: true)
            let curledWithWrist = makeHand(timestamp: 1.0, ringCurled: true, littleCurled: true, includeWrist: true)
            let openNoWrist = makeHand(timestamp: 1.0, ringCurled: false, littleCurled: false, includeWrist: false)
            let curledNoWrist = makeHand(timestamp: 1.0, ringCurled: true, littleCurled: true, includeWrist: false)

            try assertTrue(openWithWrist.lowerFingerCurlRatio > 0.70, "손목 있을 때 펼침 비율(\(openWithWrist.lowerFingerCurlRatio))이 0.70보다 커야 함")
            try assertTrue(curledWithWrist.lowerFingerCurlRatio < 0.45, "손목 있을 때 접힘 비율(\(curledWithWrist.lowerFingerCurlRatio))이 0.45보다 작아야 함")
            try assertTrue(openNoWrist.lowerFingerCurlRatio > 0.70, "손목 잘렸을 때 펼침 비율(\(openNoWrist.lowerFingerCurlRatio))이 0.70보다 커야 함")
            try assertTrue(curledNoWrist.lowerFingerCurlRatio < 0.45, "손목 잘렸을 때 접힘 비율(\(curledNoWrist.lowerFingerCurlRatio))이 0.45보다 작아야 함")
        }

        func count(_ events: [EmittedMouseEvent], _ match: (EmittedMouseEvent.Kind) -> Bool) -> Int {
            events.filter { match($0.kind) }.count
        }
        let isDown: (EmittedMouseEvent.Kind) -> Bool = { if case .leftDown = $0 { return true }; return false }
        let isUp: (EmittedMouseEvent.Kind) -> Bool = { if case .leftUp = $0 { return true }; return false }
        let isDrag: (EmittedMouseEvent.Kind) -> Bool = { if case .leftDragged = $0 { return true }; return false }

        // 2. 하이퍼링크 엄지 붙이기 클릭 (엄지가 검지를 밀어 끝이 흔들려도 호버 좌표에서 클릭, 드래그 오판 없음)
        check("2. 하이퍼링크 엄지 붙이기 클릭 (검지 흔들림 롤백 & 드래그 오판 방지)") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var events: [EmittedMouseEvent] = []
            engine.onEventEmitted = { events.append($0) }

            var t: CFAbsoluteTime = 100.0
            // (a) 0.4초 동안 하이퍼링크 위치(0.50, 0.65) 위에서 엄지를 편 채 호버
            for _ in 0..<24 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.50, y: 0.65)))
                engine.tick(nowOverride: t)
            }
            let hoverPoint = events.last?.point ?? .zero
            events.removeAll()

            // (b) 엄지가 검지로 다가오는 프레임 (검지 끝이 살짝 밀림)
            t += 1.0 / 60.0
            engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.49, y: 0.63), thumbTip: CGPoint(x: 0.41, y: 0.50)))
            engine.tick(nowOverride: t)

            // (c) 엄지 붙임 0.28초 유지 (검지 끝이 0.65 -> 0.61로 흔들림)
            for i in 0..<16 {
                t += 1.0 / 60.0
                let jx = 0.48 + CGFloat(i % 3) * 0.003
                let jy = 0.61 - CGFloat(i % 2) * 0.004
                engine.process(hand: touchingHand(timestamp: t, indexTip: CGPoint(x: jx, y: jy)))
                engine.tick(nowOverride: t)
            }

            // (d) 엄지 벌림
            t += 1.0 / 60.0
            engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.50, y: 0.65)))
            engine.tick(nowOverride: t)

            let downs = events.filter { isDown($0.kind) }
            let ups = events.filter { isUp($0.kind) }
            try assertTrue(count(events, isDrag) == 0, "엄지 붙이기 클릭 중 leftDragged가 발생하면 안 됨")
            try assertTrue(downs.count == 1 && ups.count == 1, "leftDown 1회, leftUp 1회여야 함 (down: \(downs.count), up: \(ups.count))")
            let drift = hypot(downs[0].point.x - hoverPoint.x, downs[0].point.y - hoverPoint.y)
            try assertTrue(hypot(downs[0].point.x - ups[0].point.x, downs[0].point.y - ups[0].point.y) < 0.01, "down/up 좌표가 일치해야 함")
            try assertTrue(drift < 5.0, "원래 호버 좌표에서 클릭되어야 함 (오차: \(drift)px)")
        }

        // 3. 처음부터 엄지를 붙인 채 진입하면 클릭 안 됨, 엄지를 벌린 뒤 붙였다 떼면 클릭
        check("3. 엄지 붙인 채 진입 시 오클릭 방지 및 무장 후 클릭") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var events: [EmittedMouseEvent] = []
            engine.onEventEmitted = { events.append($0) }

            var t: CFAbsoluteTime = 200.0
            for _ in 0..<10 {
                t += 1.0 / 60.0
                engine.process(hand: touchingHand(timestamp: t))
                engine.tick(nowOverride: t)
            }
            try assertTrue(!engine.isPressed, "엄지를 붙인 채 진입했을 때는 클릭이 걸리면 안 됨")

            for _ in 0..<10 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t))
                engine.tick(nowOverride: t)
            }
            events.removeAll()
            for _ in 0..<8 {
                t += 1.0 / 60.0
                engine.process(hand: touchingHand(timestamp: t))
                engine.tick(nowOverride: t)
            }
            t += 1.0 / 60.0
            engine.process(hand: makeHand(timestamp: t))

            try assertTrue(count(events, isDown) == 1 && count(events, isUp) == 1, "엄지 붙였다 떼면 정확히 1회 클릭되어야 함")
        }

        // 4. 연속 엄지 붙이기 시 더블클릭(clickState == 2)
        check("4. 더블클릭 (clickState == 1 -> 2) 정상 주입 검증") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var downClicks: [Int] = []
            engine.onEventEmitted = { ev in
                if case let .leftDown(clicks) = ev.kind { downClicks.append(clicks) }
            }

            var t: CFAbsoluteTime = 300.0
            for _ in 0..<12 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t))
                engine.tick(nowOverride: t)
            }
            for _ in 0..<2 {
                for _ in 0..<5 { t += 1.0 / 60.0; engine.process(hand: touchingHand(timestamp: t)) }
                for _ in 0..<6 { t += 1.0 / 60.0; engine.process(hand: makeHand(timestamp: t)) }
            }
            try assertTrue(downClicks == [1, 2], "연속 클릭 시 clickState가 [1, 2]여야 함 (실제: \(downClicks))")
        }

        // 5. 엄지를 붙인 채 이동하면 드래그
        check("5. 엄지 붙이고 이동 시 드래그 앤 드롭 검증") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var events: [EmittedMouseEvent] = []
            engine.onEventEmitted = { events.append($0) }

            var t: CFAbsoluteTime = 400.0
            for _ in 0..<10 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.50, y: 0.50)))
                engine.tick(nowOverride: t)
            }
            events.removeAll()

            for i in 0..<40 {
                t += 1.0 / 60.0
                let x = 0.50 - CGFloat(i) * 0.005
                engine.process(hand: touchingHand(timestamp: t, indexTip: CGPoint(x: x, y: 0.50)))
                engine.tick(nowOverride: t)
            }
            t += 1.0 / 60.0
            // 합성 손은 MCP가 고정이라, 엄지도 검지 끝 기준으로 L자 위치에 둔다
            engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.30, y: 0.50), thumbTip: CGPoint(x: 0.14, y: 0.31)))

            let drags = count(events, isDrag)
            try assertTrue(count(events, isDown) == 1 && drags > 5 && count(events, isUp) == 1,
                           "드래그 시 leftDown(1) -> leftDragged(\(drags)) -> leftUp(1)이어야 함")
        }

        // 6. 두 손가락 조이스틱 스크롤: 기준점에서는 정지, 손을 올리면 위로, 오른쪽으로 옮기면 가로 스크롤, 엄지가 붙어도 클릭 없음
        check("6. 조이스틱 스크롤 (정지 구간·세로·가로) 및 좌클릭 오작동 차단") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var sumX: Int32 = 0
            var sumY: Int32 = 0
            var accidentalClicks = 0
            var phases: [String] = []
            engine.onEventEmitted = { ev in
                switch ev.kind {
                case let .scroll(dx, dy):
                    sumX += dx
                    sumY += dy
                case .scrollBegan:
                    phases.append("began")
                case .scrollEnded:
                    phases.append("ended")
                case .leftDown, .leftDragged:
                    accidentalClicks += 1
                default:
                    break
                }
            }
            // 검지+중지 붙여 펴고 약지+새끼 접고 엄지는 검지 옆에 붙인 스크롤 자세
            func scrollHand(_ t: CFAbsoluteTime, _ offset: CGVector) -> HandPoseData {
                makeHand(timestamp: t, indexTip: CGPoint(x: 0.48, y: 0.62), thumbTip: CGPoint(x: 0.46, y: 0.50),
                         middleTip: CGPoint(x: 0.52, y: 0.62), ringCurled: true, littleCurled: true,
                         middleExtended: true, offset: offset)
            }
            var t: CFAbsoluteTime = 500.0
            func run(_ frames: Int, _ offset: CGVector) {
                for _ in 0..<frames {
                    t += 1.0 / 30.0
                    engine.process(hand: scrollHand(t, offset))
                    // 240Hz 보간 스레드 대신 프레임 사이 8회 tick
                    for k in 1...8 { engine.tick(nowOverride: t + Double(k) / 240.0) }
                }
            }
            for _ in 0..<5 { t += 1.0 / 30.0; engine.process(hand: makeHand(timestamp: t)) }  // 클릭 무장

            run(15, .zero)
            try assertTrue(engine.currentState == .scrolling, "스크롤 자세에서는 .scrolling 상태여야 함 (실제: \(engine.currentState))")
            try assertTrue(sumX == 0 && sumY == 0, "기준점에 손을 두면 스크롤이 없어야 함 (x: \(sumX), y: \(sumY))")

            run(30, CGVector(dx: 0, dy: 0.15))  // 손을 위로 (Vision y는 위가 +)
            try assertTrue(sumY > 50 && sumX == 0, "손을 올리면 위로만 스크롤되어야 함 (x: \(sumX), y: \(sumY))")

            let yBefore = sumY
            run(30, CGVector(dx: -0.15, dy: 0))  // 카메라 영상 x-는 사용자 기준 오른쪽
            try assertTrue(sumX < -50, "손을 오른쪽으로 옮기면 가로 스크롤(wheel2 음수)이 나와야 함 (x: \(sumX))")
            try assertTrue(abs(sumY - yBefore) < 60, "가로 이동 중 세로 스크롤은 거의 없어야 함 (Δy: \(sumY - yBefore))")

            // 스크롤 자세를 풀고 엄지를 벌려도 클릭이 나가면 안 됨 (유예 0.06초를 넘기도록 3프레임)
            for _ in 0..<3 {
                t += 1.0 / 30.0
                engine.process(hand: makeHand(timestamp: t))
            }
            try assertTrue(phases == ["began", "ended"], "트랙패드처럼 began 1회 → ended 1회여야 함 (실제: \(phases))")
            try assertTrue(accidentalClicks == 0, "스크롤 중 엄지가 검지에 붙어 있어도 좌클릭이 발생하면 안 됨 (발생: \(accidentalClicks))")
        }

        // 6b. 조이스틱 속도 곡선
        check("6b. 조이스틱 속도 곡선 (정지 구간·증가·상한·주축 스냅)") {
            func v(_ x: CGFloat, _ y: CGFloat) -> CGVector {
                GestureEngine.joystickScrollVelocity(offset: CGVector(dx: x, dy: y), deadZone: 0.25, gain: 1600, maxSpeed: 4000)
            }
            try assertTrue(v(0, 0.2) == .zero, "정지 구간 안에서는 0이어야 함")
            try assertTrue(v(0, 0.5).dy > 0 && v(0, -0.5).dy < 0, "위는 +, 아래는 -")
            try assertTrue(v(0, 1.0).dy > v(0, 0.5).dy, "멀수록 빨라야 함")
            try assertTrue(v(0, 10).dy == 4000, "상한 4000px/s")
            try assertTrue(v(0.2, 1.0).dx == 0, "세로가 지배적이면 가로 성분은 스냅되어 0")
            try assertTrue(v(1.0, 0).dx < 0 && v(1.0, 0).dy == 0, "오른쪽은 wheel2 음수")
        }

        // 7. 약지+새끼 접기는 더 이상 클릭이 아님
        check("7. 약지·새끼 접기로는 클릭되지 않음") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var t: CFAbsoluteTime = 600.0
            for _ in 0..<10 { t += 1.0 / 60.0; engine.process(hand: makeHand(timestamp: t)) }
            for _ in 0..<10 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t, ringCurled: true, littleCurled: true))
            }
            try assertTrue(!engine.isPressed, "약지+새끼 접기로 눌리면 안 됨")
        }

        // 7b. 엄지-검지 붙임 비율 기하 검증
        check("7b. 엄지-검지 붙임 비율 (L자 벌림 vs 옆면 붙임)") {
            let open = makeHand(timestamp: 1.0).thumbIndexRatio ?? 0
            let touching = touchingHand(timestamp: 1.0).thumbIndexRatio ?? 1
            try assertTrue(open > 0.55, "L자로 벌린 엄지 비율(\(open))이 0.55보다 커야 함")
            try assertTrue(touching < 0.15, "검지에 붙인 엄지 비율(\(touching))이 0.15보다 작아야 함")
        }

        // 8. 멀티스레드 동시성 스트레스 테스트 & Fail-safe 워치독 검증
        check("8. 멀티스레드 동시성 스트레스(2,000회) 및 Fail-safe 워치독 자동 해제") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true

            let group = DispatchGroup()
            let q1 = DispatchQueue(label: "test.q1", attributes: .concurrent)
            let q2 = DispatchQueue(label: "test.q2", attributes: .concurrent)

            for i in 0..<500 {
                group.enter()
                q1.async {
                    let ts = CFAbsoluteTime(700 + Double(i) * 0.01)
                    engine.process(hand: i % 2 == 0 ? touchingHand(timestamp: ts) : makeHand(timestamp: ts))
                    group.leave()
                }
                group.enter()
                q2.async {
                    engine.tick(nowOverride: CFAbsoluteTime(700 + Double(i) * 0.01))
                    if i % 50 == 0 {
                        engine.isEnabled.toggle()
                        engine.sensitivity = SensitivityLevel.allCases[i % SensitivityLevel.allCases.count]
                    }
                    group.leave()
                }
            }
            group.wait()
            engine.releaseAll()
            engine.isEnabled = true

            // 워치독: 엄지 붙이기 누름 후 2.0초 동안 프레임이 끊기면 자동 해제
            var t: CFAbsoluteTime = 899.7
            for _ in 0..<15 { t += 1.0 / 60.0; engine.process(hand: makeHand(timestamp: t)) }  // 무장 (0.12초 이상)
            for _ in 0..<5 { t += 1.0 / 60.0; engine.process(hand: touchingHand(timestamp: t)) }  // 확정 (0.05초 이상)
            try assertTrue(engine.isPressed, "엄지를 붙여 확정된 뒤 isPressed == true여야 함")
            engine.tick(nowOverride: t + 2.0)
            try assertTrue(!engine.isPressed, "1.2초 이상 프레임 입력이 끊기면 워치독이 자동으로 isPressed를 해제해야 함")
        }

        // 9. 실제 macOS CGEvent 생성 및 스크롤/클릭 이벤트 필드 무결성 검증
        check("9. macOS CGEvent(클릭·더블클릭·연속 픽셀 스크롤) 시스템 필드 무결성 검증") {
            let src = CGEventSource(stateID: .hidSystemState)
            src?.localEventsSuppressionInterval = 0.0

            guard let downEv = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 300, y: 300), mouseButton: .left) else {
                throw TestFailure("leftMouseDown CGEvent 생성 실패")
            }
            downEv.setIntegerValueField(.mouseEventClickState, value: 2)
            try assertTrue(downEv.getIntegerValueField(.mouseEventClickState) == 2, "mouseEventClickState가 2로 설정되어야 함")

            guard let scrollEv = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0) else {
                throw TestFailure("scrollWheel CGEvent 생성 실패")
            }
            let isCont = scrollEv.getIntegerValueField(.scrollWheelEventIsContinuous)
            let ptDelta = scrollEv.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let lineDelta = scrollEv.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            try assertTrue(isCont == 1 && ptDelta == 12, "픽셀 스크롤 이벤트의 continuous(1) 및 pointDelta(12) 필드가 유효해야 함 (isCont=\(isCont), ptDelta=\(ptDelta), lineDelta=\(lineDelta))")

            if let nsEv = NSEvent(cgEvent: scrollEv) {
                try assertTrue(nsEv.hasPreciseScrollingDeltas && nsEv.scrollingDeltaY == 12.0, "AppKit NSEvent 변환 시 정밀 스크롤 델타(12.0px)가 유지되어야 함 (hasPrecise=\(nsEv.hasPreciseScrollingDeltas), deltaY=\(nsEv.scrollingDeltaY), legacyDeltaY=\(nsEv.deltaY))")
            }
        }

        // 10. 커서 이동 중 스크롤 오작동 차단 검증 (🖐️ 다섯 손가락 펼침 이동 / 👆 검지 단독 이동 / 🖐️→👆 자세 전환 이동)
        check("10. 커서 이동(🖐️ 열린 손 · 👆 한 손가락 · 🖐️→👆 자세 전환) 중 스크롤·드래그 오작동 0건 검증") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var falseScrolls = 0
            var falseDrags = 0
            engine.onEventEmitted = { ev in
                switch ev.kind {
                case .scroll:
                    falseScrolls += 1
                case .leftDragged:
                    falseDrags += 1
                default:
                    break
                }
            }

            var t: CFAbsoluteTime = 1000.0
            // (a) 🖐️ 다섯 손가락을 모두 편 상태(검지+중지도 펴져 있고 붙어 있지만 약지+새끼도 펴진 상태)로 상하좌우 커서 이동 20프레임
            for i in 0..<20 {
                t += 1.0 / 60.0
                let dy = CGFloat(i) * 0.005
                let openPalmHand = makeHand(
                    timestamp: t,
                    indexTip: CGPoint(x: 0.48, y: 0.58 + dy),
                    thumbTip: CGPoint(x: 0.34, y: 0.42 + dy),
                    middleTip: CGPoint(x: 0.52, y: 0.59 + dy),
                    ringCurled: false,
                    littleCurled: false,
                    middleExtended: true
                )
                engine.process(hand: openPalmHand)
                engine.tick(nowOverride: t)
                try assertTrue(engine.currentState == .pointing, "🖐️ 열린 손 이동 중에는 상태가 무조건 .pointing이어야 함 (실제: \(engine.currentState))")
            }

            // (b) 👆 검지만 펴고 중지·약지·새끼는 접은 상태로 상하좌우 크게 이동 25프레임 (중지가 반쯤 들려 보여도 검지보다 낮으면 무조건 .pointing)
            for i in 0..<25 {
                t += 1.0 / 60.0
                let dx = CGFloat(i) * 0.006
                let dy = CGFloat(i) * 0.004
                let singleFingerHand = makeHand(
                    timestamp: t,
                    indexTip: CGPoint(x: 0.45 + dx, y: 0.58 + dy),
                    thumbTip: CGPoint(x: 0.30, y: 0.42 + dy),  // L자 엄지 유지 (합성 손은 MCP 고정)
                    middleTip: CGPoint(x: 0.49 + dx, y: 0.49 + dy),
                    ringCurled: true,
                    littleCurled: true,
                    middleExtended: false
                )
                engine.process(hand: singleFingerHand)
                engine.tick(nowOverride: t)
            }

            try assertTrue(falseScrolls == 0, "🖐️ 열린 손 또는 👆 한 손가락으로 커서 이동 중 스크롤이 절대 발생하면 안 됨 (발생: \(falseScrolls)회)")
            try assertTrue(falseDrags == 0, "🖐️에서 👆 자세로 바꾸어 커서를 이동할 때 드래그가 걸리면 안 됨 (발생: \(falseDrags)회)")
            try assertTrue(engine.currentState == .pointing, "이동 종료 후 상태가 .pointing이어야 함 (실제: \(engine.currentState))")
        }

        // 11. 손 고정: 두 번째 손이 들어와도 원래 손(같은 좌우, 가까운 위치)을 유지
        check("11. 손 고정 (chirality + 근접도 선택)") {
            let right = (chirality: VNChirality.right, indexTip: CGPoint(x: 0.30, y: 0.50) as CGPoint?)
            let left = (chirality: VNChirality.left, indexTip: CGPoint(x: 0.52, y: 0.50) as CGPoint?)
            let last = CGPoint(x: 0.50, y: 0.50)
            try assertTrue(HandPoseDetector.selectHand(candidates: [left, right], locked: .right, lastIndexTip: last) == 1,
                           "고정된 오른손이 더 멀어도 오른손을 골라야 함")
            try assertTrue(HandPoseDetector.selectHand(candidates: [right, left], locked: .unknown, lastIndexTip: last) == 1,
                           "좌우 미고정이면 직전 검지에 가까운 손을 골라야 함")
            try assertTrue(HandPoseDetector.selectHand(candidates: [left], locked: .right, lastIndexTip: last) == 0,
                           "고정된 손이 없으면 남은 손으로 폴백해야 함")
            try assertTrue(HandPoseDetector.selectHand(candidates: [], locked: .right, lastIndexTip: last) == nil,
                           "후보가 없으면 nil")
        }

        // 12. 신뢰도 게이트: 엄지 끝 신뢰도가 낮으면 클릭으로 진입하지 않음
        check("12. 저신뢰 엄지 끝 붙이기 무시") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var t: CFAbsoluteTime = 1100.0
            for _ in 0..<10 { t += 1.0 / 60.0; engine.process(hand: makeHand(timestamp: t)) }

            t += 1.0 / 60.0
            var blurry = touchingHand(timestamp: t)
            blurry.confidences[.thumbTip] = 0.30
            engine.process(hand: blurry)
            try assertTrue(!engine.isPressed, "신뢰도 0.30 엄지 끝으로는 눌리면 안 됨")

            var clear = blurry
            clear.confidences[.thumbTip] = 0.90
            for _ in 0..<5 {
                clear.timestamp += 1.0 / 60.0
                engine.process(hand: clear)
            }
            try assertTrue(engine.isPressed, "신뢰도 0.90이 이어지면 눌려야 함")
        }

        // 13. 시간 기반 무장: 30fps든 60fps든 엄지를 벌린 지 0.12초가 지나야 무장
        check("13. 시간 기반 무장 (30fps·60fps 동일 체감 시간)") {
            for fps in [30.0, 60.0] {
                let engine = GestureEngine(startInterpolator: false)
                engine.suppressSystemEvents = true
                var t: CFAbsoluteTime = 1200.0
                // 0.08초만 벌렸다가 바로 붙이면 무장 전이라 클릭 안 됨
                for _ in 0..<Int(0.08 * fps) { t += 1.0 / fps; engine.process(hand: makeHand(timestamp: t)) }
                for _ in 0..<Int(0.2 * fps) { t += 1.0 / fps; engine.process(hand: touchingHand(timestamp: t)) }
                try assertTrue(!engine.isPressed, "\(Int(fps))fps: 0.08초만 벌렸으면 무장 전이라 눌리면 안 됨")
                // 0.2초 벌린 뒤 붙이면 클릭
                for _ in 0..<Int(0.2 * fps) { t += 1.0 / fps; engine.process(hand: makeHand(timestamp: t)) }
                for _ in 0..<Int(0.1 * fps) { t += 1.0 / fps; engine.process(hand: touchingHand(timestamp: t)) }
                try assertTrue(engine.isPressed, "\(Int(fps))fps: 0.2초 벌린 뒤 붙이면 눌려야 함")
            }
        }

        // 14. 재앵커: 손을 기준점에서 옮긴 채 스크롤을 끝내도 커서가 손 위치로 점프하지 않음
        check("14. 스크롤 종료 후 커서 점프 없음 (재앵커)") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var lastMove: CGPoint?
            engine.onEventEmitted = { ev in
                if case .move = ev.kind { lastMove = ev.point }
            }
            var t: CFAbsoluteTime = 1300.0
            func frame(_ h: HandPoseData) {
                engine.process(hand: h)
                for k in 1...8 { engine.tick(nowOverride: t + Double(k) / 240.0) }
            }
            func scrollPose(_ off: CGVector) -> HandPoseData {
                makeHand(timestamp: t, indexTip: CGPoint(x: 0.48, y: 0.62), thumbTip: CGPoint(x: 0.34, y: 0.46),
                         middleTip: CGPoint(x: 0.52, y: 0.62), ringCurled: true, littleCurled: true,
                         middleExtended: true, offset: off)
            }
            for _ in 0..<30 { t += 1.0 / 30.0; frame(makeHand(timestamp: t, indexTip: CGPoint(x: 0.48, y: 0.62))) }
            // 자세를 먼저 잡고(스크롤 확정), 그다음 손을 위로 옮겨 스크롤
            for _ in 0..<8 { t += 1.0 / 30.0; frame(scrollPose(.zero)) }
            guard let before = lastMove else { throw TestFailure("호버 중 커서 이동 이벤트가 없음") }
            let up = CGVector(dx: 0, dy: 0.15)
            for _ in 0..<20 { t += 1.0 / 30.0; frame(scrollPose(up)) }
            try assertTrue(engine.currentState == .scrolling, "스크롤 중이어야 함")
            // 손을 위로 옮긴 채 스크롤 자세를 풀고 포인팅
            // (검지 끝은 스크롤 자세 때와 같은 자리, 중지만 접음 → 손 자체는 움직이지 않음)
            for _ in 0..<10 {
                t += 1.0 / 30.0
                frame(makeHand(timestamp: t, indexTip: CGPoint(x: 0.48, y: 0.62), offset: up))
            }
            let after = lastMove ?? before
            let jump = hypot(after.x - before.x, after.y - before.y)
            try assertTrue(jump < 15, "스크롤 후 커서는 원래 자리 근처여야 함 (이동: \(Int(jump))px)")
        }

        // 15. 랜드마크 기록 형식 왕복 + 엄지 보정 계산
        check("15. 기록 JSONL 왕복 및 엄지 보정 임계값") {
            let h = touchingHand(timestamp: 42.5)
            guard let back = LandmarkCodec.decode(LandmarkCodec.encode(h, t: 42.5)), let hb = back.hand else {
                throw TestFailure("디코드 실패")
            }
            try assertTrue(back.t == 42.5 && hb.points.count == h.points.count, "시각·관절 수가 같아야 함")
            try assertTrue(abs((hb.thumbIndexRatio ?? 9) - (h.thumbIndexRatio ?? 0)) < 1e-6, "엄지 비율이 같아야 함")
            try assertTrue(LandmarkCodec.decode(LandmarkCodec.encode(nil, t: 1.0))?.hand == nil, "손 없음 프레임 왕복")

            let samples = (0..<40).map { i -> CGFloat in i % 2 == 0 ? 0.10 : 0.80 }
            guard let th = ThumbCalibration.thresholds(from: samples) else { throw TestFailure("보정 실패") }
            try assertTrue(th.enter < th.exit && th.exit < th.approach, "누름 < 뗌 < 접근 순서")
            try assertTrue(abs(th.enter - 0.345) < 0.01, "누름 = 붙임 + 35% (실제 \(th.enter))")
            try assertTrue(ThumbCalibration.thresholds(from: Array(repeating: 0.5, count: 40)) == nil, "변화가 없으면 보정 실패")
        }

        print("====================================================")
        print("📊 테스트 결과 요약: 총 \(passed + failed)개 중 \(passed)개 통과, \(failed)개 실패")
        print("====================================================")
        return failed == 0 ? 0 : 1
    }
}
