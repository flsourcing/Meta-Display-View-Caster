import Foundation

enum SigningInfo {
    /// Apple Team ID from the sideload provisioning profile (needed for Meta DAT registration).
    static var teamIdentifier: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .ascii) else { return nil }

        if let match = text.range(of: "<key>com.apple.developer.team-identifier</key>\\s*<array>\\s*<string>([A-Z0-9]{10})</string>", options: .regularExpression) {
            let snippet = String(text[match])
            if let id = snippet.range(of: "[A-Z0-9]{10}", options: .regularExpression) {
                return String(snippet[id])
            }
        }

        if let match = text.range(of: "<key>ApplicationIdentifierPrefix</key>\\s*<array>\\s*<string>([A-Z0-9]{10})</string>", options: .regularExpression) {
            let snippet = String(text[match])
            if let id = snippet.range(of: "[A-Z0-9]{10}", options: .regularExpression) {
                return String(snippet[id])
            }
        }

        return nil
    }
}
