import AVFoundation
import CoreMedia

/// Rear phone camera fallback when Meta SDK registration is unavailable.
final class PhoneCameraManager: NSObject, @unchecked Sendable {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private var output: AVCaptureVideoDataOutput?
    private var isRunning = false

    func start() async throws {
        guard !isRunning else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw PhoneCameraError.denied
            }
        default:
            throw PhoneCameraError.denied
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            throw PhoneCameraError.noCamera
        }
        session.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "viewcaster.phone.camera"))

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw PhoneCameraError.noCamera
        }
        session.addOutput(videoOutput)
        output = videoOutput
        session.commitConfiguration()

        session.startRunning()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
    }

    enum PhoneCameraError: LocalizedError {
        case denied
        case noCamera

        var errorDescription: String? {
            switch self {
            case .denied: return "Allow camera access in Settings for phone camera fallback."
            case .noCamera: return "Phone camera unavailable."
            }
        }
    }
}

extension PhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }
}
