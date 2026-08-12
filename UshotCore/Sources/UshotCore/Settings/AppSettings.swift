import Foundation
import UniformTypeIdentifiers

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 11

    public var schemaVersion: Int
    public var general: GeneralSettings
    public var capture: CaptureSettings
    public var output: OutputSettings
    public var editor: EditorSettings
    public var colorPicker: ColorPickerSettings
    public var shortcuts: ShortcutSettings
    public var history: HistorySettings
    public var advanced: AdvancedSettings

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        general: GeneralSettings = .init(),
        capture: CaptureSettings = .init(),
        output: OutputSettings = .init(),
        editor: EditorSettings = .init(),
        colorPicker: ColorPickerSettings = .init(),
        shortcuts: ShortcutSettings = .defaults,
        history: HistorySettings = .init(),
        advanced: AdvancedSettings = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.capture = capture
        self.output = output
        self.editor = editor
        self.colorPicker = colorPicker
        self.shortcuts = shortcuts
        self.history = history
        self.advanced = advanced
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case general
        case capture
        case output
        case editor
        case colorPicker
        case shortcuts
        case history
        case advanced
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        general = try container.decode(GeneralSettings.self, forKey: .general)
        capture = try container.decode(CaptureSettings.self, forKey: .capture)
        output = try container.decode(OutputSettings.self, forKey: .output)
        editor = try EditorSettings(
            from: container.superDecoder(forKey: .editor),
            allowsLegacyColorPalette: schemaVersion <= 8
        )
        colorPicker = try container.decode(ColorPickerSettings.self, forKey: .colorPicker)
        shortcuts = try container.decode(ShortcutSettings.self, forKey: .shortcuts)
        history = try container.decode(HistorySettings.self, forKey: .history)
        advanced = try container.decode(AdvancedSettings.self, forKey: .advanced)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(general, forKey: .general)
        try container.encode(capture, forKey: .capture)
        try container.encode(output, forKey: .output)
        try container.encode(editor, forKey: .editor)
        try container.encode(colorPicker, forKey: .colorPicker)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(history, forKey: .history)
        try container.encode(advanced, forKey: .advanced)
    }

    public static let defaults = AppSettings()
}

public enum StartupBehavior: String, Codable, CaseIterable, Sendable {
    case doNothing
    case openSettings
    case openHistory

    public var title: String {
        switch self {
        case .doNothing: return NSLocalizedString("Do Nothing", comment: "Startup behavior")
        case .openSettings: return NSLocalizedString("Open Settings", comment: "Startup behavior")
        case .openHistory: return NSLocalizedString("Open History", comment: "Startup behavior")
        }
    }
}

public struct GeneralSettings: Codable, Equatable, Sendable {
    public var showsMenuBarIcon = true
    public var showsDockIcon = false
    public var launchesAtLogin = false
    public var startupBehavior: StartupBehavior = .doNothing

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showsMenuBarIcon
        case showsDockIcon
        case launchesAtLogin
        case startupBehavior
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarIcon) ?? true
        showsDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showsDockIcon) ?? false
        launchesAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchesAtLogin) ?? false
        startupBehavior = try container.decodeIfPresent(StartupBehavior.self, forKey: .startupBehavior) ?? .doNothing
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showsMenuBarIcon, forKey: .showsMenuBarIcon)
        try container.encode(showsDockIcon, forKey: .showsDockIcon)
        try container.encode(launchesAtLogin, forKey: .launchesAtLogin)
        try container.encode(startupBehavior, forKey: .startupBehavior)
    }
}

public struct CaptureSettings: Codable, Equatable, Sendable {
    public var capturesCursor = false
    public var includesWindowShadow = true
    public var presentsPinnedShot = true
    public var showsQuickToolbar = true
    public var automaticallyCopies = false
    public var automaticallySaves = false
    public var automaticallyOpensCanvasEditor = false
    public var savesOriginalAndEdited = false
    public var showsCornerThumbnail = false
    public var recognizesInterfaceElements = true
    /// Displayed region corner radius in `regionCornerRadiusUnit`.
    /// Zero disables rounded region chrome and export clipping.
    public var regionCornerRadius: Double
    public var regionCornerRadiusUnit: AnnotationMeasurementUnit

    public init(
        capturesCursor: Bool = false,
        includesWindowShadow: Bool = true,
        presentsPinnedShot: Bool = true,
        showsQuickToolbar: Bool = true,
        automaticallyCopies: Bool = false,
        automaticallySaves: Bool = false,
        automaticallyOpensCanvasEditor: Bool = false,
        savesOriginalAndEdited: Bool = false,
        showsCornerThumbnail: Bool = false,
        recognizesInterfaceElements: Bool = true,
        regionCornerRadius: Double = RegionCaptureCornerRadius.defaultDisplayedValue,
        regionCornerRadiusUnit: AnnotationMeasurementUnit = RegionCaptureCornerRadius.defaultUnit
    ) {
        self.capturesCursor = capturesCursor
        self.includesWindowShadow = includesWindowShadow
        self.presentsPinnedShot = presentsPinnedShot
        self.showsQuickToolbar = showsQuickToolbar
        self.automaticallyCopies = automaticallyCopies
        self.automaticallySaves = automaticallySaves
        self.automaticallyOpensCanvasEditor = automaticallyOpensCanvasEditor
        self.savesOriginalAndEdited = savesOriginalAndEdited
        self.showsCornerThumbnail = showsCornerThumbnail
        self.recognizesInterfaceElements = recognizesInterfaceElements
        self.regionCornerRadius = regionCornerRadius
        self.regionCornerRadiusUnit = regionCornerRadiusUnit
    }

    public func logicalRegionCornerRadius(backingScale: CGFloat) -> CGFloat {
        regionCornerRadiusUnit.logicalPoints(
            fromDisplayedValue: CGFloat(regionCornerRadius),
            backingScale: backingScale
        )
    }

    public mutating func setRegionCornerRadiusUnit(
        _ unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) {
        guard regionCornerRadiusUnit != unit else { return }
        regionCornerRadius = Double(
            regionCornerRadiusUnit.convertedDisplayedValue(
                CGFloat(regionCornerRadius),
                to: unit,
                backingScale: backingScale
            )
        )
        regionCornerRadiusUnit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case capturesCursor
        case includesWindowShadow
        case presentsPinnedShot
        case showsQuickToolbar
        case automaticallyCopies
        case automaticallySaves
        case automaticallyOpensCanvasEditor
        case savesOriginalAndEdited
        case showsCornerThumbnail
        case recognizesInterfaceElements
        case regionCornerRadius
        case regionCornerRadiusUnit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptureSettings()
        capturesCursor = try container.decodeIfPresent(Bool.self, forKey: .capturesCursor) ?? false
        includesWindowShadow = try container.decodeIfPresent(Bool.self, forKey: .includesWindowShadow) ?? true
        presentsPinnedShot = try container.decodeIfPresent(Bool.self, forKey: .presentsPinnedShot) ?? true
        showsQuickToolbar = try container.decodeIfPresent(Bool.self, forKey: .showsQuickToolbar) ?? true
        automaticallyCopies = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCopies) ?? false
        automaticallySaves = try container.decodeIfPresent(Bool.self, forKey: .automaticallySaves) ?? false
        automaticallyOpensCanvasEditor = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyOpensCanvasEditor
        ) ?? false
        savesOriginalAndEdited = try container.decodeIfPresent(Bool.self, forKey: .savesOriginalAndEdited) ?? false
        showsCornerThumbnail = try container.decodeIfPresent(Bool.self, forKey: .showsCornerThumbnail) ?? false
        recognizesInterfaceElements = try container.decodeIfPresent(
            Bool.self,
            forKey: .recognizesInterfaceElements
        ) ?? true
        regionCornerRadius = try container.decodeIfPresent(
            Double.self,
            forKey: .regionCornerRadius
        ) ?? defaults.regionCornerRadius
        regionCornerRadiusUnit = try container.decodeIfPresent(
            AnnotationMeasurementUnit.self,
            forKey: .regionCornerRadiusUnit
        ) ?? defaults.regionCornerRadiusUnit
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capturesCursor, forKey: .capturesCursor)
        try container.encode(includesWindowShadow, forKey: .includesWindowShadow)
        try container.encode(presentsPinnedShot, forKey: .presentsPinnedShot)
        try container.encode(showsQuickToolbar, forKey: .showsQuickToolbar)
        try container.encode(automaticallyCopies, forKey: .automaticallyCopies)
        try container.encode(automaticallySaves, forKey: .automaticallySaves)
        try container.encode(automaticallyOpensCanvasEditor, forKey: .automaticallyOpensCanvasEditor)
        try container.encode(savesOriginalAndEdited, forKey: .savesOriginalAndEdited)
        try container.encode(showsCornerThumbnail, forKey: .showsCornerThumbnail)
        try container.encode(recognizesInterfaceElements, forKey: .recognizesInterfaceElements)
        try container.encode(regionCornerRadius, forKey: .regionCornerRadius)
        try container.encode(regionCornerRadiusUnit, forKey: .regionCornerRadiusUnit)
    }
}

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case tiff

    public var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }

    public var fileExtension: String {
        contentType.preferredFilenameExtension ?? rawValue
    }
}

public struct OutputSettings: Codable, Equatable, Sendable {
    public var format: ExportFormat = .png
    public var filenameTemplate = "Screenshot-{yyyy}-{MM}-{dd}-{HH}.{mm}.{ss}"
    public var defaultDirectoryPath: String?
    public var preservesColorProfile = true

    public init() {}
}

public enum AnnotationColorPalette {
    /// The factory palette used for new installations and explicit restoration.
    /// The configured toolbar palette is otherwise fully user-owned.
    public static let factoryDefaultHexColors = [
        "#FF3B30", // system red
        "#FF9500", // system orange
        "#FFCC00", // system yellow
        "#34C759", // system green
        "#007AFF", // system blue
        "#AF52DE"  // system purple
    ]

    public static func normalizedHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let validDigits = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard digits.count == 6,
              digits.unicodeScalars.allSatisfy({ validDigits.contains($0) })
        else { return nil }
        return "#\(digits.uppercased())"
    }

    public static func color(fromHex value: String) -> RGBAColor? {
        guard let normalized = normalizedHex(value),
              let packed = UInt64(normalized.dropFirst(), radix: 16)
        else { return nil }
        return RGBAColor(
            red: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255
        )
    }

    public static func hexString(for color: RGBAColor) -> String {
        precondition(
            color.red.isFinite && color.green.isFinite && color.blue.isFinite,
            "An annotation color must have finite RGB components."
        )
        let red = Int((max(0, min(1, color.red)) * 255).rounded())
        let green = Int((max(0, min(1, color.green)) * 255).rounded())
        let blue = Int((max(0, min(1, color.blue)) * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Returns the configured palette plus a temporary current-value entry
    /// when an existing annotation retains a configured color that was removed
    /// from Settings. The temporary entry represents document state without
    /// mutating the configured palette; menu consumers must present an appended
    /// entry as non-actionable.
    public static func displayedHexColors(
        configuredHexColors: [String],
        currentHex: String
    ) -> [String] {
        precondition(
            !configuredHexColors.isEmpty
                && Set(configuredHexColors).count == configuredHexColors.count
                && configuredHexColors.allSatisfy { normalizedHex($0) == $0 },
            "Configured annotation colors must be unique normalized #RRGGBB values."
        )
        precondition(
            normalizedHex(currentHex) == currentHex,
            "The current annotation color must be a normalized #RRGGBB value."
        )
        return configuredHexColors.contains(currentHex)
            ? configuredHexColors
            : configuredHexColors + [currentHex]
    }
}

public struct EditorSettings: Codable, Equatable, Sendable {
    public var defaultColorHex: String
    public var defaultTextColorHex: String
    public var defaultRectangleColorHex: String
    public var defaultEllipseColorHex: String
    public var toolbarColorHexes: [String]
    public var defaultLineWidth: Double
    public var defaultLineWidthUnit: AnnotationMeasurementUnit
    public var defaultRectangleCornerRadius: Double
    public var defaultRectangleCornerRadiusUnit: AnnotationMeasurementUnit
    public var defaultFontSize: Double
    public var defaultFontSizeUnit: AnnotationMeasurementUnit
    public var defaultTextFontName: String?
    public var defaultBackgroundHex: String

    public init(
        defaultColorHex: String = "#FF3B30",
        defaultTextColorHex: String? = nil,
        defaultRectangleColorHex: String? = nil,
        defaultEllipseColorHex: String? = nil,
        toolbarColorHexes: [String] = AnnotationColorPalette.factoryDefaultHexColors,
        defaultLineWidth: Double = 3,
        defaultLineWidthUnit: AnnotationMeasurementUnit = .pixels,
        defaultRectangleCornerRadius: Double = 4,
        defaultRectangleCornerRadiusUnit: AnnotationMeasurementUnit = .pixels,
        defaultFontSize: Double = 18,
        defaultFontSizeUnit: AnnotationMeasurementUnit = .pixels,
        defaultTextFontName: String? = nil,
        defaultBackgroundHex: String = "#FFFFFF"
    ) {
        self.defaultColorHex = defaultColorHex
        self.defaultTextColorHex = defaultTextColorHex ?? defaultColorHex
        self.defaultRectangleColorHex = defaultRectangleColorHex ?? defaultColorHex
        self.defaultEllipseColorHex = defaultEllipseColorHex ?? defaultColorHex
        self.toolbarColorHexes = toolbarColorHexes
        self.defaultLineWidth = defaultLineWidth
        self.defaultLineWidthUnit = defaultLineWidthUnit
        self.defaultRectangleCornerRadius = defaultRectangleCornerRadius
        self.defaultRectangleCornerRadiusUnit = defaultRectangleCornerRadiusUnit
        self.defaultFontSize = defaultFontSize
        self.defaultFontSizeUnit = defaultFontSizeUnit
        self.defaultTextFontName = defaultTextFontName
        self.defaultBackgroundHex = defaultBackgroundHex
    }

    public var availableColorHexes: [String] {
        toolbarColorHexes
    }

    public func defaultColorHex(for tool: AnnotationTool) -> String {
        switch tool {
        case .text: return defaultTextColorHex
        case .rectangle: return defaultRectangleColorHex
        case .ellipse: return defaultEllipseColorHex
        default: return defaultColorHex
        }
    }

    public func logicalDefaultRectangleCornerRadius(backingScale: CGFloat) -> CGFloat {
        defaultRectangleCornerRadiusUnit.logicalPoints(
            fromDisplayedValue: CGFloat(defaultRectangleCornerRadius),
            backingScale: backingScale
        )
    }

    public func logicalDefaultFontSize(backingScale: CGFloat) -> CGFloat {
        defaultFontSizeUnit.logicalPoints(
            fromDisplayedValue: CGFloat(defaultFontSize),
            backingScale: backingScale
        )
    }

    public mutating func setDefaultLineWidthUnit(
        _ unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) {
        guard defaultLineWidthUnit != unit else { return }
        defaultLineWidth = Double(defaultLineWidthUnit.convertedDisplayedValue(
            CGFloat(defaultLineWidth),
            to: unit,
            backingScale: backingScale
        ))
        defaultLineWidthUnit = unit
    }

    public mutating func setDefaultRectangleCornerRadiusUnit(
        _ unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) {
        guard defaultRectangleCornerRadiusUnit != unit else { return }
        defaultRectangleCornerRadius = Double(
            defaultRectangleCornerRadiusUnit.convertedDisplayedValue(
                CGFloat(defaultRectangleCornerRadius),
                to: unit,
                backingScale: backingScale
            )
        )
        defaultRectangleCornerRadiusUnit = unit
    }

    public mutating func setDefaultFontSizeUnit(
        _ unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) {
        guard defaultFontSizeUnit != unit else { return }
        defaultFontSize = Double(defaultFontSizeUnit.convertedDisplayedValue(
            CGFloat(defaultFontSize),
            to: unit,
            backingScale: backingScale
        ))
        defaultFontSizeUnit = unit
    }

    public func validatedColorPalette() throws -> EditorSettings {
        guard let normalizedDefault = AnnotationColorPalette.normalizedHex(defaultColorHex) else {
            throw ScreenshotAppError.annotationColorPaletteInvalid(
                description: "The default annotation color must use #RRGGBB format."
            )
        }

        guard !toolbarColorHexes.isEmpty else {
            throw ScreenshotAppError.annotationColorPaletteInvalid(
                description: "The annotation toolbar must contain at least one color."
            )
        }

        var normalized = self
        normalized.defaultColorHex = normalizedDefault
        var seen = Set<String>()
        normalized.toolbarColorHexes = try toolbarColorHexes.map { value in
            guard let hex = AnnotationColorPalette.normalizedHex(value) else {
                throw ScreenshotAppError.annotationColorPaletteInvalid(
                    description: "\(value) is not a valid #RRGGBB color."
                )
            }
            guard seen.insert(hex).inserted else {
                throw ScreenshotAppError.annotationColorPaletteInvalid(
                    description: "\(hex) is already in the annotation color menu."
                )
            }
            return hex
        }
        let toolDefaults: [(WritableKeyPath<EditorSettings, String>, String, String)] = [
            (\.defaultTextColorHex, defaultTextColorHex, "text"),
            (\.defaultRectangleColorHex, defaultRectangleColorHex, "rectangle"),
            (\.defaultEllipseColorHex, defaultEllipseColorHex, "ellipse")
        ]
        guard seen.contains(normalizedDefault) else {
            throw ScreenshotAppError.annotationColorPaletteInvalid(
                description: "The default annotation color must be present in the toolbar color menu."
            )
        }
        for (keyPath, value, toolName) in toolDefaults {
            guard let normalizedValue = AnnotationColorPalette.normalizedHex(value) else {
                throw ScreenshotAppError.annotationColorPaletteInvalid(
                    description: "The default \(toolName) color must use #RRGGBB format."
                )
            }
            guard seen.contains(normalizedValue) else {
                throw ScreenshotAppError.annotationColorPaletteInvalid(
                    description: "The default \(toolName) color must be present in the toolbar color menu."
                )
            }
            normalized[keyPath: keyPath] = normalizedValue
        }
        if let fontName = normalized.defaultTextFontName {
            let trimmed = fontName.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.defaultTextFontName = trimmed.isEmpty ? nil : trimmed
        }
        return normalized
    }

    public mutating func addToolbarColor(_ value: String) throws {
        guard let hex = AnnotationColorPalette.normalizedHex(value) else {
            throw ScreenshotAppError.annotationColorPaletteInvalid(
                description: "New annotation colors must use #RRGGBB format."
            )
        }
        guard !availableColorHexes.contains(hex) else {
            throw ScreenshotAppError.annotationColorPaletteInvalid(
                description: "\(hex) is already in the annotation color menu."
            )
        }
        toolbarColorHexes.append(hex)
    }

    public mutating func removeToolbarColor(
        _ value: String,
        replacingUsesWith replacementValue: String
    ) throws {
        guard let hex = AnnotationColorPalette.normalizedHex(value),
              let index = toolbarColorHexes.firstIndex(of: hex)
        else {
            throw ScreenshotAppError.annotationColorPaletteInvalid(
                description: "The toolbar color no longer exists."
            )
        }

        guard toolbarColorHexes.count > 1 else {
            throw ScreenshotAppError.annotationColorPaletteInvalid(
                description: "The annotation toolbar must contain at least one color."
            )
        }

        guard let replacementHex = AnnotationColorPalette.normalizedHex(replacementValue),
              replacementHex != hex,
              toolbarColorHexes.contains(replacementHex)
        else {
            throw ScreenshotAppError.annotationColorPaletteInvalid(
                description: "Choose another color from the annotation toolbar before removing this color."
            )
        }

        toolbarColorHexes.remove(at: index)
        if defaultColorHex == hex {
            defaultColorHex = replacementHex
        }
        if defaultTextColorHex == hex {
            defaultTextColorHex = replacementHex
        }
        if defaultRectangleColorHex == hex {
            defaultRectangleColorHex = replacementHex
        }
        if defaultEllipseColorHex == hex {
            defaultEllipseColorHex = replacementHex
        }
    }

    public mutating func restoreFactoryToolbarColors() {
        let restoredColors = AnnotationColorPalette.factoryDefaultHexColors
        let replacementHex = restoredColors[0]
        toolbarColorHexes = restoredColors
        if !restoredColors.contains(defaultColorHex) {
            defaultColorHex = replacementHex
        }
        if !restoredColors.contains(defaultTextColorHex) {
            defaultTextColorHex = replacementHex
        }
        if !restoredColors.contains(defaultRectangleColorHex) {
            defaultRectangleColorHex = replacementHex
        }
        if !restoredColors.contains(defaultEllipseColorHex) {
            defaultEllipseColorHex = replacementHex
        }
    }

    public mutating func restoreFactoryToolbarColorsPreservingCustomColors() {
        let restoredColors = AnnotationColorPalette.factoryDefaultHexColors
        let restoredColorSet = Set(restoredColors)
        let customColors = toolbarColorHexes.filter { !restoredColorSet.contains($0) }
        toolbarColorHexes = restoredColors + customColors
    }

    private enum CodingKeys: String, CodingKey {
        case defaultColorHex
        case defaultTextColorHex
        case defaultRectangleColorHex
        case defaultEllipseColorHex
        case toolbarColorHexes
        // Decoding only: schema versions 1...8 stored only colors added
        // beyond the immutable factory palette.
        case customColorHexes
        case defaultLineWidth
        case defaultLineWidthUnit
        case defaultRectangleCornerRadius
        case defaultRectangleCornerRadiusUnit
        case defaultFontSize
        case defaultFontSizeUnit
        case defaultTextFontName
        case defaultBackgroundHex
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, allowsLegacyColorPalette: false)
    }

    fileprivate init(
        from decoder: Decoder,
        allowsLegacyColorPalette: Bool
    ) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EditorSettings()
        defaultColorHex = try container.decodeIfPresent(String.self, forKey: .defaultColorHex)
            ?? defaults.defaultColorHex
        defaultTextColorHex = try container.decodeIfPresent(String.self, forKey: .defaultTextColorHex)
            ?? defaultColorHex
        defaultRectangleColorHex = try container.decodeIfPresent(String.self, forKey: .defaultRectangleColorHex)
            ?? defaultColorHex
        defaultEllipseColorHex = try container.decodeIfPresent(String.self, forKey: .defaultEllipseColorHex)
            ?? defaultColorHex
        if container.contains(.toolbarColorHexes) {
            toolbarColorHexes = try container.decode(
                [String].self,
                forKey: .toolbarColorHexes
            )
        } else if allowsLegacyColorPalette {
            let legacyCustomColors = try container.decodeIfPresent(
                [String].self,
                forKey: .customColorHexes
            ) ?? []
            toolbarColorHexes = AnnotationColorPalette.factoryDefaultHexColors + legacyCustomColors
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.toolbarColorHexes,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Schema v9 editor settings require the complete toolbar color palette."
                )
            )
        }
        defaultLineWidth = try container.decodeIfPresent(Double.self, forKey: .defaultLineWidth)
            ?? defaults.defaultLineWidth
        defaultLineWidthUnit = try container.decodeIfPresent(
            AnnotationMeasurementUnit.self,
            forKey: .defaultLineWidthUnit
        ) ?? defaults.defaultLineWidthUnit
        defaultRectangleCornerRadius = try container.decodeIfPresent(
            Double.self,
            forKey: .defaultRectangleCornerRadius
        ) ?? defaults.defaultRectangleCornerRadius
        defaultRectangleCornerRadiusUnit = try container.decodeIfPresent(
            AnnotationMeasurementUnit.self,
            forKey: .defaultRectangleCornerRadiusUnit
        ) ?? defaults.defaultRectangleCornerRadiusUnit
        defaultFontSize = try container.decodeIfPresent(Double.self, forKey: .defaultFontSize)
            ?? defaults.defaultFontSize
        defaultFontSizeUnit = try container.decodeIfPresent(
            AnnotationMeasurementUnit.self,
            forKey: .defaultFontSizeUnit
        ) ?? defaults.defaultFontSizeUnit
        defaultTextFontName = try container.decodeIfPresent(String.self, forKey: .defaultTextFontName)
            ?? defaults.defaultTextFontName
        defaultBackgroundHex = try container.decodeIfPresent(String.self, forKey: .defaultBackgroundHex)
            ?? defaults.defaultBackgroundHex
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultColorHex, forKey: .defaultColorHex)
        try container.encode(defaultTextColorHex, forKey: .defaultTextColorHex)
        try container.encode(defaultRectangleColorHex, forKey: .defaultRectangleColorHex)
        try container.encode(defaultEllipseColorHex, forKey: .defaultEllipseColorHex)
        try container.encode(toolbarColorHexes, forKey: .toolbarColorHexes)
        try container.encode(defaultLineWidth, forKey: .defaultLineWidth)
        try container.encode(defaultLineWidthUnit, forKey: .defaultLineWidthUnit)
        try container.encode(defaultRectangleCornerRadius, forKey: .defaultRectangleCornerRadius)
        try container.encode(
            defaultRectangleCornerRadiusUnit,
            forKey: .defaultRectangleCornerRadiusUnit
        )
        try container.encode(defaultFontSize, forKey: .defaultFontSize)
        try container.encode(defaultFontSizeUnit, forKey: .defaultFontSizeUnit)
        try container.encodeIfPresent(defaultTextFontName, forKey: .defaultTextFontName)
        try container.encode(defaultBackgroundHex, forKey: .defaultBackgroundHex)
    }
}

public enum ColorSpacePreference: String, Codable, CaseIterable, Sendable {
    case sRGB
    case displayP3
    case genericRGB
    case adobeRGB1998

    public var title: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .genericRGB: return NSLocalizedString("Generic RGB", comment: "Color-space name")
        case .adobeRGB1998: return "Adobe RGB (1998)"
        }
    }
}

public enum ColorCopyFormat: String, Codable, CaseIterable, Sendable {
    case hex
    case css
    case components

    public var title: String {
        NSLocalizedString(rawValue.capitalized, comment: "Color copy format")
    }
}

public struct ColorPickerSettings: Codable, Equatable, Sendable {
    public var colorSpace: ColorSpacePreference = .sRGB
    public var copyFormat: ColorCopyFormat = .hex

    public init() {}
}

public struct HistorySettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var retentionDays = 30
    public var maximumItemCount = 500

    public init() {}
}

public enum AppLogLevel: String, Codable, CaseIterable, Sendable {
    case error
    case info
    case debug
}

public struct AdvancedSettings: Codable, Equatable, Sendable {
    public var logLevel: AppLogLevel
    /// In-app UI language. Defaults to Simplified Chinese.
    public var language: AppLanguagePreference

    public init(
        logLevel: AppLogLevel = .info,
        language: AppLanguagePreference = .default
    ) {
        self.logLevel = logLevel
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case logLevel
        case language
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AdvancedSettings()
        logLevel = try container.decodeIfPresent(AppLogLevel.self, forKey: .logLevel) ?? defaults.logLevel
        language = try container.decodeIfPresent(
            AppLanguagePreference.self,
            forKey: .language
        ) ?? defaults.language
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(logLevel, forKey: .logLevel)
        try container.encode(language, forKey: .language)
    }
}
