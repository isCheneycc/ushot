import AppKit
import Combine
import UniformTypeIdentifiers
import UshotCore

@MainActor
final class PinnedShotManager {
    var onOpenEditor: ((AnnotationEditingSession, UUID) -> Void)?
    var onError: ((Error) -> Void)?

    private let exporter: any ImageExporting
    private let settingsStore: SettingsStore
    private let historyStore: any ScreenshotHistoryStoring
    private let updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    private let admitAppWork: @MainActor () throws -> Void
    private var currentController: PinnedShotPanelController?
    private var regionDraftController: PinnedShotPanelController?
    private var preparedRegionDraftToolbarController: PinnedShotToolbarController?
    private var canvasEditorLeases: [ObjectIdentifier: UUID] = [:]
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    var hasBlockingUpdateActivity: Bool {
        !canvasEditorLeases.isEmpty
            || regionDraftController != nil
            || currentController?.hasBlockingUpdateActivity == true
    }

    init(
        exporter: any ImageExporting = SystemImageExporter(),
        settingsStore: SettingsStore,
        historyStore: any ScreenshotHistoryStoring,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker,
        admitAppWork: @escaping @MainActor () throws -> Void = {}
    ) {
        self.exporter = exporter
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.updateSensitiveActivityTracker = updateSensitiveActivityTracker
        self.admitAppWork = admitAppWork
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.currentController?.releaseRebuildableCaches()
            self?.regionDraftController?.releaseRebuildableCaches()
            self?.preparedRegionDraftToolbarController = nil
            AppLog.capture.notice("Released current pinned-shot export cache after memory pressure")
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Logical region corner radius from Capture settings for the given backing scale.
    func configuredRegionCornerRadius(backingScale: CGFloat) -> CGFloat {
        settingsStore.settings.capture.logicalRegionCornerRadius(backingScale: backingScale)
    }

    func prepareRegionDraftToolbar() {
        guard preparedRegionDraftToolbarController == nil else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let editor = settingsStore.settings.editor
        guard let initialColor = AnnotationColorPalette.color(
            fromHex: editor.defaultColorHex
        ) else {
            preconditionFailure(
                "Validated editor settings must provide a toolbar default color."
            )
        }
        let controller = PinnedShotToolbarController(
            initialStyle: AnnotationStyle(strokeColor: initialColor),
            initialLineWidthUnit: .points,
            toolShortcuts: settingsStore.settings.shortcuts.annotationToolAssignments,
            colorPaletteHexes: editor.availableColorHexes,
            backingScale: 1,
            showsPinAction: true
        )
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()
        let fittingSize = controller.view.fittingSize
        precondition(
            fittingSize.width.isFinite && fittingSize.width > 0,
            "A prepared region toolbar must resolve a non-empty intrinsic width."
        )
        preparedRegionDraftToolbarController = controller
        AppLog.capture.notice(
            "Prepared reusable region toolbar: durationMs=\((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000, privacy: .public), width=\(fittingSize.width, privacy: .public)"
        )
    }

    func present(_ result: CaptureResult) {
        precondition(
            regionDraftController == nil,
            "A non-region capture cannot be presented while region confirmation is active."
        )
        let capturedImage = result.presentationImage
        AppLog.capture.notice(
            "Presenting screenshot: kind=\(capturedImage.sourceMetadata.kind.rawValue, privacy: .public), logical=\(capturedImage.logicalSize.width, privacy: .public)x\(capturedImage.logicalSize.height, privacy: .public), pixels=\(capturedImage.image.width, privacy: .public)x\(capturedImage.image.height, privacy: .public), scale=\(capturedImage.scale, privacy: .public)x"
        )
        let session = AnnotationEditingSession(
            capturedImage: capturedImage,
            editorSettings: settingsStore.settings.editor,
            updateSensitiveActivityTracker: updateSensitiveActivityTracker
        )
        let identifier = UUID()
        let captureSettings = settingsStore.settings.capture
        completeCaptureActions(for: session, opensCanvasEditor: false)
        guard captureSettings.presentsPinnedShot else {
            if captureSettings.automaticallyOpensCanvasEditor {
                presentCanvasEditor(for: session, reason: "automatic-capture-action")
            }
            return
        }
        let showsToolbar = captureSettings.showsQuickToolbar

        if let currentController {
            AppLog.capture.notice(
                "Replacing current screenshot: previous=\(currentController.identifier.uuidString, privacy: .public), replacement=\(identifier.uuidString, privacy: .public)"
            )
            recycleRegionDraftToolbar(from: currentController)
            currentController.close(reason: .replacement)
        }

        let controller = PinnedShotPanelController(
            identifier: identifier,
            session: session,
            exporter: exporter,
            settingsStore: settingsStore,
            outputSettings: settingsStore.settings.output,
            presentationMode: .pinned(showsToolbar: showsToolbar),
            updateSensitiveActivityTracker: updateSensitiveActivityTracker,
            admitAppWork: admitAppWork
        )
        controller.onClose = { [weak self] identifier in
            guard self?.currentController?.identifier == identifier else { return }
            self?.currentController = nil
        }
        controller.onOpenEditor = { [weak self] session in
            self?.presentCanvasEditor(for: session, reason: "pinned-toolbar-action")
        }
        controller.onError = { [weak self] error in
            self?.onError?(error)
        }
        currentController = controller
        if captureSettings.automaticallyOpensCanvasEditor {
            controller.beginCanvasEditorPresentation(reason: "automatic-editor-before-pinned-presentation")
        } else if canvasEditorLeases[ObjectIdentifier(session)] != nil {
            controller.beginCanvasEditorPresentation(reason: "automatic-editor-already-presented")
        }
        controller.present()
        if captureSettings.automaticallyOpensCanvasEditor {
            presentCanvasEditor(for: session, reason: "automatic-capture-action")
        }
    }

    func presentRegionDraft(
        _ capturedImage: CapturedImage,
        onPin: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onResizeBegan: @escaping (RegionSelectionResizeHandle, CGPoint) -> Void,
        onResizeChanged: @escaping (CGPoint) -> Void,
        onResizeEnded: @escaping (CGPoint) -> Void,
        onMoveBegan: @escaping (CGPoint) -> Void,
        onMoveChanged: @escaping (CGPoint) -> Void,
        onMoveEnded: @escaping (CGPoint) -> Void
    ) {
        let identifier = UUID()
        let configuredCornerRadius = settingsStore.settings.capture.logicalRegionCornerRadius(
            backingScale: capturedImage.scale
        )
        let cornerRadius = RegionCaptureCornerRadius.effective(
            for: capturedImage.logicalSize,
            configured: configuredCornerRadius
        )
        let regionDocument = AnnotationDocument(
            baseImageReference: ImageReference(
                relativePath: "base.png",
                pixelSize: capturedImage.pixelSize,
                colorSpaceName: capturedImage.colorSpace?.name as String?
            ),
            canvasSize: capturedImage.logicalSize,
            canvasEffects: CanvasEffects(cornerRadius: cornerRadius)
        )
        let session = AnnotationEditingSession(
            capturedImage: capturedImage,
            document: regionDocument,
            editorSettings: settingsStore.settings.editor,
            updateSensitiveActivityTracker: updateSensitiveActivityTracker,
            configuredRegionCornerRadius: configuredCornerRadius
        )
        AppLog.capture.notice(
            "Presenting transparent region confirmation surface: id=\(identifier.uuidString, privacy: .public), logical=\(capturedImage.logicalSize.width, privacy: .public)x\(capturedImage.logicalSize.height, privacy: .public), cachedPixels=\(capturedImage.image.width, privacy: .public)x\(capturedImage.image.height, privacy: .public), cornerRadius=\(cornerRadius, privacy: .public), configuredCornerRadius=\(configuredCornerRadius, privacy: .public), cornerRadiusUnit=\(self.settingsStore.settings.capture.regionCornerRadiusUnit.rawValue, privacy: .public), outputCommitted=false"
        )

        precondition(
            regionDraftController == nil,
            "Only one region confirmation may be active at a time."
        )

        if preparedRegionDraftToolbarController == nil {
            prepareRegionDraftToolbar()
        }
        guard let preparedToolbarController = preparedRegionDraftToolbarController else {
            preconditionFailure("Region draft presentation requires a prepared toolbar controller.")
        }
        preparedRegionDraftToolbarController = nil

        let controller = PinnedShotPanelController(
            identifier: identifier,
            session: session,
            exporter: exporter,
            settingsStore: settingsStore,
            outputSettings: settingsStore.settings.output,
            presentationMode: .regionDraft,
            preparedToolbarController: preparedToolbarController,
            updateSensitiveActivityTracker: updateSensitiveActivityTracker,
            admitAppWork: admitAppWork
        )
        controller.onClose = { [weak self] identifier in
            if self?.currentController?.identifier == identifier {
                self?.currentController = nil
            }
            if self?.regionDraftController?.identifier == identifier {
                self?.regionDraftController = nil
            }
        }
        controller.onOpenEditor = { [weak self] session in
            self?.presentCanvasEditor(for: session, reason: "region-toolbar-action")
        }
        controller.onError = { [weak self] error in
            self?.onError?(error)
        }
        controller.onRegionDraftPinned = { [weak self, weak controller] pinnedIdentifier in
            guard let self,
                  let controller,
                  self.regionDraftController?.identifier == pinnedIdentifier
            else {
                preconditionFailure("Only the active region confirmation may transition into a pinned screenshot.")
            }
            let previousPinnedController = self.currentController
            self.regionDraftController = nil
            self.currentController = controller
            if let previousPinnedController, previousPinnedController !== controller {
                self.recycleRegionDraftToolbar(from: previousPinnedController)
                previousPinnedController.close(reason: .replacement)
            }
            onPin()
            self.completeCaptureActions(for: session)
        }
        controller.onRegionDraftCopied = { [weak self, weak controller] copiedIdentifier in
            guard let self,
                  let controller,
                  self.regionDraftController?.identifier == copiedIdentifier
            else {
                preconditionFailure("Only the active region confirmation may complete Copy.")
            }
            self.recycleRegionDraftToolbar(from: controller)
            onCopy()
            controller.close(reason: .regionCopied)
        }
        controller.onRegionDraftSaved = { [weak self, weak controller] savedIdentifier in
            guard let self,
                  let controller,
                  self.regionDraftController?.identifier == savedIdentifier
            else {
                preconditionFailure("Only the active region confirmation may complete Save.")
            }
            self.recycleRegionDraftToolbar(from: controller)
            onSave()
            controller.close(reason: .regionSaved)
        }
        controller.onRegionDraftCancelled = { [weak self, weak controller] cancelledIdentifier in
            guard let controller, cancelledIdentifier == identifier else {
                preconditionFailure("The cancelled region draft identifier did not match its controller.")
            }
            self?.recycleRegionDraftToolbar(from: controller)
            onCancel()
        }
        controller.onRegionDraftResizeBegan = onResizeBegan
        controller.onRegionDraftResizeChanged = onResizeChanged
        controller.onRegionDraftResizeEnded = onResizeEnded
        controller.onRegionDraftMoveBegan = onMoveBegan
        controller.onRegionDraftMoveChanged = onMoveChanged
        controller.onRegionDraftMoveEnded = onMoveEnded
        regionDraftController = controller
        controller.present()
    }

    func previewCurrentRegionDraftFrame(
        _ frame: CGRect,
        change: RegionDraftGeometryChange
    ) {
        guard let regionDraftController, regionDraftController.isRegionDraft else {
            preconditionFailure("Region selection requested a frame preview without a current region draft.")
        }
        regionDraftController.previewRegionDraftFrame(frame, change: change)
    }

    func setCurrentRegionDraftGeometryUpdating(_ updating: Bool) {
        guard let regionDraftController, regionDraftController.isRegionDraft else {
            preconditionFailure("Region selection changed geometry state without a current region draft.")
        }
        regionDraftController.setRegionDraftGeometryUpdating(updating)
    }

    func updateCurrentRegionDraft(
        _ capturedImage: CapturedImage,
        change: RegionDraftGeometryChange
    ) {
        guard let regionDraftController, regionDraftController.isRegionDraft else {
            preconditionFailure("Region selection supplied a recrop without a current region draft.")
        }
        regionDraftController.updateRegionDraft(capturedImage, change: change)
    }

    @discardableResult
    func endCurrentRegionDraftTextEditing() -> Bool {
        guard let regionDraftController, regionDraftController.isRegionDraft else {
            preconditionFailure("Region selection tried to end text editing without a current region draft.")
        }
        return regionDraftController.endTextEditingForGeometryChange()
    }

    func reportRegionDraftUpdateFailure(_ error: Error) {
        AppLog.capture.error(
            "Region draft geometry update failed: \(error.localizedDescription, privacy: .public)"
        )
        onError?(error)
    }

    func pinCurrentRegionDraft() {
        guard let regionDraftController, regionDraftController.isRegionDraft else {
            preconditionFailure("Region selection requested Pin without a current editable region draft.")
        }
        regionDraftController.pinRegionDraft()
    }

    func cancelCurrentRegionDraft() {
        guard let regionDraftController, regionDraftController.isRegionDraft else {
            preconditionFailure("Region selection requested cancellation without a current editable region draft.")
        }
        regionDraftController.cancelRegionDraft()
    }

    func closeForApplicationTermination() {
        regionDraftController?.close(reason: .applicationTermination)
        currentController?.close(reason: .applicationTermination)
    }

    func canvasEditorDidClose(session: AnnotationEditingSession, leaseID: UUID) {
        let key = ObjectIdentifier(session)
        guard canvasEditorLeases[key] == leaseID else {
            AppLog.capture.debug("Ignored stale canvas-editor close notification")
            return
        }
        canvasEditorLeases.removeValue(forKey: key)
        AppLog.capture.notice("Scheduled exclusive canvas-editor ownership release after window teardown")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.canvasEditorLeases[key] == nil else {
                AppLog.capture.notice("Kept exclusive canvas-editor ownership after an immediate reopen")
                return
            }
            self.currentController?.endCanvasEditorPresentation(for: session)
            self.regionDraftController?.endCanvasEditorPresentation(for: session)
            AppLog.capture.notice("Released exclusive canvas-editor ownership")
        }
    }

    private func presentCanvasEditor(for session: AnnotationEditingSession, reason: String) {
        do {
            try admitAppWork()
        } catch {
            AppLog.updates.notice(
                "Rejected canvas-editor presentation during an update transaction: reason=\(reason, privacy: .public)"
            )
            NSSound.beep()
            onError?(error)
            return
        }
        guard let onOpenEditor else {
            preconditionFailure("Canvas-editor presentation requires an installed application coordinator.")
        }
        let key = ObjectIdentifier(session)
        let leaseID = canvasEditorLeases[key] ?? UUID()
        canvasEditorLeases[key] = leaseID
        currentController?.beginCanvasEditorPresentation(for: session, reason: reason)
        regionDraftController?.beginCanvasEditorPresentation(for: session, reason: reason)
        AppLog.capture.notice(
            "Acquired exclusive canvas-editor ownership: reason=\(reason, privacy: .public)"
        )
        onOpenEditor(session, leaseID)
    }

    private func recycleRegionDraftToolbar(from controller: PinnedShotPanelController) {
        guard preparedRegionDraftToolbarController == nil,
              let toolbarController = controller.takeRegionDraftToolbarForReuse()
        else { return }
        preparedRegionDraftToolbarController = toolbarController
        AppLog.capture.debug("Recycled region toolbar for the next selection")
    }

#if DEBUG
    func runLineWidthRoutingRegression() {
        guard let currentController else {
            preconditionFailure("Line-width routing regression requires a current screenshot.")
        }
        currentController.runLineWidthRoutingRegression()
    }

    func runReadOnlyWindowPressCursorRegression() {
        guard let currentController else {
            preconditionFailure("Pinned cursor regression requires a current screenshot.")
        }
        currentController.runReadOnlyWindowPressCursorRegression()
    }

    func runInlineTextStabilityRegression() {
        guard let currentController else {
            preconditionFailure("Inline text stability regression requires a current screenshot.")
        }
        currentController.runInlineTextStabilityRegression()
    }

    func prepareInlineTextResizeUITest() {
        guard let currentController else {
            preconditionFailure("Inline text resize UI testing requires a current screenshot.")
        }
        currentController.prepareInlineTextResizeUITest()
    }
#endif

    private func completeCaptureActions(
        for session: AnnotationEditingSession,
        opensCanvasEditor: Bool = true
    ) {
        let captureSettings = settingsStore.settings.capture
        if settingsStore.settings.history.isEnabled {
            let recorder = HistorySessionRecorder(
                session: session,
                store: historyStore,
                settingsStore: settingsStore,
                updateSensitiveActivityTracker: updateSensitiveActivityTracker,
                onError: { [weak self] error in self?.onError?(error) }
            )
            session.attachHistoryRecorder(recorder)
        }
        if captureSettings.automaticallyCopies {
            automaticallyCopy(session.previewImage)
        }
        if captureSettings.automaticallySaves {
            automaticallySave(session.previewImage)
        }
        if opensCanvasEditor && captureSettings.automaticallyOpensCanvasEditor {
            presentCanvasEditor(for: session, reason: "automatic-capture-action")
        }
    }

    private func automaticallyCopy(_ image: CapturedImage) {
        do {
            let item = NSPasteboardItem()
            item.setData(try exporter.pngData(for: image.image), forType: .png)
            if let tiff = NSBitmapImageRep(cgImage: image.image).tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else {
                throw ScreenshotAppError.exportFailed(
                    description: "The pasteboard rejected the automatically copied screenshot."
                )
            }
        } catch {
            onError?(error)
        }
    }

    private func automaticallySave(_ image: CapturedImage) {
        do {
            let output = settingsStore.settings.output
            guard let path = output.defaultDirectoryPath, !path.isEmpty else {
                throw ScreenshotAppError.exportFailed(
                    description: "Automatic saving has no configured output directory. It has been paused."
                )
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw ScreenshotAppError.exportFailed(
                    description: "The automatic-save directory is unavailable. Automatic saving has been paused."
                )
            }
            let filename = FilenameTemplateFormatter().filename(
                template: output.filenameTemplate,
                date: Date(),
                fileExtension: output.format.fileExtension
            )
            let destination = availableDestination(
                in: directory,
                preferredFilename: filename
            )
            try exporter.write(
                image.image,
                format: output.format,
                preservesColorProfile: output.preservesColorProfile,
                to: destination
            )
        } catch {
            pauseAutomaticSaving(after: error)
        }
    }

    private func availableDestination(in directory: URL, preferredFilename: String) -> URL {
        let preferred = directory.appendingPathComponent(preferredFilename)
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        let base = preferred.deletingPathExtension().lastPathComponent
        let pathExtension = preferred.pathExtension
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)-\(index).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func pauseAutomaticSaving(after originalError: Error) {
        do {
            try settingsStore.update(\AppSettings.capture.automaticallySaves, to: false)
            onError?(originalError)
        } catch {
            onError?(ScreenshotAppError.settingsPersistenceFailed(
                description: "\(originalError.localizedDescription) The automatic-save setting also could not be paused: \(error.localizedDescription)"
            ))
        }
    }
}

private enum PinnedShotPresentationMode {
    case pinned(showsToolbar: Bool)
    case regionDraft

    var showsToolbar: Bool {
        switch self {
        case .pinned(let showsToolbar): showsToolbar
        case .regionDraft: true
        }
    }

    var isRegionDraft: Bool {
        if case .regionDraft = self { return true }
        return false
    }
}

private enum PinnedShotCloseReason: String {
    case applicationTermination = "application-termination"
    case copied
    case escape
    case replacement
    case regionCopied = "region-copied"
    case regionSaved = "region-saved"
    case regionSelectionCancelled = "region-selection-cancelled"
    case toolbar
}

@MainActor
private final class PinnedShotPanelController: NSObject, NSWindowDelegate, NSDraggingSource {
    private enum CopyRequestSource: String {
        case toolbar
        case keyboard
        case contextMenu = "context-menu"
    }

    private enum CopyCompletionPolicy: String {
        case dismissAfterSuccess = "dismiss-after-success"
        case keepPresented = "keep-presented"
    }

    private enum CopySuccessDisposition: Equatable {
        case completeRegionSelection
        case closePresentedScreenshot
        case keepPresented
    }

    private enum ExportAction: String {
        case copy
        case save
    }

    private struct ExportTransaction {
        let identifier: UUID
        let action: ExportAction
        let beganAsRegionDraft: Bool
        let desktopFrame: CGRect
        let imageIgnoredMouseEvents: Bool
        let resizeWasEnabled: Bool?
    }

    private struct WindowMoveInteraction {
        let startedAt: TimeInterval
        let pointerOrigin: CGPoint
        let panelOrigin: CGPoint
    }

    private enum LineWidthEditDisposition: String {
        case commitOrReject = "commit-or-reject"
        case cancel
    }

    let identifier: UUID
    var onClose: ((UUID) -> Void)?
    var onOpenEditor: ((AnnotationEditingSession) -> Void)?
    var onError: ((Error) -> Void)?
    var onRegionDraftPinned: ((UUID) -> Void)?
    var onRegionDraftCopied: ((UUID) -> Void)?
    var onRegionDraftSaved: ((UUID) -> Void)?
    var onRegionDraftCancelled: ((UUID) -> Void)?
    var onRegionDraftResizeBegan: ((RegionSelectionResizeHandle, CGPoint) -> Void)?
    var onRegionDraftResizeChanged: ((CGPoint) -> Void)?
    var onRegionDraftResizeEnded: ((CGPoint) -> Void)?
    var onRegionDraftMoveBegan: ((CGPoint) -> Void)?
    var onRegionDraftMoveChanged: ((CGPoint) -> Void)?
    var onRegionDraftMoveEnded: ((CGPoint) -> Void)?

    private var capturedImage: CapturedImage
    private let session: AnnotationEditingSession
    private let payload: PinnedShotPayload
    private let imagePanel: PinnedShotPanel
    private let toolbarPanel: PinnedShotToolbarPanel
    private let imageView: QuickAnnotationCanvasView
    private var regionDraftContainerView: RegionDraftContainerView?
    private var regionDraftChromeView: RegionDraftChromeView?
    private let toolbarController: PinnedShotToolbarController
    private let ownsReusableRegionToolbar: Bool
    private let settingsStore: SettingsStore
    private let outputSettings: OutputSettings
    private let updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    private let admitAppWork: @MainActor () throws -> Void
    private var presentationMode: PinnedShotPresentationMode
    private var promiseDelegates: [FilePromiseDelegate] = []
    private var cancellables: Set<AnyCancellable> = []
    private var keyboardMonitor: Any?
    private var activeSavePanel: NSSavePanel?
    private var activeExportTransaction: ExportTransaction?
    private var activeExportTask: Task<Void, Never>?
    private var imageIsHidden = false
    private var copiedOrSaved = false
    private var retainsAfterCopy = false
    private var closeReason: PinnedShotCloseReason?
    private var regionDraftTransitionInProgress = false
    private var regionDraftImageIgnoredMouseEvents = false
    private var regionDraftGeometryUpdateInProgress = false
    private var regionDraftGeometryImageIgnoredMouseEvents = false
    private var didReleaseRegionToolbar = false
    private var toolbarContextMenuItem: NSMenuItem?
    private var windowMoveInteraction: WindowMoveInteraction?
    private var liveResizeInProgress = false
    private var canvasEditorPresented = false
    private var restoresToolbarAfterCanvasEditor = false
    private var isApplyingEditorSettings = false

    var isRegionDraft: Bool { presentationMode.isRegionDraft }
    private var exportInProgress: Bool { activeExportTransaction != nil }
    var hasBlockingUpdateActivity: Bool {
        presentationMode.isRegionDraft
            || presentationMode.showsToolbar
            || canvasEditorPresented
            || activeSavePanel != nil
            || exportInProgress
            || !promiseDelegates.isEmpty
            || regionDraftTransitionInProgress
            || regionDraftGeometryUpdateInProgress
            || windowMoveInteraction != nil
            || liveResizeInProgress
    }

    init(
        identifier: UUID,
        session: AnnotationEditingSession,
        exporter: any ImageExporting,
        settingsStore: SettingsStore,
        outputSettings: OutputSettings,
        presentationMode: PinnedShotPresentationMode,
        preparedToolbarController: PinnedShotToolbarController? = nil,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker,
        admitAppWork: @escaping @MainActor () throws -> Void = {}
    ) {
        precondition(
            preparedToolbarController == nil || presentationMode.isRegionDraft,
            "Only a region draft may consume the prepared Pin toolbar."
        )
        self.identifier = identifier
        self.session = session
        self.capturedImage = session.baseImage
        self.payload = PinnedShotPayload(capturedImage: session.previewImage, exporter: exporter)
        self.settingsStore = settingsStore
        self.outputSettings = outputSettings
        self.updateSensitiveActivityTracker = updateSensitiveActivityTracker
        self.admitAppWork = admitAppWork
        self.presentationMode = presentationMode
        self.ownsReusableRegionToolbar = presentationMode.isRegionDraft

        let initialSize = Self.initialWindowSize(for: session.baseImage)
        // Prefer the capture desktop frame for region drafts so the panel is
        // born at the same size positionImagePanel will commit, avoiding a
        // content reflow when the window is first ordered front.
        let regionSelectionSize = session.baseImage.sourceMetadata.desktopFrame.standardized.size
        let initialPanelSize = presentationMode.isRegionDraft
            ? RegionDraftChromeView.panelSize(for: regionSelectionSize)
            : initialSize
        self.imagePanel = PinnedShotPanel(
            contentRect: NSRect(origin: .zero, size: initialPanelSize),
            styleMask: presentationMode.isRegionDraft ? [.borderless] : [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        self.imageView = QuickAnnotationCanvasView(
            session: session,
            drawsBaseImage: !presentationMode.isRegionDraft
        )
        let toolbarController = preparedToolbarController ?? PinnedShotToolbarController(
                initialStyle: session.currentStyle,
                initialLineWidthUnit: session.lineWidthUnit,
                toolShortcuts: settingsStore.settings.shortcuts.annotationToolAssignments,
                colorPaletteHexes: settingsStore.settings.editor.availableColorHexes,
                backingScale: session.baseImage.scale,
                showsPinAction: presentationMode.isRegionDraft
            )
        toolbarController.configureForSession(
            style: session.currentStyle,
            lineWidthUnit: session.lineWidthUnit,
            toolShortcuts: settingsStore.settings.shortcuts.annotationToolAssignments,
            colorPaletteHexes: settingsStore.settings.editor.availableColorHexes,
            backingScale: session.baseImage.scale
        )
        self.toolbarController = toolbarController
        self.toolbarPanel = PinnedShotToolbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 44),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanels(initialSize: initialSize)
        wireActions()
        if case .pinned(let showsToolbar) = presentationMode {
            imageView.setAnnotationEditingEnabled(showsToolbar)
        }
    }

    func present() {
        positionImagePanel()
        if presentationMode.isRegionDraft {
            // Desktop-frame geometry is the authority. Synchronize content
            // layout against it before first paint so the confirmation surface
            // never lands for one frame at the init contentRect size/origin and
            // then reflows into the capture frame (visible as a tiny jump).
            let selectionFrame = capturedImage.sourceMetadata.desktopFrame.standardized
            let selectionSize = selectionFrame.size
            regionDraftContainerView?.synchronizeSelectionSize(selectionSize)
            imageView.syncPresentationContentCornerRadius(for: selectionSize)
            imagePanel.contentView?.layoutSubtreeIfNeeded()
            imagePanel.displayIfNeeded()
            imagePanel.ignoresMouseEvents = false
            precondition(
                !imagePanel.ignoresMouseEvents,
                "The region confirmation surface must own interior pointer input."
            )
            imagePanel.setAccessibilityValue("surfaceInput=enabled; inputOwner=annotation-surface")
            AppLog.capture.notice(
                "Region draft presentation geometry committed before order-front: selection=\(selectionFrame.debugDescription, privacy: .public), panel=\(self.imagePanel.frame.debugDescription, privacy: .public), canvas=\(self.imageView.frame.debugDescription, privacy: .public)"
            )
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        imagePanel.makeKeyAndOrderFront(nil)
        if presentationMode.showsToolbar {
            repositionToolbar()
            toolbarPanel.orderFrontRegardless()
        }
        installKeyboardMonitor()
        AppLog.capture.notice(
            "Presented current screenshot: id=\(self.identifier.uuidString, privacy: .public), imageKey=\(self.imagePanel.isKeyWindow, privacy: .public), toolbarVisible=\(self.presentationMode.showsToolbar, privacy: .public), regionDraft=\(self.presentationMode.isRegionDraft, privacy: .public)"
        )
    }

    func releaseRebuildableCaches() {
        payload.releaseCache()
    }

    func beginCanvasEditorPresentation(for candidate: AnnotationEditingSession, reason: String) {
        guard session === candidate else { return }
        beginCanvasEditorPresentation(reason: reason)
    }

    func beginCanvasEditorPresentation(reason: String) {
        precondition(
            !presentationMode.isRegionDraft,
            "An uncommitted region confirmation cannot share its document with the full canvas editor."
        )
        guard !canvasEditorPresented else {
            AppLog.capture.debug(
                "Kept existing exclusive canvas-editor ownership: id=\(self.identifier.uuidString, privacy: .public), reason=\(reason, privacy: .public)"
            )
            return
        }

        resolveActiveLineWidthEdit(.commitOrReject, reason: "canvas-editor-open")
        imageView.endTextEditingIfNeeded(reason: .externalAction)
        canvasEditorPresented = true
        restoresToolbarAfterCanvasEditor = presentationMode.showsToolbar
        if presentationMode.showsToolbar {
            setPinnedToolbarVisible(
                false,
                reason: "canvas-editor-open",
                preservesSharedEditorState: true
            )
        } else {
            suspendAnnotationEditingForCanvasEditor(reason: "canvas-editor-open")
            updatePinnedContextMenuTitle()
        }
        precondition(
            !presentationMode.showsToolbar
                && !toolbarController.hasAttachedLineWidthFieldEditor
                && !toolbarController.hasActiveLineWidthEditing
                && !imageView.hasActiveLineWidthEditing,
            "The pinned surface must release every editing transaction before the full canvas editor takes ownership."
        )
        AppLog.capture.notice(
            "Pinned surface yielded exclusive annotation ownership to canvas editor: id=\(self.identifier.uuidString, privacy: .public), reason=\(reason, privacy: .public), restoreToolbar=\(self.restoresToolbarAfterCanvasEditor, privacy: .public)"
        )
    }

    func endCanvasEditorPresentation(for candidate: AnnotationEditingSession) {
        guard session === candidate, canvasEditorPresented else { return }
        precondition(
            !presentationMode.isRegionDraft,
            "Canvas-editor ownership can only return to a pinned screenshot."
        )
        let shouldRestoreToolbar = restoresToolbarAfterCanvasEditor
        canvasEditorPresented = false
        restoresToolbarAfterCanvasEditor = false
        synchronizePinnedToolbarAfterCanvasEditor()
        if shouldRestoreToolbar, closeReason == nil {
            setPinnedToolbarVisible(true, reason: "canvas-editor-close")
        } else {
            updatePinnedContextMenuTitle()
        }
        AppLog.capture.notice(
            "Canvas editor released exclusive annotation ownership: id=\(self.identifier.uuidString, privacy: .public), restoredToolbar=\(shouldRestoreToolbar && self.closeReason == nil, privacy: .public)"
        )
    }

    @discardableResult
    func endTextEditingForGeometryChange() -> Bool {
        imageView.endTextEditingIfNeeded(reason: .externalAction)
    }

    func takeRegionDraftToolbarForReuse() -> PinnedShotToolbarController? {
        guard ownsReusableRegionToolbar, !didReleaseRegionToolbar, !exportInProgress else { return nil }
        didReleaseRegionToolbar = true
        prepareToolbarForDetachment(reason: "region-toolbar-reuse")
        return toolbarController
    }

    private func prepareToolbarForDetachment(reason: String) {
        resolveActiveLineWidthEdit(.cancel, reason: reason)
        toolbarController.prepareForReuse()
        precondition(
            !toolbarController.hasAttachedLineWidthFieldEditor
                && !toolbarController.hasActiveLineWidthEditing
                && !imageView.hasActiveLineWidthEditing,
            "A screenshot toolbar must be fully idle before it is detached."
        )
        toolbarPanel.orderOut(nil)
        toolbarPanel.contentViewController = nil
    }

#if DEBUG
    func runLineWidthRoutingRegression() {
        imageView.runLineWidthRoutingRegression()
        persistDefaultLineWidth(
            logicalPoints: 9,
            unit: session.lineWidthUnit
        )

        session.currentTool = .select
        syncLineWidthToolbar()
        precondition(
            toolbarController.debugLineWidthFieldIsEnabled,
            "Select must keep the line-width field enabled for a compatible selected annotation."
        )
        toolbarController.runLineWidthInputCommitRegression(displayedText: "11")
        guard let selectedID = session.controller.selectedItemIDs.first else {
            preconditionFailure("The toolbar line-width regression lost its selected annotation.")
        }
        precondition(
            session.controller.document.annotations.first(where: { $0.id == selectedID })?.style.lineWidth == 11,
            "The real toolbar input callback chain did not update the selected annotation."
        )
        precondition(
            session.defaultStyle(for: .rectangle).lineWidth == 9,
            "Editing a selection through the toolbar must not persist over the rectangle default."
        )

        session.controller.undo()
        precondition(
            session.controller.document.annotations.first(where: { $0.id == selectedID })?.style.lineWidth == 9
                && toolbarController.debugCommittedLineWidth == 9,
            "Undo must synchronize the selected annotation and toolbar field after a real input callback."
        )

        session.controller.selectedItemIDs.removeAll()
        session.currentTool = .rectangle
        let documentBeforeDefaultEdit = session.controller.document
        toolbarController.runLineWidthInputCommitRegression(displayedText: "10")
        precondition(
            session.controller.document == documentBeforeDefaultEdit,
            "A toolbar default-width edit without a selection must not mutate the document."
        )
        precondition(
            session.creationStyle(for: .rectangle).lineWidth == 10
                && session.defaultStyle(for: .rectangle).lineWidth == 10,
            "The real toolbar input callback chain did not update and persist the creation default."
        )

        guard let lifecycleSelectionID = session.controller.document.orderedAnnotations.last?.id else {
            preconditionFailure("The toolbar lifecycle regression requires an existing stroked annotation.")
        }
        session.controller.selectedItemIDs = [lifecycleSelectionID]
        session.currentTool = .select
        toolbarController.beginNativeLineWidthInputRegression(displayedText: "12")
        disableAnnotationEditing(reason: "debug-line-width-lifecycle")
        precondition(
            !toolbarController.debugHasActiveLineWidthEdit,
            "Disabling annotation editing must end the toolbar's line-width transaction."
        )
        imageView.setAnnotationEditingEnabled(true)
        syncLineWidthToolbar()
        precondition(
            !toolbarController.debugLineWidthFieldIsEnabled,
            "Re-enabling Select with no selection must leave the line-width field disabled."
        )

        session.currentTool = .rectangle
        toolbarController.beginLineWidthInputRegression(displayedText: "12")
        let alternateUnit: AnnotationLineWidthUnit = session.lineWidthUnit == .pixels
            ? .points
            : .pixels
        toolbarController.runLineWidthUnitChangeRegression(to: alternateUnit)
        precondition(
            !toolbarController.debugHasActiveLineWidthEdit
                && session.lineWidthUnit == alternateUnit
                && session.creationStyle(for: .rectangle).lineWidth == 12,
            "Changing units must commit and detach the active line-width transaction before conversion."
        )

        toolbarController.beginNativeLineWidthInputRegression(displayedText: "13.")
        selectAnnotationTool(.arrow, reason: "debug-line-width-tool-switch")
        precondition(
            session.currentTool == .arrow
                && !toolbarController.debugHasActiveLineWidthEdit
                && !toolbarController.debugLineWidthFieldHasEditor
                && toolbarController.debugLineWidthFieldString == "13"
                && !imageView.hasActiveLineWidthEditing,
            "Changing tools must resolve both sides of an active native line-width edit and normalize its display before changing ownership."
        )
        precondition(
            session.defaultStyle(for: .rectangle).lineWidth == 13
                && session.creationStyle(for: .arrow).lineWidth == 13,
            "A valid tool-default line width must commit before the next tool loads its default."
        )

        toolbarController.beginNativeLineWidthInputRegression(displayedText: "14")
        imageView.runLineWidthCanvasBoundaryRegression()
        precondition(
            session.creationStyle(for: .arrow).lineWidth == 14
                && !toolbarController.debugHasActiveLineWidthEdit
                && !toolbarController.debugLineWidthFieldHasEditor
                && !imageView.hasActiveLineWidthEditing,
            "Canvas pointer-down must commit and detach the active tool-default line-width edit first."
        )

        guard let sharedSelectionID = session.controller.document.orderedAnnotations.last?.id else {
            preconditionFailure("The shared-session ownership regression requires an existing annotation.")
        }
        session.controller.selectedItemIDs = [sharedSelectionID]
        selectAnnotationTool(.select, reason: "debug-shared-session-selection")
        toolbarController.beginNativeLineWidthInputRegression(displayedText: "15")
        let selectionBeforeCanvasEditor = session.controller.selectedItemIDs
        let restoredToolbarVisibility = presentationMode.showsToolbar
        beginCanvasEditorPresentation(reason: "debug-shared-session-boundary")
        precondition(
            canvasEditorPresented
                && !presentationMode.showsToolbar
                && session.controller.selectedItemIDs == selectionBeforeCanvasEditor
                && session.controller.document.annotations.first(where: { $0.id == sharedSelectionID })?.style.lineWidth == 15
                && !toolbarController.debugHasActiveLineWidthEdit
                && !toolbarController.debugLineWidthFieldHasEditor
                && !imageView.hasActiveLineWidthEditing
                && !imageView.debugIsAnnotationEditingEnabled
                && imageView.debugPresentedSelectionHandleCount == 0,
            "Opening the full editor must commit the selected value, preserve shared selection and make the pinned surface a transaction-free reader."
        )
        session.currentTool = .ellipse
        session.controller.perform(label: "Debug shared-editor delete") { document in
            document.annotations.removeAll { $0.id == sharedSelectionID }
        }
        precondition(
            !session.controller.selectedItemIDs.contains(sharedSelectionID),
            "Deleting the committed line-width target in the full editor must atomically invalidate its selection."
        )
        endCanvasEditorPresentation(for: session)
        precondition(
            !canvasEditorPresented
                && presentationMode.showsToolbar == restoredToolbarVisibility
                && imageView.debugIsAnnotationEditingEnabled == restoredToolbarVisibility,
            "Closing the full editor must release exclusive ownership and restore the prior pinned-toolbar state."
        )

        let restoredEditor = settingsStore.settings.editor
        let exclusiveColorCandidates = ["#12ABEF", "#654321", "#ABCDEF", "#FEDCBA"]
        guard let exclusiveColor = exclusiveColorCandidates.first(where: {
            !restoredEditor.availableColorHexes.contains($0)
        }) else {
            preconditionFailure("The palette ownership regression requires one color outside the configured palette.")
        }
        var exclusiveEditor = restoredEditor
        exclusiveEditor.toolbarColorHexes = [exclusiveColor]
        exclusiveEditor.defaultColorHex = exclusiveColor
        exclusiveEditor.defaultTextColorHex = exclusiveColor
        exclusiveEditor.defaultRectangleColorHex = exclusiveColor
        exclusiveEditor.defaultEllipseColorHex = exclusiveColor
        session.controller.selectedItemIDs.removeAll()
        session.currentTool = .text
        applyEditorColorSettings(exclusiveEditor)
        session.adoptCurrentStyle(session.currentStyle, origin: .newTextDraft)
        beginCanvasEditorPresentation(reason: "debug-canvas-editor-palette-ownership")

        session.updateEditorSettings(restoredEditor)
        session.adoptCurrentStyle(
            session.defaultStyle(for: .text),
            origin: .newTextDraft
        )
        precondition(
            toolbarController.debugColorPaletteHexes == [exclusiveColor],
            "The hidden pinned toolbar must not consume canvas-editor palette mutations."
        )
        endCanvasEditorPresentation(for: session)
        let restoredCurrentColor = AnnotationColorPalette.hexString(
            for: session.currentStyle.strokeColor
        )
        precondition(
            toolbarController.debugColorPaletteHexes == restoredEditor.availableColorHexes
                && toolbarController.debugCurrentColorHex == restoredCurrentColor
                && restoredEditor.availableColorHexes.contains(restoredCurrentColor),
            "Returning from the canvas editor must atomically reconcile the hidden toolbar with the latest palette and active style."
        )
        selectAnnotationTool(.arrow, reason: "debug-shared-session-return")

        toolbarController.beginNativeLineWidthInputRegression(displayedText: "15")
        precondition(
            session.creationStyle(for: .arrow).lineWidth == 15,
            "The toolbar-detachment regression requires a live uncommitted Arrow width."
        )
        prepareToolbarForDetachment(reason: "debug-line-width-toolbar-detachment")
        precondition(
            session.creationStyle(for: .arrow).lineWidth == 14
                && !toolbarController.debugHasActiveLineWidthEdit
                && !toolbarController.debugLineWidthFieldHasEditor
                && !imageView.hasActiveLineWidthEditing,
            "Toolbar detachment must cancel and release its native line-width edit before removing the content view."
        )
        AppLog.capture.notice(
            "Annotation toolbar line-width callback regression passed: selectFieldEnabled=true, selectedCommit=11, selectedUndo=9, defaultCommit=10, lifecycleCancel=true, activeUnitBoundary=true, toolSwitchCommit=13, rawCommitNormalized=true, canvasCommit=14, sharedSessionExclusive=true, sharedSelectionPreserved=true, sharedTargetDeletionSafe=true, paletteOwnershipExclusive=true, paletteReturnAtomic=true, detachCancel=14"
        )
    }

    func runReadOnlyWindowPressCursorRegression() {
        imageView.runReadOnlyWindowPressCursorRegression()
    }

    func runInlineTextStabilityRegression() {
        imageView.runInlineTextStabilityRegression()
    }

    func prepareInlineTextResizeUITest() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        imagePanel.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
        imagePanel.makeKey()
        imageView.prepareInlineTextResizeUITest()
        imagePanel.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
    }
#endif

    func close(reason: PinnedShotCloseReason) {
        guard closeReason == nil else { return }
        cancelActiveExport(reason: "close-\(reason.rawValue)")
        closeReason = reason
        disableAnnotationEditing(reason: "close-\(reason.rawValue)")
        AppLog.capture.notice(
            "Closing current screenshot: id=\(self.identifier.uuidString, privacy: .public), reason=\(reason.rawValue, privacy: .public)"
        )
        imagePanel.close()
    }

    func windowDidMove(_ notification: Notification) {
        repositionToolbar()
    }

    func windowDidResize(_ notification: Notification) {
        repositionToolbar()
    }

    func windowWillClose(_ notification: Notification) {
        cancelActiveExport(reason: "window-will-close")
        disableAnnotationEditing(reason: "window-will-close")
        let externalDragCloseReason = closeReason?.rawValue ?? "window-without-explicit-reason"
        let forcesExternalDragCancellation = closeReason == .applicationTermination
        let externalDragDelegates = promiseDelegates
        for promiseDelegate in externalDragDelegates {
            promiseDelegate.sourceWillClose(
                reason: externalDragCloseReason,
                force: forcesExternalDragCancellation
            )
        }
        removeKeyboardMonitor()
        activeSavePanel?.cancel(nil)
        activeSavePanel = nil
        toolbarPanel.orderOut(nil)
        if !copiedOrSaved {
            payload.releaseCache()
        }
        if closeReason == nil {
            AppLog.capture.error(
                "Current screenshot closed without an explicit lifecycle reason: id=\(self.identifier.uuidString, privacy: .public)"
            )
        }
        onClose?(identifier)
    }

    private func installKeyboardMonitor() {
        precondition(keyboardMonitor == nil, "A pinned screenshot may install only one keyboard monitor.")
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.ownsKeyboardEvent(event) else { return event }
            if self.regionDraftTransitionInProgress { return nil }

            let dismissalModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if self.exportInProgress {
                if event.keyCode == 12, dismissalModifiers == .command {
                    return event
                }
                if event.keyCode == 53, dismissalModifiers.isEmpty {
                    self.handleEscape()
                } else if Self.isScreenshotCopyShortcut(event) {
                    AppLog.export.notice("Ignored duplicate screenshot copy shortcut while output was in progress")
                    NSSound.beep()
                }
                return nil
            }
            if event.keyCode == 53, dismissalModifiers.isEmpty {
                if self.imageView.isTextEditing
                    || self.toolbarPanel.firstResponder is NSTextView
                {
                    return event
                }
                self.handleEscape()
                return nil
            }

            guard !self.imageView.isTextEditing,
                  !(self.toolbarPanel.firstResponder is NSTextView)
            else { return event }

            if Self.isScreenshotCopyShortcut(event) {
                self.requestCopy(source: .keyboard)
                return nil
            }

            guard self.presentationMode.showsToolbar else { return event }

            if self.presentationMode.isRegionDraft,
               (event.keyCode == 36 || event.keyCode == 76),
               dismissalModifiers.isEmpty
            {
                self.pinRegionDraft()
                return nil
            }

            let shortcut = Self.shortcut(for: event)
            guard let tool = self.settingsStore.settings.shortcuts.annotationTool(matching: shortcut) else {
                return event
            }
            self.selectAnnotationTool(tool, reason: "keyboard-tool-selection")
            AppLog.capture.notice(
                "Pinned annotation tool selected by shortcut: tool=\(tool.rawValue, privacy: .public), shortcut=\(shortcut.displayString, privacy: .public)"
            )
            return nil
        }) else {
            preconditionFailure("The current screenshot could not install its keyboard monitor.")
        }
        keyboardMonitor = monitor
    }

    private func ownsKeyboardEvent(_ event: NSEvent) -> Bool {
        var candidate = event.window ?? NSApplication.shared.keyWindow
        while let window = candidate {
            if window === imagePanel || window === toolbarPanel {
                return true
            }
            candidate = window.parent
        }
        return false
    }

    private func removeKeyboardMonitor() {
        guard let keyboardMonitor else { return }
        NSEvent.removeMonitor(keyboardMonitor)
        self.keyboardMonitor = nil
    }

    private static func shortcut(for event: NSEvent) -> HotKeyShortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: HotKeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    private static func isScreenshotCopyShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return event.keyCode == 8 && modifiers == .command
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let promiseDelegate = promiseDelegates.first(where: { $0.owns(session) }) else {
            AppLog.export.fault(
                "External drag ended without its file-promise lifecycle owner: id=\(self.identifier.uuidString, privacy: .public), operation=\(operation.rawValue, privacy: .public)"
            )
            return
        }
        promiseDelegate.draggingSessionDidEnd(operation: operation)
    }

    private func configurePanels(initialSize: CGSize) {
        imagePanel.delegate = self
        imagePanel.setAccessibilityIdentifier(
            presentationMode.isRegionDraft ? "capture.region.annotationSurface" : "pinned.image"
        )
        imagePanel.inputRole = presentationMode.isRegionDraft ? "region-confirmation" : "pinned-image"
        imagePanel.level = presentationMode.isRegionDraft
            ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            : .floating
        imagePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        imagePanel.animationBehavior = .none
        imagePanel.hidesOnDeactivate = false
        imagePanel.isReleasedWhenClosed = false
        imagePanel.hasShadow = !presentationMode.isRegionDraft
        imagePanel.backgroundColor = .clear
        imagePanel.isOpaque = false
        if presentationMode.isRegionDraft {
            let selectionSize = capturedImage.sourceMetadata.desktopFrame.standardized.size
            let panelSize = RegionDraftChromeView.panelSize(for: selectionSize)
            imageView.syncPresentationContentCornerRadius(for: selectionSize)
            let containerView = RegionDraftContainerView(frame: NSRect(
                origin: .zero,
                size: panelSize
            ))
            containerView.wantsLayer = true
            containerView.layer?.backgroundColor = NSColor.clear.cgColor
            imagePanel.contentView = containerView
            imageView.frame = CGRect(
                x: RegionDraftChromeView.panelOutset,
                y: RegionDraftChromeView.panelOutset,
                width: selectionSize.width,
                height: selectionSize.height
            )
            imageView.autoresizingMask = []
            containerView.addSubview(imageView)
            let chromeView = RegionDraftChromeView(frame: containerView.bounds)
            chromeView.autoresizingMask = [.width, .height]
            chromeView.configuredCornerRadius =
                session.configuredRegionCornerRadius ?? RegionCaptureCornerRadius.defaultLogicalPoints
            chromeView.onResizeBegan = { [weak self] handle, point in
                guard let self else { return }
                _ = self.imageView.endTextEditingIfNeeded(reason: .externalAction)
                self.onRegionDraftResizeBegan?(handle, point)
            }
            chromeView.onResizeChanged = { [weak self] point in
                self?.onRegionDraftResizeChanged?(point)
            }
            chromeView.onResizeEnded = { [weak self] point in
                self?.onRegionDraftResizeEnded?(point)
            }
            containerView.addSubview(chromeView)
            containerView.configureHitRouting(
                annotationView: imageView,
                chromeView: chromeView
            )
            containerView.synchronizeSelectionSize(selectionSize)
            AppLog.capture.notice(
                "Configured region confirmation input routing: canvasFrame=\(self.imageView.frame.debugDescription, privacy: .public), chromeFrame=\(chromeView.frame.debugDescription, privacy: .public), interior=canvas, handles=chrome"
            )
            regionDraftContainerView = containerView
            regionDraftChromeView = chromeView
        } else {
            imagePanel.contentAspectRatio = capturedImage.logicalSize
            imagePanel.minSize = Self.minimumWindowSize(for: capturedImage.logicalSize)
            imagePanel.contentView = imageView
            imageView.frame = NSRect(origin: .zero, size: initialSize)
            imageView.autoresizingMask = [.width, .height]
        }
        imageView.onWindowDragBegan = { [weak self] event in
            guard let self else { return }
            precondition(
                event.type == .leftMouseDown,
                "A screenshot-canvas move must begin with the original left-mouse-down event."
            )
            if self.presentationMode.isRegionDraft {
                self.imageView.setWindowDragInProgress(true)
                self.onRegionDraftMoveBegan?(NSEvent.mouseLocation)
                AppLog.capture.notice(
                    "Region confirmation canvas press began: id=\(self.identifier.uuidString, privacy: .public), cursor=closed-hand"
                )
                return
            }
            precondition(
                self.windowMoveInteraction == nil,
                "A pinned screenshot cannot begin a second window move before pointer-up."
            )
            guard self.admitUpdateSensitiveAction("move-window") else { return }
            let panelOrigin = self.imagePanel.frame.origin
            self.windowMoveInteraction = WindowMoveInteraction(
                startedAt: ProcessInfo.processInfo.systemUptime,
                pointerOrigin: NSEvent.mouseLocation,
                panelOrigin: panelOrigin
            )
            self.imageView.setWindowDragInProgress(true)
            AppLog.capture.notice(
                "Pinned screenshot press began app-controlled move: id=\(self.identifier.uuidString, privacy: .public), panelX=\(panelOrigin.x, privacy: .public), panelY=\(panelOrigin.y, privacy: .public), cursor=closed-hand"
            )
        }
        imageView.onWindowDragChanged = { [weak self] _ in
            guard let self else { return }
            if self.presentationMode.isRegionDraft {
                self.onRegionDraftMoveChanged?(NSEvent.mouseLocation)
                NSCursor.closedHand.set()
                return
            }
            guard let interaction = self.windowMoveInteraction else {
                preconditionFailure("A pinned-window drag update requires an active mouse-down interaction.")
            }
            let pointer = NSEvent.mouseLocation
            let updatedOrigin = CGPoint(
                x: interaction.panelOrigin.x + pointer.x - interaction.pointerOrigin.x,
                y: interaction.panelOrigin.y + pointer.y - interaction.pointerOrigin.y
            )
            self.imagePanel.setFrameOrigin(updatedOrigin)
            NSCursor.closedHand.set()
        }
        imageView.onWindowDragEnded = { [weak self] in
            guard let self else { return }
            if self.presentationMode.isRegionDraft {
                self.onRegionDraftMoveEnded?(NSEvent.mouseLocation)
                AppLog.capture.notice(
                    "Region confirmation canvas move ended: id=\(self.identifier.uuidString, privacy: .public)"
                )
                return
            }
            guard let interaction = self.windowMoveInteraction else { return }
            self.windowMoveInteraction = nil
            let finalOrigin = self.imagePanel.frame.origin
            AppLog.capture.notice(
                "Pinned screenshot app-controlled move ended: id=\(self.identifier.uuidString, privacy: .public), deltaX=\(finalOrigin.x - interaction.panelOrigin.x, privacy: .public), deltaY=\(finalOrigin.y - interaction.panelOrigin.y, privacy: .public), durationMs=\((ProcessInfo.processInfo.systemUptime - interaction.startedAt) * 1_000, privacy: .public)"
            )
        }
        imageView.onExternalDrag = { [weak self] event in
            self?.beginExternalDrag(event: event)
        }
        imageView.onEditingContextWillChange = { [weak self] reason in
            self?.resolveActiveLineWidthEdit(.commitOrReject, reason: reason)
        }
        imageView.onCopyFinalImage = { [weak self] in
            self?.requestCopy(source: .keyboard)
        }
        imageView.onPreviewChange = { [weak self] captured in
            guard let self else { return }
            self.payload.update(capturedImage: captured)
            if !self.presentationMode.isRegionDraft {
                self.imagePanel.contentAspectRatio = captured.logicalSize
            }
        }
        imagePanel.onEscape = { [weak self] in self?.handleEscape() }
        imagePanel.shouldAcceptLeftMouseDown = { [weak self] in
            self?.admitPinnedPointerInput(action: "left-mouse-down") ?? false
        }
        session.onError = { [weak self] error in
            guard let self else { return }
            if self.closeReason != nil {
                AppLog.export.debug("Ignored annotation-session error after screenshot close began")
                return
            }
            if self.exportInProgress || self.regionDraftTransitionInProgress {
                AppLog.export.debug(
                    "Deferred annotation-session error to the active screenshot action: export=\(self.exportInProgress, privacy: .public), pin=\(self.regionDraftTransitionInProgress, privacy: .public)"
                )
                return
            }
            self.onError?(error)
        }

        toolbarPanel.level = presentationMode.isRegionDraft
            ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
            : .floating
        toolbarPanel.setAccessibilityIdentifier(
            presentationMode.isRegionDraft ? "capture.region.toolbar" : "pinned.toolbar.window"
        )
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        toolbarPanel.animationBehavior = .none
        toolbarPanel.hidesOnDeactivate = false
        toolbarPanel.isReleasedWhenClosed = false
        toolbarPanel.hasShadow = true
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.isOpaque = false
        toolbarPanel.contentViewController = toolbarController
        let toolbarFittingSize = toolbarController.view.fittingSize
        precondition(
            toolbarFittingSize.width.isFinite && toolbarFittingSize.width > 0,
            "Pinned toolbar must resolve a non-empty intrinsic width."
        )
        toolbarPanel.setContentSize(CGSize(
            width: ceil(toolbarFittingSize.width),
            height: max(44, ceil(toolbarFittingSize.height))
        ))
        toolbarPanel.onEscape = { [weak self] in self?.handleEscape() }
        if presentationMode.showsToolbar && !presentationMode.isRegionDraft {
            imagePanel.addChildWindow(toolbarPanel, ordered: .above)
        }
        if !presentationMode.isRegionDraft {
            configurePinnedContextMenu()
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === imagePanel else { return }
        liveResizeInProgress = true
        guard admitPinnedPointerInput(action: "live-resize") else {
            AppLog.updates.fault(
                "AppKit began a pinned live resize after update ownership rejected its pointer input: id=\(self.identifier.uuidString, privacy: .public)"
            )
            return
        }
        AppLog.capture.debug(
            "Pinned screenshot live resize began: id=\(self.identifier.uuidString, privacy: .public)"
        )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === imagePanel else { return }
        liveResizeInProgress = false
        AppLog.capture.debug(
            "Pinned screenshot live resize ended: id=\(self.identifier.uuidString, privacy: .public)"
        )
    }

    private func wireActions() {
        toolbarController.onCopy = { [weak self] in
            self?.requestCopy(source: .toolbar)
        }
        toolbarController.onSave = { [weak self] in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "save")
            self.imageView.endTextEditingIfNeeded(reason: .externalAction)
            self.saveImage()
        }
        toolbarController.onRestoreSize = { [weak self] in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "restore-size")
            self.restoreOriginalSize()
        }
        toolbarController.onOpacityChange = { [weak self] value in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "opacity-change")
            self.imagePanel.alphaValue = value
        }
        toolbarController.onToggleClickThrough = { [weak self] enabled in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "click-through-change")
            self.imagePanel.ignoresMouseEvents = enabled
        }
        toolbarController.onToggleHidden = { [weak self] in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "temporary-visibility-change")
            self.toggleImageVisibility()
        }
        toolbarController.onOpenEditor = { [weak self] in
            guard let self else { return }
            guard let onOpenEditor = self.onOpenEditor else {
                preconditionFailure("The pinned toolbar requires a canvas-editor presentation handler.")
            }
            onOpenEditor(self.session)
        }
        toolbarController.onPin = { [weak self] in self?.pinRegionDraft() }
        toolbarController.onClose = { [weak self] in
            guard let self else { return }
            if self.presentationMode.isRegionDraft {
                self.cancelRegionDraft()
            } else {
                self.close(reason: .toolbar)
            }
        }
        toolbarController.onSelectTool = { [weak self] tool in
            guard let self else { return }
            self.selectAnnotationTool(tool, reason: "toolbar-tool-selection")
            AppLog.capture.notice("Pinned annotation tool selected: \(tool.rawValue, privacy: .public)")
        }
        toolbarController.onUndo = { [weak self] in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "undo")
            self.session.controller.undo()
        }
        toolbarController.onRedo = { [weak self] in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "redo")
            self.session.controller.redo()
        }
        toolbarController.onColorChange = { [weak self] color in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "color-change")
            self.imageView.applyStrokeColor(color)
        }
        toolbarController.onLineWidthEditingBegan = { [weak self] in
            guard let self else { return }
            self.imageView.beginLineWidthEditing()
            self.syncLineWidthToolbar()
        }
        toolbarController.onLineWidthChange = { [weak self] width in
            guard let self else { return }
            self.imageView.applyLineWidth(width)
            self.syncLineWidthToolbar()
        }
        toolbarController.onLineWidthCommit = { [weak self] callbackWidth, unit in
            guard let self else { return }
            switch self.imageView.commitLineWidthEditing() {
            case .none:
                return
            case .toolDefault(_, let committedWidth):
                precondition(
                    abs(committedWidth - callbackWidth) < 0.0001,
                    "The toolbar and canvas must commit the same tool-default line width."
                )
                self.persistDefaultLineWidth(
                    logicalPoints: committedWidth,
                    unit: unit
                )
            case .selection(let itemCount, let committedWidth):
                precondition(
                    abs(committedWidth - callbackWidth) < 0.0001,
                    "The toolbar and canvas must commit the same selected line width."
                )
                AppLog.capture.notice(
                    "Kept selected annotation line-width edit local to document: items=\(itemCount, privacy: .public), logicalPoints=\(committedWidth, privacy: .public), unit=\(unit.rawValue, privacy: .public)"
                )
            }
            self.syncLineWidthToolbar()
        }
        toolbarController.onLineWidthCancel = { [weak self] in
            guard let self else { return }
            self.imageView.cancelLineWidthEditing(reason: "invalid-input-or-lifecycle")
            self.syncLineWidthToolbar()
        }
        toolbarController.onLineWidthUnitChange = { [weak self] unit in
            guard let self else { return }
            self.session.lineWidthUnit = unit
            self.persistDefaultLineWidthUnit(unit)
            AppLog.capture.notice("Pinned annotation line-width unit selected: \(unit.rawValue, privacy: .public)")
        }
        toolbarController.onShapeFillModeChange = { [weak self] fillMode in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "shape-fill-change")
            self.imageView.applyShapeFillMode(fillMode)
            AppLog.capture.notice("Pinned shape fill mode selected: \(fillMode.rawValue, privacy: .public)")
        }
        toolbarController.onArrowStyleChange = { [weak self] arrowStyle in
            guard let self else { return }
            self.resolveActiveLineWidthEdit(.commitOrReject, reason: "arrow-style-change")
            self.imageView.applyArrowHeadStyle(arrowStyle)
            AppLog.capture.notice("Pinned arrow style selected: \(arrowStyle.rawValue, privacy: .public)")
        }

        session.$currentTool
            .sink { [weak self] tool in
                guard let self else { return }
                guard !self.canvasEditorPresented else { return }
                self.toolbarController.setSelectedTool(tool)
                self.syncLineWidthToolbar(currentTool: tool)
            }
            .store(in: &cancellables)
        session.$currentStyle
            .sink { [weak self] style in
                guard let self else { return }
                guard !self.isApplyingEditorSettings else { return }
                guard !self.canvasEditorPresented else { return }
                let allowsHistoricalColor = self.session.currentStyleOrigin == .existingAnnotation
                    && !self.session.controller.selectedItemIDs.isEmpty
                self.toolbarController.setAnnotationStyle(
                    style,
                    allowsHistoricalColor: allowsHistoricalColor
                )
            }
            .store(in: &cancellables)
        session.$lineWidthUnit
            .sink { [weak self] unit in
                guard let self, !self.canvasEditorPresented else { return }
                self.toolbarController.setLineWidthUnit(unit)
            }
            .store(in: &cancellables)
        settingsStore.$settings
            .map { $0.shortcuts.annotationToolAssignments }
            .removeDuplicates()
            .sink { [weak self] shortcuts in self?.toolbarController.setToolShortcuts(shortcuts) }
            .store(in: &cancellables)
        settingsStore.$settings
            .map(\.editor)
            .removeDuplicates()
            .sink { [weak self] editor in self?.applyEditorColorSettings(editor) }
            .store(in: &cancellables)
        session.controller.documentPublisher
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !self.canvasEditorPresented else { return }
                    self.toolbarController.setUndoState(
                        canUndo: self.session.controller.canUndo,
                        canRedo: self.session.controller.canRedo
                    )
                }
            }
            .store(in: &cancellables)
        session.controller.statePublisher
            .sink { [weak self] state in
                guard let self, !self.canvasEditorPresented else { return }
                self.syncLineWidthToolbar(state: state)
            }
            .store(in: &cancellables)
    }

    private func synchronizePinnedToolbarAfterCanvasEditor() {
        precondition(
            !canvasEditorPresented,
            "The pinned toolbar may only reconcile after canvas-editor ownership is released."
        )
        toolbarController.setSelectedTool(session.currentTool)
        toolbarController.setLineWidthUnit(session.lineWidthUnit)
        applyEditorColorSettings(settingsStore.settings.editor)
        toolbarController.setUndoState(
            canUndo: session.controller.canUndo,
            canRedo: session.controller.canRedo
        )
        syncLineWidthToolbar(
            state: session.controller.state,
            currentTool: session.currentTool
        )
        AppLog.capture.notice(
            "Reconciled pinned toolbar after exclusive canvas-editor ownership: id=\(self.identifier.uuidString, privacy: .public), paletteCount=\(self.settingsStore.settings.editor.availableColorHexes.count, privacy: .public), tool=\(self.session.currentTool.rawValue, privacy: .public)"
        )
    }

    private func syncLineWidthToolbar(
        state: AnnotationDocumentController.State? = nil,
        currentTool: AnnotationTool? = nil
    ) {
        let presentation = imageView.lineWidthControlPresentation(
            document: state?.document,
            selectedItemIDs: state?.selectedItemIDs,
            currentTool: currentTool
        )
        toolbarController.setLineWidthPresentation(
            logicalPoints: presentation.logicalLineWidth,
            isEnabled: presentation.isEnabled
        )
    }

    private func selectAnnotationTool(_ tool: AnnotationTool, reason: String) {
        resolveActiveLineWidthEdit(.commitOrReject, reason: reason)
        session.currentTool = tool
    }

    private func resolveActiveLineWidthEdit(
        _ disposition: LineWidthEditDisposition,
        reason: String
    ) {
        let hadActiveEdit = toolbarController.hasActiveLineWidthEditing
            || imageView.hasActiveLineWidthEditing
            || toolbarController.hasAttachedLineWidthFieldEditor
        switch disposition {
        case .commitOrReject:
            toolbarController.commitActiveLineWidthEditingForBoundary(reason: reason)
        case .cancel:
            toolbarController.cancelActiveLineWidthEditingForLifecycle(reason: reason)
        }
        precondition(
            !toolbarController.hasActiveLineWidthEditing
                && !toolbarController.hasAttachedLineWidthFieldEditor
                && !imageView.hasActiveLineWidthEditing,
            "A line-width context boundary must leave the toolbar, native field editor, and canvas idle."
        )
        if hadActiveEdit {
            AppLog.capture.notice(
                "Resolved annotation line-width context boundary: disposition=\(disposition.rawValue, privacy: .public), reason=\(reason, privacy: .public), tool=\(self.session.currentTool.rawValue, privacy: .public)"
            )
        }
    }

    private func applyEditorColorSettings(_ editor: EditorSettings) {
        guard !canvasEditorPresented else {
            AppLog.capture.debug(
                "Deferred editor-settings reconciliation to the exclusive canvas editor"
            )
            return
        }
        precondition(
            !isApplyingEditorSettings,
            "Editor settings cannot be applied recursively to one annotation session."
        )
        isApplyingEditorSettings = true
        defer { isApplyingEditorSettings = false }

        imageView.applyEditorSettings(editor)
        let palette = editor.availableColorHexes
        let allowsHistoricalColor = session.currentStyleOrigin == .existingAnnotation
            && !session.controller.selectedItemIDs.isEmpty
        toolbarController.setColorConfiguration(
            palette: palette,
            style: session.currentStyle,
            allowsHistoricalColor: allowsHistoricalColor
        )
    }

    private func persistDefaultLineWidth(
        logicalPoints: CGFloat,
        unit: AnnotationLineWidthUnit
    ) {
        let displayedValue = unit.displayedValue(
            forLogicalPoints: logicalPoints,
            backingScale: capturedImage.scale
        )
        do {
            try settingsStore.update { settings in
                settings.editor.defaultLineWidth = Double(displayedValue)
                settings.editor.defaultLineWidthUnit = unit
            }
            AppLog.capture.notice(
                "Persisted annotation line-width default: displayed=\(displayedValue, privacy: .public), unit=\(unit.rawValue, privacy: .public), logicalPoints=\(logicalPoints, privacy: .public), scale=\(self.capturedImage.scale, privacy: .public)"
            )
        } catch {
            AppLog.capture.error(
                "Failed to persist annotation line-width default: \(error.localizedDescription, privacy: .public)"
            )
            onError?(error)
        }
    }

    private func persistDefaultLineWidthUnit(_ unit: AnnotationLineWidthUnit) {
        let previousValue = settingsStore.settings.editor.defaultLineWidth
        let previousUnit = settingsStore.settings.editor.defaultLineWidthUnit
        guard previousUnit != unit else { return }
        do {
            try settingsStore.update { settings in
                settings.editor.setDefaultLineWidthUnit(
                    unit,
                    backingScale: capturedImage.scale
                )
            }
            AppLog.capture.notice(
                "Persisted annotation line-width display unit without replacing its default: fromValue=\(previousValue, privacy: .public), fromUnit=\(previousUnit.rawValue, privacy: .public), toValue=\(self.settingsStore.settings.editor.defaultLineWidth, privacy: .public), toUnit=\(unit.rawValue, privacy: .public), scale=\(self.capturedImage.scale, privacy: .public)"
            )
        } catch {
            AppLog.capture.error(
                "Failed to persist annotation line-width unit: \(error.localizedDescription, privacy: .public)"
            )
            onError?(error)
        }
    }

    private func handleEscape() {
        if imageView.endTextEditingIfNeeded(reason: .escape) {
            AppLog.capture.notice(
                "Escape ended inline text editing without closing the screenshot: id=\(self.identifier.uuidString, privacy: .public)"
            )
            return
        }
        if presentationMode.isRegionDraft {
            cancelRegionDraft()
        } else {
            close(reason: .escape)
        }
    }

    func pinRegionDraft() {
        guard presentationMode.isRegionDraft else {
            preconditionFailure("The Pin action is only valid while presenting a region draft.")
        }
        guard !regionDraftTransitionInProgress else { return }
        guard !exportInProgress else {
            AppLog.capture.notice("Ignored Pin while a region output action was still running")
            NSSound.beep()
            return
        }
        guard !regionDraftGeometryUpdateInProgress else {
            AppLog.capture.notice("Ignored Pin while region geometry was still being committed")
            NSSound.beep()
            return
        }
        disableAnnotationEditing(reason: "region-pin")
        regionDraftTransitionInProgress = true
        regionDraftImageIgnoredMouseEvents = imagePanel.ignoresMouseEvents
        imagePanel.ignoresMouseEvents = true
        toolbarPanel.ignoresMouseEvents = true
        toolbarController.setRegionDraftTransitioning(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let currentImage = try await self.session.resolvedPreviewImage()
                self.payload.update(capturedImage: currentImage)
                let pinnedFrame = self.capturedImage.sourceMetadata.desktopFrame.standardized
                self.retainsAfterCopy = true
                self.presentationMode = .pinned(showsToolbar: false)
                self.imagePanel.styleMask.insert(.resizable)
                self.transitionRegionDraftSurfaceToPinned(
                    frame: pinnedFrame,
                    logicalSize: currentImage.logicalSize
                )
                self.imagePanel.level = .floating
                self.imagePanel.setAccessibilityIdentifier("pinned.image")
                self.imagePanel.inputRole = "pinned-image"
                self.imagePanel.setAccessibilityValue(
                    "surfaceInput=enabled; inputOwner=pinned-canvas"
                )
                self.imageView.setDrawsBaseImage(true)
                self.imageView.syncPresentationContentCornerRadius(
                    for: currentImage.logicalSize
                )
                self.imagePanel.hasShadow = true
                self.toolbarPanel.orderOut(nil)
                self.toolbarPanel.setAccessibilityIdentifier("pinned.toolbar.window")
                self.toolbarPanel.level = .floating
                self.toolbarController.setRegionActionsVisible(false)
                self.resizeToolbarPanelToFittingSize()
                self.configurePinnedContextMenu()
                self.imagePanel.ignoresMouseEvents = self.regionDraftImageIgnoredMouseEvents
                self.toolbarPanel.ignoresMouseEvents = false
                self.regionDraftTransitionInProgress = false
                self.toolbarController.setRegionDraftTransitioning(false)
                AppLog.capture.notice(
                    "Region draft transitioned to pinned screenshot: id=\(self.identifier.uuidString, privacy: .public), annotations=\(self.session.controller.document.annotations.count, privacy: .public), toolbarVisible=false, annotationEditing=false"
                )
                self.onRegionDraftPinned?(self.identifier)
            } catch {
                self.imageView.setAnnotationEditingEnabled(true)
                self.imagePanel.ignoresMouseEvents = self.regionDraftImageIgnoredMouseEvents
                self.toolbarPanel.ignoresMouseEvents = false
                self.regionDraftTransitionInProgress = false
                self.toolbarController.setRegionDraftTransitioning(false)
                AppLog.capture.error(
                    "Region draft could not resolve its latest render before Pin: id=\(self.identifier.uuidString, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
                )
                self.onError?(error)
            }
        }
    }

    private func transitionRegionDraftSurfaceToPinned(
        frame: CGRect,
        logicalSize: CGSize
    ) {
        guard regionDraftContainerView != nil, let regionDraftChromeView else {
            preconditionFailure("Pin requires the active region confirmation container and chrome.")
        }
        precondition(
            frame.width > 0 && frame.height > 0,
            "A pinned region must retain a non-empty desktop frame."
        )
        regionDraftChromeView.removeFromSuperview()
        imageView.removeFromSuperview()
        imageView.translatesAutoresizingMaskIntoConstraints = true
        imageView.autoresizingMask = [.width, .height]
        imagePanel.contentView = imageView
        imagePanel.contentAspectRatio = logicalSize
        imagePanel.minSize = Self.minimumWindowSize(for: logicalSize)
        imagePanel.setFrame(frame, display: true, animate: false)
        imageView.frame = imagePanel.contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        imageView.refreshWindowInteractionState()
        self.regionDraftChromeView = nil
        self.regionDraftContainerView = nil
        AppLog.capture.notice(
            "Region confirmation chrome removed for Pin: borderAligned=true, panelOutset=\(RegionDraftChromeView.panelOutset, privacy: .public), pinnedFrame=\(frame.debugDescription, privacy: .public)"
        )
    }

    func cancelRegionDraft() {
        guard presentationMode.isRegionDraft else {
            preconditionFailure("Only a region draft may use the region-selection cancellation path.")
        }
        guard !regionDraftTransitionInProgress else { return }
        cancelActiveExport(reason: "region-selection-cancel")
        resolveActiveLineWidthEdit(.cancel, reason: "region-selection-cancel")
        AppLog.capture.notice(
            "Region draft cancelled before Pin: id=\(self.identifier.uuidString, privacy: .public), annotations=\(self.session.controller.document.annotations.count, privacy: .public)"
        )
        onRegionDraftCancelled?(identifier)
        close(reason: .regionSelectionCancelled)
    }

    func previewRegionDraftFrame(
        _ frame: CGRect,
        change: RegionDraftGeometryChange
    ) {
        guard presentationMode.isRegionDraft else {
            preconditionFailure("Only a region draft may preview selection geometry.")
        }
        let standardized = frame.standardized
        precondition(
            standardized.width >= 2 && standardized.height >= 2,
            "A region draft preview frame must remain non-empty."
        )
        imagePanel.setFrame(
            RegionDraftChromeView.panelFrame(forSelectionFrame: standardized),
            display: false,
            animate: false
        )
        guard let regionDraftContainerView else {
            preconditionFailure("A region draft preview requires its active container view.")
        }
        regionDraftContainerView.synchronizeSelectionSize(standardized.size)
        imageView.previewRegionDraftFrame(
            sourceDesktopFrame: capturedImage.sourceMetadata.desktopFrame,
            previewDesktopFrame: standardized,
            change: change
        )
        imagePanel.displayIfNeeded()
        repositionToolbar()
    }

    func setRegionDraftGeometryUpdating(_ updating: Bool) {
        guard presentationMode.isRegionDraft else {
            preconditionFailure("Only a region draft may update selection geometry.")
        }
        guard regionDraftGeometryUpdateInProgress != updating else { return }
        if updating {
            resolveActiveLineWidthEdit(.commitOrReject, reason: "region-geometry-change")
        }
        regionDraftGeometryUpdateInProgress = updating
        regionDraftChromeView?.isResizeEnabled = !updating
        toolbarController.setRegionDraftTransitioning(updating)
        if updating {
            _ = imageView.endTextEditingIfNeeded(reason: .externalAction)
            regionDraftGeometryImageIgnoredMouseEvents = imagePanel.ignoresMouseEvents
            imagePanel.ignoresMouseEvents = true
        } else {
            imagePanel.ignoresMouseEvents = regionDraftGeometryImageIgnoredMouseEvents
        }
        AppLog.capture.debug(
            "Region draft geometry transaction changed: updating=\(updating, privacy: .public), selectionFrame=\(self.regionToolbarAnchorFrame.debugDescription, privacy: .public), panelFrame=\(self.imagePanel.frame.debugDescription, privacy: .public)"
        )
    }

    func updateRegionDraft(
        _ updatedImage: CapturedImage,
        change: RegionDraftGeometryChange
    ) {
        guard presentationMode.isRegionDraft, regionDraftGeometryUpdateInProgress else {
            preconditionFailure("A region draft recrop must occur inside a geometry update transaction.")
        }
        let oldFrame = capturedImage.sourceMetadata.desktopFrame.standardized
        let newFrame = updatedImage.sourceMetadata.desktopFrame.standardized
        precondition(
            newFrame.width >= 2 && newFrame.height >= 2,
            "A recropped region draft must retain a non-empty desktop frame."
        )
        let translation: CGSize
        switch change {
        case .resizePreservingDesktopAnchors:
            translation = CGSize(
                width: oldFrame.minX - newFrame.minX,
                height: oldFrame.minY - newFrame.minY
            )
        case .moveCanvas:
            translation = .zero
        }
        capturedImage = updatedImage
        imageView.finishRegionDraftFramePreview()
        session.replaceBaseImage(updatedImage, translatingDocumentBy: translation)
        payload.update(capturedImage: updatedImage)
        toolbarController.setBackingScale(updatedImage.scale)
        imagePanel.setFrame(
            RegionDraftChromeView.panelFrame(forSelectionFrame: newFrame),
            display: true,
            animate: false
        )
        repositionToolbar()
        imageView.syncPresentationContentCornerRadius(for: newFrame.size)
        AppLog.capture.notice(
            "Updated editable region draft geometry: change=\(change.rawValue, privacy: .public), oldFrame=\(oldFrame.debugDescription, privacy: .public), newFrame=\(newFrame.debugDescription, privacy: .public), translation=\(translation.debugDescription, privacy: .public), pixels=\(updatedImage.image.width, privacy: .public)x\(updatedImage.image.height, privacy: .public), cornerRadius=\(self.session.controller.document.canvasEffects.cornerRadius, privacy: .public)"
        )
    }

    private func requestCopy(source: CopyRequestSource) {
        guard admitUpdateSensitiveAction("copy-\(source.rawValue)") else { return }
        resolveActiveLineWidthEdit(.commitOrReject, reason: "copy-\(source.rawValue)")
        imageView.endTextEditingIfNeeded(reason: .externalAction)
        let completionPolicy: CopyCompletionPolicy = source == .contextMenu || retainsAfterCopy
            ? .keepPresented
            : .dismissAfterSuccess
        AppLog.export.notice(
            "Requested composed screenshot copy: source=\(source.rawValue, privacy: .public), completion=\(completionPolicy.rawValue, privacy: .public), regionConfirmation=\(self.presentationMode.isRegionDraft, privacy: .public), explicitlyPinned=\(self.retainsAfterCopy, privacy: .public)"
        )
        copyImage(source: source, completionPolicy: completionPolicy)
    }

    private func copyImage(
        source: CopyRequestSource,
        completionPolicy: CopyCompletionPolicy
    ) {
        guard let transaction = beginExport(action: .copy) else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var successDisposition: CopySuccessDisposition?
            var failure: (error: Error, action: String)?
            defer {
                if self.finishExport(transaction: transaction) {
                    if let successDisposition {
                        switch successDisposition {
                        case .completeRegionSelection:
                            precondition(
                                self.presentationMode.isRegionDraft,
                                "Copy completion lost its active region confirmation state."
                            )
                            self.onRegionDraftCopied?(self.identifier)
                        case .closePresentedScreenshot:
                            self.close(reason: .copied)
                        case .keepPresented:
                            self.toolbarController.showConfirmation(symbol: "checkmark", help: "Copied")
                        }
                    } else if let failure {
                        self.reportOutputFailure(failure.error, action: failure.action)
                    }
                }
            }
            let currentImage: CapturedImage
            do {
                currentImage = try await self.session.resolvedPreviewImage()
                try Task.checkCancellation()
                guard self.validateActiveExport(transaction, stage: "copy-render-complete") else { return }
                precondition(
                    currentImage.sourceMetadata.desktopFrame.standardized == transaction.desktopFrame,
                    "Copy must resolve the same committed desktop frame that its output transaction locked."
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    AppLog.export.debug(
                        "Cancelled screenshot copy before pasteboard write: transaction=\(transaction.identifier.uuidString, privacy: .public)"
                    )
                    return
                }
                failure = (error, "Copy render")
                return
            }
            do {
                self.payload.update(capturedImage: currentImage)
                let pngData = try self.payload.pngData()
                let bitmap = NSBitmapImageRep(cgImage: currentImage.image)
                let item = NSPasteboardItem()
                item.setData(pngData, forType: .png)
                if let tiffData = bitmap.tiffRepresentation {
                    item.setData(tiffData, forType: .tiff)
                }
                try Task.checkCancellation()
                guard self.validateActiveExport(transaction, stage: "copy-pasteboard-write") else { return }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([item]) else {
                    throw ScreenshotAppError.exportFailed(description: "The pasteboard rejected the image data.")
                }
                self.copiedOrSaved = true
                if transaction.beganAsRegionDraft {
                    successDisposition = .completeRegionSelection
                } else if completionPolicy == .dismissAfterSuccess {
                    successDisposition = .closePresentedScreenshot
                } else {
                    successDisposition = .keepPresented
                }
                AppLog.export.notice(
                    "Copied composed screenshot output: transaction=\(transaction.identifier.uuidString, privacy: .public), source=\(source.rawValue, privacy: .public), completion=\(completionPolicy.rawValue, privacy: .public), regionConfirmation=\(transaction.beganAsRegionDraft, privacy: .public), closesPresentedScreenshot=\(successDisposition == .closePresentedScreenshot, privacy: .public), pixels=\(currentImage.image.width, privacy: .public)x\(currentImage.image.height, privacy: .public), logical=\(currentImage.logicalSize.width, privacy: .public)x\(currentImage.logicalSize.height, privacy: .public), scale=\(currentImage.scale, privacy: .public)x, annotations=\(self.session.controller.document.annotations.count, privacy: .public)"
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    AppLog.export.debug(
                        "Cancelled screenshot copy during output preparation: transaction=\(transaction.identifier.uuidString, privacy: .public)"
                    )
                    return
                }
                failure = (error, "Copy")
            }
        }
        activeExportTask = task
    }

    private func saveImage() {
        guard activeSavePanel == nil else { return }
        let savePanel = NSSavePanel()
        savePanel.setAccessibilityIdentifier("pinned.save.panel")
        savePanel.allowedContentTypes = [outputSettings.format.contentType]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = FilenameTemplateFormatter().filename(
            template: outputSettings.filenameTemplate,
            date: Date(),
            fileExtension: outputSettings.format.fileExtension
        )
        activeSavePanel = savePanel
        NSApplication.shared.activate(ignoringOtherApps: true)
        savePanel.begin { [weak self, weak savePanel] response in
            guard let self else { return }
            self.activeSavePanel = nil
            guard response == .OK, let url = savePanel?.url else { return }
            self.saveLatestImage(to: url)
        }
    }

    private func saveLatestImage(to url: URL) {
        guard let transaction = beginExport(action: .save) else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var completesRegionSelection = false
            var failure: (error: Error, action: String)?
            defer {
                if self.finishExport(transaction: transaction) {
                    if completesRegionSelection {
                        precondition(
                            self.presentationMode.isRegionDraft,
                            "Save completion lost its active region confirmation state."
                        )
                        self.onRegionDraftSaved?(self.identifier)
                    } else if let failure {
                        self.reportOutputFailure(failure.error, action: failure.action)
                    }
                }
            }
            let currentImage: CapturedImage
            do {
                currentImage = try await self.session.resolvedPreviewImage()
                try Task.checkCancellation()
                guard self.validateActiveExport(transaction, stage: "save-render-complete") else { return }
                precondition(
                    currentImage.sourceMetadata.desktopFrame.standardized == transaction.desktopFrame,
                    "Save must resolve the same committed desktop frame that its output transaction locked."
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    AppLog.export.debug(
                        "Cancelled screenshot save before file write: transaction=\(transaction.identifier.uuidString, privacy: .public)"
                    )
                    return
                }
                failure = (error, "Save render")
                return
            }
            do {
                try Task.checkCancellation()
                guard self.validateActiveExport(transaction, stage: "save-file-write") else { return }
                self.payload.update(capturedImage: currentImage)
                try self.payload.write(
                    to: url,
                    format: self.outputSettings.format,
                    preservesColorProfile: self.outputSettings.preservesColorProfile
                )
                self.copiedOrSaved = true
                completesRegionSelection = transaction.beganAsRegionDraft
                if !completesRegionSelection {
                    self.toolbarController.showConfirmation(symbol: "checkmark", help: "Saved")
                }
                AppLog.export.notice(
                    "Saved composed screenshot output to \(url.path, privacy: .private): transaction=\(transaction.identifier.uuidString, privacy: .public), regionConfirmation=\(completesRegionSelection, privacy: .public), pixels=\(currentImage.image.width, privacy: .public)x\(currentImage.image.height, privacy: .public), scale=\(currentImage.scale, privacy: .public)x, annotations=\(self.session.controller.document.annotations.count, privacy: .public)"
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    AppLog.export.debug(
                        "Cancelled screenshot save during output preparation: transaction=\(transaction.identifier.uuidString, privacy: .public)"
                    )
                    return
                }
                failure = (error, "Save")
            }
        }
        activeExportTask = task
    }

    private func reportOutputFailure(_ error: Error, action: String) {
        AppLog.export.error(
            "Screenshot output failed: action=\(action, privacy: .public), regionConfirmation=\(self.presentationMode.isRegionDraft, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
        )
        onError?(error)
    }

    private func beginExport(action: ExportAction) -> ExportTransaction? {
        guard activeExportTransaction == nil else {
            AppLog.export.notice(
                "Rejected overlapping screenshot output: requested=\(action.rawValue, privacy: .public), active=\(self.activeExportTransaction?.action.rawValue ?? "unknown", privacy: .public)"
            )
            NSSound.beep()
            return nil
        }
        guard !canvasEditorPresented else {
            AppLog.export.notice(
                "Rejected screenshot output while the full canvas editor owned the document: action=\(action.rawValue, privacy: .public)"
            )
            NSSound.beep()
            return nil
        }
        guard closeReason == nil else {
            AppLog.export.error(
                "Rejected screenshot output after close began: action=\(action.rawValue, privacy: .public), closeReason=\(self.closeReason?.rawValue ?? "unknown", privacy: .public)"
            )
            return nil
        }
        guard !regionDraftTransitionInProgress else {
            AppLog.export.notice(
                "Rejected screenshot output during region Pin transition: action=\(action.rawValue, privacy: .public)"
            )
            NSSound.beep()
            return nil
        }
        guard !regionDraftGeometryUpdateInProgress else {
            AppLog.export.notice(
                "Rejected screenshot output while region geometry was being recropped: action=\(action.rawValue, privacy: .public)"
            )
            NSSound.beep()
            return nil
        }
        guard NSEvent.pressedMouseButtons == 0 else {
            AppLog.export.notice(
                "Rejected screenshot output during an active pointer interaction: action=\(action.rawValue, privacy: .public), pressedButtons=\(NSEvent.pressedMouseButtons, privacy: .public)"
            )
            NSSound.beep()
            return nil
        }

        let transaction = ExportTransaction(
            identifier: UUID(),
            action: action,
            beganAsRegionDraft: presentationMode.isRegionDraft,
            desktopFrame: capturedImage.sourceMetadata.desktopFrame.standardized,
            imageIgnoredMouseEvents: imagePanel.ignoresMouseEvents,
            resizeWasEnabled: regionDraftChromeView?.isResizeEnabled
        )
        activeExportTransaction = transaction
        imagePanel.ignoresMouseEvents = true
        regionDraftChromeView?.isResizeEnabled = false
        toolbarController.setExporting(true)
        AppLog.export.notice(
            "Began screenshot output transaction: id=\(transaction.identifier.uuidString, privacy: .public), action=\(action.rawValue, privacy: .public), regionConfirmation=\(transaction.beganAsRegionDraft, privacy: .public), inputFrozen=true"
        )
        return transaction
    }

    @discardableResult
    private func finishExport(transaction: ExportTransaction) -> Bool {
        guard activeExportTransaction?.identifier == transaction.identifier else {
            AppLog.export.debug(
                "Ignored stale screenshot output completion: id=\(transaction.identifier.uuidString, privacy: .public), action=\(transaction.action.rawValue, privacy: .public)"
            )
            return false
        }
        activeExportTask = nil
        activeExportTransaction = nil
        restoreInput(after: transaction)
        AppLog.export.notice(
            "Finished screenshot output transaction: id=\(transaction.identifier.uuidString, privacy: .public), action=\(transaction.action.rawValue, privacy: .public), inputFrozen=false"
        )
        return true
    }

    private func cancelActiveExport(reason: String) {
        guard let transaction = activeExportTransaction else { return }
        activeExportTask?.cancel()
        activeExportTask = nil
        activeExportTransaction = nil
        restoreInput(after: transaction)
        AppLog.export.notice(
            "Cancelled screenshot output transaction: id=\(transaction.identifier.uuidString, privacy: .public), action=\(transaction.action.rawValue, privacy: .public), reason=\(reason, privacy: .public), staleCompletionBlocked=true"
        )
    }

    private func validateActiveExport(
        _ transaction: ExportTransaction,
        stage: String
    ) -> Bool {
        guard activeExportTransaction?.identifier == transaction.identifier else {
            AppLog.export.debug(
                "Rejected stale screenshot output stage: id=\(transaction.identifier.uuidString, privacy: .public), action=\(transaction.action.rawValue, privacy: .public), stage=\(stage, privacy: .public)"
            )
            return false
        }
        guard closeReason == nil,
              presentationMode.isRegionDraft == transaction.beganAsRegionDraft,
              capturedImage.sourceMetadata.desktopFrame.standardized == transaction.desktopFrame,
              !regionDraftGeometryUpdateInProgress
        else {
            AppLog.export.error(
                "Screenshot output ownership changed while active: id=\(transaction.identifier.uuidString, privacy: .public), action=\(transaction.action.rawValue, privacy: .public), stage=\(stage, privacy: .public), closeReason=\(self.closeReason?.rawValue ?? "none", privacy: .public), beganAsRegion=\(transaction.beganAsRegionDraft, privacy: .public), currentlyRegion=\(self.presentationMode.isRegionDraft, privacy: .public), expectedFrame=\(transaction.desktopFrame.debugDescription, privacy: .public), currentFrame=\(self.capturedImage.sourceMetadata.desktopFrame.standardized.debugDescription, privacy: .public), geometryUpdating=\(self.regionDraftGeometryUpdateInProgress, privacy: .public)"
            )
            return false
        }
        return true
    }

    private func restoreInput(after transaction: ExportTransaction) {
        imagePanel.ignoresMouseEvents = transaction.imageIgnoredMouseEvents
        if let resizeWasEnabled = transaction.resizeWasEnabled {
            regionDraftChromeView?.isResizeEnabled = resizeWasEnabled
        }
        toolbarController.setExporting(false)
    }

    private func restoreOriginalSize() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentImage: CapturedImage
            do {
                currentImage = try await self.session.resolvedPreviewImage()
            } catch {
                self.reportOutputFailure(error, action: "Restore original size")
                return
            }
            self.payload.update(capturedImage: currentImage)
            var target = currentImage.logicalSize
            if let visible = self.imagePanel.screen?.visibleFrame {
                let ratio = min(1, visible.width / target.width, visible.height / target.height)
                target = CGSize(width: target.width * ratio, height: target.height * ratio)
            }
            self.imagePanel.setContentSize(target)
            self.repositionToolbar()
        }
    }

    private func toggleImageVisibility() {
        imageIsHidden.toggle()
        imageView.isHidden = imageIsHidden
        imagePanel.hasShadow = !imageIsHidden
        toolbarController.setImageHidden(imageIsHidden)
    }

    private func configurePinnedContextMenu() {
        guard imageView.menu == nil else {
            updatePinnedContextMenuTitle()
            return
        }
        let menu = NSMenu(title: NSLocalizedString(
            "Pinned Screenshot",
            comment: "Pinned screenshot context-menu title"
        ))
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(
            title: NSLocalizedString(
                "Copy Screenshot",
                comment: "Pinned screenshot context-menu copy action"
            ),
            action: #selector(copyScreenshotFromContextMenu),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = true
        copyItem.setAccessibilityIdentifier("pinned.context.copy")
        menu.addItem(copyItem)

        let toolbarItem = NSMenuItem(
            title: "",
            action: #selector(toggleToolbarFromContextMenu),
            keyEquivalent: ""
        )
        toolbarItem.target = self
        toolbarItem.isEnabled = true
        toolbarItem.setAccessibilityIdentifier("pinned.context.toggleToolbar")
        toolbarContextMenuItem = toolbarItem
        menu.addItem(toolbarItem)
        imageView.menu = menu
        updatePinnedContextMenuTitle()
    }

    private func updatePinnedContextMenuTitle() {
        let toolbarVisible = presentationMode.showsToolbar
        toolbarContextMenuItem?.title = NSLocalizedString(
            toolbarVisible ? "Hide Toolbar" : "Show Toolbar",
            comment: "Pinned screenshot context-menu toolbar action"
        )
        toolbarContextMenuItem?.isEnabled = !canvasEditorPresented
    }

    @objc private func copyScreenshotFromContextMenu() {
        guard !presentationMode.isRegionDraft else {
            preconditionFailure("Region confirmation must use its visible Copy action.")
        }
        requestCopy(source: .contextMenu)
    }

    @objc private func toggleToolbarFromContextMenu() {
        guard !presentationMode.isRegionDraft else {
            preconditionFailure("Region confirmation cannot toggle the pinned toolbar.")
        }
        guard !canvasEditorPresented else {
            AppLog.capture.notice(
                "Rejected pinned-toolbar toggle while canvas editor owned the session: id=\(self.identifier.uuidString, privacy: .public)"
            )
            NSSound.beep()
            return
        }
        guard admitUpdateSensitiveAction("toggle-toolbar") else { return }
        setPinnedToolbarVisible(!presentationMode.showsToolbar, reason: "context-menu")
    }

    private func setPinnedToolbarVisible(
        _ visible: Bool,
        reason: String,
        preservesSharedEditorState: Bool = false
    ) {
        guard !presentationMode.isRegionDraft else {
            preconditionFailure("Only a pinned screenshot may toggle its editing toolbar.")
        }
        precondition(
            !visible || !canvasEditorPresented,
            "The pinned quick toolbar cannot become writable while the full canvas editor owns the session."
        )
        guard presentationMode.showsToolbar != visible else { return }
        presentationMode = .pinned(showsToolbar: visible)
        if visible {
            toolbarController.setRegionActionsVisible(false)
            resizeToolbarPanelToFittingSize()
            imageView.setAnnotationEditingEnabled(true)
            if toolbarPanel.parent == nil {
                imagePanel.addChildWindow(toolbarPanel, ordered: .above)
            }
            repositionToolbar()
            toolbarPanel.orderFrontRegardless()
        } else {
            if preservesSharedEditorState {
                suspendAnnotationEditingForCanvasEditor(reason: reason)
            } else {
                disableAnnotationEditing(reason: "pinned-toolbar-hidden")
            }
            toolbarPanel.orderOut(nil)
            if toolbarPanel.parent === imagePanel {
                imagePanel.removeChildWindow(toolbarPanel)
            }
        }
        updatePinnedContextMenuTitle()
        AppLog.capture.notice(
            "Pinned screenshot toolbar visibility changed: id=\(self.identifier.uuidString, privacy: .public), visible=\(visible, privacy: .public), annotationEditing=\(visible, privacy: .public), reason=\(reason, privacy: .public)"
        )
    }

    private func disableAnnotationEditing(reason: String) {
        resolveActiveLineWidthEdit(.cancel, reason: reason)
        imageView.setAnnotationEditingEnabled(false)
    }

    private func suspendAnnotationEditingForCanvasEditor(reason: String) {
        resolveActiveLineWidthEdit(.cancel, reason: reason)
        imageView.suspendAnnotationEditingForExternalOwner(reason: reason)
    }

    private func resizeToolbarPanelToFittingSize() {
        toolbarController.view.layoutSubtreeIfNeeded()
        let fittingSize = toolbarController.view.fittingSize
        precondition(
            fittingSize.width.isFinite && fittingSize.width > 0,
            "Pinned toolbar must retain a non-empty intrinsic width."
        )
        toolbarPanel.setContentSize(CGSize(
            width: ceil(fittingSize.width),
            height: max(44, ceil(fittingSize.height))
        ))
    }

    private func positionImagePanel() {
        if capturedImage.sourceMetadata.kind == .region {
            let captureFrame = capturedImage.sourceMetadata.desktopFrame.standardized
            precondition(
                captureFrame.width > 0 && captureFrame.height > 0,
                "A region capture must have a non-empty desktop frame."
            )
            let panelFrame = presentationMode.isRegionDraft
                ? RegionDraftChromeView.panelFrame(forSelectionFrame: captureFrame)
                : captureFrame
            imagePanel.setFrame(panelFrame, display: false, animate: false)
            AppLog.capture.notice(
                "Region surface anchored to capture frame: confirmation=\(self.presentationMode.isRegionDraft, privacy: .public), x=\(captureFrame.minX, privacy: .public), y=\(captureFrame.minY, privacy: .public), width=\(captureFrame.width, privacy: .public), height=\(captureFrame.height, privacy: .public), panelOutset=\(self.presentationMode.isRegionDraft ? RegionDraftChromeView.panelOutset : 0, privacy: .public)"
            )
            return
        }
        positionNearMouse()
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            imagePanel.center()
            return
        }
        var origin = CGPoint(x: mouse.x + 18, y: mouse.y - imagePanel.frame.height - 18)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - imagePanel.frame.width)
        origin.y = min(max(origin.y, visible.minY + 52), visible.maxY - imagePanel.frame.height)
        imagePanel.setFrameOrigin(origin)
    }

    private func repositionToolbar() {
        guard let screen = imagePanel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let toolbarSize = toolbarPanel.frame.size
        let layout = FloatingToolbarLayout(
            screenMargin: 8,
            imageSpacing: 8,
            reservedSpaceBelow: toolbarController.preferredStylePopoverSpaceBelow
        )
        let origin = layout.toolbarOrigin(
            imageFrame: regionToolbarAnchorFrame,
            toolbarSize: toolbarSize,
            visibleFrame: visible
        )
        toolbarPanel.setFrameOrigin(origin)
        AppLog.capture.debug(
            "Positioned pinned toolbar: x=\(origin.x, privacy: .public), y=\(origin.y, privacy: .public), screen=\(screen.localizedName, privacy: .public), reservedBelow=\(self.toolbarController.preferredStylePopoverSpaceBelow, privacy: .public)"
        )
    }

    private var regionToolbarAnchorFrame: CGRect {
        presentationMode.isRegionDraft
            ? RegionDraftChromeView.selectionFrame(fromPanelFrame: imagePanel.frame)
            : imagePanel.frame
    }

    private func beginExternalDrag(event: NSEvent) {
        guard admitUpdateSensitiveAction("external-drag") else { return }

        guard promiseDelegates.isEmpty else {
            let error = FilePromiseLifecycleError.concurrentDrag()
            AppLog.export.error(
                "Rejected overlapping external drag: id=\(self.identifier.uuidString, privacy: .public), activePromises=\(self.promiseDelegates.count, privacy: .public)"
            )
            NSSound.beep()
            onError?(error)
            return
        }

        let lifecycleID = UUID()
        let lease = updateSensitiveActivityTracker.begin(
            operation: "pinned-external-drag"
        )
        let promiseDelegate = FilePromiseDelegate(
            identifier: lifecycleID,
            payload: payload,
            filenameTemplate: outputSettings.filenameTemplate,
            updateSensitiveActivityTracker: updateSensitiveActivityTracker,
            lease: lease,
            onFinished: { [weak self] finishedID in
                guard let self else { return }
                guard let index = self.promiseDelegates.firstIndex(where: {
                    $0.identifier == finishedID
                }) else {
                    AppLog.export.fault(
                        "A file-promise lifecycle finished without controller ownership: lifecycle=\(finishedID.uuidString, privacy: .public)"
                    )
                    return
                }
                self.promiseDelegates.remove(at: index)
                AppLog.export.debug(
                    "Released external drag lifecycle ownership: lifecycle=\(finishedID.uuidString, privacy: .public), remaining=\(self.promiseDelegates.count, privacy: .public)"
                )
            }
        )
        promiseDelegate.armLifecycleRetention()
        promiseDelegates.append(promiseDelegate)
        AppLog.export.notice(
            "Began external drag lifecycle: id=\(self.identifier.uuidString, privacy: .public), lifecycle=\(lifecycleID.uuidString, privacy: .public)"
        )

        do {
            let item = NSPasteboardItem()
            item.setData(try payload.pngData(), forType: .png)
            if let tiffData = NSBitmapImageRep(cgImage: payload.currentImage().image).tiffRepresentation {
                item.setData(tiffData, forType: .tiff)
            }
            let imageDraggingItem = NSDraggingItem(pasteboardWriter: item)
            imageDraggingItem.setDraggingFrame(imageView.bounds, contents: imageView.draggingImage)

            let provider = NSFilePromiseProvider(
                fileType: UTType.png.identifier,
                delegate: promiseDelegate
            )
            let promiseItem = NSDraggingItem(pasteboardWriter: provider)
            promiseItem.setDraggingFrame(imageView.bounds, contents: imageView.draggingImage)
            let draggingSession = imageView.beginDraggingSession(
                with: [imageDraggingItem, promiseItem],
                event: event,
                source: self
            )
            promiseDelegate.bind(to: draggingSession)
        } catch {
            promiseDelegate.dragSetupDidFail(error)
            onError?(error)
        }
    }

    private func admitUpdateSensitiveAction(_ action: String) -> Bool {
        do {
            try admitAppWork()
            return true
        } catch {
            AppLog.updates.notice(
                "Rejected pinned screenshot action during an update transaction: action=\(action, privacy: .public), id=\(self.identifier.uuidString, privacy: .public)"
            )
            NSSound.beep()
            onError?(error)
            return false
        }
    }

    private func admitPinnedPointerInput(action: String) -> Bool {
        do {
            try admitAppWork()
            return true
        } catch {
            AppLog.updates.notice(
                "Rejected pinned screenshot pointer input during an update transaction: action=\(action, privacy: .public), id=\(self.identifier.uuidString, privacy: .public)"
            )
            NSSound.beep()
            return false
        }
    }

    private static func initialWindowSize(for image: CapturedImage) -> CGSize {
        let logical = image.logicalSize
        if image.sourceMetadata.kind == .region {
            return logical
        }
        let maximum = CGSize(width: 720, height: 520)
        let maximumRatio = min(maximum.width / logical.width, maximum.height / logical.height)
        let baseRatio = min(1, maximumRatio)
        let minimumUsableRatio = max(160 / logical.width, 100 / logical.height)
        let ratio = minimumUsableRatio <= maximumRatio
            ? max(baseRatio, minimumUsableRatio)
            : maximumRatio
        return CGSize(
            width: logical.width * ratio,
            height: logical.height * ratio
        )
    }

    private static func minimumWindowSize(for aspect: CGSize) -> CGSize {
        let maximum = CGSize(width: 480, height: 360)
        let maximumRatio = min(maximum.width / aspect.width, maximum.height / aspect.height)
        let minimumUsableRatio = max(160 / aspect.width, 80 / aspect.height)
        let ratio = min(minimumUsableRatio, maximumRatio)
        return CGSize(width: aspect.width * ratio, height: aspect.height * ratio)
    }
}

private final class RegionDraftContainerView: NSView {
    private weak var annotationView: NSView?
    private weak var chromeView: RegionDraftChromeView?

    func configureHitRouting(
        annotationView: NSView,
        chromeView: RegionDraftChromeView
    ) {
        precondition(
            annotationView.superview === self && chromeView.superview === self,
            "Region draft hit routing requires both views to belong to the container."
        )
        annotationView.translatesAutoresizingMaskIntoConstraints = true
        self.annotationView = annotationView
        self.chromeView = chromeView
        layoutSubtreeIfNeeded()
        precondition(
            annotationView.frame == bounds.insetBy(
                dx: RegionDraftChromeView.panelOutset,
                dy: RegionDraftChromeView.panelOutset
            ),
            "Region draft canvas must occupy the exact selected frame inside its chrome margin."
        )
    }

    func synchronizeSelectionSize(_ selectionSize: CGSize) {
        guard let annotationView, let chromeView else {
            preconditionFailure("Region draft geometry cannot update before hit routing is configured.")
        }
        precondition(
            selectionSize.width >= 2 && selectionSize.height >= 2,
            "Region draft geometry requires a non-empty selection size."
        )
        let panelSize = RegionDraftChromeView.panelSize(for: selectionSize)
        setFrameSize(panelSize)
        annotationView.frame = CGRect(
            x: RegionDraftChromeView.panelOutset,
            y: RegionDraftChromeView.panelOutset,
            width: selectionSize.width,
            height: selectionSize.height
        )
        chromeView.frame = CGRect(origin: .zero, size: panelSize)
        precondition(
            annotationView.bounds.size == selectionSize,
            "Region draft geometry must synchronously resize the annotation viewport."
        )
        precondition(
            chromeView.bounds.size == panelSize,
            "Region draft geometry must synchronously resize its single chrome layer."
        )
    }

    override func layout() {
        super.layout()
        annotationView?.frame = bounds.insetBy(
            dx: RegionDraftChromeView.panelOutset,
            dy: RegionDraftChromeView.panelOutset
        )
        chromeView?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        guard let annotationView, let chromeView else {
            preconditionFailure("Region draft hit routing was queried before configuration.")
        }

        let chromePoint = chromeView.convert(point, from: self)
        if let chromeHit = chromeView.hitTest(chromePoint) {
            return chromeHit
        }

        let annotationPoint = annotationView.convert(point, from: self)
        guard annotationView.bounds.contains(annotationPoint) else { return nil }
        return annotationView.hitTest(annotationPoint) ?? annotationView
    }
}

private final class RegionDraftChromeView: NSView {
    static let panelOutset: CGFloat = 10

    static func panelSize(for selectionSize: CGSize) -> CGSize {
        CGSize(
            width: selectionSize.width + panelOutset * 2,
            height: selectionSize.height + panelOutset * 2
        )
    }

    static func panelFrame(forSelectionFrame selectionFrame: CGRect) -> CGRect {
        selectionFrame.standardized.insetBy(dx: -panelOutset, dy: -panelOutset)
    }

    static func selectionFrame(fromPanelFrame panelFrame: CGRect) -> CGRect {
        panelFrame.standardized.insetBy(dx: panelOutset, dy: panelOutset)
    }

    var onResizeBegan: ((RegionSelectionResizeHandle, CGPoint) -> Void)?
    var onResizeChanged: ((CGPoint) -> Void)?
    var onResizeEnded: ((CGPoint) -> Void)?
    /// Configured logical corner radius before selection-size clamp.
    var configuredCornerRadius: CGFloat = RegionCaptureCornerRadius.defaultLogicalPoints {
        didSet {
            guard configuredCornerRadius != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(accessibilityValue)
        }
    }

    var isResizeEnabled = true {
        didSet {
            guard isResizeEnabled != oldValue else { return }
            if !isResizeEnabled { activeHandle = nil }
            setAccessibilityValue(
                accessibilityValue
            )
            window?.invalidateCursorRects(for: self)
        }
    }

    private let handleDiameter: CGFloat = 8
    private let handleHitDiameter: CGFloat = 18
    private var activeHandle: RegionSelectionResizeHandle?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString(
            "Resize selected region",
            comment: "Region confirmation resize handles"
        ))
        setAccessibilityIdentifier("capture.region.resizeChrome")
        setAccessibilityValue(accessibilityValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isResizeEnabled, resizeHandle(at: point) != nil else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isResizeEnabled else { return }
        for (handle, rect) in resizeHitRegions() {
            addCursorRect(rect, cursor: cursor(for: handle))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isResizeEnabled,
              let handle = resizeHandle(at: convert(event.locationInWindow, from: nil))
        else { return }
        activeHandle = handle
        onResizeBegan?(handle, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizeEnabled, activeHandle != nil else { return }
        onResizeChanged?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard isResizeEnabled, activeHandle != nil else { return }
        activeHandle = nil
        onResizeEnded?(NSEvent.mouseLocation)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let selectionRect = selectionRect
        guard selectionRect.width >= 2, selectionRect.height >= 2 else { return }

        // Match the pre-confirmation overlay stroke inset. Do not re-run
        // `.integral` here: the selection is already a whole-point frame, and
        // re-integraling a layout-fractional rect would expand it by 1 pt.
        let borderRect = selectionRect.insetBy(dx: 0.5, dy: 0.5)
        let borderRadius = effectiveCornerRadius(for: borderRect.size)
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(
            roundedRect: borderRect,
            xRadius: borderRadius,
            yRadius: borderRadius
        )
        border.lineWidth = 2
        border.stroke()

        for point in handlePoints() {
            let handle = CGRect(
                x: point.x - handleDiameter / 2,
                y: point.y - handleDiameter / 2,
                width: handleDiameter,
                height: handleDiameter
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handle).fill()
            NSColor.systemBlue.setStroke()
            NSBezierPath(ovalIn: handle).stroke()
        }
    }

    private func resizeHandle(at point: CGPoint) -> RegionSelectionResizeHandle? {
        resizeHitRegions().first { _, rect in rect.contains(point) }?.0
    }

    private func handlePoints() -> [CGPoint] {
        let selectionRect = selectionRect
        return [
            CGPoint(x: selectionRect.minX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.midX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.midY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.minY),
            CGPoint(x: selectionRect.midX, y: selectionRect.minY),
            CGPoint(x: selectionRect.minX, y: selectionRect.minY),
            CGPoint(x: selectionRect.minX, y: selectionRect.midY)
        ]
    }

    private var selectionRect: CGRect {
        bounds.insetBy(dx: Self.panelOutset, dy: Self.panelOutset)
    }

    private func effectiveCornerRadius(for size: CGSize) -> CGFloat {
        RegionCaptureCornerRadius.effective(for: size, configured: configuredCornerRadius)
    }

    private var accessibilityValue: String {
        let cornerRadius = effectiveCornerRadius(for: selectionRect.size)
        return "handles=8; resize=\(isResizeEnabled ? "enabled" : "disabled"); borderInset=\(Int(Self.panelOutset)); handleAlignment=border; borderHitTarget=full; interiorHitTarget=canvas; cornerRadius=\(cornerRadius)"
    }

    private func resizeHitRegions() -> [(RegionSelectionResizeHandle, CGRect)] {
        let rect = selectionRect
        let half = handleHitDiameter / 2
        let cornerSpan = handleHitDiameter
        let horizontalLength = max(0, rect.width - cornerSpan * 2)
        let verticalLength = max(0, rect.height - cornerSpan * 2)
        return [
            (.northWest, CGRect(x: rect.minX - half, y: rect.maxY - half, width: handleHitDiameter, height: handleHitDiameter)),
            (.northEast, CGRect(x: rect.maxX - half, y: rect.maxY - half, width: handleHitDiameter, height: handleHitDiameter)),
            (.southEast, CGRect(x: rect.maxX - half, y: rect.minY - half, width: handleHitDiameter, height: handleHitDiameter)),
            (.southWest, CGRect(x: rect.minX - half, y: rect.minY - half, width: handleHitDiameter, height: handleHitDiameter)),
            (.north, CGRect(x: rect.minX + cornerSpan, y: rect.maxY - half, width: horizontalLength, height: handleHitDiameter)),
            (.east, CGRect(x: rect.maxX - half, y: rect.minY + cornerSpan, width: handleHitDiameter, height: verticalLength)),
            (.south, CGRect(x: rect.minX + cornerSpan, y: rect.minY - half, width: horizontalLength, height: handleHitDiameter)),
            (.west, CGRect(x: rect.minX - half, y: rect.minY + cornerSpan, width: handleHitDiameter, height: verticalLength))
        ]
    }

    private func cursor(for handle: RegionSelectionResizeHandle) -> NSCursor {
        handle.cursor
    }
}

private final class PinnedShotPanel: NSPanel {
    var onEscape: (() -> Void)?
    var shouldAcceptLeftMouseDown: (() -> Bool)?
    var inputRole = "unconfigured"

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            guard shouldAcceptLeftMouseDown?() != false else { return }
            let point = event.locationInWindow
            let targetDescription: String
            if let contentView {
                let contentPoint = contentView.convert(point, from: nil)
                let target = contentView.hitTest(contentPoint)
                targetDescription = target.map { String(describing: type(of: $0)) } ?? "none"
            } else {
                targetDescription = "no-content-view"
            }
            AppLog.capture.notice(
                "Pinned surface pointer routed: role=\(self.inputRole, privacy: .public), target=\(targetDescription, privacy: .public), x=\(point.x, privacy: .public), y=\(point.y, privacy: .public), ignoresMouseEvents=\(self.ignoresMouseEvents, privacy: .public)"
            )
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard let onEscape else {
            super.cancelOperation(sender)
            return
        }
        onEscape()
    }
}

private final class PinnedShotToolbarPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        guard let onEscape else {
            super.cancelOperation(sender)
            return
        }
        onEscape()
    }
}

@MainActor
private final class PinnedShotToolbarController: NSViewController, NSTextFieldDelegate {
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onRestoreSize: (() -> Void)?
    var onOpacityChange: ((CGFloat) -> Void)?
    var onToggleClickThrough: ((Bool) -> Void)?
    var onToggleHidden: (() -> Void)?
    var onOpenEditor: (() -> Void)?
    var onClose: (() -> Void)?
    var onSelectTool: ((AnnotationTool) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onColorChange: ((NSColor) -> Void)?
    var onLineWidthEditingBegan: (() -> Void)?
    var onLineWidthChange: ((CGFloat) -> Void)?
    var onLineWidthCommit: ((CGFloat, AnnotationLineWidthUnit) -> Void)?
    var onLineWidthCancel: (() -> Void)?
    var onLineWidthUnitChange: ((AnnotationLineWidthUnit) -> Void)?
    var onShapeFillModeChange: ((ShapeFillMode) -> Void)?
    var onArrowStyleChange: ((ArrowHeadStyle) -> Void)?

    var preferredStylePopoverSpaceBelow: CGFloat {
        PinnedToolStylePopoverController.maximumPreferredPopoverHeight + 20
    }

    private let hiddenButton = NSButton()
    private let clickThroughButton = NSButton()
    private let confirmationButton = NSButton()
    private let annotationColorButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider()
    private let lineWidthField = NSTextField()
    private let lineWidthUnitButton = NSPopUpButton()
    private let lineWidthFormatter = NumberFormatter()
    private var backingScale: CGFloat
    private var toolShortcuts: [AnnotationTool: HotKeyShortcut]
    private var colorPaletteHexes: [String]
    private var currentColorHex: String
    private var allowsHistoricalCurrentColor = false
    private var committedLineWidth: CGFloat
    private var lineWidthAtEditingStart: CGFloat? = nil
    private var lineWidthUnit: AnnotationLineWidthUnit
    private var shapeFillMode: ShapeFillMode
    private var arrowHeadStyle: ArrowHeadStyle
    private var stylePopover: NSPopover?
    private var colorActionGeneration: UInt = 0
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var copyButton: NSButton?
    private var saveButton: NSButton?
    private var pinButton: NSButton?
    private var regionActionSeparator: NSBox?
    private var closeButton: NSButton?
    private var pinnedOnlyControls: [NSView] = []
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var exportingControlStates: [(control: NSControl, wasEnabled: Bool)] = []
    private var isExporting = false
    private let toolOrder = AnnotationTool.quickToolbarOrder
    private let showsPinAction: Bool

    var hasActiveLineWidthEditing: Bool { lineWidthAtEditingStart != nil }
    var hasAttachedLineWidthFieldEditor: Bool { lineWidthField.currentEditor() != nil }

#if DEBUG
    var debugLineWidthFieldIsEnabled: Bool { lineWidthField.isEnabled }
    var debugCommittedLineWidth: CGFloat { committedLineWidth }
    var debugHasActiveLineWidthEdit: Bool { lineWidthAtEditingStart != nil }
    var debugLineWidthFieldHasEditor: Bool { lineWidthField.currentEditor() != nil }
    var debugLineWidthFieldString: String { lineWidthField.stringValue }
    var debugColorPaletteHexes: [String] { colorPaletteHexes }
    var debugCurrentColorHex: String { currentColorHex }

    func beginLineWidthInputRegression(displayedText: String) {
        precondition(
            lineWidthField.isEnabled && lineWidthAtEditingStart == nil,
            "A toolbar input regression requires an enabled, idle line-width field."
        )
        lineWidthField.stringValue = displayedText
        controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: lineWidthField))
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: lineWidthField))
    }

    func beginNativeLineWidthInputRegression(displayedText: String) {
        precondition(
            lineWidthField.isEnabled && lineWidthAtEditingStart == nil,
            "A native toolbar input regression requires an enabled, idle line-width field."
        )
        guard let window = lineWidthField.window,
              window.makeFirstResponder(lineWidthField),
              let fieldEditor = lineWidthField.currentEditor() as? NSTextView
        else {
            preconditionFailure("The native toolbar input regression could not acquire a field editor.")
        }
        if lineWidthAtEditingStart == nil {
            controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: lineWidthField))
        }
        lineWidthField.stringValue = displayedText
        fieldEditor.string = displayedText
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: lineWidthField))
        precondition(
            lineWidthField.currentEditor() != nil && lineWidthAtEditingStart != nil,
            "The native toolbar input regression must retain its field editor and semantic transaction."
        )
    }

    func runLineWidthInputCommitRegression(displayedText: String) {
        beginLineWidthInputRegression(displayedText: displayedText)
        lineWidthChanged(lineWidthField)
        precondition(
            lineWidthAtEditingStart == nil,
            "A toolbar input regression must finish its line-width transaction."
        )
    }

    func runLineWidthUnitChangeRegression(to unit: AnnotationLineWidthUnit) {
        precondition(
            unit != lineWidthUnit && lineWidthAtEditingStart != nil,
            "A toolbar unit regression requires a different unit and an active line-width edit."
        )
        lineWidthUnitButton.selectItem(withTitle: unit.rawValue)
        lineWidthUnitChanged(lineWidthUnitButton)
    }
#endif

    init(
        initialStyle: AnnotationStyle,
        initialLineWidthUnit: AnnotationLineWidthUnit,
        toolShortcuts: [AnnotationTool: HotKeyShortcut],
        colorPaletteHexes: [String],
        backingScale: CGFloat,
        showsPinAction: Bool = false
    ) {
        precondition(backingScale.isFinite && backingScale > 0, "Pinned annotation toolbar requires a valid backing scale.")
        precondition(
            Self.isValidColorPalette(colorPaletteHexes),
            "Pinned annotation toolbar colors must be unique, normalized #RRGGBB values."
        )
        let initialColorHex = AnnotationColorPalette.hexString(for: initialStyle.strokeColor)
        precondition(
            colorPaletteHexes.contains(initialColorHex),
            "The initial annotation color must be present in the toolbar color menu."
        )
        self.backingScale = backingScale
        committedLineWidth = initialStyle.lineWidth
        lineWidthUnit = initialLineWidthUnit
        self.toolShortcuts = toolShortcuts
        self.colorPaletteHexes = colorPaletteHexes
        currentColorHex = initialColorHex
        shapeFillMode = initialStyle.shapeFillMode
        arrowHeadStyle = initialStyle.arrowHeadStyle
        self.showsPinAction = showsPinAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = 10
        material.setAccessibilityIdentifier(
            showsPinAction ? "capture.region.toolbar.content" : "pinned.toolbar"
        )

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            stack.topAnchor.constraint(equalTo: material.topAnchor),
            stack.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])

        for (index, tool) in toolOrder.enumerated() {
            let toolButton = button(
                symbol: tool.toolbarSystemSymbolName,
                help: helpTitle(for: tool),
                action: #selector(selectTool(_:)),
                identifier: "pinned.tool.\(tool.rawValue)"
            )
            if tool == .text {
                toolButton.image = nil
                toolButton.imagePosition = .noImage
                toolButton.title = "T"
                toolButton.font = .systemFont(ofSize: 15, weight: .semibold)
                toolButton.alignment = .center
            }
            toolButton.tag = index
            toolButton.setButtonType(.toggle)
            toolButton.wantsLayer = true
            toolButton.layer?.cornerRadius = 5
            toolButtons[tool] = toolButton
            stack.addArrangedSubview(toolButton)
        }
        setSelectedTool(.select)
        stack.addArrangedSubview(separator())
        let undoButton = button(
            symbol: "arrow.uturn.backward",
            help: "Undo",
            action: #selector(undo),
            identifier: "pinned.action.undo"
        )
        let redoButton = button(
            symbol: "arrow.uturn.forward",
            help: "Redo",
            action: #selector(redo),
            identifier: "pinned.action.redo"
        )
        self.undoButton = undoButton
        self.redoButton = redoButton
        setUndoState(canUndo: false, canRedo: false)
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)

        annotationColorButton.controlSize = .small
        annotationColorButton.imagePosition = .imageOnly
        annotationColorButton.target = self
        annotationColorButton.action = #selector(colorChanged(_:))
        let annotationColorTitle = NSLocalizedString("Annotation color", comment: "Annotation color control")
        annotationColorButton.toolTip = annotationColorTitle
        annotationColorButton.setAccessibilityLabel(annotationColorTitle)
        annotationColorButton.setAccessibilityIdentifier("pinned.annotation.color")
        annotationColorButton.widthAnchor.constraint(equalToConstant: 38).isActive = true
        annotationColorButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        rebuildColorMenu()
        stack.addArrangedSubview(annotationColorButton)

        lineWidthFormatter.numberStyle = .decimal
        lineWidthFormatter.minimumFractionDigits = 0
        lineWidthFormatter.maximumFractionDigits = 1
        // Keep the editor's raw text independent from its committed numeric
        // value. Attaching NumberFormatter directly makes AppKit reject the
        // valid intermediate string `1.`, so users can only insert a decimal
        // point after typing both surrounding digits.
        lineWidthField.alignment = .right
        lineWidthField.controlSize = .small
        (lineWidthField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        lineWidthField.delegate = self
        lineWidthField.target = self
        lineWidthField.action = #selector(lineWidthChanged(_:))
        lineWidthField.toolTip = NSLocalizedString("Line width", comment: "Annotation line-width tooltip")
        lineWidthField.setAccessibilityLabel(NSLocalizedString("Annotation line width", comment: "Annotation line-width control"))
        lineWidthField.setAccessibilityIdentifier("pinned.annotation.lineWidth")
        lineWidthField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(lineWidthField)

        lineWidthUnitButton.controlSize = .small
        lineWidthUnitButton.target = self
        lineWidthUnitButton.action = #selector(lineWidthUnitChanged(_:))
        lineWidthUnitButton.setAccessibilityLabel(NSLocalizedString(
            "Line width unit",
            comment: "Annotation line-width unit control"
        ))
        lineWidthUnitButton.setAccessibilityIdentifier("pinned.annotation.lineWidthUnit")
        for unit in AnnotationLineWidthUnit.allCases {
            lineWidthUnitButton.addItem(withTitle: unit.rawValue)
        }
        lineWidthUnitButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        stack.addArrangedSubview(lineWidthUnitButton)
        refreshLineWidthControls()
        stack.addArrangedSubview(separator())

        let copyButton = button(
            symbol: "doc.on.doc",
            help: "Copy",
            action: #selector(copyImage),
            identifier: "pinned.action.copy"
        )
        let saveButton = button(
            symbol: "square.and.arrow.down",
            help: "Save",
            action: #selector(saveImage),
            identifier: "pinned.action.save"
        )
        self.copyButton = copyButton
        self.saveButton = saveButton
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(saveButton)
        stack.addArrangedSubview(button(
            symbol: "1.square",
            help: "Original size",
            action: #selector(restoreSize),
            identifier: "pinned.action.originalSize"
        ))

        opacitySlider.minValue = 0.2
        opacitySlider.maxValue = 1
        opacitySlider.doubleValue = 1
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.toolTip = NSLocalizedString("Opacity", comment: "Pinned screenshot opacity tooltip")
        opacitySlider.setAccessibilityLabel(NSLocalizedString("Pinned screenshot opacity", comment: "Pinned screenshot opacity control"))
        opacitySlider.setAccessibilityIdentifier("pinned.image.opacity")
        opacitySlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        stack.addArrangedSubview(opacitySlider)

        clickThroughButton.image = NSImage(
            systemSymbolName: "cursorarrow.rays",
            accessibilityDescription: NSLocalizedString("Click through", comment: "Click-through icon")
        )
        configure(button: clickThroughButton, help: "Toggle click-through", action: #selector(toggleClickThrough(_:)))
        clickThroughButton.setAccessibilityIdentifier("pinned.image.clickThrough")
        clickThroughButton.setButtonType(.toggle)
        updateToggleAppearance(clickThroughButton, enabled: false)
        stack.addArrangedSubview(clickThroughButton)

        hiddenButton.image = NSImage(
            systemSymbolName: "eye.slash",
            accessibilityDescription: NSLocalizedString("Temporarily hide image", comment: "Hide pinned screenshot icon")
        )
        configure(button: hiddenButton, help: "Temporarily hide image", action: #selector(toggleHidden))
        hiddenButton.setAccessibilityIdentifier("pinned.image.visibility")
        setImageHidden(false)
        stack.addArrangedSubview(hiddenButton)

        let openEditorButton = button(
            symbol: "pencil.and.outline",
            help: "Open Canvas Editor",
            action: #selector(openEditor),
            identifier: "pinned.action.openEditor"
        )
        stack.addArrangedSubview(openEditorButton)
        pinnedOnlyControls = [clickThroughButton, hiddenButton, openEditorButton]
        for control in pinnedOnlyControls {
            control.isHidden = showsPinAction
        }
        if showsPinAction {
            let regionActionSeparator = separator()
            self.regionActionSeparator = regionActionSeparator
            stack.addArrangedSubview(regionActionSeparator)
            let pinButton = button(
                symbol: "pin.fill",
                help: "Pin selected region",
                action: #selector(pinSelectedRegion),
                identifier: "capture.region.pin"
            )
            pinButton.contentTintColor = .controlAccentColor
            self.pinButton = pinButton
            stack.addArrangedSubview(pinButton)
        }
        let closeButton = button(
            symbol: "xmark",
            help: showsPinAction ? "Cancel" : "Close",
            action: #selector(closePanel),
            identifier: showsPinAction ? "capture.region.cancel" : "pinned.action.close"
        )
        self.closeButton = closeButton
        stack.addArrangedSubview(closeButton)

        confirmationButton.isHidden = true
        confirmationButton.isBordered = false
        confirmationButton.isEnabled = false
        stack.addArrangedSubview(confirmationButton)
        view = material
    }

    func configureForSession(
        style: AnnotationStyle,
        lineWidthUnit: AnnotationLineWidthUnit,
        toolShortcuts: [AnnotationTool: HotKeyShortcut],
        colorPaletteHexes: [String],
        backingScale: CGFloat
    ) {
        colorActionGeneration &+= 1
        cancelActiveLineWidthEditingForLifecycle(reason: "session-reconfiguration")
        precondition(
            lineWidthField.currentEditor() == nil,
            "A reused annotation toolbar must not retain its previous field editor."
        )
        precondition(
            backingScale.isFinite && backingScale > 0,
            "A reused annotation toolbar requires a valid backing scale."
        )
        self.backingScale = backingScale
        self.lineWidthUnit = lineWidthUnit
        self.toolShortcuts = toolShortcuts
        committedLineWidth = style.lineWidth
        shapeFillMode = style.shapeFillMode
        arrowHeadStyle = style.arrowHeadStyle

        _ = view
        stylePopover?.close()
        stylePopover = nil
        currentColorHex = AnnotationColorPalette.hexString(for: style.strokeColor)
        setColorPalette(colorPaletteHexes)
        opacitySlider.doubleValue = 1
        clickThroughButton.state = .off
        updateToggleAppearance(clickThroughButton, enabled: false)
        setImageHidden(false)
        confirmationButton.isHidden = true
        setExporting(false)
        setRegionDraftTransitioning(false)
        setRegionActionsVisible(showsPinAction)
        setToolShortcuts(toolShortcuts)
        allowsHistoricalCurrentColor = false
        setAnnotationStyle(style, allowsHistoricalColor: false)
        refreshLineWidthControls()
        setSelectedTool(.select)
        setUndoState(canUndo: false, canRedo: false)
    }

    func prepareForReuse() {
        colorActionGeneration &+= 1
        cancelActiveLineWidthEditingForLifecycle(reason: "toolbar-reuse")
        stylePopover?.close()
        stylePopover = nil
        confirmationButton.isHidden = true
        setRegionActionsVisible(showsPinAction)
    }

    func setRegionActionsVisible(_ visible: Bool) {
        guard showsPinAction else { return }
        regionActionSeparator?.isHidden = !visible
        pinButton?.isHidden = !visible
        for control in pinnedOnlyControls {
            control.isHidden = visible
        }
        let closeHelp = NSLocalizedString(
            visible ? "Cancel" : "Close",
            comment: "Screenshot toolbar close action"
        )
        closeButton?.toolTip = closeHelp
        closeButton?.setAccessibilityLabel(closeHelp)
        closeButton?.setAccessibilityIdentifier(
            visible ? "capture.region.cancel" : "pinned.action.close"
        )
        view.setAccessibilityIdentifier(
            visible ? "capture.region.toolbar.content" : "pinned.toolbar"
        )
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        AppLog.capture.debug(
            "Configured screenshot toolbar lifecycle controls: regionActions=\(visible, privacy: .public), pinnedOnlyActions=\(!visible, privacy: .public), pinnedOnlyControlCount=\(self.pinnedOnlyControls.count, privacy: .public)"
        )
    }

    func setImageHidden(_ hidden: Bool) {
        let description = NSLocalizedString(
            hidden ? "Show image" : "Temporarily hide image",
            comment: "Pinned screenshot visibility action"
        )
        hiddenButton.image = NSImage(
            systemSymbolName: hidden ? "eye" : "eye.slash",
            accessibilityDescription: description
        )
        hiddenButton.toolTip = description
        hiddenButton.setAccessibilityLabel(description)
        hiddenButton.setAccessibilityValue(NSLocalizedString(
            hidden ? "Hidden" : "Visible",
            comment: "Pinned screenshot visibility state"
        ))
    }

    func setSelectedTool(_ selectedTool: AnnotationTool) {
        stylePopover?.close()
        stylePopover = nil
        for (tool, button) in toolButtons {
            let selected = tool == selectedTool
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
            button.setAccessibilityValue(NSLocalizedString(
                selected ? "Selected" : "Not selected",
                comment: "Pinned annotation tool selection state"
            ))
        }
    }

    func setAnnotationStyle(
        _ style: AnnotationStyle,
        allowsHistoricalColor: Bool
    ) {
        shapeFillMode = style.shapeFillMode
        arrowHeadStyle = style.arrowHeadStyle
        let semanticColor = style.strokeColor
        let hasValidSemanticColor = semanticColor.red.isFinite
            && semanticColor.green.isFinite
            && semanticColor.blue.isFinite
            && semanticColor.alpha.isFinite
            && semanticColor.alpha > .ulpOfOne
        if !hasValidSemanticColor {
            AppLog.capture.error(
                "Rejected annotation style without a visible semantic toolbar color."
            )
        }
        precondition(
            hasValidSemanticColor,
            "An active annotation style must expose a visible finite semantic color."
        )
        let updatedColorHex = AnnotationColorPalette.hexString(for: style.strokeColor)
        let isConfiguredColor = colorPaletteHexes.contains(updatedColorHex)
        precondition(
            isConfiguredColor || allowsHistoricalColor,
            "Only a selected existing annotation may present a color outside the configured palette."
        )
        allowsHistoricalCurrentColor = allowsHistoricalColor
        if !isConfiguredColor {
            AppLog.capture.notice(
                "Presented existing annotation color outside current palette: color=\(updatedColorHex, privacy: .public), paletteCount=\(self.colorPaletteHexes.count, privacy: .public)"
            )
        }
        if currentColorHex != updatedColorHex {
            currentColorHex = updatedColorHex
            rebuildColorMenu()
        } else {
            selectCurrentColorMenuItem()
        }
    }

    func setLineWidthPresentation(
        logicalPoints: CGFloat,
        isEnabled: Bool
    ) {
        precondition(
            logicalPoints.isFinite && (0.5...24).contains(logicalPoints),
            "A toolbar line-width presentation must be finite and supported."
        )
        let isActivelyEditing = lineWidthAtEditingStart != nil
        if !isActivelyEditing {
            committedLineWidth = logicalPoints
        }
        lineWidthField.isEnabled = !isExporting && (isEnabled || isActivelyEditing)
        if !isActivelyEditing, lineWidthField.currentEditor() == nil {
            refreshLineWidthField()
        }
    }

    func setColorPalette(_ colorPaletteHexes: [String]) {
        precondition(
            Self.isValidColorPalette(colorPaletteHexes),
            "Pinned annotation toolbar colors must be unique, normalized #RRGGBB values."
        )
        precondition(
            colorPaletteHexes.contains(currentColorHex) || allowsHistoricalCurrentColor,
            "A tool default may not survive outside the configured annotation palette."
        )
        guard self.colorPaletteHexes != colorPaletteHexes else {
            let displayedHexes = annotationColorButton.itemArray.compactMap {
                $0.representedObject as? String
            }
            if displayedHexes == effectiveColorMenuHexes {
                selectCurrentColorMenuItem()
            } else {
                rebuildColorMenu()
            }
            return
        }
        colorActionGeneration &+= 1
        self.colorPaletteHexes = colorPaletteHexes
        rebuildColorMenu()
    }

    func setColorConfiguration(
        palette: [String],
        style: AnnotationStyle,
        allowsHistoricalColor: Bool
    ) {
        precondition(
            Self.isValidColorPalette(palette),
            "Pinned annotation toolbar colors must be unique, normalized #RRGGBB values."
        )
        let paletteChanged = colorPaletteHexes != palette
        let previousColorHex = currentColorHex
        if paletteChanged {
            colorActionGeneration &+= 1
        }
        colorPaletteHexes = palette
        setAnnotationStyle(
            style,
            allowsHistoricalColor: allowsHistoricalColor
        )
        if paletteChanged, previousColorHex == currentColorHex {
            rebuildColorMenu()
        }
    }

    func setLineWidthUnit(_ unit: AnnotationLineWidthUnit) {
        guard lineWidthUnit != unit else { return }
        lineWidthUnit = unit
        refreshLineWidthControls()
    }

    func setBackingScale(_ scale: CGFloat) {
        precondition(
            scale.isFinite && scale > 0,
            "An annotation toolbar requires a valid backing scale."
        )
        guard backingScale != scale else { return }
        backingScale = scale
        refreshLineWidthControls()
    }

    func setToolShortcuts(_ shortcuts: [AnnotationTool: HotKeyShortcut]) {
        toolShortcuts = shortcuts
        for (tool, button) in toolButtons {
            let help = helpTitle(for: tool)
            button.toolTip = help
            button.setAccessibilityLabel(help)
        }
    }

    func setUndoState(canUndo: Bool, canRedo: Bool) {
        undoButton?.isEnabled = !isExporting && canUndo
        redoButton?.isEnabled = !isExporting && canRedo
    }

    func setExporting(_ exporting: Bool) {
        guard exporting != isExporting else { return }
        isExporting = exporting
        if exporting {
            stylePopover?.close()
            stylePopover = nil
            exportingControlStates = descendantControls(in: view)
                .filter { $0 !== closeButton }
                .map { control in
                    let state = (control: control, wasEnabled: control.isEnabled)
                    control.isEnabled = false
                    return state
                }
        } else {
            for state in exportingControlStates {
                state.control.isEnabled = state.wasEnabled
            }
            exportingControlStates.removeAll()
        }
    }

    func setRegionDraftTransitioning(_ transitioning: Bool) {
        pinButton?.isEnabled = !isExporting && !transitioning
    }

    private func descendantControls(in rootView: NSView) -> [NSControl] {
        rootView.subviews.flatMap { subview in
            let control = (subview as? NSControl).map { [$0] } ?? []
            return control + descendantControls(in: subview)
        }
    }

    func showConfirmation(symbol: String, help: String) {
        let localizedHelp = NSLocalizedString(help, comment: "Pinned screenshot action confirmation")
        confirmationButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: localizedHelp)
        confirmationButton.toolTip = localizedHelp
        confirmationButton.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.confirmationButton.isHidden = true
        }
    }

    private func button(
        symbol: String,
        help: String,
        action: Selector,
        identifier: String? = nil
    ) -> NSButton {
        let localizedHelp = NSLocalizedString(help, comment: "Pinned screenshot toolbar action")
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: localizedHelp)
        configure(button: button, help: localizedHelp, action: action)
        if let identifier {
            button.setAccessibilityIdentifier(identifier)
        }
        return button
    }

    private func configure(button: NSButton, help: String, action: Selector) {
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func updateToggleAppearance(_ button: NSButton, enabled: Bool) {
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.contentTintColor = enabled ? .controlAccentColor : .labelColor
        button.layer?.backgroundColor = enabled
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        button.setAccessibilityValue(NSLocalizedString(
            enabled ? "Enabled" : "Disabled",
            comment: "Pinned screenshot toggle state"
        ))
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return separator
    }

    private func title(for tool: AnnotationTool) -> String {
        tool.title
    }

    private func helpTitle(for tool: AnnotationTool) -> String {
        guard let shortcut = toolShortcuts[tool] else { return title(for: tool) }
        return "\(title(for: tool)) (\(shortcut.displayString))"
    }

    private func rebuildColorMenu() {
        annotationColorButton.removeAllItems()
        for hex in effectiveColorMenuHexes {
            annotationColorButton.addItem(withTitle: hex)
            guard let item = annotationColorButton.lastItem else {
                preconditionFailure("The annotation color menu failed to add \(hex).")
            }
            item.representedObject = hex
            item.image = Self.colorSwatchImage(for: hex)
            item.setAccessibilityIdentifier("pinned.annotation.color.\(hex.dropFirst())")
            if !colorPaletteHexes.contains(hex) {
                item.isEnabled = false
                item.toolTip = NSLocalizedString(
                    "Current document color (removed from palette)",
                    comment: "Disabled annotation color menu item"
                )
                item.setAccessibilityLabel(
                    "\(hex), \(item.toolTip ?? "")"
                )
            }
        }
        selectCurrentColorMenuItem()
    }

    private var effectiveColorMenuHexes: [String] {
        AnnotationColorPalette.displayedHexColors(
            configuredHexColors: colorPaletteHexes,
            currentHex: currentColorHex
        )
    }

    private func selectCurrentColorMenuItem() {
        guard let selection = annotationColorButton.itemArray.enumerated().first(where: {
            $0.element.representedObject as? String == currentColorHex
        }),
              let selectedItem = annotationColorButton.item(at: selection.offset),
              let selectedSwatch = selectedItem.image
        else {
            preconditionFailure("The active annotation color is missing from its menu.")
        }
        annotationColorButton.selectItem(at: selection.offset)
        for (itemIndex, item) in annotationColorButton.itemArray.enumerated() {
            item.state = itemIndex == selection.offset ? .on : .off
        }
        // Swatches are rendered once when the palette changes. Reusing the
        // selected menu item's image avoids an AppKit focus/drawing round trip
        // while the menu is still tracking the click.
        annotationColorButton.image = selectedSwatch
        annotationColorButton.setAccessibilityValue(currentColorHex)
    }

    private static func isValidColorPalette(_ hexes: [String]) -> Bool {
        !hexes.isEmpty
            && Set(hexes).count == hexes.count
            && hexes.allSatisfy { AnnotationColorPalette.normalizedHex($0) == $0 }
    }

    private static func colorSwatchImage(for hex: String) -> NSImage {
        guard let color = AnnotationColorPalette.color(fromHex: hex) else {
            preconditionFailure("The annotation color menu received an invalid color: \(hex)")
        }
        let image = NSImage(size: NSSize(width: 15, height: 15))
        image.lockFocus()
        defer { image.unlockFocus() }
        let path = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 13, height: 13))
        NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        ).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        image.isTemplate = false
        image.accessibilityDescription = hex
        return image
    }

    private func showStylePopover(for tool: AnnotationTool, relativeTo button: NSButton) {
        stylePopover?.close()
        let optionsController: PinnedToolStylePopoverController
        switch tool {
        case .rectangle, .ellipse:
            optionsController = PinnedToolStylePopoverController(
                shapeFillMode: shapeFillMode,
                shape: tool
            )
        case .arrow:
            optionsController = PinnedToolStylePopoverController(arrowHeadStyle: arrowHeadStyle)
        default:
            stylePopover = nil
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = optionsController
        popover.contentSize = optionsController.preferredPopoverSize
        optionsController.onShapeFillModeChange = { [weak self, weak popover] fillMode in
            self?.shapeFillMode = fillMode
            self?.onShapeFillModeChange?(fillMode)
            popover?.performClose(nil)
        }
        optionsController.onArrowStyleChange = { [weak self, weak popover] arrowStyle in
            self?.arrowHeadStyle = arrowStyle
            self?.onArrowStyleChange?(arrowStyle)
            popover?.performClose(nil)
        }
        // NSButton uses flipped coordinates, so maxY is its visual bottom edge.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        stylePopover = popover
        DispatchQueue.main.async { [weak self, weak popover] in
            guard let self,
                  let popoverFrame = popover?.contentViewController?.view.window?.frame,
                  let toolbarFrame = self.view.window?.frame
            else { return }
            let verticalPlacement = popoverFrame.midY < toolbarFrame.midY ? "below" : "above"
            AppLog.capture.debug(
                "Presented pinned style popover: placement=\(verticalPlacement, privacy: .public), popoverY=\(popoverFrame.minY, privacy: .public), toolbarY=\(toolbarFrame.minY, privacy: .public)"
            )
        }
    }

    @objc private func pinSelectedRegion() { onPin?() }
    @objc private func copyImage() { onCopy?() }
    @objc private func saveImage() { onSave?() }
    @objc private func restoreSize() { onRestoreSize?() }
    @objc private func opacityChanged(_ sender: NSSlider) { onOpacityChange?(CGFloat(sender.doubleValue)) }
    @objc private func toggleClickThrough(_ sender: NSButton) {
        let enabled = sender.state == .on
        updateToggleAppearance(sender, enabled: enabled)
        onToggleClickThrough?(enabled)
    }
    @objc private func toggleHidden() { onToggleHidden?() }
    @objc private func openEditor() { onOpenEditor?() }
    @objc private func closePanel() { onClose?() }
    @objc private func selectTool(_ sender: NSButton) {
        guard toolOrder.indices.contains(sender.tag) else { return }
        let tool = toolOrder[sender.tag]
        stylePopover?.close()
        onSelectTool?(tool)
        setSelectedTool(tool)
        showStylePopover(for: tool, relativeTo: sender)
    }
    @objc private func undo() { onUndo?() }
    @objc private func redo() { onRedo?() }
    @objc private func colorChanged(_ sender: NSPopUpButton) {
        let selectionStartedAt = ProcessInfo.processInfo.systemUptime
        guard let hex = sender.selectedItem?.representedObject as? String,
              colorPaletteHexes.contains(hex),
              let color = AnnotationColorPalette.color(fromHex: hex)
        else {
            preconditionFailure("The annotation color menu selected a non-configured item.")
        }
        let menuContainsHistoricalColor = annotationColorButton.numberOfItems
            > colorPaletteHexes.count
        let actionGeneration = colorActionGeneration
        let colorChange = onColorChange
        currentColorHex = hex
        allowsHistoricalCurrentColor = false
        selectCurrentColorMenuItem()
        let selectedColor = NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
        let menuActionFinishedAt = ProcessInfo.processInfo.systemUptime

        // A native popup keeps tracking until its action returns. Applying the
        // document mutation synchronously here made menu dismissal wait for
        // TextKit, selection and accessibility updates. Commit on the next main
        // run-loop turn so the popup closes immediately, then apply the exact
        // selected color without an artificial delay or dropped edit.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.colorActionGeneration == actionGeneration
            else {
                AppLog.capture.notice(
                    "Discarded stale annotation color action after toolbar lifecycle change: hex=\(hex, privacy: .public)"
                )
                return
            }
            let applicationStartedAt = ProcessInfo.processInfo.systemUptime
            if menuContainsHistoricalColor, self.colorPaletteHexes.contains(hex) {
                self.rebuildColorMenu()
            }
            colorChange?(selectedColor)
            let applicationFinishedAt = ProcessInfo.processInfo.systemUptime
            AppLog.capture.notice(
                "Applied annotation toolbar color: hex=\(hex, privacy: .public), queueDelayMs=\((applicationStartedAt - menuActionFinishedAt) * 1_000, privacy: .public), applyMs=\((applicationFinishedAt - applicationStartedAt) * 1_000, privacy: .public)"
            )
        }
        AppLog.capture.notice(
            "Selected annotation toolbar color: hex=\(hex, privacy: .public), paletteCount=\(self.colorPaletteHexes.count, privacy: .public), menuActionMs=\((menuActionFinishedAt - selectionStartedAt) * 1_000, privacy: .public)"
        )
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let sender = notification.object as? NSTextField,
              sender === lineWidthField
        else { return }
        beginLineWidthEditingIfNeeded()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let sender = notification.object as? NSTextField,
              sender === lineWidthField,
              let displayedLineWidth = parsedDisplayedLineWidth(from: sender.stringValue)
        else { return }
        beginLineWidthEditingIfNeeded()
        applyDisplayedLineWidth(displayedLineWidth)
    }

    @objc private func lineWidthChanged(_ sender: NSTextField) {
        beginLineWidthEditingIfNeeded()
        guard let displayedLineWidth = parsedDisplayedLineWidth(from: sender.stringValue),
              applyDisplayedLineWidth(displayedLineWidth)
        else {
            AppLog.capture.error(
                "Rejected invalid annotation line width: value=\(sender.stringValue, privacy: .public), unit=\(self.lineWidthUnit.rawValue, privacy: .public), scale=\(self.backingScale, privacy: .public)"
            )
            NSSound.beep()
            guard let initialLineWidth = lineWidthAtEditingStart else {
                preconditionFailure("An invalid line-width edit must retain its initial value.")
            }
            committedLineWidth = initialLineWidth
            lineWidthAtEditingStart = nil
            onLineWidthCancel?()
            refreshLineWidthField()
            return
        }
        lineWidthAtEditingStart = nil
        onLineWidthCommit?(committedLineWidth, lineWidthUnit)
        refreshLineWidthField()
    }

    private func beginLineWidthEditingIfNeeded() {
        guard lineWidthAtEditingStart == nil else { return }
        lineWidthAtEditingStart = committedLineWidth
        onLineWidthEditingBegan?()
    }

    func commitActiveLineWidthEditingForBoundary(reason: String) {
        let hadActiveEdit = lineWidthAtEditingStart != nil
        if hadActiveEdit {
            AppLog.capture.notice(
                "Resolving active toolbar line-width edit before context change: reason=\(reason, privacy: .public), unit=\(self.lineWidthUnit.rawValue, privacy: .public)"
            )
            lineWidthChanged(lineWidthField)
        }
        _ = lineWidthField.abortEditing()
        refreshLineWidthField()
        precondition(
            lineWidthAtEditingStart == nil && lineWidthField.currentEditor() == nil,
            "A toolbar context change must resolve and release its native line-width editor."
        )
        if hadActiveEdit {
            AppLog.capture.notice(
                "Resolved active toolbar line-width edit before context change: reason=\(reason, privacy: .public), logicalPoints=\(self.committedLineWidth, privacy: .public)"
            )
        }
    }

    func cancelActiveLineWidthEditingForLifecycle(reason: String) {
        let initialLineWidth = lineWidthAtEditingStart
        if let initialLineWidth {
            committedLineWidth = initialLineWidth
            lineWidthAtEditingStart = nil
            onLineWidthCancel?()
            refreshLineWidthField()
            AppLog.capture.notice(
                "Cancelled active toolbar line-width edit for lifecycle transition: reason=\(reason, privacy: .public), restoredLogicalPoints=\(initialLineWidth, privacy: .public)"
            )
        }
        _ = lineWidthField.abortEditing()
        refreshLineWidthField()
        precondition(
            lineWidthField.currentEditor() == nil,
            "A toolbar lifecycle transition must release its native field editor."
        )
    }

    @objc private func lineWidthUnitChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title,
              let unit = AnnotationLineWidthUnit(rawValue: title)
        else {
            preconditionFailure("The line-width unit menu contained an unknown item.")
        }
        guard lineWidthUnit != unit else { return }
        if lineWidthAtEditingStart != nil {
            AppLog.capture.notice(
                "Resolving active annotation line-width input before unit change: from=\(self.lineWidthUnit.rawValue, privacy: .public), to=\(unit.rawValue, privacy: .public)"
            )
        }
        commitActiveLineWidthEditingForBoundary(reason: "line-width-unit-change")
        lineWidthUnit = unit
        refreshLineWidthControls()
        onLineWidthUnitChange?(unit)
    }

    private func parsedDisplayedLineWidth(from text: String) -> CGFloat? {
        let valueText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !valueText.isEmpty else { return nil }

        let localeSeparator = lineWidthFormatter.decimalSeparator ?? "."
        let acceptedSeparators = localeSeparator == "." ? ["."] : [localeSeparator, "."]
        let usedSeparators = acceptedSeparators.filter(valueText.contains)
        guard usedSeparators.count <= 1 else { return nil }

        let separator = usedSeparators.first
        let components = separator.map { valueText.components(separatedBy: $0) } ?? [valueText]
        let hasValidFractionLength = separator == nil
            || (components.last?.count ?? 0) <= lineWidthFormatter.maximumFractionDigits
        guard components.count <= 2,
              components.joined().contains(where: \.isNumber),
              components.joined().allSatisfy(\.isNumber),
              hasValidFractionLength
        else { return nil }

        var localizedValueText = valueText
        if localeSeparator != ".", separator == "." {
            localizedValueText = valueText.replacingOccurrences(of: ".", with: localeSeparator)
        }
        if localizedValueText.hasPrefix(localeSeparator) {
            localizedValueText = "0" + localizedValueText
        }
        guard let number = lineWidthFormatter.number(from: localizedValueText) else { return nil }
        let value = CGFloat(number.doubleValue)
        return value.isFinite ? value : nil
    }

    @discardableResult
    private func applyDisplayedLineWidth(_ displayedLineWidth: CGFloat) -> Bool {
        guard displayedLineWidth.isFinite else { return false }
        let logicalLineWidth = lineWidthUnit.logicalPoints(
            fromDisplayedValue: displayedLineWidth,
            backingScale: backingScale
        )
        guard (0.5...24).contains(logicalLineWidth) else { return false }
        committedLineWidth = logicalLineWidth
        onLineWidthChange?(logicalLineWidth)
        return true
    }

    private func refreshLineWidthControls() {
        let minimum = lineWidthUnit.displayedValue(forLogicalPoints: 0.5, backingScale: backingScale)
        let maximum = lineWidthUnit.displayedValue(forLogicalPoints: 24, backingScale: backingScale)
        lineWidthFormatter.minimum = NSNumber(value: Double(minimum))
        lineWidthFormatter.maximum = NSNumber(value: Double(maximum))
        lineWidthUnitButton.selectItem(withTitle: lineWidthUnit.rawValue)
        lineWidthUnitButton.setAccessibilityValue(lineWidthUnit.rawValue)
        refreshLineWidthField()
    }

    private func refreshLineWidthField() {
        let displayedLineWidth = lineWidthUnit.displayedValue(
            forLogicalPoints: committedLineWidth,
            backingScale: backingScale
        )
        guard let formattedLineWidth = lineWidthFormatter.string(
            from: NSNumber(value: Double(displayedLineWidth))
        ) else {
            preconditionFailure("A valid annotation line width must be formattable for display.")
        }
        lineWidthField.stringValue = formattedLineWidth
    }
}

@MainActor
private final class PinnedToolStylePopoverController: NSViewController {
    static let maximumPreferredPopoverHeight: CGFloat = 48

    var onShapeFillModeChange: ((ShapeFillMode) -> Void)?
    var onArrowStyleChange: ((ArrowHeadStyle) -> Void)?

    let preferredPopoverSize: CGSize

    private enum Mode {
        case shape(selected: ShapeFillMode, shape: AnnotationTool)
        case arrow(selected: ArrowHeadStyle)
    }

    private let mode: Mode
    private let vectorRenderer = AnnotationVectorRenderer()

    init(shapeFillMode: ShapeFillMode, shape: AnnotationTool) {
        precondition(shape == .rectangle || shape == .ellipse)
        mode = .shape(selected: shapeFillMode, shape: shape)
        preferredPopoverSize = CGSize(width: 214, height: 48)
        super.init(nibName: nil, bundle: nil)
    }

    init(arrowHeadStyle: ArrowHeadStyle) {
        mode = .arrow(selected: arrowHeadStyle)
        preferredPopoverSize = CGSize(width: 354, height: 48)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let container = NSView(frame: CGRect(origin: .zero, size: preferredPopoverSize))
        container.setAccessibilityIdentifier("pinned.style.popover")
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7)
        ])

        switch mode {
        case .shape(let selected, let shape):
            for (tag, fillMode) in [ShapeFillMode.outline, .filled].enumerated() {
                let title = NSLocalizedString(
                    fillMode == .outline ? "Outline" : "Filled",
                    comment: "Shape fill option"
                )
                let button = optionButton(
                    title: title,
                    image: shapePreview(shape: shape, fillMode: fillMode),
                    selected: fillMode == selected,
                    action: #selector(selectShapeFillMode(_:)),
                    identifier: "pinned.style.shape.\(fillMode.rawValue)",
                    tag: tag
                )
                stack.addArrangedSubview(button)
            }
        case .arrow(let selected):
            let options: [(title: String, style: ArrowHeadStyle)] = [
                ("Solid Arrow", .filled),
                ("Line Arrow", .open),
                ("Tapered Arrow", .tapered)
            ]
            for (tag, option) in options.enumerated() {
                let title = NSLocalizedString(option.title, comment: "Arrow style option")
                let button = optionButton(
                    title: title,
                    image: arrowPreview(style: option.style),
                    selected: option.style == selected,
                    action: #selector(selectArrowStyle(_:)),
                    identifier: "pinned.style.arrow.\(option.style.rawValue)",
                    tag: tag
                )
                stack.addArrangedSubview(button)
            }
        }
        view = container
    }

    private func optionButton(
        title: String,
        image: NSImage,
        selected: Bool,
        action: Selector,
        identifier: String,
        tag: Int
    ) -> NSButton {
        let button = NSButton(title: title, image: image, target: self, action: action)
        button.tag = tag
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.toggle)
        button.state = selected ? .on : .off
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityValue(NSLocalizedString(
            selected ? "Selected" : "Not selected",
            comment: "Annotation style selection state"
        ))
        return button
    }

    private func shapePreview(shape: AnnotationTool, fillMode: ShapeFillMode) -> NSImage {
        var style = AnnotationStyle(strokeColor: .black, lineWidth: 2, cornerRadius: 2)
        style.shapeFillMode = fillMode
        let kind: AnnotationKind = shape == .ellipse ? .ellipse : .rectangle
        return previewImage(item: AnnotationItem(
            kind: kind,
            zIndex: 0,
            geometry: .rect(CGRect(x: 3, y: 3, width: 32, height: 12)),
            style: style
        ))
    }

    private func arrowPreview(style arrowHeadStyle: ArrowHeadStyle) -> NSImage {
        let style = AnnotationStyle(
            strokeColor: .black,
            lineWidth: 2,
            arrowHeadStyle: arrowHeadStyle
        )
        return previewImage(item: AnnotationItem(
            kind: .arrow,
            zIndex: 0,
            geometry: .line(start: CGPoint(x: 3, y: 3), end: CGPoint(x: 35, y: 15)),
            style: style
        ))
    }

    private func previewImage(item: AnnotationItem) -> NSImage {
        let size = CGSize(width: 38, height: 18)
        let image = NSImage(size: size, flipped: false) { [vectorRenderer] _ in
            guard let context = NSGraphicsContext.current?.cgContext,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            else { return false }
            return vectorRenderer.draw(
                item: item,
                in: context,
                colorSpace: colorSpace,
                canvasBounds: CGRect(origin: .zero, size: size)
            )
        }
        image.isTemplate = true
        return image
    }

    @objc private func selectShapeFillMode(_ sender: NSButton) {
        let options = [ShapeFillMode.outline, .filled]
        guard options.indices.contains(sender.tag) else {
            preconditionFailure("Unknown shape fill option tag \(sender.tag).")
        }
        onShapeFillModeChange?(options[sender.tag])
    }

    @objc private func selectArrowStyle(_ sender: NSButton) {
        let options = [ArrowHeadStyle.filled, .open, .tapered]
        guard options.indices.contains(sender.tag) else {
            preconditionFailure("Unknown arrow style option tag \(sender.tag).")
        }
        onArrowStyleChange?(options[sender.tag])
    }
}

private final class PinnedShotPayload: @unchecked Sendable {
    private var capturedImage: CapturedImage
    private let exporter: any ImageExporting
    private let lock = NSLock()
    private var cachedPNGData: Data?

    init(capturedImage: CapturedImage, exporter: any ImageExporting) {
        self.capturedImage = capturedImage
        self.exporter = exporter
    }

    func pngData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPNGData { return cachedPNGData }
        let data = try exporter.pngData(for: capturedImage.image)
        cachedPNGData = data
        return data
    }

    func currentImage() -> CapturedImage {
        lock.lock()
        defer { lock.unlock() }
        return capturedImage
    }

    func update(capturedImage: CapturedImage) {
        lock.lock()
        self.capturedImage = capturedImage
        cachedPNGData = nil
        lock.unlock()
    }

    func writePNG(to url: URL) throws {
        try pngData().write(to: url, options: .atomic)
    }

    func write(
        to url: URL,
        format: ExportFormat,
        preservesColorProfile: Bool
    ) throws {
        let image = currentImage().image
        try exporter.write(
            image,
            format: format,
            preservesColorProfile: preservesColorProfile,
            to: url
        )
    }

    func releaseCache() {
        lock.lock()
        cachedPNGData = nil
        lock.unlock()
    }
}

private enum FilePromiseLifecycleError {
    private static let domain = "\(ProductIdentity.bundleIdentifier).file-promise"

    static func concurrentDrag() -> NSError {
        NSError(
            domain: domain,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "Finish the current drag before starting another one."
                )
            ]
        )
    }

    static func duplicateWriteRequest() -> NSError {
        NSError(
            domain: domain,
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "The destination requested the same promised file more than once."
                )
            ]
        )
    }

    static func lifecycleEnded() -> NSError {
        NSError(
            domain: domain,
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "The promised file is no longer available because its drag ended."
                )
            ]
        )
    }
}

/// Coordinates the one callback that AppKit is allowed to issue from the
/// file-promise operation queue with the lifecycle decisions made on the main
/// actor. Sealing and callback registration are one atomic boundary, so a late
/// callback can be rejected without ever writing during an update transaction.
private final class FilePromiseCallbackRegistry: @unchecked Sendable {
    enum Registration {
        case accepted
        case duplicate
        case terminal
    }

    private enum State {
        case open
        case registered
        case terminal
    }

    private let lock = NSLock()
    private var state: State = .open

    func registerWriteCallback() -> Registration {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .open:
            state = .registered
            return .accepted
        case .registered:
            return .duplicate
        case .terminal:
            return .terminal
        }
    }

    /// Atomically closes a lifecycle only when no write callback has won the
    /// race. A `false` result means the registered callback now owns completion.
    func sealIfNoWriteCallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .open:
            state = .terminal
            return true
        case .registered:
            return false
        case .terminal:
            preconditionFailure("A file-promise callback registry cannot be sealed twice.")
        }
    }

    func sealAfterWriteCallback() {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .registered:
            state = .terminal
        case .open:
            preconditionFailure("A file-promise write cannot finish before its callback is registered.")
        case .terminal:
            preconditionFailure("A file-promise callback registry cannot finish twice.")
        }
    }

    var hasRegisteredWriteCallback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .registered
    }

    var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .terminal
    }
}

private final class FilePromiseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func finish(with error: Error?) {
        let completion: (Error?) -> Void
        lock.lock()
        guard let handler else {
            lock.unlock()
            preconditionFailure("A file-promise completion handler cannot be called more than once.")
        }
        completion = handler
        self.handler = nil
        lock.unlock()
        completion(error)
    }
}

@MainActor
private final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private enum WriteState {
        case notRequested
        case writing
        case finished
    }

    let identifier: UUID
    private let payload: PinnedShotPayload
    private let promisedFilename: String
    private let updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    private let callbackRegistry = FilePromiseCallbackRegistry()
    private let onFinished: @MainActor (UUID) -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "\(ProductIdentity.bundleIdentifier).file-promise"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private weak var draggingSession: NSDraggingSession?
    private var lease: UpdateSensitiveActivityTracker.Lease?
    private var lifecycleRetention: FilePromiseDelegate?
    private var dragEndedOperation: NSDragOperation?
    private var sourceCloseReason: String?
    private var forceSourceClose = false
    private var fileNameWasRequested = false
    private var writeState: WriteState = .notRequested
    private var isDeliveringWriteCompletion = false

    init(
        identifier: UUID,
        payload: PinnedShotPayload,
        filenameTemplate: String,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker,
        lease: UpdateSensitiveActivityTracker.Lease,
        onFinished: @escaping @MainActor (UUID) -> Void
    ) {
        self.identifier = identifier
        self.payload = payload
        self.promisedFilename = FilenameTemplateFormatter().filename(
            template: filenameTemplate,
            date: Date()
        )
        self.updateSensitiveActivityTracker = updateSensitiveActivityTracker
        self.lease = lease
        self.onFinished = onFinished
    }

    deinit {
        precondition(
            callbackRegistry.isTerminal,
            "A file-promise delegate must not deinitialize before its lifecycle is terminal."
        )
    }

    func armLifecycleRetention() {
        precondition(lifecycleRetention == nil, "A file-promise lifecycle may retain itself only once.")
        precondition(lease != nil, "A file-promise lifecycle must own a lease before it is armed.")
        lifecycleRetention = self
    }

    func bind(to session: NSDraggingSession) {
        precondition(draggingSession == nil, "A file-promise lifecycle may bind to only one drag session.")
        precondition(lease != nil, "A terminal file-promise lifecycle cannot bind to a drag session.")
        draggingSession = session
        AppLog.export.debug(
            "Bound external drag session: lifecycle=\(self.identifier.uuidString, privacy: .public)"
        )
    }

    func owns(_ session: NSDraggingSession) -> Bool {
        draggingSession === session
    }

    func draggingSessionDidEnd(operation: NSDragOperation) {
        guard dragEndedOperation == nil else {
            AppLog.export.fault(
                "Received duplicate external drag end callback: lifecycle=\(self.identifier.uuidString, privacy: .public), operation=\(operation.rawValue, privacy: .public)"
            )
            return
        }
        dragEndedOperation = operation
        AppLog.export.notice(
            "External drag session ended: lifecycle=\(self.identifier.uuidString, privacy: .public), operation=\(operation.rawValue, privacy: .public), fileNameRequested=\(self.fileNameWasRequested, privacy: .public), writeRegistered=\(self.callbackRegistry.hasRegisteredWriteCallback, privacy: .public)"
        )
        reconcileLifecycle(reason: "drag-ended")
    }

    func sourceWillClose(reason: String, force: Bool) {
        guard lease != nil else { return }
        guard sourceCloseReason == nil else {
            AppLog.export.fault(
                "Received duplicate source-close callback for external drag: lifecycle=\(self.identifier.uuidString, privacy: .public), previous=\(self.sourceCloseReason ?? "unknown", privacy: .public), current=\(reason, privacy: .public)"
            )
            return
        }
        sourceCloseReason = reason
        forceSourceClose = force
        AppLog.export.notice(
            "External drag source is closing: lifecycle=\(self.identifier.uuidString, privacy: .public), reason=\(reason, privacy: .public), forced=\(force, privacy: .public)"
        )
        reconcileLifecycle(reason: "source-close")
    }

    func dragSetupDidFail(_ error: Error) {
        guard lease != nil else {
            preconditionFailure("A terminal file-promise lifecycle cannot report a setup failure.")
        }
        let nsError = error as NSError
        AppLog.export.error(
            "External drag setup failed: lifecycle=\(self.identifier.uuidString, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
        )
        finishWithoutWrite(reason: "setup-failed")
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        guard lease != nil else {
            AppLog.export.fault(
                "Requested a filename from a terminal file-promise lifecycle: lifecycle=\(self.identifier.uuidString, privacy: .public)"
            )
            return promisedFilename
        }
        fileNameWasRequested = true
        AppLog.export.debug(
            "Requested external drag filename: lifecycle=\(self.identifier.uuidString, privacy: .public)"
        )
        return promisedFilename
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = FilePromiseCompletion(completionHandler)
        switch callbackRegistry.registerWriteCallback() {
        case .accepted:
            Task { @MainActor [self] in
                await performRegisteredWrite(to: url, completion: completion)
            }
        case .duplicate:
            AppLog.export.fault("Received duplicate file-promise write callback")
            completion.finish(with: FilePromiseLifecycleError.duplicateWriteRequest())
        case .terminal:
            AppLog.export.fault("Received file-promise write callback after lifecycle termination")
            completion.finish(with: FilePromiseLifecycleError.lifecycleEnded())
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    private func performRegisteredWrite(
        to url: URL,
        completion: FilePromiseCompletion
    ) async {
        guard lease != nil else {
            AppLog.export.fault(
                "A registered file-promise write reached a terminal lifecycle: lifecycle=\(self.identifier.uuidString, privacy: .public)"
            )
            completion.finish(with: FilePromiseLifecycleError.lifecycleEnded())
            return
        }
        guard writeState == .notRequested else {
            AppLog.export.fault(
                "A file-promise lifecycle attempted to start more than one write: lifecycle=\(self.identifier.uuidString, privacy: .public)"
            )
            completion.finish(with: FilePromiseLifecycleError.duplicateWriteRequest())
            return
        }

        writeState = .writing
        AppLog.export.notice(
            "Began pinned file-promise output: lifecycle=\(self.identifier.uuidString, privacy: .public)"
        )

        let writeError: Error?
        do {
            let payload = payload
            try await Task.detached {
                try payload.writePNG(to: url)
            }.value
            writeError = nil
            AppLog.export.notice(
                "Completed pinned file-promise output: lifecycle=\(self.identifier.uuidString, privacy: .public)"
            )
        } catch {
            writeError = error
            let nsError = error as NSError
            AppLog.export.error(
                "Pinned file-promise output failed: lifecycle=\(self.identifier.uuidString, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
            )
        }

        writeState = .finished
        isDeliveringWriteCompletion = true
        completion.finish(with: writeError)
        isDeliveringWriteCompletion = false
        reconcileLifecycle(reason: writeError == nil ? "write-completed" : "write-failed")
    }

    private func reconcileLifecycle(reason: String) {
        guard lease != nil else { return }
        guard !isDeliveringWriteCompletion else { return }

        switch writeState {
        case .writing:
            return
        case .finished:
            guard dragEndedOperation != nil || sourceCloseReason != nil else { return }
            finishAfterWrite(reason: reason)
        case .notRequested:
            if callbackRegistry.hasRegisteredWriteCallback {
                return
            }
            if forceSourceClose {
                finishWithoutWrite(reason: "forced-source-close")
                return
            }
            guard let dragEndedOperation else { return }
            if dragEndedOperation.isEmpty {
                finishWithoutWrite(reason: "cancelled-drag")
            } else if !fileNameWasRequested {
                finishWithoutWrite(reason: "drop-did-not-request-file-promise")
            } else if sourceCloseReason != nil {
                finishWithoutWrite(reason: "closed-while-awaiting-file-promise")
            } else {
                AppLog.export.notice(
                    "Retaining accepted file promise while awaiting its write callback: lifecycle=\(self.identifier.uuidString, privacy: .public)"
                )
            }
        }
    }

    private func finishWithoutWrite(reason: String) {
        guard lease != nil else {
            preconditionFailure("A file-promise lifecycle cannot finish more than once.")
        }
        guard callbackRegistry.sealIfNoWriteCallback() else {
            AppLog.export.debug(
                "A file-promise write callback won the lifecycle-finalization race: lifecycle=\(self.identifier.uuidString, privacy: .public), reason=\(reason, privacy: .public)"
            )
            return
        }
        finishLease(reason: reason)
    }

    private func finishAfterWrite(reason: String) {
        precondition(writeState == .finished, "Only a completed file-promise write may finish this path.")
        callbackRegistry.sealAfterWriteCallback()
        finishLease(reason: reason)
    }

    private func finishLease(reason: String) {
        guard let lease else {
            preconditionFailure("A file-promise lifecycle cannot release its update lease twice.")
        }
        updateSensitiveActivityTracker.finish(lease)
        self.lease = nil
        AppLog.export.notice(
            "Finished external drag lifecycle: lifecycle=\(self.identifier.uuidString, privacy: .public), reason=\(reason, privacy: .public)"
        )
        onFinished(identifier)
        lifecycleRetention = nil
    }
}
