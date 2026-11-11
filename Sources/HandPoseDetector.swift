import Foundation
import Vision
import CoreMedia

struct HandPoseData {
    var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
    var confidences: [VNHumanHandPoseObservation.JointName: Float] = [:]
    var timestamp: CFAbsoluteTime = 0.0
    var aspectRatio: CGFloat = 4.0 / 3.0

    var indexTip: CGPoint? { points[.indexTip] }
    var indexDIP: CGPoint? { points[.indexDIP] }
    var indexPIP: CGPoint? { points[.indexPIP] }
    var indexMCP: CGPoint? { points[.indexMCP] }

    var thumbTip: CGPoint? { points[.thumbTip] }
    var thumbIP: CGPoint? { points[.thumbIP] }
    var thumbMP: CGPoint? { points[.thumbMP] }
    var thumbCMC: CGPoint? { points[.thumbCMC] }

    var middleTip: CGPoint? { points[.middleTip] }
    var middleDIP: CGPoint? { points[.middleDIP] }
    var middlePIP: CGPoint? { points[.middlePIP] }
    var middleMCP: CGPoint? { points[.middleMCP] }

    var ringTip: CGPoint? { points[.ringTip] }
    var ringDIP: CGPoint? { points[.ringDIP] }
    var ringPIP: CGPoint? { points[.ringPIP] }
    var ringMCP: CGPoint? { points[.ringMCP] }

    var littleTip: CGPoint? { points[.littleTip] }
    var littleDIP: CGPoint? { points[.littleDIP] }
    var littlePIP: CGPoint? { points[.littlePIP] }
    var littleMCP: CGPoint? { points[.littleMCP] }

    var wrist: CGPoint? { points[.wrist] }

    /// 관절 신뢰도. 합성 테스트 데이터처럼 신뢰도가 없으면 1.0으로 본다.
    func confidence(_ joint: VNHumanHandPoseObservation.JointName) -> Float {
        confidences[joint] ?? (points[joint] == nil ? 0 : 1)
    }

    var isValid: Bool {
        // 손목이 화각 밖으로 나가더라도 손가락 관절들이 보이면 유효한 손으로 판정
        indexTip != nil && thumbTip != nil && (wrist != nil || indexMCP != nil || thumbMP != nil)
    }

    /// 카메라 프레임 종횡비를 반영한 정규화 유클리드 거리 (손 회전 방향에 따른 척도 왜곡 방지)
    func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = (p1.x - p2.x) * aspectRatio
        let dy = p1.y - p2.y
        return hypot(dx, dy)
    }

    /// 손바닥 기준 척도 (거리 변화 및 손 회전 각도에 강건한 정규화 척도)
    var palmScale: CGFloat {
        var candidates: [CGFloat] = []
        if let mcp = indexMCP, let w = wrist {
            candidates.append(distance(mcp, w))
        }
        if let mmcp = middleMCP, let w = wrist {
            candidates.append(distance(mmcp, w) * 0.95)
        }
        if let imcp = indexMCP, let lmcp = littleMCP {
            candidates.append(distance(imcp, lmcp) * 1.45)
        }
        if !candidates.isEmpty {
            let best = candidates.max() ?? 0.18
            return max(best, 0.06)
        }
        if let mcp = indexMCP, let pip = indexPIP {
            return max(distance(mcp, pip) * 2.3, 0.06)
        }
        if let tmp = thumbMP, let mcp = indexMCP {
            return max(distance(tmp, mcp) * 1.8, 0.06)
        }
        return 0.18
    }

    /// 카메라 거리나 3D 각도(원근 단축)에 영향받지 않는 관절 직선도 기반 손가락 펴짐 점수 (0.0: 완전 접힘 ~ 1.0: 완전 펴짐)
    /// - 원리: 같은 손가락 축 위의 `dist(Tip, MCP) / dist(PIP, MCP)` 비율(펴짐 ~2.0, 접힘 <1.25)과
    ///   `MCP->PIP` 및 `PIP->Tip` 벡터의 코사인 내적(`cosAngle`), 그리고 손목 대비 원위부 순서를 결합합니다.
    func fingerExtensionRatio(mcp: CGPoint?, pip: CGPoint?, dip: CGPoint? = nil, tip: CGPoint?) -> CGFloat? {
        guard let tip = tip else { return nil }
        let scale = palmScale

        if let mcp = mcp, let pip = pip {
            let seg1 = distance(pip, mcp)
            let seg2 = distance(tip, pip)
            let total = distance(tip, mcp)

            guard seg1 > 0.004 && seg2 > 0.004 else {
                return min(total / scale, 1.0)
            }

            // 1. 관절 꺾임 코사인 각도 (-1.0: 완전히 접혀 손바닥 향함, +1.0: 일직선 펴짐)
            let v1x = (pip.x - mcp.x) * aspectRatio
            let v1y = pip.y - mcp.y
            let v2x = (tip.x - pip.x) * aspectRatio
            let v2y = tip.y - pip.y
            let cosAngle = (v1x * v2x + v1y * v2y) / (seg1 * seg2)

            // 2. 마디 비율: 일직선일 때 total / (seg1 + seg2) ≈ 1.0, 접힐 때 < 0.65
            let straightness = total / (seg1 + seg2)

            // 3. 손목이 보이면 끝점(Tip)이 중간마디(PIP)보다 손목에서 더 멀어야 펴진 것임
            var wristFactor: CGFloat = 1.0
            if let w = wrist {
                let tipToWrist = distance(tip, w)
                let pipToWrist = distance(pip, w)
                if tipToWrist < pipToWrist * 1.08 {
                    // 손가락 끝이 PIP보다 손목 쪽으로 말려 들어간 경우 확실한 접힘
                    wristFactor = 0.35
                }
            }

            // 4. 손을 세웠을 때(pip.y > mcp.y) tip.y가 pip.y보다 아래로 꺾이면 접힘
            if pip.y > mcp.y && tip.y < pip.y {
                wristFactor = min(wristFactor, 0.35)
            }

            // cosAngle이 0.25 미만이면 손가락이 굽혀진 상태
            let angleFactor = min(max((cosAngle + 0.35) / 1.15, 0.25), 1.0)
            let rawScore = (total / scale) * straightness * angleFactor * wristFactor
            return min(max(rawScore, 0.0), 1.2)
        }

        if let mcp = mcp {
            let mcpDist = distance(tip, mcp) / scale
            if let w = wrist {
                let wristMetric = (distance(tip, w) / scale) * 0.50
                return min(mcpDist, wristMetric)
            }
            return mcpDist
        }

        if let w = wrist {
            return (distance(tip, w) / scale) * 0.50
        }
        return nil
    }

    var indexExtensionRatio: CGFloat {
        fingerExtensionRatio(mcp: indexMCP, pip: indexPIP, dip: indexDIP, tip: indexTip) ?? 0.9
    }

    var middleExtensionRatio: CGFloat {
        fingerExtensionRatio(mcp: middleMCP, pip: middlePIP, dip: middleDIP, tip: middleTip) ?? 0.0
    }

    var ringExtensionRatio: CGFloat {
        fingerExtensionRatio(mcp: ringMCP, pip: ringPIP, dip: ringDIP, tip: ringTip) ?? 0.0
    }

    var littleExtensionRatio: CGFloat {
        fingerExtensionRatio(mcp: littleMCP, pip: littlePIP, dip: littleDIP, tip: littleTip) ?? 0.0
    }

    /// 조이스틱 스크롤 기준점: 검지·중지 MCP 중점 (없으면 손가락 끝 중점)
    var scrollReferencePoint: CGPoint? {
        if let a = indexMCP, let b = middleMCP { return CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5) }
        if let a = indexTip, let b = middleTip { return CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5) }
        return nil
    }

    /// 엄지-검지 붙임 비율: 엄지 끝과 검지(MCP→PIP→DIP→Tip 꺾은선) 사이 최단 거리 / palmScale.
    /// L자로 엄지를 벌리면 ~0.6 이상, 엄지를 검지 옆면(또는 끝)에 붙이면 0.25 미만.
    var thumbIndexRatio: CGFloat? {
        guard let thm = thumbTip else { return nil }
        let chain = [indexMCP, indexPIP, indexDIP, indexTip].compactMap { $0 }
        guard chain.count >= 2 else { return nil }
        // 종횡비 보정 좌표에서 점-선분 거리
        func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspectRatio, y: p.y) }
        let p = scaled(thm)
        var best = CGFloat.infinity
        for i in 0..<(chain.count - 1) {
            let a = scaled(chain[i]), b = scaled(chain[i + 1])
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let len2 = ab.x * ab.x + ab.y * ab.y
            let t = len2 > 0 ? min(max(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2, 0), 1) : 0
            best = min(best, hypot(p.x - (a.x + t * ab.x), p.y - (a.y + t * ab.y)))
        }
        return best / palmScale
    }

    /// 엄지와 검지 사이의 정규화된 거리 비율
    var pinchRatio: CGFloat? {
        guard let idx = indexTip, let thm = thumbTip else { return nil }
        return distance(idx, thm) / palmScale
    }

    /// 엄지와 중지 사이의 정규화된 거리 비율 (우클릭 제스처용)
    var middlePinchRatio: CGFloat? {
        guard let mid = middleTip, let thm = thumbTip else { return nil }
        return distance(mid, thm) / palmScale
    }

    /// 검지 끝과 중지 끝 사이의 정규화된 거리 비율 (두 손가락 스크롤용)
    var indexMiddleTipRatio: CGFloat? {
        guard let idx = indexTip, let mid = middleTip else { return nil }
        return distance(idx, mid) / palmScale
    }

    /// 약지와 새끼손가락의 손바닥 대비 펴짐/접힘 비율 (0.0~0.48: 접힘, 0.68+: 펼침)
    var lowerFingerCurlRatio: CGFloat {
        var ratios: [CGFloat] = []
        if let r = fingerExtensionRatio(mcp: ringMCP, pip: ringPIP, dip: ringDIP, tip: ringTip) {
            ratios.append(r)
        }
        if let l = fingerExtensionRatio(mcp: littleMCP, pip: littlePIP, dip: littleDIP, tip: littleTip) {
            ratios.append(l)
        }
        guard !ratios.isEmpty else { return 1.0 }
        return ratios.reduce(0, +) / CGFloat(ratios.count)
    }

    /// 약지 및 새끼손가락이 모두 확실히 접혔는지 여부
    var isLowerFingersCurled: Bool {
        lowerFingerCurlRatio < 0.48
    }

    /// 중지가 검지와 대등한 높이/길이로 함께 펴져 있는지 여부
    /// - `👆` (검지만 편 자세)에서는 false가 나오고, `✌️` 또는 `🖐️` 자세에서만 true가 나옵니다.
    var isMiddleCoExtendedWithIndex: Bool {
        guard let idx = indexTip, let mid = middleTip else { return false }
        guard middleExtensionRatio >= 0.62 else { return false }

        // 1. 검지 끝과 중지 끝의 Y 높이 차이가 작아야 함 (중지가 접히면 mid.y가 idx.y보다 훨씬 낮아짐)
        let dyRatio = abs(idx.y - mid.y) / palmScale
        if dyRatio > 0.25 { return false }

        // 2. 중지 길이(MCP~Tip)가 검지 길이(MCP~Tip)의 최소 80% 이상이어야 함
        if let imcp = indexMCP, let mmcp = middleMCP {
            let idxLen = distance(idx, imcp)
            let midLen = distance(mid, mmcp)
            if idxLen > 0.01 && midLen < idxLen * 0.80 {
                return false
            }
        }

        // 3. 손목이 보이면 손목~중지끝 거리가 손목~검지끝 거리의 최소 85% 이상이어야 함
        if let w = wrist {
            let idxW = distance(idx, w)
            let midW = distance(mid, w)
            if idxW > 0.01 && midW < idxW * 0.85 {
                return false
            }
        }

        return true
    }

    /// 두 손가락(검지+중지) 스크롤 자세 여부 판정
    /// - 오직 "검지+중지만 나란히 붙여서 펴고, 약지+새끼는 확실히 접은 자세"에서만 true를 반환합니다.
    /// - `👆` (검지만 편 자세) → 중지가 접혀 있으므로 false (포인팅 보장)
    /// - `🖐️` (손을 다 편 자세) → 약지·새끼가 펴져 있으므로 false (포인팅 보장)
    func isTwoFingerScrollPose(currentlyScrolling: Bool) -> Bool {
        guard let idx = indexTip, let mid = middleTip, let tipDist = indexMiddleTipRatio else { return false }
        let pRatio = pinchRatio ?? 1.0
        let mpRatio = middlePinchRatio ?? 1.0

        // 1. 엄지가 검지나 중지와 핀치 중이면 스크롤이 아님
        guard pRatio > 0.40 && mpRatio > 0.36 else { return false }

        // 2. 검지와 중지가 모두 꼿꼿이 펴져 있고 높이가 나란해야 함 (`👆` 검지 단독 포인팅 완벽 배제)
        let idxMin: CGFloat = currentlyScrolling ? 0.56 : 0.65
        guard indexExtensionRatio >= idxMin && isMiddleCoExtendedWithIndex else { return false }

        // 3. 약지와 새끼손가락은 반드시 접혀 있어야 함 (`🖐️` 열린 손 포인팅 완벽 배제)
        let maxCurl: CGFloat = currentlyScrolling ? 0.54 : 0.46
        guard lowerFingerCurlRatio < maxCurl else { return false }

        // 약지 끝이 보이면 중지 끝보다 확실히 아래에 접혀 있어야 함
        if let rTip = ringTip {
            let ringDrop = (mid.y - rTip.y) / palmScale
            let minDrop: CGFloat = currentlyScrolling ? 0.16 : 0.24
            if ringDrop < minDrop { return false }
        }

        // 4. 검지 끝과 중지 끝이 서로 밀착되어 있어야 함 ("검지+중지 모아")
        let maxTipDist: CGFloat = currentlyScrolling ? 0.42 : 0.33
        guard tipDist < maxTipDist else { return false }

        let dyRatio = abs(idx.y - mid.y) / palmScale
        let maxDy: CGFloat = currentlyScrolling ? 0.26 : 0.20
        if dyRatio > maxDy { return false }

        return true
    }

    /// 스켈레톤 연결선 쌍 (오버레이 드로잉용)
    static let skeletonConnections: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
        // 엄지
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        // 검지
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        // 중지
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        // 약지
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        // 새끼
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        // 손바닥 가로 연결
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP)
    ]
}

protocol HandPoseDetectorDelegate: AnyObject {
    func handPoseDetector(_ detector: HandPoseDetector, didDetect hand: HandPoseData?, frame: CVImageBuffer)
}

final class HandPoseDetector {
    weak var delegate: HandPoseDetectorDelegate?

    private let handPoseRequest: VNDetectHumanHandPoseRequest
    private let confidenceThreshold: Float = 0.25

    // 손 고정: 처음 잡은 손의 좌우(chirality)와 직전 검지 위치로 같은 손을 계속 추적
    private var lockedChirality: VNChirality = .unknown
    private var lastIndexTip: CGPoint?
    private var missStreak = 0

    init() {
        handPoseRequest = VNDetectHumanHandPoseRequest()
        // 두 손을 받아야 두 번째 손이 들어와도 원래 손을 골라낼 수 있음
        handPoseRequest.maximumHandCount = 2
    }

    /// 후보 손 중 추적할 손의 인덱스. 고정된 좌우가 있으면 그 손만, 그중 직전 검지에 가장 가까운 손을 고른다.
    static func selectHand(
        candidates: [(chirality: VNChirality, indexTip: CGPoint?)],
        locked: VNChirality,
        lastIndexTip: CGPoint?
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }
        var pool = Array(candidates.indices)
        if locked != .unknown {
            let same = pool.filter { candidates[$0].chirality == locked }
            if !same.isEmpty { pool = same }
        }
        guard let last = lastIndexTip else { return pool.first }
        return pool.min { a, b in
            let da = candidates[a].indexTip.map { hypot($0.x - last.x, $0.y - last.y) } ?? .infinity
            let db = candidates[b].indexTip.map { hypot($0.x - last.x, $0.y - last.y) } ?? .infinity
            return da < db
        }
    }

    /// 카메라 촬영 시각(PTS)을 CFAbsoluteTime 기준으로 환산. Vision 추론 시간 편차가 1€ 필터 dt에 섞이지 않게 한다.
    static func captureTimestamp(of sampleBuffer: CMSampleBuffer) -> CFAbsoluteTime {
        let now = CFAbsoluteTimeGetCurrent()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return now }
        let age = CMClockGetTime(CMClockGetHostTimeClock()).seconds - pts.seconds
        // PTS가 호스트 시계 기준이 아니면(외장 장치 등) 현재 시각으로 폴백
        guard age >= 0, age < 0.5 else { return now }
        return now - age
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([handPoseRequest])
            let timestamp = HandPoseDetector.captureTimestamp(of: sampleBuffer)

            let observations = handPoseRequest.results ?? []
            let candidates = observations.map { obs -> (chirality: VNChirality, indexTip: CGPoint?) in
                let tip = (try? obs.recognizedPoint(.indexTip)).flatMap { $0.confidence >= confidenceThreshold ? $0.location : nil }
                return (obs.chirality, tip)
            }
            guard let idx = HandPoseDetector.selectHand(candidates: candidates, locked: lockedChirality, lastIndexTip: lastIndexTip) else {
                // 한두 프레임 놓친 것으로 고정을 풀지 않도록 약 0.5초(15프레임) 연속 미검출 시에만 해제
                missStreak += 1
                if missStreak >= 15 {
                    lockedChirality = .unknown
                    lastIndexTip = nil
                }
                delegate?.handPoseDetector(self, didDetect: nil, frame: pixelBuffer)
                return
            }
            missStreak = 0
            let observation = observations[idx]
            if lockedChirality == .unknown { lockedChirality = observation.chirality }
            lastIndexTip = candidates[idx].indexTip ?? lastIndexTip

            let recognizedPoints = try observation.recognizedPoints(.all)
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let aspect: CGFloat = (h > 0) ? CGFloat(w) / CGFloat(h) : (4.0 / 3.0)
            var hand = HandPoseData(timestamp: timestamp, aspectRatio: aspect)

            for (joint, point) in recognizedPoints {
                if point.confidence >= confidenceThreshold {
                    hand.points[joint] = point.location
                    hand.confidences[joint] = point.confidence
                }
            }

            delegate?.handPoseDetector(self, didDetect: hand, frame: pixelBuffer)
        } catch {
            delegate?.handPoseDetector(self, didDetect: nil, frame: pixelBuffer)
        }
    }
}
