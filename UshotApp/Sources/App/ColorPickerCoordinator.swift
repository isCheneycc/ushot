import AppKit
import CoreGraphics
import UshotCore

@MainActor
protocol ColorPickerCursorControlling: AnyObject {
    var location: CGPoint { get }

    func move(
        to displayLocalPoint: CGPoint,
        on displayID: CGDirectDisplayID
    ) -> CGError
}

@MainActor
final class SystemColorPickerCursorController: ColorPickerCursorControlling {
    var location: CGPoint { NSEvent.mouseLocation }

    func move(
        to displayLocalPoint: CGPoint,
        on displayID: CGDirectDisplayID
    ) -> CGError {
        CGDisplayMoveCursorToPoint(displayID, displayLocalPoint)
    }
}

@MainActor
final class ColorPickerCoordinator {
    private static let captureRadius = 128
    private static let presentationRadius = 5

    var onPermissionRequired: (() -> Void)?
    var onError: ((Error) -> Void)?
    var isSessionActive: Bool {
        isPreparing || !panels.isEmpty || preparationTask != nil || samplingTask != nil
    }

    private let samplerFactory: any PixelSamplerCreating
    private let permissionChecker: any CapturePermissionChecking
    private let settingsStore: SettingsStore
    private let cursorController: any ColorPickerCursorControlling
    private var isPreparing = false
    private var sessionGeneration = 0
    private var sampleGeneration = 0
    private var completionGeneration: Int?
    private var preparationTask: Task<Void, Never>?
    private var samplingTask: Task<Void, Never>?
    private var keyboardMonitor: Any?
    private var panels: [PixelToolOverlayPanel] = []
    private var views: [ColorPickerOverlayView] = []
    private var sampler: (any PixelSampling)?
    private var currentPoint: CGPoint?
    private var currentSample: ColorSample?
    private var currentMagnifier: PixelMagnifier?
    private var requestedSample: ColorPickerSampleRequest?
    private var exactPresentationGeneration: Int?
    private var minimumPresentationGeneration: Int?
    private var lastKeyboardNudgeEventTimestamp: TimeInterval?
    private var latestKeyboardNudgeTarget: ColorPickerSampleTarget?
    private var firstPublishedTargetAfterLatestKeyboardNudge: ColorPickerSampleTarget?
    private var sampleRequestCount = 0
    private var completedSampleCount = 0
    private var publishedSampleCount = 0
    private var supersededSampleCount = 0
    private var totalSampleLatencyMilliseconds = 0.0
    private var maximumSampleLatencyMilliseconds = 0.0
    private var keyboardNudgeRequestCount = 0
    private var keyboardNudgePublishedCount = 0
    private var lastCountedKeyboardPresentationGeneration: Int?
    private var derivedKeyboardPresentationCount = 0
    private var ignoredStalePointerEventCount = 0
    private var didPushCursor = false

    init(
        samplerFactory: any PixelSamplerCreating,
        permissionChecker: any CapturePermissionChecking,
        settingsStore: SettingsStore,
        cursorController: (any ColorPickerCursorControlling)? = nil
    ) {
        self.samplerFactory = samplerFactory
        self.permissionChecker = permissionChecker
        self.settingsStore = settingsStore
        if let cursorController {
            self.cursorController = cursorController
        } else {
            self.cursorController = SystemColorPickerCursorController()
        }
    }

    func start() {
        guard !isPreparing, panels.isEmpty else {
            NSSound.beep()
            return
        }
        isPreparing = true
        sessionGeneration += 1
        let generation = sessionGeneration
        preparationTask = Task { [weak self] in
            await self?.prepareAndPresent(sessionGeneration: generation)
        }
    }

    func cancel() {
        cleanup(reason: "external-cancel")
    }

    fileprivate func mouseMoved(to point: CGPoint, eventTimestamp: TimeInterval) {
        guard completionGeneration == nil else { return }
        if let lastKeyboardNudgeEventTimestamp,
           eventTimestamp < lastKeyboardNudgeEventTimestamp
        {
            ignoredStalePointerEventCount += 1
            AppLog.colorPicker.debug(
                "Ignored a pointer event queued before the latest keyboard nudge"
            )
            return
        }
        let beginsPointerInputEpoch = requestedSample?.origin != .pointer
        let advancesPointerInputBarrier = minimumPresentationGeneration != nil
        currentPoint = point
        scheduleSample(origin: .pointer)
        if beginsPointerInputEpoch || advancesPointerInputBarrier,
           let requestedSample
        {
            exactPresentationGeneration = nil
            minimumPresentationGeneration = requestedSample.generation
        }
        views.forEach { $0.moveCard(to: point) }
    }

    fileprivate func mouseDown(at point: CGPoint) {
        guard completionGeneration == nil else { return }
        currentPoint = point
        scheduleSample(
            origin: .completion,
            copyAfterSampling: true
        )
    }

    @discardableResult
    fileprivate func keyDown(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            AppLog.colorPicker.debug("Handled color-picker key action: escape")
            cleanup(reason: "escape")
            return true
        }
        guard completionGeneration == nil else {
            NSSound.beep()
            return true
        }
        if event.keyCode == 8, event.modifierFlags.contains(.command) {
            AppLog.colorPicker.debug("Handled color-picker key action: copy")
            scheduleSample(origin: .completion, copyAfterSampling: true)
            return true
        }
        if event.keyCode == 48 {
            AppLog.colorPicker.debug("Handled color-picker key action: cycle-color-space")
            cycleColorSpace()
            return true
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            let largeStep = event.modifierFlags.contains(.shift)
            AppLog.colorPicker.debug(
                "Handled color-picker key action: nudge, largeStep=\(largeStep, privacy: .public)"
            )
            nudge(
                keyCode: event.keyCode,
                largeStep: largeStep,
                eventTimestamp: event.timestamp
            )
            return true
        }
        return false
    }

    private func prepareAndPresent(sessionGeneration generation: Int) async {
        guard await permissionChecker.authorizationStatus() == .authorized else {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            isPreparing = false
            preparationTask = nil
            onPermissionRequired?()
            return
        }

        do {
            let sampler = try await samplerFactory.makePixelSampler()
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            self.sampler = sampler
            currentPoint = initialPoint(in: sampler.displays)
            isPreparing = false
            preparationTask = nil
            try present(displays: sampler.displays)
            scheduleSample(origin: .initial)
            AppLog.colorPicker.notice(
                "Color picker presented across \(sampler.displays.count, privacy: .public) display(s)"
            )
        } catch is CancellationError {
            guard generation == sessionGeneration else { return }
            isPreparing = false
            preparationTask = nil
        } catch {
            guard generation == sessionGeneration else { return }
            isPreparing = false
            preparationTask = nil
            fail(error)
        }
    }

    private func present(displays: [DisplayDescriptor]) throws {
        guard panels.isEmpty else {
            throw ScreenshotAppError.pixelSamplingFailed(description: "The color picker overlay is already active.")
        }
        var keyPanel: PixelToolOverlayPanel?
        for screen in NSScreen.screens {
            guard
                let displayID = displayID(for: screen),
                displays.contains(where: { $0.id == displayID })
            else { continue }
            let view = ColorPickerOverlayView(coordinator: self)
            let panel = PixelToolOverlayPanel(screen: screen, contentView: view)
            panel.initialFirstResponder = view
            panels.append(panel)
            views.append(view)
            panel.orderFrontRegardless()
            if currentPoint.map(screen.frame.contains) == true { keyPanel = panel }
        }
        guard !panels.isEmpty else { throw ScreenshotAppError.noDisplayAvailable }
        NSCursor.crosshair.push()
        didPushCursor = true
        let panel = keyPanel ?? panels[0]
        panel.makeKeyAndOrderFront(nil)
        let acceptedFirstResponder = panel.makeFirstResponder(panel.contentView)
        guard acceptedFirstResponder, panel.isKeyWindow, panel.firstResponder === panel.contentView else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "The color picker could not establish its keyboard input session."
            )
        }
        installKeyboardMonitor()
        AppLog.colorPicker.notice(
            "Color picker input ready: appActive=\(NSApplication.shared.isActive, privacy: .public), keyWindow=\(panel.isKeyWindow, privacy: .public), firstResponder=\(acceptedFirstResponder, privacy: .public)"
        )
    }

    private func initialPoint(in displays: [DisplayDescriptor]) -> CGPoint {
        let mouse = cursorController.location
        if displays.contains(where: { $0.frame.contains(mouse) }) { return mouse }
        return CGPoint(x: displays[0].frame.midX, y: displays[0].frame.midY)
    }

    private func scheduleSample(
        at explicitPoint: CGPoint? = nil,
        target explicitTarget: ColorPickerSampleTarget? = nil,
        origin: ColorPickerSampleOrigin,
        copyAfterSampling: Bool = false
    ) {
        guard let sampler, let point = explicitPoint ?? currentPoint else { return }
        let colorSpace = explicitTarget?.colorSpace
            ?? settingsStore.settings.colorPicker.colorSpace
        guard let resolvedTarget = sampleTarget(
            at: point,
            colorSpace: colorSpace,
            sampler: sampler
        ) else {
            fail(ScreenshotAppError.pixelSamplingFailed(
                description: "The pointer is outside every capturable display."
            ))
            return
        }
        if let explicitTarget, explicitTarget != resolvedTarget {
            fail(ScreenshotAppError.pixelSamplingFailed(
                description: "The color-picker point does not map to its requested physical pixel."
            ))
            return
        }
        let target = explicitTarget ?? resolvedTarget
        if !copyAfterSampling,
           target == requestedSample?.target,
           origin == requestedSample?.origin
        {
            return
        }
        if let previousTarget = requestedSample?.target,
           previousTarget.displayID != target.displayID
            || previousTarget.colorSpace != target.colorSpace
        {
            currentSample = nil
            currentMagnifier = nil
            views.forEach { $0.clearCard() }
        }

        sampleGeneration += 1
        let request = ColorPickerSampleRequest(
            generation: sampleGeneration,
            point: point,
            target: target,
            origin: origin
        )
        requestedSample = request
        if origin == .keyboard {
            exactPresentationGeneration = request.generation
            minimumPresentationGeneration = nil
            keyboardNudgeRequestCount += 1
        }
        if copyAfterSampling {
            completionGeneration = request.generation
            exactPresentationGeneration = request.generation
            minimumPresentationGeneration = nil
        }
        guard samplingTask == nil else { return }
        let activeSession = sessionGeneration
        samplingTask = Task { [weak self] in
            await self?.runSamplingLoop(sessionGeneration: activeSession)
        }
    }

    private func runSamplingLoop(sessionGeneration activeSession: Int) async {
        while !Task.isCancelled, activeSession == sessionGeneration {
            guard let sampler, let request = requestedSample else {
                clearSamplingTask(sessionGeneration: activeSession)
                return
            }
            sampleRequestCount += 1
            let requestStart = ProcessInfo.processInfo.systemUptime
            do {
                let frame = try await sampler.sampleFrame(
                    at: request.point,
                    colorSpace: request.target.colorSpace,
                    radius: Self.captureRadius
                )
                guard
                    activeSession == sessionGeneration,
                    !Task.isCancelled,
                    self.sampler != nil
                else { return }
                guard frame.sample.displayID == request.target.displayID,
                      Int(frame.sample.pixelPoint.x) == request.target.pixelX,
                      Int(frame.sample.pixelPoint.y) == request.target.pixelY,
                      frame.sample.colorSpace == request.target.colorSpace
                else {
                    throw ScreenshotAppError.pixelSamplingFailed(
                        description: "The pixel sampler returned a frame that does not match its requested target."
                    )
                }
                let latencyMilliseconds = (ProcessInfo.processInfo.systemUptime - requestStart) * 1_000
                completedSampleCount += 1
                totalSampleLatencyMilliseconds += latencyMilliseconds
                maximumSampleLatencyMilliseconds = max(
                    maximumSampleLatencyMilliseconds,
                    latencyMilliseconds
                )
                guard let latestRequest = requestedSample else {
                    clearSamplingTask(sessionGeneration: activeSession)
                    fail(ScreenshotAppError.pixelSamplingFailed(
                        description: "The color-picker sampling target disappeared during an active session."
                    ))
                    return
                }
                let requestIsLatest = request.generation == latestRequest.generation
                let matchesLatestDisplayAndColorSpace = request.target.displayID
                        == latestRequest.target.displayID
                    && request.target.colorSpace == latestRequest.target.colorSpace
                let mayDeriveLatestPresentation = latestRequest.origin == .keyboard
                    || latestRequest.origin == .colorSpace
                guard let requestPresentation = try presentationFrame(
                    for: request,
                    from: frame,
                    sampler: sampler
                ) else {
                    throw ScreenshotAppError.pixelSamplingFailed(
                        description: "A captured color patch does not contain its requested presentation pixels."
                    )
                }
                var publication: (request: ColorPickerSampleRequest, frame: PixelSampleFrame)?
                if let exactPresentationGeneration {
                    if requestIsLatest,
                       request.generation >= exactPresentationGeneration
                    {
                        publication = (request, requestPresentation)
                    } else if latestRequest.generation >= exactPresentationGeneration,
                              mayDeriveLatestPresentation,
                              let latestPresentation = try presentationFrame(
                                for: latestRequest,
                                from: frame,
                                sampler: sampler
                              )
                    {
                        publication = (latestRequest, latestPresentation)
                    }
                } else if let minimumPresentationGeneration {
                    if requestIsLatest,
                       request.generation >= minimumPresentationGeneration
                    {
                        publication = (request, requestPresentation)
                    } else if latestRequest.origin == .pointer,
                              latestRequest.generation >= minimumPresentationGeneration,
                              let latestPresentation = try presentationFrame(
                                for: latestRequest,
                                from: frame,
                                sampler: sampler
                              )
                    {
                        publication = (latestRequest, latestPresentation)
                    }
                } else if matchesLatestDisplayAndColorSpace {
                    publication = (request, requestPresentation)
                }
                if let publication {
                    currentSample = publication.frame.sample
                    currentMagnifier = publication.frame.magnifier
                    publishedSampleCount += 1
                    if publication.request.origin == .keyboard,
                       publication.request.generation != request.generation
                    {
                        derivedKeyboardPresentationCount += 1
                    }
                    if publication.request.origin == .keyboard,
                       lastCountedKeyboardPresentationGeneration
                        != publication.request.generation
                    {
                        keyboardNudgePublishedCount += 1
                        lastCountedKeyboardPresentationGeneration = publication.request.generation
                    }
                    if latestKeyboardNudgeTarget != nil,
                       firstPublishedTargetAfterLatestKeyboardNudge == nil
                    {
                        firstPublishedTargetAfterLatestKeyboardNudge = publication.request.target
                    }
                    if let exactPresentationGeneration,
                       publication.request.generation >= exactPresentationGeneration
                    {
                        self.exactPresentationGeneration = nil
                    }
                    if let minimumPresentationGeneration,
                       publication.request.generation >= minimumPresentationGeneration
                    {
                        self.minimumPresentationGeneration = nil
                    }
                    updateCards()
                }

                let isExactCompletion = completionGeneration == request.generation
                let completionNeedsFreshRequest = completionGeneration != nil && !isExactCompletion
                guard requestIsLatest, !completionNeedsFreshRequest else {
                    supersededSampleCount += 1
                    continue
                }
                let shouldCopy = isExactCompletion
                completionGeneration = nil
                clearSamplingTask(sessionGeneration: activeSession)
                if shouldCopy, copyCurrentSample() {
                    cleanup(reason: "copy-completed")
                }
                return
            } catch is CancellationError {
                clearSamplingTask(sessionGeneration: activeSession)
                return
            } catch {
                guard activeSession == sessionGeneration else { return }
                clearSamplingTask(sessionGeneration: activeSession)
                fail(error)
                return
            }
        }
        clearSamplingTask(sessionGeneration: activeSession)
    }

    private func clearSamplingTask(sessionGeneration activeSession: Int) {
        guard activeSession == sessionGeneration else { return }
        samplingTask = nil
    }

    @discardableResult
    private func copyCurrentSample() -> Bool {
        guard let sample = currentSample else {
            NSSound.beep()
            return false
        }
        let value = sample.copyRepresentation(format: settingsStore.settings.colorPicker.copyFormat)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            fail(ScreenshotAppError.exportFailed(description: "The color value could not be written to the pasteboard."))
            return false
        }
        AppLog.export.notice("Copied a \(sample.colorSpace.title, privacy: .public) color sample")
        return true
    }

    private func cycleColorSpace() {
        let spaces = ColorSpacePreference.allCases
        let current = settingsStore.settings.colorPicker.colorSpace
        guard let index = spaces.firstIndex(of: current) else {
            fail(ScreenshotAppError.settingsCorrupted(description: "The saved color-space preference is unknown."))
            return
        }
        let next = spaces[(index + 1) % spaces.count]
        do {
            try settingsStore.update(\AppSettings.colorPicker.colorSpace, to: next)
            scheduleSample(origin: .colorSpace)
        } catch {
            fail(error)
        }
    }

    private func nudge(
        keyCode: UInt16,
        largeStep: Bool,
        eventTimestamp: TimeInterval
    ) {
        guard
            let sampler,
            let point = currentPoint,
            let currentTarget = sampleTarget(
                at: point,
                colorSpace: settingsStore.settings.colorPicker.colorSpace,
                sampler: sampler
            ),
            let display = sampler.displays.first(where: { $0.id == currentTarget.displayID }),
            display.scale > 0,
            display.pixelSize.width >= 1,
            display.pixelSize.height >= 1
        else {
            NSSound.beep()
            return
        }
        let step = largeStep ? 10 : 1
        var nextPixelX = currentTarget.pixelX
        var nextPixelY = currentTarget.pixelY
        switch keyCode {
        case 123: nextPixelX -= step
        case 124: nextPixelX += step
        case 125: nextPixelY += step
        default: nextPixelY -= step
        }
        nextPixelX = min(
            max(0, nextPixelX),
            max(0, Int(display.pixelSize.width) - 1)
        )
        nextPixelY = min(
            max(0, nextPixelY),
            max(0, Int(display.pixelSize.height) - 1)
        )
        guard nextPixelX != currentTarget.pixelX
                || nextPixelY != currentTarget.pixelY
        else { return }

        let nextTarget = ColorPickerSampleTarget(
            displayID: display.id,
            pixelX: nextPixelX,
            pixelY: nextPixelY,
            colorSpace: currentTarget.colorSpace
        )
        let next = globalPoint(centerOf: nextTarget, in: display)
        let displayLocalPoint = CGPoint(
            x: next.x - display.frame.minX,
            y: display.frame.maxY - next.y
        )
        let cursorMoveResult = cursorController.move(
            to: displayLocalPoint,
            on: display.id
        )
        guard cursorMoveResult == .success else {
            fail(ScreenshotAppError.pixelSamplingFailed(
                description: "The system could not move the color-picker cursor (CGError \(cursorMoveResult.rawValue))."
            ))
            return
        }
        lastKeyboardNudgeEventTimestamp = eventTimestamp
        currentPoint = next
        latestKeyboardNudgeTarget = nextTarget
        firstPublishedTargetAfterLatestKeyboardNudge = nil
        views.forEach { $0.moveCard(to: next) }
        scheduleSample(
            at: next,
            target: nextTarget,
            origin: .keyboard
        )
    }

#if DEBUG
    func injectPointerMoveForUITesting(
        to point: CGPoint,
        eventTimestamp: TimeInterval
    ) {
        mouseMoved(to: point, eventTimestamp: eventTimestamp)
    }
#endif

    private func fail(_ error: Error) {
        AppLog.colorPicker.error("Color picker failed: \(error.localizedDescription, privacy: .public)")
        cleanup(reason: "failure")
        onError?(error)
    }

    private func updateCards() {
        guard let currentSample, let currentMagnifier else { return }
        let state = ColorPickerCardState(
            sample: currentSample,
            magnifier: currentMagnifier,
            copyFormat: settingsStore.settings.colorPicker.copyFormat,
            latestKeyboardNudgeTarget: latestKeyboardNudgeTarget,
            firstPublishedTargetAfterLatestKeyboardNudge: firstPublishedTargetAfterLatestKeyboardNudge
        )
        views.forEach { $0.updateCard(state: state, at: currentPoint) }
    }

    private func sampleTarget(
        at point: CGPoint,
        colorSpace: ColorSpacePreference,
        sampler: any PixelSampling
    ) -> ColorPickerSampleTarget? {
        guard let display = sampler.displays.first(where: { $0.frame.contains(point) }) else {
            return nil
        }
        let pixelX = Int(floor((point.x - display.frame.minX) * display.scale))
        let pixelY = Int(floor((display.frame.maxY - point.y) * display.scale))
        return ColorPickerSampleTarget(
            displayID: display.id,
            pixelX: min(max(0, pixelX), max(0, Int(display.pixelSize.width) - 1)),
            pixelY: min(max(0, pixelY), max(0, Int(display.pixelSize.height) - 1)),
            colorSpace: colorSpace
        )
    }

    private func globalPoint(
        centerOf target: ColorPickerSampleTarget,
        in display: DisplayDescriptor
    ) -> CGPoint {
        CGPoint(
            x: display.frame.minX + (CGFloat(target.pixelX) + 0.5) / display.scale,
            y: display.frame.maxY - (CGFloat(target.pixelY) + 0.5) / display.scale
        )
    }

    private func presentationFrame(
        for request: ColorPickerSampleRequest,
        from capturedFrame: PixelSampleFrame,
        sampler: any PixelSampling
    ) throws -> PixelSampleFrame? {
        guard
            capturedFrame.sample.displayID == request.target.displayID,
            let display = sampler.displays.first(where: { $0.id == request.target.displayID })
        else { return nil }

        let sourceRect = capturedFrame.magnifier.sourcePixelRect
        let presentationRect = pixelCrop(
            centerX: request.target.pixelX,
            centerY: request.target.pixelY,
            radius: Self.presentationRadius,
            pixelSize: display.pixelSize
        )
        guard sourceRect.minX <= presentationRect.minX,
              sourceRect.minY <= presentationRect.minY,
              sourceRect.maxX >= presentationRect.maxX,
              sourceRect.maxY >= presentationRect.maxY
        else { return nil }

        let sourceImage = capturedFrame.magnifier.image
        let imageCropRect = presentationRect.offsetBy(
            dx: -sourceRect.minX,
            dy: -sourceRect.minY
        )
        guard let presentationImage = sourceImage.cropping(to: imageCropRect),
              presentationImage.width == Int(presentationRect.width),
              presentationImage.height == Int(presentationRect.height)
        else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "The captured color patch could not produce its magnifier image."
            )
        }
        let pixelInSourceImage = CGPoint(
            x: CGFloat(request.target.pixelX) - sourceRect.minX,
            y: CGFloat(request.target.pixelY) - sourceRect.minY
        )
        let components = try ColorManagedPixelReader().components(
            from: sourceImage,
            at: pixelInSourceImage,
            into: request.target.colorSpace.nsColorSpace
        )
        return PixelSampleFrame(
            sample: ColorSample(
                displayID: display.id,
                displayName: display.name,
                globalPoint: request.point,
                pixelPoint: CGPoint(
                    x: CGFloat(request.target.pixelX),
                    y: CGFloat(request.target.pixelY)
                ),
                colorSpace: request.target.colorSpace,
                components: components,
                sourceColorSpaceName: capturedFrame.sample.sourceColorSpaceName
            ),
            magnifier: PixelMagnifier(
                image: presentationImage,
                centerPixel: CGPoint(
                    x: CGFloat(request.target.pixelX) - presentationRect.minX,
                    y: CGFloat(request.target.pixelY) - presentationRect.minY
                ),
                sourcePixelRect: presentationRect,
                displayScale: display.scale
            )
        )
    }

    private func pixelCrop(
        centerX: Int,
        centerY: Int,
        radius: Int,
        pixelSize: CGSize
    ) -> CGRect {
        let requestedLength = CGFloat(radius * 2 + 1)
        let width = min(requestedLength, pixelSize.width)
        let height = min(requestedLength, pixelSize.height)
        let maximumX = pixelSize.width - width
        let maximumY = pixelSize.height - height
        return CGRect(
            x: min(max(0, CGFloat(centerX - radius)), maximumX),
            y: min(max(0, CGFloat(centerY - radius)), maximumY),
            width: width,
            height: height
        ).integral
    }

    private func installKeyboardMonitor() {
        precondition(keyboardMonitor == nil, "The color picker may install only one keyboard monitor.")
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.ownsKeyboardEvent(event) else { return event }
            return self.keyDown(with: event) ? nil : event
        }) else {
            preconditionFailure("The color picker could not install its keyboard monitor.")
        }
        keyboardMonitor = monitor
    }

    private func ownsKeyboardEvent(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApplication.shared.keyWindow else { return false }
        return panels.contains { $0 === window }
    }

    private func removeKeyboardMonitor() {
        guard let keyboardMonitor else { return }
        NSEvent.removeMonitor(keyboardMonitor)
        self.keyboardMonitor = nil
    }

    private func cleanup(reason: String) {
        let wasActive = isPreparing || sampler != nil || !panels.isEmpty
        if wasActive {
            let averageLatency = completedSampleCount > 0
                ? totalSampleLatencyMilliseconds / Double(completedSampleCount)
                : 0
            AppLog.colorPicker.notice(
                "Color picker closing: reason=\(reason, privacy: .public), requests=\(self.sampleRequestCount, privacy: .public), completed=\(self.completedSampleCount, privacy: .public), published=\(self.publishedSampleCount, privacy: .public), superseded=\(self.supersededSampleCount, privacy: .public), keyboardRequests=\(self.keyboardNudgeRequestCount, privacy: .public), keyboardPublished=\(self.keyboardNudgePublishedCount, privacy: .public), derivedKeyboardPresentations=\(self.derivedKeyboardPresentationCount, privacy: .public), stalePointerEvents=\(self.ignoredStalePointerEventCount, privacy: .public), averageLatencyMs=\(averageLatency, privacy: .public), maximumLatencyMs=\(self.maximumSampleLatencyMilliseconds, privacy: .public)"
            )
        }
        sessionGeneration += 1
        sampleGeneration += 1
        preparationTask?.cancel()
        preparationTask = nil
        samplingTask?.cancel()
        samplingTask = nil
        removeKeyboardMonitor()
        completionGeneration = nil
        panels.forEach {
            $0.orderOut(nil)
            $0.close()
        }
        panels.removeAll()
        views.removeAll()
        sampler = nil
        currentPoint = nil
        currentSample = nil
        currentMagnifier = nil
        requestedSample = nil
        exactPresentationGeneration = nil
        minimumPresentationGeneration = nil
        lastKeyboardNudgeEventTimestamp = nil
        latestKeyboardNudgeTarget = nil
        firstPublishedTargetAfterLatestKeyboardNudge = nil
        sampleRequestCount = 0
        completedSampleCount = 0
        publishedSampleCount = 0
        supersededSampleCount = 0
        totalSampleLatencyMilliseconds = 0
        maximumSampleLatencyMilliseconds = 0
        keyboardNudgeRequestCount = 0
        keyboardNudgePublishedCount = 0
        lastCountedKeyboardPresentationGeneration = nil
        derivedKeyboardPresentationCount = 0
        ignoredStalePointerEventCount = 0
        isPreparing = false
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }
}

private enum ColorPickerSampleOrigin: Equatable {
    case initial
    case pointer
    case keyboard
    case colorSpace
    case completion
}

private struct ColorPickerSampleTarget: Equatable {
    let displayID: CGDirectDisplayID
    let pixelX: Int
    let pixelY: Int
    let colorSpace: ColorSpacePreference
}

private struct ColorPickerSampleRequest: Equatable {
    let generation: Int
    let point: CGPoint
    let target: ColorPickerSampleTarget
    let origin: ColorPickerSampleOrigin
}

private struct ColorPickerCardState {
    let sample: ColorSample
    let magnifier: PixelMagnifier
    let copyFormat: ColorCopyFormat
    let latestKeyboardNudgeTarget: ColorPickerSampleTarget?
    let firstPublishedTargetAfterLatestKeyboardNudge: ColorPickerSampleTarget?
}

@MainActor
private final class ColorPickerOverlayView: NSView {
    private weak var coordinator: ColorPickerCoordinator?
    private let cardView: ColorPickerCardView
    private var trackingAreaReference: NSTrackingArea?

    init(coordinator: ColorPickerCoordinator) {
        self.coordinator = coordinator
        cardView = ColorPickerCardView(
            frame: CGRect(origin: .zero, size: ColorPickerCardView.cardSize)
        )
        super.init(frame: .zero)
        cardView.isHidden = true
        addSubview(cardView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
#if DEBUG
        setAccessibilityIdentifier("colorPicker.overlay")
#endif
        setAccessibilityLabel(NSLocalizedString("Screen color picker", comment: "Color picker overlay"))
#if DEBUG
        setAccessibilityValue("state=waiting")
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.mouseMoved(
            to: globalPoint(for: event),
            eventTimestamp: event.timestamp
        )
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.mouseMoved(
            to: globalPoint(for: event),
            eventTimestamp: event.timestamp
        )
    }
    override func mouseDown(with event: NSEvent) { coordinator?.mouseDown(at: globalPoint(for: event)) }
    override func keyDown(with event: NSEvent) {
        if coordinator?.keyDown(with: event) != true {
            super.keyDown(with: event)
        }
    }

    func updateCard(state: ColorPickerCardState, at globalPoint: CGPoint?) {
        cardView.update(state: state)
        moveCard(to: globalPoint)
#if DEBUG
        let nudgePixel = state.latestKeyboardNudgeTarget.map {
            "\($0.pixelX),\($0.pixelY)"
        } ?? "none"
        let firstPublishedPixel = state.firstPublishedTargetAfterLatestKeyboardNudge.map {
            "\($0.pixelX),\($0.pixelY)"
        } ?? "none"
        setAccessibilityValue(
            "state=ready; colorSpace=\(state.sample.colorSpace.rawValue); screen=\(Int(state.sample.globalPoint.x)),\(Int(state.sample.globalPoint.y)); pixel=\(Int(state.sample.pixelPoint.x)),\(Int(state.sample.pixelPoint.y)); copy=\(state.sample.copyRepresentation(format: state.copyFormat)); magnifier=\(state.magnifier.image.width)x\(state.magnifier.image.height); magnifierCenter=\(Int(state.magnifier.centerPixel.x)),\(Int(state.magnifier.centerPixel.y)); nudgePixel=\(nudgePixel); firstPublishedAfterNudge=\(firstPublishedPixel)"
        )
#endif
    }

    func clearCard() {
        cardView.clear()
        cardView.isHidden = true
#if DEBUG
        setAccessibilityValue("state=waiting")
#endif
    }

    func moveCard(to globalPoint: CGPoint?) {
        guard
            cardView.hasState,
            let globalPoint,
            let window,
            window.frame.contains(globalPoint)
        else {
            cardView.isHidden = true
            return
        }
        let localPoint = CGPoint(
            x: globalPoint.x - window.frame.minX,
            y: globalPoint.y - window.frame.minY
        )
        cardView.frame = cardRect(near: localPoint, size: cardView.frame.size)
        cardView.isHidden = false
    }

    private func cardRect(near point: CGPoint, size: CGSize) -> CGRect {
        let placementBounds: CGRect
        if let window, let visibleFrame = window.screen?.visibleFrame.intersection(window.frame), !visibleFrame.isNull {
            placementBounds = CGRect(
                x: visibleFrame.minX - window.frame.minX,
                y: visibleFrame.minY - window.frame.minY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        } else {
            placementBounds = bounds
        }
        let minimumX = placementBounds.minX + 8
        let maximumX = placementBounds.maxX - size.width - 8
        let minimumY = placementBounds.minY + 8
        let maximumY = placementBounds.maxY - size.height - 8

        var x = point.x + 22
        if x + size.width > placementBounds.maxX - 8 { x = point.x - size.width - 22 }
        x = min(max(minimumX, x), max(minimumX, maximumX))
        var y = point.y - size.height / 2
        y = min(max(minimumY, y), max(minimumY, maximumY))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return CGPoint(
            x: window.frame.minX + event.locationInWindow.x,
            y: window.frame.minY + event.locationInWindow.y
        )
    }
}

@MainActor
private final class ColorPickerCardView: NSView {
    static let cardSize = CGSize(width: 430, height: 330)

    private enum Layout {
        static let horizontalInset: CGFloat = 14
        static let contentWidth: CGFloat = 402
        static let magnifierRect = CGRect(x: 14, y: 162, width: 154, height: 154)
        static let detailX: CGFloat = 184
        static let detailWidth: CGFloat = 232
        static let swatchRect = CGRect(x: 184, y: 276, width: 232, height: 40)
        static let mainDividerY: CGFloat = 152.5
        static let shortcutDividerY: CGFloat = 70.5
        static let metadataColumnWidth: CGFloat = 193
        static let metadataRightX: CGFloat = 223
    }

    private var state: ColorPickerCardState?

    var hasState: Bool { state != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 14
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 14,
            cornerHeight: 14,
            transform: nil
        )
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
#if DEBUG
        setAccessibilityIdentifier("colorPicker.card")
#endif
        setAccessibilityLabel(NSLocalizedString("Color picker details", comment: "Color picker detail card"))
        setAccessibilityValue(
            NSLocalizedString("Waiting for a color sample", comment: "Color picker accessibility waiting state")
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }

    func update(state: ColorPickerCardState) {
        self.state = state
        let accessibilitySummary = accessibilitySummary(for: state)
#if DEBUG
        setAccessibilityValue(
            "hierarchy=copy,channels,metadata,shortcuts; shortcutLayout=three-plus-two; presentation=\(copyPresentationTitle(for: state)); \(accessibilitySummary)"
        )
#else
        setAccessibilityValue(accessibilitySummary)
#endif
        needsDisplay = true
    }

    func clear() {
        state = nil
        setAccessibilityValue(
            NSLocalizedString("Waiting for a color sample", comment: "Color picker accessibility waiting state")
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        let card = bounds

        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14).stroke()

        drawMagnifier(state.magnifier, in: Layout.magnifierRect)
        drawSwatch(state.sample, in: Layout.swatchRect)
        drawCopyValue(state)
        drawChannels(state.sample)
        drawDivider(at: Layout.mainDividerY)
        drawMetadata(state.sample)
        drawDivider(at: Layout.shortcutDividerY)
        drawShortcuts()
    }

    private func drawMagnifier(_ magnifier: PixelMagnifier, in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 7, yRadius: 7).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: magnifier.image, size: NSSize(width: magnifier.image.width, height: magnifier.image.height))
            .draw(in: rect, from: .zero, operation: .copy, fraction: 1)

        let cellWidth = rect.width / CGFloat(magnifier.image.width)
        let cellHeight = rect.height / CGFloat(magnifier.image.height)
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let grid = NSBezierPath()
        for column in 1..<magnifier.image.width {
            let x = rect.minX + CGFloat(column) * cellWidth
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.line(to: CGPoint(x: x, y: rect.maxY))
        }
        for row in 1..<magnifier.image.height {
            let y = rect.minY + CGFloat(row) * cellHeight
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.line(to: CGPoint(x: rect.maxX, y: y))
        }
        grid.lineWidth = 0.5
        grid.stroke()

        let center = CGRect(
            x: rect.minX + magnifier.centerPixel.x * cellWidth,
            y: rect.maxY - (magnifier.centerPixel.y + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        ).insetBy(dx: -1, dy: -1)
        NSColor.white.setStroke()
        let outer = NSBezierPath(rect: center)
        outer.lineWidth = 3
        outer.stroke()
        NSColor.black.setStroke()
        let inner = NSBezierPath(rect: center.insetBy(dx: 1, dy: 1))
        inner.lineWidth = 1
        inner.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let outerKeyline = NSBezierPath(
            roundedRect: rect.insetBy(dx: -0.5, dy: -0.5),
            xRadius: 6,
            yRadius: 6
        )
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()
        outerKeyline.lineWidth = 1
        outerKeyline.stroke()
        let innerKeyline = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 5,
            yRadius: 5
        )
        NSColor.white.withAlphaComponent(0.46).setStroke()
        innerKeyline.lineWidth = 1
        innerKeyline.stroke()
    }

    private func drawSwatch(_ sample: ColorSample, in rect: CGRect) {
        let color = NSColor(
            colorSpace: sample.colorSpace.nsColorSpace,
            components: [
                sample.components.red,
                sample.components.green,
                sample.components.blue,
                sample.components.alpha
            ],
            count: 4
        )
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
    }

    private func drawCopyValue(_ state: ColorPickerCardState) {
        let copyValue = state.sample.copyRepresentation(format: state.copyFormat)
        drawText(
            NSLocalizedString("Copy value", comment: "Color picker primary value label"),
            in: CGRect(x: Layout.detailX, y: 252, width: 146, height: 14),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: .secondaryLabelColor,
            wraps: false
        )
        drawText(
            copyPresentationTitle(for: state),
            in: CGRect(x: 330, y: 252, width: 86, height: 14),
            font: .systemFont(ofSize: 9.5, weight: .semibold),
            color: .secondaryLabelColor,
            wraps: false,
            alignment: .right
        )

        let isShortValue = copyValue.count <= 12 && !copyValue.contains(where: \.isWhitespace)
        drawText(
            copyValue,
            in: CGRect(
                x: Layout.detailX,
                y: isShortValue ? 216 : 211,
                width: Layout.detailWidth,
                height: isShortValue ? 31 : 38
            ),
            font: isShortValue
                ? AppKitDrawingFonts.colorPickerPrimaryValue
                : AppKitDrawingFonts.colorPickerLongValue,
            color: .labelColor,
            wraps: !isShortValue
        )
    }

    private func drawChannels(_ sample: ColorSample) {
        drawText(
            NSLocalizedString("Channels", comment: "Color picker RGBA channel section"),
            in: CGRect(x: Layout.detailX, y: 197, width: Layout.detailWidth, height: 13),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: .secondaryLabelColor,
            wraps: false
        )

        let channels: [(label: String, value: CGFloat)] = [
            ("R", sample.components.red),
            ("G", sample.components.green),
            ("B", sample.components.blue),
            ("A", sample.components.alpha)
        ]
        let cellWidth = Layout.detailWidth / CGFloat(channels.count)
        for (index, channel) in channels.enumerated() {
            let cellX = Layout.detailX + CGFloat(index) * cellWidth
            drawText(
                channel.label,
                in: CGRect(x: cellX, y: 174, width: 10, height: 16),
                font: .systemFont(ofSize: 9.5, weight: .semibold),
                color: .secondaryLabelColor,
                wraps: false
            )
            drawText(
                channelValue(channel.value),
                in: CGRect(x: cellX + 11, y: 173, width: cellWidth - 11, height: 17),
                font: AppKitDrawingFonts.colorPickerChannelValue,
                color: .labelColor,
                wraps: false
            )
        }
    }

    private func drawMetadata(_ sample: ColorSample) {
        drawMetadataItem(
            label: NSLocalizedString("Display", comment: "Color picker display label"),
            value: sample.displayName,
            x: Layout.horizontalInset,
            labelY: 133,
            valueY: 115,
            valueFont: .systemFont(ofSize: 11.5, weight: .medium)
        )
        drawMetadataItem(
            label: NSLocalizedString("Output color space", comment: "Color picker output color-space label"),
            value: sample.colorSpace.title,
            x: Layout.metadataRightX,
            labelY: 133,
            valueY: 115,
            valueFont: .systemFont(ofSize: 11.5, weight: .medium)
        )
        drawMetadataItem(
            label: NSLocalizedString("Screen", comment: "Color picker screen-coordinate label"),
            value: "\(Int(sample.globalPoint.x)), \(Int(sample.globalPoint.y)) pt",
            x: Layout.horizontalInset,
            labelY: 96,
            valueY: 78,
            valueFont: AppKitDrawingFonts.colorPickerLongValue
        )
        drawMetadataItem(
            label: NSLocalizedString("Pixel", comment: "Color picker pixel-coordinate label"),
            value: "\(Int(sample.pixelPoint.x)), \(Int(sample.pixelPoint.y))",
            x: Layout.metadataRightX,
            labelY: 96,
            valueY: 78,
            valueFont: AppKitDrawingFonts.colorPickerLongValue
        )

    }

    private func drawMetadataItem(
        label: String,
        value: String,
        x: CGFloat,
        labelY: CGFloat,
        valueY: CGFloat,
        valueFont: NSFont
    ) {
        drawText(
            label,
            in: CGRect(x: x, y: labelY, width: Layout.metadataColumnWidth, height: 13),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: .secondaryLabelColor,
            wraps: false
        )
        drawText(
            value,
            in: CGRect(x: x, y: valueY, width: Layout.metadataColumnWidth, height: 17),
            font: valueFont,
            color: .labelColor,
            wraps: false
        )
    }

    private func drawDivider(at y: CGFloat) {
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: Layout.horizontalInset, y: y))
        divider.line(to: CGPoint(x: bounds.maxX - Layout.horizontalInset, y: y))
        divider.lineWidth = 1
        NSColor.separatorColor.withAlphaComponent(0.38).setStroke()
        divider.stroke()
    }

    private func copyPresentationTitle(for state: ColorPickerCardState) -> String {
        switch (state.copyFormat, state.sample.colorSpace) {
        case (.hex, .sRGB):
            return "HEX"
        case (.hex, .displayP3), (.css, .sRGB), (.css, .displayP3):
            return "CSS"
        case (.hex, .genericRGB), (.hex, .adobeRGB1998),
             (.css, .genericRGB), (.css, .adobeRGB1998),
             (.components, _):
            return NSLocalizedString("Components", comment: "Color copy format")
        }
    }

    private func accessibilitySummary(for state: ColorPickerCardState) -> String {
        let sample = state.sample
        let channels = [
            "R \(channelValue(sample.components.red))",
            "G \(channelValue(sample.components.green))",
            "B \(channelValue(sample.components.blue))",
            "A \(channelValue(sample.components.alpha))"
        ]
        .joined(separator: ", ")
        return [
            "\(NSLocalizedString("Copy value", comment: "Color picker primary value label")): \(sample.copyRepresentation(format: state.copyFormat))",
            "\(NSLocalizedString("Channels", comment: "Color picker RGBA channel section")): \(channels)",
            "\(NSLocalizedString("Display", comment: "Color picker display label")): \(sample.displayName)",
            "\(NSLocalizedString("Output color space", comment: "Color picker output color-space label")): \(sample.colorSpace.title)",
            "\(NSLocalizedString("Screen", comment: "Color picker screen-coordinate label")): \(Int(sample.globalPoint.x)), \(Int(sample.globalPoint.y)) pt",
            "\(NSLocalizedString("Pixel", comment: "Color picker pixel-coordinate label")): \(Int(sample.pixelPoint.x)), \(Int(sample.pixelPoint.y))"
        ]
        .joined(separator: ". ")
    }

    private func channelValue(_ component: CGFloat) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), component)
    }

    private func drawShortcuts() {
        drawText(
            NSLocalizedString("Shortcuts", comment: "Color picker shortcut section"),
            in: CGRect(x: Layout.horizontalInset, y: 52, width: Layout.contentWidth, height: 13),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: .secondaryLabelColor,
            wraps: false
        )

        drawShortcut(
            key: "⌘C",
            action: NSLocalizedString("Copy", comment: "Color picker shortcut action"),
            in: CGRect(x: 14, y: 31, width: 104, height: 16)
        )
        drawShortcut(
            key: "Tab",
            action: NSLocalizedString("Color space", comment: "Color picker shortcut action"),
            in: CGRect(x: 130, y: 31, width: 176, height: 16)
        )
        drawShortcut(
            key: "Esc",
            action: NSLocalizedString("Close", comment: "Color picker shortcut action"),
            in: CGRect(x: 318, y: 31, width: 98, height: 16)
        )
        drawShortcut(
            key: "↑↓←→",
            action: NSLocalizedString("Move 1 px", comment: "Color picker shortcut action"),
            in: CGRect(x: 14, y: 11, width: 182, height: 16)
        )
        drawShortcut(
            key: "⇧ ↑↓←→",
            action: NSLocalizedString("Move 10 px", comment: "Color picker shortcut action"),
            in: CGRect(x: 212, y: 11, width: 204, height: 16)
        )
    }

    private func drawShortcut(key: String, action: String, in rect: CGRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributed = NSMutableAttributedString(
            string: key,
            attributes: [
                .font: AppKitDrawingFonts.colorPickerChannelValue,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        attributed.append(
            NSAttributedString(
                string: "  \(action)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraphStyle
                ]
            )
        )
        attributed.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        )
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        wraps: Bool,
        alignment: NSTextAlignment = .left
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        paragraphStyle.alignment = alignment
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )
        attributed.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        )
    }
}
