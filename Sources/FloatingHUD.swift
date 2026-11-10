import AppKit
import Vision
import CoreMedia

final class HUDView: NSView {
    private var currentImage: CGImage?
    private var currentHand: HandPoseData?
    private var currentState: GestureState = .noHand
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
        statusLabel.frame = NSRect(x: 10, y: 8, width: 140, height: 18)
        addSubview(statusLabel)

        fpsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        fpsLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        fpsLabel.alignment = .right
        fpsLabel.frame = NSRect(x: bounds.width - 70, y: 8, width: 60, height: 18)
        addSubview(fpsLabel)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fpsLabel.frame = NSRect(x: bounds.width - 70, y: 8, width: 60, height: 18)
    }

    func update(frame: CVImageBuffer?, hand: HandPoseData?, state: GestureState) {
        if let frame = frame {
            let ciImage = CIImage(cvImageBuffer: frame)
            let context = CIContext()
            currentImage = context.createCGImage(ciImage, from: ciImage.extent)
        }

        currentHand = hand
        currentState = state

        // FPS 계산
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastFpsCalcTime
        if dt >= 0.5 {
            fps = Double(frameCount) / dt
            frameCount = 0
            lastFpsCalcTime = now
            fpsLabel.stringValue = String(format: "%.0f FPS", fps)
        }

        statusLabel.stringValue = state.rawValue
        switch state {
        case .pinching:
            statusLabel.textColor = .systemGreen
        case .rightClicking:
            statusLabel.textColor = .systemOrange
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

        // 1. 카메라 영상 (반투명 어둡게 렌더링)
        if let img = currentImage {
            ctx.saveGState()
            // 거울 모드로 좌우 반전 렌더링
            ctx.translateBy(x: b.width, y: 0)
            ctx.scaleBy(x: -1.0, y: 1.0)
            ctx.setAlpha(0.55)
            ctx.draw(img, in: b)
            ctx.restoreGState()
        }

        // 2. 손 스켈레톤 드로잉
        guard let hand = currentHand, hand.isValid else { return }

        ctx.saveGState()

        // 스켈레톤 연결선 드로잉
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(2.0)

        for (j1, j2) in HandPoseData.skeletonConnections {
            if let p1 = hand.points[j1], let p2 = hand.points[j2] {
                // 거울 모드 좌표 변환
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
                ctx.setFillColor(currentState == .pinching ? NSColor.systemGreen.cgColor : NSColor.systemCyan.cgColor)
            } else if joint == .thumbTip {
                ctx.setFillColor(currentState == .pinching ? NSColor.systemGreen.cgColor : NSColor.systemYellow.cgColor)
            } else if joint == .middleTip {
                ctx.setFillColor(currentState == .rightClicking ? NSColor.systemOrange.cgColor : NSColor.white.cgColor)
            } else {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            }

            ctx.fillEllipse(in: rect)
        }

        // 3. 핀치 시 검지와 엄지 연결 하이라이트 링
        if let idx = hand.indexTip, let thm = hand.thumbTip {
            let ptIdx = CGPoint(x: (1.0 - idx.x) * b.width, y: idx.y * b.height)
            let ptThm = CGPoint(x: (1.0 - thm.x) * b.width, y: thm.y * b.height)

            if currentState == .pinching {
                ctx.setStrokeColor(NSColor.systemGreen.cgColor)
                ctx.setLineWidth(3.0)
                ctx.move(to: ptIdx)
                ctx.addLine(to: ptThm)
                ctx.strokePath()

                ctx.setStrokeColor(NSColor.systemGreen.cgColor)
                ctx.strokeEllipse(in: CGRect(x: ptIdx.x - 10, y: ptIdx.y - 10, width: 20, height: 20))
            }
        }

        ctx.restoreGState()
    }
}

final class FloatingHUD: NSPanel {
    let hudView: HUDView

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
        contentView = hudView
    }

    func update(frame: CVImageBuffer?, hand: HandPoseData?, state: GestureState) {
        DispatchQueue.main.async { [weak self] in
            self?.hudView.update(frame: frame, hand: hand, state: state)
        }
    }
}
