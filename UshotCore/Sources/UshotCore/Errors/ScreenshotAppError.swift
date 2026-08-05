import Foundation

public enum ScreenshotAppError: LocalizedError, Sendable {
    case captureCancelled
    case permissionDenied
    case noDisplayAvailable
    case noWindowAvailable
    case contentUnavailable
    case captureFailed(description: String)
    case colorConversionFailed(description: String)
    case pixelSamplingFailed(description: String)
    case exportFailed(description: String)
    case invalidGlobalShortcut(action: HotKeyAction)
    case shortcutConflict(action: HotKeyAction, status: Int32?)
    case annotationShortcutConflict(tool: AnnotationTool, conflictingTool: AnnotationTool)
    case annotationColorPaletteInvalid(description: String)
    case shortcutRollbackFailed(description: String)
    case historyCorrupted(description: String)
    case historyPersistenceFailed(description: String)
    case settingsCorrupted(description: String)
    case settingsPersistenceFailed(description: String)
    case launchAtLoginFailed(description: String)

    public var errorDescription: String? {
        switch self {
        case .captureCancelled:
            return NSLocalizedString("Capture was cancelled.", comment: "Capture cancelled error")
        case .permissionDenied:
            return NSLocalizedString(
                "Screen recording permission is required to capture the screen.",
                comment: "Screen recording permission error"
            )
        case .noDisplayAvailable:
            return NSLocalizedString("No capturable display is available.", comment: "No display error")
        case .noWindowAvailable:
            return NSLocalizedString("No capturable window is available.", comment: "No window error")
        case .contentUnavailable:
            return NSLocalizedString("The selected content is no longer available.", comment: "Content unavailable error")
        case .captureFailed(let description):
            return localizedFormat("Capture failed: %@", description)
        case .colorConversionFailed(let description):
            return localizedFormat("Color conversion failed: %@", description)
        case .pixelSamplingFailed(let description):
            return localizedFormat("Pixel sampling failed: %@", description)
        case .exportFailed(let description):
            return localizedFormat("Export failed: %@", description)
        case .invalidGlobalShortcut(let action):
            return String(
                format: NSLocalizedString(
                    "The shortcut for %@ must include Command, Option, Control, or Shift unless it is F1–F20.",
                    comment: "Invalid global shortcut error"
                ),
                locale: .current,
                action.title
            )
        case .shortcutConflict(let action, _):
            let actionTitle = NSLocalizedString(action.title, comment: "Global shortcut action title")
            return localizedFormat(
                "The shortcut for %@ is already in use. The previous shortcut remains active.",
                actionTitle
            )
        case .annotationShortcutConflict(let tool, let conflictingTool):
            return String(
                format: NSLocalizedString(
                    "The shortcut for %@ is already assigned to %@. Choose another shortcut.",
                    comment: "Annotation shortcut conflict error"
                ),
                locale: .current,
                tool.title,
                conflictingTool.title
            )
        case .annotationColorPaletteInvalid(let description):
            return localizedFormat("Annotation colors could not be changed: %@", description)
        case .shortcutRollbackFailed(let description):
            return localizedFormat("Shortcut registration could not be restored: %@", description)
        case .historyCorrupted(let description):
            return localizedFormat("A history record is damaged: %@", description)
        case .historyPersistenceFailed(let description):
            return localizedFormat("Screenshot history could not be saved: %@", description)
        case .settingsCorrupted(let description):
            return localizedFormat("Settings could not be read: %@", description)
        case .settingsPersistenceFailed(let description):
            return localizedFormat("Settings could not be saved: %@", description)
        case .launchAtLoginFailed(let description):
            return localizedFormat("Launch at login could not be changed: %@", description)
        }
    }

    private func localizedFormat(_ key: String, _ value: String) -> String {
        String(
            format: NSLocalizedString(key, comment: "Screenshot application error with diagnostic detail"),
            locale: .current,
            value
        )
    }
}
