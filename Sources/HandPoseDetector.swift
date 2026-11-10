import Foundation
import Vision
import CoreMedia

struct HandPoseData {
    var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
    var confidences: [VNHumanHandPoseObservation.JointName: Float] = [:]
    var timestamp: CFAbsoluteTime = 0.0

    var indexTip: CGPoint? { points[.indexTip] }
    var indexPIP: CGPoint? { points[.indexPIP] }
    var indexMCP: CGPoint? { points[.indexMCP] }

    var thumbTip: CGPoint? { points[.thumbTip] }
    var thumbIP: CGPoint? { points[.thumbIP] }
    var thumbMP: CGPoint? { points[.thumbMP] }

    var middleTip: CGPoint? { points[.middleTip] }
    var middleMCP: CGPoint? { points[.middleMCP] }

    var ringTip: CGPoint? { points[.ringTip] }
    var ringMCP: CGPoint? { points[.ringMCP] }

    var littleTip: CGPoint? { points[.littleTip] }
    var littleMCP: CGPoint? { points[.littleMCP] }
    var wrist: CGPoint? { points[.wrist] }

    var isValid: Bool {
        // 손목이 화각 밖으로 나가더라도 손가락 관절들이 보이면 유효한 손으로 판정
        indexTip != nil && thumbTip != nil && (wrist != nil || indexMCP != nil || thumbMP != nil)
    }

    /// 손바닥 기준 척도 (거리 변화에 강건한 정규화 척도)
    var palmScale: CGFloat {
        if let mcp = indexMCP, let w = wrist {
            let d = hypot(mcp.x - w.x, mcp.y - w.y)
            return max(d, 0.06)
        }
        // 손목이 잘린 경우: 검지 마디(MCP-PIP) 거리 기반 추정
        if let mcp = indexMCP, let pip = indexPIP {
            let d = hypot(mcp.x - pip.x, mcp.y - pip.y) * 2.3
            return max(d, 0.06)
        }
        // 엄지-중지 관절 기준 대체
        if let tmp = thumbMP, let mcp = indexMCP {
            let d = hypot(tmp.x - mcp.x, tmp.y - mcp.y) * 1.8
            return max(d, 0.06)
        }
        return 0.18
    }

    /// 엄지와 검지 사이의 정규화된 거리 비율
    var pinchRatio: CGFloat? {
        guard let idx = indexTip, let thm = thumbTip else { return nil }
        let dist = hypot(idx.x - thm.x, idx.y - thm.y)
        return dist / palmScale
    }

    /// 엄지와 중지 사이의 정규화된 거리 비율 (우클릭 제스처용)
    var middlePinchRatio: CGFloat? {
        guard let mid = middleTip, let thm = thumbTip else { return nil }
        let dist = hypot(mid.x - thm.x, mid.y - thm.y)
        return dist / palmScale
    }

    /// 약지와 새끼손가락의 손목/손바닥 대비 접힘 비율 (0.0: 완전 접힘, 1.0+: 완전 펼침)
    var lowerFingerCurlRatio: CGFloat {
        let basePoint = wrist ?? indexMCP ?? CGPoint(x: 0.5, y: 0.5)
        var ratios: [CGFloat] = []
        if let tip = ringTip {
            let d = hypot(tip.x - basePoint.x, tip.y - basePoint.y)
            ratios.append(d / palmScale)
        }
        if let tip = littleTip {
            let d = hypot(tip.x - basePoint.x, tip.y - basePoint.y)
            ratios.append(d / palmScale)
        }
        guard !ratios.isEmpty else { return 1.0 }
        return ratios.reduce(0, +) / CGFloat(ratios.count)
    }

    /// 약지 또는 새끼손가락이 접혔는지 여부
    var isLowerFingersCurled: Bool {
        lowerFingerCurlRatio < 0.72
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

    init() {
        handPoseRequest = VNDetectHumanHandPoseRequest()
        handPoseRequest.maximumHandCount = 1
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([handPoseRequest])
            let timestamp = CFAbsoluteTimeGetCurrent()

            guard let observation = handPoseRequest.results?.first else {
                delegate?.handPoseDetector(self, didDetect: nil, frame: pixelBuffer)
                return
            }

            let recognizedPoints = try observation.recognizedPoints(.all)
            var hand = HandPoseData(timestamp: timestamp)

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
