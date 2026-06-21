import MWDATCore
import SwiftUI

@main
struct ViewCasterRelayApp: App {
    @StateObject private var model = RelayViewModel()

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
                .environmentObject(model)
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
