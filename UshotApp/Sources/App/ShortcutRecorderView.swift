import AppKit
import SwiftUI
import UshotCore

struct ShortcutsSettingsView: View {
    let environment: AppEnvironment
    @ObservedObject var alerts: SettingsAlertModel
    @ObservedObject private var store: SettingsStore

    init(environment: AppEnvironment, alerts: SettingsAlertModel) {
        self.environment = environment
        self.alerts = alerts
        self._store = ObservedObject(wrappedValue: environment.settingsStore)
    }

    var body: some View {
        Form {
            Section("Global Shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(
                            shortcut: shortcut(for: action),
                            accessibilityIdentifier: "settings.shortcuts.global.\(action.rawValue)",
                            accessibilityLabel: action.title,
                            policy: .global,
                            onChange: { update(action: action, shortcut: $0) }
                        )
                        .frame(width: 128, height: 28)
                    }
                }
            }

            Section("Annotation Tool Shortcuts") {
                ForEach(AnnotationTool.quickToolbarOrder) { tool in
                    HStack {
                        Text(tool.title)
                        Spacer()
                        ShortcutRecorder(
                            shortcut: shortcut(for: tool),
                            accessibilityIdentifier: "settings.shortcuts.annotation.\(tool.rawValue)",
                            accessibilityLabel: tool.title,
                            policy: .annotation,
                            onChange: { update(tool: tool, shortcut: $0) }
                        )
                        .frame(width: 128, height: 28)
                    }
                }
            }

            HStack {
                Text("Global shortcuts require a modifier, except F1–F20. Annotation shortcuts are active only while editing a screenshot. Escape cancels recording.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { restoreDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(for action: HotKeyAction) -> HotKeyShortcut {
        store.settings.shortcuts.assignments[action]
            ?? ShortcutSettings.defaults.assignments[action]
            ?? HotKeyShortcut(keyCode: 0, modifiers: [.control, .option])
    }

    private func shortcut(for tool: AnnotationTool) -> HotKeyShortcut {
        store.settings.shortcuts.annotationToolAssignments[tool]
            ?? ShortcutSettings.defaultAnnotationToolAssignments[tool]
            ?? HotKeyShortcut(keyCode: 18, modifiers: [])
    }

    private func update(action: HotKeyAction, shortcut: HotKeyShortcut) {
        let previous = self.shortcut(for: action)
        do {
            try environment.hotKeyManager.update(action: action, to: shortcut)
            do {
                var shortcuts = store.settings.shortcuts
                shortcuts.assignments[action] = shortcut
                try store.update(\AppSettings.shortcuts, to: shortcuts)
            } catch {
                try environment.hotKeyManager.update(action: action, to: previous)
                throw error
            }
        } catch {
            alerts.present(error)
        }
    }

    private func update(tool: AnnotationTool, shortcut: HotKeyShortcut) {
        do {
            var shortcuts = store.settings.shortcuts
            shortcuts.annotationToolAssignments[tool] = shortcut
            try store.update(\AppSettings.shortcuts, to: shortcuts)
            AppLog.hotKeys.notice(
                "Updated annotation shortcut: tool=\(tool.rawValue, privacy: .public), shortcut=\(shortcut.displayString, privacy: .public)"
            )
        } catch {
            AppLog.hotKeys.error(
                "Rejected annotation shortcut update: tool=\(tool.rawValue, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
            )
            alerts.present(error)
        }
    }

    private func restoreDefaults() {
        let previous = store.settings.shortcuts
        do {
            try environment.hotKeyManager.register(ShortcutSettings.defaults.assignments)
            do {
                try store.update(\AppSettings.shortcuts, to: .defaults)
            } catch {
                try environment.hotKeyManager.register(previous.assignments)
                throw error
            }
        } catch {
            alerts.present(error)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: HotKeyShortcut
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let policy: ShortcutRecorderPolicy
    let onChange: (HotKeyShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.shortcut = shortcut
        view.policy = policy
        view.onChange = onChange
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityLabel(accessibilityLabel)
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.shortcut = shortcut
        nsView.policy = policy
        nsView.onChange = onChange
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.setAccessibilityLabel(accessibilityLabel)
    }
}

private enum ShortcutRecorderPolicy {
    case global
    case annotation

    var accessibilityHelp: String {
        switch self {
        case .global:
            return String(
                localized: "Press a modified key combination or F1–F20 to change this global shortcut.",
                comment: "Shortcut recorder accessibility help for a global shortcut"
            )
        case .annotation:
            return String(
                localized: "Press a key or key combination to change this annotation tool shortcut.",
                comment: "Shortcut recorder accessibility help for an annotation shortcut"
            )
        }
    }

    func accepts(_ shortcut: HotKeyShortcut) -> Bool {
        switch self {
        case .global:
            return shortcut.isValidGlobalShortcut
        case .annotation:
            return true
        }
    }
}

private final class ShortcutRecorderNSView: NSView {
    var shortcut = HotKeyShortcut(keyCode: 0, modifiers: [.control, .option]) {
        didSet {
            guard shortcut != oldValue else { return }
            setAccessibilityValue(shortcut.displayString)
            needsDisplay = true
        }
    }
    var policy = ShortcutRecorderPolicy.global {
        didSet {
            setAccessibilityHelp(policy.accessibilityHelp)
        }
    }
    var onChange: ((HotKeyShortcut) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 128, height: 28) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityValue(shortcut.displayString)
        setAccessibilityHelp(policy.accessibilityHelp)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = HotKeyModifiers(eventModifiers: event.modifierFlags)
        let candidate = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard policy.accepts(candidate) else {
            AppLog.hotKeys.notice(
                "Rejected unmodified non-function global shortcut recording: keyCode=\(event.keyCode, privacy: .public)"
            )
            NSSound.beep()
            return
        }

        onChange?(candidate)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()

        (isRecording ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = isRecording
            ? NSLocalizedString("Type shortcut…", comment: "Shortcut recorder active prompt")
            : shortcut.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppKitDrawingFonts.shortcutRecorder,
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

private extension HotKeyModifiers {
    init(eventModifiers: NSEvent.ModifierFlags) {
        let flags = eventModifiers.intersection(.deviceIndependentFlagsMask)
        var result: HotKeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}
