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
        _model = StateObject(wrappedValue: RelayViewModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    MetaAppDelegate.onOpenURL = { url in
                        Task { @MainActor in
                            await model.handleMetaCallback(url)
                        }
                    }
                }
                .onOpenURL { url in
                    Task { await model.handleMetaCallback(url) }
                }
        }
    }
}
