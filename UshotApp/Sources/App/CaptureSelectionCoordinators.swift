import AppKit
import CoreGraphics
import UshotCore

enum RegionSelectionResizeHandle: CaseIterable, Equatable {
    case northWest, north, northEast, east, southEast, south, southWest, west

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .northWest: position = .topLeft
            case .north: position = .top
            case .northEast: position = .topRight
            case .east: position = .right
            case .southEast: position = .bottomRight
            case .south: position = .bottom
            case .southWest: position = .bottomLeft
            case .west: position = .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch self {
        case .north, .south:
            return .resizeUpDown
        case .east, .west:
            return .resizeLeftRight
        case .northWest, .northEast, .southEast, .southWest:
            return .crosshair
        }
    }
}

enum RegionDraftGeometryChange: String {
    /// Changing one or more edges keeps existing annotations anchored to the
    /// same frozen desktop pixels while the crop boundary moves around them.
    case resizePreservingDesktopAnchors = "resize-preserving-desktop-anchors"
    /// Moving the selected canvas keeps annotation coordinates local to the
    /// canvas, so the image and every edit travel together.
    case moveCanvas = "move-canvas"
}

@MainActor
final class DisplaySelectionCoordinator {
    private var continuation: CheckedContinuation<CGDirectDisplayID, Error>?
    private var panels: [SelectionOverlayPanel] = []

    func select(from displays: [DisplayDescriptor]) async throws -> CGDirectDisplayID {
        guard continuation == nil else {
            throw ScreenshotAppError.captureFailed(description: "Display selection is already active.")
        }
        guard !displays.isEmpty else { throw ScreenshotAppError.noDisplayAvailable }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            present(displays: displays)
        }
    }

    private func present(displays: [DisplayDescriptor]) {
        var keyPanel: SelectionOverlayPanel?
        for (index, screen) in NSScreen.screens.enumerated() {
            guard
                let displayID = screenDisplayID(screen),
                let descriptor = displays.first(where: { $0.id == displayID })
            else { continue }

            let view = DisplaySelectionOverlayView(descriptor: descriptor, number: index + 1)
            view.onSelect = { [weak self] in self?.complete(with: descriptor.id) }
            view.onCancel = { [weak self] in self?.cancel() }
            let panel = SelectionOverlayPanel(screen: screen, contentView: view)
            panels.append(panel)
            panel.orderFrontRegardless()
            if descriptor.isCurrent { keyPanel = panel }
        }
        let panel = keyPanel ?? panels.first
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panel?.contentView)
    }

    private func complete(with displayID: CGDirectDisplayID) {
        let continuation = self.continuation
        cleanup()
        continuation?.resume(returning: displayID)
    }

    private func cancel() {
        let continuation = self.continuation
        cleanup()
        continuation?.resume(throwing: ScreenshotAppError.captureCancelled)
    }

    private func cleanup() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        continuation = nil
    }
}

@MainActor
final class WindowSelectionCoordinator {
    private var continuation: CheckedContinuation<CGWindowID, Error>?
    private var panels: [SelectionOverlayPanel] = []
    private var views: [WindowSelectionOverlayView] = []
    private var candidates: [WindowDescriptor] = []
    private var highlightedWindow: WindowDescriptor? {
        didSet {
            views.forEach {
                $0.highlightedWindow = highlightedWindow
                $0.needsDisplay = true
            }
        }
    }

    func select(from windows: [WindowDescriptor]) async throws -> CGWindowID {
        guard continuation == nil else {
            throw ScreenshotAppError.captureFailed(description: "Window selection is already active.")
        }
        guard !windows.isEmpty else { throw ScreenshotAppError.noWindowAvailable }
        candidates = windows

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        var keyPanel: SelectionOverlayPanel?
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let view = WindowSelectionOverlayView()
            view.onMove = { [weak self] point in self?.updateHighlight(at: point) }
            view.onSelect = { [weak self] point in self?.selectWindow(at: point) }
            view.onCancel = { [weak self] in self?.cancel() }
            let panel = SelectionOverlayPanel(screen: screen, contentView: view)
            panel.acceptsMouseMovedEvents = true
            panels.append(panel)
            views.append(view)
            panel.orderFrontRegardless()
            if screen.frame.contains(mouseLocation) { keyPanel = panel }
        }
        updateHighlight(at: mouseLocation)
        let panel = keyPanel ?? panels.first
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panel?.contentView)
    }

    private func updateHighlight(at point: CGPoint) {
        highlightedWindow = WindowSelectionResolver().topmostWindow(at: point, candidates: candidates)
    }

    private func selectWindow(at point: CGPoint) {
        guard let window = WindowSelectionResolver().topmostWindow(at: point, candidates: candidates) else {
            NSSound.beep()
            return
        }
        let continuation = self.continuation
        cleanup()
        continuation?.resume(returning: window.id)
    }

    private func cancel() {
        let continuation = self.continuation
        cleanup()
        continuation?.resume(throwing: ScreenshotAppError.captureCancelled)
    }

    private func cleanup() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        candidates.removeAll()
        highlightedWindow = nil
        continuation = nil
    }
}

@MainActor
final class RegionSelectionCoordinator {
    typealias ElementResolutionHandler = @Sendable (
        _ point: CGPoint,
        _ window: WindowDescriptor,
        _ primaryDisplayHeight: CGFloat
    ) -> InterfaceElementResolution

    private enum OutputAction: String {
        case copy
        case save
        case pin
    }

    private enum DragMode {
        case creating
        case snappedCandidate
        case moving
        case resizing(RegionSelectionResizeHandle)
    }

    private enum SnapCandidateKind: String {
        case window
        case interfaceElement = "interface-element"
    }

    private struct SnapTarget: Equatable {
        let frame: CGRect
        let kind: SnapCandidateKind
    }

    private struct ElementResolutionRequest: Sendable {
        let point: CGPoint
        let window: WindowDescriptor
        let lifecycleGeneration: UInt
    }

    private var continuation: CheckedContinuation<CGRect, Error>?
    private var panels: [SelectionOverlayPanel] = []
    private var views: [RegionSelectionOverlayView] = []
    private let pinnedShotManager: PinnedShotManager
    private var preparation: RegionCapturePreparation?
    private let elementResolutionHandler: ElementResolutionHandler
    private var recognizesInterfaceElements = true
    private var snapCandidate: CGRect? {
        didSet {
            guard snapCandidate != oldValue else { return }
            invalidateViews()
        }
    }
    private var snapCandidateKind: SnapCandidateKind? {
        didSet {
            guard snapCandidateKind != oldValue else { return }
            invalidateViews()
        }
    }
    private var snapTargets: [SnapTarget] = []
    private var selectedSnapTargetIndex = 0
    private var snapWindowID: CGWindowID?
    private var snapLevelWasUserAdjusted = false
    private var hierarchyScrollAccumulator: CGFloat = 0
    private var interfaceElementToWindowFallbackCount = 0
    private var pendingElementResolution: ElementResolutionRequest?
    private var elementResolutionTask: Task<Void, Never>?
    private var elementResolutionGeneration: UInt = 0
    private var didLogMissingAccessibilityPermission = false
    private var selection: CGRect? {
        didSet {
            invalidateViews()
        }
    }
    private var mouseLocation: CGPoint? { didSet { invalidateViews() } }
    private var dragMode: DragMode?
    private var dragOrigin: CGPoint = .zero
    private var initialSelection: CGRect?
    private var confirmedResizePointerOffset: CGPoint = .zero
    private var isSpacePressed = false
    private var draftCropTask: Task<CapturedImage, Error>?
    private var draftPresentationTask: Task<Void, Never>?
    private var isPreparingDraft = false {
        didSet {
            invalidateViews()
        }
    }
    private var isConfirmingSelection = false {
        didSet {
            invalidateViews()
            updateOverlayInputOwnership()
        }
    }
    /// Overlay blue chrome stays until the confirmation panel is ordered front,
    /// so mouse-up does not briefly remove the border before the draft surface
    /// appears (that handoff read as a one-frame layout jump).
    private var hidesOverlaySelectionChrome = false {
        didSet {
            guard hidesOverlaySelectionChrome != oldValue else { return }
            invalidateViews()
        }
    }
    private var isSelectionLocked: Bool { isPreparingDraft || isConfirmingSelection }

    init(
        pinnedShotManager: PinnedShotManager,
        elementResolver: InterfaceElementSelectionResolver = InterfaceElementSelectionResolver()
    ) {
        self.pinnedShotManager = pinnedShotManager
        elementResolutionHandler = { point, window, primaryDisplayHeight in
            elementResolver.resolve(
                at: point,
                in: window,
                primaryDisplayHeight: primaryDisplayHeight
            )
        }
    }

    init(
        pinnedShotManager: PinnedShotManager,
        elementResolutionHandler: @escaping ElementResolutionHandler
    ) {
        self.pinnedShotManager = pinnedShotManager
        self.elementResolutionHandler = elementResolutionHandler
    }

    /// Logical region corner radius from Capture settings for overlay drawing.
    fileprivate func configuredCornerRadius(backingScale: CGFloat) -> CGFloat {
        pinnedShotManager.configuredRegionCornerRadius(backingScale: backingScale)
    }

    func select(
        from preparation: RegionCapturePreparation,
        recognizesInterfaceElements: Bool = true
    ) async throws -> CGRect {
        guard continuation == nil else {
            throw ScreenshotAppError.captureFailed(description: "Region selection is already active.")
        }
        guard !preparation.displays.isEmpty else { throw ScreenshotAppError.noDisplayAvailable }
        self.preparation = preparation
        self.recognizesInterfaceElements = recognizesInterfaceElements
        self.selection = nil
        self.mouseLocation = NSEvent.mouseLocation
        self.snapCandidate = nil
        self.snapCandidateKind = nil
        self.snapTargets = []
        self.selectedSnapTargetIndex = 0
        self.snapWindowID = nil
        self.snapLevelWasUserAdjusted = false
        self.hierarchyScrollAccumulator = 0
        self.interfaceElementToWindowFallbackCount = 0
        self.pendingElementResolution = nil
        self.didLogMissingAccessibilityPermission = false

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            present(preparation: preparation)
        }
    }

    fileprivate func mouseMoved(to point: CGPoint) {
        mouseLocation = point
        guard !isSelectionLocked, dragMode == nil else { return }
        updateSnapCandidate(at: point)
    }

    fileprivate func mouseDown(at point: CGPoint) {
        guard !isSelectionLocked else {
            if isConfirmingSelection {
                AppLog.capture.error(
                    "Region confirmation overlay received a pointer event after ownership moved to the annotation surface: x=\(point.x, privacy: .public), y=\(point.y, privacy: .public)"
                )
            }
            return
        }
        mouseLocation = point

        dragOrigin = point
        initialSelection = selection
        if selection == nil,
           let snapCandidate,
           snapCandidate.contains(point)
        {
            guard let snapCandidateKind else {
                preconditionFailure("A smart region candidate must retain its source kind until pointer-down.")
            }
            pendingElementResolution = nil
            elementResolutionTask?.cancel()
            elementResolutionGeneration &+= 1
            AppLog.capture.notice(
                "Accepted smart region candidate: kind=\(snapCandidateKind.rawValue, privacy: .public), x=\(snapCandidate.minX, privacy: .public), y=\(snapCandidate.minY, privacy: .public), width=\(snapCandidate.width, privacy: .public), height=\(snapCandidate.height, privacy: .public)"
            )
            self.selection = snapCandidate
            initialSelection = snapCandidate
            self.snapCandidate = nil
            self.snapCandidateKind = nil
            snapTargets = []
            selectedSnapTargetIndex = 0
            snapWindowID = nil
            snapLevelWasUserAdjusted = false
            dragMode = .snappedCandidate
        } else if let selection, let handle = resizeHandle(at: point, selection: selection) {
            dragMode = .resizing(handle)
        } else if let selection, selection.contains(point) || isSpacePressed {
            dragMode = .moving
        } else {
            // Anchor creating on a whole-point origin so live size matches the
            // mouse-up canonical frame (avoids Int-truncation display vs
            // CGRect.integral expansion: e.g. 504→505).
            let origin = wholeDesktopPoint(point)
            dragOrigin = origin
            selection = CGRect(origin: origin, size: .zero)
            initialSelection = selection
            dragMode = .creating
        }
        invalidateViews()
    }

    fileprivate func mouseDragged(to point: CGPoint) {
        guard !isSelectionLocked else { return }
        updateActiveDrag(to: point)
    }

    private func updateActiveDrag(to point: CGPoint) {
        mouseLocation = point
        guard let dragMode, let bounds = preparation?.geometry.desktopBounds else { return }
        let constrainedPoint = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )

        switch dragMode {
        case .creating:
            selection = liveSelectionFrame(
                from: CGRect(
                    x: min(dragOrigin.x, constrainedPoint.x),
                    y: min(dragOrigin.y, constrainedPoint.y),
                    width: abs(constrainedPoint.x - dragOrigin.x),
                    height: abs(constrainedPoint.y - dragOrigin.y)
                )
            )
        case .snappedCandidate:
            let distance = hypot(
                constrainedPoint.x - dragOrigin.x,
                constrainedPoint.y - dragOrigin.y
            )
            guard distance >= 4 else { return }
            self.dragMode = .creating
            selection = liveSelectionFrame(
                from: CGRect(
                    x: min(dragOrigin.x, constrainedPoint.x),
                    y: min(dragOrigin.y, constrainedPoint.y),
                    width: abs(constrainedPoint.x - dragOrigin.x),
                    height: abs(constrainedPoint.y - dragOrigin.y)
                )
            )
        case .moving:
            guard let initialSelection else { return }
            let offset = CGPoint(x: point.x - dragOrigin.x, y: point.y - dragOrigin.y)
            selection = liveSelectionFrame(
                from: constrained(
                    initialSelection.offsetBy(dx: offset.x, dy: offset.y),
                    to: bounds
                )
            )
        case .resizing(let handle):
            guard let initialSelection else { return }
            selection = liveSelectionFrame(
                from: resized(
                    initialSelection,
                    handle: handle,
                    point: constrainedPoint,
                    bounds: bounds
                )
            )
        }
    }

    fileprivate func mouseUp() {
        guard !isSelectionLocked else { return }
        guard dragMode != nil else { return }
        dragMode = nil
        initialSelection = nil
        guard let selection, selection.width >= 2, selection.height >= 2 else {
            self.selection = nil
            invalidateViews()
            return
        }
        guard let preparation else {
            preconditionFailure("A completed region selection must retain its frozen capture preparation.")
        }
        let selectedRegion = canonicalSelectionFrame(selection)
        self.selection = selectedRegion
        let preparationStartedAt = ProcessInfo.processInfo.systemUptime
        isPreparingDraft = true
        AppLog.capture.notice(
            "Region draft preparation started off main actor: x=\(selectedRegion.origin.x, privacy: .public), y=\(selectedRegion.origin.y, privacy: .public), width=\(selectedRegion.width, privacy: .public), height=\(selectedRegion.height, privacy: .public)"
        )

        let cropTask = Task.detached(priority: .userInitiated) {
            try RegionCaptureProcessor().crop(selectedRegion, from: preparation)
        }
        draftCropTask = cropTask
        draftPresentationTask = Task { @MainActor [weak self, cropTask] in
            do {
                let capturedImage = try await cropTask.value
                try Task.checkCancellation()
                guard let self, self.isPreparingDraft, self.continuation != nil else { return }
                let cropFinishedAt = ProcessInfo.processInfo.systemUptime
                // Admit confirmation input ownership first, but keep overlay
                // chrome painted until the draft panel is fully positioned and
                // ordered front to avoid a one-frame border/frame jump.
                self.isConfirmingSelection = true
                self.isPreparingDraft = false
                self.hidesOverlaySelectionChrome = false
                self.pinnedShotManager.presentRegionDraft(
                    capturedImage,
                    onPin: { [weak self] in self?.completeSelection(using: .pin) },
                    onCopy: { [weak self] in self?.completeSelection(using: .copy) },
                    onSave: { [weak self] in self?.completeSelection(using: .save) },
                    onCancel: { [weak self] in self?.finishCancellation() },
                    onResizeBegan: { [weak self] handle, point in
                        self?.beginConfirmedResize(handle: handle, at: point)
                    },
                    onResizeChanged: { [weak self] point in
                        self?.updateConfirmedResize(to: point)
                    },
                    onResizeEnded: { [weak self] point in
                        self?.endConfirmedResize(at: point)
                    },
                    onMoveBegan: { [weak self] point in
                        self?.beginConfirmedMove(at: point)
                    },
                    onMoveChanged: { [weak self] point in
                        self?.updateConfirmedMove(to: point)
                    },
                    onMoveEnded: { [weak self] point in
                        self?.endConfirmedMove(at: point)
                    }
                )
                self.hidesOverlaySelectionChrome = true
                self.views.forEach { $0.displayIfNeeded() }
                self.draftCropTask = nil
                self.draftPresentationTask = nil
                let readyAt = ProcessInfo.processInfo.systemUptime
                AppLog.capture.notice(
                    "Region selection entered editable confirmation: x=\(selection.origin.x, privacy: .public), y=\(selection.origin.y, privacy: .public), width=\(selection.width, privacy: .public), height=\(selection.height, privacy: .public), cropMs=\((cropFinishedAt - preparationStartedAt) * 1_000, privacy: .public), totalMs=\((readyAt - preparationStartedAt) * 1_000, privacy: .public), toolbar=full, selectionResize=true"
                )
            } catch is CancellationError {
                AppLog.capture.debug("Cancelled region draft preparation before presentation")
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.draftCropTask = nil
                self.draftPresentationTask = nil
                self.isPreparingDraft = false
                self.fail(with: error)
            }
        }
    }

    fileprivate func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            if dragMode != nil {
                selection = initialSelection
                dragMode = nil
                initialSelection = nil
                isConfirmingSelection = selection.map(isValidSelection) ?? false
            } else {
                cancel()
            }
        case 36, 76:
            if isConfirmingSelection {
                pinnedShotManager.pinCurrentRegionDraft()
            } else {
                NSSound.beep()
            }
        case 49:
            if !isSelectionLocked { isSpacePressed = true }
        case 123, 124, 125, 126:
            if !isSelectionLocked,
               selection == nil,
               event.modifierFlags.contains(.option),
               (event.keyCode == 125 || event.keyCode == 126)
            {
                cycleSnapTarget(
                    towardParent: event.keyCode == 126,
                    reason: "option-arrow"
                )
            } else if !isSelectionLocked {
                nudgeSelection(keyCode: event.keyCode, largeStep: event.modifierFlags.contains(.shift))
            }
        default:
            break
        }
    }

    fileprivate func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { isSpacePressed = false }
    }

    fileprivate func drawState(for panelFrame: CGRect) -> RegionOverlayDrawState {
        let displayedSelection = selection ?? snapCandidate
        let selectionPixelSize = displayedSelection.flatMap(physicalPixelSize)
        let magnifierInteraction: String
        switch dragMode {
        case nil: magnifierInteraction = "hover"
        case .creating?: magnifierInteraction = "creating"
        case .snappedCandidate?: magnifierInteraction = "snapped-candidate"
        case .moving?: magnifierInteraction = "moving"
        case .resizing?: magnifierInteraction = "resizing"
        }
        let showsMagnifier: Bool
        if case .moving? = dragMode {
            showsMagnifier = false
        } else {
            showsMagnifier = !isSelectionLocked
        }
        return RegionOverlayDrawState(
            selection: displayedSelection,
            selectionPixelSize: selectionPixelSize,
            mouseLocation: mouseLocation,
            handles: selection.map(handlePoints) ?? [],
            panelFrame: panelFrame,
            showsMagnifier: showsMagnifier,
            magnifierInteraction: magnifierInteraction,
            showsConfirmationSurface: isConfirmingSelection,
            showsSelectionChrome: !hidesOverlaySelectionChrome,
            acceptsPointerInput: !isConfirmingSelection,
            snapCandidateKind: selection == nil ? snapCandidateKind?.rawValue : nil,
            snapCandidateLevel: selection == nil && !snapTargets.isEmpty
                ? selectedSnapTargetIndex + 1
                : nil,
            snapCandidateLevelCount: selection == nil && !snapTargets.isEmpty
                ? snapTargets.count
                : nil,
            snapStabilityFallbacks: interfaceElementToWindowFallbackCount
        )
    }

    private func physicalPixelSize(for selection: CGRect) -> CGSize? {
        guard let preparation else { return nil }
        let intersectingScales = preparation.displays.compactMap { capture -> CGFloat? in
            let intersection = selection.intersection(capture.descriptor.frame)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0
            else { return nil }
            return capture.descriptor.scale
        }
        guard let outputScale = intersectingScales.max() else { return nil }
        return CGSize(
            width: ceil(selection.width * outputScale),
            height: ceil(selection.height * outputScale)
        )
    }

    private func updateSnapCandidate(at point: CGPoint) {
        guard recognizesInterfaceElements,
              let preparation,
              let window = WindowSelectionResolver().topmostWindow(
                at: point,
                candidates: preparation.windows
              )
        else {
            clearSnapCandidates(reason: "no-window")
            return
        }

        let windowFrame = canonicalSelectionFrame(window.frame)
        guard isValidSelection(windowFrame) else {
            clearSnapCandidates(reason: "invalid-window")
            return
        }

        if snapWindowID != window.id || snapTargets.isEmpty {
            publishSnapTargets(
                [SnapTarget(frame: windowFrame, kind: .window)],
                selectedIndex: 0,
                windowID: window.id,
                userAdjusted: false,
                reason: "window-hit"
            )
        }

        pendingElementResolution = ElementResolutionRequest(
            point: point,
            window: window,
            lifecycleGeneration: elementResolutionGeneration
        )
        startElementResolutionPipelineIfNeeded()
    }

    private func startElementResolutionPipelineIfNeeded() {
        guard elementResolutionTask == nil, pendingElementResolution != nil else { return }
        elementResolutionTask = Task { @MainActor [weak self] in
            await self?.runElementResolutionPipeline()
        }
    }

    private func runElementResolutionPipeline() async {
        while !Task.isCancelled, let request = pendingElementResolution {
            pendingElementResolution = nil
            let resolutionHandler = elementResolutionHandler
            let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
            let resolution = await Task.detached(priority: .userInitiated) {
                resolutionHandler(request.point, request.window, primaryDisplayHeight)
            }.value
            guard !Task.isCancelled,
                  request.lifecycleGeneration == elementResolutionGeneration,
                  dragMode == nil,
                  !isSelectionLocked,
                  snapWindowID == request.window.id
            else { continue }
            applyElementResolution(resolution, request: request)
        }
        elementResolutionTask = nil
        startElementResolutionPipelineIfNeeded()
    }

    private func applyElementResolution(
        _ resolution: InterfaceElementResolution,
        request: ElementResolutionRequest
    ) {
        guard let point = mouseLocation else { return }
        let windowFrame = canonicalSelectionFrame(request.window.frame)
        switch resolution {
        case .elementHierarchy(let frames):
            var controlFrames = frames
                .map(canonicalSelectionFrame)
                .filter {
                    isValidSelection($0)
                        && $0.contains(point)
                        && $0 != windowFrame
                }
            if snapCandidateKind == .interfaceElement,
               let snapCandidate,
               snapCandidate.contains(point),
               !controlFrames.contains(snapCandidate)
            {
                // The frozen target cannot move underneath the overlay. Retain
                // a previously verified frame when a web accessibility tree
                // transiently returns a different descendant path.
                controlFrames.append(snapCandidate)
            }
            controlFrames = controlFrames.reduce(into: []) { result, frame in
                if !result.contains(frame) {
                    result.append(frame)
                }
            }.sorted {
                $0.width * $0.height < $1.width * $1.height
            }
            guard !controlFrames.isEmpty else {
                if pendingElementResolution != nil { return }
                publishWindowFallback(
                    frame: windowFrame,
                    windowID: request.window.id,
                    reason: "no-current-control"
                )
                return
            }

            let targets = controlFrames.map {
                SnapTarget(frame: $0, kind: .interfaceElement)
            } + [SnapTarget(frame: windowFrame, kind: .window)]
            let selectedIndex = selectedIndex(
                in: targets,
                preserving: snapCandidate,
                userAdjusted: snapLevelWasUserAdjusted
            )
            publishSnapTargets(
                targets,
                selectedIndex: selectedIndex,
                windowID: request.window.id,
                userAdjusted: snapLevelWasUserAdjusted,
                reason: "accessibility-hierarchy"
            )
        case .accessibilityPermissionRequired:
            if snapCandidateKind != .interfaceElement || snapCandidate?.contains(point) != true {
                publishWindowFallback(
                    frame: windowFrame,
                    windowID: request.window.id,
                    reason: "accessibility-permission"
                )
            }
            guard !didLogMissingAccessibilityPermission else { return }
            didLogMissingAccessibilityPermission = true
            AppLog.capture.notice(
                "Interface-element snapping is limited to window frames until Accessibility permission is granted"
            )
        case .noElement:
            if snapCandidateKind == .interfaceElement, snapCandidate?.contains(point) == true {
                return
            }
            if pendingElementResolution != nil { return }
            publishWindowFallback(
                frame: windowFrame,
                windowID: request.window.id,
                reason: "no-accessibility-element"
            )
        }
    }

    private func selectedIndex(
        in targets: [SnapTarget],
        preserving previousFrame: CGRect?,
        userAdjusted: Bool
    ) -> Int {
        if let previousFrame,
           let matchedIndex = targets.firstIndex(where: { $0.frame == previousFrame }),
           (snapCandidateKind == .interfaceElement || userAdjusted)
        {
            return matchedIndex
        }
        guard userAdjusted, !snapTargets.isEmpty else { return 0 }
        let previousLevelFromWindow = snapTargets.count - 1 - selectedSnapTargetIndex
        return max(0, targets.count - 1 - previousLevelFromWindow)
    }

    private func publishWindowFallback(
        frame: CGRect,
        windowID: CGWindowID,
        reason: String
    ) {
        publishSnapTargets(
            [SnapTarget(frame: frame, kind: .window)],
            selectedIndex: 0,
            windowID: windowID,
            userAdjusted: false,
            reason: reason
        )
    }

    private func publishSnapTargets(
        _ targets: [SnapTarget],
        selectedIndex: Int,
        windowID: CGWindowID,
        userAdjusted: Bool,
        reason: String
    ) {
        precondition(!targets.isEmpty, "Smart region snapping requires at least one target.")
        precondition(targets.indices.contains(selectedIndex), "Smart region snap level is out of range.")
        let previousKind = snapCandidateKind
        let previousFrame = snapCandidate
        let previousWindowID = snapWindowID
        let previousLevel = selectedSnapTargetIndex
        let previousLevelCount = snapTargets.count
        let target = targets[selectedIndex]
        if previousKind == .interfaceElement,
           target.kind == .window,
           previousWindowID == windowID,
           !userAdjusted
        {
            interfaceElementToWindowFallbackCount += 1
        }
        snapTargets = targets
        selectedSnapTargetIndex = selectedIndex
        snapWindowID = windowID
        snapLevelWasUserAdjusted = userAdjusted
        snapCandidate = target.frame
        snapCandidateKind = target.kind
        if previousLevel != selectedIndex || previousLevelCount != targets.count {
            invalidateViews()
        }
        guard previousKind != target.kind || previousFrame != target.frame else { return }
        AppLog.capture.debug(
            "Smart region target changed: reason=\(reason, privacy: .public), windowID=\(windowID, privacy: .public), kind=\(target.kind.rawValue, privacy: .public), level=\(selectedIndex + 1, privacy: .public)/\(targets.count, privacy: .public), x=\(target.frame.minX, privacy: .public), y=\(target.frame.minY, privacy: .public), width=\(target.frame.width, privacy: .public), height=\(target.frame.height, privacy: .public)"
        )
    }

    private func clearSnapCandidates(reason: String) {
        let hadCandidate = snapCandidate != nil
        pendingElementResolution = nil
        elementResolutionTask?.cancel()
        elementResolutionGeneration &+= 1
        snapTargets = []
        selectedSnapTargetIndex = 0
        snapWindowID = nil
        snapLevelWasUserAdjusted = false
        hierarchyScrollAccumulator = 0
        snapCandidate = nil
        snapCandidateKind = nil
        if hadCandidate {
            AppLog.capture.debug(
                "Cleared smart region target: reason=\(reason, privacy: .public)"
            )
        }
    }

    private func cycleSnapTarget(towardParent: Bool, reason: String) {
        guard selection == nil,
              !isSelectionLocked,
              dragMode == nil,
              let point = mouseLocation,
              !snapTargets.isEmpty
        else { return }
        let validTargets = snapTargets.filter { $0.frame.contains(point) }
        guard validTargets.count > 1 else { return }
        let currentIndex = validTargets.firstIndex {
            $0.frame == snapCandidate && $0.kind == snapCandidateKind
        } ?? 0
        let targetIndex = min(
            max(0, currentIndex + (towardParent ? 1 : -1)),
            validTargets.count - 1
        )
        guard targetIndex != currentIndex, let windowID = snapWindowID else {
            NSSound.beep()
            return
        }
        publishSnapTargets(
            validTargets,
            selectedIndex: targetIndex,
            windowID: windowID,
            userAdjusted: true,
            reason: reason
        )
    }

    fileprivate func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option),
              event.momentumPhase.isEmpty,
              !isSelectionLocked,
              selection == nil
        else { return }
        if event.phase.contains(.began) {
            hierarchyScrollAccumulator = 0
        }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        hierarchyScrollAccumulator += event.scrollingDeltaY * multiplier
        let threshold: CGFloat = 18
        if abs(hierarchyScrollAccumulator) >= threshold {
            cycleSnapTarget(
                towardParent: hierarchyScrollAccumulator > 0,
                reason: "option-scroll"
            )
            hierarchyScrollAccumulator = 0
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            hierarchyScrollAccumulator = 0
        }
    }

    private func updateOverlayInputOwnership() {
        panels.forEach { $0.ignoresMouseEvents = isConfirmingSelection }
        guard !panels.isEmpty else { return }
        AppLog.capture.notice(
            "Region input ownership changed: confirmation=\(self.isConfirmingSelection, privacy: .public), overlayMouseEvents=\(self.isConfirmingSelection ? "ignored" : "enabled", privacy: .public), owner=\(self.isConfirmingSelection ? "annotation-surface" : "selection-overlay", privacy: .public), overlays=\(self.panels.count, privacy: .public)"
        )
    }

    private func beginConfirmedResize(
        handle: RegionSelectionResizeHandle,
        at point: CGPoint
    ) {
        guard isConfirmingSelection,
              !isPreparingDraft,
              dragMode == nil,
              let selection,
              isValidSelection(selection)
        else { return }
        precondition(
            selection == selection.integral,
            "Region confirmation must begin resizing from its canonical whole-point frame."
        )
        dragOrigin = point
        initialSelection = selection
        dragMode = .resizing(handle)
        let anchor = handlePoint(for: handle, in: selection)
        confirmedResizePointerOffset = CGPoint(
            x: anchor.x - point.x,
            y: anchor.y - point.y
        )
        AppLog.capture.notice(
            "Region confirmation resize began: handle=\(String(describing: handle), privacy: .public), x=\(selection.minX, privacy: .public), y=\(selection.minY, privacy: .public), width=\(selection.width, privacy: .public), height=\(selection.height, privacy: .public)"
        )
    }

    private func updateConfirmedResize(to point: CGPoint) {
        guard isConfirmingSelection, !isPreparingDraft, dragMode != nil else { return }
        updateActiveDrag(to: confirmedResizePoint(from: point))
        guard let selection, isValidSelection(selection) else { return }
        let canonicalSelection = canonicalSelectionFrame(selection)
        self.selection = canonicalSelection
        pinnedShotManager.previewCurrentRegionDraftFrame(
            canonicalSelection,
            change: .resizePreservingDesktopAnchors
        )
    }

    private func endConfirmedResize(at point: CGPoint) {
        guard isConfirmingSelection,
              !isPreparingDraft,
              dragMode != nil,
              let previousSelection = initialSelection
        else { return }
        updateActiveDrag(to: confirmedResizePoint(from: point))
        dragMode = nil
        initialSelection = nil
        confirmedResizePointerOffset = .zero
        guard let preparation, let selection
        else {
            self.selection = previousSelection
            pinnedShotManager.previewCurrentRegionDraftFrame(
                previousSelection.integral,
                change: .resizePreservingDesktopAnchors
            )
            return
        }
        let updatedSelection = canonicalSelectionFrame(selection)
        guard isValidSelection(updatedSelection) else {
            self.selection = previousSelection
            pinnedShotManager.previewCurrentRegionDraftFrame(
                previousSelection.integral,
                change: .resizePreservingDesktopAnchors
            )
            return
        }

        self.selection = updatedSelection
        pinnedShotManager.previewCurrentRegionDraftFrame(
            updatedSelection,
            change: .resizePreservingDesktopAnchors
        )
        guard updatedSelection != previousSelection.integral else { return }
        refreshRegionDraft(
            from: previousSelection.integral,
            to: updatedSelection,
            preparation: preparation,
            change: .resizePreservingDesktopAnchors
        )
    }

    private func beginConfirmedMove(at point: CGPoint) {
        guard isConfirmingSelection,
              !isPreparingDraft,
              dragMode == nil,
              let selection,
              isValidSelection(selection)
        else { return }
        _ = pinnedShotManager.endCurrentRegionDraftTextEditing()
        dragOrigin = point
        initialSelection = selection.integral
        dragMode = .moving
        AppLog.capture.notice(
            "Region confirmation move began: x=\(selection.minX, privacy: .public), y=\(selection.minY, privacy: .public), width=\(selection.width, privacy: .public), height=\(selection.height, privacy: .public)"
        )
    }

    private func updateConfirmedMove(to point: CGPoint) {
        guard isConfirmingSelection,
              !isPreparingDraft,
              case .moving? = dragMode
        else { return }
        updateActiveDrag(to: point)
        guard let selection, isValidSelection(selection) else { return }
        let canonicalSelection = canonicalSelectionFrame(selection)
        self.selection = canonicalSelection
        pinnedShotManager.previewCurrentRegionDraftFrame(
            canonicalSelection,
            change: .moveCanvas
        )
    }

    private func endConfirmedMove(at point: CGPoint) {
        guard isConfirmingSelection,
              !isPreparingDraft,
              case .moving? = dragMode,
              let previousSelection = initialSelection,
              let preparation
        else { return }
        updateActiveDrag(to: point)
        dragMode = nil
        initialSelection = nil
        guard let selection else {
            self.selection = previousSelection
            pinnedShotManager.previewCurrentRegionDraftFrame(
                previousSelection,
                change: .moveCanvas
            )
            return
        }
        let updatedSelection = canonicalSelectionFrame(selection)
        guard isValidSelection(updatedSelection) else {
            self.selection = previousSelection
            pinnedShotManager.previewCurrentRegionDraftFrame(
                previousSelection,
                change: .moveCanvas
            )
            return
        }

        self.selection = updatedSelection
        pinnedShotManager.previewCurrentRegionDraftFrame(
            updatedSelection,
            change: .moveCanvas
        )
        guard updatedSelection != previousSelection else { return }
        refreshRegionDraft(
            from: previousSelection,
            to: updatedSelection,
            preparation: preparation,
            change: .moveCanvas
        )
    }

    private func refreshRegionDraft(
        from previousSelection: CGRect,
        to updatedSelection: CGRect,
        preparation: RegionCapturePreparation,
        change: RegionDraftGeometryChange
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        isPreparingDraft = true
        pinnedShotManager.setCurrentRegionDraftGeometryUpdating(true)
        let cropTask = Task.detached(priority: .userInitiated) {
            try RegionCaptureProcessor().crop(updatedSelection, from: preparation)
        }
        draftCropTask = cropTask
        draftPresentationTask = Task { @MainActor [weak self, cropTask] in
            do {
                let capturedImage = try await cropTask.value
                try Task.checkCancellation()
                guard let self,
                      self.isPreparingDraft,
                      self.isConfirmingSelection,
                      self.continuation != nil
                else { return }
                self.pinnedShotManager.updateCurrentRegionDraft(
                    capturedImage,
                    change: change
                )
                self.pinnedShotManager.setCurrentRegionDraftGeometryUpdating(false)
                self.draftCropTask = nil
                self.draftPresentationTask = nil
                self.isPreparingDraft = false
                AppLog.capture.notice(
                    "Region confirmation geometry committed: change=\(change.rawValue, privacy: .public), oldX=\(previousSelection.minX, privacy: .public), oldY=\(previousSelection.minY, privacy: .public), oldWidth=\(previousSelection.width, privacy: .public), oldHeight=\(previousSelection.height, privacy: .public), newX=\(updatedSelection.minX, privacy: .public), newY=\(updatedSelection.minY, privacy: .public), newWidth=\(updatedSelection.width, privacy: .public), newHeight=\(updatedSelection.height, privacy: .public), durationMs=\((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000, privacy: .public)"
                )
            } catch is CancellationError {
                AppLog.capture.debug(
                    "Cancelled region confirmation geometry recrop: change=\(change.rawValue, privacy: .public)"
                )
            } catch {
                guard let self, !Task.isCancelled, self.continuation != nil else { return }
                self.selection = previousSelection
                self.pinnedShotManager.previewCurrentRegionDraftFrame(
                    previousSelection,
                    change: change
                )
                self.pinnedShotManager.setCurrentRegionDraftGeometryUpdating(false)
                self.pinnedShotManager.reportRegionDraftUpdateFailure(error)
                self.draftCropTask = nil
                self.draftPresentationTask = nil
                self.isPreparingDraft = false
                AppLog.capture.error(
                    "Region confirmation geometry rolled back after recrop failure: change=\(change.rawValue, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func completeSelection(using action: OutputAction) {
        guard isConfirmingSelection, let selection, isValidSelection(selection) else {
            NSSound.beep()
            return
        }
        AppLog.capture.notice(
            "Region selection output committed: action=\(action.rawValue, privacy: .public), width=\(selection.width, privacy: .public), height=\(selection.height, privacy: .public)"
        )
        let continuation = self.continuation
        cleanup()
        continuation?.resume(returning: selection.integral)
    }

    private func cancel() {
        if isConfirmingSelection {
            pinnedShotManager.cancelCurrentRegionDraft()
            return
        }
        finishCancellation()
    }

    private func finishCancellation() {
        AppLog.capture.notice("Region selection cancelled")
        let continuation = self.continuation
        cleanup()
        continuation?.resume(throwing: ScreenshotAppError.captureCancelled)
    }

    private func fail(with error: Error) {
        AppLog.capture.error(
            "Region selection failed before editable confirmation: \(error.localizedDescription, privacy: .public)"
        )
        let continuation = self.continuation
        cleanup()
        continuation?.resume(throwing: error)
    }

    private func cleanup() {
        draftPresentationTask?.cancel()
        draftPresentationTask = nil
        draftCropTask?.cancel()
        draftCropTask = nil
        pendingElementResolution = nil
        elementResolutionTask?.cancel()
        elementResolutionGeneration &+= 1
        isPreparingDraft = false
        isConfirmingSelection = false
        hidesOverlaySelectionChrome = false
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        continuation = nil
        preparation = nil
        selection = nil
        snapCandidate = nil
        snapCandidateKind = nil
        snapTargets = []
        selectedSnapTargetIndex = 0
        snapWindowID = nil
        snapLevelWasUserAdjusted = false
        hierarchyScrollAccumulator = 0
        interfaceElementToWindowFallbackCount = 0
        mouseLocation = nil
        dragMode = nil
        initialSelection = nil
        confirmedResizePointerOffset = .zero
        isSpacePressed = false
        didLogMissingAccessibilityPermission = false
    }

    private func present(preparation: RegionCapturePreparation) {
        var keyPanel: SelectionOverlayPanel?
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard
                let displayID = screenDisplayID(screen),
                let capture = preparation.displays.first(where: { $0.descriptor.id == displayID })
            else { continue }
            let view = RegionSelectionOverlayView(capture: capture, coordinator: self)
            let panel = SelectionOverlayPanel(screen: screen, contentView: view)
            panel.acceptsMouseMovedEvents = true
            panels.append(panel)
            views.append(view)
            panel.orderFrontRegardless()
            if screen.frame.contains(mouse) { keyPanel = panel }
        }
        let panel = keyPanel ?? panels.first
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panel?.contentView)
    }

    private func isValidSelection(_ selection: CGRect) -> Bool {
        selection.width >= 2 && selection.height >= 2
    }

    private func canonicalSelectionFrame(_ selection: CGRect) -> CGRect {
        guard let bounds = preparation?.geometry.desktopBounds else {
            preconditionFailure("Canonical region geometry requires its frozen desktop bounds.")
        }
        let canonical = selection.standardized.integral.intersection(bounds)
        precondition(
            canonical == canonical.integral,
            "The frozen desktop bounds must preserve a whole-point region frame."
        )
        return canonical
    }

    /// Live selection uses the same whole-point frame as mouse-up commit so the
    /// size badge cannot show a truncated fractional size and then jump after
    /// `CGRect.integral` expands the rect by a point.
    private func liveSelectionFrame(from selection: CGRect) -> CGRect {
        let standardized = selection.standardized
        guard isValidSelection(standardized) else { return standardized }
        return canonicalSelectionFrame(standardized)
    }

    private func wholeDesktopPoint(_ point: CGPoint) -> CGPoint {
        guard let bounds = preparation?.geometry.desktopBounds else {
            return CGPoint(x: point.x.rounded(.down), y: point.y.rounded(.down))
        }
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        return CGPoint(x: clamped.x.rounded(.down), y: clamped.y.rounded(.down))
    }

    private func invalidateViews() {
        views.forEach { $0.needsDisplay = true }
    }

    private func constrained(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var rect = rect
        if rect.minX < bounds.minX { rect.origin.x += bounds.minX - rect.minX }
        if rect.maxX > bounds.maxX { rect.origin.x -= rect.maxX - bounds.maxX }
        if rect.minY < bounds.minY { rect.origin.y += bounds.minY - rect.minY }
        if rect.maxY > bounds.maxY { rect.origin.y -= rect.maxY - bounds.maxY }
        return rect
    }

    private func resized(
        _ rect: CGRect,
        handle: RegionSelectionResizeHandle,
        point: CGPoint,
        bounds: CGRect
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch handle {
        case .northWest: minX = point.x; maxY = point.y
        case .north: maxY = point.y
        case .northEast: maxX = point.x; maxY = point.y
        case .east: maxX = point.x
        case .southEast: maxX = point.x; minY = point.y
        case .south: minY = point.y
        case .southWest: minX = point.x; minY = point.y
        case .west: minX = point.x
        }
        if maxX - minX < 2 {
            if [.northWest, .southWest, .west].contains(handle) { minX = maxX - 2 }
            else { maxX = minX + 2 }
        }
        if maxY - minY < 2 {
            if [.southEast, .south, .southWest].contains(handle) { minY = maxY - 2 }
            else { maxY = minY + 2 }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(bounds)
    }

    private func resizeHandle(at point: CGPoint, selection: CGRect) -> RegionSelectionResizeHandle? {
        resizeHitRegions(selection).first { _, rect in rect.contains(point) }?.0
    }

    private func resizeHitRegions(_ selection: CGRect) -> [(RegionSelectionResizeHandle, CGRect)] {
        let rect = selection.standardized
        let hitThickness: CGFloat = 12
        let half = hitThickness / 2
        let cornerSpan = hitThickness
        let horizontalLength = max(0, rect.width - cornerSpan * 2)
        let verticalLength = max(0, rect.height - cornerSpan * 2)
        return [
            (.northWest, CGRect(x: rect.minX - half, y: rect.maxY - half, width: hitThickness, height: hitThickness)),
            (.northEast, CGRect(x: rect.maxX - half, y: rect.maxY - half, width: hitThickness, height: hitThickness)),
            (.southEast, CGRect(x: rect.maxX - half, y: rect.minY - half, width: hitThickness, height: hitThickness)),
            (.southWest, CGRect(x: rect.minX - half, y: rect.minY - half, width: hitThickness, height: hitThickness)),
            (.north, CGRect(x: rect.minX + cornerSpan, y: rect.maxY - half, width: horizontalLength, height: hitThickness)),
            (.east, CGRect(x: rect.maxX - half, y: rect.minY + cornerSpan, width: hitThickness, height: verticalLength)),
            (.south, CGRect(x: rect.minX + cornerSpan, y: rect.minY - half, width: horizontalLength, height: hitThickness)),
            (.west, CGRect(x: rect.minX - half, y: rect.minY + cornerSpan, width: hitThickness, height: verticalLength))
        ]
    }

    private func handlePoints(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY)
        ]
    }

    private func handlePoint(
        for handle: RegionSelectionResizeHandle,
        in rect: CGRect
    ) -> CGPoint {
        guard let index = RegionSelectionResizeHandle.allCases.firstIndex(of: handle) else {
            preconditionFailure("Every region resize handle must have a matching anchor point.")
        }
        return handlePoints(rect)[index]
    }

    private func confirmedResizePoint(from pointer: CGPoint) -> CGPoint {
        CGPoint(
            x: pointer.x + confirmedResizePointerOffset.x,
            y: pointer.y + confirmedResizePointerOffset.y
        )
    }

    private func nudgeSelection(keyCode: UInt16, largeStep: Bool) {
        guard let selection, let bounds = preparation?.geometry.desktopBounds else { return }
        let step: CGFloat = largeStep ? 10 : 1
        let delta: CGPoint
        switch keyCode {
        case 123: delta = CGPoint(x: -step, y: 0)
        case 124: delta = CGPoint(x: step, y: 0)
        case 125: delta = CGPoint(x: 0, y: -step)
        default: delta = CGPoint(x: 0, y: step)
        }
        self.selection = constrained(selection.offsetBy(dx: delta.x, dy: delta.y), to: bounds)
    }
}

private final class SelectionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, contentView: NSView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }
}

private final class DisplaySelectionOverlayView: NSView {
    var onSelect: (() -> Void)?
    var onCancel: (() -> Void)?
    private let descriptor: DisplayDescriptor
    private let number: Int

    init(descriptor: DisplayDescriptor, number: Int) {
        self.descriptor = descriptor
        self.number = number
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(
            format: NSLocalizedString("Select %@", comment: "Display selection accessibility label"),
            descriptor.name
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 || event.keyCode == 76 { onSelect?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.48).setFill()
        bounds.fill()
        let card = NSRect(x: bounds.midX - 145, y: bounds.midY - 70, width: 290, height: 140)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        border.lineWidth = 3
        border.stroke()

        drawCentered("\(number)", size: 36, weight: .bold, y: card.midY + 18)
        drawCentered(descriptor.name, size: 15, weight: .semibold, y: card.midY - 18)
        let resolution = "\(Int(descriptor.pixelSize.width)) × \(Int(descriptor.pixelSize.height)) px"
        drawCentered(resolution, size: 12, weight: .regular, y: card.midY - 43)
    }

    private func drawCentered(_ text: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - textSize.width / 2, y: y - textSize.height / 2), withAttributes: attributes)
    }
}

private final class WindowSelectionOverlayView: NSView {
    var highlightedWindow: WindowDescriptor?
    var onMove: ((CGPoint) -> Void)?
    var onSelect: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
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
    override func mouseMoved(with event: NSEvent) { onMove?(globalPoint(for: event)) }
    override func mouseDragged(with event: NSEvent) { onMove?(globalPoint(for: event)) }
    override func mouseDown(with event: NSEvent) { onSelect?(globalPoint(for: event)) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()
        guard let highlightedWindow, let window else { return }
        let local = highlightedWindow.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: local, xRadius: 8, yRadius: 8).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: local.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        border.lineWidth = 4
        border.stroke()
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        let local = event.locationInWindow
        return CGPoint(x: window.frame.minX + local.x, y: window.frame.minY + local.y)
    }
}

private struct RegionOverlayDrawState {
    let selection: CGRect?
    let selectionPixelSize: CGSize?
    let mouseLocation: CGPoint?
    let handles: [CGPoint]
    let panelFrame: CGRect
    let showsMagnifier: Bool
    let magnifierInteraction: String
    let showsConfirmationSurface: Bool
    let showsSelectionChrome: Bool
    let acceptsPointerInput: Bool
    let snapCandidateKind: String?
    let snapCandidateLevel: Int?
    let snapCandidateLevelCount: Int?
    let snapStabilityFallbacks: Int
}

private final class RegionSelectionOverlayView: NSView {
    private struct MagnifierMetrics {
        let pixelX: Int
        let pixelY: Int
        let selectionPixelSize: CGSize?
        let snapCandidateKind: String?
        let snapCandidateLevel: Int?
        let snapCandidateLevelCount: Int?
    }

    private let capture: DisplayCapture
    private let frozenImage: NSImage
    private weak var coordinator: RegionSelectionCoordinator?
    private var trackingAreaReference: NSTrackingArea?

    init(capture: DisplayCapture, coordinator: RegionSelectionCoordinator) {
        self.capture = capture
        frozenImage = NSImage(
            cgImage: capture.capturedImage.image,
            size: capture.descriptor.frame.size
        )
        self.coordinator = coordinator
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Capture region selection", comment: "Region selection overlay"))
        setAccessibilityIdentifier("capture.region.overlay")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }

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

    override func mouseMoved(with event: NSEvent) { coordinator?.mouseMoved(to: globalPoint(for: event)) }
    override func mouseDown(with event: NSEvent) {
        coordinator?.mouseDown(at: globalPoint(for: event))
    }
    override func mouseDragged(with event: NSEvent) {
        coordinator?.mouseDragged(to: globalPoint(for: event))
    }
    override func mouseUp(with event: NSEvent) { coordinator?.mouseUp() }
    override func scrollWheel(with event: NSEvent) { coordinator?.scrollWheel(with: event) }
    override func keyDown(with event: NSEvent) { coordinator?.keyDown(with: event) }
    override func keyUp(with event: NSEvent) { coordinator?.keyUp(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let coordinator else { return }
        let state = coordinator.drawState(for: window.frame)
        let magnifierMetrics = state.mouseLocation.flatMap { mouse in
            state.showsMagnifier && state.panelFrame.contains(mouse)
                ? self.magnifierMetrics(
                    at: mouse,
                    panelFrame: state.panelFrame,
                    selectionPixelSize: state.selectionPixelSize,
                    snapCandidateKind: state.snapCandidateKind,
                    snapCandidateLevel: state.snapCandidateLevel,
                    snapCandidateLevelCount: state.snapCandidateLevelCount
                )
                : nil
        }
        let magnifierSelection = magnifierMetrics?.selectionPixelSize.map {
            "\(Int($0.width))x\(Int($0.height))"
        } ?? "none"
        setAccessibilityValue(
            "selectionChrome=\(state.showsSelectionChrome ? "visible" : "hidden"); confirmationSurface=\(state.showsConfirmationSurface ? "visible" : "hidden"); overlayInput=\(state.acceptsPointerInput ? "enabled" : "ignored"); snap=\(state.snapCandidateKind ?? "none"); snapLevel=\(state.snapCandidateLevel.map(String.init) ?? "none")/\(state.snapCandidateLevelCount.map(String.init) ?? "none"); snapStabilityFallbacks=\(state.snapStabilityFallbacks); magnifier=\(magnifierMetrics == nil ? "hidden" : "visible"); magnifierInteraction=\(state.magnifierInteraction); magnifierPixel=\(magnifierMetrics.map { "\($0.pixelX),\($0.pixelY)" } ?? "none"); magnifierSelection=\(magnifierSelection); magnifierTarget=\(magnifierMetrics?.snapCandidateKind ?? "none"); magnifierGrid=1px; magnifierCenter=crosshair"
        )
        drawFrozenImage()
        NSColor.black.withAlphaComponent(0.34).setFill()
        bounds.fill()

        if let selection = state.selection {
            let localSelection = selection.offsetBy(dx: -state.panelFrame.minX, dy: -state.panelFrame.minY)
            let configuredRadius = coordinator.configuredCornerRadius(
                backingScale: capture.descriptor.scale
            )
            let cornerRadius = RegionCaptureCornerRadius.effective(
                for: selection.size,
                configured: configuredRadius
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(
                roundedRect: localSelection,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).addClip()
            drawFrozenImage()
            NSGraphicsContext.restoreGraphicsState()

            if state.showsSelectionChrome {
                NSColor.systemBlue.setStroke()
                // Selection is whole-point after live canonicalization; only
                // inset for the stroke—do not re-integral or the frame grows.
                let borderRect = localSelection.insetBy(dx: 0.5, dy: 0.5)
                let borderRadius = RegionCaptureCornerRadius.effective(
                    for: borderRect.size,
                    configured: configuredRadius
                )
                let border = NSBezierPath(
                    roundedRect: borderRect,
                    xRadius: borderRadius,
                    yRadius: borderRadius
                )
                border.lineWidth = 2
                border.stroke()
                drawHandles(state.handles, panelFrame: state.panelFrame)
            }
            if magnifierMetrics == nil {
                drawSize(
                    selection: selection,
                    selectionPixelSize: state.selectionPixelSize,
                    localRect: localSelection
                )
            }
        }
        if let mouse = state.mouseLocation,
           let magnifierMetrics
        {
            drawMagnifier(
                at: mouse,
                panelFrame: state.panelFrame,
                metrics: magnifierMetrics
            )
        }
    }

    private func drawFrozenImage() {
        frozenImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    private func drawHandles(_ handles: [CGPoint], panelFrame: CGRect) {
        for point in handles where panelFrame.insetBy(dx: -6, dy: -6).contains(point) {
            let local = CGPoint(x: point.x - panelFrame.minX, y: point.y - panelFrame.minY)
            let rect = CGRect(x: local.x - 4, y: local.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.systemBlue.setStroke()
            NSBezierPath(ovalIn: rect).stroke()
        }
    }

    private func drawSize(
        selection: CGRect,
        selectionPixelSize: CGSize?,
        localRect: CGRect
    ) {
        guard localRect.intersects(bounds), let selectionPixelSize else { return }
        // Whole-point frames are exact integers; round for any residual float noise
        // instead of truncating (which made 504.6 display as 504 then jump to 505).
        let pointWidth = Int(selection.width.rounded())
        let pointHeight = Int(selection.height.rounded())
        let pixelWidth = Int(selectionPixelSize.width)
        let pixelHeight = Int(selectionPixelSize.height)
        let text = "\(pointWidth) × \(pointHeight) pt · \(pixelWidth) × \(pixelHeight) px"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppKitDrawingFonts.regionSelectionSize,
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        var origin = CGPoint(x: max(8, localRect.minX), y: min(bounds.maxY - size.height - 12, localRect.maxY + 8))
        if origin.y < 8 { origin.y = 8 }
        let background = CGRect(x: origin.x - 6, y: origin.y - 4, width: size.width + 12, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5).fill()
        text.draw(at: origin, withAttributes: attributes)
    }

    private func magnifierMetrics(
        at globalPoint: CGPoint,
        panelFrame: CGRect,
        selectionPixelSize: CGSize?,
        snapCandidateKind: String?,
        snapCandidateLevel: Int?,
        snapCandidateLevelCount: Int?
    ) -> MagnifierMetrics {
        let scale = capture.descriptor.scale
        let pixelX = min(
            max(0, Int(floor((globalPoint.x - panelFrame.minX) * scale))),
            capture.capturedImage.image.width - 1
        )
        let pixelY = min(
            max(0, Int(floor((panelFrame.maxY - globalPoint.y) * scale))),
            capture.capturedImage.image.height - 1
        )
        return MagnifierMetrics(
            pixelX: pixelX,
            pixelY: pixelY,
            selectionPixelSize: selectionPixelSize,
            snapCandidateKind: snapCandidateKind,
            snapCandidateLevel: snapCandidateLevel,
            snapCandidateLevelCount: snapCandidateLevelCount
        )
    }

    private func drawMagnifier(
        at globalPoint: CGPoint,
        panelFrame: CGRect,
        metrics: MagnifierMetrics
    ) {
        let scale = capture.descriptor.scale
        let sampleSize = max(5, Int(11 * scale))
        var crop = CGRect(
            x: CGFloat(metrics.pixelX - sampleSize / 2),
            y: CGFloat(metrics.pixelY - sampleSize / 2),
            width: CGFloat(sampleSize),
            height: CGFloat(sampleSize)
        )
        crop.origin.x = min(max(0, crop.origin.x), CGFloat(capture.capturedImage.image.width) - crop.width)
        crop.origin.y = min(max(0, crop.origin.y), CGFloat(capture.capturedImage.image.height) - crop.height)
        let sampledCrop = crop.integral
        guard let sampled = capture.capturedImage.image.cropping(to: sampledCrop) else { return }

        let local = CGPoint(x: globalPoint.x - panelFrame.minX, y: globalPoint.y - panelFrame.minY)
        let lensSize = CGSize(width: 110, height: 110)
        let infoWidth: CGFloat = 144
        let infoHeight: CGFloat = 34
        let infoGap: CGFloat = 4
        let stackSize = CGSize(
            width: max(lensSize.width, infoWidth),
            height: lensSize.height + infoGap + infoHeight
        )
        let edgeMargin: CGFloat = 8
        var stack = CGRect(
            x: local.x + 18,
            y: local.y - 18 - stackSize.height,
            width: stackSize.width,
            height: stackSize.height
        )
        if stack.maxX > bounds.maxX - edgeMargin {
            stack.origin.x = local.x - 18 - stack.width
        }
        if stack.minY < bounds.minY + edgeMargin {
            stack.origin.y = local.y + 18
        }
        stack.origin.x = min(
            max(edgeMargin, stack.origin.x),
            max(edgeMargin, bounds.maxX - edgeMargin - stack.width)
        )
        stack.origin.y = min(
            max(edgeMargin, stack.origin.y),
            max(edgeMargin, bounds.maxY - edgeMargin - stack.height)
        )
        let infoRect = CGRect(
            x: stack.minX,
            y: stack.minY,
            width: infoWidth,
            height: infoHeight
        )
        let destination = CGRect(
            x: stack.midX - lensSize.width / 2,
            y: infoRect.maxY + infoGap,
            width: lensSize.width,
            height: lensSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let magnifierPath = NSBezierPath(roundedRect: destination, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.black.withAlphaComponent(0.12).setFill()
        magnifierPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        magnifierPath.addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: sampled, size: NSSize(width: sampleSize, height: sampleSize))
            .draw(in: destination, from: .zero, operation: .copy, fraction: 1)

        let cellWidth = destination.width / sampledCrop.width
        let cellHeight = destination.height / sampledCrop.height
        drawMagnifierPixelGrid(
            columns: Int(sampledCrop.width),
            rows: Int(sampledCrop.height),
            in: destination
        )
        let sampledPixelX = min(
            max(CGFloat(metrics.pixelX), sampledCrop.minX),
            sampledCrop.maxX - 1
        )
        let sampledPixelY = min(
            max(CGFloat(metrics.pixelY), sampledCrop.minY),
            sampledCrop.maxY - 1
        )
        let centerPixel = CGRect(
            x: destination.minX + (sampledPixelX - sampledCrop.minX) * cellWidth,
            y: destination.maxY - (sampledPixelY - sampledCrop.minY + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        drawMagnifierCrosshair(around: centerPixel, in: destination)
        NSColor.black.withAlphaComponent(0.72).setStroke()
        let centerPixelOuterBorder = NSBezierPath(rect: centerPixel.insetBy(dx: -1, dy: -1))
        centerPixelOuterBorder.lineWidth = 2
        centerPixelOuterBorder.stroke()
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let centerPixelInnerBorder = NSBezierPath(rect: centerPixel.insetBy(dx: 0.5, dy: 0.5))
        centerPixelInnerBorder.lineWidth = 1
        centerPixelInnerBorder.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.58).setStroke()
        let outerBorder = NSBezierPath(
            roundedRect: destination.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 7.5,
            yRadius: 7.5
        )
        outerBorder.lineWidth = 1
        outerBorder.stroke()
        NSColor.white.withAlphaComponent(0.72).setStroke()
        let innerBorder = NSBezierPath(
            roundedRect: destination.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 6.5,
            yRadius: 6.5
        )
        innerBorder.lineWidth = 1
        innerBorder.stroke()
        drawMagnifierInfo(metrics, in: infoRect)
    }

    private func drawMagnifierPixelGrid(columns: Int, rows: Int, in rect: CGRect) {
        guard columns > 1, rows > 1 else { return }
        let path = NSBezierPath()
        let cellWidth = rect.width / CGFloat(columns)
        let cellHeight = rect.height / CGFloat(rows)
        for column in 1..<columns {
            let x = rect.minX + CGFloat(column) * cellWidth
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.line(to: CGPoint(x: x, y: rect.maxY))
        }
        for row in 1..<rows {
            let y = rect.minY + CGFloat(row) * cellHeight
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.line(to: CGPoint(x: rect.maxX, y: y))
        }
        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1 / max(1, capture.descriptor.scale)
        path.stroke()
    }

    private func drawMagnifierCrosshair(around centerPixel: CGRect, in rect: CGRect) {
        let center = CGPoint(x: centerPixel.midX, y: centerPixel.midY)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: center.y))
        path.line(to: CGPoint(x: centerPixel.minX, y: center.y))
        path.move(to: CGPoint(x: centerPixel.maxX, y: center.y))
        path.line(to: CGPoint(x: rect.maxX, y: center.y))
        path.move(to: CGPoint(x: center.x, y: rect.minY))
        path.line(to: CGPoint(x: center.x, y: centerPixel.minY))
        path.move(to: CGPoint(x: center.x, y: centerPixel.maxY))
        path.line(to: CGPoint(x: center.x, y: rect.maxY))

        NSColor.black.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 2
        path.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    private func drawMagnifierInfo(_ metrics: MagnifierMetrics, in rect: CGRect) {
        let reducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let backgroundAlpha: CGFloat = reducesTransparency ? 0.94 : 0.78
        let infoPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(backgroundAlpha).setFill()
        infoPath.fill()
        NSColor.black.withAlphaComponent(increasesContrast ? 0.9 : 0.56).setStroke()
        infoPath.lineWidth = increasesContrast ? 1.5 : 1
        infoPath.stroke()
        NSColor.white.withAlphaComponent(0.72).setStroke()
        let innerPath = NSBezierPath(
            roundedRect: rect.insetBy(dx: 1, dy: 1),
            xRadius: 5,
            yRadius: 5
        )
        innerPath.lineWidth = 0.75
        innerPath.stroke()

        let primary = "X \(metrics.pixelX)  Y \(metrics.pixelY) px"
        let targetTitle: String?
        switch metrics.snapCandidateKind {
        case "window":
            targetTitle = NSLocalizedString("Window", comment: "Region magnifier smart-snap target")
        case "interface-element":
            targetTitle = NSLocalizedString("Control", comment: "Region magnifier smart-snap target")
        default:
            targetTitle = nil
        }
        let hierarchyTitle = targetTitle.map { title in
            guard let level = metrics.snapCandidateLevel,
                  let count = metrics.snapCandidateLevelCount,
                  count > 1
            else { return title }
            return "\(title) \(level)/\(count)"
        }
        let secondary = metrics.selectionPixelSize.map { size in
            let dimensions = "\(Int(size.width))×\(Int(size.height)) px"
            return hierarchyTitle.map { "\($0) · \(dimensions)" } ?? dimensions
        } ?? hierarchyTitle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppKitDrawingFonts.regionMagnifierHUD,
            .foregroundColor: NSColor.white
        ]
        drawCenteredMagnifierText(
            primary,
            atY: secondary == nil ? rect.midY - 5 : rect.minY + 18,
            in: rect,
            attributes: attributes
        )
        if let secondary {
            drawCenteredMagnifierText(
                secondary,
                atY: rect.minY + 4,
                in: rect,
                attributes: attributes
            )
        }
    }

    private func drawCenteredMagnifierText(
        _ text: String,
        atY y: CGFloat,
        in rect: CGRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - textSize.width / 2, y: y),
            withAttributes: attributes
        )
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
private func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}
