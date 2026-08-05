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

struct CanvasEditorRootView: View {
    @ObservedObject var session: AnnotationEditingSession
    @ObservedObject private var controller: AnnotationDocumentController
    @ObservedObject private var settingsStore: SettingsStore
    @StateObject private var zoom = CanvasZoomModel()
    @State private var inspectorMode = 0

    let onCopy: () -> Void
    let onExport: () -> Void
    let onDone: () -> Void

    init(
        session: AnnotationEditingSession,
        settingsStore: SettingsStore,
        onCopy: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.session = session
        self._controller = ObservedObject(wrappedValue: session.controller)
        self._settingsStore = ObservedObject(wrappedValue: settingsStore)
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
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            Button(action: controller.undo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!controller.canUndo)
                .help("Undo")
                .accessibilityLabel("Undo")
            Button(action: controller.redo) { Image(systemName: "arrow.uturn.forward") }
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
            Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
            Button(action: onExport) { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
            Button("Done", action: onDone)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 46)
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
                        controller: controller
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
                                Slider(value: paddingBinding, in: 0...200)
                            }
                        }
                        LabeledContent("Corner radius") {
                            Slider(value: documentBinding(get: { $0.canvasEffects.cornerRadius }, set: { $0.canvasEffects.cornerRadius = $1 }), in: 0...80)
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
                controller.perform(label: "Edit canvas") { set(&$0, value) }
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
                controller.perform(label: "Change padding") { document in
                    let color: RGBAColor
                    if case .padded(let existing, _) = document.background { color = existing }
                    else { color = .white }
                    document.background = .padded(color: color, amount: amount)
                }
            }
        )
    }

    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { @MainActor in controller.document.canvasEffects.shadow != nil },
            set: { @MainActor enabled in
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
    @State private var draft: AnnotationInspectorDraft

    init(item: AnnotationItem, controller: AnnotationDocumentController) {
        self.item = item
        self.controller = controller
        _draft = State(initialValue: AnnotationInspectorDraft(item: item))
    }

    var body: some View {
        GroupBox("Selection") {
            VStack(alignment: .leading, spacing: 10) {
                Text(draft.item.name).font(.headline)
                LabeledContent("Line width") {
                    Slider(value: $draft.lineWidth, in: 1...24)
                }
                LabeledContent("Opacity") {
                    Slider(value: $draft.opacity, in: 0.05...1)
                }
                LabeledContent("Rotation") {
                    Slider(value: $draft.rotationDegrees, in: -180...180)
                }
                if draft.item.kind.allowsUserResize {
                    LabeledContent("Scale X") {
                        Slider(value: $draft.scaleX, in: 0.1...4)
                    }
                    LabeledContent("Scale Y") {
                        Slider(value: $draft.scaleY, in: 0.1...4)
                    }
                }
                if draft.item.kind == .text {
                    TextField("Text", text: $draft.text)
                    LabeledContent("Font size") {
                        Slider(value: $draft.fontSize, in: 8...96)
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
            if draft.item != updatedItem {
                draft = AnnotationInspectorDraft(item: updatedItem)
            }
        }
        .onChange(of: draft) { _, updatedDraft in
            guard updatedDraft.item.id == item.id else {
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
            guard storedItem != updatedDraft.item else { return }
            controller.updateItem(id: updatedDraft.item.id) { storedItem in
                storedItem = updatedDraft.item
            }
        }
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
        canvas.applyEditorSettings(editorSettings)
        context.coordinator.lastEditorSettings = editorSettings
        context.coordinator.startObserving()
        DispatchQueue.main.async {
            scrollView.magnify(toFit: canvas.bounds)
            zoomModel.magnification = scrollView.magnification
        }
        return scrollView
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

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
