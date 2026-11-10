import AppKit
import CoreMedia
import ApplicationServices
import AVFoundation

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

        let statusTitle = isPaused ? "상태: ⏸️ 일시정지됨" : "상태: 🟢 작동 중 (240Hz 보간)"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: #selector(togglePause), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 1. 카메라 선택 서브메뉴
        let camMenu = NSMenu()
        let devices = cameraManager.availableDevices()
        for dev in devices {
            var label = dev.localizedName
            if dev.localizedName.contains("iPhone") {
                label += " (⚡ 60 FPS 초고속 지원)"
            } else {
                label += " (30 FPS 고정)"
            }
            let it = NSMenuItem(title: label, action: #selector(selectCameraDevice(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = dev.uniqueID
            it.state = (dev.localizedName == cameraManager.currentDeviceName) ? .on : .off
            camMenu.addItem(it)
        }
        let camItem = NSMenuItem(title: "카메라 선택 (\(cameraManager.currentDeviceName))", action: nil, keyEquivalent: "")
        camItem.submenu = camMenu
        menu.addItem(camItem)

        // 2. 초저지연 반응 모드
        let lowLatencyItem = NSMenuItem(title: "⚡ 초저지연 모드 (640x480 ANE 가속)", action: #selector(toggleLowLatency), keyEquivalent: "")
        lowLatencyItem.target = self
        lowLatencyItem.state = cameraManager.isLowLatencyMode ? .on : .off
        menu.addItem(lowLatencyItem)

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

        // 3. 클릭 방식 선택 (약지+새끼 접기 vs 핀치)
        let clickMenu = NSMenu()
        for mode in ClickTriggerMode.allCases {
            let it = NSMenuItem(title: mode.rawValue, action: #selector(setClickTriggerMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode
            it.state = (gestureEngine.clickTriggerMode == mode) ? .on : .off
            clickMenu.addItem(it)
        }
        let clickItem = NSMenuItem(title: "클릭 제스처 방식", action: nil, keyEquivalent: "")
        clickItem.submenu = clickMenu
        menu.addItem(clickItem)

        menu.addItem(NSMenuItem.separator())

        let tip1 = NSMenuItem(title: "💡 검지 이동: 마우스 커서 조준", action: nil, keyEquivalent: "")
        tip1.isEnabled = false
        menu.addItem(tip1)

        let tip2 = NSMenuItem(title: "💡 약지+새끼 접기: 흔들림 없는 좌클릭 / 드래그", action: nil, keyEquivalent: "")
        tip2.isEnabled = false
        menu.addItem(tip2)

        let tip3 = NSMenuItem(title: "💡 엄지+검지 핀치: 보조 좌클릭", action: nil, keyEquivalent: "")
        tip3.isEnabled = false
        menu.addItem(tip3)

        let tip4 = NSMenuItem(title: "💡 엄지+중지 핀치: 우클릭", action: nil, keyEquivalent: "")
        tip4.isEnabled = false
        menu.addItem(tip4)

        let tip5 = NSMenuItem(title: "💡 검지+중지 모아 상하: 스크롤", action: nil, keyEquivalent: "")
        tip5.isEnabled = false
        menu.addItem(tip5)

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

    @objc private func selectCameraDevice(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            cameraManager.switchDevice(uniqueID: uid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.buildMenu()
            }
        }
    }

    @objc private func toggleLowLatency() {
        cameraManager.setLowLatencyMode(!cameraManager.isLowLatencyMode)
        buildMenu()
    }

    @objc private func setClickTriggerMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? ClickTriggerMode {
            gestureEngine.clickTriggerMode = mode
            buildMenu()
        }
    }

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
            hud?.renderFrame(buffer: frame, hand: hand, state: gestureEngine.currentState)
        }
    }

    // MARK: - GestureEngineDelegate

    func gestureEngine(_ engine: GestureEngine, didChangeState state: GestureState, point: CGPoint, pinchRatio: CGFloat?) {
    }
}
