import AppKit
import Vision
import CoreMedia
import ApplicationServices

final class HUDView: NSView {
    private var currentImage: CGImage?
    private var currentHand: HandPoseData?
    private var currentState: GestureState = .noHand
    private var roiRect: CGRect = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
    private var clickArmed = false
    private var clickProgress: CGFloat = 0.0
    private var fps: Double = 0.0
    private var frameCount = 0
    private var lastFpsCalcTime = CFAbsoluteTimeGetCurrent()

    private let statusLabel = NSTextField(labelWithString: "초기화 중...")
    private let fpsLabel = NSTextField(labelWithString: "0 FPS")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor

        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        statusLabel.textColor = .white
        statusLabel.frame = NSRect(x: 10, y: 8, width: 165, height: 18)
        addSubview(statusLabel)

        fpsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        fpsLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        fpsLabel.alignment = .right
        fpsLabel.frame = NSRect(x: bounds.width - 65, y: 8, width: 55, height: 18)
        addSubview(fpsLabel)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fpsLabel.frame = NSRect(x: bounds.width - 65, y: 8, width: 55, height: 18)
    }

    func update(image: CGImage?, hand: HandPoseData?, state: GestureState, roi: CGRect,
                feedback: (armed: Bool, progress: CGFloat)) {
        if let image = image {
            currentImage = image
        }
        currentHand = hand
        currentState = state
        roiRect = roi
        clickArmed = feedback.armed
        clickProgress = feedback.progress

        // FPS 계산 (카메라 + 비전 추론 프레임레이트)
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastFpsCalcTime
        if dt >= 0.5 {
            fps = Double(frameCount) / dt
            frameCount = 0
            lastFpsCalcTime = now
            fpsLabel.stringValue = String(format: "%.0f FPS", fps)
        }

        if !AXIsProcessTrusted() {
            statusLabel.stringValue = "⚠️ 손쉬운사용 권한 필요(클릭차단)"
            statusLabel.textColor = .systemRed
            needsDisplay = true
            return
        }

        let ratioStr: String
        if state == .scrolling {
            ratioStr = String(format: " · 간격:%.2f", hand?.indexMiddleTipRatio ?? 0.0)
        } else if let ratio = hand?.thumbIndexRatio {
            ratioStr = String(format: " · 엄지:%.2f", ratio)
        } else {
            ratioStr = ""
        }

        // 엄지를 붙인 채 손을 들이밀면 무장 전이라 클릭이 안 되므로 안내
        let hint = (state == .pointing && !feedback.armed) ? " · 엄지를 벌리세요" : ""
        statusLabel.stringValue = state.rawValue + ratioStr + hint
        switch state {
        case .thumbTouching, .dragging:
            statusLabel.textColor = .systemGreen
        case .scrolling:
            statusLabel.textColor = .systemCyan
        case .pointing:
            statusLabel.textColor = .systemBlue
        case .noHand, .idle:
            statusLabel.textColor = .systemGray
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let b = bounds

        // 1. 카메라 영상 (거울 모드로 좌우 반전 렌더링)
        if let img = currentImage {
            ctx.saveGState()
            ctx.translateBy(x: b.width, y: 0)
            ctx.scaleBy(x: -1.0, y: 1.0)
            ctx.setAlpha(0.45)
            ctx.draw(img, in: b)
            ctx.restoreGState()
        }

        // 2. 유효 활동 영역(Active ROI) 가이드 박스 표시
        ctx.saveGState()
        let guideRect = CGRect(
            x: roiRect.origin.x * b.width,
            y: (1.0 - roiRect.maxY) * b.height,
            width: roiRect.width * b.width,
            height: roiRect.height * b.height
        )
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.stroke(guideRect)
        ctx.restoreGState()

        // 3. 손 스켈레톤 드로잉
        guard let hand = currentHand, hand.isValid else { return }

        ctx.saveGState()

        // 스켈레톤 연결선 드로잉
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(2.0)

        for (j1, j2) in HandPoseData.skeletonConnections {
            if let p1 = hand.points[j1], let p2 = hand.points[j2] {
                let pt1 = CGPoint(x: (1.0 - p1.x) * b.width, y: p1.y * b.height)
                let pt2 = CGPoint(x: (1.0 - p2.x) * b.width, y: p2.y * b.height)

                ctx.move(to: pt1)
                ctx.addLine(to: pt2)
                ctx.strokePath()
            }
        }

        // 관절 원 드로잉
        for (joint, pt) in hand.points {
            let drawPt = CGPoint(x: (1.0 - pt.x) * b.width, y: pt.y * b.height)
            let isTip = joint == .indexTip || joint == .thumbTip || joint == .middleTip

            let radius: CGFloat = isTip ? 5.0 : 3.0
            let rect = CGRect(x: drawPt.x - radius, y: drawPt.y - radius, width: radius * 2, height: radius * 2)

            if joint == .indexTip {
                ctx.setFillColor(NSColor.systemCyan.cgColor)
            } else if joint == .thumbTip {
                ctx.setFillColor((currentState == .thumbTouching || currentState == .dragging) ? NSColor.systemGreen.cgColor : NSColor.systemYellow.cgColor)
            } else if joint == .middleTip {
                ctx.setFillColor(currentState == .scrolling ? NSColor.systemCyan.cgColor : NSColor.white.cgColor)
            } else {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            }

            ctx.fillEllipse(in: rect)
        }

        // 4. 엄지 끝 클릭 피드백 링: 다가가는 정도만큼 노란 호, 누름은 초록 원, 드래그는 파란 원
        if let thm = hand.thumbTip {
            let c = CGPoint(x: (1.0 - thm.x) * b.width, y: thm.y * b.height)
            let ringRect = CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)
            ctx.setLineWidth(3.0)
            if currentState == .thumbTouching {
                ctx.setStrokeColor(NSColor.systemGreen.cgColor)
                ctx.strokeEllipse(in: ringRect)
            } else if currentState == .dragging {
                ctx.setStrokeColor(NSColor.systemBlue.cgColor)
                ctx.strokeEllipse(in: ringRect)
            } else if currentState == .pointing && clickArmed && clickProgress > 0.02 {
                ctx.setStrokeColor(NSColor.systemYellow.cgColor)
                ctx.addArc(center: c, radius: 10, startAngle: .pi / 2,
                           endAngle: .pi / 2 - clickProgress * 2 * .pi, clockwise: true)
                ctx.strokePath()
            }
        }

        ctx.restoreGState()
    }
}

final class FloatingHUD: NSPanel {
    let hudView: HUDView
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var imageFrameSkip = 0

    init() {
        let size = NSSize(width: 240, height: 160)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20,
                          width: size.width, height: size.height)

        hudView = HUDView(frame: NSRect(origin: .zero, size: size))

        super.init(contentRect: rect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // 기본적으로 마우스 클릭이 미니 뷰어를 통과하도록 설정하여 우측 상단(탭/창 닫기/링크) 클릭 간섭 방지
        ignoresMouseEvents = true
        contentView = hudView
    }

    /// 백그라운드 큐에서 안전하게 호출됨
    func renderFrame(buffer: CVImageBuffer?, hand: HandPoseData?, state: GestureState, roi: CGRect,
                     feedback: (armed: Bool, progress: CGFloat) = (false, 0)) {
        var cgImage: CGImage?

        // 배경 비디오 이미지는 2프레임당 1회만 변환하여 CPU/GPU 부담 60% 절감
        imageFrameSkip += 1
        if imageFrameSkip % 2 == 0, let buffer = buffer {
            let ciImage = CIImage(cvImageBuffer: buffer)
            cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        DispatchQueue.main.async { [weak self] in
            self?.hudView.update(image: cgImage, hand: hand, state: state, roi: roi, feedback: feedback)
        }
    }
}
