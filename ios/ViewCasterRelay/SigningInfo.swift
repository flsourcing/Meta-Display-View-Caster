import Foundation

enum SigningInfo {
    /// Team ID from the sideload signature (embedded.mobileprovision).
    static var embeddedTeamIdentifier: String? {
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

    /// Team ID baked into Info.plist for Meta DAT (must match embeddedTeamIdentifier).
    static var configuredMWTeamID: String? {
        guard let mw = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any],
              let team = mw["TeamID"] as? String,
              !team.isEmpty else { return nil }
        return team
    }

    /// True when Meta AI cannot link — IPA was sideloaded without Team ID patch.
    static var needsTeamIDPatch: Bool {
        guard let signed = embeddedTeamIdentifier else { return configuredMWTeamID == nil }
        guard let configured = configuredMWTeamID else { return true }
        return configured.uppercased() != signed.uppercased()
    }

    static var patchInstructions: String {
        let team = embeddedTeamIdentifier ?? "YOUR10CHARID"
        return """
        Reinstall required for Meta AI connection.
        On PC run:
        .\\patch-ipa-teamid.ps1 -TeamId \(team) -Ipa ViewCasterRelay-unsigned.ipa
        Then Sideloadly install the -patched.ipa (not the original).
        """
    }
}
