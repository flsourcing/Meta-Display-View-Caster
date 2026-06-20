import SwiftUI

@MainActor
final class RelayViewModel: ObservableObject {
    @Published var serverURLString: String
    @Published private(set) var signaling: SignalingClient
    private let webrtc = WebRTCManager()

    init() {
        let saved = UserDefaults.standard.string(forKey: "signalingServerURL")
            ?? "wss://meta-display-view-caster.onrender.com"
        serverURLString = saved
        signaling = SignalingClient(serverURL: URL(string: saved)!)
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
        applyServerURL()
        wireCallbacks()
        signaling.connect()
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

                Button(model.signaling.connected ? "Restart relay" : "Start relay") {
                    model.stop()
                    model.start()
                }
                .buttonStyle(.borderedProminent)

                Text("1. Start relay here\n2. Enter code on desktop\n3. Enter code on glasses\n4. Tap Live Stream on glasses")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .onAppear { model.start() }
        }
    }
}
