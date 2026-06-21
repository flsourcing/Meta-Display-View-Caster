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

    var registrationStateLabel: String {
        let state = Wearables.shared.registrationState
        return "\(state) — \(state.description)"
    }

    var needsCompleteRegistration: Bool {
        let state = Wearables.shared.registrationState
        return registrationSetupStatus != .success
            && (state == .registering || state == .unavailable || registrationOpenedAt != nil)
    }

    func bootstrap() async {
        startRegistrationMonitoring()
        await waitForRegistrationStateToSettle()
        await validateCameraPermissionFlag()
        _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false)
        refreshSetupProgress()
        applyInitialRegistrationState()
    }

    /// SDK sometimes reports unavailable briefly after configure(); poll before showing errors.
    private func waitForRegistrationStateToSettle() async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let state = Wearables.shared.registrationState
            if state == .available || state == .registered || state == .registering {
                handleRegistrationStateChange(state)
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func applyInitialRegistrationState() {
        let state = Wearables.shared.registrationState
        handleRegistrationStateChange(state)
        if state == .unavailable {
            wearablesStatus = unavailableGuidance()
        }
    }

    private func unavailableGuidance() -> String {
        if isDeveloperModeConfig {
            return """
            SDK still unavailable (Dev Mode IPA). App Developer Mode looks ON — enable it on the glasses too:
            Meta AI → Settings → Meta RB Display (your glasses) → Developer Mode ON.
            If shown, tap Install DAT SDK. Force-quit Meta AI and View Caster, then tap Register below.
            """
        }
        return """
        Registration unavailable — SDK rejected this app's Meta credentials.
        Your wearables.developer.meta.com project must match exactly:
        Bundle \(runtimeBundleID), Team \(datTeamID), scheme viewcaster://
        Or install a Dev Mode IPA (MetaAppID=0) from GitHub Releases.
        """
    }

    private var isDeveloperModeConfig: Bool {
        datMetaAppID == "0"
    }

    func onAppWillEnterForeground() {
        Task {
            await waitForRegistrationStateToSettle()
            onAppBecameActive()
        }
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
            wearablesStatus = unavailableGuidance()
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

            let state = Wearables.shared.registrationState
            if state == .unavailable {
                wearablesStatus = "Trying registration anyway (SDK reported unavailable)..."
            } else {
                wearablesStatus = "Opening Meta AI registration..."
            }

            do {
                registrationOpenedAt = Date()
                try await Wearables.shared.startRegistration()
                wearablesStatus = "Opened Meta AI. Tap Connect, then return here and tap Finish in Meta AI."
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

    func completeRegistrationInMetaAI() {
        Task {
            isBusy = true
            defer { isBusy = false }

            wearablesStatus = "Opening Meta AI — tap View Caster Relay to deliver callback..."
            do {
                try await Wearables.shared.openDATGlassesAppUpdate()
            } catch {
                NSLog("ViewCaster: openDATGlassesAppUpdate: \(error.localizedDescription)")
                openMetaAIApp()
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = await waitForRegistrationReady(timeoutSeconds: 20)
            refreshSetupProgress()
            if !isRegistrationStateReady(Wearables.shared.registrationState) {
                wearablesStatus = unavailableGuidance()
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

        let state = Wearables.shared.registrationState
        let registrationText = "\(state) — \(state.description)"
        let modeText = isDeveloperModeConfig ? "Developer Mode (MetaAppID=0)" : "Production"
        let monitor = bluetoothMonitorInstance()
        wearablesStatus = """
        Mode: \(modeText)
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
        if isDeveloperModeConfig {
            return true
        }
        if datMetaAppID == "<missing>" || datMetaAppID.isEmpty
            || datClientToken == "<missing>" || datClientToken.isEmpty {
            let msg = "Production MetaAppID/ClientToken missing. Install Dev Mode IPA or fix portal credentials."
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
