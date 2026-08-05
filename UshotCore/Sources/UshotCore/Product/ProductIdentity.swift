import Foundation

public enum ProductIdentity {
    public static let name = "Ushot"
    public static let bundleIdentifier = "io.github.ischeneycc.ushot"
    public static let legacyBundleIdentifier = "com.example.UshotApp"
    public static let settingsStorageKey = "\(bundleIdentifier).settings"
    public static let legacySettingsStorageKey = "\(legacyBundleIdentifier).settings"
    public static let applicationSupportDirectoryName = bundleIdentifier
    public static let legacyApplicationSupportDirectoryName = legacyBundleIdentifier
    public static let legacyHistoryMigrationMarkerKey =
        "\(bundleIdentifier).history-migration-from-legacy.v1"
    public static let updateFeedURLString =
        "https://ischeneycc.github.io/ushot/updates/appcast.xml"
    public static let sparklePublicEDKey =
        "gdZAswkBeWYGYjpqCUmtrUEuyIc/RP5DO+c5I7h+h3Q="
}
