import Foundation

enum SetupItemStatus: Equatable {
    case waiting
    case success
}

actor RegistrationWaitGate {
    private(set) var isFinished = false
    private(set) var result = false

    func finish(_ value: Bool) {
        guard !isFinished else { return }
        isFinished = true
        result = value
    }
}
