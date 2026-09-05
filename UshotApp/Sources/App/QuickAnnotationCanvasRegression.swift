#if DEBUG
import AppKit
import UshotCore

@MainActor
extension QuickAnnotationCanvasView {
    func runLineWidthRoutingRegression() {
        let session = debugRegressionSession
        precondition(
            session.controller.document.annotations.isEmpty,
            "The line-width routing regression requires an empty annotation document."
        )
        precondition(
            !hasActiveLineWidthEditing,
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
        debugCommitAnnotation(
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
              let presentedDuringPreview = debugSelectedDisplayItems.first(where: { $0.id == firstID })
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

        debugCommitAnnotation(
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
        debugCommitAnnotation(
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
            hasActiveLineWidthEditing,
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
            !hasActiveLineWidthEditing,
            "Canvas mouse-down must resolve a toolbar line-width edit before starting its interaction."
        )
        self.mouseUp(with: mouseUp)
        AppLog.capture.notice(
            "Annotation line-width canvas-boundary regression passed: fieldResolvedBeforePointerInteraction=true"
        )
    }

    func runReadOnlyWindowPressCursorRegression() {
        let session = debugRegressionSession
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
        precondition(debugWindowDragState.isArmed, "Pinned mouse-down must arm window movement immediately.")
        precondition(debugWindowDragState.isInProgress, "Pinned mouse-down must enter the active drag state before movement.")
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
        precondition(!debugWindowDragState.isInProgress, "Pinned mouse-up must end the active drag state.")

        self.mouseDown(with: mouseDown)
        precondition(
            debugWindowDragState.isInProgress,
            "Pinned editing-disable regression must begin with an active body move."
        )
        setAnnotationEditingEnabled(false)
        precondition(
            !debugWindowDragState.isInProgress && !debugWindowDragState.isArmed,
            "Disabling an already read-only canvas must still release its active body move."
        )
        self.mouseUp(with: mouseUp)

        let originalTool = session.currentTool
        let originalAnnotationCount = session.controller.document.annotations.count
        setAnnotationEditingEnabled(true)
        session.currentTool = .select
        self.mouseDown(with: mouseDown)
        precondition(
            debugWindowDragState.isInProgress,
            "Pinned tool-switch regression must begin with an active Select body move."
        )
        session.currentTool = .text
        self.mouseUp(with: mouseUp)
        precondition(
            !debugWindowDragState.isInProgress
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
}

@MainActor
enum AnnotationTextRegressionFixtures {
    static func requiredRendererReadyTextLayoutForRegression(
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

    static func requiredRendererReadyTextPayloadForRegression(
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
}
#endif
