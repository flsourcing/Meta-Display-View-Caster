import AVFoundation
import CoreMedia

/// Rear phone camera fallback when Meta SDK registration is unavailable.
final class PhoneCameraManager: NSObject, @unchecked Sendable {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "viewcaster.phone.camera.session")
    private var output: AVCaptureVideoDataOutput?
    private var isRunning = false

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: PhoneCameraError.noCamera)
                    return
                }
                do {
                    try self.startOnSessionQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnSessionQueue() throws {
        guard !isRunning else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            throw PhoneCameraError.denied
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
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)

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

    func startAfterAuthorization() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            try await start()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw PhoneCameraError.denied }
            try await start()
        default:
            throw PhoneCameraError.denied
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.session.stopRunning()
            self.isRunning = false
        }
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
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleBufferOut: &copy)
        guard status == noErr, let copy else { return }

        let handler = onSampleBuffer
        DispatchQueue.main.async {
            handler?(copy)
        }
    }
}
