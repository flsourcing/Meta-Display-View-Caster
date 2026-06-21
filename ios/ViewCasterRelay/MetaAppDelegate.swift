import UIKit

/// Delivers Meta AI callback URLs (viewcaster://…) from cold start and legacy openURL paths.
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
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        for context in options.urlContexts {
            NSLog("ViewCaster: cold-start URL \(context.url.absoluteString)")
            MetaAppDelegate.deliver(context.url)
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
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

    fileprivate static func deliver(_ url: URL) {
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
