import SwiftUI

/// Meta Glasses Camera block from Bypass Market Checker SettingsSheetView.
struct MetaSettingsView: View {
    @ObservedObject var meta: BypassMetaCompanion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meta Glasses Camera")
                .font(.headline)

            Text(meta.wearablesStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            Text(meta.registrationStateLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            if let message = meta.message {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(meta.isError ? .red : .secondary)
            }

            Button { meta.openMetaAIApp() } label: {
                Label("Open Meta AI", systemImage: "app.connected.to.app.below.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(meta.isBusy)

            metaSettingsRow(
                title: "Register With Meta AI",
                icon: "link",
                status: meta.registrationSetupStatus
            ) {
                meta.startRegistration()
            }

            if meta.needsCompleteRegistration {
                Button {
                    meta.completeRegistrationInMetaAI()
                } label: {
                    Label("Finish in Meta AI", systemImage: "arrow.uturn.backward.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(meta.isBusy)
            }

            metaSettingsRow(
                title: "Allow Camera",
                icon: "camera.badge.ellipsis",
                status: meta.cameraSetupStatus
            ) {
                Task { await meta.requestCameraPermission() }
            }

            Button("Run Meta diagnostics") {
                Task { await meta.runWearablesDiagnostics() }
            }
            .font(.footnote)

            Text("After Connect in Meta AI, return here and tap Finish in Meta AI (sideload needs the viewcaster:// callback).")
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
            .disabled(meta.isBusy)

            Circle()
                .fill(status == .success ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 14, height: 14)
        }
    }
}
