import SwiftUI
import MWDATCore

@main
struct ViewCasterRelayApp: App {
    @UIApplicationDelegateAdaptor(MetaAppDelegate.self) private var appDelegate
    @StateObject private var model: RelayViewModel

    init() {
        do {
            try Wearables.configure()
        } catch {
            NSLog("ViewCaster: Wearables.configure failed: \(error.localizedDescription)")
        }
        let vm = RelayViewModel()
        _model = StateObject(wrappedValue: vm)
        MetaAppDelegate.install { url in
            Task { @MainActor in
                await vm.handleMetaCallback(url)
            }
        }
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
