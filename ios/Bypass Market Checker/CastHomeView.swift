import SwiftUI

struct CastHomeView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var signaling: SignalingClient

    static let desktopURL = "https://flsourcing.github.io/Meta-Display-View-Caster/"
    static let glassesURL = "https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("View Caster")
                .font(.title3.bold())
                .foregroundStyle(.white)

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
                    hint: "Open glasses app → Live Stream (links to phone automatically)"
                )
            }

            viewersPanel

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

            Button {
                viewModel.wipeLiveChat()
            } label: {
                Label("Wipe Live Chat", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DangerButtonStyle())

            liveChatControlPanel

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
        }
        .cardStyle()
        .onAppear {
            viewModel.startCastCompanionBridge()
        }
    }

    private var viewersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Viewers")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            if signaling.viewerRoster.isEmpty {
                Text("No viewers yet")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.vertical, 4)
            } else {
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
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveChatControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Chat Control")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            Text("Remove individual guest messages from the live chat.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))

            if signaling.chatMessages.isEmpty {
                Text("No chat messages yet")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(signaling.chatMessages) { message in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(message.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                        chatMessagePreview(message)
                                    }
                                    Spacer(minLength: 8)
                                    Button {
                                        signaling.deleteChatMessage(id: message.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.red.opacity(0.9))
                                    .accessibilityLabel("Delete message from \(message.name)")
                                }
                                .id(message.id)
                                .padding(.vertical, 8)

                                if message.id != signaling.chatMessages.last?.id {
                                    Divider().overlay(Color.white.opacity(0.08))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .onChange(of: signaling.chatMessages.count) { _, _ in
                        scrollChatToLatest(proxy)
                    }
                    .onChange(of: signaling.chatMessages.last?.id) { _, _ in
                        scrollChatToLatest(proxy)
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func scrollChatToLatest(_ proxy: ScrollViewProxy) {
        guard let lastId = signaling.chatMessages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(lastId, anchor: .bottom)
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

    @ViewBuilder
    private func chatMessagePreview(_ message: CastChatMessage) -> some View {
        if let url = message.mediaURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Text(message.previewText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                default:
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(message.previewText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
        }
    }
}
