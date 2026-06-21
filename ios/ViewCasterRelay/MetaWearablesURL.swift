import Foundation
import MWDATCore

/// Same URL handling as Bypass_Market_CheckerApp.onOpenURL.
enum MetaWearablesURL {
    static func handle(_ url: URL) async {
        NSLog("ViewCaster: incoming URL \(url.absoluteString)")
        do {
            let handled = try await Wearables.shared.handleUrl(url)
            let state = Wearables.shared.registrationState
            NSLog("ViewCaster: handleUrl handled=\(handled) state=\(state)")
            if handled {
                NotificationCenter.default.post(name: .wearablesURLHandled, object: url)
            }
        } catch {
            NSLog("ViewCaster: Wearables handleUrl failed: \(error.localizedDescription)")
        }
    }
}
