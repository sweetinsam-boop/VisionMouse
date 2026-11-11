import Foundation
import CoreGraphics
import AppKit
import Vision

enum SelfTestRunner {
    // 표준 손 포즈 생성 헬퍼 (정규화 좌표 [0, 1])
    static func makeHand(
        timestamp: CFAbsoluteTime,
        indexTip: CGPoint = CGPoint(x: 0.50, y: 0.65),
        thumbTip: CGPoint = CGPoint(x: 0.40, y: 0.50),
        middleTip: CGPoint = CGPoint(x: 0.54, y: 0.42),
        ringCurled: Bool = false,
        littleCurled: Bool = false,
        middleExtended: Bool = false,
        includeWrist: Bool = true
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

        return hand
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

        // 2. 하이퍼링크 핀치 클릭 검증 (손가락 오므릴 때 발생하는 50px 이상 검지 흔들림 속에서도 정확한 호버 좌표 클릭 및 드래그 오작동 차단)
        check("2. 하이퍼링크 엄지+검지 핀치 클릭 (검지 흔들림 롤백 & 드래그 오판 방지)") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var events: [EmittedMouseEvent] = []
            engine.onEventEmitted = { events.append($0) }

            var t: CFAbsoluteTime = 100.0
            // (a) 0.4초 동안 하이퍼링크 위치(0.50, 0.65) 위에서 안정적으로 포인팅 호버
            for _ in 0..<24 {
                t += 1.0 / 60.0
                let h = makeHand(timestamp: t, indexTip: CGPoint(x: 0.50, y: 0.65), thumbTip: CGPoint(x: 0.36, y: 0.48))
                engine.process(hand: h)
                engine.tick(nowOverride: t)
            }
            let hoverPoint = events.last?.point ?? .zero
            events.removeAll()

            // (b) 핀치 접근 프레임 (엄지와 검지가 가까워지며 검지 끝이 아래로 살짝 끌려 내려감)
            t += 1.0 / 60.0
            let approachHand = makeHand(timestamp: t, indexTip: CGPoint(x: 0.49, y: 0.62), thumbTip: CGPoint(x: 0.42, y: 0.55))
            engine.process(hand: approachHand)
            engine.tick(nowOverride: t)

            // (c) 핀치 완료 및 0.28초 유지 (검지 끝이 0.65 -> 0.59로 크게 흔들렸지만 드래그로 오판하면 안 됨!)
            for i in 0..<16 {
                t += 1.0 / 60.0
                let jitterX = 0.48 + CGFloat(i % 3) * 0.003
                let jitterY = 0.59 - CGFloat(i % 2) * 0.004
                let pinchedHand = makeHand(timestamp: t, indexTip: CGPoint(x: jitterX, y: jitterY), thumbTip: CGPoint(x: jitterX - 0.015, y: jitterY - 0.015))
                engine.process(hand: pinchedHand)
                engine.tick(nowOverride: t)
            }

            // (d) 핀치 해제
            t += 1.0 / 60.0
            let releaseHand = makeHand(timestamp: t, indexTip: CGPoint(x: 0.50, y: 0.65), thumbTip: CGPoint(x: 0.36, y: 0.48))
            engine.process(hand: releaseHand)
            engine.tick(nowOverride: t)

            let dragEvents = events.filter {
                if case .leftDragged = $0.kind { return true }
                return false
            }
            let downEvents = events.filter {
                if case .leftDown = $0.kind { return true }
                return false
            }
            let upEvents = events.filter {
                if case .leftUp = $0.kind { return true }
                return false
            }

            try assertTrue(dragEvents.isEmpty, "핀치 클릭 중 leftDragged 이벤트가 발생하면 안 됨 (발생 수: \(dragEvents.count))")
            try assertTrue(downEvents.count == 1 && upEvents.count == 1, "leftDown 1회, leftUp 1회가 정확히 발생해야 함 (down: \(downEvents.count), up: \(upEvents.count))")
            let downPt = downEvents[0].point
            let upPt = upEvents[0].point
            try assertTrue(hypot(downPt.x - upPt.x, downPt.y - upPt.y) < 0.01, "mouseDown과 mouseUp 좌표가 완전히 일치해야 함")
            let driftFromHover = hypot(downPt.x - hoverPoint.x, downPt.y - hoverPoint.y)
            try assertTrue(driftFromHover < 5.0, "핀치 시 검지가 흔들려도 원래 호버하던 하이퍼링크 좌표에서 클릭되어야 함 (오차: \(driftFromHover)px)")
        }

        // 3. 처음부터 👆 자세(약지/새끼 접힘)로 진입 시 오클릭 방지 및 약지 접기 클릭 검증
        check("3. 👆 자세 초기 진입 시 오클릭 방지 및 약지+새끼 접기 클릭") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var events: [EmittedMouseEvent] = []
            engine.onEventEmitted = { events.append($0) }

            var t: CFAbsoluteTime = 200.0
            // (a) 처음부터 약지/새끼가 접힌 상태(👆)로 10프레임 이동 -> 클릭이 발동되면 안 됨!
            for _ in 0..<10 {
                t += 1.0 / 60.0
                let h = makeHand(timestamp: t, ringCurled: true, littleCurled: true)
                engine.process(hand: h)
                engine.tick(nowOverride: t)
            }
            try assertTrue(!engine.isPressed, "손이 처음부터 약지/새끼를 접은 채 진입했을 때는 자동 클릭이 걸리면 안 됨")

            // (b) 손가락을 펴서 무장(isCurlArmed = true) 후 다시 접었다 펴기 -> 정상 클릭 발동!
            for _ in 0..<10 {
                t += 1.0 / 60.0
                let openHand = makeHand(timestamp: t, ringCurled: false, littleCurled: false)
                engine.process(hand: openHand)
                engine.tick(nowOverride: t)
            }
            events.removeAll()

            for _ in 0..<8 {
                t += 1.0 / 60.0
                let curledHand = makeHand(timestamp: t, ringCurled: true, littleCurled: true)
                engine.process(hand: curledHand)
                engine.tick(nowOverride: t)
            }
            t += 1.0 / 60.0
            let releaseHand = makeHand(timestamp: t, ringCurled: false, littleCurled: false)
            engine.process(hand: releaseHand)

            let downCount = events.filter { if case .leftDown = $0.kind { return true }; return false }.count
            let upCount = events.filter { if case .leftUp = $0.kind { return true }; return false }.count
            try assertTrue(downCount == 1 && upCount == 1, "약지+새끼 접기 후 펴기 시 정확히 1회 클릭되어야 함")
        }

        // 4. 연속 핀치 시 더블클릭(clickState == 2) 발생 검증
        check("4. 더블클릭 (clickState == 1 -> 2) 정상 주입 검증") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var downClicks: [Int] = []
            engine.onEventEmitted = { ev in
                if case let .leftDown(clicks) = ev.kind {
                    downClicks.append(clicks)
                }
            }

            var t: CFAbsoluteTime = 300.0
            for _ in 0..<12 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t))
                engine.tick(nowOverride: t)
            }
            // 첫 번째 클릭
            for _ in 0..<5 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.50, y: 0.64), thumbTip: CGPoint(x: 0.49, y: 0.63)))
            }
            for _ in 0..<6 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t))
            }
            // 두 번째 클릭 (0.2초 이내)
            for _ in 0..<5 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.50, y: 0.64), thumbTip: CGPoint(x: 0.49, y: 0.63)))
            }
            t += 1.0 / 60.0
            engine.process(hand: makeHand(timestamp: t))

            try assertTrue(downClicks == [1, 2], "연속 클릭 시 clickState가 [1, 2]여야 함 (실제: \(downClicks))")
        }

        // 5. 의도적 홀드 + 이동 시 드래그(leftMouseDragged) 정상 작동 검증
        check("5. 의도적 길게 누르고 이동 시 드래그 앤 드롭 검증") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var events: [EmittedMouseEvent] = []
            engine.onEventEmitted = { events.append($0) }

            var t: CFAbsoluteTime = 400.0
            for _ in 0..<10 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.50, y: 0.50), thumbTip: CGPoint(x: 0.35, y: 0.40)))
                engine.tick(nowOverride: t)
            }
            events.removeAll()

            // 핀치한 채로 0.5초 동안 X: 0.50 -> 0.35로 크게 이동
            for i in 0..<30 {
                t += 1.0 / 60.0
                let x = 0.50 - CGFloat(i) * 0.005
                engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: x, y: 0.50), thumbTip: CGPoint(x: x - 0.01, y: 0.49)))
                engine.tick(nowOverride: t)
            }
            t += 1.0 / 60.0
            engine.process(hand: makeHand(timestamp: t, indexTip: CGPoint(x: 0.35, y: 0.50), thumbTip: CGPoint(x: 0.25, y: 0.40)))

            let dragCount = events.filter { if case .leftDragged = $0.kind { return true }; return false }.count
            let downCount = events.filter { if case .leftDown = $0.kind { return true }; return false }.count
            let upCount = events.filter { if case .leftUp = $0.kind { return true }; return false }.count

            try assertTrue(downCount == 1 && dragCount > 5 && upCount == 1, "드래그 시 leftDown(1) -> leftDragged(\(dragCount)) -> leftUp(1)이 순서대로 발생해야 함")
        }

        // 6. 두 손가락 저속·고속 스크롤 (데드존 증발 방지 & 약지 접힘 좌클릭 간섭 차단)
        check("6. 두 손가락(검지+중지) 부드러운 픽셀 스크롤 및 좌클릭 오작동 차단") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var scrollPixels: Int32 = 0
            var scrollEventCount = 0
            var accidentalClicks = 0
            engine.onEventEmitted = { ev in
                switch ev.kind {
                case let .scroll(dy):
                    scrollPixels += dy
                    scrollEventCount += 1
                case .leftDown, .leftDragged:
                    accidentalClicks += 1
                default:
                    break
                }
            }

            var t: CFAbsoluteTime = 500.0
            // 먼저 일반 포인팅으로 약지/새끼 무장 상태(isCurlArmed = true)를 만듦
            for _ in 0..<5 {
                t += 1.0 / 60.0
                engine.process(hand: makeHand(timestamp: t, ringCurled: false, littleCurled: false))
            }

            // 이제 검지+중지를 나란히 붙여서 펴고(x 간격 0.04, 높이 동일) 약지+새끼는 접은 상태에서 위로 25프레임 이동
            for i in 0..<25 {
                t += 1.0 / 60.0
                let y = 0.56 + CGFloat(i) * 0.0025
                let scrollHand = makeHand(
                    timestamp: t,
                    indexTip: CGPoint(x: 0.48, y: y),
                    thumbTip: CGPoint(x: 0.34, y: 0.38),
                    middleTip: CGPoint(x: 0.52, y: y),
                    ringCurled: true,
                    littleCurled: true,
                    middleExtended: true
                )
                engine.process(hand: scrollHand)
            }

            try assertTrue(accidentalClicks == 0, "두 손가락 스크롤 중 약지/새끼가 접혀 있어도 좌클릭이 발생하면 안 됨 (발생: \(accidentalClicks))")
            try assertTrue(scrollEventCount >= 8 && scrollPixels > 90, "저속 이동에서도 데드존 없이 픽셀 스크롤이 누적 배출되어야 함 (이벤트: \(scrollEventCount)회, 총 픽셀: \(scrollPixels))")
        }

        // 7. 우클릭 논블로킹(Non-blocking) 속도 검증
        check("7. 엄지+중지 우클릭 즉시 응답 (스레드 블로킹 제거 검증)") {
            let engine = GestureEngine(startInterpolator: false)
            engine.suppressSystemEvents = true
            var rightClicks = 0
            engine.onEventEmitted = { ev in
                if case .rightUp = ev.kind { rightClicks += 1 }
            }

            let t0 = CFAbsoluteTimeGetCurrent()
            let rightClickHand = makeHand(
                timestamp: 600.0,
                indexTip: CGPoint(x: 0.46, y: 0.65),
                thumbTip: CGPoint(x: 0.50, y: 0.45),
                middleTip: CGPoint(x: 0.51, y: 0.46),
                ringCurled: false,
                littleCurled: false
            )
            engine.process(hand: rightClickHand)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

            try assertTrue(rightClicks == 1, "우클릭 이벤트가 1회 발생해야 함")
            try assertTrue(elapsedMs < 10.0, "우클릭 처리가 캡처 스레드를 블로킹하지 않아야 함 (소요: \(String(format: "%.2f", elapsedMs))ms)")
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
                    let h = makeHand(timestamp: CFAbsoluteTime(700 + Double(i) * 0.01), ringCurled: i % 2 == 0, littleCurled: i % 2 == 0)
                    engine.process(hand: h)
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

            // 워치독 테스트: 핀치 누름 후 2.0초 동안 프레임이 끊겼을 때 자동 해제되는지 확인
            let pinchHand = makeHand(timestamp: 900.0, indexTip: CGPoint(x: 0.50, y: 0.60), thumbTip: CGPoint(x: 0.49, y: 0.59))
            engine.process(hand: pinchHand)
            try assertTrue(engine.isPressed, "핀치 직후 isPressed == true여야 함")
            engine.tick(nowOverride: 902.0)
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
                    thumbTip: CGPoint(x: 0.35 + dx, y: 0.42 + dy),
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

        print("====================================================")
        print("📊 테스트 결과 요약: 총 \(passed + failed)개 중 \(passed)개 통과, \(failed)개 실패")
        print("====================================================")
        return failed == 0 ? 0 : 1
    }
}
