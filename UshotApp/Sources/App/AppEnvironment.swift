import Foundation
import UshotCore

private enum AppEnvironmentConfigurationError: Error, LocalizedError {
    case bundleIdentifierMismatch(actual: String?)
    case invalidLegacySettingsValue

    var errorDescription: String? {
        switch self {
        case .bundleIdentifierMismatch:
            return String(localized: "Ushot could not verify its application identity.")
        case .invalidLegacySettingsValue:
            return String(localized: "The previous Ushot settings are damaged and could not be migrated.")
        }
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    let entitlementProvider: any FeatureEntitlementChecking
    let updateChecker: any UpdateChecking
    let settingsStore: SettingsStore
    let permissionChecker: any CapturePermissionChecking
    let launchAtLoginManager: any LaunchAtLoginManaging
    let hotKeyManager: any GlobalHotKeyManaging
    let capturer: any ScreenCapturing
    let pixelSamplerFactory: any PixelSamplerCreating
    let historyStore: any ScreenshotHistoryStoring

    init(
        entitlementProvider: any FeatureEntitlementChecking,
        updateChecker: any UpdateChecking,
        settingsStore: SettingsStore,
        permissionChecker: any CapturePermissionChecking,
        launchAtLoginManager: any LaunchAtLoginManaging,
        hotKeyManager: any GlobalHotKeyManaging,
        capturer: any ScreenCapturing,
        pixelSamplerFactory: any PixelSamplerCreating,
        historyStore: any ScreenshotHistoryStoring
    ) {
        self.entitlementProvider = entitlementProvider
        self.updateChecker = updateChecker
        self.settingsStore = settingsStore
        self.permissionChecker = permissionChecker
        self.launchAtLoginManager = launchAtLoginManager
        self.hotKeyManager = hotKeyManager
        self.capturer = capturer
        self.pixelSamplerFactory = pixelSamplerFactory
        self.historyStore = historyStore
    }

    static func live() throws -> AppEnvironment {
        let actualBundleIdentifier = Bundle.main.bundleIdentifier
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isUITestLaunch = arguments.contains { $0.hasPrefix("--uitest-") }
        let isolatedTestBundleIdentifiers = [
            "\(ProductIdentity.bundleIdentifier).tests",
            "\(ProductIdentity.bundleIdentifier).uitests"
        ]
        let usesExplicitUITestIdentity = isUITestLaunch
            && actualBundleIdentifier.map(isolatedTestBundleIdentifiers.contains) == true
        guard
            actualBundleIdentifier == ProductIdentity.bundleIdentifier
                || usesExplicitUITestIdentity
        else {
            let error = AppEnvironmentConfigurationError.bundleIdentifierMismatch(
                actual: actualBundleIdentifier
            )
            AppLog.lifecycle.fault(
                "Application identity mismatch: expected=\(ProductIdentity.bundleIdentifier, privacy: .public), actual=\(actualBundleIdentifier ?? "missing", privacy: .public), explicitUITest=\(isUITestLaunch, privacy: .public)"
            )
            throw error
        }
        if usesExplicitUITestIdentity {
            AppLog.lifecycle.notice(
                "Accepted isolated UI-test application identity: identifier=\(actualBundleIdentifier ?? "missing", privacy: .public)"
            )
        }
#else
        guard actualBundleIdentifier == ProductIdentity.bundleIdentifier else {
            let error = AppEnvironmentConfigurationError.bundleIdentifierMismatch(
                actual: actualBundleIdentifier
            )
            AppLog.lifecycle.fault(
                "Release application identity mismatch: expected=\(ProductIdentity.bundleIdentifier, privacy: .public), actual=\(actualBundleIdentifier ?? "missing", privacy: .public)"
            )
            throw error
        }
#endif

        let settingsConfiguration = settingsDefaults()
        if settingsConfiguration.migratesLegacyDomain {
            try migrateLegacySettingsIfNeeded(into: settingsConfiguration.defaults)
            try migrateLegacyHistoryIfNeeded(using: settingsConfiguration.defaults)
        }

        let settingsStore = SettingsStore(defaults: settingsConfiguration.defaults)
        let launchAtLoginManager = SystemLaunchAtLoginManager()
        if settingsConfiguration.migratesLegacyDomain {
            let launchAtLoginResult = try launchAtLoginManager.reconcile(
                desiredEnabled: settingsStore.settings.general.launchesAtLogin
            )
            AppLog.lifecycle.notice(
                "Reconciled launch-at-login service after identity admission: result=\(String(describing: launchAtLoginResult), privacy: .public)"
            )
        } else {
            AppLog.lifecycle.debug(
                "Skipped launch-at-login reconciliation for an isolated UI-test identity"
            )
        }

        return try AppEnvironment(
            entitlementProvider: OpenSourceEntitlementProvider(),
            updateChecker: SparkleUpdateChecker.makeFailClosed(),
            settingsStore: settingsStore,
            permissionChecker: SystemCapturePermissionChecker(),
            launchAtLoginManager: launchAtLoginManager,
            hotKeyManager: CarbonGlobalHotKeyManager(),
            capturer: ScreenCaptureKitCapturer(),
            pixelSamplerFactory: ScreenCaptureKitPixelSamplerFactory(),
            historyStore: try SystemScreenshotHistoryStore.applicationSupportStore(
                bundleIdentifier: ProductIdentity.applicationSupportDirectoryName
            )
        )
    }

    private static func settingsDefaults() -> (
        defaults: UserDefaults,
        migratesLegacyDomain: Bool
    ) {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isUITestLaunch = arguments.contains { $0.hasPrefix("--uitest-") }
        guard isUITestLaunch else { return (.standard, true) }
        guard let suiteName = ProcessInfo.processInfo.environment[
            "USHOT_UI_TEST_SETTINGS_SUITE"
        ], !suiteName.isEmpty else {
            preconditionFailure("UI tests must provide an isolated settings suite.")
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("The isolated UI-test settings suite could not be created.")
        }
        AppLog.lifecycle.debug("Using an isolated settings suite for UI testing")
        return (defaults, false)
#else
        return (.standard, true)
#endif
    }

    private static func migrateLegacySettingsIfNeeded(into defaults: UserDefaults) throws {
        guard defaults.object(forKey: SettingsStore.storageKey) == nil else {
            AppLog.lifecycle.debug(
                "Skipped legacy settings migration because the current settings key already exists"
            )
            return
        }
        guard let legacyDefaults = UserDefaults(
            suiteName: ProductIdentity.legacyBundleIdentifier
        ) else {
            preconditionFailure("The legacy preferences domain could not be opened.")
        }
        guard let legacyValue = legacyDefaults.object(
            forKey: SettingsStore.legacyStorageKey
        ) else {
            return
        }
        guard let legacyData = legacyValue as? Data else {
            AppLog.lifecycle.fault(
                "Legacy settings migration failed because the stored value is not data"
            )
            throw AppEnvironmentConfigurationError.invalidLegacySettingsValue
        }

        let validatedLegacyStore = SettingsStore(
            defaults: legacyDefaults,
            storageKey: SettingsStore.legacyStorageKey
        )
        if let loadError = validatedLegacyStore.loadError {
            AppLog.lifecycle.fault(
                "Legacy settings migration rejected a decoding failure: error=\(loadError.localizedDescription, privacy: .public)"
            )
            throw loadError
        }

        defaults.set(legacyData, forKey: SettingsStore.storageKey)
        AppLog.lifecycle.notice(
            "Migrated legacy settings domain without removing the recoverable source value"
        )
    }

    private static func migrateLegacyHistoryIfNeeded(using defaults: UserDefaults) throws {
        guard !defaults.bool(forKey: ProductIdentity.legacyHistoryMigrationMarkerKey) else {
            AppLog.lifecycle.debug("Skipped completed legacy history migration")
            return
        }

        let result = try SystemScreenshotHistoryStore.migrateApplicationSupportHistory(
            fromBundleIdentifier: ProductIdentity.legacyApplicationSupportDirectoryName,
            toBundleIdentifier: ProductIdentity.applicationSupportDirectoryName
        )
        defaults.set(true, forKey: ProductIdentity.legacyHistoryMigrationMarkerKey)
        AppLog.lifecycle.notice(
            "Completed recoverable legacy history migration: copied=\(result.copiedItemCount, privacy: .public), identical=\(result.identicalItemCount, privacy: .public), sourcePreserved=true"
        )
    }
}
