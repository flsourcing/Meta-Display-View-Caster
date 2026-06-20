import UIKit

/// Delivers Meta AI callback URLs (viewcaster://…) — more reliable than SwiftUI .onOpenURL alone.
final class MetaAppDelegate: NSObject, UIApplicationDelegate {
    static var onOpenURL: ((URL) -> Void)?

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        NSLog("ViewCaster: application openURL \(url.absoluteString)")
        MetaAppDelegate.onOpenURL?(url)
        return true
    }
}
