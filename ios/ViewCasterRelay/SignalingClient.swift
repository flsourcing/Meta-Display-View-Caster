import Foundation

@MainActor
final class SignalingClient: ObservableObject {
    @Published var code = "------"
    @Published var status = "Offline"
    @Published var connected = false
    @Published var desktopLinked = false
    @Published var glassesLinked = false

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var serverURL: URL
    private var pingTask: Task<Void, Never>?

    var onStartStream: (() -> Void)?
    var onStopStream: (() -> Void)?
    var onOffer: ((String) -> Void)?
    var onAnswer: ((String) -> Void)?
    var onIceCandidate: ((String, Int32, String?) -> Void)?

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    func updateServerURL(_ url: URL) {
        serverURL = url
    }

    func connect() {
        disconnect()
        status = "Connecting…"
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: serverURL)
        ws = task
        task.resume()
        listen()
        send(["type": "register-relay"])
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        connected = false
        desktopLinked = false
        glassesLinked = false
        status = "Offline"
    }

    func sendSignal(type: String, payload: [String: Any] = [:]) {
        var body = payload
        body["type"] = type
        send(body)
    }

    func sendOffer(_ sdp: String) {
        sendSignal(type: "offer", payload: ["sdp": sdp, "target": "desktop"])
    }

    func sendAnswer(_ sdp: String) {
        sendSignal(type: "answer", payload: ["sdp": sdp, "target": "desktop"])
    }

    func sendIceCandidate(_ candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        sendSignal(type: "ice-candidate", payload: [
            "candidate": candidate,
            "sdpMLineIndex": sdpMLineIndex,
            "sdpMid": sdpMid ?? "",
        ])
    }

    private func send(_ body: [String: Any]) {
        guard let ws else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if error != nil {
                Task { @MainActor in self?.status = "Send failed" }
            }
        }
    }

    private func listen() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in
                    self.connected = false
                    self.status = "Could not reach signaling server"
                }
            case .success(let message):
                Task { @MainActor in
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.listen()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "relay-registered", "code-rotated":
            if let c = json["code"] as? String { code = c }
            connected = true
            status = "Ready — connect desktop & glasses"
            startPing()
        case "desktop-joined":
            desktopLinked = true
            status = "Desktop connected"
        case "glasses-joined":
            glassesLinked = true
            status = desktopLinked ? "All linked" : "Glasses connected"
        case "desktop-left":
            desktopLinked = false
            status = "Desktop disconnected"
        case "glasses-left":
            glassesLinked = false
        case "start-stream":
            onStartStream?()
        case "stop-stream":
            onStopStream?()
        case "offer":
            if let sdp = json["sdp"] as? String { onOffer?(sdp) }
        case "answer":
            if let sdp = json["sdp"] as? String { onAnswer?(sdp) }
        case "ice-candidate":
            if let c = json["candidate"] as? String {
                let idx = json["sdpMLineIndex"] as? Int32 ?? 0
                let mid = json["sdpMid"] as? String
                onIceCandidate?(c, idx, mid)
            }
        case "error":
            status = json["message"] as? String ?? "Error"
        default:
            break
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                ws?.sendPing { _ in }
            }
        }
    }
}
