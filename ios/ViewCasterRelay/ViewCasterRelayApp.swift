import SwiftUI

@main
struct ViewCasterRelayApp: App {
    @StateObject private var model = RelayViewModel()

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
