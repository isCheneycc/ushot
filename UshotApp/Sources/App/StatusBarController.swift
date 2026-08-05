import AppKit
import UshotCore

@MainActor
final class StatusBarController: NSObject {
    var onAction: ((HotKeyAction) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: (() -> Void)?

    var isVisible: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    private let statusItem: NSStatusItem
    private var shortcuts: [HotKeyAction: HotKeyShortcut] = [:]
    private var historyEnabled = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        guard let menuBarIcon = NSImage(named: "MenuBarIcon") else {
            preconditionFailure("Missing MenuBarIcon image asset")
        }
        menuBarIcon.isTemplate = true
        menuBarIcon.accessibilityDescription = "UshotApp"
        statusItem.button?.image = menuBarIcon
        statusItem.button?.toolTip = "UshotApp"
        rebuildMenu(shortcuts: [:], historyEnabled: false)
    }

    func rebuildMenu(
        shortcuts: [HotKeyAction: HotKeyShortcut],
        historyEnabled: Bool
    ) {
        self.shortcuts = shortcuts
        self.historyEnabled = historyEnabled

        let menu = NSMenu()
        addAction(.captureRegion, to: menu)
        addAction(.captureWindow, to: menu)
        addAction(.captureCurrentDisplay, to: menu)
        addAction(.captureSelectedDisplay, to: menu)
        addAction(.captureAllDisplays, to: menu)
        menu.addItem(.separator())
        addAction(.colorPicker, to: menu)
        addAction(.screenRuler, to: menu)

        menu.addItem(.separator())
        let historyTitle = NSLocalizedString(
            historyEnabled ? "History…" : "History… (Off)",
            comment: "Menu item for screenshot history"
        )
        let history = NSMenuItem(title: historyTitle, action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: NSLocalizedString("Settings…", comment: "Settings menu item"), action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: NSLocalizedString("About UshotApp", comment: "About menu item"), action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: NSLocalizedString("Quit UshotApp", comment: "Quit menu item"), action: #selector(quitApplication), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func addAction(_ action: HotKeyAction, to menu: NSMenu) {
        let shortcut = shortcuts[action]
        let suffix = shortcut.map { "    \($0.displayString)" } ?? ""
        let item = NSMenuItem(
            title: NSLocalizedString(action.title, comment: "Capture action title") + suffix,
            action: #selector(performAction(_:)),
            keyEquivalent: ""
        )
        item.representedObject = NSNumber(value: action.rawValue)
        item.target = self
        menu.addItem(item)
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard
            let rawValue = (sender.representedObject as? NSNumber)?.uint32Value,
            let action = HotKeyAction(rawValue: rawValue)
        else { return }
        onAction?(action)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openHistory() {
        onOpenHistory?()
    }

    @objc private func openAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}
