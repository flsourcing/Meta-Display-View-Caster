import CoreBluetooth
import Foundation

/// Matches Bypass Market Checker — waits for Bluetooth before Meta camera permission.
@MainActor
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

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    var isPoweredOn: Bool {
        central.state == .poweredOn
    }

    var stateDescription: String {
        switch central.state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "powered off"
        case .poweredOn: return "powered on"
        @unknown default: return "unknown"
        }
    }

    func waitUntilPoweredOn(timeoutSeconds: TimeInterval = 6) async -> Bool {
        if isPoweredOn { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isPoweredOn { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isPoweredOn
    }
}
