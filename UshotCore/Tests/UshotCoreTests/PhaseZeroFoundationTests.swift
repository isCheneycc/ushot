#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
import AppKit
import Carbon
import Combine
import Foundation
import CoreGraphics
import CoreText
import ImageIO
@testable import UshotCore

@MainActor
private final class FakeHotKeyBackend: HotKeySystemRegistering {
    var onAction: ((HotKeyAction) -> Void)?
    var registrations: [UInt32: HotKeyShortcut] = [:]
    var failOnceForAction: HotKeyAction?

    func register(action: HotKeyAction, shortcut: HotKeyShortcut) throws -> UInt32 {
        if failOnceForAction == action {
            failOnceForAction = nil
            throw ScreenshotAppError.shortcutConflict(action: action, status: -9878)
        }
        registrations[action.rawValue] = shortcut
        return action.rawValue
    }

    func unregister(token: UInt32) throws {
        registrations[token] = nil
    }
}

private enum HotKeyTestSupport {
    static let modifiersWithUnknownBit = HotKeyModifiers(
        rawValue: HotKeyModifiers.command.rawValue | (UInt32(1) << 31)
    )
}

private enum SettingsTestSupport {
    static func makeDefaults() -> (defaults: UserDefaults, key: String, suite: String) {
        let suite = "UshotCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, "settings", suite)
    }

    static func legacyVersionOneData() throws -> Data {
        let legacy = AppSettings(schemaVersion: 1)
        let encoded = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var general = object["general"] as? [String: Any],
              var editor = object["editor"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a version-one settings document."
            )
        }
        general["startupBehavior"] = nil
        editor["defaultLineWidthUnit"] = nil
        editor["defaultRectangleCornerRadius"] = nil
        object["general"] = general
        object["editor"] = editor
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func legacyVersionTwoData() throws -> Data {
        let legacy = AppSettings(schemaVersion: 2)
        let encoded = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var editor = object["editor"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a version-two settings document."
            )
        }
        editor["defaultLineWidthUnit"] = nil
        editor["defaultRectangleCornerRadius"] = nil
        object["editor"] = editor
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func legacyVersionThreeData() throws -> Data {
        let legacy = AppSettings(schemaVersion: 3)
        let encoded = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var editor = object["editor"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a version-three settings document."
            )
        }
        editor["defaultLineWidthUnit"] = nil
        object["editor"] = editor
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func legacyVersionFourData() throws -> Data {
        let legacy = AppSettings(schemaVersion: 4)
        let encoded = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var shortcuts = object["shortcuts"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a version-four settings document."
            )
        }
        shortcuts["annotationToolAssignments"] = nil
        object["shortcuts"] = shortcuts
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func legacyVersionFiveData(usesSpotlightDefaultForRectangle: Bool = false) throws -> Data {
        let legacy = AppSettings(
            schemaVersion: 5,
            editor: EditorSettings(defaultColorHex: "#123456")
        )
        let encoded = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var editor = object["editor"] as? [String: Any],
              var shortcuts = object["shortcuts"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a version-five settings document."
            )
        }
        editor["customColorHexes"] = nil
        let replacementShortcut = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(HotKeyShortcut(keyCode: 33, modifiers: []))
        )
        if var assignments = shortcuts["annotationToolAssignments"] as? [String: Any] {
            assignments[AnnotationTool.spotlight.rawValue] = nil
            if usesSpotlightDefaultForRectangle {
                assignments[AnnotationTool.rectangle.rawValue] = replacementShortcut
            }
            shortcuts["annotationToolAssignments"] = assignments
        } else if var assignments = shortcuts["annotationToolAssignments"] as? [Any] {
            var index = 0
            while index + 1 < assignments.count {
                guard let tool = assignments[index] as? String else {
                    throw ScreenshotAppError.settingsCorrupted(
                        description: "The legacy annotation shortcut key is not a string."
                    )
                }
                if tool == AnnotationTool.spotlight.rawValue {
                    assignments.removeSubrange(index...(index + 1))
                    continue
                }
                if usesSpotlightDefaultForRectangle,
                   tool == AnnotationTool.rectangle.rawValue
                {
                    assignments[index + 1] = replacementShortcut
                }
                index += 2
            }
            shortcuts["annotationToolAssignments"] = assignments
        } else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not decode legacy annotation shortcuts."
            )
        }
        object["editor"] = editor
        object["shortcuts"] = shortcuts
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func legacyVersionSixData() throws -> Data {
        let legacy = AppSettings(
            schemaVersion: 6,
            editor: EditorSettings(defaultColorHex: "#123456")
        )
        let encoded = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var capture = object["capture"] as? [String: Any],
              var editor = object["editor"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a version-six settings document."
            )
        }
        capture["recognizesInterfaceElements"] = nil
        editor["defaultTextColorHex"] = nil
        editor["defaultRectangleColorHex"] = nil
        editor["defaultEllipseColorHex"] = nil
        editor["defaultTextFontName"] = nil
        object["capture"] = capture
        object["editor"] = editor
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func legacyVersionSevenData() throws -> Data {
        let legacy = AppSettings(
            schemaVersion: 7,
            editor: EditorSettings(defaultLineWidthUnit: .points)
        )
        let encoded = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var editor = object["editor"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a version-seven settings document."
            )
        }
        editor["defaultFontSizeUnit"] = nil
        editor["defaultRectangleCornerRadiusUnit"] = nil
        object["editor"] = editor
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func legacyVersionEightData() throws -> Data {
        let legacyCustomColors = ["#12ABEF", "#654321"]
        let legacy = AppSettings(
            schemaVersion: 8,
            editor: EditorSettings(
                defaultColorHex: legacyCustomColors[0],
                toolbarColorHexes: AnnotationColorPalette.factoryDefaultHexColors
                    + legacyCustomColors
            )
        )
        let encoded = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var editor = object["editor"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a version-eight settings document."
            )
        }
        editor["toolbarColorHexes"] = nil
        editor["customColorHexes"] = legacyCustomColors
        object["editor"] = editor
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func currentVersionDataWithoutToolbarColors(explicitNull: Bool) throws -> Data {
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var editor = object["editor"] as? [String: Any]
        else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "The test could not construct a malformed current settings document."
            )
        }
        editor["toolbarColorHexes"] = explicitNull ? NSNull() : nil
        object["editor"] = editor
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private enum ImageTestSupport {
    static func verticallyAsymmetricImage(width: Int = 20, height: Int = 20) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return context.makeImage()!
    }

    static func rgbaBytes(for image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func redRectangleStrokeThicknesses(
        in image: CGImage
    ) -> (horizontal: CGFloat, vertical: CGFloat) {
        let bytes = rgbaBytes(for: image)
        var redBounds = CGRect.null
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let isDominantRed = bytes[offset] > 20
                    && bytes[offset] > bytes[offset + 1] * 2
                    && bytes[offset] > bytes[offset + 2] * 2
                guard isDominantRed else { continue }
                redBounds = redBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        precondition(!redBounds.isNull, "The rectangle fixture must contain a visible red stroke.")
        let centerX = Int(redBounds.midX.rounded(.down))
        let centerY = Int(redBounds.midY.rounded(.down))
        let horizontalCoverage = (0..<image.height).reduce(CGFloat.zero) { result, y in
            let offset = (y * image.width + centerX) * 4
            return result + CGFloat(bytes[offset]) / 255
        }
        let verticalCoverage = (0..<image.width).reduce(CGFloat.zero) { result, x in
            let offset = (centerY * image.width + x) * 4
            return result + CGFloat(bytes[offset]) / 255
        }
        return (
            horizontal: horizontalCoverage / 2,
            vertical: verticalCoverage / 2
        )
    }

    static func displayCapture(
        id: CGDirectDisplayID,
        frame: CGRect,
        scale: CGFloat,
        red: CGFloat
    ) -> DisplayCapture {
        let width = Int(frame.width * scale)
        let height = Int(frame.height * scale)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return displayCapture(id: id, frame: frame, scale: scale, image: image)
    }

    static func displayCapture(
        id: CGDirectDisplayID,
        frame: CGRect,
        scale: CGFloat,
        image: CGImage
    ) -> DisplayCapture {
        let width = Int(frame.width * scale)
        let height = Int(frame.height * scale)
        precondition(
            image.width == width && image.height == height,
            "The display fixture image must match its declared backing geometry."
        )
        let descriptor = DisplayDescriptor(
            id: id,
            name: "Display \(id)",
            frame: frame,
            pixelSize: CGSize(width: width, height: height),
            scale: scale,
            isCurrent: false
        )
        let captured = CapturedImage(
            image: image,
            colorSpace: image.colorSpace,
            pixelSize: descriptor.pixelSize,
            logicalSize: frame.size,
            scale: scale,
            sourceMetadata: CaptureSourceMetadata(
                kind: .display,
                displayIDs: [id],
                windowID: nil,
                desktopFrame: frame
            )
        )
        return DisplayCapture(descriptor: descriptor, capturedImage: captured)
    }
}

private enum AnnotationTestSupport {
    static func document(
        annotations: [AnnotationItem] = [],
        canvasSize: CGSize = CGSize(width: 100, height: 100)
    ) -> AnnotationDocument {
        AnnotationDocument(
            baseImageReference: ImageReference(pixelSize: canvasSize),
            canvasSize: canvasSize,
            annotations: annotations
        )
    }

    static var allRenderableItems: [AnnotationItem] {
        [
            AnnotationItem(kind: .rectangle, zIndex: 0, geometry: .rect(CGRect(x: 5, y: 5, width: 25, height: 20))),
            AnnotationItem(kind: .ellipse, zIndex: 1, geometry: .rect(CGRect(x: 35, y: 5, width: 25, height: 20))),
            AnnotationItem(kind: .line, zIndex: 2, geometry: .line(start: CGPoint(x: 5, y: 35), end: CGPoint(x: 30, y: 45))),
            AnnotationItem(kind: .arrow, zIndex: 3, geometry: .line(start: CGPoint(x: 35, y: 35), end: CGPoint(x: 65, y: 48))),
            AnnotationItem(kind: .freehand, zIndex: 4, geometry: .path([CGPoint(x: 5, y: 55), CGPoint(x: 15, y: 65), CGPoint(x: 30, y: 58)])),
            AnnotationItem(kind: .text, zIndex: 5, geometry: .rect(CGRect(x: 35, y: 55, width: 50, height: 20)), text: "Text"),
            AnnotationItem(kind: .counter, zIndex: 6, geometry: .rect(CGRect(x: 5, y: 72, width: 20, height: 20)), counterValue: 1),
            AnnotationItem(
                kind: .highlight,
                zIndex: 7,
                geometry: .rect(CGRect(x: 30, y: 75, width: 20, height: 12)),
                style: AnnotationStyle(fillColor: .yellowHighlight)
            ),
            AnnotationItem(kind: .mosaic, zIndex: 8, geometry: .rect(CGRect(x: 55, y: 75, width: 15, height: 15))),
            AnnotationItem(kind: .blur, zIndex: 9, geometry: .rect(CGRect(x: 72, y: 75, width: 15, height: 15))),
            AnnotationItem(kind: .spotlight, zIndex: 10, geometry: .rect(CGRect(x: 65, y: 5, width: 28, height: 28)))
        ]
    }
}

private enum HistoryTestSupport {
    struct Result {
        let initialSummaryCount: Int
        let filesWereComplete: Bool
        let loadedAnnotationCount: Int
        let validCountAfterCorruption: Int
        let validRecordWasRemovedByRetention: Bool
        let countAfterClear: Int
    }

    static func exerciseStore() async throws -> Result {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("UshotHistoryTests-\(UUID().uuidString)", isDirectory: true)
        do {
            let store = SystemScreenshotHistoryStore(rootDirectory: root)
            let validID = UUID()
            let validRecord = makeRecord(
                id: validID,
                createdAt: Date(timeIntervalSince1970: 100)
            )
            try await store.save(validRecord)
            let initial = try await store.list()
            let validDirectory = root.appendingPathComponent(validID.uuidString, isDirectory: true)
            let filesWereComplete = ["base.png", "preview.png", "document.json", "metadata.json"].allSatisfy {
                fileManager.fileExists(atPath: validDirectory.appendingPathComponent($0).path)
            }

            var updated = validRecord
            updated.document.annotations = [
                AnnotationItem(
                    kind: .rectangle,
                    zIndex: 0,
                    geometry: .rect(CGRect(x: 1, y: 1, width: 4, height: 4))
                )
            ]
            updated.metadata.updatedAt = Date(timeIntervalSince1970: 200)
            try await store.save(updated)
            let loaded = try await store.load(id: validID)

            let corruptID = UUID()
            try await store.save(makeRecord(id: corruptID, createdAt: Date()))
            let corruptMetadata = root
                .appendingPathComponent(corruptID.uuidString, isDirectory: true)
                .appendingPathComponent("metadata.json")
            try Data("broken metadata".utf8).write(to: corruptMetadata, options: .atomic)
            let afterCorruption = try await store.list()

            try await store.enforceRetention(days: 30, maximumItemCount: 500, now: Date())
            let validRecordWasRemoved = !fileManager.fileExists(atPath: validDirectory.path)
            try await store.clear()
            let afterClear = try await store.list()
            let result = Result(
                initialSummaryCount: initial.count,
                filesWereComplete: filesWereComplete,
                loadedAnnotationCount: loaded.document.annotations.count,
                validCountAfterCorruption: afterCorruption.count,
                validRecordWasRemovedByRetention: validRecordWasRemoved,
                countAfterClear: afterClear.count
            )
            try fileManager.removeItem(at: root)
            return result
        } catch {
            if fileManager.fileExists(atPath: root.path) {
                do {
                    try fileManager.removeItem(at: root)
                } catch let cleanupError {
                    throw ScreenshotAppError.historyPersistenceFailed(
                        description: "Test cleanup failed after \(error.localizedDescription): \(cleanupError.localizedDescription)"
                    )
                }
            }
            throw error
        }
    }

    private static func makeRecord(id: UUID, createdAt: Date) -> ScreenshotHistoryRecord {
        let image = ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 8, height: 8),
            scale: 1,
            red: 0.4
        ).capturedImage
        let document = AnnotationDocument(
            id: id,
            baseImageReference: ImageReference(
                relativePath: "base.png",
                pixelSize: image.pixelSize,
                colorSpaceName: image.colorSpace?.name as String?
            ),
            canvasSize: image.logicalSize
        )
        var metadata = HistoryRecordMetadata.make(documentID: id, baseImage: image, now: createdAt)
        metadata.createdAt = createdAt
        metadata.updatedAt = createdAt
        return ScreenshotHistoryRecord(
            metadata: metadata,
            document: document,
            baseImage: image,
            previewImage: image
        )
    }
}

#if canImport(XCTest)
final class UshotCoreFoundationTests: XCTestCase {
    func testOpenSourceProviderEntitlesEveryDeclaredFeature() {
        let provider = OpenSourceEntitlementProvider()
        for feature in AppFeature.allCases {
            XCTAssertTrue(provider.isEntitled(to: feature), "Expected entitlement for \(feature)")
        }
    }

    func testNoOpUpdateCheckerReportsNoUpdate() async throws {
        let result = try await NoOpUpdateChecker().checkForUpdates()
        XCTAssertFalse(result.isUpdateAvailable)
        XCTAssertNil(result.version)
    }

    @MainActor
    func testDefaultSettingsMatchProductDefaults() {
        let settings = AppSettings.defaults
        XCTAssertTrue(settings.general.showsMenuBarIcon)
        XCTAssertFalse(settings.general.showsDockIcon)
        XCTAssertTrue(settings.capture.presentsPinnedShot)
        XCTAssertTrue(settings.capture.showsQuickToolbar)
        XCTAssertTrue(settings.capture.recognizesInterfaceElements)
        XCTAssertFalse(settings.capture.automaticallyCopies)
        XCTAssertFalse(settings.capture.automaticallySaves)
        XCTAssertFalse(settings.history.isEnabled)
        XCTAssertEqual(settings.output.format, .png)
        XCTAssertEqual(settings.colorPicker.colorSpace, .sRGB)
        XCTAssertEqual(settings.general.startupBehavior, .doNothing)
        XCTAssertEqual(settings.editor.defaultLineWidthUnit, .pixels)
        XCTAssertEqual(settings.editor.defaultFontSizeUnit, .pixels)
        XCTAssertEqual(settings.editor.defaultRectangleCornerRadiusUnit, .pixels)
        XCTAssertEqual(settings.editor.defaultRectangleCornerRadius, 4)
        XCTAssertEqual(settings.editor.defaultFontSize, 18)
        XCTAssertEqual(
            settings.editor.toolbarColorHexes,
            AnnotationColorPalette.factoryDefaultHexColors
        )
        XCTAssertEqual(settings.editor.availableColorHexes, settings.editor.toolbarColorHexes)
        XCTAssertEqual(
            AnnotationColorPalette.displayedHexColors(
                configuredHexColors: AnnotationColorPalette.factoryDefaultHexColors,
                currentHex: "#007AFF"
            ),
            AnnotationColorPalette.factoryDefaultHexColors
        )
        XCTAssertEqual(
            AnnotationColorPalette.displayedHexColors(
                configuredHexColors: AnnotationColorPalette.factoryDefaultHexColors,
                currentHex: "#123456"
            ),
            AnnotationColorPalette.factoryDefaultHexColors + ["#123456"]
        )
        XCTAssertEqual(settings.editor.defaultColorHex, "#FF3B30")
        XCTAssertEqual(settings.editor.defaultTextColorHex, "#FF3B30")
        XCTAssertEqual(settings.editor.defaultRectangleColorHex, "#FF3B30")
        XCTAssertEqual(settings.editor.defaultEllipseColorHex, "#FF3B30")
        XCTAssertNil(settings.editor.defaultTextFontName)
        XCTAssertEqual(AnnotationTool.highlight.toolbarSystemSymbolName, "rectangle.fill")
        for tool in AnnotationTool.allCases {
            XCTAssertNotNil(
                NSImage(
                    systemSymbolName: tool.toolbarSystemSymbolName,
                    accessibilityDescription: tool.rawValue
                ),
                "Missing toolbar symbol for \(tool.rawValue)"
            )
        }
        XCTAssertFalse(AnnotationTool.quickToolbarOrder.contains(.crop))
        XCTAssertNil(settings.shortcuts.annotationToolAssignments[.crop])
        XCTAssertNil(
            settings.shortcuts.annotationTool(
                matching: HotKeyShortcut(keyCode: 24, modifiers: [])
            )
        )
        XCTAssertEqual(
            AnnotationTool.quickToolbarOrder.compactMap {
                settings.shortcuts.annotationToolAssignments[$0]?.displayString
            },
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "["]
        )
    }

    @MainActor
    func testSettingsStoreRoundTripsOneVersionedDocument() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        try store.update(\AppSettings.general.showsDockIcon, to: true)
        try store.update(\AppSettings.editor.defaultRectangleCornerRadius, to: 12.5)
        try store.update { settings in
            settings.editor.defaultTextColorHex = "#007AFF"
            settings.editor.defaultRectangleColorHex = "#34C759"
            settings.editor.defaultEllipseColorHex = "#AF52DE"
            settings.editor.defaultTextFontName = "Helvetica"
        }
        let reloaded = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertTrue(reloaded.settings.general.showsDockIcon)
        XCTAssertEqual(reloaded.settings.editor.defaultRectangleCornerRadius, 12.5)
        XCTAssertEqual(reloaded.settings.editor.defaultTextColorHex, "#007AFF")
        XCTAssertEqual(reloaded.settings.editor.defaultRectangleColorHex, "#34C759")
        XCTAssertEqual(reloaded.settings.editor.defaultEllipseColorHex, "#AF52DE")
        XCTAssertEqual(reloaded.settings.editor.defaultTextFontName, "Helvetica")
        XCTAssertEqual(reloaded.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertNil(reloaded.loadError)
    }

    @MainActor
    func testCorruptSettingsAreObservable() {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(Data("not-json".utf8), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.settings, .defaults)
    }

    @MainActor
    func testVersionOneSettingsMigrateToCurrentSchema() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(try SettingsTestSupport.legacyVersionOneData(), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(store.settings.general.startupBehavior, .doNothing)
        XCTAssertEqual(store.settings.editor.defaultRectangleCornerRadius, 4)
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testVersionTwoSettingsMigrateRectangleCornerRadiusDefault() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(try SettingsTestSupport.legacyVersionTwoData(), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(store.settings.editor.defaultRectangleCornerRadius, 4)
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testVersionThreeSettingsMigratePixelLineWidthUnitDefault() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(try SettingsTestSupport.legacyVersionThreeData(), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(store.settings.editor.defaultLineWidthUnit, .pixels)
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testVersionFourSettingsMigrateAnnotationToolShortcutDefaults() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(try SettingsTestSupport.legacyVersionFourData(), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(
            store.settings.shortcuts.annotationToolAssignments,
            ShortcutSettings.defaultAnnotationToolAssignments
        )
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testVersionFiveSettingsPreserveLegacyCustomDefaultColor() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(try SettingsTestSupport.legacyVersionFiveData(), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(store.settings.editor.defaultColorHex, "#123456")
        XCTAssertEqual(
            store.settings.editor.toolbarColorHexes,
            AnnotationColorPalette.factoryDefaultHexColors + ["#123456"]
        )
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testVersionFiveMigrationPreservesShortcutThatNowDefaultsToSpotlight() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(
            try SettingsTestSupport.legacyVersionFiveData(usesSpotlightDefaultForRectangle: true),
            forKey: context.key
        )

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(
            store.settings.shortcuts.annotationToolAssignments[.rectangle],
            HotKeyShortcut(keyCode: 33, modifiers: [])
        )
        XCTAssertEqual(
            store.settings.shortcuts.annotationToolAssignments[.spotlight],
            HotKeyShortcut(keyCode: 30, modifiers: [])
        )
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testVersionSixSettingsMigrateToolDefaultsAndElementRecognition() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(try SettingsTestSupport.legacyVersionSixData(), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(store.settings.editor.defaultTextColorHex, "#123456")
        XCTAssertEqual(store.settings.editor.defaultRectangleColorHex, "#123456")
        XCTAssertEqual(store.settings.editor.defaultEllipseColorHex, "#123456")
        XCTAssertNil(store.settings.editor.defaultTextFontName)
        XCTAssertTrue(store.settings.capture.recognizesInterfaceElements)
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testVersionSevenSettingsMigratePixelMeasurementUnitDefaults() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(try SettingsTestSupport.legacyVersionSevenData(), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(store.settings.editor.defaultLineWidthUnit, .points)
        XCTAssertEqual(store.settings.editor.defaultFontSizeUnit, .pixels)
        XCTAssertEqual(store.settings.editor.defaultRectangleCornerRadiusUnit, .pixels)
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testVersionEightSettingsMigrateLegacyCustomColorsToCompleteToolbarPalette() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(try SettingsTestSupport.legacyVersionEightData(), forKey: context.key)

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(
            store.settings.editor.toolbarColorHexes,
            AnnotationColorPalette.factoryDefaultHexColors + ["#12ABEF", "#654321"]
        )
        XCTAssertEqual(store.settings.editor.defaultColorHex, "#12ABEF")
        XCTAssertEqual(store.settings.editor.defaultTextColorHex, "#12ABEF")
        XCTAssertEqual(store.settings.editor.defaultRectangleColorHex, "#12ABEF")
        XCTAssertEqual(store.settings.editor.defaultEllipseColorHex, "#12ABEF")
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testCurrentSettingsMissingToolbarPaletteFailFast() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(
            try SettingsTestSupport.currentVersionDataWithoutToolbarColors(explicitNull: false),
            forKey: context.key
        )

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.settings, .defaults)
    }

    @MainActor
    func testCurrentSettingsNullToolbarPaletteFailFast() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        context.defaults.set(
            try SettingsTestSupport.currentVersionDataWithoutToolbarColors(explicitNull: true),
            forKey: context.key
        )

        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.settings, .defaults)
    }

    @MainActor
    func testCompleteToolbarPaletteRoundTripsWithoutLegacyCustomColorKey() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
        var editor = EditorSettings(
            defaultColorHex: "#12ABEF",
            toolbarColorHexes: ["#12ABEF", "#654321"]
        )
        try store.update(\AppSettings.editor, to: editor)

        let reloaded = SettingsStore(defaults: context.defaults, storageKey: context.key)
        XCTAssertEqual(reloaded.settings.editor.toolbarColorHexes, ["#12ABEF", "#654321"])
        XCTAssertEqual(reloaded.settings.editor.defaultColorHex, "#12ABEF")
        XCTAssertNil(reloaded.loadError)

        let persistedData = try XCTUnwrap(context.defaults.data(forKey: context.key))
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        let persistedEditor = try XCTUnwrap(document["editor"] as? [String: Any])
        XCTAssertEqual(
            persistedEditor["toolbarColorHexes"] as? [String],
            ["#12ABEF", "#654321"]
        )
        XCTAssertNil(persistedEditor["customColorHexes"])

        let original = editor
        XCTAssertThrowsError(try editor.addToolbarColor("12abef"))
        XCTAssertEqual(editor, original)
    }

    func testRemovingFactoryToolbarColorRedirectsEveryDefaultAtomically() throws {
        var editor = EditorSettings()
        let removedHex = "#FF3B30"
        let replacementHex = "#007AFF"

        try editor.removeToolbarColor(removedHex, replacingUsesWith: replacementHex)

        XCTAssertEqual(
            editor.toolbarColorHexes,
            AnnotationColorPalette.factoryDefaultHexColors.filter { $0 != removedHex }
        )
        XCTAssertEqual(editor.defaultColorHex, replacementHex)
        XCTAssertEqual(editor.defaultTextColorHex, replacementHex)
        XCTAssertEqual(editor.defaultRectangleColorHex, replacementHex)
        XCTAssertEqual(editor.defaultEllipseColorHex, replacementHex)
        XCTAssertEqual(try editor.validatedColorPalette(), editor)
    }

    func testRemovingLastToolbarColorFailsAtomically() {
        var editor = EditorSettings(
            defaultColorHex: "#12ABEF",
            toolbarColorHexes: ["#12ABEF"]
        )
        let original = editor

        XCTAssertThrowsError(
            try editor.removeToolbarColor("#12ABEF", replacingUsesWith: "#12ABEF")
        )
        XCTAssertEqual(editor, original)
    }

    func testCustomOnlyToolbarPaletteIsValid() throws {
        let editor = EditorSettings(
            defaultColorHex: "12abef",
            defaultTextColorHex: "#654321",
            defaultRectangleColorHex: "12abef",
            defaultEllipseColorHex: "#654321",
            toolbarColorHexes: ["12abef", "#654321"]
        )

        let validated = try editor.validatedColorPalette()

        XCTAssertEqual(validated.toolbarColorHexes, ["#12ABEF", "#654321"])
        XCTAssertEqual(validated.defaultColorHex, "#12ABEF")
        XCTAssertEqual(validated.defaultTextColorHex, "#654321")
        XCTAssertEqual(validated.defaultRectangleColorHex, "#12ABEF")
        XCTAssertEqual(validated.defaultEllipseColorHex, "#654321")
    }

    func testRestoringFactoryToolbarColorsPreservesNonPaletteSettingsAndRedirectsDefaults() throws {
        var editor = EditorSettings(
            defaultColorHex: "#12ABEF",
            defaultTextColorHex: "#007AFF",
            defaultRectangleColorHex: "#654321",
            defaultEllipseColorHex: "#FF3B30",
            toolbarColorHexes: ["#12ABEF", "#007AFF", "#654321", "#FF3B30"],
            defaultLineWidth: 7.5,
            defaultLineWidthUnit: .points,
            defaultRectangleCornerRadius: 11,
            defaultRectangleCornerRadiusUnit: .points,
            defaultFontSize: 26,
            defaultFontSizeUnit: .points,
            defaultTextFontName: "Helvetica",
            defaultBackgroundHex: "#102030"
        )

        editor.restoreFactoryToolbarColors()

        XCTAssertEqual(editor.toolbarColorHexes, AnnotationColorPalette.factoryDefaultHexColors)
        XCTAssertEqual(editor.defaultColorHex, "#FF3B30")
        XCTAssertEqual(editor.defaultTextColorHex, "#007AFF")
        XCTAssertEqual(editor.defaultRectangleColorHex, "#FF3B30")
        XCTAssertEqual(editor.defaultEllipseColorHex, "#FF3B30")
        XCTAssertEqual(editor.defaultLineWidth, 7.5)
        XCTAssertEqual(editor.defaultLineWidthUnit, .points)
        XCTAssertEqual(editor.defaultRectangleCornerRadius, 11)
        XCTAssertEqual(editor.defaultRectangleCornerRadiusUnit, .points)
        XCTAssertEqual(editor.defaultFontSize, 26)
        XCTAssertEqual(editor.defaultFontSizeUnit, .points)
        XCTAssertEqual(editor.defaultTextFontName, "Helvetica")
        XCTAssertEqual(editor.defaultBackgroundHex, "#102030")
        XCTAssertEqual(try editor.validatedColorPalette(), editor)
    }

    func testRestoringFactoryToolbarColorsCanPreserveCustomColorsAndToolDefaults() throws {
        var editor = EditorSettings(
            defaultColorHex: "#12ABEF",
            defaultTextColorHex: "#007AFF",
            defaultRectangleColorHex: "#654321",
            defaultEllipseColorHex: "#FF3B30",
            toolbarColorHexes: ["#654321", "#007AFF", "#12ABEF", "#FF3B30"],
            defaultLineWidth: 7.5,
            defaultTextFontName: "Helvetica"
        )

        editor.restoreFactoryToolbarColorsPreservingCustomColors()
        let firstRestoration = editor
        editor.restoreFactoryToolbarColorsPreservingCustomColors()

        XCTAssertEqual(
            editor.toolbarColorHexes,
            AnnotationColorPalette.factoryDefaultHexColors + ["#654321", "#12ABEF"]
        )
        XCTAssertEqual(editor.defaultColorHex, "#12ABEF")
        XCTAssertEqual(editor.defaultTextColorHex, "#007AFF")
        XCTAssertEqual(editor.defaultRectangleColorHex, "#654321")
        XCTAssertEqual(editor.defaultEllipseColorHex, "#FF3B30")
        XCTAssertEqual(editor.defaultLineWidth, 7.5)
        XCTAssertEqual(editor.defaultTextFontName, "Helvetica")
        XCTAssertEqual(editor, firstRestoration)
        XCTAssertEqual(try editor.validatedColorPalette(), editor)
    }

    func testRemovingToolbarColorRejectsMissingReplacementAtomically() throws {
        var editor = EditorSettings()
        try editor.addToolbarColor("#12ABEF")
        editor.defaultTextColorHex = "#12ABEF"
        let original = editor

        XCTAssertThrowsError(
            try editor.removeToolbarColor("#12ABEF", replacingUsesWith: "#123456")
        )
        XCTAssertEqual(editor, original)
    }

    @MainActor
    func testAnnotationToolShortcutPersistsAcrossSettingsReload() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
        let custom = HotKeyShortcut(keyCode: 0, modifiers: [.shift])

        try store.update { settings in
            settings.shortcuts.annotationToolAssignments[.rectangle] = custom
        }

        let reloaded = SettingsStore(defaults: context.defaults, storageKey: context.key)
        XCTAssertEqual(reloaded.settings.shortcuts.annotationToolAssignments[.rectangle], custom)
        XCTAssertEqual(reloaded.settings.shortcuts.annotationTool(matching: custom), .rectangle)
        XCTAssertNil(reloaded.loadError)
    }

    func testLegacyCropShortcutIsDiscardedWhileVisibleCustomizationSurvives() throws {
        let customRectangleShortcut = HotKeyShortcut(keyCode: 42, modifiers: [.shift])
        var legacyAssignments = ShortcutSettings.defaultAnnotationToolAssignments
        legacyAssignments[.rectangle] = customRectangleShortcut
        legacyAssignments[.spotlight] = nil
        legacyAssignments[.crop] = HotKeyShortcut(keyCode: 33, modifiers: [])
        let legacySettings = ShortcutSettings(
            assignments: ShortcutSettings.defaults.assignments,
            annotationToolAssignments: legacyAssignments
        )

        let encoded = try JSONEncoder().encode(legacySettings)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"crop\""))

        let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: encoded)
        XCTAssertNil(decoded.annotationToolAssignments[.crop])
        XCTAssertEqual(decoded.annotationToolAssignments[.rectangle], customRectangleShortcut)
        XCTAssertEqual(
            decoded.annotationToolAssignments[.spotlight],
            HotKeyShortcut(keyCode: 33, modifiers: [])
        )
    }

    func testDuplicateShortcutIsRejected() {
        let duplicate = HotKeyShortcut(keyCode: 0, modifiers: [.control, .option])
        let settings = ShortcutSettings(assignments: [
            .captureRegion: duplicate,
            .captureWindow: duplicate
        ])

        XCTAssertThrowsError(try settings.validatingUniqueAssignments())
    }

    func testFunctionKeyDisplayAndClassificationUseCarbonKeyCodes() {
        let expectedNamesByKeyCode: [(keyCode: Int, name: String)] = [
            (kVK_F1, "F1"),
            (kVK_F2, "F2"),
            (kVK_F12, "F12"),
            (kVK_F20, "F20")
        ]

        for (keyCode, name) in expectedNamesByKeyCode {
            let shortcut = HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: [])
            XCTAssertEqual(shortcut.displayString, name)
            XCTAssertTrue(shortcut.isFunctionKey)
            XCTAssertTrue(shortcut.isValidGlobalShortcut)
        }

        let letterShortcut = HotKeyShortcut(keyCode: 0, modifiers: [])
        XCTAssertEqual(letterShortcut.displayString, "A")
        XCTAssertFalse(letterShortcut.isFunctionKey)
        XCTAssertFalse(letterShortcut.isValidGlobalShortcut)
        XCTAssertTrue(
            HotKeyShortcut(keyCode: 0, modifiers: [.command]).isValidGlobalShortcut
        )
        XCTAssertFalse(
            HotKeyShortcut(
                keyCode: UInt32(kVK_F1),
                modifiers: HotKeyTestSupport.modifiersWithUnknownBit
            ).isValidGlobalShortcut
        )
    }

    func testGlobalShortcutAdmissionAcceptsBareFunctionKeysAndModifiedLetters() throws {
        let settings = ShortcutSettings(assignments: [
            .captureRegion: HotKeyShortcut(keyCode: UInt32(kVK_F1), modifiers: []),
            .captureWindow: HotKeyShortcut(keyCode: UInt32(kVK_F20), modifiers: []),
            .colorPicker: HotKeyShortcut(keyCode: 0, modifiers: [.option])
        ])

        XCTAssertEqual(try settings.validatingUniqueAssignments(), settings)
    }

    func testBareLetterGlobalShortcutIsRejectedByShortcutSettings() {
        let settings = ShortcutSettings(assignments: [
            .captureRegion: HotKeyShortcut(keyCode: 0, modifiers: [])
        ])

        XCTAssertThrowsError(try settings.validatingUniqueAssignments()) { error in
            guard case .invalidGlobalShortcut(let action) = error as? ScreenshotAppError else {
                return XCTFail("Expected invalidGlobalShortcut, received \(error)")
            }
            XCTAssertEqual(action, .captureRegion)
        }
    }

    func testUnknownModifierBitsAreRejectedByShortcutSettings() {
        let settings = ShortcutSettings(assignments: [
            .captureRegion: HotKeyShortcut(
                keyCode: 0,
                modifiers: HotKeyTestSupport.modifiersWithUnknownBit
            )
        ])

        XCTAssertThrowsError(try settings.validatingUniqueAssignments()) { error in
            guard case .invalidGlobalShortcut(let action) = error as? ScreenshotAppError else {
                return XCTFail("Expected invalidGlobalShortcut, received \(error)")
            }
            XCTAssertEqual(action, .captureRegion)
        }
    }

    func testDuplicateAnnotationToolShortcutIsRejected() {
        var settings = ShortcutSettings.defaults
        settings.annotationToolAssignments[.rectangle] = settings.annotationToolAssignments[.select]

        XCTAssertThrowsError(try settings.validatingUniqueAssignments())
    }

    @MainActor
    func testDuplicateAnnotationToolShortcutDoesNotMutateSettingsStore() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
        let original = store.settings

        XCTAssertThrowsError(try store.update { settings in
            settings.shortcuts.annotationToolAssignments[.rectangle]
                = settings.shortcuts.annotationToolAssignments[.select]
        })
        XCTAssertEqual(store.settings, original)
    }

    @MainActor
    func testHotKeyRegistrationFailureRestoresPreviousAssignments() throws {
        let backend = FakeHotKeyBackend()
        let manager = try CarbonGlobalHotKeyManager(backend: backend)
        let previous = ShortcutSettings.defaults.assignments
        try manager.register(previous)
        var candidate = previous
        candidate[.captureRegion] = HotKeyShortcut(keyCode: 12, modifiers: [.control, .option])
        backend.failOnceForAction = .captureWindow

        XCTAssertThrowsError(try manager.register(candidate))
        XCTAssertEqual(manager.assignments, previous)
        XCTAssertEqual(backend.registrations.count, previous.count)
    }

    @MainActor
    func testBareLetterGlobalShortcutDoesNotMutateManagerRegistrations() throws {
        let backend = FakeHotKeyBackend()
        let manager = try CarbonGlobalHotKeyManager(backend: backend)
        let previous = ShortcutSettings.defaults.assignments
        try manager.register(previous)
        let previousRegistrations = backend.registrations
        var candidate = previous
        candidate[.captureRegion] = HotKeyShortcut(keyCode: 0, modifiers: [])

        XCTAssertThrowsError(try manager.register(candidate)) { error in
            guard case .invalidGlobalShortcut(let action) = error as? ScreenshotAppError else {
                return XCTFail("Expected invalidGlobalShortcut, received \(error)")
            }
            XCTAssertEqual(action, .captureRegion)
        }
        XCTAssertEqual(manager.assignments, previous)
        XCTAssertEqual(backend.registrations, previousRegistrations)
    }

    @MainActor
    func testBareLetterGlobalShortcutDoesNotMutateSettingsStore() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
        try store.update(\AppSettings.general.showsDockIcon, to: true)
        let previous = store.settings
        let previousData = context.defaults.data(forKey: context.key)

        XCTAssertThrowsError(try store.update { settings in
            settings.shortcuts.assignments[.captureRegion] = HotKeyShortcut(
                keyCode: 0,
                modifiers: []
            )
        }) { error in
            guard case .invalidGlobalShortcut(let action) = error as? ScreenshotAppError else {
                return XCTFail("Expected invalidGlobalShortcut, received \(error)")
            }
            XCTAssertEqual(action, .captureRegion)
        }
        XCTAssertEqual(store.settings, previous)
        XCTAssertEqual(context.defaults.data(forKey: context.key), previousData)
    }

    @MainActor
    func testUnknownModifierBitsDoNotMutateManagerRegistrations() throws {
        let backend = FakeHotKeyBackend()
        let manager = try CarbonGlobalHotKeyManager(backend: backend)
        let previous = ShortcutSettings.defaults.assignments
        try manager.register(previous)
        let previousRegistrations = backend.registrations
        var candidate = previous
        candidate[.captureRegion] = HotKeyShortcut(
            keyCode: 0,
            modifiers: HotKeyTestSupport.modifiersWithUnknownBit
        )

        XCTAssertThrowsError(try manager.register(candidate)) { error in
            guard case .invalidGlobalShortcut(let action) = error as? ScreenshotAppError else {
                return XCTFail("Expected invalidGlobalShortcut, received \(error)")
            }
            XCTAssertEqual(action, .captureRegion)
        }
        XCTAssertEqual(manager.assignments, previous)
        XCTAssertEqual(backend.registrations, previousRegistrations)
    }

    @MainActor
    func testUnknownModifierBitsDoNotMutateSettingsStore() throws {
        let context = SettingsTestSupport.makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
        try store.update(\AppSettings.general.showsDockIcon, to: true)
        let previous = store.settings
        let previousData = context.defaults.data(forKey: context.key)

        XCTAssertThrowsError(try store.update { settings in
            settings.shortcuts.assignments[.captureRegion] = HotKeyShortcut(
                keyCode: 0,
                modifiers: HotKeyTestSupport.modifiersWithUnknownBit
            )
        }) { error in
            guard case .invalidGlobalShortcut(let action) = error as? ScreenshotAppError else {
                return XCTFail("Expected invalidGlobalShortcut, received \(error)")
            }
            XCTAssertEqual(action, .captureRegion)
        }
        XCTAssertEqual(store.settings, previous)
        XCTAssertEqual(context.defaults.data(forKey: context.key), previousData)
    }

    func testScreenCaptureFramesConvertToAppKitGlobalCoordinates() {
        let transformer = CoordinateTransformer(primaryDisplayHeight: 1_080)

        XCTAssertEqual(
            transformer.appKitRect(fromScreenCaptureRect: CGRect(x: 0, y: -900, width: 1_440, height: 900)),
            CGRect(x: 0, y: 1_080, width: 1_440, height: 900)
        )
        XCTAssertEqual(
            transformer.appKitRect(fromScreenCaptureRect: CGRect(x: 0, y: 1_080, width: 1_440, height: 900)),
            CGRect(x: 0, y: -900, width: 1_440, height: 900)
        )
    }

    func testDisplayBackingMetricsUsesRetinaPixelsAndRejectsAxisMismatch() throws {
        let metrics = try DisplayBackingMetrics(
            logicalSize: CGSize(width: 1_728, height: 1_117),
            pixelSize: CGSize(width: 3_456, height: 2_234)
        )

        XCTAssertEqual(metrics.scale, 2)
        XCTAssertEqual(metrics.pixelSize, CGSize(width: 3_456, height: 2_234))
        XCTAssertThrowsError(try DisplayBackingMetrics(
            logicalSize: CGSize(width: 100, height: 100),
            pixelSize: CGSize(width: 200, height: 100)
        ))
    }

    func testScreenCapturePixelGeometryPreservesAdjacentRetinaPixels() throws {
        let evenPixel = try ScreenCapturePixelGeometry(
            targetPixel: CGPoint(x: 1_600, y: 600),
            radius: 128,
            pixelSize: CGSize(width: 4_096, height: 2_304),
            scale: 2
        )
        let adjacentOddPixel = try ScreenCapturePixelGeometry(
            targetPixel: CGPoint(x: 1_601, y: 600),
            radius: 128,
            pixelSize: CGSize(width: 4_096, height: 2_304),
            scale: 2
        )
        let adjacentOddRow = try ScreenCapturePixelGeometry(
            targetPixel: CGPoint(x: 1_600, y: 601),
            radius: 128,
            pixelSize: CGSize(width: 4_096, height: 2_304),
            scale: 2
        )
        let oneXPixel = try ScreenCapturePixelGeometry(
            targetPixel: CGPoint(x: 1_600, y: 600),
            radius: 128,
            pixelSize: CGSize(width: 4_096, height: 2_304),
            scale: 1
        )
        let bottomRightPixel = try ScreenCapturePixelGeometry(
            targetPixel: CGPoint(x: 4_095, y: 2_303),
            radius: 128,
            pixelSize: CGSize(width: 4_096, height: 2_304),
            scale: 2
        )
        let fractionalScalePixel = try ScreenCapturePixelGeometry(
            targetPixel: CGPoint(x: 500, y: 300),
            radius: 128,
            pixelSize: CGSize(width: 1_500, height: 900),
            scale: 1.5
        )

        XCTAssertEqual(
            evenPixel.sourceRectInPoints,
            CGRect(x: 736, y: 236, width: 129, height: 129)
        )
        XCTAssertEqual(evenPixel.sourceRectInPoints, adjacentOddPixel.sourceRectInPoints)
        XCTAssertEqual(
            evenPixel.sourcePixelRect,
            CGRect(x: 1_472, y: 472, width: 258, height: 258)
        )
        XCTAssertEqual(evenPixel.targetPixelInImage, CGPoint(x: 128, y: 128))
        XCTAssertEqual(adjacentOddPixel.targetPixelInImage, CGPoint(x: 129, y: 128))
        XCTAssertEqual(adjacentOddRow.sourceRectInPoints, evenPixel.sourceRectInPoints)
        XCTAssertEqual(adjacentOddRow.targetPixelInImage, CGPoint(x: 128, y: 129))
        XCTAssertEqual(
            oneXPixel.sourcePixelRect,
            CGRect(x: 1_472, y: 472, width: 257, height: 257)
        )
        XCTAssertEqual(oneXPixel.targetPixelInImage, CGPoint(x: 128, y: 128))
        XCTAssertEqual(
            bottomRightPixel.sourcePixelRect,
            CGRect(x: 3_838, y: 2_046, width: 258, height: 258)
        )
        XCTAssertEqual(bottomRightPixel.targetPixelInImage, CGPoint(x: 257, y: 257))
        XCTAssertEqual(
            fractionalScalePixel.sourceRectInPoints,
            CGRect(x: 248, y: 114, width: 172, height: 172)
        )
        XCTAssertEqual(
            fractionalScalePixel.sourcePixelRect,
            CGRect(x: 372, y: 171, width: 258, height: 258)
        )
        XCTAssertEqual(
            fractionalScalePixel.targetPixelInImage,
            CGPoint(x: 128, y: 129)
        )
    }

    func testAnnotationLineWidthUnitsRoundTripAtRetinaScale() {
        let pixels = AnnotationLineWidthUnit.pixels
        let points = AnnotationLineWidthUnit.points
        let editor = EditorSettings()

        XCTAssertEqual(pixels.logicalPoints(fromDisplayedValue: 3, backingScale: 2), 1.5)
        XCTAssertEqual(pixels.displayedValue(forLogicalPoints: 1.5, backingScale: 2), 3)
        XCTAssertEqual(points.logicalPoints(fromDisplayedValue: 3, backingScale: 2), 3)
        XCTAssertEqual(points.displayedValue(forLogicalPoints: 3, backingScale: 2), 3)
        XCTAssertEqual(editor.logicalDefaultFontSize(backingScale: 2), 9)
        XCTAssertEqual(editor.logicalDefaultRectangleCornerRadius(backingScale: 2), 2)
    }

    func testLineWidthEditingKindsMatchToolbarStrokedTools() {
        XCTAssertEqual(
            AnnotationTool.allCases.filter(\.supportsLineWidthEditing),
            [.rectangle, .ellipse, .line, .arrow, .freehand]
        )
        XCTAssertTrue(AnnotationTool.allCases.allSatisfy {
            $0.supportsLineWidthEditing == ($0.annotationKind?.supportsLineWidthEditing == true)
        })
    }

    func testEditorMeasurementUnitChangesPreserveLogicalValuesAtRetinaScale() {
        var editor = EditorSettings()
        let initialLineWidth = editor.defaultLineWidthUnit.logicalPoints(
            fromDisplayedValue: editor.defaultLineWidth,
            backingScale: 2
        )
        let initialFontSize = editor.logicalDefaultFontSize(backingScale: 2)
        let initialCornerRadius = editor.logicalDefaultRectangleCornerRadius(backingScale: 2)

        editor.setDefaultLineWidthUnit(.points, backingScale: 2)
        editor.setDefaultFontSizeUnit(.points, backingScale: 2)
        editor.setDefaultRectangleCornerRadiusUnit(.points, backingScale: 2)

        XCTAssertEqual(editor.defaultLineWidth, 1.5)
        XCTAssertEqual(editor.defaultFontSize, 9)
        XCTAssertEqual(editor.defaultRectangleCornerRadius, 2)
        XCTAssertEqual(editor.defaultLineWidthUnit, .points)
        XCTAssertEqual(editor.defaultFontSizeUnit, .points)
        XCTAssertEqual(editor.defaultRectangleCornerRadiusUnit, .points)
        XCTAssertEqual(
            editor.defaultLineWidthUnit.logicalPoints(
                fromDisplayedValue: editor.defaultLineWidth,
                backingScale: 2
            ),
            initialLineWidth
        )
        XCTAssertEqual(editor.logicalDefaultFontSize(backingScale: 2), initialFontSize)
        XCTAssertEqual(
            editor.logicalDefaultRectangleCornerRadius(backingScale: 2),
            initialCornerRadius
        )

        editor.setDefaultLineWidthUnit(.pixels, backingScale: 2)
        editor.setDefaultFontSizeUnit(.pixels, backingScale: 2)
        editor.setDefaultRectangleCornerRadiusUnit(.pixels, backingScale: 2)

        XCTAssertEqual(editor.defaultLineWidth, 3)
        XCTAssertEqual(editor.defaultFontSize, 18)
        XCTAssertEqual(editor.defaultRectangleCornerRadius, 4)
    }

    func testFloatingToolbarReservesDownwardPopoverSpaceForLargeCapture() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let layout = FloatingToolbarLayout(
            screenMargin: 8,
            imageSpacing: 8,
            reservedSpaceBelow: 68
        )
        let origin = layout.toolbarOrigin(
            imageFrame: CGRect(x: 20, y: 20, width: 1_400, height: 850),
            toolbarSize: CGSize(width: 880, height: 44),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.x, 280)
        XCTAssertEqual(origin.y, 76)
        XCTAssertGreaterThanOrEqual(origin.y - 68, visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(origin.y + 44, visibleFrame.maxY - 8)
    }

    func testPixelCropAlignsAndFlipsYExactlyOnce() {
        let transformer = CoordinateTransformer(primaryDisplayHeight: 100)
        let display = DisplayGeometry(
            id: 1,
            frame: CGRect(x: -100, y: 0, width: 100, height: 100),
            scale: 2
        )

        let crop = transformer.pixelCropRect(
            for: CGRect(x: -75, y: 25, width: 50, height: 50),
            in: display,
            imagePixelSize: CGSize(width: 200, height: 200)
        )

        XCTAssertEqual(crop, CGRect(x: 50, y: 50, width: 100, height: 100))
    }

    func testCaptureStateMachineCancellationReturnsToIdle() async throws {
        let stateMachine = CaptureStateMachine()
        try await stateMachine.begin(mode: .currentDisplay)
        try await stateMachine.permissionGranted()
        try await stateMachine.contentPrepared(requiresSelection: false)
        await stateMachine.cancel()

        let finalState = await stateMachine.state
        XCTAssertEqual(finalState, .idle)
    }

    func testCaptureAdmissionRejectsReentryWithoutResettingActiveSession() async throws {
        let stateMachine = CaptureStateMachine()
        let initialAdmission = await stateMachine.admit(mode: .region)
        XCTAssertEqual(initialAdmission, .accepted)
        try await stateMachine.permissionGranted()

        let repeatedAdmission = await stateMachine.admit(mode: .region)
        let activeState = await stateMachine.state
        XCTAssertEqual(repeatedAdmission, .rejected(activeState: .preparingContent(.region)))
        XCTAssertEqual(activeState, .preparingContent(.region))
    }

    func testAllDisplayCompositeLayoutHandlesNegativeCoordinatesScaleAndGaps() {
        let displays = [
            DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2),
            DisplayGeometry(id: 2, frame: CGRect(x: -50, y: 100, width: 50, height: 50), scale: 1),
            DisplayGeometry(id: 3, frame: CGRect(x: 150, y: -50, width: 100, height: 50), scale: 2)
        ]
        let geometry = ScreenGeometry(displays: displays)
        let transformer = CoordinateTransformer(primaryDisplayHeight: 0)

        XCTAssertEqual(geometry.desktopBounds, CGRect(x: -50, y: -50, width: 300, height: 200))
        XCTAssertEqual(geometry.maximumScale, 2)
        XCTAssertEqual(
            transformer.bitmapContextDestinationPixelRect(for: displays[0], desktopBounds: geometry.desktopBounds, outputScale: 2),
            CGRect(x: 100, y: 100, width: 200, height: 200)
        )
        XCTAssertEqual(
            transformer.bitmapContextDestinationPixelRect(for: displays[1], desktopBounds: geometry.desktopBounds, outputScale: 2),
            CGRect(x: 0, y: 300, width: 100, height: 100)
        )
        XCTAssertEqual(
            transformer.bitmapContextDestinationPixelRect(for: displays[2], desktopBounds: geometry.desktopBounds, outputScale: 2),
            CGRect(x: 400, y: 0, width: 200, height: 100)
        )
    }

    func testAllDisplayCompositePreservesEachCaptureVerticalOrientation() throws {
        let topImage = ImageTestSupport.verticallyAsymmetricImage(width: 20, height: 20)
        let bottomImage = ImageTestSupport.verticallyAsymmetricImage(width: 20, height: 10)
        let captures = [
            ImageTestSupport.displayCapture(
                id: 1,
                frame: CGRect(x: 0, y: 10, width: 20, height: 20),
                scale: 1,
                image: topImage
            ),
            ImageTestSupport.displayCapture(
                id: 2,
                frame: CGRect(x: 0, y: 0, width: 20, height: 10),
                scale: 1,
                image: bottomImage
            )
        ]

        let composite = try MultiDisplayCompositor().compose(captures).composite.image
        let compositeBytes = ImageTestSupport.rgbaBytes(for: composite)
        let topBytes = ImageTestSupport.rgbaBytes(for: topImage)
        let bottomBytes = ImageTestSupport.rgbaBytes(for: bottomImage)

        XCTAssertEqual(composite.width, 20)
        XCTAssertEqual(composite.height, 30)
        XCTAssertEqual(Array(compositeBytes.prefix(topBytes.count)), topBytes)
        XCTAssertEqual(Array(compositeBytes.suffix(bottomBytes.count)), bottomBytes)
    }

    func testWindowResolverUsesFrontToBackCandidateOrder() {
        let front = WindowDescriptor(
            id: 10,
            title: "Front",
            applicationName: "A",
            frame: CGRect(x: -50, y: 0, width: 100, height: 100),
            layer: 0
        )
        let back = WindowDescriptor(
            id: 11,
            title: "Back",
            applicationName: "B",
            frame: CGRect(x: -100, y: -100, width: 300, height: 300),
            layer: 0
        )

        XCTAssertEqual(
            WindowSelectionResolver().topmostWindow(at: CGPoint(x: 0, y: 50), candidates: [front, back]),
            front
        )
        XCTAssertNil(
            WindowSelectionResolver().topmostWindow(at: CGPoint(x: 500, y: 500), candidates: [front, back])
        )
    }

    func testWindowResolverRejectsDisplayCoveringSystemLayersBeforeAppWindows() {
        let desktopSurface = WindowDescriptor(
            id: 9,
            title: "Desktop Surface",
            applicationName: "System UI",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            layer: 20
        )
        let appWindow = WindowDescriptor(
            id: 10,
            title: "Application Window",
            applicationName: "Another App",
            frame: CGRect(x: 100, y: 100, width: 800, height: 600),
            layer: 0
        )

        XCTAssertEqual(
            WindowSelectionResolver().topmostWindow(
                at: CGPoint(x: 400, y: 400),
                candidates: [desktopSurface, appWindow]
            ),
            appWindow
        )
        XCTAssertNil(
            WindowSelectionResolver().topmostWindow(
                at: CGPoint(x: 50, y: 50),
                candidates: [desktopSurface, appWindow]
            )
        )
    }

    func testRegionCropPreservesNativeScaleOnOneDisplay() throws {
        let preparation = RegionCapturePreparation(displays: [
            ImageTestSupport.displayCapture(
                id: 1,
                frame: CGRect(x: -100, y: 0, width: 100, height: 100),
                scale: 2,
                red: 1
            )
        ])

        let result = try RegionCaptureProcessor().crop(
            CGRect(x: -75, y: 25, width: 50, height: 50),
            from: preparation
        )

        XCTAssertEqual(result.pixelSize, CGSize(width: 100, height: 100))
        XCTAssertEqual(result.logicalSize, CGSize(width: 50, height: 50))
        XCTAssertEqual(result.scale, 2)
        XCTAssertEqual(result.sourceMetadata.desktopFrame, CGRect(x: -75, y: 25, width: 50, height: 50))
    }

    func testCrossDisplayRegionUsesMaximumScaleAndKeepsGap() throws {
        let preparation = RegionCapturePreparation(displays: [
            ImageTestSupport.displayCapture(
                id: 1,
                frame: CGRect(x: -100, y: 0, width: 80, height: 100),
                scale: 1,
                red: 1
            ),
            ImageTestSupport.displayCapture(
                id: 2,
                frame: CGRect(x: 20, y: 0, width: 80, height: 100),
                scale: 2,
                red: 0.5
            )
        ])

        let result = try RegionCaptureProcessor().crop(
            CGRect(x: -50, y: 25, width: 100, height: 50),
            from: preparation
        )

        XCTAssertEqual(result.pixelSize, CGSize(width: 200, height: 100))
        XCTAssertEqual(result.logicalSize, CGSize(width: 100, height: 50))
        XCTAssertEqual(result.scale, 2)
        XCTAssertEqual(result.sourceMetadata.displayIDs, [1, 2])
    }

    func testFilenameTemplateIsDeterministicAndSanitized() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 31, hour: 22, minute: 35, second: 8
        )))

        let filename = FilenameTemplateFormatter(calendar: calendar).filename(
            template: "Screenshot-{yyyy}/{MM}/{dd}-{HH}:{mm}:{ss}",
            date: date
        )

        XCTAssertEqual(filename, "Screenshot-2026-07-31-22-35-08.png")
    }

    func testPNGExporterProducesDecodableColorManagedImage() throws {
        let source = ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 8, height: 8),
            scale: 1,
            red: 1
        ).capturedImage.image

        let data = try SystemImageExporter().pngData(for: source)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertNotNil(decoded.colorSpace)

        for format in ExportFormat.allCases {
            let encoded = try SystemImageExporter().imageData(
                for: source,
                format: format,
                preservesColorProfile: true
            )
            let formatSource = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
            let formatImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(formatSource, 0, nil))
            XCTAssertEqual(formatImage.width, 8)
            XCTAssertEqual(formatImage.height, 8)
            XCTAssertNotNil(formatImage.colorSpace)
        }
    }

    func testAnnotationDocumentRoundTripsEveryItemKind() throws {
        let document = AnnotationTestSupport.document(annotations: AnnotationTestSupport.allRenderableItems)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(Set(decoded.annotations.map(\.kind)), Set(AnnotationKind.allCases))
    }

    func testAnnotationHitTestingHandlesTransformsAndShapes() {
        let translated = AnnotationItem(
            kind: .rectangle,
            zIndex: 0,
            geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
            transform: AnnotationTransform(translation: CGSize(width: 20, height: 0))
        )
        let ellipse = AnnotationItem(
            kind: .ellipse,
            zIndex: 1,
            geometry: .rect(CGRect(x: 0, y: 0, width: 20, height: 10))
        )
        let line = AnnotationItem(
            kind: .line,
            zIndex: 2,
            geometry: .line(start: .zero, end: CGPoint(x: 20, y: 0))
        )
        let tester = AnnotationHitTester()

        XCTAssertTrue(tester.contains(CGPoint(x: 25, y: 5), in: translated, tolerance: 0))
        XCTAssertFalse(tester.contains(CGPoint(x: 5, y: 5), in: translated, tolerance: 0))
        XCTAssertFalse(tester.contains(CGPoint(x: 0, y: 0), in: ellipse, tolerance: 0))
        XCTAssertTrue(tester.contains(CGPoint(x: 10, y: 3), in: line, tolerance: 3))
    }

    func testAnnotationSelectionGeometryMovesAndResizesFromStableOppositeEdge() {
        let item = AnnotationItem(
            kind: .rectangle,
            zIndex: 0,
            geometry: .rect(CGRect(x: 10, y: 20, width: 100, height: 60)),
            transform: AnnotationTransform(translation: CGSize(width: 20, height: 0))
        )
        let geometry = AnnotationSelectionGeometry()

        XCTAssertEqual(geometry.handlePoints(for: item).count, 8)
        let moved = geometry.moved(item, by: CGSize(width: 12, height: -8))
        XCTAssertEqual(moved.transform.translation.width, 32)
        XCTAssertEqual(moved.transform.translation.height, -8)

        let resized = geometry.resized(
            item,
            using: .east,
            to: CGPoint(x: 170, y: 50),
            minimumDimension: 6
        )
        let resizedBounds = geometry.transformedBounds(for: resized)
        XCTAssertEqual(resizedBounds.minX, 30, accuracy: 0.001)
        XCTAssertEqual(resizedBounds.maxX, 170, accuracy: 0.001)
        XCTAssertEqual(resizedBounds.minY, 20, accuracy: 0.001)
        XCTAssertEqual(resizedBounds.maxY, 80, accuracy: 0.001)

        let clamped = geometry.resized(
            item,
            using: .east,
            to: CGPoint(x: -100, y: 50),
            minimumDimension: 6
        )
        let clampedBounds = geometry.transformedBounds(for: clamped)
        XCTAssertEqual(clampedBounds.minX, 30, accuracy: 0.001)
        XCTAssertEqual(clampedBounds.maxX, 36, accuracy: 0.001)

        let brushStroke = AnnotationItem(
            kind: .freehand,
            zIndex: 1,
            geometry: .path([
                CGPoint(x: 10, y: 10),
                CGPoint(x: 24, y: 40),
                CGPoint(x: 42, y: 18)
            ])
        )
        XCTAssertTrue(brushStroke.kind.allowsUserTranslation)
        XCTAssertFalse(brushStroke.kind.allowsUserResize)
        XCTAssertFalse(brushStroke.kind.usesStandardSelectionResizeHandles)
        XCTAssertTrue(geometry.handlePoints(for: brushStroke).isEmpty)
    }

    func testAnnotationSelectionGeometryResizesLineEndpointsInWorldCoordinates() {
        let item = AnnotationItem(
            kind: .arrow,
            zIndex: 0,
            geometry: .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 40, y: 30)),
            transform: AnnotationTransform(translation: CGSize(width: 15, height: -5))
        )
        let geometry = AnnotationSelectionGeometry()
        XCTAssertEqual(geometry.handlePoints(for: item).count, 2)

        let resized = geometry.resized(
            item,
            using: .lineEnd,
            to: CGPoint(x: 90, y: 75),
            minimumDimension: 6
        )
        guard case .line(let start, let end) = resized.geometry else {
            return XCTFail("Expected line geometry after endpoint resize.")
        }
        XCTAssertEqual(start.x, 25, accuracy: 0.001)
        XCTAssertEqual(start.y, 5, accuracy: 0.001)
        XCTAssertEqual(end.x, 90, accuracy: 0.001)
        XCTAssertEqual(end.y, 75, accuracy: 0.001)
        XCTAssertEqual(resized.transform, AnnotationTransform())
    }

    @MainActor
    func testAnnotationUndoRedoAndLayerOrdering() {
        let controller = AnnotationDocumentController(document: AnnotationTestSupport.document())
        let first = AnnotationItem(kind: .rectangle, zIndex: 0, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let second = AnnotationItem(kind: .ellipse, zIndex: 1, geometry: .rect(CGRect(x: 20, y: 0, width: 10, height: 10)))
        controller.add(first)
        controller.add(second)
        controller.selectedItemIDs = [first.id]
        controller.bringSelectionToFront()

        XCTAssertEqual(controller.document.orderedAnnotations.last?.id, first.id)
        controller.undo()
        XCTAssertEqual(controller.document.orderedAnnotations.last?.id, second.id)
        controller.redo()
        XCTAssertEqual(controller.document.orderedAnnotations.last?.id, first.id)
        XCTAssertTrue(controller.canUndo)
    }

    @MainActor
    func testBlurAndMosaicRemainAnchoredWhenSelectionMoves() {
        let items = [
            AnnotationItem(kind: .mosaic, zIndex: 0, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10))),
            AnnotationItem(kind: .blur, zIndex: 1, geometry: .rect(CGRect(x: 20, y: 0, width: 10, height: 10))),
            AnnotationItem(kind: .rectangle, zIndex: 2, geometry: .rect(CGRect(x: 40, y: 0, width: 10, height: 10)))
        ]
        let controller = AnnotationDocumentController(
            document: AnnotationTestSupport.document(annotations: items)
        )
        controller.selectedItemIDs = Set(items.map(\.id))

        controller.moveSelection(by: CGSize(width: 9, height: 4))

        XCTAssertEqual(controller.document.annotations[0].transform.translation, .zero)
        XCTAssertEqual(controller.document.annotations[1].transform.translation, .zero)
        XCTAssertEqual(
            controller.document.annotations[2].transform.translation,
            CGSize(width: 9, height: 4)
        )
        let selectionGeometry = AnnotationSelectionGeometry()
        for item in items.prefix(2) {
            XCTAssertFalse(item.kind.allowsUserTranslation)
            XCTAssertFalse(item.kind.allowsUserResize)
            XCTAssertTrue(selectionGeometry.handlePoints(for: item).isEmpty)
        }
        XCTAssertEqual(selectionGeometry.handlePoints(for: items[2]).count, 8)
    }

    @MainActor
    func testAnnotationDocumentAndSelectionPublishAsOneValidState() {
        let controller = AnnotationDocumentController(document: AnnotationTestSupport.document())
        let item = AnnotationItem(
            kind: .rectangle,
            zIndex: 0,
            geometry: .rect(CGRect(x: 4, y: 6, width: 24, height: 18))
        )
        var observedStates: [AnnotationDocumentController.State] = []
        let observation = controller.$state.sink { state in
            let validIDs = Set(state.document.annotations.map(\.id))
            XCTAssertTrue(
                state.selectedItemIDs.isSubset(of: validIDs),
                "Every published selection must belong to the document from the same emission."
            )
            observedStates.append(state)
        }

        controller.add(item)
        controller.undo()

        XCTAssertEqual(observedStates.count, 3)
        XCTAssertEqual(observedStates[1].document.annotations.map(\.id), [item.id])
        XCTAssertEqual(observedStates[1].selectedItemIDs, [item.id])
        XCTAssertTrue(observedStates[2].document.annotations.isEmpty)
        XCTAssertTrue(observedStates[2].selectedItemIDs.isEmpty)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testAnnotationCanvasRebasePreservesUndoRedoTimeline() {
        var document = AnnotationTestSupport.document()
        document.crop = CropState(rect: CGRect(x: 10, y: 20, width: 40, height: 30))
        let controller = AnnotationDocumentController(document: document)
        let item = AnnotationItem(
            kind: .rectangle,
            zIndex: 0,
            geometry: .rect(CGRect(x: 12, y: 14, width: 20, height: 18))
        )
        controller.add(item)
        controller.moveSelection(by: CGSize(width: 5, height: 0))
        controller.undo()

        let reference = ImageReference(pixelSize: CGSize(width: 280, height: 240))
        controller.rebaseCanvas(
            baseImageReference: reference,
            canvasSize: CGSize(width: 140, height: 120),
            translation: CGSize(width: 20, height: -10)
        )

        XCTAssertEqual(controller.document.baseImageReference, reference)
        XCTAssertEqual(controller.document.canvasSize, CGSize(width: 140, height: 120))
        XCTAssertEqual(controller.document.crop.rect, CGRect(x: 30, y: 10, width: 40, height: 30))
        XCTAssertEqual(controller.document.annotations[0].transform.translation, CGSize(width: 20, height: -10))
        XCTAssertTrue(controller.canUndo)
        XCTAssertTrue(controller.canRedo)

        controller.undo()
        XCTAssertTrue(controller.document.annotations.isEmpty)
        controller.redo()
        XCTAssertEqual(controller.document.annotations[0].transform.translation, CGSize(width: 20, height: -10))
        controller.redo()
        XCTAssertEqual(controller.document.annotations[0].transform.translation, CGSize(width: 25, height: -10))
    }

    func testArrowGeometryKeepsTheRequestedDragEndpoints() throws {
        let start = CGPoint(x: 12, y: 18)
        let tip = CGPoint(x: 92, y: 67)
        let geometry = try XCTUnwrap(ArrowVectorGeometry(start: start, tip: tip, lineWidth: 4))

        XCTAssertEqual(geometry.start, start)
        XCTAssertEqual(geometry.tip, tip)
        XCTAssertEqual((geometry.headLeft.x + geometry.headRight.x) / 2, geometry.headBaseCenter.x, accuracy: 0.0001)
        XCTAssertEqual((geometry.headLeft.y + geometry.headRight.y) / 2, geometry.headBaseCenter.y, accuracy: 0.0001)
        XCTAssertGreaterThan(hypot(tip.x - geometry.headBaseCenter.x, tip.y - geometry.headBaseCenter.y), 0)
        XCTAssertLessThan(
            hypot(tip.x - geometry.headShaftJoin.x, tip.y - geometry.headShaftJoin.y),
            hypot(tip.x - geometry.headBaseCenter.x, tip.y - geometry.headBaseCenter.y),
            "The filled head's rear edges must converge forward into the shaft instead of closing across a flat base."
        )
        XCTAssertGreaterThan(
            hypot(geometry.headShaftJoin.x - start.x, geometry.headShaftJoin.y - start.y),
            hypot(geometry.headBaseCenter.x - start.x, geometry.headBaseCenter.y - start.y)
        )
        XCTAssertLessThan(
            hypot(tip.x - geometry.headShaftEnd.x, tip.y - geometry.headShaftEnd.y),
            hypot(tip.x - geometry.headShaftJoin.x, tip.y - geometry.headShaftJoin.y),
            "The round shaft cap must overlap the filled head instead of ending visibly at its V-shaped join."
        )
        XCTAssertEqual(
            (geometry.taperedNeckLeft.x + geometry.taperedNeckRight.x) / 2,
            geometry.headShaftJoin.x,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            (geometry.taperedNeckLeft.y + geometry.taperedNeckRight.y) / 2,
            geometry.headShaftJoin.y,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            hypot(geometry.taperedNeckLeft.x - geometry.taperedNeckRight.x, geometry.taperedNeckLeft.y - geometry.taperedNeckRight.y),
            hypot(geometry.headLeft.x - geometry.headRight.x, geometry.headLeft.y - geometry.headRight.y)
        )
    }

    func testFilledArrowRendersPaperPlaneWingsAroundAContinuousShaft() throws {
        let width = 96
        let height = 64
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let item = AnnotationItem(
            kind: .arrow,
            zIndex: 0,
            geometry: .line(start: CGPoint(x: 8, y: 32), end: CGPoint(x: 88, y: 32)),
            style: AnnotationStyle(
                strokeColor: .systemRed,
                lineWidth: 8,
                arrowHeadStyle: .filled
            )
        )

        XCTAssertTrue(AnnotationVectorRenderer().draw(
            item: item,
            in: context,
            colorSpace: colorSpace
        ))
        let rendered = try XCTUnwrap(context.makeImage())
        let bytes = ImageTestSupport.rgbaBytes(for: rendered)
        func alpha(x: Int, y: Int) -> UInt8 {
            bytes[(y * rendered.width + x) * 4 + 3]
        }

        XCTAssertGreaterThan(alpha(x: 58, y: 44), 200, "The upper paper-plane wing must be filled.")
        XCTAssertLessThan(alpha(x: 58, y: 38), 32, "The rear edge must angle into the shaft instead of forming a flat base.")
        XCTAssertGreaterThan(alpha(x: 8, y: 32), 200, "The rounded shaft tail must remain filled as one continuous path.")
        XCTAssertGreaterThan(alpha(x: 58, y: 32), 200, "The shaft must remain continuous through the V-shaped join.")
        XCTAssertLessThan(alpha(x: 93, y: 32), 32, "The round shaft cap must not protrude beyond the requested arrow tip.")
    }

    func testShortThickArrowsStayInsideTheirEndpointsAndKeepTaperedWidthsOrdered() throws {
        let geometry = try XCTUnwrap(ArrowVectorGeometry(
            start: CGPoint(x: 28, y: 32),
            tip: CGPoint(x: 36, y: 32),
            lineWidth: 24
        ))
        let headWidth = hypot(
            geometry.headLeft.x - geometry.headRight.x,
            geometry.headLeft.y - geometry.headRight.y
        )
        let neckWidth = hypot(
            geometry.taperedNeckLeft.x - geometry.taperedNeckRight.x,
            geometry.taperedNeckLeft.y - geometry.taperedNeckRight.y
        )
        let tailWidth = hypot(
            geometry.taperedTailLeft.x - geometry.taperedTailRight.x,
            geometry.taperedTailLeft.y - geometry.taperedTailRight.y
        )
        XCTAssertLessThan(tailWidth, neckWidth)
        XCTAssertLessThan(neckWidth, headWidth)
        XCTAssertLessThan(geometry.shaftLineWidth, headWidth)

        for arrowStyle in [ArrowHeadStyle.filled, .double, .tapered] {
            let width = 64
            let height = 64
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let item = AnnotationItem(
                kind: .arrow,
                zIndex: 0,
                geometry: .line(start: CGPoint(x: 28, y: 32), end: CGPoint(x: 36, y: 32)),
                style: AnnotationStyle(
                    strokeColor: .systemRed,
                    lineWidth: 24,
                    arrowHeadStyle: arrowStyle
                )
            )
            XCTAssertTrue(AnnotationVectorRenderer().draw(
                item: item,
                in: context,
                colorSpace: colorSpace
            ))
            let rendered = try XCTUnwrap(context.makeImage())
            let bytes = ImageTestSupport.rgbaBytes(for: rendered)
            func alpha(x: Int, y: Int) -> UInt8 {
                bytes[(y * rendered.width + x) * 4 + 3]
            }

            XCTAssertGreaterThan(alpha(x: 34, y: 32), 200, "The short (arrowStyle.rawValue) arrow must remain visible.")
            XCTAssertLessThan(alpha(x: 40, y: 32), 32, "The (arrowStyle.rawValue) arrow must not paint beyond its tip.")
            XCTAssertLessThan(alpha(x: 24, y: 32), 32, "The (arrowStyle.rawValue) arrow must not paint behind its start.")
            XCTAssertLessThan(alpha(x: 34, y: 42), 32, "The (arrowStyle.rawValue) arrow width must shrink with the available geometry.")
        }
    }

    func testShapeFillAndTaperedArrowStylesRoundTrip() throws {
        var style = AnnotationStyle(strokeColor: .systemRed)
        XCTAssertEqual(style.shapeFillMode, .outline)

        style.shapeFillMode = .filled
        style.arrowHeadStyle = .tapered
        XCTAssertEqual(style.fillColor, style.strokeColor)

        let decoded = try JSONDecoder().decode(
            AnnotationStyle.self,
            from: JSONEncoder().encode(style)
        )
        XCTAssertEqual(decoded.shapeFillMode, .filled)
        XCTAssertEqual(decoded.arrowHeadStyle, .tapered)

        style.shapeFillMode = .outline
        XCTAssertNil(style.fillColor)
    }

    func testHighlightStyleKeepsSemanticColorSeparateFromFillOpacity() {
        let blue = RGBAColor(red: 0, green: 0.478, blue: 1)
        let source = AnnotationStyle(
            strokeColor: .systemYellow,
            fillColor: .yellowHighlight,
            lineWidth: 7
        )

        let recolored = source.applyingColor(blue, for: .highlight)

        XCTAssertEqual(recolored.strokeColor, blue)
        XCTAssertEqual(
            recolored.fillColor,
            blue.withAlphaComponent(AnnotationStyle.highlightFillAlpha)
        )
        XCTAssertEqual(recolored.lineWidth, source.lineWidth)
        XCTAssertEqual(recolored.strokeColor.alpha, 1)
        XCTAssertEqual(
            recolored.fillColor?.alpha,
            AnnotationStyle.highlightFillAlpha
        )
        XCTAssertEqual(recolored.asHighlightStyle(), recolored)

        let counter = AnnotationStyle(
            strokeColor: .systemRed,
            fillColor: .white
        ).applyingColor(blue, for: .counter)
        XCTAssertEqual(counter.strokeColor, blue)
        XCTAssertEqual(counter.fillColor, .white)
    }

    func testAnnotationDocumentNormalizesLegacyClearStrokeHighlightsForEditing() {
        let legacyHighlightID = UUID()
        let canonicalHighlightID = UUID()
        let rectangleID = UUID()
        let legacyGeometry = CGRect(x: 8, y: 12, width: 54, height: 6)
        let canonicalStyle = AnnotationStyle(
            strokeColor: .systemYellow,
            fillColor: .yellowHighlight,
            lineWidth: 5
        ).asHighlightStyle()
        let untouchedRectangle = AnnotationItem(
            id: rectangleID,
            kind: .rectangle,
            zIndex: 2,
            geometry: .rect(CGRect(x: 4, y: 4, width: 20, height: 20)),
            style: AnnotationStyle(strokeColor: .clear, fillColor: .systemRed)
        )
        var document = AnnotationTestSupport.document(annotations: [
            AnnotationItem(
                id: legacyHighlightID,
                kind: .highlight,
                zIndex: 0,
                geometry: .rect(legacyGeometry),
                style: AnnotationStyle(
                    strokeColor: .clear,
                    fillColor: .yellowHighlight,
                    lineWidth: 9
                )
            ),
            AnnotationItem(
                id: canonicalHighlightID,
                kind: .highlight,
                zIndex: 1,
                geometry: .rect(CGRect(x: 10, y: 30, width: 40, height: 8)),
                style: canonicalStyle
            ),
            untouchedRectangle
        ])

        XCTAssertEqual(document.normalizeHighlightStylesForEditing(), 1)

        let migrated = document.annotations[0]
        XCTAssertEqual(migrated.id, legacyHighlightID)
        XCTAssertEqual(migrated.geometry, .rect(legacyGeometry))
        XCTAssertEqual(migrated.style.strokeColor, .systemYellow)
        XCTAssertEqual(migrated.style.fillColor, .yellowHighlight)
        XCTAssertEqual(migrated.style.lineWidth, 9)
        XCTAssertEqual(document.annotations[1].style, canonicalStyle)
        XCTAssertEqual(document.annotations[2], untouchedRectangle)

        let normalizedDocument = document
        XCTAssertEqual(document.normalizeHighlightStylesForEditing(), 0)
        XCTAssertEqual(document, normalizedDocument)

        let customBlue = blueHighlightStyleForLegacyMigration()
        var customDocument = AnnotationTestSupport.document(annotations: [
            AnnotationItem(
                kind: .highlight,
                zIndex: 0,
                geometry: .rect(legacyGeometry),
                style: customBlue
            )
        ])
        XCTAssertEqual(customDocument.normalizeHighlightStylesForEditing(), 1)
        XCTAssertEqual(
            customDocument.annotations[0].style.strokeColor,
            customBlue.fillColor?.withAlphaComponent(1)
        )
        XCTAssertEqual(
            customDocument.annotations[0].style.fillColor?.alpha,
            AnnotationStyle.highlightFillAlpha
        )
        XCTAssertEqual(
            customDocument.annotations[0].style.fillColor,
            customBlue.fillColor?.withAlphaComponent(AnnotationStyle.highlightFillAlpha)
        )
    }

    private func blueHighlightStyleForLegacyMigration() -> AnnotationStyle {
        AnnotationStyle(
            strokeColor: .clear,
            fillColor: RGBAColor(red: 0, green: 0.478, blue: 1, alpha: 0.2)
        )
    }

    func testRendererCoversEveryRequiredAnnotationKind() throws {
        let base = ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1,
            red: 0.2
        ).capturedImage.image
        let document = AnnotationTestSupport.document(annotations: AnnotationTestSupport.allRenderableItems)

        let rendered = try AnnotationRenderer().render(document: document, baseImage: base, scale: 1)

        XCTAssertEqual(rendered.width, 100)
        XCTAssertEqual(rendered.height, 100)
    }

    func testSpotlightUsesANativeStyleRectangularMask() throws {
        let base = ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 20, height: 20),
            scale: 1,
            red: 1
        ).capturedImage.image
        let document = AnnotationTestSupport.document(
            annotations: [
                AnnotationItem(
                    kind: .spotlight,
                    zIndex: 0,
                    geometry: .rect(CGRect(x: 5, y: 5, width: 10, height: 10))
                )
            ],
            canvasSize: CGSize(width: 20, height: 20)
        )

        let rendered = try AnnotationRenderer().render(document: document, baseImage: base, scale: 1)
        let bytes = ImageTestSupport.rgbaBytes(for: rendered)
        let highlightedCorner = (6 * rendered.width + 6) * 4
        let dimmedCorner = (1 * rendered.width + 1) * 4

        XCTAssertGreaterThan(bytes[highlightedCorner], 230)
        XCTAssertLessThan(bytes[dimmedCorner], 150)
    }

    func testSpotlightVectorMaskCoversLiveExpandedCanvasBounds() throws {
        let width = 30
        let height = 20
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let spotlight = AnnotationItem(
            kind: .spotlight,
            zIndex: 0,
            geometry: .rect(CGRect(x: 5, y: 5, width: 10, height: 10))
        )

        XCTAssertTrue(AnnotationVectorRenderer().draw(
            item: spotlight,
            in: context,
            colorSpace: colorSpace,
            canvasBounds: CGRect(x: 0, y: 0, width: width, height: height)
        ))
        let rendered = try XCTUnwrap(context.makeImage())
        let bytes = ImageTestSupport.rgbaBytes(for: rendered)
        let focusPixel = (10 * rendered.width + 10) * 4
        let newlyExposedPixel = (10 * rendered.width + 25) * 4

        XCTAssertGreaterThan(bytes[focusPixel], 230)
        XCTAssertLessThan(bytes[newlyExposedPixel], 150)
    }

    func testNonUniformShapeResizePreservesPhysicalStrokeWidth() throws {
        let base = ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 2,
            red: 0
        ).capturedImage.image
        let rectangle = AnnotationItem(
            kind: .rectangle,
            zIndex: 0,
            geometry: .rect(CGRect(x: 30, y: 30, width: 20, height: 20)),
            style: AnnotationStyle(strokeColor: .systemRed, lineWidth: 1.5),
            transform: AnnotationTransform(scaleX: 3, scaleY: 2)
        )
        let document = AnnotationTestSupport.document(annotations: [rectangle])

        let rendered = try AnnotationRenderer().render(
            document: document,
            baseImage: base,
            scale: 2
        )
        let thicknesses = ImageTestSupport.redRectangleStrokeThicknesses(in: rendered)

        XCTAssertEqual(thicknesses.horizontal, 3, accuracy: 0.05)
        XCTAssertEqual(thicknesses.vertical, 3, accuracy: 0.05)
    }

    @MainActor
    func testAnnotationTextLayoutMatchesTextKitAndPreservesBaselineAnchor() {
        var style = AnnotationStyle(
            fontSize: 18,
            fontWeight: .semibold,
            textAlignment: .leading
        )
        let text = "这个位置 First"
        let font = AnnotationTextLayout.font(style: style)
        let metrics = AnnotationTextLayout.lineMetrics(for: text, style: style)

        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
        editor.isRichText = false
        editor.font = font
        editor.string = text
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.containerSize = CGSize(width: 400, height: 80)
        let textContainer = editor.textContainer!
        let layoutManager = editor.layoutManager!
        layoutManager.ensureLayout(for: textContainer)

        XCTAssertEqual(
            metrics.width,
            layoutManager.usedRect(for: textContainer).width,
            accuracy: 0.001,
            "The renderer and native editor must resolve the same system font and fallback glyph widths."
        )
        XCTAssertNotEqual(
            CTFontCopyPostScriptName(font as CTFont) as String,
            "Helvetica",
            "The semibold system font must not silently fall back to Helvetica during rendering."
        )

        let baselineAnchor = CGPoint(x: 173.25, y: 91.75)
        for alignment in AnnotationTextAlignment.allCases {
            style.textAlignment = alignment
            let rect = AnnotationTextLayout.annotationRect(
                baselineAnchor: baselineAnchor,
                text: text,
                style: style
            )
            let recoveredAnchor = AnnotationTextLayout.alignmentAnchor(
                in: rect,
                style: style
            )
            XCTAssertEqual(recoveredAnchor.x, baselineAnchor.x, accuracy: 0.001)
            XCTAssertEqual(recoveredAnchor.y, baselineAnchor.y, accuracy: 0.001)
            XCTAssertEqual(
                AnnotationTextLayout.lineOriginX(
                    in: rect,
                    lineWidth: metrics.width,
                    alignment: alignment
                ),
                AnnotationTextLayout.lineOriginX(
                    alignmentAnchorX: baselineAnchor.x,
                    lineWidth: metrics.width,
                    alignment: alignment
                ),
                accuracy: 0.001
            )
        }

        var customFontStyle = style
        customFontStyle.fontName = "Helvetica"
        XCTAssertEqual(
            AnnotationTextLayout.font(style: customFontStyle).fontName,
            "Helvetica"
        )
        let decodedStyle = try? JSONDecoder().decode(
            AnnotationStyle.self,
            from: JSONEncoder().encode(customFontStyle)
        )
        XCTAssertEqual(decodedStyle?.fontName, "Helvetica")
    }

    func testTextUsesDedicatedSelectionChromeWhileShapesKeepStandardHandles() {
        let geometry = AnnotationSelectionGeometry()
        let text = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(CGRect(x: 20, y: 30, width: 80, height: 24)),
            text: "Text"
        )
        let rectangle = AnnotationItem(
            kind: .rectangle,
            zIndex: 1,
            geometry: .rect(CGRect(x: 20, y: 30, width: 80, height: 24))
        )

        XCTAssertTrue(text.kind.allowsUserResize)
        XCTAssertFalse(text.kind.usesStandardSelectionResizeHandles)
        XCTAssertTrue(
            geometry.handlePoints(for: text).isEmpty,
            "Text font resizing belongs exclusively to its three-handle chrome."
        )
        XCTAssertEqual(geometry.handlePoints(for: rectangle).count, 8)
    }

    func testRendererPreservesBaseImageVerticalOrientationAfterAnnotation() throws {
        let base = ImageTestSupport.verticallyAsymmetricImage()
        let rectangle = AnnotationItem(
            kind: .rectangle,
            zIndex: 0,
            geometry: .rect(CGRect(x: 6, y: 6, width: 8, height: 8))
        )
        let document = AnnotationTestSupport.document(
            annotations: [rectangle],
            canvasSize: CGSize(width: base.width, height: base.height)
        )

        let rendered = try AnnotationRenderer().render(document: document, baseImage: base, scale: 1)
        let baseBytes = ImageTestSupport.rgbaBytes(for: base)
        let renderedBytes = ImageTestSupport.rgbaBytes(for: rendered)
        let rowByteCount = base.width * 4

        XCTAssertNotEqual(
            Array(baseBytes.prefix(rowByteCount)),
            Array(baseBytes.suffix(rowByteCount)),
            "The fixture must distinguish the image's two vertical ends."
        )
        XCTAssertEqual(
            Array(renderedBytes.prefix(rowByteCount)),
            Array(baseBytes.prefix(rowByteCount)),
            "Rendering an annotation must not flip the base image vertically."
        )
        XCTAssertEqual(
            Array(renderedBytes.suffix(rowByteCount)),
            Array(baseBytes.suffix(rowByteCount)),
            "Rendering an annotation must preserve the opposite edge as well."
        )
    }

    func testRendererCropRotationPaddingAndRoundedBackground() throws {
        let base = ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1,
            red: 0.2
        ).capturedImage.image
        var document = AnnotationTestSupport.document()
        document.crop = CropState(rect: CGRect(x: 10, y: 20, width: 40, height: 30))
        document.rotation = RotationState(quarterTurnsClockwise: 1)
        document.background = .padded(color: .white, amount: 5)
        document.canvasEffects = CanvasEffects(cornerRadius: 4)

        let rendered = try AnnotationRenderer().render(document: document, baseImage: base, scale: 1)

        XCTAssertEqual(rendered.width, 40)
        XCTAssertEqual(rendered.height, 50)
    }

    @MainActor
    func testMultiSelectionAlignmentAndDistributionAreUndoable() {
        let items = [
            AnnotationItem(kind: .rectangle, zIndex: 0, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10))),
            AnnotationItem(kind: .rectangle, zIndex: 1, geometry: .rect(CGRect(x: 30, y: 10, width: 10, height: 10))),
            AnnotationItem(kind: .rectangle, zIndex: 2, geometry: .rect(CGRect(x: 100, y: 20, width: 10, height: 10)))
        ]
        let controller = AnnotationDocumentController(document: AnnotationTestSupport.document(annotations: items))
        controller.selectedItemIDs = Set(items.map(\.id))

        controller.distributeSelection(along: .horizontal)
        XCTAssertEqual(controller.document.annotations[1].transform.translation.width, 20)
        controller.alignSelection(.bottom)
        XCTAssertEqual(controller.document.annotations[1].transform.translation.height, -10)
        XCTAssertEqual(controller.document.annotations[2].transform.translation.height, -20)
        controller.undo()
        XCTAssertEqual(controller.document.annotations[1].transform.translation.height, 0)
    }

    func testSystemColorConversionUsesNamedProfilesAndRoundTrips() throws {
        let converter = SystemColorSpaceConverter()
        let source = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let p3 = try converter.convert(
            RGBAComponents(red: 1, green: 0, blue: 0, alpha: 1),
            from: source,
            to: .displayP3
        )
        XCTAssertEqual(p3.red, 0.917, accuracy: 0.02)
        XCTAssertEqual(p3.green, 0.200, accuracy: 0.02)
        XCTAssertEqual(p3.blue, 0.139, accuracy: 0.02)

        let p3Space = try XCTUnwrap(ColorSpacePreference.displayP3.nsColorSpace.cgColorSpace)
        let roundTrip = try converter.convert(p3, from: p3Space, to: .sRGB)
        XCTAssertEqual(roundTrip.red, 1, accuracy: 0.02)
        XCTAssertEqual(roundTrip.green, 0, accuracy: 0.02)
        XCTAssertEqual(roundTrip.blue, 0, accuracy: 0.02)
        for preference in ColorSpacePreference.allCases {
            XCTAssertNotNil(preference.nsColorSpace.cgColorSpace)
        }
    }

    @MainActor
    func testFrozenPixelSamplerTracksDisplayPixelAndColorSpace() async throws {
        let preparation = RegionCapturePreparation(displays: [
            ImageTestSupport.displayCapture(
                id: 42,
                frame: CGRect(x: -100, y: 0, width: 100, height: 100),
                scale: 2,
                red: 1
            )
        ])
        let sampler = try FrozenFramePixelSampler(preparation: preparation)
        let frame = try await sampler.sampleFrame(
            at: CGPoint(x: -75, y: 25),
            colorSpace: .sRGB,
            radius: 5
        )
        let sample = frame.sample

        XCTAssertEqual(sample.displayID, 42)
        XCTAssertEqual(sample.pixelPoint, CGPoint(x: 50, y: 150))
        XCTAssertEqual(sample.components.red, 1, accuracy: 1.0 / 255.0)
        XCTAssertEqual(sample.hexString, "#FF0000")
        let p3 = try await sampler.sampleFrame(
            at: CGPoint(x: -75, y: 25),
            colorSpace: .displayP3,
            radius: 5
        ).sample
        XCTAssertTrue(try XCTUnwrap(p3.displayP3CSSString).hasPrefix("color(display-p3 "))
        let adobe = try await sampler.sampleFrame(
            at: CGPoint(x: -75, y: 25),
            colorSpace: .adobeRGB1998,
            radius: 5
        ).sample
        XCTAssertTrue(adobe.copyRepresentation(format: .hex).hasPrefix("Adobe RGB (1998) "))
        XCTAssertEqual(frame.magnifier.image.width, 11)
    }

    func testMeasurementReportsPointPixelScaleAndConstraint() throws {
        let displays = [
            DisplayDescriptor(
                id: 1,
                name: "1x",
                frame: CGRect(x: -100, y: 0, width: 100, height: 100),
                pixelSize: CGSize(width: 100, height: 100),
                scale: 1,
                isCurrent: false
            ),
            DisplayDescriptor(
                id: 2,
                name: "Retina",
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                pixelSize: CGSize(width: 200, height: 200),
                scale: 2,
                isCurrent: true
            )
        ]
        let calculator = ScreenMeasurementCalculator(displays: displays)
        let measurement = try calculator.measurement(
            shape: .rectangle,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 40, y: 50)
        )

        XCTAssertEqual(measurement.widthInPoints, 30)
        XCTAssertEqual(measurement.heightInPoints, 40)
        XCTAssertEqual(measurement.distanceInPoints, 50)
        XCTAssertEqual(measurement.widthInPixels, 60)
        XCTAssertEqual(measurement.heightInPixels, 80)
        XCTAssertEqual(measurement.distanceInPixels, 100)
        XCTAssertTrue(measurement.copyRepresentation.contains("scale 2.00x"))
        let constrained = calculator.constrainedEnd(start: .zero, proposedEnd: CGPoint(x: 9, y: 5))
        XCTAssertEqual(constrained.x, constrained.y, accuracy: 0.001)
    }

    func testHistoryStoreRoundTripsSkipsCorruptionAndEnforcesRetention() async throws {
        let result = try await HistoryTestSupport.exerciseStore()
        XCTAssertEqual(result.initialSummaryCount, 1)
        XCTAssertTrue(result.filesWereComplete)
        XCTAssertEqual(result.loadedAnnotationCount, 1)
        XCTAssertEqual(result.validCountAfterCorruption, 1)
        XCTAssertTrue(result.validRecordWasRemovedByRetention)
        XCTAssertEqual(result.countAfterClear, 0)
    }
}
#else
@Test
func openSourceProviderEntitlesEveryDeclaredFeature() {
    let provider = OpenSourceEntitlementProvider()
    for feature in AppFeature.allCases {
        #expect(provider.isEntitled(to: feature))
    }
}

@Test
func noOpUpdateCheckerReportsNoUpdate() async throws {
    let result = try await NoOpUpdateChecker().checkForUpdates()
    #expect(result.isUpdateAvailable == false)
    #expect(result.version == nil)
}

@Test @MainActor
func defaultSettingsMatchProductDefaults() {
    let settings = AppSettings.defaults
    #expect(settings.general.showsMenuBarIcon)
    #expect(!settings.general.showsDockIcon)
    #expect(settings.capture.presentsPinnedShot)
    #expect(settings.capture.showsQuickToolbar)
    #expect(settings.capture.recognizesInterfaceElements)
    #expect(!settings.capture.automaticallyCopies)
    #expect(!settings.capture.automaticallySaves)
    #expect(!settings.history.isEnabled)
    #expect(settings.output.format == .png)
    #expect(settings.colorPicker.colorSpace == .sRGB)
    #expect(settings.general.startupBehavior == .doNothing)
    #expect(settings.editor.defaultLineWidthUnit == .pixels)
    #expect(settings.editor.defaultFontSizeUnit == .pixels)
    #expect(settings.editor.defaultRectangleCornerRadiusUnit == .pixels)
    #expect(settings.editor.defaultRectangleCornerRadius == 4)
    #expect(settings.editor.defaultFontSize == 18)
    #expect(
        settings.editor.toolbarColorHexes == AnnotationColorPalette.factoryDefaultHexColors
    )
    #expect(settings.editor.availableColorHexes == settings.editor.toolbarColorHexes)
    #expect(
        AnnotationColorPalette.displayedHexColors(
            configuredHexColors: AnnotationColorPalette.factoryDefaultHexColors,
            currentHex: "#007AFF"
        ) == AnnotationColorPalette.factoryDefaultHexColors
    )
    #expect(
        AnnotationColorPalette.displayedHexColors(
            configuredHexColors: AnnotationColorPalette.factoryDefaultHexColors,
            currentHex: "#123456"
        ) == AnnotationColorPalette.factoryDefaultHexColors + ["#123456"]
    )
    #expect(settings.editor.defaultColorHex == "#FF3B30")
    #expect(settings.editor.defaultTextColorHex == "#FF3B30")
    #expect(settings.editor.defaultRectangleColorHex == "#FF3B30")
    #expect(settings.editor.defaultEllipseColorHex == "#FF3B30")
    #expect(settings.editor.defaultTextFontName == nil)
    #expect(AnnotationTool.highlight.toolbarSystemSymbolName == "rectangle.fill")
    for tool in AnnotationTool.allCases {
        #expect(
            NSImage(
                systemSymbolName: tool.toolbarSystemSymbolName,
                accessibilityDescription: tool.rawValue
            ) != nil
        )
    }
    #expect(!AnnotationTool.quickToolbarOrder.contains(.crop))
    #expect(settings.shortcuts.annotationToolAssignments[.crop] == nil)
    #expect(
        settings.shortcuts.annotationTool(
            matching: HotKeyShortcut(keyCode: 24, modifiers: [])
        ) == nil
    )
    #expect(
        AnnotationTool.quickToolbarOrder.compactMap {
            settings.shortcuts.annotationToolAssignments[$0]?.displayString
        } == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "["]
    )
}

@Test @MainActor
func settingsStoreRoundTripsOneVersionedDocument() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
    try store.update(\AppSettings.general.showsDockIcon, to: true)
    try store.update(\AppSettings.editor.defaultRectangleCornerRadius, to: 12.5)
    try store.update { settings in
        settings.editor.defaultTextColorHex = "#007AFF"
        settings.editor.defaultRectangleColorHex = "#34C759"
        settings.editor.defaultEllipseColorHex = "#AF52DE"
        settings.editor.defaultTextFontName = "Helvetica"
    }

    let reloaded = SettingsStore(defaults: context.defaults, storageKey: context.key)
    #expect(reloaded.settings.general.showsDockIcon)
    #expect(reloaded.settings.editor.defaultRectangleCornerRadius == 12.5)
    #expect(reloaded.settings.editor.defaultTextColorHex == "#007AFF")
    #expect(reloaded.settings.editor.defaultRectangleColorHex == "#34C759")
    #expect(reloaded.settings.editor.defaultEllipseColorHex == "#AF52DE")
    #expect(reloaded.settings.editor.defaultTextFontName == "Helvetica")
    #expect(reloaded.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(reloaded.loadError == nil)
}

@Test @MainActor
func corruptSettingsAreObservable() {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(Data("not-json".utf8), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
    #expect(store.loadError != nil)
    #expect(store.settings == .defaults)
}

@Test @MainActor
func versionOneSettingsMigrateToCurrentSchema() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(try SettingsTestSupport.legacyVersionOneData(), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(store.settings.general.startupBehavior == .doNothing)
    #expect(store.settings.editor.defaultRectangleCornerRadius == 4)
    #expect(store.loadError == nil)
}

@Test @MainActor
func versionTwoSettingsMigrateRectangleCornerRadiusDefault() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(try SettingsTestSupport.legacyVersionTwoData(), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(store.settings.editor.defaultRectangleCornerRadius == 4)
    #expect(store.loadError == nil)
}

@Test @MainActor
func versionThreeSettingsMigratePixelLineWidthUnitDefault() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(try SettingsTestSupport.legacyVersionThreeData(), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(store.settings.editor.defaultLineWidthUnit == .pixels)
    #expect(store.loadError == nil)
}

@Test @MainActor
func versionFourSettingsMigrateAnnotationToolShortcutDefaults() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(try SettingsTestSupport.legacyVersionFourData(), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(
        store.settings.shortcuts.annotationToolAssignments
            == ShortcutSettings.defaultAnnotationToolAssignments
    )
    #expect(store.loadError == nil)
}

@Test @MainActor
func versionFiveSettingsPreserveLegacyCustomDefaultColor() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(try SettingsTestSupport.legacyVersionFiveData(), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(store.settings.editor.defaultColorHex == "#123456")
    #expect(
        store.settings.editor.toolbarColorHexes
            == AnnotationColorPalette.factoryDefaultHexColors + ["#123456"]
    )
    #expect(store.loadError == nil)
}

@Test @MainActor
func versionFiveMigrationPreservesShortcutThatNowDefaultsToSpotlight() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(
        try SettingsTestSupport.legacyVersionFiveData(usesSpotlightDefaultForRectangle: true),
        forKey: context.key
    )

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(
        store.settings.shortcuts.annotationToolAssignments[.rectangle]
            == HotKeyShortcut(keyCode: 33, modifiers: [])
    )
    #expect(
        store.settings.shortcuts.annotationToolAssignments[.spotlight]
            == HotKeyShortcut(keyCode: 30, modifiers: [])
    )
    #expect(store.loadError == nil)
}

@Test @MainActor
func versionSixSettingsMigrateToolDefaultsAndElementRecognition() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(try SettingsTestSupport.legacyVersionSixData(), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(store.settings.editor.defaultTextColorHex == "#123456")
    #expect(store.settings.editor.defaultRectangleColorHex == "#123456")
    #expect(store.settings.editor.defaultEllipseColorHex == "#123456")
    #expect(store.settings.editor.defaultTextFontName == nil)
    #expect(store.settings.capture.recognizesInterfaceElements)
    #expect(store.loadError == nil)
}

@Test @MainActor
func versionSevenSettingsMigratePixelMeasurementUnitDefaults() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(try SettingsTestSupport.legacyVersionSevenData(), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(store.settings.editor.defaultLineWidthUnit == .points)
    #expect(store.settings.editor.defaultFontSizeUnit == .pixels)
    #expect(store.settings.editor.defaultRectangleCornerRadiusUnit == .pixels)
    #expect(store.loadError == nil)
}

@Test @MainActor
func versionEightSettingsMigrateLegacyCustomColorsToCompleteToolbarPalette() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(try SettingsTestSupport.legacyVersionEightData(), forKey: context.key)

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.settings.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(
        store.settings.editor.toolbarColorHexes
            == AnnotationColorPalette.factoryDefaultHexColors + ["#12ABEF", "#654321"]
    )
    #expect(store.settings.editor.defaultColorHex == "#12ABEF")
    #expect(store.settings.editor.defaultTextColorHex == "#12ABEF")
    #expect(store.settings.editor.defaultRectangleColorHex == "#12ABEF")
    #expect(store.settings.editor.defaultEllipseColorHex == "#12ABEF")
    #expect(store.loadError == nil)
}

@Test @MainActor
func currentSettingsMissingToolbarPaletteFailFast() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(
        try SettingsTestSupport.currentVersionDataWithoutToolbarColors(explicitNull: false),
        forKey: context.key
    )

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.loadError != nil)
    #expect(store.settings == .defaults)
}

@Test @MainActor
func currentSettingsNullToolbarPaletteFailFast() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    context.defaults.set(
        try SettingsTestSupport.currentVersionDataWithoutToolbarColors(explicitNull: true),
        forKey: context.key
    )

    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)

    #expect(store.loadError != nil)
    #expect(store.settings == .defaults)
}

@Test @MainActor
func completeToolbarPaletteRoundTripsWithoutLegacyCustomColorKey() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
    var editor = EditorSettings(
        defaultColorHex: "#12ABEF",
        toolbarColorHexes: ["#12ABEF", "#654321"]
    )
    try store.update(\AppSettings.editor, to: editor)

    let reloaded = SettingsStore(defaults: context.defaults, storageKey: context.key)
    #expect(reloaded.settings.editor.toolbarColorHexes == ["#12ABEF", "#654321"])
    #expect(reloaded.settings.editor.defaultColorHex == "#12ABEF")
    #expect(reloaded.loadError == nil)

    let persistedData = try #require(context.defaults.data(forKey: context.key))
    let document = try #require(
        JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
    )
    let persistedEditor = try #require(document["editor"] as? [String: Any])
    #expect(
        persistedEditor["toolbarColorHexes"] as? [String] == ["#12ABEF", "#654321"]
    )
    #expect(persistedEditor["customColorHexes"] == nil)

    let original = editor
    #expect(throws: (any Error).self) {
        try editor.addToolbarColor("12abef")
    }
    #expect(editor == original)
}

@Test
func removingFactoryToolbarColorRedirectsEveryDefaultAtomically() throws {
    var editor = EditorSettings()
    let removedHex = "#FF3B30"
    let replacementHex = "#007AFF"

    try editor.removeToolbarColor(removedHex, replacingUsesWith: replacementHex)

    #expect(
        editor.toolbarColorHexes
            == AnnotationColorPalette.factoryDefaultHexColors.filter { $0 != removedHex }
    )
    #expect(editor.defaultColorHex == replacementHex)
    #expect(editor.defaultTextColorHex == replacementHex)
    #expect(editor.defaultRectangleColorHex == replacementHex)
    #expect(editor.defaultEllipseColorHex == replacementHex)
    #expect(try editor.validatedColorPalette() == editor)
}

@Test
func removingLastToolbarColorFailsAtomically() {
    var editor = EditorSettings(
        defaultColorHex: "#12ABEF",
        toolbarColorHexes: ["#12ABEF"]
    )
    let original = editor

    #expect(throws: (any Error).self) {
        try editor.removeToolbarColor("#12ABEF", replacingUsesWith: "#12ABEF")
    }
    #expect(editor == original)
}

@Test
func customOnlyToolbarPaletteIsValid() throws {
    let editor = EditorSettings(
        defaultColorHex: "12abef",
        defaultTextColorHex: "#654321",
        defaultRectangleColorHex: "12abef",
        defaultEllipseColorHex: "#654321",
        toolbarColorHexes: ["12abef", "#654321"]
    )

    let validated = try editor.validatedColorPalette()

    #expect(validated.toolbarColorHexes == ["#12ABEF", "#654321"])
    #expect(validated.defaultColorHex == "#12ABEF")
    #expect(validated.defaultTextColorHex == "#654321")
    #expect(validated.defaultRectangleColorHex == "#12ABEF")
    #expect(validated.defaultEllipseColorHex == "#654321")
}

@Test
func restoringFactoryToolbarColorsPreservesNonPaletteSettingsAndRedirectsDefaults() throws {
    var editor = EditorSettings(
        defaultColorHex: "#12ABEF",
        defaultTextColorHex: "#007AFF",
        defaultRectangleColorHex: "#654321",
        defaultEllipseColorHex: "#FF3B30",
        toolbarColorHexes: ["#12ABEF", "#007AFF", "#654321", "#FF3B30"],
        defaultLineWidth: 7.5,
        defaultLineWidthUnit: .points,
        defaultRectangleCornerRadius: 11,
        defaultRectangleCornerRadiusUnit: .points,
        defaultFontSize: 26,
        defaultFontSizeUnit: .points,
        defaultTextFontName: "Helvetica",
        defaultBackgroundHex: "#102030"
    )

    editor.restoreFactoryToolbarColors()

    #expect(editor.toolbarColorHexes == AnnotationColorPalette.factoryDefaultHexColors)
    #expect(editor.defaultColorHex == "#FF3B30")
    #expect(editor.defaultTextColorHex == "#007AFF")
    #expect(editor.defaultRectangleColorHex == "#FF3B30")
    #expect(editor.defaultEllipseColorHex == "#FF3B30")
    #expect(editor.defaultLineWidth == 7.5)
    #expect(editor.defaultLineWidthUnit == .points)
    #expect(editor.defaultRectangleCornerRadius == 11)
    #expect(editor.defaultRectangleCornerRadiusUnit == .points)
    #expect(editor.defaultFontSize == 26)
    #expect(editor.defaultFontSizeUnit == .points)
    #expect(editor.defaultTextFontName == "Helvetica")
    #expect(editor.defaultBackgroundHex == "#102030")
    #expect(try editor.validatedColorPalette() == editor)
}

@Test
func restoringFactoryToolbarColorsCanPreserveCustomColorsAndToolDefaults() throws {
    var editor = EditorSettings(
        defaultColorHex: "#12ABEF",
        defaultTextColorHex: "#007AFF",
        defaultRectangleColorHex: "#654321",
        defaultEllipseColorHex: "#FF3B30",
        toolbarColorHexes: ["#654321", "#007AFF", "#12ABEF", "#FF3B30"],
        defaultLineWidth: 7.5,
        defaultTextFontName: "Helvetica"
    )

    editor.restoreFactoryToolbarColorsPreservingCustomColors()
    let firstRestoration = editor
    editor.restoreFactoryToolbarColorsPreservingCustomColors()

    #expect(
        editor.toolbarColorHexes
            == AnnotationColorPalette.factoryDefaultHexColors + ["#654321", "#12ABEF"]
    )
    #expect(editor.defaultColorHex == "#12ABEF")
    #expect(editor.defaultTextColorHex == "#007AFF")
    #expect(editor.defaultRectangleColorHex == "#654321")
    #expect(editor.defaultEllipseColorHex == "#FF3B30")
    #expect(editor.defaultLineWidth == 7.5)
    #expect(editor.defaultTextFontName == "Helvetica")
    #expect(editor == firstRestoration)
    #expect(try editor.validatedColorPalette() == editor)
}

@Test
func removingToolbarColorRejectsMissingReplacementAtomically() throws {
    var editor = EditorSettings()
    try editor.addToolbarColor("#12ABEF")
    editor.defaultTextColorHex = "#12ABEF"
    let original = editor

    #expect(throws: (any Error).self) {
        try editor.removeToolbarColor("#12ABEF", replacingUsesWith: "#123456")
    }
    #expect(editor == original)
}

@Test @MainActor
func annotationToolShortcutPersistsAcrossSettingsReload() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
    let custom = HotKeyShortcut(keyCode: 0, modifiers: [.shift])

    try store.update { settings in
        settings.shortcuts.annotationToolAssignments[.rectangle] = custom
    }

    let reloaded = SettingsStore(defaults: context.defaults, storageKey: context.key)
    #expect(reloaded.settings.shortcuts.annotationToolAssignments[.rectangle] == custom)
    #expect(reloaded.settings.shortcuts.annotationTool(matching: custom) == .rectangle)
    #expect(reloaded.loadError == nil)
}

@Test
func legacyCropShortcutIsDiscardedWhileVisibleCustomizationSurvives() throws {
    let customRectangleShortcut = HotKeyShortcut(keyCode: 42, modifiers: [.shift])
    var legacyAssignments = ShortcutSettings.defaultAnnotationToolAssignments
    legacyAssignments[.rectangle] = customRectangleShortcut
    legacyAssignments[.spotlight] = nil
    legacyAssignments[.crop] = HotKeyShortcut(keyCode: 33, modifiers: [])
    let legacySettings = ShortcutSettings(
        assignments: ShortcutSettings.defaults.assignments,
        annotationToolAssignments: legacyAssignments
    )

    let encoded = try JSONEncoder().encode(legacySettings)
    #expect(String(decoding: encoded, as: UTF8.self).contains("\"crop\""))

    let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: encoded)
    #expect(decoded.annotationToolAssignments[.crop] == nil)
    #expect(decoded.annotationToolAssignments[.rectangle] == customRectangleShortcut)
    #expect(
        decoded.annotationToolAssignments[.spotlight]
            == HotKeyShortcut(keyCode: 33, modifiers: [])
    )
}

@Test
func duplicateShortcutIsRejected() {
    let duplicate = HotKeyShortcut(keyCode: 0, modifiers: [.control, .option])
    let settings = ShortcutSettings(assignments: [
        .captureRegion: duplicate,
        .captureWindow: duplicate
    ])

    #expect(throws: (any Error).self) {
        try settings.validatingUniqueAssignments()
    }
}

@Test
func functionKeyDisplayAndClassificationUseCarbonKeyCodes() {
    let expectedNamesByKeyCode: [(keyCode: Int, name: String)] = [
        (kVK_F1, "F1"),
        (kVK_F2, "F2"),
        (kVK_F12, "F12"),
        (kVK_F20, "F20")
    ]

    for (keyCode, name) in expectedNamesByKeyCode {
        let shortcut = HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: [])
        #expect(shortcut.displayString == name)
        #expect(shortcut.isFunctionKey)
        #expect(shortcut.isValidGlobalShortcut)
    }

    let letterShortcut = HotKeyShortcut(keyCode: 0, modifiers: [])
    #expect(letterShortcut.displayString == "A")
    #expect(!letterShortcut.isFunctionKey)
    #expect(!letterShortcut.isValidGlobalShortcut)
    #expect(HotKeyShortcut(keyCode: 0, modifiers: [.command]).isValidGlobalShortcut)
    #expect(
        !HotKeyShortcut(
            keyCode: UInt32(kVK_F1),
            modifiers: HotKeyTestSupport.modifiersWithUnknownBit
        ).isValidGlobalShortcut
    )
}

@Test
func globalShortcutAdmissionAcceptsBareFunctionKeysAndModifiedLetters() throws {
    let settings = ShortcutSettings(assignments: [
        .captureRegion: HotKeyShortcut(keyCode: UInt32(kVK_F1), modifiers: []),
        .captureWindow: HotKeyShortcut(keyCode: UInt32(kVK_F20), modifiers: []),
        .colorPicker: HotKeyShortcut(keyCode: 0, modifiers: [.option])
    ])

    #expect(try settings.validatingUniqueAssignments() == settings)
}

@Test
func bareLetterGlobalShortcutIsRejectedByShortcutSettings() {
    let settings = ShortcutSettings(assignments: [
        .captureRegion: HotKeyShortcut(keyCode: 0, modifiers: [])
    ])

    do {
        _ = try settings.validatingUniqueAssignments()
        Issue.record("Expected invalidGlobalShortcut")
    } catch let ScreenshotAppError.invalidGlobalShortcut(action) {
        #expect(action == .captureRegion)
    } catch {
        Issue.record("Expected invalidGlobalShortcut, received \(error)")
    }
}

@Test
func unknownModifierBitsAreRejectedByShortcutSettings() {
    let settings = ShortcutSettings(assignments: [
        .captureRegion: HotKeyShortcut(
            keyCode: 0,
            modifiers: HotKeyTestSupport.modifiersWithUnknownBit
        )
    ])

    do {
        _ = try settings.validatingUniqueAssignments()
        Issue.record("Expected invalidGlobalShortcut")
    } catch let ScreenshotAppError.invalidGlobalShortcut(action) {
        #expect(action == .captureRegion)
    } catch {
        Issue.record("Expected invalidGlobalShortcut, received \(error)")
    }
}

@Test
func duplicateAnnotationToolShortcutIsRejected() {
    var settings = ShortcutSettings.defaults
    settings.annotationToolAssignments[.rectangle] = settings.annotationToolAssignments[.select]

    #expect(throws: (any Error).self) {
        try settings.validatingUniqueAssignments()
    }
}

@Test @MainActor
func duplicateAnnotationToolShortcutDoesNotMutateSettingsStore() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
    let original = store.settings

    #expect(throws: (any Error).self) {
        try store.update { settings in
            settings.shortcuts.annotationToolAssignments[.rectangle]
                = settings.shortcuts.annotationToolAssignments[.select]
        }
    }
    #expect(store.settings == original)
}

@Test @MainActor
func hotKeyRegistrationFailureRestoresPreviousAssignments() throws {
    let backend = FakeHotKeyBackend()
    let manager = try CarbonGlobalHotKeyManager(backend: backend)
    let previous = ShortcutSettings.defaults.assignments
    try manager.register(previous)
    var candidate = previous
    candidate[.captureRegion] = HotKeyShortcut(keyCode: 12, modifiers: [.control, .option])
    backend.failOnceForAction = .captureWindow

    #expect(throws: (any Error).self) {
        try manager.register(candidate)
    }
    #expect(manager.assignments == previous)
    #expect(backend.registrations.count == previous.count)
}

@Test @MainActor
func bareLetterGlobalShortcutDoesNotMutateManagerRegistrations() throws {
    let backend = FakeHotKeyBackend()
    let manager = try CarbonGlobalHotKeyManager(backend: backend)
    let previous = ShortcutSettings.defaults.assignments
    try manager.register(previous)
    let previousRegistrations = backend.registrations
    var candidate = previous
    candidate[.captureRegion] = HotKeyShortcut(keyCode: 0, modifiers: [])

    do {
        try manager.register(candidate)
        Issue.record("Expected invalidGlobalShortcut")
    } catch let ScreenshotAppError.invalidGlobalShortcut(action) {
        #expect(action == .captureRegion)
    } catch {
        Issue.record("Expected invalidGlobalShortcut, received \(error)")
    }
    #expect(manager.assignments == previous)
    #expect(backend.registrations == previousRegistrations)
}

@Test @MainActor
func bareLetterGlobalShortcutDoesNotMutateSettingsStore() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
    try store.update(\AppSettings.general.showsDockIcon, to: true)
    let previous = store.settings
    let previousData = context.defaults.data(forKey: context.key)

    do {
        try store.update { settings in
            settings.shortcuts.assignments[.captureRegion] = HotKeyShortcut(
                keyCode: 0,
                modifiers: []
            )
        }
        Issue.record("Expected invalidGlobalShortcut")
    } catch let ScreenshotAppError.invalidGlobalShortcut(action) {
        #expect(action == .captureRegion)
    } catch {
        Issue.record("Expected invalidGlobalShortcut, received \(error)")
    }
    #expect(store.settings == previous)
    #expect(context.defaults.data(forKey: context.key) == previousData)
}

@Test @MainActor
func unknownModifierBitsDoNotMutateManagerRegistrations() throws {
    let backend = FakeHotKeyBackend()
    let manager = try CarbonGlobalHotKeyManager(backend: backend)
    let previous = ShortcutSettings.defaults.assignments
    try manager.register(previous)
    let previousRegistrations = backend.registrations
    var candidate = previous
    candidate[.captureRegion] = HotKeyShortcut(
        keyCode: 0,
        modifiers: HotKeyTestSupport.modifiersWithUnknownBit
    )

    do {
        try manager.register(candidate)
        Issue.record("Expected invalidGlobalShortcut")
    } catch let ScreenshotAppError.invalidGlobalShortcut(action) {
        #expect(action == .captureRegion)
    } catch {
        Issue.record("Expected invalidGlobalShortcut, received \(error)")
    }
    #expect(manager.assignments == previous)
    #expect(backend.registrations == previousRegistrations)
}

@Test @MainActor
func unknownModifierBitsDoNotMutateSettingsStore() throws {
    let context = SettingsTestSupport.makeDefaults()
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    let store = SettingsStore(defaults: context.defaults, storageKey: context.key)
    try store.update(\AppSettings.general.showsDockIcon, to: true)
    let previous = store.settings
    let previousData = context.defaults.data(forKey: context.key)

    do {
        try store.update { settings in
            settings.shortcuts.assignments[.captureRegion] = HotKeyShortcut(
                keyCode: 0,
                modifiers: HotKeyTestSupport.modifiersWithUnknownBit
            )
        }
        Issue.record("Expected invalidGlobalShortcut")
    } catch let ScreenshotAppError.invalidGlobalShortcut(action) {
        #expect(action == .captureRegion)
    } catch {
        Issue.record("Expected invalidGlobalShortcut, received \(error)")
    }
    #expect(store.settings == previous)
    #expect(context.defaults.data(forKey: context.key) == previousData)
}

@Test
func screenCaptureFramesConvertToAppKitGlobalCoordinates() {
    let transformer = CoordinateTransformer(primaryDisplayHeight: 1_080)

    #expect(
        transformer.appKitRect(fromScreenCaptureRect: CGRect(x: 0, y: -900, width: 1_440, height: 900))
            == CGRect(x: 0, y: 1_080, width: 1_440, height: 900)
    )
    #expect(
        transformer.appKitRect(fromScreenCaptureRect: CGRect(x: 0, y: 1_080, width: 1_440, height: 900))
            == CGRect(x: 0, y: -900, width: 1_440, height: 900)
    )
}

@Test
func displayBackingMetricsUsesRetinaPixelsAndRejectsAxisMismatch() throws {
    let metrics = try DisplayBackingMetrics(
        logicalSize: CGSize(width: 1_728, height: 1_117),
        pixelSize: CGSize(width: 3_456, height: 2_234)
    )

    #expect(metrics.scale == 2)
    #expect(metrics.pixelSize == CGSize(width: 3_456, height: 2_234))
    #expect(throws: (any Error).self) {
        try DisplayBackingMetrics(
            logicalSize: CGSize(width: 100, height: 100),
            pixelSize: CGSize(width: 200, height: 100)
        )
    }
}

@Test
func screenCapturePixelGeometryPreservesAdjacentRetinaPixels() throws {
    let evenPixel = try ScreenCapturePixelGeometry(
        targetPixel: CGPoint(x: 1_600, y: 600),
        radius: 128,
        pixelSize: CGSize(width: 4_096, height: 2_304),
        scale: 2
    )
    let adjacentOddPixel = try ScreenCapturePixelGeometry(
        targetPixel: CGPoint(x: 1_601, y: 600),
        radius: 128,
        pixelSize: CGSize(width: 4_096, height: 2_304),
        scale: 2
    )
    let adjacentOddRow = try ScreenCapturePixelGeometry(
        targetPixel: CGPoint(x: 1_600, y: 601),
        radius: 128,
        pixelSize: CGSize(width: 4_096, height: 2_304),
        scale: 2
    )
    let oneXPixel = try ScreenCapturePixelGeometry(
        targetPixel: CGPoint(x: 1_600, y: 600),
        radius: 128,
        pixelSize: CGSize(width: 4_096, height: 2_304),
        scale: 1
    )
    let bottomRightPixel = try ScreenCapturePixelGeometry(
        targetPixel: CGPoint(x: 4_095, y: 2_303),
        radius: 128,
        pixelSize: CGSize(width: 4_096, height: 2_304),
        scale: 2
    )
    let fractionalScalePixel = try ScreenCapturePixelGeometry(
        targetPixel: CGPoint(x: 500, y: 300),
        radius: 128,
        pixelSize: CGSize(width: 1_500, height: 900),
        scale: 1.5
    )

    #expect(
        evenPixel.sourceRectInPoints
            == CGRect(x: 736, y: 236, width: 129, height: 129)
    )
    #expect(evenPixel.sourceRectInPoints == adjacentOddPixel.sourceRectInPoints)
    #expect(
        evenPixel.sourcePixelRect
            == CGRect(x: 1_472, y: 472, width: 258, height: 258)
    )
    #expect(evenPixel.targetPixelInImage == CGPoint(x: 128, y: 128))
    #expect(adjacentOddPixel.targetPixelInImage == CGPoint(x: 129, y: 128))
    #expect(adjacentOddRow.sourceRectInPoints == evenPixel.sourceRectInPoints)
    #expect(adjacentOddRow.targetPixelInImage == CGPoint(x: 128, y: 129))
    #expect(
        oneXPixel.sourcePixelRect
            == CGRect(x: 1_472, y: 472, width: 257, height: 257)
    )
    #expect(oneXPixel.targetPixelInImage == CGPoint(x: 128, y: 128))
    #expect(
        bottomRightPixel.sourcePixelRect
            == CGRect(x: 3_838, y: 2_046, width: 258, height: 258)
    )
    #expect(bottomRightPixel.targetPixelInImage == CGPoint(x: 257, y: 257))
    #expect(
        fractionalScalePixel.sourceRectInPoints
            == CGRect(x: 248, y: 114, width: 172, height: 172)
    )
    #expect(
        fractionalScalePixel.sourcePixelRect
            == CGRect(x: 372, y: 171, width: 258, height: 258)
    )
    #expect(fractionalScalePixel.targetPixelInImage == CGPoint(x: 128, y: 129))
}

@Test
func annotationLineWidthUnitsRoundTripAtRetinaScale() {
    let pixels = AnnotationLineWidthUnit.pixels
    let points = AnnotationLineWidthUnit.points
    let editor = EditorSettings()

    #expect(pixels.logicalPoints(fromDisplayedValue: 3, backingScale: 2) == 1.5)
    #expect(pixels.displayedValue(forLogicalPoints: 1.5, backingScale: 2) == 3)
    #expect(points.logicalPoints(fromDisplayedValue: 3, backingScale: 2) == 3)
    #expect(points.displayedValue(forLogicalPoints: 3, backingScale: 2) == 3)
    #expect(editor.logicalDefaultFontSize(backingScale: 2) == 9)
    #expect(editor.logicalDefaultRectangleCornerRadius(backingScale: 2) == 2)
}

@Test
func lineWidthEditingKindsMatchToolbarStrokedTools() {
    #expect(
        AnnotationTool.allCases.filter(\.supportsLineWidthEditing)
            == [.rectangle, .ellipse, .line, .arrow, .freehand]
    )
    #expect(AnnotationTool.allCases.allSatisfy {
        $0.supportsLineWidthEditing == ($0.annotationKind?.supportsLineWidthEditing == true)
    })
}

@Test
func editorMeasurementUnitChangesPreserveLogicalValuesAtRetinaScale() {
    var editor = EditorSettings()
    let initialLineWidth = editor.defaultLineWidthUnit.logicalPoints(
        fromDisplayedValue: editor.defaultLineWidth,
        backingScale: 2
    )
    let initialFontSize = editor.logicalDefaultFontSize(backingScale: 2)
    let initialCornerRadius = editor.logicalDefaultRectangleCornerRadius(backingScale: 2)

    editor.setDefaultLineWidthUnit(.points, backingScale: 2)
    editor.setDefaultFontSizeUnit(.points, backingScale: 2)
    editor.setDefaultRectangleCornerRadiusUnit(.points, backingScale: 2)

    #expect(editor.defaultLineWidth == 1.5)
    #expect(editor.defaultFontSize == 9)
    #expect(editor.defaultRectangleCornerRadius == 2)
    #expect(editor.defaultLineWidthUnit == .points)
    #expect(editor.defaultFontSizeUnit == .points)
    #expect(editor.defaultRectangleCornerRadiusUnit == .points)
    #expect(
        editor.defaultLineWidthUnit.logicalPoints(
            fromDisplayedValue: editor.defaultLineWidth,
            backingScale: 2
        ) == initialLineWidth
    )
    #expect(editor.logicalDefaultFontSize(backingScale: 2) == initialFontSize)
    #expect(editor.logicalDefaultRectangleCornerRadius(backingScale: 2) == initialCornerRadius)

    editor.setDefaultLineWidthUnit(.pixels, backingScale: 2)
    editor.setDefaultFontSizeUnit(.pixels, backingScale: 2)
    editor.setDefaultRectangleCornerRadiusUnit(.pixels, backingScale: 2)

    #expect(editor.defaultLineWidth == 3)
    #expect(editor.defaultFontSize == 18)
    #expect(editor.defaultRectangleCornerRadius == 4)
}

@Test
func floatingToolbarReservesDownwardPopoverSpaceForLargeCapture() {
    let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let layout = FloatingToolbarLayout(
        screenMargin: 8,
        imageSpacing: 8,
        reservedSpaceBelow: 68
    )
    let origin = layout.toolbarOrigin(
        imageFrame: CGRect(x: 20, y: 20, width: 1_400, height: 850),
        toolbarSize: CGSize(width: 880, height: 44),
        visibleFrame: visibleFrame
    )

    #expect(origin.x == 280)
    #expect(origin.y == 76)
    #expect(origin.y - 68 >= visibleFrame.minY + 8)
    #expect(origin.y + 44 <= visibleFrame.maxY - 8)
}

@Test
func pixelCropAlignsAndFlipsYExactlyOnce() {
    let transformer = CoordinateTransformer(primaryDisplayHeight: 100)
    let display = DisplayGeometry(
        id: 1,
        frame: CGRect(x: -100, y: 0, width: 100, height: 100),
        scale: 2
    )

    let crop = transformer.pixelCropRect(
        for: CGRect(x: -75, y: 25, width: 50, height: 50),
        in: display,
        imagePixelSize: CGSize(width: 200, height: 200)
    )

    #expect(crop == CGRect(x: 50, y: 50, width: 100, height: 100))
}

@Test
func captureStateMachineCancellationReturnsToIdle() async throws {
    let stateMachine = CaptureStateMachine()
    try await stateMachine.begin(mode: .currentDisplay)
    try await stateMachine.permissionGranted()
    try await stateMachine.contentPrepared(requiresSelection: false)
    await stateMachine.cancel()

    #expect(await stateMachine.state == .idle)
}

@Test
func captureAdmissionRejectsReentryWithoutResettingActiveSession() async throws {
    let stateMachine = CaptureStateMachine()
    #expect(await stateMachine.admit(mode: .region) == .accepted)
    try await stateMachine.permissionGranted()

    #expect(
        await stateMachine.admit(mode: .region)
            == .rejected(activeState: .preparingContent(.region))
    )
    #expect(await stateMachine.state == .preparingContent(.region))
}

@Test
func allDisplayCompositeLayoutHandlesNegativeCoordinatesScaleAndGaps() {
    let displays = [
        DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2),
        DisplayGeometry(id: 2, frame: CGRect(x: -50, y: 100, width: 50, height: 50), scale: 1),
        DisplayGeometry(id: 3, frame: CGRect(x: 150, y: -50, width: 100, height: 50), scale: 2)
    ]
    let geometry = ScreenGeometry(displays: displays)
    let transformer = CoordinateTransformer(primaryDisplayHeight: 0)

    #expect(geometry.desktopBounds == CGRect(x: -50, y: -50, width: 300, height: 200))
    #expect(geometry.maximumScale == 2)
    #expect(
        transformer.bitmapContextDestinationPixelRect(for: displays[0], desktopBounds: geometry.desktopBounds, outputScale: 2)
            == CGRect(x: 100, y: 100, width: 200, height: 200)
    )
    #expect(
        transformer.bitmapContextDestinationPixelRect(for: displays[1], desktopBounds: geometry.desktopBounds, outputScale: 2)
            == CGRect(x: 0, y: 300, width: 100, height: 100)
    )
    #expect(
        transformer.bitmapContextDestinationPixelRect(for: displays[2], desktopBounds: geometry.desktopBounds, outputScale: 2)
            == CGRect(x: 400, y: 0, width: 200, height: 100)
    )
}

@Test
func allDisplayCompositePreservesEachCaptureVerticalOrientation() throws {
    let topImage = ImageTestSupport.verticallyAsymmetricImage(width: 20, height: 20)
    let bottomImage = ImageTestSupport.verticallyAsymmetricImage(width: 20, height: 10)
    let captures = [
        ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: 0, y: 10, width: 20, height: 20),
            scale: 1,
            image: topImage
        ),
        ImageTestSupport.displayCapture(
            id: 2,
            frame: CGRect(x: 0, y: 0, width: 20, height: 10),
            scale: 1,
            image: bottomImage
        )
    ]

    let composite = try MultiDisplayCompositor().compose(captures).composite.image
    let compositeBytes = ImageTestSupport.rgbaBytes(for: composite)
    let topBytes = ImageTestSupport.rgbaBytes(for: topImage)
    let bottomBytes = ImageTestSupport.rgbaBytes(for: bottomImage)

    #expect(composite.width == 20)
    #expect(composite.height == 30)
    #expect(Array(compositeBytes.prefix(topBytes.count)) == topBytes)
    #expect(Array(compositeBytes.suffix(bottomBytes.count)) == bottomBytes)
}

@Test
func windowResolverUsesFrontToBackCandidateOrder() {
    let front = WindowDescriptor(
        id: 10,
        title: "Front",
        applicationName: "A",
        frame: CGRect(x: -50, y: 0, width: 100, height: 100),
        layer: 0
    )
    let back = WindowDescriptor(
        id: 11,
        title: "Back",
        applicationName: "B",
        frame: CGRect(x: -100, y: -100, width: 300, height: 300),
        layer: 0
    )

    #expect(WindowSelectionResolver().topmostWindow(at: CGPoint(x: 0, y: 50), candidates: [front, back]) == front)
    #expect(WindowSelectionResolver().topmostWindow(at: CGPoint(x: 500, y: 500), candidates: [front, back]) == nil)
}

@Test
func windowResolverRejectsDisplayCoveringSystemLayersBeforeAppWindows() {
    let desktopSurface = WindowDescriptor(
        id: 9,
        title: "Desktop Surface",
        applicationName: "System UI",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        layer: 20
    )
    let appWindow = WindowDescriptor(
        id: 10,
        title: "Application Window",
        applicationName: "Another App",
        frame: CGRect(x: 100, y: 100, width: 800, height: 600),
        layer: 0
    )

    #expect(
        WindowSelectionResolver().topmostWindow(
            at: CGPoint(x: 400, y: 400),
            candidates: [desktopSurface, appWindow]
        ) == appWindow
    )
    #expect(
        WindowSelectionResolver().topmostWindow(
            at: CGPoint(x: 50, y: 50),
            candidates: [desktopSurface, appWindow]
        ) == nil
    )
}

@Test
func regionCropPreservesNativeScaleOnOneDisplay() throws {
    let preparation = RegionCapturePreparation(displays: [
        ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: -100, y: 0, width: 100, height: 100),
            scale: 2,
            red: 1
        )
    ])

    let result = try RegionCaptureProcessor().crop(
        CGRect(x: -75, y: 25, width: 50, height: 50),
        from: preparation
    )

    #expect(result.pixelSize == CGSize(width: 100, height: 100))
    #expect(result.logicalSize == CGSize(width: 50, height: 50))
    #expect(result.scale == 2)
    #expect(result.sourceMetadata.desktopFrame == CGRect(x: -75, y: 25, width: 50, height: 50))
}

@Test
func crossDisplayRegionUsesMaximumScaleAndKeepsGap() throws {
    let preparation = RegionCapturePreparation(displays: [
        ImageTestSupport.displayCapture(
            id: 1,
            frame: CGRect(x: -100, y: 0, width: 80, height: 100),
            scale: 1,
            red: 1
        ),
        ImageTestSupport.displayCapture(
            id: 2,
            frame: CGRect(x: 20, y: 0, width: 80, height: 100),
            scale: 2,
            red: 0.5
        )
    ])

    let result = try RegionCaptureProcessor().crop(
        CGRect(x: -50, y: 25, width: 100, height: 50),
        from: preparation
    )

    #expect(result.pixelSize == CGSize(width: 200, height: 100))
    #expect(result.logicalSize == CGSize(width: 100, height: 50))
    #expect(result.scale == 2)
    #expect(result.sourceMetadata.displayIDs == [1, 2])
}

@Test
func filenameTemplateIsDeterministicAndSanitized() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(
        year: 2026, month: 7, day: 31, hour: 22, minute: 35, second: 8
    ))!

    let filename = FilenameTemplateFormatter(calendar: calendar).filename(
        template: "Screenshot-{yyyy}/{MM}/{dd}-{HH}:{mm}:{ss}",
        date: date
    )

    #expect(filename == "Screenshot-2026-07-31-22-35-08.png")
}

@Test
func pngExporterProducesDecodableColorManagedImage() throws {
    let source = ImageTestSupport.displayCapture(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 8, height: 8),
        scale: 1,
        red: 1
    ).capturedImage.image

    let data = try SystemImageExporter().pngData(for: source)
    let imageSource = CGImageSourceCreateWithData(data as CFData, nil)!
    let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!

    #expect(decoded.width == 8)
    #expect(decoded.height == 8)
    #expect(decoded.colorSpace != nil)

    for format in ExportFormat.allCases {
        let encoded = try SystemImageExporter().imageData(
            for: source,
            format: format,
            preservesColorProfile: true
        )
        let formatSource = CGImageSourceCreateWithData(encoded as CFData, nil)!
        let formatImage = CGImageSourceCreateImageAtIndex(formatSource, 0, nil)!
        #expect(formatImage.width == 8)
        #expect(formatImage.height == 8)
        #expect(formatImage.colorSpace != nil)
    }
}

@Test
func annotationDocumentRoundTripsEveryItemKind() throws {
    let document = AnnotationTestSupport.document(annotations: AnnotationTestSupport.allRenderableItems)
    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)

    #expect(decoded == document)
    #expect(Set(decoded.annotations.map(\.kind)) == Set(AnnotationKind.allCases))
}

@Test
func annotationHitTestingHandlesTransformsAndShapes() {
    let translated = AnnotationItem(
        kind: .rectangle,
        zIndex: 0,
        geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
        transform: AnnotationTransform(translation: CGSize(width: 20, height: 0))
    )
    let ellipse = AnnotationItem(
        kind: .ellipse,
        zIndex: 1,
        geometry: .rect(CGRect(x: 0, y: 0, width: 20, height: 10))
    )
    let line = AnnotationItem(
        kind: .line,
        zIndex: 2,
        geometry: .line(start: .zero, end: CGPoint(x: 20, y: 0))
    )
    let tester = AnnotationHitTester()

    #expect(tester.contains(CGPoint(x: 25, y: 5), in: translated, tolerance: 0))
    #expect(!tester.contains(CGPoint(x: 5, y: 5), in: translated, tolerance: 0))
    #expect(!tester.contains(CGPoint(x: 0, y: 0), in: ellipse, tolerance: 0))
    #expect(tester.contains(CGPoint(x: 10, y: 3), in: line, tolerance: 3))
}

@Test
func annotationSelectionGeometryMovesAndResizesFromStableOppositeEdge() {
    let item = AnnotationItem(
        kind: .rectangle,
        zIndex: 0,
        geometry: .rect(CGRect(x: 10, y: 20, width: 100, height: 60)),
        transform: AnnotationTransform(translation: CGSize(width: 20, height: 0))
    )
    let geometry = AnnotationSelectionGeometry()

    #expect(geometry.handlePoints(for: item).count == 8)
    let moved = geometry.moved(item, by: CGSize(width: 12, height: -8))
    #expect(moved.transform.translation.width == 32)
    #expect(moved.transform.translation.height == -8)

    let resized = geometry.resized(
        item,
        using: .east,
        to: CGPoint(x: 170, y: 50),
        minimumDimension: 6
    )
    let resizedBounds = geometry.transformedBounds(for: resized)
    #expect(abs(resizedBounds.minX - 30) < 0.001)
    #expect(abs(resizedBounds.maxX - 170) < 0.001)
    #expect(abs(resizedBounds.minY - 20) < 0.001)
    #expect(abs(resizedBounds.maxY - 80) < 0.001)

    let clamped = geometry.resized(
        item,
        using: .east,
        to: CGPoint(x: -100, y: 50),
        minimumDimension: 6
    )
    let clampedBounds = geometry.transformedBounds(for: clamped)
    #expect(abs(clampedBounds.minX - 30) < 0.001)
    #expect(abs(clampedBounds.maxX - 36) < 0.001)

    let brushStroke = AnnotationItem(
        kind: .freehand,
        zIndex: 1,
        geometry: .path([
            CGPoint(x: 10, y: 10),
            CGPoint(x: 24, y: 40),
            CGPoint(x: 42, y: 18)
        ])
    )
    #expect(brushStroke.kind.allowsUserTranslation)
    #expect(!brushStroke.kind.allowsUserResize)
    #expect(!brushStroke.kind.usesStandardSelectionResizeHandles)
    #expect(geometry.handlePoints(for: brushStroke).isEmpty)
}

@Test
func annotationSelectionGeometryResizesLineEndpointsInWorldCoordinates() {
    let item = AnnotationItem(
        kind: .arrow,
        zIndex: 0,
        geometry: .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 40, y: 30)),
        transform: AnnotationTransform(translation: CGSize(width: 15, height: -5))
    )
    let geometry = AnnotationSelectionGeometry()
    #expect(geometry.handlePoints(for: item).count == 2)

    let resized = geometry.resized(
        item,
        using: .lineEnd,
        to: CGPoint(x: 90, y: 75),
        minimumDimension: 6
    )
    guard case .line(let start, let end) = resized.geometry else {
        Issue.record("Expected line geometry after endpoint resize.")
        return
    }
    #expect(abs(start.x - 25) < 0.001)
    #expect(abs(start.y - 5) < 0.001)
    #expect(abs(end.x - 90) < 0.001)
    #expect(abs(end.y - 75) < 0.001)
    #expect(resized.transform == AnnotationTransform())
}

@Test @MainActor
func annotationUndoRedoAndLayerOrdering() {
    let controller = AnnotationDocumentController(document: AnnotationTestSupport.document())
    let first = AnnotationItem(kind: .rectangle, zIndex: 0, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
    let second = AnnotationItem(kind: .ellipse, zIndex: 1, geometry: .rect(CGRect(x: 20, y: 0, width: 10, height: 10)))
    controller.add(first)
    controller.add(second)
    controller.selectedItemIDs = [first.id]
    controller.bringSelectionToFront()

    #expect(controller.document.orderedAnnotations.last?.id == first.id)
    controller.undo()
    #expect(controller.document.orderedAnnotations.last?.id == second.id)
    controller.redo()
    #expect(controller.document.orderedAnnotations.last?.id == first.id)
    #expect(controller.canUndo)
}

@Test @MainActor
func blurAndMosaicRemainAnchoredWhenSelectionMoves() {
    let items = [
        AnnotationItem(kind: .mosaic, zIndex: 0, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10))),
        AnnotationItem(kind: .blur, zIndex: 1, geometry: .rect(CGRect(x: 20, y: 0, width: 10, height: 10))),
        AnnotationItem(kind: .rectangle, zIndex: 2, geometry: .rect(CGRect(x: 40, y: 0, width: 10, height: 10)))
    ]
    let controller = AnnotationDocumentController(
        document: AnnotationTestSupport.document(annotations: items)
    )
    controller.selectedItemIDs = Set(items.map(\.id))

    controller.moveSelection(by: CGSize(width: 9, height: 4))

    #expect(controller.document.annotations[0].transform.translation == .zero)
    #expect(controller.document.annotations[1].transform.translation == .zero)
    #expect(
        controller.document.annotations[2].transform.translation
            == CGSize(width: 9, height: 4)
    )
    let selectionGeometry = AnnotationSelectionGeometry()
    for item in items.prefix(2) {
        #expect(!item.kind.allowsUserTranslation)
        #expect(!item.kind.allowsUserResize)
        #expect(selectionGeometry.handlePoints(for: item).isEmpty)
    }
    #expect(selectionGeometry.handlePoints(for: items[2]).count == 8)
}

@Test @MainActor
func annotationCanvasRebasePreservesUndoRedoTimeline() {
    var document = AnnotationTestSupport.document()
    document.crop = CropState(rect: CGRect(x: 10, y: 20, width: 40, height: 30))
    let controller = AnnotationDocumentController(document: document)
    let item = AnnotationItem(
        kind: .rectangle,
        zIndex: 0,
        geometry: .rect(CGRect(x: 12, y: 14, width: 20, height: 18))
    )
    controller.add(item)
    controller.moveSelection(by: CGSize(width: 5, height: 0))
    controller.undo()

    let reference = ImageReference(pixelSize: CGSize(width: 280, height: 240))
    controller.rebaseCanvas(
        baseImageReference: reference,
        canvasSize: CGSize(width: 140, height: 120),
        translation: CGSize(width: 20, height: -10)
    )

    #expect(controller.document.baseImageReference == reference)
    #expect(controller.document.canvasSize == CGSize(width: 140, height: 120))
    #expect(controller.document.crop.rect == CGRect(x: 30, y: 10, width: 40, height: 30))
    #expect(controller.document.annotations[0].transform.translation == CGSize(width: 20, height: -10))
    #expect(controller.canUndo)
    #expect(controller.canRedo)

    controller.undo()
    #expect(controller.document.annotations.isEmpty)
    controller.redo()
    #expect(controller.document.annotations[0].transform.translation == CGSize(width: 20, height: -10))
    controller.redo()
    #expect(controller.document.annotations[0].transform.translation == CGSize(width: 25, height: -10))
}

@Test
func arrowGeometryKeepsTheRequestedDragEndpoints() throws {
    let start = CGPoint(x: 12, y: 18)
    let tip = CGPoint(x: 92, y: 67)
    let geometry = try #require(ArrowVectorGeometry(start: start, tip: tip, lineWidth: 4))

    #expect(geometry.start == start)
    #expect(geometry.tip == tip)
    #expect(abs((geometry.headLeft.x + geometry.headRight.x) / 2 - geometry.headBaseCenter.x) < 0.0001)
    #expect(abs((geometry.headLeft.y + geometry.headRight.y) / 2 - geometry.headBaseCenter.y) < 0.0001)
    #expect(hypot(tip.x - geometry.headBaseCenter.x, tip.y - geometry.headBaseCenter.y) > 0)
    #expect(
        hypot(tip.x - geometry.headShaftJoin.x, tip.y - geometry.headShaftJoin.y)
            < hypot(tip.x - geometry.headBaseCenter.x, tip.y - geometry.headBaseCenter.y)
    )
    #expect(
        hypot(geometry.headShaftJoin.x - start.x, geometry.headShaftJoin.y - start.y)
            > hypot(geometry.headBaseCenter.x - start.x, geometry.headBaseCenter.y - start.y)
    )
    #expect(
        hypot(tip.x - geometry.headShaftEnd.x, tip.y - geometry.headShaftEnd.y)
            < hypot(tip.x - geometry.headShaftJoin.x, tip.y - geometry.headShaftJoin.y)
    )
    #expect(abs((geometry.taperedNeckLeft.x + geometry.taperedNeckRight.x) / 2 - geometry.headShaftJoin.x) < 0.0001)
    #expect(abs((geometry.taperedNeckLeft.y + geometry.taperedNeckRight.y) / 2 - geometry.headShaftJoin.y) < 0.0001)
    #expect(
        hypot(geometry.taperedNeckLeft.x - geometry.taperedNeckRight.x, geometry.taperedNeckLeft.y - geometry.taperedNeckRight.y)
            < hypot(geometry.headLeft.x - geometry.headRight.x, geometry.headLeft.y - geometry.headRight.y)
    )
}

@Test
func filledArrowRendersPaperPlaneWingsAroundAContinuousShaft() throws {
    let width = 96
    let height = 64
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let item = AnnotationItem(
        kind: .arrow,
        zIndex: 0,
        geometry: .line(start: CGPoint(x: 8, y: 32), end: CGPoint(x: 88, y: 32)),
        style: AnnotationStyle(
            strokeColor: .systemRed,
            lineWidth: 8,
            arrowHeadStyle: .filled
        )
    )

    #expect(AnnotationVectorRenderer().draw(
        item: item,
        in: context,
        colorSpace: colorSpace
    ))
    let rendered = try #require(context.makeImage())
    let bytes = ImageTestSupport.rgbaBytes(for: rendered)
    func alpha(x: Int, y: Int) -> UInt8 {
        bytes[(y * rendered.width + x) * 4 + 3]
    }

    #expect(alpha(x: 58, y: 44) > 200)
    #expect(alpha(x: 58, y: 38) < 32)
    #expect(alpha(x: 8, y: 32) > 200)
    #expect(alpha(x: 58, y: 32) > 200)
    #expect(alpha(x: 93, y: 32) < 32)
}

@Test
func shortThickArrowsStayInsideTheirEndpointsAndKeepTaperedWidthsOrdered() throws {
    let geometry = try #require(ArrowVectorGeometry(
        start: CGPoint(x: 28, y: 32),
        tip: CGPoint(x: 36, y: 32),
        lineWidth: 24
    ))
    let headWidth = hypot(
        geometry.headLeft.x - geometry.headRight.x,
        geometry.headLeft.y - geometry.headRight.y
    )
    let neckWidth = hypot(
        geometry.taperedNeckLeft.x - geometry.taperedNeckRight.x,
        geometry.taperedNeckLeft.y - geometry.taperedNeckRight.y
    )
    let tailWidth = hypot(
        geometry.taperedTailLeft.x - geometry.taperedTailRight.x,
        geometry.taperedTailLeft.y - geometry.taperedTailRight.y
    )
    #expect(tailWidth < neckWidth)
    #expect(neckWidth < headWidth)
    #expect(geometry.shaftLineWidth < headWidth)

    for arrowStyle in [ArrowHeadStyle.filled, .double, .tapered] {
        let width = 64
        let height = 64
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let item = AnnotationItem(
            kind: .arrow,
            zIndex: 0,
            geometry: .line(start: CGPoint(x: 28, y: 32), end: CGPoint(x: 36, y: 32)),
            style: AnnotationStyle(
                strokeColor: .systemRed,
                lineWidth: 24,
                arrowHeadStyle: arrowStyle
            )
        )
        #expect(AnnotationVectorRenderer().draw(
            item: item,
            in: context,
            colorSpace: colorSpace
        ))
        let rendered = try #require(context.makeImage())
        let bytes = ImageTestSupport.rgbaBytes(for: rendered)
        func alpha(x: Int, y: Int) -> UInt8 {
            bytes[(y * rendered.width + x) * 4 + 3]
        }

        #expect(alpha(x: 34, y: 32) > 200)
        #expect(alpha(x: 40, y: 32) < 32)
        #expect(alpha(x: 24, y: 32) < 32)
        #expect(alpha(x: 34, y: 42) < 32)
    }
}

@Test
func shapeFillAndTaperedArrowStylesRoundTrip() throws {
    var style = AnnotationStyle(strokeColor: .systemRed)
    #expect(style.shapeFillMode == .outline)

    style.shapeFillMode = .filled
    style.arrowHeadStyle = .tapered
    #expect(style.fillColor == style.strokeColor)

    let decoded = try JSONDecoder().decode(
        AnnotationStyle.self,
        from: JSONEncoder().encode(style)
    )
    #expect(decoded.shapeFillMode == .filled)
    #expect(decoded.arrowHeadStyle == .tapered)

    style.shapeFillMode = .outline
    #expect(style.fillColor == nil)
}

@Test
func highlightStyleKeepsSemanticColorSeparateFromFillOpacity() {
    let blue = RGBAColor(red: 0, green: 0.478, blue: 1)
    let source = AnnotationStyle(
        strokeColor: .systemYellow,
        fillColor: .yellowHighlight,
        lineWidth: 7
    )

    let recolored = source.applyingColor(blue, for: .highlight)

    #expect(recolored.strokeColor == blue)
    #expect(
        recolored.fillColor
            == blue.withAlphaComponent(AnnotationStyle.highlightFillAlpha)
    )
    #expect(recolored.lineWidth == source.lineWidth)
    #expect(recolored.strokeColor.alpha == 1)
    #expect(recolored.fillColor?.alpha == AnnotationStyle.highlightFillAlpha)
    #expect(recolored.asHighlightStyle() == recolored)

    let counter = AnnotationStyle(
        strokeColor: .systemRed,
        fillColor: .white
    ).applyingColor(blue, for: .counter)
    #expect(counter.strokeColor == blue)
    #expect(counter.fillColor == .white)
}

@Test
func annotationDocumentNormalizesLegacyClearStrokeHighlightsForEditing() {
    let legacyHighlightID = UUID()
    let canonicalHighlightID = UUID()
    let rectangleID = UUID()
    let legacyGeometry = CGRect(x: 8, y: 12, width: 54, height: 6)
    let canonicalStyle = AnnotationStyle(
        strokeColor: .systemYellow,
        fillColor: .yellowHighlight,
        lineWidth: 5
    ).asHighlightStyle()
    let untouchedRectangle = AnnotationItem(
        id: rectangleID,
        kind: .rectangle,
        zIndex: 2,
        geometry: .rect(CGRect(x: 4, y: 4, width: 20, height: 20)),
        style: AnnotationStyle(strokeColor: .clear, fillColor: .systemRed)
    )
    var document = AnnotationTestSupport.document(annotations: [
        AnnotationItem(
            id: legacyHighlightID,
            kind: .highlight,
            zIndex: 0,
            geometry: .rect(legacyGeometry),
            style: AnnotationStyle(
                strokeColor: .clear,
                fillColor: .yellowHighlight,
                lineWidth: 9
            )
        ),
        AnnotationItem(
            id: canonicalHighlightID,
            kind: .highlight,
            zIndex: 1,
            geometry: .rect(CGRect(x: 10, y: 30, width: 40, height: 8)),
            style: canonicalStyle
        ),
        untouchedRectangle
    ])

    #expect(document.normalizeHighlightStylesForEditing() == 1)

    let migrated = document.annotations[0]
    #expect(migrated.id == legacyHighlightID)
    #expect(migrated.geometry == .rect(legacyGeometry))
    #expect(migrated.style.strokeColor == .systemYellow)
    #expect(migrated.style.fillColor == .yellowHighlight)
    #expect(migrated.style.lineWidth == 9)
    #expect(document.annotations[1].style == canonicalStyle)
    #expect(document.annotations[2] == untouchedRectangle)

    let normalizedDocument = document
    #expect(document.normalizeHighlightStylesForEditing() == 0)
    #expect(document == normalizedDocument)

    let customBlue = AnnotationStyle(
        strokeColor: .clear,
        fillColor: RGBAColor(red: 0, green: 0.478, blue: 1, alpha: 0.2)
    )
    var customDocument = AnnotationTestSupport.document(annotations: [
        AnnotationItem(
            kind: .highlight,
            zIndex: 0,
            geometry: .rect(legacyGeometry),
            style: customBlue
        )
    ])
    #expect(customDocument.normalizeHighlightStylesForEditing() == 1)
    #expect(
        customDocument.annotations[0].style.strokeColor
            == customBlue.fillColor?.withAlphaComponent(1)
    )
    #expect(
        customDocument.annotations[0].style.fillColor?.alpha
            == AnnotationStyle.highlightFillAlpha
    )
    #expect(
        customDocument.annotations[0].style.fillColor
            == customBlue.fillColor?.withAlphaComponent(AnnotationStyle.highlightFillAlpha)
    )
}

@Test
func rendererCoversEveryRequiredAnnotationKind() throws {
    let base = ImageTestSupport.displayCapture(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        scale: 1,
        red: 0.2
    ).capturedImage.image
    let document = AnnotationTestSupport.document(annotations: AnnotationTestSupport.allRenderableItems)

    let rendered = try AnnotationRenderer().render(document: document, baseImage: base, scale: 1)

    #expect(rendered.width == 100)
    #expect(rendered.height == 100)
}

@Test
func spotlightUsesANativeStyleRectangularMask() throws {
    let base = ImageTestSupport.displayCapture(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 20, height: 20),
        scale: 1,
        red: 1
    ).capturedImage.image
    let document = AnnotationTestSupport.document(
        annotations: [
            AnnotationItem(
                kind: .spotlight,
                zIndex: 0,
                geometry: .rect(CGRect(x: 5, y: 5, width: 10, height: 10))
            )
        ],
        canvasSize: CGSize(width: 20, height: 20)
    )

    let rendered = try AnnotationRenderer().render(document: document, baseImage: base, scale: 1)
    let bytes = ImageTestSupport.rgbaBytes(for: rendered)
    let highlightedCorner = (6 * rendered.width + 6) * 4
    let dimmedCorner = (1 * rendered.width + 1) * 4

    #expect(bytes[highlightedCorner] > 230)
    #expect(bytes[dimmedCorner] < 150)
}

@Test
func spotlightVectorMaskCoversLiveExpandedCanvasBounds() throws {
    let width = 30
    let height = 20
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let spotlight = AnnotationItem(
        kind: .spotlight,
        zIndex: 0,
        geometry: .rect(CGRect(x: 5, y: 5, width: 10, height: 10))
    )

    #expect(AnnotationVectorRenderer().draw(
        item: spotlight,
        in: context,
        colorSpace: colorSpace,
        canvasBounds: CGRect(x: 0, y: 0, width: width, height: height)
    ))
    let rendered = try #require(context.makeImage())
    let bytes = ImageTestSupport.rgbaBytes(for: rendered)
    let focusPixel = (10 * rendered.width + 10) * 4
    let newlyExposedPixel = (10 * rendered.width + 25) * 4

    #expect(bytes[focusPixel] > 230)
    #expect(bytes[newlyExposedPixel] < 150)
}

@Test
func nonUniformShapeResizePreservesPhysicalStrokeWidth() throws {
    let base = ImageTestSupport.displayCapture(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        scale: 2,
        red: 0
    ).capturedImage.image
    let rectangle = AnnotationItem(
        kind: .rectangle,
        zIndex: 0,
        geometry: .rect(CGRect(x: 30, y: 30, width: 20, height: 20)),
        style: AnnotationStyle(strokeColor: .systemRed, lineWidth: 1.5),
        transform: AnnotationTransform(scaleX: 3, scaleY: 2)
    )
    let document = AnnotationTestSupport.document(annotations: [rectangle])

    let rendered = try AnnotationRenderer().render(
        document: document,
        baseImage: base,
        scale: 2
    )
    let thicknesses = ImageTestSupport.redRectangleStrokeThicknesses(in: rendered)

    #expect(abs(thicknesses.horizontal - 3) < 0.05)
    #expect(abs(thicknesses.vertical - 3) < 0.05)
}

@Test
func rendererPreservesBaseImageVerticalOrientationAfterAnnotation() throws {
    let base = ImageTestSupport.verticallyAsymmetricImage()
    let rectangle = AnnotationItem(
        kind: .rectangle,
        zIndex: 0,
        geometry: .rect(CGRect(x: 6, y: 6, width: 8, height: 8))
    )
    let document = AnnotationTestSupport.document(
        annotations: [rectangle],
        canvasSize: CGSize(width: base.width, height: base.height)
    )

    let rendered = try AnnotationRenderer().render(document: document, baseImage: base, scale: 1)
    let baseBytes = ImageTestSupport.rgbaBytes(for: base)
    let renderedBytes = ImageTestSupport.rgbaBytes(for: rendered)
    let rowByteCount = base.width * 4

    #expect(Array(baseBytes.prefix(rowByteCount)) != Array(baseBytes.suffix(rowByteCount)))
    #expect(Array(renderedBytes.prefix(rowByteCount)) == Array(baseBytes.prefix(rowByteCount)))
    #expect(Array(renderedBytes.suffix(rowByteCount)) == Array(baseBytes.suffix(rowByteCount)))
}

@Test
func rendererCropRotationPaddingAndRoundedBackground() throws {
    let base = ImageTestSupport.displayCapture(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        scale: 1,
        red: 0.2
    ).capturedImage.image
    var document = AnnotationTestSupport.document()
    document.crop = CropState(rect: CGRect(x: 10, y: 20, width: 40, height: 30))
    document.rotation = RotationState(quarterTurnsClockwise: 1)
    document.background = .padded(color: .white, amount: 5)
    document.canvasEffects = CanvasEffects(cornerRadius: 4)

    let rendered = try AnnotationRenderer().render(document: document, baseImage: base, scale: 1)

    #expect(rendered.width == 40)
    #expect(rendered.height == 50)
}

@Test @MainActor
func multiSelectionAlignmentAndDistributionAreUndoable() {
    let items = [
        AnnotationItem(kind: .rectangle, zIndex: 0, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10))),
        AnnotationItem(kind: .rectangle, zIndex: 1, geometry: .rect(CGRect(x: 30, y: 10, width: 10, height: 10))),
        AnnotationItem(kind: .rectangle, zIndex: 2, geometry: .rect(CGRect(x: 100, y: 20, width: 10, height: 10)))
    ]
    let controller = AnnotationDocumentController(document: AnnotationTestSupport.document(annotations: items))
    controller.selectedItemIDs = Set(items.map(\.id))

    controller.distributeSelection(along: .horizontal)
    #expect(controller.document.annotations[1].transform.translation.width == 20)
    controller.alignSelection(.bottom)
    #expect(controller.document.annotations[1].transform.translation.height == -10)
    #expect(controller.document.annotations[2].transform.translation.height == -20)
    controller.undo()
    #expect(controller.document.annotations[1].transform.translation.height == 0)
}

@Test
func systemColorConversionUsesNamedProfilesAndRoundTrips() throws {
    let converter = SystemColorSpaceConverter()
    let source = CGColorSpace(name: CGColorSpace.sRGB)!
    let p3 = try converter.convert(
        RGBAComponents(red: 1, green: 0, blue: 0, alpha: 1),
        from: source,
        to: .displayP3
    )
    #expect(abs(p3.red - 0.917) < 0.02)
    #expect(abs(p3.green - 0.200) < 0.02)
    #expect(abs(p3.blue - 0.139) < 0.02)

    let p3Space = ColorSpacePreference.displayP3.nsColorSpace.cgColorSpace!
    let roundTrip = try converter.convert(p3, from: p3Space, to: .sRGB)
    #expect(abs(roundTrip.red - 1) < 0.02)
    #expect(abs(roundTrip.green) < 0.02)
    #expect(abs(roundTrip.blue) < 0.02)
    for preference in ColorSpacePreference.allCases {
        #expect(preference.nsColorSpace.cgColorSpace != nil)
    }
}

@Test @MainActor
func frozenPixelSamplerTracksDisplayPixelAndColorSpace() async throws {
    let preparation = RegionCapturePreparation(displays: [
        ImageTestSupport.displayCapture(
            id: 42,
            frame: CGRect(x: -100, y: 0, width: 100, height: 100),
            scale: 2,
            red: 1
        )
    ])
    let sampler = try FrozenFramePixelSampler(preparation: preparation)
    let frame = try await sampler.sampleFrame(
        at: CGPoint(x: -75, y: 25),
        colorSpace: .sRGB,
        radius: 5
    )
    let sample = frame.sample

    #expect(sample.displayID == 42)
    #expect(sample.pixelPoint == CGPoint(x: 50, y: 150))
    #expect(abs(sample.components.red - 1) <= 1.0 / 255.0)
    #expect(sample.hexString == "#FF0000")
    let p3 = try await sampler.sampleFrame(
        at: CGPoint(x: -75, y: 25),
        colorSpace: .displayP3,
        radius: 5
    ).sample
    #expect(p3.displayP3CSSString?.hasPrefix("color(display-p3 ") == true)
    let adobe = try await sampler.sampleFrame(
        at: CGPoint(x: -75, y: 25),
        colorSpace: .adobeRGB1998,
        radius: 5
    ).sample
    #expect(adobe.copyRepresentation(format: .hex).hasPrefix("Adobe RGB (1998) "))
    #expect(frame.magnifier.image.width == 11)
}

@Test
func measurementReportsPointPixelScaleAndConstraint() throws {
    let displays = [
        DisplayDescriptor(
            id: 1,
            name: "1x",
            frame: CGRect(x: -100, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 100, height: 100),
            scale: 1,
            isCurrent: false
        ),
        DisplayDescriptor(
            id: 2,
            name: "Retina",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 200, height: 200),
            scale: 2,
            isCurrent: true
        )
    ]
    let calculator = ScreenMeasurementCalculator(displays: displays)
    let measurement = try calculator.measurement(
        shape: .rectangle,
        start: CGPoint(x: 10, y: 10),
        end: CGPoint(x: 40, y: 50)
    )

    #expect(measurement.widthInPoints == 30)
    #expect(measurement.heightInPoints == 40)
    #expect(measurement.distanceInPoints == 50)
    #expect(measurement.widthInPixels == 60)
    #expect(measurement.heightInPixels == 80)
    #expect(measurement.distanceInPixels == 100)
    #expect(measurement.copyRepresentation.contains("scale 2.00x"))
    let constrained = calculator.constrainedEnd(start: .zero, proposedEnd: CGPoint(x: 9, y: 5))
    #expect(abs(constrained.x - constrained.y) < 0.001)
}

@Test
func historyStoreRoundTripsSkipsCorruptionAndEnforcesRetention() async throws {
    let result = try await HistoryTestSupport.exerciseStore()
    #expect(result.initialSummaryCount == 1)
    #expect(result.filesWereComplete)
    #expect(result.loadedAnnotationCount == 1)
    #expect(result.validCountAfterCorruption == 1)
    #expect(result.validRecordWasRemovedByRetention)
    #expect(result.countAfterClear == 0)
}
#endif
