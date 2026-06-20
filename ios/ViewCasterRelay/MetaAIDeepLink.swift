import UIKit

@MainActor
enum MetaAIDeepLink {
    static func openMetaAI() {
        guard let url = URL(string: "fb-viewapp://") else { return }
        UIApplication.shared.open(url)
    }

    static func openAddWebApp(name: String, url: String) {
        var components = URLComponents(string: "fb-viewapp://web_app_deep_link")!
        components.queryItems = [
            URLQueryItem(name: "appName", value: name),
            URLQueryItem(name: "appUrl", value: url),
        ]
        guard let link = components.url else { return }
        UIApplication.shared.open(link)
    }
}
