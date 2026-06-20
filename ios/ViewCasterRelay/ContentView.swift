import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class RelayViewModel: ObservableObject {
    @Published var serverURLString: String
    @Published private(set) var signaling: SignalingClient
    @Published var cameraStatus = "Tap to allow camera for Live Stream"
    @Published var metaHint = ""
    private let webrtc = WebRTCManager()

    static let glassesURL = "https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html"

    init() {
        let saved = UserDefaults.standard.string(forKey: "signalingServerURL") ?? ""
        serverURLString = saved
        let url = URL(string: saved.trimmingCharacters(in: .whitespaces))
            ?? URL(string: "wss://localhost")!
        signaling = SignalingClient(serverURL: url)
        wireCallbacks()
    }

    func wireCallbacks() {
        webrtc.attach(signaling: signaling)
        signaling.onStartStream = { [weak self] in
            self?.webrtc.startStream()
        }
        signaling.onStopStream = { [weak self] in
            self?.webrtc.stopStream()
        }
    }

    func applyServerURL() {
        UserDefaults.standard.set(serverURLString, forKey: "signalingServerURL")
        guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)) else { return }
        signaling.updateServerURL(url)
    }

    func start() {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme?.hasPrefix("ws") == true else {
            signaling.status = "Enter signaling server URL (deploy server/ to Render first)"
            return
        }
        applyServerURL()
        wireCallbacks()
        signaling.connect()
    }

    func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                self?.cameraStatus = granted
                    ? "Camera allowed — ready for Live Stream"
                    : "Camera denied — enable in Settings → View Caster Relay"
            }
        }
    }

    func connectMetaAI() {
        UIPasteboard.general.string = Self.glassesURL
        metaHint = "Glasses URL copied. Meta AI app → Web apps → add URL, then enter the code on glasses."
    }

    func stop() {
        webrtc.stopStream()
        signaling.disconnect()
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: RelayViewModel

    var body: some View {
        NavigationStack {
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

                TextField("Signaling server (wss://…)", text: $model.serverURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Allow camera permissions") {
                    model.requestCameraAccess()
                }
                .buttonStyle(.bordered)

                Text(model.cameraStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Connect Meta AI glasses") {
                    model.connectMetaAI()
                }
                .buttonStyle(.bordered)

                if !model.metaHint.isEmpty {
                    Text(model.metaHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(model.signaling.connected ? "Restart relay" : "Start relay") {
                    model.stop()
                    model.start()
                }
                .buttonStyle(.borderedProminent)

                Text("Profile app (no server): use install.html on iPhone.\nNative app: deploy server/ to Render, paste wss:// URL above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("1. Start relay here\n2. Enter code on desktop\n3. Enter code on glasses\n4. Tap Live Stream on glasses")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .onAppear {
                if !model.serverURLString.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.start()
                } else {
                    model.signaling.status = "Enter signaling server URL, then tap Start relay"
                }
            }
        }
    }
}
