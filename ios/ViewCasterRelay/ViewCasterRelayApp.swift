import MWDATCore
import SwiftUI

@main
struct ViewCasterRelayApp: App {
    @UIApplicationDelegateAdaptor(MetaAppDelegate.self) private var appDelegate
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
                .onAppear {
                    MetaAppDelegate.install { url in
                        model.handleMetaCallback(url)
                    }
                }
                .onOpenURL { url in
                    model.handleMetaCallback(url)
                }
        }
    }
}
