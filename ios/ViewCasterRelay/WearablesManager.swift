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
    @Published private(set) var registrationStateName = "available"

    var onVideoFrame: ((VideoFrame) -> Void)?

    private var sdk: any WearablesInterface { Wearables.shared }
    private var deviceSession: DeviceSession?
    private var glassesStream: MWDATCamera.Stream?
    private var frameListener: Any?
    private var observeTasks: [Task<Void, Never>] = []

    private static let metaSetupKey = "metaSetupStarted"

    init() {
        metaSetupStarted = UserDefaults.standard.bool(forKey: Self.metaSetupKey)
        if metaSetupStarted {
            unlockCameraStepIfNeeded()
        }
    }

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
        registrationStateName = String(describing: state)
        switch state {
        case .registered:
            isRegistered = true
            enableCameraStep()
            registrationLabel = "Meta AI connected"
        case .registering:
            isRegistered = false
            registrationLabel = "Finish in Meta AI — tap Open to return, or switch back here"
            if metaSetupStarted {
                unlockCameraStepIfNeeded()
            } else if !canRequestCamera {
                cameraLabel = "Connect Meta AI first"
            }
        case .available:
            isRegistered = false
            if metaSetupStarted {
                unlockCameraStepIfNeeded()
                registrationLabel = "Returned from Meta AI — tap Allow glasses camera"
            } else {
                canRequestCamera = false
                registrationLabel = "Tap Connect Meta AI"
                cameraLabel = "Connect Meta AI first"
            }
        case .unavailable:
            isRegistered = false
            if metaSetupStarted {
                unlockCameraStepIfNeeded()
                registrationLabel = "Meta state unavailable — try Allow glasses camera anyway"
            } else {
                canRequestCamera = false
                registrationLabel = "Registration unavailable — enable Developer Mode in Meta AI"
                cameraLabel = "Connect Meta AI first"
            }
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

    /// Sync unlock — safe to call on foreground before async SDK calls.
    func unlockCameraStepIfNeeded() {
        guard metaSetupStarted, !cameraGranted else { return }
        canRequestCamera = true
        cameraLabel = "Tap Allow glasses camera"
    }

    func connectMetaAI() {
        guard !isRegistered else {
            registrationLabel = "Already connected to Meta AI"
            enableCameraStep()
            return
        }
        markMetaSetupStarted()
        Task { @MainActor in
            do {
                registrationLabel = "Opening Meta AI…"
                try await sdk.startRegistration()
                registrationLabel = "Approve connection in Meta AI, then return here"
                unlockCameraStepIfNeeded()
            } catch {
                registrationLabel = "Registration failed: \(error.localizedDescription)"
                unlockCameraStepIfNeeded()
            }
        }
    }

    func resetMetaConnection() {
        Task { @MainActor in
            do {
                registrationLabel = "Opening Meta AI to disconnect…"
                try await sdk.startUnregistration()
            } catch {
                registrationLabel = "Reset failed: \(error.localizedDescription)"
            }
        }
    }

    func clearLocalMetaState() {
        metaSetupStarted = false
        isRegistered = false
        cameraGranted = false
        canRequestCamera = false
        UserDefaults.standard.removeObject(forKey: Self.metaSetupKey)
        registrationLabel = "Tap Connect Meta AI"
        cameraLabel = "Connect Meta AI first"
    }

    func markMetaSetupStarted() {
        metaSetupStarted = true
        UserDefaults.standard.set(true, forKey: Self.metaSetupKey)
        unlockCameraStepIfNeeded()
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
                registrationLabel = "Meta callback not recognized — tap Allow glasses camera"
                unlockCameraStepIfNeeded()
            }
        } catch {
            registrationLabel = "Meta callback error: \(error.localizedDescription)"
            unlockCameraStepIfNeeded()
        }
    }

    func refreshAfterForeground() async {
        unlockCameraStepIfNeeded()
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
        if !metaSetupStarted && !isRegistered {
            cameraLabel = "Connect Meta AI first (step 1)"
            return
        }
        unlockCameraStepIfNeeded()
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
