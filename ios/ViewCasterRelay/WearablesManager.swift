import Foundation
import MWDATCamera
import MWDATCore

/// Meta Wearables DAT — glasses camera registration, permissions, and live stream.
@MainActor
final class WearablesManager: ObservableObject {
    @Published private(set) var registrationLabel = "Tap Connect Meta AI"
    @Published private(set) var cameraLabel = "Tap Allow glasses camera"
    @Published private(set) var isRegistered = false
    @Published private(set) var cameraGranted = false
    @Published private(set) var isStreaming = false

    var onVideoFrame: ((VideoFrame) -> Void)?

    private var sdk: any WearablesInterface { Wearables.shared }
    private var deviceSession: DeviceSession?
    private var glassesStream: MWDATCamera.Stream?
    private var frameListener: Any?
    private var observeTasks: [Task<Void, Never>] = []

    func configure() {
        startObservers()
    }

    private func startObservers() {
        observeTasks.forEach { $0.cancel() }
        observeTasks = [
            Task { [weak self] in
                guard let self else { return }
                for await state in self.sdk.registrationStateStream() {
                    await MainActor.run {
                        switch state {
                        case .registered:
                            self.isRegistered = true
                            self.registrationLabel = "Meta AI connected"
                        default:
                            self.isRegistered = false
                            if self.registrationLabel == "Meta AI connected" {
                                self.registrationLabel = "Tap Connect Meta AI"
                            }
                        }
                    }
                }
            },
        ]
    }

    func connectMetaAI() {
        Task { @MainActor in
            do {
                try await sdk.startRegistration()
                registrationLabel = "Opening Meta AI… approve connection"
            } catch {
                registrationLabel = "Registration failed: \(error.localizedDescription)"
            }
        }
    }

    func requestGlassesCamera() async {
        cameraLabel = "Opening Meta AI for camera permission…"
        do {
            let status = try await sdk.requestPermission(.camera)
            cameraGranted = (status == .granted)
            cameraLabel = cameraGranted
                ? "Glasses camera allowed"
                : "Camera denied — allow in Meta AI app"
        } catch {
            cameraLabel = "Permission error: \(error.localizedDescription)"
        }
    }

    func handleCallback(_ url: URL) async {
        do {
            _ = try await sdk.handleUrl(url)
        } catch {
            registrationLabel = "Meta AI callback failed"
        }
    }

    func startGlassesStream() async throws {
        guard isRegistered else {
            throw WearablesStreamError.notRegistered
        }
        if !cameraGranted {
            await requestGlassesCamera()
            guard cameraGranted else {
                throw WearablesStreamError.cameraDenied
            }
        }

        stopGlassesStream()

        let selector = AutoDeviceSelector(wearables: sdk)
        let session = try sdk.createSession(deviceSelector: selector)
        deviceSession = session
        try session.start()

        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .medium,
            frameRate: 24
        )
        guard let stream = try session.addStream(config: config) else {
            throw WearablesStreamError.streamFailed
        }
        glassesStream = stream

        frameListener = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.onVideoFrame?(frame)
            }
        }

        await stream.start()
        isStreaming = true
    }

    func stopGlassesStream() {
        frameListener = nil
        Task { await glassesStream?.stop() }
        glassesStream = nil
        try? deviceSession?.stop()
        deviceSession = nil
        isStreaming = false
    }

    enum WearablesStreamError: LocalizedError {
        case notRegistered
        case cameraDenied
        case streamFailed

        var errorDescription: String? {
            switch self {
            case .notRegistered: return "Connect Meta AI first."
            case .cameraDenied: return "Allow glasses camera in Meta AI."
            case .streamFailed: return "Could not start glasses stream."
            }
        }
    }
}
