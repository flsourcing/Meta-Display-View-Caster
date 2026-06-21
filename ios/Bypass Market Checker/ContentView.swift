import CoreBluetooth
import CoreImage
import Foundation
import MWDATCamera
import MWDATCore
import PhotosUI
import SafariServices
import Speech
import AVFoundation
import SwiftUI
import ImageIO
import UIKit
import Vision

extension Notification.Name {
    static let wearablesURLHandled = Notification.Name("wearablesURLHandled")
    static let castStartRequested = Notification.Name("castStartRequested")
    static let castStopRequested = Notification.Name("castStopRequested")
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = CompanionViewModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.04, green: 0.08, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header

                        if viewModel.isMobileSetupComplete {
                            CastHomeView(
                                viewModel: viewModel,
                                signaling: viewModel.ensureRelaySignaling()
                            )
                        } else {
                            setupWizard
                        }

                        if let message = viewModel.message {
                            Text(message)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(viewModel.isError ? .red : .cyan)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(24)
                    .padding(.top, viewModel.isMobileSetupComplete ? 28 : 0)
                }

                if viewModel.isMobileSetupComplete {
                    Button {
                        viewModel.showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(16)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .padding(24)
                    .accessibilityLabel("Settings")
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.isMobileSetupComplete {
                    Button {
                        viewModel.showConnectionPopover.toggle()
                    } label: {
                        Circle()
                            .fill(viewModel.glassesConnectionStatus == .connected ? Color.green : Color.red.opacity(0.85))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1.5))
                            .padding(10)
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 4)
                    .accessibilityLabel("Connection status")
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.showConnectionPopover {
                    ConnectionStatusPopover(
                        metaAIStatus: viewModel.metaAIStatusLabel,
                        cameraStatus: viewModel.cameraStatusLabel,
                        audioStatus: viewModel.audioStatusLabel,
                        onDismiss: { viewModel.showConnectionPopover = false }
                    )
                    .padding(.top, 36)
                    .padding(.trailing, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
                }
            }
            .overlay {
                if viewModel.showConfetti {
                    ConfettiView()
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("View Caster")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                viewModel.startRegistrationMonitoring()
                await viewModel.restoreSession()
                if viewModel.isMobileSetupComplete {
                    viewModel.startCastRelayIfNeeded()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    viewModel.onAppWillEnterForeground()
                case .background:
                    viewModel.onAppEnteredBackground()
                default:
                    break
                }
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsSheetView(viewModel: viewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: .castStartRequested)) { _ in
                Task { await viewModel.handleCastStartFromGlasses() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .castStopRequested)) { _ in
                viewModel.userStopLiveCast()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meta Display View Caster")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            Text("Phone relay — keep View Caster open, then go live from glasses or here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var setupWizard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
                .overlay(.white.opacity(0.18))

            switch viewModel.setupStep {
            case .registration:
                setupRegistrationStep
            case .camera:
                setupCameraStep
            case .audio:
                setupAudioStep
            case .finalize:
                setupFinalizeStep
            }

            if viewModel.isBusy {
                ProgressView()
                    .tint(.cyan)
            }
        }
        .cardStyle()
    }

    private var setupRegistrationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup — Step 1 of 4")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("Register with Meta AI")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))

            setupStatusRow(
                label: viewModel.registrationSetupStatus == .success ? "Successful" : "Waiting for connection...",
                isSuccess: viewModel.registrationSetupStatus == .success
            )

            Button {
                viewModel.startRegistration()
            } label: {
                Label("Register With Meta AI", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(viewModel.isBusy)

            Text("Complete registration in Meta AI, then return here. Next unlocks when connected.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))

            setupNextButton
        }
    }

    private var setupCameraStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup — Step 2 of 4")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("Allow Camera")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))

            setupStatusRow(
                label: viewModel.cameraSetupStatus == .success ? "Successful" : "Waiting for approval...",
                isSuccess: viewModel.cameraSetupStatus == .success
            )

            Button {
                Task { await viewModel.requestCameraPermission() }
            } label: {
                Label("Allow Camera", systemImage: "camera.badge.ellipsis")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(viewModel.isBusy)

            Text("Approve camera access in Meta AI, then return here. Next unlocks when allowed.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))

            setupNextButton
        }
    }

    private var setupAudioStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup — Step 3 of 4")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("Allow Microphone")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))

            setupStatusRow(
                label: viewModel.audioSetupStatus == .success ? "Successful" : "Waiting for approval...",
                isSuccess: viewModel.audioSetupStatus == .success
            )

            Button {
                Task { await viewModel.requestAudioPermission() }
            } label: {
                Label("Allow Microphone", systemImage: "mic.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(viewModel.isBusy)

            Text("Enables live audio from your glasses over Bluetooth. Approve the microphone prompt, then return here.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))

            setupNextButton
        }
    }

    private var setupFinalizeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup — Step 4 of 4")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("You're all set!")
                .font(.headline)
                .foregroundStyle(.green.opacity(0.9))

            Text("Tap Get Started to open View Caster. On glasses, open the app and tap Live Stream — no code needed.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))

            Button {
                viewModel.finishMobileSetup()
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(isEnabled: !viewModel.isBusy))
            .disabled(viewModel.isBusy)
        }
    }

    private var setupNextButton: some View {
        Button {
            viewModel.advanceSetupStep()
        } label: {
            Text("Next")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle(isEnabled: viewModel.canAdvanceSetup))
        .disabled(!viewModel.canAdvanceSetup || viewModel.isBusy)
    }

    private func setupStatusRow(label: String, isSuccess: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isSuccess ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSuccess ? .green : .orange)
        }
    }
}

// MARK: - Home & Settings Views

struct ConnectionStatusPopover: View {
    let metaAIStatus: String
    let cameraStatus: String
    let audioStatus: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connection Status")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            statusLine(label: "Meta AI", value: metaAIStatus)
            statusLine(label: "Camera", value: cameraStatus)
            statusLine(label: "Microphone", value: audioStatus)
        }
        .padding(14)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .frame(maxWidth: 240)
    }

    private func statusLine(label: String, value: String) -> some View {
        HStack {
            Text("\(label):")
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(value == "Connected" ? .green : .orange)
        }
        .font(.subheadline)
    }
}

struct ConfettiView: View {
    private let colors: [Color] = [.green, .cyan, .yellow, .pink, .orange, .blue]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(0..<34, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(colors[index % colors.count])
                        .frame(width: 9, height: 16)
                        .rotationEffect(.degrees(Double(index * 31)))
                        .offset(
                            x: CGFloat((index * 37) % max(Int(proxy.size.width), 1)) - proxy.size.width / 2,
                            y: proxy.size.height * 0.55
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SettingsSheetView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.04, green: 0.08, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Meta Glasses Camera")
                            .font(.title3.bold())
                            .foregroundStyle(.white)

                        Text(viewModel.wearablesStatus)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.72))

                        Button { viewModel.openMetaAIApp() } label: {
                            Label("Open Meta AI", systemImage: "app.connected.to.app.below.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle(isEnabled: !viewModel.isBusy))

                        settingsRow(
                            title: "Register With Meta AI",
                            icon: "link",
                            status: viewModel.registrationSetupStatus
                        ) { viewModel.startRegistration() }

                        settingsRow(
                            title: "Allow Camera",
                            icon: "camera.badge.ellipsis",
                            status: viewModel.cameraSetupStatus
                        ) { Task { await viewModel.requestCameraPermission() } }

                        settingsRow(
                            title: "Allow Microphone",
                            icon: "mic.badge.plus",
                            status: viewModel.audioSetupStatus
                        ) { Task { await viewModel.requestAudioPermission() } }

                        Text("When glasses tap Live Stream, this app opens the POV camera and relays video and audio to viewers.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
    }

    private func settingsRow(
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
            .buttonStyle(CompactSecondaryButtonStyle())
            .disabled(viewModel.isBusy)

            Circle()
                .fill(status == .success ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 14, height: 14)
        }
    }
}

struct LookupHistoryView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEntry: LookupHistoryEntry?
    @State private var incorrectFeedbackEntry: LookupHistoryEntry?
    @State private var feedbackRefreshTask: Task<Void, Never>?

    private func historyEntry(for entry: LookupHistoryEntry) -> LookupHistoryEntry {
        viewModel.lookupHistory.first(where: { $0.id == entry.id }) ?? entry
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.04, green: 0.08, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if viewModel.lookupHistory.isEmpty {
                    Text("No lookups yet.")
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(viewModel.lookupHistory) { entry in
                                LookupHistoryRow(
                                    entry: historyEntry(for: entry),
                                    onOpen: { selectedEntry = entry },
                                    onCorrect: {
                                        Task {
                                            await viewModel.submitHistoryFeedback(
                                                entry: historyEntry(for: entry),
                                                status: "correct"
                                            )
                                        }
                                    },
                                    onIncorrect: {
                                        incorrectFeedbackEntry = historyEntry(for: entry)
                                    }
                                )
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Lookup History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.cyan)
                }
            }
            .sheet(item: $selectedEntry) { entry in
                LookupHistoryDetailView(entry: entry, viewModel: viewModel)
            }
            .sheet(item: $incorrectFeedbackEntry) { entry in
                IncorrectFeedbackSheet(
                    lookupType: entry.lookupType ?? (entry.resultSummary.hasPrefix("UPC ") ? "barcode" : "image"),
                    onCancel: { incorrectFeedbackEntry = nil },
                    onSave: { note in
                        let entryToSave = historyEntry(for: entry)
                        incorrectFeedbackEntry = nil
                        Task {
                            await viewModel.submitHistoryFeedback(
                                entry: entryToSave,
                                status: "incorrect",
                                note: note
                            )
                        }
                    }
                )
            }
            .task {
                await viewModel.refreshLookupHistoryFeedback()
                feedbackRefreshTask?.cancel()
                feedbackRefreshTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await viewModel.refreshLookupHistoryFeedback()
                    }
                }
            }
            .onDisappear {
                feedbackRefreshTask?.cancel()
                feedbackRefreshTask = nil
            }
        }
    }
}

struct LookupHistoryDetailView: View {
    let entry: LookupHistoryEntry
    @ObservedObject var viewModel: CompanionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showIncorrectPrompt = false

    private var visibleEntry: LookupHistoryEntry {
        if let matchedEntry = viewModel.lookupHistory.first(where: { $0.id == entry.id }) {
            return matchedEntry
        }

        if let lookupId = entry.lookupId,
           let matchedEntry = viewModel.lookupHistory.first(where: { $0.lookupId == lookupId }) {
            return matchedEntry
        }

        return entry
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.04, green: 0.08, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let image = UIImage(contentsOfFile: visibleEntry.imageURL.path) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(.white.opacity(0.14), lineWidth: 1)
                                )
                        }

                        if let aliasImageURL = visibleEntry.marketData?.alias?.product.mainPictureUrl,
                           let url = URL(string: aliasImageURL) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Alias Catalog")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFit()
                                    default:
                                        ProgressView()
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            detailLine(label: "Source", value: visibleEntry.source.rawValue, valueColor: .cyan)
                            detailLine(label: "Result", value: visibleEntry.resultSummary)
                            if !visibleEntry.detail.isEmpty {
                                let detailLabel = visibleEntry.resultSummary.hasPrefix("UPC ") ? "Method" : "Details"
                                detailLine(label: detailLabel, value: visibleEntry.detail)
                            }
                            detailLine(label: "Date", value: visibleEntry.formattedDate, valueColor: .white.opacity(0.65))
                            detailLine(label: "Feedback", value: visibleEntry.feedbackStatus?.capitalized ?? "Not marked", valueColor: feedbackColor)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

                        if visibleEntry.lookupId != nil && visibleEntry.feedbackStatus == nil {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Was this lookup correct?")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Feedback is saved to your account and helps improve future image and barcode matching.")
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.65))

                                HStack(spacing: 12) {
                                    Button {
                                        Task { await viewModel.submitHistoryFeedback(entry: visibleEntry, status: "correct") }
                                    } label: {
                                        Label("Correct", systemImage: "checkmark.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(PrimaryButtonStyle(isEnabled: true))

                                    Button {
                                        showIncorrectPrompt = true
                                    } label: {
                                        Label("Incorrect", systemImage: "xmark.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(SecondaryButtonStyle())
                                }
                            }
                            .padding(16)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                        }

                        if let marketData = visibleEntry.marketData {
                            MarketPricingView(marketData: marketData)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Lookup Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
            .task(id: visibleEntry.lookupId) {
                guard let lookupId = visibleEntry.lookupId else { return }

                while !Task.isCancelled {
                    await viewModel.refreshLookupHistoryFeedback(lookupId: lookupId)

                    if Task.isCancelled || visibleEntry.feedbackStatus != nil {
                        break
                    }

                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            .sheet(isPresented: $showIncorrectPrompt) {
                IncorrectFeedbackSheet(
                    lookupType: visibleEntry.lookupType ?? (visibleEntry.resultSummary.hasPrefix("UPC ") ? "barcode" : "image"),
                    onCancel: { showIncorrectPrompt = false },
                    onSave: { note in
                        let entryToSave = visibleEntry
                        showIncorrectPrompt = false
                        Task { await viewModel.submitHistoryFeedback(entry: entryToSave, status: "incorrect", note: note) }
                    }
                )
            }
        }
    }

    private var feedbackColor: Color {
        switch visibleEntry.feedbackStatus {
        case "correct": return .green
        case "incorrect": return .orange
        default: return .white
        }
    }

    private func detailLine(label: String, value: String, valueColor: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(label == "Result" ? .title3.weight(.semibold) : .body)
                .foregroundStyle(valueColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MarketPricingView: View {
    let marketData: LookupMarketData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Market Pricing (New)")
                .font(.headline)
                .foregroundStyle(.white)

            if let title = marketData.stockx?.product.title ?? marketData.alias?.product.name {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
            }

            if marketData.combined.isEmpty {
                Text("No market sizes returned.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Size").frame(width: 44, alignment: .leading)
                            Text("SX Bid").frame(width: 58)
                            Text("SX Ask").frame(width: 58)
                            Text("Al Bid").frame(width: 58)
                            Text("Al Ask").frame(width: 58)
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.vertical, 8)

                        ForEach(marketData.combined, id: \.size) { row in
                            HStack {
                                Text(formatSize(row.size))
                                    .frame(width: 44, alignment: .leading)
                                Text(formatPrice(row.stockx?.highestBid))
                                    .frame(width: 58)
                                Text(formatPrice(row.stockx?.lowestAsk))
                                    .frame(width: 58)
                                Text(formatPrice(row.alias?.highestBid))
                                    .frame(width: 58)
                                Text(formatPrice(row.alias?.lowestAsk))
                                    .frame(width: 58)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }

            if let stockxError = marketData.errors?.stockx {
                Text("StockX: \(stockxError)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let aliasError = marketData.errors?.alias {
                Text("Alias: \(aliasError)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func formatSize(_ size: Double) -> String {
        size.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", size)
            : String(format: "%.1f", size)
    }

    private func formatPrice(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.0f", value)
    }
}

struct IncorrectFeedbackSheet: View {
    let lookupType: String
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var note = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.04, green: 0.08, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Help improve future matches")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Optional: tell us what was wrong with the result. Notes help our systems get better over time.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.68))
                    TextField("Optional note", text: $note)
                        .fieldStyle()
                        .keyboardType(.default)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled()
                    Button {
                        onSave(note)
                    } label: {
                        Text("Save Incorrect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle(isEnabled: true))
                    Button("Cancel", action: onCancel)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.cyan)
                }
                .padding(24)
            }
            .navigationTitle("Incorrect Result")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct LookupHistoryRow: View {
    let entry: LookupHistoryEntry
    let onOpen: () -> Void
    let onCorrect: () -> Void
    let onIncorrect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 14) {
                    if let image = UIImage(contentsOfFile: entry.imageURL.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.source.rawValue)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)

                        Text(entry.resultSummary)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)

                        if !entry.detail.isEmpty {
                            Text(entry.detail)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }

                        Text(entry.formattedDate)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))

                        if let marketData = entry.marketData, !marketData.combined.isEmpty {
                            Text("StockX · Alias market loaded")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green.opacity(0.85))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            LookupHistoryRowFeedbackColumn(
                entry: entry,
                onCorrect: onCorrect,
                onIncorrect: onIncorrect
            )
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct LookupHistoryRowFeedbackColumn: View {
    let entry: LookupHistoryEntry
    let onCorrect: () -> Void
    let onIncorrect: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let status = entry.feedbackStatus {
                VStack(alignment: .trailing, spacing: 6) {
                    Label(status.capitalized, systemImage: status == "correct" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(status == "correct" ? .green : .orange)
                        .labelStyle(.titleAndIcon)

                    if status == "incorrect",
                       let note = entry.feedbackCorrection?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                            .frame(maxWidth: 96, alignment: .trailing)
                    }
                }
            } else if entry.lookupId != nil {
                VStack(spacing: 6) {
                    Text("Needs feedback")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))

                    Button(action: onCorrect) {
                        Text("Correct")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(HistoryFeedbackCorrectButtonStyle())

                    Button(action: onIncorrect) {
                        Text("Incorrect")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(HistoryFeedbackIncorrectButtonStyle())
                }
            } else {
                Text("Local only")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.trailing)
            }
        }
        .frame(width: 96, alignment: .trailing)
    }
}

struct HistoryFeedbackCorrectButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Color.green.opacity(configuration.isPressed ? 0.34 : 0.24),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(0.42), lineWidth: 1)
            )
    }
}

struct HistoryFeedbackIncorrectButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Color.red.opacity(configuration.isPressed ? 0.3 : 0.2),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.red.opacity(0.38), lineWidth: 1)
            )
    }
}

struct TextLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CompanionViewModel
    @State private var query = ""
    @State private var suggestions: [CatalogSearchItem] = []
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.04, green: 0.08, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 14) {
                    TextField("Search product name or SKU", text: $query)
                        .fieldStyle()
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if viewModel.isBusy {
                        ProgressView("Loading market prices...")
                            .tint(.cyan)
                            .foregroundStyle(.white.opacity(0.82))
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(suggestions) { item in
                                Button {
                                    Task { await viewModel.performTextLookup(item: item) }
                                } label: {
                                    catalogSuggestionRow(item)
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.isBusy)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Text Lookup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
            .task(id: query) {
                await refreshSuggestions()
            }
        }
    }

    @ViewBuilder
    private func catalogSuggestionRow(_ item: CatalogSearchItem) -> some View {
        HStack(spacing: 12) {
            if let imageUrl = item.imageUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        catalogSuggestionPlaceholder(for: item)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                catalogSuggestionPlaceholder(for: item)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)

                Text(item.sku)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func catalogSuggestionPlaceholder(for item: CatalogSearchItem) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.white.opacity(0.08))
            .frame(width: 64, height: 64)
            .overlay {
                Text("?")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white.opacity(0.82))
            }
    }

    private func refreshSuggestions() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            suggestions = []
            statusMessage = nil
            return
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }

        do {
            let response = try await viewModel.searchCatalogSuggestions(query: trimmed)
            guard !Task.isCancelled else { return }
            suggestions = response
            statusMessage = response.isEmpty ? "No matches yet. Keep typing or try another term." : nil
        } catch {
            guard !Task.isCancelled else { return }
            suggestions = []
            statusMessage = error.localizedDescription
        }
    }
}

struct PhoneCameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }
    }
}

enum BarcodeScanner {
    static func decodeUPC(from image: UIImage, jpegData: Data? = nil) -> String? {
        if let upc = scanImage(image) {
            return upc
        }

        if let data = jpegData ?? image.jpegData(compressionQuality: 1.0) {
            return decodeUPC(fromJPEGData: data)
        }

        return nil
    }

    static func decodeUPC(fromJPEGData data: Data) -> String? {
        if let ciImage = CIImage(data: data), let upc = scanCIImage(ciImage) {
            return upc
        }

        for image in loadUIImages(fromJPEGData: data) {
            if let upc = scanImage(image) {
                return upc
            }
        }

        return nil
    }

    static func decodeUPC(from image: UIImage?, jpegData: Data?) -> String? {
        if let image, let upc = decodeUPC(from: image, jpegData: jpegData) {
            return upc
        }

        if let jpegData, let upc = decodeUPC(fromJPEGData: jpegData) {
            return upc
        }

        return nil
    }

    static func decodeUPCFromPhotoData(_ imageData: Data) -> String? {
        if let image = UIImage(data: imageData) {
            let normalized = normalizedImage(image)
            if let upc = decodeUPC(from: normalized, jpegData: imageData) {
                return upc
            }
            if let upc = decodeUPC(from: image, jpegData: imageData) {
                return upc
            }
        }

        return decodeUPC(fromJPEGData: imageData)
    }

    private static func scanImage(_ image: UIImage) -> String? {
        let symbologies: [VNBarcodeSymbology] = [.code128, .ean13, .ean8, .upce, .code39]

        for candidate in scanCandidates(for: image) {
            if let upc = decodeVision(from: candidate, symbologies: symbologies) {
                return upc
            }
        }

        return nil
    }

    private static func scanCIImage(_ ciImage: CIImage) -> String? {
        let symbologies: [VNBarcodeSymbology] = [.code128, .ean13, .ean8, .upce, .code39]

        var ciCandidates: [CIImage] = [ciImage]
        for contrast in [1.3, 1.6, 1.9, 2.2] as [Float] {
            if let adjusted = contrastAdjusted(ciImage, contrast: contrast) {
                ciCandidates.append(adjusted)
            }
        }
        if let sharp = sharpened(ciImage) {
            ciCandidates.append(sharp)
        }
        if let contrasted = contrastAdjusted(ciImage, contrast: 1.6),
           let enhanced = sharpened(contrasted) {
            ciCandidates.append(enhanced)
            for scale in [2.0, 3.0, 4.0] as [CGFloat] {
                if let upscaled = upscaled(enhanced, scale: scale) {
                    ciCandidates.append(upscaled)
                }
            }
        }

        for candidate in ciCandidates {
            if let upc = decodeVision(from: candidate, symbologies: symbologies) {
                return upc
            }
        }

        return nil
    }

    private static func loadUIImages(fromJPEGData data: Data) -> [UIImage] {
        var images: [UIImage] = []

        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let exifOrientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let orientation = uiImageOrientation(fromExif: exifOrientation)
            images.append(UIImage(cgImage: cgImage, scale: 1, orientation: orientation))
            images.append(UIImage(cgImage: cgImage, scale: 1, orientation: .up))
        }

        if let plain = UIImage(data: data) {
            images.append(plain)
        }

        return images
    }

    private static func uiImageOrientation(fromExif value: UInt32) -> UIImage.Orientation {
        switch value {
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }

    private static func scanCandidates(for image: UIImage) -> [UIImage] {
        let normalized = normalizedImage(image)
        var candidates: [UIImage] = []
        var seen = Set<String>()

        let maxCandidateCount = 12
        let maxPixelCount: CGFloat = 1_600_000

        func append(_ candidate: UIImage?) {
            guard candidates.count < maxCandidateCount,
                  let candidate,
                  candidate.size.width * candidate.size.height <= maxPixelCount else { return }
            let key = "\(Int(candidate.size.width))x\(Int(candidate.size.height))-\(candidate.imageOrientation.rawValue)"
            guard seen.insert(key).inserted else { return }
            candidates.append(candidate)
        }

        append(normalized)

        if image.imageOrientation != .up {
            append(image)
        }

        if let ciBase = CIImage(image: normalized) {
            for contrast in [1.4, 1.8] as [Float] {
                append(renderedImage(from: contrastAdjusted(ciBase, contrast: contrast)))
            }
            if let contrasted = contrastAdjusted(ciBase, contrast: 1.6),
               let enhanced = sharpened(contrasted) {
                append(renderedImage(from: enhanced))
            }
        }

        for scale in [0.75, 1.5, 2.0] as [CGFloat] {
            append(scaledImage(normalized, scale: scale))
        }

        for crop in barcodeRegionCrops(for: normalized).prefix(4) {
            append(crop)
            append(scaledImage(crop, scale: 2.0))
        }

        for crop in detectedBarcodeRegionCrops(for: normalized).prefix(2) {
            append(crop)
            append(scaledImage(crop, scale: 2.0))
        }

        return candidates
    }

    private static func contrastAdjusted(_ image: CIImage, contrast: Float) -> CIImage? {
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(0, forKey: kCIInputBrightnessKey)
        filter.setValue(1, forKey: kCIInputSaturationKey)
        return filter.outputImage
    }

    private static func sharpened(_ image: CIImage) -> CIImage? {
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(0.9, forKey: kCIInputSharpnessKey)
        return filter.outputImage
    }

    private static func upscaled(_ image: CIImage, scale: CGFloat) -> CIImage? {
        guard scale > 1 else { return image }
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage
    }

    private static func renderedImage(from ciImage: CIImage?) -> UIImage? {
        guard let ciImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func barcodeRegionCrops(for image: UIImage) -> [UIImage] {
        let specs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.05, 0.30, 0.90, 0.40),
            (0.10, 0.25, 0.80, 0.50),
            (0.05, 0.55, 0.90, 0.35),
            (0.05, 0.05, 0.90, 0.35),
            (0.00, 0.40, 1.00, 0.20),
            (0.15, 0.35, 0.70, 0.30),
        ]

        return specs.compactMap { cropImage(image, originX: $0.0, originY: $0.1, width: $0.2, height: $0.3) }
    }

    private static func detectedBarcodeRegionCrops(for image: UIImage) -> [UIImage] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.code128, .ean13, .ean8, .upce, .code39]

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: cgImageOrientation(from: image.imageOrientation),
            options: [:]
        )
        try? handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else { return [] }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        return observations.compactMap { observation in
            let box = observation.boundingBox
            let rect = CGRect(
                x: box.minX * imageWidth,
                y: (1 - box.maxY) * imageHeight,
                width: box.width * imageWidth,
                height: box.height * imageHeight
            )
            let expanded = rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.35)
            return cropImage(image, rect: expanded)
        }
    }

    private static func cropImage(
        _ image: UIImage,
        originX: CGFloat,
        originY: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let rect = CGRect(
            x: originX * imageWidth,
            y: originY * imageHeight,
            width: width * imageWidth,
            height: height * imageHeight
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard rect.width >= 32, rect.height >= 16 else { return nil }
        return cropImage(image, rect: rect)
    }

    private static func cropImage(_ image: UIImage, rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage,
              let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func scaledImage(_ image: UIImage, scale: CGFloat) -> UIImage? {
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard size.width > 32, size.height > 32 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func decodeVision(from ciImage: CIImage, symbologies: [VNBarcodeSymbology]) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        try? handler.perform([request])

        return extractBarcode(from: request.results)
    }

    private static func decodeVision(from image: UIImage, symbologies: [VNBarcodeSymbology]) -> String? {
        guard let cgImage = image.cgImage else { return nil }

        let orientations: [CGImagePropertyOrientation] = [
            cgImageOrientation(from: image.imageOrientation),
            .up,
            .right,
            .left,
            .down,
            .upMirrored,
            .downMirrored,
            .leftMirrored,
            .rightMirrored,
        ]

        for orientation in orientations {
            let request = VNDetectBarcodesRequest()
            request.symbologies = symbologies

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try? handler.perform([request])

            if let value = extractBarcode(from: request.results) {
                return value
            }
        }

        return nil
    }

    private static func cgImageOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private static func extractBarcode(from observations: [VNBarcodeObservation]?) -> String? {
        guard let observations else { return nil }

        var fallbackValue: String?

        for observation in observations {
            guard let value = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }

            let digits = value.filter(\.isNumber)
            let normalized = !digits.isEmpty ? digits : value

            if observation.symbology == .code128 {
                return normalized
            }

            if fallbackValue == nil {
                fallbackValue = normalized
            }
        }

        return fallbackValue
    }
}

#Preview {
    ContentView()
}

enum SetupStep: Int {
    case registration = 1
    case camera = 2
    case audio = 3
    case finalize = 4
}

enum SetupItemStatus {
    case waiting
    case success
}

enum GlassesConnectionStatus {
    case connected
    case disconnected

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
}

enum LookupSource: String, Codable {
    case mobile = "Mobile search"
    case metaGlasses = "Meta Glasses"
    case text = "Text search"
}

private enum LookupHistoryPaths {
    static let imagesDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("LookupHistoryImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
}

struct MarketSizeSide: Codable {
    let lowestAsk: Double?
    let highestBid: Double?
}

struct ProviderSizeQuote: Codable {
    let size: Double
    let lowestAsk: Double?
    let highestBid: Double?
}

struct CombinedSizeQuote: Codable {
    let size: Double
    let stockx: MarketSizeSide?
    let alias: MarketSizeSide?
}

struct AliasMarketProduct: Codable {
    let name: String
    let brand: String
    let sku: String
    let colorway: String?
    let mainPictureUrl: String?
    let retailPriceCents: Int?
}

struct AliasMarketResult: Codable {
    let product: AliasMarketProduct
    let sizes: [ProviderSizeQuote]
}

struct StockXMarketProduct: Codable {
    let productId: String
    let title: String
    let brand: String
    let styleId: String?
    let colorway: String?
    let urlKey: String?
}

struct StockXMarketResult: Codable {
    let product: StockXMarketProduct
    let sizes: [ProviderSizeQuote]
}

struct LookupMarketErrors: Codable {
    let alias: String?
    let stockx: String?
}

struct LookupMarketData: Codable {
    let status: String
    let query: String
    let alias: AliasMarketResult?
    let stockx: StockXMarketResult?
    let combined: [CombinedSizeQuote]
    let errors: LookupMarketErrors?
}

struct IntegrationStatus: Decodable {
    let provider: String
    let configured: Bool
    let email: String?
    let oauthConnected: Bool?
    let redirectUri: String?
}

struct LookupHistoryEntry: Identifiable, Codable {
    let id: String
    let lookupId: String?
    let lookupType: String?
    let source: LookupSource
    let resultSummary: String
    let detail: String
    let createdAt: Date
    let imageFilename: String
    let marketData: LookupMarketData?
    var feedbackStatus: String?
    var feedbackCorrection: String?

    var imageURL: URL {
        LookupHistoryPaths.imagesDirectory.appendingPathComponent(imageFilename)
    }

    var formattedDate: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

@MainActor
final class LookupHistoryStore: ObservableObject {
    @Published private(set) var entries: [LookupHistoryEntry] = []

    private let storageKey = "lookupHistoryEntries"

    init() {
        load()
    }

    @discardableResult
    func add(
        source: LookupSource,
        imageData: Data,
        resultSummary: String,
        detail: String,
        marketData: LookupMarketData? = nil,
        lookupId: String? = nil,
        lookupType: String? = nil,
        feedbackStatus: String? = nil,
        feedbackCorrection: String? = nil
    ) -> String? {
        let id = UUID().uuidString
        let filename = "\(id).jpg"
        let fileURL = LookupHistoryPaths.imagesDirectory.appendingPathComponent(filename)

        do {
            try imageData.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        let entry = LookupHistoryEntry(
            id: id,
            lookupId: lookupId,
            lookupType: lookupType,
            source: source,
            resultSummary: resultSummary,
            detail: detail,
            createdAt: Date(),
            imageFilename: filename,
            marketData: marketData,
            feedbackStatus: feedbackStatus,
            feedbackCorrection: feedbackCorrection
        )

        entries.insert(entry, at: 0)
        save()
        return id
    }

    func updateFeedback(entryId: String, status: String, correction: String?) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[index].feedbackStatus = status
        entries[index].feedbackCorrection = correction
        save()
    }

    func clearFeedback(entryId: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[index].feedbackStatus = nil
        entries[index].feedbackCorrection = nil
        save()
    }

    func updateFeedback(lookupId: String, status: String, correction: String?) {
        var didUpdate = false
        for index in entries.indices where entries[index].lookupId == lookupId {
            entries[index].feedbackStatus = status
            entries[index].feedbackCorrection = correction
            didUpdate = true
        }
        if didUpdate {
            save()
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LookupHistoryEntry].self, from: data) else {
            entries = []
            return
        }

        entries = decoded.filter {
            FileManager.default.fileExists(
                atPath: LookupHistoryPaths.imagesDirectory.appendingPathComponent($0.imageFilename).path
            )
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func clearOnLogout() {
        entries = []
        UserDefaults.standard.removeObject(forKey: storageKey)
        try? FileManager.default.removeItem(at: LookupHistoryPaths.imagesDirectory)
        try? FileManager.default.createDirectory(at: LookupHistoryPaths.imagesDirectory, withIntermediateDirectories: true)
    }
}

final class BluetoothStateMonitor: NSObject, CBCentralManagerDelegate {
    private let central: CBCentralManager

    override init() {
        central = CBCentralManager(
            delegate: nil,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        super.init()
        central.delegate = self
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    var isPoweredOn: Bool {
        central.state == .poweredOn
    }

    var stateDescription: String {
        switch central.state {
        case .unknown:
            return "unknown"
        case .resetting:
            return "resetting"
        case .unsupported:
            return "unsupported"
        case .unauthorized:
            return "unauthorized"
        case .poweredOff:
            return "powered off"
        case .poweredOn:
            return "powered on"
        @unknown default:
            return "unknown"
        }
    }

    func waitUntilPoweredOn(timeoutSeconds: TimeInterval = 6) async -> Bool {
        if isPoweredOn {
            return true
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isPoweredOn {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return isPoweredOn
    }
}

@MainActor
final class CompanionViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var user: User?
    @Published var token: String?
    @Published var activeLookup: ImageLookup?
    @Published var isBusy = false
    @Published var message: String?
    @Published var isError = false
    @Published var wearablesStatus = "Register the app, allow camera, then start the glasses stream."
    @Published var previewImage: UIImage?
    @Published var castPreviewImage: UIImage?
    @Published var setupStep: SetupStep = .registration
    @Published var registrationSetupStatus: SetupItemStatus = .waiting
    @Published var cameraSetupStatus: SetupItemStatus = .waiting
    @Published var audioSetupStatus: SetupItemStatus = .waiting
    @Published var showConnectionPopover = false
    @Published var showSettings = false
    @Published var showLookupHistory = false
    @Published var showTextLookup = false
    @Published var showMobileImageCamera = false
    @Published var showBarcodeCamera = false
    @Published var showConfetti = false
    @Published var glassesConnectionStatus: GlassesConnectionStatus = .disconnected
    @Published var glassesPreparedForCast = false
    @Published private(set) var isLiveCasting = false
    @Published private(set) var isStartingLiveCast = false
    @Published var lookupHistory: [LookupHistoryEntry] = []
    @Published var hasGeminiApiKey = false
    @Published var geminiApiKeyInput = ""
    @Published var hasAliasIntegration = false
    @Published var aliasIntegrationEmail: String?
    @Published var aliasEmailInput = ""
    @Published var aliasPasswordInput = ""
    @Published var aliasApiKeyInput = ""
    @Published var hasStockXIntegration = false
    @Published var stockxOAuthConnected = false
    @Published var stockxIntegrationEmail: String?
    @Published var stockxRedirectUri = "https://meta-cloud-meta-cloud.up.railway.app/integrations/stockx/oauth/callback"
    @Published var stockxEmailInput = ""
    @Published var stockxApiKeyInput = ""
    @Published var stockxClientIdInput = ""
    @Published var stockxClientSecretInput = ""
    @Published var showStockXOAuthSafari = false
    @Published var stockxOAuthURL: URL?

    var canSaveAliasIntegration: Bool {
        !aliasEmailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !aliasPasswordInput.isEmpty
            && aliasApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
    }

    var canSaveStockXIntegration: Bool {
        !stockxEmailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && stockxApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
            && !stockxClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !stockxClientSecretInput.isEmpty
    }

    let historyStore = LookupHistoryStore()

    private let api = MetaCloudAPI()
    private let tokenKey = "metaCloudToken"
    private let emailKey = "metaCloudEmail"
    private let cameraPermissionConfirmedKey = "datCameraPermissionConfirmed"
    private let audioPermissionConfirmedKey = CastAudioManager.permissionConfirmedKey
    private let datConnectionReadyKey = "datConnectionReady"
    private let mobileSetupCompleteKey = "mobileSetupComplete"
    private let mobileSetupStepKey = "mobileSetupStep"
    private let mobileSetupPendingRestartKey = "mobileSetupPendingRestart"
    private var deviceSession: DeviceSession?
    private var cameraStream: MWDATCamera.Stream?
    private var stateToken: Any?
    private var frameToken: Any?
    private var photoToken: Any?
    private var captureWatchdogTask: Task<Void, Never>?
    private var latestFrameJPEGData: Data?
    private var latestFrameUIImage: UIImage?
    private var hasLiveFrame = false
    private var streamStateText = "stopped"
    private var lookupPollTask: Task<Void, Never>?
    private var pendingCaptureLookupId: String?
    private var pendingCaptureLookupType: String?
    private var lastAutoCaptureLookupId: String?
    private var lastCaptureAttemptToken: String?
    private var streamHandshakeLookupId: String?
    private var startupBaselineLookupId: String?
    private var hasCapturedStartupBaseline = false
    private var autoStartedStreamForLookupId: String?
    private var isAutoCaptureInFlight = false
    private var registrationMonitorTask: Task<Void, Never>?
    private var urlHandledObserver: NSObjectProtocol?
    private var registrationOpenedAt: Date?
    private var registrationCompletedAt: Date?
    private var pendingCameraPermissionRetry = false
    private var pendingAudioPermissionRetry = false
    private var datPrepareTask: Task<Bool, Never>?
    private var datPrepareBackgroundTask: Task<Void, Never>?
    private var autoDeviceSelector: AutoDeviceSelector?
    private var readyDeviceSession: DeviceSession?
    private var readySessionStateTask: Task<Void, Never>?
    private var activeDeviceMonitorTask: Task<Void, Never>?
    private var hasActiveDATDevice = false
    private var photoCaptureContinuation: CheckedContinuation<Data, Error>?
    private var companionBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var pendingStockXOAuthRefresh = false
    private var appBackgroundObserver: NSObjectProtocol?
    private var appForegroundObserver: NSObjectProtocol?
    private var lastPolledLookupId: String?
    private var lastPolledCaptureMode: String?
    private var didAcceptPhotoCaptureRequest = false
    private var isDictationInFlight = false
    private var activeDictationLookupId: String?
    private let speechTranscriber = CompanionSpeechTranscriber()
    private let lookupPollIntervalNanoseconds: UInt64 = 350_000_000
    private let defaultMetaAppID = "0"
    private let defaultClientToken = "DEV_MODE"
    private var bluetoothMonitor: BluetoothStateMonitor?
    private var relaySignaling: SignalingClient!
    private let castWebRTC = WebRTCManager()
    private var castTask: Task<Void, Never>?
    private var isLiveCastActive = false
    private var castRelayConfigured = false
    private var pendingViewerIds: Set<String> = []

    static let defaultSignalingServer = "wss://meta-display-view-caster.onrender.com"

    var isLoggedIn: Bool {
        token != nil
    }

    var isMobileSetupComplete: Bool {
        UserDefaults.standard.bool(forKey: mobileSetupCompleteKey)
    }

    var canAdvanceSetup: Bool {
        switch setupStep {
        case .registration:
            return registrationSetupStatus == .success
        case .camera:
            return cameraSetupStatus == .success
        case .audio:
            return audioSetupStatus == .success
        case .finalize:
            return false
        }
    }

    var metaAIStatusLabel: String {
        registrationSetupStatus == .success ? "Connected" : "Disconnected"
    }

    var cameraStatusLabel: String {
        cameraSetupStatus == .success ? "Connected" : "Disconnected"
    }

    var audioStatusLabel: String {
        audioSetupStatus == .success ? "Connected" : "Disconnected"
    }

    var currentEmail: String {
        user?.email ?? UserDefaults.standard.string(forKey: emailKey) ?? email
    }

    var canUploadPhoto: Bool {
        activeLookup != nil
    }

    var canCaptureGlassesPhoto: Bool {
        cameraStream != nil && activeLookup != nil
    }

    var activeLookupText: String {
        guard let activeLookup else {
            return "Open Image Lookup on the glasses, then tap Refresh."
        }

        return "Waiting for photo. Capture code: \(activeLookup.captureCode)"
    }

    deinit {
        lookupPollTask?.cancel()
        registrationMonitorTask?.cancel()
        datPrepareTask?.cancel()
        datPrepareBackgroundTask?.cancel()
        activeDeviceMonitorTask?.cancel()
        readySessionStateTask?.cancel()
        readyDeviceSession?.stop()
        if let urlHandledObserver {
            NotificationCenter.default.removeObserver(urlHandledObserver)
        }
        if let appBackgroundObserver {
            NotificationCenter.default.removeObserver(appBackgroundObserver)
        }
        if let appForegroundObserver {
            NotificationCenter.default.removeObserver(appForegroundObserver)
        }
    }

    private var datConfig: [String: Any] {
        Bundle.main.infoDictionary?["MWDAT"] as? [String: Any] ?? [:]
    }

    private var datMetaAppID: String {
        datConfig["MetaAppID"] as? String ?? "<missing>"
    }

    private var datClientToken: String {
        datConfig["ClientToken"] as? String ?? "<missing>"
    }

    private var datTeamID: String {
        datConfig["TeamID"] as? String ?? "<missing>"
    }

    private var runtimeBundleID: String {
        Bundle.main.bundleIdentifier ?? "<missing>"
    }

    private var hasPlaceholderDATCredentials: Bool {
        datMetaAppID == defaultMetaAppID || datClientToken == defaultClientToken || datClientToken == "<missing>"
    }

    func loadMobileSetupState() {
        if UserDefaults.standard.bool(forKey: mobileSetupPendingRestartKey) {
            UserDefaults.standard.set(false, forKey: mobileSetupPendingRestartKey)
            UserDefaults.standard.set(true, forKey: mobileSetupCompleteKey)
        }

        if isMobileSetupComplete {
            refreshSetupProgress()
            startCastCompanionBridge()
            return
        }

        let savedStep = UserDefaults.standard.integer(forKey: mobileSetupStepKey)
        if savedStep == 0,
           isRegistrationStateReady(Wearables.shared.registrationState),
           UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey),
           UserDefaults.standard.bool(forKey: audioPermissionConfirmedKey) {
            setupStep = .finalize
            UserDefaults.standard.set(SetupStep.finalize.rawValue, forKey: mobileSetupStepKey)
            UserDefaults.standard.set(true, forKey: mobileSetupPendingRestartKey)
            refreshSetupProgress()
            return
        }

        if savedStep == 3, !UserDefaults.standard.bool(forKey: audioPermissionConfirmedKey) {
            setupStep = UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) ? .audio : .finalize
        } else if let step = SetupStep(rawValue: savedStep) {
            setupStep = step
        } else {
            setupStep = .registration
        }

        refreshSetupProgress()
    }

    func advanceSetupStep() {
        switch setupStep {
        case .registration:
            setupStep = .camera
            Task { await validateCameraPermissionFlag() }
        case .camera:
            setupStep = .audio
            Task { await validateAudioPermissionFlag() }
        case .audio:
            setupStep = .finalize
            UserDefaults.standard.set(true, forKey: mobileSetupPendingRestartKey)
        case .finalize:
            break
        }

        UserDefaults.standard.set(setupStep.rawValue, forKey: mobileSetupStepKey)
        isError = false
        message = nil
    }

    func refreshSetupProgress() {
        if isRegistrationStateReady(Wearables.shared.registrationState) {
            registrationSetupStatus = .success
        } else if registrationSetupStatus != .success {
            registrationSetupStatus = .waiting
        }

        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            cameraSetupStatus = .success
        } else if cameraSetupStatus != .success {
            cameraSetupStatus = .waiting
        }

        if UserDefaults.standard.bool(forKey: audioPermissionConfirmedKey) {
            audioSetupStatus = .success
        } else if audioSetupStatus != .success {
            audioSetupStatus = .waiting
        }

        refreshGlassesConnectionStatus()
        updateReadyWearablesStatus()
    }

    func refreshGlassesConnectionStatus() {
        let registered = isRegistrationStateReady(Wearables.shared.registrationState)
        let cameraAllowed = UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey)
        let sessionReady = readyDeviceSession?.state == .started

        if sessionReady || (registered && cameraAllowed && isMobileSetupComplete) {
            glassesConnectionStatus = .connected
        } else {
            glassesConnectionStatus = .disconnected
        }
    }

    func restoreSession() async {
        startRegistrationMonitoring()
        loadMobileSetupState()
        await validateCameraPermissionFlag()
        _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false)
        await validateAudioPermissionFlag()
        _ = await resolveAudioPermissionIfAlreadyGranted(shouldShowMessage: false)
        refreshSetupProgress()
        if isMobileSetupComplete {
            startCastCompanionBridge()
        }

        guard let savedToken = UserDefaults.standard.string(forKey: tokenKey) else {
            return
        }

        token = savedToken
        email = UserDefaults.standard.string(forKey: emailKey) ?? ""
        await refreshActiveLookup()
        captureLookupBaselineIfNeeded()
        startCompanionBackgroundBridgeIfNeeded()
        syncLookupHistory()
        await refreshApiKeys()
        await refreshIntegrations()
    }

    func startCompanionBackgroundBridgeIfNeeded() {
        startCastCompanionBridge()
        guard isLoggedIn, isMobileSetupComplete, token != nil else { return }
        startLookupPollingIfNeeded()
    }

    /// Keeps relay + DAT session warm for View Caster (no login required).
    func startCastCompanionBridge() {
        installCompanionLifecycleObserversIfNeeded()
        startActiveDeviceMonitoring()
        guard isMobileSetupComplete else { return }
        startCastRelayIfNeeded()
        scheduleDATPrepareIfNeeded(delayNanoseconds: 0)
    }

    private func wakeCastFromGlasses() {
        beginCompanionBackgroundTask()
        startCastCompanionBridge()
        wearablesStatus = "Live Stream requested — starting glasses camera…"
    }

    private func installCompanionLifecycleObserversIfNeeded() {
        guard appBackgroundObserver == nil else { return }

        appBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onAppEnteredBackground()
            }
        }

        appForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onAppWillEnterForeground()
            }
        }
    }

    func onAppEnteredBackground() {
        if isMobileSetupComplete {
            beginCompanionBackgroundTask()
            updateReadyWearablesStatus()
            startCastCompanionBridge()
        }
        guard isLoggedIn, isMobileSetupComplete, token != nil else { return }
        startLookupPollingIfNeeded()
    }

    func onAppWillEnterForeground() {
        endCompanionBackgroundTask()
        onAppBecameActive()
    }

    private func beginCompanionBackgroundTask() {
        guard companionBackgroundTaskID == .invalid else { return }
        companionBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MetaDisplayCompanion") { [weak self] in
            Task { @MainActor in
                self?.renewCompanionBackgroundTask()
            }
        }
    }

    private func renewCompanionBackgroundTask() {
        endCompanionBackgroundTask()
        guard UIApplication.shared.applicationState == .background else { return }
        if isMobileSetupComplete || (isLoggedIn && token != nil) {
            beginCompanionBackgroundTask()
        }
    }

    private func endCompanionBackgroundTask() {
        guard companionBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(companionBackgroundTaskID)
        companionBackgroundTaskID = .invalid
    }

    func refreshApiKeys() async {
        guard let token else {
            hasGeminiApiKey = false
            return
        }

        do {
            let response = try await api.listApiKeys(token: token)
            hasGeminiApiKey = response.apiKeys.contains { $0.provider == "gemini" }
        } catch {
            hasGeminiApiKey = false
        }
    }

    func saveGeminiApiKey() async {
        guard let token else {
            showError("Log in to save an API key.")
            return
        }

        let trimmedKey = geminiApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.count >= 8 else {
            showError("Enter a valid Gemini API key.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await api.saveApiKey(token: token, provider: "gemini", apiKey: trimmedKey, label: "Gemini")
            geminiApiKeyInput = ""
            hasGeminiApiKey = true
            showMessage("Gemini API key saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func deleteGeminiApiKey() async {
        guard let token else {
            showError("Log in to remove an API key.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await api.deleteApiKey(token: token, provider: "gemini")
            geminiApiKeyInput = ""
            hasGeminiApiKey = false
            showMessage("Gemini API key removed.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func refreshIntegrations() async {
        guard let token else {
            hasAliasIntegration = false
            aliasIntegrationEmail = nil
            hasStockXIntegration = false
            stockxOAuthConnected = false
            stockxIntegrationEmail = nil
            return
        }

        do {
            async let alias = api.getAliasIntegration(token: token)
            async let stockx = api.getStockXIntegration(token: token)
            let aliasResult = try await alias
            let stockxResult = try await stockx
            hasAliasIntegration = aliasResult.integration.configured
            aliasIntegrationEmail = aliasResult.integration.email
            hasStockXIntegration = stockxResult.integration.configured
            stockxIntegrationEmail = stockxResult.integration.email
            stockxOAuthConnected = stockxResult.integration.oauthConnected ?? false
            if let redirectUri = stockxResult.integration.redirectUri {
                stockxRedirectUri = redirectUri
            }
        } catch {
            hasAliasIntegration = false
            aliasIntegrationEmail = nil
            hasStockXIntegration = false
            stockxOAuthConnected = false
            stockxIntegrationEmail = nil
        }
    }

    func saveAliasIntegration() async {
        guard let token else {
            showError("Log in to save Alias credentials.")
            return
        }

        let email = aliasEmailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = aliasApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

        isBusy = true
        defer { isBusy = false }

        do {
            showMessage("Connecting to Alias...")
            try await api.loginAliasAccount(email: email, password: aliasPasswordInput)

            let result = try await api.saveAliasIntegration(
                token: token,
                email: email,
                password: aliasPasswordInput,
                apiKey: apiKey
            )
            hasAliasIntegration = result.integration.configured
            aliasIntegrationEmail = result.integration.email
            aliasPasswordInput = ""
            aliasApiKeyInput = ""
            showMessage("Alias connected and saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func deleteAliasIntegration() async {
        guard let token else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            try await api.deleteAliasIntegration(token: token)
            hasAliasIntegration = false
            aliasIntegrationEmail = nil
            showMessage("Alias credentials removed.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveStockXIntegration() async {
        guard let token else {
            showError("Log in to save StockX credentials.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await api.saveStockXIntegration(
                token: token,
                email: stockxEmailInput.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: stockxApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                clientId: stockxClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: stockxClientSecretInput
            )
            hasStockXIntegration = result.integration.configured
            stockxIntegrationEmail = result.integration.email
            stockxOAuthConnected = result.integration.oauthConnected ?? false
            if let redirectUri = result.integration.redirectUri {
                stockxRedirectUri = redirectUri
            }
            stockxClientSecretInput = ""
            showMessage("StockX credentials saved.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func deleteStockXIntegration() async {
        guard let token else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            try await api.deleteStockXIntegration(token: token)
            hasStockXIntegration = false
            stockxOAuthConnected = false
            stockxIntegrationEmail = nil
            showMessage("StockX credentials removed.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func loginStockX() async {
        guard let token else {
            showError("Log in first.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await api.startStockXOAuth(token: token)
            stockxRedirectUri = result.redirectUri
            guard let authURL = URL(string: result.authUrl) else {
                showError("Invalid StockX login URL.")
                return
            }

            pendingStockXOAuthRefresh = true
            stockxOAuthURL = authURL
            showStockXOAuthSafari = true
            showMessage("Complete StockX login in the browser sheet.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func handleStockXOAuthDismissed() async {
        await refreshIntegrations()
        if stockxOAuthConnected {
            showMessage("StockX connected.")
        }
        stockxOAuthURL = nil
    }

    func onAppBecameActive() {
        Task {
            if isMobileSetupComplete {
                startCastRelayIfNeeded()
            }

            if pendingStockXOAuthRefresh {
                pendingStockXOAuthRefresh = false
                await refreshIntegrations()
                if stockxOAuthConnected {
                    showMessage("StockX connected.")
                }
            }

            let timeout: TimeInterval = registrationOpenedAt == nil ? 2 : 10
            if await waitForRegistrationReady(timeoutSeconds: timeout) {
                registrationOpenedAt = nil
                refreshSetupProgress()
            }

            if pendingCameraPermissionRetry {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await finishPendingCameraPermissionIfPossible(showStatusMessage: !isMobileSetupComplete)
            } else {
                _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false)
                refreshSetupProgress()
            }

            if pendingAudioPermissionRetry {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await finishPendingAudioPermissionIfPossible(showStatusMessage: !isMobileSetupComplete)
            } else {
                _ = await resolveAudioPermissionIfAlreadyGranted(shouldShowMessage: false)
                refreshSetupProgress()
            }
        }
    }

    func login() async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            showError("Enter your email and password.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await api.login(email: email, password: password)
            user = response.user
            token = response.session.token
            UserDefaults.standard.set(response.session.token, forKey: tokenKey)
            UserDefaults.standard.set(response.user.email, forKey: emailKey)
            password = ""
            showMessage("Logged in.")
            startRegistrationMonitoring()
            loadMobileSetupState()
            await refreshActiveLookup()
            captureLookupBaselineIfNeeded()
            startCompanionBackgroundBridgeIfNeeded()
            await validateCameraPermissionFlag()
            _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false)
            refreshSetupProgress()
            syncLookupHistory()
            await refreshApiKeys()
            await refreshIntegrations()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func logout() {
        stopLookupPolling()
        stopGlassesStream()
        endCompanionBackgroundTask()
        token = nil
        user = nil
        activeLookup = nil
        pendingCaptureLookupId = nil
        pendingCaptureLookupType = nil
        lastAutoCaptureLookupId = nil
        lastCaptureAttemptToken = nil
        lastPolledLookupId = nil
        lastPolledCaptureMode = nil
        streamHandshakeLookupId = nil
        startupBaselineLookupId = nil
        hasCapturedStartupBaseline = false
        autoStartedStreamForLookupId = nil
        isAutoCaptureInFlight = false
        activeDeviceMonitorTask?.cancel()
        activeDeviceMonitorTask = nil
        autoDeviceSelector = nil
        hasActiveDATDevice = false
        stopReadyDeviceSession()
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
        UserDefaults.standard.removeObject(forKey: datConnectionReadyKey)
        UserDefaults.standard.removeObject(forKey: mobileSetupCompleteKey)
        UserDefaults.standard.removeObject(forKey: mobileSetupStepKey)
        UserDefaults.standard.removeObject(forKey: mobileSetupPendingRestartKey)
        setupStep = .registration
        registrationSetupStatus = .waiting
        cameraSetupStatus = .waiting
        audioSetupStatus = .waiting
        glassesConnectionStatus = .disconnected
        showConnectionPopover = false
        showSettings = false
        hasGeminiApiKey = false
        geminiApiKeyInput = ""
        hasAliasIntegration = false
        aliasIntegrationEmail = nil
        aliasEmailInput = ""
        aliasPasswordInput = ""
        aliasApiKeyInput = ""
        hasStockXIntegration = false
        stockxOAuthConnected = false
        stockxIntegrationEmail = nil
        stockxEmailInput = ""
        stockxApiKeyInput = ""
        stockxClientIdInput = ""
        stockxClientSecretInput = ""
        historyStore.clearOnLogout()
        lookupHistory = []
        showMessage("Logged out.")
    }

    func refreshActiveLookup() async {
        guard let token else { return }

        isBusy = true
        defer { isBusy = false }

        await fetchActiveLookup(token: token, showStatusMessage: true)
    }

    private func fetchActiveLookup(token: String, showStatusMessage: Bool) async {
        do {
            activeLookup = try await api.activeLookup(token: token).lookup
            syncLookupFeedbackToHistory(activeLookup)
            if showStatusMessage {
                showMessage(activeLookup == nil ? "No active lookup found." : "Active lookup found.")
            }
        } catch {
            if showStatusMessage {
                showError(error.localizedDescription)
            }
        }
    }

    func uploadPhoto(_ item: PhotosPickerItem) async {
        guard let token, let activeLookup else {
            showError("No active lookup. Start Image Lookup on the glasses first.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                showError("Could not read selected photo.")
                return
            }

            let response = try await api.uploadImage(
                token: token,
                lookupId: activeLookup.id,
                imageData: data
            )
            self.activeLookup = response.lookup
            showMessage("Photo uploaded. Check the glasses for the SKU.")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func startRegistration() {
        Task {
            guard validateDATConfiguration() else { return }
            if isRegistrationStateReady(Wearables.shared.registrationState) {
                wearablesStatus = "Already registered with Meta AI."
                showMessage("Already Registered")
                return
            }

            isBusy = true
            defer { isBusy = false }

            wearablesStatus = "Opening Meta AI registration..."
            do {
                registrationOpenedAt = Date()
                try await Wearables.shared.startRegistration()
                wearablesStatus = "Opened Meta AI registration. Return here after approving."
            } catch RegistrationError.alreadyRegistered {
                wearablesStatus = "Already registered with Meta AI."
                showMessage("Already Registered")
            } catch {
                if isRegistrationStateReady(Wearables.shared.registrationState) {
                    wearablesStatus = "Already registered with Meta AI."
                    showMessage("Already Registered")
                    return
                }
                showWearablesError(context: "Registration", error: error)
            }
        }
    }

    func requestCameraPermission() async {
        guard validateDATConfiguration() else { return }

        isBusy = true
        defer { isBusy = false }

        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            markCameraPermissionGranted(shouldShowMessage: true)
            return
        }

        if let status = await safeCameraPermissionStatus(), status == .granted {
            markCameraPermissionGranted(shouldShowMessage: true)
            return
        }

        if !isRegistrationStateReady(Wearables.shared.registrationState) {
            wearablesStatus = "Register with Meta AI first."
            showError("Tap Register With Meta AI first, then Allow Camera.")
            return
        }

        let monitor = bluetoothMonitorInstance()
        if !monitor.isPoweredOn {
            wearablesStatus = "Waiting for Bluetooth..."
            let ready = await monitor.waitUntilPoweredOn(timeoutSeconds: 2)
            guard ready else {
                showError("Bluetooth is \(monitor.stateDescription). Turn Bluetooth on, then retry Allow Camera.")
                return
            }
        }

        wearablesStatus = "Opening Meta AI for camera permission..."
        pendingCameraPermissionRetry = true

        do {
            try await openCameraPermissionInMetaAI()
        } catch {
            if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: true) {
                return
            }
            if isRecoverableWearablesSyncError(error) {
                pendingCameraPermissionRetry = true
                wearablesStatus = "Waiting for camera approval in Meta AI."
                showMessage("Approve camera access in Meta AI, then return here.")
                return
            }
            pendingCameraPermissionRetry = false
            showWearablesError(context: "Camera permission", error: error)
        }
    }

    private func openCameraPermissionInMetaAI() async throws {
        let status = try await Wearables.shared.requestPermission(.camera)

        if status == .granted {
            markCameraPermissionGranted(shouldShowMessage: true)
            return
        }

        if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: true) {
            return
        }

        pendingCameraPermissionRetry = true
        showMessage("Approve camera access in Meta AI, then return here.")
    }

    private func safeCameraPermissionStatus() async -> PermissionStatus? {
        do {
            return try await Wearables.shared.checkPermissionStatus(.camera)
        } catch {
            return nil
        }
    }

    private func requestCameraPermissionDirectly() async throws {
        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            markCameraPermissionGranted(shouldShowMessage: false)
            return
        }

        try await openCameraPermissionInMetaAI()
    }

    private func finishPendingCameraPermissionIfPossible(showStatusMessage: Bool) async {
        try? await Task.sleep(nanoseconds: 300_000_000)

        if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: showStatusMessage) {
            if !isMobileSetupComplete {
                beginGlassesConnectionSetup(showStatus: showStatusMessage)
            }
            return
        }

        if showStatusMessage {
            wearablesStatus = "Waiting for camera approval to sync..."
            showMessage("If you chose Always Allow in Meta AI, wait a moment and it should update automatically.")
        }
    }

    private func resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: Bool) async -> Bool {
        if let status = await waitForCameraPermissionStatus(timeoutSeconds: 1),
           status == .granted {
            markCameraPermissionGranted(shouldShowMessage: shouldShowMessage)
            return true
        }

        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            await validateCameraPermissionFlag()
            if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
                markCameraPermissionGranted(shouldShowMessage: shouldShowMessage)
                return true
            }
        }

        return false
    }

    private func validateCameraPermissionFlag() async {
        guard UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) else {
            cameraSetupStatus = .waiting
            refreshGlassesConnectionStatus()
            return
        }

        guard let status = await safeCameraPermissionStatus() else {
            return
        }

        if status == .granted {
            cameraSetupStatus = .success
            refreshGlassesConnectionStatus()
            return
        }

        UserDefaults.standard.set(false, forKey: cameraPermissionConfirmedKey)
        cameraSetupStatus = .waiting
        refreshGlassesConnectionStatus()
        updateReadyWearablesStatus()
    }

    private func waitForCameraPermissionStatus(timeoutSeconds: TimeInterval) async -> PermissionStatus? {
        if let status = await safeCameraPermissionStatus() {
            return status
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let status = await safeCameraPermissionStatus() {
                return status
            }
        }
        return await safeCameraPermissionStatus()
    }

    private func refreshCameraPermissionStatus(shouldShowMessage: Bool) async {
        _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: shouldShowMessage)
    }

    private func markCameraPermissionGranted(shouldShowMessage: Bool) {
        pendingCameraPermissionRetry = false
        UserDefaults.standard.set(true, forKey: cameraPermissionConfirmedKey)
        wearablesStatus = isMobileSetupComplete
            ? "Preparing glasses for capture..."
            : "Camera access approved."
        startActiveDeviceMonitoring()
        refreshSetupProgress()
        beginGlassesConnectionSetup(showStatus: shouldShowMessage)
        if shouldShowMessage {
            showMessage(isMobileSetupComplete ? "Camera Already Allowed" : "Camera Allowed")
        }
    }

    func requestAudioPermission() async {
        guard validateDATConfiguration() else { return }

        isBusy = true
        defer { isBusy = false }

        if UserDefaults.standard.bool(forKey: audioPermissionConfirmedKey) {
            markAudioPermissionGranted(shouldShowMessage: true)
            return
        }

        if await resolveAudioPermissionIfAlreadyGranted(shouldShowMessage: true) {
            return
        }

        if !isRegistrationStateReady(Wearables.shared.registrationState) {
            wearablesStatus = "Register with Meta AI first."
            showError("Tap Register With Meta AI first, then Allow Microphone.")
            return
        }

        wearablesStatus = "Requesting microphone access for live cast audio..."
        pendingAudioPermissionRetry = true

        let granted = await CastAudioManager.shared.requestMicrophonePermission()
        if granted {
            markAudioPermissionGranted(shouldShowMessage: true)
            return
        }

        if await resolveAudioPermissionIfAlreadyGranted(shouldShowMessage: true) {
            return
        }

        pendingAudioPermissionRetry = true
        wearablesStatus = "Waiting for microphone approval."
        showMessage("Allow microphone access in Settings, then return here.")
    }

    private func finishPendingAudioPermissionIfPossible(showStatusMessage: Bool) async {
        guard pendingAudioPermissionRetry else { return }
        if await resolveAudioPermissionIfAlreadyGranted(shouldShowMessage: showStatusMessage) {
            return
        }
        if showStatusMessage {
            wearablesStatus = "Waiting for microphone approval."
        }
    }

    private func resolveAudioPermissionIfAlreadyGranted(shouldShowMessage: Bool) async -> Bool {
        if await CastAudioManager.shared.currentRecordPermissionGranted() {
            markAudioPermissionGranted(shouldShowMessage: shouldShowMessage)
            return true
        }

        if UserDefaults.standard.bool(forKey: audioPermissionConfirmedKey) {
            await validateAudioPermissionFlag()
            if UserDefaults.standard.bool(forKey: audioPermissionConfirmedKey) {
                markAudioPermissionGranted(shouldShowMessage: shouldShowMessage)
                return true
            }
        }

        return false
    }

    private func validateAudioPermissionFlag() async {
        guard UserDefaults.standard.bool(forKey: audioPermissionConfirmedKey) else {
            audioSetupStatus = .waiting
            refreshGlassesConnectionStatus()
            return
        }

        if await CastAudioManager.shared.currentRecordPermissionGranted() {
            audioSetupStatus = .success
            refreshGlassesConnectionStatus()
            return
        }

        CastAudioManager.shared.clearPermissionFlag()
        audioSetupStatus = .waiting
        refreshGlassesConnectionStatus()
    }

    private func markAudioPermissionGranted(shouldShowMessage: Bool) {
        pendingAudioPermissionRetry = false
        CastAudioManager.shared.markPermissionGranted()
        wearablesStatus = isMobileSetupComplete
            ? "Microphone ready for live cast."
            : "Microphone access approved."
        refreshSetupProgress()
        if shouldShowMessage {
            showMessage(isMobileSetupComplete ? "Microphone Already Allowed" : "Microphone Allowed")
        }
    }

    private func prepareCastAudioIfNeeded() async {
        let includeAudio = CastAudioManager.shared.isPermissionConfirmed
        castWebRTC.setAudioEnabled(includeAudio)
        guard includeAudio else { return }
        do {
            try await CastAudioManager.shared.prepareForLiveCast()
            castWebRTC.startStream()
        } catch {
            castWebRTC.setAudioEnabled(false)
            wearablesStatus = "Live video only — \(error.localizedDescription)"
        }
    }

    private func beginGlassesConnectionSetup(showStatus: Bool) {
        datPrepareBackgroundTask?.cancel()
        datPrepareBackgroundTask = Task { [weak self] in
            _ = await self?.ensureReadyDeviceSession(showStatus: showStatus, timeoutSeconds: 60)
        }
    }

    private func scheduleDATPrepareIfNeeded(delayNanoseconds: UInt64 = 500_000_000) {
        guard UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) else { return }
        guard isRegistrationStateReady(Wearables.shared.registrationState) else { return }
        guard readyDeviceSession?.state != .started else { return }

        datPrepareBackgroundTask?.cancel()
        datPrepareBackgroundTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            _ = await self?.ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 60)
        }
    }

    private func autoSelector() -> AutoDeviceSelector {
        if let autoDeviceSelector {
            return autoDeviceSelector
        }

        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        autoDeviceSelector = selector
        return selector
    }

    private func startActiveDeviceMonitoring() {
        guard activeDeviceMonitorTask == nil else { return }

        let selector = autoSelector()
        activeDeviceMonitorTask = Task { [weak self] in
            for await device in selector.activeDeviceStream() {
                let isActive = device != nil
                await MainActor.run {
                    self?.hasActiveDATDevice = isActive
                }
            }
        }
    }

    private func ensureReadyDeviceSession(showStatus: Bool, timeoutSeconds: TimeInterval = 60) async -> Bool {
        if let datPrepareTask, !datPrepareTask.isCancelled {
            return await datPrepareTask.value
        }

        let task = Task { [weak self] () -> Bool in
            await self?.establishReadyDeviceSession(showStatus: showStatus, timeoutSeconds: timeoutSeconds) ?? false
        }
        datPrepareTask = task
        let ready = await task.value
        datPrepareTask = nil
        return ready
    }

    private func establishReadyDeviceSession(showStatus: Bool, timeoutSeconds: TimeInterval) async -> Bool {
        if let session = readyDeviceSession, session.state == .started {
            UserDefaults.standard.set(true, forKey: datConnectionReadyKey)
            updateReadyWearablesStatus()
            return true
        }

        if readyDeviceSession?.state == .stopped {
            readyDeviceSession = nil
        }

        guard isRegistrationStateReady(Wearables.shared.registrationState) else { return false }
        guard UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) else { return false }

        if showStatus {
            wearablesStatus = "Preparing glasses for capture..."
        }

        startActiveDeviceMonitoring()
        _ = await waitForRegistrationReady(timeoutSeconds: min(12, timeoutSeconds / 2))

        let monitor = bluetoothMonitorInstance()
        if !monitor.isPoweredOn {
            _ = await monitor.waitUntilPoweredOn(timeoutSeconds: 5)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled {
                return false
            }

            if !hasActiveDATDevice, Wearables.shared.devices.isEmpty {
                _ = await waitForKnownDevice(timeoutSeconds: min(2, max(1, deadline.timeIntervalSinceNow)))
            } else {
                hasActiveDATDevice = true
            }

            do {
                let session = try await getOrCreateStartedSession()
                readyDeviceSession = session
                UserDefaults.standard.set(true, forKey: datConnectionReadyKey)
                updateReadyWearablesStatus()
                if showStatus {
                    showMessage("Glasses ready for capture.")
                }
                return true
            } catch {
                readyDeviceSession = nil
                await recoverFromDATSetupError(error)
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        return readyDeviceSession?.state == .started
    }

    private func getOrCreateStartedSession() async throws -> DeviceSession {
        if let session = readyDeviceSession {
            if session.state == .started {
                return session
            }
            if session.state == .stopped {
                readyDeviceSession = nil
            } else {
                try await waitForSessionStarted(session)
                return session
            }
        }

        let session = try Wearables.shared.createSession(deviceSelector: autoSelector())
        readyDeviceSession = session

        let stateStream = session.stateStream()
        let errorStream = session.errorStream()
        try session.start()

        if session.state == .started {
            observeReadySessionState(session)
            return session
        }

        try await waitForSessionStarted(
            session,
            stateStream: stateStream,
            errorStream: errorStream
        )
        observeReadySessionState(session)
        return session
    }

    private func waitForSessionStarted(
        _ session: DeviceSession,
        stateStream: AsyncStream<DeviceSessionState>? = nil,
        errorStream: AsyncStream<DeviceSessionError>? = nil
    ) async throws {
        let states = stateStream ?? session.stateStream()
        let errors = errorStream ?? session.errorStream()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in states {
                    if state == .started {
                        return
                    }
                    if state == .stopped {
                        throw DeviceSessionError.unexpectedError(description: "The session stopped before it started.")
                    }
                }
                throw DeviceSessionError.unexpectedError(description: "The session failed to start.")
            }

            group.addTask {
                for await error in errors {
                    throw error
                }
                throw DeviceSessionError.unexpectedError(description: "The session failed to start.")
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func observeReadySessionState(_ session: DeviceSession) {
        readySessionStateTask?.cancel()
        readySessionStateTask = Task { [weak self] in
            for await state in session.stateStream() {
                await MainActor.run {
                    guard let self else { return }
                    if state == .started {
                        UserDefaults.standard.set(true, forKey: self.datConnectionReadyKey)
                        self.updateReadyWearablesStatus()
                    } else if state == .stopped {
                        self.readyDeviceSession = nil
                        UserDefaults.standard.set(false, forKey: self.datConnectionReadyKey)
                        self.readySessionStateTask = nil
                    }
                }
            }
        }
    }

    private func recoverFromDATSetupError(_ error: Error) async {
        if case DeviceSessionError.datAppOnTheGlassesUpdateRequired = error {
            wearablesStatus = "Updating glasses app..."
            try? await Wearables.shared.openDATGlassesAppUpdate()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return
        }

        let text = error.localizedDescription.lowercased()
        if text.contains("datapp") || text.contains("glasses update") || text.contains("update required") {
            wearablesStatus = "Updating glasses app..."
            try? await Wearables.shared.openDATGlassesAppUpdate()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func stopReadyDeviceSession() {
        readySessionStateTask?.cancel()
        readySessionStateTask = nil
        readyDeviceSession?.stop()
        readyDeviceSession = nil
        UserDefaults.standard.set(false, forKey: datConnectionReadyKey)
    }

    private func startGlassesStreamForCapture(quiet: Bool, lookupId: String? = nil) async throws {
        guard !isLiveCasting, !isLiveCastActive, !isStartingLiveCast else {
            throw APIError(message: "Live cast is active.")
        }
        let ready = await ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 30)
        guard ready else {
            throw APIError(message: "No eligible device available.")
        }

        if cameraStream != nil {
            await stopCameraStreamOnly()
        }

        try await startGlassesStreamAttempt(quiet: quiet, photoCaptureOnly: true, deviceTimeoutSeconds: 20)
        if let lookupId {
            autoStartedStreamForLookupId = lookupId
        }
    }

    private func isRecoverableWearablesSyncError(_ error: Error) -> Bool {
        if isRegistrationSyncError(error) {
            return true
        }

        let text = error.localizedDescription.lowercased()
        return text.contains("permissionerror") || text.contains("registrationerror")
    }

    func runWearablesDiagnostics() async {
        guard validateDATConfiguration(reportAsError: false) else { return }

        isBusy = true
        defer { isBusy = false }

        var permissionText = "unknown"
        do {
            let permission = try await Wearables.shared.checkPermissionStatus(.camera)
            permissionText = String(describing: permission)
        } catch {
            permissionText = "error: \(error.localizedDescription)"
        }

        let registrationText = String(describing: Wearables.shared.registrationState)
        let registrationReady = isRegistrationStateReady(registrationText)

        let monitor = bluetoothMonitorInstance()
        let devicesText = await deviceSnapshot(timeoutSeconds: 6)
        wearablesStatus = """
        MetaAppID: \(datMetaAppID)
        ClientToken: \(maskedToken(datClientToken))
        TeamID(plist): \(datTeamID)
        Bundle(runtime): \(runtimeBundleID)
        Bluetooth: \(monitor.stateDescription)
        Registration: \(registrationText) (\(registrationReady ? "ready" : "not ready"))
        Camera permission: \(permissionText)
        DAT devices: \(devicesText)
        """

        if hasPlaceholderDATCredentials {
            showMessage("MetaAppID/ClientToken are placeholders. If you still get permission errors, replace them from Meta Wearables Developer Center.")
        }
    }

    func startGlassesStream() async {
        guard validateDATConfiguration() else { return }
        guard await ensureBluetoothPoweredOn(actionName: "Start Glasses") else { return }
        guard await ensureRegistered(actionName: "Start Glasses") else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            try await startGlassesStreamAttempt()
            await refreshActiveLookup()
            startLookupPollingIfNeeded()
        } catch {
            if error.localizedDescription.contains("No eligible device available") {
                wearablesStatus = "Device not eligible yet. Re-opening Meta AI, then retrying..."
                openMetaAIApp()
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                do {
                    try await startGlassesStreamAttempt()
                    showMessage("Glasses stream active after re-sync.")
                    await refreshActiveLookup()
                    return
                } catch {
                    showWearablesError(context: "Start glasses stream", error: error)
                    return
                }
            }

            if error.localizedDescription.contains("XPC connection invalid") {
                stopGlassesStream()
                wearablesStatus = "DAT connection dropped. Retrying stream start..."
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                do {
                    try await startGlassesStreamAttempt()
                    showMessage("Glasses stream active after retry.")
                    await refreshActiveLookup()
                    return
                } catch {
                    showWearablesError(context: "Start glasses stream", error: error)
                    return
                }
            }
            showWearablesError(context: "Start glasses stream", error: error)
        }
    }

    func captureGlassesPhoto() {
        guard let cameraStream else {
            showError("Start the glasses stream first.")
            return
        }

        guard let activeLookup else {
            showError("Start Image Lookup on the glasses first.")
            return
        }

        pendingCaptureLookupId = activeLookup.id
        pendingCaptureLookupType = activeLookup.lookupType ?? (activeLookup.provider == "local" ? "barcode" : "image")
        lastAutoCaptureLookupId = activeLookup.id
        isAutoCaptureInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let accepted = await self.requestCaptureWithRetry(
                stream: cameraStream,
                captureCode: activeLookup.captureCode,
                maxAttempts: 8,
                delayNanoseconds: 250_000_000
            )
            if accepted {
                self.scheduleCaptureWatchdog(
                    lookupId: activeLookup.id,
                    captureCode: activeLookup.captureCode
                )
            } else {
                let fallbackUploaded = await self.uploadLatestFrameFallback(
                    lookupId: activeLookup.id,
                    captureCode: activeLookup.captureCode
                )
                if !fallbackUploaded {
                    self.pendingCaptureLookupId = nil
                    self.lastAutoCaptureLookupId = nil
                    self.isAutoCaptureInFlight = false
                    self.showError("Capture request was not accepted after retries. Try Capture again.")
                }
            }
        }
    }

    private func uploadCapturedGlassesImage(_ imageData: Data, quiet: Bool = false) async {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil

        guard let token else {
            isAutoCaptureInFlight = false
            pendingCaptureLookupId = nil
            showError("Not logged in. Log in to continue.")
            return
        }
        guard let lookupId = pendingCaptureLookupId ?? activeLookup?.id else {
            isAutoCaptureInFlight = false
            showError("No active lookup. Start Image Lookup on the glasses first.")
            return
        }

        // The photo bytes are already in memory here, so release the glasses camera
        // before slower upload / Gemini / market processing begins.
        await finishGlassesCaptureAfterPhoto()

        let blocksUI = !quiet
        if blocksUI {
            isBusy = true
        }
        defer {
            if blocksUI {
                isBusy = false
            }
            isAutoCaptureInFlight = false
            resetCaptureBridgeStateAfterResult()
        }

        do {
            if isPendingBarcodeCapture() {
                await finishGlassesBarcodeCapture(
                    lookupId: lookupId,
                    imageData: imageData,
                    quiet: quiet
                )
            } else {
                let response = try await api.uploadImage(
                    token: token,
                    lookupId: lookupId,
                    imageData: imageData
                )
                lastAutoCaptureLookupId = lookupId
                pendingCaptureLookupId = nil
                pendingCaptureLookupType = nil
                self.activeLookup = response.lookup
                await recordLookupHistory(source: .metaGlasses, imageData: imageData, lookup: response.lookup)
                streamHandshakeLookupId = nil
                if quiet {
                    restoreIdleWearablesStatus()
                } else {
                    showMessage("Glasses photo uploaded. Stream stopped. Check the display for SKU.")
                }
            }
        } catch {
            lastAutoCaptureLookupId = lookupId
            pendingCaptureLookupId = nil
            pendingCaptureLookupType = nil
            showError(error.localizedDescription)
        }
    }

    private func resetCaptureBridgeStateAfterResult() {
        pendingCaptureLookupId = nil
        pendingCaptureLookupType = nil
        streamHandshakeLookupId = nil
        lastPolledLookupId = nil
        lastPolledCaptureMode = nil
        lastCaptureAttemptToken = nil
        autoStartedStreamForLookupId = nil
        didAcceptPhotoCaptureRequest = false
    }

    private func decodeBarcodeUPC(from imageData: Data, image: UIImage? = nil) async -> String? {
        await Task.detached(priority: .userInitiated) {
            if let image {
                return BarcodeScanner.decodeUPC(from: image, jpegData: imageData)
            }
            return BarcodeScanner.decodeUPCFromPhotoData(imageData)
        }.value
    }

    /// Tries on-device Vision first, then uploads the photo for server-side Gemini when configured.
    private func uploadBarcodeLookupWithGeminiFallback(
        lookupId: String,
        imageData: Data,
        localImage: UIImage? = nil
    ) async throws -> ImageLookup {
        guard let token else {
            throw APIError(message: "Not logged in.")
        }

        wearablesStatus = "Scanning barcode..."
        let decodedUpc = await decodeBarcodeUPC(from: imageData, image: localImage)

        if let decodedUpc, !decodedUpc.isEmpty {
            wearablesStatus = "Uploading barcode..."
            let response = try await api.uploadImage(
                token: token,
                lookupId: lookupId,
                imageData: imageData,
                upc: decodedUpc
            )
            return response.lookup
        }

        guard hasGeminiApiKey else {
            wearablesStatus = "Uploading photo..."
            let response = try await api.uploadImage(
                token: token,
                lookupId: lookupId,
                imageData: imageData,
                barcodeResult: "not_found"
            )
            return response.lookup
        }

        wearablesStatus = "Asking Gemini..."
        let response = try await api.uploadImage(
            token: token,
            lookupId: lookupId,
            imageData: imageData
        )
        return response.lookup
    }

    private func finishGlassesBarcodeCapture(lookupId: String, imageData: Data, quiet: Bool) async {
        do {
            let lookup = try await uploadBarcodeLookupWithGeminiFallback(
                lookupId: lookupId,
                imageData: imageData
            )
            lastAutoCaptureLookupId = lookupId
            pendingCaptureLookupId = nil
            pendingCaptureLookupType = nil
            activeLookup = lookup
            await recordLookupHistory(source: .metaGlasses, imageData: imageData, lookup: lookup)
            streamHandshakeLookupId = nil
            restoreIdleWearablesStatus()

            if lookup.status == "error", !hasGeminiApiKey {
                showError("Barcode not found on device. Add a Gemini API key in Settings for backup scanning.")
            } else {
                let summary = summarizeLookupResult(lookup)
                if lookup.lookupType == "barcode", lookup.status == "complete" {
                    showMessage("\(summary.title) · \(summary.detail)")
                } else {
                    showMessage(summary.title)
                }
            }
        } catch {
            lastAutoCaptureLookupId = lookupId
            pendingCaptureLookupId = nil
            pendingCaptureLookupType = nil
            historyStore.add(
                source: .metaGlasses,
                imageData: imageData,
                resultSummary: "No UPC found",
                detail: "Barcode lookup failed"
            )
            syncLookupHistory()
            restoreIdleWearablesStatus()
            showError(error.localizedDescription)
        }
    }

    private func isPendingBarcodeCapture() -> Bool {
        if let pendingCaptureLookupType {
            return isBarcodeLookupType(pendingCaptureLookupType)
        }

        guard let activeLookup else { return false }

        if isBarcodeLookupType(activeLookup.lookupType) {
            return true
        }

        return activeLookup.provider == "local"
    }

    private func isBarcodeLookupType(_ value: String?) -> Bool {
        value == "barcode"
    }

    func openMetaAIApp() {
        guard let url = URL(string: "fb-viewapp://") else {
            showError("Could not open Meta AI app URL.")
            return
        }

        UIApplication.shared.open(url)
    }

    func presentMobileImageLookup() {
        showMobileImageCamera = true
    }

    func presentBarcodeLookup() {
        showBarcodeCamera = true
    }

    func syncLookupHistory() {
        lookupHistory = historyStore.entries
    }

    func submitHistoryFeedback(
        entry: LookupHistoryEntry,
        status: String,
        note: String? = nil
    ) async {
        guard let token else {
            showError("Log in before saving feedback.")
            return
        }
        guard let lookupId = entry.lookupId else {
            showError("This local history item is not linked to a server lookup.")
            return
        }

        historyStore.updateFeedback(
            entryId: entry.id,
            status: status,
            correction: note
        )
        syncLookupHistory()

        do {
            let lookup = try await api.submitLookupFeedback(
                token: token,
                lookupId: lookupId,
                status: status,
                note: note
            )
            historyStore.updateFeedback(
                entryId: entry.id,
                status: lookup.feedback?.status ?? status,
                correction: lookup.feedback?.correction ?? note
            )
            syncLookupHistory()
            if activeLookup?.id == lookup.id {
                activeLookup = lookup
            }
            showMessage(status == "correct" ? "Marked correct." : "Marked incorrect. Thanks for helping improve results.")
            if status == "correct" {
                triggerConfetti()
            }
        } catch {
            if let previousStatus = entry.feedbackStatus {
                historyStore.updateFeedback(
                    entryId: entry.id,
                    status: previousStatus,
                    correction: entry.feedbackCorrection
                )
            } else {
                historyStore.clearFeedback(entryId: entry.id)
            }
            syncLookupHistory()
            showError(error.localizedDescription)
        }
    }

    private func triggerConfetti() {
        showConfetti = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            showConfetti = true
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            showConfetti = false
        }
    }

    private func syncLookupFeedbackToHistory(_ lookup: ImageLookup?) {
        guard let lookup, let feedback = lookup.feedback else { return }
        historyStore.updateFeedback(
            lookupId: lookup.id,
            status: feedback.status,
            correction: feedback.correction
        )
        syncLookupHistory()
    }

    func refreshLookupHistoryFeedback() async {
        guard token != nil else { return }
        let lookupIds = Array(Set(historyStore.entries.compactMap(\.lookupId)))
        guard !lookupIds.isEmpty else { return }

        for lookupId in lookupIds.prefix(25) {
            await refreshLookupHistoryFeedback(lookupId: lookupId)
        }
    }

    func refreshLookupHistoryFeedback(lookupId: String) async {
        guard let token else { return }

        do {
            let lookup = try await api.getLookup(token: token, lookupId: lookupId)
            syncLookupFeedbackToHistory(lookup)
            if activeLookup?.id == lookup.id {
                activeLookup = lookup
            }
        } catch {
            return
        }
    }

    func searchCatalogSuggestions(query: String) async throws -> [CatalogSearchItem] {
        guard let token else {
            throw APIError(message: "Not logged in.")
        }

        let response = try await api.searchCatalog(token: token, query: query, limit: 10)
        return response.items
    }

    func performTextLookup(item: CatalogSearchItem) async {
        guard let token else {
            showError("Not logged in.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await api.createTextLookup(token: token, item: item)
            let imageData = await downloadCatalogImageData(from: item.imageUrl) ?? placeholderCatalogImageData()
            let summary = summarizeLookupResult(response.lookup)
            wearablesStatus = "Loading market prices..."
            await recordLookupHistory(source: .text, imageData: imageData, lookup: response.lookup)
            showTextLookup = false
            showMessage(summary.title)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func performMobileImageLookup(image: UIImage) async {
        guard let token else {
            showError("Not logged in.")
            return
        }
        guard let imageData = image.jpegData(compressionQuality: 0.88) else {
            showError("Could not process photo.")
            return
        }

        isBusy = true
        wearablesStatus = "Looking up product..."
        defer {
            isBusy = false
            updateReadyWearablesStatus()
        }

        do {
            let created = try await api.createLookup(token: token, provider: "gemini", mode: "mobile", lookupType: "image")
            let response = try await api.uploadImage(token: token, lookupId: created.lookup.id, imageData: imageData)
            let summary = summarizeLookupResult(response.lookup)
            wearablesStatus = "Loading market prices..."
            await recordLookupHistory(source: .mobile, imageData: imageData, lookup: response.lookup)
            showMessage(summary.title)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func performBarcodeLookup(image: UIImage) async {
        guard let token else {
            showError("Not logged in.")
            return
        }
        guard let imageData = image.jpegData(compressionQuality: 0.88) else {
            showError("Could not process photo.")
            return
        }

        isBusy = true
        wearablesStatus = "Scanning barcode..."
        defer {
            isBusy = false
            updateReadyWearablesStatus()
        }

        do {
            let created = try await api.createLookup(
                token: token,
                provider: "local",
                mode: "mobile",
                lookupType: "barcode"
            )

            let lookup = try await uploadBarcodeLookupWithGeminiFallback(
                lookupId: created.lookup.id,
                imageData: imageData,
                localImage: image
            )
            let summary = summarizeLookupResult(lookup)
            wearablesStatus = "Loading market prices..."
            await recordLookupHistory(source: .mobile, imageData: imageData, lookup: lookup)

            if lookup.status == "error", !hasGeminiApiKey {
                showError("No Code 128 barcode found locally. Add a Gemini API key in Settings for backup scanning.")
            } else if lookup.lookupType == "barcode", lookup.status == "complete" {
                showMessage("\(summary.title) · \(summary.detail)")
            } else {
                showMessage(summary.title)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func barcodeDetectionMethod(for lookup: ImageLookup) -> String {
        guard let notes = lookup.result?.notes?.lowercased() else {
            return "Device scan"
        }

        if notes.contains("gemini") {
            return "Gemini fallback"
        }

        return "Device scan"
    }

    private func summarizeLookupResult(_ lookup: ImageLookup) -> (title: String, detail: String) {
        if lookup.status == "error" {
            return (lookup.error ?? "Lookup failed", lookup.lookupType == "barcode" ? "Barcode lookup error" : "Image lookup error")
        }

        guard let result = lookup.result else {
            return ("Lookup pending", "No result returned yet")
        }

        if lookup.lookupType == "barcode" {
            let upc = result.upc?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? result.sku?.trimmingCharacters(in: .whitespacesAndNewlines)
            let method = barcodeDetectionMethod(for: lookup)
            if let upc, !upc.isEmpty {
                return ("UPC \(upc)", method)
            }
            return ("No UPC found", method)
        }

        if lookup.lookupType == "text" {
            let sku = result.sku?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let brand = result.brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = result.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
            if !sku.isEmpty {
                return ("SKU \(sku)", name.isEmpty ? "Text search" : name)
            }
            return (name.isEmpty ? "Text lookup" : name, "Text search")
        }

        let sku = result.sku?.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = result.brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = result.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")

        if let sku, !sku.isEmpty {
            let accuracy = result.confidence.map { "\(Int($0))% accurate" } ?? ""
            let detail = [name, accuracy].filter { !$0.isEmpty }.joined(separator: " · ")
            return ("SKU \(sku)", detail.isEmpty ? "Gemini image lookup" : detail)
        }

        let detail = [name, result.notes ?? "Gemini image lookup"]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " Â· ")
        return ("SKU Not found", detail)
    }

    private func downloadCatalogImageData(from urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func placeholderCatalogImageData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { context in
            UIColor(white: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    private func recordLookupHistory(source: LookupSource, imageData: Data, lookup: ImageLookup) async {
        let summary = summarizeLookupResult(lookup)
        let marketData = await waitForLookupMarketData(lookupId: lookup.id, initialLookup: lookup)
        historyStore.add(
            source: source,
            imageData: imageData,
            resultSummary: summary.title,
            detail: summary.detail,
            marketData: marketData,
            lookupId: lookup.id,
            lookupType: lookup.lookupType,
            feedbackStatus: lookup.feedback?.status,
            feedbackCorrection: lookup.feedback?.correction
        )
        syncLookupHistory()
    }

    private func waitForLookupMarketData(lookupId: String, initialLookup: ImageLookup) async -> LookupMarketData? {
        guard let token else { return nil }
        guard initialLookup.status == "complete", skuOrUpc(from: initialLookup) != nil else {
            return initialLookup.marketData
        }

        var lookup = initialLookup
        if lookup.marketStatus == "loading" || (lookup.marketData == nil && lookup.marketStatus != "error") {
            for _ in 0..<60 {
                if lookup.marketStatus != "loading", lookup.marketData != nil || lookup.marketStatus == "error" {
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                do {
                    lookup = try await api.getLookup(token: token, lookupId: lookupId)
                } catch {
                    break
                }
            }
        }

        return lookup.marketData
    }

    private func skuOrUpc(from lookup: ImageLookup) -> String? {
        guard let result = lookup.result else { return nil }
        let value = (result.sku ?? result.upc)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func deviceSnapshot(timeoutSeconds: TimeInterval) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask {
                for await devices in Wearables.shared.devicesStream() {
                    return String(describing: devices)
                }
                return "[]"
            }

            group.addTask {
                let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return "timeout (no device update)"
            }

            let first = await group.next() ?? "unknown"
            group.cancelAll()
            return first
        }
    }

    private func waitForKnownDevice(timeoutSeconds: TimeInterval) async -> Bool {
        if !Wearables.shared.devices.isEmpty {
            return true
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await devices in Wearables.shared.devicesStream() {
                    if !devices.isEmpty {
                        return true
                    }
                }
                return false
            }

            group.addTask {
                let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func stopCameraStreamOnly() async {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        stateToken = nil
        frameToken = nil
        photoToken = nil

        let streamToStop = cameraStream
        let sessionToStop = deviceSession

        cameraStream = nil
        deviceSession = nil
        latestFrameJPEGData = nil
        latestFrameUIImage = nil
        hasLiveFrame = false
        previewImage = nil
        castPreviewImage = nil
        streamStateText = "stopping"

        if let streamToStop {
            await streamToStop.stop()
        }

        if let sessionToStop, sessionToStop !== readyDeviceSession, sessionToStop.state == .started {
            try? sessionToStop.removeCapability(MWDATCamera.Stream.self)
            sessionToStop.stop()
        }

        streamStateText = "stopped"
    }

    private func tearDownGlassesCameraImmediately() async {
        await stopCameraStreamOnly()

        let sessionToStop = readyDeviceSession
        readySessionStateTask?.cancel()
        readySessionStateTask = nil
        readyDeviceSession = nil
        UserDefaults.standard.set(false, forKey: datConnectionReadyKey)

        if let sessionToStop, sessionToStop.state == .started {
            try? sessionToStop.removeCapability(MWDATCamera.Stream.self)
            sessionToStop.stop()
        }
    }

    private func stopActiveStreamOnly() async {
        await tearDownGlassesCameraImmediately()
    }

    private func finishGlassesCaptureAfterPhoto() async {
        await tearDownGlassesCameraImmediately()
        autoStartedStreamForLookupId = nil
        wearablesStatus = "Photo captured. Processing on glasses..."
    }

    private func stopGlassesStream() {
        Task { await stopActiveStreamOnly() }
        stopReadyDeviceSession()
        pendingCaptureLookupId = nil
        lastAutoCaptureLookupId = nil
        lastCaptureAttemptToken = nil
        pendingCaptureLookupType = nil
        lastPolledLookupId = nil
        lastPolledCaptureMode = nil
        streamHandshakeLookupId = nil
        isAutoCaptureInFlight = false
    }

    private func startLookupPollingIfNeeded() {
        guard lookupPollTask == nil else { return }

        lookupPollTask = Task { [weak self] in
            await self?.pollLookupAndBridgeCapture()
            await self?.pollCompanionDictation()
            while !(Task.isCancelled) {
                try? await Task.sleep(nanoseconds: self?.lookupPollIntervalNanoseconds ?? 800_000_000)
                await self?.pollLookupAndBridgeCapture()
                await self?.pollCompanionDictation()
            }
        }
    }

    private func stopLookupPolling() {
        lookupPollTask?.cancel()
        lookupPollTask = nil
    }

    private func captureLookupBaselineIfNeeded() {
        guard !hasCapturedStartupBaseline else { return }
        startupBaselineLookupId = activeLookup?.id
        hasCapturedStartupBaseline = true
    }

    private func pollLookupAndBridgeCapture() async {
        guard isMobileSetupComplete else { return }
        guard let token else { return }
        await fetchActiveLookup(token: token, showStatusMessage: false)

        captureLookupBaselineIfNeeded()

        guard let lookup = activeLookup else {
            lastPolledLookupId = nil
            lastPolledCaptureMode = nil
            streamHandshakeLookupId = nil
            autoStartedStreamForLookupId = nil
            return
        }

        // Ignore any lookup that already existed before companion startup/login.
        // This prevents stream auto-start from firing when app opens.
        if lookup.id == startupBaselineLookupId {
            return
        }

        guard lookup.status == "pending" else {
            lastPolledLookupId = nil
            lastPolledCaptureMode = nil
            streamHandshakeLookupId = nil
            autoStartedStreamForLookupId = nil
            return
        }

        let captureMode = lookup.captureMode ?? "stream_pair"
        defer {
            lastPolledLookupId = lookup.id
            lastPolledCaptureMode = captureMode
        }

        if captureMode == "stream_pair" {
            streamHandshakeLookupId = lookup.id
            if isLiveCasting || isLiveCastActive || isStartingLiveCast {
                return
            }
            if cameraStream != nil || isAutoCaptureInFlight {
                await stopCameraStreamOnly()
                isAutoCaptureInFlight = false
                pendingCaptureLookupId = nil
                pendingCaptureLookupType = nil
            }
            restoreIdleWearablesStatus()
            return
        }

        guard captureMode == "capture" else {
            return
        }

        let armedTransition = lastPolledLookupId == lookup.id && lastPolledCaptureMode == "stream_pair"
        let waitingForCapture = streamHandshakeLookupId == lookup.id
        guard armedTransition || waitingForCapture else {
            return
        }

        guard !isAutoCaptureInFlight else { return }
        guard !isLiveCasting, !isLiveCastActive, !isStartingLiveCast else { return }

        let captureAttemptToken = lookupCaptureAttemptToken(lookup)
        if lastCaptureAttemptToken == captureAttemptToken {
            return
        }

        streamHandshakeLookupId = nil
        await performOneShotCapture(for: lookup)
    }

    private func pollCompanionDictation() async {
        guard isMobileSetupComplete else { return }
        guard let token else { return }
        guard !isDictationInFlight else { return }

        do {
            let response = try await api.activeDictation(token: token)
            guard let dictation = response.dictation, dictation.status == "requested" else {
                return
            }

            isDictationInFlight = true
            activeDictationLookupId = dictation.lookupId
            defer {
                isDictationInFlight = false
                activeDictationLookupId = nil
            }

            _ = try await api.markDictationListening(token: token, lookupId: dictation.lookupId)
            wearablesStatus = "Listening for glasses feedback note..."
            showMessage("Speak your feedback note for the glasses.")

            let transcript = try await speechTranscriber.transcribe(maxDurationSeconds: 12)
            let trimmed = transcript.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            if trimmed.isEmpty {
                _ = try await api.completeDictation(
                    token: token,
                    lookupId: dictation.lookupId,
                    error: "No speech detected."
                )
                showMessage("No speech detected for glasses note.")
                restoreIdleWearablesStatus()
                return
            }

            _ = try await api.completeDictation(
                token: token,
                lookupId: dictation.lookupId,
                transcript: trimmed
            )
            showMessage("Sent dictated note to glasses.")
            restoreIdleWearablesStatus()
        } catch {
            if let lookupId = activeDictationLookupId {
                _ = try? await api.completeDictation(
                    token: token,
                    lookupId: lookupId,
                    error: error.localizedDescription
                )
            }
            showError(error.localizedDescription)
            restoreIdleWearablesStatus()
        }
    }

    private func lookupCaptureAttemptToken(_ lookup: ImageLookup) -> String {
        if let updatedAt = lookup.updatedAt, !updatedAt.isEmpty {
            return "\(lookup.id):\(updatedAt)"
        }
        return lookup.id
    }

    private func performOneShotCapture(for lookup: ImageLookup) async {
        guard !isLiveCasting, !isLiveCastActive, !isStartingLiveCast else { return }
        pendingCaptureLookupId = lookup.id
        pendingCaptureLookupType = lookup.lookupType ?? (lookup.provider == "local" ? "barcode" : "image")
        lastCaptureAttemptToken = lookupCaptureAttemptToken(lookup)
        isAutoCaptureInFlight = true
        wearablesStatus = "Snapping photo..."
        beginCompanionBackgroundTask()
        scheduleCaptureWatchdog(
            lookupId: lookup.id,
            captureCode: lookup.captureCode,
            timeoutNanoseconds: 12_000_000_000
        )

        defer {
            if UIApplication.shared.applicationState == .active {
                endCompanionBackgroundTask()
            }
        }

        do {
            let monitor = bluetoothMonitorInstance()
            guard await monitor.waitUntilPoweredOn(timeoutSeconds: 3) else {
                throw APIError(message: "Bluetooth is \(monitor.stateDescription). Turn Bluetooth on and retry Capture.")
            }

            let ready = await ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 20)
            guard ready else {
                throw APIError(message: "Glasses are not ready yet.")
            }

            let photoData = try await capturePhotoFromGlasses()
            await uploadCapturedGlassesImage(photoData, quiet: true)
            lastAutoCaptureLookupId = lookup.id
        } catch {
            pendingCaptureLookupId = nil
            pendingCaptureLookupType = nil
            isAutoCaptureInFlight = false
            await stopCameraStreamOnly()
            autoStartedStreamForLookupId = nil
            updateReadyWearablesStatus()
        }
    }

    private func capturePhotoFromGlasses() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            didAcceptPhotoCaptureRequest = false
            photoCaptureContinuation = continuation

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if let pending = self.photoCaptureContinuation {
                    self.photoCaptureContinuation = nil
                    pending.resume(throwing: APIError(message: "Photo capture timed out."))
                }
            }

            Task { @MainActor in
                do {
                    let hadExistingStream = self.cameraStream != nil
                    if self.cameraStream == nil {
                        try await self.startGlassesStreamForCapture(
                            quiet: true,
                            lookupId: self.pendingCaptureLookupId
                        )
                    }

                    guard let stream = self.cameraStream else {
                        throw APIError(message: "Could not access the glasses camera.")
                    }
                    if hadExistingStream {
                        guard await self.triggerSinglePhotoCapture(on: stream) else {
                            throw APIError(message: "Could not trigger photo capture.")
                        }
                    }
                } catch {
                    if let pending = self.photoCaptureContinuation {
                        self.photoCaptureContinuation = nil
                        pending.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func triggerSinglePhotoCapture(on stream: MWDATCamera.Stream) async -> Bool {
        if didAcceptPhotoCaptureRequest {
            return true
        }

        for _ in 1...4 {
            guard photoCaptureContinuation != nil else { return true }
            if didAcceptPhotoCaptureRequest {
                return true
            }
            if stream.capturePhoto(format: PhotoCaptureFormat.jpeg) {
                didAcceptPhotoCaptureRequest = true
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return false
    }

    private func restoreIdleWearablesStatus() {
        updateReadyWearablesStatus()
    }

    private func requestCaptureWithRetry(
        stream: MWDATCamera.Stream,
        captureCode: String,
        maxAttempts: Int,
        delayNanoseconds: UInt64
    ) async -> Bool {
        let ready = await waitForCaptureReadiness(maxWaitNanoseconds: isAutoCaptureInFlight ? 2_500_000_000 : 4_000_000_000)
        guard ready else {
            if !isAutoCaptureInFlight {
                wearablesStatus = "Stream not ready for capture yet."
            }
            return false
        }

        for attempt in 1...maxAttempts {
            if stream.capturePhoto(format: PhotoCaptureFormat.jpeg) {
                if !isAutoCaptureInFlight {
                    wearablesStatus = "Capturing frame for \(captureCode)..."
                }
                return true
            }

            if !isAutoCaptureInFlight {
                wearablesStatus = "Capture pending (\(attempt)/\(maxAttempts))..."
            }
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        return false
    }

    private func waitForLiveFrame(maxWaitNanoseconds: UInt64) async -> Bool {
        if hasLiveFrame, latestFrameJPEGData != nil {
            return true
        }

        let deadline = Date().addingTimeInterval(Double(maxWaitNanoseconds) / 1_000_000_000.0)
        while Date() < deadline {
            if hasLiveFrame, latestFrameJPEGData != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        return hasLiveFrame && latestFrameJPEGData != nil
    }

    private func uploadLatestFrameFallback(lookupId: String, captureCode: String) async -> Bool {
        guard let frameData = latestFrameJPEGData else {
            return false
        }

        pendingCaptureLookupId = lookupId
        await uploadCapturedGlassesImage(frameData, quiet: true)
        return true
    }

    private func scheduleCaptureWatchdog(
        lookupId: String,
        captureCode: String,
        timeoutNanoseconds: UInt64 = 2_500_000_000
    ) {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)

            guard self.pendingCaptureLookupId == lookupId else { return }
            guard self.isAutoCaptureInFlight else { return }

            self.pendingCaptureLookupId = nil
            self.pendingCaptureLookupType = nil
            self.isAutoCaptureInFlight = false
            self.resetCaptureBridgeStateAfterResult()
            await self.stopCameraStreamOnly()
            self.autoStartedStreamForLookupId = nil
            self.updateReadyWearablesStatus()
        }
    }

    private func waitForCaptureReadiness(maxWaitNanoseconds: UInt64) async -> Bool {
        if hasLiveFrame, latestFrameJPEGData != nil {
            return true
        }

        let deadline = Date().addingTimeInterval(Double(maxWaitNanoseconds) / 1_000_000_000.0)
        while Date() < deadline {
            if hasLiveFrame, latestFrameJPEGData != nil {
                return true
            }
            if streamStateText.contains("started") || streamStateText.contains("streaming") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if hasLiveFrame, latestFrameJPEGData != nil {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return hasLiveFrame && latestFrameJPEGData != nil
    }

    private func ensureBluetoothPoweredOn(actionName: String) async -> Bool {
        let monitor = bluetoothMonitorInstance()
        let ready = await monitor.waitUntilPoweredOn()
        guard ready else {
            showError("Bluetooth is \(monitor.stateDescription). Turn Bluetooth on, then retry \(actionName).")
            return false
        }
        return true
    }

    private func bluetoothMonitorInstance() -> BluetoothStateMonitor {
        if let bluetoothMonitor {
            return bluetoothMonitor
        }
        let monitor = BluetoothStateMonitor()
        bluetoothMonitor = monitor
        return monitor
    }

    private func ensureRegistered(actionName: String) async -> Bool {
        if isRegistrationStateReady(Wearables.shared.registrationState) {
            return true
        }

        if Wearables.shared.registrationState == .registering {
            wearablesStatus = "Finishing Meta AI registration..."
            if await waitForRegistrationReady(timeoutSeconds: 15) {
                refreshWearablesSetupStatus()
                return true
            }
        }

        if await waitForRegistrationReady(timeoutSeconds: 3) {
            refreshWearablesSetupStatus()
            return true
        }

        let currentState = Wearables.shared.registrationState
        if currentState == .available {
            do {
                try await Wearables.shared.startRegistration()
                openMetaAIApp()
                wearablesStatus = "Complete registration in Meta AI, then return here."
                showMessage("Meta AI opened for \(actionName). After approving, return and tap Allow Camera.")
                return false
            } catch RegistrationError.alreadyRegistered {
                if await waitForRegistrationReady(timeoutSeconds: 10) {
                    refreshWearablesSetupStatus()
                    return true
                }
            } catch {
                if isRegistrationStateReady(Wearables.shared.registrationState) {
                    refreshWearablesSetupStatus()
                    return true
                }
                showWearablesError(context: "Registration check", error: error)
                return false
            }
        }

        if currentState == .unavailable {
            showError("Registration is unavailable. Confirm Meta AI is installed and Developer Mode is enabled.")
            return false
        }

        if await waitForRegistrationReady(timeoutSeconds: 8) {
            refreshWearablesSetupStatus()
            return true
        }

        showError("Registration is not ready yet. Approve access in Meta AI, return here, then tap \(actionName) again.")
        return false
    }

    private func waitForRegistrationReady(timeoutSeconds: TimeInterval) async -> Bool {
        if isRegistrationStateReady(Wearables.shared.registrationState) {
            return true
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for await state in Wearables.shared.registrationStateStream() {
                    if self.isRegistrationStateReady(state) {
                        return true
                    }
                }
                return false
            }

            group.addTask { @MainActor in
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while Date() < deadline {
                    if self.isRegistrationStateReady(Wearables.shared.registrationState) {
                        return true
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                return self.isRegistrationStateReady(Wearables.shared.registrationState)
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func startRegistrationMonitoring() {
        guard registrationMonitorTask == nil else { return }

        refreshWearablesSetupStatus()
        startActiveDeviceMonitoring()

        registrationMonitorTask = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                await MainActor.run {
                    self?.handleRegistrationStateChange(state)
                }
            }
        }

        urlHandledObserver = NotificationCenter.default.addObserver(
            forName: .wearablesURLHandled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registrationOpenedAt = nil
                self?.registrationCompletedAt = Date()
                self?.refreshSetupProgress()
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                guard self?.pendingCameraPermissionRetry == true else {
                    self?.refreshSetupProgress()
                    return
                }

                await self?.finishPendingCameraPermissionIfPossible(showStatusMessage: true)
            }
        }
    }

    private func handleRegistrationStateChange(_ state: RegistrationState) {
        switch state {
        case .registered:
            registrationCompletedAt = Date()
            registrationOpenedAt = nil
            wearablesStatus = "Registered with Meta AI."
            Task { await validateCameraPermissionFlag() }
            refreshSetupProgress()
            startActiveDeviceMonitoring()
            if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
                beginGlassesConnectionSetup(showStatus: false)
            }
        case .registering:
            wearablesStatus = "Finishing Meta AI registration..."
        case .available:
            wearablesStatus = "Register the app, allow camera, then pair desktop & glasses."
        case .unavailable:
            wearablesStatus = "Registration unavailable. Check Meta AI and Developer Mode."
        @unknown default:
            break
        }
    }

    private func refreshWearablesSetupStatus() {
        refreshSetupProgress()
    }

    private func updateReadyWearablesStatus() {
        let sessionReady = readyDeviceSession?.state == .started
        if sessionReady {
            wearablesStatus = isLiveCasting ? "Live cast active" : "Glasses ready for capture."
            glassesPreparedForCast = true
        } else if isMobileSetupComplete, UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            wearablesStatus = "Tap Prepare Glasses — keep Meta AI open on phone."
            glassesPreparedForCast = false
        } else if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            wearablesStatus = "Camera access approved."
            glassesPreparedForCast = false
        } else if isRegistrationStateReady(Wearables.shared.registrationState) {
            wearablesStatus = "Registered with Meta AI."
            glassesPreparedForCast = false
        }
        refreshGlassesConnectionStatus()
    }

    private func isRegistrationSyncError(_ error: Error) -> Bool {
        if case RegistrationError.alreadyRegistered = error {
            return true
        }

        let text = error.localizedDescription.lowercased()
        return text.contains("registrationerror")
    }

    private func isRegistrationStateReady(_ state: RegistrationState) -> Bool {
        state == .registered
    }

    private func isRegistrationStateReady(_ stateDescription: String) -> Bool {
        let normalized = stateDescription.lowercased()
        if normalized.contains("unavailable") {
            return false
        }
        if normalized.contains("available") && !normalized.contains("unavailable") {
            return false
        }
        if normalized.contains("registering") {
            return false
        }
        if normalized.contains("registered") {
            return true
        }
        if normalized.contains("rawvalue: 3") || normalized.contains("rawvalue:3") {
            return true
        }
        return false
    }

    private func startGlassesStreamAttempt(
        quiet: Bool = false,
        photoCaptureOnly: Bool = false,
        deviceTimeoutSeconds: TimeInterval = 12
    ) async throws {
        try await ensureCameraPermissionForCapture()

        let monitor = bluetoothMonitorInstance()
        if !monitor.isPoweredOn {
            guard await monitor.waitUntilPoweredOn(timeoutSeconds: 3) else {
                throw APIError(message: "Bluetooth is off. Turn Bluetooth on and retry.")
            }
        }

        if cameraStream != nil {
            await stopActiveStreamOnly()
        }

        let deadline = Date().addingTimeInterval(deviceTimeoutSeconds)
        var lastError: Error = APIError(
            message: "No DAT device detected. Keep Meta AI open and glasses connected, then retry."
        )

        while Date() < deadline {
            do {
                let session = try await getOrCreateStartedSession()
                try await attachCameraStream(to: session, quiet: quiet, photoCaptureOnly: photoCaptureOnly)
                return
            } catch {
                lastError = error
                readyDeviceSession = nil
                await recoverFromDATSetupError(error)
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }

        throw lastError
    }

    private func attachCameraStream(
        to newDeviceSession: DeviceSession,
        quiet: Bool,
        photoCaptureOnly: Bool = false
    ) async throws {
        let stream = try await createCameraStreamWithRetry(
            newDeviceSession,
            photoCaptureOnly: photoCaptureOnly,
            maxAttempts: quiet ? 8 : 10
        )
        hasLiveFrame = false
        latestFrameJPEGData = nil
        latestFrameUIImage = nil
        streamStateText = "starting"

        stateToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                let text = String(describing: state).lowercased()
                self?.streamStateText = text
                guard let self else { return }
                if photoCaptureOnly,
                   self.photoCaptureContinuation != nil,
                   !self.didAcceptPhotoCaptureRequest,
                   (text.contains("streaming") || text.contains("started")) {
                    _ = await self.triggerSinglePhotoCapture(on: stream)
                }

                guard !self.isAutoCaptureInFlight, !quiet else { return }
                self.wearablesStatus = "Stream: \(String(describing: state))"
            }
        }

        frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            guard let image = frame.makeUIImage() else { return }
            Task { @MainActor in
                guard let self else { return }
                self.latestFrameUIImage = image
                let quality: CGFloat = photoCaptureOnly ? 0.92 : 0.85
                self.latestFrameJPEGData = image.jpegData(compressionQuality: quality)
                self.hasLiveFrame = true
                if self.isLiveCastActive {
                    self.castWebRTC.pushGlassesFrame(frame)
                    self.castPreviewImage = image
                }
                if !quiet, !photoCaptureOnly {
                    self.previewImage = image
                }
            }
        }

        photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                guard let self else { return }
                if let continuation = self.photoCaptureContinuation {
                    self.photoCaptureContinuation = nil
                    continuation.resume(returning: photoData.data)
                    return
                }
                guard self.pendingCaptureLookupId != nil || self.isAutoCaptureInFlight else {
                    return
                }
                await self.uploadCapturedGlassesImage(photoData.data, quiet: true)
            }
        }

        deviceSession = newDeviceSession
        cameraStream = stream

        if isLiveCastActive {
            await prepareCastAudioIfNeeded()
        }

        await stream.start()

        if isLiveCastActive {
            wearablesStatus = "Glasses camera active — streaming to desktop…"
        } else if quiet {
            restoreIdleWearablesStatus()
        } else {
            wearablesStatus = "Glasses stream started."
            showMessage("Glasses stream active.")
        }
    }

    private func ensureCameraPermissionForCapture() async throws {
        if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
            return
        }

        if await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: false) {
            return
        }

        let permission = try await Wearables.shared.checkPermissionStatus(.camera)
        if permission == .granted {
            markCameraPermissionGranted(shouldShowMessage: false)
            return
        }

        let requested = try await Wearables.shared.requestPermission(.camera)
        if requested == .granted {
            markCameraPermissionGranted(shouldShowMessage: false)
            return
        }

        throw APIError(message: "Camera access is not granted. Tap Allow Camera and approve in Meta AI first.")
    }

    private func createCameraStreamWithRetry(
        _ session: DeviceSession,
        photoCaptureOnly: Bool = false,
        maxAttempts: Int = 10
    ) async throws -> MWDATCamera.Stream {
        let config = StreamConfiguration(
            videoCodec: VideoCodec.raw,
            resolution: StreamingResolution.low,
            frameRate: 24
        )

        for attempt in 1...maxAttempts {
            if let stream = try? session.addStream(config: config) {
                return stream
            }

            if !isAutoCaptureInFlight {
                wearablesStatus = "Preparing camera stream (\(attempt)/\(maxAttempts))..."
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        throw APIError(
            message: "Could not start camera stream. The glasses session connected but camera capability was not ready yet."
        )
    }

    private func validateDATConfiguration(reportAsError: Bool = true) -> Bool {
        if hasPlaceholderDATCredentials {
            let message = "Using placeholder DAT credentials (MetaAppID=\(datMetaAppID), ClientToken=\(maskedToken(datClientToken))). If registration fails, replace these with values from Meta Wearables Developer Center."
            if reportAsError {
                showMessage(message)
            } else {
                wearablesStatus = message
            }
        }

        return true
    }

    private func isPermissionGranted(_ permissionText: String) -> Bool {
        let normalized = permissionText.lowercased()
        return normalized.contains("authorized")
            || normalized.contains("granted")
            || normalized.contains("allow")
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 8 else { return token }
        return "\(token.prefix(4))...\(token.suffix(4))"
    }

    private func showWearablesError(context: String, error: Error) {
        if case RegistrationError.alreadyRegistered = error {
            wearablesStatus = "Already registered with Meta AI."
            showMessage("Already Registered")
            return
        }

        let value = error.localizedDescription
        if value.contains("PermissionError") {
            if UserDefaults.standard.bool(forKey: cameraPermissionConfirmedKey) {
                markCameraPermissionGranted(shouldShowMessage: true)
                return
            }
            pendingCameraPermissionRetry = true
            Task {
                _ = await resolveCameraPermissionIfAlreadyGranted(shouldShowMessage: true)
            }
            showMessage("Approve camera access in Meta AI, then return here.")
            return
        }
        if value.contains("No eligible device available") {
            if isAutoCaptureInFlight {
                showError("Glasses connection is syncing. Try Capture again in a moment.")
                return
            }
            showError("No eligible device available. In Meta AI, confirm this app is registered and allowed, then retry.")
            return
        }
        showError("\(context) failed: \(value)")
    }

    private func showMessage(_ value: String) {
        isError = false
        message = value
    }

    private func showError(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "cancelled" || normalized == "canceled" || normalized == "cancelled." || normalized == "canceled." {
            return
        }
        isError = true
        message = value
    }

    func ensureRelaySignaling() -> SignalingClient {
        configureCastRelay()
        return relaySignaling
    }

    func finishMobileSetup() {
        UserDefaults.standard.set(true, forKey: mobileSetupCompleteKey)
        UserDefaults.standard.set(false, forKey: mobileSetupPendingRestartKey)
        isError = false
        message = nil
        beginGlassesConnectionSetup(showStatus: false)
        startCastCompanionBridge()
        refreshSetupProgress()
    }

    func configureCastRelay() {
        guard !castRelayConfigured else { return }
        castRelayConfigured = true

        let saved = UserDefaults.standard.string(forKey: "signalingServerURL") ?? Self.defaultSignalingServer
        let url = URL(string: saved.trimmingCharacters(in: .whitespaces))
            ?? URL(string: Self.defaultSignalingServer)!
        relaySignaling = SignalingClient(serverURL: url)
        castWebRTC.attach(signaling: relaySignaling)

        relaySignaling.onStartStream = { [weak self] in
            Task { @MainActor in
                await self?.handleCastStartFromGlasses()
            }
        }
        relaySignaling.onStopStream = { [weak self] in
            Task { @MainActor in
                self?.endLiveCast()
            }
        }
        relaySignaling.onAnswer = { [weak self] sdp, viewerId in
            self?.castWebRTC.handleAnswer(sdp, viewerId: viewerId)
        }
        relaySignaling.onIceCandidate = { [weak self] candidate, idx, mid, viewerId in
            self?.castWebRTC.handleRemoteIce(candidate: candidate, sdpMLineIndex: idx, sdpMid: mid, viewerId: viewerId)
        }
        relaySignaling.onViewerJoined = { [weak self] viewerId in
            Task { @MainActor in
                self?.registerViewerForStream(viewerId)
            }
        }
        relaySignaling.onViewerLeft = { [weak self] viewerId in
            Task { @MainActor in
                self?.pendingViewerIds.remove(viewerId)
                self?.castWebRTC.removeViewer(viewerId: viewerId)
            }
        }
        relaySignaling.onViewerNeedsOffer = { [weak self] viewerId in
            Task { @MainActor in
                self?.refreshViewerStream(viewerId)
            }
        }
        relaySignaling.onGlassesJoined = { [weak self] in
            Task { @MainActor in
                self?.startCastCompanionBridge()
                self?.beginGlassesConnectionSetup(showStatus: false)
            }
        }
        relaySignaling.onGlassesLeft = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Glasses WS can drop while the phone keeps streaming; don't kill the camera.
                if !self.isLiveCasting {
                    return
                }
            }
        }
        relaySignaling.onDesktopJoined = { [weak self] in
            Task { @MainActor in
                self?.registerViewerForStream("legacy-desktop")
            }
        }
    }

    private func refreshViewerStream(_ viewerId: String) {
        guard isLiveCasting, cameraStream != nil else {
            pendingViewerIds.insert(viewerId)
            return
        }
        if castWebRTC.hasViewer(viewerId) { return }
        castWebRTC.prepareFactory()
        castWebRTC.attach(signaling: relaySignaling)
        castWebRTC.setAudioEnabled(CastAudioManager.shared.isPermissionConfirmed)
        castWebRTC.startStream()
        castWebRTC.addViewer(viewerId: viewerId)
    }

    private func registerViewerForStream(_ viewerId: String) {
        if isLiveCasting, cameraStream != nil {
            castWebRTC.prepareFactory()
            castWebRTC.attach(signaling: relaySignaling)
            castWebRTC.setAudioEnabled(CastAudioManager.shared.isPermissionConfirmed)
            castWebRTC.startStream()
            castWebRTC.addViewer(viewerId: viewerId)
        } else {
            pendingViewerIds.insert(viewerId)
        }
    }

    private func connectAllViewers() {
        castWebRTC.prepareFactory()
        castWebRTC.attach(signaling: relaySignaling)
        castWebRTC.setAudioEnabled(CastAudioManager.shared.isPermissionConfirmed)
        castWebRTC.startStream()
        var ids = Set(pendingViewerIds)
        for viewer in relaySignaling.viewerRoster {
            ids.insert(viewer.id)
        }
        for viewerId in ids {
            if !castWebRTC.hasViewer(viewerId) {
                castWebRTC.addViewer(viewerId: viewerId)
            }
        }
        pendingViewerIds.removeAll()
    }

    private func connectPendingViewers() {
        connectAllViewers()
    }

    /// Same device session + camera path as image lookup capture, but keeps video streaming.
    private func startContinuousGlassesStreamForCast() async throws {
        guard validateDATConfiguration() else {
            throw APIError(message: "Meta wearables configuration is invalid.")
        }

        wearablesStatus = "Turning on glasses camera…"
        relaySignaling?.status = "Turning on glasses camera…"
        beginCompanionBackgroundTask()

        let monitor = bluetoothMonitorInstance()
        guard await monitor.waitUntilPoweredOn(timeoutSeconds: 3) else {
            throw APIError(message: "Bluetooth is off. Turn Bluetooth on and retry.")
        }

        if readyDeviceSession?.state != .started {
            guard await ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 15) else {
                throw APIError(message: "No eligible device available.")
            }
        }
        glassesPreparedForCast = true

        if cameraStream != nil {
            wearablesStatus = "Glasses camera already active."
            return
        }

        do {
            try await startGlassesStreamAttempt(
                quiet: true,
                photoCaptureOnly: false,
                deviceTimeoutSeconds: 20
            )
        } catch {
            if error.localizedDescription.contains("No eligible device available")
                || error.localizedDescription.contains("No DAT device") {
                wearablesStatus = "Re-syncing with Meta AI, then retrying camera…"
                openMetaAIApp()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                readyDeviceSession = nil
                guard await ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 20) else {
                    throw error
                }
                try await startGlassesStreamAttempt(
                    quiet: true,
                    photoCaptureOnly: false,
                    deviceTimeoutSeconds: 20
                )
                return
            }

            if error.localizedDescription.contains("XPC connection invalid") {
                await stopCameraStreamOnly()
                readyDeviceSession = nil
                wearablesStatus = "DAT connection dropped. Retrying camera…"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard await ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 20) else {
                    throw error
                }
                try await startGlassesStreamAttempt(
                    quiet: true,
                    photoCaptureOnly: false,
                    deviceTimeoutSeconds: 20
                )
                return
            }

            throw error
        }
    }

    private func beginDesktopStreamIfReady() {
        guard isLiveCasting, cameraStream != nil else { return }
        connectPendingViewers()
        if relaySignaling.viewerCount > 0 || relaySignaling.desktopLinked {
            relaySignaling.status = "Live casting — tap Stop when done"
        }
    }

    func startCastRelayIfNeeded() {
        guard isMobileSetupComplete else { return }
        configureCastRelay()
        castWebRTC.prepareFactory()
        if !relaySignaling.connected {
            relaySignaling.connect()
        }
        scheduleDATPrepareIfNeeded(delayNanoseconds: 0)
    }

    func restartCastRelay() {
        endLiveCast()
        relaySignaling?.disconnectAndClearSession()
        startCastRelayIfNeeded()
    }

    func copyPairingCode() {
        UIPasteboard.general.string = relaySignaling?.code ?? "------"
        showMessage("Copied pairing code.")
    }

    func prepareGlassesForCast() async {
        isBusy = true
        defer { isBusy = false }

        configureCastRelay()
        wearablesStatus = "Preparing glasses — same path as image lookup…"
        relaySignaling?.status = "Preparing glasses…"
        startActiveDeviceMonitoring()
        beginGlassesConnectionSetup(showStatus: true)

        let ready = await ensureReadyDeviceSession(showStatus: true, timeoutSeconds: 60)
        glassesPreparedForCast = ready
        if ready {
            relaySignaling?.status = "Glasses ready — tap Start Live Cast"
            showMessage("Glasses ready. Live Stream on glasses or Start Live Cast here.")
        } else {
            relaySignaling?.status = "Glasses not ready — tap Prepare Glasses"
            showError("Could not connect to glasses. Keep View Caster open, then tap Prepare Glasses again.")
        }
        updateReadyWearablesStatus()
    }

    func handleCastStartFromGlasses() async {
        configureCastRelay()
        relaySignaling.sendSignal(type: "stream-starting")
        wakeCastFromGlasses()
        await performLiveCast(triggeredByGlasses: true)
    }

    func userStartLiveCast() async {
        configureCastRelay()
        relaySignaling.sendSignal(type: "stream-starting")
        await performLiveCast(triggeredByGlasses: false)
    }

    func wipeLiveChat() {
        relaySignaling?.clearLiveChat()
    }

    func userStopLiveCast() {
        relaySignaling?.sendSignal(type: "stop-stream")
        endLiveCast()
    }

    func beginLiveCastFromSignaling() async {
        await handleCastStartFromGlasses()
    }

    private func performLiveCast(triggeredByGlasses: Bool) async {
        if isLiveCasting || isStartingLiveCast {
            return
        }

        castTask?.cancel()
        isStartingLiveCast = true
        isLiveCastActive = true

        castTask = Task { @MainActor in
            defer {
                isStartingLiveCast = false
                castTask = nil
            }

            configureCastRelay()
            relaySignaling.status = "Turning on glasses camera…"

            guard await ensureBluetoothPoweredOn(actionName: "Live Stream") else {
                relaySignaling.sendSignal(type: "stream-error", payload: ["message": "Bluetooth is off"])
                endLiveCast()
                return
            }

            if !isRegistrationStateReady(Wearables.shared.registrationState) {
                guard await ensureRegistered(actionName: "Live Stream") else {
                    relaySignaling.sendSignal(type: "stream-error", payload: ["message": "Not registered with Meta AI"])
                    endLiveCast()
                    return
                }
            }

            do {
                relaySignaling.sendSignal(type: "stream-starting")
                beginCompanionBackgroundTask()

                try await startContinuousGlassesStreamForCast()
                isLiveCasting = true
                let audioRoute = CastAudioManager.shared.isPermissionConfirmed
                    ? CastAudioManager.shared.activeRouteDescription()
                    : ""
                wearablesStatus = audioRoute.isEmpty
                    ? "Glasses camera active — streaming…"
                    : "Glasses camera active — audio via \(audioRoute)"

                beginDesktopStreamIfReady()

                relaySignaling.sendSignal(type: "stream-started", payload: ["source": "glasses"])
                relaySignaling.status = "Live casting — tap Stop when done"

                while !Task.isCancelled && isLiveCastActive && cameraStream != nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                let msg = error.localizedDescription
                relaySignaling.sendSignal(type: "stream-error", payload: ["message": msg])
                relaySignaling.status = msg
                showError("Live stream failed: \(msg)")
                endLiveCast()
            }
        }

        await castTask?.value
    }

    func endLiveCast() {
        isLiveCastActive = false
        isLiveCasting = false
        isStartingLiveCast = false
        castTask?.cancel()
        castTask = nil
        castPreviewImage = nil
        castWebRTC.setAudioEnabled(false)
        CastAudioManager.shared.teardown()
        Task { await stopCameraStreamOnly() }
        castWebRTC.stopStream()
        relaySignaling?.status = relaySignaling?.connected == true
            ? "Enter this code on desktop & glasses"
            : "Offline"
        updateReadyWearablesStatus()
    }
}

struct MetaCloudAPI {
    private let baseURL = URL(string: "https://meta-cloud-meta-cloud.up.railway.app")!
    private let aliasHostURL = URL(string: "https://bypass-alias-host-railway-alias.up.railway.app")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    func login(email: String, password: String) async throws -> AuthResponse {
        var request = URLRequest(url: baseURL.appending(path: "/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "email": email,
            "password": password
        ])

        return try await send(request)
    }

    func activeLookup(token: String) async throws -> ActiveLookupResponse {
        var request = URLRequest(url: baseURL.appending(path: "/lookups/companion/active"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    func activeDictation(token: String) async throws -> ActiveDictationResponse {
        var request = URLRequest(url: baseURL.appending(path: "/lookups/companion/dictation/active"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    func markDictationListening(token: String, lookupId: String) async throws -> DictationResponse {
        var request = URLRequest(url: baseURL.appending(path: "/lookups/\(lookupId)/dictation/listening"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    func completeDictation(
        token: String,
        lookupId: String,
        transcript: String? = nil,
        error: String? = nil
    ) async throws -> DictationResponse {
        var request = URLRequest(url: baseURL.appending(path: "/lookups/\(lookupId)/dictation/complete"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [:]
        if let transcript {
            body["transcript"] = transcript
        }
        if let error {
            body["error"] = error
        }
        request.httpBody = try JSONEncoder().encode(body)

        return try await send(request)
    }

    func createLookup(
        token: String,
        provider: String = "gemini",
        mode: String = "capture",
        lookupType: String = "image"
    ) async throws -> LookupResponse {
        var request = URLRequest(url: baseURL.appending(path: "/lookups"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "provider": provider,
            "mode": mode,
            "type": lookupType,
        ])

        return try await send(request)
    }

    func uploadImage(
        token: String,
        lookupId: String,
        imageData: Data,
        upc: String? = nil,
        barcodeResult: String? = nil
    ) async throws -> LookupResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "/lookups/\(lookupId)/image"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var extraFields: [String: String] = [:]
        if let upc, !upc.isEmpty {
            extraFields["upc"] = upc
        }
        if let barcodeResult, !barcodeResult.isEmpty {
            extraFields["barcodeResult"] = barcodeResult
        }

        request.httpBody = multipartBody(
            boundary: boundary,
            fieldName: "image",
            fileName: "glasses-photo.jpg",
            mimeType: "image/jpeg",
            data: imageData,
            extraFields: extraFields
        )

        return try await send(request)
    }

    func listApiKeys(token: String) async throws -> ApiKeysListResponse {
        var request = URLRequest(url: baseURL.appending(path: "/api-keys"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    func saveApiKey(token: String, provider: String, apiKey: String, label: String? = nil) async throws -> SaveApiKeyResponse {
        var request = URLRequest(url: baseURL.appending(path: "/api-keys"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "provider": provider,
            "apiKey": apiKey
        ]
        if let label {
            body["label"] = label
        }
        request.httpBody = try JSONEncoder().encode(body)

        return try await send(request)
    }

    func deleteApiKey(token: String, provider: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api-keys/\(provider)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        try await sendNoContent(request)
    }

    func getLookup(token: String, lookupId: String) async throws -> ImageLookup {
        var request = URLRequest(url: baseURL.appending(path: "/lookups/\(lookupId)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let response: LookupDetailResponse = try await send(request)
        return response.lookup
    }

    func searchCatalog(token: String, query: String, limit: Int = 10) async throws -> CatalogSearchResponse {
        var components = URLComponents(url: baseURL.appending(path: "/lookups/catalog/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        guard let url = components?.url else {
            throw APIError(message: "Invalid catalog search URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    func createTextLookup(token: String, item: CatalogSearchItem) async throws -> LookupResponse {
        var request = URLRequest(url: baseURL.appending(path: "/lookups/text"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "sku": item.sku,
            "name": item.name,
            "brand": item.brand,
        ]
        if let imageUrl = item.imageUrl {
            body["imageUrl"] = imageUrl
        }
        request.httpBody = try JSONEncoder().encode(body)

        return try await send(request)
    }

    func submitLookupFeedback(
        token: String,
        lookupId: String,
        status: String,
        note: String?
    ) async throws -> ImageLookup {
        var request = URLRequest(url: baseURL.appending(path: "/lookups/\(lookupId)/feedback"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "status": status,
            "note": note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            "correction": note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ])

        let response: LookupDetailResponse = try await send(request)
        return response.lookup
    }

    func getAliasIntegration(token: String) async throws -> IntegrationResponse {
        var request = URLRequest(url: baseURL.appending(path: "/integrations/alias"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    func loginAliasAccount(email: String, password: String) async throws {
        var request = URLRequest(url: aliasHostURL.appending(path: "/alias-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "email": email,
            "password": password,
        ])

        let (data, response) = try await Self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError(message: "Invalid Alias login response.")
        }

        if (200..<300).contains(httpResponse.statusCode) {
            return
        }

        let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw APIError(message: detail?.isEmpty == false ? "Alias login failed: \(detail!)" : "Alias login failed.")
    }

    func saveAliasIntegration(token: String, email: String, password: String, apiKey: String) async throws -> IntegrationResponse {
        var request = URLRequest(url: baseURL.appending(path: "/integrations/alias"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "email": email,
            "password": password,
            "apiKey": apiKey,
        ])

        return try await send(request)
    }

    func deleteAliasIntegration(token: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/integrations/alias"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        try await sendNoContent(request)
    }

    func getStockXIntegration(token: String) async throws -> IntegrationResponse {
        var request = URLRequest(url: baseURL.appending(path: "/integrations/stockx"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    func saveStockXIntegration(
        token: String,
        email: String,
        apiKey: String,
        clientId: String,
        clientSecret: String
    ) async throws -> IntegrationResponse {
        var request = URLRequest(url: baseURL.appending(path: "/integrations/stockx"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "email": email,
            "apiKey": apiKey,
            "clientId": clientId,
            "clientSecret": clientSecret,
        ])

        return try await send(request)
    }

    func deleteStockXIntegration(token: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/integrations/stockx"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        try await sendNoContent(request)
    }

    func startStockXOAuth(token: String) async throws -> StockXOAuthStartResponse {
        var request = URLRequest(url: baseURL.appending(path: "/integrations/stockx/oauth/start"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await Self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError(message: "Invalid server response.")
        }

        if (200..<300).contains(httpResponse.statusCode) {
            return try JSONDecoder.api.decode(T.self, from: data)
        }

        let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        throw APIError(message: errorResponse?.error ?? "Request failed with status \(httpResponse.statusCode).")
    }

    private func sendNoContent(_ request: URLRequest) async throws {
        let (data, response) = try await Self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError(message: "Invalid server response.")
        }

        if httpResponse.statusCode == 204 {
            return
        }

        let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        throw APIError(message: errorResponse?.error ?? "Request failed with status \(httpResponse.statusCode).")
    }

    private func multipartBody(
        boundary: String,
        fieldName: String,
        fileName: String,
        mimeType: String,
        data: Data,
        extraFields: [String: String] = [:]
    ) -> Data {
        var body = Data()

        for (key, value) in extraFields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }
}

struct AuthResponse: Decodable {
    let user: User
    let session: Session
}

struct ActiveLookupResponse: Decodable {
    let lookup: ImageLookup?
}

struct ActiveDictationResponse: Decodable {
    let dictation: ActiveDictationRequest?
}

struct ActiveDictationRequest: Decodable {
    let lookupId: String
    let status: String
    let updatedAt: String?
}

struct DictationResponse: Decodable {
    let dictation: DictationSession
}

struct DictationSession: Decodable {
    let lookupId: String
    let status: String
    let transcript: String?
    let error: String?
    let updatedAt: String?
}

struct LookupResponse: Decodable {
    let lookup: ImageLookup
}

struct LookupDetailResponse: Decodable {
    let lookup: ImageLookup
}

struct IntegrationResponse: Decodable {
    let integration: IntegrationStatus
}

struct StockXOAuthStartResponse: Decodable {
    let authUrl: String
    let redirectUri: String
}

struct ApiKeysListResponse: Decodable {
    let apiKeys: [StoredApiKey]
}

struct SaveApiKeyResponse: Decodable {
    let apiKey: StoredApiKey
}

struct StoredApiKey: Decodable {
    let id: String
    let provider: String
    let label: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct User: Decodable {
    let id: String
    let email: String
}

struct Session: Decodable {
    let token: String
    let expiresAt: String
}

struct CatalogSearchItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let sku: String
    let brand: String
    let imageUrl: String?
}

struct CatalogSearchResponse: Decodable {
    let items: [CatalogSearchItem]
}

struct ImageLookup: Decodable {
    let id: String
    let captureCode: String
    let captureMode: String?
    let provider: String?
    let lookupType: String?
    let status: String
    let result: LookupResult?
    let error: String?
    let marketStatus: String?
    let marketData: LookupMarketData?
    let feedback: LookupFeedback?
    let updatedAt: String?
}

struct LookupFeedback: Decodable {
    let status: String
    let correction: String?
    let createdAt: String?
    let updatedAt: String?
}

struct LookupResult: Decodable {
    let sku: String?
    let upc: String?
    let brand: String?
    let model: String?
    let colorway: String?
    let confidence: Double?
    let notes: String?
}

struct ErrorResponse: Decodable {
    let error: String
}

struct APIError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct SafariAuthView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension JSONDecoder {
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }
}

extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

extension View {
    func cardStyle() -> some View {
        padding(18)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
    }

    func fieldStyle() -> some View {
        padding(14)
            .foregroundStyle(.white)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .textInputAutocapitalization(.never)
    }
}

struct CompactSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .foregroundStyle(Color.white)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .foregroundStyle(Color.white)
            .background(
                isEnabled ? Color.green.opacity(0.72) : Color.gray.opacity(0.42),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .foregroundStyle(Color.white)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .foregroundStyle(Color.white)
            .background(Color.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

enum CompanionSpeechTranscriberError: LocalizedError {
    case unavailable
    case permissionDenied
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Speech recognition is unavailable on this device."
        case .permissionDenied:
            return "Microphone or speech recognition permission was denied."
        case .noSpeechDetected:
            return "No speech detected."
        }
    }
}

final class CompanionSpeechTranscriber {
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func transcribe(maxDurationSeconds: TimeInterval) async throws -> String {
        try await ensurePermissions()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw CompanionSpeechTranscriberError.unavailable
        }

        cleanup()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        return try await withCheckedThrowingContinuation { continuation in
            let audioEngine = AVAudioEngine()
            self.audioEngine = audioEngine

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.recognitionRequest = request

            var hasResumed = false
            var bestTranscript = ""

            func resumeOnce(returning value: String) {
                guard !hasResumed else { return }
                hasResumed = true
                cleanup()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                continuation.resume(returning: value)
            }

            func resumeOnce(throwing error: Error) {
                guard !hasResumed else { return }
                hasResumed = true
                cleanup()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                continuation.resume(throwing: error)
            }

            self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    bestTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        let trimmed = bestTranscript.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            resumeOnce(throwing: CompanionSpeechTranscriberError.noSpeechDetected)
                        } else {
                            resumeOnce(returning: trimmed)
                        }
                    }
                    return
                }

                if let error {
                    let trimmed = bestTranscript.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        resumeOnce(throwing: error)
                    } else {
                        resumeOnce(returning: trimmed)
                    }
                }
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                resumeOnce(throwing: error)
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(maxDurationSeconds * 1_000_000_000))
                request.endAudio()
                try? await Task.sleep(nanoseconds: 900_000_000)

                if hasResumed {
                    return
                }

                let trimmed = bestTranscript.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if trimmed.isEmpty {
                    resumeOnce(throwing: CompanionSpeechTranscriberError.noSpeechDetected)
                } else {
                    resumeOnce(returning: trimmed)
                }
            }
        }
    }

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    private func ensurePermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            throw CompanionSpeechTranscriberError.permissionDenied
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            throw CompanionSpeechTranscriberError.permissionDenied
        }
    }
}
