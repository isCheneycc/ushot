import SwiftUI
import UshotCore

@main
struct UshotApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Apply the stored Advanced language before any UI reads
        // NSLocalizedString / String(localized:). Default is Simplified Chinese.
        let language = AppLanguagePreference.loadStoredPreference()
        AppLanguagePreference.apply(language)
        AppLog.lifecycle.notice(
            "Applied in-app language preference at launch: language=\(language.rawValue, privacy: .public)"
        )
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
