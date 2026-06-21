import MWDATCore
import SwiftUI

private func handleCastDeepLink(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "bypassmarketchecker" else { return false }
    let host = url.host?.lowercased() ?? ""
    let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    if (host == "cast" && path == "stop") || path == "cast/stop" {
        NotificationCenter.default.post(name: .castStopRequested, object: nil)
        return true
    }
    if (host == "cast" && path == "start") || path == "cast/start" {
        NotificationCenter.default.post(name: .castStartRequested, object: nil)
        return true
    }
    return false
}

@main
struct Bypass_Market_CheckerApp: App {
    init() {
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Failed to configure Meta Wearables SDK: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    if handleCastDeepLink(url) {
                        return
                    }
                    Task {
                        do {
                            let handled = try await Wearables.shared.handleUrl(url)
                            if handled {
                                NotificationCenter.default.post(name: .wearablesURLHandled, object: url)
                            }
                        } catch {
                            NSLog("Wearables handleUrl failed: \(error.localizedDescription)")
                        }
                    }
                }
        }
    }
}
