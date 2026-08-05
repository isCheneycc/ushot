import OSLog

public enum AppLog {
    private static let subsystem = ProductIdentity.bundleIdentifier

    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let colorPicker = Logger(subsystem: subsystem, category: "color-picker")
    public static let screenRuler = Logger(subsystem: subsystem, category: "screen-ruler")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let hotKeys = Logger(subsystem: subsystem, category: "hotkeys")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let updates = Logger(subsystem: subsystem, category: "updates")
}
