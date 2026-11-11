import AppKit
import CoreMedia
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, CameraManagerDelegate, HandPoseDetectorDelegate, GestureEngineDelegate {
    private var statusItem: NSStatusItem!
    private let cameraManager = CameraManager()
    private let handDetector = HandPoseDetector()
    private let gestureEngine = GestureEngine()
    private let defaults = UserDefaults.standard
    private var hud: FloatingHUD?
    private var isHUDVisible = true
    private var isHUDMovable = false
    private var isPaused = false
    private let recorder = LandmarkRecorder()
    private var calibrationSamples: [CGFloat]?   // nil이 아니면 엄지 보정 수집 중 (메인 스레드에서만 접근)
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()
        checkAccessibilityPermission()

        setupStatusItem()
        setupPipeline()
        setupGlobalShortcut()

        hud = FloatingHUD()
        hud?.ignoresMouseEvents = !isHUDMovable
        if isHUDVisible {
            hud?.orderFront(nil)
        }

        startTracking()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let h = hotKeyHandler { RemoveEventHandler(h) }
        cameraManager.stop()
    }

    private func loadPreferences() {
        defaults.register(defaults: [
            "isHUDVisible": true,
            "isLowLatencyMode": true,
            "sensitivity": SensitivityLevel.normal.rawValue
        ])
        isHUDVisible = defaults.bool(forKey: "isHUDVisible")
        cameraManager.isLowLatencyMode = defaults.bool(forKey: "isLowLatencyMode")
        if let sensRaw = defaults.string(forKey: "sensitivity"),
           let sens = SensitivityLevel(rawValue: sensRaw) {
            gestureEngine.sensitivity = sens
        }
        gestureEngine.aimBlendKnuckle = defaults.bool(forKey: "aimBlendKnuckle")
        // 엄지 보정 결과가 저장돼 있으면 적용 (뗌 > 누름일 때만)
        let enter = defaults.double(forKey: "thumbTouchEnter")
        let exit = defaults.double(forKey: "thumbTouchExit")
        let approach = defaults.double(forKey: "thumbTouchApproach")
        if enter > 0 && exit > enter && approach >= exit {
            gestureEngine.thumbTouchEnter = CGFloat(enter)
            gestureEngine.thumbTouchExit = CGFloat(exit)
            gestureEngine.thumbTouchApproach = CGFloat(approach)
        }
    }

    private func setupGlobalShortcut() {
        // Control + Option + Space 등록형 핫키: 손쉬운 사용 권한 없이 동작하고, 키를 소비해 앞쪽 앱에 전달되지 않음
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.togglePause() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x564D_5345), id: 1) // 'VMSE'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("[VisionMouse] ⌃⌥Space 핫키 등록 실패 (다른 앱이 사용 중일 수 있음): %d", status)
        }
    }

    /// `defaults write com.aimmac.VisionMouse scrollDebugLog -bool YES` 일 때만 ~/Library/Logs/VisionMouse/scroll.csv 기록
    private func setupScrollDebugLog() {
        guard defaults.bool(forKey: "scrollDebugLog") else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VisionMouse")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scroll.csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("# frame,t,refX,refY,palmScale,offX,offY,targetVx,targetVy | tick,t,dt,vx,vy,sx,sy\n".utf8))
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        let queue = DispatchQueue(label: "com.aimmac.VisionMouse.scrolllog")
        gestureEngine.scrollDebugLog = { line in
            queue.async { handle.write(Data((line + "\n").utf8)) }
        }
        NSLog("[VisionMouse] 스크롤 진단 로그: %@", url.path)
    }

    private func checkAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            // 기존 ad-hoc 서명 빌드에서 생성된 구버전 TCC 엔트리가 남아 있으면 권한 토글이 켜져 있어도 클릭/스크롤이 차단됨.
            // 개발자 인증서 서명 빌드로 최초 전환 시 1회 자동 리셋하여 정상 팝업을 유도.
            if !defaults.bool(forKey: "didResetAdhocTCC_v2") {
                defaults.set(true, forKey: "didResetAdhocTCC_v2")
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                task.arguments = ["reset", "Accessibility", "com.aimmac.VisionMouse"]
                try? task.run()
                task.waitUntilExit()
            }
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) {
                NSLog("[VisionMouse] Accessibility permission needed for mouse events.")
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "👆"
            btn.toolTip = "VisionMouse (웹캠 손가락 에어마우스 · 일시정지 단축키: ⌃⌥Space)"
        }
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statusTitle = isPaused
            ? "상태: ⏸️ 일시정지됨 (클릭 또는 ⌃⌥Space로 재개)"
            : "상태: 🟢 작동 중 (클릭 또는 ⌃⌥Space로 일시정지)"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: #selector(togglePause), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)

        if !AXIsProcessTrusted() {
            let axItem = NSMenuItem(title: "⚠️ 손쉬운 사용 권한 필요 (클릭·스크롤 활성화)", action: #selector(resetAndPromptAccessibility), keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
        }

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

        let hudMoveItem = NSMenuItem(title: isHUDMovable ? "미니 뷰어 위치 고정 (클릭 통과 켜기)" : "미니 뷰어 드래그 이동 허용", action: #selector(toggleHUDMovable), keyEquivalent: "")
        hudMoveItem.target = self
        hudMoveItem.state = isHUDMovable ? .on : .off
        menu.addItem(hudMoveItem)

        let sensitivityMenu = NSMenu()
        for level in SensitivityLevel.allCases {
            let it = NSMenuItem(title: level.rawValue, action: #selector(setSensitivityLevel(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = level
            it.state = (gestureEngine.sensitivity == level) ? .on : .off
            sensitivityMenu.addItem(it)
        }
        let currentSensTitle = gestureEngine.sensitivity.rawValue.components(separatedBy: " ").first ?? ""
        let sensItem = NSMenuItem(title: "포인터 감도 (\(currentSensTitle))", action: nil, keyEquivalent: "")
        sensItem.submenu = sensitivityMenu
        menu.addItem(sensItem)

        let aimItem = NSMenuItem(title: "조준: 검지 끝+관절 혼합 (클릭 시 흔들림 감소)", action: #selector(toggleAimBlend), keyEquivalent: "")
        aimItem.target = self
        aimItem.state = gestureEngine.aimBlendKnuckle ? .on : .off
        menu.addItem(aimItem)

        let calibItem = NSMenuItem(title: calibrationSamples == nil ? "엄지 클릭 보정…" : "엄지 클릭 보정 중…",
                                   action: calibrationSamples == nil ? #selector(startThumbCalibration) : nil, keyEquivalent: "")
        calibItem.target = self
        menu.addItem(calibItem)

        let recItem = NSMenuItem(title: recorder.isRecording ? "⏺ 손 동작 기록 중지" : "손 동작 기록 시작 (진단용, 최대 3분)",
                                 action: #selector(toggleRecording), keyEquivalent: "")
        recItem.target = self
        menu.addItem(recItem)

        menu.addItem(NSMenuItem.separator())

        let tip1 = NSMenuItem(title: "💡 검지 이동: 마우스 커서 조준", action: nil, keyEquivalent: "")
        tip1.isEnabled = false
        menu.addItem(tip1)

        let tip2 = NSMenuItem(title: "💡 엄지를 검지에 붙였다 떼기: 좌클릭 (2회: 더블클릭, 붙인 채 이동: 드래그)", action: nil, keyEquivalent: "")
        tip2.isEnabled = false
        menu.addItem(tip2)

        let tip4 = NSMenuItem(title: "💡 검지+중지 붙여 펴고 손을 기준점에서 이동: 조이스틱 스크롤", action: nil, keyEquivalent: "")
        tip4.isEnabled = false
        menu.addItem(tip4)

        let tip5 = NSMenuItem(title: "💡 단축키 ⌃⌥Space: 즉시 일시정지 / 재개", action: nil, keyEquivalent: "")
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
        setupScrollDebugLog()
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

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resetAndPromptAccessibility() {
        // 기존 ad-hoc 서명 시절 묶인 구버전 TCC 항목을 초기화하고 새 인증서 기준으로 권한 팝업 재요청
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", "com.aimmac.VisionMouse"]
        try? task.run()
        task.waitUntilExit()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    @objc private func selectCameraDevice(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            cameraManager.switchDevice(uniqueID: uid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.buildMenu()
            }
        }
    }

    @objc private func toggleLowLatency() {
        let next = !cameraManager.isLowLatencyMode
        defaults.set(next, forKey: "isLowLatencyMode")
        cameraManager.setLowLatencyMode(next)
        buildMenu()
    }

    @objc private func togglePause() {
        isPaused.toggle()
        gestureEngine.isEnabled = !isPaused
        if isPaused {
            cameraManager.stop()
            hud?.renderFrame(buffer: nil, hand: nil, state: .idle, roi: gestureEngine.currentROIRect)
        } else {
            cameraManager.start()
        }
        if let btn = statusItem.button {
            btn.title = isPaused ? "⏸️" : "👆"
        }
        buildMenu()
    }

    @objc private func toggleHUD() {
        isHUDVisible.toggle()
        defaults.set(isHUDVisible, forKey: "isHUDVisible")
        if isHUDVisible {
            hud?.orderFront(nil)
        } else {
            hud?.orderOut(nil)
        }
        buildMenu()
    }

    @objc private func toggleHUDMovable() {
        isHUDMovable.toggle()
        hud?.ignoresMouseEvents = !isHUDMovable
        buildMenu()
    }

    @objc private func setSensitivityLevel(_ sender: NSMenuItem) {
        if let level = sender.representedObject as? SensitivityLevel {
            gestureEngine.sensitivity = level
            defaults.set(level.rawValue, forKey: "sensitivity")
            buildMenu()
        }
    }

    @objc private func toggleAimBlend() {
        gestureEngine.aimBlendKnuckle.toggle()
        defaults.set(gestureEngine.aimBlendKnuckle, forKey: "aimBlendKnuckle")
        buildMenu()
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            if let url = recorder.url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } else {
            recorder.onAutoStop = { [weak self] in self?.buildMenu() }
            if recorder.start() == nil {
                NSLog("[VisionMouse] 기록 파일을 만들 수 없음")
            }
        }
        buildMenu()
    }

    /// 4초 동안 엄지를 벌렸다 붙였다 하게 해서 thumbIndexRatio 분포로 임계값을 정한다. 수집 중에는 클릭이 나가지 않게 엔진을 끈다.
    @objc private func startThumbCalibration() {
        let intro = NSAlert()
        intro.messageText = "엄지 클릭 보정"
        intro.informativeText = "확인을 누른 뒤 4초 동안, 검지를 펴고 엄지를 L자로 벌렸다가 검지에 붙이기를 천천히 3번 반복하세요.\n보정 중에는 클릭이 나가지 않습니다."
        intro.addButton(withTitle: "시작")
        intro.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard intro.runModal() == .alertFirstButtonReturn else { return }

        calibrationSamples = []
        gestureEngine.isEnabled = false
        buildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.finishThumbCalibration()
        }
    }

    private func finishThumbCalibration() {
        let samples = calibrationSamples ?? []
        calibrationSamples = nil
        gestureEngine.isEnabled = !isPaused
        buildMenu()

        let result = NSAlert()
        if let th = ThumbCalibration.thresholds(from: samples) {
            gestureEngine.thumbTouchEnter = th.enter
            gestureEngine.thumbTouchExit = th.exit
            gestureEngine.thumbTouchApproach = th.approach
            defaults.set(Double(th.enter), forKey: "thumbTouchEnter")
            defaults.set(Double(th.exit), forKey: "thumbTouchExit")
            defaults.set(Double(th.approach), forKey: "thumbTouchApproach")
            result.messageText = "보정 완료"
            result.informativeText = String(format: "누름 %.2f · 뗌 %.2f · 접근 %.2f (샘플 %d개)", th.enter, th.exit, th.approach, samples.count)
        } else {
            result.messageText = "보정 실패"
            result.informativeText = "엄지를 벌린 값과 붙인 값의 차이가 충분하지 않거나 손이 잘 보이지 않았습니다 (샘플 \(samples.count)개). 기존 값을 유지합니다."
        }
        NSApp.activate(ignoringOtherApps: true)
        result.runModal()
    }

    @objc private func quitApp() {
        cameraManager.stop()
        NSApp.terminate(nil)
    }

    // MARK: - CameraManagerDelegate

    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        guard !isPaused else { return }
        handDetector.process(sampleBuffer: sampleBuffer)
    }

    // MARK: - HandPoseDetectorDelegate

    func handPoseDetector(_ detector: HandPoseDetector, didDetect hand: HandPoseData?, frame: CVImageBuffer) {
        gestureEngine.process(hand: hand)
        recorder.append(hand)
        if let r = hand?.thumbIndexRatio {
            DispatchQueue.main.async { [weak self] in self?.calibrationSamples?.append(r) }
        }
        if isHUDVisible {
            hud?.renderFrame(buffer: frame, hand: hand, state: gestureEngine.currentState, roi: gestureEngine.currentROIRect,
                             feedback: gestureEngine.clickFeedback)
        }
    }

    // MARK: - GestureEngineDelegate

    func gestureEngine(_ engine: GestureEngine, didChangeState state: GestureState, point: CGPoint, pinchRatio: CGFloat?) {
    }
}
