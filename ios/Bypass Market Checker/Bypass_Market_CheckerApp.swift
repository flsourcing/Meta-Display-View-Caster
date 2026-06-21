import MWDATCore
import SwiftUI

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
