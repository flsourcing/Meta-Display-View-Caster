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
                registrationLabel = "Finish in Meta AI — tap Open, or confirm below when done"
            } else {
                registrationLabel = "Meta AI connected"
            }
            if metaSetupStarted || registrationConfirmed {
                unlockCameraStepIfNeeded()
            }
        case .available:
            if registrationConfirmed {
                isRegistered = true
                registrationLabel = "Meta AI connected"
                enableCameraStep()
            } else if metaSetupStarted {
                unlockCameraStepIfNeeded()
                registrationLabel = "If Meta AI shows connected, tap the button below"
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
                registrationLabel = "If Meta AI shows connected, tap the button below"
            } else {
                isRegistered = false
                canRequestCamera = false
                registrationLabel = "Enable Developer Mode in Meta AI (Settings → glasses)"
                cameraLabel = "Connect Meta AI first"
            }
        @unknown default:
            if !registrationConfirmed { isRegistered = false }
        }
    }

    private func confirmRegistration() {
        registrationConfirmed = true
        UserDefaults.standard.set(true, forKey: Self.registrationConfirmedKey)
        isRegistered = true
        enableCameraStep()
        registrationLabel = "Meta AI connected"
    }

    private func confirmCameraPermission() {
        cameraPermissionConfirmed = true
        UserDefaults.standard.set(true, forKey: Self.cameraConfirmedKey)
        cameraGranted = true
        cameraLabel = "Glasses camera allowed"
        canRequestCamera = true
    }

    /// User confirms Meta AI shows the app as connected (SDK sync often misses app-switcher return).
    func userConfirmMetaConnected() {
        markMetaSetupStarted()
        confirmRegistration()
        lastMetaSyncNote = "Meta connection saved"
        Task { await syncMetaStatus() }
    }

    /// User confirms camera is allowed in Meta AI settings.
    func userConfirmCameraAllowed() {
        confirmCameraPermission()
        lastMetaSyncNote = "Camera permission saved"
        Task { await syncMetaStatus() }
    }

    private func enableCameraStep() {
        canRequestCamera = true
        if !cameraGranted {
            cameraLabel = "Tap Allow glasses camera, or confirm below when done"
        }
    }

    func unlockCameraStepIfNeeded() {
        guard (metaSetupStarted || registrationConfirmed), !cameraGranted else { return }
        canRequestCamera = true
        cameraLabel = "Tap Allow glasses camera, or confirm below when done"
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
                registrationLabel = "Approve in Meta AI → tap Open to return, then confirm below"
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
        } catch {
            registrationLabel = "Meta callback error: \(error.localizedDescription)"
        }
        await refreshAfterForeground()
    }

    func refreshAfterForeground() async {
        unlockCameraStepIfNeeded()
        await syncMetaStatus()
    }

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
                lastMetaSyncNote = "Synced — camera granted"
            } else if !cameraGranted {
                lastMetaSyncNote = "SDK: camera not granted yet — confirm below if Meta AI shows allowed"
            }
        } catch {
            lastMetaSyncNote = "SDK sync failed — use confirm buttons if Meta AI looks correct"
            NSLog("ViewCaster: checkPermissionStatus: \(error.localizedDescription)")
        }
    }

    func requestGlassesCamera() async {
        if !metaSetupStarted && !registrationConfirmed {
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
                cameraLabel = "If allowed in Meta AI, tap confirm button below"
            }
        } catch {
            cameraLabel = "If allowed in Meta AI, tap confirm button below"
            await syncMetaStatus()
        }
    }

    func startGlassesStream(status: @escaping (String) -> Void) async throws {
        await syncMetaStatus()

        guard registrationConfirmed || metaSetupStarted || isRegistered else {
            throw WearablesStreamError.notRegistered
        }

        let permissionOK = cameraGranted || cameraPermissionConfirmed
            || (try? await sdk.checkPermissionStatus(.camera)) == .granted
        if permissionOK {
            confirmCameraPermission()
        } else {
            throw WearablesStreamError.cameraDenied
        }

        stopGlassesStream()

        status("Connecting to glasses…")
        let selector = AutoDeviceSelector(wearables: sdk)
        let session = try sdk.createSession(deviceSelector: selector)
        deviceSession = session
        try session.start()

        status("Waiting for glasses (wear them, Bluetooth on)…")
        try await waitForDeviceSessionStarted(session, status: status)

        status("Starting camera stream…")
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
        try await waitForStreamActive(stream, status: status)

        isStreaming = true
        lastMetaSyncNote = "Glasses stream active"
    }

    private func waitForDeviceSessionStarted(
        _ session: DeviceSession,
        status: @escaping (String) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await state in session.stateStream() {
                    NSLog("ViewCaster: deviceSession \(state)")
                    if state == .started { return }
                }
                throw WearablesStreamError.sessionFailed("Glasses session closed")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 45_000_000_000)
                throw WearablesStreamError.deviceTimeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func waitForStreamActive(
        _ stream: MWDATCamera.Stream,
        status: @escaping (String) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    var finished = false
                    _ = stream.statePublisher.listen { streamState in
                        Task { @MainActor in
                            NSLog("ViewCaster: stream state \(streamState)")
                            status("Camera: \(streamState)…")
                            guard !finished else { return }
                            if streamState == .streaming {
                                finished = true
                                cont.resume()
                            }
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw WearablesStreamError.deviceTimeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
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
        case deviceTimeout
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRegistered:
                return "Tap “Meta AI shows connected” below after connecting in Meta AI."
            case .cameraDenied:
                return "Tap “Camera allowed in Meta AI” below, then Live Stream again."
            case .streamFailed:
                return "Could not start glasses stream — wear glasses, open Meta AI, Bluetooth on."
            case .deviceTimeout:
                return "Glasses timed out — wear them, wait for Meta AI to show connected, retry Live Stream."
            case .sessionFailed(let detail):
                return detail
            }
        }
    }
}
