import Foundation
import UshotCore

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
        try AppEnvironment(
            entitlementProvider: OpenSourceEntitlementProvider(),
            updateChecker: NoOpUpdateChecker(),
            settingsStore: SettingsStore(defaults: settingsDefaults()),
            permissionChecker: SystemCapturePermissionChecker(),
            launchAtLoginManager: SystemLaunchAtLoginManager(),
            hotKeyManager: CarbonGlobalHotKeyManager(),
            capturer: ScreenCaptureKitCapturer(),
            pixelSamplerFactory: ScreenCaptureKitPixelSamplerFactory(),
            historyStore: try SystemScreenshotHistoryStore.applicationSupportStore(
                bundleIdentifier: "com.example.UshotApp"
            )
        )
    }

    private static func settingsDefaults() -> UserDefaults {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isUITestLaunch = arguments.contains { $0.hasPrefix("--uitest-") }
        guard isUITestLaunch else { return .standard }
        guard let suiteName = ProcessInfo.processInfo.environment[
            "USHOT_UI_TEST_SETTINGS_SUITE"
        ], !suiteName.isEmpty else {
            preconditionFailure("UI tests must provide an isolated settings suite.")
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("The isolated UI-test settings suite could not be created.")
        }
        AppLog.lifecycle.debug("Using an isolated settings suite for UI testing")
        return defaults
#else
        return .standard
#endif
    }
}
