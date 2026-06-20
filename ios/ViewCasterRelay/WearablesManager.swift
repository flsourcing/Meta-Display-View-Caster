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
    @Published private(set) var lastMetaSyncNote = ""

    var onVideoFrame: ((VideoFrame) -> Void)?

    private var sdk: any WearablesInterface { Wearables.shared }
    private var deviceSession: DeviceSession?
    private var glassesStream: MWDATCamera.Stream?
    private var frameListener: Any?
    private var observeTasks: [Task<Void, Never>] = []

    private var registrationConfirmed = false
    private var cameraPermissionConfirmed = false

    private static let metaSetupKey = "metaSetupStarted"
    private static let registrationConfirmedKey = "metaRegistrationConfirmed"
    private static let cameraConfirmedKey = "metaCameraConfirmed"

    init() {
        metaSetupStarted = UserDefaults.standard.bool(forKey: Self.metaSetupKey)
        registrationConfirmed = UserDefaults.standard.bool(forKey: Self.registrationConfirmedKey)
        cameraPermissionConfirmed = UserDefaults.standard.bool(forKey: Self.cameraConfirmedKey)
        applyPersistedMetaState()
    }

    private func applyPersistedMetaState() {
        if registrationConfirmed {
            isRegistered = true
            registrationLabel = "Meta AI connected"
            enableCameraStep()
        }
        if cameraPermissionConfirmed {
            cameraGranted = true
            cameraLabel = "Glasses camera allowed"
        } else if metaSetupStarted || registrationConfirmed {
            unlockCameraStepIfNeeded()
        }
    }

    func configure() {
        startObservers()
        Task { await refreshAfterForeground() }
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
            confirmRegistration()
        case .registering:
            if !registrationConfirmed {
                isRegistered = false
                registrationLabel = "Finish in Meta AI — tap Open to return, or switch back here"
            } else {
                registrationLabel = "Meta AI connected"
            }
            if metaSetupStarted || registrationConfirmed {
                unlockCameraStepIfNeeded()
            } else if !canRequestCamera {
                cameraLabel = "Connect Meta AI first"
            }
        case .available:
            if registrationConfirmed {
                isRegistered = true
                registrationLabel = "Meta AI connected"
                enableCameraStep()
            } else if metaSetupStarted {
                unlockCameraStepIfNeeded()
                registrationLabel = "Returned from Meta AI — tap Sync Meta status"
            } else {
                isRegistered = false
                canRequestCamera = false
                registrationLabel = "Tap Connect Meta AI"
                cameraLabel = "Connect Meta AI first"
            }
        case .unavailable:
            if registrationConfirmed {
                isRegistered = true
                registrationLabel = "Meta AI connected"
                enableCameraStep()
            } else if metaSetupStarted {
                unlockCameraStepIfNeeded()
                registrationLabel = "Meta state unavailable — tap Sync Meta status"
            } else {
                isRegistered = false
                canRequestCamera = false
                registrationLabel = "Registration unavailable — enable Developer Mode in Meta AI"
                cameraLabel = "Connect Meta AI first"
            }
        @unknown default:
            if !registrationConfirmed {
                isRegistered = false
            }
            registrationLabel = "Unknown registration state"
        }
    }

    private func confirmRegistration() {
        registrationConfirmed = true
        UserDefaults.standard.set(true, forKey: Self.registrationConfirmedKey)
        isRegistered = true
        enableCameraStep()
        registrationLabel = "Meta AI connected"
        lastMetaSyncNote = "Registration confirmed"
    }

    private func confirmCameraPermission() {
        cameraPermissionConfirmed = true
        UserDefaults.standard.set(true, forKey: Self.cameraConfirmedKey)
        cameraGranted = true
        cameraLabel = "Glasses camera allowed"
        canRequestCamera = true
        lastMetaSyncNote = "Camera permission confirmed"
    }

    private func enableCameraStep() {
        canRequestCamera = true
        if !cameraGranted {
            cameraLabel = "Tap Allow glasses camera"
        }
    }

    func unlockCameraStepIfNeeded() {
        guard (metaSetupStarted || registrationConfirmed), !cameraGranted else { return }
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
        registrationConfirmed = false
        cameraPermissionConfirmed = false
        isRegistered = false
        cameraGranted = false
        canRequestCamera = false
        lastMetaSyncNote = ""
        UserDefaults.standard.removeObject(forKey: Self.metaSetupKey)
        UserDefaults.standard.removeObject(forKey: Self.registrationConfirmedKey)
        UserDefaults.standard.removeObject(forKey: Self.cameraConfirmedKey)
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
            _ = try await sdk.handleUrl(url)
            await refreshAfterForeground()
        } catch {
            registrationLabel = "Meta callback error: \(error.localizedDescription)"
            await refreshAfterForeground()
        }
    }

    func refreshAfterForeground() async {
        unlockCameraStepIfNeeded()
        await syncMetaStatus()
    }

    /// Query Meta SDK — never opens Meta AI.
    func syncMetaStatus() async {
        if registrationStateName.contains("registered") {
            confirmRegistration()
        }

        do {
            let status = try await sdk.checkPermissionStatus(.camera)
            confirmRegistration()
            enableCameraStep()
            if status == .granted {
                confirmCameraPermission()
            } else if !cameraGranted {
                cameraLabel = "Tap Allow glasses camera (or tap Sync Meta status after allowing in Meta AI)"
                lastMetaSyncNote = "Camera not granted yet — sync after allowing in Meta AI"
            }
        } catch {
            lastMetaSyncNote = "Sync: \(error.localizedDescription)"
            NSLog("ViewCaster: checkPermissionStatus failed: \(error.localizedDescription)")
            if registrationConfirmed {
                isRegistered = true
                registrationLabel = "Meta AI connected"
                enableCameraStep()
            }
        }
    }

    func requestGlassesCamera() async {
        if !metaSetupStarted && !isRegistered && !registrationConfirmed {
            cameraLabel = "Connect Meta AI first (step 1)"
            return
        }

        await syncMetaStatus()
        if cameraGranted { return }

        unlockCameraStepIfNeeded()
        cameraLabel = "Opening Meta AI for camera permission…"
        do {
            let status = try await sdk.requestPermission(.camera)
            confirmRegistration()
            enableCameraStep()
            if status == .granted {
                confirmCameraPermission()
            } else {
                cameraLabel = "Camera denied — allow in Meta AI app"
                lastMetaSyncNote = "Request returned: \(status)"
            }
        } catch {
            cameraLabel = "Permission error: \(error.localizedDescription)"
            await syncMetaStatus()
        }
    }

    func startGlassesStream() async throws {
        await syncMetaStatus()

        guard isRegistered || registrationConfirmed || metaSetupStarted else {
            throw WearablesStreamError.notRegistered
        }

        if !cameraGranted {
            if let status = try? await sdk.checkPermissionStatus(.camera), status == .granted {
                confirmCameraPermission()
            } else {
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
        lastMetaSyncNote = "Glasses stream active"
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
            case .notRegistered:
                return "Connect Meta AI first, then tap Sync Meta status."
            case .cameraDenied:
                return "Allow glasses camera in Meta AI, return here, tap Sync Meta status, then Live Stream again."
            case .streamFailed:
                return "Could not start glasses stream — check glasses are connected in Meta AI."
            }
        }
    }
}
