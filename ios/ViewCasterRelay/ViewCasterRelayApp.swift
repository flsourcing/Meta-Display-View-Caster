import SwiftUI
import MWDATCore

@main
struct ViewCasterRelayApp: App {
    @StateObject private var model: RelayViewModel

    init() {
        // Meta DAT must be configured before any Wearables.shared access.
        do {
            try Wearables.configure()
        } catch {
            NSLog("ViewCaster: Wearables.configure failed: \(error.localizedDescription)")
        }
        _model = StateObject(wrappedValue: RelayViewModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    Task { await model.handleMetaCallback(url) }
                }
        }
    }
}
