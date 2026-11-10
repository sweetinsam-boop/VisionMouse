import AppKit
import CoreMedia
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, CameraManagerDelegate, HandPoseDetectorDelegate, GestureEngineDelegate {
    private var statusItem: NSStatusItem!
    private let cameraManager = CameraManager()
    private let handDetector = HandPoseDetector()
    private let gestureEngine = GestureEngine()
    private var hud: FloatingHUD?
    private var isHUDVisible = true
    private var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()

        setupStatusItem()
        setupPipeline()

        hud = FloatingHUD()
        hud?.orderFront(nil)

        startTracking()
    }

    private func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("[VisionMouse] Accessibility permission needed for mouse events.")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "👆"
            btn.toolTip = "VisionMouse (웹캠 손가락 에어마우스)"
        }
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statusTitle = isPaused ? "상태: ⏸️ 일시정지됨" : "상태: 🟢 작동 중"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: #selector(togglePause), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        let hudMenuItem = NSMenuItem(title: isHUDVisible ? "미니 뷰어 숨기기" : "미니 뷰어 보기", action: #selector(toggleHUD), keyEquivalent: "h")
        hudMenuItem.target = self
        menu.addItem(hudMenuItem)

        let sensitivityMenu = NSMenu()
        let sensNormal = NSMenuItem(title: "보통 (권장)", action: #selector(setSensNormal), keyEquivalent: "")
        sensNormal.target = self
        sensNormal.state = .on
        sensitivityMenu.addItem(sensNormal)

        let sensHigh = NSMenuItem(title: "고감도 (작은 손 움직임)", action: #selector(setSensHigh), keyEquivalent: "")
        sensHigh.target = self
        sensitivityMenu.addItem(sensHigh)

        let sensLow = NSMenuItem(title: "저감도 (정밀)", action: #selector(setSensLow), keyEquivalent: "")
        sensLow.target = self
        sensitivityMenu.addItem(sensLow)

        let sensItem = NSMenuItem(title: "포인터 감도", action: nil, keyEquivalent: "")
        sensItem.submenu = sensitivityMenu
        menu.addItem(sensItem)

        menu.addItem(NSMenuItem.separator())

        let tip1 = NSMenuItem(title: "💡 검지 이동: 마우스 커서 이동", action: nil, keyEquivalent: "")
        tip1.isEnabled = false
        menu.addItem(tip1)

        let tip2 = NSMenuItem(title: "💡 엄지+검지 핀치: 좌클릭 / 드래그", action: nil, keyEquivalent: "")
        tip2.isEnabled = false
        menu.addItem(tip2)

        let tip3 = NSMenuItem(title: "💡 엄지+중지 핀치: 우클릭", action: nil, keyEquivalent: "")
        tip3.isEnabled = false
        menu.addItem(tip3)

        let tip4 = NSMenuItem(title: "💡 검지+중지 모아 상하: 스크롤", action: nil, keyEquivalent: "")
        tip4.isEnabled = false
        menu.addItem(tip4)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupPipeline() {
        cameraManager.delegate = self
        handDetector.delegate = self
        gestureEngine.delegate = self
    }

    private func startTracking() {
        cameraManager.requestPermissionAndStart { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "카메라 권한 필요"
                    alert.informativeText = "맥북 내장 카메라를 통해 손가락을 추적하려면 '시스템 설정 > 개인정보 보호 및 보안 > 카메라'에서 권한을 허용해야 합니다."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "확인")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePause() {
        isPaused.toggle()
        gestureEngine.isEnabled = !isPaused
        if let btn = statusItem.button {
            btn.title = isPaused ? "⏸️" : "👆"
        }
        buildMenu()
    }

    @objc private func toggleHUD() {
        isHUDVisible.toggle()
        if isHUDVisible {
            hud?.orderFront(nil)
        } else {
            hud?.orderOut(nil)
        }
        buildMenu()
    }

    @objc private func setSensNormal() {
        gestureEngine.roiMinX = 0.20
        gestureEngine.roiMaxX = 0.80
        gestureEngine.roiMinY = 0.20
        gestureEngine.roiMaxY = 0.80
        buildMenu()
    }

    @objc private func setSensHigh() {
        gestureEngine.roiMinX = 0.30
        gestureEngine.roiMaxX = 0.70
        gestureEngine.roiMinY = 0.30
        gestureEngine.roiMaxY = 0.70
        buildMenu()
    }

    @objc private func setSensLow() {
        gestureEngine.roiMinX = 0.10
        gestureEngine.roiMaxX = 0.90
        gestureEngine.roiMinY = 0.10
        gestureEngine.roiMaxY = 0.90
        buildMenu()
    }

    @objc private func quitApp() {
        cameraManager.stop()
        NSApp.terminate(nil)
    }

    // MARK: - CameraManagerDelegate

    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        handDetector.process(sampleBuffer: sampleBuffer)
    }

    // MARK: - HandPoseDetectorDelegate

    func handPoseDetector(_ detector: HandPoseDetector, didDetect hand: HandPoseData?, frame: CVImageBuffer) {
        gestureEngine.process(hand: hand)
        if isHUDVisible {
            hud?.update(frame: frame, hand: hand, state: gestureEngine.currentState)
        }
    }

    // MARK: - GestureEngineDelegate

    func gestureEngine(_ engine: GestureEngine, didChangeState state: GestureState, point: CGPoint, pinchRatio: CGFloat?) {
        // 제스처 상태 변화 시 추가 처리 필요시 사용
    }
}
