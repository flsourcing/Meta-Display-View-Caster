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

        signaling.onStartStream = { [weak self] in
            Task { @MainActor in
                await self?.beginGlassesCast()
            }
        }
        signaling.onStopStream = { [weak self] in
            self?.wearables.stopGlassesStream()
            self?.webrtc.stopStream()
        }
        signaling.onAnswer = { [weak self] sdp in
            self?.webrtc.handleAnswer(sdp)
        }
        signaling.onIceCandidate = { [weak self] candidate, idx, mid in
            self?.webrtc.handleRemoteIce(candidate: candidate, sdpMLineIndex: idx, sdpMid: mid)
        }
    }

    func configureWearables() {
        wearables.configure()
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
        wearables.stopGlassesStream()
        webrtc.stopStream()
        signaling.disconnectAndClearSession()
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
        metaHint = """
        \(SigningInfo.developerModeHint)
        In Meta AI you should see a prompt to connect View Caster Relay.
        If Meta AI opens with no prompt, tap Reset Meta connection below and try again.
        """
        wearables.connectMetaAI()
    }

    func resetMetaConnection() {
        wearables.resetMetaConnection()
        metaHint = "Disconnect View Caster in Meta AI if listed, then tap Connect Meta AI again."
    }

    func clearLocalMetaState() {
        wearables.clearLocalMetaState()
        metaHint = "Local Meta steps reset. Tap Connect Meta AI."
    }

    func refreshMetaConnection() {
        Task { await wearables.refreshAfterForeground() }
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
        Task {
            await wearables.requestGlassesCamera()
        }
    }

    func syncMetaStatus() {
        Task { await wearables.refreshAfterForeground() }
    }

    func connectMetaAIWebApp() {
        UIPasteboard.general.string = Self.glassesURL
        metaHint = "Glasses web app URL copied. Meta AI → Web apps → add URL for the digit pad on glasses."
    }

    func handleMetaCallback(_ url: URL) async {
        await wearables.handleCallback(url)
    }

    func onReturnFromBackground() {
        endBackgroundTask()
        refreshMetaInstallState()
        wearables.unlockCameraStepIfNeeded()
        Task { await wearables.refreshAfterForeground() }
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

    func finishedMetaAISetup() {
        wearables.markMetaSetupStarted()
        Task { await wearables.refreshAfterForeground() }
        metaHint = "Step 2 enabled. Tap Allow glasses camera."
    }

    private func beginGlassesCast() async {
        signaling.status = "Starting glasses camera…"
        await wearables.refreshAfterForeground()
        do {
            try await wearables.startGlassesStream()
            webrtc.startStream()
            signaling.sendSignal(type: "stream-started")
            signaling.status = "Casting from glasses"
        } catch {
            webrtc.stopStream()
            wearables.stopGlassesStream()
            signaling.sendSignal(type: "stream-error", payload: ["message": error.localizedDescription])
            signaling.status = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: RelayViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("View Caster Relay")
                        .font(.title2.bold())

                    Text("Glasses camera (native)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Meta setup")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("Bundle: \(SigningInfo.bundleIdentifier)")
                            .font(.caption.monospaced())
                        Text("IPA Team: \(SigningInfo.configuredMWTeamID ?? "missing")")
                            .font(.caption.monospaced())
                        Text("Sideload Team: \(SigningInfo.embeddedTeamIdentifier ?? "unknown")")
                            .font(.caption.monospaced())
                        Text("Meta state: \(model.wearables.registrationStateName)")
                            .font(.caption.monospaced())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Group {
                        Label(model.wearables.isRegistered ? "1. Meta AI connected" : "1. Connect Meta AI",
                              systemImage: model.wearables.isRegistered ? "checkmark.circle.fill" : "circle")

                        Button("1. Connect Meta AI") {
                            model.connectMetaAI()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.wearables.isRegistered || model.metaBlocked)

                        Text(model.wearables.registrationLabel)
                            .font(.footnote)
                            .foregroundStyle(model.wearables.isRegistered ? .green : .secondary)
                            .multilineTextAlignment(.center)

                        if model.wearables.metaSetupStarted && !model.wearables.isRegistered {
                            Button("Sync Meta status") {
                                model.syncMetaStatus()
                            }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                        }

                        if !model.wearables.lastMetaSyncNote.isEmpty {
                            Text(model.wearables.lastMetaSyncNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Label(model.wearables.cameraGranted ? "2. Glasses camera allowed" : "2. Allow glasses camera",
                              systemImage: model.wearables.cameraGranted ? "checkmark.circle.fill" : "circle")

                        Button("2. Allow glasses camera") {
                            model.allowGlassesCamera()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.metaBlocked || model.wearables.cameraGranted
                                  || (!model.wearables.metaSetupStarted && !model.wearables.isRegistered))

                        Text(model.wearables.cameraLabel)
                            .font(.footnote)
                            .foregroundStyle(model.wearables.cameraGranted ? .green : .secondary)
                            .multilineTextAlignment(.center)

                        Button("Add glasses web app (digit pad)") {
                            model.connectMetaAIWebApp()
                        }
                        .buttonStyle(.bordered)

                        Button("Sync Meta status") {
                            model.syncMetaStatus()
                        }
                        .font(.footnote)

                        Button("Reset Meta connection") {
                            model.resetMetaConnection()
                        }
                        .font(.footnote)

                        Button("Clear local Meta steps") {
                            model.clearLocalMetaState()
                        }
                        .font(.footnote)
                    }

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

                    Text("Profile web app uses your iPhone camera only.\nThis native app streams from Meta glasses via Meta AI.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

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
                model.configureWearables()
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
