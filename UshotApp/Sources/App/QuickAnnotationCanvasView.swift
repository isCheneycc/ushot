import AppKit
import Combine
import UshotCore

private enum InlineAnnotationTextResizeHandle: String {
    case northWest = "north-west"
    case southWest = "south-west"
    case southEast = "south-east"

    var fixedCorner: InlineAnnotationTextFrameCorner {
        switch self {
        case .northWest: return .southEast
        case .southWest: return .northEast
        case .southEast: return .northWest
        }
    }
}

private enum InlineAnnotationTextFrameCorner {
    case northWest
    case northEast
    case southWest
    case southEast
}

@MainActor
final class QuickAnnotationCanvasView: NSView, NSTextViewDelegate {
    private enum InlineTextEditorMetrics {
        static let minimumViewportWidth: CGFloat = 240
        static let maximumViewportWidth: CGFloat = 520
        static let horizontalPadding = AnnotationTextLayout.horizontalChromePadding
        static let verticalPadding = AnnotationTextLayout.verticalChromePadding
    }

    private enum PinnedWindowCursorMetrics {
        static let edgeThickness: CGFloat = 7
        static let cornerSpan: CGFloat = 16
    }

    enum TextEditingEndReason: String {
        case escape
        case focusChange = "focus-change"
        case returnKey = "return"
        case toolChange = "tool-change"
        case externalAction = "external-action"
        case deleteButton = "delete-button"
    }

    private struct TextEditingState {
        let itemID: UUID?
        var anchor: CGPoint
        var style: AnnotationStyle
        let transform: AnnotationTransform
        let originalItem: AnnotationItem?

        init(
            itemID: UUID?,
            anchor: CGPoint,
            style: AnnotationStyle,
            transform: AnnotationTransform,
            originalItem: AnnotationItem? = nil
        ) {
            self.itemID = itemID
            self.anchor = anchor
            self.style = style
            self.transform = transform
            self.originalItem = originalItem
        }

        var chromeMode: AnnotationTextLayoutPayload.ChromeMode {
            if let originalItem {
                return originalItem.textLayout?.chromeMode ?? .legacyTight
            }
            return .uniformPadded
        }
    }

    private struct TextEditorFontRequest: Equatable {
        let fontName: String?
        let fontWeight: AnnotationFontWeight
        let pointSize: CGFloat

        init(style: AnnotationStyle) {
            fontName = style.fontName
            fontWeight = style.fontWeight
            pointSize = style.fontSize
        }
    }

    /// Last renderer-ready generation accepted by the live editor. Revalidating
    /// it before authoring the next generation turns a removed, unreadable or
    /// replaced font source into a typed capability failure instead of silently
    /// rebasing an active edit onto different font bytes.
    private struct TextEditorRendererGeneration {
        let text: String
        let style: AnnotationStyle
        let payload: AnnotationTextLayoutPayload
    }

    private enum TextEditingDisposition: Equatable {
        case commit
        case delete
    }

    private struct TextResizeInteraction {
        let handle: InlineAnnotationTextResizeHandle
        let initialFontSize: CGFloat
        let minimumFontSize: CGFloat
        let maximumFontSize: CGFloat
        /// Persisted TextKit-container width at pointer-down. The interaction
        /// scales this semantic owner directly; the capped viewport is only a
        /// window onto it and must never be inverted back into document state.
        let initialCanonicalWrapWidthInDocument: CGFloat
        let initialViewportWidth: CGFloat
        let initialAnchor: CGPoint
        let fieldAnchorResidualInDocument: CGSize
        let initialActiveCornerInView: CGPoint
        let initialPointerInView: CGPoint
        let fixedCornerInView: CGPoint
        let canvasBounds: CGRect
        let maximumFieldWidth: CGFloat
        let maximumFieldHeight: CGFloat
        let initialBaselineCorrectionCount: Int
        let startedAt: TimeInterval
        var updateCount: Int
        var maximumFixedCornerError: CGFloat
    }

    private struct SelectedTextResizeInteraction {
        let handle: InlineAnnotationTextResizeHandle
        let itemID: UUID
        let initialItem: AnnotationItem
        var previewItem: AnnotationItem
        let initialFontSize: CGFloat
        let initialActiveCornerInView: CGPoint
        let initialPointerInView: CGPoint
        let fixedCornerInView: CGPoint
        let canvasBounds: CGRect
        let startedAt: TimeInterval
    }

    private struct TextEditorPresentationLayout {
        let frame: CGRect
        let containerFrame: CGRect
        let documentBaseOrigin: CGPoint
        /// View-space extent of the scaled document host. The viewport and
        /// deterministic scroll lifecycle operate exclusively on this size.
        let documentSize: CGSize
        /// Canonical, untransformed document extent owned by TextKit. The
        /// document host maps these bounds into `documentSize`; NSTextView
        /// never recomputes typography at presentation scale.
        let canonicalDocumentSize: CGSize
    }

    private struct InlineTextEditorLineSnapshot {
        let utf16Range: NSRange
        let consumedUTF16Range: NSRange
        let originInView: CGPoint
    }

    private struct InlineTextKitCapabilityLineSnapshot {
        let utf16Range: NSRange
        let consumedUTF16Range: NSRange
        let usedRectMinX: CGFloat
        let baselineY: CGFloat
        let baselineOffsetInFragment: CGFloat
        let isExtraLineFragment: Bool
    }

    private struct InlineTextKitEditingCapabilityError: LocalizedError {
        let diagnostic: String

        var errorDescription: String? {
            NSLocalizedString(
                "This text cannot be edited on this Mac because its saved layout does not match the available text engine. The annotation was left unchanged.",
                comment: "Inline text editing is rejected when the live TextKit stack cannot reproduce a saved layout"
            )
        }
    }

    private struct RegionDraftViewport {
        let sourceDesktopFrame: CGRect
        let previewDesktopFrame: CGRect
        let change: RegionDraftGeometryChange

        var visibleDocumentRect: CGRect {
            switch change {
            case .resizePreservingDesktopAnchors:
                return CGRect(
                    x: previewDesktopFrame.minX - sourceDesktopFrame.minX,
                    y: previewDesktopFrame.minY - sourceDesktopFrame.minY,
                    width: previewDesktopFrame.width,
                    height: previewDesktopFrame.height
                )
            case .moveCanvas:
                return CGRect(origin: .zero, size: previewDesktopFrame.size)
            }
        }
    }

    private enum SelectionInteractionMode {
        case stationary
        case move
        case resize(itemID: UUID, handle: AnnotationSelectionHandle)
    }

    private struct SelectionInteraction {
        let mode: SelectionInteractionMode
        let startPoint: CGPoint
        let initialItems: [UUID: AnnotationItem]
        let editsTextOnClick: UUID?
        var previewItems: [UUID: AnnotationItem]
        var hasMoved = false
    }

    enum LineWidthEditCommitTarget {
        case none
        case toolDefault(tool: AnnotationTool, lineWidth: CGFloat)
        case selection(itemCount: Int, lineWidth: CGFloat)
    }

    struct LineWidthControlPresentation {
        let isEnabled: Bool
        let logicalLineWidth: CGFloat
        let targetDescription: String
    }

    private enum LineWidthEditTarget {
        case toolDefault(tool: AnnotationTool, initialStyle: AnnotationStyle)
        case selection(initialItems: [UUID: AnnotationItem])
    }

    private struct LineWidthEditingState {
        let target: LineWidthEditTarget
        var latestLineWidth: CGFloat
        var previewItems: [UUID: AnnotationItem]
    }

    var onWindowDragBegan: ((NSEvent) -> Void)?
    var onWindowDragChanged: ((NSEvent) -> Void)?
    var onWindowDragEnded: ((String) -> Void)?
    var onExternalDrag: ((NSEvent) -> Void)?
    var onCopyFinalImage: (() -> Void)?
    var onRegionSelectionDoubleClickCopy: (() -> Void)?
    var onPreviewChange: ((CapturedImage) -> Void)?
    var onEditingContextWillChange: ((String) -> Void)?

    private let session: AnnotationEditingSession
    /// Region confirmation keeps newly committed annotations visually clean.
    /// Other editing surfaces retain their existing add-and-select workflow.
    private let selectsNewAnnotationsAfterCommit: Bool
    private let vectorRenderer = AnnotationVectorRenderer()
    /// Drawing is demand-driven and may repeat many times for one document
    /// generation. Keep deterministic vector failures visible without
    /// presenting the same error on every AppKit display pass.
    private var reportedVectorRenderFailureItems: [UUID: AnnotationItem] = [:]
    private var reportedProvisionalVectorRenderFailureDescriptions: Set<String> = []
    private var lastTextLayoutAuthoringFailureFingerprint: String?
    private let effectRenderer = AnnotationEffectRenderer()
    private let selectionGeometry = AnnotationSelectionGeometry()
    private var drawsBaseImage: Bool
    private var baseImage: NSImage
    private var previewImage: NSImage
    private var authoritativeImage: NSImage
    private var blurredEffectPreview: (radius: CGFloat, image: CGImage)?
    private var mosaicedEffectPreview: (blockSize: CGFloat, image: CGImage)?
    private var cancellables: Set<AnyCancellable> = []
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var freehandPoints: [CGPoint] = []
    private var selectionInteraction: SelectionInteraction?
    private var lineWidthEditingState: LineWidthEditingState?
    private var copiedItems: [AnnotationItem] = []
    private let hitTester = AnnotationHitTester()
    private var textEditor: InlineAnnotationTextView?
    private var textEditorContainer: InlineAnnotationTextViewportView?
    private var textEditorDocumentView: InlineAnnotationTextDocumentView?
    private var textEditorFrameView: InlineAnnotationTextEditorFrameView?
    private var selectedTextFrameView: InlineAnnotationTextEditorFrameView?
    private var textEditorPreferredViewportWidthInDocument: CGFloat?
    /// Semantic untransformed content width. Unlike the visible field frame,
    /// this never absorbs interaction minimums or edge clamps.
    private var textEditorCanonicalWrapWidthInDocument: CGFloat?
    /// Complete persisted layout owner for the current semantic generation.
    /// A published legacy item remains nil during an exact no-op; its first
    /// real layout mutation materializes a versioned payload with overhangs.
    private var textEditorLayoutPayload: AnnotationTextLayoutPayload?
    /// True after direct manipulation has taken ownership of the semantic wrap
    /// width. Text/font changes may grow an untouched width, but they must not
    /// overwrite a width explicitly chosen by the resize gesture.
    private var textEditorCanonicalWrapWidthWasExplicitlyResized = false
    private var textEditorFieldPlacementAnchorInDocument: CGPoint?
    private var textEditorLayoutBounds: CGRect?
    private var textEditorDocumentScaleInView: CGSize?
    private var textEditorSessionFont: NSFont?
    private var textEditorSessionFontRequest: TextEditorFontRequest?
    private var textEditorRendererGeneration: TextEditorRendererGeneration?
    /// Fixed TextKit paragraph advance for the current canonical layout plan.
    /// This is text-dependent because fallback glyphs can increase the plan's
    /// shared line height without changing the annotation's primary font.
    private var textEditorCanonicalLineAdvance: CGFloat?
    private var textEditorSessionBaselineOffset: CGFloat?
    private var textEditorPresentationLayout: TextEditorPresentationLayout?
    private var textEditorGeometryConfigurationCount = 0
    private var textEditorPostConfigurationViewportMutationCount = 0
    private var textEditorPostConfigurationLineOriginDriftCount = 0
    private var textEditorPreventedFrameMutationCount = 0
    private var textEditorBaselineCorrectionCount = 0
    private var textEditorBaselineError: CGPoint?
    private var lastTextCommitBaselineError: CGPoint?
    private var textEditingState: TextEditingState?
    private var textResizeInteraction: TextResizeInteraction?
    private var selectedTextResizeInteraction: SelectedTextResizeInteraction?
    private var textResizeFixedCornerError: CGFloat = 0
    private var isAnnotationEditingEnabled = true
    private var isReadOnlyWindowDragArmed = false
    private var isWindowDragInProgress = false
    private var pendingRegionBodyMoveMouseDown: NSEvent?
    private var regionBodyMoveStartScreenPoint: CGPoint?
    private var regionBodyMoveHasDragged = false
    private var pendingRegionDoubleClickCopy = false
    private var lastEmptyRegionClick: (timestamp: TimeInterval, screenPoint: CGPoint)?
    private var windowDragObservationGeneration: UInt = 0
    private var selectionMoveCursorObservationGeneration: UInt = 0
    private var regionDraftViewport: RegionDraftViewport?
    private var didPreviewRegionDraftGeometry = false
    private var lastRegionDraftPreviewScale = CGPoint(x: 1, y: 1)
    private var lastRegionDraftPreviewAnchorError: CGFloat = 0
    private var lastRegionDraftPreviewGridError: CGFloat = 0

    var draggingImage: NSImage { authoritativeImage }
    var isTextEditing: Bool { textEditor != nil }
    var hasActiveLineWidthEditing: Bool { lineWidthEditingState != nil }

#if DEBUG
    private func requiredTextEditorFontForRegression(
        _ state: TextEditingState
    ) -> NSFont {
        do {
            return try textEditorFont(for: state)
        } catch {
            preconditionFailure(
                "Text regression fixture could not resolve its required font: \(error)"
            )
        }
    }

    private func requiredRendererReadyTextLayoutForRegression(
        baselineAnchor: CGPoint,
        text: String,
        style: AnnotationStyle,
        maximumWrapWidth: CGFloat? = nil
    ) -> AnnotationTextLayoutResolution {
        do {
            return try AnnotationTextLayout.newTextLayout(
                baselineAnchor: baselineAnchor,
                text: text,
                style: style,
                maximumWrapWidth: maximumWrapWidth
            )
        } catch {
            preconditionFailure(
                "Text regression fixture could not resolve renderer-ready layout: \(error)"
            )
        }
    }

    private func requiredRendererReadyTextPayloadForRegression(
        text: String,
        style: AnnotationStyle,
        proposedWrapWidth: CGFloat,
        chromeMode: AnnotationTextLayoutPayload.ChromeMode
    ) -> AnnotationTextLayoutPayload {
        do {
            return try AnnotationTextLayout.safeLayoutPayload(
                for: text,
                style: style,
                proposedWrapWidth: proposedWrapWidth,
                chromeMode: chromeMode
            )
        } catch {
            preconditionFailure(
                "Text regression fixture could not resolve renderer-ready payload: \(error)"
            )
        }
    }

    var debugIsAnnotationEditingEnabled: Bool { isAnnotationEditingEnabled }
    var debugPresentedSelectionHandleCount: Int {
        guard isAnnotationEditingEnabled else { return 0 }
        if selectedTextFrameView != nil { return 3 }
        let selectedItems = selectedDisplayItems()
        guard selectedItems.count == 1, let item = selectedItems.first else { return 0 }
        return selectionGeometry.handlePoints(for: item).count
    }

    func runLineWidthRoutingRegression() {
        precondition(
            session.controller.document.annotations.isEmpty,
            "The line-width routing regression requires an empty annotation document."
        )
        precondition(
            lineWidthEditingState == nil,
            "The line-width routing regression requires no active width edit."
        )
        session.currentTool = .rectangle
        let unchangedTool = session.currentTool

        beginLineWidthEditing()
        applyLineWidth(5)
        precondition(
            session.controller.document.annotations.isEmpty,
            "Changing an unselected tool default must not mutate the document."
        )
        precondition(
            session.creationStyle(for: .rectangle).lineWidth == 5,
            "The first new annotation must observe the live tool-default width."
        )
        guard case .toolDefault(let defaultTool, let firstDefaultWidth) = commitLineWidthEditing() else {
            preconditionFailure("An unselected line-width edit must target the tool default.")
        }
        precondition(
            defaultTool == .rectangle && firstDefaultWidth == 5,
            "The committed tool-default width did not match its captured target."
        )
        commit(
            tool: .rectangle,
            start: CGPoint(x: 24, y: 24),
            end: CGPoint(x: 124, y: 84)
        )
        guard let firstID = session.controller.selectedItemIDs.first,
              let firstItem = session.controller.document.annotations.first(where: { $0.id == firstID })
        else {
            preconditionFailure("The line-width regression could not create its first selected rectangle.")
        }
        precondition(firstItem.style.lineWidth == 5, "The first rectangle ignored the updated default width.")
        precondition(
            session.currentStyleOrigin == .existingAnnotation
                && session.currentStyle.lineWidth == 5,
            "Creating and selecting the first rectangle must synchronize the toolbar presentation."
        )

        beginLineWidthEditing()
        applyLineWidth(7)
        guard let storedDuringPreview = session.controller.document.annotations.first(where: { $0.id == firstID }),
              let presentedDuringPreview = selectedDisplayItems().first(where: { $0.id == firstID })
        else {
            preconditionFailure("The selected line-width preview lost its target rectangle.")
        }
        precondition(
            storedDuringPreview.style.lineWidth == 5 && presentedDuringPreview.style.lineWidth == 7,
            "A selected line-width edit must preview immediately without prematurely committing the document."
        )
        guard case .selection(let selectedCount, let selectedWidth) = commitLineWidthEditing() else {
            preconditionFailure("A selected line-width edit must target the selected annotation.")
        }
        precondition(
            selectedCount == 1 && selectedWidth == 7,
            "The selected line-width commit reported the wrong target or value."
        )
        precondition(
            session.controller.document.annotations.first(where: { $0.id == firstID })?.style.lineWidth == 7,
            "The selected rectangle did not commit its live line width."
        )
        precondition(
            session.creationStyle(for: .rectangle).lineWidth == 5,
            "Editing a selected rectangle must not overwrite the tool default."
        )
        session.controller.undo()
        precondition(
            session.controller.document.annotations.first(where: { $0.id == firstID })?.style.lineWidth == 5,
            "One Undo must restore the selected rectangle's original line width."
        )
        precondition(
            session.currentStyle.lineWidth == 5
                && lineWidthControlPresentation().logicalLineWidth == 5,
            "Undo must synchronize the selected rectangle's restored width back to the toolbar."
        )
        session.controller.redo()
        precondition(
            session.controller.document.annotations.first(where: { $0.id == firstID })?.style.lineWidth == 7,
            "One Redo must restore the selected rectangle's edited line width."
        )
        precondition(
            session.currentStyle.lineWidth == 7
                && lineWidthControlPresentation().logicalLineWidth == 7,
            "Redo must synchronize the selected rectangle's edited width back to the toolbar."
        )

        commit(
            tool: .rectangle,
            start: CGPoint(x: 148, y: 24),
            end: CGPoint(x: 248, y: 84)
        )
        guard let secondID = session.controller.selectedItemIDs.first,
              secondID != firstID,
              let secondItem = session.controller.document.annotations.first(where: { $0.id == secondID })
        else {
            preconditionFailure("The line-width regression could not create its second selected rectangle.")
        }
        precondition(
            secondItem.style.lineWidth == 5,
            "Drawing again while the edited item is selected must still use the independent tool default."
        )
        precondition(
            session.currentStyleOrigin == .existingAnnotation
                && session.currentStyle.lineWidth == 5
                && lineWidthControlPresentation().logicalLineWidth == 5,
            "The newly selected rectangle must replace the previous selection's toolbar width."
        )
        beginLineWidthEditing()
        guard case .selection(let unchangedCount, let unchangedWidth) = commitLineWidthEditing() else {
            preconditionFailure("Focusing and committing an unchanged selected width must retain the selection target.")
        }
        precondition(
            unchangedCount == 1
                && unchangedWidth == 5
                && session.controller.document.annotations.first(where: { $0.id == secondID })?.style.lineWidth == 5,
            "Focusing and leaving the synchronized field must not restore the previous item's width."
        )

        session.controller.selectedItemIDs.removeAll()
        let undoCountBeforeDefaultChange = session.controller.undoStack.count
        beginLineWidthEditing()
        applyLineWidth(9)
        precondition(
            session.controller.document.annotations.first(where: { $0.id == firstID })?.style.lineWidth == 7,
            "Changing an unselected default must leave existing annotations unchanged."
        )
        guard case .toolDefault(let secondDefaultTool, let secondDefaultWidth) = commitLineWidthEditing() else {
            preconditionFailure("A deselected line-width edit must target the tool default.")
        }
        precondition(
            secondDefaultTool == .rectangle && secondDefaultWidth == 9,
            "The deselected default edit committed the wrong tool or width."
        )
        precondition(
            session.controller.undoStack.count == undoCountBeforeDefaultChange,
            "Changing a tool default must not create a document Undo entry."
        )
        commit(
            tool: .rectangle,
            start: CGPoint(x: 82, y: 108),
            end: CGPoint(x: 182, y: 168)
        )
        let createdWidths = session.controller.document.orderedAnnotations.map(\.style.lineWidth)
        precondition(
            createdWidths == [7, 5, 9],
            "Existing and newly created rectangles must retain independent selected/default widths."
        )
        precondition(
            session.currentTool == unchangedTool,
            "Line-width changes must take effect without switching tools."
        )
        AppLog.capture.notice(
            "Annotation line-width routing regression passed: noSelectionDefault=5, selectedPreview=7, selectedUndoRedo=true, consecutiveCreationDefault=5, synchronizedFocusCommit=5, deselectedDefault=9, createdWidths=7,5,9, toolSwitches=0"
        )
    }

    func runLineWidthCanvasBoundaryRegression() {
        guard let window else {
            preconditionFailure("The line-width canvas-boundary regression requires a presented window.")
        }
        precondition(
            lineWidthEditingState != nil,
            "The line-width canvas-boundary regression requires an active edit."
        )
        let viewPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let windowPoint = convert(viewPoint, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 31,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 32,
            clickCount: 1,
            pressure: 0
        ) else {
            preconditionFailure("The line-width canvas-boundary regression could not synthesize pointer events.")
        }
        self.mouseDown(with: mouseDown)
        precondition(
            lineWidthEditingState == nil,
            "Canvas mouse-down must resolve a toolbar line-width edit before starting its interaction."
        )
        self.mouseUp(with: mouseUp)
        AppLog.capture.notice(
            "Annotation line-width canvas-boundary regression passed: fieldResolvedBeforePointerInteraction=true"
        )
    }

    func runReadOnlyWindowPressCursorRegression() {
        guard let window else {
            preconditionFailure("The pinned cursor regression requires a presented window.")
        }
        setAnnotationEditingEnabled(false)
        let viewPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let windowPoint = convert(viewPoint, to: nil)
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            preconditionFailure("The pinned cursor regression could not synthesize mouse-down.")
        }
        self.mouseDown(with: mouseDown)
        precondition(isReadOnlyWindowDragArmed, "Pinned mouse-down must arm window movement immediately.")
        precondition(isWindowDragInProgress, "Pinned mouse-down must enter the active drag state before movement.")
        precondition(
            NSCursor.current == NSCursor.closedHand,
            "Pinned mouse-down must set the closed-hand cursor before any drag event."
        )
        guard let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ) else {
            preconditionFailure("The pinned cursor regression could not synthesize mouse-up.")
        }
        self.mouseUp(with: mouseUp)
        precondition(!isWindowDragInProgress, "Pinned mouse-up must end the active drag state.")

        self.mouseDown(with: mouseDown)
        precondition(
            isWindowDragInProgress,
            "Pinned editing-disable regression must begin with an active body move."
        )
        setAnnotationEditingEnabled(false)
        precondition(
            !isWindowDragInProgress && !isReadOnlyWindowDragArmed,
            "Disabling an already read-only canvas must still release its active body move."
        )
        self.mouseUp(with: mouseUp)

        let originalTool = session.currentTool
        let originalAnnotationCount = session.controller.document.annotations.count
        setAnnotationEditingEnabled(true)
        session.currentTool = .select
        self.mouseDown(with: mouseDown)
        precondition(
            isWindowDragInProgress,
            "Pinned tool-switch regression must begin with an active Select body move."
        )
        session.currentTool = .text
        self.mouseUp(with: mouseUp)
        precondition(
            !isWindowDragInProgress
                && !isTextEditing
                && session.controller.document.annotations.count == originalAnnotationCount,
            "Releasing a body move after a tool switch must not begin or commit an annotation."
        )
        session.currentTool = originalTool
        setAnnotationEditingEnabled(false)
        AppLog.capture.notice(
            "Pinned cursor press regression passed: pressCursor=closed-hand, movement=zero, releaseState=idle, editingDisableCancellation=true, toolSwitchReleaseSideEffect=false"
        )
    }

    func runInlineTextStabilityRegression() {
        layoutSubtreeIfNeeded()
        precondition(bounds.width > 0 && bounds.height > 0, "Text stability regression requires a laid-out canvas.")
        let anchor = documentPoint(fromViewPoint: CGPoint(
            x: bounds.width * 0.18,
            y: bounds.height * 0.52
        ))
        var regressionStyle = session.defaultStyle(for: .text)
        regressionStyle.fontName = "Menlo-Regular"
        regressionStyle.fontSize = 18
        guard NSFont(name: regressionStyle.fontName!, size: regressionStyle.fontSize) != nil else {
            preconditionFailure("Text stability regression requires the system Menlo font.")
        }
        session.adoptCurrentStyle(regressionStyle, origin: .newTextDraft)
        installTextEditor(
            text: "",
            state: TextEditingState(
                itemID: nil,
                anchor: anchor,
                style: regressionStyle,
                transform: AnnotationTransform()
            )
        )
        guard let editor = textEditor,
              let frameView = textEditorFrameView,
              let container = textEditorContainer,
              let initialLineOrigin = textEditorLineOriginInView(editor)
        else {
            preconditionFailure("Text stability regression could not start the inline editor.")
        }
        frameView.displayIfNeeded()
        guard let frameBackground = frameView.layer?.backgroundColor else {
            preconditionFailure("Inline text regression requires an explicit framing-layer background color.")
        }
        precondition(
            frameBackground.alpha == 0 && !frameView.isOpaque,
            "Inline text framing must preserve the selected pixels with a clear background."
        )
        let initialFrame = frameView.frame
        let initialGeometry = textEditorGeometryDescription(editor)

        func assertStableState(_ context: String) {
            // Real AppKit input schedules a parent layout pass between rapid
            // marked-text updates. Exercise that path instead of validating
            // only the final NSTextView delegate callback.
            updateTextEditorFrame()
            updateTextEditorLayout(scrollsToInsertionPoint: true)
            layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            guard let currentLineOrigin = textEditorLineOriginInView(editor) else {
                preconditionFailure("Text stability regression lost the TextKit line origin during \(context).")
            }
            precondition(
                maxFrameDelta(initialFrame, frameView.frame) < 0.01,
                "Inline text \(context) moved or resized the anchored outer frame."
            )
            precondition(
                max(
                    abs(currentLineOrigin.x - initialLineOrigin.x),
                    abs(currentLineOrigin.y - initialLineOrigin.y)
                ) < 0.01,
                "Inline text \(context) changed the rendered line origin from \(initialLineOrigin) to \(currentLineOrigin). Initial geometry: \(initialGeometry). Current geometry: \(textEditorGeometryDescription(editor))."
            )
            precondition(
                textEditorGeometryConfigurationCount == 1,
                "Inline text \(context) reconfigured presentation geometry."
            )
            precondition(
                textEditorPostConfigurationViewportMutationCount == 0,
                "Inline text \(context) moved the viewport after initial calibration."
            )
            precondition(
                textEditorPostConfigurationLineOriginDriftCount == 0,
                "Inline text \(context) changed TextKit's line origin after initial calibration."
            )
            precondition(
                max(
                    abs(textEditorBaselineError?.x ?? .infinity),
                    abs(textEditorBaselineError?.y ?? .infinity)
                ) < 0.01,
                "Inline text \(context) left a visible baseline error."
            )
        }

        for (value, context) in [
            ("中", "CJK fallback"),
            ("M", "returning to primary font"),
            ("M中", "mixed primary and fallback fonts"),
            ("", "returning to the empty caret")
        ] {
            editor.insertText(
                value,
                replacementRange: NSRange(location: 0, length: editor.string.utf16.count)
            )
            assertStableState(context)
        }

        for fragment in ["F", "i", "r", "s", "t"] {
            editor.insertText(
                fragment,
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            assertStableState("typing")
        }

        for fragment in ["z", "zh", "zho", "zhon", "zhong"] {
            // macOS input methods deliver attributed marked text, often
            // without the editor's ordinary typing attributes. A plain Swift
            // String does not exercise the transient mixed-attribute state
            // that NSTextView exposes during real Pinyin composition.
            editor.setMarkedText(
                NSAttributedString(
                    string: fragment,
                    attributes: [
                        .markedClauseSegment: 0,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                ),
                selectedRange: NSRange(location: fragment.utf16.count, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            assertStableState("rapid IME composition")
        }
        let markedRange = editor.markedRange()
        precondition(markedRange.location != NSNotFound, "IME regression did not create marked text.")
        editor.insertText("中", replacementRange: markedRange)
        assertStableState("IME commit")
        editor.insertText("文", replacementRange: NSRange(location: NSNotFound, length: 0))
        assertStableState("typing")

        let textBeforeOverflow = editor.string
        let overflowStart = editor.string.utf16.count
        let overflowText = String(repeating: "W", count: 40)
        editor.insertText(
            overflowText,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        updateTextEditorFrame()
        updateTextEditorLayout(scrollsToInsertionPoint: true)
        layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        guard let overflowLineOrigin = textEditorLineOriginInView(editor),
              let documentView = textEditorDocumentView,
              let presentation = textEditorPresentationLayout,
              let overflowFrameView = textEditorFrameView,
              let insertionX = textEditorInsertionX(editor),
              let overflowEditingState = textEditingState
        else {
            preconditionFailure("Text stability regression could not inspect wrapping of long inline text.")
        }
        guard let wrapWidth = textEditorCanonicalWrapWidthInDocument else {
            preconditionFailure("Text stability regression lost its canonical wrap width.")
        }
        precondition(
            abs(overflowLineOrigin.y - initialLineOrigin.y) < 0.01,
            "Wrapping long inline text changed the calibrated first-line baseline."
        )
        let horizontalScrollOffset = presentation.documentBaseOrigin.x
            - documentView.frame.minX
        let overflowFieldFrame = overflowFrameView.fieldFrame(in: self)
        precondition(
            overflowLineOrigin.x >= overflowFieldFrame.minX - 0.5
                && overflowLineOrigin.x <= overflowFieldFrame.maxX + 0.5,
            "Wrapping must keep the first line reachable inside the viewport."
        )
        precondition(
            overflowFrameView.fieldFrame(in: self).height > initialFrame.height + 1,
            "Long inline text must grow the field downward when it wraps."
        )
        let visibleInsertionX = documentView.frame.minX + insertionX
        let insertionInset = textEditorChromeInsetsInView(
            for: overflowEditingState
        ).width
        precondition(
            visibleInsertionX >= insertionInset - 0.5
                && visibleInsertionX <= container.bounds.maxX
                    - insertionInset + 0.5,
            "Wrapping did not keep the insertion point visible: visibleX=\(visibleInsertionX), documentX=\(documentView.frame.minX), insertionX=\(insertionX), viewportWidth=\(container.bounds.width)."
        )
        precondition(
            AnnotationTextLayout.visualLineCount(
                in: editor.string,
                style: overflowEditingState.style,
                wrapWidth: wrapWidth
            ) > 1,
            "Long inline text must wrap onto additional visible lines."
        )
        let lineOriginBeforeCommit = renderedTextLineOriginInView(
            state: overflowEditingState,
            text: editor.string,
            layout: textEditorLayoutPayload
        )
        precondition(
            abs(
                overflowLineOrigin.x
                    + horizontalScrollOffset
                    - lineOriginBeforeCommit.x
            ) < 0.01
                && abs(overflowLineOrigin.y - lineOriginBeforeCommit.y) < 0.01,
            "Wrapped editor origin must match the renderer after explicit scroll conversion."
        )
        assertTextEditorLinesMatchRenderer(
            editor,
            state: overflowEditingState,
            layout: textEditorLayoutPayload,
            canonicalHorizontalOffset: horizontalScrollOffset,
            context: "wrapped mixed-script text"
        )
        let baselineCorrections = textEditorBaselineCorrectionCount
        precondition(
            baselineCorrections > 0,
            "Text stability regression did not exercise a fallback-font baseline change."
        )
        _ = endTextEditingIfNeeded(reason: .focusChange)
        guard let committedItem = session.controller.document.annotations.last,
              committedItem.kind == .text,
              case .rect(let committedRect) = committedItem.geometry,
              let committedText = committedItem.text
        else {
            preconditionFailure("Text stability regression did not commit a text annotation.")
        }
        let committedState = TextEditingState(
            itemID: committedItem.id,
            anchor: AnnotationTextLayout.alignmentAnchor(
                in: committedRect,
                text: committedText,
                style: committedItem.style,
                layout: committedItem.textLayout
            ),
            style: committedItem.style,
            transform: committedItem.transform
        )
        let committedLineOrigin = renderedTextLineOriginInView(
            state: committedState,
            text: committedText,
            layout: committedItem.textLayout
        )
        precondition(
            max(
                abs(committedLineOrigin.x - lineOriginBeforeCommit.x),
                abs(committedLineOrigin.y - lineOriginBeforeCommit.y)
            ) < 0.01,
            "Focus-change commit moved text from \(lineOriginBeforeCommit) to \(committedLineOrigin)."
        )
        precondition(
            max(
                abs(lastTextCommitBaselineError?.x ?? .infinity),
                abs(lastTextCommitBaselineError?.y ?? .infinity)
            ) < 0.01,
            "Focus-change commit retained a visible editor-to-renderer baseline error."
        )
        precondition(
            selectionGeometry.handlePoints(for: committedItem).isEmpty,
            "Committed text must never return to the standard eight-handle selection path."
        )
        runInlineTextFieldGeometryRegression(style: committedItem.style)
        beginTextEditing(item: committedItem)
        guard let existingEditor = textEditor,
              textEditingState?.itemID == committedItem.id
        else {
            preconditionFailure("Active text resize regression could not reopen the committed CJK text.")
        }
        existingEditor.insertText(
            "",
            replacementRange: NSRange(
                location: overflowStart,
                length: overflowText.utf16.count
            )
        )
        precondition(
            existingEditor.string == textBeforeOverflow,
            "Overflow commit regression must restore the original mixed-script text before resizing."
        )
        let activeResizeText = existingEditor.string
        runEdgeClampedNoOpTextResizeRegression(eventNumberBase: 150)
        runTextResizeCancellationRegression(eventNumberBase: 170)
        let activeOverflowStart = activeResizeText.utf16.count
        let activeOverflowText = String(repeating: "W", count: 40)
        existingEditor.setSelectedRange(NSRange(location: activeOverflowStart, length: 0))
        existingEditor.insertText(
            activeOverflowText,
            replacementRange: NSRange(location: activeOverflowStart, length: 0)
        )
        guard let activeOverflowDocumentView = textEditorDocumentView,
              let activeOverflowPresentation = textEditorPresentationLayout,
              let activeOverflowState = textEditingState
        else {
            preconditionFailure("Active resize overflow regression lost its document viewport.")
        }
        let activeOverflowScroll = activeOverflowPresentation.documentBaseOrigin.x
            - activeOverflowDocumentView.frame.minX
        assertTextEditorLinesMatchRenderer(
            existingEditor,
            state: activeOverflowState,
            layout: textEditorLayoutPayload,
            canonicalHorizontalOffset: activeOverflowScroll,
            context: "active-resize wrapped overflow"
        )
        let fontSizeAfterSouthEast = runActiveTextResizeRegression(
            handle: .southEast,
            pointerDelta: CGPoint(x: 112, y: -56),
            steps: 16,
            eventNumberBase: 200
        )
        precondition(
            fontSizeAfterSouthEast > 20,
            "Active CJK text resize must cross the 18-to-20 point metric boundary."
        )
        existingEditor.insertText(
            "",
            replacementRange: NSRange(
                location: activeOverflowStart,
                length: activeOverflowText.utf16.count
            )
        )
        precondition(
            existingEditor.string == activeResizeText,
            "Active resize overflow regression must restore its original mixed-script text."
        )
        existingEditor.setSelectedRange(NSRange(location: 1, length: 2))
        let activeResizeSelection = existingEditor.selectedRange()
        _ = runActiveTextResizeRegression(
            handle: .northWest,
            pointerDelta: CGPoint(x: 24, y: -12),
            steps: 12,
            eventNumberBase: 300
        )
        _ = runActiveTextResizeRegression(
            handle: .southWest,
            pointerDelta: CGPoint(x: 20, y: 10),
            steps: 12,
            eventNumberBase: 400
        )
        precondition(
            existingEditor.selectedRange() == activeResizeSelection,
            "Three-corner active resizing must preserve the text selection."
        )
        guard let activeEditingStateBeforeCommit = textEditingState else {
            preconditionFailure("Active text resize regression lost the canonical state before commit.")
        }
        let activeLineOriginBeforeCommit = renderedTextLineOriginInView(
            state: activeEditingStateBeforeCommit,
            text: existingEditor.string,
            layout: textEditorLayoutPayload
        )
        _ = endTextEditingIfNeeded(reason: .focusChange)
        guard let activeResizedItem = session.controller.document.annotations.first(where: {
            $0.id == committedItem.id
        }), let activeResizedText = activeResizedItem.text,
              case .rect(let activeResizedRect) = activeResizedItem.geometry
        else {
            preconditionFailure("Active text resize regression lost the committed annotation.")
        }
        let activeResizedState = TextEditingState(
            itemID: activeResizedItem.id,
            anchor: AnnotationTextLayout.alignmentAnchor(
                in: activeResizedRect,
                text: activeResizedText,
                style: activeResizedItem.style,
                layout: activeResizedItem.textLayout
            ),
            style: activeResizedItem.style,
            transform: activeResizedItem.transform
        )
        let activeLineOriginAfterCommit = renderedTextLineOriginInView(
            state: activeResizedState,
            text: activeResizedText,
            layout: activeResizedItem.textLayout
        )
        precondition(
            hypot(
                activeLineOriginAfterCommit.x - activeLineOriginBeforeCommit.x,
                activeLineOriginAfterCommit.y - activeLineOriginBeforeCommit.y
            ) < 0.01,
            "Committing continuously resized text must not move its rendered line."
        )
        session.currentTool = .select
        session.controller.selectedItemIDs.removeAll()
        precondition(selectedTextFrameView == nil, "Deselected text must remove its dedicated chrome.")
        session.controller.selectedItemIDs = [activeResizedItem.id]
        guard let selectedTextFrameView else {
            preconditionFailure("Reselecting committed text must install its dedicated chrome.")
        }
        precondition(
            selectedTextFrameView.resizeHandleCount == 3
                && selectedTextFrameView.deleteControlCount == 1,
            "Selected text must expose exactly three font-size handles and one delete control."
        )
        guard let window else {
            preconditionFailure("Selected-text resize regression requires a presented window.")
        }
        let resizeStartInView = selectedTextFrameView.fieldPoint(
            corner: .southEast,
            in: self
        )
        let resizeStartInWindow = convert(resizeStartInView, to: nil)
        let resizeEndInWindow = CGPoint(
            x: resizeStartInWindow.x + 24,
            y: resizeStartInWindow.y - 12
        )
        guard let resizeDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: resizeStartInWindow,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 101,
            clickCount: 1,
            pressure: 1
        ), let resizeDrag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: resizeEndInWindow,
            modifierFlags: [],
            timestamp: 1.1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 102,
            clickCount: 1,
            pressure: 1
        ), let resizeUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: resizeEndInWindow,
            modifierFlags: [],
            timestamp: 1.2,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 103,
            clickCount: 1,
            pressure: 0
        ) else {
            preconditionFailure("Selected-text resize regression could not synthesize pointer events.")
        }
        beginSelectedTextResize(handle: .southEast, event: resizeDown)
        updateSelectedTextResize(handle: .southEast, event: resizeDrag)
        endSelectedTextResize(handle: .southEast, event: resizeUp)
        guard let resizedText = session.controller.document.annotations.first(where: {
            $0.id == activeResizedItem.id
        }) else {
            preconditionFailure("Selected-text resize regression lost its committed annotation.")
        }
        precondition(
            resizedText.style.fontSize > activeResizedItem.style.fontSize,
            "Dragging selected text from the bottom-right must increase its font size."
        )
        precondition(
            textResizeFixedCornerError < 0.51,
            "Selected-text resize must keep its opposite corner fixed."
        )
        let cancellationHandle = InlineAnnotationTextResizeHandle.northWest
        let cancellationStart = convert(
            selectedTextFrameView.fieldPoint(corner: .northWest, in: self),
            to: nil
        )
        guard let cancellationDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: cancellationStart,
            modifierFlags: [],
            timestamp: 1.3,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 104,
            clickCount: 1,
            pressure: 1
        ), let staleCancellationUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: cancellationStart,
            modifierFlags: [],
            timestamp: 1.4,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 105,
            clickCount: 1,
            pressure: 0
        ) else {
            preconditionFailure("Selected-text cancellation regression could not synthesize pointer events.")
        }
        beginSelectedTextResize(handle: cancellationHandle, event: cancellationDown)
        precondition(
            cancelSelectedTextResize(reason: "debug-simulated-missed-mouse-up"),
            "Selected-text resizing must expose an explicit cancellation path."
        )
        endSelectedTextResize(handle: cancellationHandle, event: staleCancellationUp)
        precondition(
            selectedTextResizeInteraction == nil
                && session.controller.document.annotations.first(where: {
                    $0.id == resizedText.id
                }) == resizedText,
            "A stale selected-text mouse-up must not commit or corrupt a cancelled preview."
        )
        runSelectedTextMoveCursorOwnershipRegression(
            itemID: resizedText.id,
            eventNumberBase: 500
        )
        let rectangleProbe = AnnotationItem(
            kind: .rectangle,
            zIndex: 0,
            geometry: .rect(CGRect(x: 10, y: 10, width: 40, height: 30))
        )
        precondition(
            selectionGeometry.handlePoints(for: rectangleProbe).count == 8,
            "Text-specific selection chrome must not change rectangle resize handles."
        )
        precondition(
            supportsStableInlineTextEditing(transform: AnnotationTransform(
                translation: CGSize(width: 12, height: -8),
                scaleX: 1.5,
                scaleY: 1.5
            )),
            "Axis-aligned uniformly scaled legacy text must remain inline editable."
        )
        precondition(
            !supportsStableInlineTextEditing(transform: AnnotationTransform(
                rotationRadians: .pi / 8
            )),
            "Rotated text must not enter an editor that cannot reproduce its presentation transform."
        )
        precondition(
            !supportsStableInlineTextEditing(transform: AnnotationTransform(
                scaleX: 1.25,
                scaleY: 0.75
            )),
            "Non-uniformly scaled text must not enter an editor that cannot reproduce its presentation transform."
        )
        precondition(
            !supportsStableInlineTextEditing(transform: AnnotationTransform(
                rotationRadians: 0.000_001
            )),
            "Even a small text rotation must be rejected when the inline editor cannot render rotation."
        )
        precondition(
            !supportsStableInlineTextEditing(transform: AnnotationTransform(
                scaleX: 1.000_01,
                scaleY: 1
            )),
            "Small non-uniform text scaling must be rejected before its error grows with line length."
        )
        let visible = visibleDocumentRect()
        let subpointScale: CGFloat = 0.02
        let subpointState = TextEditingState(
            itemID: nil,
            anchor: .zero,
            style: committedItem.style,
            transform: AnnotationTransform(
                scaleX: subpointScale,
                scaleY: subpointScale
            )
        )
        let expectedSubpointFontSize = committedItem.style.fontSize
            * bounds.height / visible.height
            * subpointScale
        let subpointFont = requiredTextEditorFontForRegression(subpointState)
        precondition(
            expectedSubpointFontSize < 1
                && abs(subpointFont.pointSize - committedItem.style.fontSize) < 0.000_1
                && abs(
                    textEditorFieldHeightInView(
                        fromUntransformedDocumentHeight: subpointFont.pointSize,
                        state: subpointState
                    ) - expectedSubpointFontSize
                ) < 0.000_1,
            "Inline TextKit must keep canonical typography while the document host projects it below one presentation point."
        )
        runInitiallyOverflowingTextAlignmentRegression(style: committedItem.style)
        runLegacyOverhangNoOpTextResizeRegression(eventNumberBase: 1_200)
        runInlineTextPointerAndLineBreakRegression()
        runInlineTextEditorAdmissionRegression()
        AppLog.capture.notice(
            "Inline text stability regression passed: characters=7, background=clear, origin=\(initialLineOrigin.x, privacy: .public),\(initialLineOrigin.y, privacy: .public), baselineCorrections=\(baselineCorrections, privacy: .public), commitError=\(self.lastTextCommitBaselineError?.y ?? .infinity, privacy: .public), activeResizeHandles=3, activeResizeFrames=58, selectedResizeHandles=3, selectedDeleteControls=1, selectedMoveCursorCycles=2, initialOverflowAlignments=3, fractionalScaleMultilineCases=12"
        )
    }

    private func runSelectedTextMoveCursorOwnershipRegression(
        itemID: UUID,
        eventNumberBase: Int
    ) {
        guard let window,
              let initialItem = session.controller.document.annotations.first(where: {
                  $0.id == itemID
              })
        else {
            preconditionFailure("Selected-text cursor regression requires a presented text annotation.")
        }
        precondition(initialItem.kind == .text, "The move cursor regression requires text geometry.")
        precondition(
            textEditor == nil && selectionInteraction == nil,
            "The move cursor regression requires an idle inline editor and pointer lifecycle."
        )
        session.currentTool = .select
        session.controller.selectedItemIDs = [itemID]
        syncSelectedTextChrome()

        let initialBounds = selectionGeometry.transformedBounds(for: initialItem)
        let startInView = viewPoint(fromDocumentPoint: CGPoint(
            x: initialBounds.midX,
            y: initialBounds.midY
        ))
        let subthresholdInView = CGPoint(x: startInView.x + 2, y: startInView.y + 1)
        let movedInView = CGPoint(x: startInView.x + 18, y: startInView.y + 12)
        let timestamp = ProcessInfo.processInfo.systemUptime

        func event(
            _ type: NSEvent.EventType,
            at point: CGPoint,
            number: Int,
            pressure: Float
        ) -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: convert(point, to: nil),
                modifierFlags: [],
                timestamp: timestamp + Double(number - eventNumberBase) * 0.01,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: pressure
            ) else {
                preconditionFailure("Selected-text cursor regression could not synthesize \(type.rawValue).")
            }
            return event
        }

        func assertPressedCursor(_ context: String, expectsMovement: Bool) {
            guard let interaction = selectionInteraction else {
                preconditionFailure("Selected-text cursor regression lost its interaction during \(context).")
            }
            guard case .move = interaction.mode else {
                preconditionFailure("Selected-text cursor regression entered a non-move interaction during \(context).")
            }
            precondition(
                interaction.hasMoved == expectsMovement,
                "Selected-text cursor regression reported the wrong movement threshold state during \(context)."
            )
            precondition(
                NSCursor.current == NSCursor.closedHand,
                "Selected-text move must retain its closed-hand cursor during \(context)."
            )
            precondition(
                selectedTextFrameView?.areChromeCursorRectsSuppressed == true,
                "Selected-text chrome must yield cursor ownership during \(context)."
            )
        }

        mouseDown(with: event(
            .leftMouseDown,
            at: startInView,
            number: eventNumberBase,
            pressure: 1
        ))
        assertPressedCursor("zero-movement press", expectsMovement: false)

        NSCursor.arrow.set()
        resetCursorRects()
        assertPressedCursor("cursor-rect rebuild", expectsMovement: false)

        NSCursor.arrow.set()
        layout()
        assertPressedCursor("selected-text chrome layout", expectsMovement: false)

        mouseDragged(with: event(
            .leftMouseDragged,
            at: subthresholdInView,
            number: eventNumberBase + 1,
            pressure: 1
        ))
        assertPressedCursor("subthreshold drag", expectsMovement: false)
        mouseUp(with: event(
            .leftMouseUp,
            at: subthresholdInView,
            number: eventNumberBase + 2,
            pressure: 0
        ))
        precondition(selectionInteraction == nil, "Pointer-up must release annotation move ownership.")
        precondition(
            selectedTextFrameView?.areChromeCursorRectsSuppressed == false,
            "Pointer-up must restore selected-text chrome cursor regions."
        )
        precondition(
            session.controller.document.annotations.first(where: { $0.id == itemID }) == initialItem,
            "A subthreshold text drag must not mutate the document."
        )
        precondition(
            NSCursor.current == NSCursor.openHand,
            "Releasing an unmoved selected text must restore its open-hand hover cursor."
        )

        mouseDown(with: event(
            .leftMouseDown,
            at: startInView,
            number: eventNumberBase + 3,
            pressure: 1
        ))
        assertPressedCursor("committing press", expectsMovement: false)
        mouseDragged(with: event(
            .leftMouseDragged,
            at: movedInView,
            number: eventNumberBase + 4,
            pressure: 1
        ))
        assertPressedCursor("live move", expectsMovement: true)

        NSCursor.arrow.set()
        applyCursor(for: CGPoint(x: bounds.maxX - 1, y: bounds.midY))
        assertPressedCursor("pinned-window edge crossing", expectsMovement: true)

        NSCursor.arrow.set()
        resetCursorRects()
        assertPressedCursor("live cursor-rect rebuild", expectsMovement: true)
        mouseUp(with: event(
            .leftMouseUp,
            at: movedInView,
            number: eventNumberBase + 5,
            pressure: 0
        ))
        precondition(selectionInteraction == nil, "Committed mouse-up must release move ownership.")
        precondition(
            selectedTextFrameView?.areChromeCursorRectsSuppressed == false
                && NSCursor.current == NSCursor.openHand,
            "Committed mouse-up must restore selected-text hover cursor ownership."
        )
        guard let movedItem = session.controller.document.annotations.first(where: {
            $0.id == itemID
        }) else {
            preconditionFailure("Selected-text cursor regression lost its moved item.")
        }
        let documentDelta = documentOffset(fromViewOffset: CGSize(
            width: movedInView.x - startInView.x,
            height: movedInView.y - startInView.y
        ))
        let movedBounds = selectionGeometry.transformedBounds(for: movedItem)
        precondition(
            abs(movedBounds.minX - initialBounds.minX - documentDelta.width) < 0.01
                && abs(movedBounds.minY - initialBounds.minY - documentDelta.height) < 0.01,
            "Selected-text cursor regression committed the wrong move delta."
        )
        session.controller.undo()
        precondition(
            session.controller.document.annotations.first(where: { $0.id == itemID }) == initialItem,
            "One undo must restore the text moved during cursor regression."
        )
        session.controller.selectedItemIDs = [itemID]
        syncSelectedTextChrome()
        AppLog.capture.notice(
            "Selected-text move cursor regression passed: pressCursor=closed-hand, subthresholdMutation=false, liveCursor=closed-hand, edgeCursor=closed-hand, releaseCursor=open-hand"
        )
    }

    private func runInitiallyOverflowingTextAlignmentRegression(
        style sourceStyle: AnnotationStyle
    ) {
        precondition(
            textEditor == nil && textEditingState == nil,
            "Initial-overflow regression requires no active inline editor."
        )
        let originalStyle = session.currentStyle
        let originalStyleOrigin = session.currentStyleOrigin
        let originalSelection = session.controller.selectedItemIDs
        let availableFieldBounds = bounds.insetBy(
            dx: InlineAnnotationTextEditorFrameView.chromeOutset,
            dy: InlineAnnotationTextEditorFrameView.chromeOutset
        )
        let overflowText = String(repeating: "W中", count: 48)
        let appendedOverflowText = "宽W"

        func encodedItem(_ item: AnnotationItem) -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                return try encoder.encode(item)
            } catch {
                preconditionFailure(
                    "Initial-overflow regression could not encode its no-op fixture: \(error)"
                )
            }
        }

        func assertCanonicalPresentation(
            context: String,
            expectedAnchor: CGPoint,
            expectedFieldFrame: CGRect,
            requiresOverflow: Bool?,
            allowsViewportGrowth: Bool = false
        ) -> CGPoint {
            updateTextEditorFrame(scrollsToInsertionPoint: true)
            updateTextEditorLayout(scrollsToInsertionPoint: true)
            layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            guard let editor = textEditor,
                  let frameView = textEditorFrameView,
                  let container = textEditorContainer,
                  let documentView = textEditorDocumentView,
                  let presentation = textEditorPresentationLayout,
                  let state = textEditingState,
                  let visibleLineOrigin = textEditorLineOriginInView(editor)
            else {
                preconditionFailure(
                    "Initial-overflow regression lost editor geometry during \(context)."
                )
            }
            guard let wrapWidthInDocument = textEditorCanonicalWrapWidthInDocument else {
                preconditionFailure(
                    "Initial-overflow regression lost semantic wrap ownership during \(context)."
                )
            }
            let wrapWidth = wrapWidthInDocument
            let renderedLineOrigin = renderedTextLineOriginInView(
                state: state,
                text: editor.string,
                layout: textEditorLayoutPayload
            )
            let horizontalScrollOffset = presentation.documentBaseOrigin.x
                - documentView.frame.minX
            let canonicalTextKitOrigin = CGPoint(
                x: visibleLineOrigin.x + horizontalScrollOffset,
                y: visibleLineOrigin.y
            )
            precondition(
                hypot(
                    canonicalTextKitOrigin.x - renderedLineOrigin.x,
                    canonicalTextKitOrigin.y - renderedLineOrigin.y
                ) < 0.01,
                "TextKit and Core Text lost their canonical origin during \(context): textKit=\(canonicalTextKitOrigin), renderer=\(renderedLineOrigin), scroll=\(horizontalScrollOffset)."
            )
            assertTextEditorLinesMatchRenderer(
                editor,
                state: state,
                layout: textEditorLayoutPayload,
                canonicalHorizontalOffset: horizontalScrollOffset,
                context: context
            )
            precondition(
                hypot(
                    state.anchor.x - expectedAnchor.x,
                    state.anchor.y - expectedAnchor.y
                ) < 0.001,
                "Canonical text anchor changed during \(context)."
            )
            let currentField = frameView.fieldFrame(in: self)
            if allowsViewportGrowth {
                let anchoredEdgeError: CGFloat
                switch state.style.textAlignment {
                case .leading:
                    anchoredEdgeError = abs(expectedFieldFrame.minX - currentField.minX)
                case .center:
                    anchoredEdgeError = abs(expectedFieldFrame.midX - currentField.midX)
                case .trailing:
                    anchoredEdgeError = abs(expectedFieldFrame.maxX - currentField.maxX)
                }
                precondition(
                    currentField.width + 0.001 >= expectedFieldFrame.width
                        && anchoredEdgeError < 0.001
                        && abs(expectedFieldFrame.maxY - currentField.maxY) < 0.001,
                    "Growing text must expand its viewport monotonically around the same placement anchor during \(context)."
                )
            } else {
                precondition(
                    abs(expectedFieldFrame.minX - currentField.minX) < 0.001
                        && abs(expectedFieldFrame.width - currentField.width) < 0.001
                        && abs(expectedFieldFrame.maxY - currentField.maxY) < 0.001,
                    "Wrapping must keep the field's leading edge, width and first-line top fixed during \(context)."
                )
            }
            precondition(
                frameView.fieldFrame(in: self).width
                    <= min(
                        InlineTextEditorMetrics.maximumViewportWidth,
                        availableFieldBounds.width
                    ) + 0.01,
                "The interaction viewport exceeded its usability bound during \(context)."
            )
            precondition(
                abs((editor.textContainer?.containerSize.width ?? 0) - wrapWidth) < 0.01,
                "TextKit did not retain the persisted semantic wrap width during \(context)."
            )
            let measuredWidth = AnnotationTextLayout.maximumLineWidth(
                for: editor.string,
                style: state.style
            )
            if requiresOverflow == true {
                precondition(
                    measuredWidth > wrapWidth + 0.01,
                    "Regression text must remain wider than the wrap width during \(context)."
                )
                precondition(
                    AnnotationTextLayout.visualLineCount(
                        in: editor.string,
                        style: state.style,
                        wrapWidth: wrapWidth
                    ) > 1,
                    "Overlong text must wrap onto additional lines during \(context)."
                )
            } else if requiresOverflow == false {
                precondition(
                    measuredWidth <= wrapWidth + 0.5,
                    "Regression text must fit the wrap width during \(context)."
                )
            }
            if let insertionX = textEditorInsertionX(editor) {
                let visibleInsertionX = documentView.frame.minX + insertionX
                let insertionInset = textEditorChromeInsetsInView(
                    for: state
                ).width
                precondition(
                    visibleInsertionX
                        >= insertionInset - 0.5
                        && visibleInsertionX
                            <= container.bounds.maxX
                                - insertionInset + 0.5,
                    "Wrapping lost the insertion point during \(context): visibleX=\(visibleInsertionX), viewport=\(container.bounds)."
                )
            }
            return renderedLineOrigin
        }

        for (alignmentIndex, alignment) in [
            AnnotationTextAlignment.leading,
            .center,
            .trailing
        ].enumerated() {
            var style = sourceStyle
            style.fontName = "Menlo-Regular"
            style.fontSize = 18
            style.textAlignment = alignment
            let anchorXInView: CGFloat
            switch alignment {
            case .leading:
                // Exercise canonical calibration independently from a field
                // placement clamp in the same initial-overflow session.
                anchorXInView = availableFieldBounds.minX + 2
            case .center:
                anchorXInView = availableFieldBounds.midX
            case .trailing:
                anchorXInView = availableFieldBounds.maxX
                    - InlineTextEditorMetrics.horizontalPadding
                    - 2
            }
            let anchor = documentPoint(fromViewPoint: CGPoint(
                x: anchorXInView,
                y: availableFieldBounds.midY
            ))
            let layout = requiredRendererReadyTextLayoutForRegression(
                baselineAnchor: anchor,
                text: overflowText,
                style: style
            )
            let item = AnnotationItem(
                kind: .text,
                zIndex: session.controller.document.annotations.count,
                geometry: .rect(layout.rect),
                style: style,
                text: overflowText,
                textLayout: layout.payload
            )
            session.controller.add(item)
            let itemBytesBeforeEditing = encodedItem(item)
            let undoCountBeforeEditing = session.controller.undoStack.count
            beginTextEditing(item: item)
            guard let editor = textEditor,
                  let frameView = textEditorFrameView,
                  let fieldPlacementAnchorInDocument = textEditorFieldPlacementAnchorInDocument,
                  let state = textEditingState
            else {
                preconditionFailure(
                    "Could not open initially overflowing \(alignment) text."
                )
            }
            let initialFieldFrame = frameView.fieldFrame(in: self)
            if alignment == .leading {
                let contentAnchor = textEditorAlignmentAnchor(
                    for: state,
                    text: editor.string,
                    layout: textEditorLayoutPayload
                )
                let fieldPlacementAnchor = viewPoint(
                    fromDocumentPoint: fieldPlacementAnchorInDocument
                )
                precondition(
                    hypot(
                        contentAnchor.x - fieldPlacementAnchor.x,
                        contentAnchor.y - fieldPlacementAnchor.y
                    ) > 1,
                    "Initial-overflow regression requires one edge-clamped field."
                )
            }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            _ = assertCanonicalPresentation(
                context: "initial \(alignment) overflow",
                expectedAnchor: anchor,
                expectedFieldFrame: initialFieldFrame,
                requiresOverflow: false
            )
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            _ = assertCanonicalPresentation(
                context: "initial \(alignment) overflow at first caret",
                expectedAnchor: anchor,
                expectedFieldFrame: initialFieldFrame,
                requiresOverflow: false
            )
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            _ = assertCanonicalPresentation(
                context: "initial \(alignment) overflow at final caret",
                expectedAnchor: anchor,
                expectedFieldFrame: initialFieldFrame,
                requiresOverflow: false
            )

            editor.insertText(
                appendedOverflowText,
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            _ = assertCanonicalPresentation(
                context: "growing \(alignment) overflow",
                expectedAnchor: anchor,
                expectedFieldFrame: initialFieldFrame,
                requiresOverflow: true
            )
            editor.insertText(
                "",
                replacementRange: NSRange(
                    location: editor.string.utf16.count - appendedOverflowText.utf16.count,
                    length: appendedOverflowText.utf16.count
                )
            )
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            let lineOriginBeforeCommit = assertCanonicalPresentation(
                context: "shrinking but still-overflowed \(alignment) text",
                expectedAnchor: anchor,
                expectedFieldFrame: initialFieldFrame,
                requiresOverflow: false
            )
            _ = endTextEditingIfNeeded(reason: .focusChange)
            guard let committedItem = session.controller.document.annotations.first(where: {
                $0.id == item.id
            }), let committedText = committedItem.text,
                  case .rect(let committedRect) = committedItem.geometry
            else {
                preconditionFailure(
                    "Initial-overflow regression lost committed \(alignment) text."
                )
            }
            let committedAnchor = AnnotationTextLayout.alignmentAnchor(
                in: committedRect,
                text: committedText,
                style: committedItem.style,
                layout: committedItem.textLayout
            )
            let committedState = TextEditingState(
                itemID: committedItem.id,
                anchor: committedAnchor,
                style: committedItem.style,
                transform: committedItem.transform
            )
            let lineOriginAfterCommit = renderedTextLineOriginInView(
                state: committedState,
                text: committedText,
                layout: committedItem.textLayout
            )
            precondition(
                committedItem == item
                    && encodedItem(committedItem) == itemBytesBeforeEditing
                    && session.controller.undoStack.count == undoCountBeforeEditing
                    && committedText == overflowText
                    && hypot(
                        committedAnchor.x - anchor.x,
                        committedAnchor.y - anchor.y
                    ) < 0.001
                    && hypot(
                        lineOriginAfterCommit.x - lineOriginBeforeCommit.x,
                        lineOriginAfterCommit.y - lineOriginBeforeCommit.y
                    ) < 0.01
                    && max(
                        abs(lastTextCommitBaselineError?.x ?? .infinity),
                        abs(lastTextCommitBaselineError?.y ?? .infinity)
                    ) < 0.01,
                "No-op focus-change commit changed initially overflowing \(alignment) text or its undo history."
            )

            if alignment == .trailing {
                beginTextEditing(item: committedItem)
                guard let transitionEditor = textEditor,
                      let transitionFrame = textEditorFrameView
                else {
                    preconditionFailure(
                        "Could not reopen trailing overflow for fit-transition regression."
                    )
                }
                let transitionFieldFrame = transitionFrame.fieldFrame(in: self)
                transitionEditor.insertText(
                    "短",
                    replacementRange: NSRange(
                        location: 0,
                        length: transitionEditor.string.utf16.count
                    )
                )
                transitionEditor.setSelectedRange(
                    NSRange(location: transitionEditor.string.utf16.count, length: 0)
                )
                _ = assertCanonicalPresentation(
                    context: "trailing overflow-to-fit transition",
                    expectedAnchor: anchor,
                    expectedFieldFrame: transitionFieldFrame,
                    requiresOverflow: false
                )
                transitionEditor.insertText(
                    overflowText,
                    replacementRange: NSRange(
                        location: 0,
                        length: transitionEditor.string.utf16.count
                    )
                )
                transitionEditor.setSelectedRange(
                    NSRange(location: transitionEditor.string.utf16.count, length: 0)
                )
                _ = assertCanonicalPresentation(
                    context: "trailing fit-to-overflow transition",
                    expectedAnchor: anchor,
                    expectedFieldFrame: transitionFieldFrame,
                    requiresOverflow: false
                )
                _ = endTextEditingIfNeeded(reason: .focusChange)
                precondition(
                    max(
                        abs(lastTextCommitBaselineError?.x ?? .infinity),
                        abs(lastTextCommitBaselineError?.y ?? .infinity)
                    ) < 0.01,
                    "Trailing fit-to-overflow commit moved the rendered line."
                )
            }

            guard let wideItem = session.controller.document.annotations.first(where: {
                $0.id == item.id
            }) else {
                preconditionFailure("Wide semantic resize regression lost its probe item.")
            }
            beginTextEditing(item: wideItem)
            guard let wideStateBeforeResize = textEditingState,
                  let wideViewportBeforeResize = textEditorContainer,
                  let wideCanonicalBeforeResize = textEditorCanonicalWrapWidthInDocument
            else {
                preconditionFailure("Wide semantic resize regression lost its editor state.")
            }
            let wideViewportWidthBeforeResize = wideViewportBeforeResize.bounds.width
            let wideFontBeforeResize = wideStateBeforeResize.style.fontSize
            let wideFontAfterResize = runActiveTextResizeRegression(
                handle: .southEast,
                pointerDelta: CGPoint(x: 16, y: -8),
                steps: 4,
                eventNumberBase: 800 + alignmentIndex * 20
            )
            guard let wideCanonicalAfterResize = textEditorCanonicalWrapWidthInDocument,
                  let wideViewportAfterResize = textEditorContainer,
                  let widePayloadAfterResize = textEditorLayoutPayload
            else {
                preconditionFailure("Wide semantic resize regression lost resized ownership.")
            }
            let expectedWideCanonical = wideCanonicalBeforeResize
                * wideFontAfterResize / wideFontBeforeResize
            let completeWidePresentationWidth = AnnotationTextLayout.presentationFieldWidth(
                layout: widePayloadAfterResize,
                canvasScale: textEditorCanvasScaleX,
                uniformTransformScale: abs(wideStateBeforeResize.transform.scaleX)
            )
            precondition(
                abs(wideCanonicalAfterResize - expectedWideCanonical) < 0.01
                    && wideViewportWidthBeforeResize
                        <= InlineTextEditorMetrics.maximumViewportWidth + 0.01
                    && wideViewportAfterResize.bounds.width
                        <= InlineTextEditorMetrics.maximumViewportWidth + 0.01
                    && completeWidePresentationWidth
                        > wideViewportAfterResize.bounds.width + 0.01,
                "Wide \(alignment) resize must scale semantic width while keeping the viewport capped."
            )
            _ = endTextEditingIfNeeded(reason: .focusChange)
            guard let resizedWideItem = session.controller.document.annotations.first(where: {
                $0.id == item.id
            }) else {
                preconditionFailure("Wide semantic resize regression lost its committed item.")
            }
            precondition(
                abs(
                    AnnotationTextLayout.canonicalWrapWidth(for: resizedWideItem)
                        - wideCanonicalAfterResize
                ) < 0.01,
                "Wide semantic resize commit replaced canonical width with the capped viewport."
            )

            session.controller.selectedItemIDs = [item.id]
            session.controller.deleteSelection()
            precondition(
                !session.controller.document.annotations.contains { $0.id == item.id },
                "Initial-overflow regression failed to remove its probe annotation."
            )
        }

        // Include a raw form-feed followed by more text. TextKit's default
        // action changes containers, whereas the canonical planner treats it
        // as an LF without changing document UTF-16 ranges.
        let scaledText = "Scale中 first\u{000C}Second mixed 行\nThird line 文"
        let scaledAppend = "WWWWWW"
        for uniformScale in [
            CGFloat(0.75),
            CGFloat(1.25),
            CGFloat(4) / 3,
            CGFloat(1.5)
        ] {
            for alignment in [
                AnnotationTextAlignment.leading,
                .center,
                .trailing
            ] {
                var style = sourceStyle
                style.fontName = "Menlo-Regular"
                style.fontSize = 18
                style.textAlignment = alignment
                let anchorXInView: CGFloat
                switch alignment {
                case .leading: anchorXInView = bounds.width * 0.3
                case .center: anchorXInView = bounds.width * 0.5
                case .trailing: anchorXInView = bounds.width * 0.7
                }
                let anchor = documentPoint(fromViewPoint: CGPoint(
                    x: anchorXInView,
                    y: bounds.height * 0.42
                ))
                let transform = AnnotationTransform(
                    translation: CGSize(width: 12, height: -8),
                    scaleX: uniformScale,
                    scaleY: uniformScale
                )
                let layout = requiredRendererReadyTextLayoutForRegression(
                    baselineAnchor: anchor,
                    text: scaledText,
                    style: style
                )
                let item = AnnotationItem(
                    kind: .text,
                    zIndex: session.controller.document.annotations.count,
                    geometry: .rect(layout.rect),
                    style: style,
                    transform: transform,
                    text: scaledText,
                    textLayout: layout.payload
                )
                session.controller.add(item)
                let itemBytesBeforeEditing = encodedItem(item)
                let undoCountBeforeEditing = session.controller.undoStack.count
                beginTextEditing(item: item)
                guard let editor = textEditor,
                      let frameView = textEditorFrameView,
                      let initialState = textEditingState
                else {
                    preconditionFailure(
                        "Could not open uniformly scaled \(alignment) text at \(uniformScale)x."
                    )
                }
                guard let scaledWrapWidth = textEditorCanonicalWrapWidthInDocument else {
                    preconditionFailure(
                        "Uniform-scale multiline regression lost its canonical wrap width."
                    )
                }
                let scaledPlan = AnnotationTextLayout.layoutPlan(
                    in: editor.string,
                    style: initialState.style,
                    wrapWidth: scaledWrapWidth
                )
                let scaledTextKitLines = textEditorLineSnapshotsInView(editor)
                let expectedBaselineAdvanceInView = textEditorFieldHeightInView(
                    fromUntransformedDocumentHeight: scaledPlan.lineAdvance,
                    state: initialState
                )
                precondition(
                    scaledTextKitLines.count >= 3
                        && zip(
                            scaledTextKitLines,
                            scaledTextKitLines.dropFirst()
                        ).allSatisfy { pair in
                            let (upper, lower) = pair
                            return abs(
                                upper.originInView.y
                                    - lower.originInView.y
                                    - expectedBaselineAdvanceInView
                            ) < 0.01
                        },
                    "Uniform-scale fixture must expose at least three live TextKit baselines at the canonical line advance for \(alignment) at \(uniformScale)x."
                )
                let initialFieldFrame = frameView.fieldFrame(in: self)
                let initialContentAnchor = textEditorAlignmentAnchor(
                    for: initialState,
                    text: editor.string,
                    layout: textEditorLayoutPayload
                )
                let initialRectWidth = AnnotationTextLayout.annotationRect(
                    baselineAnchor: anchor,
                    text: editor.string,
                    style: style
                ).width
                editor.setSelectedRange(
                    NSRange(location: editor.string.utf16.count, length: 0)
                )
                let initialLineOrigin = assertCanonicalPresentation(
                    context: "initial \(uniformScale)x \(alignment) text",
                    expectedAnchor: anchor,
                    expectedFieldFrame: initialFieldFrame,
                    requiresOverflow: nil
                )

                editor.insertText(
                    scaledAppend,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                editor.setSelectedRange(
                    NSRange(location: editor.string.utf16.count, length: 0)
                )
                let lineOriginBeforeCommit = assertCanonicalPresentation(
                    context: "wider \(uniformScale)x \(alignment) text",
                    expectedAnchor: anchor,
                    expectedFieldFrame: initialFieldFrame,
                    requiresOverflow: nil,
                    allowsViewportGrowth: true
                )
                guard let widenedState = textEditingState else {
                    preconditionFailure(
                        "Uniform-scale regression lost its widened editing state."
                    )
                }
                let widenedContentAnchor = textEditorAlignmentAnchor(
                    for: widenedState,
                    text: editor.string,
                    layout: textEditorLayoutPayload
                )
                let widenedRectWidth = AnnotationTextLayout.annotationRect(
                    baselineAnchor: anchor,
                    text: editor.string,
                    style: style
                ).width
                let alignmentCenterFactor: CGFloat
                switch alignment {
                case .leading: alignmentCenterFactor = 0.5
                case .center: alignmentCenterFactor = 0
                case .trailing: alignmentCenterFactor = -0.5
                }
                let expectedContentAnchorDeltaInView = viewOffset(
                    fromDocumentOffset: CGSize(
                        width: (1 - uniformScale)
                            * alignmentCenterFactor
                            * (widenedRectWidth - initialRectWidth),
                        height: 0
                    )
                ).width
                precondition(
                    abs(
                        widenedContentAnchor.x
                            - initialContentAnchor.x
                            - expectedContentAnchorDeltaInView
                    ) < 0.01
                        && widenedState.anchor == anchor
                        && widenedState.transform == transform,
                    "Uniform-scale presentation anchor did not follow renderer geometry for \(alignment) at \(uniformScale)x."
                )

                editor.insertText(
                    "",
                    replacementRange: NSRange(
                        location: editor.string.utf16.count - scaledAppend.utf16.count,
                        length: scaledAppend.utf16.count
                    )
                )
                editor.setSelectedRange(
                    NSRange(location: editor.string.utf16.count, length: 0)
                )
                let restoredLineOrigin = assertCanonicalPresentation(
                    context: "restored \(uniformScale)x \(alignment) no-op text",
                    expectedAnchor: anchor,
                    expectedFieldFrame: initialFieldFrame,
                    requiresOverflow: nil,
                    allowsViewportGrowth: true
                )
                _ = endTextEditingIfNeeded(reason: .focusChange)
                guard let restoredItem = session.controller.document.annotations.first(where: {
                    $0.id == item.id
                }) else {
                    preconditionFailure(
                        "Uniform-scale no-op regression lost \(alignment) text."
                    )
                }
                precondition(
                    restoredItem == item
                        && encodedItem(restoredItem) == itemBytesBeforeEditing
                        && session.controller.undoStack.count == undoCountBeforeEditing
                        && hypot(
                            restoredLineOrigin.x - initialLineOrigin.x,
                            restoredLineOrigin.y - initialLineOrigin.y
                        ) < 0.01
                        && max(
                            abs(lastTextCommitBaselineError?.x ?? .infinity),
                            abs(lastTextCommitBaselineError?.y ?? .infinity)
                        ) < 0.01,
                    "Uniform-scale grow-and-restore changed \(alignment) bytes or undo history at \(uniformScale)x."
                )

                beginTextEditing(item: restoredItem)
                guard let reopenedEditor = textEditor else {
                    preconditionFailure(
                        "Uniform-scale regression could not reopen \(alignment) text after no-op."
                    )
                }
                reopenedEditor.setSelectedRange(
                    NSRange(location: reopenedEditor.string.utf16.count, length: 0)
                )
                reopenedEditor.insertText(
                    scaledAppend,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                reopenedEditor.setSelectedRange(
                    NSRange(location: reopenedEditor.string.utf16.count, length: 0)
                )
                let finalLineOriginBeforeCommit = assertCanonicalPresentation(
                    context: "reopened wider \(uniformScale)x \(alignment) text",
                    expectedAnchor: anchor,
                    expectedFieldFrame: initialFieldFrame,
                    requiresOverflow: nil,
                    allowsViewportGrowth: true
                )
                precondition(
                    hypot(
                        finalLineOriginBeforeCommit.x - lineOriginBeforeCommit.x,
                        finalLineOriginBeforeCommit.y - lineOriginBeforeCommit.y
                    ) < 0.01,
                    "Reopening uniformly scaled text changed its widened renderer origin."
                )

                _ = endTextEditingIfNeeded(reason: .focusChange)
                guard let committedItem = session.controller.document.annotations.first(where: {
                    $0.id == item.id
                }), let committedText = committedItem.text,
                      case .rect(let committedRect) = committedItem.geometry
                else {
                    preconditionFailure(
                        "Uniform-scale regression lost committed \(alignment) text."
                    )
                }
                let committedAnchor = AnnotationTextLayout.alignmentAnchor(
                    in: committedRect,
                    text: committedText,
                    style: committedItem.style,
                    layout: committedItem.textLayout
                )
                let committedState = TextEditingState(
                    itemID: committedItem.id,
                    anchor: committedAnchor,
                    style: committedItem.style,
                    transform: committedItem.transform
                )
                let lineOriginAfterCommit = renderedTextLineOriginInView(
                    state: committedState,
                    text: committedText,
                    layout: committedItem.textLayout
                )
                precondition(
                    committedText == scaledText + scaledAppend
                        && committedAnchor == anchor
                        && committedItem.transform == transform
                        && hypot(
                            lineOriginAfterCommit.x - finalLineOriginBeforeCommit.x,
                            lineOriginAfterCommit.y - finalLineOriginBeforeCommit.y
                        ) < 0.01
                        && max(
                            abs(lastTextCommitBaselineError?.x ?? .infinity),
                            abs(lastTextCommitBaselineError?.y ?? .infinity)
                        ) < 0.01,
                    "Committing \(uniformScale)x \(alignment) text changed its renderer presentation."
                )

                session.controller.selectedItemIDs = [item.id]
                session.controller.deleteSelection()
            }
        }

        var resizeStyle = sourceStyle
        resizeStyle.fontName = "Menlo-Regular"
        resizeStyle.fontSize = 18
        resizeStyle.textAlignment = .leading
        let resizeAnchor = documentPoint(fromViewPoint: CGPoint(
            x: bounds.width * 0.38,
            y: bounds.height * 0.38
        ))
        let resizeTransform = AnnotationTransform(
            translation: CGSize(width: 12, height: -8),
            scaleX: 1.5,
            scaleY: 1.5
        )
        let resizeLayout = requiredRendererReadyTextLayoutForRegression(
            baselineAnchor: resizeAnchor,
            text: "ResizeScale",
            style: resizeStyle
        )
        let resizeItem = AnnotationItem(
            kind: .text,
            zIndex: session.controller.document.annotations.count,
            geometry: .rect(resizeLayout.rect),
            style: resizeStyle,
            transform: resizeTransform,
            text: "ResizeScale",
            textLayout: resizeLayout.payload
        )
        session.controller.add(resizeItem)
        beginTextEditing(item: resizeItem)
        _ = runActiveTextResizeRegression(
            handle: .southEast,
            pointerDelta: CGPoint(x: 24, y: -12),
            steps: 6,
            eventNumberBase: 600
        )
        _ = runActiveTextResizeRegression(
            handle: .northWest,
            pointerDelta: CGPoint(x: 12, y: -6),
            steps: 6,
            eventNumberBase: 650
        )
        _ = runActiveTextResizeRegression(
            handle: .southWest,
            pointerDelta: CGPoint(x: 10, y: 5),
            steps: 6,
            eventNumberBase: 700
        )
        guard let resizedEditor = textEditor,
              let resizedFrameView = textEditorFrameView,
              let resizedState = textEditingState
        else {
            preconditionFailure(
                "Uniform-scale active resize regression lost the editor."
            )
        }
        let resizedLineOriginBeforeCommit = assertCanonicalPresentation(
            context: "uniform-scale three-corner resize",
            expectedAnchor: resizedState.anchor,
            expectedFieldFrame: resizedFrameView.fieldFrame(in: self),
            requiresOverflow: nil
        )
        let resizedText = resizedEditor.string
        _ = endTextEditingIfNeeded(reason: .focusChange)
        guard let committedResizeItem = session.controller.document.annotations.first(where: {
            $0.id == resizeItem.id
        }), let committedResizeText = committedResizeItem.text,
              case .rect(let committedResizeRect) = committedResizeItem.geometry
        else {
            preconditionFailure(
                "Uniform-scale active resize regression lost its committed item."
            )
        }
        let committedResizeState = TextEditingState(
            itemID: committedResizeItem.id,
            anchor: AnnotationTextLayout.alignmentAnchor(
                in: committedResizeRect,
                text: committedResizeText,
                style: committedResizeItem.style,
                layout: committedResizeItem.textLayout
            ),
            style: committedResizeItem.style,
            transform: committedResizeItem.transform
        )
        let resizedLineOriginAfterCommit = renderedTextLineOriginInView(
            state: committedResizeState,
            text: committedResizeText,
            layout: committedResizeItem.textLayout
        )
        precondition(
            committedResizeText == resizedText
                && committedResizeItem.transform == resizeTransform
                && hypot(
                    resizedLineOriginAfterCommit.x - resizedLineOriginBeforeCommit.x,
                    resizedLineOriginAfterCommit.y - resizedLineOriginBeforeCommit.y
                ) < 0.01
                && max(
                    abs(lastTextCommitBaselineError?.x ?? .infinity),
                    abs(lastTextCommitBaselineError?.y ?? .infinity)
                ) < 0.01,
            "Committing uniformly scaled three-corner resize changed its presentation."
        )
        session.controller.selectedItemIDs = [resizeItem.id]
        session.controller.deleteSelection()

        session.adoptCurrentStyle(originalStyle, origin: originalStyleOrigin)
        session.controller.selectedItemIDs = originalSelection
        syncSelectedTextChrome()
    }

    private func runInlineTextPointerAndLineBreakRegression() {
        _ = endTextEditingIfNeeded(reason: .externalAction)
        var style = session.defaultStyle(for: .text)
        style.fontName = "Menlo-Regular"
        style.fontSize = 18
        let anchor = documentPoint(fromViewPoint: CGPoint(
            x: bounds.midX,
            y: bounds.midY
        ))
        installTextEditor(
            text: "AB",
            state: TextEditingState(
                itemID: nil,
                anchor: anchor,
                style: style,
                transform: AnnotationTransform()
            )
        )
        guard let editor = textEditor,
              let frameView = textEditorFrameView,
              let initialLineOrigin = textEditorLineOriginInView(editor)
        else {
            preconditionFailure("Pointer and line-break regression could not start the inline editor.")
        }
        let initialField = frameView.fieldFrame(in: self)
        let clickPoint = CGPoint(x: initialField.midX, y: initialField.midY)
        let framePoint = frameView.convert(clickPoint, from: self)
        let fieldHit = frameView.hitTest(framePoint)
        precondition(
            fieldHit === editor,
            "Clicking the active text field must hit the NSTextView, not \(String(describing: fieldHit.map { type(of: $0) }))."
        )
        let canvasHit = hitTest(clickPoint)
        precondition(
            canvasHit === editor,
            "Canvas hit testing must route field clicks to the NSTextView, not \(String(describing: canvasHit.map { type(of: $0) }))."
        )

        editor.insertNewlineIgnoringFieldEditor(nil)
        updateTextEditorLayout(scrollsToInsertionPoint: true)
        layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        guard let brokenLineOrigin = textEditorLineOriginInView(editor) else {
            preconditionFailure("Pointer and line-break regression lost the first-line origin after inserting a newline.")
        }
        precondition(
            editor.string.contains("\n"),
            "Shift-Return must insert a hard line break instead of committing the annotation."
        )
        precondition(
            AnnotationTextLayout.lineCount(in: editor.string) == 2,
            "A single line break must produce exactly two visual lines."
        )
        precondition(
            abs(brokenLineOrigin.x - initialLineOrigin.x) < 0.01
                && abs(brokenLineOrigin.y - initialLineOrigin.y) < 0.01,
            "Inserting a line break moved the first-line origin from \(initialLineOrigin) to \(brokenLineOrigin)."
        )
        let grownField = frameView.fieldFrame(in: self)
        precondition(
            grownField.height > initialField.height + 1,
            "A line break must grow the text field. initial=\(initialField.height), grown=\(grownField.height)."
        )
        precondition(
            abs(grownField.maxY - initialField.maxY) < 0.51,
            "A line break must keep the first-line top edge fixed. initialMaxY=\(initialField.maxY), grownMaxY=\(grownField.maxY)."
        )

        _ = endTextEditingIfNeeded(reason: .focusChange)
        guard let committedItem = session.controller.document.annotations.last,
              committedItem.kind == .text,
              let committedText = committedItem.text
        else {
            preconditionFailure("Pointer and line-break regression did not commit the multiline annotation.")
        }
        precondition(
            committedText.contains("\n"),
            "Committing inline text must preserve hard line breaks instead of flattening them to spaces."
        )
        session.controller.selectedItemIDs = [committedItem.id]
        session.controller.deleteSelection()
        AppLog.capture.notice(
            "Inline text pointer and line-break regression passed: fieldHit=editor, firstLineOriginStable=true, fieldGrewDownward=true, committedNewline=true"
        )
    }

    private func runInlineTextEditorAdmissionRegression() {
        precondition(textEditor == nil, "Canvas admission regression requires no active editor.")
        let originalBounds = bounds
        for size in [
            CGSize(width: 2, height: 2),
            CGSize(width: 20, height: 20),
            CGSize(width: 19, height: 40)
        ] {
            bounds = CGRect(origin: originalBounds.origin, size: size)
            beginTextEditing(at: .zero)
            precondition(
                textEditor == nil,
                "A \(size.width)x\(size.height) canvas must reject inline text controls without crashing."
            )
        }
        bounds = originalBounds

        var probeStyle = session.defaultStyle(for: .text)
        probeStyle.fontName = "Menlo-Regular"
        probeStyle.fontSize = 18
        probeStyle.textAlignment = .center
        let probeText = "Probe first\u{000C}Probe second\u{000B}Probe third\n"
        let probeLayout = requiredRendererReadyTextLayoutForRegression(
            baselineAnchor: .zero,
            text: probeText,
            style: probeStyle,
            maximumWrapWidth: 240
        )
        let probePlan: AnnotationTextLayoutPlan
        do {
            probePlan = try AnnotationTextLayout.persistedPlan(
                text: probeText,
                style: probeStyle,
                payload: probeLayout.payload
            )
            try validateInlineTextKitEditingCapability(
                text: probeText,
                style: probeStyle,
                payload: probeLayout.payload,
                plan: probePlan
            )
        } catch {
            preconditionFailure(
                "The native offscreen TextKit admission fixture did not reproduce its persisted plan: \(error)"
            )
        }
        precondition(
            probePlan.lineCount >= 4
                && probePlan.lines.last?.utf16Range.length == 0
                && probePlan.lines.last?.consumedUTF16Range.length == 0,
            "The native offscreen TextKit admission fixture must cover three drawable lines and the terminal extra line."
        )
        let selectionBeforeRejectedProbe = session.controller.selectedItemIDs
        let chromeBeforeRejectedProbe = selectedTextFrameView
        var rejectedMismatchedText = false
        do {
            try validateInlineTextKitEditingCapability(
                text: probeText + "X",
                style: probeStyle,
                payload: probeLayout.payload,
                plan: probePlan
            )
        } catch is InlineTextKitEditingCapabilityError {
            rejectedMismatchedText = true
        } catch {
            preconditionFailure(
                "The native offscreen TextKit mismatch fixture returned an unexpected error: \(error)"
            )
        }
        precondition(
            rejectedMismatchedText
                && textEditor == nil
                && textEditingState == nil
                && session.controller.selectedItemIDs == selectionBeforeRejectedProbe
                && selectedTextFrameView === chromeBeforeRejectedProbe,
            "A rejected offscreen TextKit capability probe must leave editor, selection and chrome state unchanged."
        )
        syncSelectedTextChrome()
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
    }

    private func runInlineTextFieldGeometryRegression(style: AnnotationStyle) {
        let availableFieldBounds = bounds.insetBy(
            dx: InlineAnnotationTextEditorFrameView.chromeOutset,
            dy: InlineAnnotationTextEditorFrameView.chromeOutset
        )
        precondition(
            availableFieldBounds.width > 420 && availableFieldBounds.height > 180,
            "Inline text geometry regression requires room away from every canvas edge."
        )
        for alignment in [
            AnnotationTextAlignment.leading,
            .center,
            .trailing
        ] {
            for fontSize in [CGFloat(18), 19.15, 20, 31] {
                var candidateStyle = style
                candidateStyle.textAlignment = alignment
                candidateStyle.fontSize = fontSize
                let candidateState = TextEditingState(
                    itemID: nil,
                    anchor: .zero,
                    style: candidateStyle,
                    transform: AnnotationTransform()
                )
                let font = requiredTextEditorFontForRegression(candidateState)
                let targetFrame = CGRect(
                    x: availableFieldBounds.minX + 90,
                    y: availableFieldBounds.minY + 70,
                    width: 287,
                    height: textEditorFieldHeight(
                        font: font,
                        state: candidateState
                    )
                )
                let alignmentAnchor = textFieldAlignmentAnchor(
                    for: targetFrame,
                    font: font,
                    alignment: alignment,
                    state: candidateState
                )
                let resolvedFrame = resolvedTextFieldFrame(
                    alignmentAnchor: alignmentAnchor,
                    font: font,
                    preferredViewportWidth: targetFrame.width,
                    availableFieldBounds: availableFieldBounds,
                    alignment: alignment,
                    state: candidateState
                )
                precondition(
                    maxFrameDelta(targetFrame, resolvedFrame) < 0.001,
                    "Inline text frame and anchor geometry must round-trip at font size \(fontSize) for \(alignment)."
                )
            }
        }

        var clampedCases = 0
        for alignment in [
            AnnotationTextAlignment.leading,
            .center,
            .trailing
        ] {
            var candidateStyle = style
            candidateStyle.textAlignment = alignment
            candidateStyle.fontSize = 18
            let candidateState = TextEditingState(
                itemID: nil,
                anchor: .zero,
                style: candidateStyle,
                transform: AnnotationTransform()
            )
            let font = requiredTextEditorFontForRegression(candidateState)
            for canonicalAnchor in [
                CGPoint(x: availableFieldBounds.minX + 2, y: availableFieldBounds.minY + 2),
                CGPoint(x: availableFieldBounds.maxX - 2, y: availableFieldBounds.minY + 2),
                CGPoint(x: availableFieldBounds.minX + 2, y: availableFieldBounds.maxY - 2),
                CGPoint(x: availableFieldBounds.maxX - 2, y: availableFieldBounds.maxY - 2)
            ] {
                let initialFrame = resolvedTextFieldFrame(
                    alignmentAnchor: canonicalAnchor,
                    font: font,
                    preferredViewportWidth: 287,
                    availableFieldBounds: availableFieldBounds,
                    alignment: alignment,
                    state: candidateState
                )
                let fieldAnchor = textFieldAlignmentAnchor(
                    for: initialFrame,
                    font: font,
                    alignment: alignment,
                    state: candidateState
                )
                let residual = CGSize(
                    width: canonicalAnchor.x - fieldAnchor.x,
                    height: canonicalAnchor.y - fieldAnchor.y
                )
                if hypot(residual.width, residual.height) > 1 {
                    clampedCases += 1
                }
                for handle in [
                    InlineAnnotationTextResizeHandle.northWest,
                    .southWest,
                    .southEast
                ] {
                    let fixedPoint = textFramePoint(
                        corner: handle.fixedCorner,
                        in: initialFrame
                    )
                    let identicalTarget = textFieldFrame(
                        fixedCorner: handle.fixedCorner,
                        fixedPoint: fixedPoint,
                        size: initialFrame.size
                    )
                    let targetFieldAnchor = textFieldAlignmentAnchor(
                        for: identicalTarget,
                        font: font,
                        alignment: alignment,
                        state: candidateState
                    )
                    let reconstructedCanonicalAnchor = CGPoint(
                        x: targetFieldAnchor.x + residual.width,
                        y: targetFieldAnchor.y + residual.height
                    )
                    precondition(
                        hypot(
                            reconstructedCanonicalAnchor.x - canonicalAnchor.x,
                            reconstructedCanonicalAnchor.y - canonicalAnchor.y
                        ) < 0.001,
                        "Clamped text field placement must preserve its independent canonical anchor for \(alignment) and \(handle.rawValue)."
                    )
                }
            }
        }
        precondition(
            clampedCases == 12,
            "Edge field regression must exercise every alignment at every canvas corner."
        )
    }

    private func runEdgeClampedNoOpTextResizeRegression(eventNumberBase: Int) {
        guard let window,
              let editor = textEditor,
              let frameView = textEditorFrameView,
              var edgeState = textEditingState,
              let preferredViewportWidthInDocument = textEditorPreferredViewportWidthInDocument,
              let canonicalWrapWidthInDocument = textEditorCanonicalWrapWidthInDocument
        else {
            preconditionFailure("Edge-clamped text resize regression requires an active editor.")
        }
        let initialLayoutPayload = textEditorLayoutPayload
        let initialExplicitResizeState = textEditorCanonicalWrapWidthWasExplicitlyResized
        edgeState.anchor.x = documentPoint(fromViewPoint: CGPoint(
            x: bounds.maxX - InlineAnnotationTextEditorFrameView.chromeOutset - 2,
            y: bounds.midY
        )).x
        textEditingState = edgeState
        textEditorFieldPlacementAnchorInDocument = nil
        textEditorPresentationLayout = nil
        updateTextEditorFrame(scrollsToInsertionPoint: true)
        guard let fieldPlacementAnchorInDocument = textEditorFieldPlacementAnchorInDocument,
              let initialLineOrigin = textEditorLineOriginInView(editor)
        else {
            preconditionFailure("Edge-clamped text resize regression could not resolve field placement.")
        }
        let contentAnchor = textEditorAlignmentAnchor(
            for: edgeState,
            text: editor.string,
            layout: textEditorLayoutPayload
        )
        let fieldPlacementAnchor = viewPoint(
            fromDocumentPoint: fieldPlacementAnchorInDocument
        )
        precondition(
            abs(contentAnchor.x - fieldPlacementAnchor.x) > 20,
            "Edge-clamped text resize regression requires a non-invertible horizontal clamp."
        )

        let initialState = edgeState
        let initialFieldFrame = frameView.fieldFrame(in: self)
        let handle = InlineAnnotationTextResizeHandle.southEast
        let activeCorner = textFramePoint(handle: handle, in: initialFieldFrame)
        let fixedCorner = textFramePoint(corner: handle.fixedCorner, in: initialFieldFrame)
        let diagonal = CGPoint(
            x: activeCorner.x - fixedCorner.x,
            y: activeCorner.y - fixedCorner.y
        )
        let perpendicularLength = hypot(diagonal.y, diagonal.x)
        precondition(perpendicularLength > 1, "Edge resize regression requires a non-empty field diagonal.")
        let perpendicularDelta = CGPoint(
            x: diagonal.y / perpendicularLength * 18,
            y: -diagonal.x / perpendicularLength * 18
        )
        let startInWindow = convert(activeCorner, to: nil)
        let noOpInWindow = CGPoint(
            x: startInWindow.x + perpendicularDelta.x,
            y: startInWindow.y + perpendicularDelta.y
        )
        let timestamp = ProcessInfo.processInfo.systemUptime

        func event(
            type: NSEvent.EventType,
            location: CGPoint,
            number: Int,
            pressure: Float
        ) -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp + Double(number) / 120,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumberBase + number,
                clickCount: 1,
                pressure: pressure
            ) else {
                preconditionFailure("Edge-clamped text resize regression could not synthesize event \(number).")
            }
            return event
        }

        beginTextResize(
            handle: handle,
            event: event(type: .leftMouseDown, location: startInWindow, number: 0, pressure: 1)
        )
        updateTextResize(
            handle: handle,
            event: event(type: .leftMouseDragged, location: noOpInWindow, number: 1, pressure: 1)
        )
        endTextResize(
            handle: handle,
            event: event(type: .leftMouseUp, location: noOpInWindow, number: 2, pressure: 0)
        )
        guard let finalState = textEditingState,
              let finalLineOrigin = textEditorLineOriginInView(editor)
        else {
            preconditionFailure("Edge-clamped text resize regression lost the active editor.")
        }
        precondition(
            hypot(
                finalState.anchor.x - initialState.anchor.x,
                finalState.anchor.y - initialState.anchor.y
            ) < 0.001
                && abs(finalState.style.fontSize - initialState.style.fontSize) < 0.001,
            "A perpendicular edge-clamped drag must not change the canonical text state."
        )
        precondition(
            maxFrameDelta(initialFieldFrame, frameView.fieldFrame(in: self)) < 0.001
                && hypot(
                    finalLineOrigin.x - initialLineOrigin.x,
                    finalLineOrigin.y - initialLineOrigin.y
                ) < 0.001,
            "A perpendicular edge-clamped drag must not move the field or visible text."
        )
        precondition(
            abs(
                (textEditorPreferredViewportWidthInDocument ?? .infinity)
                    - preferredViewportWidthInDocument
            ) < 0.001
                && abs(
                    (textEditorCanonicalWrapWidthInDocument ?? .infinity)
                        - canonicalWrapWidthInDocument
                ) < 0.001
                && textEditorLayoutPayload == initialLayoutPayload
                && textEditorCanonicalWrapWidthWasExplicitlyResized
                    == initialExplicitResizeState
                && window.firstResponder === editor,
            "A perpendicular edge-clamped drag must preserve viewport and semantic layout ownership."
        )
    }

    private func runLegacyOverhangNoOpTextResizeRegression(eventNumberBase: Int) {
        precondition(
            textEditor == nil && textEditingState == nil,
            "Legacy overhang resize regression requires an idle inline editor."
        )
        func encodedProbeItem(_ item: AnnotationItem) -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                return try encoder.encode(item)
            } catch {
                preconditionFailure(
                    "Legacy overhang regression could not encode its no-op fixture: \(error)"
                )
            }
        }

        let originalSelection = session.controller.selectedItemIDs
        let originalStyle = session.currentStyle
        let originalStyleOrigin = session.currentStyleOrigin
        var style = originalStyle
        style.fontName = "Zapfino"
        style.fontSize = 18
        style.fontWeight = .regular
        style.textAlignment = .leading
        let text = "Zapfino fj Ág"
        let canonicalWrapWidth: CGFloat = 140
        let legacyRect = CGRect(
            x: documentPoint(fromViewPoint: CGPoint(
                x: bounds.maxX - InlineAnnotationTextEditorFrameView.chromeOutset - 2,
                y: bounds.midY
            )).x,
            y: visibleDocumentRect().midY - 13.5,
            width: canonicalWrapWidth,
            height: 27
        )
        let safePayload = requiredRendererReadyTextPayloadForRegression(
            text: text,
            style: style,
            proposedWrapWidth: canonicalWrapWidth,
            chromeMode: .legacyTight
        )
        precondition(
            safePayload.leadingOverhang + safePayload.trailingOverhang > 0.01
                && abs(
                    safePayload.leadingOverhang - safePayload.trailingOverhang
                ) > 0.01,
            "Legacy overhang regression requires asymmetric Zapfino glyph bearings."
        )
        let transform = AnnotationTransform(scaleX: 1.5, scaleY: 1.5)
        let item = AnnotationItem(
            kind: .text,
            zIndex: session.controller.document.annotations.count,
            geometry: .rect(legacyRect),
            style: style,
            transform: transform,
            text: text,
            textLayout: nil
        )
        session.controller.add(item)
        let encodedItemBeforeEditing = encodedProbeItem(item)
        let undoCountBeforeEditing = session.controller.undoStack.count
        let originalAnchor = AnnotationTextLayout.alignmentAnchor(
            in: legacyRect,
            text: text,
            style: style,
            layout: nil
        )

        beginTextEditing(item: item)
        guard let container = textEditorContainer,
              let documentView = textEditorDocumentView,
              let activeState = textEditingState,
              let activeCanonicalWrapWidth = textEditorCanonicalWrapWidthInDocument
        else {
            preconditionFailure("Legacy overhang regression could not open its probe item.")
        }
        precondition(
            textEditorLayoutPayload == nil
                && abs(activeCanonicalWrapWidth - canonicalWrapWidth) < 0.001
                && documentView.frame.width > container.bounds.width + 0.01
                && activeState.transform == transform,
            "A legacy nil layout must keep semantic width while its overhang scrolls inside the viewport."
        )
        runEdgeClampedNoOpTextResizeRegression(eventNumberBase: eventNumberBase)
        guard let finalState = textEditingState else {
            preconditionFailure("Legacy overhang regression lost its active state after resize.")
        }
        precondition(
            hypot(
                finalState.anchor.x - originalAnchor.x,
                finalState.anchor.y - originalAnchor.y
            ) < 0.001
                && finalState.style.fontSize == style.fontSize
                && textEditorLayoutPayload == nil
                && !textEditorCanonicalWrapWidthWasExplicitlyResized,
            "A projected scale-one drag must preserve the complete legacy text owner."
        )
        _ = endTextEditingIfNeeded(reason: .focusChange)
        guard let committedItem = session.controller.document.annotations.first(where: {
            $0.id == item.id
        }) else {
            preconditionFailure("Legacy overhang regression lost its committed probe item.")
        }
        precondition(
            committedItem == item
                && encodedProbeItem(committedItem) == encodedItemBeforeEditing
                && session.controller.undoStack.count == undoCountBeforeEditing,
            "A projected scale-one legacy resize must remain byte- and undo-equivalent."
        )

        session.controller.selectedItemIDs = [item.id]
        session.controller.deleteSelection()
        session.adoptCurrentStyle(originalStyle, origin: originalStyleOrigin)
        session.controller.selectedItemIDs = originalSelection
        syncSelectedTextChrome()
    }

    private func runTextResizeCancellationRegression(eventNumberBase: Int) {
        guard let window,
              let editor = textEditor,
              let frameView = textEditorFrameView
        else {
            preconditionFailure("Text resize cancellation regression requires an active editor.")
        }
        let timestamp = ProcessInfo.processInfo.systemUptime

        func event(
            type: NSEvent.EventType,
            location: CGPoint,
            number: Int,
            pressure: Float
        ) -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp + Double(number) / 120,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumberBase + number,
                clickCount: 1,
                pressure: pressure
            ) else {
                preconditionFailure("Text resize cancellation regression could not synthesize event \(number).")
            }
            return event
        }

        func startPoint(for handle: InlineAnnotationTextResizeHandle) -> CGPoint {
            convert(
                textFramePoint(handle: handle, in: frameView.fieldFrame(in: self)),
                to: nil
            )
        }

        let firstHandle = InlineAnnotationTextResizeHandle.northWest
        let firstStart = startPoint(for: firstHandle)
        beginTextResize(
            handle: firstHandle,
            event: event(type: .leftMouseDown, location: firstStart, number: 0, pressure: 1)
        )
        precondition(
            cancelTextResize(reason: "debug-simulated-missed-mouse-up"),
            "A lost mouse-up must have an explicit cancellation path."
        )
        endTextResize(
            handle: firstHandle,
            event: event(type: .leftMouseUp, location: firstStart, number: 1, pressure: 0)
        )
        precondition(
            textResizeInteraction == nil && window.firstResponder === editor,
            "A stale mouse-up after cancellation must preserve the active editor."
        )

        let secondHandle = InlineAnnotationTextResizeHandle.southWest
        let secondStart = startPoint(for: secondHandle)
        beginTextResize(
            handle: secondHandle,
            event: event(type: .leftMouseDown, location: secondStart, number: 2, pressure: 1)
        )
        let originalBounds = bounds
        bounds = CGRect(
            origin: originalBounds.origin,
            size: CGSize(
                width: originalBounds.width - 1,
                height: originalBounds.height
            )
        )
        let geometryUpdateWasAccepted = updateTextResize(
            handle: secondHandle,
            event: event(
                type: .leftMouseDragged,
                location: CGPoint(x: secondStart.x + 1, y: secondStart.y),
                number: 3,
                pressure: 1
            )
        )
        bounds = originalBounds
        updateTextEditorFrame(scrollsToInsertionPoint: true)
        precondition(
            !geometryUpdateWasAccepted && textResizeInteraction == nil,
            "Canvas geometry changes must cancel active text resizing instead of trapping."
        )
        endTextResize(
            handle: secondHandle,
            event: event(type: .leftMouseUp, location: secondStart, number: 4, pressure: 0)
        )

        let finalHandle = InlineAnnotationTextResizeHandle.southEast
        let finalStart = startPoint(for: finalHandle)
        beginTextResize(
            handle: finalHandle,
            event: event(type: .leftMouseDown, location: finalStart, number: 5, pressure: 1)
        )
        endTextResize(
            handle: finalHandle,
            event: event(type: .leftMouseUp, location: finalStart, number: 6, pressure: 0)
        )
        precondition(
            textResizeInteraction == nil && window.firstResponder === editor,
            "A new text resize must start normally after every cancellation path."
        )

        guard let stableViewportWidthInDocument = textEditorPreferredViewportWidthInDocument,
              let stableFieldPlacementAnchorInDocument = textEditorFieldPlacementAnchorInDocument,
              let frameView = textEditorFrameView,
              let container = textEditorContainer
        else {
            preconditionFailure("Viewport persistence regression lost its document geometry.")
        }
        let initialViewportWidthInView = container.bounds.width
        let initialFieldFrame = frameView.fieldFrame(in: self)
        bounds = CGRect(
            origin: originalBounds.origin,
            size: CGSize(
                width: originalBounds.width * 0.8,
                height: originalBounds.height * 0.8
            )
        )
        updateTextEditorFrame(scrollsToInsertionPoint: true)
        precondition(
            abs(
                (textEditorPreferredViewportWidthInDocument ?? .infinity)
                    - stableViewportWidthInDocument
            ) < 0.001
                && textEditorFieldPlacementAnchorInDocument
                    == stableFieldPlacementAnchorInDocument,
            "Canvas resizing must preserve the user-owned field geometry in document space."
        )
        bounds = originalBounds
        updateTextEditorFrame(scrollsToInsertionPoint: true)
        precondition(
            abs(container.bounds.width - initialViewportWidthInView) < 0.01
                && maxFrameDelta(
                    frameView.fieldFrame(in: self),
                    initialFieldFrame
                ) < 0.01
                && textEditorFieldPlacementAnchorInDocument
                    == stableFieldPlacementAnchorInDocument,
            "Restoring canvas bounds must restore the explicit text field geometry."
        )
    }

    @discardableResult
    private func runActiveTextResizeRegression(
        handle: InlineAnnotationTextResizeHandle,
        pointerDelta: CGPoint,
        steps: Int,
        eventNumberBase: Int
    ) -> CGFloat {
        guard steps > 1,
              let window,
              let editor = textEditor,
              let frameView = textEditorFrameView,
              let initialState = textEditingState,
              let initialCanonicalWrapWidth = textEditorCanonicalWrapWidthInDocument,
              initialState.itemID != nil
        else {
            preconditionFailure("Active text resize regression requires existing inline text in a window.")
        }
        let initialText = editor.string
        let initialSelection = editor.selectedRange()
        let initialFieldFrame = frameView.fieldFrame(in: self)
        let initialLayoutPlan = AnnotationTextLayout.layoutPlan(
            in: editor.string,
            style: initialState.style,
            wrapWidth: initialCanonicalWrapWidth
        )
        let initialFieldAnchor = textFieldAlignmentAnchor(
            for: initialFieldFrame,
            font: requiredTextEditorFontForRegression(initialState),
            alignment: initialState.style.textAlignment,
            lineCount: initialLayoutPlan.lineCount,
            layoutPlan: initialLayoutPlan,
            layoutPayload: textEditorLayoutPayload,
            state: initialState
        )
        let initialContentAnchor = textEditorAlignmentAnchor(
            for: initialState,
            text: editor.string,
            layout: textEditorLayoutPayload
        )
        let initialContentToFieldResidual = documentOffset(
            fromViewOffset: CGSize(
                width: initialContentAnchor.x - initialFieldAnchor.x,
                height: initialContentAnchor.y - initialFieldAnchor.y
            )
        )
        let activeCornerInView = textFramePoint(handle: handle, in: initialFieldFrame)
        let fixedCornerInView = textFramePoint(
            corner: handle.fixedCorner,
            in: initialFieldFrame
        )
        let startInWindow = convert(activeCornerInView, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime

        func pointerEvent(
            type: NSEvent.EventType,
            location: CGPoint,
            step: Int,
            pressure: Float
        ) -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp + Double(step) / 120,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumberBase + step,
                clickCount: 1,
                pressure: pressure
            ) else {
                preconditionFailure("Active text resize regression could not synthesize event \(step).")
            }
            return event
        }

        beginTextResize(
            handle: handle,
            event: pointerEvent(
                type: .leftMouseDown,
                location: startInWindow,
                step: 0,
                pressure: 1
            )
        )
        updateTextResize(
            handle: handle,
            event: pointerEvent(
                type: .leftMouseDragged,
                location: startInWindow,
                step: 1,
                pressure: 1
            )
        )
        precondition(
            maxFrameDelta(initialFieldFrame, frameView.fieldFrame(in: self)) < 0.001,
            "Pressing an active text resize handle without movement must not change its frame."
        )

        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let location = CGPoint(
                x: startInWindow.x + pointerDelta.x * progress,
                y: startInWindow.y + pointerDelta.y * progress
            )
            updateTextResize(
                handle: handle,
                event: pointerEvent(
                    type: .leftMouseDragged,
                    location: location,
                    step: step + 1,
                    pressure: 1
                )
            )
            let currentFixedCorner = frameView.fieldPoint(
                corner: handle.fixedCorner,
                in: self
            )
            precondition(
                hypot(
                    currentFixedCorner.x - fixedCornerInView.x,
                    currentFixedCorner.y - fixedCornerInView.y
                ) < 0.01,
                "Active text resize moved its fixed corner during frame \(step) for \(handle.rawValue)."
            )
            guard let currentState = textEditingState,
                  let currentCanonicalWrapWidth = textEditorCanonicalWrapWidthInDocument
            else {
                preconditionFailure(
                    "Active text resize lost its canonical state during frame \(step)."
                )
            }
            let currentLayoutPlan = AnnotationTextLayout.layoutPlan(
                in: editor.string,
                style: currentState.style,
                wrapWidth: currentCanonicalWrapWidth
            )
            let currentFieldAnchor = textFieldAlignmentAnchor(
                for: frameView.fieldFrame(in: self),
                font: requiredTextEditorFontForRegression(currentState),
                alignment: currentState.style.textAlignment,
                lineCount: currentLayoutPlan.lineCount,
                layoutPlan: currentLayoutPlan,
                layoutPayload: textEditorLayoutPayload,
                state: currentState
            )
            let currentContentAnchor = textEditorAlignmentAnchor(
                for: currentState,
                text: editor.string,
                layout: textEditorLayoutPayload
            )
            let currentContentToFieldResidual = documentOffset(
                fromViewOffset: CGSize(
                    width: currentContentAnchor.x - currentFieldAnchor.x,
                    height: currentContentAnchor.y - currentFieldAnchor.y
                )
            )
            precondition(
                hypot(
                    currentContentToFieldResidual.width
                        - initialContentToFieldResidual.width,
                    currentContentToFieldResidual.height
                        - initialContentToFieldResidual.height
                ) < 0.01,
                "Active text resize changed its content-to-field relationship during frame \(step) for \(handle.rawValue)."
            )
            precondition(
                window.firstResponder === editor
                    && editor.string == initialText
                    && editor.selectedRange() == initialSelection,
                "Active text resize changed focus, text, or selection during frame \(step)."
            )
            precondition(
                abs(textEditorBaselineError?.y ?? .infinity) < 0.01,
                "Active text resize left a vertical baseline error during frame \(step)."
            )
            if let presentation = textEditorPresentationLayout,
               let documentView = textEditorDocumentView,
               abs(documentView.frame.minX - presentation.documentBaseOrigin.x) < 0.01
            {
                precondition(
                    abs(textEditorBaselineError?.x ?? .infinity) < 0.01,
                    "Unscrolled active text resize left a horizontal baseline error during frame \(step)."
                )
            }
            if let insertionX = textEditorInsertionX(editor),
               let documentView = textEditorDocumentView,
               let container = textEditorContainer
            {
                let visibleInsertionX = documentView.frame.minX + insertionX
                let insertionInset = textEditorChromeInsetsInView(
                    for: currentState
                ).width
                precondition(
                    visibleInsertionX
                        >= insertionInset - 0.5
                        && visibleInsertionX
                            <= container.bounds.maxX
                                - insertionInset + 0.5,
                    "Active text resize moved the insertion point outside the viewport during frame \(step): visibleX=\(visibleInsertionX), viewport=\(container.bounds), document=\(documentView.frame), font=\(textEditingState?.style.fontSize ?? -1)."
                )
            }
        }
        let endInWindow = CGPoint(
            x: startInWindow.x + pointerDelta.x,
            y: startInWindow.y + pointerDelta.y
        )
        endTextResize(
            handle: handle,
            event: pointerEvent(
                type: .leftMouseUp,
                location: endInWindow,
                step: steps + 2,
                pressure: 0
            )
        )
        guard let finalState = textEditingState else {
            preconditionFailure("Active text resize regression lost the editing state.")
        }
        precondition(
            textResizeInteraction == nil
                && window.firstResponder === editor
                && editor.string == initialText
                && editor.selectedRange() == initialSelection,
            "Ending active text resize must preserve the inline editing session."
        )
        precondition(
            abs(finalState.style.fontSize - initialState.style.fontSize) > 0.05,
            "Active text resize regression must change the font size for \(handle.rawValue)."
        )
        return finalState.style.fontSize
    }

    func prepareInlineTextResizeUITest() {
        layoutSubtreeIfNeeded()
        precondition(bounds.width > 0 && bounds.height > 0, "Inline text resize UI testing requires a laid-out canvas.")
        session.currentTool = .text
        beginTextEditing(at: documentPoint(fromViewPoint: CGPoint(
            x: bounds.width * 0.18,
            y: bounds.height * 0.52
        )))
        guard let editor = textEditor else {
            preconditionFailure("Inline text resize UI testing could not start the editor.")
        }
        editor.insertText(
            "Resize 中文混排",
            replacementRange: NSRange(location: 0, length: editor.string.utf16.count)
        )
        updateTextEditorLayout(scrollsToInsertionPoint: true)
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.notice("Prepared active inline text editor for resize UI testing")
    }
#endif

    init(
        session: AnnotationEditingSession,
        drawsBaseImage: Bool = true,
        selectsNewAnnotationsAfterCommit: Bool = true
    ) {
        self.session = session
        self.drawsBaseImage = drawsBaseImage
        self.selectsNewAnnotationsAfterCommit = selectsNewAnnotationsAfterCommit
        baseImage = NSImage(cgImage: session.baseImage.image, size: session.baseImage.logicalSize)
        previewImage = NSImage(cgImage: session.previewImage.image, size: session.previewImage.logicalSize)
        authoritativeImage = NSImage(
            cgImage: session.authoritativePreviewImage.image,
            size: session.authoritativePreviewImage.logicalSize
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        syncPresentationContentCornerRadius()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Quick Annotation Overlay", comment: "Quick annotation canvas"))
        setAccessibilityIdentifier("pinned.canvas")
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)

        session.$baseImage
            .sink { [weak self] captured in
                guard let self else { return }
                self.baseImage = NSImage(cgImage: captured.image, size: captured.logicalSize)
                self.blurredEffectPreview = nil
                self.mosaicedEffectPreview = nil
                self.needsDisplay = true
            }
            .store(in: &cancellables)
        session.$previewImage
            .sink { [weak self] captured in
                guard let self else { return }
                self.previewImage = NSImage(cgImage: captured.image, size: captured.logicalSize)
                self.needsDisplay = true
                self.updateAccessibilitySummary(document: self.session.controller.document, captured: captured)
            }
            .store(in: &cancellables)
        session.$authoritativePreviewImage
            .sink { [weak self] captured in
                guard let self else { return }
                self.authoritativeImage = NSImage(cgImage: captured.image, size: captured.logicalSize)
                self.onPreviewChange?(captured)
            }
            .store(in: &cancellables)
        session.$renderedPreviewExcludedAnnotationIDs
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &cancellables)
        session.controller.statePublisher
            .sink { [weak self] state in
                guard let self else { return }
                self.syncCurrentStyleWithEditorState(
                    document: state.document,
                    selectedItemIDs: state.selectedItemIDs,
                    reason: "document-state"
                )
                self.syncPresentationContentCornerRadius()
                self.needsDisplay = true
                self.refreshPreviewExclusions(
                    document: state.document,
                    selectedItemIDs: state.selectedItemIDs
                )
                self.syncSelectedTextChrome(
                    document: state.document,
                    selectedItemIDs: state.selectedItemIDs
                )
                self.window?.invalidateCursorRects(for: self)
                self.updateAccessibilitySummary(
                    document: state.document,
                    captured: self.session.previewImage,
                    selectedItemIDs: state.selectedItemIDs
                )
            }
            .store(in: &cancellables)
        session.$currentTool
            .sink { [weak self] currentTool in
                guard let self else { return }
                precondition(
                    self.lineWidthEditingState == nil,
                    "Changing annotation tools requires the active line-width edit to be resolved first."
                )
                if currentTool != .text, self.isTextEditing,
                   !self.endTextEditingIfNeeded(reason: .toolChange)
                {
                    AppLog.capture.notice(
                        "Restored the Text tool because active text could not commit"
                    )
                    self.session.currentTool = .text
                    return
                }
                self.cancelProvisionalDrawing()
                self.syncSelectedTextChrome()
                if currentTool != .blur {
                    self.blurredEffectPreview = nil
                }
                if currentTool != .mosaic {
                    self.mosaicedEffectPreview = nil
                }
                self.syncCurrentStyleWithEditorState(
                    document: self.session.controller.document,
                    selectedItemIDs: self.session.controller.selectedItemIDs,
                    reason: "tool-change"
                )
                self.updateAccessibilitySummary(
                    document: self.session.controller.document,
                    captured: self.session.previewImage,
                    currentTool: currentTool
                )
            }
            .store(in: &cancellables)
        session.$currentStyle
            .sink { [weak self] currentStyle in
                guard let self else { return }
                self.needsDisplay = true
                self.updateAccessibilitySummary(
                    document: self.session.controller.document,
                    captured: self.session.previewImage,
                    currentStyle: currentStyle
                )
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        )
        .sink { [weak self] _ in
            self?.cancelTextResize(reason: "application-resigned-active")
            self?.cancelSelectedTextResize(reason: "application-resigned-active")
            self?.cancelSelectionInteraction(reason: "application-resigned-active")
        }
        .store(in: &cancellables)
        NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification
        )
        .sink { [weak self] notification in
            guard let self,
                  let notificationWindow = notification.object as? NSWindow,
                  notificationWindow === self.window
            else { return }
            self.cancelTextResize(reason: "window-resigned-key")
            self.cancelSelectedTextResize(reason: "window-resigned-key")
            self.cancelSelectionInteraction(reason: "window-resigned-key")
        }
        .store(in: &cancellables)
        NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification
        )
        .sink { [weak self] notification in
            guard let self,
                  let notificationWindow = notification.object as? NSWindow,
                  notificationWindow === self.window
            else { return }
            self.cancelTextResize(reason: "window-will-close")
            self.cancelSelectedTextResize(reason: "window-will-close")
            self.cancelSelectionInteraction(reason: "window-will-close")
        }
        .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let frameView = textEditorFrameView,
           frameView.frame.contains(point)
        {
            let framePoint = frameView.convert(point, from: self)
            if let textTarget = frameView.hitTest(framePoint) {
                return textTarget
            }
        }
        if let frameView = selectedTextFrameView,
           frameView.frame.contains(point)
        {
            let framePoint = frameView.convert(point, from: self)
            if let textTarget = frameView.hitTest(framePoint) {
                return textTarget
            }
        }
        return super.hitTest(point)
    }

    func setAnnotationEditingEnabled(_ enabled: Bool) {
        setAnnotationEditingEnabled(
            enabled,
            preservesSharedEditorState: false,
            reason: "toolbar-visibility"
        )
    }

    func suspendAnnotationEditingForExternalOwner(reason: String) {
        setAnnotationEditingEnabled(
            false,
            preservesSharedEditorState: true,
            reason: reason
        )
    }

    private func setAnnotationEditingEnabled(
        _ enabled: Bool,
        preservesSharedEditorState: Bool,
        reason: String
    ) {
        if !enabled {
            pendingRegionBodyMoveMouseDown = nil
            regionBodyMoveStartScreenPoint = nil
            regionBodyMoveHasDragged = false
            pendingRegionDoubleClickCopy = false
            finishWindowDragIfNeeded(reason: "annotation-editing-disabled-\(reason)")
        }
        guard isAnnotationEditingEnabled != enabled else { return }
        if !enabled {
            _ = endTextEditingIfNeeded(reason: .externalAction)
            cancelLineWidthEditing(reason: "annotation-editing-disabled")
            cancelProvisionalDrawing()
            isReadOnlyWindowDragArmed = false
            if !preservesSharedEditorState {
                session.controller.selectedItemIDs.removeAll()
                session.setPreviewExcludedAnnotationIDs([])
            }
        }
        isAnnotationEditingEnabled = enabled
        syncSelectedTextChrome()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
        AppLog.capture.notice(
            "Pinned canvas annotation editing changed: enabled=\(enabled, privacy: .public), annotations=\(self.session.controller.document.annotations.count, privacy: .public), preservedSharedState=\(preservesSharedEditorState, privacy: .public), reason=\(reason, privacy: .public)"
        )
    }

    func setDrawsBaseImage(_ drawsBaseImage: Bool) {
        guard self.drawsBaseImage != drawsBaseImage else { return }
        self.drawsBaseImage = drawsBaseImage
        syncPresentationContentCornerRadius()
        needsDisplay = true
    }

    /// Keeps the live canvas clip aligned with export `canvasEffects.cornerRadius`.
    /// Region drafts write a non-zero radius; other captures keep the decorative pin radius.
    func syncPresentationContentCornerRadius(for size: CGSize? = nil) {
        let targetSize = size ?? bounds.size
        let documentRadius = session.controller.document.canvasEffects.cornerRadius
        let radius: CGFloat
        if documentRadius > 0 {
            radius = RegionCaptureCornerRadius.effective(
                for: targetSize.width > 0 && targetSize.height > 0
                    ? targetSize
                    : session.controller.document.canvasSize,
                configured: documentRadius
            )
        } else {
            radius = drawsBaseImage ? 5 : 0
        }
        wantsLayer = true
        if layer?.cornerRadius != radius {
            layer?.cornerRadius = radius
        }
        layer?.masksToBounds = true
    }

    func applyStrokeColor(_ color: NSColor) {
        let convertedColor: RGBAColor
        do {
            convertedColor = try session.annotationColor(from: color)
        } catch {
            session.onError?(error)
            return
        }

        if var state = textEditingState {
            state.style = style(
                state.style,
                applying: convertedColor,
                for: .text
            )
            textEditingState = state
            session.adoptCurrentStyle(
                state.style,
                origin: state.itemID == nil ? .newTextDraft : .existingAnnotation
            )
            applyActiveTextEditorStyle(state.style)
            needsDisplay = true
            updateAccessibilitySummary(
                document: session.controller.document,
                captured: session.previewImage
            )
            AppLog.capture.notice(
                "Changed active inline text color: mode=\(state.itemID == nil ? "new" : "existing", privacy: .public), color=\(AnnotationColorPalette.hexString(for: convertedColor), privacy: .public)"
            )
            return
        }

        let selectedIDs = session.controller.selectedItemIDs
        if !selectedIDs.isEmpty {
            var representativeStyle: AnnotationStyle?
            session.controller.perform(label: "Change annotation color") { document in
                for index in document.annotations.indices
                    where selectedIDs.contains(document.annotations[index].id)
                        && !document.annotations[index].isLocked
                {
                    let kind = document.annotations[index].kind
                    document.annotations[index].style = self.style(
                        document.annotations[index].style,
                        applying: convertedColor,
                        for: kind
                    )
                    representativeStyle = representativeStyle ?? document.annotations[index].style
                }
            }
            if let representativeStyle {
                session.adoptCurrentStyle(
                    representativeStyle,
                    origin: .existingAnnotation
                )
                AppLog.capture.notice(
                    "Changed selected annotation color: selected=\(selectedIDs.count, privacy: .public), color=\(AnnotationColorPalette.hexString(for: convertedColor), privacy: .public)"
                )
                return
            }
        }

        session.setStrokeColor(convertedColor)
    }

    func applyEditorSettings(_ editor: EditorSettings) {
        session.updateEditorSettings(editor)
        let palette = editor.availableColorHexes
        let currentHex = AnnotationColorPalette.hexString(
            for: session.currentStyle.strokeColor
        )
        let isEditingExistingAnnotation = session.currentStyleOrigin == .existingAnnotation
            && !session.controller.selectedItemIDs.isEmpty
        guard !palette.contains(currentHex), !isEditingExistingAnnotation else { return }

        let replacementColor = session.defaultStyle(for: session.currentTool).strokeColor
        let replacementHex = AnnotationColorPalette.hexString(for: replacementColor)
        if session.currentStyleOrigin == .newTextDraft {
            applyStrokeColor(NSColor(
                srgbRed: replacementColor.red,
                green: replacementColor.green,
                blue: replacementColor.blue,
                alpha: replacementColor.alpha
            ))
        } else {
            session.setStrokeColor(replacementColor)
        }
        AppLog.capture.notice(
            "Reset active canvas color after palette removal: tool=\(self.session.currentTool.rawValue, privacy: .public), removed=\(currentHex, privacy: .public), replacement=\(replacementHex, privacy: .public), activeTextDraft=\(self.textEditingState != nil, privacy: .public)"
        )
    }

    func beginLineWidthEditing() {
        precondition(
            lineWidthEditingState == nil,
            "A line-width edit cannot begin while another line-width edit is active."
        )
        let selectedItems = selectedLineWidthEditableItems()
        let target: LineWidthEditTarget
        let initialLineWidth: CGFloat
        if selectedItems.isEmpty {
            precondition(
                session.currentTool.supportsLineWidthEditing,
                "A tool-default line-width edit requires a stroked drawing tool."
            )
            let style = session.creationStyle(for: session.currentTool)
            target = .toolDefault(tool: session.currentTool, initialStyle: style)
            initialLineWidth = style.lineWidth
        } else {
            let items = Dictionary(uniqueKeysWithValues: selectedItems.map { ($0.id, $0) })
            target = .selection(initialItems: items)
            initialLineWidth = selectedItems[0].style.lineWidth
        }
        lineWidthEditingState = LineWidthEditingState(
            target: target,
            latestLineWidth: initialLineWidth,
            previewItems: [:]
        )
        AppLog.capture.notice(
            "Began annotation line-width edit: target=\(selectedItems.isEmpty ? "tool-default" : "selection", privacy: .public), tool=\(self.session.currentTool.rawValue, privacy: .public), selectedEditable=\(selectedItems.count, privacy: .public), initialLogicalPoints=\(initialLineWidth, privacy: .public), styleOrigin=\(String(describing: self.session.currentStyleOrigin), privacy: .public)"
        )
    }

    func lineWidthControlPresentation(
        document: AnnotationDocument? = nil,
        selectedItemIDs: Set<UUID>? = nil,
        currentTool: AnnotationTool? = nil
    ) -> LineWidthControlPresentation {
        if let state = lineWidthEditingState {
            return LineWidthControlPresentation(
                isEnabled: true,
                logicalLineWidth: state.latestLineWidth,
                targetDescription: "active-edit"
            )
        }

        let document = document ?? session.controller.document
        let selectedItemIDs = selectedItemIDs ?? session.controller.selectedItemIDs
        if let selectedItem = lineWidthEditableItems(
            document: document,
            selectedItemIDs: selectedItemIDs
        ).first {
            return LineWidthControlPresentation(
                isEnabled: true,
                logicalLineWidth: selectedItem.style.lineWidth,
                targetDescription: "selection"
            )
        }

        let currentTool = currentTool ?? session.currentTool
        if currentTool.supportsLineWidthEditing {
            let style = currentTool == session.currentTool
                ? session.creationStyle(for: currentTool)
                : session.defaultStyle(for: currentTool)
            return LineWidthControlPresentation(
                isEnabled: true,
                logicalLineWidth: style.lineWidth,
                targetDescription: "tool-default"
            )
        }

        return LineWidthControlPresentation(
            isEnabled: false,
            logicalLineWidth: session.currentStyle.lineWidth,
            targetDescription: "unavailable"
        )
    }

    func applyLineWidth(_ lineWidth: CGFloat) {
        precondition(
            lineWidth.isFinite && (0.5...24).contains(lineWidth),
            "A live annotation line width must be finite and supported."
        )
        if lineWidthEditingState == nil {
            beginLineWidthEditing()
        }
        guard var state = lineWidthEditingState else {
            preconditionFailure("A line-width update requires an active edit target.")
        }
        state.latestLineWidth = lineWidth
        let targetDescription: String
        switch state.target {
        case .toolDefault(let tool, _):
            precondition(
                tool == session.currentTool,
                "A tool-default line-width edit must remain owned by its original tool."
            )
            session.setCurrentToolDefaultLineWidth(lineWidth)
            targetDescription = "tool-default"
        case .selection(let initialItems):
            state.previewItems = initialItems.mapValues { item in
                var preview = item
                preview.style.lineWidth = lineWidth
                return preview
            }
            let representativeStyle = session.controller.document.orderedAnnotations
                .compactMap { state.previewItems[$0.id]?.style }
                .first
            guard let representativeStyle else {
                preconditionFailure("A selected line-width edit lost every preview item.")
            }
            session.adoptCurrentStyle(representativeStyle, origin: .existingAnnotation)
            targetDescription = "selection"
        }
        lineWidthEditingState = state
        needsDisplay = true
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.debug(
            "Previewed annotation line-width edit: target=\(targetDescription, privacy: .public), logicalPoints=\(lineWidth, privacy: .public), selectedEditable=\(state.previewItems.count, privacy: .public)"
        )
    }

    func commitLineWidthEditing() -> LineWidthEditCommitTarget {
        guard let state = lineWidthEditingState else {
            AppLog.capture.error("Ignored duplicate annotation line-width commit without an active edit target.")
            return .none
        }
        let result: LineWidthEditCommitTarget
        switch state.target {
        case .toolDefault(let tool, _):
            precondition(
                tool == session.currentTool,
                "A tool-default line-width commit must remain owned by its original tool."
            )
            session.setCurrentToolDefaultLineWidth(state.latestLineWidth)
            result = .toolDefault(tool: tool, lineWidth: state.latestLineWidth)
            AppLog.capture.notice(
                "Committed annotation line-width edit: target=tool-default, tool=\(tool.rawValue, privacy: .public), logicalPoints=\(state.latestLineWidth, privacy: .public), persistedByOwner=true"
            )
        case .selection(let initialItems):
            let targetIDs = Set(initialItems.keys)
            let currentItems = Dictionary(
                uniqueKeysWithValues: session.controller.document.annotations.map { ($0.id, $0) }
            )
            precondition(
                targetIDs.allSatisfy {
                    currentItems[$0]?.isLocked == false
                        && currentItems[$0]?.kind.supportsLineWidthEditing == true
                },
                "A selected line-width edit target disappeared or became non-editable before commit."
            )
            session.controller.perform(label: "Change annotation line width") { document in
                for index in document.annotations.indices
                    where targetIDs.contains(document.annotations[index].id)
                {
                    document.annotations[index].style.lineWidth = state.latestLineWidth
                }
            }
            guard let representativeStyle = session.controller.document.orderedAnnotations
                .first(where: { targetIDs.contains($0.id) })?.style
            else {
                preconditionFailure("A committed selected line-width edit lost its representative item.")
            }
            session.adoptCurrentStyle(representativeStyle, origin: .existingAnnotation)
            result = .selection(
                itemCount: targetIDs.count,
                lineWidth: state.latestLineWidth
            )
            AppLog.capture.notice(
                "Committed annotation line-width edit: target=selection, items=\(targetIDs.count, privacy: .public), logicalPoints=\(state.latestLineWidth, privacy: .public), persistedByOwner=false"
            )
        }
        lineWidthEditingState = nil
        syncCurrentStyleWithEditorState(
            document: session.controller.document,
            selectedItemIDs: session.controller.selectedItemIDs,
            reason: "line-width-commit"
        )
        needsDisplay = true
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        return result
    }

    func cancelLineWidthEditing(reason: String) {
        guard let state = lineWidthEditingState else { return }
        switch state.target {
        case .toolDefault(let tool, let initialStyle):
            precondition(
                tool == session.currentTool,
                "A cancelled tool-default line-width edit must remain owned by its original tool."
            )
            session.setCurrentToolDefaultLineWidth(initialStyle.lineWidth)
        case .selection(let initialItems):
            let selectedIDs = session.controller.selectedItemIDs
            if let representative = session.controller.document.orderedAnnotations.first(where: {
                selectedIDs.contains($0.id) && initialItems[$0.id] != nil
            }) {
                session.adoptCurrentStyle(representative.style, origin: .existingAnnotation)
            } else {
                session.restoreCurrentToolDefaultStyle()
            }
        }
        lineWidthEditingState = nil
        syncCurrentStyleWithEditorState(
            document: session.controller.document,
            selectedItemIDs: session.controller.selectedItemIDs,
            reason: "line-width-cancel"
        )
        needsDisplay = true
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.notice(
            "Cancelled annotation line-width edit: reason=\(reason, privacy: .public), logicalPoints=\(state.latestLineWidth, privacy: .public)"
        )
    }

    func applyShapeFillMode(_ fillMode: ShapeFillMode) {
        let selectedIDs = session.controller.selectedItemIDs
        var representativeStyle: AnnotationStyle?
        session.controller.perform(label: "Change annotation fill mode") { document in
            for index in document.annotations.indices
                where selectedIDs.contains(document.annotations[index].id)
                    && !document.annotations[index].isLocked
                    && [.rectangle, .ellipse].contains(document.annotations[index].kind)
            {
                document.annotations[index].style.shapeFillMode = fillMode
                representativeStyle = representativeStyle ?? document.annotations[index].style
            }
        }
        if let representativeStyle {
            session.adoptCurrentStyle(representativeStyle, origin: .existingAnnotation)
            AppLog.capture.notice(
                "Changed selected annotation fill mode: selected=\(selectedIDs.count, privacy: .public), mode=\(fillMode.rawValue, privacy: .public)"
            )
        } else {
            session.setShapeFillMode(fillMode)
        }
    }

    func applyArrowHeadStyle(_ arrowHeadStyle: ArrowHeadStyle) {
        let selectedIDs = session.controller.selectedItemIDs
        var representativeStyle: AnnotationStyle?
        session.controller.perform(label: "Change arrow style") { document in
            for index in document.annotations.indices
                where selectedIDs.contains(document.annotations[index].id)
                    && !document.annotations[index].isLocked
                    && document.annotations[index].kind == .arrow
            {
                document.annotations[index].style.arrowHeadStyle = arrowHeadStyle
                representativeStyle = representativeStyle ?? document.annotations[index].style
            }
        }
        if let representativeStyle {
            session.adoptCurrentStyle(representativeStyle, origin: .existingAnnotation)
            AppLog.capture.notice(
                "Changed selected arrow style: selected=\(selectedIDs.count, privacy: .public), style=\(arrowHeadStyle.rawValue, privacy: .public)"
            )
        } else {
            session.setArrowHeadStyle(arrowHeadStyle)
        }
    }

    func previewRegionDraftFrame(
        sourceDesktopFrame: CGRect,
        previewDesktopFrame: CGRect,
        change: RegionDraftGeometryChange
    ) {
        let source = sourceDesktopFrame.standardized
        let preview = previewDesktopFrame.standardized
        precondition(
            source.width >= 2 && source.height >= 2
                && preview.width >= 2 && preview.height >= 2,
            "A live region-draft viewport requires non-empty source and preview frames."
        )
        precondition(
            max(
                abs(source.width - session.controller.document.canvasSize.width),
                abs(source.height - session.controller.document.canvasSize.height)
            ) < 0.01,
            "The region-draft source frame must match the current annotation document."
        )
        precondition(
            max(abs(bounds.width - preview.width), abs(bounds.height - preview.height)) < 0.01,
            "The region-draft canvas must be laid out at the preview selection size before drawing."
        )

        let viewport = RegionDraftViewport(
            sourceDesktopFrame: source,
            previewDesktopFrame: preview,
            change: change
        )
        regionDraftViewport = viewport
        didPreviewRegionDraftGeometry = true

        let visible = viewport.visibleDocumentRect
        let scale = CGPoint(
            x: bounds.width / visible.width,
            y: bounds.height / visible.height
        )
        let gridError = max(
            maxFrameDelta(source, source.integral),
            maxFrameDelta(preview, preview.integral)
        )
        let selectedAnchors = selectedDisplayItems().first.map { item -> [CGPoint] in
            let rect = selectionGeometry.transformedBounds(for: item)
            return [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)
            ]
        } ?? [CGPoint(
            x: session.controller.document.canvasSize.width / 2,
            y: session.controller.document.canvasSize.height / 2
        )]
        let maximumAnchorError = selectedAnchors.reduce(CGFloat.zero) { current, documentPoint in
            let viewPoint = viewPoint(fromDocumentPoint: documentPoint)
            let expectedGlobalPoint: CGPoint
            switch change {
            case .resizePreservingDesktopAnchors:
                expectedGlobalPoint = CGPoint(
                    x: source.minX + documentPoint.x,
                    y: source.minY + documentPoint.y
                )
            case .moveCanvas:
                expectedGlobalPoint = CGPoint(
                    x: preview.minX + documentPoint.x,
                    y: preview.minY + documentPoint.y
                )
            }
            let previewGlobalPoint = CGPoint(
                x: preview.minX + viewPoint.x,
                y: preview.minY + viewPoint.y
            )
            return max(
                current,
                max(
                    abs(expectedGlobalPoint.x - previewGlobalPoint.x),
                    abs(expectedGlobalPoint.y - previewGlobalPoint.y)
                )
            )
        }
        lastRegionDraftPreviewScale = scale
        lastRegionDraftPreviewAnchorError = maximumAnchorError
        lastRegionDraftPreviewGridError = gridError
        precondition(
            max(abs(scale.x - 1), abs(scale.y - 1)) < 0.001,
            "Live region resizing must never scale annotation geometry or stroke width."
        )
        precondition(
            maximumAnchorError < 0.01,
            "Live region resizing must preserve every annotation's global desktop position."
        )
        precondition(
            gridError < 0.001,
            "Live region resizing must retain the same whole-point pixel phase through mouse-up."
        )

        if maxFrameDelta(source, preview) < 0.01 {
            regionDraftViewport = nil
        }
        syncPresentationContentCornerRadius(for: preview.size)
        syncSelectedTextChrome()
        needsDisplay = true
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.debug(
            "Region draft live viewport updated: change=\(change.rawValue, privacy: .public), source=\(source.debugDescription, privacy: .public), preview=\(preview.debugDescription, privacy: .public), visibleDocument=\(visible.debugDescription, privacy: .public), scaleX=\(scale.x, privacy: .public), scaleY=\(scale.y, privacy: .public), anchorError=\(maximumAnchorError, privacy: .public), gridError=\(gridError, privacy: .public)"
        )
    }

    func finishRegionDraftFramePreview() {
        guard regionDraftViewport != nil else { return }
        regionDraftViewport = nil
        syncPresentationContentCornerRadius()
        syncSelectedTextChrome()
        needsDisplay = true
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.notice(
            "Region draft live viewport committed without annotation scaling: scaleX=\(self.lastRegionDraftPreviewScale.x, privacy: .public), scaleY=\(self.lastRegionDraftPreviewScale.y, privacy: .public), anchorError=\(self.lastRegionDraftPreviewAnchorError, privacy: .public), gridError=\(self.lastRegionDraftPreviewGridError, privacy: .public)"
        )
    }

    func refreshWindowInteractionState() {
        window?.invalidateCursorRects(for: self)
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
    }

    func setWindowDragInProgress(_ inProgress: Bool) {
        if !inProgress {
            isReadOnlyWindowDragArmed = false
        }
        guard isWindowDragInProgress != inProgress else { return }
        isWindowDragInProgress = inProgress
        windowDragObservationGeneration &+= 1
        window?.invalidateCursorRects(for: self)
        applyCurrentCursor()
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        if inProgress {
            observeWindowDragRelease(generation: windowDragObservationGeneration)
        }
    }

    private func observeWindowDragRelease(generation: UInt) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self,
                  self.isWindowDragInProgress,
                  self.windowDragObservationGeneration == generation
            else { return }
            guard NSEvent.pressedMouseButtons & 1 != 0 else {
                AppLog.capture.debug("Pinned screenshot drag cursor released after pointer-up")
                self.finishWindowDragIfNeeded(reason: "pressed-buttons-released")
                return
            }
            // The active press owns the cursor until release, including the interval
            // before movement crosses the user's drag threshold.
            NSCursor.closedHand.set()
            self.observeWindowDragRelease(generation: generation)
        }
    }

    private func finishWindowDragIfNeeded(reason: String) {
        pendingRegionBodyMoveMouseDown = nil
        regionBodyMoveStartScreenPoint = nil
        if isWindowDragInProgress {
            pendingRegionDoubleClickCopy = false
        }
        guard isWindowDragInProgress else { return }
        AppLog.capture.debug(
            "Pinned canvas body move ending: reason=\(reason, privacy: .public)"
        )
        setWindowDragInProgress(false)
        onWindowDragEnded?(reason)
    }

    private var activeSelectionInteractionCursor: NSCursor? {
        guard let interaction = selectionInteraction else { return nil }
        switch interaction.mode {
        case .stationary:
            return nil
        case .move:
            return .closedHand
        case .resize(_, let handle):
            return cursor(for: handle)
        }
    }

    private var isSelectionMoveCursorOwnerActive: Bool {
        guard let interaction = selectionInteraction else { return false }
        if case .move = interaction.mode { return true }
        return false
    }

    private func beginSelectionMoveCursorOwnership(itemCount: Int) {
        precondition(
            isSelectionMoveCursorOwnerActive,
            "Annotation move cursor ownership requires an active move interaction."
        )
        selectionMoveCursorObservationGeneration &+= 1
        let generation = selectionMoveCursorObservationGeneration
        selectedTextFrameView?.setChromeCursorRectsSuppressed(true)
        window?.invalidateCursorRects(for: self)
        NSCursor.closedHand.set()
        observeSelectionMoveCursorOwnership(generation: generation)
        AppLog.capture.notice(
            "Annotation move cursor acquired: items=\(itemCount, privacy: .public), cursor=closed-hand"
        )
    }

    private func observeSelectionMoveCursorOwnership(generation: UInt) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self,
                  self.isSelectionMoveCursorOwnerActive,
                  self.selectionMoveCursorObservationGeneration == generation
            else { return }
            guard NSEvent.pressedMouseButtons & 1 != 0 else {
                // The normal mouse-up callback or a window/application
                // lifecycle cancellation owns the corresponding teardown.
                return
            }
            NSCursor.closedHand.set()
            self.observeSelectionMoveCursorOwnership(generation: generation)
        }
    }

    @discardableResult
    private func endSelectionInteractionLifecycle(reason: String) -> SelectionInteraction? {
        guard let interaction = selectionInteraction else { return nil }
        selectionInteraction = nil
        if case .move = interaction.mode {
            selectionMoveCursorObservationGeneration &+= 1
            selectedTextFrameView?.setChromeCursorRectsSuppressed(false)
            AppLog.capture.notice(
                "Annotation move cursor released: reason=\(reason, privacy: .public), moved=\(interaction.hasMoved, privacy: .public), cursor=hover"
            )
        }
        return interaction
    }

    @discardableResult
    private func cancelSelectionInteraction(reason: String) -> Bool {
        guard let interaction = endSelectionInteractionLifecycle(reason: reason) else { return false }
        startPoint = nil
        currentPoint = nil
        freehandPoints.removeAll()
        syncSelectedTextChrome()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        applyCurrentCursor()
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.notice(
            "Cancelled annotation interaction: reason=\(reason, privacy: .public), previewMoved=\(interaction.hasMoved, privacy: .public), items=\(interaction.previewItems.count, privacy: .public)"
        )
        return true
    }

    override func layout() {
        super.layout()
        if let interaction = textResizeInteraction,
           maxFrameDelta(bounds, interaction.canvasBounds) >= 0.001
        {
            cancelTextResize(reason: "layout-bounds-changed")
        }
        if let interaction = selectedTextResizeInteraction,
           maxFrameDelta(bounds, interaction.canvasBounds) >= 0.001
        {
            cancelSelectedTextResize(reason: "layout-bounds-changed")
        }
        updateTextEditorFrame()
        syncSelectedTextChrome()
        window?.invalidateCursorRects(for: self)
        activeSelectionInteractionCursor?.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        if supportsDirectInteractiveComposition {
            drawInteractiveDocument()
        } else {
            drawScaledScreenshot(
                previewImage,
                sourcePixelSize: session.previewImage.pixelSize
            )
            drawExcludedAnnotations()
        }
        drawSelection()
        drawProvisional()
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let editor = textEditor, let frameView = textEditorFrameView {
            let fieldFrame = frameView.fieldFrame(in: self)
            if fieldFrame.contains(viewPoint) {
                AppLog.capture.notice(
                    "Routed pointer into the active inline text field instead of stealing first responder: x=\(viewPoint.x, privacy: .public), y=\(viewPoint.y, privacy: .public), characters=\(editor.string.utf16.count, privacy: .public)"
                )
                if window?.firstResponder !== editor {
                    guard window?.makeFirstResponder(editor) == true else {
                        preconditionFailure("Clicking the inline text field must keep the editor as first responder.")
                    }
                }
                editor.mouseDown(with: event)
                return
            }
        }
        if textEditor != nil {
            guard endTextEditingIfNeeded(reason: .focusChange) else {
                AppLog.capture.notice(
                    "Rejected canvas pointer interaction because active text could not commit"
                )
                return
            }
        }
        if isAnnotationEditingEnabled {
            onEditingContextWillChange?("canvas-pointer-down")
            precondition(
                lineWidthEditingState == nil,
                "A canvas interaction cannot begin while a line-width edit still owns its previous target."
            )
        }
        window?.makeFirstResponder(self)
        if armRegionDoubleClickCopyIfNeeded(from: event) {
            return
        }
        guard isAnnotationEditingEnabled else {
            guard !event.modifierFlags.contains(.option) else {
                isReadOnlyWindowDragArmed = false
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            isReadOnlyWindowDragArmed = pinnedWindowResizeHandle(at: point) == nil
            if isReadOnlyWindowDragArmed {
                window?.invalidateCursorRects(for: self)
                NSCursor.closedHand.set()
                onWindowDragBegan?(event)
            }
            return
        }
        let point = documentPoint(fromViewPoint: convert(event.locationInWindow, from: nil))
        AppLog.capture.notice(
            "Pinned canvas interaction began: tool=\(self.session.currentTool.rawValue, privacy: .public), x=\(point.x, privacy: .public), y=\(point.y, privacy: .public)"
        )

        if event.modifierFlags.contains(.option) {
            return
        }

        if beginSelectionInteraction(at: point, event: event) {
            precondition(
                startPoint == nil && currentPoint == nil,
                "Moving or resizing a selection must not arm a new annotation draft."
            )
            needsDisplay = true
            return
        }

        startPoint = point
        currentPoint = point
        switch session.currentTool {
        case .select:
            session.controller.selectedItemIDs.removeAll()
            isReadOnlyWindowDragArmed = true
            window?.invalidateCursorRects(for: self)
            NSCursor.closedHand.set()
            if isRegionConfirmationCanvas {
                pendingRegionBodyMoveMouseDown = event
                regionBodyMoveStartScreenPoint = screenPoint(from: event)
                regionBodyMoveHasDragged = false
                AppLog.capture.debug(
                    "Armed region confirmation body press without moving yet so a physical double-click can complete."
                )
            } else {
                onWindowDragBegan?(event)
            }
        case .text:
            session.controller.selectedItemIDs.removeAll()
        case .counter:
            addCounter(at: point)
        case .freehand:
            freehandPoints = [point]
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if selectionInteraction != nil {
            let point = documentPoint(fromViewPoint: convert(event.locationInWindow, from: nil))
            updateSelectionInteraction(to: point)
            return
        }
        if pendingRegionDoubleClickCopy {
            NSCursor.closedHand.set()
            if beginRegionBodyMoveIfNeeded(with: event) {
                onWindowDragChanged?(event)
            }
            return
        }
        if isWindowDragInProgress || pendingRegionBodyMoveMouseDown != nil {
            NSCursor.closedHand.set()
            if beginRegionBodyMoveIfNeeded(with: event) {
                onWindowDragChanged?(event)
            }
            return
        }
        if event.modifierFlags.contains(.option) {
            onExternalDrag?(event)
            return
        }
        guard isAnnotationEditingEnabled else {
            guard isReadOnlyWindowDragArmed else { return }
            NSCursor.closedHand.set()
            onWindowDragChanged?(event)
            return
        }
        let point = documentPoint(fromViewPoint: convert(event.locationInWindow, from: nil))
        if session.currentTool == .select {
            guard isReadOnlyWindowDragArmed else { return }
            NSCursor.closedHand.set()
            if beginRegionBodyMoveIfNeeded(with: event) {
                onWindowDragChanged?(event)
            }
            return
        }

        currentPoint = point
        if session.currentTool == .freehand {
            if let last = freehandPoints.last, hypot(last.x - point.x, last.y - point.y) >= 1 {
                freehandPoints.append(point)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isAnnotationEditingEnabled else {
            finishWindowDragIfNeeded(reason: "pointer-up-read-only")
            applyCursor(for: convert(event.locationInWindow, from: nil))
            return
        }
        let completesWindowDrag = isWindowDragInProgress
        defer {
            finishWindowDragIfNeeded(reason: "pointer-up-editing")
            startPoint = nil
            currentPoint = nil
            freehandPoints.removeAll()
            _ = endSelectionInteractionLifecycle(reason: "pointer-up")
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            applyCursor(for: convert(event.locationInWindow, from: nil))
            updateAccessibilitySummary(
                document: session.controller.document,
                captured: session.previewImage
            )
        }
        if finishRegionDoubleClickCopyIfNeeded(from: event) {
            pendingRegionBodyMoveMouseDown = nil
            regionBodyMoveStartScreenPoint = nil
            regionBodyMoveHasDragged = false
            return
        }
        if isRegionConfirmationCanvas,
           session.currentTool == .select,
           !regionBodyMoveHasDragged,
           !completesWindowDrag
        {
            let end = documentPoint(fromViewPoint: convert(event.locationInWindow, from: nil))
            if shouldCopyRegionOnDoubleClick(at: end) {
                lastEmptyRegionClick = (
                    timestamp: event.timestamp,
                    screenPoint: screenPoint(from: event)
                )
            } else {
                lastEmptyRegionClick = nil
            }
        } else if regionBodyMoveHasDragged || completesWindowDrag {
            lastEmptyRegionClick = nil
        }
        pendingRegionBodyMoveMouseDown = nil
        regionBodyMoveStartScreenPoint = nil
        regionBodyMoveHasDragged = false
        pendingRegionDoubleClickCopy = false
        guard !completesWindowDrag else { return }
        let end = documentPoint(fromViewPoint: convert(event.locationInWindow, from: nil))

        if selectionInteraction != nil {
            finishSelectionInteraction(at: end)
            return
        }
        if event.modifierFlags.contains(.option) { return }
        if session.currentTool == .select { return }
        if let startPoint,
           resolveRegionCreationToolClick(
               from: startPoint,
               to: end
           )
        {
            return
        }
        if session.currentTool == .text {
            guard let startPoint,
                  !textInteractionExceededDragThreshold(from: startPoint, to: end)
            else { return }
            beginTextEditing(at: startPoint)
            return
        }
        guard let startPoint else { return }
        commit(tool: session.currentTool, start: startPoint, end: end)
    }

    private func resolveRegionCreationToolClick(
        from start: CGPoint,
        to end: CGPoint
    ) -> Bool {
        guard !selectsNewAnnotationsAfterCommit,
              !textInteractionExceededDragThreshold(from: start, to: end)
        else { return false }
        switch session.currentTool {
        case .rectangle, .ellipse, .line, .arrow, .freehand,
             .mosaic, .blur, .highlight, .spotlight:
            break
        case .select, .text, .counter, .crop:
            return false
        }
        if let item = session.controller.topmostItem(at: end) {
            session.controller.selectedItemIDs = [item.id]
            session.adoptCurrentStyle(item.style, origin: .existingAnnotation)
            AppLog.capture.notice(
                "Selected an existing region annotation after a creation-tool click: kind=\(item.kind.rawValue, privacy: .public), tool=\(self.session.currentTool.rawValue, privacy: .public)"
            )
        } else {
            let clearedSelectionCount = session.controller.selectedItemIDs.count
            session.controller.selectedItemIDs.removeAll()
            if clearedSelectionCount > 0 {
                AppLog.capture.notice(
                    "Cleared region annotation selection after an empty creation-tool click: tool=\(self.session.currentTool.rawValue, privacy: .public), clearedSelection=\(clearedSelectionCount, privacy: .public)"
                )
            }
        }
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if textResizeInteraction != nil, newWindow !== window {
            cancelTextResize(reason: "canvas-moving-between-windows")
        }
        if selectedTextResizeInteraction != nil, newWindow !== window {
            cancelSelectedTextResize(reason: "canvas-moving-between-windows")
        }
        if selectionInteraction != nil, newWindow !== window {
            cancelSelectionInteraction(reason: "canvas-moving-between-windows")
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isWindowDragInProgress
            || pendingRegionBodyMoveMouseDown != nil
            || (!isAnnotationEditingEnabled && isReadOnlyWindowDragArmed)
        {
            addCursorRect(bounds, cursor: .closedHand)
            return
        }
        if let activeSelectionInteractionCursor {
            addCursorRect(bounds, cursor: activeSelectionInteractionCursor)
            activeSelectionInteractionCursor.set()
            return
        }
        guard isAnnotationEditingEnabled else {
            addOrdinaryPinnedWindowCursorRects(cursor: .openHand)
            addPinnedWindowResizeCursorRects()
            return
        }
        addOrdinaryPinnedWindowCursorRects(cursor: defaultCursor)
        let selectedItems = selectedDisplayItems()
        for item in selectedItems where item.id != textEditingState?.itemID {
            addCursorRect(
                viewRect(fromDocumentRect: selectionGeometry.transformedBounds(for: item)).insetBy(dx: -4, dy: -4),
                cursor: item.kind.allowsUserTranslation ? .openHand : defaultCursor
            )
            for handlePoint in selectedItems.count == 1 ? selectionGeometry.handlePoints(for: item) : [] {
                let point = viewPoint(fromDocumentPoint: handlePoint.point)
                addCursorRect(
                    CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12),
                    cursor: cursor(for: handlePoint.handle)
                )
            }
        }
        addPinnedWindowResizeCursorRects()
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if !isAnnotationEditingEnabled {
            if command, event.keyCode == 8 {
                onCopyFinalImage?()
                return
            }
            super.keyDown(with: event)
            return
        }
        if command, event.keyCode == 6 {
            shift ? session.controller.redo() : session.controller.undo()
            return
        }
        if command, event.keyCode == 8 {
            copySelectionOrImage()
            return
        }
        if command, event.keyCode == 9 {
            pasteCopiedItems()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            session.controller.deleteSelection()
            return
        }
        if event.keyCode == 53 {
            if startPoint != nil {
                cancelProvisionalDrawing()
            } else if session.currentTool != .select {
                session.currentTool = .select
            } else {
                session.controller.selectedItemIDs.removeAll()
            }
            return
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            let step: CGFloat = shift ? 10 : 1
            let offset: CGSize
            switch event.keyCode {
            case 123: offset = CGSize(width: -step, height: 0)
            case 124: offset = CGSize(width: step, height: 0)
            case 125: offset = CGSize(width: 0, height: -step)
            default: offset = CGSize(width: 0, height: step)
            }
            session.controller.moveSelection(by: offset)
            return
        }
        super.keyDown(with: event)
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === textEditor else { return }
        updateTextEditorLayout(scrollsToInsertionPoint: true)
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === textEditor else { return }
        endTextEditingIfNeeded(reason: .focusChange)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === textEditor else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditingIfNeeded(reason: .escape)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || commandSelector == #selector(NSResponder.insertLineBreak(_:))
        {
            AppLog.capture.notice(
                "Accepted inline text line break command: selector=\(NSStringFromSelector(commandSelector), privacy: .public), characters=\(textView.string.utf16.count, privacy: .public), lines=\(AnnotationTextLayout.lineCount(in: textView.string), privacy: .public)"
            )
            return false
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let event = NSApp.currentEvent, isShiftReturnLineBreakEvent(event) {
                AppLog.capture.notice(
                    "Accepted Shift-Return as an inline text line break: characters=\(textView.string.utf16.count, privacy: .public), lines=\(AnnotationTextLayout.lineCount(in: textView.string), privacy: .public)"
                )
                return false
            }
            endTextEditingIfNeeded(reason: .returnKey)
            return true
        }
        return false
    }

    private func isShiftReturnLineBreakEvent(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.shift)
            && !modifiers.contains(.command)
            && !modifiers.contains(.control)
    }

    private func commit(tool: AnnotationTool, start: CGPoint, end: CGPoint) {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        let style = style(for: tool)
        let zIndex = session.controller.document.annotations.count
        AppLog.capture.notice(
            "Committing pinned annotation: tool=\(tool.rawValue, privacy: .public), start=(\(start.x, privacy: .public),\(start.y, privacy: .public)), end=(\(end.x, privacy: .public),\(end.y, privacy: .public)), width=\(rect.width, privacy: .public), height=\(rect.height, privacy: .public), logicalLineWidth=\(style.lineWidth, privacy: .public), styleOrigin=tool-default, selectedBeforeCommit=\(self.session.controller.selectedItemIDs.count, privacy: .public), shapeFill=\(style.shapeFillMode.rawValue, privacy: .public), arrowStyle=\(style.arrowHeadStyle.rawValue, privacy: .public)"
        )

        switch tool {
        case .rectangle:
            add(kind: .rectangle, geometry: .rect(rect), style: style, minimumRect: rect)
        case .ellipse:
            add(kind: .ellipse, geometry: .rect(rect), style: style, minimumRect: rect)
        case .line:
            add(kind: .line, geometry: .line(start: start, end: end), style: style, minimumRect: rect)
        case .arrow:
            add(kind: .arrow, geometry: .line(start: start, end: end), style: style, minimumRect: rect)
        case .freehand:
            guard freehandPoints.count > 1 else { return }
            addNewAnnotation(AnnotationItem(
                kind: .freehand,
                zIndex: zIndex,
                geometry: .path(freehandPoints),
                style: style
            ))
        case .mosaic:
            add(kind: .mosaic, geometry: .rect(rect), style: style, minimumRect: rect)
        case .blur:
            add(kind: .blur, geometry: .rect(rect), style: style, minimumRect: rect)
        case .highlight:
            add(kind: .highlight, geometry: .rect(rect), style: style, minimumRect: rect)
        case .spotlight:
            add(kind: .spotlight, geometry: .rect(rect), style: style, minimumRect: rect)
        case .crop:
            guard rect.width >= 2, rect.height >= 2 else { return }
            session.controller.perform(label: "Crop") { document in
                document.crop = CropState(rect: rect.intersection(CGRect(origin: .zero, size: document.canvasSize)))
            }
            session.currentTool = .select
        case .select, .text, .counter:
            break
        }

        func add(
            kind: AnnotationKind,
            geometry: AnnotationGeometry,
            style: AnnotationStyle,
            minimumRect: CGRect
        ) {
            guard minimumRect.width >= 2, minimumRect.height >= 2 else { return }
            addNewAnnotation(AnnotationItem(
                kind: kind,
                zIndex: zIndex,
                geometry: geometry,
                style: style
            ))
        }
    }

    private func addNewAnnotation(_ item: AnnotationItem) {
        session.controller.add(
            item,
            selectsAddedItem: selectsNewAnnotationsAfterCommit
        )
        AppLog.capture.notice(
            "Committed new canvas annotation: kind=\(item.kind.rawValue, privacy: .public), selectsAddedItem=\(self.selectsNewAnnotationsAfterCommit, privacy: .public), selectedAfterCommit=\(self.session.controller.selectedItemIDs.count, privacy: .public)"
        )
    }

    private func style(for tool: AnnotationTool) -> AnnotationStyle {
        var style = session.creationStyle(for: tool)
        switch tool {
        case .highlight:
            style = style.asHighlightStyle()
        case .counter:
            style.fillColor = .white
        default:
            break
        }
        return style
    }

    private func addCounter(at point: CGPoint) {
        let diameter: CGFloat = 28
        var style = style(for: .counter)
        style.fontSize = 15
        addNewAnnotation(AnnotationItem(
            kind: .counter,
            zIndex: session.controller.document.annotations.count,
            geometry: .rect(CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)),
            style: style,
            counterValue: session.controller.nextCounterValue()
        ))
    }

    @discardableResult
    func endTextEditingIfNeeded(reason: TextEditingEndReason = .externalAction) -> Bool {
        finishTextEditingIfNeeded(reason: reason, disposition: .commit)
    }

    private func deleteActiveTextEditor() {
        guard let editor = textEditor, let editingState = textEditingState else {
            preconditionFailure("The inline text delete control requires an active editor.")
        }
        if editor.hasMarkedText() {
            guard let inputContext = editor.inputContext else {
                preconditionFailure("Deleting marked inline text requires an NSInputContext.")
            }
            inputContext.discardMarkedText()
            updateTextEditorLayout(scrollsToInsertionPoint: true)
        }
        AppLog.capture.notice(
            "Requested inline text deletion: mode=\(editingState.itemID == nil ? "new" : "existing", privacy: .public), id=\(editingState.itemID?.uuidString ?? "none", privacy: .public)"
        )
        _ = finishTextEditingIfNeeded(reason: .deleteButton, disposition: .delete)
    }

    @discardableResult
    private func finishTextEditingIfNeeded(
        reason: TextEditingEndReason,
        disposition: TextEditingDisposition
    ) -> Bool {
        guard let editor = textEditor, let editingState = textEditingState else { return false }
        guard let frameView = textEditorFrameView, textEditorContainer != nil else {
            preconditionFailure("The inline annotation editor lost its viewport hierarchy before commit.")
        }
        let text = editor.string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let containsVisibleText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if disposition == .commit, containsVisibleText {
            // Focus changes can finalize IME marked text immediately before
            // NSTextView sends textDidEndEditing. Reconcile that final glyph
            // run against the canonical document baseline before measuring or
            // removing the editor, even if no later textDidChange arrives.
            guard updateTextEditorLayout(scrollsToInsertionPoint: false) else {
                window?.makeFirstResponder(editor)
                return false
            }
            restoreTextEditorCanonicalHorizontalOriginForCommit()
        }
        let editedItemID = editingState.itemID
        guard let fieldWrapWidthInDocument = textEditorCanonicalWrapWidthInDocument else {
            preconditionFailure(
                "Inline text commit requires an explicit canonical wrap-width owner."
            )
        }
        let commitLayout: AnnotationTextLayoutResolution?
        let isExistingLayoutNoOp: Bool
        let preservesExistingLayoutPayload: Bool
        do {
        if disposition == .delete {
            commitLayout = nil
            isExistingLayoutNoOp = false
            preservesExistingLayoutPayload = false
        } else if containsVisibleText, let originalItem = editingState.originalItem {
            guard case .rect(let originalRect) = originalItem.geometry else {
                preconditionFailure("An existing inline text editor lost its original text rectangle.")
            }
            let originalAnchor = AnnotationTextLayout.alignmentAnchor(
                in: originalRect,
                text: originalItem.text ?? "",
                style: originalItem.style,
                layout: originalItem.textLayout
            )
            let typographyUnchanged = originalItem.style.fontSize == editingState.style.fontSize
                && originalItem.style.fontName == editingState.style.fontName
                && originalItem.style.fontWeight == editingState.style.fontWeight
                && originalItem.style.textAlignment == editingState.style.textAlignment
            let originalCanonicalWrapWidth = AnnotationTextLayout.canonicalWrapWidth(
                for: originalItem
            )
            preservesExistingLayoutPayload = originalItem.text == text
                && typographyUnchanged
                && !textEditorCanonicalWrapWidthWasExplicitlyResized
                && abs(fieldWrapWidthInDocument - originalCanonicalWrapWidth) < 0.001
                && textEditorLayoutPayload == originalItem.textLayout
                && hypot(
                    originalAnchor.x - editingState.anchor.x,
                    originalAnchor.y - editingState.anchor.y
                ) < 0.000_001
            isExistingLayoutNoOp = preservesExistingLayoutPayload
                && originalItem.style == editingState.style
            if preservesExistingLayoutPayload {
                // A schema-1 no-op must persist `nil`, but the transient
                // commit measurement still needs a complete current plan.
                let payload: AnnotationTextLayoutPayload
                if let existingPayload = originalItem.textLayout {
                    payload = existingPayload
                } else {
                    payload = try AnnotationTextLayout.safeLayoutPayload(
                        for: text,
                        style: editingState.style,
                        proposedWrapWidth: originalCanonicalWrapWidth,
                        chromeMode: .legacyTight,
                        resolvedFont: try textEditorFont(for: editingState)
                    )
                }
                commitLayout = AnnotationTextLayoutResolution(
                    rect: originalRect,
                    payload: payload
                )
            } else {
                let canonicalWrapWidth = fieldWrapWidthInDocument
                let payload = try AnnotationTextLayout.safeLayoutPayload(
                    for: text,
                    style: editingState.style,
                    proposedWrapWidth: canonicalWrapWidth,
                    chromeMode: originalItem.textLayout?.chromeMode ?? .legacyTight,
                    resolvedFont: try textEditorFont(for: editingState)
                )
                guard textEditorLayoutPayload == payload else {
                    throw inlineTextKitEditingCapabilityError(
                        "inline commit did not match the active renderer-ready layout generation"
                    )
                }
                commitLayout = AnnotationTextLayoutResolution(
                    rect: AnnotationTextLayout.annotationRect(
                        baselineAnchor: editingState.anchor,
                        text: text,
                        style: editingState.style,
                        layout: payload
                    ),
                    payload: payload
                )
            }
        } else if containsVisibleText {
            isExistingLayoutNoOp = false
            preservesExistingLayoutPayload = false
            let payload = try AnnotationTextLayout.safeLayoutPayload(
                for: text,
                style: editingState.style,
                proposedWrapWidth: fieldWrapWidthInDocument,
                chromeMode: .uniformPadded,
                resolvedFont: try textEditorFont(for: editingState)
            )
            guard textEditorLayoutPayload == payload else {
                throw inlineTextKitEditingCapabilityError(
                    "new inline commit did not match the active renderer-ready layout generation"
                )
            }
            commitLayout = AnnotationTextLayoutResolution(
                rect: AnnotationTextLayout.annotationRect(
                    baselineAnchor: editingState.anchor,
                    text: text,
                    style: editingState.style,
                    layout: payload
                ),
                payload: payload
            )
        } else {
            isExistingLayoutNoOp = false
            preservesExistingLayoutPayload = false
            commitLayout = nil
        }
        } catch {
            reportTextLayoutAuthoringFailure(
                error,
                operation: "inline-text-commit",
                itemID: editedItemID
            )
            return false
        }
        if disposition == .commit {
            clearTextLayoutAuthoringFailure()
        }
        var committedStyleForSession: AnnotationStyle?
        defer {
            session.finalizeTextEditingStyle(committedStyle: committedStyleForSession)
        }
        cancelTextResize(reason: "editor-ending-\(reason.rawValue)")
        if disposition == .commit,
           containsVisibleText,
           let editorLineOrigin = textEditorLineOriginInView(editor)
        {
            let committedLineOrigin = renderedTextLineOriginInView(
                state: editingState,
                text: text,
                layout: preservesExistingLayoutPayload
                    ? editingState.originalItem?.textLayout
                    : commitLayout?.payload
            )
            let transitionError = CGPoint(
                x: committedLineOrigin.x - editorLineOrigin.x,
                y: committedLineOrigin.y - editorLineOrigin.y
            )
            lastTextCommitBaselineError = transitionError
            if max(abs(transitionError.x), abs(transitionError.y)) > 0.01 {
                AppLog.capture.error(
                    "Inline text commit would move the rendered line: dx=\(transitionError.x, privacy: .public), dy=\(transitionError.y, privacy: .public), reason=\(reason.rawValue, privacy: .public), font=\(editingState.style.fontName ?? "system", privacy: .public), characters=\(text.utf16.count, privacy: .public)"
                )
            } else {
                AppLog.capture.debug(
                    "Verified inline text commit baseline: dx=\(transitionError.x, privacy: .public), dy=\(transitionError.y, privacy: .public), reason=\(reason.rawValue, privacy: .public)"
                )
            }
        } else {
            lastTextCommitBaselineError = nil
        }

        dismantleInlineTextEditor(editor: editor, frameView: frameView)

        let outcome: String
        if disposition == .delete {
            if let editedItemID {
                if session.controller.document.annotations.contains(where: { $0.id == editedItemID }) {
                    session.controller.perform(label: "Delete text") { document in
                        document.annotations.removeAll { $0.id == editedItemID && !$0.isLocked }
                    }
                    session.controller.selectedItemIDs.remove(editedItemID)
                    outcome = "deleted"
                } else {
                    AppLog.capture.error(
                        "Inline text deletion found no matching annotation: id=\(editedItemID.uuidString, privacy: .public)"
                    )
                    outcome = "missing"
                }
            } else {
                outcome = "discarded"
            }
        } else if containsVisibleText {
            guard let commitLayout else {
                preconditionFailure("Visible inline text must resolve committed layout state.")
            }
            let rect = commitLayout.rect
            AppLog.capture.debug(
                "Resolved inline text commit geometry: baseline=(\(editingState.anchor.x, privacy: .public),\(editingState.anchor.y, privacy: .public)), rect=(\(rect.minX, privacy: .public),\(rect.minY, privacy: .public),\(rect.width, privacy: .public),\(rect.height, privacy: .public)), layoutVersion=\(commitLayout.payload.version, privacy: .public), chrome=\(commitLayout.payload.chromeMode.rawValue, privacy: .public), wrapWidth=\(commitLayout.payload.wrapWidth, privacy: .public), font=\(editingState.style.fontName ?? "system", privacy: .public)"
            )
            if let editedItemID {
                guard session.controller.document.annotations.contains(where: { $0.id == editedItemID }) else {
                    refreshPreviewExclusions()
                    AppLog.capture.error(
                        "Inline text commit failed because the edited annotation disappeared: id=\(editedItemID.uuidString, privacy: .public), reason=\(reason.rawValue, privacy: .public)"
                    )
                    updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
                    return true
                }
                if !isExistingLayoutNoOp {
                    session.controller.updateItem(id: editedItemID) { item in
                        item.text = text
                        item.geometry = .rect(rect)
                        item.style = editingState.style
                        item.textLayout = preservesExistingLayoutPayload
                            ? editingState.originalItem?.textLayout
                            : commitLayout.payload
                    }
                } else {
                    AppLog.capture.debug(
                        "Preserved byte-equivalent legacy/current text item after no-op re-edit: id=\(editedItemID.uuidString, privacy: .public)"
                    )
                }
                session.controller.selectedItemIDs = [editedItemID]
                committedStyleForSession = editingState.style
            } else {
                let item = AnnotationItem(
                    kind: .text,
                    zIndex: session.controller.document.annotations.count,
                    geometry: .rect(rect),
                    style: editingState.style,
                    text: text,
                    textLayout: commitLayout.payload
                )
                addNewAnnotation(item)
                committedStyleForSession = editingState.style
            }
            outcome = "committed"
        } else if let editedItemID {
            session.controller.perform(label: "Delete text") { document in
                document.annotations.removeAll { $0.id == editedItemID && !$0.isLocked }
            }
            session.controller.selectedItemIDs.remove(editedItemID)
            outcome = "deleted"
        } else {
            outcome = "discarded"
        }

        refreshPreviewExclusions()
        syncSelectedTextChrome()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
        AppLog.capture.notice(
            "Ended inline text editing: mode=\(editedItemID == nil ? "new" : "existing", privacy: .public), id=\(editedItemID?.uuidString ?? "none", privacy: .public), reason=\(reason.rawValue, privacy: .public), outcome=\(outcome, privacy: .public), characters=\(text.count, privacy: .public)"
        )
        return true
    }

    private func dismantleInlineTextEditor(
        editor: InlineAnnotationTextView,
        frameView: InlineAnnotationTextEditorFrameView
    ) {
        textEditor = nil
        textEditorContainer = nil
        textEditorDocumentView = nil
        textEditorFrameView = nil
        textEditorPreferredViewportWidthInDocument = nil
        textEditorCanonicalWrapWidthInDocument = nil
        textEditorLayoutPayload = nil
        textEditorCanonicalWrapWidthWasExplicitlyResized = false
        textEditorFieldPlacementAnchorInDocument = nil
        textEditorLayoutBounds = nil
        textEditorDocumentScaleInView = nil
        textEditorSessionFont = nil
        textEditorSessionFontRequest = nil
        textEditorRendererGeneration = nil
        textEditorCanonicalLineAdvance = nil
        textEditorSessionBaselineOffset = nil
        textEditorPresentationLayout = nil
        textEditorGeometryConfigurationCount = 0
        textEditorPostConfigurationViewportMutationCount = 0
        textEditorPostConfigurationLineOriginDriftCount = 0
        textEditorPreventedFrameMutationCount = 0
        textEditorBaselineCorrectionCount = 0
        textEditorBaselineError = nil
        textEditingState = nil
        textResizeInteraction = nil
        textResizeFixedCornerError = 0
        editor.delegate = nil
        editor.onMarkedTextChange = nil
        editor.onEscape = nil
        editor.onShiftReturnLineBreak = nil
        editor.onRejectedPresentationFrameChange = nil
        frameView.onResizeBegan = nil
        frameView.onResizeChanged = nil
        frameView.onResizeEnded = nil
        frameView.onDelete = nil
        if window?.firstResponder === editor {
            window?.makeFirstResponder(self)
        }
        frameView.removeFromSuperview()
    }

    private func syncSelectedTextChrome(
        document: AnnotationDocument? = nil,
        selectedItemIDs: Set<UUID>? = nil
    ) {
        let sourceDocument = document ?? session.controller.document
        let effectiveSelectedItemIDs = selectedItemIDs ?? session.controller.selectedItemIDs
        let selectedItems = sourceDocument.orderedAnnotations.compactMap { item -> AnnotationItem? in
            guard effectiveSelectedItemIDs.contains(item.id), !item.isLocked else { return nil }
            return displayItem(for: item)
        }
        guard textEditor == nil,
              textEditingState == nil,
              isAnnotationEditingEnabled,
              selectedItems.count == 1,
              let item = selectedItems.first,
              item.kind == .text,
              item.isVisible,
              case .rect = item.geometry
        else {
            removeSelectedTextChrome(reason: "selection-inactive")
            return
        }

        let frameView: InlineAnnotationTextEditorFrameView
        if let existing = selectedTextFrameView {
            frameView = existing
        } else {
            let created = InlineAnnotationTextEditorFrameView(frame: .zero)
            created.installChromeControls()
            created.setAccessibilityElement(true)
            created.setAccessibilityRole(.group)
            created.setAccessibilityIdentifier("pinned.text.frame")
            created.setAccessibilityLabel(
                NSLocalizedString("Selected annotation text", comment: "Selected text annotation frame")
            )
            created.onResizeBegan = { [weak self] handle, event in
                self?.beginSelectedTextResize(handle: handle, event: event)
            }
            created.onResizeChanged = { [weak self] handle, event in
                self?.updateSelectedTextResize(handle: handle, event: event)
            }
            created.onResizeEnded = { [weak self] handle, event in
                self?.endSelectedTextResize(handle: handle, event: event)
            }
            created.onDelete = { [weak self] in
                self?.deleteSelectedText()
            }
            selectedTextFrameView = created
            addSubview(created)
            AppLog.capture.debug(
                "Installed selected-text chrome: id=\(item.id.uuidString, privacy: .public)"
            )
            frameView = created
        }

        let fieldFrame = viewRect(
            fromDocumentRect: selectionGeometry.transformedBounds(for: item)
        ).standardized
        precondition(
            fieldFrame.width.isFinite && fieldFrame.height.isFinite
                && fieldFrame.width > 0 && fieldFrame.height > 0,
            "Selected text chrome requires finite, non-empty display geometry."
        )
        let chromeOutset = InlineAnnotationTextEditorFrameView.chromeOutset
        frameView.frame = fieldFrame.insetBy(dx: -chromeOutset, dy: -chromeOutset)
        frameView.setFieldFrame(CGRect(
            x: chromeOutset,
            y: chromeOutset,
            width: fieldFrame.width,
            height: fieldFrame.height
        ))
        frameView.setFontSizeAccessibilityValue(item.style.fontSize)
        frameView.setChromeCursorRectsSuppressed(isSelectionMoveCursorOwnerActive)
        frameView.setAccessibilityValue(String(
            format: "mode=selected;fontSize=%.2f;resizeHandles=3;deleteControls=1",
            item.style.fontSize
        ))
    }

    private func removeSelectedTextChrome(reason: String) {
        guard let frameView = selectedTextFrameView else { return }
        frameView.cancelActiveResize()
        frameView.onResizeBegan = nil
        frameView.onResizeChanged = nil
        frameView.onResizeEnded = nil
        frameView.onDelete = nil
        frameView.removeFromSuperview()
        selectedTextFrameView = nil
        if selectedTextResizeInteraction != nil {
            selectedTextResizeInteraction = nil
            AppLog.capture.notice(
                "Cancelled selected-text resize because its chrome was removed: reason=\(reason, privacy: .public)"
            )
        }
    }

    private func beginSelectedTextResize(
        handle: InlineAnnotationTextResizeHandle,
        event: NSEvent
    ) {
        let selectedItems = selectedDocumentItems()
        if selectedTextResizeInteraction != nil {
            cancelSelectedTextResize(reason: "superseded-by-new-drag")
        }
        guard let frameView = selectedTextFrameView,
              selectedItems.count == 1,
              let item = selectedItems.first,
              item.kind == .text
        else {
            preconditionFailure("Selected text resizing requires one stable selected text annotation.")
        }
        let fieldFrame = frameView.fieldFrame(in: self)
        let activeCorner = textFramePoint(handle: handle, in: fieldFrame)
        let fixedCorner = textFramePoint(corner: handle.fixedCorner, in: fieldFrame)
        let initialPointer = convert(event.locationInWindow, from: nil)
        precondition(
            hypot(activeCorner.x - fixedCorner.x, activeCorner.y - fixedCorner.y) > 1,
            "Selected text resizing requires a non-empty starting frame."
        )
        selectedTextResizeInteraction = SelectedTextResizeInteraction(
            handle: handle,
            itemID: item.id,
            initialItem: item,
            previewItem: item,
            initialFontSize: item.style.fontSize,
            initialActiveCornerInView: activeCorner,
            initialPointerInView: initialPointer,
            fixedCornerInView: fixedCorner,
            canvasBounds: bounds,
            startedAt: event.timestamp
        )
        textResizeFixedCornerError = 0
        frameView.setActiveResizeHandle(handle)
        AppLog.capture.notice(
            "Started selected-text font resize: id=\(item.id.uuidString, privacy: .public), handle=\(handle.rawValue, privacy: .public), initialFontSize=\(item.style.fontSize, privacy: .public)"
        )
    }

    @discardableResult
    private func updateSelectedTextResize(
        handle: InlineAnnotationTextResizeHandle,
        event: NSEvent
    ) -> Bool {
        guard var interaction = selectedTextResizeInteraction else {
            AppLog.capture.debug(
                "Ignored stale selected-text resize update: handle=\(handle.rawValue, privacy: .public)"
            )
            return false
        }
        guard interaction.handle == handle else {
            AppLog.capture.debug(
                "Ignored selected-text resize update from a superseded handle: active=\(interaction.handle.rawValue, privacy: .public), received=\(handle.rawValue, privacy: .public)"
            )
            return false
        }
        guard let frameView = selectedTextFrameView else {
            preconditionFailure("Selected text resize lost its chrome during an active interaction.")
        }
        guard maxFrameDelta(bounds, interaction.canvasBounds) < 0.001 else {
            cancelSelectedTextResize(reason: "canvas-geometry-changed")
            return false
        }
        let currentPointer = convert(event.locationInWindow, from: nil)
        let pointerDelta = CGPoint(
            x: currentPointer.x - interaction.initialPointerInView.x,
            y: currentPointer.y - interaction.initialPointerInView.y
        )
        if abs(pointerDelta.x) < 0.001,
           abs(pointerDelta.y) < 0.001,
           interaction.previewItem == interaction.initialItem
        {
            return true
        }
        let initialVector = CGPoint(
            x: interaction.initialActiveCornerInView.x - interaction.fixedCornerInView.x,
            y: interaction.initialActiveCornerInView.y - interaction.fixedCornerInView.y
        )
        let projectedVector = CGPoint(
            x: initialVector.x + pointerDelta.x,
            y: initialVector.y + pointerDelta.y
        )
        let denominator = initialVector.x * initialVector.x + initialVector.y * initialVector.y
        precondition(denominator > 1, "Selected text resize projection requires a non-empty diagonal.")
        let projectedScale = (
            projectedVector.x * initialVector.x + projectedVector.y * initialVector.y
        ) / denominator
        precondition(projectedScale.isFinite, "Selected text resizing produced a non-finite scale.")

        let editableRange = AnnotationTextLayout.editableFontSizeRange
        let minimumFontSize = min(editableRange.lowerBound, interaction.initialFontSize)
        let maximumFontSize = max(editableRange.upperBound, interaction.initialFontSize)
        let fontSize = min(
            maximumFontSize,
            max(minimumFontSize, interaction.initialFontSize * projectedScale)
        )
        do {
            interaction.previewItem = try resizedSelectedTextItem(
                interaction.initialItem,
                fontSize: fontSize,
                fixedCorner: handle.fixedCorner
            )
            clearTextLayoutAuthoringFailure()
        } catch {
            reportTextLayoutAuthoringFailure(
                error,
                operation: "update-selected-text-resize",
                itemID: interaction.itemID
            )
            cancelSelectedTextResize(reason: "layout-capability-failed")
            return false
        }
        selectedTextResizeInteraction = interaction
        syncSelectedTextChrome()
        let resolvedFixedCorner = frameView.fieldPoint(corner: handle.fixedCorner, in: self)
        textResizeFixedCornerError = hypot(
            resolvedFixedCorner.x - interaction.fixedCornerInView.x,
            resolvedFixedCorner.y - interaction.fixedCornerInView.y
        )
        precondition(
            textResizeFixedCornerError < 0.51,
            "Selected text resizing moved its fixed corner by \(textResizeFixedCornerError) points."
        )
        needsDisplay = true
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
        AppLog.capture.debug(
            "Updated selected-text font resize: id=\(interaction.itemID.uuidString, privacy: .public), handle=\(handle.rawValue, privacy: .public), fontSize=\(fontSize, privacy: .public), fixedCornerError=\(self.textResizeFixedCornerError, privacy: .public)"
        )
        return true
    }

    private func endSelectedTextResize(
        handle: InlineAnnotationTextResizeHandle,
        event: NSEvent
    ) {
        guard updateSelectedTextResize(handle: handle, event: event) else { return }
        guard let interaction = selectedTextResizeInteraction,
              let frameView = selectedTextFrameView
        else {
            preconditionFailure("Selected text resize ended without an active interaction.")
        }
        selectedTextResizeInteraction = nil
        frameView.cancelActiveResize()

        let currentItem = session.controller.document.annotations.first {
            $0.id == interaction.itemID
        }
        guard currentItem == interaction.initialItem else {
            AppLog.capture.error(
                "Selected text changed during font resize; the stale preview was not committed: id=\(interaction.itemID.uuidString, privacy: .public)"
            )
            syncSelectedTextChrome()
            needsDisplay = true
            return
        }
        if interaction.previewItem != interaction.initialItem {
            session.controller.perform(label: "Resize text") { document in
                guard let index = document.annotations.firstIndex(where: {
                    $0.id == interaction.itemID
                }), !document.annotations[index].isLocked else { return }
                document.annotations[index] = interaction.previewItem
            }
            session.adoptCurrentStyle(
                interaction.previewItem.style,
                origin: .existingAnnotation
            )
        } else {
            syncSelectedTextChrome()
        }
        needsDisplay = true
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
        AppLog.capture.notice(
            "Ended selected-text font resize: id=\(interaction.itemID.uuidString, privacy: .public), handle=\(handle.rawValue, privacy: .public), initialFontSize=\(interaction.initialFontSize, privacy: .public), finalFontSize=\(interaction.previewItem.style.fontSize, privacy: .public), fixedCornerError=\(self.textResizeFixedCornerError, privacy: .public), committed=\(interaction.previewItem != interaction.initialItem, privacy: .public), durationMilliseconds=\(max(0, event.timestamp - interaction.startedAt) * 1_000, privacy: .public)"
        )
    }

    @discardableResult
    private func cancelSelectedTextResize(reason: String) -> Bool {
        guard let interaction = selectedTextResizeInteraction else { return false }
        selectedTextResizeInteraction = nil
        selectedTextFrameView?.cancelActiveResize()
        textResizeFixedCornerError = 0
        syncSelectedTextChrome()
        needsDisplay = true
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.notice(
            "Cancelled selected-text font resize: reason=\(reason, privacy: .public), id=\(interaction.itemID.uuidString, privacy: .public), handle=\(interaction.handle.rawValue, privacy: .public), discardedPreview=\(interaction.previewItem != interaction.initialItem, privacy: .public)"
        )
        return true
    }

    private func resizedSelectedTextItem(
        _ item: AnnotationItem,
        fontSize: CGFloat,
        fixedCorner: InlineAnnotationTextFrameCorner
    ) throws -> AnnotationItem {
        guard item.kind == .text,
              case .rect = item.geometry,
              let text = item.text
        else {
            preconditionFailure("Font-size resizing requires a text annotation with rectangle geometry.")
        }
        let initialBounds = selectionGeometry.transformedBounds(for: item)
        let fixedPoint = textFramePoint(corner: fixedCorner, in: initialBounds)
        var resized = try AnnotationTextLayout.reflowedTextItem(
            item,
            text: text,
            fontSize: fontSize,
            wrapWidthStrategy: .scaleWithFont
        )
        let resizedBounds = selectionGeometry.transformedBounds(for: resized)
        let resizedFixedPoint = textFramePoint(corner: fixedCorner, in: resizedBounds)
        resized.transform.translation.width += fixedPoint.x - resizedFixedPoint.x
        resized.transform.translation.height += fixedPoint.y - resizedFixedPoint.y
        return resized
    }

    private func deleteSelectedText() {
        let selectedItems = selectedDocumentItems()
        guard textEditor == nil,
              selectedItems.count == 1,
              let item = selectedItems.first,
              item.kind == .text
        else {
            preconditionFailure("The selected-text delete control requires one selected text annotation.")
        }
        AppLog.capture.notice(
            "Requested selected-text deletion: id=\(item.id.uuidString, privacy: .public)"
        )
        session.controller.perform(label: "Delete text") { document in
            document.annotations.removeAll { $0.id == item.id && !$0.isLocked }
        }
        session.controller.selectedItemIDs.remove(item.id)
    }

    private func beginSelectionInteraction(at point: CGPoint, event: NSEvent) -> Bool {
        let selectedItems = selectedDocumentItems()
        if selectedItems.count == 1,
           let item = selectedItems.first,
           item.kind.allowsUserResize,
           let handle = selectionHandle(at: point, for: item)
        {
            selectionInteraction = SelectionInteraction(
                mode: .resize(itemID: item.id, handle: handle),
                startPoint: point,
                initialItems: [item.id: item],
                editsTextOnClick: nil,
                previewItems: [item.id: item]
            )
            AppLog.capture.debug(
                "Started annotation resize interaction: id=\(item.id.uuidString, privacy: .public), handle=\(handle.rawValue, privacy: .public)"
            )
            cursor(for: handle).set()
            return true
        }

        let selectedIDs = session.controller.selectedItemIDs
        let selectedHit = session.controller.document.orderedAnnotations.reversed().first {
            selectedIDs.contains($0.id) && !$0.isLocked && hitTester.contains(point, in: $0, tolerance: 6)
        }
        let hitItem: AnnotationItem?
        if let selectedHit {
            hitItem = selectedHit
        } else {
            switch session.currentTool {
            case .select:
                hitItem = session.controller.topmostItem(at: point)
            case .text:
                hitItem = topmostEditableText(at: point)
            default:
                hitItem = nil
            }
        }
        guard let hitItem else { return false }

        if session.currentTool == .select, event.modifierFlags.contains(.shift) {
            session.controller.selectedItemIDs.insert(hitItem.id)
        } else {
            session.controller.selectedItemIDs = [hitItem.id]
        }
        session.adoptCurrentStyle(hitItem.style, origin: .existingAnnotation)
        guard hitItem.kind.allowsUserTranslation else {
            selectionInteraction = SelectionInteraction(
                mode: .stationary,
                startPoint: point,
                initialItems: [hitItem.id: hitItem],
                editsTextOnClick: nil,
                previewItems: [hitItem.id: hitItem]
            )
            AppLog.capture.debug(
                "Selected source-anchored annotation without starting a move: id=\(hitItem.id.uuidString, privacy: .public), kind=\(hitItem.kind.rawValue, privacy: .public)"
            )
            return true
        }
        let interactionItems = selectedDocumentItems().filter(\.kind.allowsUserTranslation)
        guard !interactionItems.isEmpty else {
            AppLog.capture.error(
                "Annotation interaction could not start because its selection resolved to no editable items."
            )
            return true
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: interactionItems.map { ($0.id, $0) })
        let editsText = hitItem.kind == .text
            && (session.currentTool == .text || event.clickCount >= 2)
        selectionInteraction = SelectionInteraction(
            mode: .move,
            startPoint: point,
            initialItems: itemsByID,
            editsTextOnClick: editsText ? hitItem.id : nil,
            previewItems: itemsByID
        )
        beginSelectionMoveCursorOwnership(itemCount: itemsByID.count)
        AppLog.capture.notice(
            "Started annotation move interaction: selected=\(itemsByID.count, privacy: .public), textEditOnClick=\(editsText, privacy: .public), cursorOwner=closed-hand"
        )
        return true
    }

    private func updateSelectionInteraction(to point: CGPoint) {
        guard var interaction = selectionInteraction else { return }
        if case .stationary = interaction.mode {
            return
        }
        if !interaction.hasMoved {
            switch interaction.mode {
            case .stationary:
                preconditionFailure("A stationary annotation interaction cannot begin moving.")
            case .move:
                interaction.hasMoved = textInteractionExceededDragThreshold(
                    from: interaction.startPoint,
                    to: point
                )
            case .resize:
                interaction.hasMoved = selectionResizeHasPointerMovement(
                    from: interaction.startPoint,
                    to: point
                )
            }
            guard interaction.hasMoved else {
                selectionInteraction = interaction
                activeSelectionInteractionCursor?.set()
                return
            }
        }

        switch interaction.mode {
        case .stationary:
            preconditionFailure("A stationary annotation interaction cannot produce a move preview.")
        case .move:
            let offset = CGSize(
                width: point.x - interaction.startPoint.x,
                height: point.y - interaction.startPoint.y
            )
            interaction.previewItems = interaction.initialItems.mapValues {
                selectionGeometry.moved($0, by: offset)
            }
        case .resize(let itemID, let handle):
            guard let initial = interaction.initialItems[itemID] else {
                preconditionFailure("The resized annotation must exist in the interaction snapshot.")
            }
            interaction.previewItems = [
                itemID: selectionGeometry.resized(
                    initial,
                    using: handle,
                    to: point,
                    minimumDimension: minimumInteractiveDocumentDimension
                )
            ]
            cursor(for: handle).set()
        }
        selectionInteraction = interaction
        syncSelectedTextChrome()
        needsDisplay = true
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
        activeSelectionInteractionCursor?.set()
    }

    private func finishSelectionInteraction(at point: CGPoint) {
        updateSelectionInteraction(to: point)
        guard let interaction = selectionInteraction else { return }
        if case .stationary = interaction.mode { return }
        guard interaction.hasMoved else {
            if let itemID = interaction.editsTextOnClick {
                guard let item = session.controller.document.annotations.first(where: { $0.id == itemID }) else {
                    AppLog.capture.error(
                        "Inline text edit could not start because the selected annotation disappeared: id=\(itemID.uuidString, privacy: .public)"
                    )
                    return
                }
                beginTextEditing(item: item)
            }
            return
        }

        let previewItems = interaction.previewItems
        let currentItems = Dictionary(uniqueKeysWithValues: session.controller.document.annotations.map { ($0.id, $0) })
        guard previewItems.keys.allSatisfy({ currentItems[$0] != nil }) else {
            AppLog.capture.error("Annotation interaction commit failed because an edited item disappeared.")
            return
        }
        let label: String
        switch interaction.mode {
        case .stationary:
            preconditionFailure("A stationary annotation interaction cannot be committed.")
        case .move: label = "Move annotation"
        case .resize: label = "Resize annotation"
        }
        session.controller.perform(label: label) { document in
            for index in document.annotations.indices {
                let id = document.annotations[index].id
                guard let replacement = previewItems[id], !document.annotations[index].isLocked else { continue }
                document.annotations[index] = replacement
            }
        }
        let maximumScaleAnisotropy = previewItems.values.reduce(CGFloat(1)) { result, item in
            let smallerScale = max(0.0001, min(abs(item.transform.scaleX), abs(item.transform.scaleY)))
            let largerScale = max(abs(item.transform.scaleX), abs(item.transform.scaleY))
            return max(result, largerScale / smallerScale)
        }
        let lineWidths = previewItems.values.map(\.style.lineWidth)
        AppLog.capture.notice(
            "Committed live annotation interaction: operation=\(label, privacy: .public), items=\(previewItems.count, privacy: .public), maximumScaleAnisotropy=\(maximumScaleAnisotropy, privacy: .public), minimumLineWidth=\(lineWidths.min() ?? 0, privacy: .public), maximumLineWidth=\(lineWidths.max() ?? 0, privacy: .public)"
        )
    }

    private func beginTextEditing(at point: CGPoint) {
        let style = session.defaultStyle(for: .text)
        let admittedFont: NSFont
        do {
            admittedFont = try AnnotationTextLayout.resolvedFont(style: style)
            _ = try AnnotationTextLayout.safeLayoutPayload(
                for: "",
                style: style,
                proposedWrapWidth: 1,
                chromeMode: .uniformPadded,
                resolvedFont: admittedFont
            )
            clearTextLayoutAuthoringFailure()
        } catch {
            NSSound.beep()
            reportVectorRenderFailure(
                error,
                item: AnnotationItem(
                    kind: .text,
                    zIndex: session.controller.document.annotations.count,
                    geometry: .rect(CGRect(origin: point, size: CGSize(width: 1, height: 1))),
                    style: style,
                    text: ""
                ),
                isProvisional: true,
                operation: "new-inline-text-admission"
            )
            return
        }
        session.adoptCurrentStyle(style, origin: .newTextDraft)
        installTextEditor(
            text: "",
            state: TextEditingState(
                itemID: nil,
                anchor: point,
                style: style,
                transform: AnnotationTransform()
            ),
            admittedFont: admittedFont
        )
    }

    private func beginTextEditing(item: AnnotationItem) {
        guard item.kind == .text, case .rect(let rect) = item.geometry else {
            preconditionFailure("Inline text editing requires a text annotation with rectangle geometry.")
        }
        let admittedFont: NSFont
        do {
            try AnnotationTextLayout.validateEditingCapability(
                text: item.text ?? "",
                style: item.style,
                rect: rect,
                layout: item.textLayout
            )
            admittedFont = try validateInlineTextKitEditingCapability(item: item)
            clearTextLayoutAuthoringFailure()
        } catch {
            NSSound.beep()
            reportVectorRenderFailure(
                error,
                item: item,
                isProvisional: false,
                operation: "existing-inline-text-admission"
            )
            return
        }
        guard supportsStableInlineTextEditing(transform: item.transform) else {
            NSSound.beep()
            AppLog.capture.error(
                "Rejected inline text editing for an unsupported presentation transform: id=\(item.id.uuidString, privacy: .public), rotationRadians=\(item.transform.rotationRadians, privacy: .public), scaleX=\(item.transform.scaleX, privacy: .public), scaleY=\(item.transform.scaleY, privacy: .public)"
            )
            return
        }
        session.controller.selectedItemIDs = [item.id]
        session.adoptCurrentStyle(item.style, origin: .existingAnnotation)
        let anchor = AnnotationTextLayout.alignmentAnchor(
            in: rect.standardized,
            text: item.text ?? "",
            style: item.style,
            layout: item.textLayout
        )
        installTextEditor(
            text: item.text ?? "",
            state: TextEditingState(
                itemID: item.id,
                anchor: anchor,
                style: item.style,
                transform: item.transform,
                originalItem: item
            ),
            admittedFont: admittedFont
        )
    }

    private func supportsStableInlineTextEditing(
        transform: AnnotationTransform
    ) -> Bool {
        guard transform.rotationRadians.isFinite,
              transform.scaleX.isFinite,
              transform.scaleY.isFinite,
              transform.translation.width.isFinite,
              transform.translation.height.isFinite,
              transform.scaleX > 0,
              transform.scaleY > 0
        else { return false }
        let normalizedRotation = atan2(
            sin(transform.rotationRadians),
            cos(transform.rotationRadians)
        )
        let representationTolerance = max(
            1,
            max(transform.scaleX, transform.scaleY)
        ) * 0.000_000_01
        return abs(normalizedRotation) < 0.000_000_01
            && abs(transform.scaleX - transform.scaleY) < representationTolerance
    }

    private func installTextEditor(
        text: String,
        state: TextEditingState,
        admittedFont: NSFont? = nil
    ) {
        let chromeDiameter = InlineAnnotationTextEditorFrameView.chromeOutset * 2
        guard bounds.width > chromeDiameter, bounds.height > chromeDiameter else {
            NSSound.beep()
            syncSelectedTextChrome()
            AppLog.capture.error(
                "Rejected inline text editing because the canvas cannot contain its controls: mode=\(state.itemID == nil ? "new" : "existing", privacy: .public), id=\(state.itemID?.uuidString ?? "none", privacy: .public), canvasWidth=\(self.bounds.width, privacy: .public), canvasHeight=\(self.bounds.height, privacy: .public), requiredExtent=\(chromeDiameter, privacy: .public)"
            )
            return
        }
        let transformedTextInsets = textEditorChromeInsetsInView(for: state)
        let maximumFieldWidth = min(
            InlineTextEditorMetrics.maximumViewportWidth,
            bounds.width - chromeDiameter
        )
        guard maximumFieldWidth > transformedTextInsets.width * 2 + 1 else {
            NSSound.beep()
            syncSelectedTextChrome()
            AppLog.capture.error(
                "Rejected inline text editing because transformed chrome leaves no content width: mode=\(state.itemID == nil ? "new" : "existing", privacy: .public), id=\(state.itemID?.uuidString ?? "none", privacy: .public), maximumFieldWidth=\(maximumFieldWidth, privacy: .public), horizontalInset=\(transformedTextInsets.width, privacy: .public), scaleX=\(state.transform.scaleX, privacy: .public)"
            )
            return
        }
        removeSelectedTextChrome(reason: "begin-editing")
        precondition(
            textEditor == nil
                && textEditorContainer == nil
                && textEditorFrameView == nil
                && textEditorDocumentView == nil
                && textEditorPreferredViewportWidthInDocument == nil
                && textEditorCanonicalWrapWidthInDocument == nil
                && textEditorLayoutPayload == nil
                && !textEditorCanonicalWrapWidthWasExplicitlyResized
                && textEditorFieldPlacementAnchorInDocument == nil
                && textEditorLayoutBounds == nil
                && textEditorDocumentScaleInView == nil
                && textEditorSessionFont == nil
                && textEditorSessionFontRequest == nil
                && textEditorRendererGeneration == nil
                && textEditorCanonicalLineAdvance == nil
                && textEditorSessionBaselineOffset == nil
                && textEditorPresentationLayout == nil
                && textEditorGeometryConfigurationCount == 0
                && textEditorPostConfigurationViewportMutationCount == 0
                && textEditorPostConfigurationLineOriginDriftCount == 0
                && textEditorPreventedFrameMutationCount == 0
                && textEditorBaselineCorrectionCount == 0
                && textEditingState == nil
                && textResizeInteraction == nil,
            "Only one inline text editor may be active."
        )
        let frameView = InlineAnnotationTextEditorFrameView(frame: .zero)
        frameView.setAccessibilityElement(true)
        frameView.setAccessibilityRole(.group)
        frameView.setAccessibilityIdentifier("pinned.text.frame")
        frameView.setAccessibilityLabel(
            NSLocalizedString("Annotation text field", comment: "Inline annotation text field")
        )
        frameView.setAccessibilityValue(
            String(
                format: "cornerRadius=%.1f;background=clear",
                InlineAnnotationTextEditorFrameView.cornerRadius
            )
        )
        frameView.onResizeBegan = { [weak self] handle, event in
            self?.beginTextResize(handle: handle, event: event)
        }
        frameView.onResizeChanged = { [weak self] handle, event in
            self?.updateTextResize(handle: handle, event: event)
        }
        frameView.onResizeEnded = { [weak self] handle, event in
            self?.endTextResize(handle: handle, event: event)
        }
        frameView.onDelete = { [weak self] in
            self?.deleteActiveTextEditor()
        }

        // NSClipView aligns its bounds to backing pixels during display. With
        // a fractional annotation anchor that silently turns (0, 0) into a
        // fractional scroll offset; the next input callback used to reset it,
        // producing a visible oscillation. A plain clipped viewport has no
        // hidden scrolling state. We move its fixed document host ourselves
        // only when a long line genuinely needs horizontal scrolling.
        let container = InlineAnnotationTextViewportView(frame: .zero)
        let documentView = InlineAnnotationTextDocumentView(frame: .zero)
        frameView.autoresizesSubviews = false
        container.autoresizesSubviews = false
        documentView.autoresizesSubviews = false

        let textStorage = NSTextStorage()
        let layoutManager = InlineAnnotationTextLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        let editor = InlineAnnotationTextView(
            frame: .zero,
            textContainer: textContainer
        )
        editor.delegate = self
        editor.string = text
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.focusRingType = .none
        // The custom viewport owns overflow and horizontal scrolling. Letting
        // NSTextView remain horizontally resizable makes AppKit pixel-align
        // its frame again during display, even when min/maxSize are equal.
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.autoresizingMask = []
        editor.textColor = annotationColor(state.style.strokeColor)
        editor.insertionPointColor = annotationColor(state.style.strokeColor)
        editor.alignment = nsTextAlignment(state.style.textAlignment)
        let editorChromeInsets = AnnotationTextLayout.chromeInsets(for: state.chromeMode)
        editor.textContainerInset = editorChromeInsets
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.maximumNumberOfLines = 0
        editor.textContainer?.lineBreakMode = .byWordWrapping
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        let initialCanonicalFieldWidth = textEditorFieldWidthInDocument(
            fromViewWidth: InlineTextEditorMetrics.minimumViewportWidth,
            state: state
        )
        editor.textContainer?.containerSize = CGSize(
            width: max(
                1,
                initialCanonicalFieldWidth - editorChromeInsets.width * 2
            ),
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityIdentifier("pinned.text.editor")
        editor.setAccessibilityLabel(NSLocalizedString("Annotation text", comment: "Inline annotation text editor"))
        editor.onMarkedTextChange = { [weak self] in
            self?.updateTextEditorLayout(scrollsToInsertionPoint: true)
        }
        editor.onEscape = { [weak self] in
            self?.endTextEditingIfNeeded(reason: .escape)
        }
        editor.onShiftReturnLineBreak = { [weak self] in
            guard let self, let editor = self.textEditor else { return }
            AppLog.capture.notice(
                "Inserted inline text line break from Shift-Return: characters=\(editor.string.utf16.count, privacy: .public), lines=\(AnnotationTextLayout.lineCount(in: editor.string), privacy: .public)"
            )
        }
        editor.onRejectedPresentationFrameChange = { [weak self] proposedFrame, lockedFrame in
            guard let self else { return }
            self.textEditorPreventedFrameMutationCount += 1
            let message = "Rejected AppKit inline text frame mutation: proposed=(\(proposedFrame.minX),\(proposedFrame.minY),\(proposedFrame.width),\(proposedFrame.height)), locked=(\(lockedFrame.minX),\(lockedFrame.minY),\(lockedFrame.width),\(lockedFrame.height)), rejections=\(self.textEditorPreventedFrameMutationCount)"
            if self.textEditorPreventedFrameMutationCount == 1 {
                AppLog.capture.notice("\(message, privacy: .public)")
            } else {
                AppLog.capture.debug("\(message, privacy: .public)")
            }
        }

        textEditingState = state
        textEditorCanonicalWrapWidthInDocument = state.originalItem.map {
            AnnotationTextLayout.canonicalWrapWidth(for: $0)
        }
        textEditorLayoutPayload = state.originalItem?.textLayout
        if let originalItem = state.originalItem,
           let payload = originalItem.textLayout
        {
            textEditorRendererGeneration = TextEditorRendererGeneration(
                text: originalItem.text ?? "",
                style: originalItem.style,
                payload: payload
            )
        }
        textEditorCanonicalWrapWidthWasExplicitlyResized = false
        lastTextCommitBaselineError = nil
        textEditor = editor
        textEditorContainer = container
        textEditorDocumentView = documentView
        textEditorFrameView = frameView
        documentView.addSubview(editor)
        container.addSubview(documentView)
        frameView.installViewport(container)
        addSubview(frameView)
        refreshPreviewExclusions()
        guard updateTextEditorFrame(admittedFont: admittedFont) else {
            abortInlineTextEditorInstallation(
                editor: editor,
                frameView: frameView,
                state: state,
                phase: "initial-layout"
            )
            return
        }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        guard updateTextEditorLayout(scrollsToInsertionPoint: true) else {
            abortInlineTextEditorInstallation(
                editor: editor,
                frameView: frameView,
                state: state,
                phase: "insertion-layout"
            )
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKey()
        guard window?.makeFirstResponder(editor) == true else {
            preconditionFailure("The inline annotation editor could not become first responder.")
        }
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
        AppLog.capture.notice(
            "Started inline text editing: mode=\(state.itemID == nil ? "new" : "existing", privacy: .public), id=\(state.itemID?.uuidString ?? "none", privacy: .public), x=\(state.anchor.x, privacy: .public), y=\(state.anchor.y, privacy: .public)"
        )
    }

    private func abortInlineTextEditorInstallation(
        editor: InlineAnnotationTextView,
        frameView: InlineAnnotationTextEditorFrameView,
        state: TextEditingState,
        phase: String
    ) {
        dismantleInlineTextEditor(editor: editor, frameView: frameView)
        if state.itemID == nil {
            session.finalizeTextEditingStyle(committedStyle: nil)
        }
        refreshPreviewExclusions()
        syncSelectedTextChrome()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.error(
            "Aborted inline text editor installation after renderer-ready layout failure: phase=\(phase, privacy: .public), mode=\(state.itemID == nil ? "new" : "existing", privacy: .public), id=\(state.itemID?.uuidString ?? "none", privacy: .public)"
        )
    }

    private func beginTextResize(
        handle: InlineAnnotationTextResizeHandle,
        event: NSEvent
    ) {
        guard let editor = textEditor,
              let frameView = textEditorFrameView,
              let container = textEditorContainer,
              let state = textEditingState,
              let initialCanonicalWrapWidth = textEditorCanonicalWrapWidthInDocument,
              textEditorFieldPlacementAnchorInDocument != nil
        else {
            preconditionFailure("Inline text resizing requires the complete active editor hierarchy.")
        }
        let presentationPayload: AnnotationTextLayoutPayload
        let layoutPlan: AnnotationTextLayoutPlan
        let font: NSFont
        do {
            font = try textEditorFont(for: state)
            if let activePayload = textEditorLayoutPayload {
                presentationPayload = activePayload
            } else {
                presentationPayload = try AnnotationTextLayout.safeLayoutPayload(
                    for: editor.string,
                    style: state.style,
                    proposedWrapWidth: initialCanonicalWrapWidth,
                    chromeMode: state.chromeMode,
                    resolvedFont: font
                )
            }
            layoutPlan = try canonicalTextLayoutPlan(
                text: editor.string,
                style: state.style,
                payload: presentationPayload,
                context: "beginning inline text resize"
            )
            clearTextLayoutAuthoringFailure()
        } catch {
            reportTextLayoutAuthoringFailure(
                error,
                operation: "begin-inline-text-resize",
                itemID: state.itemID
            )
            return
        }
        if textResizeInteraction != nil {
            cancelTextResize(reason: "superseded-by-new-drag")
        }
        precondition(
            window?.firstResponder === editor,
            "A resize handle must not take first responder from inline text input."
        )
        if editor.hasMarkedText() {
            editor.unmarkText()
            precondition(
                !editor.hasMarkedText(),
                "Inline text composition must be committed before direct font resizing."
            )
        }
        let fieldFrame = frameView.fieldFrame(in: self)
        let currentFieldAnchor = textFieldAlignmentAnchor(
            for: fieldFrame,
            font: font,
            alignment: state.style.textAlignment,
            lineCount: layoutPlan.lineCount,
            layoutPlan: layoutPlan,
            layoutPayload: presentationPayload,
            state: state
        )
        let currentContentAnchor = textEditorAlignmentAnchor(
            for: state,
            text: editor.string,
            layout: textEditorLayoutPayload
        )
        let fieldAnchorResidualInDocument = documentOffset(
            fromViewOffset: CGSize(
                width: currentContentAnchor.x - currentFieldAnchor.x,
                height: currentContentAnchor.y - currentFieldAnchor.y
            )
        )
        let initialActiveCorner = textFramePoint(handle: handle, in: fieldFrame)
        let fixedCorner = textFramePoint(corner: handle.fixedCorner, in: fieldFrame)
        let initialPointer = convert(event.locationInWindow, from: nil)
        precondition(
            hypot(
                initialActiveCorner.x - fixedCorner.x,
                initialActiveCorner.y - fixedCorner.y
            ) > 1,
            "Inline text resizing requires a non-empty starting field."
        )
        let availableFieldBounds = bounds.insetBy(
            dx: InlineAnnotationTextEditorFrameView.chromeOutset,
            dy: InlineAnnotationTextEditorFrameView.chromeOutset
        )
        precondition(
            availableFieldBounds.width > 0 && availableFieldBounds.height > 0,
            "Inline text chrome requires a non-empty canvas interior."
        )
        let maximumFieldHeight: CGFloat
        switch handle {
        case .northWest:
            maximumFieldHeight = availableFieldBounds.maxY - fixedCorner.y
        case .southWest, .southEast:
            maximumFieldHeight = fixedCorner.y - availableFieldBounds.minY
        }
        let maximumFieldWidth: CGFloat
        switch handle {
        case .northWest, .southWest:
            maximumFieldWidth = fixedCorner.x - availableFieldBounds.minX
        case .southEast:
            maximumFieldWidth = availableFieldBounds.maxX - fixedCorner.x
        }
        precondition(
            maximumFieldWidth > 0 && maximumFieldHeight > 0,
            "The fixed inline text corner must leave resize space inside the canvas."
        )
        let editableRange = AnnotationTextLayout.editableFontSizeRange
        let minimumFontSize = min(editableRange.lowerBound, state.style.fontSize)
        let maximumFontSize: CGFloat
        do {
            maximumFontSize = try maximumTextFontSize(
                fittingFieldHeight: maximumFieldHeight,
                initialFontSize: state.style.fontSize,
                editableUpperBound: max(editableRange.upperBound, state.style.fontSize),
                state: state,
                initialCanonicalWrapWidthInDocument: initialCanonicalWrapWidth,
                resolvedFont: font
            )
        } catch {
            reportTextLayoutAuthoringFailure(
                error,
                operation: "begin-inline-text-resize-maximum-font",
                itemID: state.itemID
            )
            return
        }
        textResizeInteraction = TextResizeInteraction(
            handle: handle,
            initialFontSize: state.style.fontSize,
            minimumFontSize: minimumFontSize,
            maximumFontSize: maximumFontSize,
            initialCanonicalWrapWidthInDocument: initialCanonicalWrapWidth,
            initialViewportWidth: container.bounds.width,
            initialAnchor: state.anchor,
            fieldAnchorResidualInDocument: fieldAnchorResidualInDocument,
            initialActiveCornerInView: initialActiveCorner,
            initialPointerInView: initialPointer,
            fixedCornerInView: fixedCorner,
            canvasBounds: bounds,
            maximumFieldWidth: maximumFieldWidth,
            maximumFieldHeight: maximumFieldHeight,
            initialBaselineCorrectionCount: textEditorBaselineCorrectionCount,
            startedAt: event.timestamp,
            updateCount: 0,
            maximumFixedCornerError: 0
        )
        textResizeFixedCornerError = 0
        frameView.setActiveResizeHandle(handle)
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
        AppLog.capture.notice(
            "Started inline text font resize: handle=\(handle.rawValue, privacy: .public), mode=\(state.itemID == nil ? "new" : "existing", privacy: .public), initialFontSize=\(state.style.fontSize, privacy: .public), initialViewportWidth=\(container.bounds.width, privacy: .public)"
        )
    }

    @discardableResult
    private func updateTextResize(
        handle: InlineAnnotationTextResizeHandle,
        event: NSEvent
    ) -> Bool {
        guard var interaction = textResizeInteraction else {
            AppLog.capture.debug(
                "Ignored stale inline text resize update: handle=\(handle.rawValue, privacy: .public)"
            )
            return false
        }
        guard interaction.handle == handle else {
            AppLog.capture.debug(
                "Ignored inline text resize update from a superseded handle: active=\(interaction.handle.rawValue, privacy: .public), received=\(handle.rawValue, privacy: .public)"
            )
            return false
        }
        guard let editor = textEditor,
              let frameView = textEditorFrameView,
              var state = textEditingState
        else {
            preconditionFailure("Inline text resize updates require an active interaction.")
        }
        precondition(
            window?.firstResponder === editor,
            "Inline text resizing must preserve the editor as first responder."
        )
        let previousState = state
        let previousViewportWidthInDocument = textEditorPreferredViewportWidthInDocument
        let previousCanonicalWrapWidthInDocument = textEditorCanonicalWrapWidthInDocument
        let previousLayoutPayload = textEditorLayoutPayload
        let previousExplicitResize = textEditorCanonicalWrapWidthWasExplicitlyResized
        let previousFieldPlacementAnchor = textEditorFieldPlacementAnchorInDocument
        let previousPresentationLayout = textEditorPresentationLayout

        guard maxFrameDelta(bounds, interaction.canvasBounds) < 0.001 else {
            cancelTextResize(reason: "canvas-geometry-changed")
            return false
        }

        let currentPointer = convert(event.locationInWindow, from: nil)
        let pointerDelta = CGPoint(
            x: currentPointer.x - interaction.initialPointerInView.x,
            y: currentPointer.y - interaction.initialPointerInView.y
        )
        if abs(pointerDelta.x) < 0.001,
           abs(pointerDelta.y) < 0.001,
           interaction.updateCount == 0
        {
            return true
        }
        let initialVector = CGPoint(
            x: interaction.initialActiveCornerInView.x - interaction.fixedCornerInView.x,
            y: interaction.initialActiveCornerInView.y - interaction.fixedCornerInView.y
        )
        let projectedActiveVector = CGPoint(
            x: initialVector.x + pointerDelta.x,
            y: initialVector.y + pointerDelta.y
        )
        let denominator = initialVector.x * initialVector.x + initialVector.y * initialVector.y
        precondition(denominator > 1, "Inline text resize projection requires a non-empty diagonal.")
        let projectedScale = (
            projectedActiveVector.x * initialVector.x
                + projectedActiveVector.y * initialVector.y
        ) / denominator
        precondition(projectedScale.isFinite, "Inline text resize produced a non-finite scale.")

        let fontSize = min(
            interaction.maximumFontSize,
            max(interaction.minimumFontSize, interaction.initialFontSize * projectedScale)
        )
        let resolvedScale = fontSize / interaction.initialFontSize
        if interaction.updateCount == 0,
           abs(resolvedScale - 1) < 0.000_001
        {
            // A nonzero pointer delta can still project to an exact no-op on
            // the resize diagonal. Preserve the original optional layout
            // generation—especially a legacy nil payload—instead of deriving
            // new overhang geometry from an interaction that changed nothing.
            return true
        }
        state.anchor = interaction.initialAnchor
        state.style.fontSize = fontSize
        let proposedCanonicalWrapWidth = interaction.initialCanonicalWrapWidthInDocument
            * resolvedScale
        let activeLayoutPayload: AnnotationTextLayoutPayload
        let layoutPlan: AnnotationTextLayoutPlan
        let font: NSFont
        do {
            font = try textEditorFont(for: state)
            activeLayoutPayload = try AnnotationTextLayout.safeLayoutPayload(
                for: editor.string,
                style: state.style,
                proposedWrapWidth: proposedCanonicalWrapWidth,
                chromeMode: state.chromeMode,
                resolvedFont: font
            )
            layoutPlan = try canonicalTextLayoutPlan(
                text: editor.string,
                style: state.style,
                payload: activeLayoutPayload,
                context: "updating inline text resize"
            )
            clearTextLayoutAuthoringFailure()
        } catch {
            reportTextLayoutAuthoringFailure(
                error,
                operation: "update-inline-text-resize",
                itemID: state.itemID
            )
            cancelTextResize(reason: "layout-capability-failed")
            return false
        }
        let canonicalWrapWidth = activeLayoutPayload.wrapWidth
        let minimumViewportWidth = min(
            interaction.initialViewportWidth,
            InlineAnnotationTextEditorFrameView.minimumInteractiveFieldWidth
        )
        let maximumViewportWidth = min(
            interaction.maximumFieldWidth,
            InlineTextEditorMetrics.maximumViewportWidth
        )
        let proportionalViewportWidth = interaction.initialViewportWidth * resolvedScale
        let viewportWidth = min(
            maximumViewportWidth,
            max(
                minimumViewportWidth,
                proportionalViewportWidth
            )
        )
        let viewportWidthInDocument = textEditorFieldWidthInDocument(
            fromViewWidth: viewportWidth,
            state: state
        )
        let fieldHeight = min(
            interaction.maximumFieldHeight,
            textEditorFieldHeight(
                font: font,
                lineCount: layoutPlan.lineCount,
                layoutPlan: layoutPlan,
                state: state
            )
        )
        let desiredFieldFrame = textFieldFrame(
            fixedCorner: handle.fixedCorner,
            fixedPoint: interaction.fixedCornerInView,
            size: CGSize(width: viewportWidth, height: fieldHeight)
        )
        let desiredAlignmentAnchor = textFieldAlignmentAnchor(
            for: desiredFieldFrame,
            font: font,
            alignment: state.style.textAlignment,
            lineCount: layoutPlan.lineCount,
            layoutPlan: layoutPlan,
            layoutPayload: activeLayoutPayload,
            state: state
        )
        let residualInView = viewOffset(
            fromDocumentOffset: interaction.fieldAnchorResidualInDocument
        )
        let desiredContentAlignmentAnchor = CGPoint(
            x: desiredAlignmentAnchor.x + residualInView.width,
            y: desiredAlignmentAnchor.y + residualInView.height
        )
        let currentAlignmentAnchor = textEditorAlignmentAnchor(
            for: state,
            text: editor.string,
            layout: activeLayoutPayload
        )
        let anchorDelta = documentOffset(fromViewOffset: CGSize(
            width: desiredContentAlignmentAnchor.x - currentAlignmentAnchor.x,
            height: desiredContentAlignmentAnchor.y - currentAlignmentAnchor.y
        ))
        state.anchor.x += anchorDelta.width
        state.anchor.y += anchorDelta.height
        if abs(previousState.style.fontSize - state.style.fontSize) < 0.001,
           abs(previousState.anchor.x - state.anchor.x) < 0.001,
           abs(previousState.anchor.y - state.anchor.y) < 0.001,
           abs(
               (previousViewportWidthInDocument ?? viewportWidthInDocument)
                   - viewportWidthInDocument
           ) < 0.001,
           abs(
               (textEditorCanonicalWrapWidthInDocument ?? canonicalWrapWidth)
                   - canonicalWrapWidth
           ) < 0.001
        {
            return true
        }
        textEditingState = state
        textEditorPreferredViewportWidthInDocument = viewportWidthInDocument
        textEditorCanonicalWrapWidthInDocument = canonicalWrapWidth
        textEditorLayoutPayload = activeLayoutPayload
        if abs(canonicalWrapWidth - interaction.initialCanonicalWrapWidthInDocument) > 0.001 {
            textEditorCanonicalWrapWidthWasExplicitlyResized = true
        }
        textEditorFieldPlacementAnchorInDocument = documentPoint(
            fromViewPoint: desiredAlignmentAnchor
        )
        textEditorPresentationLayout = nil

        let selection = editor.selectedRange()
        guard updateTextEditorFrame(
            scrollsToInsertionPoint: true,
            admittedFont: font
        ) else {
            textEditingState = previousState
            textEditorPreferredViewportWidthInDocument = previousViewportWidthInDocument
            textEditorCanonicalWrapWidthInDocument = previousCanonicalWrapWidthInDocument
            textEditorLayoutPayload = previousLayoutPayload
            textEditorCanonicalWrapWidthWasExplicitlyResized = previousExplicitResize
            textEditorFieldPlacementAnchorInDocument = previousFieldPlacementAnchor
            textEditorPresentationLayout = previousPresentationLayout
            cancelTextResize(reason: "layout-capability-failed-after-preview")
            return false
        }
        precondition(
            editor.selectedRange() == selection,
            "Inline text font resizing changed the active insertion selection."
        )
        precondition(
            window?.firstResponder === editor,
            "Inline text font resizing ended text input unexpectedly."
        )
        let resolvedFixedCorner = frameView.fieldPoint(
            corner: handle.fixedCorner,
            in: self
        )
        textResizeFixedCornerError = hypot(
            resolvedFixedCorner.x - interaction.fixedCornerInView.x,
            resolvedFixedCorner.y - interaction.fixedCornerInView.y
        )
        precondition(
            textResizeFixedCornerError < 0.51,
            "Inline text resizing moved its fixed corner by \(textResizeFixedCornerError) points."
        )
        interaction.updateCount += 1
        interaction.maximumFixedCornerError = max(
            interaction.maximumFixedCornerError,
            textResizeFixedCornerError
        )
        textResizeInteraction = interaction
        AppLog.capture.debug(
            "Updated inline text font resize: handle=\(handle.rawValue, privacy: .public), fontSize=\(fontSize, privacy: .public), viewportWidth=\(viewportWidth, privacy: .public), fixedCornerError=\(self.textResizeFixedCornerError, privacy: .public)"
        )
        return true
    }

    private func endTextResize(
        handle: InlineAnnotationTextResizeHandle,
        event: NSEvent
    ) {
        guard updateTextResize(handle: handle, event: event) else { return }
        guard let interaction = textResizeInteraction,
              let state = textEditingState,
              let frameView = textEditorFrameView
        else {
            preconditionFailure("Inline text resize ended without its active state.")
        }
        textResizeInteraction = nil
        frameView.cancelActiveResize()
        session.adoptCurrentStyle(
            state.style,
            origin: state.itemID == nil ? .newTextDraft : .existingAnnotation
        )
        updateAccessibilitySummary(document: session.controller.document, captured: session.previewImage)
        AppLog.capture.notice(
            "Ended inline text font resize: handle=\(handle.rawValue, privacy: .public), initialFontSize=\(interaction.initialFontSize, privacy: .public), finalFontSize=\(state.style.fontSize, privacy: .public), updates=\(interaction.updateCount, privacy: .public), maximumFixedCornerError=\(interaction.maximumFixedCornerError, privacy: .public), baselineCorrections=\(self.textEditorBaselineCorrectionCount - interaction.initialBaselineCorrectionCount, privacy: .public), durationMilliseconds=\(max(0, event.timestamp - interaction.startedAt) * 1_000, privacy: .public)"
        )
    }

    @discardableResult
    private func cancelTextResize(reason: String) -> Bool {
        guard let interaction = textResizeInteraction else { return false }
        textResizeInteraction = nil
        textEditorFrameView?.cancelActiveResize()
        if let state = textEditingState {
            session.adoptCurrentStyle(
                state.style,
                origin: state.itemID == nil ? .newTextDraft : .existingAnnotation
            )
        }
        textResizeFixedCornerError = 0
        updateAccessibilitySummary(
            document: session.controller.document,
            captured: session.previewImage
        )
        AppLog.capture.notice(
            "Cancelled inline text font resize: reason=\(reason, privacy: .public), handle=\(interaction.handle.rawValue, privacy: .public), updates=\(interaction.updateCount, privacy: .public), maximumFixedCornerError=\(interaction.maximumFixedCornerError, privacy: .public), preservedLatestState=true"
        )
        return true
    }

    private func maximumTextFontSize(
        fittingFieldHeight maximumHeight: CGFloat,
        initialFontSize: CGFloat,
        editableUpperBound: CGFloat,
        state: TextEditingState,
        initialCanonicalWrapWidthInDocument: CGFloat,
        resolvedFont: NSFont
    ) throws -> CGFloat {
        let sourceText = textEditor?.string ?? ""
        let chromeInsets = AnnotationTextLayout.chromeInsets(for: state.chromeMode)
        let maximumHeightInDocument = textEditorFieldHeightInDocument(
            fromViewHeight: maximumHeight,
            state: state
        )
        guard textEditorFieldHeightInDocument(
            fromViewHeight: InlineAnnotationTextEditorFrameView.minimumInteractiveFieldHeight,
            state: state
        ) <= maximumHeightInDocument else {
            return initialFontSize
        }
        let maximumContentHeight = max(
            1,
            maximumHeightInDocument - chromeInsets.height * 2
        )
        return try AnnotationTextLayout.maximumEditableFontSize(
            text: sourceText,
            style: state.style,
            wrapWidthAtInitialSize: initialCanonicalWrapWidthInDocument,
            initialFontSize: initialFontSize,
            upperBound: editableUpperBound,
            maximumContentHeight: maximumContentHeight,
            resolvedFont: resolvedFont
        )
    }

    private func textEditorFont(for state: TextEditingState) throws -> NSFont {
        let request = TextEditorFontRequest(style: state.style)
        let font: NSFont
        if request == textEditorSessionFontRequest,
           let admittedFont = textEditorSessionFont
        {
            font = admittedFont
        } else {
            font = try AnnotationTextLayout.resolvedFont(style: state.style)
        }
        guard font.pointSize.isFinite, font.pointSize > 0 else {
            throw inlineTextKitEditingCapabilityError(
                "resolved primary font did not retain a positive finite point size"
            )
        }
        return font
    }

    /// Proves the actual NSTextView/TextKit 1 stack can reproduce an existing
    /// annotation before selection, chrome, first-responder or editor state is
    /// changed. Core validates the persisted renderer snapshot first; this
    /// second boundary covers the separate live editing engine and our custom
    /// VT/FF control-character delegate.
    private func validateInlineTextKitEditingCapability(
        item: AnnotationItem
    ) throws -> NSFont {
        guard item.kind == .text, case .rect(let rawRect) = item.geometry else {
            throw inlineTextKitEditingCapabilityError(
                "item did not provide text rectangle geometry"
            )
        }
        let text = item.text ?? ""
        let font = try AnnotationTextLayout.resolvedFont(style: item.style)
        let presentationPayload: AnnotationTextLayoutPayload
        if let payload = item.textLayout {
            presentationPayload = payload
        } else {
            presentationPayload = try AnnotationTextLayout.safeLayoutPayload(
                for: text,
                style: item.style,
                proposedWrapWidth: rawRect.standardized.width,
                chromeMode: .legacyTight,
                resolvedFont: font
            )
        }
        let plan = try AnnotationTextLayout.persistedPlan(
            text: text,
            style: item.style,
            payload: presentationPayload
        )
        try validateInlineTextKitEditingCapability(
            text: text,
            style: item.style,
            payload: presentationPayload,
            plan: plan,
            resolvedFont: font
        )
        AppLog.capture.debug(
            "Validated live inline TextKit editing capability: id=\(item.id.uuidString, privacy: .public), lines=\(plan.lineCount, privacy: .public), characters=\(text.utf16.count, privacy: .public), explicitLayout=\(item.textLayout != nil, privacy: .public)"
        )
        return font
    }

    private func validateInlineTextKitEditingCapability(
        text: String,
        style: AnnotationStyle,
        payload: AnnotationTextLayoutPayload,
        plan: AnnotationTextLayoutPlan,
        resolvedFont: NSFont? = nil
    ) throws {
        let font: NSFont
        if let resolvedFont {
            font = resolvedFont
        } else {
            font = try AnnotationTextLayout.resolvedFont(style: style)
        }
        let paragraphStyle = canonicalInlineTextParagraphStyle(
            style: style,
            lineAdvance: plan.lineAdvance
        )
        guard let canonicalBaselineOffset = measuredStableTextEditorBaselineOffset(
            font: font,
            paragraphStyle: paragraphStyle,
            lineHeight: plan.lineAdvance
        ) else {
            throw inlineTextKitEditingCapabilityError(
                "could not resolve the canonical reference baseline"
            )
        }

        let textStorage = NSTextStorage()
        let layoutManager = InlineAnnotationTextLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        let chromeInsets = AnnotationTextLayout.chromeInsets(
            for: payload.chromeMode
        )
        let editorInsets = CGSize(
            width: chromeInsets.width + payload.leadingOverhang,
            height: chromeInsets.height
        )
        let documentSize = CGSize(
            width: chromeInsets.width * 2
                + payload.leadingOverhang
                + plan.wrapWidth
                + payload.trailingOverhang,
            height: chromeInsets.height * 2 + plan.contentHeight
        )
        guard documentSize.width.isFinite,
              documentSize.height.isFinite,
              documentSize.width > 0,
              documentSize.height > 0
        else {
            throw inlineTextKitEditingCapabilityError(
                "saved plan produced a non-finite offscreen document extent"
            )
        }
        let editor = InlineAnnotationTextView(
            frame: CGRect(origin: .zero, size: documentSize),
            textContainer: textContainer
        )
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.autoresizingMask = []
        editor.textContainerInset = editorInsets
        editor.font = font
        editor.alignment = nsTextAlignment(style.textAlignment)
        editor.defaultParagraphStyle = paragraphStyle
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.containerSize = CGSize(
            width: plan.wrapWidth,
            // Editing admission validates line ownership, not viewport
            // clipping. The live editor also begins with an unbounded
            // canonical container before its document host is projected into
            // the viewport; keep every saved visual line inspectable here.
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.string = text
        editor.typingAttributes = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        if textStorage.length > 0 {
            textStorage.addAttributes(
                [
                    .font: font,
                    .paragraphStyle: paragraphStyle
                ],
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        layoutManager.setCanonicalBaselineOffset(canonicalBaselineOffset)
        layoutManager.ensureLayout(for: textContainer)

        let actualLines = inlineTextKitCapabilityLineSnapshots(
            editor: editor,
            canonicalBaselineOffset: canonicalBaselineOffset
        )
        guard actualLines.count == plan.lines.count else {
            throw inlineTextKitEditingCapabilityError(
                "line-count mismatch expected=\(plan.lines.count) actual=\(actualLines.count)"
            )
        }
        guard let firstActualBaseline = actualLines.first?.baselineY else {
            throw inlineTextKitEditingCapabilityError(
                "live TextKit produced no inspectable visual line"
            )
        }
        let expectsExtraLine = text.isEmpty || ((text as NSString).length > 0
            && isInlineTextHardBreakUTF16Unit(
                (text as NSString).character(at: (text as NSString).length - 1)
            ))
        let tolerance = AnnotationTextLayout.persistedGeometryTolerance
        for (lineIndex, pair) in zip(plan.lines, actualLines).enumerated() {
            let (expected, actual) = pair
            guard NSEqualRanges(expected.utf16Range, actual.utf16Range),
                  NSEqualRanges(
                    expected.consumedUTF16Range,
                    actual.consumedUTF16Range
                  )
            else {
                throw inlineTextKitEditingCapabilityError(
                    "line \(lineIndex) UTF-16 ownership mismatch expected=\(expected.utf16Range)/\(expected.consumedUTF16Range) actual=\(actual.utf16Range)/\(actual.consumedUTF16Range)"
                )
            }
            guard abs(expected.originX - actual.usedRectMinX) < tolerance else {
                throw inlineTextKitEditingCapabilityError(
                    "line \(lineIndex) used-origin mismatch expected=\(expected.originX) actual=\(actual.usedRectMinX)"
                )
            }
            let actualBaselineOffset = firstActualBaseline - actual.baselineY
            guard abs(expected.baselineOffset - actualBaselineOffset) < tolerance else {
                throw inlineTextKitEditingCapabilityError(
                    "line \(lineIndex) baseline mismatch expected=\(expected.baselineOffset) actual=\(actualBaselineOffset)"
                )
            }
            guard abs(
                actual.baselineOffsetInFragment - canonicalBaselineOffset
            ) < tolerance else {
                throw inlineTextKitEditingCapabilityError(
                    "line \(lineIndex) fragment baseline was not canonical"
                )
            }
            let shouldBeExtraLine = expectsExtraLine
                && lineIndex == plan.lines.count - 1
            guard actual.isExtraLineFragment == shouldBeExtraLine else {
                throw inlineTextKitEditingCapabilityError(
                    "line \(lineIndex) extra-line ownership mismatch expected=\(shouldBeExtraLine) actual=\(actual.isExtraLineFragment)"
                )
            }
        }
    }

    private func inlineTextKitCapabilityLineSnapshots(
        editor: NSTextView,
        canonicalBaselineOffset: CGFloat
    ) -> [InlineTextKitCapabilityLineSnapshot] {
        guard let textContainer = editor.textContainer,
              let layoutManager = editor.layoutManager
        else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let nsText = editor.string as NSString
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var snapshots: [InlineTextKitCapabilityLineSnapshot] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { lineFragmentRect, usedRect, _, lineGlyphRange, _ in
            let consumedRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            var drawableRange = consumedRange
            while drawableRange.length > 0 {
                let finalUTF16Unit = nsText.character(
                    at: NSMaxRange(drawableRange) - 1
                )
                guard self.isInlineTextHardBreakUTF16Unit(finalUTF16Unit) else {
                    break
                }
                drawableRange.length -= 1
            }
            let baselineLocation = lineGlyphRange.length > 0
                ? layoutManager.location(forGlyphAt: lineGlyphRange.location)
                : usedRect.origin
            snapshots.append(InlineTextKitCapabilityLineSnapshot(
                utf16Range: drawableRange,
                consumedUTF16Range: consumedRange,
                usedRectMinX: usedRect.minX,
                baselineY: lineFragmentRect.minY + baselineLocation.y,
                baselineOffsetInFragment: baselineLocation.y,
                isExtraLineFragment: false
            ))
        }
        let terminatesWithHardBreak = nsText.length > 0
            && isInlineTextHardBreakUTF16Unit(
                nsText.character(at: nsText.length - 1)
            )
        if editor.string.isEmpty || terminatesWithHardBreak {
            let emptyRange = NSRange(location: nsText.length, length: 0)
            snapshots.append(InlineTextKitCapabilityLineSnapshot(
                utf16Range: emptyRange,
                consumedUTF16Range: emptyRange,
                usedRectMinX: layoutManager.extraLineFragmentUsedRect.minX,
                baselineY: layoutManager.extraLineFragmentRect.minY
                    + canonicalBaselineOffset,
                baselineOffsetInFragment: canonicalBaselineOffset,
                isExtraLineFragment: true
            ))
        }
        return snapshots
    }

    private func inlineTextKitEditingCapabilityError(
        _ diagnostic: String
    ) -> InlineTextKitEditingCapabilityError {
        AppLog.capture.error(
            "Rejected live inline TextKit editing capability: \(diagnostic, privacy: .public)"
        )
        return InlineTextKitEditingCapabilityError(diagnostic: diagnostic)
    }

    private func canonicalInlineTextParagraphStyle(
        style: AnnotationStyle,
        lineAdvance: CGFloat
    ) -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineAdvance
        paragraphStyle.maximumLineHeight = lineAdvance
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = nsTextAlignment(style.textAlignment)
        return paragraphStyle
    }

    private func canonicalTextLayoutPlan(
        text: String,
        style: AnnotationStyle,
        payload: AnnotationTextLayoutPayload,
        context: String
    ) throws -> AnnotationTextLayoutPlan {
        do {
            return try AnnotationTextLayout.persistedPlan(
                text: text,
                style: style,
                payload: payload
            )
        } catch {
            AppLog.capture.error(
                "Rejected canonical inline text plan: context=\(context, privacy: .public)"
            )
            throw error
        }
    }

    private func nsTextAlignment(_ alignment: AnnotationTextAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    private func textEditorFieldHeight(
        font: NSFont,
        lineCount: Int = 1,
        layoutPlan: AnnotationTextLayoutPlan? = nil,
        state explicitState: TextEditingState? = nil
    ) -> CGFloat {
        let state = explicitState ?? textEditingState
        let verticalInsetInDocument = state.map {
            AnnotationTextLayout.chromeInsets(for: $0.chromeMode).height
        } ?? InlineTextEditorMetrics.verticalPadding
        let lines = CGFloat(max(1, lineCount))
        let contentHeightInDocument = layoutPlan?.contentHeight
            ?? AnnotationTextLayout.lineAdvance(for: font) * lines
        let completeHeightInDocument = contentHeightInDocument
            + verticalInsetInDocument * 2
        let completeHeightInView = state.map {
            textEditorFieldHeightInView(
                fromUntransformedDocumentHeight: completeHeightInDocument,
                state: $0
            )
        } ?? completeHeightInDocument
        // The border is interaction chrome, not persisted text geometry. Give
        // it a whole view-point ceiling so small fallback-glyph extent changes
        // do not make the field visibly breathe while IME composition swaps
        // fonts. TextKit's canonical bounds and every line origin remain exact.
        let stableInteractiveHeight = ceil(completeHeightInView)
        return max(
            InlineAnnotationTextEditorFrameView.minimumInteractiveFieldHeight,
            stableInteractiveHeight
        )
    }

    private func textFieldBaselineInsetFromSouth(
        font: NSFont,
        lineCount: Int = 1,
        layoutPlan: AnnotationTextLayoutPlan? = nil,
        state explicitState: TextEditingState? = nil
    ) -> CGFloat {
        let state = explicitState ?? textEditingState
        let verticalInsetInDocument = state.map {
            AnnotationTextLayout.chromeInsets(for: $0.chromeMode).height
        } ?? InlineTextEditorMetrics.verticalPadding
        let baselineInsetInDocument: CGFloat
        if let layoutPlan {
            baselineInsetInDocument = layoutPlan.bottomExtent
                + CGFloat(max(0, layoutPlan.lineCount - 1)) * layoutPlan.lineAdvance
                + verticalInsetInDocument
        } else {
            let extraLines = CGFloat(max(0, max(1, lineCount) - 1))
            baselineInsetInDocument = max(0, -font.descender)
                + max(0, font.leading) / 2
                + verticalInsetInDocument
                + AnnotationTextLayout.lineAdvance(for: font) * extraLines
        }
        return state.map {
            textEditorFieldHeightInView(
                fromUntransformedDocumentHeight: baselineInsetInDocument,
                state: $0
            )
        } ?? baselineInsetInDocument
    }

    private func resolvedTextFieldFrame(
        alignmentAnchor: CGPoint,
        font: NSFont,
        preferredViewportWidth: CGFloat,
        availableFieldBounds: CGRect,
        alignment: AnnotationTextAlignment,
        lineCount: Int = 1,
        layoutPlan: AnnotationTextLayoutPlan? = nil,
        layoutPayload: AnnotationTextLayoutPayload? = nil,
        state: TextEditingState? = nil
    ) -> CGRect {
        precondition(
            preferredViewportWidth > 0
                && availableFieldBounds.width > 0
                && availableFieldBounds.height > 0,
            "Inline text field layout requires finite, non-empty geometry."
        )
        let width = min(availableFieldBounds.width, preferredViewportWidth)
        let height = min(
            availableFieldBounds.height,
            textEditorFieldHeight(
                font: font,
                lineCount: lineCount,
                layoutPlan: layoutPlan,
                state: state
            )
        )
        let proposedX: CGFloat
        let horizontalMargins = textEditorHorizontalMarginsInView(
            for: layoutPayload ?? textEditorLayoutPayload
        )
        switch alignment {
        case .leading:
            proposedX = alignmentAnchor.x - horizontalMargins.leading
        case .center:
            proposedX = alignmentAnchor.x
                + (horizontalMargins.trailing - horizontalMargins.leading) / 2
                - width / 2
        case .trailing:
            proposedX = alignmentAnchor.x
                - width
                + horizontalMargins.trailing
        }
        let proposedY = alignmentAnchor.y
            - textFieldBaselineInsetFromSouth(
                font: font,
                lineCount: lineCount,
                layoutPlan: layoutPlan,
                state: state
            )
        return CGRect(
            x: min(
                max(availableFieldBounds.minX, proposedX),
                max(availableFieldBounds.minX, availableFieldBounds.maxX - width)
            ),
            y: min(
                max(availableFieldBounds.minY, proposedY),
                max(availableFieldBounds.minY, availableFieldBounds.maxY - height)
            ),
            width: width,
            height: height
        )
    }

    private func textFieldAlignmentAnchor(
        for fieldFrame: CGRect,
        font: NSFont,
        alignment: AnnotationTextAlignment,
        lineCount: Int = 1,
        layoutPlan: AnnotationTextLayoutPlan? = nil,
        layoutPayload: AnnotationTextLayoutPayload? = nil,
        state: TextEditingState? = nil
    ) -> CGPoint {
        precondition(
            fieldFrame.width > 0 && fieldFrame.height > 0,
            "Inline text field inversion requires a non-empty target frame."
        )
        let x: CGFloat
        let horizontalMargins = textEditorHorizontalMarginsInView(
            for: layoutPayload ?? textEditorLayoutPayload
        )
        switch alignment {
        case .leading:
            x = fieldFrame.minX + horizontalMargins.leading
        case .center:
            x = fieldFrame.midX
                + (horizontalMargins.leading - horizontalMargins.trailing) / 2
        case .trailing:
            x = fieldFrame.maxX - horizontalMargins.trailing
        }
        return CGPoint(
            x: x,
            y: fieldFrame.minY + textFieldBaselineInsetFromSouth(
                font: font,
                lineCount: lineCount,
                layoutPlan: layoutPlan,
                state: state
            )
        )
    }

    private func textFramePoint(
        handle: InlineAnnotationTextResizeHandle,
        in rect: CGRect
    ) -> CGPoint {
        switch handle {
        case .northWest: return CGPoint(x: rect.minX, y: rect.maxY)
        case .southWest: return CGPoint(x: rect.minX, y: rect.minY)
        case .southEast: return CGPoint(x: rect.maxX, y: rect.minY)
        }
    }

    private func textFramePoint(
        corner: InlineAnnotationTextFrameCorner,
        in rect: CGRect
    ) -> CGPoint {
        switch corner {
        case .northWest: return CGPoint(x: rect.minX, y: rect.maxY)
        case .northEast: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .southWest: return CGPoint(x: rect.minX, y: rect.minY)
        case .southEast: return CGPoint(x: rect.maxX, y: rect.minY)
        }
    }

    private func textFieldFrame(
        fixedCorner: InlineAnnotationTextFrameCorner,
        fixedPoint: CGPoint,
        size: CGSize
    ) -> CGRect {
        switch fixedCorner {
        case .northWest:
            return CGRect(x: fixedPoint.x, y: fixedPoint.y - size.height, width: size.width, height: size.height)
        case .northEast:
            return CGRect(x: fixedPoint.x - size.width, y: fixedPoint.y - size.height, width: size.width, height: size.height)
        case .southWest:
            return CGRect(origin: fixedPoint, size: size)
        case .southEast:
            return CGRect(x: fixedPoint.x - size.width, y: fixedPoint.y, width: size.width, height: size.height)
        }
    }

    private func documentOffset(fromViewOffset offset: CGSize) -> CGSize {
        let visible = visibleDocumentRect()
        precondition(
            bounds.width > 0 && bounds.height > 0,
            "Inline text resize conversion requires non-empty canvas bounds."
        )
        return CGSize(
            width: offset.width / bounds.width * visible.width,
            height: offset.height / bounds.height * visible.height
        )
    }

    private func viewOffset(fromDocumentOffset offset: CGSize) -> CGSize {
        let visible = visibleDocumentRect()
        precondition(
            visible.width > 0 && visible.height > 0,
            "Inline text layout conversion requires non-empty document geometry."
        )
        return CGSize(
            width: offset.width / visible.width * bounds.width,
            height: offset.height / visible.height * bounds.height
        )
    }

    private func textEditorChromeInsetsInView(
        for state: TextEditingState
    ) -> CGSize {
        let documentInsets = AnnotationTextLayout.chromeInsets(for: state.chromeMode)
        let canvasInsets = viewOffset(fromDocumentOffset: documentInsets)
        return CGSize(
            width: canvasInsets.width * abs(state.transform.scaleX),
            height: canvasInsets.height * abs(state.transform.scaleY)
        )
    }

    private func textEditorHorizontalMarginsInView(
        for payload: AnnotationTextLayoutPayload?
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard let state = textEditingState else {
            return (
                InlineTextEditorMetrics.horizontalPadding,
                InlineTextEditorMetrics.horizontalPadding
            )
        }
        let chrome = textEditorChromeInsetsInView(for: state).width
        guard let payload else { return (chrome, chrome) }
        return (
            chrome + textEditorFieldWidthInView(
                fromUntransformedDocumentWidth: payload.leadingOverhang,
                state: state
            ),
            chrome + textEditorFieldWidthInView(
                fromUntransformedDocumentWidth: payload.trailingOverhang,
                state: state
            )
        )
    }

    private var textEditorCanvasScaleX: CGFloat {
        let scale = viewOffset(fromDocumentOffset: CGSize(width: 1, height: 0)).width
        precondition(
            scale.isFinite && scale > 0,
            "Inline text layout requires a finite positive horizontal canvas scale."
        )
        return scale
    }

    private func textEditorFieldWidthInView(
        fromUntransformedDocumentWidth width: CGFloat,
        state: TextEditingState
    ) -> CGFloat {
        viewOffset(fromDocumentOffset: CGSize(width: width, height: 0)).width
            * abs(state.transform.scaleX)
    }

    private func textEditorFieldHeightInView(
        fromUntransformedDocumentHeight height: CGFloat,
        state: TextEditingState
    ) -> CGFloat {
        viewOffset(fromDocumentOffset: CGSize(width: 0, height: height)).height
            * abs(state.transform.scaleY)
    }

    private func textEditorFieldWidthInDocument(
        fromViewWidth width: CGFloat,
        state: TextEditingState
    ) -> CGFloat {
        precondition(
            state.transform.scaleX.isFinite && abs(state.transform.scaleX) > 0,
            "Inline text width conversion requires a finite non-zero uniform transform."
        )
        return documentOffset(fromViewOffset: CGSize(
            width: width / abs(state.transform.scaleX),
            height: 0
        )).width
    }

    private func textEditorFieldHeightInDocument(
        fromViewHeight height: CGFloat,
        state: TextEditingState
    ) -> CGFloat {
        precondition(
            state.transform.scaleY.isFinite && abs(state.transform.scaleY) > 0,
            "Inline text height conversion requires a finite non-zero uniform transform."
        )
        return documentOffset(fromViewOffset: CGSize(
            width: 0,
            height: height / abs(state.transform.scaleY)
        )).height
    }

    private func textEditorDocumentSizeInView(
        fromCanonicalSize size: CGSize,
        state: TextEditingState
    ) -> CGSize {
        CGSize(
            width: textEditorFieldWidthInView(
                fromUntransformedDocumentWidth: size.width,
                state: state
            ),
            height: textEditorFieldHeightInView(
                fromUntransformedDocumentHeight: size.height,
                state: state
            )
        )
    }

    private func canonicalTextWrapWidth(
        forFieldWidth fieldWidth: CGFloat,
        state: TextEditingState
    ) -> CGFloat {
        AnnotationTextLayout.canonicalWrapWidth(
            fromPresentationFieldWidth: fieldWidth,
            chromeMode: state.chromeMode,
            canvasScale: textEditorCanvasScaleX,
            uniformTransformScale: abs(state.transform.scaleX)
        )
    }

    private func style(
        _ source: AnnotationStyle,
        applying color: RGBAColor,
        for kind: AnnotationKind
    ) -> AnnotationStyle {
        source.applyingColor(color, for: kind)
    }

    private func applyActiveTextEditorStyle(_ style: AnnotationStyle) {
        guard let editor = textEditor else {
            preconditionFailure("An active text style change requires its inline editor.")
        }
        let color = annotationColor(style.strokeColor)
        editor.textColor = color
        editor.insertionPointColor = color
        var typingAttributes = editor.typingAttributes
        typingAttributes[.foregroundColor] = color
        editor.typingAttributes = typingAttributes
        if let textStorage = editor.textStorage,
           textStorage.length > 0,
           !editor.hasMarkedText()
        {
            textStorage.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
    }

    private func applyCanonicalTextEditorTypography(
        to editor: InlineAnnotationTextView,
        state: TextEditingState,
        font: NSFont,
        lineAdvance: CGFloat,
        canonicalBaselineOffset: CGFloat
    ) {
        precondition(
            lineAdvance.isFinite && lineAdvance > 0,
            "Inline text requires a finite positive canonical line advance."
        )
        let alignment = nsTextAlignment(state.style.textAlignment)
        let fontMatches: (NSFont?) -> Bool = { candidate in
            guard let candidate else { return false }
            return candidate.fontName == font.fontName
                && abs(candidate.pointSize - font.pointSize) < 0.001
        }
        let paragraphMatches: (NSParagraphStyle?) -> Bool = { paragraphStyle in
            guard let paragraphStyle else { return false }
            return abs(paragraphStyle.minimumLineHeight - lineAdvance) < 0.001
                && abs(paragraphStyle.maximumLineHeight - lineAdvance) < 0.001
                && paragraphStyle.lineBreakMode == .byWordWrapping
                && paragraphStyle.alignment == alignment
        }
        let canonicalLineAdvanceChanged = textEditorCanonicalLineAdvance.map {
            abs($0 - lineAdvance) >= 0.001
        } ?? true
        let defaultTypographyChanged = !fontMatches(editor.font)
            || !paragraphMatches(editor.defaultParagraphStyle)
        let typingTypographyChanged = !fontMatches(
            editor.typingAttributes[.font] as? NSFont
        ) || !paragraphMatches(
            editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        )
        var storageTypographyChanged = false
        if let textStorage = editor.textStorage, textStorage.length > 0 {
            textStorage.enumerateAttributes(
                in: NSRange(location: 0, length: textStorage.length),
                options: []
            ) { attributes, _, stop in
                guard fontMatches(attributes[.font] as? NSFont),
                      paragraphMatches(
                        attributes[.paragraphStyle] as? NSParagraphStyle
                      )
                else {
                    storageTypographyChanged = true
                    stop.pointee = true
                    return
                }
            }
        }
        guard canonicalLineAdvanceChanged
                || defaultTypographyChanged
                || typingTypographyChanged
                || storageTypographyChanged
        else { return }

        let previousLineAdvance = textEditorCanonicalLineAdvance
        let paragraphStyle = canonicalInlineTextParagraphStyle(
            style: state.style,
            lineAdvance: lineAdvance
        )

        // Publish the generation before touching NSTextStorage. AppKit may
        // synchronously ask for another layout while processing attributes;
        // that pass must observe the same canonical typography owner.
        textEditorCanonicalLineAdvance = lineAdvance
        editor.font = font
        editor.alignment = alignment
        editor.defaultParagraphStyle = paragraphStyle
        guard let layoutManager = editor.layoutManager
                as? InlineAnnotationTextLayoutManager
        else {
            preconditionFailure(
                "Inline text requires its canonical TextKit layout manager."
            )
        }
        layoutManager.setCanonicalBaselineOffset(canonicalBaselineOffset)
        textEditorSessionBaselineOffset = canonicalBaselineOffset
        var typingAttributes = editor.typingAttributes
        typingAttributes[.font] = font
        typingAttributes[.foregroundColor] = annotationColor(state.style.strokeColor)
        typingAttributes[.paragraphStyle] = paragraphStyle
        editor.typingAttributes = typingAttributes
        if let textStorage = editor.textStorage, textStorage.length > 0 {
            // Preserve IME clause/underline attributes while enforcing the
            // same canonical font and paragraph advance on the marked run.
            // A fallback glyph is resolved by TextKit from this primary font;
            // an IME-provided presentation font must not become layout state.
            textStorage.addAttributes(
                [
                    .font: font,
                    .paragraphStyle: paragraphStyle
                ],
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        if canonicalLineAdvanceChanged, let previousLineAdvance {
            AppLog.capture.debug(
                "Updated canonical inline text line advance: previous=\(previousLineAdvance, privacy: .public), next=\(lineAdvance, privacy: .public), markedText=\(editor.hasMarkedText(), privacy: .public), characters=\(editor.string.utf16.count, privacy: .public)"
            )
        }
    }

    @discardableResult
    private func updateTextEditorFrame(
        scrollsToInsertionPoint: Bool = false,
        admittedFont: NSFont? = nil
    ) -> Bool {
        guard textEditor != nil,
              let state = textEditingState,
              bounds.width > 0, bounds.height > 0
        else { return true }
        let previousLayoutBounds = textEditorLayoutBounds
        let previousDocumentScaleInView = textEditorDocumentScaleInView
        let previousSessionFont = textEditorSessionFont
        let previousSessionFontRequest = textEditorSessionFontRequest
        let previousCanonicalLineAdvance = textEditorCanonicalLineAdvance
        let previousSessionBaselineOffset = textEditorSessionBaselineOffset
        let previousPresentationLayout = textEditorPresentationLayout
        let previousPreferredViewportWidth = textEditorPreferredViewportWidthInDocument
        let font: NSFont
        do {
            if let admittedFont {
                font = admittedFont
            } else {
                font = try textEditorFont(for: state)
            }
        } catch {
            reportTextLayoutAuthoringFailure(
                error,
                operation: "resolve-inline-text-font",
                itemID: state.itemID
            )
            return false
        }
        let fontRequest = TextEditorFontRequest(style: state.style)
        let documentScaleInView = CGSize(
            width: textEditorFieldWidthInView(
                fromUntransformedDocumentWidth: 1,
                state: state
            ),
            height: textEditorFieldHeightInView(
                fromUntransformedDocumentHeight: 1,
                state: state
            )
        )

        let layoutBoundsChanged = textEditorLayoutBounds != bounds
        let documentScaleChanged = textEditorDocumentScaleInView.map {
            abs($0.width - documentScaleInView.width) > 0.000_001
                || abs($0.height - documentScaleInView.height) > 0.000_001
        } ?? true
        let sessionFontChanged = textEditorSessionFontRequest != fontRequest
            || (textEditorSessionFont.map {
                $0.fontName != font.fontName || abs($0.pointSize - font.pointSize) > 0.001
            } ?? true)
        if layoutBoundsChanged || documentScaleChanged || sessionFontChanged {
            if textEditorGeometryConfigurationCount > 0 {
                let message = "Recalibrating inline text after geometry or typography changed: boundsChanged=\(layoutBoundsChanged), documentScaleChanged=\(documentScaleChanged), sessionFontChanged=\(sessionFontChanged), explicitResize=\(self.textResizeInteraction != nil), configurations=\(self.textEditorGeometryConfigurationCount)"
                if textResizeInteraction == nil {
                    AppLog.capture.notice("\(message, privacy: .public)")
                } else {
                    AppLog.capture.debug("\(message, privacy: .public)")
                }
            }
            textEditorLayoutBounds = bounds
            textEditorDocumentScaleInView = documentScaleInView
            textEditorSessionFont = font
            textEditorSessionFontRequest = fontRequest
            if sessionFontChanged {
                // The next canonical plan owns the complete font/line-height
                // generation, even when two primary fonts share a point size.
                textEditorCanonicalLineAdvance = nil
                textEditorSessionBaselineOffset = nil
            }
            textEditorPresentationLayout = nil
        }
        if textEditorPreferredViewportWidthInDocument == nil {
            // New drafts start compact and grow with the text. Re-editing a
            // wrapped annotation keeps the committed wrap width so the same
            // line breaks come back. The width never shrinks during a session,
            // so IME marked text cannot oscillate the frame.
            let availableWidth = max(
                1,
                bounds.width - InlineAnnotationTextEditorFrameView.chromeOutset * 2
            )
            let maximumViewportWidth = min(
                InlineTextEditorMetrics.maximumViewportWidth,
                availableWidth
            )
            let initialViewportWidth: CGFloat
            if let itemID = state.itemID,
               let item = session.controller.document.annotations.first(where: { $0.id == itemID }),
               case .rect = item.geometry
            {
                let existingWidth: CGFloat
                if let layout = item.textLayout {
                    existingWidth = AnnotationTextLayout.presentationFieldWidth(
                        layout: layout,
                        canvasScale: textEditorCanvasScaleX,
                        uniformTransformScale: abs(state.transform.scaleX)
                    )
                } else {
                    existingWidth = AnnotationTextLayout.presentationFieldWidth(
                        canonicalWrapWidth: AnnotationTextLayout.canonicalWrapWidth(for: item),
                        chromeMode: .legacyTight,
                        canvasScale: textEditorCanvasScaleX,
                        uniformTransformScale: abs(state.transform.scaleX)
                    )
                }
                initialViewportWidth = min(
                    maximumViewportWidth,
                    max(1, existingWidth)
                )
            } else {
                initialViewportWidth = min(
                    maximumViewportWidth,
                    InlineTextEditorMetrics.minimumViewportWidth
                )
            }
            textEditorPreferredViewportWidthInDocument = textEditorFieldWidthInDocument(
                fromViewWidth: initialViewportWidth,
                state: state
            )
        }
        let didResolveLayout = updateTextEditorLayout(
            scrollsToInsertionPoint: scrollsToInsertionPoint
        )
        if !didResolveLayout {
            textEditorLayoutBounds = previousLayoutBounds
            textEditorDocumentScaleInView = previousDocumentScaleInView
            textEditorSessionFont = previousSessionFont
            textEditorSessionFontRequest = previousSessionFontRequest
            textEditorCanonicalLineAdvance = previousCanonicalLineAdvance
            textEditorSessionBaselineOffset = previousSessionBaselineOffset
            textEditorPresentationLayout = previousPresentationLayout
            textEditorPreferredViewportWidthInDocument = previousPreferredViewportWidth
        }
        return didResolveLayout
    }

    @discardableResult
    private func updateTextEditorLayout(scrollsToInsertionPoint: Bool) -> Bool {
        do {
            try updateTextEditorLayoutChecked(
                scrollsToInsertionPoint: scrollsToInsertionPoint
            )
            clearTextLayoutAuthoringFailure()
            return true
        } catch {
            reportTextLayoutAuthoringFailure(
                error,
                operation: "update-inline-text-layout",
                itemID: textEditingState?.itemID
            )
            return false
        }
    }

    private func updateTextEditorLayoutChecked(
        scrollsToInsertionPoint: Bool
    ) throws {
        guard let editor = textEditor,
              let container = textEditorContainer,
              let documentView = textEditorDocumentView,
              let frameView = textEditorFrameView,
              let preferredViewportWidthInDocument = textEditorPreferredViewportWidthInDocument,
              let state = textEditingState,
              let font = textEditorSessionFont,
              bounds.width > 0, bounds.height > 0
        else { return }
        if let priorGeneration = textEditorRendererGeneration {
            try AnnotationTextLayout.validateEditingCapability(
                text: priorGeneration.text,
                style: priorGeneration.style,
                layout: priorGeneration.payload
            )
        }
        var preferredViewportWidth = textEditorFieldWidthInView(
            fromUntransformedDocumentWidth: preferredViewportWidthInDocument,
            state: state
        )
        precondition(
            preferredViewportWidth.isFinite && preferredViewportWidth > 0,
            "Inline text viewport width must resolve to a positive view-space value."
        )
        let measuredWidth = AnnotationTextLayout.maximumLineWidth(
            for: editor.string,
            resolvedFont: font
        )
        let chromeOutset = InlineAnnotationTextEditorFrameView.chromeOutset
        let availableFieldBounds = bounds.insetBy(dx: chromeOutset, dy: chromeOutset)
        guard availableFieldBounds.width > 0, availableFieldBounds.height > 0 else {
            preconditionFailure("Inline text chrome requires a non-empty canvas interior.")
        }
        let maximumViewportWidth = min(
            InlineTextEditorMetrics.maximumViewportWidth,
            availableFieldBounds.width
        )
        let semanticWrapCap = canonicalTextWrapWidth(
            forFieldWidth: maximumViewportWidth,
            state: state
        )
        let requiredUntransformedWidth = min(
            semanticWrapCap,
            max(1, ceil(measuredWidth))
        )
        let semanticBaseWidth: CGFloat
        let textActuallyChanged: Bool
        let fontMetricsActuallyChanged: Bool
        let alignmentActuallyChanged: Bool
        let originalSemanticStateRestored: Bool
        let resetsPresentationForRestoredOriginal: Bool
        let previousLayoutPayload = textEditorLayoutPayload
        if let originalItem = state.originalItem {
            guard case .rect(let originalRect) = originalItem.geometry else {
                preconditionFailure("An existing inline text editor lost its original text rectangle.")
            }
            let originalWrapWidth = AnnotationTextLayout.canonicalWrapWidth(for: originalItem)
            textActuallyChanged = editor.string != (originalItem.text ?? "")
            fontMetricsActuallyChanged = abs(
                state.style.fontSize - originalItem.style.fontSize
            ) > 0.000_001
                || state.style.fontName != originalItem.style.fontName
                || state.style.fontWeight != originalItem.style.fontWeight
            alignmentActuallyChanged = state.style.textAlignment
                != originalItem.style.textAlignment
            let originalAnchor = AnnotationTextLayout.alignmentAnchor(
                in: originalRect,
                text: originalItem.text ?? "",
                style: originalItem.style,
                layout: originalItem.textLayout
            )
            originalSemanticStateRestored = !textActuallyChanged
                && !fontMetricsActuallyChanged
                && !alignmentActuallyChanged
                && !textEditorCanonicalWrapWidthWasExplicitlyResized
                && hypot(
                    originalAnchor.x - state.anchor.x,
                    originalAnchor.y - state.anchor.y
                ) < 0.000_001
            if originalSemanticStateRestored {
                resetsPresentationForRestoredOriginal = abs(
                    (textEditorCanonicalWrapWidthInDocument ?? originalWrapWidth)
                        - originalWrapWidth
                ) > 0.001
                    || previousLayoutPayload != originalItem.textLayout
                semanticBaseWidth = originalWrapWidth
            } else {
                resetsPresentationForRestoredOriginal = false
                semanticBaseWidth = textEditorCanonicalWrapWidthInDocument
                    ?? originalWrapWidth
            }
        } else {
            semanticBaseWidth = textEditorCanonicalWrapWidthInDocument ?? 1
            textActuallyChanged = true
            fontMetricsActuallyChanged = false
            alignmentActuallyChanged = false
            originalSemanticStateRestored = false
            resetsPresentationForRestoredOriginal = false
        }
        let layoutActuallyChanged = textActuallyChanged
            || fontMetricsActuallyChanged
            || alignmentActuallyChanged
        // The interaction viewport is bounded by the canvas and the 520-point
        // usability cap. The persisted wrap width is not: an older or scaled
        // annotation may legitimately own a wider line. Never narrow that
        // semantic width merely because only part of it is visible while the
        // user edits. New content may still grow up to the interaction cap.
        let proposedSemanticWrapWidth = layoutActuallyChanged
            && !textEditorCanonicalWrapWidthWasExplicitlyResized
            && textResizeInteraction == nil
            ? max(
                semanticBaseWidth,
                textActuallyChanged || fontMetricsActuallyChanged
                    ? min(semanticWrapCap, requiredUntransformedWidth)
                    : semanticBaseWidth
            )
            : semanticBaseWidth
        let safeLayoutPayload = try AnnotationTextLayout.safeLayoutPayload(
            for: editor.string,
            style: state.style,
            proposedWrapWidth: proposedSemanticWrapWidth,
            chromeMode: state.chromeMode,
            resolvedFont: font
        )
        if originalSemanticStateRestored,
           let originalPayload = state.originalItem?.textLayout,
           safeLayoutPayload != originalPayload
        {
            throw inlineTextKitEditingCapabilityError(
                "the current font source no longer reproduces the admitted renderer generation"
            )
        }
        let resolvedLayoutPayload: AnnotationTextLayoutPayload?
        if originalSemanticStateRestored {
            resolvedLayoutPayload = state.originalItem?.textLayout
        } else {
            resolvedLayoutPayload = safeLayoutPayload
        }
        // A legacy nil payload remains absent for exact persistence, while its
        // live NSTextView still needs the measured overhangs to avoid clipping.
        let presentationLayoutPayload = resolvedLayoutPayload ?? safeLayoutPayload
        let layoutPlan = try canonicalTextLayoutPlan(
            text: editor.string,
            style: state.style,
            payload: presentationLayoutPayload,
            context: "updating inline text presentation"
        )
        let baselineParagraphStyle = canonicalInlineTextParagraphStyle(
            style: state.style,
            lineAdvance: layoutPlan.lineAdvance
        )
        let canonicalBaselineOffset = try stableTextEditorBaselineOffset(
            font: font,
            paragraphStyle: baselineParagraphStyle,
            lineHeight: layoutPlan.lineAdvance
        )
        if resetsPresentationForRestoredOriginal {
            // The editor may have grown while text was temporarily different
            // or may own a different overhang generation at the same wrap
            // width. Reset only after the restored payload has passed every
            // renderer-ready capability check.
            textEditorPresentationLayout = nil
        }
        textEditorLayoutPayload = resolvedLayoutPayload
        let semanticWrapWidth = presentationLayoutPayload.wrapWidth
        precondition(
            semanticWrapWidth.isFinite && semanticWrapWidth > 0,
            "Inline text semantic layout produced an invalid canonical wrap width."
        )
        textEditorCanonicalWrapWidthInDocument = semanticWrapWidth
        frameView.setFontSizeAccessibilityValue(state.style.fontSize)
        let completeSemanticFieldWidth = AnnotationTextLayout.presentationFieldWidth(
            layout: presentationLayoutPayload,
            canvasScale: textEditorCanvasScaleX,
            uniformTransformScale: abs(state.transform.scaleX)
        )
        // A direct-resize interaction already owns the presentation viewport.
        // Re-growing it from semantic content in the same frame overrides the
        // pointer-derived width and changes the content-to-field residual.
        let neededViewportWidth = textResizeInteraction == nil
            && (textActuallyChanged || fontMetricsActuallyChanged)
            ? min(
                maximumViewportWidth,
                max(
                    preferredViewportWidth,
                    ceil(completeSemanticFieldWidth)
                )
            )
            : preferredViewportWidth
        if neededViewportWidth > preferredViewportWidth + 0.01 {
            AppLog.capture.notice(
                "Grew the inline text field so leading characters stay visible: previousWidth=\(preferredViewportWidth, privacy: .public), nextWidth=\(neededViewportWidth, privacy: .public), characters=\(editor.string.utf16.count, privacy: .public)"
            )
            preferredViewportWidth = neededViewportWidth
            textEditorPreferredViewportWidthInDocument = textEditorFieldWidthInDocument(
                fromViewWidth: preferredViewportWidth,
                state: state
            )
        }
        applyCanonicalTextEditorTypography(
            to: editor,
            state: state,
            font: font,
            lineAdvance: layoutPlan.lineAdvance,
            canonicalBaselineOffset: canonicalBaselineOffset
        )
        let lineCount = layoutPlan.lineCount
        // A legacy uniform transform is applied around the annotation rect,
        // whose center changes when leading/trailing text changes width. The
        // renderer's presentation anchor must therefore be resolved from the
        // current text on every layout. The editor field is a separate stable
        // interaction surface whose own placement is stored in document
        // coordinates, so content changes and temporary canvas scaling cannot
        // move it.
        let canonicalAlignmentAnchor = textEditorAlignmentAnchor(
            for: state,
            text: editor.string,
            layout: textEditorLayoutPayload
        )
        let desiredLineOrigin = renderedTextLineOriginInView(
            state: state,
            text: editor.string,
            layout: textEditorLayoutPayload
        )
        let fieldPlacementAnchor = textEditorFieldPlacementAnchorInDocument.map {
            viewPoint(fromDocumentPoint: $0)
        } ?? canonicalAlignmentAnchor
        let stableFieldFrame = resolvedTextFieldFrame(
            alignmentAnchor: fieldPlacementAnchor,
            font: font,
            preferredViewportWidth: preferredViewportWidth,
            availableFieldBounds: availableFieldBounds,
            alignment: state.style.textAlignment,
            lineCount: lineCount,
            layoutPlan: layoutPlan,
            layoutPayload: presentationLayoutPayload,
            state: state
        )
        if textEditorFieldPlacementAnchorInDocument == nil {
            let resolvedFieldAnchor = textFieldAlignmentAnchor(
                for: stableFieldFrame,
                font: font,
                alignment: state.style.textAlignment,
                lineCount: lineCount,
                layoutPlan: layoutPlan,
                layoutPayload: presentationLayoutPayload,
                state: state
            )
            textEditorFieldPlacementAnchorInDocument = documentPoint(
                fromViewPoint: resolvedFieldAnchor
            )
        }
        let outerFrame = stableFieldFrame.insetBy(dx: -chromeOutset, dy: -chromeOutset)
        let localFieldFrame = CGRect(
            x: chromeOutset,
            y: chromeOutset,
            width: stableFieldFrame.width,
            height: stableFieldFrame.height
        )
        let chromeInsets = AnnotationTextLayout.chromeInsets(for: state.chromeMode)
        let textContainerInset = CGSize(
            width: chromeInsets.width + presentationLayoutPayload.leadingOverhang,
            height: chromeInsets.height
        )
        let minimumCanonicalDocumentSize = CGSize(
            width: textEditorFieldWidthInDocument(
                fromViewWidth: stableFieldFrame.width,
                state: state
            ),
            height: textEditorFieldHeightInDocument(
                fromViewHeight: stableFieldFrame.height,
                state: state
            )
        )
        let completeSemanticDocumentWidth = chromeInsets.width * 2
            + presentationLayoutPayload.leadingOverhang
            + semanticWrapWidth
            + presentationLayoutPayload.trailingOverhang
        let canonicalDocumentSize = CGSize(
            width: max(
                textEditorPresentationLayout?.canonicalDocumentSize.width ?? 0,
                max(
                    minimumCanonicalDocumentSize.width,
                    completeSemanticDocumentWidth
                )
            ),
            height: minimumCanonicalDocumentSize.height
        )
        let documentSize = textEditorDocumentSizeInView(
            fromCanonicalSize: canonicalDocumentSize,
            state: state
        )
        let configuresGeometry = textEditorPresentationLayout == nil
        if configuresGeometry {
            frameView.frame = outerFrame
            frameView.setFieldFrame(localFieldFrame)
            container.frame = localFieldFrame
            editor.textContainerInset = textContainerInset
            documentView.frame = CGRect(origin: .zero, size: documentSize)
            configureTextEditorDocumentExtent(
                editor: editor,
                documentView: documentView,
                presentationSize: documentSize,
                canonicalSize: canonicalDocumentSize,
                wrapWidth: semanticWrapWidth,
                layoutPayload: presentationLayoutPayload
            )
        } else {
            guard var presentation = textEditorPresentationLayout else {
                preconditionFailure("The inline editor geometry cache disappeared during input.")
            }
            let frameChanged = maxFrameDelta(presentation.frame, outerFrame) > 0.01
            let containerChanged = maxFrameDelta(
                presentation.containerFrame,
                localFieldFrame
            ) > 0.01
            let documentSizeChanged = max(
                abs(presentation.documentSize.width - documentSize.width),
                abs(presentation.documentSize.height - documentSize.height)
            ) > 0.01
            let canonicalDocumentSizeChanged = max(
                abs(
                    presentation.canonicalDocumentSize.width
                        - canonicalDocumentSize.width
                ),
                abs(
                    presentation.canonicalDocumentSize.height
                        - canonicalDocumentSize.height
                )
            ) > 0.01
            let textContainerOriginChanged = max(
                abs(editor.textContainerInset.width - textContainerInset.width),
                abs(editor.textContainerInset.height - textContainerInset.height)
            ) > 0.001
            let geometryChanged = frameChanged
                || containerChanged
                || documentSizeChanged
                || canonicalDocumentSizeChanged
                || textContainerOriginChanged
            if geometryChanged {
                let didWrap = measuredWidth > semanticWrapWidth + 0.01
                AppLog.capture.notice(
                    "Updated inline text field for wrap or growth: lines=\(lineCount, privacy: .public), previous=(\(presentation.frame.width, privacy: .public)x\(presentation.frame.height, privacy: .public)), next=(\(outerFrame.width, privacy: .public)x\(outerFrame.height, privacy: .public)), wrapped=\(didWrap, privacy: .public), characters=\(editor.string.utf16.count, privacy: .public)"
                )
                frameView.frame = outerFrame
                frameView.setFieldFrame(localFieldFrame)
                container.frame = localFieldFrame
                editor.textContainerInset = textContainerInset
                // Reconfiguration operates on the unscrolled canonical
                // document. A visible caret scroll must never be promoted into
                // the next layout generation's base origin.
                documentView.setFrameOrigin(presentation.documentBaseOrigin)
                configureTextEditorDocumentExtent(
                    editor: editor,
                    documentView: documentView,
                    presentationSize: documentSize,
                    canonicalSize: canonicalDocumentSize,
                    wrapWidth: semanticWrapWidth,
                    layoutPayload: presentationLayoutPayload
                )
                presentation = TextEditorPresentationLayout(
                    frame: outerFrame,
                    containerFrame: localFieldFrame,
                    documentBaseOrigin: documentView.frame.origin,
                    documentSize: documentSize,
                    canonicalDocumentSize: canonicalDocumentSize
                )
                textEditorPresentationLayout = presentation
            }
            if !geometryChanged {
                precondition(
                    maxFrameDelta(presentation.frame, outerFrame) < 0.01,
                    "Text input changed the fixed editor frame without a canvas resize."
                )
            }
            let documentSizeDelta = max(
                abs(editor.frame.width - presentation.canonicalDocumentSize.width),
                abs(editor.frame.height - presentation.canonicalDocumentSize.height)
            )
            let hostSizeDelta = max(
                abs(documentView.frame.width - presentation.documentSize.width),
                abs(documentView.frame.height - presentation.documentSize.height)
            )
            let hostBoundsDelta = max(
                abs(
                    documentView.bounds.width
                        - presentation.canonicalDocumentSize.width
                ),
                abs(
                    documentView.bounds.height
                        - presentation.canonicalDocumentSize.height
                )
            )
            precondition(
                hostSizeDelta < 0.01 && hostBoundsDelta < 0.01,
                "The inline text document host changed its presentation frame or canonical bounds during input."
            )
            if documentSizeDelta >= 0.01 {
                AppLog.capture.error(
                    "TextKit mutated canonical inline document geometry: expected=\(presentation.canonicalDocumentSize.width, privacy: .public)x\(presentation.canonicalDocumentSize.height, privacy: .public), actual=\(editor.frame.width, privacy: .public)x\(editor.frame.height, privacy: .public), presentation=\(presentation.documentSize.width, privacy: .public)x\(presentation.documentSize.height, privacy: .public), viewport=\(container.bounds.width, privacy: .public)x\(container.bounds.height, privacy: .public), min=\(editor.minSize.width, privacy: .public)x\(editor.minSize.height, privacy: .public), max=\(editor.maxSize.width, privacy: .public)x\(editor.maxSize.height, privacy: .public)"
                )
                preconditionFailure("TextKit resized the fixed inline document view during input.")
            }
            if !geometryChanged {
                precondition(
                    maxFrameDelta(container.frame, presentation.containerFrame) < 0.01,
                    "TextKit moved the fixed inline viewport during input."
                )
                precondition(
                    abs(documentView.frame.minY - presentation.documentBaseOrigin.y) < 0.01,
                    "Text input moved the document vertically after initial calibration."
                )
            }
            if !geometryChanged,
               (abs(editor.textContainerInset.width - textContainerInset.width) > 0.001
                    || abs(editor.textContainerInset.height - textContainerInset.height) > 0.001)
            {
                editor.textContainerInset = textContainerInset
            }
        }
        guard let textContainer = editor.textContainer,
              let layoutManager = editor.layoutManager
        else {
            preconditionFailure("The inline annotation editor requires a TextKit layout stack.")
        }
        let expectedTextContainerSize = CGSize(
            width: semanticWrapWidth,
            height: max(
                1,
                canonicalDocumentSize.height - textContainerInset.height * 2
            )
        )
        if abs(textContainer.containerSize.width - expectedTextContainerSize.width) > 0.01
            || abs(textContainer.containerSize.height - expectedTextContainerSize.height) > 0.01
        {
            textContainer.containerSize = expectedTextContainerSize
        }
        layoutManager.ensureLayout(for: textContainer)

        let documentWidthFitsViewport = documentSize.width
            <= container.bounds.width + 0.01
        if configuresGeometry {
            alignTextEditorBaseline(
                to: desiredLineOrigin,
                entireLineFits: documentWidthFitsViewport,
                calibratesCanonicalHorizontalOrigin: true
            )
            textEditorGeometryConfigurationCount += 1
            textEditorPresentationLayout = TextEditorPresentationLayout(
                frame: outerFrame,
                containerFrame: container.frame,
                documentBaseOrigin: documentView.frame.origin,
                documentSize: documentSize,
                canonicalDocumentSize: canonicalDocumentSize
            )
        } else {
            // The renderer's alignment anchor is fixed, but the canonical
            // line origin changes with line width for centered and trailing
            // text. Recalibrate the unscrolled document origin on every
            // TextKit layout, including while the line remains overflowed.
            alignTextEditorBaseline(
                to: desiredLineOrigin,
                entireLineFits: documentWidthFitsViewport,
                calibratesCanonicalHorizontalOrigin: true
            )
        }
        guard let presentation = textEditorPresentationLayout else {
            preconditionFailure("The inline editor must be calibrated before scrolling.")
        }
        // Canonical baseline calibration can translate an otherwise narrow
        // host. It fits only when that complete calibrated frame—not merely
        // its width—lies inside the viewport.
        let entireLineFits = presentation.documentBaseOrigin.x >= -0.01
            && presentation.documentBaseOrigin.x
                + presentation.documentSize.width
                <= container.bounds.width + 0.01
        updateTextEditorHorizontalScroll(
            editor: editor,
            container: container,
            documentView: documentView,
            presentation: presentation,
            entireLineFits: entireLineFits,
            scrollsToInsertionPoint: scrollsToInsertionPoint
        )
        alignTextEditorBaseline(
            to: desiredLineOrigin,
            entireLineFits: entireLineFits,
            // The second pass observes the visible, potentially scrolled
            // presentation. It must never reinterpret scrolling as a change
            // to the canonical renderer origin.
            calibratesCanonicalHorizontalOrigin: false
        )
        // Baseline alignment can finalize a different TextKit line fragment
        // for the insertion point. Re-read its explicitly converted document
        // coordinate once and apply the same bounded scroll policy so a
        // fractional transform cannot leave it beyond the viewport.
        guard let postAlignmentPresentation = textEditorPresentationLayout else {
            preconditionFailure("Inline text alignment lost its calibrated document mapping.")
        }
        updateTextEditorHorizontalScroll(
            editor: editor,
            container: container,
            documentView: documentView,
            presentation: postAlignmentPresentation,
            entireLineFits: entireLineFits,
            scrollsToInsertionPoint: scrollsToInsertionPoint
        )
        textEditorRendererGeneration = TextEditorRendererGeneration(
            text: editor.string,
            style: state.style,
            payload: presentationLayoutPayload
        )
        AppLog.capture.debug(
            "Laid out stable inline text frame: outer=(\(outerFrame.minX, privacy: .public),\(outerFrame.minY, privacy: .public),\(outerFrame.width, privacy: .public),\(outerFrame.height, privacy: .public)), field=(\(stableFieldFrame.minX, privacy: .public),\(stableFieldFrame.minY, privacy: .public),\(stableFieldFrame.width, privacy: .public),\(stableFieldFrame.height, privacy: .public)), canonicalLineWidth=\(measuredWidth, privacy: .public), canonicalWrapWidth=\(semanticWrapWidth, privacy: .public), viewportWidth=\(preferredViewportWidth, privacy: .public), presentationDocumentWidth=\(documentSize.width, privacy: .public), canonicalDocumentWidth=\(canonicalDocumentSize.width, privacy: .public), scrollable=\(!entireLineFits, privacy: .public), geometryConfigurations=\(self.textEditorGeometryConfigurationCount, privacy: .public), characters=\(editor.string.utf16.count, privacy: .public)"
        )
    }

    private func configureTextEditorDocumentExtent(
        editor: InlineAnnotationTextView,
        documentView: NSView,
        presentationSize: CGSize,
        canonicalSize: CGSize,
        wrapWidth: CGFloat,
        layoutPayload: AnnotationTextLayoutPayload
    ) {
        guard let state = textEditingState else {
            preconditionFailure("Inline text extent configuration requires its layout owner.")
        }
        let chromeInsets = AnnotationTextLayout.chromeInsets(for: state.chromeMode)
        let horizontalMargins = (
            leading: chromeInsets.width + layoutPayload.leadingOverhang,
            trailing: chromeInsets.width + layoutPayload.trailingOverhang
        )
        precondition(
            wrapWidth.isFinite && wrapWidth > 0
                && wrapWidth
                    + horizontalMargins.leading
                    + horizontalMargins.trailing <= canonicalSize.width + 0.01,
            "The canonical inline text document must contain its semantic wrap width."
        )
        precondition(
            presentationSize.width.isFinite
                && presentationSize.height.isFinite
                && presentationSize.width > 0
                && presentationSize.height > 0
                && canonicalSize.width.isFinite
                && canonicalSize.height.isFinite
                && canonicalSize.width > 0
                && canonicalSize.height > 0,
            "Inline text host mapping requires finite positive frame and bounds sizes."
        )
        documentView.setFrameSize(presentationSize)
        documentView.bounds = CGRect(origin: .zero, size: canonicalSize)
        editor.minSize = .zero
        editor.maxSize = canonicalSize
        editor.lockDocumentFrame(CGRect(origin: .zero, size: canonicalSize))
        editor.minSize = canonicalSize
        editor.textContainer?.containerSize = CGSize(
            width: wrapWidth,
            height: max(
                1,
                canonicalSize.height - chromeInsets.height * 2
            )
        )
    }

    private func updateTextEditorHorizontalScroll(
        editor: NSTextView,
        container: NSView,
        documentView: NSView,
        presentation: TextEditorPresentationLayout,
        entireLineFits: Bool,
        scrollsToInsertionPoint: Bool
    ) {
        var horizontalOffset = presentation.documentBaseOrigin.x - documentView.frame.minX
        guard let state = textEditingState else {
            preconditionFailure("Inline text scrolling requires its layout owner.")
        }
        let horizontalInset = textEditorChromeInsetsInView(for: state).width
        if entireLineFits {
            horizontalOffset = 0
        } else if scrollsToInsertionPoint,
                  let insertionX = textEditorInsertionX(editor)
        {
            let minimumVisibleX = horizontalInset
            let maximumVisibleX = max(
                minimumVisibleX,
                container.bounds.width - horizontalInset
            )
            let visibleInsertionX = presentation.documentBaseOrigin.x
                - horizontalOffset
                + insertionX
            if visibleInsertionX > maximumVisibleX {
                horizontalOffset += visibleInsertionX - maximumVisibleX
            } else if visibleInsertionX < minimumVisibleX {
                horizontalOffset -= minimumVisibleX - visibleInsertionX
            }
        }
        // The canonical document origin may be asymmetric relative to the
        // viewport when the field itself is clamped at a canvas edge. Derive
        // both scroll limits from that calibrated origin, rather than assuming
        // leading/center/trailing always means 0, 1/2 or all of the overflow.
        let minimumOffset: CGFloat
        let maximumOffset: CGFloat
        if entireLineFits {
            minimumOffset = 0
            maximumOffset = 0
        } else {
            let leftEdgeOffset = presentation.documentBaseOrigin.x
            let rightEdgeOffset = presentation.documentBaseOrigin.x
                + presentation.documentSize.width
                - container.bounds.width
            minimumOffset = min(leftEdgeOffset, rightEdgeOffset)
            maximumOffset = max(leftEdgeOffset, rightEdgeOffset)
        }
        horizontalOffset = min(max(minimumOffset, horizontalOffset), maximumOffset)
        let backingScale = max(1, window?.backingScaleFactor ?? 1)
        horizontalOffset = (horizontalOffset * backingScale).rounded() / backingScale
        horizontalOffset = min(max(minimumOffset, horizontalOffset), maximumOffset)
        let newOrigin = CGPoint(
            x: presentation.documentBaseOrigin.x - horizontalOffset,
            y: presentation.documentBaseOrigin.y
        )
        if max(
            abs(documentView.frame.minX - newOrigin.x),
            abs(documentView.frame.minY - newOrigin.y)
        ) > 0.001 {
            documentView.setFrameOrigin(newOrigin)
            AppLog.capture.debug(
                "Updated deterministic inline text scroll: horizontalOffset=\(horizontalOffset, privacy: .public), insertionVisible=\(scrollsToInsertionPoint, privacy: .public)"
            )
        }
    }

    private func restoreTextEditorCanonicalHorizontalOriginForCommit() {
        guard let documentView = textEditorDocumentView,
              let presentation = textEditorPresentationLayout
        else {
            preconditionFailure(
                "Committing inline text requires its calibrated presentation geometry."
            )
        }
        let horizontalOffset = presentation.documentBaseOrigin.x - documentView.frame.minX
        guard abs(horizontalOffset) > 0.001 else { return }
        documentView.setFrameOrigin(presentation.documentBaseOrigin)
        AppLog.capture.debug(
            "Restored inline text canonical origin before commit: previousHorizontalOffset=\(horizontalOffset, privacy: .public)"
        )
    }

    private func isInlineTextHardBreakUTF16Unit(_ unit: unichar) -> Bool {
        switch unit {
        case 0x000A, 0x000B, 0x000C, 0x000D, 0x0085, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    private func textEditorInsertionX(_ editor: NSTextView) -> CGFloat? {
        guard let textStorage = editor.textStorage,
              let textContainer = editor.textContainer,
              let layoutManager = editor.layoutManager,
              let container = textEditorContainer,
              let documentView = textEditorDocumentView
        else { return nil }
        let characterLocation = min(editor.selectedRange().location, textStorage.length)
        layoutManager.ensureLayout(for: textContainer)
        let insertionXInTextContainer: CGFloat
        let nsText = editor.string as NSString
        let terminatesWithHardBreak: Bool
        if textStorage.length > 0 {
            let finalUTF16Unit = nsText.character(at: textStorage.length - 1)
            terminatesWithHardBreak = isInlineTextHardBreakUTF16Unit(
                finalUTF16Unit
            )
        } else {
            terminatesWithHardBreak = false
        }
        if textStorage.length == 0
            || (characterLocation == textStorage.length && terminatesWithHardBreak)
        {
            insertionXInTextContainer = layoutManager.extraLineFragmentUsedRect.minX
        } else {
            let lineProbeCharacter = min(characterLocation, textStorage.length - 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineProbeCharacter)
            let lineFragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            var positions = [CGFloat](repeating: 0, count: textStorage.length + 1)
            var characterIndexes = [Int](repeating: 0, count: textStorage.length + 1)
            let insertionPointCount = positions.withUnsafeMutableBufferPointer { positionsBuffer in
                characterIndexes.withUnsafeMutableBufferPointer { characterIndexesBuffer in
                    layoutManager.getLineFragmentInsertionPoints(
                        forCharacterAt: lineProbeCharacter,
                        alternatePositions: false,
                        inDisplayOrder: false,
                        positions: positionsBuffer.baseAddress,
                        characterIndexes: characterIndexesBuffer.baseAddress
                    )
                }
            }
            guard let insertionPointIndex = characterIndexes[..<insertionPointCount]
                .firstIndex(of: characterLocation)
            else {
                preconditionFailure(
                    "TextKit did not expose the active inline insertion point in its line fragment."
                )
            }
            insertionXInTextContainer = lineFragment.minX
                + positions[insertionPointIndex]
        }
        let editorInsertionPoint = CGPoint(
            x: editor.textContainerOrigin.x + insertionXInTextContainer,
            y: editor.textContainerOrigin.y
        )
        let caretInViewport = container.convert(
            editorInsertionPoint,
            from: editor
        )
        let presentationLocalX = caretInViewport.x - documentView.frame.minX
        precondition(
            presentationLocalX.isFinite,
            "Inline text caret conversion produced a non-finite presentation coordinate."
        )
        return presentationLocalX
    }

    private var isRegionConfirmationCanvas: Bool {
        onRegionSelectionDoubleClickCopy != nil
    }

    private func screenPoint(from event: NSEvent) -> CGPoint {
        if let window = event.window {
            return window.convertToScreen(
                CGRect(origin: event.locationInWindow, size: .zero)
            ).origin
        }
        return NSEvent.mouseLocation
    }

    @discardableResult
    private func armRegionDoubleClickCopyIfNeeded(from event: NSEvent) -> Bool {
        guard recognizesRegionDoubleClick(from: event) else { return false }
        pendingRegionDoubleClickCopy = true
        lastEmptyRegionClick = nil
        // A recognized second click is still the beginning of an ordinary
        // Select-body press until its pointer-up commits the copy. Retain the
        // original down event so crossing the move threshold can cancel the
        // copy candidate and enter the same region-move lifecycle without a
        // dead press or a synthetic replacement event.
        pendingRegionBodyMoveMouseDown = event
        regionBodyMoveStartScreenPoint = screenPoint(from: event)
        regionBodyMoveHasDragged = false
        startPoint = nil
        currentPoint = nil
        AppLog.capture.notice(
            "Armed region confirmation double-click copy for pointer-up: clickCount=\(event.clickCount, privacy: .public), tool=\(self.session.currentTool.rawValue, privacy: .public)"
        )
        return true
    }

    @discardableResult
    private func finishRegionDoubleClickCopyIfNeeded(from event: NSEvent) -> Bool {
        let wasArmed = pendingRegionDoubleClickCopy
        let recognizedOnRelease = recognizesRegionDoubleClick(from: event)
        guard wasArmed || recognizedOnRelease else { return false }
        guard !regionBodyMoveHasDragged, !isWindowDragInProgress else {
            AppLog.capture.notice(
                "Ignored region confirmation double-click copy because the press became a move: clickCount=\(event.clickCount, privacy: .public)"
            )
            pendingRegionDoubleClickCopy = false
            lastEmptyRegionClick = nil
            return false
        }
        pendingRegionDoubleClickCopy = false
        lastEmptyRegionClick = nil
        pendingRegionBodyMoveMouseDown = nil
        regionBodyMoveStartScreenPoint = nil
        regionBodyMoveHasDragged = false
        finishWindowDragIfNeeded(reason: "region-double-click-copy")
        _ = endSelectionInteractionLifecycle(reason: "region-double-click-copy")
        startPoint = nil
        currentPoint = nil
        let documentPoint = documentPoint(
            fromViewPoint: convert(event.locationInWindow, from: nil)
        )
        AppLog.capture.notice(
            "Region confirmation double-click requested copy: clickCount=\(event.clickCount, privacy: .public), armed=\(wasArmed, privacy: .public), recognizedOnRelease=\(recognizedOnRelease, privacy: .public), tool=\(self.session.currentTool.rawValue, privacy: .public), x=\(documentPoint.x, privacy: .public), y=\(documentPoint.y, privacy: .public)"
        )
        onRegionSelectionDoubleClickCopy?()
        return true
    }

    private func recognizesRegionDoubleClick(from event: NSEvent) -> Bool {
        guard isRegionConfirmationCanvas, isAnnotationEditingEnabled else { return false }
        let documentPoint = documentPoint(
            fromViewPoint: convert(event.locationInWindow, from: nil)
        )
        guard shouldCopyRegionOnDoubleClick(at: documentPoint) else {
            if event.clickCount >= 2 {
                AppLog.capture.notice(
                    "Ignored region confirmation double-click because the target was not empty interior: clickCount=\(event.clickCount, privacy: .public), tool=\(self.session.currentTool.rawValue, privacy: .public), x=\(documentPoint.x, privacy: .public), y=\(documentPoint.y, privacy: .public)"
                )
            }
            return false
        }
        let recognizedByClickCount = event.clickCount >= 2
        let recognizedByPairedClick = isPairedEmptyRegionClick(event)
        if recognizedByClickCount || recognizedByPairedClick {
            return true
        }
        if let last = lastEmptyRegionClick {
            let screen = screenPoint(from: event)
            let elapsed = event.timestamp - last.timestamp
            let distance = hypot(
                screen.x - last.screenPoint.x,
                screen.y - last.screenPoint.y
            )
            AppLog.capture.notice(
                "Region confirmation click was not a copy double-click: clickCount=\(event.clickCount, privacy: .public), elapsed=\(elapsed, privacy: .public), distance=\(distance, privacy: .public), interval=\(NSEvent.doubleClickInterval, privacy: .public)"
            )
        }
        return false
    }

    private func isPairedEmptyRegionClick(_ event: NSEvent) -> Bool {
        guard let last = lastEmptyRegionClick else { return false }
        return RegionConfirmationClickPolicy.isPairedClick(
            previousTimestamp: last.timestamp,
            previousScreenPoint: last.screenPoint,
            currentTimestamp: event.timestamp,
            currentScreenPoint: screenPoint(from: event),
            interval: NSEvent.doubleClickInterval
        )
    }

    @discardableResult
    private func beginRegionBodyMoveIfNeeded(with event: NSEvent) -> Bool {
        if isWindowDragInProgress {
            return true
        }
        guard let pending = pendingRegionBodyMoveMouseDown,
              let start = regionBodyMoveStartScreenPoint
        else { return false }
        let current = screenPoint(from: event)
        guard RegionConfirmationClickPolicy.didCrossBodyMoveThreshold(from: start, to: current) else {
            return false
        }
        let distance = hypot(current.x - start.x, current.y - start.y)
        let canceledDoubleClickCopy = pendingRegionDoubleClickCopy
        pendingRegionBodyMoveMouseDown = nil
        regionBodyMoveHasDragged = true
        pendingRegionDoubleClickCopy = false
        lastEmptyRegionClick = nil
        AppLog.capture.debug(
            "Region confirmation body press crossed the move threshold: distance=\(distance, privacy: .public), canceledDoubleClickCopy=\(canceledDoubleClickCopy, privacy: .public)"
        )
        onWindowDragBegan?(pending)
        return isWindowDragInProgress
    }

    private func shouldCopyRegionOnDoubleClick(at point: CGPoint) -> Bool {
        guard onRegionSelectionDoubleClickCopy != nil else { return false }
        guard session.currentTool == .select else { return false }
        guard textEditor == nil, textEditingState == nil else { return false }
        guard selectionInteraction == nil,
              textResizeInteraction == nil,
              selectedTextResizeInteraction == nil
        else { return false }
        if pinnedWindowResizeHandle(at: viewPoint(fromDocumentPoint: point)) != nil {
            return false
        }
        if session.controller.topmostItem(at: point) != nil {
            return false
        }
        return true
    }

    private func topmostEditableText(at point: CGPoint) -> AnnotationItem? {
        session.controller.document.orderedAnnotations.reversed().first {
            $0.kind == .text && !$0.isLocked && hitTester.contains(point, in: $0, tolerance: 6)
        }
    }

    private func textInteractionExceededDragThreshold(from start: CGPoint, to end: CGPoint) -> Bool {
        let viewStart = viewPoint(fromDocumentPoint: start)
        let viewEnd = viewPoint(fromDocumentPoint: end)
        return hypot(viewEnd.x - viewStart.x, viewEnd.y - viewStart.y) >= 4
    }

    private func selectionResizeHasPointerMovement(from start: CGPoint, to end: CGPoint) -> Bool {
        viewPoint(fromDocumentPoint: start) != viewPoint(fromDocumentPoint: end)
    }

    private func maxFrameDelta(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(
            max(abs(lhs.minX - rhs.minX), abs(lhs.minY - rhs.minY)),
            max(abs(lhs.width - rhs.width), abs(lhs.height - rhs.height))
        )
    }

    private func textEditorGeometryDescription(_ editor: NSTextView) -> String {
        guard let frameView = textEditorFrameView,
              let container = textEditorContainer,
              let documentView = textEditorDocumentView
        else { return "missing" }
        return "canvasBounds=\(bounds), canvasFrame=\(frame), field=\(frameView.frame), viewport=\(container.frame), viewportBounds=\(container.bounds), documentFrame=\(documentView.frame), documentBounds=\(documentView.bounds), editorDocumentFrame=\(editor.frame), textContainerOrigin=\(editor.textContainerOrigin), windowFrame=\(window?.frame ?? .zero)"
    }

    private func textEditorAlignmentAnchor(
        for state: TextEditingState,
        text: String,
        layout: AnnotationTextLayoutPayload?
    ) -> CGPoint {
        let resolvedLayout = layout
        let annotationRect: CGRect
        if let resolvedLayout {
            annotationRect = AnnotationTextLayout.annotationRect(
                baselineAnchor: state.anchor,
                text: text,
                style: state.style,
                layout: resolvedLayout
            )
        } else if let originalItem = state.originalItem,
                  case .rect(let originalRect) = originalItem.geometry
        {
            annotationRect = originalRect.standardized
        } else {
            preconditionFailure("Inline text alignment requires explicit layout ownership.")
        }
        return viewPoint(fromDocumentPoint: transformedPoint(
            state.anchor,
            transform: state.transform,
            around: annotationRect
        ))
    }

    private func renderedTextLineOriginInView(
        state: TextEditingState,
        text: String,
        layout: AnnotationTextLayoutPayload?
    ) -> CGPoint {
        guard let firstLine = renderedTextLineSnapshotsInView(
            state: state,
            text: text,
            layout: layout
        ).first else {
            preconditionFailure("Inline text rendering requires at least one canonical line.")
        }
        return firstLine.originInView
    }

    private func renderedTextLineSnapshotsInView(
        state: TextEditingState,
        text: String,
        layout: AnnotationTextLayoutPayload?
    ) -> [InlineTextEditorLineSnapshot] {
        let resolvedLayout = layout
        let annotationRect: CGRect
        if let resolvedLayout {
            annotationRect = AnnotationTextLayout.annotationRect(
                baselineAnchor: state.anchor,
                text: text,
                style: state.style,
                layout: resolvedLayout
            )
        } else if let originalItem = state.originalItem,
                  case .rect(let originalRect) = originalItem.geometry
        {
            annotationRect = originalRect.standardized
        } else {
            preconditionFailure("Inline text rendering requires explicit layout ownership.")
        }
        return AnnotationTextLayout.placedLines(
            in: annotationRect,
            text: text,
            style: state.style,
            layout: resolvedLayout
        ).map { placedLine in
            InlineTextEditorLineSnapshot(
                utf16Range: placedLine.line.utf16Range,
                consumedUTF16Range: placedLine.line.consumedUTF16Range,
                originInView: viewPoint(fromDocumentPoint: transformedPoint(
                    placedLine.origin,
                    transform: state.transform,
                    around: annotationRect
                ))
            )
        }
    }

    private func textEditorLineSnapshotsInView(
        _ editor: NSTextView
    ) -> [InlineTextEditorLineSnapshot] {
        guard let textContainer = editor.textContainer,
              let layoutManager = editor.layoutManager
        else {
            preconditionFailure("Inline text line inspection requires its TextKit stack.")
        }
        layoutManager.ensureLayout(for: textContainer)
        let nsText = editor.string as NSString
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var snapshots: [InlineTextEditorLineSnapshot] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { lineFragmentRect, usedRect, _, lineGlyphRange, _ in
            let consumedRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            var drawableRange = consumedRange
            while drawableRange.length > 0 {
                let finalUTF16Unit = nsText.character(at: NSMaxRange(drawableRange) - 1)
                guard self.isInlineTextHardBreakUTF16Unit(finalUTF16Unit) else {
                    break
                }
                drawableRange.length -= 1
            }
            let baselineLocation = lineGlyphRange.length > 0
                ? layoutManager.location(forGlyphAt: lineGlyphRange.location)
                : usedRect.origin
            snapshots.append(InlineTextEditorLineSnapshot(
                utf16Range: drawableRange,
                consumedUTF16Range: consumedRange,
                originInView: editor.convert(
                    CGPoint(
                        // Match the canonical plan's visual line origin. The
                        // first logical glyph can live at the opposite edge of
                        // an RTL or mixed-direction fragment.
                        x: editor.textContainerOrigin.x + usedRect.minX,
                        y: editor.textContainerOrigin.y
                            + lineFragmentRect.minY
                            + baselineLocation.y
                    ),
                    to: self
                )
            ))
        }
        let terminatesWithHardBreak = nsText.length > 0
            && isInlineTextHardBreakUTF16Unit(
                nsText.character(at: nsText.length - 1)
            )
        if editor.string.isEmpty || terminatesWithHardBreak {
            guard let stableBaselineOffset = textEditorSessionBaselineOffset else {
                preconditionFailure(
                    "Inline text extra-line inspection requires a canonical baseline offset."
                )
            }
            let emptyRange = NSRange(location: nsText.length, length: 0)
            snapshots.append(InlineTextEditorLineSnapshot(
                utf16Range: emptyRange,
                consumedUTF16Range: emptyRange,
                originInView: editor.convert(
                    CGPoint(
                        x: editor.textContainerOrigin.x
                            + layoutManager.extraLineFragmentUsedRect.minX,
                        y: editor.textContainerOrigin.y
                            + layoutManager.extraLineFragmentRect.minY
                            + stableBaselineOffset
                    ),
                    to: self
                )
            ))
        }
        return snapshots
    }

    private func assertTextEditorLinesMatchRenderer(
        _ editor: NSTextView,
        state: TextEditingState,
        layout: AnnotationTextLayoutPayload?,
        canonicalHorizontalOffset: CGFloat = 0,
        context: String
    ) {
        let editorLines = textEditorLineSnapshotsInView(editor)
        let renderedLines = renderedTextLineSnapshotsInView(
            state: state,
            text: editor.string,
            layout: layout
        )
        precondition(
            editorLines.count == renderedLines.count,
            "Inline text line count diverged from the canonical renderer during \(context): editor=\(editorLines.count), renderer=\(renderedLines.count)."
        )
        for (index, pair) in zip(editorLines, renderedLines).enumerated() {
            let (editorLine, renderedLine) = pair
            precondition(
                NSEqualRanges(editorLine.utf16Range, renderedLine.utf16Range)
                    && NSEqualRanges(
                        editorLine.consumedUTF16Range,
                        renderedLine.consumedUTF16Range
                    ),
                "Inline text line \(index) range diverged from the canonical renderer during \(context): editor=\(editorLine.utf16Range)/\(editorLine.consumedUTF16Range), renderer=\(renderedLine.utf16Range)/\(renderedLine.consumedUTF16Range)."
            )
            precondition(
                hypot(
                    editorLine.originInView.x
                        + canonicalHorizontalOffset
                        - renderedLine.originInView.x,
                    editorLine.originInView.y - renderedLine.originInView.y
                ) < 0.01,
                "Inline text line \(index) origin diverged from the canonical renderer during \(context): editor=\(editorLine.originInView), renderer=\(renderedLine.originInView)."
            )
        }
    }

    private func alignTextEditorBaseline(
        to desiredLineOrigin: CGPoint,
        entireLineFits: Bool,
        calibratesCanonicalHorizontalOrigin: Bool
    ) {
        guard let editor = textEditor,
              let documentView = textEditorDocumentView,
              let actualLineOrigin = textEditorLineOriginInView(editor)
        else { return }
        let documentOriginBeforeAlignment = documentView.frame.origin
        var performedCanonicalHorizontalCalibration = false

        if calibratesCanonicalHorizontalOrigin {
            // actualLineOrigin includes the current horizontal scroll. The
            // renderer invariant applies to the unscrolled document base, so
            // remove that scroll before comparing TextKit with Core Text:
            // canonicalActual = visibleActual + (baseOrigin - visibleOrigin).
            let horizontalScrollOffset = textEditorPresentationLayout.map {
                $0.documentBaseOrigin.x - documentView.frame.minX
            } ?? 0
            let canonicalActualLineOriginX = actualLineOrigin.x + horizontalScrollOffset
            let horizontalCorrection = desiredLineOrigin.x - canonicalActualLineOriginX
            let appliedHorizontalCorrection: CGFloat
            if abs(horizontalCorrection) > 0.01 {
                // TextKit rounds textContainerOrigin to whole layout points.
                // Preserve the renderer's fractional baseline by moving the
                // stable document host once instead of accumulating an
                // ineffective inset correction on every input callback.
                documentView.frame.origin.x += horizontalCorrection
                appliedHorizontalCorrection = horizontalCorrection
            } else {
                appliedHorizontalCorrection = 0
            }
            performedCanonicalHorizontalCalibration = true
            if let presentation = textEditorPresentationLayout {
                textEditorPresentationLayout = TextEditorPresentationLayout(
                    frame: presentation.frame,
                    containerFrame: presentation.containerFrame,
                    documentBaseOrigin: CGPoint(
                        x: presentation.documentBaseOrigin.x + appliedHorizontalCorrection,
                        y: presentation.documentBaseOrigin.y
                    ),
                    documentSize: presentation.documentSize,
                    canonicalDocumentSize: presentation.canonicalDocumentSize
                )
            }
        }

        guard let horizontallyAlignedOrigin = textEditorLineOriginInView(editor) else { return }
        let verticalCorrection = desiredLineOrigin.y - horizontallyAlignedOrigin.y
        if abs(verticalCorrection) > 0.005 {
            documentView.frame.origin.y += verticalCorrection
            if let presentation = textEditorPresentationLayout {
                textEditorPresentationLayout = TextEditorPresentationLayout(
                    frame: presentation.frame,
                    containerFrame: presentation.containerFrame,
                    documentBaseOrigin: CGPoint(
                        x: presentation.documentBaseOrigin.x,
                        y: presentation.documentBaseOrigin.y + verticalCorrection
                    ),
                    documentSize: presentation.documentSize,
                    canonicalDocumentSize: presentation.canonicalDocumentSize
                )
            }
            if textEditorGeometryConfigurationCount > 0 {
                textEditorBaselineCorrectionCount += 1
                let message = "Corrected inline text fallback baseline: dy=\(verticalCorrection), font=\(self.textEditorSessionFont?.fontName ?? "missing"), markedText=\(editor.hasMarkedText()), characters=\(editor.string.utf16.count), corrections=\(self.textEditorBaselineCorrectionCount)"
                if textResizeInteraction == nil {
                    AppLog.capture.notice("\(message, privacy: .public)")
                } else {
                    AppLog.capture.debug("\(message, privacy: .public)")
                }
            }
        }

        let documentDelta = CGPoint(
            x: documentView.frame.origin.x - documentOriginBeforeAlignment.x,
            y: documentView.frame.origin.y - documentOriginBeforeAlignment.y
        )
        if textEditorGeometryConfigurationCount > 0,
           textResizeInteraction == nil,
           !performedCanonicalHorizontalCalibration,
           abs(documentDelta.x) > 0.005
        {
            textEditorPostConfigurationViewportMutationCount += 1
            AppLog.capture.notice(
                "Inline text document moved horizontally during post-configuration alignment: dx=\(documentDelta.x, privacy: .public), markedText=\(editor.hasMarkedText(), privacy: .public), mutations=\(self.textEditorPostConfigurationViewportMutationCount, privacy: .public)"
            )
        }

        guard let finalLineOrigin = textEditorLineOriginInView(editor) else { return }
        let measuredError = CGPoint(
            x: desiredLineOrigin.x - finalLineOrigin.x,
            y: desiredLineOrigin.y - finalLineOrigin.y
        )
        let error = CGPoint(
            x: abs(measuredError.x) < 0.005 ? 0 : measuredError.x,
            y: abs(measuredError.y) < 0.005 ? 0 : measuredError.y
        )
        textEditorBaselineError = error
        let fontName = textEditorSessionFont?.fontName ?? "missing"
        let message = "Measured inline text baseline: desired=(\(desiredLineOrigin.x),\(desiredLineOrigin.y)), actual=(\(finalLineOrigin.x),\(finalLineOrigin.y)), error=(\(error.x),\(error.y)), font=\(fontName), canonicalHorizontalCalibration=\(calibratesCanonicalHorizontalOrigin)"
        let visibleDrift = max(
            entireLineFits ? abs(error.x) : 0,
            abs(error.y)
        )
        if !calibratesCanonicalHorizontalOrigin, visibleDrift > 0.005 {
            textEditorPostConfigurationLineOriginDriftCount += 1
            AppLog.capture.error("\(message, privacy: .public)")
        } else {
            AppLog.capture.debug("\(message, privacy: .public)")
        }
    }

    private func textEditorLineOriginInView(
        _ editor: NSTextView
    ) -> CGPoint? {
        guard textEditorSessionFont != nil,
              let stableBaselineOffset = textEditorSessionBaselineOffset,
              let textContainer = editor.textContainer,
              let layoutManager = editor.layoutManager
        else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let location: CGPoint
        if glyphRange.length > 0 {
            let baselineLocation = layoutManager.location(
                forGlyphAt: glyphRange.location
            )
            let lineFragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let usedRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            location = CGPoint(
                x: usedRect.minX,
                y: lineFragmentRect.minY + baselineLocation.y
            )
        } else {
            location = CGPoint(
                x: 0,
                // Empty NSTextView layout uses defaultBaselineOffset(for:),
                // but the first real line can differ by a full point once a
                // fixed paragraph line height is applied. Calibrate the empty
                // caret from a real reference glyph so the first keystroke
                // cannot move the baseline.
                y: stableBaselineOffset
            )
        }
        return editor.convert(
            CGPoint(
                x: editor.textContainerOrigin.x + location.x,
                y: editor.textContainerOrigin.y + location.y
            ),
            to: self
        )
    }

    private func stableTextEditorBaselineOffset(
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        lineHeight: CGFloat
    ) throws -> CGFloat {
        guard let baselineOffset = measuredStableTextEditorBaselineOffset(
            font: font,
            paragraphStyle: paragraphStyle,
            lineHeight: lineHeight
        ) else {
            throw inlineTextKitEditingCapabilityError(
                "baseline calibration did not produce exactly one finite reference glyph"
            )
        }
        return baselineOffset
    }

    private func measuredStableTextEditorBaselineOffset(
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        lineHeight: CGFloat
    ) -> CGFloat? {
        let storage = NSTextStorage(
            string: "M",
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: 100, height: lineHeight))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 1
        textContainer.lineBreakMode = .byClipping
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length == 1 else { return nil }
        let baselineOffset = layoutManager.location(
            forGlyphAt: glyphRange.location
        ).y
        return baselineOffset.isFinite && baselineOffset >= 0
            ? baselineOffset
            : nil
    }

    private func annotationColor(_ color: RGBAColor) -> NSColor {
        switch color.colorSpace {
        case .displayP3:
            return NSColor(
                displayP3Red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
        case .sRGB, .genericRGB, .adobeRGB1998:
            return NSColor(
                srgbRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
        }
    }

    private func transformedPoint(
        _ point: CGPoint,
        transform itemTransform: AnnotationTransform,
        around bounds: CGRect
    ) -> CGPoint {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(
            x: center.x + itemTransform.translation.width,
            y: center.y + itemTransform.translation.height
        )
        transform = transform.rotated(by: itemTransform.rotationRadians)
        transform = transform.scaledBy(x: itemTransform.scaleX, y: itemTransform.scaleY)
        transform = transform.translatedBy(x: -center.x, y: -center.y)
        return point.applying(transform)
    }

    private func copySelectionOrImage() {
        let selected = session.controller.document.orderedAnnotations.filter {
            session.controller.selectedItemIDs.contains($0.id)
        }
        if selected.isEmpty {
            onCopyFinalImage?()
        } else {
            copiedItems = selected
        }
    }

    private func pasteCopiedItems() {
        guard !copiedItems.isEmpty else { return }
        var pastedIDs: Set<UUID> = []
        for original in copiedItems {
            let id = UUID()
            pastedIDs.insert(id)
            var transform = original.transform
            transform.translation.width += 10
            transform.translation.height -= 10
            session.controller.add(AnnotationItem(
                id: id,
                name: original.name + " Copy",
                kind: original.kind,
                zIndex: session.controller.document.annotations.count,
                geometry: original.geometry,
                style: original.style,
                opacity: original.opacity,
                transform: transform,
                isVisible: original.isVisible,
                isLocked: false,
                text: original.text,
                textLayout: original.textLayout,
                counterValue: original.counterValue
            ))
        }
        session.controller.selectedItemIDs = pastedIDs
    }

    private func drawExcludedAnnotations() {
        var excludedIDs = session.renderedPreviewExcludedAnnotationIDs
        let renderedItemIDs = Set(session.renderedPreviewDocument?.annotations.map(\.id) ?? [])
        for selectedID in session.controller.selectedItemIDs where !renderedItemIDs.contains(selectedID) {
            excludedIDs.insert(selectedID)
        }
        guard !excludedIDs.isEmpty else { return }
        for storedItem in session.controller.document.orderedAnnotations
            where excludedIDs.contains(storedItem.id)
        {
            if storedItem.id == textEditingState?.itemID { continue }
            let item = displayItem(for: storedItem)
            drawInteractiveItem(item)
        }
    }

    private func drawInteractiveDocument() {
        if drawsBaseImage {
            drawScaledScreenshot(
                baseImage,
                sourcePixelSize: session.baseImage.pixelSize
            )
        }
        for storedItem in session.controller.document.orderedAnnotations {
            if storedItem.id == textEditingState?.itemID { continue }
            let item = displayItem(for: storedItem)
            drawInteractiveItem(item)
        }
    }

    /// Nearest-neighbor is correct only for a true two-axis 1:1 mapping.
    /// Every other size uses high-quality interpolation: using `.none` for an
    /// enlarged screenshot or for a width-only match manufactures jagged
    /// edges, while AppKit's implicit default makes reduced previews soft.
    private func drawScaledScreenshot(_ image: NSImage, sourcePixelSize: CGSize) {
        guard let context = NSGraphicsContext.current else {
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            return
        }
        let previousInterpolation = context.imageInterpolation
        defer { context.imageInterpolation = previousInterpolation }
        let decision = ScreenshotSamplingPolicy.decision(
            sourcePixelSize: sourcePixelSize,
            destinationPixelSize: convertToBacking(bounds).size
        )
        context.imageInterpolation = decision.usesNearestNeighbor ? .none : .high
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    private func reportTextLayoutAuthoringFailure(
        _ error: Error,
        operation: String,
        itemID: UUID? = nil
    ) {
        let nsError = error as NSError
        let fingerprint = "\(type(of: error))|\(nsError.domain)|\(nsError.code)|\(nsError.localizedDescription)"
        guard fingerprint != lastTextLayoutAuthoringFailureFingerprint else { return }
        lastTextLayoutAuthoringFailureFingerprint = fingerprint
        AppLog.capture.error(
            "Rejected text layout before document mutation: operation=\(operation, privacy: .public), id=\(itemID?.uuidString ?? "none", privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
        )
        NSSound.beep()
        DispatchQueue.main.async { [weak self, nsError] in
            self?.session.onError?(nsError)
        }
    }

    private func clearTextLayoutAuthoringFailure() {
        lastTextLayoutAuthoringFailureFingerprint = nil
    }

    private func reportVectorRenderFailure(
        _ error: Error,
        item: AnnotationItem,
        isProvisional: Bool,
        operation: String = "render"
    ) {
        let nsError = error as NSError
        let shouldReport: Bool
        if isProvisional {
            let fingerprint = "\(type(of: error))|\(nsError.domain)|\(nsError.code)|\(nsError.localizedDescription)"
            shouldReport = reportedProvisionalVectorRenderFailureDescriptions
                .insert(fingerprint).inserted
        } else if reportedVectorRenderFailureItems[item.id] == item {
            shouldReport = false
        } else {
            reportedVectorRenderFailureItems[item.id] = item
            shouldReport = true
        }
        guard shouldReport else { return }
        AppLog.capture.error(
            "Annotation vector operation failed: operation=\(operation, privacy: .public), id=\(item.id.uuidString, privacy: .public), kind=\(item.kind.rawValue, privacy: .public), provisional=\(isProvisional, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
        )
        // Never present application UI from inside AppKit's drawing stack.
        DispatchQueue.main.async { [weak self, nsError] in
            self?.session.onError?(nsError)
        }
    }

    private func drawInteractiveItem(_ item: AnnotationItem) {
        guard item.isVisible,
              let colorSpace = session.baseImage.image.colorSpace
                ?? CGColorSpace(name: CGColorSpace.sRGB)
        else { return }
        withDocumentDrawingContext { context in
            let didDrawVector: Bool
            do {
                didDrawVector = try vectorRenderer.draw(
                    item: item,
                    in: context,
                    colorSpace: colorSpace,
                    canvasBounds: visibleDocumentRect()
                )
            } catch {
                reportVectorRenderFailure(
                    error,
                    item: item,
                    isProvisional: false
                )
                return
            }
            if didDrawVector {
                return
            }
            guard case .rect(let rect) = item.geometry else { return }
            let effectImage: CGImage?
            switch item.kind {
            case .blur:
                if let cached = blurredEffectPreview, cached.radius == item.style.blurRadius {
                    effectImage = cached.image
                } else {
                    effectImage = effectRenderer.blurred(
                        session.baseImage.image,
                        radius: item.style.blurRadius
                    )
                    if let effectImage {
                        blurredEffectPreview = (item.style.blurRadius, effectImage)
                    }
                }
            case .mosaic:
                if let cached = mosaicedEffectPreview, cached.blockSize == item.style.mosaicBlockSize {
                    effectImage = cached.image
                } else {
                    effectImage = effectRenderer.mosaiced(
                        session.baseImage.image,
                        blockSize: item.style.mosaicBlockSize
                    )
                    if let effectImage {
                        mosaicedEffectPreview = (item.style.mosaicBlockSize, effectImage)
                    }
                }
            default:
                return
            }
            guard let effectImage else { return }
            context.saveGState()
            applyTransform(item.transform, around: item.geometry.boundingBox, to: context)
            context.clip(to: rect.standardized)
            context.draw(
                effectImage,
                in: CGRect(origin: .zero, size: session.controller.document.canvasSize)
            )
            context.restoreGState()
        }
    }

    private func drawSelection() {
        guard isAnnotationEditingEnabled else { return }
        if startPoint != nil, selectionInteraction == nil { return }
        let accent = NSColor.controlAccentColor
        let selectedItems = selectedDisplayItems()
        guard selectedItems.count == 1,
              let item = selectedItems.first,
              item.id != textEditingState?.itemID
        else { return }
        for handlePoint in selectionGeometry.handlePoints(for: item) {
            let point = viewPoint(fromDocumentPoint: handlePoint.point)
            let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            let handlePath = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            NSColor.windowBackgroundColor.setFill()
            handlePath.fill()
            accent.setStroke()
            handlePath.lineWidth = 1.25
            handlePath.stroke()
        }
    }

    private func drawProvisional() {
        guard let startPoint, let currentPoint, session.currentTool != .select else { return }
        let rect = CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
        let style = style(for: session.currentTool)
        let provisionalItem: AnnotationItem
        switch session.currentTool {
        case .rectangle:
            provisionalItem = AnnotationItem(kind: .rectangle, zIndex: 0, geometry: .rect(rect), style: style)
        case .ellipse:
            provisionalItem = AnnotationItem(kind: .ellipse, zIndex: 0, geometry: .rect(rect), style: style)
        case .line:
            provisionalItem = AnnotationItem(
                kind: .line,
                zIndex: 0,
                geometry: .line(start: startPoint, end: currentPoint),
                style: style
            )
        case .arrow:
            provisionalItem = AnnotationItem(
                kind: .arrow,
                zIndex: 0,
                geometry: .line(start: startPoint, end: currentPoint),
                style: style
            )
        case .freehand:
            provisionalItem = AnnotationItem(
                kind: .freehand,
                zIndex: 0,
                geometry: .path(freehandPoints),
                style: style
            )
        case .highlight:
            provisionalItem = AnnotationItem(kind: .highlight, zIndex: 0, geometry: .rect(rect), style: style)
        case .spotlight:
            drawSpotlightProvisional(rect)
            return
        case .blur, .mosaic:
            drawEffectProvisional(kind: session.currentTool, in: rect, style: style)
            return
        case .crop:
            drawCropProvisional(rect)
            return
        case .text, .counter, .select:
            return
        }

        guard let colorSpace = session.baseImage.image.colorSpace
                ?? CGColorSpace(name: CGColorSpace.sRGB)
        else { return }
        withDocumentDrawingContext { context in
            do {
                _ = try vectorRenderer.draw(
                    item: provisionalItem,
                    in: context,
                    colorSpace: colorSpace,
                    canvasBounds: visibleDocumentRect()
                )
            } catch {
                reportVectorRenderFailure(
                    error,
                    item: provisionalItem,
                    isProvisional: true
                )
            }
        }
    }

    private func drawEffectProvisional(
        kind: AnnotationTool,
        in rect: CGRect,
        style: AnnotationStyle
    ) {
        let effectImage: CGImage?
        switch kind {
        case .blur:
            if let cached = blurredEffectPreview, cached.radius == style.blurRadius {
                effectImage = cached.image
            } else {
                let image = effectRenderer.blurred(session.baseImage.image, radius: style.blurRadius)
                if let image {
                    blurredEffectPreview = (style.blurRadius, image)
                }
                effectImage = image
            }
        case .mosaic:
            if let cached = mosaicedEffectPreview, cached.blockSize == style.mosaicBlockSize {
                effectImage = cached.image
            } else {
                let image = effectRenderer.mosaiced(session.baseImage.image, blockSize: style.mosaicBlockSize)
                if let image {
                    mosaicedEffectPreview = (style.mosaicBlockSize, image)
                }
                effectImage = image
            }
        default:
            preconditionFailure("Only blur and mosaic have bitmap provisional effects.")
        }
        guard let effectImage else { return }

        withDocumentDrawingContext { context in
            context.saveGState()
            context.clip(to: rect.standardized)
            context.draw(
                effectImage,
                in: CGRect(origin: .zero, size: session.controller.document.canvasSize)
            )
            context.restoreGState()
        }
    }

    private func drawCropProvisional(_ rect: CGRect) {
        withDocumentDrawingContext { context in
            let canvasRect = CGRect(origin: .zero, size: session.controller.document.canvasSize)
            let outside = CGMutablePath()
            outside.addRect(canvasRect)
            outside.addRect(rect.standardized)
            context.addPath(outside)
            context.setFillColor(CGColor(gray: 0, alpha: 0.48))
            context.drawPath(using: .eoFill)

            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(1.5)
            context.stroke(rect.standardized)
        }
    }

    private func drawSpotlightProvisional(_ rect: CGRect) {
        withDocumentDrawingContext { context in
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect.standardized)
        }
    }

    private func withDocumentDrawingContext(_ drawing: (CGContext) -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let visible = visibleDocumentRect()
        guard visible.width > 0, visible.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scaleX = bounds.width / visible.width
        let scaleY = bounds.height / visible.height
        let documentToView = CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: -visible.minX * scaleX,
            ty: -visible.minY * scaleY
        )
        context.saveGState()
        context.concatenate(documentToView)
        drawing(context)
        context.restoreGState()
    }

    private func applyTransform(
        _ transform: AnnotationTransform,
        around bounds: CGRect,
        to context: CGContext
    ) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.translateBy(
            x: center.x + transform.translation.width,
            y: center.y + transform.translation.height
        )
        context.rotate(by: transform.rotationRadians)
        context.scaleBy(x: transform.scaleX, y: transform.scaleY)
        context.translateBy(x: -center.x, y: -center.y)
    }

    private func selectedDocumentItems() -> [AnnotationItem] {
        session.controller.document.orderedAnnotations.filter {
            session.controller.selectedItemIDs.contains($0.id) && !$0.isLocked
        }
    }

    private func selectedLineWidthEditableItems() -> [AnnotationItem] {
        lineWidthEditableItems(
            document: session.controller.document,
            selectedItemIDs: session.controller.selectedItemIDs
        )
    }

    private func lineWidthEditableItems(
        document: AnnotationDocument,
        selectedItemIDs: Set<UUID>
    ) -> [AnnotationItem] {
        document.orderedAnnotations.filter {
            selectedItemIDs.contains($0.id)
                && !$0.isLocked
                && $0.kind.supportsLineWidthEditing
        }
    }

    private func syncCurrentStyleWithEditorState(
        document: AnnotationDocument,
        selectedItemIDs: Set<UUID>,
        reason: String
    ) {
        guard lineWidthEditingState == nil, textEditingState == nil else { return }

        if let representative = document.orderedAnnotations.first(where: {
            selectedItemIDs.contains($0.id) && !$0.isLocked
        }) {
            let changed = session.currentStyle != representative.style
                || session.currentStyleOrigin != .existingAnnotation
            session.adoptCurrentStyle(representative.style, origin: .existingAnnotation)
            if changed {
                AppLog.capture.debug(
                    "Synchronized annotation toolbar with selection: reason=\(reason, privacy: .public), id=\(representative.id.uuidString, privacy: .public), kind=\(representative.kind.rawValue, privacy: .public), logicalLineWidth=\(representative.style.lineWidth, privacy: .public)"
                )
            }
        } else if session.currentStyleOrigin == .existingAnnotation {
            session.restoreCurrentToolDefaultStyle()
            AppLog.capture.debug(
                "Restored annotation tool defaults after editable selection cleared: reason=\(reason, privacy: .public), tool=\(self.session.currentTool.rawValue, privacy: .public)"
            )
        }
    }

    private func selectedDisplayItems() -> [AnnotationItem] {
        selectedDocumentItems().map(displayItem(for:))
    }

    private func displayItem(for storedItem: AnnotationItem) -> AnnotationItem {
        if let selectedTextResizeInteraction,
           selectedTextResizeInteraction.itemID == storedItem.id
        {
            return selectedTextResizeInteraction.previewItem
        }
        if let preview = lineWidthEditingState?.previewItems[storedItem.id] {
            return preview
        }
        return selectionInteraction?.previewItems[storedItem.id] ?? storedItem
    }

    private func refreshPreviewExclusions(
        document: AnnotationDocument? = nil,
        selectedItemIDs: Set<UUID>? = nil
    ) {
        let document = document ?? session.controller.document
        let selectedItemIDs = selectedItemIDs ?? session.controller.selectedItemIDs
        let validIDs = Set(document.annotations.lazy.compactMap { item in
            selectedItemIDs.contains(item.id) && item.isVisible ? item.id : nil
        })
        session.setPreviewExcludedAnnotationIDs(validIDs, document: document)
    }

    private func selectionHandle(
        at documentPoint: CGPoint,
        for item: AnnotationItem
    ) -> AnnotationSelectionHandle? {
        guard item.kind.allowsUserResize else { return nil }
        let pointer = viewPoint(fromDocumentPoint: documentPoint)
        return selectionGeometry.handlePoints(for: item).first { handlePoint in
            let point = viewPoint(fromDocumentPoint: handlePoint.point)
            return CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                .contains(pointer)
        }?.handle
    }

    private var minimumInteractiveDocumentDimension: CGFloat {
        let visible = visibleDocumentRect()
        let scaleX = bounds.width / max(1, visible.width)
        let scaleY = bounds.height / max(1, visible.height)
        return 6 / max(0.01, min(scaleX, scaleY))
    }

    private var defaultCursor: NSCursor {
        switch session.currentTool {
        case .select: return .arrow
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    private var supportsDirectInteractiveComposition: Bool {
        let document = session.controller.document
        guard document.crop.rect == nil,
              document.rotation.quarterTurnsClockwise == 0
        else { return false }
        // Corner radius alone is presentation/export clipping (layer mask +
        // AnnotationRenderer). It must not force the opaque preview-image path:
        // region confirmation keeps drawsBaseImage=false so the frozen overlay
        // remains the live pixel source while the panel moves or resizes.
        // Shadows still require the full effects composite.
        guard document.canvasEffects.shadow == nil else { return false }
        guard case .transparent = document.background else { return false }
        return true
    }

    private func cursor(for handle: AnnotationSelectionHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .northWest: position = .topLeft
            case .north: position = .top
            case .northEast: position = .topRight
            case .east: position = .right
            case .southEast: position = .bottomRight
            case .south: position = .bottom
            case .southWest: position = .bottomLeft
            case .west: position = .left
            case .lineStart, .lineEnd: return .crosshair
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch handle {
        case .north, .south: return .resizeUpDown
        case .east, .west: return .resizeLeftRight
        case .northWest, .northEast, .southEast, .southWest, .lineStart, .lineEnd:
            return .crosshair
        }
    }

    private func applyCurrentCursor() {
        guard let window else { return }
        applyCursor(for: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func applyCursor(for viewPoint: CGPoint) {
        if isWindowDragInProgress
            || pendingRegionBodyMoveMouseDown != nil
            || (!isAnnotationEditingEnabled && isReadOnlyWindowDragArmed)
        {
            NSCursor.closedHand.set()
            return
        }
        if let activeSelectionInteractionCursor {
            activeSelectionInteractionCursor.set()
            return
        }
        if let resizeHandle = pinnedWindowResizeHandle(at: viewPoint) {
            resizeHandle.cursor.set()
            return
        }
        guard isAnnotationEditingEnabled else {
            NSCursor.openHand.set()
            return
        }
        if selectionInteraction != nil {
            defaultCursor.set()
            return
        }
        let documentPoint = documentPoint(fromViewPoint: viewPoint)
        let selectedItems = selectedDisplayItems()
        if selectedItems.count == 1,
           let item = selectedItems.last,
           let handle = selectionHandle(at: documentPoint, for: item)
        {
            cursor(for: handle).set()
            return
        }
        let selectedIDs = session.controller.selectedItemIDs
        let selectedHit = selectedDisplayItems().reversed().first {
            selectedIDs.contains($0.id) && hitTester.contains(documentPoint, in: $0, tolerance: 6)
        }
        if let selectedHit {
            (selectedHit.kind.allowsUserTranslation ? NSCursor.openHand : defaultCursor).set()
            return
        }
        if session.currentTool == .select,
           let item = session.controller.topmostItem(at: documentPoint)
        {
            (item.kind.allowsUserTranslation ? NSCursor.openHand : defaultCursor).set()
            return
        }
        if session.currentTool == .text,
           topmostEditableText(at: documentPoint) != nil
        {
            NSCursor.openHand.set()
            return
        }
        defaultCursor.set()
    }

    private var pinnedWindowResizeIsAvailable: Bool {
        window?.styleMask.contains(.resizable) == true
    }

    private func pinnedWindowResizeHandle(at point: CGPoint) -> RegionSelectionResizeHandle? {
        guard pinnedWindowResizeIsAvailable, bounds.contains(point) else { return nil }
        let edge = min(
            PinnedWindowCursorMetrics.edgeThickness,
            max(1, min(bounds.width, bounds.height) / 2)
        )
        let corner = min(
            PinnedWindowCursorMetrics.cornerSpan,
            max(edge, min(bounds.width, bounds.height) / 2)
        )
        let nearLeftCorner = point.x <= bounds.minX + corner
        let nearRightCorner = point.x >= bounds.maxX - corner
        // This canvas is flipped, so the visual top edge has the smaller Y value.
        let nearTopCorner = point.y <= bounds.minY + corner
        let nearBottomCorner = point.y >= bounds.maxY - corner
        if nearLeftCorner && nearTopCorner { return .northWest }
        if nearRightCorner && nearTopCorner { return .northEast }
        if nearRightCorner && nearBottomCorner { return .southEast }
        if nearLeftCorner && nearBottomCorner { return .southWest }
        if point.y <= bounds.minY + edge { return .north }
        if point.x >= bounds.maxX - edge { return .east }
        if point.y >= bounds.maxY - edge { return .south }
        if point.x <= bounds.minX + edge { return .west }
        return nil
    }

    private func addOrdinaryPinnedWindowCursorRects(cursor: NSCursor) {
        guard pinnedWindowResizeIsAvailable else {
            addCursorRect(bounds, cursor: cursor)
            return
        }
        let edge = min(
            PinnedWindowCursorMetrics.edgeThickness,
            max(1, min(bounds.width, bounds.height) / 2)
        )
        let corner = min(
            PinnedWindowCursorMetrics.cornerSpan,
            max(edge, min(bounds.width, bounds.height) / 2)
        )
        let cursorRects = [
            CGRect(
                x: bounds.minX + corner,
                y: bounds.minY + edge,
                width: max(0, bounds.width - corner * 2),
                height: max(0, bounds.height - edge * 2)
            ),
            CGRect(
                x: bounds.minX + edge,
                y: bounds.minY + corner,
                width: max(0, corner - edge),
                height: max(0, bounds.height - corner * 2)
            ),
            CGRect(
                x: bounds.maxX - corner,
                y: bounds.minY + corner,
                width: max(0, corner - edge),
                height: max(0, bounds.height - corner * 2)
            )
        ]
        for rect in cursorRects where !rect.isEmpty {
            addCursorRect(rect, cursor: cursor)
        }
    }

    private func addPinnedWindowResizeCursorRects() {
        guard pinnedWindowResizeIsAvailable else { return }
        let edge = min(
            PinnedWindowCursorMetrics.edgeThickness,
            max(1, min(bounds.width, bounds.height) / 2)
        )
        let corner = min(
            PinnedWindowCursorMetrics.cornerSpan,
            max(edge, min(bounds.width, bounds.height) / 2)
        )
        let middleWidth = max(0, bounds.width - corner * 2)
        let middleHeight = max(0, bounds.height - corner * 2)
        let cursorRects: [(RegionSelectionResizeHandle, CGRect)] = [
            (.northWest, CGRect(x: bounds.minX, y: bounds.minY, width: corner, height: corner)),
            (.north, CGRect(x: bounds.minX + corner, y: bounds.minY, width: middleWidth, height: edge)),
            (.northEast, CGRect(x: bounds.maxX - corner, y: bounds.minY, width: corner, height: corner)),
            (.east, CGRect(x: bounds.maxX - edge, y: bounds.minY + corner, width: edge, height: middleHeight)),
            (.southEast, CGRect(x: bounds.maxX - corner, y: bounds.maxY - corner, width: corner, height: corner)),
            (.south, CGRect(x: bounds.minX + corner, y: bounds.maxY - edge, width: middleWidth, height: edge)),
            (.southWest, CGRect(x: bounds.minX, y: bounds.maxY - corner, width: corner, height: corner)),
            (.west, CGRect(x: bounds.minX, y: bounds.minY + corner, width: edge, height: middleHeight))
        ]
        for (handle, rect) in cursorRects where !rect.isEmpty {
            addCursorRect(rect, cursor: handle.cursor)
        }
    }

    private func visibleDocumentRect() -> CGRect {
        if let regionDraftViewport {
            return regionDraftViewport.visibleDocumentRect
        }
        return session.controller.document.crop.rect?.standardized
            ?? CGRect(origin: .zero, size: session.controller.document.canvasSize)
    }

    private func documentPoint(fromViewPoint point: CGPoint) -> CGPoint {
        let visible = visibleDocumentRect()
        return CGPoint(
            x: visible.minX + point.x / max(1, bounds.width) * visible.width,
            y: visible.minY + point.y / max(1, bounds.height) * visible.height
        )
    }

    private func viewPoint(fromDocumentPoint point: CGPoint) -> CGPoint {
        let visible = visibleDocumentRect()
        return CGPoint(
            x: (point.x - visible.minX) / max(1, visible.width) * bounds.width,
            y: (point.y - visible.minY) / max(1, visible.height) * bounds.height
        )
    }

    private func viewRect(fromDocumentRect rect: CGRect) -> CGRect {
        let origin = viewPoint(fromDocumentPoint: rect.origin)
        let maxPoint = viewPoint(fromDocumentPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: maxPoint.x - origin.x, height: maxPoint.y - origin.y)
    }

    private func cancelProvisionalDrawing() {
        startPoint = nil
        currentPoint = nil
        freehandPoints.removeAll()
        _ = cancelSelectionInteraction(reason: "provisional-drawing-cancelled")
        syncSelectedTextChrome()
        needsDisplay = true
    }

    private func updateAccessibilitySummary(
        document: AnnotationDocument,
        captured: CapturedImage,
        selectedItemIDs: Set<UUID>? = nil,
        currentTool: AnnotationTool? = nil,
        currentStyle: AnnotationStyle? = nil
    ) {
        let effectiveSelectedItemIDs = selectedItemIDs ?? session.controller.selectedItemIDs
        let currentTool = currentTool ?? session.currentTool
        let currentStyle = currentStyle ?? session.currentStyle
        let accessibilitySelectedItems = document.orderedAnnotations.compactMap { item -> AnnotationItem? in
            guard effectiveSelectedItemIDs.contains(item.id), !item.isLocked else { return nil }
            return displayItem(for: item)
        }
        let selectionHandleCount: Int
        if !isAnnotationEditingEnabled {
            selectionHandleCount = 0
        } else if accessibilitySelectedItems.count == 1,
           accessibilitySelectedItems[0].kind == .text
        {
            selectionHandleCount = 3
        } else {
            selectionHandleCount = accessibilitySelectedItems.count == 1
                ? selectionGeometry.handlePoints(for: accessibilitySelectedItems[0]).count
                : 0
        }
        let interactionState = (
            selectionInteraction?.hasMoved == true
                || selectedTextResizeInteraction != nil
        ) ? "live" : "idle"
        let selectionBounds = accessibilitySelectedItems.reduce(CGRect.null) {
            $0.union(selectionGeometry.transformedBounds(for: $1))
        }
        let selectionX = selectionBounds.isNull ? -1 : selectionBounds.minX
        let selectionY = selectionBounds.isNull ? -1 : selectionBounds.minY
        let selectionWidth = selectionBounds.isNull ? 0 : selectionBounds.width
        let selectionHeight = selectionBounds.isNull ? 0 : selectionBounds.height
        let annotationBounds = document.orderedAnnotations.reduce(CGRect.null) {
            $0.union(selectionGeometry.transformedBounds(for: $1))
        }
        let annotationX = annotationBounds.isNull ? -1 : annotationBounds.minX
        let annotationY = annotationBounds.isNull ? -1 : annotationBounds.minY
        let annotationWidth = annotationBounds.isNull ? 0 : annotationBounds.width
        let annotationHeight = annotationBounds.isNull ? 0 : annotationBounds.height
        let presentedSelectedLineWidth = accessibilitySelectedItems.first?.style.lineWidth ?? -1
        let storedSelectedLineWidth = document.orderedAnnotations.first(where: {
            effectiveSelectedItemIDs.contains($0.id) && !$0.isLocked
        })?.style.lineWidth ?? -1
        let storedAnnotationLineWidths = document.orderedAnnotations
            .map { String(format: "%.2f", $0.style.lineWidth) }
            .joined(separator: ",")
        let textEditingMode: String
        if let textEditingState {
            textEditingMode = textEditingState.itemID == nil ? "new" : "existing"
        } else {
            textEditingMode = "inactive"
        }
        let textBaselineError = textEditorBaselineError
            ?? CGPoint(x: -1, y: -1)
        let textLineOrigin = textEditor.flatMap(textEditorLineOriginInView)
            ?? CGPoint(x: -1, y: -1)
        let textViewportOrigin = textEditorDocumentView?.frame.origin
            ?? CGPoint(x: -1, y: -1)
        let selectedTextFontSize = accessibilitySelectedItems.first.flatMap {
            $0.kind == .text ? $0.style.fontSize : nil
        }
        let activeTextFontSize = textEditingState?.style.fontSize ?? selectedTextFontSize ?? -1
        let textResizeState = textResizeInteraction?.handle.rawValue
            ?? selectedTextResizeInteraction?.handle.rawValue
            ?? "idle"
        let textChromeState: String
        if textEditorFrameView != nil {
            textChromeState = "editing"
        } else if selectedTextFrameView != nil {
            textChromeState = "selected"
        } else {
            textChromeState = "hidden"
        }
        let commitBaselineError = lastTextCommitBaselineError ?? CGPoint(x: -1, y: -1)
        let textAnnotationCount = document.annotations.lazy.filter { $0.kind == .text }.count
        let activeTextCharacterCount = textEditor?.string.utf16.count ?? 0
        let textFocusState = textEditor != nil && window?.firstResponder === textEditor
            ? "active"
            : "inactive"
        let annotationMoveCursorState: String
        if let selectionInteraction, case .move = selectionInteraction.mode {
            annotationMoveCursorState = selectionInteraction.hasMoved
                ? "dragging-closed-hand"
                : "pressed-closed-hand"
        } else {
            annotationMoveCursorState = "idle-hover"
        }
        let summary = String(
            format: "annotations=%d; textAnnotations=%d; pixels=%d×%d; logical=%.0f×%.0f; scale=%.2fx; tool=%@; editing=%@; color=%@; lineWidth=%.1f; presentedSelectedLineWidth=%.2f; storedSelectedLineWidth=%.2f; annotationLineWidths=%@; rectangleRadius=%.1f; shapeFill=%@; arrowStyle=%@; selectionOutline=%@; selectionHandles=%d; selectionBounds=%.1f,%.1f,%.1f,%.1f; annotationBounds=%.1f,%.1f,%.1f,%.1f; interaction=%@; annotationMoveCursor=%@; textEditing=%@; textCharacters=%d; textFocus=%@; textChrome=%@; textFontSize=%.2f; textResize=%@; textResizeFixedCornerError=%.2f; textBaselineError=%.2f,%.2f; textCommitBaselineError=%.2f,%.2f; textLineOrigin=%.2f,%.2f; textViewportOrigin=%.2f,%.2f; textGeometryConfigurations=%d; textBaselineCorrections=%d; textViewportMutations=%d; textLineOriginDrifts=%d; textFrameMutationRejections=%d; markedText=%@; windowResize=%@; windowMoveCursor=%@; windowMoveState=%@",
            document.annotations.count,
            textAnnotationCount,
            captured.image.width,
            captured.image.height,
            captured.logicalSize.width,
            captured.logicalSize.height,
            captured.scale,
            currentTool.rawValue,
            isAnnotationEditingEnabled ? "enabled" : "disabled",
            AnnotationColorPalette.hexString(for: currentStyle.strokeColor),
            currentStyle.lineWidth,
            presentedSelectedLineWidth,
            storedSelectedLineWidth,
            storedAnnotationLineWidths,
            currentStyle.cornerRadius,
            currentStyle.shapeFillMode.rawValue,
            currentStyle.arrowHeadStyle.rawValue,
            "hidden",
            selectionHandleCount,
            selectionX,
            selectionY,
            selectionWidth,
            selectionHeight,
            annotationX,
            annotationY,
            annotationWidth,
            annotationHeight,
            interactionState,
            annotationMoveCursorState,
            textEditingMode,
            activeTextCharacterCount,
            textFocusState,
            textChromeState,
            activeTextFontSize,
            textResizeState,
            textResizeFixedCornerError,
            textBaselineError.x,
            textBaselineError.y,
            commitBaselineError.x,
            commitBaselineError.y,
            textLineOrigin.x,
            textLineOrigin.y,
            textViewportOrigin.x,
            textViewportOrigin.y,
            textEditorGeometryConfigurationCount,
            textEditorBaselineCorrectionCount,
            textEditorPostConfigurationViewportMutationCount,
            textEditorPostConfigurationLineOriginDriftCount,
            textEditorPreventedFrameMutationCount,
            textEditor?.hasMarkedText() == true ? "active" : "inactive",
            pinnedWindowResizeIsAvailable ? "enabled" : "disabled",
            pinnedWindowResizeIsAvailable ? "grab" : "unavailable",
            isWindowDragInProgress ? "pressed-closed-hand" : "idle-open-hand"
        )
        let regionPreviewState = regionDraftViewport != nil
            ? "active"
            : (didPreviewRegionDraftGeometry ? "committed" : "inactive")
        let regionPreviewSummary = String(
            format: "; regionPreview=%@; regionPreviewScale=%.2f,%.2f; regionPreviewAnchorError=%.2f; regionPreviewGridError=%.2f",
            regionPreviewState,
            lastRegionDraftPreviewScale.x,
            lastRegionDraftPreviewScale.y,
            lastRegionDraftPreviewAnchorError,
            lastRegionDraftPreviewGridError
        )
        setAccessibilityValue(summary + regionPreviewSummary)
    }
}

private final class InlineAnnotationTextLayoutManager: NSLayoutManager,
    NSLayoutManagerDelegate
{
    private var canonicalBaselineOffset: CGFloat?

    override init() {
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setCanonicalBaselineOffset(_ baselineOffset: CGFloat) {
        precondition(
            baselineOffset.isFinite && baselineOffset >= 0,
            "Inline text requires a finite canonical baseline offset."
        )
        guard canonicalBaselineOffset.map({
            abs($0 - baselineOffset) >= 0.001
        }) ?? true else { return }
        canonicalBaselineOffset = baselineOffset
        if let textStorage {
            invalidateLayout(
                forCharacterRange: NSRange(
                    location: 0,
                    length: textStorage.length
                ),
                actualCharacterRange: nil
            )
        }
    }

    override func defaultBaselineOffset(for font: NSFont) -> CGFloat {
        canonicalBaselineOffset ?? super.defaultBaselineOffset(for: font)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let canonicalBaselineOffset else { return false }
        baselineOffset.pointee = canonicalBaselineOffset
        return true
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard let textStorage, charIndex < textStorage.length else {
            return action
        }
        switch (textStorage.string as NSString).character(at: charIndex) {
        case 0x000B, 0x000C:
            // Core's canonical planner treats these raw hard breaks like LF
            // while preserving their original UTF-16 unit in the document.
            return [.lineBreak, .paragraphBreak]
        default:
            return action
        }
    }
}

private final class InlineAnnotationTextDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class InlineAnnotationTextViewportView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class InlineAnnotationTextEditorFrameView: NSView {
    static let cornerRadius: CGFloat = 4
    static let chromeOutset: CGFloat = 10
    static let minimumInteractiveFieldWidth: CGFloat = 48
    static let minimumInteractiveFieldHeight = chromeOutset * 2

    var onResizeBegan: ((InlineAnnotationTextResizeHandle, NSEvent) -> Void)?
    var onResizeChanged: ((InlineAnnotationTextResizeHandle, NSEvent) -> Void)?
    var onResizeEnded: ((InlineAnnotationTextResizeHandle, NSEvent) -> Void)?
    var onDelete: (() -> Void)?

    private var textFieldFrame: CGRect = .zero
    private let northWestResize = InlineAnnotationTextChromeControl(
        kind: .resize(.northWest),
        accessibilityIdentifier: "pinned.text.resize.northWest",
        accessibilityLabel: NSLocalizedString(
            "Resize text from top left",
            comment: "Inline text top-left font resize handle"
        )
    )
    private let southWestResize = InlineAnnotationTextChromeControl(
        kind: .resize(.southWest),
        accessibilityIdentifier: "pinned.text.resize.southWest",
        accessibilityLabel: NSLocalizedString(
            "Resize text from bottom left",
            comment: "Inline text bottom-left font resize handle"
        )
    )
    private let southEastResize = InlineAnnotationTextChromeControl(
        kind: .resize(.southEast),
        accessibilityIdentifier: "pinned.text.resize.southEast",
        accessibilityLabel: NSLocalizedString(
            "Resize text from bottom right",
            comment: "Inline text bottom-right font resize handle"
        )
    )
    private let deleteControl = InlineAnnotationTextChromeControl(
        kind: .delete,
        accessibilityIdentifier: "pinned.text.delete",
        accessibilityLabel: NSLocalizedString(
            "Delete text box",
            comment: "Inline text delete button"
        )
    )
    private var didInstallChromeControls = false
    private var capturesFieldHitTesting = false

    private var resizeControls: [InlineAnnotationTextChromeControl] {
        [northWestResize, southWestResize, southEastResize]
    }

    private var chromeControls: [InlineAnnotationTextChromeControl] {
        [northWestResize, southWestResize, southEastResize, deleteControl]
    }

    var resizeHandleCount: Int { resizeControls.count }
    var deleteControlCount: Int { 1 }
    var areChromeCursorRectsSuppressed: Bool {
        chromeControls.allSatisfy(\.isCursorRectSuppressed)
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        for control in resizeControls {
            control.onResizeBegan = { [weak self] handle, event in
                self?.onResizeBegan?(handle, event)
            }
            control.onResizeChanged = { [weak self] handle, event in
                self?.onResizeChanged?(handle, event)
            }
            control.onResizeEnded = { [weak self] handle, event in
                self?.onResizeEnded?(handle, event)
            }
        }
        deleteControl.onActivate = { [weak self] in self?.onDelete?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func installViewport(_ viewport: NSView) {
        addSubview(viewport)
        capturesFieldHitTesting = true
        installChromeControls(relativeTo: viewport)
    }

    func installChromeControls() {
        installChromeControls(relativeTo: nil)
    }

    func setFieldFrame(_ frame: CGRect) {
        precondition(
            bounds.contains(frame),
            "The inline text viewport must remain inside its chrome frame."
        )
        textFieldFrame = frame
        layoutChromeControls()
        for control in chromeControls where !control.isHidden {
            let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
            precondition(
                hitTest(center) === control,
                "Inline text chrome must remain above the editable viewport in hit testing."
            )
        }
        needsDisplay = true
    }

    func fieldFrame(in view: NSView) -> CGRect {
        convert(textFieldFrame, to: view)
    }

    func fieldPoint(
        corner: InlineAnnotationTextFrameCorner,
        in view: NSView
    ) -> CGPoint {
        let point: CGPoint
        switch corner {
        case .northWest: point = CGPoint(x: textFieldFrame.minX, y: textFieldFrame.maxY)
        case .northEast: point = CGPoint(x: textFieldFrame.maxX, y: textFieldFrame.maxY)
        case .southWest: point = CGPoint(x: textFieldFrame.minX, y: textFieldFrame.minY)
        case .southEast: point = CGPoint(x: textFieldFrame.maxX, y: textFieldFrame.minY)
        }
        return convert(point, to: view)
    }

    func setActiveResizeHandle(_ handle: InlineAnnotationTextResizeHandle?) {
        for control in resizeControls {
            control.isActive = control.resizeHandle == handle
        }
    }

    func cancelActiveResize() {
        for control in resizeControls {
            control.isActive = false
            control.cancelPress()
        }
    }

    func setFontSizeAccessibilityValue(_ fontSize: CGFloat) {
        let value = String(
            format: NSLocalizedString(
                "Font size %.1f points",
                comment: "Inline text resize handle accessibility value"
            ),
            fontSize
        )
        for control in resizeControls {
            control.setAccessibilityValue(value)
        }
    }

    func setChromeCursorRectsSuppressed(_ suppressed: Bool) {
        for control in chromeControls {
            control.isCursorRectSuppressed = suppressed
        }
    }

    override func layout() {
        super.layout()
        layoutChromeControls()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Callers pass receiver-local points. Do not forward them to
        // super.hitTest, which expects superview coordinates and would miss
        // the NSTextView whenever the chrome is not at the canvas origin.
        guard bounds.contains(point) else { return nil }
        let matchingControls = chromeControls.filter {
            !$0.isHidden && $0.frame.contains(point)
        }
        if let nearestControl = matchingControls.min(by: {
            squaredDistance(
                from: point,
                to: CGPoint(x: $0.frame.midX, y: $0.frame.midY)
            ) < squaredDistance(
                from: point,
                to: CGPoint(x: $1.frame.midX, y: $1.frame.midY)
            )
        }) {
            return nearestControl
        }
        guard capturesFieldHitTesting, textFieldFrame.contains(point) else { return nil }
        guard let editor = inlineEditorDescendant() else {
            preconditionFailure("An editable inline text field must contain its NSTextView.")
        }
        return editor
    }

    private func inlineEditorDescendant() -> NSTextView? {
        func search(_ view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView {
                return editor
            }
            for subview in view.subviews {
                if let editor = search(subview) {
                    return editor
                }
            }
            return nil
        }
        return search(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard textFieldFrame.width > 0, textFieldFrame.height > 0 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(
            roundedRect: textFieldFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        path.lineWidth = 1
        path.stroke()
    }

    private func layoutChromeControls() {
        guard textFieldFrame.width > 0, textFieldFrame.height > 0 else { return }
        let hitSize = Self.chromeOutset * 2
        let half = hitSize / 2
        northWestResize.frame = CGRect(
            x: textFieldFrame.minX - half,
            y: textFieldFrame.maxY - half,
            width: hitSize,
            height: hitSize
        )
        southWestResize.frame = CGRect(
            x: textFieldFrame.minX - half,
            y: textFieldFrame.minY - half,
            width: hitSize,
            height: hitSize
        )
        southEastResize.frame = CGRect(
            x: textFieldFrame.maxX - half,
            y: textFieldFrame.minY - half,
            width: hitSize,
            height: hitSize
        )
        deleteControl.frame = CGRect(
            x: textFieldFrame.maxX - half,
            y: textFieldFrame.maxY - half,
            width: hitSize,
            height: hitSize
        )
    }

    private func installChromeControls(relativeTo viewport: NSView?) {
        guard !didInstallChromeControls else { return }
        didInstallChromeControls = true
        for control in chromeControls {
            if let viewport {
                addSubview(control, positioned: .above, relativeTo: viewport)
            } else {
                addSubview(control)
            }
        }
    }

    private func squaredDistance(from point: CGPoint, to other: CGPoint) -> CGFloat {
        let dx = point.x - other.x
        let dy = point.y - other.y
        return dx * dx + dy * dy
    }

}

private final class InlineAnnotationTextChromeControl: NSView {
    enum Kind {
        case resize(InlineAnnotationTextResizeHandle)
        case delete
    }

    let kind: Kind
    var onResizeBegan: ((InlineAnnotationTextResizeHandle, NSEvent) -> Void)?
    var onResizeChanged: ((InlineAnnotationTextResizeHandle, NSEvent) -> Void)?
    var onResizeEnded: ((InlineAnnotationTextResizeHandle, NSEvent) -> Void)?
    var onActivate: (() -> Void)?
    var isActive = false {
        didSet { needsDisplay = true }
    }
    var isCursorRectSuppressed = false {
        didSet {
            guard oldValue != isCursorRectSuppressed else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    var resizeHandle: InlineAnnotationTextResizeHandle? {
        guard case .resize(let handle) = kind else { return nil }
        return handle
    }

    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(
        kind: Kind,
        accessibilityIdentifier: String,
        accessibilityLabel: String
    ) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(accessibilityIdentifier)
        setAccessibilityLabel(accessibilityLabel)
        if case .resize = kind {
            setAccessibilityHelp(NSLocalizedString(
                "Drag to change the font size.",
                comment: "Text resize handle accessibility help"
            ))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isCursorRectSuppressed else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        switch kind {
        case .resize(let handle):
            cursor.set()
            onResizeBegan?(handle, event)
        case .delete:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .resize(let handle) = kind else { return }
        cursor.set()
        onResizeChanged?(handle, event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        switch kind {
        case .resize(let handle):
            cursor.set()
            onResizeEnded?(handle, event)
        case .delete:
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) {
                onActivate?()
            }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard case .delete = kind else { return false }
        onActivate?()
        return true
    }

    func cancelPress() {
        isPressed = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch kind {
        case .resize:
            let diameter: CGFloat = isActive || isPressed ? 9 : 8
            let knob = CGRect(
                x: bounds.midX - diameter / 2,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            (isActive ? NSColor.controlAccentColor : NSColor.windowBackgroundColor).setFill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            path.fill()
            path.stroke()
        case .delete:
            let diameter: CGFloat = 16
            let circle = CGRect(
                x: bounds.midX - diameter / 2,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.72 : 1).setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke()
            let inset: CGFloat = 5
            let xPath = NSBezierPath()
            xPath.move(to: CGPoint(x: circle.minX + inset, y: circle.minY + inset))
            xPath.line(to: CGPoint(x: circle.maxX - inset, y: circle.maxY - inset))
            xPath.move(to: CGPoint(x: circle.minX + inset, y: circle.maxY - inset))
            xPath.line(to: CGPoint(x: circle.maxX - inset, y: circle.minY + inset))
            xPath.lineWidth = 1.5
            xPath.lineCapStyle = .round
            xPath.stroke()
        }
    }

    private var cursor: NSCursor {
        guard case .resize(let handle) = kind else { return .arrow }
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .northWest: position = .topLeft
            case .southWest: position = .bottomLeft
            case .southEast: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return .crosshair
    }
}

private final class InlineAnnotationTextView: NSTextView {
    var onMarkedTextChange: (() -> Void)?
    var onEscape: (() -> Void)?
    var onShiftReturnLineBreak: (() -> Void)?
    var onRejectedPresentationFrameChange: ((CGRect, CGRect) -> Void)?
    private var documentFrameLock: CGRect?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        AppLog.capture.notice(
            "Inline text received pointer down: x=\(location.x, privacy: .public), y=\(location.y, privacy: .public), characters=\(self.string.utf16.count, privacy: .public), selected=\(self.selectedRange().location, privacy: .public)"
        )
        super.mouseDown(with: event)
    }

    func lockDocumentFrame(_ frame: CGRect) {
        documentFrameLock = nil
        super.setFrameOrigin(frame.origin)
        super.setFrameSize(frame.size)
        documentFrameLock = frame
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        guard let documentFrameLock else {
            super.setFrameOrigin(newOrigin)
            return
        }
        let proposedFrame = CGRect(origin: newOrigin, size: frame.size)
        if max(
            abs(proposedFrame.minX - documentFrameLock.minX),
            abs(proposedFrame.minY - documentFrameLock.minY)
        ) > 0.001 {
            onRejectedPresentationFrameChange?(proposedFrame, documentFrameLock)
        }
        super.setFrameOrigin(documentFrameLock.origin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard let documentFrameLock else {
            super.setFrameSize(newSize)
            return
        }
        let proposedFrame = CGRect(origin: frame.origin, size: newSize)
        if max(
            abs(proposedFrame.width - documentFrameLock.width),
            abs(proposedFrame.height - documentFrameLock.height)
        ) > 0.001 {
            onRejectedPresentationFrameChange?(proposedFrame, documentFrameLock)
        }
        super.setFrameSize(documentFrameLock.size)
    }

    override func keyDown(with event: NSEvent) {
        let dismissalModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, dismissalModifiers.isEmpty {
            let discardedComposition = hasMarkedText()
            if discardedComposition {
                guard let inputContext else {
                    preconditionFailure("A marked inline composition must have an NSInputContext.")
                }
                inputContext.discardMarkedText()
                onMarkedTextChange?()
            }
            AppLog.capture.debug(
                "Handled inline text Escape: discardedComposition=\(discardedComposition, privacy: .public)"
            )
            onEscape?()
            return
        }
        if isShiftReturnLineBreak(event) {
            insertNewlineIgnoringFieldEditor(nil)
            onShiftReturnLineBreak?()
            onMarkedTextChange?()
            return
        }
        super.keyDown(with: event)
    }

    private func isShiftReturnLineBreak(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.shift)
            && !modifiers.contains(.command)
            && !modifiers.contains(.control)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        let characterCount: Int
        if let attributed = string as? NSAttributedString {
            characterCount = attributed.length
        } else if let plain = string as? NSString {
            characterCount = plain.length
        } else {
            characterCount = 0
        }
        onMarkedTextChange?()
        AppLog.capture.debug(
            "Updated inline IME composition: characters=\(characterCount, privacy: .public), selectionLength=\(selectedRange.length, privacy: .public)"
        )
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?()
        AppLog.capture.debug("Committed inline IME composition")
    }

    override func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        if let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
        }
        let rect = super.firstRect(forCharacterRange: range, actualRange: actualRange)
        AppLog.capture.debug(
            "Resolved inline IME candidate anchor: x=\(rect.minX, privacy: .public), y=\(rect.minY, privacy: .public), width=\(rect.width, privacy: .public), height=\(rect.height, privacy: .public)"
        )
        return rect
    }
}
