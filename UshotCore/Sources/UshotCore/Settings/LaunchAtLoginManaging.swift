import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: String, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
public protocol LaunchAtLoginManaging: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ isEnabled: Bool) throws
    func openSystemSettings()
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
