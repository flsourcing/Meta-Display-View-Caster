import UIKit

/// Delivers Meta AI callback URLs (viewcaster://…) — must not drop URLs that arrive before SwiftUI onAppear.
final class MetaAppDelegate: NSObject, UIApplicationDelegate {
    static var onOpenURL: ((URL) -> Void)? {
        didSet { flushPendingURLs() }
    }

    private static var pendingURLs: [URL] = []

    static func install(handler: @escaping (URL) -> Void) {
        onOpenURL = handler
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        NSLog("ViewCaster: application openURL \(url.absoluteString)")
        MetaAppDelegate.deliver(url)
        return true
    }

    private static func deliver(_ url: URL) {
        if let handler = onOpenURL {
            handler(url)
        } else {
            pendingURLs.append(url)
        }
    }

    private static func flushPendingURLs() {
        guard let handler = onOpenURL else { return }
        for url in pendingURLs {
            handler(url)
        }
        pendingURLs.removeAll()
    }
}
