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
    var littleTip: CGPoint? { points[.littleTip] }
    var wrist: CGPoint? { points[.wrist] }

    var isValid: Bool {
        indexTip != nil && thumbTip != nil && wrist != nil
    }

    /// 손바닥 기준 척도 (검지 관절과 손목 간 거리)
    var palmScale: CGFloat {
        guard let mcp = indexMCP, let w = wrist else { return 0.2 }
        let d = hypot(mcp.x - w.x, mcp.y - w.y)
        return max(d, 0.05)
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
    private let confidenceThreshold: Float = 0.35

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
