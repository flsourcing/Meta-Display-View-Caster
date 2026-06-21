import CoreMedia
import Foundation
import UIKit
import MWDATCamera
import MWDATCore

enum SetupItemStatus { case waiting, success }

enum GlassesConnectionStatus {
    case connected, disconnected
    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
}

struct WearablesCompanionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class MarketCheckerWearablesCompanion: ObservableObject {
    @Published var isBusy = false
    @Published var message: String?
    @Published var isError = false
    @Published var wearablesStatus = "Register the app, allow camera, then capture from the glasses."
    @Published var registrationSetupStatus: SetupItemStatus = .waiting
    @Published var cameraSetupStatus: SetupItemStatus = .waiting
    @Published var glassesConnectionStatus: GlassesConnectionStatus = .disconnected

    var onPhotoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onVideoFrame: ((VideoFrame) -> Void)?

    private let cameraPermissionConfirmedKey = "datCameraPermissionConfirmed"
    private let datConnectionReadyKey = "datConnectionReady"
    private var deviceSession: DeviceSession?
    private var cameraStream: MWDATCamera.Stream?
    private var stateToken: Any?
    private var frameToken: Any?
    private var photoToken: Any?
    private var latestFrameJPEGData: Data?
    private var latestFrameUIImage: UIImage?
    private var hasLiveFrame = false
    private var streamStateText = "stopped"
    private var registrationMonitorTask: Task<Void, Never>?
    nonisolated(unsafe) private var urlHandledObserver: NSObjectProtocol?
    private var registrationOpenedAt: Date?
    private var registrationCompletedAt: Date?
    private var pendingCameraPermissionRetry = false
    private var datPrepareTask: Task<Bool, Never>?
    private var datPrepareBackgroundTask: Task<Void, Never>?
    private var autoDeviceSelector: AutoDeviceSelector?
    private var readyDeviceSession: DeviceSession?
    private var readySessionStateTask: Task<Void, Never>?
    private var activeDeviceMonitorTask: Task<Void, Never>?
    private var hasActiveDATDevice = false
    private var photoCaptureContinuation: CheckedContinuation<Data, Error>?
    private var companionBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    nonisolated(unsafe) private var appBackgroundObserver: NSObjectProtocol?
    nonisolated(unsafe) private var appForegroundObserver: NSObjectProtocol?
    private let defaultMetaAppID = "0"
    private let defaultClientToken = "DEV_MODE"
    private var bluetoothMonitor: BluetoothStateMonitor?
    private var didAcceptPhotoCaptureRequest = false

    deinit {
        // lookupPollTask removed
        registrationMonitorTask?.cancel()
        datPrepareTask?.cancel()
        datPrepareBackgroundTask?.cancel()
        activeDeviceMonitorTask?.cancel()
        readySessionStateTask?.cancel()
        readyDeviceSession?.stop()
        if let urlHandledObserver {
            NotificationCenter.default.removeObserver(urlHandledObserver)
        }
        if let appBackgroundObserver {
            NotificationCenter.default.removeObserver(appBackgroundObserver)
        }
        if let appForegroundObserver {
            NotificationCenter.default.removeObserver(appForegroundObserver)
        }
    }

    private var datConfig: [String: Any] {
        Bundle.main.infoDictionary?["MWDAT"] as? [String: Any] ?? [:]
    }

    private var datMetaAppID: String {
        datConfig["MetaAppID"] as? String ?? "<missing>"
    }

    private var datClientToken: String {
        datConfig["ClientToken"] as? String ?? "<missing>"
    }

    private var datTeamID: String {
        datConfig["TeamID"] as? String ?? "<missing>"
    }

    private var runtimeBundleID: String {
        Bundle.main.bundleIdentifier ?? "<missing>"
    }

    private var hasPlaceholderDATCredentials: Bool {
        datMetaAppID == defaultMetaAppID || datClientToken == defaultClientToken || datClientToken == "<missing>"
    }





    func refreshSetupProgress() {
        if isRegistrationStateReady(Wearables.shared.registrationState) {
            registrationSetupStatus = .success
        } else if registrationSetupStatus != .success {
            registrationSetupStatus = .waiting
        }

        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            cameraSetupStatus = .success
        } else if cameraSetupStatus != .success {
            cameraSetupStatus = .waiting
        }

        refreshGlassesConnectionStatus()
        updateReadyWearablesStatus()
    }

    func refreshGlassesConnectionStatus() {
        let registered = isRegistrationStateReady(Wearables.shared.registrationState)
        let cameraAllowed = UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey)
        let sessionReady = readyDeviceSession?.state == .started

        if sessionReady || (registered && cameraAllowed) {
            glassesConnectionStatus = .connected
        } else {
            glassesConnectionStatus = .disconnected
        }
    }



    func startCompanionBackgroundBridgeIfNeeded() {
        installCompanionLifecycleObserversIfNeeded()
        startActiveDeviceMonitoring()
    }

    private func installCompanionLifecycleObserversIfNeeded() {
        guard appBackgroundObserver == nil else { return }

        appBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onAppEnteredBackground()
            }
        }

        appForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onAppWillEnterForeground()
            }
        }
    }

    func onAppEnteredBackground() {
        beginCompanionBackgroundTask()
        updateReadyWearablesStatus()
    }

    func onAppWillEnterForeground() {
        endCompanionBackgroundTask()
        onAppBecameActive()
    }

    private func beginCompanionBackgroundTask() {
        guard companionBackgroundTaskID == .invalid else { return }
        companionBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MetaDisplayCompanion") { [weak self] in
            Task { @MainActor in
                self?.renewCompanionBackgroundTask()
            }
        }
    }

    private func renewCompanionBackgroundTask() {
        endCompanionBackgroundTask()
        guard UIApplication.shared.applicationState == .background else { return }
        beginCompanionBackgroundTask()
    }

    private func endCompanionBackgroundTask() {
        guard companionBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(companionBackgroundTaskID)
        companionBackgroundTaskID = .invalid
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
                await finishPendingCameraPermissionIfPossible(showStatusMessage: false)
            } else {
                _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false)
                refreshSetupProgress()
            }
        }
    }











    func startRegistration() {
        Task {
            guard validateDATConfiguration() else { return }
            if let installIssue = SigningInfo.metaConnectionIssue {
                wearablesStatus = installIssue
                showError(installIssue)
                return
            }
            if Wearables.shared.registrationState == .unavailable {
                let issue = registrationUnavailableExplanation()
                wearablesStatus = issue
                showError(issue)
                return
            }
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

        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
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
            let ready = await monitor.waitUntilPoweredOn(timeoutSeconds: 2)
            guard ready else {
                showError("Bluetooth is \(monitor.stateDescription). Turn Bluetooth on, then retry Allow Camera.")
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
        do {
            return try await Wearables.shared.checkPermissionStatus(.camera)
        } catch {
            return nil
        }
    }

    private func requestCameraPermissionDirectly() async throws {
        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            markCameraPermissionGranted(shouldShowMessage: false)
            return
        }

        try await openCameraPermissionInMetaAI()
    }

    private func finishPendingCameraPermissionIfPossible(showStatusMessage: Bool) async {
        try? await Task.sleep(nanoseconds: 300_000_000)

        if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: showStatusMessage) {
            beginGlassesConnectionSetup(showStatus: showStatusMessage)
            return
        }

        if showStatusMessage {
            wearablesStatus = "Waiting for camera approval to sync..."
            showMessage("If you chose Always Allow in Meta AI, wait a moment and it should update automatically.")
        }
    }

    private func resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: Bool) async -> Bool {
        if let status = await waitForCameraPermissionStatus(timeoutSeconds: 1),
           status == .granted {
            markCameraPermissionGranted(shouldShowMessage: shouldShowMessage)
            return true
        }

        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            await validateCameraPermissionFlag()
            if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
                markCameraPermissionGranted(shouldShowMessage: shouldShowMessage)
                return true
            }
        }

        return false
    }

    private func validateCameraPermissionFlag() async {
        guard UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) else {
            cameraSetupStatus = .waiting
            refreshGlassesConnectionStatus()
            return
        }

        guard let status = await safeCameraPermissionStatus() else {
            return
        }

        if status == .granted {
            cameraSetupStatus = .success
            refreshGlassesConnectionStatus()
            return
        }

        UserDefaults.standard.set(false, forKey: cameraPermissionConfirmedKey)
        cameraSetupStatus = .waiting
        refreshGlassesConnectionStatus()
        updateReadyWearablesStatus()
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

    private func refreshCameraPermissionStatus(shouldShowMessage: Bool) async {
        _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: shouldShowMessage)
    }

    private func markCameraPermissionGranted(shouldShowMessage: Bool) {
        pendingCameraPermissionRetry = false
        UserDefaults.standard.set(true, forKey: cameraPermissionConfirmedKey)
        wearablesStatus = "Preparing glasses for capture..."
        startActiveDeviceMonitoring()
        refreshSetupProgress()
        beginGlassesConnectionSetup(showStatus: shouldShowMessage)
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

    private func scheduleDATPrepareIfNeeded(delayNanoseconds: UInt64 = 500_000_000) {
        guard UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) else { return }
        guard isRegistrationStateReady(Wearables.shared.registrationState) else { return }
        guard readyDeviceSession?.state != .started else { return }

        datPrepareBackgroundTask?.cancel()
        datPrepareBackgroundTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            _ = await self?.ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 60)
        }
    }

    private func autoSelector() -> AutoDeviceSelector {
        if let autoDeviceSelector {
            return autoDeviceSelector
        }

        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        autoDeviceSelector = selector
        return selector
    }

    private func startActiveDeviceMonitoring() {
        guard activeDeviceMonitorTask == nil else { return }

        let selector = autoSelector()
        activeDeviceMonitorTask = Task { [weak self] in
            for await device in selector.activeDeviceStream() {
                let isActive = device != nil
                await MainActor.run {
                    self?.hasActiveDATDevice = isActive
                }
            }
        }
    }

    private func ensureReadyDeviceSession(showStatus: Bool, timeoutSeconds: TimeInterval = 60) async -> Bool {
        if let datPrepareTask, !datPrepareTask.isCancelled {
            return await datPrepareTask.value
        }

        let task = Task { [weak self] () -> Bool in
            await self?.establishReadyDeviceSession(showStatus: showStatus, timeoutSeconds: timeoutSeconds) ?? false
        }
        datPrepareTask = task
        let ready = await task.value
        datPrepareTask = nil
        return ready
    }

    private func establishReadyDeviceSession(showStatus: Bool, timeoutSeconds: TimeInterval) async -> Bool {
        if let session = readyDeviceSession, session.state == .started {
            UserDefaults.standard.set(true, forKey: datConnectionReadyKey)
            updateReadyWearablesStatus()
            return true
        }

        if readyDeviceSession?.state == .stopped {
            readyDeviceSession = nil
        }

        guard isRegistrationStateReady(Wearables.shared.registrationState) else { return false }
        guard UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) else { return false }

        if showStatus {
            wearablesStatus = "Preparing glasses for capture..."
        }

        startActiveDeviceMonitoring()
        _ = await waitForRegistrationReady(timeoutSeconds: min(12, timeoutSeconds / 2))

        let monitor = bluetoothMonitorInstance()
        if !monitor.isPoweredOn {
            _ = await monitor.waitUntilPoweredOn(timeoutSeconds: 5)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled {
                return false
            }

            if !hasActiveDATDevice, Wearables.shared.devices.isEmpty {
                _ = await waitForKnownDevice(timeoutSeconds: min(2, max(1, deadline.timeIntervalSinceNow)))
            } else {
                hasActiveDATDevice = true
            }

            do {
                let session = try await getOrCreateStartedSession()
                readyDeviceSession = session
                UserDefaults.standard.set(true, forKey: datConnectionReadyKey)
                updateReadyWearablesStatus()
                if showStatus {
                    showMessage("Glasses ready for capture.")
                }
                return true
            } catch {
                readyDeviceSession = nil
                await recoverFromDATSetupError(error)
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        return readyDeviceSession?.state == .started
    }

    private func getOrCreateStartedSession() async throws -> DeviceSession {
        if let session = readyDeviceSession {
            if session.state == .started {
                return session
            }
            if session.state == .stopped {
                readyDeviceSession = nil
            } else {
                try await waitForSessionStarted(session)
                return session
            }
        }

        let session = try Wearables.shared.createSession(deviceSelector: autoSelector())
        readyDeviceSession = session

        let stateStream = session.stateStream()
        let errorStream = session.errorStream()
        try session.start()

        if session.state == .started {
            observeReadySessionState(session)
            return session
        }

        try await waitForSessionStarted(
            session,
            stateStream: stateStream,
            errorStream: errorStream
        )
        observeReadySessionState(session)
        return session
    }

    private func waitForSessionStarted(
        _ session: DeviceSession,
        stateStream: AsyncStream<DeviceSessionState>? = nil,
        errorStream: AsyncStream<DeviceSessionError>? = nil
    ) async throws {
        let states = stateStream ?? session.stateStream()
        let errors = errorStream ?? session.errorStream()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in states {
                    if state == .started {
                        return
                    }
                    if state == .stopped {
                        throw DeviceSessionError.unexpectedError(description: "The session stopped before it started.")
                    }
                }
                throw DeviceSessionError.unexpectedError(description: "The session failed to start.")
            }

            group.addTask {
                for await error in errors {
                    throw error
                }
                throw DeviceSessionError.unexpectedError(description: "The session failed to start.")
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func observeReadySessionState(_ session: DeviceSession) {
        readySessionStateTask?.cancel()
        readySessionStateTask = Task { [weak self] in
            for await state in session.stateStream() {
                await MainActor.run {
                    guard let self else { return }
                    if state == .started {
                        UserDefaults.standard.set(true, forKey: self.datConnectionReadyKey)
                        self.updateReadyWearablesStatus()
                    } else if state == .stopped {
                        self.readyDeviceSession = nil
                        UserDefaults.standard.set(false, forKey: self.datConnectionReadyKey)
                        self.readySessionStateTask = nil
                    }
                }
            }
        }
    }

    private func recoverFromDATSetupError(_ error: Error) async {
        if case DeviceSessionError.datAppOnTheGlassesUpdateRequired = error {
            wearablesStatus = "Updating glasses app..."
            try? await Wearables.shared.openDATGlassesAppUpdate()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return
        }

        let text = error.localizedDescription.lowercased()
        if text.contains("datapp") || text.contains("glasses update") || text.contains("update required") {
            wearablesStatus = "Updating glasses app..."
            try? await Wearables.shared.openDATGlassesAppUpdate()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func stopReadyDeviceSession() {
        readySessionStateTask?.cancel()
        readySessionStateTask = nil
        readyDeviceSession?.stop()
        readyDeviceSession = nil
        UserDefaults.standard.set(false, forKey: datConnectionReadyKey)
    }

    private func startGlassesStreamForCapture(quiet: Bool) async throws {
        let ready = await ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 30)
        guard ready else {
            throw WearablesCompanionError(message: "No eligible device available.")
        }

        if cameraStream != nil {
            await stopCameraStreamOnly()
        }

        try await startGlassesStreamAttempt(quiet: quiet, photoCaptureOnly: true, deviceTimeoutSeconds: 20)
    }

    private func isRecoverableWearablesSyncError(_ error: Error) -> Bool {
        if isRegistrationSyncError(error) {
            return true
        }

        let text = error.localizedDescription.lowercased()
        return text.contains("permissionerror") || text.contains("registrationerror")
    }

    func runWearablesDiagnostics() async {
        guard validateDATConfiguration(reportAsError: false) else { return }

        isBusy = true
        defer { isBusy = false }

        var permissionText = "unknown"
        do {
            let permission = try await Wearables.shared.checkPermissionStatus(.camera)
            permissionText = String(describing: permission)
        } catch {
            permissionText = "error: \(error.localizedDescription)"
        }

        let registrationText = String(describing: Wearables.shared.registrationState)
        let registrationReady = isRegistrationStateReady(registrationText)

        let monitor = bluetoothMonitorInstance()
        let devicesText = await deviceSnapshot(timeoutSeconds: 6)
        wearablesStatus = """
        MetaAppID: \(datMetaAppID)
        ClientToken: \(maskedToken(datClientToken))
        TeamID(plist): \(datTeamID)
        Bundle(runtime): \(runtimeBundleID)
        Bluetooth: \(monitor.stateDescription)
        Registration: \(registrationText) (\(registrationReady ? "ready" : "not ready"))
        Camera permission: \(permissionText)
        DAT devices: \(devicesText)
        """

        if hasPlaceholderDATCredentials {
            showMessage("MetaAppID/ClientToken are placeholders. If you still get permission errors, replace them from Meta Wearables Developer Center.")
        }
    }











    /// Tries on-device Vision first, then uploads the photo for server-side Gemini when configured.








    func openMetaAIApp() {
        guard let url = URL(string: "fb-viewapp://") else {
            showError("Could not open Meta AI app URL.")
            return
        }

        UIApplication.shared.open(url)
    }




































    private func deviceSnapshot(timeoutSeconds: TimeInterval) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask {
                for await devices in Wearables.shared.devicesStream() {
                    return String(describing: devices)
                }
                return "[]"
            }

            group.addTask {
                let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return "timeout (no device update)"
            }

            let first = await group.next() ?? "unknown"
            group.cancelAll()
            return first
        }
    }

    private func waitForKnownDevice(timeoutSeconds: TimeInterval) async -> Bool {
        if !Wearables.shared.devices.isEmpty {
            return true
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await devices in Wearables.shared.devicesStream() {
                    if !devices.isEmpty {
                        return true
                    }
                }
                return false
            }

            group.addTask {
                let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func stopCameraStreamOnly() async {
        stateToken = nil
        frameToken = nil
        photoToken = nil

        let streamToStop = cameraStream
        let sessionToStop = deviceSession

        cameraStream = nil
        deviceSession = nil
        latestFrameJPEGData = nil
        latestFrameUIImage = nil
        hasLiveFrame = false
        streamStateText = "stopping"

        if let streamToStop {
            await streamToStop.stop()
        }

        if let sessionToStop, sessionToStop !== readyDeviceSession, sessionToStop.state == .started {
            try? sessionToStop.removeCapability(MWDATCamera.Stream.self)
            sessionToStop.stop()
        }

        streamStateText = "stopped"
    }

    private func tearDownGlassesCameraImmediately() async {
        await stopCameraStreamOnly()

        let sessionToStop = readyDeviceSession
        readySessionStateTask?.cancel()
        readySessionStateTask = nil
        readyDeviceSession = nil
        UserDefaults.standard.set(false, forKey: datConnectionReadyKey)

        if let sessionToStop, sessionToStop.state == .started {
            try? sessionToStop.removeCapability(MWDATCamera.Stream.self)
            sessionToStop.stop()
        }
    }

    private func stopActiveStreamOnly() async {
        await tearDownGlassesCameraImmediately()
    }

    private func finishGlassesCaptureAfterPhoto() async {
        await tearDownGlassesCameraImmediately()
        wearablesStatus = "Photo captured."
    }

    private func stopGlassesStream() {
        Task { await stopActiveStreamOnly() }
        stopReadyDeviceSession()
    }















    private func capturePhotoFromGlasses() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            didAcceptPhotoCaptureRequest = false
            photoCaptureContinuation = continuation

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if let pending = self.photoCaptureContinuation {
                    self.photoCaptureContinuation = nil
                    pending.resume(throwing: WearablesCompanionError(message: "Photo capture timed out."))
                }
            }

            Task { @MainActor in
                do {
                    let hadExistingStream = self.cameraStream != nil
                    if self.cameraStream == nil {
                        try await self.startGlassesStreamForCapture(quiet: true)
                    }

                    guard let stream = self.cameraStream else {
                        throw WearablesCompanionError(message: "Could not access the glasses camera.")
                    }
                    if hadExistingStream {
                        guard await self.triggerSinglePhotoCapture(on: stream) else {
                            throw WearablesCompanionError(message: "Could not trigger photo capture.")
                        }
                    }
                } catch {
                    if let pending = self.photoCaptureContinuation {
                        self.photoCaptureContinuation = nil
                        pending.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func triggerSinglePhotoCapture(on stream: MWDATCamera.Stream) async -> Bool {
        if didAcceptPhotoCaptureRequest {
            return true
        }

        for _ in 1...4 {
            guard photoCaptureContinuation != nil else { return true }
            if didAcceptPhotoCaptureRequest {
                return true
            }
            if stream.capturePhoto(format: PhotoCaptureFormat.jpeg) {
                didAcceptPhotoCaptureRequest = true
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return false
    }













    private func ensureBluetoothPoweredOn(actionName: String) async -> Bool {
        let monitor = bluetoothMonitorInstance()
        let ready = await monitor.waitUntilPoweredOn()
        guard ready else {
            showError("Bluetooth is \(monitor.stateDescription). Turn Bluetooth on, then retry \(actionName).")
            return false
        }
        return true
    }

    private func bluetoothMonitorInstance() -> BluetoothStateMonitor {
        if let bluetoothMonitor {
            return bluetoothMonitor
        }
        let monitor = BluetoothStateMonitor()
        bluetoothMonitor = monitor
        return monitor
    }

    private func ensureRegistered(actionName: String) async -> Bool {
        if isRegistrationStateReady(Wearables.shared.registrationState) {
            return true
        }

        if Wearables.shared.registrationState == .registering {
            wearablesStatus = "Finishing Meta AI registration..."
            if await waitForRegistrationReady(timeoutSeconds: 15) {
                refreshWearablesSetupStatus()
                return true
            }
        }

        if await waitForRegistrationReady(timeoutSeconds: 3) {
            refreshWearablesSetupStatus()
            return true
        }

        let currentState = Wearables.shared.registrationState
        if currentState == .available {
            do {
                try await Wearables.shared.startRegistration()
                openMetaAIApp()
                wearablesStatus = "Complete registration in Meta AI, then return here."
                showMessage("Meta AI opened for \(actionName). After approving, return and tap Allow Camera.")
                return false
            } catch RegistrationError.alreadyRegistered {
                if await waitForRegistrationReady(timeoutSeconds: 10) {
                    refreshWearablesSetupStatus()
                    return true
                }
            } catch {
                if isRegistrationStateReady(Wearables.shared.registrationState) {
                    refreshWearablesSetupStatus()
                    return true
                }
                showWearablesError(context: "Registration check", error: error)
                return false
            }
        }

        if currentState == .unavailable {
            showError(registrationUnavailableExplanation())
            return false
        }

        if await waitForRegistrationReady(timeoutSeconds: 8) {
            refreshWearablesSetupStatus()
            return true
        }

        showError("Registration is not ready yet. Approve access in Meta AI, return here, then tap \(actionName) again.")
        return false
    }

    private func waitForRegistrationReady(timeoutSeconds: TimeInterval) async -> Bool {
        if isRegistrationStateReady(Wearables.shared.registrationState) {
            return true
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isRegistrationStateReady(Wearables.shared.registrationState) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isRegistrationStateReady(Wearables.shared.registrationState)
    }

    func startRegistrationMonitoring() {
        guard registrationMonitorTask == nil else { return }

        refreshWearablesSetupStatus()
        startActiveDeviceMonitoring()

        registrationMonitorTask = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                await MainActor.run {
                    self?.handleRegistrationStateChange(state)
                }
            }
        }

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

                guard self?.pendingCameraPermissionRetry == true else {
                    self?.refreshSetupProgress()
                    return
                }

                await self?.finishPendingCameraPermissionIfPossible(showStatusMessage: true)
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
            wearablesStatus = registrationUnavailableExplanation()
        @unknown default:
            break
        }
    }

    private func refreshWearablesSetupStatus() {
        refreshSetupProgress()
    }

    private func updateReadyWearablesStatus() {
        if readyDeviceSession?.state == .started {
            wearablesStatus = "Glasses ready for capture."
        } else if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            wearablesStatus = "Camera access approved."
        } else if isRegistrationStateReady(Wearables.shared.registrationState) {
            wearablesStatus = "Registered with Meta AI."
        }
        refreshGlassesConnectionStatus()
    }

    private func isRegistrationSyncError(_ error: Error) -> Bool {
        if case RegistrationError.alreadyRegistered = error {
            return true
        }

        let text = error.localizedDescription.lowercased()
        return text.contains("registrationerror")
    }

    private func registrationUnavailableExplanation() -> String {
        if let issue = SigningInfo.metaConnectionIssue {
            return issue
        }
        return """
        Registration unavailable (SDK rejected app identity — not a Developer Mode issue).
        Tap Run Meta diagnostics and confirm Bundle(runtime) is com.flsourcing.bypassmarketchecker.
        If Sideloadly changed the bundle ID, delete the app and reinstall with Custom Bundle ID empty.
        """
    }

    private func isRegistrationStateReady(_ state: RegistrationState) -> Bool {
        state == .registered
    }

    private func isRegistrationStateReady(_ stateDescription: String) -> Bool {
        let normalized = stateDescription.lowercased()
        if normalized.contains("unavailable") {
            return false
        }
        if normalized.contains("available") && !normalized.contains("unavailable") {
            return false
        }
        if normalized.contains("registering") {
            return false
        }
        if normalized.contains("registered") {
            return true
        }
        if normalized.contains("rawvalue: 3") || normalized.contains("rawvalue:3") {
            return true
        }
        return false
    }

    private func startGlassesStreamAttempt(
        quiet: Bool = false,
        photoCaptureOnly: Bool = false,
        deviceTimeoutSeconds: TimeInterval = 12
    ) async throws {
        try await ensureCameraPermissionForCapture()

        let monitor = bluetoothMonitorInstance()
        if !monitor.isPoweredOn {
            guard await monitor.waitUntilPoweredOn(timeoutSeconds: 3) else {
                throw WearablesCompanionError(message: "Bluetooth is off. Turn Bluetooth on and retry.")
            }
        }

        if cameraStream != nil {
            await stopActiveStreamOnly()
        }

        let deadline = Date().addingTimeInterval(deviceTimeoutSeconds)
        var lastError: Error = WearablesCompanionError(
            message: "No DAT device detected. Keep Meta AI open and glasses connected, then retry."
        )

        while Date() < deadline {
            do {
                let session = try await getOrCreateStartedSession()
                try await attachCameraStream(to: session, quiet: quiet, photoCaptureOnly: photoCaptureOnly)
                return
            } catch {
                lastError = error
                readyDeviceSession = nil
                await recoverFromDATSetupError(error)
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }

        throw lastError
    }

    private func attachCameraStream(
        to newDeviceSession: DeviceSession,
        quiet: Bool,
        photoCaptureOnly: Bool = false
    ) async throws {
        let stream = try await createCameraStreamWithRetry(
            newDeviceSession,
            photoCaptureOnly: photoCaptureOnly,
            maxAttempts: quiet ? 8 : 10
        )
        hasLiveFrame = false
        latestFrameJPEGData = nil
        latestFrameUIImage = nil
        streamStateText = "starting"

        stateToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                let text = String(describing: state).lowercased()
                self?.streamStateText = text
                guard let self else { return }
                if photoCaptureOnly,
                   self.photoCaptureContinuation != nil,
                   !self.didAcceptPhotoCaptureRequest,
                   (text.contains("streaming") || text.contains("started")) {
                    _ = await self.triggerSinglePhotoCapture(on: stream)
                }

                guard !quiet else { return }
                self.wearablesStatus = "Stream: \(String(describing: state))"
            }
        }

        frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            guard let image = frame.makeUIImage() else { return }
            Task { @MainActor in
                guard let self else { return }
                self.latestFrameUIImage = image
                let quality: CGFloat = photoCaptureOnly ? 0.92 : 0.85
                self.latestFrameJPEGData = image.jpegData(compressionQuality: quality)
                self.hasLiveFrame = true
                self.onVideoFrame?(frame)
            }
        }

        photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                guard let self else { return }
                if let continuation = self.photoCaptureContinuation {
                    self.photoCaptureContinuation = nil
                    continuation.resume(returning: photoData.data)
                    return
                }
                guard self.photoCaptureContinuation != nil else {
                    return
                }
                if let sample = self.sampleBufferFromJPEG(photoData.data) { self.onPhotoSampleBuffer?(sample) }
                await self.tearDownGlassesCameraImmediately()
            }
        }

        deviceSession = newDeviceSession
        cameraStream = stream
        await stream.start()

        if quiet {
            updateReadyWearablesStatus()
        } else {
            wearablesStatus = "Glasses stream started."
            showMessage("Glasses stream active.")
        }
    }

    private func ensureCameraPermissionForCapture() async throws {
        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            return
        }

        if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false) {
            return
        }

        let permission = try await Wearables.shared.checkPermissionStatus(.camera)
        if permission == .granted {
            markCameraPermissionGranted(shouldShowMessage: false)
            return
        }

        let requested = try await Wearables.shared.requestPermission(.camera)
        if requested == .granted {
            markCameraPermissionGranted(shouldShowMessage: false)
            return
        }

        throw WearablesCompanionError(message: "Camera access is not granted. Tap Allow Camera and approve in Meta AI first.")
    }

    private func createCameraStreamWithRetry(
        _ session: DeviceSession,
        photoCaptureOnly: Bool = false,
        maxAttempts: Int = 10
    ) async throws -> MWDATCamera.Stream {
        let config = StreamConfiguration(
            videoCodec: VideoCodec.raw,
            resolution: StreamingResolution.low,
            frameRate: 24
        )

        for attempt in 1...maxAttempts {
            if let stream = try? session.addStream(config: config) {
                return stream
            }

            if true {
                wearablesStatus = "Preparing camera stream (\(attempt)/\(maxAttempts))..."
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        throw WearablesCompanionError(
            message: "Could not start camera stream. The glasses session connected but camera capability was not ready yet."
        )
    }

    private func validateDATConfiguration(reportAsError: Bool = true) -> Bool {
        if hasPlaceholderDATCredentials {
            let message = "Using placeholder DAT credentials (MetaAppID=\(datMetaAppID), ClientToken=\(maskedToken(datClientToken))). If registration fails, replace these with values from Meta Wearables Developer Center."
            if reportAsError {
                showMessage(message)
            } else {
                wearablesStatus = message
            }
        }

        return true
    }

    private func isPermissionGranted(_ permissionText: String) -> Bool {
        let normalized = permissionText.lowercased()
        return normalized.contains("authorized")
            || normalized.contains("granted")
            || normalized.contains("allow")
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
            if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
                markCameraPermissionGranted(shouldShowMessage: true)
                return
            }
            pendingCameraPermissionRetry = true
            Task {
                _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: true)
            }
            showMessage("Approve camera access in Meta AI, then return here.")
            return
        }
        if value.contains("No eligible device available") {
            showError("No eligible device available. In Meta AI, confirm this app is registered and allowed, then retry.")
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
        if normalized == "cancelled" || normalized == "canceled" || normalized == "cancelled." || normalized == "canceled." {
            return
        }
        isError = true
        message = value
    }

    var metaAIStatusLabel: String {
        registrationSetupStatus == .success ? "Connected" : "Disconnected"
    }

    var cameraStatusLabel: String {
        cameraSetupStatus == .success ? "Connected" : "Disconnected"
    }

    func bootstrap() async {
        startRegistrationMonitoring()
        installCompanionLifecycleObserversIfNeeded()
        startCompanionBackgroundBridgeIfNeeded()
        if let installIssue = SigningInfo.metaConnectionIssue {
            wearablesStatus = installIssue
        } else if Wearables.shared.registrationState == .unavailable {
            wearablesStatus = registrationUnavailableExplanation()
        }
        await validateCameraPermissionFlag()
        _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false)
        refreshSetupProgress()
    }

    var isRegistered: Bool { isRegistrationStateReady(Wearables.shared.registrationState) }
    var cameraGranted: Bool { UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) }
    var canStreamFromGlasses: Bool { isRegistered && cameraGranted }

    func capturePhotoForCast(status: @escaping (String) -> Void) async throws {
        status("Preparing glasses...")
        let photoData = try await capturePhotoFromGlasses()
        if let sample = sampleBufferFromJPEG(photoData) {
            onPhotoSampleBuffer?(sample)
        }
        status("Photo captured")
    }

    func stopCastCapture() {
        Task { await tearDownGlassesCameraImmediately() }
    }

    private func sampleBufferFromJPEG(_ data: Data) -> CMSampleBuffer? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }
}

