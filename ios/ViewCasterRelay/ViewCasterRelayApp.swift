import SwiftUI
import MWDATCore

@main
struct ViewCasterRelayApp: App {
    @UIApplicationDelegateAdaptor(MetaAppDelegate.self) private var appDelegate
    @StateObject private var model: RelayViewModel
    private let configureError: String?

    init() {
        var configErr: String?
        do {
            try Wearables.configure()
        } catch {
            configErr = error.localizedDescription
            NSLog("ViewCaster: Wearables.configure failed: \(error.localizedDescription)")
        }
        configureError = configErr

        let vm = RelayViewModel()
        _model = StateObject(wrappedValue: vm)

        MetaAppDelegate.install { url in
            Task { @MainActor in
                await vm.wearables.handleIncomingURL(url)
            }
        }

        Task { @MainActor in
            vm.configureWearables(configError: configErr)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(configureError: configureError)
                .environmentObject(model)
                .onOpenURL { url in
                    Task { @MainActor in
                        await model.wearables.handleIncomingURL(url)
                    }
                }
        }
    }
}
