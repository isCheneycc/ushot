import Combine
import Foundation

@MainActor
public final class SettingsStore: ObservableObject {
    public nonisolated static let storageKey = "com.example.UshotApp.settings"

    @Published public private(set) var settings: AppSettings
    @Published public private(set) var loadError: ScreenshotAppError?

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = SettingsStore.storageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.sortedKeys]

        guard let data = defaults.data(forKey: storageKey) else {
            self.settings = .defaults
            self.loadError = nil
            return
        }

        do {
            self.settings = try Self.decodeAndMigrate(data: data, decoder: decoder)
            self.loadError = nil
        } catch {
            self.settings = .defaults
            self.loadError = .settingsCorrupted(description: error.localizedDescription)
            AppLog.lifecycle.fault("Settings decoding failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func update<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>, to value: Value) throws {
        var candidate = settings
        candidate[keyPath: keyPath] = value
        try persist(candidate)
    }

    public func update(_ mutation: (inout AppSettings) -> Void) throws {
        var candidate = settings
        mutation(&candidate)
        try persist(candidate)
    }

    public func replace(with candidate: AppSettings) throws {
        try persist(candidate)
    }

    public func reset() throws {
        try persist(.defaults)
    }

    public func clearLoadError() {
        loadError = nil
    }

    private func persist(_ candidate: AppSettings) throws {
        do {
            var validated = candidate
            _ = try validated.shortcuts.validatingUniqueAssignments()
            validated.editor = try validated.editor.validatedColorPalette()
            let data = try encoder.encode(validated)
            defaults.set(data, forKey: storageKey)
            settings = validated
            loadError = nil
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            let wrapped = ScreenshotAppError.settingsPersistenceFailed(description: error.localizedDescription)
            AppLog.lifecycle.error("Settings encoding failed: \(error.localizedDescription, privacy: .public)")
            throw wrapped
        }
    }

    private static func decodeAndMigrate(data: Data, decoder: JSONDecoder) throws -> AppSettings {
        let decoded = try decoder.decode(AppSettings.self, from: data)
        guard decoded.schemaVersion <= AppSettings.currentSchemaVersion else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "Unsupported schema version \(decoded.schemaVersion)."
            )
        }

        var migrated: AppSettings
        switch decoded.schemaVersion {
        case AppSettings.currentSchemaVersion:
            migrated = decoded
        case 1, 2, 3, 4, 5, 6, 7, 8:
            var upgraded = decoded
            let legacyDefaults = [
                upgraded.editor.defaultColorHex,
                upgraded.editor.defaultTextColorHex,
                upgraded.editor.defaultRectangleColorHex,
                upgraded.editor.defaultEllipseColorHex
            ]
            for value in legacyDefaults {
                if let legacyDefault = AnnotationColorPalette.normalizedHex(value),
                   !upgraded.editor.toolbarColorHexes.contains(legacyDefault) {
                    upgraded.editor.toolbarColorHexes.append(legacyDefault)
                }
            }
            AppLog.lifecycle.notice(
                "Migrated settings schema: from=\(decoded.schemaVersion, privacy: .public), to=\(AppSettings.currentSchemaVersion, privacy: .public), toolbarColorCount=\(upgraded.editor.toolbarColorHexes.count, privacy: .public)"
            )
            upgraded.schemaVersion = AppSettings.currentSchemaVersion
            migrated = upgraded
        default:
            throw ScreenshotAppError.settingsCorrupted(
                description: "No migration exists for schema version \(decoded.schemaVersion)."
            )
        }
        _ = try migrated.shortcuts.validatingUniqueAssignments()
        migrated.editor = try migrated.editor.validatedColorPalette()
        return migrated
    }
}
