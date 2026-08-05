import CoreGraphics
import Foundation

public enum CapturePermissionStatus: String, Equatable, Sendable {
    case authorized
    case notAuthorized
}

public protocol CapturePermissionChecking: Sendable {
    func authorizationStatus() async -> CapturePermissionStatus
    func requestAccess() async -> CapturePermissionStatus
}

public struct SystemCapturePermissionChecker: CapturePermissionChecking {
    public init() {}

    public func authorizationStatus() async -> CapturePermissionStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .notAuthorized
    }

    public func requestAccess() async -> CapturePermissionStatus {
        CGRequestScreenCaptureAccess() ? .authorized : .notAuthorized
    }
}
