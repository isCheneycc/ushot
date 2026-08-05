import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UshotCore

@MainActor
final class CanvasEditorManager {
    private let exporter: any ImageExporting
    private let settingsStore: SettingsStore
    private var controllers: [ObjectIdentifier: CanvasEditorWindowController] = [:]

    init(
        exporter: any ImageExporting = SystemImageExporter(),
        settingsStore: SettingsStore
    ) {
        self.exporter = exporter
        self.settingsStore = settingsStore
    }

    func open(
        session: AnnotationEditingSession,
        ownershipID: UUID? = nil,
        onClose: (() -> Void)? = nil
    ) {
        let key = ObjectIdentifier(session)
        if let existing = controllers[key] {
            existing.registerCloseCallback(onClose, ownershipID: ownershipID)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let controller = CanvasEditorWindowController(
            session: session,
            exporter: exporter,
            settingsStore: settingsStore
        )
        controller.registerCloseCallback(onClose, ownershipID: ownershipID)
        controller.onClose = { [weak self] in self?.controllers[key] = nil }
        controllers[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class CanvasEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let session: AnnotationEditingSession
    private let exporter: any ImageExporting
    private let outputSettings: OutputSettings
    private var closeCallbacks: [() -> Void] = []
    private var registeredCloseOwnershipIDs: Set<UUID> = []
    private var didCompleteCloseLifecycle = false

    init(
        session: AnnotationEditingSession,
        exporter: any ImageExporting,
        settingsStore: SettingsStore
    ) {
        self.session = session
        self.exporter = exporter
        self.outputSettings = settingsStore.settings.output
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("UshotApp Canvas Editor", comment: "Canvas editor window title")
        window.setAccessibilityIdentifier("editor.window")
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: CanvasEditorRootView(
            session: session,
            settingsStore: settingsStore,
            onCopy: { [weak self] in self?.copyImage() },
            onExport: { [weak self] in self?.exportImage() },
            onDone: { [weak self] in self?.close() }
        ))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func registerCloseCallback(_ callback: (() -> Void)?, ownershipID: UUID?) {
        guard let callback else { return }
        precondition(
            !didCompleteCloseLifecycle,
            "A close callback cannot be registered after the canvas editor has closed."
        )
        if let ownershipID,
           !registeredCloseOwnershipIDs.insert(ownershipID).inserted
        {
            AppLog.lifecycle.debug("Ignored duplicate canvas-editor ownership callback registration")
            return
        }
        closeCallbacks.append(callback)
        AppLog.lifecycle.debug(
            "Registered canvas-editor close callback: pendingCallbacks=\(self.closeCallbacks.count, privacy: .public)"
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard !didCompleteCloseLifecycle else {
            AppLog.lifecycle.error("Ignored duplicate canvas-editor window close notification")
            return
        }
        didCompleteCloseLifecycle = true
        let callbacks = closeCallbacks
        closeCallbacks.removeAll()
        AppLog.lifecycle.notice(
            "Closing canvas editor: registeredCallbacks=\(callbacks.count, privacy: .public)"
        )
        callbacks.forEach { $0() }
        onClose?()
        onClose = nil
    }

    private func copyImage() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.session.resolvedPreviewImage()
                let image = resolved.image
                let item = NSPasteboardItem()
                item.setData(try self.exporter.pngData(for: image), forType: .png)
                if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([item]) else {
                    throw ScreenshotAppError.exportFailed(description: "The pasteboard rejected the rendered image.")
                }
            } catch {
                self.present(error)
            }
        }
    }

    private func exportImage() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [outputSettings.format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = FilenameTemplateFormatter().filename(
            template: outputSettings.filenameTemplate,
            date: Date(),
            fileExtension: outputSettings.format.fileExtension
        )
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let resolved = try await self.session.resolvedPreviewImage()
                    let image = resolved.image
                    try self.exporter.write(
                        image,
                        format: self.outputSettings.format,
                        preservesColorProfile: self.outputSettings.preservesColorProfile,
                        to: url
                    )
                } catch {
                    self.present(error)
                }
            }
        }
    }

    private func present(_ error: Error) {
        AppLog.export.error("Canvas editor export failed: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window!)
    }
}
