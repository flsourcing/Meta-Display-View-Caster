import Foundation
import UIKit
import CoreMedia
import MWDATCamera
import MWDATCore

enum SetupItemStatus: Equatable {
    case waiting
    case success
}

/// Meta Wearables — same registration/camera/session flow as Bypass Market Checker.
@MainActor
final class WearablesManager: ObservableObject {
    @Published private(set) var wearablesStatus = ""
    @Published private(set) var registrationSetupStatus: SetupItemStatus = .waiting
    @Published private(set) var cameraSetupStatus: SetupItemStatus = .waiting
    @Published private(set) var isRegistered = false
    @Published private(set) var cameraGranted = false
    @Published private(set) var registrationStateName = "available"
    @Published private(set) var glassesDevicesLabel = "Glasses: scanning…"
    @Published private(set) var glassesDeviceCount = 0
    @Published private(set) var sdkRegistered = false

    var onVideoFrame: ((VideoFrame) -> Void)?
    var onPhotoSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var registrationOpenedAt: Date?
    private var pendingCameraPermissionRetry = false
    private var urlHandledObserver: NSObjectProtocol?
    private var registrationMonitorTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var didConfigure = false
    private var bluetoothMonitor: BluetoothStateMonitor?

    private var autoDeviceSelector: AutoDeviceSelector?
    private var readyDeviceSession: DeviceSession?
    private var readySessionStateTask: Task<Void, Never>?
    private var activeDeviceMonitorTask: Task<Void, Never>?
    private var cameraStream: MWDATCamera.Stream?
    private var stateToken: Any?
    private var frameToken: Any?
    private var photoToken: Any?
    private var photoCaptureContinuation: CheckedContinuation<Data, Error>?
    private var deviceObserveTask: Task<Void, Never>?

    private static let cameraConfirmedKey = "metaCameraConfirmed"

    private var sdk: any WearablesInterface { Wearables.shared }

    init() {
        if UserDefaults.standard.bool(forKey: Self.cameraConfirmedKey) {
            cameraGranted = true
            cameraSetupStatus = .success
        }
    }

    func configure(configError: String? = nil) {
        if let configError {
            wearablesStatus = "SDK configure: \(configError)"
        }
        guard !didConfigure else { return }
        didConfigure = true
        startRegistrationMonitoring()
        startDeviceObserver()
        installForegroundObserver()
        refreshSetupProgress()
        applyRegistrationState(sdk.registrationState)
        Task { await onAppBecameActive() }
    }

    // MARK: - Bypass: startRegistrationMonitoring

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
                self?.refreshSetupProgress()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if self?.pendingCameraPermissionRetry == true {
                    await self?.finishPendingCameraPermissionIfPossible()
                } else {
                    self?.refreshSetupProgress()
                }
            }
        }
    }

    private func handleRegistrationStateChange(_ state: RegistrationState) {
        registrationStateName = String(describing: state)
        sdkRegistered = state == .registered
        isRegistered = sdkRegistered

        switch state {
        case .registered:
            registrationOpenedAt = nil
            wearablesStatus = "Registered with Meta AI."
            Task { await validateCameraPermissionFlag() }
            refreshSetupProgress()
            if cameraGranted {
                beginGlassesConnectionSetup(showStatus: false)
            }
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

    private func applyRegistrationState(_ state: RegistrationState) {
        handleRegistrationStateChange(state)
    }

    func refreshSetupProgress() {
        if isRegistrationReady(sdk.registrationState) {
            registrationSetupStatus = .success
        } else if registrationSetupStatus != .success {
            registrationSetupStatus = .waiting
        }

        if UserDefaults.standard.bool(forKey: Self.cameraConfirmedKey) || cameraGranted {
            cameraSetupStatus = .success
        } else if cameraSetupStatus != .success {
            cameraSetupStatus = .waiting
        }
    }

    // MARK: - Bypass: startRegistration

    func startRegistration() {
        Task {
            if isRegistrationReady(sdk.registrationState) {
                wearablesStatus = "Already registered with Meta AI."
                return
            }

            wearablesStatus = "Opening Meta AI registration..."
            do {
                registrationOpenedAt = Date()
                try await sdk.startRegistration()
                wearablesStatus = "Opened Meta AI registration. Return here after approving."
            } catch RegistrationError.alreadyRegistered {
                wearablesStatus = "Already registered with Meta AI."
            } catch {
                if isRegistrationReady(sdk.registrationState) {
                    wearablesStatus = "Already registered with Meta AI."
                    return
                }
                wearablesStatus = "Registration failed: \(error.localizedDescription)"
            }
        }
    }

    /// RelayViewModel entry point — same as startRegistration().
    func connectMetaAI() {
        startRegistration()
    }

    func openMetaAIApp() {
        guard let url = URL(string: "fb-viewapp://") else {
            wearablesStatus = "Could not open Meta AI app URL."
            return
        }
        UIApplication.shared.open(url)
    }

    // MARK: - Bypass: requestCameraPermission

    func requestCameraPermission() async {
        if UserDefaults.standard.bool(forKey: Self.cameraConfirmedKey) {
            markCameraPermissionGranted()
            return
        }

        if let status = await safeCameraPermissionStatus(), status == .granted {
            markCameraPermissionGranted()
            return
        }

        if !isRegistrationReady(sdk.registrationState) {
            wearablesStatus = "Register with Meta AI first."
            return
        }

        let monitor = bluetoothMonitorInstance()
        if !monitor.isPoweredOn {
            wearablesStatus = "Waiting for Bluetooth..."
            let ready = await waitForBluetooth(timeoutSeconds: 2)
            guard ready else {
                wearablesStatus = "Bluetooth is \(bluetoothMonitorInstance().stateDescription). Turn Bluetooth on, then retry Allow Camera."
                return
            }
        }

        wearablesStatus = "Opening Meta AI for camera permission..."
        pendingCameraPermissionRetry = true

        do {
            try await openCameraPermissionInMetaAI()
        } catch {
            if await resolveCameraPermissionIfAlreadyGranted() {
                return
            }
            pendingCameraPermissionRetry = true
            wearablesStatus = "Waiting for camera approval in Meta AI."
        }
    }

    func requestGlassesCamera() async {
        await requestCameraPermission()
    }

    private func openCameraPermissionInMetaAI() async throws {
        let status = try await sdk.requestPermission(.camera)
        if status == .granted {
            markCameraPermissionGranted()
            return
        }
        if await resolveCameraPermissionIfAlreadyGranted() {
            return
        }
        pendingCameraPermissionRetry = true
        wearablesStatus = "Approve camera access in Meta AI, then return here."
    }

    private func markCameraPermissionGranted() {
        pendingCameraPermissionRetry = false
        UserDefaults.standard.set(true, forKey: Self.cameraConfirmedKey)
        cameraGranted = true
        cameraSetupStatus = .success
        wearablesStatus = "Camera access approved."
        refreshSetupProgress()
        beginGlassesConnectionSetup(showStatus: false)
    }

    // MARK: - Bypass: onAppBecameActive

    func onAppBecameActive() async {
        let timeout: TimeInterval = registrationOpenedAt == nil ? 2 : 10
        if await waitForRegistrationReady(timeoutSeconds: timeout) {
            registrationOpenedAt = nil
            refreshSetupProgress()
        }

        if pendingCameraPermissionRetry {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await finishPendingCameraPermissionIfPossible()
        } else {
            _ = await resolveCameraPermissionIfAlreadyGranted()
            refreshSetupProgress()
        }
    }

    func runWearablesDiagnostics() async {
        var permissionText = "unknown"
        do {
            permissionText = String(describing: try await sdk.checkPermissionStatus(.camera))
        } catch {
            permissionText = "error: \(error.localizedDescription)"
        }

        let registrationText = String(describing: sdk.registrationState)
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
        Glasses: \(glassesDeviceCount)
        """
    }

    // MARK: - Photo capture (Bypass pattern, not live stream)

    var canStreamFromGlasses: Bool {
        sdkRegistered && cameraGranted
    }

    func captureGlassesPhoto(status: @escaping (String) -> Void) async throws {
        guard await ensureRegistered() else {
            throw WearablesStreamError.notRegistered
        }
        guard cameraGranted || UserDefaults.standard.bool(forKey: Self.cameraConfirmedKey) else {
            throw WearablesStreamError.cameraDenied
        }

        status("Preparing glasses for photo...")
        let ready = await ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 30)
        guard ready else {
            throw WearablesStreamError.noEligibleDevice
        }

        if cameraStream != nil {
            await stopCameraStreamOnly()
        }

        try await startGlassesStreamForCapture(quiet: true)
        status("Capturing photo from glasses...")

        let photoData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            photoCaptureContinuation = continuation
            Task { @MainActor in
                guard let stream = self.cameraStream else {
                    continuation.resume(throwing: WearablesStreamError.streamFailed)
                    return
                }
                _ = await self.triggerSinglePhotoCapture(on: stream)
            }
        }

        if let sample = sampleBufferFromJPEG(photoData) {
            onPhotoSampleBuffer?(sample)
        }

        await stopCameraStreamOnly()
        status("Photo captured")
    }

    /// Legacy live-stream entry — now captures a single photo like Bypass.
    func startGlassesStream(status: @escaping (String) -> Void) async throws {
        try await captureGlassesPhoto(status: status)
    }

    func stopGlassesStream() {
        Task { await stopCameraStreamOnly() }
    }

    // MARK: - Private helpers (Bypass)

    private var datConfig: [String: Any] {
        Bundle.main.infoDictionary?["MWDAT"] as? [String: Any] ?? [:]
    }

    private var datMetaAppID: String { datConfig["MetaAppID"] as? String ?? "<missing>" }
    private var datClientToken: String { datConfig["ClientToken"] as? String ?? "<missing>" }
    private var datTeamID: String { datConfig["TeamID"] as? String ?? "<missing>" }
    private var runtimeBundleID: String { Bundle.main.bundleIdentifier ?? "<missing>" }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 8 else { return token }
        return "\(token.prefix(4))...\(token.suffix(4))"
    }

    private func isRegistrationReady(_ state: RegistrationState) -> Bool {
        state == .registered
    }

    private func waitForRegistrationReady(timeoutSeconds: TimeInterval) async -> Bool {
        if isRegistrationReady(sdk.registrationState) { return true }

        let gate = RegistrationWaitGate()
        let streamTask = Task { @MainActor in
            for await state in self.sdk.registrationStateStream() {
                if await gate.isFinished { return }
                self.applyRegistrationState(state)
                if self.isRegistrationReady(state) {
                    await gate.finish(true)
                    return
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            applyRegistrationState(sdk.registrationState)
            if isRegistrationReady(sdk.registrationState) {
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
        return isRegistrationReady(sdk.registrationState)
    }

    private func ensureRegistered() async -> Bool {
        if isRegistrationReady(sdk.registrationState) { return true }
        if sdk.registrationState == .registering {
            if await waitForRegistrationReady(timeoutSeconds: 15) { return true }
        }
        if await waitForRegistrationReady(timeoutSeconds: 3) { return true }
        return false
    }

    private func safeCameraPermissionStatus() async -> PermissionStatus? {
        try? await sdk.checkPermissionStatus(.camera)
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

    private func resolveCameraPermissionIfAlreadyGranted() async -> Bool {
        if let status = await waitForCameraPermissionStatus(timeoutSeconds: 1), status == .granted {
            markCameraPermissionGranted()
            return true
        }
        return false
    }

    private func finishPendingCameraPermissionIfPossible() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await resolveCameraPermissionIfAlreadyGranted()
    }

    private func validateCameraPermissionFlag() async {
        guard UserDefaults.standard.bool(forKey: Self.cameraConfirmedKey) else {
            cameraSetupStatus = .waiting
            return
        }
        guard let status = await safeCameraPermissionStatus() else { return }
        if status == .granted {
            markCameraPermissionGranted()
        } else {
            UserDefaults.standard.set(false, forKey: Self.cameraConfirmedKey)
            cameraGranted = false
            cameraSetupStatus = .waiting
        }
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

    private func autoSelector() -> AutoDeviceSelector {
        if let autoDeviceSelector { return autoDeviceSelector }
        let selector = AutoDeviceSelector(wearables: sdk)
        autoDeviceSelector = selector
        return selector
    }

    private func startDeviceObserver() {
        deviceObserveTask?.cancel()
        deviceObserveTask = Task { [weak self] in
            guard let self else { return }
            for await devices in self.sdk.devicesStream() {
                await MainActor.run {
                    self.glassesDeviceCount = devices.count
                    if devices.isEmpty {
                        self.glassesDevicesLabel = "Glasses: none detected"
                    } else {
                        self.glassesDevicesLabel = "Glasses: \(devices.count) detected"
                    }
                }
            }
        }
    }

    private func startActiveDeviceMonitoring() {
        guard activeDeviceMonitorTask == nil else { return }
        let selector = autoSelector()
        activeDeviceMonitorTask = Task {
            for await _ in selector.activeDeviceStream() { }
        }
    }

    private func beginGlassesConnectionSetup(showStatus: Bool) {
        Task {
            _ = await ensureReadyDeviceSession(showStatus: showStatus, timeoutSeconds: 60)
        }
    }

    private func ensureReadyDeviceSession(showStatus: Bool, timeoutSeconds: TimeInterval) async -> Bool {
        if let session = readyDeviceSession, session.state == .started { return true }
        return await establishReadyDeviceSession(showStatus: showStatus, timeoutSeconds: timeoutSeconds)
    }

    private func establishReadyDeviceSession(showStatus: Bool, timeoutSeconds: TimeInterval) async -> Bool {
        guard isRegistrationReady(sdk.registrationState) else { return false }
        guard UserDefaults.standard.bool(forKey: Self.cameraConfirmedKey) else { return false }

        if showStatus {
            wearablesStatus = "Preparing glasses for capture..."
        }

        let monitor = bluetoothMonitorInstance()
        if !monitor.isPoweredOn {
            _ = await waitForBluetooth(timeoutSeconds: 5)
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

    private func getOrCreateStartedSession() async throws -> DeviceSession {
        if let session = readyDeviceSession, session.state == .started {
            return session
        }

        let session = try sdk.createSession(deviceSelector: autoSelector())
        readyDeviceSession = session
        try session.start()

        if session.state == .started {
            observeReadySessionState(session)
            return session
        }

        for await state in session.stateStream() {
            if state == .started {
                observeReadySessionState(session)
                return session
            }
            if state == .stopped {
                throw WearablesStreamError.sessionFailed("Session stopped before start.")
            }
        }
        throw WearablesStreamError.sessionFailed("Session failed to start.")
    }

    private func observeReadySessionState(_ session: DeviceSession) {
        readySessionStateTask?.cancel()
        readySessionStateTask = Task { [weak self] in
            for await state in session.stateStream() {
                await MainActor.run {
                    if state == .stopped {
                        self?.readyDeviceSession = nil
                    }
                }
            }
        }
    }

    private func startGlassesStreamForCapture(quiet: Bool) async throws {
        try await startGlassesStreamAttempt(quiet: quiet, photoCaptureOnly: true)
    }

    private func startGlassesStreamAttempt(quiet: Bool, photoCaptureOnly: Bool) async throws {
        if !bluetoothMonitorInstance().isPoweredOn {
            guard await waitForBluetooth(timeoutSeconds: 3) else {
                throw WearablesStreamError.noEligibleDevice
            }
        }

        let deadline = Date().addingTimeInterval(20)
        var lastError: Error = WearablesStreamError.noEligibleDevice
        while Date() < deadline {
            do {
                let session = try await getOrCreateStartedSession()
                try await attachCameraStream(to: session, quiet: quiet, photoCaptureOnly: photoCaptureOnly)
                return
            } catch {
                lastError = error
                readyDeviceSession = nil
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
        throw lastError
    }

    private func attachCameraStream(
        to session: DeviceSession,
        quiet: Bool,
        photoCaptureOnly: Bool
    ) async throws {
        let stream = try await createCameraStreamWithRetry(session)
        cameraStream = stream

        stateToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                let text = String(describing: state).lowercased()
                if photoCaptureOnly,
                   self.photoCaptureContinuation != nil,
                   text.contains("streaming") || text.contains("started") {
                    _ = await self.triggerSinglePhotoCapture(on: stream)
                }
                if !quiet {
                    self.wearablesStatus = "Stream: \(String(describing: state))"
                }
            }
        }

        photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                guard let self, let continuation = self.photoCaptureContinuation else { return }
                self.photoCaptureContinuation = nil
                continuation.resume(returning: photoData.data)
            }
        }

        frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                self?.onVideoFrame?(frame)
            }
        }

        await stream.start()
    }

    private func createCameraStreamWithRetry(_ session: DeviceSession, maxAttempts: Int = 10) async throws -> MWDATCamera.Stream {
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )
        for attempt in 1...maxAttempts {
            if let stream = try? session.addStream(config: config) {
                return stream
            }
            wearablesStatus = "Preparing camera stream (\(attempt)/\(maxAttempts))..."
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw WearablesStreamError.streamFailed
    }

    private func triggerSinglePhotoCapture(on stream: MWDATCamera.Stream) async -> Bool {
        for _ in 1...4 {
            guard photoCaptureContinuation != nil else { return true }
            if stream.capturePhoto(format: PhotoCaptureFormat.jpeg) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func stopCameraStreamOnly() async {
        stateToken = nil
        frameToken = nil
        photoToken = nil
        await cameraStream?.stop()
        cameraStream = nil
    }

    private func installForegroundObserver() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.onAppBecameActive() }
        }
    }

    enum WearablesStreamError: LocalizedError {
        case notRegistered
        case cameraDenied
        case streamFailed
        case noEligibleDevice
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRegistered: return "Register with Meta AI first."
            case .cameraDenied: return "Allow camera in Meta AI first."
            case .streamFailed: return "Could not start glasses camera."
            case .noEligibleDevice: return "No eligible glasses. Wear them, open Meta AI, Bluetooth on."
            case .sessionFailed(let detail): return detail
            }
        }
    }
}

private func sampleBufferFromJPEG(_ data: Data) -> CMSampleBuffer? {
    guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    var pixelBuffer: CVPixelBuffer?
    let attrs = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess,
          let buffer = pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
    guard let format else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer
}

private actor RegistrationWaitGate {
    private(set) var isFinished = false
    private(set) var result = false

    func finish(_ value: Bool) {
        guard !isFinished else { return }
        isFinished = true
        result = value
    }
}
