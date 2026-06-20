import Foundation

enum SigningInfo {
    /// Team ID from the sideload signature (embedded.mobileprovision).
    static var embeddedTeamIdentifier: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }

        // Provisioning profile wraps XML plist in binary CMS — scan as lossy UTF-8.
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

    /// Team ID baked into Info.plist for Meta DAT.
    static var configuredMWTeamID: String? {
        if let mw = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any],
           let team = mw["TeamID"] as? String,
           !team.isEmpty {
            return team
        }
        guard let url = Bundle.main.url(forResource: "Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let pl = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let mw = pl["MWDAT"] as? [String: Any],
              let team = mw["TeamID"] as? String,
              !team.isEmpty else { return nil }
        return team
    }

    /// True when Meta AI cannot link — no Team ID in this install.
    static var needsTeamIDPatch: Bool {
        guard let configured = configuredMWTeamID else { return true }
        guard let signed = embeddedTeamIdentifier else { return false }
        return configured.uppercased() != signed.uppercased()
    }

    static var displayTeamID: String? {
        embeddedTeamIdentifier ?? configuredMWTeamID
    }

    static var patchInstructions: String {
        let team = displayTeamID ?? "YOUR10CHARID"
        return """
        Reinstall an IPA built with Team ID \(team).
        Download the release tagged for your Team ID from GitHub Releases.
        """
    }
}
