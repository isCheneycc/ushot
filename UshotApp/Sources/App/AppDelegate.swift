import AppKit
import Combine
import UshotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updateSensitiveActivityTracker = UpdateSensitiveActivityTracker()
    private(set) var environment: AppEnvironment?
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var historyWindowController: HistoryWindowController?
    private var captureWorkflow: CaptureWorkflowCoordinator?
    private var pinnedShotManager: PinnedShotManager?
    private var canvasEditorManager: CanvasEditorManager?
    private var colorPickerCoordinator: ColorPickerCoordinator?
    private var screenRulerCoordinator: ScreenRulerCoordinator?
    private var cancellables: Set<AnyCancellable> = []
#if DEBUG
    private var uiTestRegionSelector: RegionSelectionCoordinator?
    private var uiTestRegionSelectionTask: Task<Void, Never>?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppKitDrawingFonts.prepare()
        do {
            let environment = try AppEnvironment.live()
            self.environment = environment
#if DEBUG
            let launchArguments = ProcessInfo.processInfo.arguments
            let isUITestLaunch = launchArguments.contains { $0.hasPrefix("--uitest-") }
            if launchArguments.contains("--uitest-reset-settings") {
                try environment.settingsStore.reset()
            }
            if isUITestLaunch {
                AppLog.lifecycle.debug("Skipping global hot-key registration for isolated UI testing")
            } else {
                try environment.hotKeyManager.register(environment.settingsStore.settings.shortcuts.assignments)
            }
#else
            try environment.hotKeyManager.register(environment.settingsStore.settings.shortcuts.assignments)
#endif
            environment.hotKeyManager.onAction = { [weak self] action in
                self?.handle(action)
            }

            let statusBarController = StatusBarController(
                updateChecker: environment.updateChecker
            )
            statusBarController.onAction = { [weak self] action in
                self?.handle(action)
            }
            statusBarController.onOpenSettings = { [weak self] in
                self?.showSettings(selecting: .general)
            }
            statusBarController.onOpenHistory = { [weak self] in
                self?.showHistory()
            }
            statusBarController.onCheckForUpdates = { [weak self] in
                self?.checkForUpdates()
            }
            self.statusBarController = statusBarController

            let pinnedShotManager = PinnedShotManager(
                settingsStore: environment.settingsStore,
                historyStore: environment.historyStore,
                updateSensitiveActivityTracker: updateSensitiveActivityTracker,
                admitAppWork: { [weak self] in
                    guard let self else {
                        throw UpdateCheckError.rejected(
                            reason: String(localized: "Ushot is shutting down and cannot start new work.")
                        )
                    }
                    try self.admitNewAppWork(action: "pinned-screenshot")
                }
            )
            let canvasEditorManager = CanvasEditorManager(
                settingsStore: environment.settingsStore,
                updateSensitiveActivityTracker: updateSensitiveActivityTracker
            )
            self.canvasEditorManager = canvasEditorManager
            pinnedShotManager.onError = { [weak self] error in
                self?.presentCaptureError(error)
            }
            pinnedShotManager.onOpenEditor = { [weak pinnedShotManager] session, leaseID in
                canvasEditorManager.open(
                    session: session,
                    ownershipID: leaseID,
                    onClose: { [weak pinnedShotManager] in
                        pinnedShotManager?.canvasEditorDidClose(session: session, leaseID: leaseID)
                    }
                )
            }
            self.pinnedShotManager = pinnedShotManager
            DispatchQueue.main.async { [weak pinnedShotManager] in
                pinnedShotManager?.prepareRegionDraftToolbar()
            }

            let captureWorkflow = CaptureWorkflowCoordinator(
                capturer: environment.capturer,
                permissionChecker: environment.permissionChecker,
                settingsStore: environment.settingsStore,
                pinnedShotManager: pinnedShotManager
            )
            captureWorkflow.onCaptured = { [weak self] result in
                self?.pinnedShotManager?.present(result)
            }
            captureWorkflow.onPermissionRequired = { [weak self] in
                self?.showSettings(selecting: .capture)
            }
            captureWorkflow.onError = { [weak self] error in
                self?.presentCaptureError(error)
            }
            self.captureWorkflow = captureWorkflow

            let colorPickerCoordinator = ColorPickerCoordinator(
                samplerFactory: environment.pixelSamplerFactory,
                permissionChecker: environment.permissionChecker,
                settingsStore: environment.settingsStore
            )
            colorPickerCoordinator.onPermissionRequired = { [weak self] in
                self?.showSettings(selecting: .capture)
            }
            colorPickerCoordinator.onError = { [weak self] error in
                self?.presentToolError(error, title: NSLocalizedString("Color Picker Failed", comment: "Color picker error title"))
            }
            self.colorPickerCoordinator = colorPickerCoordinator

            let screenRulerCoordinator = ScreenRulerCoordinator()
            screenRulerCoordinator.onError = { [weak self] error in
                self?.presentToolError(error, title: NSLocalizedString("Screen Ruler Failed", comment: "Screen ruler error title"))
            }
            self.screenRulerCoordinator = screenRulerCoordinator

            applyPresentation(settings: environment.settingsStore.settings)
            environment.settingsStore.$settings
                .sink { [weak self] settings in
                    self?.applyPresentation(settings: settings)
                }
                .store(in: &cancellables)

            let handledUITestScenario: Bool
#if DEBUG
            handledUITestScenario = try performUITestLaunchScenarioIfRequested(environment: environment)
#else
            handledUITestScenario = false
#endif
            if environment.settingsStore.loadError != nil {
                showSettings(selecting: .advanced)
            } else if !handledUITestScenario {
                performStartupBehavior(environment.settingsStore.settings.general.startupBehavior)
            }
            AppLog.lifecycle.notice("Ushot launched")
        } catch {
            presentFatalLaunchError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        colorPickerCoordinator?.cancel()
        screenRulerCoordinator?.cancel()
        pinnedShotManager?.closeForApplicationTermination()
        do {
            try environment?.hotKeyManager.unregisterAll()
        } catch {
            AppLog.hotKeys.fault("Hot keys could not be unregistered during termination: \(error.localizedDescription, privacy: .public)")
        }
        AppLog.lifecycle.notice("Ushot is terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func applyPresentation(settings: AppSettings) {
        let policy: NSApplication.ActivationPolicy = settings.general.showsDockIcon ? .regular : .accessory
        if NSApplication.shared.activationPolicy() != policy {
            NSApplication.shared.setActivationPolicy(policy)
        }
        statusBarController?.isVisible = settings.general.showsMenuBarIcon
        statusBarController?.rebuildMenu(
            shortcuts: settings.shortcuts.assignments,
            historyEnabled: settings.history.isEnabled
        )
    }

    private func handle(_ action: HotKeyAction) {
        do {
            try admitNewAppWork(action: String(describing: action))
        } catch {
            AppLog.updates.notice(
                "Rejected app action during an active update transaction: action=\(String(describing: action), privacy: .public)"
            )
            NSSound.beep()
            return
        }

        switch action {
        case .captureRegion, .captureWindow, .captureCurrentDisplay, .captureSelectedDisplay, .captureAllDisplays:
            colorPickerCoordinator?.cancel()
            screenRulerCoordinator?.cancel()
            captureWorkflow?.perform(action)
        case .colorPicker:
            screenRulerCoordinator?.cancel()
            colorPickerCoordinator?.start()
        case .screenRuler:
            colorPickerCoordinator?.cancel()
            screenRulerCoordinator?.start()
        }
    }

    private func showSettings(selecting section: SettingsSection) {
        guard let environment else { return }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(environment: environment)
        }
        settingsWindowController?.show(section: section)
    }

    private func showHistory() {
        guard let environment else { return }
        do {
            try admitNewAppWork(action: "show-history")
        } catch {
            presentUpdateError(error)
            return
        }
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController(
                store: environment.historyStore,
                settingsStore: environment.settingsStore,
                updateSensitiveActivityTracker: updateSensitiveActivityTracker,
                admitAppWork: { [weak self] in
                    guard let self else {
                        throw UpdateCheckError.rejected(
                            reason: String(localized: "Ushot is shutting down and cannot start new work.")
                        )
                    }
                    try self.admitNewAppWork(action: "history")
                },
                onOpenSession: { [weak self] session in
                    self?.canvasEditorManager?.open(session: session)
                }
            )
        }
        historyWindowController?.show()
    }

    private func checkForUpdates() {
        guard let updateChecker = environment?.updateChecker else {
            preconditionFailure("The update command cannot run before the app environment exists.")
        }
        do {
            try updateChecker.checkForUpdates { [weak self] in
                guard let self else {
                    throw UpdateCheckError.rejected(
                        reason: String(localized: "Ushot is shutting down and cannot check for updates.")
                    )
                }
                try self.admitUpdateCheck()
            }
        } catch {
            presentUpdateError(error)
        }
    }

    private func admitUpdateCheck() throws {
        let captureActive = captureWorkflow?.isSessionActive == true
        let colorPickerActive = colorPickerCoordinator?.isSessionActive == true
        let screenRulerActive = screenRulerCoordinator?.isSessionActive == true
        let editorActive = canvasEditorManager?.hasOpenEditors == true
        let historyActive = historyWindowController?.hasBlockingUpdateActivity == true
        let pinnedActivity = pinnedShotManager?.hasBlockingUpdateActivity == true
        let backgroundActivityCount = updateSensitiveActivityTracker.activeOperationCount

        guard
            !captureActive,
            !colorPickerActive,
            !screenRulerActive,
            !editorActive,
            !historyActive,
            !pinnedActivity,
            backgroundActivityCount == 0
        else {
            AppLog.updates.notice(
                "Rejected update check while app work is active: capture=\(captureActive, privacy: .public), colorPicker=\(colorPickerActive, privacy: .public), screenRuler=\(screenRulerActive, privacy: .public), editor=\(editorActive, privacy: .public), history=\(historyActive, privacy: .public), pinnedActivity=\(pinnedActivity, privacy: .public), backgroundActivities=\(backgroundActivityCount, privacy: .public)"
            )
            throw UpdateCheckError.rejected(
                reason: String(
                    localized: "Finish or close the active capture, editing, or output task before checking for updates."
                )
            )
        }
    }

    private func admitNewAppWork(action: String) throws {
        guard environment?.updateChecker.isSessionActive != true else {
            AppLog.updates.notice(
                "Rejected new app work during an update transaction: action=\(action, privacy: .public)"
            )
            throw UpdateCheckError.rejected(
                reason: String(
                    localized: "An update is in progress. Finish it before starting another task."
                )
            )
        }
    }

    private func performStartupBehavior(_ behavior: StartupBehavior) {
        switch behavior {
        case .doNothing:
            break
        case .openSettings:
            showSettings(selecting: .general)
        case .openHistory:
            showHistory()
        }
    }

#if DEBUG
    private func performUITestLaunchScenarioIfRequested(
        environment: AppEnvironment
    ) throws -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitest-settings")
            || arguments.contains("--uitest-settings-editor")
            || arguments.contains("--uitest-settings-shortcuts") {
            let section: SettingsSection
            if arguments.contains("--uitest-settings-editor") {
                section = .editor
            } else if arguments.contains("--uitest-settings-shortcuts") {
                section = .shortcuts
            } else {
                section = .general
            }
            showSettings(selecting: section)
            return true
        }
        if arguments.contains("--uitest-editor") {
            let captured = try makeUITestCapturedImage(
                logicalSize: CGSize(width: 320, height: 200),
                desktopFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
                displayID: CGMainDisplayID(),
                scale: 1
            )
            canvasEditorManager?.open(session: AnnotationEditingSession(
                capturedImage: captured,
                editorSettings: environment.settingsStore.settings.editor,
                updateSensitiveActivityTracker: updateSensitiveActivityTracker
            ))
            return true
        }
        if arguments.contains("--uitest-editor-selection-invalidation") {
            let captured = try makeUITestCapturedImage(
                logicalSize: CGSize(width: 320, height: 200),
                desktopFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
                displayID: CGMainDisplayID(),
                scale: 1
            )
            let session = AnnotationEditingSession(
                capturedImage: captured,
                editorSettings: environment.settingsStore.settings.editor,
                updateSensitiveActivityTracker: updateSensitiveActivityTracker
            )
            session.controller.add(AnnotationItem(
                kind: .rectangle,
                zIndex: 0,
                geometry: .rect(CGRect(x: 40, y: 36, width: 120, height: 80))
            ))
            canvasEditorManager?.open(session: session)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                AppLog.capture.notice(
                    "UI regression removing the selected annotation while its inspector is mounted"
                )
                session.controller.undo()
            }
            return true
        }
        if arguments.contains("--uitest-region-selection") {
            try startUITestRegionSelection()
            return true
        }
        if arguments.contains("--uitest-color-picker-first-nudge") {
            try startUITestColorPicker(
                environment: environment,
                usesDeterministicFirstNudgeFixture: true,
                holdsInitialSampleUntilFirstNudge: true
            )
            return true
        }
        if arguments.contains("--uitest-color-picker-visible-first-nudge") {
            try startUITestColorPicker(
                environment: environment,
                usesDeterministicFirstNudgeFixture: true
            )
            return true
        }
        if arguments.contains("--uitest-color-picker") {
            try startUITestColorPicker(environment: environment)
            return true
        }
        if arguments.contains("--uitest-line-width-routing") {
            let captured = try makeUITestCapturedImage(
                logicalSize: CGSize(width: 320, height: 200),
                desktopFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
                displayID: CGMainDisplayID(),
                scale: 1
            )
            pinnedShotManager?.present(.image(captured))
            DispatchQueue.main.async { [weak self] in
                guard let manager = self?.pinnedShotManager else {
                    preconditionFailure("Line-width routing UI regression lost its pinned-shot manager.")
                }
                manager.runLineWidthRoutingRegression()
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
            return true
        }
        if arguments.contains("--uitest-inline-text-stability") {
            let captured = try makeUITestCapturedImage(
                logicalSize: CGSize(width: 620, height: 360),
                desktopFrame: CGRect(x: 0, y: 0, width: 620, height: 360),
                displayID: CGMainDisplayID(),
                scale: 1
            )
            pinnedShotManager?.present(.image(captured))
            DispatchQueue.main.async { [weak self] in
                guard let manager = self?.pinnedShotManager else {
                    preconditionFailure("Inline text stability UI regression lost its pinned-shot manager.")
                }
                manager.runInlineTextStabilityRegression()
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
            return true
        }
        if arguments.contains("--uitest-inline-text-resize") {
            let captured = try makeUITestCapturedImage(
                logicalSize: CGSize(width: 620, height: 360),
                desktopFrame: CGRect(x: 0, y: 0, width: 620, height: 360),
                displayID: CGMainDisplayID(),
                scale: 1
            )
            pinnedShotManager?.present(.image(captured))
            DispatchQueue.main.async { [weak self] in
                guard let manager = self?.pinnedShotManager else {
                    preconditionFailure("Inline text resize UI testing lost its pinned-shot manager.")
                }
                manager.prepareInlineTextResizeUITest()
            }
            return true
        }
        if arguments.contains("--uitest-pinned-cursor-press") {
            let captured = try makeUITestCapturedImage(
                logicalSize: CGSize(width: 320, height: 200),
                desktopFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
                displayID: CGMainDisplayID(),
                scale: 1
            )
            pinnedShotManager?.present(.image(captured))
            DispatchQueue.main.async { [weak self] in
                guard let manager = self?.pinnedShotManager else {
                    preconditionFailure("Pinned cursor UI regression lost its pinned-shot manager.")
                }
                manager.runReadOnlyWindowPressCursorRegression()
            }
            return true
        }
        if arguments.contains("--uitest-pinned-lifecycle") {
            let displayID = CGMainDisplayID()
            let first = try makeUITestCapturedImage(
                logicalSize: CGSize(width: 340, height: 210),
                desktopFrame: CGRect(x: 0, y: 0, width: 340, height: 210),
                displayID: displayID,
                scale: 1
            )
            let replacement = try makeUITestCapturedImage(
                logicalSize: CGSize(width: 260, height: 160),
                desktopFrame: CGRect(x: 0, y: 0, width: 260, height: 160),
                displayID: displayID,
                scale: 1
            )
            pinnedShotManager?.present(.image(first))
            pinnedShotManager?.present(.image(replacement))
            return true
        }
        return false
    }

    private func startUITestColorPicker(
        environment: AppEnvironment,
        usesDeterministicFirstNudgeFixture: Bool = false,
        holdsInitialSampleUntilFirstNudge: Bool = false
    ) throws {
        guard
            let screen = NSScreen.main ?? NSScreen.screens.first,
            let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            throw ScreenshotAppError.noDisplayAvailable
        }
        let displayID = displayNumber.uint32Value
        let scale: CGFloat = usesDeterministicFirstNudgeFixture
            ? 2
            : max(1, screen.backingScaleFactor)
        let pixelWidth = max(1, Int((screen.frame.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((screen.frame.height * scale).rounded(.up)))
        let initialPixelX = min(max(5, pixelWidth / 2), max(0, pixelWidth - 6))
        let initialPixelY = min(max(5, pixelHeight / 2), max(0, pixelHeight - 6))
        let adjacentColorColumns: (red: Int, blue: Int)? = usesDeterministicFirstNudgeFixture
            ? (red: initialPixelX, blue: initialPixelX + 1)
            : nil
        let captured = try makeUITestCapturedImage(
            logicalSize: screen.frame.size,
            desktopFrame: screen.frame,
            displayID: displayID,
            scale: scale,
            adjacentColorColumns: adjacentColorColumns
        )
        let descriptor = DisplayDescriptor(
            id: displayID,
            name: "UI Test UltraWide Display",
            frame: screen.frame,
            pixelSize: captured.pixelSize,
            scale: scale,
            isCurrent: true
        )
        let frozenSampler = try FrozenFramePixelSampler(preparation: RegionCapturePreparation(
            displays: [DisplayCapture(descriptor: descriptor, capturedImage: captured)],
            windows: []
        ))
        let sampler: any PixelSampling
        let controlledSampler: UITestControlledPixelSampler?
        if holdsInitialSampleUntilFirstNudge {
            let controller = UITestControlledPixelSampler(sampler: frozenSampler)
            controlledSampler = controller
            sampler = controller
        } else {
            controlledSampler = nil
            sampler = frozenSampler
        }
        let initialPoint = CGPoint(
            x: screen.frame.minX + (CGFloat(initialPixelX) + 0.5) / scale,
            y: screen.frame.maxY - (CGFloat(initialPixelY) + 0.5) / scale
        )
        let cursorController: any ColorPickerCursorControlling
        let uiTestCursorController: UITestColorPickerCursorController?
        if usesDeterministicFirstNudgeFixture {
            let controller = UITestColorPickerCursorController(
                location: initialPoint,
                expectedFirstDisplayID: displayID,
                expectedFirstDisplayLocalPoint: CGPoint(
                    x: (CGFloat(initialPixelX + 1) + 0.5) / scale,
                    y: (CGFloat(initialPixelY) + 0.5) / scale
                )
            )
            uiTestCursorController = controller
            cursorController = controller
        } else {
            uiTestCursorController = nil
            cursorController = SystemColorPickerCursorController()
        }
        let coordinator = ColorPickerCoordinator(
            samplerFactory: UITestPixelSamplerFactory(sampler: sampler),
            permissionChecker: UITestAuthorizedCapturePermissionChecker(),
            settingsStore: environment.settingsStore,
            cursorController: cursorController
        )
        uiTestCursorController?.onFirstMove = { [weak coordinator] in
            coordinator?.injectPointerMoveForUITesting(
                to: initialPoint,
                eventTimestamp: -1
            )
            controlledSampler?.releaseFirstRequest()
        }
        coordinator.onPermissionRequired = {
            preconditionFailure("The isolated color-picker UI test unexpectedly requested capture permission.")
        }
        coordinator.onError = { [weak self] error in
            self?.presentToolError(error, title: "Color Picker UI Test Failed")
        }
        colorPickerCoordinator?.cancel()
        colorPickerCoordinator = coordinator
        coordinator.start()
    }

    private func startUITestRegionSelection() throws {
        guard let pinnedShotManager,
              let screen = NSScreen.main ?? NSScreen.screens.first,
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            throw ScreenshotAppError.noDisplayAvailable
        }
        let displayID = displayNumber.uint32Value
        let captured = try makeUITestCapturedImage(
            logicalSize: screen.frame.size,
            desktopFrame: screen.frame,
            displayID: displayID,
            scale: 2
        )
        let descriptor = DisplayDescriptor(
            id: displayID,
            name: "UI Test Display",
            frame: screen.frame,
            pixelSize: captured.pixelSize,
            scale: captured.scale,
            isCurrent: true
        )
        let syntheticWindowFrame = CGRect(
            x: screen.frame.minX + screen.frame.width * 0.18,
            y: screen.frame.minY + screen.frame.height * 0.20,
            width: screen.frame.width * 0.52,
            height: screen.frame.height * 0.48
        ).integral
        let preparation = RegionCapturePreparation(
            displays: [DisplayCapture(
                descriptor: descriptor,
                capturedImage: captured
            )],
            windows: [WindowDescriptor(
                id: 9_001,
                title: "UI Test Snap Window",
                applicationName: "UI Test Host",
                frame: syntheticWindowFrame,
                layer: 0
            )]
        )
        let selector = RegionSelectionCoordinator(pinnedShotManager: pinnedShotManager)
        uiTestRegionSelector = selector
        uiTestRegionSelectionTask = Task { @MainActor [weak self, selector] in
            defer {
                self?.uiTestRegionSelector = nil
                self?.uiTestRegionSelectionTask = nil
            }
            do {
                _ = try await selector.select(from: preparation)
            } catch ScreenshotAppError.captureCancelled {
                AppLog.capture.notice("UI-test region selection cancelled")
            } catch {
                self?.presentCaptureError(error)
            }
        }
    }

    private func makeUITestCapturedImage(
        logicalSize: CGSize,
        desktopFrame: CGRect,
        displayID: CGDirectDisplayID,
        scale: CGFloat,
        adjacentColorColumns: (red: Int, blue: Int)? = nil
    ) throws -> CapturedImage {
        let pixelSize = CGSize(
            width: logicalSize.width * scale,
            height: logicalSize.height * scale
        )
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: max(1, Int(pixelSize.width.rounded(.up))),
                height: max(1, Int(pixelSize.height.rounded(.up))),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw ScreenshotAppError.captureFailed(
                description: "The UI-test canvas context could not be created."
            )
        }
        context.setFillColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        if let adjacentColorColumns {
            guard adjacentColorColumns.red >= 0,
                  adjacentColorColumns.blue < context.width
            else {
                throw ScreenshotAppError.captureFailed(
                    description: "The color-picker UI-test columns are outside the fixture image."
                )
            }
            context.setShouldAntialias(false)
            context.setBlendMode(.copy)
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(
                x: CGFloat(adjacentColorColumns.red),
                y: 0,
                width: 1,
                height: CGFloat(context.height)
            ))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(
                x: CGFloat(adjacentColorColumns.blue),
                y: 0,
                width: 1,
                height: CGFloat(context.height)
            ))
        }
        guard let image = context.makeImage() else {
            throw ScreenshotAppError.captureFailed(
                description: "The UI-test canvas image could not be created."
            )
        }
        return CapturedImage(
            image: image,
            colorSpace: image.colorSpace,
            pixelSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
            logicalSize: logicalSize,
            scale: scale,
            sourceMetadata: CaptureSourceMetadata(
                kind: .display,
                displayIDs: [displayID],
                windowID: nil,
                desktopFrame: desktopFrame
            )
        )
    }
#endif

    private func presentCaptureError(_ error: Error) {
        AppLog.capture.error("Capture workflow failed: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert(error: error)
        alert.messageText = NSLocalizedString("Screenshot Failed", comment: "Screenshot error title")
        alert.alertStyle = .critical
        alert.layout()
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        alert.window.hidesOnDeactivate = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        AppLog.capture.notice(
            "Presenting capture failure above capture surfaces: level=\(alert.window.level.rawValue, privacy: .public), inputTransactionReleased=true"
        )
        alert.runModal()
    }

    private func presentToolError(_ error: Error, title: String) {
        AppLog.lifecycle.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }

    private func presentUpdateError(_ error: Error) {
        let nsError = error as NSError
        AppLog.updates.error(
            "Update check was not started: domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
        )
        let alert = NSAlert(error: error)
        alert.messageText = String(localized: "Unable to Check for Updates")
        alert.alertStyle = .warning
        alert.layout()
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        alert.window.hidesOnDeactivate = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentFatalLaunchError(_ error: Error) {
        AppLog.lifecycle.fault("Application startup failed: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert(error: error)
        alert.messageText = NSLocalizedString("Ushot could not start", comment: "Fatal startup error title")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}

#if DEBUG
@MainActor
private final class UITestPixelSamplerFactory: PixelSamplerCreating {
    private let sampler: any PixelSampling

    init(sampler: any PixelSampling) {
        self.sampler = sampler
    }

    func makePixelSampler() async throws -> any PixelSampling {
        sampler
    }
}

@MainActor
private final class UITestControlledPixelSampler: PixelSampling {
    private let sampler: any PixelSampling
    private var requestCount = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private var firstRequestWasReleased = false

    var displays: [DisplayDescriptor] { sampler.displays }

    init(sampler: any PixelSampling) {
        self.sampler = sampler
    }

    func releaseFirstRequest() {
        firstRequestWasReleased = true
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    func sampleFrame(
        at globalPoint: CGPoint,
        colorSpace: ColorSpacePreference,
        radius: Int
    ) async throws -> PixelSampleFrame {
        requestCount += 1
        if requestCount == 1 {
            if !firstRequestWasReleased {
                await withCheckedContinuation { continuation in
                    firstRequestContinuation = continuation
                }
            }
        } else {
            try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000)
        }
        return try await sampler.sampleFrame(
            at: globalPoint,
            colorSpace: colorSpace,
            radius: radius
        )
    }
}

@MainActor
private final class UITestColorPickerCursorController: ColorPickerCursorControlling {
    let location: CGPoint
    var onFirstMove: (@MainActor @Sendable () -> Void)?

    private let expectedFirstDisplayID: CGDirectDisplayID
    private let expectedFirstDisplayLocalPoint: CGPoint
    private var moveCount = 0

    init(
        location: CGPoint,
        expectedFirstDisplayID: CGDirectDisplayID,
        expectedFirstDisplayLocalPoint: CGPoint
    ) {
        self.location = location
        self.expectedFirstDisplayID = expectedFirstDisplayID
        self.expectedFirstDisplayLocalPoint = expectedFirstDisplayLocalPoint
    }

    func move(
        to displayLocalPoint: CGPoint,
        on displayID: CGDirectDisplayID
    ) -> CGError {
        moveCount += 1
        if moveCount == 1 {
            precondition(
                displayID == expectedFirstDisplayID,
                "The first color-picker nudge targeted the wrong display."
            )
            precondition(
                abs(displayLocalPoint.x - expectedFirstDisplayLocalPoint.x) < 0.000_1
                    && abs(displayLocalPoint.y - expectedFirstDisplayLocalPoint.y) < 0.000_1,
                "The first color-picker nudge did not target the adjacent physical-pixel center."
            )
            if let onFirstMove {
                self.onFirstMove = nil
                DispatchQueue.main.async(execute: onFirstMove)
            }
        }
        return .success
    }
}

private struct UITestAuthorizedCapturePermissionChecker: CapturePermissionChecking {
    func authorizationStatus() async -> CapturePermissionStatus { .authorized }
    func requestAccess() async -> CapturePermissionStatus { .authorized }
}
#endif
