import AppKit
import SwiftUI
import UshotCore

@MainActor
final class CanvasZoomModel: ObservableObject {
    @Published var magnification: CGFloat = 1
    @Published var fitRequest = UUID()

    func fit() {
        fitRequest = UUID()
    }
}

@MainActor
final class CanvasEditorCommandGate: ObservableObject {
    @Published private(set) var isInteractionSuspended = false
    private weak var canvas: QuickAnnotationCanvasView?
    private var inspectorFinalizer: (identifier: UUID, action: () throws -> Void)?

#if DEBUG
    var hasRegisteredCanvasForRegression: Bool { canvas != nil }
#endif

    func register(_ canvas: QuickAnnotationCanvasView) {
        self.canvas = canvas
        canvas.setInteractionSuspended(isInteractionSuspended)
    }

    func unregister(_ candidate: QuickAnnotationCanvasView?) {
        guard canvas === candidate else { return }
        canvas = nil
    }

    func resolveActiveTextEditing(reason: String) -> Bool {
        guard !isInteractionSuspended else { return false }
        guard let canvas else {
            AppLog.capture.fault(
                "Rejected Canvas editor command without its registered canvas: reason=\(reason, privacy: .public)"
            )
            return false
        }
        guard canvas.isTextEditing else { return true }
        guard canvas.endTextEditingIfNeeded(reason: .externalAction) else {
            AppLog.capture.notice(
                "Rejected Canvas editor command because active text could not commit: reason=\(reason, privacy: .public)"
            )
            return false
        }
        return true
    }

    func registerInspectorFinalizer(identifier: UUID, action: @escaping () throws -> Void) {
        inspectorFinalizer = (identifier, action)
    }

    func unregisterInspectorFinalizer(identifier: UUID) {
        guard inspectorFinalizer?.identifier == identifier else { return }
        inspectorFinalizer = nil
    }

    func prepareForHistoryFinalization(reason: String) throws {
        guard !isInteractionSuspended else { return }
        guard let canvas, !canvas.hasActivePointerInteraction else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: String(localized: "Finish the active annotation gesture before closing the editor.")
            )
        }
        guard resolveActiveTextEditing(reason: reason),
              canvas.window?.makeFirstResponder(nil) == true
        else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: String(localized: "The active text could not be committed. The editor remains open.")
            )
        }
        // SwiftUI draft publication may still be queued when the close button
        // fires. Resolve its live value before freezing the document snapshot.
        try inspectorFinalizer?.action()
        setInteractionSuspended(true)
    }

    func setInteractionSuspended(_ suspended: Bool) {
        isInteractionSuspended = suspended
        canvas?.setInteractionSuspended(suspended)
    }
}

struct CanvasEditorRootView: View {
    @ObservedObject var session: AnnotationEditingSession
    @ObservedObject private var controller: AnnotationDocumentController
    @ObservedObject private var settingsStore: SettingsStore
    @StateObject private var zoom = CanvasZoomModel()
    @State private var inspectorMode = 0
    @State private var canvasEditTransaction: AnnotationDocumentController.ContinuousEditToken?

    @ObservedObject var commandGate: CanvasEditorCommandGate

    let onCopy: () -> Void
    let onExport: () -> Void
    let onDone: () -> Void

    init(
        session: AnnotationEditingSession,
        settingsStore: SettingsStore,
        commandGate: CanvasEditorCommandGate,
        onCopy: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.session = session
        self._controller = ObservedObject(wrappedValue: session.controller)
        self._settingsStore = ObservedObject(wrappedValue: settingsStore)
        self.commandGate = commandGate
        self.onCopy = onCopy
        self.onExport = onExport
        self.onDone = onDone
    }

    var body: some View {
        HStack(spacing: 0) {
            toolRail
            Divider()
            VStack(spacing: 0) {
                commandBar
                Divider()
                CanvasScrollView(
                    session: session,
                    editorSettings: settingsStore.settings.editor,
                    zoomModel: zoom,
                    commandGate: commandGate,
                    onCopy: onCopy
                )
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                statusBar
            }
            Divider()
            inspector
                .frame(width: 280)
        }
        .disabled(commandGate.isInteractionSuspended)
        .onDisappear {
            if let transaction = canvasEditTransaction {
                _ = controller.commitContinuousEdit(transaction)
                canvasEditTransaction = nil
            }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            Button {
                performCanvasCommand(reason: "undo", action: controller.undo)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
                .disabled(!controller.canUndo)
                .help("Undo")
                .accessibilityLabel("Undo")
            Button {
                performCanvasCommand(reason: "redo", action: controller.redo)
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
                .disabled(!controller.canRedo)
                .help("Redo")
                .accessibilityLabel("Redo")
            Divider().frame(height: 20)
            Button { zoom.magnification = max(0.1, zoom.magnification - 0.1) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            .accessibilityLabel("Zoom out")
            Button("\(Int(zoom.magnification * 100))%") { zoom.magnification = 1 }
                .monospacedDigit()
                .frame(minWidth: 52)
                .help("Actual size")
            Button { zoom.magnification = min(4, zoom.magnification + 0.1) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
            Button("Fit") { zoom.fit() }
                .help("Fit canvas in window")
                .accessibilityLabel("Fit canvas in window")
            Spacer()
            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                onExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
                .buttonStyle(.borderedProminent)
            Button("Done") {
                onDone()
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private func performCanvasCommand(reason: String, action: () -> Void) {
        guard commandGate.resolveActiveTextEditing(reason: reason) else { return }
        action()
    }

    private var toolRail: some View {
        VStack(spacing: 5) {
            ForEach(AnnotationTool.quickToolbarOrder) { tool in
                Button {
                    session.currentTool = tool
                } label: {
                    toolSymbol(for: tool)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(session.currentTool == tool ? Color.accentColor.opacity(0.22) : .clear)
                )
                .help(NSLocalizedString(tool.rawValue.capitalized, comment: "Annotation tool name"))
                .accessibilityIdentifier("editor.tool.\(tool.rawValue)")
                .accessibilityLabel(NSLocalizedString(tool.rawValue.capitalized, comment: "Annotation tool name"))
                .accessibilityValue(NSLocalizedString(
                    session.currentTool == tool ? "Selected" : "Not selected",
                    comment: "Annotation tool selection state"
                ))
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .background(.thinMaterial)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorMode) {
                Text("Properties").tag(0)
                Text("Layers").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if inspectorMode == 0 {
                propertiesInspector
            } else {
                layersInspector
            }
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var propertiesInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let item = selectedItem {
                    SelectionPropertiesInspector(
                        item: item,
                        controller: controller,
                        commandGate: commandGate,
                        onError: { error in
                            session.onError?(error)
                        }
                    )
                    .id(item.id)
                } else {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "cursorarrow",
                        description: Text("Select one or more annotations to edit transforms and alignment.")
                    )
                }

                GroupBox("Canvas") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Background", selection: backgroundChoiceBinding) {
                            Text("Transparent").tag(CanvasBackgroundChoice.transparent)
                            Text("Solid").tag(CanvasBackgroundChoice.solid)
                            Text("Padded").tag(CanvasBackgroundChoice.padded)
                        }
                        if case .padded = controller.document.background {
                            LabeledContent("Padding") {
                                Slider(
                                    value: paddingBinding,
                                    in: 0...200,
                                    onEditingChanged: { editing in
                                        updateCanvasEditLifecycle(
                                            editing: editing,
                                            label: "Change padding",
                                            owner: "canvas-padding"
                                        )
                                    }
                                )
                            }
                        }
                        LabeledContent("Corner radius") {
                            Slider(
                                value: documentBinding(
                                    get: { $0.canvasEffects.cornerRadius },
                                    set: { $0.canvasEffects.cornerRadius = $1 }
                                ),
                                in: 0...80,
                                onEditingChanged: { editing in
                                    updateCanvasEditLifecycle(
                                        editing: editing,
                                        label: "Edit canvas",
                                        owner: "canvas-corner-radius"
                                    )
                                }
                            )
                        }
                        Toggle("Shadow", isOn: shadowBinding)
                        Button("Rotate 90° Clockwise") {
                            controller.perform(label: "Rotate canvas") { document in
                                document.rotation = RotationState(
                                    quarterTurnsClockwise: document.rotation.quarterTurnsClockwise + 1
                                )
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var layersInspector: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(controller.document.orderedAnnotations.reversed()) { item in
                    LayerRow(item: item, controller: controller)
                }
            }
            .padding(10)
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(Int(session.previewImage.pixelSize.width)) × \(Int(session.previewImage.pixelSize.height)) px")
            Divider().frame(height: 14)
            Text("\(Int(zoom.magnification * 100))%")
            Divider().frame(height: 14)
            Text(session.previewImage.colorSpace?.name as String? ?? NSLocalizedString(
                "Unspecified color space",
                comment: "Canvas color-space fallback"
            ))
            Spacer()
            Text(controller.document.annotations.count == 1 ? "1 layer" : "\(controller.document.annotations.count) layers")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var selectedItem: AnnotationItem? {
        controller.document.orderedAnnotations.reversed().first {
            controller.selectedItemIDs.contains($0.id)
        }
    }

    private func documentBinding<Value>(
        get: @escaping (AnnotationDocument) -> Value,
        set: @escaping (inout AnnotationDocument, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { @MainActor in get(controller.document) },
            set: { @MainActor value in
                guard !commandGate.isInteractionSuspended else { return }
                if let transaction = canvasEditTransaction {
                    guard controller.isContinuousEditActive(transaction) else {
                        canvasEditTransaction = nil
                        return
                    }
                    _ = controller.previewContinuousEdit(transaction) { set(&$0, value) }
                } else {
                    controller.perform(label: "Edit canvas") { set(&$0, value) }
                }
            }
        )
    }

    private var backgroundChoiceBinding: Binding<CanvasBackgroundChoice> {
        Binding(
            get: { @MainActor in
                switch controller.document.background {
                case .transparent: return .transparent
                case .solid: return .solid
                case .padded: return .padded
                }
            },
            set: { @MainActor choice in
                guard !commandGate.isInteractionSuspended else { return }
                controller.perform(label: "Change background") { document in
                    switch choice {
                    case .transparent: document.background = .transparent
                    case .solid: document.background = .solid(.white)
                    case .padded: document.background = .padded(color: .white, amount: 32)
                    }
                }
            }
        )
    }

    private var paddingBinding: Binding<CGFloat> {
        Binding(
            get: { @MainActor in
                if case .padded(_, let amount) = controller.document.background { return amount }
                return 0
            },
            set: { @MainActor amount in
                guard !commandGate.isInteractionSuspended else { return }
                let mutation: (inout AnnotationDocument) -> Void = { document in
                    let color: RGBAColor
                    if case .padded(let existing, _) = document.background { color = existing }
                    else { color = .white }
                    document.background = .padded(color: color, amount: amount)
                }
                if let transaction = canvasEditTransaction {
                    guard controller.isContinuousEditActive(transaction) else {
                        canvasEditTransaction = nil
                        return
                    }
                    _ = controller.previewContinuousEdit(transaction, mutation: mutation)
                } else {
                    controller.perform(label: "Change padding", mutation: mutation)
                }
            }
        )
    }

    private func updateCanvasEditLifecycle(
        editing: Bool,
        label: String,
        owner: String
    ) {
        guard !commandGate.isInteractionSuspended else { return }
        if editing {
            canvasEditTransaction = controller.beginContinuousEdit(
                label: label,
                owner: owner
            )
        } else if let transaction = canvasEditTransaction {
            _ = controller.commitContinuousEdit(transaction)
            canvasEditTransaction = nil
        }
    }

    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { @MainActor in controller.document.canvasEffects.shadow != nil },
            set: { @MainActor enabled in
                guard !commandGate.isInteractionSuspended else { return }
                controller.perform(label: "Toggle canvas shadow") { document in
                    document.canvasEffects.shadow = enabled ? AnnotationShadow() : nil
                }
            }
        )
    }

    @ViewBuilder
    private func toolSymbol(for tool: AnnotationTool) -> some View {
        if tool == .text {
            Text(verbatim: "T")
                .font(.system(size: 15, weight: .semibold))
        } else {
            Image(systemName: tool.toolbarSystemSymbolName)
        }
    }
}

private struct SelectionPropertiesInspector: View {
    let item: AnnotationItem
    @ObservedObject var controller: AnnotationDocumentController
    @ObservedObject var commandGate: CanvasEditorCommandGate
    let onError: (Error) -> Void
    @State private var draft: AnnotationInspectorDraft
    @State private var editTransaction: AnnotationDocumentController.ContinuousEditToken?
    @FocusState private var isTextFieldFocused: Bool
    @State private var finalizerID = UUID()

    init(
        item: AnnotationItem,
        controller: AnnotationDocumentController,
        commandGate: CanvasEditorCommandGate,
        onError: @escaping (Error) -> Void
    ) {
        self.item = item
        self.controller = controller
        self.commandGate = commandGate
        self.onError = onError
        _draft = State(initialValue: AnnotationInspectorDraft(item: item))
    }

    var body: some View {
        GroupBox("Selection") {
            VStack(alignment: .leading, spacing: 10) {
                Text(draft.item.name).font(.headline)
                LabeledContent("Line width") {
                    inspectorSlider(
                        value: $draft.lineWidth,
                        range: 1...24,
                        label: "Edit line width",
                        owner: "selection-line-width"
                    )
                }
                LabeledContent("Opacity") {
                    inspectorSlider(
                        value: $draft.opacity,
                        range: 0.05...1,
                        label: "Edit opacity",
                        owner: "selection-opacity"
                    )
                }
                LabeledContent("Rotation") {
                    inspectorSlider(
                        value: $draft.rotationDegrees,
                        range: -180...180,
                        label: "Edit rotation",
                        owner: "selection-rotation"
                    )
                }
                if draft.item.kind.allowsUserResize && draft.item.kind != .text {
                    LabeledContent("Scale X") {
                        inspectorSlider(
                            value: $draft.scaleX,
                            range: 0.1...4,
                            label: "Edit horizontal scale",
                            owner: "selection-scale-x"
                        )
                    }
                    LabeledContent("Scale Y") {
                        inspectorSlider(
                            value: $draft.scaleY,
                            range: 0.1...4,
                            label: "Edit vertical scale",
                            owner: "selection-scale-y"
                        )
                    }
                }
                if draft.item.kind == .text {
                    TextField("Text", text: $draft.text)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            finishInspectorEdit(
                                reason: "text-submit",
                                expectedOwner: "selection-text"
                            )
                            if isTextFieldFocused {
                                beginInspectorEdit(
                                    label: "Edit text",
                                    owner: "selection-text"
                                )
                            }
                        }
                    LabeledContent("Font size") {
                        inspectorSlider(
                            value: $draft.fontSize,
                            range: 8...96,
                            label: "Edit font size",
                            owner: "selection-font-size"
                        )
                    }
                }
            }
        }

        GroupBox("Align & Distribute") {
            VStack(spacing: 8) {
                HStack {
                    alignmentButton("align.horizontal.left", .leading)
                    alignmentButton("align.horizontal.center", .horizontalCenter)
                    alignmentButton("align.horizontal.right", .trailing)
                    alignmentButton("align.vertical.top", .top)
                    alignmentButton("align.vertical.center", .verticalCenter)
                    alignmentButton("align.vertical.bottom", .bottom)
                }
                HStack {
                    Button("Distribute H") { controller.distributeSelection(along: .horizontal) }
                    Button("Distribute V") { controller.distributeSelection(along: .vertical) }
                }
            }
        }
        .onChange(of: item) { _, updatedItem in
            guard updatedItem.id == draft.item.id else {
                preconditionFailure("A selection inspector must not be reused for another annotation identity.")
            }
            if let transaction = editTransaction,
               !controller.isContinuousEditActive(transaction) {
                editTransaction = nil
            }
            if draft.item != updatedItem {
                draft = AnnotationInspectorDraft(item: updatedItem)
            }
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            guard !commandGate.isInteractionSuspended else { return }
            if focused {
                beginInspectorEdit(label: "Edit text", owner: "selection-text")
            } else {
                finishInspectorEdit(
                    reason: "text-blur",
                    expectedOwner: "selection-text"
                )
            }
        }
        .onChange(of: draft) { _, updatedDraft in
            guard !commandGate.isInteractionSuspended else { return }
            do {
                try Self.applyInspectorDraft(
                    updatedDraft,
                    itemID: item.id,
                    controller: controller,
                    transactionBinding: $editTransaction
                )
            } catch {
                rejectInspectorUpdate(
                    error,
                    operation: "apply-draft",
                    transaction: editTransaction,
                    annotationID: updatedDraft.item.id
                )
            }
        }
        .onAppear {
            let draftBinding = $draft
            let transactionBinding = $editTransaction
            let controller = controller
            let itemID = item.id
            commandGate.registerInspectorFinalizer(identifier: finalizerID) {
                guard controller.selectedItemIDs.contains(itemID) else { return }
                try Self.applyInspectorDraft(
                    draftBinding.wrappedValue,
                    itemID: itemID,
                    controller: controller,
                    transactionBinding: transactionBinding
                )
                if let transaction = transactionBinding.wrappedValue {
                    _ = controller.commitContinuousEdit(transaction)
                    transactionBinding.wrappedValue = nil
                }
            }
        }
        .onDisappear {
            commandGate.unregisterInspectorFinalizer(identifier: finalizerID)
            finishInspectorEdit(reason: "inspector-disappear")
        }
    }

    private static func applyInspectorDraft(
        _ updatedDraft: AnnotationInspectorDraft,
        itemID: UUID,
        controller: AnnotationDocumentController,
        transactionBinding: Binding<AnnotationDocumentController.ContinuousEditToken?>
    ) throws {
        guard updatedDraft.item.id == itemID else {
            preconditionFailure("A selection inspector draft changed annotation identity.")
        }
        guard let storedItem = controller.document.annotations.first(where: {
            $0.id == updatedDraft.item.id
        }) else {
            AppLog.capture.notice(
                "Discarded an inspector update after its annotation left the document: annotationID=\(updatedDraft.item.id.uuidString, privacy: .public)"
            )
            return
        }
        let transaction: AnnotationDocumentController.ContinuousEditToken?
        if let candidate = transactionBinding.wrappedValue {
            guard controller.isContinuousEditActive(candidate) else {
                AppLog.capture.notice(
                    "Discarded a stale Canvas inspector draft update: owner=\(candidate.owner, privacy: .public), annotationID=\(updatedDraft.item.id.uuidString, privacy: .public)"
                )
                transactionBinding.wrappedValue = nil
                return
            }
            transaction = candidate
        } else {
            transaction = nil
        }
        if storedItem.kind == .text {
            let strategy: AnnotationTextWrapWidthStrategy = abs(
                storedItem.style.fontSize - updatedDraft.item.style.fontSize
            ) > 0.000_001 ? .scaleWithFont : .preserve
            if let transaction {
                _ = try controller.previewTextItemLayout(
                    transaction: transaction,
                    id: updatedDraft.item.id,
                    text: updatedDraft.item.text ?? "",
                    fontSize: updatedDraft.item.style.fontSize,
                    wrapWidthStrategy: strategy
                ) { updatedItem in
                    updatedItem.style.lineWidth = updatedDraft.item.style.lineWidth
                    updatedItem.opacity = updatedDraft.item.opacity
                    updatedItem.transform.rotationRadians = updatedDraft.item.transform.rotationRadians
                }
            } else {
                try controller.updateTextItemLayout(
                    id: updatedDraft.item.id,
                    text: updatedDraft.item.text ?? "",
                    fontSize: updatedDraft.item.style.fontSize,
                    wrapWidthStrategy: strategy
                ) { updatedItem in
                    updatedItem.style.lineWidth = updatedDraft.item.style.lineWidth
                    updatedItem.opacity = updatedDraft.item.opacity
                    updatedItem.transform.rotationRadians = updatedDraft.item.transform.rotationRadians
                }
            }
            return
        }
        let resolvedItem = updatedDraft.resolvedNonTextItem(from: storedItem)
        guard storedItem != resolvedItem else { return }
        if let transaction {
            _ = controller.previewContinuousEdit(transaction) { document in
                guard let index = document.annotations.firstIndex(where: {
                    $0.id == updatedDraft.item.id
                }) else {
                    preconditionFailure("A continuous inspector preview lost its annotation identity.")
                }
                guard !document.annotations[index].isLocked else { return }
                document.annotations[index] = resolvedItem
            }
        } else {
            controller.updateItem(id: updatedDraft.item.id) { storedItem in
                storedItem = resolvedItem
            }
        }
    }

    private func rejectInspectorUpdate(
        _ error: Error,
        operation: String,
        transaction: AnnotationDocumentController.ContinuousEditToken?,
        annotationID: UUID
    ) {
        if let transaction {
            _ = controller.cancelContinuousEdit(transaction)
            editTransaction = nil
        }
        if let restoredItem = controller.document.annotations.first(where: {
            $0.id == annotationID
        }) {
            draft = AnnotationInspectorDraft(item: restoredItem)
        }
        let nsError = error as NSError
        AppLog.capture.error(
            "Rejected Canvas inspector update before document publication: operation=\(operation, privacy: .public), annotationID=\(annotationID.uuidString, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public), cancelledContinuousEdit=\(transaction != nil, privacy: .public)"
        )
        onError(error)
    }

    private func inspectorSlider(
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        label: String,
        owner: String
    ) -> some View {
        Slider(
            value: value,
            in: range,
            onEditingChanged: { editing in
                if editing {
                    beginInspectorEdit(label: label, owner: owner)
                } else {
                    finishInspectorEdit(reason: "slider-end", expectedOwner: owner)
                }
            }
        )
    }

    private func beginInspectorEdit(label: String, owner: String) {
        guard !commandGate.isInteractionSuspended else { return }
        if let transaction = editTransaction,
           controller.isContinuousEditActive(transaction),
           transaction.owner == owner {
            return
        }
        editTransaction = controller.beginContinuousEdit(
            label: label,
            owner: owner,
            itemID: item.id
        )
    }

    private func finishInspectorEdit(reason: String, expectedOwner: String? = nil) {
        guard let transaction = editTransaction else { return }
        if let expectedOwner, transaction.owner != expectedOwner {
            return
        }
        if !controller.commitContinuousEdit(transaction) {
            AppLog.capture.notice(
                "Canvas inspector observed an already-finished continuous edit: reason=\(reason, privacy: .public), owner=\(transaction.owner, privacy: .public), annotationID=\(item.id.uuidString, privacy: .public)"
            )
        }
        editTransaction = nil
    }

    private func alignmentButton(
        _ symbol: String,
        _ alignment: AnnotationDocumentController.Alignment
    ) -> some View {
        Button { controller.alignSelection(alignment) } label: { Image(systemName: symbol) }
            .help("Align")
            .accessibilityLabel(alignmentAccessibilityLabel(alignment))
    }

    private func alignmentAccessibilityLabel(
        _ alignment: AnnotationDocumentController.Alignment
    ) -> String {
        let key: String
        switch alignment {
        case .leading: key = "Align left"
        case .horizontalCenter: key = "Align horizontal centers"
        case .trailing: key = "Align right"
        case .top: key = "Align top"
        case .verticalCenter: key = "Align vertical centers"
        case .bottom: key = "Align bottom"
        }
        return NSLocalizedString(key, comment: "Canvas alignment action")
    }
}

private struct AnnotationInspectorDraft: Equatable {
    var item: AnnotationItem

    var lineWidth: CGFloat {
        get { item.style.lineWidth }
        set { item.style.lineWidth = newValue }
    }

    var opacity: CGFloat {
        get { item.opacity }
        set { item.opacity = newValue }
    }

    var rotationDegrees: CGFloat {
        get { item.transform.rotationRadians * 180 / .pi }
        set { item.transform.rotationRadians = newValue * .pi / 180 }
    }

    var scaleX: CGFloat {
        get { item.transform.scaleX }
        set { item.transform.scaleX = newValue }
    }

    var scaleY: CGFloat {
        get { item.transform.scaleY }
        set { item.transform.scaleY = newValue }
    }

    var text: String {
        get { item.text ?? "" }
        set { item.text = newValue }
    }

    var fontSize: CGFloat {
        get { item.style.fontSize }
        set { item.style.fontSize = newValue }
    }

    func resolvedNonTextItem(from storedItem: AnnotationItem) -> AnnotationItem {
        precondition(
            storedItem.id == item.id && storedItem.kind == item.kind && item.kind != .text,
            "A non-text inspector draft can resolve only its original annotation identity and kind."
        )
        var resolved = storedItem
        resolved.style.lineWidth = item.style.lineWidth
        resolved.opacity = item.opacity
        resolved.transform.rotationRadians = item.transform.rotationRadians
        if storedItem.kind.allowsUserResize {
            resolved.transform.scaleX = item.transform.scaleX
            resolved.transform.scaleY = item.transform.scaleY
        }
        return resolved
    }
}

private enum CanvasBackgroundChoice: Hashable {
    case transparent, solid, padded
}

private struct LayerRow: View {
    let item: AnnotationItem
    @ObservedObject var controller: AnnotationDocumentController

    var body: some View {
        let visibilityTitle = NSLocalizedString(
            item.isVisible ? "Hide layer" : "Show layer",
            comment: "Layer visibility action"
        )
        let selectionTitle = NSLocalizedString(
            controller.selectedItemIDs.contains(item.id) ? "Deselect layer" : "Select layer",
            comment: "Layer selection action"
        )
        let lockTitle = NSLocalizedString(
            item.isLocked ? "Unlock layer" : "Lock layer",
            comment: "Layer lock action"
        )
        HStack(spacing: 6) {
            Button {
                controller.setVisibility(id: item.id, isVisible: !item.isVisible)
            } label: {
                Image(systemName: item.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .help(visibilityTitle)
            .accessibilityLabel(visibilityTitle)

            Button {
                if controller.selectedItemIDs.contains(item.id) {
                    controller.selectedItemIDs.remove(item.id)
                } else {
                    controller.selectedItemIDs.insert(item.id)
                }
            } label: {
                Image(systemName: controller.selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .help(selectionTitle)
            .accessibilityLabel(selectionTitle)

            TextField("Layer name", text: Binding(
                get: { @MainActor in item.name },
                set: { @MainActor name in controller.rename(id: item.id, name: name) }
            ))
            .textFieldStyle(.plain)

            Button {
                controller.setLocked(id: item.id, isLocked: !item.isLocked)
            } label: {
                Image(systemName: item.isLocked ? "lock.fill" : "lock.open")
            }
            .buttonStyle(.plain)
            .help(lockTitle)
            .accessibilityLabel(lockTitle)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(controller.selectedItemIDs.contains(item.id) ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
        )
        .contextMenu {
            Button("Bring to Front") {
                controller.selectedItemIDs = [item.id]
                controller.bringSelectionToFront()
            }
            Button("Send to Back") {
                controller.selectedItemIDs = [item.id]
                controller.sendSelectionToBack()
            }
            Divider()
            Button("Delete", role: .destructive) {
                controller.selectedItemIDs = [item.id]
                controller.deleteSelection()
            }
        }
    }
}

private struct CanvasScrollView: NSViewRepresentable {
    let session: AnnotationEditingSession
    let editorSettings: EditorSettings
    @ObservedObject var zoomModel: CanvasZoomModel
    let commandGate: CanvasEditorCommandGate
    let onCopy: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomModel: zoomModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 4

        let canvas = QuickAnnotationCanvasView(session: session)
        canvas.frame = NSRect(origin: .zero, size: session.previewImage.logicalSize)
        canvas.onCopyFinalImage = onCopy
        scrollView.documentView = canvas
        context.coordinator.canvas = canvas
        context.coordinator.scrollView = scrollView
        context.coordinator.commandGate = commandGate
        commandGate.register(canvas)
        canvas.applyEditorSettings(editorSettings)
        context.coordinator.lastEditorSettings = editorSettings
        context.coordinator.startObserving()
        DispatchQueue.main.async {
            scrollView.magnify(toFit: canvas.bounds)
            zoomModel.magnification = scrollView.magnification
        }
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.commandGate?.unregister(coordinator.canvas)
        coordinator.stopObserving()
        scrollView.documentView = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.lastEditorSettings != editorSettings {
            context.coordinator.lastEditorSettings = editorSettings
            context.coordinator.canvas?.applyEditorSettings(editorSettings)
        }

        if let canvas = context.coordinator.canvas,
           canvas.frame.size != session.previewImage.logicalSize {
            canvas.setFrameSize(session.previewImage.logicalSize)
        }

        if context.coordinator.lastFitRequest != zoomModel.fitRequest {
            context.coordinator.lastFitRequest = zoomModel.fitRequest
            if let canvas = context.coordinator.canvas {
                scrollView.magnify(toFit: canvas.bounds)
                DispatchQueue.main.async { zoomModel.magnification = scrollView.magnification }
            }
        } else if abs(scrollView.magnification - zoomModel.magnification) > 0.001 {
            scrollView.setMagnification(zoomModel.magnification, centeredAt: scrollView.contentView.bounds.center)
        }
    }

    final class Coordinator: NSObject {
        let zoomModel: CanvasZoomModel
        weak var canvas: QuickAnnotationCanvasView?
        weak var scrollView: NSScrollView?
        weak var commandGate: CanvasEditorCommandGate?
        var lastFitRequest: UUID?
        var lastEditorSettings: EditorSettings?
        private var observer: NSObjectProtocol?

        init(zoomModel: CanvasZoomModel) {
            self.zoomModel = zoomModel
        }

        func startObserving() {
            guard let scrollView else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] notification in
                guard let scroll = notification.object as? NSScrollView else { return }
                Task { @MainActor in self?.zoomModel.magnification = scroll.magnification }
            }
        }

        func stopObserving() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }

        deinit {
            stopObserving()
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
