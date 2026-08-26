import Foundation

public enum ProductIdentity {
    public struct RuntimeIdentity: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case production
            case debug
        }

        public let kind: Kind
        public let bundleIdentifier: String
        public let applicationSupportDirectoryName: String

        public var isProduction: Bool {
            kind == .production
        }

        private init(kind: Kind, bundleIdentifier: String) {
            self.kind = kind
            self.bundleIdentifier = bundleIdentifier
            self.applicationSupportDirectoryName = bundleIdentifier
        }

        fileprivate static let production = RuntimeIdentity(
            kind: .production,
            bundleIdentifier: ProductIdentity.bundleIdentifier
        )
        fileprivate static let debug = RuntimeIdentity(
            kind: .debug,
            bundleIdentifier: ProductIdentity.debugBundleIdentifier
        )
    }

    public static let name = "Ushot"
    public static let bundleIdentifier = "io.github.ischeneycc.ushot"
    public static let debugBundleIdentifier = "\(bundleIdentifier).debug"
    public static let legacyBundleIdentifier = "com.example.UshotApp"
    public static let settingsStorageKey = "\(bundleIdentifier).settings"
    public static let legacySettingsStorageKey = "\(legacyBundleIdentifier).settings"
    public static let applicationSupportDirectoryName = bundleIdentifier
    public static let legacyApplicationSupportDirectoryName = legacyBundleIdentifier
    public static let legacyHistoryMigrationMarkerKey =
        "\(bundleIdentifier).history-migration-from-legacy.v1"
    public static let updateFeedURLString =
        "https://ischeneycc.github.io/ushot/updates/v1/appcast.xml"
    public static let sparklePublicEDKey =
        "+zRL11/2yYePt5O+OetThnLGwyvAvFtPPXxiBBOTTjE="

    public static func runtimeIdentity(
        forBundleIdentifier bundleIdentifier: String
    ) -> RuntimeIdentity? {
        switch bundleIdentifier {
        case Self.bundleIdentifier:
            return .production
        case debugBundleIdentifier:
            return .debug
        default:
            return nil
        }
    }
}
