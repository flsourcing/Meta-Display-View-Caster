import Foundation

enum SigningInfo {
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// Team ID from the sideload signature (embedded.mobileprovision).
    static var embeddedTeamIdentifier: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        let patterns = [
            "team-identifier</key>\\s*<array>\\s*<string>([A-Z0-9]{10})</string>",
            "ApplicationIdentifierPrefix</key>\\s*<array>\\s*<string>([A-Z0-9]{10})</string>",
            "TeamIdentifier</key>\\s*<string>([A-Z0-9]{10})</string>",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    static var configuredMWTeamID: String? {
        mwDict?["TeamID"] as? String
    }

    static var configuredMetaAppID: String? {
        mwDict?["MetaAppID"] as? String
    }

    static var configuredURLScheme: String? {
        mwDict?["AppLinkURLScheme"] as? String
    }

    private static var mwDict: [String: Any]? {
        if let mw = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] {
            return mw
        }
        guard let url = Bundle.main.url(forResource: "Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let pl = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return pl["MWDAT"] as? [String: Any]
    }

    /// Why Meta AI opens but never shows a connect prompt.
    static var metaConnectionIssue: String? {
        guard let configured = configuredMWTeamID, !configured.isEmpty else {
            return "Missing MWDAT TeamID in this install. Reinstall a GitHub release tagged with your Team ID."
        }
        guard let signed = embeddedTeamIdentifier else {
            return nil
        }
        if configured.uppercased() != signed.uppercased() {
            return """
            Team ID mismatch — Meta AI won't prompt.
            IPA Team ID: \(configured)
            Sideload Team ID: \(signed)
            Rebuild the IPA with Team ID \(signed) (GitHub Actions → Build iOS IPA).
            """
        }
        return nil
    }

    static var needsTeamIDPatch: Bool {
        guard let configured = configuredMWTeamID, !configured.isEmpty else { return true }
        guard let signed = embeddedTeamIdentifier else { return false }
        return configured.uppercased() != signed.uppercased()
    }

    static var displayTeamID: String? {
        embeddedTeamIdentifier ?? configuredMWTeamID
    }

    static var patchInstructions: String {
        if let issue = metaConnectionIssue {
            return issue
        }
        let team = displayTeamID ?? "YOUR10CHARID"
        return """
        Reinstall an IPA built with Team ID \(team).
        Download the release tagged (Team \(team)) from GitHub Releases.
        """
    }

    static var developerModeHint: String {
        "Meta AI → Settings → your glasses → Developer Mode ON (per glasses pair; re-enable after firmware updates)."
    }
}
