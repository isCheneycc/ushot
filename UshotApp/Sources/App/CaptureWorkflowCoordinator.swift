import AppKit
import UshotCore

@MainActor
final class CaptureWorkflowCoordinator {
    var onCaptured: ((CaptureResult) -> Void)?
    var onPermissionRequired: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let capturer: any ScreenCapturing
    private let permissionChecker: any CapturePermissionChecking
    private let settingsStore: SettingsStore
    private let stateMachine: CaptureStateMachine
    private let displaySelector: DisplaySelectionCoordinator
    private let windowSelector: WindowSelectionCoordinator
    private let regionSelector: RegionSelectionCoordinator

    init(
        capturer: any ScreenCapturing,
        permissionChecker: any CapturePermissionChecking,
        settingsStore: SettingsStore,
        pinnedShotManager: PinnedShotManager,
        stateMachine: CaptureStateMachine = CaptureStateMachine()
    ) {
        self.capturer = capturer
        self.permissionChecker = permissionChecker
        self.settingsStore = settingsStore
        self.stateMachine = stateMachine
        self.displaySelector = DisplaySelectionCoordinator()
        self.windowSelector = WindowSelectionCoordinator()
        self.regionSelector = RegionSelectionCoordinator(pinnedShotManager: pinnedShotManager)
    }

    func perform(_ action: HotKeyAction) {
        guard let mode = captureMode(for: action) else { return }
        Task { await run(mode: mode) }
    }

    private func run(mode: CaptureMode) async {
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
                excludesOwnApplication: true
            )
            let result: CaptureResult

            switch mode {
            case .currentDisplay, .allDisplays:
                try await stateMachine.contentPrepared(requiresSelection: false)
                result = try await capturer.capture(request)

            case .selectedDisplay:
                let targets = try await capturer.discoverTargets()
                try await stateMachine.contentPrepared(requiresSelection: true)
                request.targetDisplayID = try await displaySelector.select(from: targets.displays)
                try await stateMachine.selectionCompleted()
                result = try await capturer.capture(request)

            case .window:
                let targets = try await capturer.discoverTargets()
                try await stateMachine.contentPrepared(requiresSelection: true)
                request.targetWindowID = try await windowSelector.select(from: targets.windows)
                try await stateMachine.selectionCompleted()
                result = try await capturer.capture(request)

            case .region:
                let preparation = try await capturer.prepareRegionCapture(request)
                try await stateMachine.contentPrepared(requiresSelection: true)
                _ = try await regionSelector.select(
                    from: preparation,
                    recognizesInterfaceElements: captureSettings.recognizesInterfaceElements
                )
                try await stateMachine.selectionCompleted()
                try await stateMachine.imageCaptured()
                await stateMachine.finish()
                return
            }

            try await stateMachine.imageCaptured()
            onCaptured?(result)
            await stateMachine.finish()
        } catch ScreenshotAppError.captureCancelled {
            await stateMachine.cancel()
        } catch {
            await stateMachine.fail(error)
            onError?(error)
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
