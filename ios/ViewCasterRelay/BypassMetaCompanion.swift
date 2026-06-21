import Foundation
import UIKit
import MWDATCore

/// Meta AI registration + camera setup copied from Bypass Market Checker CompanionViewModel.
@MainActor
final class BypassMetaCompanion: ObservableObject {
    @Published var wearablesStatus = "Register the app, allow camera, then capture from the glasses."
    @Published var registrationSetupStatus: SetupItemStatus = .waiting
    @Published var cameraSetupStatus: SetupItemStatus = .waiting
    @Published var isBusy = false
    @Published var message: String?
    @Published var isError = false

    private var registrationOpenedAt: Date?
    private var registrationCompletedAt: Date?
    private var pendingCameraPermissionRetry = false
    private var registrationMonitorTask: Task<Void, Never>?
    private var urlHandledObserver: NSObjectProtocol?
    private var bluetoothMonitor: BluetoothStateMonitor?
    private var autoDeviceSelector: AutoDeviceSelector?
    private var activeDeviceMonitorTask: Task<Void, Never>?
    private var datPrepareBackgroundTask: Task<Void, Never>?
    private var readyDeviceSession: DeviceSession?
    private var hasActiveDATDevice = false

    private static let cameraPermissionConfirmedKey = "metaCameraConfirmed"

    var isRegistered: Bool {
        isRegistrationStateReady(Wearables.shared.registrationState)
    }

    var cameraGranted: Bool {
        UserDefaults.standard.bool(forKey: Self.cameraPermissionConfirmedKey)
    }

    var metaAIStatusLabel: String {
        registrationSetupStatus == .success ? "Connected" : "Disconnected"
    }

    var cameraStatusLabel: String {
        cameraSetupStatus == .success ? "Connected" : "Disconnected"
    }

    func bootstrap() async {
        startRegistrationMonitoring()
        await validateCameraPermissionFlag()
        _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false)
        refreshSetupProgress()
    }

    func onAppWillEnterForeground() {
        onAppBecameActive()
    }

    func startRegistrationMonitoring() {
        guard registrationMonitorTask == nil else { return }

        refreshSetupProgress()
        startActiveDeviceMonitoring()

        registrationMonitorTask = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                await MainActor.run {
                    self?.handleRegistrationStateChange(state)
                }
            }
        }

        guard urlHandledObserver == nil else { return }
        urlHandledObserver = NotificationCenter.default.addObserver(
            forName: .wearablesURLHandled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registrationOpenedAt = nil
                self?.registrationCompletedAt = Date()
                self?.refreshSetupProgress()
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                if self?.pendingCameraPermissionRetry == true {
                    await self?.finishPendingCameraPermissionIfPossible(showStatusMessage: true)
                } else {
                    self?.refreshSetupProgress()
                }
            }
        }
    }

    private func handleRegistrationStateChange(_ state: RegistrationState) {
        switch state {
        case .registered:
            registrationCompletedAt = Date()
            registrationOpenedAt = nil
            wearablesStatus = "Registered with Meta AI."
            Task { await validateCameraPermissionFlag() }
            refreshSetupProgress()
            startActiveDeviceMonitoring()
            beginGlassesConnectionSetup(showStatus: false)
        case .registering:
            wearablesStatus = "Finishing Meta AI registration..."
        case .available:
            wearablesStatus = "Register the app, allow camera, then capture from the glasses."
        case .unavailable:
            wearablesStatus = "Registration unavailable. Check Meta AI and Developer Mode."
        @unknown default:
            break
        }
    }

    func refreshSetupProgress() {
        if isRegistrationStateReady(Wearables.shared.registrationState) {
            registrationSetupStatus = .success
        } else if registrationSetupStatus != .success {
            registrationSetupStatus = .waiting
        }

        if UserDefaults.standard.bool(forKey: Self.cameraPermissionConfirmedKey) {
            cameraSetupStatus = .success
        } else if cameraSetupStatus != .success {
            cameraSetupStatus = .waiting
        }
    }

    // MARK: - Bypass startRegistration

    func startRegistration() {
        Task {
            if let issue = SigningInfo.metaConnectionIssue {
                wearablesStatus = issue
                showError(issue)
                return
            }
            guard validateDATConfiguration() else { return }
            if isRegistrationStateReady(Wearables.shared.registrationState) {
                wearablesStatus = "Already registered with Meta AI."
                showMessage("Already Registered")
                return
            }

            isBusy = true
            defer { isBusy = false }

            wearablesStatus = "Opening Meta AI registration..."
            do {
                registrationOpenedAt = Date()
                try await Wearables.shared.startRegistration()
                wearablesStatus = "Opened Meta AI registration. Return here after approving."
            } catch RegistrationError.alreadyRegistered {
                wearablesStatus = "Already registered with Meta AI."
                showMessage("Already Registered")
            } catch {
                if isRegistrationStateReady(Wearables.shared.registrationState) {
                    wearablesStatus = "Already registered with Meta AI."
                    showMessage("Already Registered")
                    return
                }
                showWearablesError(context: "Registration", error: error)
            }
        }
    }

    func requestCameraPermission() async {
        guard validateDATConfiguration() else { return }

        isBusy = true
        defer { isBusy = false }

        if UserDefaults.standard.bool(forKey: Self.cameraPermissionConfirmedKey) {
            markCameraPermissionGranted(shouldShowMessage: true)
            return
        }

        if let status = await safeCameraPermissionStatus(), status == .granted {
            markCameraPermissionGranted(shouldShowMessage: true)
            return
        }

        if !isRegistrationStateReady(Wearables.shared.registrationState) {
            wearablesStatus = "Register with Meta AI first."
            showError("Tap Register With Meta AI first, then Allow Camera.")
            return
        }

        let monitor = bluetoothMonitorInstance()
        if !monitor.isPoweredOn {
            wearablesStatus = "Waiting for Bluetooth..."
            let ready = await waitForBluetooth(timeoutSeconds: 2)
            guard ready else {
                showError("Bluetooth is \(bluetoothMonitorInstance().stateDescription). Turn Bluetooth on, then retry Allow Camera.")
                return
            }
        }

        wearablesStatus = "Opening Meta AI for camera permission..."
        pendingCameraPermissionRetry = true

        do {
            try await openCameraPermissionInMetaAI()
        } catch {
            if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: true) {
                return
            }
            if isRecoverableWearablesSyncError(error) {
                pendingCameraPermissionRetry = true
                wearablesStatus = "Waiting for camera approval in Meta AI."
                showMessage("Approve camera access in Meta AI, then return here.")
                return
            }
            pendingCameraPermissionRetry = false
            showWearablesError(context: "Camera permission", error: error)
        }
    }

    func openMetaAIApp() {
        guard let url = URL(string: "fb-viewapp://") else {
            showError("Could not open Meta AI app URL.")
            return
        }
        UIApplication.shared.open(url)
    }

    func onAppBecameActive() {
        Task {
            let timeout: TimeInterval = registrationOpenedAt == nil ? 2 : 10
            if await waitForRegistrationReady(timeoutSeconds: timeout) {
                registrationOpenedAt = nil
                refreshSetupProgress()
            }

            if pendingCameraPermissionRetry {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await finishPendingCameraPermissionIfPossible(showStatusMessage: true)
            } else {
                _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false)
                refreshSetupProgress()
            }
        }
    }

    func runWearablesDiagnostics() async {
        guard validateDATConfiguration(reportAsError: false) else { return }

        isBusy = true
        defer { isBusy = false }

        var permissionText = "unknown"
        do {
            permissionText = String(describing: try await Wearables.shared.checkPermissionStatus(.camera))
        } catch {
            permissionText = "error: \(error.localizedDescription)"
        }

        let registrationText = String(describing: Wearables.shared.registrationState)
        let monitor = bluetoothMonitorInstance()
        wearablesStatus = """
        MetaAppID: \(datMetaAppID)
        ClientToken: \(maskedToken(datClientToken))
        TeamID(plist): \(datTeamID)
        Sideload Team: \(SigningInfo.embeddedTeamIdentifier ?? "?")
        Bundle: \(runtimeBundleID)
        Bluetooth: \(monitor.stateDescription)
        Registration: \(registrationText)
        Camera: \(permissionText)
        """
    }

    // MARK: - Private (Bypass)

    private var datConfig: [String: Any] {
        Bundle.main.infoDictionary?["MWDAT"] as? [String: Any] ?? [:]
    }

    private var datMetaAppID: String { datConfig["MetaAppID"] as? String ?? "<missing>" }
    private var datClientToken: String { datConfig["ClientToken"] as? String ?? "<missing>" }
    private var datTeamID: String { datConfig["TeamID"] as? String ?? "<missing>" }
    private var runtimeBundleID: String { Bundle.main.bundleIdentifier ?? "<missing>" }

    @discardableResult
    private func validateDATConfiguration(reportAsError: Bool = true) -> Bool {
        if datMetaAppID == "0" || datClientToken == "<missing>" || datClientToken.isEmpty {
            let msg = "MWDAT MetaAppID/ClientToken missing in this IPA. Reinstall latest GitHub release."
            if reportAsError { showMessage(msg) } else { wearablesStatus = msg }
        }
        return true
    }

    private func openCameraPermissionInMetaAI() async throws {
        let status = try await Wearables.shared.requestPermission(.camera)
        if status == .granted {
            markCameraPermissionGranted(shouldShowMessage: true)
            return
        }
        if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: true) {
            return
        }
        pendingCameraPermissionRetry = true
        showMessage("Approve camera access in Meta AI, then return here.")
    }

    private func safeCameraPermissionStatus() async -> PermissionStatus? {
        try? await Wearables.shared.checkPermissionStatus(.camera)
    }

    private func finishPendingCameraPermissionIfPossible(showStatusMessage: Bool) async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: showStatusMessage) {
            return
        }
        if showStatusMessage {
            wearablesStatus = "Waiting for camera approval to sync..."
            showMessage("If you chose Always Allow in Meta AI, wait a moment and it should update automatically.")
        }
    }

    private func resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: Bool) async -> Bool {
        if let status = await waitForCameraPermissionStatus(timeoutSeconds: 1), status == .granted {
            markCameraPermissionGranted(shouldShowMessage: shouldShowMessage)
            return true
        }
        if UserDefaults.standard.bool(forKey: Self.cameraPermissionConfirmedKey) {
            await validateCameraPermissionFlag()
            if UserDefaults.standard.bool(forKey: Self.cameraPermissionConfirmedKey) {
                markCameraPermissionGranted(shouldShowMessage: shouldShowMessage)
                return true
            }
        }
        return false
    }

    private func validateCameraPermissionFlag() async {
        guard UserDefaults.standard.bool(forKey: Self.cameraPermissionConfirmedKey) else {
            cameraSetupStatus = .waiting
            return
        }
        guard let status = await safeCameraPermissionStatus() else { return }
        if status == .granted {
            cameraSetupStatus = .success
            return
        }
        UserDefaults.standard.set(false, forKey: Self.cameraPermissionConfirmedKey)
        cameraSetupStatus = .waiting
    }

    private func waitForCameraPermissionStatus(timeoutSeconds: TimeInterval) async -> PermissionStatus? {
        if let status = await safeCameraPermissionStatus() { return status }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let status = await safeCameraPermissionStatus() { return status }
        }
        return await safeCameraPermissionStatus()
    }

    private func markCameraPermissionGranted(shouldShowMessage: Bool) {
        pendingCameraPermissionRetry = false
        UserDefaults.standard.set(true, forKey: Self.cameraPermissionConfirmedKey)
        wearablesStatus = "Camera access approved."
        startActiveDeviceMonitoring()
        refreshSetupProgress()
        beginGlassesConnectionSetup(showStatus: false)
        if shouldShowMessage {
            showMessage("Camera Allowed")
        }
    }

    private func beginGlassesConnectionSetup(showStatus: Bool) {
        datPrepareBackgroundTask?.cancel()
        datPrepareBackgroundTask = Task { [weak self] in
            _ = await self?.ensureReadyDeviceSession(showStatus: showStatus, timeoutSeconds: 60)
        }
    }

    private func autoSelector() -> AutoDeviceSelector {
        if let autoDeviceSelector { return autoDeviceSelector }
        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        autoDeviceSelector = selector
        return selector
    }

    private func startActiveDeviceMonitoring() {
        guard activeDeviceMonitorTask == nil else { return }
        let selector = autoSelector()
        activeDeviceMonitorTask = Task { [weak self] in
            for await device in selector.activeDeviceStream() {
                await MainActor.run {
                    self?.hasActiveDATDevice = device != nil
                }
            }
        }
    }

    func ensureReadyDeviceSession(showStatus: Bool, timeoutSeconds: TimeInterval = 60) async -> Bool {
        if let session = readyDeviceSession, session.state == .started { return true }
        guard isRegistrationStateReady(Wearables.shared.registrationState) else { return false }
        guard UserDefaults.standard.bool(forKey: Self.cameraPermissionConfirmedKey) else { return false }

        if showStatus {
            wearablesStatus = "Preparing glasses for capture..."
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            do {
                let session = try await getOrCreateStartedSession()
                readyDeviceSession = session
                if showStatus {
                    wearablesStatus = "Glasses ready for capture."
                }
                return true
            } catch {
                readyDeviceSession = nil
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
        return readyDeviceSession?.state == .started
    }

    func getStartedSessionForCapture() async throws -> DeviceSession {
        try await getOrCreateStartedSession()
    }

    private func getOrCreateStartedSession() async throws -> DeviceSession {
        if let session = readyDeviceSession, session.state == .started {
            return session
        }
        let session = try Wearables.shared.createSession(deviceSelector: autoSelector())
        readyDeviceSession = session
        try session.start()
        if session.state == .started { return session }
        for await state in session.stateStream() {
            if state == .started { return session }
            if state == .stopped {
                throw NSError(domain: "ViewCaster", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session stopped before start."])
            }
        }
        throw NSError(domain: "ViewCaster", code: 2, userInfo: [NSLocalizedDescriptionKey: "Session failed to start."])
    }

    private func bluetoothMonitorInstance() -> BluetoothStateMonitor {
        if let bluetoothMonitor { return bluetoothMonitor }
        let monitor = BluetoothStateMonitor()
        bluetoothMonitor = monitor
        return monitor
    }

    private func waitForBluetooth(timeoutSeconds: TimeInterval) async -> Bool {
        if bluetoothMonitorInstance().isPoweredOn { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if bluetoothMonitorInstance().isPoweredOn { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return bluetoothMonitorInstance().isPoweredOn
    }

    private func waitForRegistrationReady(timeoutSeconds: TimeInterval) async -> Bool {
        if isRegistrationStateReady(Wearables.shared.registrationState) { return true }

        let gate = RegistrationWaitGate()
        let streamTask = Task { @MainActor in
            for await state in Wearables.shared.registrationStateStream() {
                if await gate.isFinished { return }
                if isRegistrationStateReady(state) {
                    await gate.finish(true)
                    return
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isRegistrationStateReady(Wearables.shared.registrationState) {
                streamTask.cancel()
                return true
            }
            if await gate.isFinished {
                streamTask.cancel()
                return await gate.result
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        streamTask.cancel()
        return isRegistrationStateReady(Wearables.shared.registrationState)
    }

    private func isRegistrationStateReady(_ state: RegistrationState) -> Bool {
        state == .registered
    }

    private func isRecoverableWearablesSyncError(_ error: Error) -> Bool {
        if case RegistrationError.alreadyRegistered = error { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("permissionerror") || text.contains("registrationerror")
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 8 else { return token }
        return "\(token.prefix(4))...\(token.suffix(4))"
    }

    private func showWearablesError(context: String, error: Error) {
        if case RegistrationError.alreadyRegistered = error {
            wearablesStatus = "Already registered with Meta AI."
            showMessage("Already Registered")
            return
        }
        let value = error.localizedDescription
        if value.contains("PermissionError") {
            if UserDefaults.standard.bool(forKey: Self.cameraPermissionConfirmedKey) {
                markCameraPermissionGranted(shouldShowMessage: true)
                return
            }
            pendingCameraPermissionRetry = true
            Task { _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: true) }
            showMessage("Approve camera access in Meta AI, then return here.")
            return
        }
        showError("\(context) failed: \(value)")
    }

    private func showMessage(_ value: String) {
        isError = false
        message = value
    }

    private func showError(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "cancelled" || normalized == "canceled" { return }
        isError = true
        message = value
    }
}
