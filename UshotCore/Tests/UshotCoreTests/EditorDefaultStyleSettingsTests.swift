import Foundation
import Testing
@testable import UshotCore

@MainActor
struct EditorDefaultStyleSettingsTests {
    @Test
    func factoryDefaultsPreserveSystemFontAndFilledArrow() {
        let editor = EditorSettings()
        #expect(editor.defaultTextFontName == nil)
        #expect(editor.defaultArrowHeadStyle == .filled)
    }

    @Test(arguments: ArrowHeadStyle.allCases)
    func selectedDefaultsSurviveReload(style: ArrowHeadStyle) throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let store = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        try store.update { settings in
            settings.editor.defaultTextFontName = AnnotationFonts.handwrittenFontName
            settings.editor.defaultArrowHeadStyle = style
            settings.capture.automaticallyCopies = true
            settings.advanced.language = .english
        }

        let reloaded = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        #expect(reloaded.loadError == nil)
        #expect(reloaded.settings == store.settings)
        #expect(reloaded.settings.editor.defaultTextFontName == AnnotationFonts.handwrittenFontName)
        #expect(reloaded.settings.editor.defaultArrowHeadStyle == style)
        let persisted = try #require(fixture.defaults.data(forKey: fixture.key))
        let object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        let editor = try #require(object["editor"] as? [String: Any])
        #expect(editor["defaultArrowHeadStyle"] as? String == style.rawValue)

        try reloaded.update(\AppSettings.editor.defaultTextFontName, to: nil)
        let restoredSystem = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        #expect(restoredSystem.loadError == nil)
        #expect(restoredSystem.settings.editor.defaultTextFontName == nil)
        #expect(restoredSystem.settings.editor.defaultArrowHeadStyle == style)
    }

    @Test(arguments: Array(1...12))
    func legacyMissingArrowStyleKeepsExistingPreferences(schema: Int) throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        var legacy = AppSettings.defaults
        legacy.schemaVersion = schema
        legacy.editor.defaultTextFontName = "Helvetica"
        legacy.editor.defaultFontSize = 22
        legacy.editor.defaultLineWidth = 5.5
        legacy.colorPicker.freezesScreen = false
        legacy.capture.automaticallyCopies = true
        legacy.advanced.language = .english
        let data = try settingsData(legacy) { editor in
            editor.removeValue(forKey: "defaultArrowHeadStyle")
        }
        fixture.defaults.set(data, forKey: fixture.key)

        let store = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        var expected = legacy
        expected.schemaVersion = AppSettings.currentSchemaVersion
        #expect(store.loadError == nil)
        #expect(store.settings == expected)
        #expect(store.settings.editor.defaultArrowHeadStyle == .filled)

        try store.update(\AppSettings.editor.defaultArrowHeadStyle, to: .handDrawn)
        let reloaded = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        #expect(reloaded.loadError == nil)
        #expect(reloaded.settings.schemaVersion == AppSettings.currentSchemaVersion)
        #expect(reloaded.settings.editor.defaultArrowHeadStyle == .handDrawn)
        #expect(reloaded.settings.editor.defaultTextFontName == "Helvetica")
    }

    @Test(arguments: ArrowHeadStyle.allCases)
    func legacyExplicitArrowStyleIsPreserved(style: ArrowHeadStyle) throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        var legacy = AppSettings.defaults
        legacy.schemaVersion = 12
        legacy.editor.defaultArrowHeadStyle = style
        legacy.editor.defaultTextFontName = "Helvetica"
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: fixture.key)

        let store = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        #expect(store.loadError == nil)
        #expect(store.settings.editor.defaultArrowHeadStyle == style)
        #expect(store.settings.editor.defaultTextFontName == "Helvetica")
    }

    enum InvalidArrowStyle: CaseIterable, Sendable {
        case missing, null, unknown, wrongType
    }

    @Test(arguments: InvalidArrowStyle.allCases)
    func invalidCurrentArrowStyleRemainsObservable(value: InvalidArrowStyle) throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let data = try settingsData(.defaults) { editor in
            switch value {
            case .missing: editor.removeValue(forKey: "defaultArrowHeadStyle")
            case .null: editor["defaultArrowHeadStyle"] = NSNull()
            case .unknown: editor["defaultArrowHeadStyle"] = "future-arrow-style"
            case .wrongType: editor["defaultArrowHeadStyle"] = 17
            }
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppSettings.self, from: data)
        }
        fixture.defaults.set(data, forKey: fixture.key)
        let store = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        #expect(store.loadError != nil)
        #expect(fixture.defaults.data(forKey: fixture.key) == data)
    }

    @Test
    func restoringEditorDefaultsPreservesOtherSettings() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let store = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        try store.update { settings in
            settings.editor.defaultTextFontName = AnnotationFonts.handwrittenFontName
            settings.editor.defaultArrowHeadStyle = .handDrawn
            settings.capture.automaticallyCopies = true
            settings.colorPicker.freezesScreen = false
            settings.advanced.language = .english
        }
        var expected = store.settings
        expected.editor = EditorSettings()

        try store.update(\AppSettings.editor, to: EditorSettings())
        let reloaded = SettingsStore(defaults: fixture.defaults, storageKey: fixture.key)
        #expect(reloaded.loadError == nil)
        #expect(reloaded.settings == expected)
    }

    private func settingsData(
        _ settings: AppSettings,
        edit: (inout [String: Any]) -> Void
    ) throws -> Data {
        let data = try JSONEncoder().encode(settings)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var editor = try #require(object["editor"] as? [String: Any])
        edit(&editor)
        object["editor"] = editor
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, key: String, suite: String) {
        let suite = "UshotCoreTests.DefaultStyles.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, "settings", suite)
    }
}
