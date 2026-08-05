import Foundation

public struct UpdateCheckResult: Equatable, Sendable {
    public let isUpdateAvailable: Bool
    public let version: String?

    public init(isUpdateAvailable: Bool, version: String?) {
        self.isUpdateAvailable = isUpdateAvailable
        self.version = version
    }
}

public protocol UpdateChecking: Sendable {
    func checkForUpdates() async throws -> UpdateCheckResult
}

public struct NoOpUpdateChecker: UpdateChecking {
    public init() {}

    public func checkForUpdates() async throws -> UpdateCheckResult {
        UpdateCheckResult(isUpdateAvailable: false, version: nil)
    }
}
