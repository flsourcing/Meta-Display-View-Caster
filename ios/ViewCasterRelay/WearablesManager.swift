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
    @Published private(set) var lastMetaCallback = ""
    @Published private(set) var glassesDevicesLabel = "Glasses: scanning…"
    @Published private(set) var glassesDeviceCount = 0
    @Published private(set) var sdkRegistered = false

    var onVideoFrame: ((VideoFrame) -> Void)?

    private var sdk: any WearablesInterface { Wearables.shared }
    private var deviceSelector: AutoDeviceSelector?
    private var deviceSession: DeviceSession?
    private var glassesStream: MWDATCamera.Stream?
    private var frameListener: Any?
    private var observeTasks: [Task<Void, Never>] = []

    private var registrationConfirmed = false
    private var cameraPermissionConfirmed = false
    private var latestDeviceIDs: [DeviceIdentifier] = []

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
        deviceSelector = AutoDeviceSelector(wearables: sdk)
        applyRegistrationState(sdk.registrationState)
        startObservers()
        Task { await refreshAfterForeground() }
    }

    private func startObservers() {
        observeTasks.forEach { $0.cancel() }
        var tasks: [Task<Void, Never>] = [
            Task { [weak self] in
                guard let self else { return }
                for await state in self.sdk.registrationStateStream() {
                    await MainActor.run {
                        self.applyRegistrationState(state)
                    }
                }
            },
            Task { [weak self] in
                guard let self else { return }
                for await devices in self.sdk.devicesStream() {
                    await MainActor.run {
                        self.updateDevices(devices)
                    }
                }
            },
        ]
        if let selector = deviceSelector {
            tasks.append(Task { [weak self] in
                for await device in selector.activeDeviceStream() {
                    await MainActor.run { [weak self] in
                        guard let self, let device else { return }
                        let name = device.nameOrId()
                        if self.glassesDeviceCount > 0 {
                            self.glassesDevicesLabel = "Glasses: \(self.glassesDeviceCount) detected, active: \(name)"
                        } else {
                            self.glassesDevicesLabel = "Glasses: active \(name)"
                        }
                    }
                }
            })
        }
        observeTasks = tasks
    }

    private func updateDevices(_ devices: [DeviceIdentifier]) {
        latestDeviceIDs = devices
        glassesDeviceCount = devices.count
        if devices.isEmpty {
            glassesDevicesLabel = sdkRegistered
                ? "Glasses: none detected — wear glasses, open Meta AI, Bluetooth on"
                : "Glasses: none (Meta SDK not registered yet)"
        } else {
            let names = devices.prefix(2).map { id in
                sdk.deviceForIdentifier(id)?.nameOrId() ?? "\(id)"
            }
            glassesDevicesLabel = "Glasses: \(devices.count) detected (\(names.joined(separator: ", ")))"
        }
    }

    private func applyRegistrationState(_ state: RegistrationState) {
        registrationStateName = describeRegistrationState(state)
        sdkRegistered = (state == .registered)

        switch state {
        case .registered:
            confirmRegistration()
        case .registering:
            if !registrationConfirmed {
                isRegistered = false
                registrationLabel = "Finish in Meta AI — tap Open to return"
            } else {
                registrationLabel = "Meta AI connected"
            }
            if metaSetupStarted || registrationConfirmed {
                unlockCameraStepIfNeeded()
            }
        case .available:
            if registrationConfirmed && sdkRegistered {
                isRegistered = true
                registrationLabel = "Meta AI connected"
                enableCameraStep()
            } else if metaSetupStarted || registrationConfirmed {
                isRegistered = false
                unlockCameraStepIfNeeded()
                registrationLabel = "SDK not registered — Connect Meta AI again, tap Open when done"
                lastMetaSyncNote = "Confirm buttons alone cannot register — need Open callback from Meta AI"
            } else {
                isRegistered = false
                canRequestCamera = false
                registrationLabel = "Tap Connect Meta AI"
                cameraLabel = "Connect Meta AI first"
            }
        case .unavailable:
            if registrationConfirmed && sdkRegistered {
                isRegistered = true
                registrationLabel = "Meta AI connected"
                enableCameraStep()
            } else if metaSetupStarted || registrationConfirmed {
                unlockCameraStepIfNeeded()
                registrationLabel = "Enable Developer Mode: Meta AI → Settings → your glasses"
            } else {
                isRegistered = false
                canRequestCamera = false
                registrationLabel = "Registration unavailable — enable Developer Mode in Meta AI"
                cameraLabel = "Connect Meta AI first"
            }
        @unknown default:
            if !registrationConfirmed { isRegistered = false }
        }
    }

    private func describeRegistrationState(_ state: RegistrationState) -> String {
        switch state {
        case .registered: return "registered"
        case .registering: return "registering"
        case .available: return "available (SDK not linked — tap Open in Meta AI)"
        case .unavailable: return "unavailable"
        @unknown default: return "unknown"
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

    func userConfirmMetaConnected() {
        markMetaSetupStarted()
        confirmRegistration()
        lastMetaSyncNote = "Saved — still need SDK registered + glasses detected for Live Stream"
        Task { await syncMetaStatus() }
    }

    func userConfirmCameraAllowed() {
        confirmCameraPermission()
        lastMetaSyncNote = "Saved — wear glasses and ensure Meta AI sees them"
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
        guard !sdkRegistered else {
            registrationLabel = "Already connected to Meta AI"
            enableCameraStep()
            return
        }
        markMetaSetupStarted()
        Task { @MainActor in
            do {
                registrationLabel = "Opening Meta AI…"
                try await sdk.startRegistration()
                registrationLabel = "Approve in Meta AI → tap Open (required) to finish"
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
        sdkRegistered = false
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
        lastMetaCallback = url.absoluteString
        do {
            _ = try await sdk.handleUrl(url)
            applyRegistrationState(sdk.registrationState)
            lastMetaSyncNote = sdkRegistered
                ? "Meta callback OK — registered"
                : "Meta callback received but state is still \(registrationStateName)"
        } catch {
            registrationLabel = "Meta callback error: \(error.localizedDescription)"
            lastMetaSyncNote = "Callback error: \(error.localizedDescription)"
        }
        await refreshAfterForeground()
    }

    func refreshAfterForeground() async {
        unlockCameraStepIfNeeded()
        await syncMetaStatus()
    }

    func syncMetaStatus() async {
        applyRegistrationState(sdk.registrationState)
        guard sdkRegistered else {
            lastMetaSyncNote = "SDK not registered — Connect Meta AI and tap Open when Meta AI finishes"
            return
        }
        confirmRegistration()
        do {
            let status = try await sdk.checkPermissionStatus(.camera)
            enableCameraStep()
            if status == .granted {
                confirmCameraPermission()
                lastMetaSyncNote = "Synced — registered, camera granted, \(glassesDeviceCount) glasses"
            } else if !cameraGranted {
                lastMetaSyncNote = "Registered — allow camera in Meta AI (\(glassesDeviceCount) glasses detected)"
            } else {
                lastMetaSyncNote = "Synced — \(glassesDeviceCount) glasses detected"
            }
        } catch {
            lastMetaSyncNote = "Registered but sync failed: \(error.localizedDescription)"
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
        applyRegistrationState(sdk.registrationState)
        await syncMetaStatus()

        guard sdkRegistered else {
            throw WearablesStreamError.notRegistered
        }

        var permissionOK = cameraGranted || cameraPermissionConfirmed
        if !permissionOK, let sdkStatus = try? await sdk.checkPermissionStatus(.camera), sdkStatus == .granted {
            permissionOK = true
        }
        if permissionOK {
            confirmCameraPermission()
        } else {
            throw WearablesStreamError.cameraDenied
        }

        stopGlassesStream()

        if deviceSelector == nil {
            deviceSelector = AutoDeviceSelector(wearables: sdk)
        }

        status("Looking for Meta glasses…")
        try await waitForGlassesDevice(status: status, timeoutSeconds: 60)

        status("Connecting to glasses…")
        let session: DeviceSession
        do {
            session = try createDeviceSession()
        } catch {
            throw mapSessionError(error)
        }
        deviceSession = session

        do {
            try session.start()
        } catch {
            throw mapSessionError(error)
        }

        status("Waiting for glasses session…")
        let deadline = Date().addingTimeInterval(45)
        var sessionReady = false
        for await state in session.stateStream() {
            NSLog("ViewCaster: deviceSession \(state)")
            if state == .started {
                sessionReady = true
                break
            }
            if Date() > deadline {
                throw WearablesStreamError.deviceTimeout
            }
        }
        if !sessionReady {
            throw WearablesStreamError.sessionFailed("Glasses session closed")
        }

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
        status("Camera stream started")

        isStreaming = true
        lastMetaSyncNote = "Glasses stream active"
    }

    private func waitForGlassesDevice(
        status: @escaping (String) -> Void,
        timeoutSeconds: TimeInterval
    ) async throws {
        if !latestDeviceIDs.isEmpty { return }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() <= deadline {
            applyRegistrationState(sdk.registrationState)
            if !latestDeviceIDs.isEmpty { return }
            status("Waiting for glasses — wear them, Meta AI open on phone, Bluetooth on…")
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw WearablesStreamError.noEligibleDevice
    }

    private func createDeviceSession() throws -> DeviceSession {
        if let deviceId = latestDeviceIDs.first {
            let specific = SpecificDeviceSelector(device: deviceId)
            if let session = try? sdk.createSession(deviceSelector: specific) {
                return session
            }
        }
        guard let selector = deviceSelector else {
            throw WearablesStreamError.noEligibleDevice
        }
        return try sdk.createSession(deviceSelector: selector)
    }

    private func mapSessionError(_ error: Error) -> WearablesStreamError {
        let text = error.localizedDescription.lowercased()
        if text.contains("eligible") || text.contains("no device") {
            return .noEligibleDevice
        }
        return .sessionFailed(error.localizedDescription)
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
        case noEligibleDevice
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRegistered:
                return "Meta SDK not registered. Connect Meta AI → approve → tap Open (not app switcher)."
            case .cameraDenied:
                return "Allow glasses camera in Meta AI, then tap confirm below."
            case .streamFailed:
                return "Could not start glasses stream — wear glasses, Meta AI open, Bluetooth on."
            case .deviceTimeout:
                return "Glasses timed out — wear them, wait until Meta AI shows connected."
            case .noEligibleDevice:
                return """
                No eligible glasses found. Wear glasses, open Meta AI on phone, Developer Mode on. \
                Meta state must show registered (not available). Re-connect Meta AI and tap Open.
                """
            case .sessionFailed(let detail):
                return detail
            }
        }
    }
}
