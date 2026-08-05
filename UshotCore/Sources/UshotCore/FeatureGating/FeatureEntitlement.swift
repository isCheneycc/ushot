import Foundation

public enum AppFeature: String, Codable, CaseIterable, Sendable {
    case basicCapture
    case quickAnnotation
    case canvasEditor
    case colorPicker
    case ruler
    case scrollingCapture
    case screenRecording
    case gifExport
}

public protocol FeatureEntitlementChecking: Sendable {
    func isEntitled(to feature: AppFeature) -> Bool
}

public struct OpenSourceEntitlementProvider: FeatureEntitlementChecking {
    public init() {}

    public func isEntitled(to feature: AppFeature) -> Bool {
        true
    }
}
