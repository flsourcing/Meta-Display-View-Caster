import SwiftUI
import UIKit

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

    init() {
        let saved = UserDefaults.standard.string(forKey: "signalingServerURL") ?? Self.defaultServer
        serverURLString = saved
        let url = URL(string: saved.trimmingCharacters(in: .whitespaces))
            ?? URL(string: Self.defaultServer)!
        signaling = SignalingClient(serverURL: url)
        wireCallbacks()
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
        signaling.disconnect()
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
        metaHint = """
        Verify in Meta AI, then tap Open to return here (important).
        Step 2 unlocks after you return — Allow glasses camera opens Meta AI again for camera access.
        """
        wearables.connectMetaAI()
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
        Task { await wearables.requestGlassesCamera() }
    }

    func connectMetaAIWebApp() {
        UIPasteboard.general.string = Self.glassesURL
        metaHint = "Glasses web app URL copied. Meta AI → Web apps → add URL for the digit pad on glasses."
    }

    func handleMetaCallback(_ url: URL) async {
        await wearables.handleCallback(url)
    }

    func onReturnFromBackground() {
        refreshMetaInstallState()
        Task { await wearables.refreshAfterForeground() }
        if !signaling.connected {
            start()
        }
    }

    private func beginGlassesCast() async {
        signaling.status = "Starting glasses camera…"
        do {
            webrtc.startStream()
            try await wearables.startGlassesStream()
            signaling.status = "Casting from glasses"
        } catch {
            webrtc.stopStream()
            wearables.stopGlassesStream()
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
                            Text("This IPA is missing your Team ID in MWDAT config. Install the GitHub release built for your Team ID.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if let configured = SigningInfo.configuredMWTeamID {
                                Text("Built-in Team ID: \(configured)")
                                    .font(.caption.monospaced())
                            } else if !model.sideloadTeamId.isEmpty {
                                Text("Sideload Team ID: \(model.sideloadTeamId)")
                                    .font(.caption.monospaced())
                            }
                            Button("Copy Team ID") {
                                model.copyTeamIdForPatch()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Group {
                        Button("1. Connect Meta AI") {
                            model.connectMetaAI()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.wearables.isRegistered || model.metaBlocked)

                        Text(model.wearables.registrationLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if !model.wearables.isRegistered && !model.metaBlocked
                            && model.wearables.registrationLabel.contains("Meta AI") {
                            Button("Refresh after Meta AI") {
                                model.refreshMetaConnection()
                            }
                            .font(.footnote)
                        }

                        Button("2. Allow glasses camera") {
                            model.allowGlassesCamera()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.wearables.canRequestCamera)

                        Text(model.wearables.cameraLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Add glasses web app (digit pad)") {
                            model.connectMetaAIWebApp()
                        }
                        .buttonStyle(.bordered)
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
                if phase == .active {
                    model.onReturnFromBackground()
                }
            }
        }
    }
}
