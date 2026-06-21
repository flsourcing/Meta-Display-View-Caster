import SwiftUI
import UIKit
import Combine

@MainActor
final class RelayViewModel: ObservableObject {
    static let defaultServer = "wss://meta-display-view-caster.onrender.com"
    static let glassesURL = "https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html"

    @Published var serverURLString: String
    @Published private(set) var signaling: SignalingClient
    @Published var metaHint = ""
    @Published private(set) var wearables = WearablesManager()
    @Published var sideloadTeamId = SigningInfo.displayTeamID ?? ""
    @Published var metaBlocked = SigningInfo.needsTeamIDPatch

    private lazy var webrtc = WebRTCManager()
    private let phoneCamera = PhoneCameraManager()
    private var castTask: Task<Void, Never>?
    private var subs = Set<AnyCancellable>()

    init() {
        let saved = UserDefaults.standard.string(forKey: "signalingServerURL") ?? Self.defaultServer
        serverURLString = saved
        let url = URL(string: saved.trimmingCharacters(in: .whitespaces))
            ?? URL(string: Self.defaultServer)!
        signaling = SignalingClient(serverURL: url)
        wireCallbacks()
        wearables.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subs)
    }

    func wireCallbacks() {
        webrtc.attach(signaling: signaling)

        wearables.onVideoFrame = { [weak self] frame in
            self?.webrtc.pushGlassesFrame(frame)
        }

        phoneCamera.onSampleBuffer = { [weak self] buffer in
            self?.webrtc.pushSampleBuffer(buffer)
        }

        signaling.onStartStream = { [weak self] in
            Task { @MainActor in
                await self?.beginGlassesCast()
            }
        }
        signaling.onStopStream = { [weak self] in
            Task { @MainActor in
                self?.cancelCast()
            }
        }
        signaling.onAnswer = { [weak self] sdp in
            self?.webrtc.handleAnswer(sdp)
        }
        signaling.onIceCandidate = { [weak self] candidate, idx, mid in
            self?.webrtc.handleRemoteIce(candidate: candidate, sdpMLineIndex: idx, sdpMid: mid)
        }
    }

    func configureWearables(configError: String? = nil) {
        webrtc.prepareFactory()
        wearables.configure(configError: configError)
    }

    func applyServerURL() {
        UserDefaults.standard.set(serverURLString, forKey: "signalingServerURL")
        guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)) else { return }
        signaling.updateServerURL(url)
    }

    func start() {
        applyServerURL()
        wireCallbacks()
        signaling.connect()
    }

    func stop() {
        cancelCast()
        signaling.disconnectAndClearSession()
    }

    private func stopCast() {
        phoneCamera.stop()
        wearables.stopGlassesStream()
        webrtc.stopStream()
    }

    private func cancelCast() {
        castTask?.cancel()
        castTask = nil
        stopCast()
    }

    func restartRelay() {
        signaling.connect()
    }

    func connectMetaAI() {
        refreshMetaInstallState()
        if metaBlocked {
            metaHint = SigningInfo.patchInstructions
            return
        }
        if let issue = SigningInfo.metaConnectionIssue {
            metaHint = issue
            return
        }
        metaHint = ""
        wearables.connectMetaAI()
    }

    func copyTeamIdForPatch() {
        let team = SigningInfo.displayTeamID ?? sideloadTeamId
        guard !team.isEmpty else {
            metaHint = "Team ID not found — check Sideloadly install log or GitHub release for your build."
            return
        }
        UIPasteboard.general.string = team
        metaHint = "Copied Team ID \(team)."
    }

    func refreshMetaInstallState() {
        sideloadTeamId = SigningInfo.displayTeamID ?? sideloadTeamId
        metaBlocked = SigningInfo.needsTeamIDPatch
    }

    func allowGlassesCamera() {
        metaHint = ""
        Task {
            await wearables.requestGlassesCamera()
        }
    }

    func handleMetaCallback(_ url: URL) async {
        await wearables.handleCallback(url)
    }

    func onReturnFromBackground() {
        endBackgroundTask()
        refreshMetaInstallState()
        Task {
            await wearables.onAppBecameActive()
        }
        if !signaling.connected {
            start()
        }
    }

    func onEnterBackground() {
        beginBackgroundTask()
    }

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func beginGlassesCast() async {
        if castTask != nil {
            signaling.status = "Cast already starting…"
            return
        }

        castTask = Task { @MainActor in
            await runGlassesCast()
            castTask = nil
        }
        await castTask?.value
    }

    private func runGlassesCast() async {
        stopCast()
        signaling.status = "Starting stream…"
        webrtc.startStream()

        if wearables.canStreamFromGlasses {
            do {
                try await wearables.startGlassesStream { [weak self] step in
                    self?.signaling.status = step
                }
                guard !Task.isCancelled else { return }
                signaling.sendSignal(type: "stream-started")
                signaling.status = "Casting from glasses"
                return
            } catch {
                wearables.stopGlassesStream()
                signaling.status = "Glasses stream failed — trying phone camera…"
            }
        } else {
            signaling.status = "Meta SDK not registered — using phone camera fallback…"
        }

        guard !Task.isCancelled else { return }

        do {
            try await phoneCamera.startAfterAuthorization()
            guard !Task.isCancelled else {
                phoneCamera.stop()
                webrtc.stopStream()
                return
            }
            signaling.sendSignal(type: "stream-started", payload: ["source": "phone"])
            signaling.status = "Casting from phone camera (hold phone at glasses POV)"
        } catch {
            phoneCamera.stop()
            webrtc.stopStream()
            let msg = error.localizedDescription
            signaling.sendSignal(type: "stream-error", payload: ["message": msg])
            signaling.status = msg
        }
    }
}

struct ContentView: View {
    var configureError: String?
    @EnvironmentObject private var model: RelayViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("View Caster Relay")
                        .font(.title2.bold())

                    Text(model.signaling.code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .tracking(4)

                    HStack {
                        Circle()
                            .fill(model.signaling.connected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(model.signaling.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.signaling.desktopLinked ? "Desktop linked" : "Desktop waiting",
                              systemImage: model.signaling.desktopLinked ? "checkmark.circle.fill" : "circle")
                        Label(model.signaling.glassesLinked ? "Glasses linked" : "Glasses waiting",
                              systemImage: model.signaling.glassesLinked ? "checkmark.circle.fill" : "circle")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if model.metaBlocked {
                        VStack(spacing: 10) {
                            Text("Meta AI can't connect to this install")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                            Text(SigningInfo.patchInstructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if let configured = SigningInfo.configuredMWTeamID {
                                Text("IPA Team ID: \(configured)")
                                    .font(.caption.monospaced())
                            }
                            if let signed = SigningInfo.embeddedTeamIdentifier {
                                Text("Sideload Team ID: \(signed)")
                                    .font(.caption.monospaced())
                            }
                            Button("Copy Sideload Team ID") {
                                model.copyTeamIdForPatch()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Meta Glasses Camera")
                            .font(.headline)

                        MetaSetupStepView(
                            title: "Register with Meta AI",
                            statusLabel: model.wearables.registrationSetupStatus == .success ? "Successful" : "Waiting for connection...",
                            isSuccess: model.wearables.registrationSetupStatus == .success,
                            buttonTitle: "Register With Meta AI",
                            buttonIcon: "link",
                            hint: "Toggle ON and tap Connect in Meta AI. Let it return you here automatically — do not use the back button.",
                            disabled: model.wearables.registrationSetupStatus == .success || model.metaBlocked
                        ) {
                            model.connectMetaAI()
                        }

                        MetaSetupStepView(
                            title: "Allow Camera",
                            statusLabel: model.wearables.cameraSetupStatus == .success ? "Successful" : "Waiting for approval...",
                            isSuccess: model.wearables.cameraSetupStatus == .success,
                            buttonTitle: "Allow Camera",
                            buttonIcon: "camera.badge.ellipsis",
                            hint: "Approve camera access in Meta AI, then return here. Next unlocks when allowed.",
                            disabled: model.metaBlocked || model.wearables.cameraSetupStatus == .success
                        ) {
                            model.allowGlassesCamera()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if !model.metaHint.isEmpty {
                        Text(model.metaHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    TextField("Signaling server (wss://…)", text: $model.serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(model.signaling.connected ? "Restart relay" : "Start relay") {
                        if model.signaling.connected {
                            model.stop()
                            model.start()
                        } else {
                            model.restartRelay()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Keep this app open on the pairing code while entering the code on glasses & desktop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("3. Start relay → code on desktop & glasses\n4. Tap Live Stream on glasses")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .onAppear {
                model.refreshMetaInstallState()
                model.configureWearables(configError: configureError)
                model.start()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    model.onReturnFromBackground()
                case .background:
                    model.onEnterBackground()
                default:
                    break
                }
            }
        }
    }
}

private struct MetaSetupStepView: View {
    let title: String
    let statusLabel: String
    let isSuccess: Bool
    let buttonTitle: String
    let buttonIcon: String
    let hint: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                Circle()
                    .fill(isSuccess ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(statusLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSuccess ? .green : .orange)
            }

            Button(action: action) {
                Label(buttonTitle, systemImage: buttonIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(disabled)

            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
