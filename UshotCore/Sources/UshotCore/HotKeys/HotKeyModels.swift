import Carbon
import Foundation

public struct HotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotKeyModifiers(rawValue: 1 << 0)
    public static let option = HotKeyModifiers(rawValue: 1 << 1)
    public static let control = HotKeyModifiers(rawValue: 1 << 2)
    public static let shift = HotKeyModifiers(rawValue: 1 << 3)
}

public enum HotKeyAction: UInt32, Codable, CaseIterable, Identifiable, Sendable {
    case captureRegion = 1
    case captureWindow = 2
    case captureCurrentDisplay = 3
    case captureSelectedDisplay = 4
    case captureAllDisplays = 5
    case colorPicker = 6
    case screenRuler = 7

    public var id: UInt32 { rawValue }

    public var title: String {
        switch self {
        case .captureRegion: return NSLocalizedString("Capture Region", comment: "Global shortcut action")
        case .captureWindow: return NSLocalizedString("Capture Window", comment: "Global shortcut action")
        case .captureCurrentDisplay: return NSLocalizedString("Capture Current Display", comment: "Global shortcut action")
        case .captureSelectedDisplay: return NSLocalizedString("Capture Selected Display", comment: "Global shortcut action")
        case .captureAllDisplays: return NSLocalizedString("Capture All Displays", comment: "Global shortcut action")
        case .colorPicker: return NSLocalizedString("Color Picker", comment: "Global shortcut action")
        case .screenRuler: return NSLocalizedString("Screen Ruler", comment: "Global shortcut action")
        }
    }
}

public struct HotKeyShortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotKeyModifiers

    public init(keyCode: UInt32, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isFunctionKey: Bool {
        Self.functionKeyNames[keyCode] != nil
    }

    public var isValidGlobalShortcut: Bool {
        let unknownModifierBits = modifiers.rawValue & ~Self.persistedModifierMask.rawValue
        return unknownModifierBits == 0 && (!modifiers.isEmpty || isFunctionKey)
    }

    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    private static func keyName(for keyCode: UInt32) -> String {
        if let functionKeyName = functionKeyNames[keyCode] {
            return functionKeyName
        }

        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }

    private static let functionKeyNames: [UInt32: String] = [
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20"
    ]

    private static let persistedModifierMask: HotKeyModifiers = [
        .command,
        .option,
        .control,
        .shift
    ]
}

public struct ShortcutSettings: Codable, Equatable, Sendable {
    public var assignments: [HotKeyAction: HotKeyShortcut]
    public var annotationToolAssignments: [AnnotationTool: HotKeyShortcut]

    public init(
        assignments: [HotKeyAction: HotKeyShortcut],
        annotationToolAssignments: [AnnotationTool: HotKeyShortcut] = ShortcutSettings.defaultAnnotationToolAssignments
    ) {
        self.assignments = assignments
        self.annotationToolAssignments = annotationToolAssignments
    }

    public static let defaultAnnotationToolAssignments: [AnnotationTool: HotKeyShortcut] = {
        // Preserve the established 1…9, 0 and - bindings and keep Spotlight
        // on `[`. Keeping the mapping explicit prevents a toolbar insertion from
        // silently changing an existing shortcut.
        let keyCodeByTool: [AnnotationTool: UInt32] = [
            .select: 18,
            .rectangle: 19,
            .ellipse: 20,
            .line: 21,
            .arrow: 23,
            .freehand: 22,
            .text: 26,
            .counter: 28,
            .mosaic: 25,
            .blur: 29,
            .highlight: 27,
            .spotlight: 33
        ]
        precondition(
            keyCodeByTool.count == AnnotationTool.quickToolbarOrder.count
                && Set(keyCodeByTool.keys) == Set(AnnotationTool.quickToolbarOrder),
            "Every quick annotation tool must have exactly one default shortcut."
        )
        return Dictionary(uniqueKeysWithValues: AnnotationTool.quickToolbarOrder.map { tool in
            guard let keyCode = keyCodeByTool[tool] else {
                preconditionFailure("The default shortcut map is missing \(tool.rawValue).")
            }
            return (tool, HotKeyShortcut(keyCode: keyCode, modifiers: []))
        })
    }()

    public static let defaults = ShortcutSettings(
        assignments: [
            .captureRegion: HotKeyShortcut(keyCode: 0, modifiers: [.control, .option]),
            .captureWindow: HotKeyShortcut(keyCode: 13, modifiers: [.control, .option]),
            .captureCurrentDisplay: HotKeyShortcut(keyCode: 3, modifiers: [.control, .option]),
            .captureSelectedDisplay: HotKeyShortcut(keyCode: 2, modifiers: [.control, .option]),
            .captureAllDisplays: HotKeyShortcut(keyCode: 46, modifiers: [.control, .option]),
            .colorPicker: HotKeyShortcut(keyCode: 8, modifiers: [.control, .option]),
            .screenRuler: HotKeyShortcut(keyCode: 15, modifiers: [.control, .option])
        ],
        annotationToolAssignments: defaultAnnotationToolAssignments
    )

    private enum CodingKeys: String, CodingKey {
        case assignments
        case annotationToolAssignments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try container.decode([HotKeyAction: HotKeyShortcut].self, forKey: .assignments)

        let persistedToolAssignments = try container.decodeIfPresent(
            [AnnotationTool: HotKeyShortcut].self,
            forKey: .annotationToolAssignments
        ) ?? [:]
        let visibleTools = Set(AnnotationTool.quickToolbarOrder)
        let visiblePersistedToolAssignments = persistedToolAssignments.filter {
            visibleTools.contains($0.key)
        }
        var mergedToolAssignments = Self.defaultAnnotationToolAssignments
        for (tool, shortcut) in visiblePersistedToolAssignments {
            mergedToolAssignments[tool] = shortcut
        }
        if visiblePersistedToolAssignments[.spotlight] == nil,
           let spotlightDefault = mergedToolAssignments[.spotlight]
        {
            let occupied = Set(visiblePersistedToolAssignments.values)
            if occupied.contains(spotlightDefault) {
                let migrationCandidates: [UInt32] = [30, 42, 41, 39, 43, 47, 44, 50]
                guard let availableKeyCode = migrationCandidates.first(where: {
                    !occupied.contains(HotKeyShortcut(keyCode: $0, modifiers: []))
                }) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .annotationToolAssignments,
                        in: container,
                        debugDescription: "No unmodified key remains for the new Spotlight shortcut."
                    )
                }
                mergedToolAssignments[.spotlight] = HotKeyShortcut(
                    keyCode: availableKeyCode,
                    modifiers: []
                )
            }
        }
        annotationToolAssignments = mergedToolAssignments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assignments, forKey: .assignments)
        try container.encode(annotationToolAssignments, forKey: .annotationToolAssignments)
    }

    public func validatingUniqueAssignments() throws -> ShortcutSettings {
        var seen: [HotKeyShortcut: HotKeyAction] = [:]
        for (action, shortcut) in assignments {
            guard shortcut.isValidGlobalShortcut else {
                throw ScreenshotAppError.invalidGlobalShortcut(action: action)
            }
            if seen[shortcut] != nil {
                throw ScreenshotAppError.shortcutConflict(action: action, status: nil)
            }
            seen[shortcut] = action
        }

        var seenAnnotationShortcuts: [HotKeyShortcut: AnnotationTool] = [:]
        for tool in AnnotationTool.quickToolbarOrder {
            guard let shortcut = annotationToolAssignments[tool] else {
                throw ScreenshotAppError.settingsCorrupted(
                    description: "The shortcut for \(tool.rawValue) is missing."
                )
            }
            if let existingTool = seenAnnotationShortcuts[shortcut] {
                throw ScreenshotAppError.annotationShortcutConflict(
                    tool: tool,
                    conflictingTool: existingTool
                )
            }
            seenAnnotationShortcuts[shortcut] = tool
        }
        return self
    }

    public func annotationTool(matching shortcut: HotKeyShortcut) -> AnnotationTool? {
        AnnotationTool.quickToolbarOrder.first { annotationToolAssignments[$0] == shortcut }
    }
}
