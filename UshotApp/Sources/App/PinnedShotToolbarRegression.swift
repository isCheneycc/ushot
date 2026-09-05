#if DEBUG
import AppKit
import UshotCore

@MainActor
enum PinnedShotToolbarRegression {
    struct Snapshot {
        let lineWidthFieldIsEnabled: Bool
        let committedLineWidth: CGFloat
        let hasActiveLineWidthEdit: Bool
        let lineWidthFieldHasEditor: Bool
        let lineWidthFieldString: String
        let colorPaletteHexes: [String]
        let currentColorHex: String
        let canvasEditorPresented: Bool
        let showsToolbar: Bool
        let editorSettings: EditorSettings
    }

    enum Action {
        case persistDefaultLineWidth(CGFloat)
        case syncLineWidthToolbar
        case commitLineWidthInput(String)
        case beginNativeLineWidthInput(String)
        case beginLineWidthInput(String)
        case changeLineWidthUnit(AnnotationLineWidthUnit)
        case disableAnnotationEditing(reason: String)
        case selectAnnotationTool(AnnotationTool, reason: String)
        case beginCanvasEditorPresentation(reason: String)
        case endCanvasEditorPresentation
        case applyEditorColorSettings(EditorSettings)
        case prepareToolbarForDetachment(reason: String)
    }

    static func run(
        session: AnnotationEditingSession,
        imageView: QuickAnnotationCanvasView,
        snapshot: () -> Snapshot,
        perform: (Action) -> Void
    ) {
        imageView.runLineWidthRoutingRegression()
        perform(.persistDefaultLineWidth(9))

        session.currentTool = .select
        perform(.syncLineWidthToolbar)
        precondition(
            snapshot().lineWidthFieldIsEnabled,
            "Select must keep the line-width field enabled for a compatible selected annotation."
        )
        perform(.commitLineWidthInput("11"))
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
                && snapshot().committedLineWidth == 9,
            "Undo must synchronize the selected annotation and toolbar field after a real input callback."
        )

        session.controller.selectedItemIDs.removeAll()
        session.currentTool = .rectangle
        let documentBeforeDefaultEdit = session.controller.document
        perform(.commitLineWidthInput("10"))
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
        perform(.beginNativeLineWidthInput("12"))
        perform(.disableAnnotationEditing(reason: "debug-line-width-lifecycle"))
        precondition(
            !snapshot().hasActiveLineWidthEdit,
            "Disabling annotation editing must end the toolbar's line-width transaction."
        )
        imageView.setAnnotationEditingEnabled(true)
        perform(.syncLineWidthToolbar)
        precondition(
            !snapshot().lineWidthFieldIsEnabled,
            "Re-enabling Select with no selection must leave the line-width field disabled."
        )

        session.currentTool = .rectangle
        perform(.beginLineWidthInput("12"))
        let alternateUnit: AnnotationLineWidthUnit = session.lineWidthUnit == .pixels
            ? .points
            : .pixels
        perform(.changeLineWidthUnit(alternateUnit))
        precondition(
            !snapshot().hasActiveLineWidthEdit
                && session.lineWidthUnit == alternateUnit
                && session.creationStyle(for: .rectangle).lineWidth == 12,
            "Changing units must commit and detach the active line-width transaction before conversion."
        )

        perform(.beginNativeLineWidthInput("13."))
        perform(.selectAnnotationTool(.arrow, reason: "debug-line-width-tool-switch"))
        precondition(
            session.currentTool == .arrow
                && !snapshot().hasActiveLineWidthEdit
                && !snapshot().lineWidthFieldHasEditor
                && snapshot().lineWidthFieldString == "13"
                && !imageView.hasActiveLineWidthEditing,
            "Changing tools must resolve both sides of an active native line-width edit and normalize its display before changing ownership."
        )
        precondition(
            session.defaultStyle(for: .rectangle).lineWidth == 13
                && session.creationStyle(for: .arrow).lineWidth == 13,
            "A valid tool-default line width must commit before the next tool loads its default."
        )

        perform(.beginNativeLineWidthInput("14"))
        imageView.runLineWidthCanvasBoundaryRegression()
        precondition(
            session.creationStyle(for: .arrow).lineWidth == 14
                && !snapshot().hasActiveLineWidthEdit
                && !snapshot().lineWidthFieldHasEditor
                && !imageView.hasActiveLineWidthEditing,
            "Canvas pointer-down must commit and detach the active tool-default line-width edit first."
        )

        guard let sharedSelectionID = session.controller.document.orderedAnnotations.last?.id else {
            preconditionFailure("The shared-session ownership regression requires an existing annotation.")
        }
        session.controller.selectedItemIDs = [sharedSelectionID]
        perform(.selectAnnotationTool(.select, reason: "debug-shared-session-selection"))
        perform(.beginNativeLineWidthInput("15"))
        let selectionBeforeCanvasEditor = session.controller.selectedItemIDs
        let restoredToolbarVisibility = snapshot().showsToolbar
        perform(.beginCanvasEditorPresentation(reason: "debug-shared-session-boundary"))
        precondition(
            snapshot().canvasEditorPresented
                && !snapshot().showsToolbar
                && session.controller.selectedItemIDs == selectionBeforeCanvasEditor
                && session.controller.document.annotations.first(where: { $0.id == sharedSelectionID })?.style.lineWidth == 15
                && !snapshot().hasActiveLineWidthEdit
                && !snapshot().lineWidthFieldHasEditor
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
        perform(.endCanvasEditorPresentation)
        precondition(
            !snapshot().canvasEditorPresented
                && snapshot().showsToolbar == restoredToolbarVisibility
                && imageView.debugIsAnnotationEditingEnabled == restoredToolbarVisibility,
            "Closing the full editor must release exclusive ownership and restore the prior pinned-toolbar state."
        )

        let restoredEditor = snapshot().editorSettings
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
        perform(.applyEditorColorSettings(exclusiveEditor))
        session.adoptCurrentStyle(session.currentStyle, origin: .newTextDraft)
        perform(.beginCanvasEditorPresentation(reason: "debug-canvas-editor-palette-ownership"))

        session.updateEditorSettings(restoredEditor)
        session.adoptCurrentStyle(
            session.defaultStyle(for: .text),
            origin: .newTextDraft
        )
        precondition(
            snapshot().colorPaletteHexes == [exclusiveColor],
            "The hidden pinned toolbar must not consume canvas-editor palette mutations."
        )
        perform(.endCanvasEditorPresentation)
        let restoredCurrentColor = AnnotationColorPalette.hexString(
            for: session.currentStyle.strokeColor
        )
        precondition(
            snapshot().colorPaletteHexes == restoredEditor.availableColorHexes
                && snapshot().currentColorHex == restoredCurrentColor
                && restoredEditor.availableColorHexes.contains(restoredCurrentColor),
            "Returning from the canvas editor must atomically reconcile the hidden toolbar with the latest palette and active style."
        )
        perform(.selectAnnotationTool(.arrow, reason: "debug-shared-session-return"))

        perform(.beginNativeLineWidthInput("15"))
        precondition(
            session.creationStyle(for: .arrow).lineWidth == 15,
            "The toolbar-detachment regression requires a live uncommitted Arrow width."
        )
        perform(.prepareToolbarForDetachment(reason: "debug-line-width-toolbar-detachment"))
        precondition(
            session.creationStyle(for: .arrow).lineWidth == 14
                && !snapshot().hasActiveLineWidthEdit
                && !snapshot().lineWidthFieldHasEditor
                && !imageView.hasActiveLineWidthEditing,
            "Toolbar detachment must cancel and release its native line-width edit before removing the content view."
        )
        AppLog.capture.notice(
            "Annotation toolbar line-width callback regression passed: selectFieldEnabled=true, selectedCommit=11, selectedUndo=9, defaultCommit=10, lifecycleCancel=true, activeUnitBoundary=true, toolSwitchCommit=13, rawCommitNormalized=true, canvasCommit=14, sharedSessionExclusive=true, sharedSelectionPreserved=true, sharedTargetDeletionSafe=true, paletteOwnershipExclusive=true, paletteReturnAtomic=true, detachCancel=14"
        )
    }
}
#endif
