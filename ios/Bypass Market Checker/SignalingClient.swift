import Foundation

struct ViewerPresence: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String

    var statusLabel: String {
        status == "watching" ? "Watching" : "Waiting"
    }

    var isWatching: Bool {
        status == "watching"
    }
}

struct CastChatMessage: Identifiable, Equatable {
    let id: String
    let viewerId: String
    let name: String
    let text: String
    let kind: String
    let gifUrl: String?

    var isGif: Bool { kind == "gif" }

    var previewText: String {
        if isGif { return "Sent a GIF" }
        return text
    }
}

@MainActor
final class SignalingClient: ObservableObject {
    @Published var status = "Offline"
    @Published var connected = false
    @Published var desktopLinked = false
    @Published var glassesLinked = false
    @Published var viewerCount = 0
    @Published var viewerRoster: [ViewerPresence] = []
    @Published var chatMessages: [CastChatMessage] = []

    private var chatSyncGeneration = 0

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
    var onAnswer: ((String, String) -> Void)?
    var onIceCandidate: ((String, Int32, String?, String) -> Void)?
    var onGlassesJoined: (() -> Void)?
    var onGlassesLeft: (() -> Void)?
    var onDesktopJoined: (() -> Void)?
    var onViewerJoined: ((String) -> Void)?
    var onViewerLeft: ((String) -> Void)?
    var onViewerNeedsOffer: ((String) -> Void)?

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
        viewerCount = 0
        viewerRoster = []
        chatMessages = []
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

    func clearLiveChat() {
        chatSyncGeneration += 1
        sendSignal(type: "clear-chat")
        chatMessages = []
    }

    func deleteChatMessage(id: String) {
        sendSignal(type: "delete-chat-message", payload: ["messageId": id])
        chatMessages.removeAll { $0.id == id }
    }

    func syncChatHistory() {
        chatSyncGeneration += 1
        let generation = chatSyncGeneration
        sendSignal(type: "sync-chat", payload: ["generation": generation])
    }

    func sendOffer(_ sdp: String, viewerId: String) {
        sendSignal(type: "offer", payload: ["sdp": sdp, "target": "viewer", "viewerId": viewerId])
    }

    func sendOfferToLegacyDesktop(_ sdp: String) {
        sendSignal(type: "offer", payload: ["sdp": sdp, "target": "desktop"])
    }

    func sendIceCandidate(_ candidate: String, sdpMLineIndex: Int32, sdpMid: String?, viewerId: String) {
        sendSignal(type: "ice-candidate", payload: [
            "candidate": candidate,
            "sdpMLineIndex": sdpMLineIndex,
            "sdpMid": sdpMid ?? "",
            "viewerId": viewerId,
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

    private func parseChatMessage(_ json: [String: Any]) -> CastChatMessage? {
        guard let id = json["id"] as? String else { return nil }
        let viewerId = json["viewerId"] as? String ?? ""
        let name = json["name"] as? String ?? "Guest"
        let kind = json["kind"] as? String ?? "text"
        let text = json["text"] as? String ?? ""
        let gifUrl = json["gifUrl"] as? String
        return CastChatMessage(
            id: id,
            viewerId: viewerId,
            name: name,
            text: text,
            kind: kind,
            gifUrl: gifUrl
        )
    }

    private func applyChatHistory(_ raw: [[String: Any]], generation: Int? = nil) {
        if let generation, generation < chatSyncGeneration { return }
        chatMessages = raw.compactMap { parseChatMessage($0) }
    }

    private func appendChatMessage(_ json: [String: Any]) {
        guard let message = parseChatMessage(json) else { return }
        if chatMessages.contains(where: { $0.id == message.id }) { return }
        chatMessages.append(message)
        if chatMessages.count > 100 {
            chatMessages.removeFirst(chatMessages.count - 100)
        }
    }

    private func applyViewerList(_ json: [String: Any]) {
        guard let raw = json["viewers"] as? [[String: Any]] else { return }
        viewerRoster = raw.compactMap { item in
            guard let viewerId = item["viewerId"] as? String,
                  let name = item["name"] as? String else { return nil }
            let status = item["status"] as? String ?? "waiting"
            return ViewerPresence(id: viewerId, name: name, status: status)
        }
        viewerCount = viewerRoster.count
        desktopLinked = viewerCount > 0
        refreshViewerStatusText()
    }

    private func refreshViewerStatusText() {
        if viewerRoster.isEmpty {
            status = glassesLinked ? "Glasses connected — waiting for viewers" : "Ready — open viewer link or glasses app"
            return
        }
        let watching = viewerRoster.filter(\.isWatching).count
        let waiting = viewerRoster.count - watching
        if watching > 0 && waiting > 0 {
            status = "\(watching) watching, \(waiting) waiting"
        } else if watching > 0 {
            status = "\(watching) viewer\(watching == 1 ? "" : "s") watching"
        } else {
            status = "\(viewerRoster.count) viewer\(viewerRoster.count == 1 ? "" : "s") waiting"
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "relay-registered", "code-rotated":
            if let sid = json["sessionId"] as? String { savedSessionId = sid }
            if let history = json["chatHistory"] as? [[String: Any]] {
                applyChatHistory(history)
            }
            connected = true
            status = "Ready — open viewer link or glasses app"
            registerTask?.cancel()
            registerTask = nil
            startPing()
        case "relay-offline":
            status = json["message"] as? String ?? "Relay paused — keep app open"
        case "relay-online":
            connected = true
            status = "Phone relay back online"
        case "desktop-joined":
            desktopLinked = true
            status = "Viewer connected"
            onDesktopJoined?()
        case "viewer-joined":
            if json["viewers"] != nil {
                applyViewerList(json)
            } else if let vid = json["viewerId"] as? String {
                let name = json["name"] as? String ?? "Guest"
                let status = json["status"] as? String ?? "waiting"
                if !viewerRoster.contains(where: { $0.id == vid }) {
                    viewerRoster.append(ViewerPresence(id: vid, name: name, status: status))
                    viewerRoster.sort {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                }
                viewerCount = viewerRoster.count
                desktopLinked = viewerCount > 0
                refreshViewerStatusText()
            }
            if let vid = json["viewerId"] as? String {
                onViewerJoined?(vid)
            }
        case "viewer-list-updated":
            applyViewerList(json)
        case "viewer-left":
            if json["viewers"] != nil {
                applyViewerList(json)
            } else if let vid = json["viewerId"] as? String {
                viewerRoster.removeAll { $0.id == vid }
                viewerCount = viewerRoster.count
                desktopLinked = viewerCount > 0
                refreshViewerStatusText()
            }
            if let vid = json["viewerId"] as? String {
                onViewerLeft?(vid)
            }
        case "viewer-needs-offer":
            if let vid = json["viewerId"] as? String {
                onViewerNeedsOffer?(vid)
            }
        case "chat-message":
            appendChatMessage(json)
        case "chat-cleared":
            chatSyncGeneration += 1
            chatMessages = []
        case "chat-sync":
            if let history = json["messages"] as? [[String: Any]] {
                let generation = json["generation"] as? Int
                applyChatHistory(history, generation: generation)
            }
        case "chat-message-deleted":
            if let id = json["id"] as? String {
                chatMessages.removeAll { $0.id == id }
            }
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
            if let sdp = json["sdp"] as? String {
                let viewerId = json["viewerId"] as? String ?? "legacy-desktop"
                onAnswer?(sdp, viewerId)
            }
        case "ice-candidate":
            if let c = json["candidate"] as? String {
                let idx = json["sdpMLineIndex"] as? Int32 ?? 0
                let mid = json["sdpMid"] as? String
                let viewerId = json["viewerId"] as? String ?? "legacy-desktop"
                onIceCandidate?(c, idx, mid, viewerId)
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
