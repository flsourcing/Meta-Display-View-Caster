import SwiftUI

/// Meta Glasses Camera — copied from Bypass Market Checker SettingsSheetView.
struct MetaSettingsView: View {
    @ObservedObject var wearables: MarketCheckerWearablesCompanion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meta Glasses Camera")
                .font(.headline)

            Text(wearables.wearablesStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            if let message = wearables.message {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(wearables.isError ? .red : .secondary)
            }

            Button { wearables.openMetaAIApp() } label: {
                Label("Open Meta AI", systemImage: "app.connected.to.app.below.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(wearables.isBusy)

            metaSettingsRow(
                title: "Register With Meta AI",
                icon: "link",
                status: wearables.registrationSetupStatus
            ) {
                wearables.startRegistration()
            }

            metaSettingsRow(
                title: "Allow Camera",
                icon: "camera.badge.ellipsis",
                status: wearables.cameraSetupStatus
            ) {
                Task { await wearables.requestCameraPermission() }
            }

            Button("Run Meta diagnostics") {
                Task { await wearables.runWearablesDiagnostics() }
            }
            .font(.footnote)

            Text("Same Meta setup as Bypass Market Checker. Register, allow camera, then return here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metaSettingsRow(
        title: String,
        icon: String,
        status: SetupItemStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(wearables.isBusy)

            Circle()
                .fill(status == .success ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 14, height: 14)
        }
    }
}
