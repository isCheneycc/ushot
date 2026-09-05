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
    @Published var isTerminating = false
    let runtimeIdentity: ProductIdentity.RuntimeIdentity
    let updateChecker: any UpdateChecking
    let settingsStore: SettingsStore
    let permissionChecker: any CapturePermissionChecking
    let launchAtLoginManager: any LaunchAtLoginManaging
    let hotKeyManager: any GlobalHotKeyManaging
    let capturer: any ScreenCapturing
    let pixelSamplerFactory: any PixelSamplerCreating
    let historyStore: any ScreenshotHistoryStoring
    var onRequestLanguageChange: (@MainActor (AppLanguagePreference, () throws -> Void) throws -> Void)?
    var onClearHistory: (@MainActor () async throws -> Void)?

    func requestLanguageChange(
        to language: AppLanguagePreference,
        applying change: () throws -> Void
    ) throws {
        guard let onRequestLanguageChange else {
            throw UpdateCheckError.unavailable(
                reason: String(localized: "Ushot cannot change language before its lifecycle coordinator is ready.")
            )
        }
        try onRequestLanguageChange(language, change)
    }

    func clearHistory() async throws {
        guard let onClearHistory else {
            throw UpdateCheckError.unavailable(
                reason: String(localized: "Ushot cannot clear history before its lifecycle coordinator is ready.")
            )
        }
        try await onClearHistory()
    }

    init(
        runtimeIdentity: ProductIdentity.RuntimeIdentity,
        updateChecker: any UpdateChecking,
        settingsStore: SettingsStore,
        permissionChecker: any CapturePermissionChecking,
        launchAtLoginManager: any LaunchAtLoginManaging,
        hotKeyManager: any GlobalHotKeyManaging,
        capturer: any ScreenCapturing,
        pixelSamplerFactory: any PixelSamplerCreating,
        historyStore: any ScreenshotHistoryStoring
    ) {
        self.runtimeIdentity = runtimeIdentity
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
        guard
            let actualBundleIdentifier,
            let runtimeIdentity = ProductIdentity.runtimeIdentity(
                forBundleIdentifier: actualBundleIdentifier
            )
        else {
            let error = AppEnvironmentConfigurationError.bundleIdentifierMismatch(
                actual: actualBundleIdentifier
            )
            AppLog.lifecycle.fault(
                "Application identity is unsupported: actual=\(actualBundleIdentifier ?? "missing", privacy: .public)"
            )
            throw error
        }
#if DEBUG
        guard runtimeIdentity.kind == .debug else {
            let error = AppEnvironmentConfigurationError.bundleIdentifierMismatch(
                actual: actualBundleIdentifier
            )
            AppLog.lifecycle.fault(
                "Debug application identity mismatch: expected=\(ProductIdentity.debugBundleIdentifier, privacy: .public), actual=\(actualBundleIdentifier, privacy: .public)"
            )
            throw error
        }
#else
        guard runtimeIdentity.kind == .production else {
            let error = AppEnvironmentConfigurationError.bundleIdentifierMismatch(
                actual: actualBundleIdentifier
            )
            AppLog.lifecycle.fault(
                "Release application identity mismatch: expected=\(ProductIdentity.bundleIdentifier, privacy: .public), actual=\(actualBundleIdentifier, privacy: .public)"
            )
            throw error
        }
#endif
        AppLog.lifecycle.notice(
            "Admitted application runtime identity: kind=\(String(describing: runtimeIdentity.kind), privacy: .public), identifier=\(runtimeIdentity.bundleIdentifier, privacy: .public)"
        )

        let settingsConfiguration = settingsDefaults(for: runtimeIdentity)
        if settingsConfiguration.migratesLegacyDomain {
            try migrateLegacySettingsIfNeeded(
                into: settingsConfiguration.defaults,
                runtimeIdentity: runtimeIdentity
            )
            try migrateLegacyHistoryIfNeeded(
                using: settingsConfiguration.defaults,
                runtimeIdentity: runtimeIdentity
            )
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
                "Skipped production launch-at-login reconciliation for runtime identifier=\(runtimeIdentity.bundleIdentifier, privacy: .public)"
            )
        }

        return try AppEnvironment(
            runtimeIdentity: runtimeIdentity,
            updateChecker: SparkleUpdateChecker.makeFailClosed(),
            settingsStore: settingsStore,
            permissionChecker: SystemCapturePermissionChecker(),
            launchAtLoginManager: launchAtLoginManager,
            hotKeyManager: CarbonGlobalHotKeyManager(),
            capturer: ScreenCaptureKitCapturer(),
            pixelSamplerFactory: ScreenCaptureKitPixelSamplerFactory(),
            historyStore: try SystemScreenshotHistoryStore.applicationSupportStore(
                bundleIdentifier: runtimeIdentity.applicationSupportDirectoryName
            )
        )
    }

    private static func settingsDefaults(
        for runtimeIdentity: ProductIdentity.RuntimeIdentity
    ) -> (
        defaults: UserDefaults,
        migratesLegacyDomain: Bool
    ) {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isUITestLaunch = arguments.contains { $0.hasPrefix("--uitest-") }
        if isUITestLaunch {
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
        }

        // Identity admission above guarantees that `.standard` resolves to the
        // Debug bundle's own persistent domain, never the production domain.
        AppLog.lifecycle.debug(
            "Using Debug settings domain: identifier=\(runtimeIdentity.bundleIdentifier, privacy: .public)"
        )
        return (.standard, false)
#else
        return (.standard, true)
#endif
    }

    private static func migrateLegacySettingsIfNeeded(
        into defaults: UserDefaults,
        runtimeIdentity: ProductIdentity.RuntimeIdentity
    ) throws {
        precondition(
            runtimeIdentity.isProduction,
            "Legacy settings migration is valid only for the production identity."
        )
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

    private static func migrateLegacyHistoryIfNeeded(
        using defaults: UserDefaults,
        runtimeIdentity: ProductIdentity.RuntimeIdentity
    ) throws {
        precondition(
            runtimeIdentity.isProduction,
            "Legacy history migration is valid only for the production identity."
        )
        guard !defaults.bool(forKey: ProductIdentity.legacyHistoryMigrationMarkerKey) else {
            AppLog.lifecycle.debug("Skipped completed legacy history migration")
            return
        }

        let result = try SystemScreenshotHistoryStore.migrateApplicationSupportHistory(
            fromBundleIdentifier: ProductIdentity.legacyApplicationSupportDirectoryName,
            toBundleIdentifier: runtimeIdentity.applicationSupportDirectoryName
        )
        defaults.set(true, forKey: ProductIdentity.legacyHistoryMigrationMarkerKey)
        AppLog.lifecycle.notice(
            "Completed recoverable legacy history migration: copied=\(result.copiedItemCount, privacy: .public), identical=\(result.identicalItemCount, privacy: .public), sourcePreserved=true"
        )
    }
}
