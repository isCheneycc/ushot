import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let selectionModel = SettingsSelectionModel()

    init(environment: AppEnvironment) {
        let rootView = SettingsRootView(
            environment: environment,
            selectionModel: selectionModel
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Ushot Settings", comment: "Settings window title")
        window.setAccessibilityIdentifier("settings.window")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 580))
        window.contentMinSize = NSSize(width: 780, height: 520)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(section: SettingsSection) {
        selectionModel.selection = section
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class SettingsSelectionModel: ObservableObject {
    @Published var selection: SettingsSection = .general
}
