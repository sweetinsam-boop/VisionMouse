import Foundation
import AVFoundation
import CoreMedia

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer)
}

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var delegate: CameraManagerDelegate?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.aimmac.VisionMouse.camera", qos: .userInteractive)
    private var isConfigured = false
    private var currentDevice: AVCaptureDevice?

    var currentDeviceName: String {
        currentDevice?.localizedName ?? "기본 카메라"
    }

    var isLowLatencyMode: Bool = true // 640x480 초저지연 모드 (기본 활성화)

    var isRunning: Bool {
        session.isRunning
    }

    func availableDevices() -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        } else {
            deviceTypes.append(.externalUnknown)
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    func requestPermissionAndStart(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.start()
                }
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func switchDevice(uniqueID: String) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let newDevice = self.availableDevices().first(where: { $0.uniqueID == uniqueID }) else { return }
            self.reconfigure(with: newDevice)
        }
    }

    func setLowLatencyMode(_ enabled: Bool) {
        isLowLatencyMode = enabled
        sessionQueue.async { [weak self] in
            guard let self = self, let dev = self.currentDevice else { return }
            self.reconfigure(with: dev)
        }
    }

    private func configureSession() {
        let devices = availableDevices()
        // 내장 카메라 우선 탐색
        var selected = devices.first(where: {
            $0.localizedName.contains("MacBook") || $0.localizedName.contains("FaceTime")
        })
        if selected == nil {
            selected = devices.first ?? AVCaptureDevice.default(for: .video)
        }

        guard let device = selected else { return }
        reconfigure(with: device)
    }

    private func reconfigure(with device: AVCaptureDevice) {
        session.beginConfiguration()

        // 기존 input/output 제거
        for input in session.inputs {
            session.removeInput(input)
        }
        for out in session.outputs {
            session.removeOutput(out)
        }

        // 초저지연 모드: 640x480 (Vision ANE 추론 2~3ms), 정밀 모드: 720p
        session.sessionPreset = isLowLatencyMode ? .vga640x480 : .hd1280x720

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        currentDevice = device

        // 프레임레이트 최대치 고정 (어두운 조도에서 15fps 드랍 방지)
        do {
            try device.lockForConfiguration()
            var maxFps: Double = 30.0
            for range in device.activeFormat.videoSupportedFrameRateRanges {
                if range.maxFrameRate > maxFps {
                    maxFps = range.maxFrameRate
                }
            }
            let targetFps = min(maxFps, 60.0)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(targetFps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(targetFps))
            device.unlockForConfiguration()
            NSLog("[CameraManager] Locked frame rate to %.0f FPS for %@", targetFps, device.localizedName)
        } catch {
            NSLog("[CameraManager] Could not lock frame rate: %@", "\(error)")
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
        isConfigured = true
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.cameraManager(self, didOutput: sampleBuffer)
    }
}
