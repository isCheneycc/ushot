import AppKit
import UshotCore

@MainActor
enum AppKitDrawingFonts {
    static let shortcutRecorder = makeMonospacedFont(
        role: "shortcut-recorder",
        size: 13,
        weight: .medium
    )
    static let regionSelectionSize = makeMonospacedFont(
        role: "region-selection-size",
        size: 12,
        weight: .semibold
    )
    static let screenRulerBody = makeMonospacedFont(
        role: "screen-ruler-body",
        size: 10,
        weight: .regular
    )
    static let colorPickerDetail = makeMonospacedFont(
        role: "color-picker-detail",
        size: 9.5,
        weight: .regular
    )
    static let compactChrome = makeMonospacedFont(
        role: "compact-chrome",
        size: 8.5,
        weight: .regular
    )

    static func prepare() {
        _ = shortcutRecorder
        _ = regionSelectionSize
        _ = screenRulerBody
        _ = colorPickerDetail
        _ = compactChrome
        AppLog.lifecycle.debug("Prepared retained AppKit drawing fonts")
    }

    private static func makeMonospacedFont(
        role: String,
        size: CGFloat,
        weight: NSFont.Weight
    ) -> NSFont {
        precondition(size.isFinite && size > 0, "Drawing font size must be finite and positive.")

        // `NSFont.monospacedSystemFont` can return a runtime nil on macOS 26.6
        // after short-lived repeated calls despite its nonnull SDK contract.
        // Deriving the same system design avoids that factory while preserving
        // its font name, metrics, size and weight, then the static role retains
        // the resulting font for the complete process lifetime.
        let systemFont = NSFont.systemFont(ofSize: size, weight: weight)
        guard
            let descriptor = systemFont.fontDescriptor.withDesign(.monospaced),
            let font = NSFont(descriptor: descriptor, size: size),
            font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        else {
            AppLog.lifecycle.fault(
                "Unable to derive monospaced drawing font: role=\(role, privacy: .public), size=\(size, privacy: .public), weight=\(weight.rawValue, privacy: .public)"
            )
            preconditionFailure("Unable to derive the required monospaced drawing font for \(role).")
        }

        AppLog.lifecycle.debug(
            "Initialized retained drawing font: role=\(role, privacy: .public), name=\(font.fontName, privacy: .public), size=\(font.pointSize, privacy: .public)"
        )
        return font
    }
}
