import AppKit
import UshotCore

@MainActor
final class CaptureWorkflowCoordinator {
    var onCaptured: ((CaptureResult, CaptureFocusRestoration) -> Void)?
    var onPermissionRequired: (() -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var isSessionActive = false

    private let capturer: any ScreenCapturing
    private let permissionChecker: any CapturePermissionChecking
    private let settingsStore: SettingsStore
    private let pinnedShotManager: PinnedShotManager
    private let stateMachine: CaptureStateMachine
    private let displaySelector: DisplaySelectionCoordinator
    private let windowSelector: WindowSelectionCoordinator
    private let regionSelector: RegionSelectionCoordinator
    private let activeApplicationTracker: ActiveApplicationTracker
    /// Visible ordinary Ushot windows (Settings) that captures may include.
    private let ownInterfaceWindowIDs: @MainActor () -> Set<CGWindowID>

    init(
        capturer: any ScreenCapturing,
        permissionChecker: any CapturePermissionChecking,
        settingsStore: SettingsStore,
        pinnedShotManager: PinnedShotManager,
        ownInterfaceWindowIDs: @escaping @MainActor () -> Set<CGWindowID> = { [] },
        activeApplicationTracker: ActiveApplicationTracker? = nil,
        stateMachine: CaptureStateMachine = CaptureStateMachine()
    ) {
        self.capturer = capturer
        self.permissionChecker = permissionChecker
        self.settingsStore = settingsStore
        self.pinnedShotManager = pinnedShotManager
        self.ownInterfaceWindowIDs = ownInterfaceWindowIDs
        self.activeApplicationTracker = activeApplicationTracker ?? ActiveApplicationTracker()
        self.stateMachine = stateMachine
        self.displaySelector = DisplaySelectionCoordinator()
        self.windowSelector = WindowSelectionCoordinator()
        self.regionSelector = RegionSelectionCoordinator(pinnedShotManager: pinnedShotManager)
    }

    func perform(_ action: HotKeyAction) {
        guard let mode = captureMode(for: action) else { return }
        guard !isSessionActive else {
            AppLog.capture.notice(
                "Ignored repeated capture request before enqueue without disturbing the active session: requested=\(String(describing: mode), privacy: .public)"
            )
            NSSound.beep()
            return
        }
        let focusRestoration = CaptureFocusRestoration()
        // Sample the smart-snap scope synchronously with the focus handoff so
        // it describes the app that was active when the user asked to capture.
        let snapScope = activeApplicationTracker.smartSnapScope(
            frontmostProcessID: focusRestoration.frontmostProcessID
        )
        isSessionActive = true
        Task { await run(mode: mode, focusRestoration: focusRestoration, snapScope: snapScope) }
    }

    private func run(
        mode: CaptureMode,
        focusRestoration: CaptureFocusRestoration,
        snapScope: SmartSnapScope
    ) async {
        precondition(isSessionActive, "A capture task must own admission before it is enqueued.")
        defer { isSessionActive = false }

        let admission = await stateMachine.admit(mode: mode)
        guard case .accepted = admission else {
            guard case .rejected(let activeState) = admission else {
                preconditionFailure("Capture admission must be accepted or identify the active session.")
            }
            AppLog.capture.notice(
                "Ignored repeated capture request without disturbing the active session: requested=\(String(describing: mode), privacy: .public), activeState=\(String(describing: activeState), privacy: .public)"
            )
            NSSound.beep()
            return
        }
        AppLog.capture.notice(
            "Capture request admitted: mode=\(String(describing: mode), privacy: .public)"
        )
        do {
            guard await permissionChecker.authorizationStatus() == .authorized else {
                await stateMachine.cancel()
                onPermissionRequired?()
                return
            }
            try await stateMachine.permissionGranted()

            let captureSettings = settingsStore.settings.capture
            var request = CaptureRequest(
                mode: mode,
                showsCursor: captureSettings.capturesCursor,
                includesWindowShadow: captureSettings.includesWindowShadow,
                excludesOwnApplication: true,
                includedOwnWindowIDs: pinnedShotManager.captureWindowIDs,
                includedOwnInterfaceWindowIDs: ownInterfaceWindowIDs()
            )
            AppLog.capture.notice(
                "Capture sources prepared: includedPinnedImages=\(request.includedOwnWindowIDs.count, privacy: .public), includedInterfaceWindows=\(request.includedOwnInterfaceWindowIDs.count, privacy: .public)"
            )
            let result: CaptureResult

            switch mode {
            case .currentDisplay, .allDisplays:
                try await stateMachine.contentPrepared(requiresSelection: false)
                result = try await capturer.capture(request)

            case .selectedDisplay:
                let displays = try await capturer.discoverDisplays()
                try await stateMachine.contentPrepared(requiresSelection: true)
                request.targetDisplayID = try await displaySelector.select(from: displays)
                try await stateMachine.selectionCompleted()
                result = try await capturer.capture(request)

            case .window:
                let targets = try await capturer.discoverTargets(
                    includingOwnWindowIDs: request.includedOwnWindowIDs,
                    includingOwnInterfaceWindowIDs: request.includedOwnInterfaceWindowIDs
                )
                try await stateMachine.contentPrepared(requiresSelection: true)
                request.targetWindowID = try await windowSelector.select(from: targets.windows)
                try await stateMachine.selectionCompleted()
                result = try await capturer.capture(request)

            case .region:
                let preparation = try await capturer.prepareRegionCapture(request)
                try await stateMachine.contentPrepared(requiresSelection: true)
                _ = try await regionSelector.select(
                    from: preparation,
                    recognizesInterfaceElements: captureSettings.recognizesInterfaceElements,
                    snapScope: snapScope,
                    focusRestoration: focusRestoration
                )
                try await stateMachine.selectionCompleted()
                try await stateMachine.imageCaptured()
                await stateMachine.finish()
                return
            }

            try await stateMachine.imageCaptured()
            onCaptured?(result, focusRestoration)
            await stateMachine.finish()
        } catch ScreenshotAppError.captureCancelled {
            await stateMachine.cancel()
            focusRestoration.restore(reason: "selection-cancelled")
        } catch {
            await stateMachine.fail(error)
            onError?(error)
            focusRestoration.restore(reason: "capture-error-dismissed")
        }
    }

    private func captureMode(for action: HotKeyAction) -> CaptureMode? {
        switch action {
        case .captureRegion: return .region
        case .captureWindow: return .window
        case .captureCurrentDisplay: return .currentDisplay
        case .captureSelectedDisplay: return .selectedDisplay
        case .captureAllDisplays: return .allDisplays
        case .colorPicker, .screenRuler: return nil
        }
    }
}

/// One capture owns the app that was active before any overlay or editor was
/// shown. Its presentation retains this handoff until the screenshot closes.
@MainActor
final class CaptureFocusRestoration {
    private let application: NSRunningApplication?
    private weak var window: NSWindow?
    private var didFinish = false

    init() {
        application = NSWorkspace.shared.frontmostApplication
        if application?.processIdentifier == NSRunningApplication.current.processIdentifier {
            window = NSApplication.shared.keyWindow
        }
    }

    /// The application that was frontmost when this capture was requested.
    var frontmostProcessID: pid_t? {
        application?.processIdentifier
    }

    func discard(reason: String) {
        guard !didFinish else { return }
        didFinish = true
        AppLog.capture.notice(
            "Discarded capture focus restoration: reason=\(reason, privacy: .public)"
        )
    }

    func restore(reason: String) {
        guard !didFinish else { return }
        didFinish = true
        guard let application, !application.isTerminated else {
            AppLog.capture.notice(
                "Skipped capture focus restoration: reason=\(reason, privacy: .public), target=unavailable"
            )
            return
        }
        let current = NSRunningApplication.current
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPID == current.processIdentifier
                || frontmostPID == application.processIdentifier
        else {
            AppLog.capture.notice(
                "Skipped capture focus restoration after another app became active: reason=\(reason, privacy: .public)"
            )
            return
        }
        if application.processIdentifier == current.processIdentifier {
            if let window, window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard frontmostPID != application.processIdentifier || NSApplication.shared.isActive else {
            return
        }
        NSApplication.shared.yieldActivation(to: application)
        let accepted = application.activate(from: current, options: [])
        if accepted {
            AppLog.capture.notice(
                "Requested capture focus restoration: reason=\(reason, privacy: .public), targetPID=\(application.processIdentifier, privacy: .public)"
            )
        } else {
            AppLog.capture.error(
                "Capture focus restoration was rejected: reason=\(reason, privacy: .public), targetPID=\(application.processIdentifier, privacy: .public)"
            )
        }
    }
}

/// Remembers the most recent frontmost application other than Ushot.
///
/// Presenting a pinned image activates Ushot, so a capture started right after
/// Pin would otherwise find Ushot frontmost and lose the app the user was
/// working in. Smart snapping then covers that previous app plus Ushot's own
/// admitted windows.
@MainActor
final class ActiveApplicationTracker {
    private let ownProcessID: pid_t
    private var previousApplication: NSRunningApplication?
    private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(workspace: NSWorkspace = .shared) {
        notificationCenter = workspace.notificationCenter
        let ownProcessID = NSRunningApplication.current.processIdentifier
        self.ownProcessID = ownProcessID
        if let frontmost = workspace.frontmostApplication,
           frontmost.processIdentifier != ownProcessID
        {
            previousApplication = frontmost
        }
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self,
                      let application,
                      application.processIdentifier != self.ownProcessID
                else { return }
                self.previousApplication = application
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    func smartSnapScope(frontmostProcessID: pid_t?) -> SmartSnapScope {
        let previousProcessID = previousApplication.flatMap { application in
            application.isTerminated ? nil : application.processIdentifier
        }
        let scope = SmartSnapScope.resolve(
            frontmostProcessID: frontmostProcessID,
            ownProcessID: ownProcessID,
            previousApplicationProcessID: previousProcessID
        )
        AppLog.capture.notice(
            "Smart snap scope resolved: origin=\(scope.origin.rawValue, privacy: .public), applications=\(scope.applicationProcessIDs.count, privacy: .public), ownInterfaceWindows=\(scope.includesOwnInterfaceWindows, privacy: .public)"
        )
        return scope
    }
}
