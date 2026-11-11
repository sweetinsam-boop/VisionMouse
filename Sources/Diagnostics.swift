import Foundation
import Vision

// 손 랜드마크 기록·재생과 엄지 임계값 보정.
// 실제 손 데이터로 제스처 임계값을 맞추고, 오인식 사례를 그대로 재현하기 위한 도구.

/// 한 프레임을 JSONL 한 줄로 변환. {"t":시각,"a":종횡비,"p":{관절:[x,y,신뢰도]}} 또는 손이 없으면 {"t":시각,"none":true}
enum LandmarkCodec {
    static func encode(_ hand: HandPoseData?, t: CFAbsoluteTime) -> String {
        var obj: [String: Any] = ["t": t]
        if let hand = hand {
            obj["a"] = Double(hand.aspectRatio)
            var pts: [String: [Double]] = [:]
            for (joint, p) in hand.points {
                pts[joint.rawValue.rawValue] = [Double(p.x), Double(p.y), Double(hand.confidences[joint] ?? 1)]
            }
            obj["p"] = pts
        } else {
            obj["none"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ line: String) -> (t: CFAbsoluteTime, hand: HandPoseData?)? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? Double else { return nil }
        if obj["none"] as? Bool == true { return (t, nil) }
        var hand = HandPoseData(timestamp: t, aspectRatio: CGFloat(obj["a"] as? Double ?? 4.0 / 3.0))
        for (key, v) in (obj["p"] as? [String: [Double]]) ?? [:] where v.count == 3 {
            let joint = VNHumanHandPoseObservation.JointName(rawValue: VNRecognizedPointKey(rawValue: key))
            hand.points[joint] = CGPoint(x: v[0], y: v[1])
            hand.confidences[joint] = Float(v[2])
        }
        return (t, hand)
    }
}

/// 카메라 프레임을 ~/Library/Logs/VisionMouse/record-날짜.jsonl 로 기록 (최대 3분 후 자동 중지)
final class LandmarkRecorder {
    static let maxDuration: CFAbsoluteTime = 180
    private let queue = DispatchQueue(label: "com.aimmac.VisionMouse.recorder")
    private var handle: FileHandle?
    private var startTime: CFAbsoluteTime = 0
    private(set) var url: URL?
    /// 3분이 지나 자동 중지되면 메인 스레드에서 호출
    var onAutoStop: (() -> Void)?

    var isRecording: Bool { queue.sync { handle != nil } }

    func start() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VisionMouse")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = dir.appendingPathComponent("record-\(stamp).jsonl")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        queue.sync {
            handle = h
            startTime = CFAbsoluteTimeGetCurrent()
            url = fileURL
        }
        return fileURL
    }

    func stop() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    func append(_ hand: HandPoseData?) {
        let t = hand?.timestamp ?? CFAbsoluteTimeGetCurrent()
        queue.async { [weak self] in
            guard let self = self, let h = self.handle else { return }
            h.write(Data((LandmarkCodec.encode(hand, t: t) + "\n").utf8))
            if CFAbsoluteTimeGetCurrent() - self.startTime > LandmarkRecorder.maxDuration {
                try? h.close()
                self.handle = nil
                DispatchQueue.main.async { self.onAutoStop?() }
            }
        }
    }
}

/// `VisionMouse --replay 파일.jsonl`: 기록을 GestureEngine에 다시 넣어 클릭·드래그·스크롤 결과와 엄지 비율 분포를 출력
enum ReplayRunner {
    static func run(path: String) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("파일을 읽을 수 없음: \(path)")
            return 1
        }
        let frames = text.split(separator: "\n").compactMap { LandmarkCodec.decode(String($0)) }
        guard let first = frames.first else {
            print("프레임 없음")
            return 1
        }

        let engine = GestureEngine(startInterpolator: false)
        engine.suppressSystemEvents = true
        var clicks: [Int] = []
        var dragEvents = 0
        var scrollSessions = 0
        var scrollX: Int64 = 0
        var scrollY: Int64 = 0
        engine.onEventEmitted = { ev in
            switch ev.kind {
            case let .leftDown(n): clicks.append(n)
            case .leftDragged: dragEvents += 1
            case .scrollBegan: scrollSessions += 1
            case let .scroll(dx, dy): scrollX += Int64(dx); scrollY += Int64(dy)
            default: break
            }
        }

        var ratios: [CGFloat] = []
        var lastState: GestureState?
        print("재생: \(frames.count)프레임, \(String(format: "%.1f", (frames.last?.t ?? first.t) - first.t))초")
        for (i, frame) in frames.enumerated() {
            engine.process(hand: frame.hand)
            if let r = frame.hand?.thumbIndexRatio { ratios.append(r) }
            let state = engine.currentState
            if state != lastState {
                print(String(format: "  %7.2fs  %@", frame.t - first.t, state.rawValue))
                lastState = state
            }
            // 다음 프레임까지 240Hz로 tick (스크롤·커서 보간 재현)
            let next = i + 1 < frames.count ? frames[i + 1].t : frame.t + 1.0 / 30.0
            var tt = frame.t + 1.0 / 240.0
            while tt < next {
                engine.tick(nowOverride: tt)
                tt += 1.0 / 240.0
            }
        }

        print("결과: 클릭 \(clicks.count)회 (clickState \(clicks)), 드래그 이벤트 \(dragEvents)개, 스크롤 \(scrollSessions)회 (x \(scrollX)px, y \(scrollY)px)")
        if !ratios.isEmpty {
            let sorted = ratios.sorted()
            func pct(_ p: Double) -> CGFloat { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
            print(String(format: "엄지-검지 비율: 최소 %.2f · 10%% %.2f · 50%% %.2f · 90%% %.2f · 최대 %.2f",
                         sorted.first!, pct(0.1), pct(0.5), pct(0.9), sorted.last!))
            if let th = ThumbCalibration.thresholds(from: ratios) {
                print(String(format: "보정 제안: 누름 %.2f · 뗌 %.2f · 접근 %.2f", th.enter, th.exit, th.approach))
            }
        }
        return 0
    }
}

/// 엄지를 벌렸다 붙였다 한 동안의 thumbIndexRatio 샘플로 누름·뗌·접근 임계값을 정한다 (사람마다 엄지 길이·유연성이 다름)
enum ThumbCalibration {
    static func thresholds(from samples: [CGFloat]) -> (enter: CGFloat, exit: CGFloat, approach: CGFloat)? {
        guard samples.count >= 20 else { return nil }
        let sorted = samples.sorted()
        let closed = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let open = sorted[Int(Double(sorted.count - 1) * 0.9)]
        let gap = open - closed
        // 붙인 값과 벌린 값이 충분히 벌어지지 않았으면 동작을 안 했거나 인식이 불안정한 것
        guard gap >= 0.15 else { return nil }
        return (closed + gap * 0.35, closed + gap * 0.60, closed + gap * 0.80)
    }
}
