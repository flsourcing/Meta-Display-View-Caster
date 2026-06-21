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
    private var connectTask: Task<Void, Never>?
    private var registerTask: Task<Void, Never>?
    private var savedSessionId: String? {
        get { UserDefaults.standard.string(forKey: "relaySessionId") }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: "relaySessionId") }
            else { UserDefaults.standard.removeObject(forKey: "relaySessionId") }
        }
    }

    var onStartStream: (() -> Void)?
    var onStopStream: (() -> Void)?
    var onAnswer: ((String) -> Void)?
    var onIceCandidate: ((String, Int32, String?) -> Void)?
    var onGlassesJoined: (() -> Void)?
    var onGlassesLeft: (() -> Void)?
    var onDesktopJoined: (() -> Void)?

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    func updateServerURL(_ url: URL) {
        serverURL = url
    }

    func connect() {
        connectTask?.cancel()
        connectTask = Task { await connectAsync() }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        closeSocket()
        connected = false
        desktopLinked = false
        glassesLinked = false
        status = "Offline"
    }

    func disconnectAndClearSession() {
        savedSessionId = nil
        disconnect()
    }

    private func closeSocket() {
        registerTask?.cancel()
        registerTask = nil
        pingTask?.cancel()
        pingTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
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

    private func httpBase() -> URL? {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        guard let scheme = serverURL.scheme?.lowercased() else { return nil }
        components?.scheme = scheme == "wss" ? "https" : "http"
        return components?.url
    }

    private func wakeServer(maxAttempts: Int = 4) async -> Bool {
        guard let base = httpBase() else { return false }
        let health = base.appendingPathComponent("health")
        for attempt in 1...maxAttempts {
            if Task.isCancelled { return false }
            status = attempt == 1
                ? "Waking signaling server…"
                : "Waking server (attempt \(attempt)/\(maxAttempts))…"
            do {
                var request = URLRequest(url: health)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 25
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return true }
            } catch {
                NSLog("CastRelay: health check failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return false
    }

    private func connectAsync() async {
        closeSocket()
        connected = false
        code = "------"
        status = "Connecting…"

        _ = await wakeServer()

        for attempt in 1...3 {
            if Task.isCancelled { return }

            status = attempt == 1 ? "Connecting to relay…" : "Retrying relay (\(attempt)/3)…"

            let session = URLSession(configuration: .default)
            self.session = session
            let task = session.webSocketTask(with: serverURL)
            ws = task
            task.resume()
            listen()
            startRegisterLoop()

            for tick in 0..<100 {
                if Task.isCancelled { return }
                if connected { return }
                if tick == 20 && !connected {
                    status = "Still connecting… (server may take up to 60s)"
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            closeSocket()
            _ = await wakeServer(maxAttempts: 2)
        }

        if !connected {
            status = "Could not reach signaling server — tap Restart relay"
        }
    }

    private func startRegisterLoop() {
        registerTask?.cancel()
        registerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            while !Task.isCancelled && !connected {
                var payload: [String: Any] = ["type": "register-relay"]
                if let savedSessionId { payload["sessionId"] = savedSessionId }
                send(payload)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func send(_ body: [String: Any]) {
        guard let ws else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    guard let self, !self.connected else { return }
                    self.status = "Send failed — retrying…"
                }
            }
        }
    }

    private func listen() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in
                    guard !self.connected else { return }
                    self.status = "Connection lost — tap Restart relay"
                    self.connected = false
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
            if let sid = json["sessionId"] as? String { savedSessionId = sid }
            connected = true
            status = "Enter this code on desktop & glasses"
            registerTask?.cancel()
            registerTask = nil
            startPing()
        case "relay-offline":
            status = json["message"] as? String ?? "Relay paused — keep app open"
        case "relay-online":
            connected = true
            if let c = json["code"] as? String { code = c }
            status = "Phone relay back online"
        case "desktop-joined":
            desktopLinked = true
            status = "Desktop connected"
            onDesktopJoined?()
        case "glasses-joined":
            glassesLinked = true
            status = desktopLinked ? "Desktop & glasses linked" : "Glasses connected"
            onGlassesJoined?()
        case "desktop-left":
            desktopLinked = false
            status = "Desktop disconnected"
        case "glasses-left":
            glassesLinked = false
            onGlassesLeft?()
        case "start-stream":
            onStartStream?()
        case "stop-stream":
            onStopStream?()
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
