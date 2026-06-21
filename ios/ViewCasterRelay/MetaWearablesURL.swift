import Foundation
import MWDATCore

/// Same URL handling as Bypass_Market_CheckerApp.onOpenURL.
enum MetaWearablesURL {
    static func handle(_ url: URL) async {
        do {
            let handled = try await Wearables.shared.handleUrl(url)
            if handled {
                NotificationCenter.default.post(name: .wearablesURLHandled, object: url)
            }
        } catch {
            NSLog("ViewCaster: Wearables handleUrl failed: \(error.localizedDescription)")
        }
    }
}
