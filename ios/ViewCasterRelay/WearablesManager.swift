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
    @Published private(set) var metaSetupStarted = false

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
            enableCameraStep()
            registrationLabel = "Meta AI connected"
        case .registering:
            isRegistered = false
            registrationLabel = "Finish in Meta AI — tap Open to return, or use app switcher"
            if !canRequestCamera {
                cameraLabel = "Connect Meta AI first"
            }
        case .available:
            isRegistered = false
            if !metaSetupStarted {
                canRequestCamera = false
                registrationLabel = "Tap Connect Meta AI"
                cameraLabel = "Connect Meta AI first"
            }
        case .unavailable:
            isRegistered = false
            canRequestCamera = false
            registrationLabel = "Registration unavailable — enable Developer Mode in Meta AI"
            cameraLabel = "Connect Meta AI first"
        @unknown default:
            isRegistered = false
            registrationLabel = "Unknown registration state"
        }
    }

    private func enableCameraStep() {
        canRequestCamera = true
        if !cameraGranted {
            cameraLabel = "Tap Allow glasses camera"
        }
    }

    func connectMetaAI() {
        guard !isRegistered else {
            registrationLabel = "Already connected to Meta AI"
            enableCameraStep()
            return
        }
        metaSetupStarted = true
        Task { @MainActor in
            do {
                registrationLabel = "Opening Meta AI…"
                try await sdk.startRegistration()
                registrationLabel = "Verify in Meta AI, then return here"
            } catch {
                registrationLabel = "Registration failed: \(error.localizedDescription)"
            }
        }
    }

    func handleCallback(_ url: URL) async {
        NSLog("ViewCaster: handleCallback \(url.absoluteString)")
        do {
            let handled = try await sdk.handleUrl(url)
            if handled {
                isRegistered = true
                enableCameraStep()
                registrationLabel = "Meta AI connected"
                await syncCameraPermissionStatus()
            } else {
                registrationLabel = "Meta AI URL not recognized — try Allow glasses camera"
                enableCameraStepAfterReturn()
            }
        } catch {
            registrationLabel = "Meta AI callback failed: \(error.localizedDescription)"
            enableCameraStepAfterReturn()
        }
    }

    /// User returned from Meta AI (app switcher or Open). Enable step 2 — Meta may already be linked.
    func enableCameraStepAfterReturn() {
        guard metaSetupStarted, !cameraGranted else { return }
        canRequestCamera = true
        cameraLabel = "Tap Allow glasses camera"
        if !isRegistered {
            registrationLabel = "Returned from Meta AI — tap Allow glasses camera next"
        }
    }

    func refreshAfterForeground() async {
        if metaSetupStarted && !isRegistered {
            enableCameraStepAfterReturn()
        }
        await syncCameraPermissionStatus()
        if isRegistered {
            enableCameraStep()
        }
    }

    private func syncCameraPermissionStatus() async {
        guard let status = try? await sdk.checkPermissionStatus(.camera) else { return }
        isRegistered = true
        enableCameraStep()
        cameraGranted = (status == .granted)
        cameraLabel = cameraGranted
            ? "Glasses camera allowed"
            : "Tap Allow glasses camera"
    }

    func requestGlassesCamera() async {
        if !canRequestCamera && !metaSetupStarted {
            cameraLabel = "Connect Meta AI first (step 1)"
            return
        }
        cameraLabel = "Opening Meta AI for camera permission…"
        do {
            let status = try await sdk.requestPermission(.camera)
            isRegistered = true
            enableCameraStep()
            cameraGranted = (status == .granted)
            cameraLabel = cameraGranted
                ? "Glasses camera allowed"
                : "Camera denied — allow in Meta AI app"
        } catch {
            cameraLabel = "Permission error: \(error.localizedDescription)"
        }
    }

    func startGlassesStream() async throws {
        if !isRegistered {
            await syncCameraPermissionStatus()
        }
        guard isRegistered || metaSetupStarted else {
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
