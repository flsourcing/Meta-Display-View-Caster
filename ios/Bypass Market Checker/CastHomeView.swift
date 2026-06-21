import SwiftUI

struct CastHomeView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var signaling: SignalingClient

    static let desktopURL = "https://flsourcing.github.io/Meta-Display-View-Caster/"
    static let glassesURL = "https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pairing code")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text(signaling.code)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(.cyan)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)

            HStack(spacing: 8) {
                Circle()
                    .fill(signaling.connected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(signaling.status)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }

            castPreviewPanel

            Text(viewModel.wearablesStatus)
                .font(.footnote)
                .foregroundStyle(viewModel.glassesPreparedForCast ? .green : .orange)

            VStack(alignment: .leading, spacing: 10) {
                linkRow(
                    title: "Glasses",
                    linked: signaling.glassesLinked,
                    hint: "Enter code on glasses → Live Stream"
                )
            }

            if !signaling.viewerRoster.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Viewers")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))

                    ForEach(signaling.viewerRoster) { viewer in
                        HStack {
                            Text(viewer.name)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.9))
                            Spacer()
                            Text(viewer.statusLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(viewer.isWatching ? .green : .orange)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }

            Button {
                Task { await viewModel.prepareGlassesForCast() }
            } label: {
                Label("Prepare Glasses", systemImage: "eyeglasses")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(viewModel.isBusy || viewModel.isLiveCasting)

            if viewModel.isLiveCasting {
                Button {
                    viewModel.userStopLiveCast()
                } label: {
                    Label("Stop Live Cast", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: true))
            } else {
                Button {
                    Task { await viewModel.userStartLiveCast() }
                } label: {
                    Label(
                        viewModel.isStartingLiveCast ? "Starting camera…" : "Start Live Cast",
                        systemImage: "video.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: !viewModel.isBusy && !viewModel.isStartingLiveCast))
                .disabled(viewModel.isBusy || viewModel.isStartingLiveCast)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Desktop")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(Self.desktopURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.cyan.opacity(0.9))
                    .textSelection(.enabled)

                Text("Glasses (Meta Display web app URL)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 4)
                Text(Self.glassesURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.cyan.opacity(0.9))
                    .textSelection(.enabled)

                Text("Guests watch at flsourcing.github.io/Meta-Display-View-Caster — password Wedding")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 4)
            }
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            Button {
                viewModel.copyPairingCode()
            } label: {
                Label("Copy pairing code", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())

            Text("1. Tap Prepare Glasses\n2. Keep View Caster open on phone\n3. Enter code on glasses\n4. Guests: open viewer URL → password Wedding → enter name\n5. Live Stream starts camera → viewers see it live\n6. Tap Stop Live Cast when done")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
        }
        .cardStyle()
        .onAppear {
            viewModel.startCastCompanionBridge()
        }
    }

    private var castPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live preview")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.85))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }

                if let image = viewModel.castPreviewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if viewModel.isLiveCasting || viewModel.isStartingLiveCast {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.cyan)
                        Text("Waiting for glasses camera…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding()
                } else {
                    Text("Start Live Cast to see glasses POV here")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 180, maxHeight: 240)
        }
    }

    private func linkRow(title: String, linked: Bool, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: linked ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(linked ? .green : .white.opacity(0.85))
                Spacer()
                Text(linked ? "Connected" : "Waiting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(linked ? .green : .orange)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}
