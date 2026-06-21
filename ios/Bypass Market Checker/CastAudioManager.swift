import AVFoundation
import Foundation

enum CastAudioError: LocalizedError {
    case permissionRequired
    case hfpUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Microphone permission is required for live cast audio."
        case .hfpUnavailable:
            return "Could not route audio from glasses. Check Bluetooth and try again."
        }
    }
}

@MainActor
final class CastAudioManager {
    static let shared = CastAudioManager()
    static let permissionConfirmedKey = "datAudioPermissionConfirmed"

    private(set) var isPrepared = false

    var isPermissionConfirmed: Bool {
        UserDefaults.standard.bool(forKey: Self.permissionConfirmedKey)
    }

    func markPermissionGranted() {
        UserDefaults.standard.set(true, forKey: Self.permissionConfirmedKey)
    }

    func clearPermissionFlag() {
        UserDefaults.standard.set(false, forKey: Self.permissionConfirmedKey)
    }

    func requestMicrophonePermission() async -> Bool {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
        if granted {
            markPermissionGranted()
        }
        return granted
    }

    func validatePermissionFlag() async -> Bool {
        guard isPermissionConfirmed else { return false }
        let granted = await currentRecordPermissionGranted()
        if !granted {
            clearPermissionFlag()
        }
        return granted
    }

    func currentRecordPermissionGranted() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied, .undetermined:
                return false
            @unknown default:
                return false
            }
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    /// Configure Bluetooth HFP before starting the DAT camera stream (Meta DAT ordering).
    func prepareForLiveCast() async throws {
        guard isPermissionConfirmed else {
            throw CastAudioError.permissionRequired
        }
        guard await currentRecordPermissionGranted() else {
            clearPermissionFlag()
            throw CastAudioError.permissionRequired
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        _ = await waitForPreferredInputRoute(timeoutSeconds: 4)
        isPrepared = true
    }

    func waitForPreferredInputRoute(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if hasGlassesAudioRoute() {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return hasGlassesAudioRoute()
    }

    func hasGlassesAudioRoute() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        for input in route.inputs {
            switch input.portType {
            case .bluetoothHFP, .bluetoothA2DP, .headsetMic:
                return true
            default:
                if input.portName.localizedCaseInsensitiveContains("meta")
                    || input.portName.localizedCaseInsensitiveContains("glasses")
                    || input.portName.localizedCaseInsensitiveContains("ray-ban") {
                    return true
                }
            }
        }
        return route.inputs.contains { $0.portType == .builtInMic }
    }

    func activeRouteDescription() -> String {
        AVAudioSession.sharedInstance().currentRoute.inputs
            .map(\.portName)
            .joined(separator: ", ")
    }

    func teardown() {
        isPrepared = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
