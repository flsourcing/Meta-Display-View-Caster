import Foundation
import MWDATCamera
import MWDATCore

/// Meta Wearables DAT — glasses camera registration, permissions, and live stream.
@MainActor
final class WearablesManager: ObservableObject {
    @Published private(set) var registrationLabel = "Tap Connect Meta AI"
    @Published private(set) var cameraLabel = "Connect Meta AI first"
    @Published private(set) var isRegistered = false
    @Published private(set) var cameraGranted = false
    @Published private(set) var isStreaming = false
    @Published private(set) var canRequestCamera = false

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
                        self.applyRegistrationState(state)
                    }
                }
            },
        ]
    }

    private func applyRegistrationState(_ state: RegistrationState) {
        switch state {
        case .registered:
            isRegistered = true
            canRequestCamera = true
            registrationLabel = "Meta AI connected"
            if cameraLabel == "Connect Meta AI first" {
                cameraLabel = "Tap Allow glasses camera"
            }
        case .registering:
            isRegistered = false
            canRequestCamera = false
            registrationLabel = "Finish verify in Meta AI, then tap Open to return here"
            cameraLabel = "Connect Meta AI first"
        case .available:
            isRegistered = false
            canRequestCamera = false
            registrationLabel = "Tap Connect Meta AI"
            cameraLabel = "Connect Meta AI first"
        case .unavailable:
            isRegistered = false
            canRequestCamera = false
            registrationLabel = "Registration unavailable — enable Developer Mode in Meta AI"
            cameraLabel = "Connect Meta AI first"
        @unknown default:
            isRegistered = false
            canRequestCamera = false
            registrationLabel = "Unknown registration state"
            cameraLabel = "Connect Meta AI first"
        }
    }

    func connectMetaAI() {
        guard !isRegistered else {
            registrationLabel = "Already connected to Meta AI"
            return
        }
        Task { @MainActor in
            do {
                registrationLabel = "Opening Meta AI…"
                try await sdk.startRegistration()
                registrationLabel = "Approve View Caster in Meta AI, then return here"
            } catch {
                registrationLabel = "Registration failed: \(error.localizedDescription)"
            }
        }
    }

    func handleCallback(_ url: URL) async {
        do {
            let handled = try await sdk.handleUrl(url)
            if handled {
                await refreshAfterForeground()
            }
        } catch {
            registrationLabel = "Meta AI callback failed: \(error.localizedDescription)"
        }
    }

    /// Called when returning from Meta AI (app switch or URL callback).
    func refreshAfterForeground() async {
        if let status = try? await sdk.checkPermissionStatus(.camera) {
            if !isRegistered {
                applyRegistrationState(.registered)
            }
            cameraGranted = (status == .granted)
            cameraLabel = cameraGranted
                ? "Glasses camera allowed"
                : "Tap Allow glasses camera"
            return
        }

        if isRegistered {
            cameraLabel = cameraGranted
                ? "Glasses camera allowed"
                : "Tap Allow glasses camera"
        }
    }

    func requestGlassesCamera() async {
        guard isRegistered else {
            cameraLabel = "Connect Meta AI first (step 1)"
            return
        }
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
