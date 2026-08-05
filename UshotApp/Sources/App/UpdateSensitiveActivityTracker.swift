import Foundation
import UshotCore

/// Owns short-lived background work that must finish before Sparkle may
/// replace and relaunch the application.
@MainActor
final class UpdateSensitiveActivityTracker {
    struct Lease: Sendable {
        fileprivate let id: UUID
        fileprivate let ownerID: UUID
        fileprivate let operation: String
    }

    private let ownerID = UUID()
    private var operations: [UUID: String] = [:]

    var hasActiveWork: Bool { !operations.isEmpty }
    var activeOperationCount: Int { operations.count }

    func begin(operation: String) -> Lease {
        precondition(!operation.isEmpty, "An update-sensitive operation must have a diagnostic name.")
        let lease = Lease(id: UUID(), ownerID: ownerID, operation: operation)
        let previous = operations.updateValue(operation, forKey: lease.id)
        precondition(previous == nil, "An update-sensitive lease identifier must be unique.")
        AppLog.updates.debug(
            "Began update-sensitive activity: operation=\(operation, privacy: .public), active=\(self.operations.count, privacy: .public)"
        )
        return lease
    }

    func finish(_ lease: Lease) {
        precondition(
            lease.ownerID == ownerID,
            "An update-sensitive lease must be released by the tracker that issued it."
        )
        guard let operation = operations.removeValue(forKey: lease.id) else {
            preconditionFailure("An update-sensitive lease cannot be released more than once.")
        }
        precondition(
            operation == lease.operation,
            "An update-sensitive lease operation cannot change during its lifetime."
        )
        AppLog.updates.debug(
            "Finished update-sensitive activity: operation=\(operation, privacy: .public), active=\(self.operations.count, privacy: .public)"
        )
    }
}
