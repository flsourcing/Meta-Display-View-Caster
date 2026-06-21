import Foundation
import UIKit
import MWDATCamera
import MWDATCore

enum SetupItemStatus: Equatable {
    case waiting
    case success
}

/// Meta Wearables DAT — glasses camera registration, permissions, and live stream.
@MainActor
final class WearablesManager: ObservableObject {
    @Published private(set) var registrationLabel = "Waiting for connection..."
    @Published private(set) var cameraLabel = "Waiting for approval..."
    @Published private(set) var registrationSetupStatus: SetupItemStatus = .waiting
    @Published private(set) var cameraSetupStatus: SetupItemStatus = .waiting
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
    @Published private(set) var sdkConfigureNote = ""

    private var registrationAttempted = false
    private var registrationOpenedAt: Date?
    private var pendingCameraPermissionRetry = false
    private var urlHandledObserver: NSObjectProtocol?
    private var lastHandledURLTime: Date?
    private var lastHandledURLString: String?
    private var foregroundSyncTask: Task<Void, Never>?
    private var didConfigure = false
    private var pendingFinishAfterManualReturn = false
    private var isFinishingRegistration = false

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
        // Persisted flags only unlock UI steps; SDK registrationState is authoritative.
        if cameraPermissionConfirmed {
            cameraGranted = true
            cameraLabel = "Successful"
        }
        if metaSetupStarted || registrationConfirmed {
            unlockCameraStepIfNeeded()
        }
    }

    private var foregroundObserver: NSObjectProtocol?

    private func ensureMetaSDKReady() {
        if deviceSelector == nil {
            deviceSelector = AutoDeviceSelector(wearables: sdk)
        }
        guard !didConfigure else { return }
        didConfigure = true
        startObservers()
        startRegistrationMonitoring()
        installForegroundObserver()
    }

    func configure(configError: String? = nil) {
        sdkConfigureNote = configError ?? "SDK configured"
        ensureMetaSDKReady()
        applyRegistrationState(sdk.registrationState)
        refreshSetupProgress()
        Task { await onAppBecameActive() }
    }

    private func startRegistrationMonitoring() {
        guard urlHandledObserver == nil else { return }

        urlHandledObserver = NotificationCenter.default.addObserver(
            forName: .wearablesURLHandled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.registrationOpenedAt = nil
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self.onAppBecameActive()
            }
        }
    }

    func handleIncomingURL(_ url: URL) async {
        ensureMetaSDKReady()

        let key = url.absoluteString
        let now = Date()
        if lastHandledURLString == key,
           let last = lastHandledURLTime,
           now.timeIntervalSince(last) < 0.5 {
            return
        }
        lastHandledURLString = key
        lastHandledURLTime = now

        NSLog("ViewCaster: handleIncomingURL \(key)")
        lastMetaCallback = key
        do {
            let handled = try await sdk.handleUrl(url)
            NSLog("ViewCaster: handleUrl handled=\(handled) state=\(sdk.registrationState)")
            registrationOpenedAt = nil
            applyRegistrationState(sdk.registrationState)
            if handled {
                NotificationCenter.default.post(name: .wearablesURLHandled, object: url)
            }
        } catch {
            registrationLabel = "Meta callback error: \(error.localizedDescription)"
            lastMetaSyncNote = "Callback error: \(error.localizedDescription)"
            NSLog("ViewCaster: handleUrl error: \(error.localizedDescription)")
        }

        _ = await ensureRegistrationComplete()
        refreshSetupProgress()
        await finishPendingCameraPermissionIfPossible()
        _ = await resolveCameraPermissionIfAlreadyGranted()
        await syncMetaStatus()
        refreshSetupProgress()
    }

    /// Backward-compatible entry for RelayViewModel.
    func handleCallback(_ url: URL) async {
        await handleIncomingURL(url)
    }

    private func refreshSetupProgress() {
        if isRegistrationReady(sdk.registrationState) {
            registrationSetupStatus = .success
        } else if registrationSetupStatus != .success {
            registrationSetupStatus = .waiting
        }

        if cameraPermissionConfirmed || cameraGranted {
            cameraSetupStatus = .success
        } else if cameraSetupStatus != .success {
            cameraSetupStatus = .waiting
        }
    }

    private func installForegroundObserver() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.onAppBecameActive()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.onAppBecameActive()
            }
        }
    }

    private func startObservers() {
        observeTasks.forEach { $0.cancel() }
        var tasks: [Task<Void, Never>] = [
            Task { [weak self] in
                guard let self else { return }
                for await state in self.sdk.registrationStateStream() {
                    await MainActor.run {
                        self.applyRegistrationState(state)
                        self.refreshSetupProgress()
                        if state == .registered {
                            self.registrationOpenedAt = nil
                            Task { await self.validateCameraPermissionFlag() }
                        }
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
                for await deviceId in selector.activeDeviceStream() {
                    await MainActor.run { [weak self] in
                        guard let self, let deviceId else { return }
                        let name = self.sdk.deviceForIdentifier(deviceId)?.nameOrId() ?? deviceId
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
        isRegistered = sdkRegistered

        switch state {
        case .registered:
            registrationOpenedAt = nil
            confirmRegistration()
        case .registering:
            isRegistered = false
            registrationLabel = "Finishing Meta AI registration..."
            if metaSetupStarted || registrationConfirmed {
                unlockCameraStepIfNeeded()
            }
        case .available:
            isRegistered = false
            if metaSetupStarted || registrationConfirmed {
                unlockCameraStepIfNeeded()
                registrationLabel = "Register the app, allow camera, then use Live Stream on the glasses."
            } else {
                canRequestCamera = false
                registrationLabel = "Waiting for connection..."
                cameraLabel = "Waiting for approval..."
            }
        case .unavailable:
            isRegistered = false
            if registrationAttempted {
                unlockCameraStepIfNeeded()
                registrationLabel = "Registration unavailable. Check Meta AI and Developer Mode."
            } else {
                canRequestCamera = false
                registrationLabel = "Waiting for connection..."
                cameraLabel = "Waiting for approval..."
            }
        @unknown default:
            isRegistered = false
        }
    }

    private func unavailableHelp(state: RegistrationState) -> String {
        state == .unavailable
            ? "Registration unavailable. Check Meta AI and Developer Mode."
            : "Complete registration in Meta AI, then return here."
    }

    private func describeRegistrationState(_ state: RegistrationState) -> String {
        switch state {
        case .registered: return "registered"
        case .registering: return "registering"
        case .available: return "available (finish in Meta AI → tap Open)"
        case .unavailable: return "unavailable (dev mode / Team ID / not eligible)"
        @unknown default: return "unknown"
        }
    }

    private func confirmRegistration() {
        registrationConfirmed = true
        UserDefaults.standard.set(true, forKey: Self.registrationConfirmedKey)
        isRegistered = true
        enableCameraStep()
        registrationLabel = "Registered with Meta AI."
        cameraLabel = cameraGranted ? "Successful" : "Waiting for approval..."
        registrationSetupStatus = .success
    }

    private func confirmCameraPermission() {
        cameraPermissionConfirmed = true
        UserDefaults.standard.set(true, forKey: Self.cameraConfirmedKey)
        cameraGranted = true
        cameraLabel = "Successful"
        canRequestCamera = true
        cameraSetupStatus = .success
    }

    func userConfirmMetaConnected() {
        markMetaSetupStarted()
        lastMetaSyncNote = "Saved UI step only — Live Stream still needs Meta state = registered"
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
            cameraLabel = "Waiting for approval..."
        }
    }

    func unlockCameraStepIfNeeded() {
        guard (metaSetupStarted || registrationConfirmed), !cameraGranted else { return }
        canRequestCamera = true
        cameraLabel = "Waiting for approval..."
    }

    var needsFinishConnection: Bool {
        registrationSetupStatus != .success && (metaSetupStarted || registrationAttempted)
    }

    func connectMetaAI() {
        guard !sdkRegistered else {
            registrationLabel = "Registered with Meta AI."
            enableCameraStep()
            return
        }
        registrationAttempted = true
        pendingFinishAfterManualReturn = true
        Task { @MainActor in
            do {
                registrationLabel = "Opening Meta AI registration..."
                registrationOpenedAt = Date()
                try await sdk.startRegistration()
                markMetaSetupStarted()
                registrationLabel = "Connect in Meta AI, then return here and tap Finish Connection."
                unlockCameraStepIfNeeded()
            } catch RegistrationError.alreadyRegistered {
                registrationOpenedAt = nil
                pendingFinishAfterManualReturn = false
                registrationLabel = "Registered with Meta AI."
                _ = await waitForRegistrationReady(timeoutSeconds: 10)
                applyRegistrationState(sdk.registrationState)
                refreshSetupProgress()
                unlockCameraStepIfNeeded()
            } catch {
                registrationLabel = "Registration unavailable. Check Meta AI and Developer Mode."
                lastMetaSyncNote = unavailableHelp(state: sdk.registrationState)
                unlockCameraStepIfNeeded()
            }
        }
    }

    /// After Connect in Meta AI, sideloaded apps often miss the auto-redirect.
    /// Opens Meta AI developer connections so the user can tap View Caster Relay → triggers viewcaster:// callback.
    func finishRegistrationConnection() async {
        guard registrationSetupStatus != .success else { return }
        guard !isFinishingRegistration else { return }
        isFinishingRegistration = true
        defer { isFinishingRegistration = false }

        ensureMetaSDKReady()
        registrationAttempted = true
        registrationLabel = "Opening Meta AI to finish connection…"

        do {
            try await sdk.openDATGlassesAppUpdate()
            registrationLabel = "In Meta AI, tap View Caster Relay to open this app."
        } catch {
            NSLog("ViewCaster: openDATGlassesAppUpdate failed: \(error.localizedDescription)")
            registrationLabel = "Re-opening Meta AI registration…"
            do {
                try await sdk.startRegistration()
            } catch RegistrationError.alreadyRegistered {
                _ = await waitForRegistrationReady(timeoutSeconds: 15)
            } catch {
                NSLog("ViewCaster: startRegistration retry failed: \(error.localizedDescription)")
            }
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = await waitForRegistrationReady(timeoutSeconds: 25)
        _ = await ensureRegistrationComplete()
        refreshSetupProgress()

        if registrationSetupStatus == .success {
            pendingFinishAfterManualReturn = false
            registrationOpenedAt = nil
        }
    }

    /// True when SDK is ready for glasses camera streaming.
    var canStreamFromGlasses: Bool {
        sdkRegistered
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
        registrationAttempted = false
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

    func refreshAfterForeground() async {
        await onAppBecameActive()
    }

    func onAppBecameActive() async {
        foregroundSyncTask?.cancel()
        foregroundSyncTask = Task { @MainActor in
            unlockCameraStepIfNeeded()

            if pendingFinishAfterManualReturn && registrationSetupStatus != .success {
                pendingFinishAfterManualReturn = false
                await finishRegistrationConnection()
            } else {
                _ = await ensureRegistrationComplete()
            }
            refreshSetupProgress()

            if pendingCameraPermissionRetry {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await finishPendingCameraPermissionIfPossible()
            } else {
                _ = await resolveCameraPermissionIfAlreadyGranted()
            }

            await validateCameraPermissionFlag()
            await syncMetaStatus()
            refreshSetupProgress()
        }
        await foregroundSyncTask?.value
    }

    @discardableResult
    private func ensureRegistrationComplete() async -> Bool {
        applyRegistrationState(sdk.registrationState)
        if isRegistrationReady(sdk.registrationState) {
            registrationOpenedAt = nil
            refreshSetupProgress()
            return true
        }

        if sdk.registrationState == .registering {
            registrationLabel = "Finishing Meta AI registration..."
            if await waitForRegistrationReady(timeoutSeconds: 15) {
                registrationOpenedAt = nil
                refreshSetupProgress()
                return true
            }
        }

        let timeout: TimeInterval = (registrationOpenedAt != nil || registrationAttempted) ? 10 : 3
        if await waitForRegistrationReady(timeoutSeconds: timeout) {
            registrationOpenedAt = nil
            refreshSetupProgress()
            return true
        }

        let currentState = sdk.registrationState
        if currentState == .available, registrationAttempted || metaSetupStarted {
            do {
                try await sdk.openDATGlassesAppUpdate()
                registrationLabel = "In Meta AI, tap View Caster Relay to finish."
                if await waitForRegistrationReady(timeoutSeconds: 20) {
                    registrationOpenedAt = nil
                    refreshSetupProgress()
                    return true
                }
            } catch {
                NSLog("ViewCaster: ensureRegistration openDAT failed: \(error.localizedDescription)")
            }
            do {
                try await sdk.startRegistration()
                registrationLabel = "Complete registration in Meta AI, then return here."
            } catch RegistrationError.alreadyRegistered {
                if await waitForRegistrationReady(timeoutSeconds: 10) {
                    registrationOpenedAt = nil
                    refreshSetupProgress()
                    return true
                }
            } catch {
                if isRegistrationReady(sdk.registrationState) {
                    refreshSetupProgress()
                    return true
                }
            }
        }

        if await waitForRegistrationReady(timeoutSeconds: 8) {
            registrationOpenedAt = nil
            refreshSetupProgress()
            return true
        }

        refreshSetupProgress()
        return isRegistrationReady(sdk.registrationState)
    }

    private func validateCameraPermissionFlag() async {
        guard cameraPermissionConfirmed else {
            if cameraSetupStatus != .success {
                cameraSetupStatus = .waiting
            }
            return
        }

        guard let status = await safeCameraPermissionStatus() else { return }

        if status == .granted {
            confirmCameraPermission()
            return
        }

        if cameraSetupStatus == .success {
            UserDefaults.standard.set(false, forKey: Self.cameraConfirmedKey)
            cameraPermissionConfirmed = false
            cameraGranted = false
            cameraSetupStatus = .waiting
            cameraLabel = "Waiting for approval..."
        }
    }

    private func isRegistrationReady(_ state: RegistrationState) -> Bool {
        state == .registered
    }

    private func waitForRegistrationReady(timeoutSeconds: TimeInterval) async -> Bool {
        applyRegistrationState(sdk.registrationState)
        if isRegistrationReady(sdk.registrationState) {
            return true
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            applyRegistrationState(sdk.registrationState)
            if isRegistrationReady(sdk.registrationState) {
                return true
            }
        }
        return isRegistrationReady(sdk.registrationState)
    }

    private func safeCameraPermissionStatus() async -> PermissionStatus? {
        do {
            return try await sdk.checkPermissionStatus(.camera)
        } catch {
            return nil
        }
    }

    private func waitForCameraPermissionStatus(timeoutSeconds: TimeInterval) async -> PermissionStatus? {
        if let status = await safeCameraPermissionStatus() {
            return status
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let status = await safeCameraPermissionStatus() {
                return status
            }
        }
        return await safeCameraPermissionStatus()
    }

    private func resolveCameraPermissionIfAlreadyGranted() async -> Bool {
        if let status = await waitForCameraPermissionStatus(timeoutSeconds: 1),
           status == .granted {
            confirmCameraPermission()
            pendingCameraPermissionRetry = false
            return true
        }

        if cameraPermissionConfirmed {
            if let status = await safeCameraPermissionStatus(), status == .granted {
                confirmCameraPermission()
                pendingCameraPermissionRetry = false
                return true
            }
        }

        return false
    }

    private func finishPendingCameraPermissionIfPossible() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if await resolveCameraPermissionIfAlreadyGranted() {
            return
        }
    }

    func syncMetaStatus() async {
        applyRegistrationState(sdk.registrationState)
        guard sdkRegistered else { return }
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
        if registrationSetupStatus != .success {
            _ = await ensureRegistrationComplete()
        }
        if registrationSetupStatus != .success {
            cameraLabel = "Register with Meta AI first."
            return
        }

        await syncMetaStatus()
        if cameraGranted { return }

        unlockCameraStepIfNeeded()
        cameraLabel = "Opening Meta AI for camera permission..."
        pendingCameraPermissionRetry = true
        do {
            let status = try await sdk.requestPermission(.camera)
            applyRegistrationState(sdk.registrationState)
            enableCameraStep()
            if status == .granted {
                confirmCameraPermission()
                pendingCameraPermissionRetry = false
            } else {
                cameraLabel = "Waiting for camera approval in Meta AI."
            }
        } catch {
            if await resolveCameraPermissionIfAlreadyGranted() {
                return
            }
            cameraLabel = "Waiting for camera approval in Meta AI."
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
