import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: String, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public enum LaunchAtLoginReconciliationResult: Equatable, Sendable {
    case unchanged(status: LaunchAtLoginStatus)
    case updated(status: LaunchAtLoginStatus)
}

@MainActor
public protocol LaunchAtLoginManaging: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ isEnabled: Bool) throws
    func openSystemSettings()
}

public extension LaunchAtLoginManaging {
    func reconcile(desiredEnabled: Bool) throws -> LaunchAtLoginReconciliationResult {
        let initialStatus = status
        let alreadyMatches = desiredEnabled
            ? initialStatus == .enabled || initialStatus == .requiresApproval
            : initialStatus == .notRegistered || initialStatus == .notFound
        guard !alreadyMatches else {
            return .unchanged(status: initialStatus)
        }

        try setEnabled(desiredEnabled)
        let finalStatus = status
        let finalMatches = desiredEnabled
            ? finalStatus == .enabled || finalStatus == .requiresApproval
            : finalStatus == .notRegistered || finalStatus == .notFound
        guard finalMatches else {
            throw ScreenshotAppError.launchAtLoginFailed(
                description: "The login-item service remained \(finalStatus.rawValue) after reconciliation."
            )
        }
        return .updated(status: finalStatus)
    }
}

@MainActor
public final class SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func setEnabled(_ isEnabled: Bool) throws {
        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            AppLog.lifecycle.error("Launch-at-login update failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotAppError.launchAtLoginFailed(description: error.localizedDescription)
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
