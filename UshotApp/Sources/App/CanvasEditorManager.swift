import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UshotCore

@MainActor
final class CanvasEditorManager {
    private let exporter: any ImageExporting
    private let settingsStore: SettingsStore
    private let updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    private let sessionRegistry: AnnotationSessionRegistry
    private var controllers: [UUID: CanvasEditorWindowController] = [:]
    var hasOpenEditors: Bool { !controllers.isEmpty }

    init(
        exporter: any ImageExporting = SystemImageExporter(),
        settingsStore: SettingsStore,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker,
        sessionRegistry: AnnotationSessionRegistry
    ) {
        self.exporter = exporter
        self.settingsStore = settingsStore
        self.updateSensitiveActivityTracker = updateSensitiveActivityTracker
        self.sessionRegistry = sessionRegistry
    }

    func open(
        session: AnnotationEditingSession,
        ownershipID: UUID? = nil,
        onClose: (() -> Void)? = nil
    ) {
        let session = sessionRegistry.register(session)
        let key = session.controller.document.id
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
            settingsStore: settingsStore,
            updateSensitiveActivityTracker: updateSensitiveActivityTracker
        )
        controller.registerCloseCallback(onClose, ownershipID: ownershipID)
        controller.onClose = { [weak self] in self?.controllers[key] = nil }
        controllers[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func prepareForApplicationTermination() throws {
        do {
            for controller in controllers.values {
                try controller.prepareForApplicationTermination()
            }
        } catch {
            resumeAfterCancelledTermination()
            throw error
        }
    }

    func flushForApplicationTermination() async throws {
        for controller in Array(controllers.values) {
            try await controller.flushForApplicationTermination()
        }
    }

    func resumeAfterCancelledTermination() {
        for controller in controllers.values {
            controller.resumeAfterCancelledTermination()
        }
    }

#if DEBUG
    func waitForCanvasForRegression(documentID: UUID) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while let controller = controllers[documentID], !controller.hasRegisteredCanvasForRegression {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ScreenshotAppError.historyPersistenceFailed(description: "The regression editor did not register its canvas.")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard controllers[documentID] != nil else {
            throw ScreenshotAppError.historyPersistenceFailed(description: "The regression editor closed before canvas registration.")
        }
    }

    func requestCloseForRegression(documentID: UUID) {
        controllers[documentID]?.window?.performClose(nil)
    }
#endif
}

@MainActor
private final class CanvasEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let session: AnnotationEditingSession
    private let exporter: any ImageExporting
    private let outputSettings: OutputSettings
    private let updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    private let commandGate: CanvasEditorCommandGate
    private var closeCallbacks: [() -> Void] = []
    private var registeredCloseOwnershipIDs: Set<UUID> = []
    private var didCompleteCloseLifecycle = false
    private enum HistoryFinalization: Equatable {
        case none
        case closing
        case terminating
    }
    private var historyFinalization = HistoryFinalization.none
    private var historyFinalizationTask: Task<Void, Error>?
    private var historyFinalizationGeneration = UUID()
    private var activeSavePanel: NSSavePanel?

#if DEBUG
    var hasRegisteredCanvasForRegression: Bool { commandGate.hasRegisteredCanvasForRegression }
#endif

    init(
        session: AnnotationEditingSession,
        exporter: any ImageExporting,
        settingsStore: SettingsStore,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    ) {
        self.session = session
        self.exporter = exporter
        self.outputSettings = settingsStore.settings.output
        self.updateSensitiveActivityTracker = updateSensitiveActivityTracker
        let commandGate = CanvasEditorCommandGate()
        self.commandGate = commandGate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Ushot Canvas Editor", comment: "Canvas editor window title")
        window.setAccessibilityIdentifier("editor.window")
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: CanvasEditorRootView(
            session: session,
            settingsStore: settingsStore,
            commandGate: commandGate,
            onCopy: { [weak self] in self?.copyImage() },
            onExport: { [weak self] in self?.exportImage() },
            onDone: { [weak self] in self?.closeFromCommandBar() }
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
        historyFinalizationGeneration = UUID()
        historyFinalizationTask = nil
        let callbacks = closeCallbacks
        closeCallbacks.removeAll()
        AppLog.lifecycle.notice(
            "Closing canvas editor: registeredCallbacks=\(callbacks.count, privacy: .public)"
        )
        callbacks.forEach { $0() }
        onClose?()
        onClose = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose(reason: "window-close")
        return false
    }

    private func closeFromCommandBar() {
        requestClose(reason: "done")
    }

    private func prepareHistoryFinalization(reason: String) throws {
        guard activeSavePanel == nil, window?.attachedSheet == nil else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: String(localized: "Close the open editor dialog before closing the editor or quitting Ushot.")
            )
        }
        try commandGate.prepareForHistoryFinalization(reason: reason)
        session.controller.finishPendingContinuousEdit(reason: reason)
    }

    private func finalHistoryPersistenceTask() -> Task<Void, Error> {
        if let historyFinalizationTask { return historyFinalizationTask }
        let session = session
        let task = Task { @MainActor in try await session.flushHistory() }
        historyFinalizationGeneration = UUID()
        historyFinalizationTask = task
        return task
    }

    private func requestClose(reason: String) {
        guard historyFinalization == .none, !didCompleteCloseLifecycle else { return }
        do {
            try prepareHistoryFinalization(reason: reason)
        } catch {
            commandGate.setInteractionSuspended(false)
            present(error)
            return
        }
        historyFinalization = .closing
        let task = finalHistoryPersistenceTask()
        let generation = historyFinalizationGeneration
        Task { @MainActor [self] in
            let result = await task.result
            // Application termination may have adopted this same barrier.
            guard historyFinalization == .closing,
                  generation == historyFinalizationGeneration
            else { return }
            historyFinalizationTask = nil
            switch result {
            case .success:
                close()
            case .failure(let error):
                historyFinalization = .none
                commandGate.setInteractionSuspended(false)
                present(error)
            }
        }
    }

    func prepareForApplicationTermination() throws {
        guard historyFinalization != .terminating else { return }
        if historyFinalization == .none {
            try prepareHistoryFinalization(reason: "application-termination")
        }
        historyFinalization = .terminating
    }

    func flushForApplicationTermination() async throws {
        precondition(historyFinalization == .terminating, "Prepare Canvas input before its termination barrier.")
        try await finalHistoryPersistenceTask().value
    }

    func resumeAfterCancelledTermination() {
        guard historyFinalization == .terminating else { return }
        historyFinalization = .none
        historyFinalizationGeneration = UUID()
        historyFinalizationTask = nil
        commandGate.setInteractionSuspended(false)
    }

    private func copyImage() {
        guard commandGate.resolveActiveTextEditing(reason: "copy") else { return }
        let updateSensitiveActivityTracker = updateSensitiveActivityTracker
        let lease = updateSensitiveActivityTracker.begin(
            operation: "canvas-editor-copy"
        )
        Task { @MainActor [self] in
            defer { updateSensitiveActivityTracker.finish(lease) }
            do {
                let resolved = try await self.session.resolvedPreviewImage()
                let image = resolved.image
                try writeImageToPasteboard(image, pngData: self.exporter.pngData(for: image))
            } catch {
                self.present(error)
            }
        }
    }

    private func exportImage() {
        guard commandGate.resolveActiveTextEditing(reason: "export") else { return }
        guard let window, activeSavePanel == nil, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [outputSettings.format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = FilenameTemplateFormatter().filename(
            template: outputSettings.filenameTemplate,
            date: Date(),
            fileExtension: outputSettings.format.fileExtension
        )
        activeSavePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeSavePanel = nil
            guard response == .OK, let url = panel.url else { return }
            let updateSensitiveActivityTracker = self.updateSensitiveActivityTracker
            let lease = updateSensitiveActivityTracker.begin(
                operation: "canvas-editor-export"
            )
            Task { @MainActor [self] in
                defer { updateSensitiveActivityTracker.finish(lease) }
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
