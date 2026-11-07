import AppKit
import Combine
import UshotCore

@MainActor
final class AnnotationEditingSession: ObservableObject {
    enum PreviewRenderingMode {
        case continuous
        case regionDraft
    }

    private struct RenderRequest {
        enum Kind { case authoritative, interactive }

        let kind: Kind
        let generation: Int
        let baseGeneration: Int
        let baseImage: CapturedImage
        let document: AnnotationDocument
        let logicalDocument: AnnotationDocument
        let excludedAnnotationIDs: Set<UUID>
    }

    struct HistoryPreviewSnapshot {
        let document: AnnotationDocument
        let previewImage: CapturedImage
    }

    enum CurrentStyleOrigin: Equatable {
        case toolDefault
        case existingAnnotation
        case newTextDraft
    }

    @Published var currentTool: AnnotationTool = .select {
        didSet {
            guard currentTool != oldValue else { return }
            let toolDefault = defaultStyle(for: currentTool)
            currentToolDefaultStyle = toolDefault
            let keepsExistingSelectionPresentation = currentStyleOrigin == .existingAnnotation
                && !controller.selectedItemIDs.isEmpty
            if !keepsExistingSelectionPresentation {
                adoptCurrentStyle(toolDefault, origin: .toolDefault)
            }
            AppLog.capture.debug(
                "Loaded annotation tool defaults: tool=\(self.currentTool.rawValue, privacy: .public), color=\(AnnotationColorPalette.hexString(for: toolDefault.strokeColor), privacy: .public), font=\(toolDefault.fontName ?? "system", privacy: .public), keptSelectionPresentation=\(keepsExistingSelectionPresentation, privacy: .public)"
            )
        }
    }
    @Published var currentStyle: AnnotationStyle
    private(set) var currentStyleOrigin: CurrentStyleOrigin = .toolDefault
    private var currentToolDefaultStyle: AnnotationStyle
    private var textFontSelection: AnnotationTextFontSelection?
    private var arrowHeadStyleSelection: ArrowHeadStyle?
    @Published var lineWidthUnit: AnnotationLineWidthUnit
    @Published private(set) var baseImage: CapturedImage
    @Published private(set) var previewImage: CapturedImage
    @Published private(set) var authoritativePreviewImage: CapturedImage
    @Published private(set) var renderedPreviewExcludedAnnotationIDs: Set<UUID> = []
    @Published private(set) var renderedPreviewDocument: AnnotationDocument?
    /// The only preview/document pair safe for history persistence. Interactive
    /// exclusion renders never enter this snapshot, and a renderer revision is
    /// upgraded only when its authoritative render has actually succeeded.
    @Published private(set) var historyPreviewSnapshot: HistoryPreviewSnapshot?

    let controller: AnnotationDocumentController
    var onError: ((Error) -> Void)?

    private let renderer: any AnnotationRendering
    private let updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    private var editorSettings: EditorSettings
    private var cancellables: Set<AnyCancellable> = []
    private var authoritativeRenderGeneration = 0
    private var interactiveRenderGeneration = 0
    private var baseGeneration = 0
    private var renderedBaseGeneration = 0
    private var previewRenderingMode: PreviewRenderingMode
    private var renderPipelineTask: Task<Void, Never>?
    private var activeRender: RenderRequest?
    private var pendingAuthoritativeRender: RenderRequest?
    private var pendingInteractiveRender: RenderRequest?
    private var authoritativeRenderFailure: (generation: Int, error: Error)?
    private var authoritativeRenderedDocument: AnnotationDocument?
    private var historyRecorder: HistorySessionRecorder?
    private var previewExcludedAnnotationIDs: Set<UUID> = []
    /// Configured logical region corner radius for this session, when the session
    /// was created as a region draft. Used to reclamp after resize commits.
    private let storedConfiguredRegionCornerRadius: CGFloat?

    /// Configured logical region corner radius for region drafts; `nil` otherwise.
    var configuredRegionCornerRadius: CGFloat? { storedConfiguredRegionCornerRadius }

    init(
        capturedImage: CapturedImage,
        previewImage: CapturedImage? = nil,
        document: AnnotationDocument? = nil,
        editorSettings: EditorSettings,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker,
        renderer: any AnnotationRendering = AnnotationRenderer(),
        configuredRegionCornerRadius: CGFloat? = nil,
        previewRenderingMode: PreviewRenderingMode = .continuous
    ) {
        baseImage = capturedImage
        self.previewImage = previewImage ?? capturedImage
        self.authoritativePreviewImage = previewImage ?? capturedImage
        self.renderer = renderer
        self.previewRenderingMode = previewRenderingMode
        self.updateSensitiveActivityTracker = updateSensitiveActivityTracker
        self.editorSettings = editorSettings
        self.storedConfiguredRegionCornerRadius = configuredRegionCornerRadius
        lineWidthUnit = editorSettings.defaultLineWidthUnit
        let initialStyle = Self.makeDefaultStyle(
            for: .select,
            editorSettings: editorSettings,
            backingScale: capturedImage.scale
        )
        currentStyle = initialStyle
        currentToolDefaultStyle = initialStyle
        let reference = ImageReference(
            relativePath: "base.png",
            pixelSize: capturedImage.pixelSize,
            colorSpaceName: capturedImage.colorSpace?.name as String?
        )
        var initialDocument = document ?? AnnotationDocument(
            baseImageReference: reference,
            canvasSize: capturedImage.logicalSize
        )
        let normalizedHighlightCount = initialDocument.normalizeHighlightStylesForEditing()
        controller = AnnotationDocumentController(document: initialDocument)
        if normalizedHighlightCount > 0 {
            AppLog.capture.notice(
                "Normalized legacy highlight styles for editor admission: count=\(normalizedHighlightCount, privacy: .public)"
            )
        }
        let hasMatchingPreviewSource = previewImage != nil || document == nil
        let cachedPreviewIsCompatible = initialDocument.isCachedPreviewCompatibleWithCurrentRenderer
        // A persisted preview was rendered from the pre-normalized document.
        // When migration changes highlight presentation (for example a legacy
        // custom fill alpha), or its renderer revision changed visible pixels,
        // it cannot be declared authoritative for the admitted document.
        if normalizedHighlightCount == 0,
           hasMatchingPreviewSource,
           cachedPreviewIsCompatible {
            authoritativeRenderedDocument = controller.document
            renderedPreviewDocument = controller.document
            historyPreviewSnapshot = HistoryPreviewSnapshot(
                document: controller.document,
                previewImage: self.authoritativePreviewImage
            )
        } else if previewImage != nil, !cachedPreviewIsCompatible {
            AppLog.history.notice(
                "Rejected cached annotation preview for renderer refresh: storedRevision=\(initialDocument.cachedPreviewRenderRevision, privacy: .public), currentRevision=\(AnnotationDocument.currentCachedPreviewRenderRevision, privacy: .public), affectedAnnotations=\(initialDocument.cachedPreviewRevisionAffectedAnnotationCount, privacy: .public)"
            )
        }

        controller.documentPublisher
            .dropFirst()
            .sink { [weak self] document in self?.scheduleRender(document: document) }
            .store(in: &cancellables)

        if authoritativeRenderedDocument == nil {
            scheduleRender(document: controller.document)
        }
    }

    private func scheduleRender(document sourceDocument: AnnotationDocument) {
        authoritativeRenderGeneration += 1
        authoritativeRenderFailure = nil
        pendingAuthoritativeRender = nil
        if defersPreviewRendering(for: sourceDocument) {
            if !hasAuthoritativePreview(for: sourceDocument) {
                authoritativeRenderedDocument = nil
                historyPreviewSnapshot = nil
                authoritativePreviewImage = baseImage
                previewImage = baseImage
                renderedPreviewDocument = nil
                renderedPreviewExcludedAnnotationIDs = []
            }
        } else {
            requestAuthoritativeRender(document: sourceDocument)
        }
        scheduleInteractivePreview(document: sourceDocument)
    }

    var supportsDirectInteractiveComposition: Bool {
        Self.supportsDirectInteractiveComposition(document: controller.document)
    }

    private static func supportsDirectInteractiveComposition(document: AnnotationDocument) -> Bool {
        guard document.crop.rect == nil,
              document.rotation.quarterTurnsClockwise == 0,
              document.canvasEffects.shadow == nil,
              case .transparent = document.background
        else { return false }
        return true
    }

    private func defersPreviewRendering(for document: AnnotationDocument) -> Bool {
        previewRenderingMode == .regionDraft && Self.supportsDirectInteractiveComposition(document: document)
    }

    func finishRegionDraft() {
        previewRenderingMode = .continuous
        scheduleRender(document: controller.document)
    }

    private func hasAuthoritativePreview(for document: AnnotationDocument) -> Bool {
        authoritativeRenderedDocument == document && renderedBaseGeneration == baseGeneration
    }

    private func requestAuthoritativeRender(document: AnnotationDocument) {
        guard !hasAuthoritativePreview(for: document) else { return }
        if let activeRender,
           activeRender.kind == .authoritative,
           isCurrent(activeRender) { return }
        if let pendingAuthoritativeRender, isCurrent(pendingAuthoritativeRender) { return }
        authoritativeRenderFailure = nil
        pendingAuthoritativeRender = RenderRequest(
            kind: .authoritative,
            generation: authoritativeRenderGeneration,
            baseGeneration: baseGeneration,
            baseImage: baseImage,
            document: document,
            logicalDocument: document,
            excludedAnnotationIDs: []
        )
        startRenderPipelineIfNeeded()
    }

    func resolvedPreviewImage() async throws -> CapturedImage {
        while true {
            try Task.checkCancellation()
            let document = controller.document
            if hasAuthoritativePreview(for: document) {
                return authoritativePreviewImage
            }
            requestAuthoritativeRender(document: document)
            guard let task = renderPipelineTask else {
                preconditionFailure("An unresolved annotation output requires an active render pipeline.")
            }
            await task.value
            try Task.checkCancellation()
            if let failure = authoritativeRenderFailure,
               failure.generation == authoritativeRenderGeneration {
                throw failure.error
            }
        }
    }

    func setPreviewExcludedAnnotationIDs(
        _ annotationIDs: Set<UUID>,
        document: AnnotationDocument? = nil
    ) {
        guard annotationIDs != previewExcludedAnnotationIDs else { return }
        previewExcludedAnnotationIDs = annotationIDs
        AppLog.export.debug(
            "Changed interactive preview exclusions: count=\(annotationIDs.count, privacy: .public)"
        )
        scheduleInteractivePreview(document: document ?? controller.document)
    }

    func setStrokeColor(_ color: NSColor) {
        do {
            setStrokeColor(try annotationColor(from: color))
        } catch {
            onError?(error)
        }
    }

    func annotationColor(from color: NSColor) throws -> RGBAColor {
        guard let converted = color.usingColorSpace(.sRGB) else {
            throw ScreenshotAppError.colorConversionFailed(
                description: "The selected annotation color could not be converted to sRGB."
            )
        }
        return RGBAColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }

    func setStrokeColor(_ convertedColor: RGBAColor) {
        guard convertedColor.red.isFinite,
              convertedColor.green.isFinite,
              convertedColor.blue.isFinite,
              convertedColor.alpha.isFinite
        else {
            onError?(ScreenshotAppError.colorConversionFailed(
                description: "The selected annotation color contains a non-finite component."
            ))
            return
        }
        var updatedStyle = currentToolDefaultStyle
        if let kind = currentTool.annotationKind {
            updatedStyle = updatedStyle.applyingColor(convertedColor, for: kind)
        } else {
            updatedStyle = updatedStyle.applyingStrokeColor(convertedColor)
        }
        currentToolDefaultStyle = updatedStyle
        adoptCurrentStyle(updatedStyle, origin: .toolDefault)
    }

    func adoptCurrentStyle(
        _ style: AnnotationStyle,
        origin: CurrentStyleOrigin
    ) {
        guard currentStyle != style || currentStyleOrigin != origin else { return }
        currentStyleOrigin = origin
        currentStyle = style
    }

    func finalizeTextEditingStyle(committedStyle: AnnotationStyle?) {
        // Changing tools publishes the new tool default before the canvas is
        // asked to end its inline editor. In that lifecycle, keep the already
        // adopted tool default instead of restoring the text style.
        guard currentStyleOrigin != .toolDefault else { return }

        if let committedStyle {
            adoptCurrentStyle(committedStyle, origin: .existingAnnotation)
        } else {
            adoptCurrentStyle(defaultStyle(for: currentTool), origin: .toolDefault)
        }
    }

    func defaultStyle(for tool: AnnotationTool) -> AnnotationStyle {
        var style = Self.makeDefaultStyle(
            for: tool,
            editorSettings: editorSettings,
            backingScale: baseImage.scale
        )
        if tool == .text, let textFontSelection {
            switch textFontSelection {
            case .system: style.fontName = nil
            case .named(let name): style.fontName = name
            }
        }
        if tool == .arrow, let arrowHeadStyleSelection {
            style.arrowHeadStyle = arrowHeadStyleSelection
        }
        return style
    }

    /// The style used to create a new annotation is owned independently from
    /// `currentStyle`, which may be presenting an existing selection. Without
    /// this separation, inspecting an old item can silently overwrite the next
    /// annotation's defaults until the user switches tools.
    func creationStyle(for tool: AnnotationTool) -> AnnotationStyle {
        tool == currentTool ? currentToolDefaultStyle : defaultStyle(for: tool)
    }

    func setCurrentToolDefaultLineWidth(_ lineWidth: CGFloat) {
        precondition(
            lineWidth.isFinite && (0.5...24).contains(lineWidth),
            "A tool-default annotation line width must be finite and supported."
        )
        currentToolDefaultStyle.lineWidth = lineWidth
        if currentStyleOrigin == .toolDefault {
            adoptCurrentStyle(currentToolDefaultStyle, origin: .toolDefault)
        }
    }

    func restoreCurrentToolDefaultStyle() {
        adoptCurrentStyle(currentToolDefaultStyle, origin: .toolDefault)
    }

    func updateEditorSettings(_ editorSettings: EditorSettings) {
        let previousDefaultColorHex = AnnotationColorPalette.hexString(
            for: defaultStyle(for: currentTool).strokeColor
        )
        let cachedColorHex = AnnotationColorPalette.hexString(
            for: currentToolDefaultStyle.strokeColor
        )
        if self.editorSettings.defaultTextFontName != editorSettings.defaultTextFontName {
            textFontSelection = nil
            if currentTool == .text {
                currentToolDefaultStyle.fontName = editorSettings.defaultTextFontName
                if currentStyleOrigin == .toolDefault {
                    adoptCurrentStyle(currentToolDefaultStyle, origin: .toolDefault)
                }
            }
        }
        if self.editorSettings.defaultArrowHeadStyle != editorSettings.defaultArrowHeadStyle {
            arrowHeadStyleSelection = nil
            if currentTool == .arrow {
                currentToolDefaultStyle.arrowHeadStyle = editorSettings.defaultArrowHeadStyle
                if currentStyleOrigin == .toolDefault {
                    adoptCurrentStyle(currentToolDefaultStyle, origin: .toolDefault)
                }
            }
        }
        self.editorSettings = editorSettings
        let replacementStyle = defaultStyle(for: currentTool)
        let replacementColorHex = AnnotationColorPalette.hexString(
            for: replacementStyle.strokeColor
        )
        let cachedColorWasRemoved = !editorSettings.availableColorHexes.contains(
            cachedColorHex
        )
        let cachedColorFollowedPreviousDefault = cachedColorHex == previousDefaultColorHex
            && replacementColorHex != previousDefaultColorHex
        guard cachedColorWasRemoved || cachedColorFollowedPreviousDefault else { return }

        if let kind = currentTool.annotationKind {
            currentToolDefaultStyle = currentToolDefaultStyle.applyingColor(
                replacementStyle.strokeColor,
                for: kind
            )
        } else {
            currentToolDefaultStyle = currentToolDefaultStyle.applyingStrokeColor(
                replacementStyle.strokeColor
            )
        }
        if currentStyleOrigin == .toolDefault {
            adoptCurrentStyle(currentToolDefaultStyle, origin: .toolDefault)
        }
        AppLog.capture.notice(
            "Reconciled cached annotation tool color after editor settings change: tool=\(self.currentTool.rawValue, privacy: .public), previous=\(cachedColorHex, privacy: .public), replacement=\(replacementColorHex, privacy: .public), removed=\(cachedColorWasRemoved, privacy: .public), followedPreviousDefault=\(cachedColorFollowedPreviousDefault, privacy: .public), preservedExistingSelection=\(self.currentStyleOrigin == .existingAnnotation, privacy: .public)"
        )
    }

    func setShapeFillMode(_ fillMode: ShapeFillMode) {
        var style = currentToolDefaultStyle
        style.shapeFillMode = fillMode
        currentToolDefaultStyle = style
        if currentStyleOrigin == .toolDefault {
            adoptCurrentStyle(style, origin: .toolDefault)
        }
    }

    func setArrowHeadStyle(_ arrowHeadStyle: ArrowHeadStyle) {
        arrowHeadStyleSelection = arrowHeadStyle
        guard currentTool == .arrow else { return }
        var style = currentToolDefaultStyle
        style.arrowHeadStyle = arrowHeadStyle
        currentToolDefaultStyle = style
        if currentStyleOrigin == .toolDefault {
            adoptCurrentStyle(style, origin: .toolDefault)
        }
    }

    func setTextFont(_ fontName: String?) {
        textFontSelection = fontName.map(AnnotationTextFontSelection.named) ?? .system
        guard currentTool == .text else { return }
        currentToolDefaultStyle.fontName = fontName
        if currentStyleOrigin == .toolDefault {
            adoptCurrentStyle(currentToolDefaultStyle, origin: .toolDefault)
        }
    }

    func attachHistoryRecorder(_ recorder: HistorySessionRecorder) {
        precondition(historyRecorder == nil, "An annotation session must have one history persistence owner.")
        precondition(previewRenderingMode == .continuous, "Only a committed screenshot may record annotation history.")
        historyRecorder = recorder
    }

    var hasHistoryRecorder: Bool { historyRecorder != nil }
    var isHistoryRecordingAuthorized: Bool { historyRecorder?.isAuthorized == true }

    /// The presentation owner freezes input before awaiting this barrier and
    /// keeps the session alive until it succeeds. A failed save is retryable.
    func flushHistory() async throws {
        guard let historyRecorder else { return }
        let lease = updateSensitiveActivityTracker.begin(operation: "history-session-flush")
        defer { updateSensitiveActivityTracker.finish(lease) }
        while historyRecorder.canPersist {
            do {
                _ = try await resolvedPreviewImage()
            } catch {
                guard !historyRecorder.isAuthorized else { throw error }
                // A successful delete may revoke this obligation while the
                // renderer is suspended. Closing must not renew that writer.
                try await historyRecorder.flush(snapshot: nil)
                return
            }
            let document = controller.document
            try await historyRecorder.flush(snapshot: historyPreviewSnapshot)
            if document == controller.document { return }
        }
        try await historyRecorder.flush(snapshot: nil)
    }

    func replaceBaseImage(
        _ capturedImage: CapturedImage,
        translatingDocumentBy translation: CGSize
    ) {
        precondition(
            historyRecorder == nil,
            "A persisted annotation history session cannot change its capture base image."
        )
        precondition(
            capturedImage.logicalSize.width >= 2 && capturedImage.logicalSize.height >= 2,
            "A replacement annotation base image must remain non-empty."
        )

        let previousImage = baseImage
        baseGeneration += 1
        authoritativeRenderGeneration += 1
        interactiveRenderGeneration += 1
        pendingAuthoritativeRender = nil
        pendingInteractiveRender = nil
        authoritativeRenderFailure = nil
        authoritativeRenderedDocument = nil
        historyPreviewSnapshot = nil
        previewExcludedAnnotationIDs = []
        renderedPreviewExcludedAnnotationIDs = []
        renderedPreviewDocument = nil

        baseImage = capturedImage
        previewImage = capturedImage
        authoritativePreviewImage = capturedImage
        controller.rebaseCanvas(
            baseImageReference: ImageReference(
                relativePath: "base.png",
                pixelSize: capturedImage.pixelSize,
                colorSpaceName: capturedImage.colorSpace?.name as String?
            ),
            canvasSize: capturedImage.logicalSize,
            translation: translation
        )
        // Region drafts are the only replaceBaseImage caller. Re-apply the
        // session's configured radius so a smaller selection reclamps, and a
        // later enlarge recovers the configured value rather than a tiny clamp.
        if let storedConfiguredRegionCornerRadius {
            let cornerRadius = RegionCaptureCornerRadius.effective(
                for: capturedImage.logicalSize,
                configured: storedConfiguredRegionCornerRadius
            )
            controller.applyCanvasCornerRadius(cornerRadius)
            AppLog.capture.notice(
                "Rebased annotation session onto resized region: oldLogical=\(previousImage.logicalSize.debugDescription, privacy: .public), newLogical=\(capturedImage.logicalSize.debugDescription, privacy: .public), translation=\(translation.debugDescription, privacy: .public), annotations=\(self.controller.document.annotations.count, privacy: .public), cornerRadius=\(cornerRadius, privacy: .public), configuredCornerRadius=\(storedConfiguredRegionCornerRadius, privacy: .public)"
            )
        } else {
            AppLog.capture.notice(
                "Rebased annotation session onto resized region: oldLogical=\(previousImage.logicalSize.debugDescription, privacy: .public), newLogical=\(capturedImage.logicalSize.debugDescription, privacy: .public), translation=\(translation.debugDescription, privacy: .public), annotations=\(self.controller.document.annotations.count, privacy: .public)"
            )
        }
        // A same-size move can leave the entire document equal while changing
        // its pixels; base replacement must invalidate rendering on its own.
        scheduleRender(document: controller.document)
    }

    private func acceptSuccessfulAuthoritativeRender(
        _ rendered: CapturedImage,
        document: AnnotationDocument
    ) {
        authoritativeRenderedDocument = document
        renderedBaseGeneration = baseGeneration
        authoritativePreviewImage = rendered
        let persistenceDocument = document.recordingCurrentCachedPreviewRenderRevision()
        historyPreviewSnapshot = HistoryPreviewSnapshot(
            document: persistenceDocument,
            previewImage: rendered
        )
        if document.cachedPreviewRenderRevision != persistenceDocument.cachedPreviewRenderRevision {
            AppLog.history.notice(
                "Refreshed cached annotation preview renderer revision: storedRevision=\(document.cachedPreviewRenderRevision, privacy: .public), currentRevision=\(persistenceDocument.cachedPreviewRenderRevision, privacy: .public), affectedAnnotations=\(document.cachedPreviewRevisionAffectedAnnotationCount, privacy: .public)"
            )
        }
        if previewExcludedAnnotationIDs.isEmpty {
            previewImage = rendered
            renderedPreviewExcludedAnnotationIDs = []
            renderedPreviewDocument = document
        }
    }

    private func scheduleInteractivePreview(document: AnnotationDocument) {
        interactiveRenderGeneration += 1
        pendingInteractiveRender = nil
        let excludedAnnotationIDs = previewExcludedAnnotationIDs

        guard !defersPreviewRendering(for: document) else { return }
        guard !excludedAnnotationIDs.isEmpty else {
            if hasAuthoritativePreview(for: document) {
                previewImage = authoritativePreviewImage
                renderedPreviewExcludedAnnotationIDs = []
                renderedPreviewDocument = document
            }
            return
        }

        var previewDocument = document
        for index in previewDocument.annotations.indices
            where excludedAnnotationIDs.contains(previewDocument.annotations[index].id)
        {
            previewDocument.annotations[index].isVisible = false
        }
        pendingInteractiveRender = RenderRequest(
            kind: .interactive,
            generation: interactiveRenderGeneration,
            baseGeneration: baseGeneration,
            baseImage: baseImage,
            document: previewDocument,
            logicalDocument: document,
            excludedAnnotationIDs: excludedAnnotationIDs
        )
        startRenderPipelineIfNeeded()
    }

    private func startRenderPipelineIfNeeded() {
        guard renderPipelineTask == nil,
              pendingAuthoritativeRender != nil || pendingInteractiveRender != nil
        else { return }
        let renderer = renderer
        let tracker = updateSensitiveActivityTracker
        let lease = tracker.begin(operation: "annotation-render-pipeline")
        renderPipelineTask = Task { [weak self] in
            defer { tracker.finish(lease) }
            // Only one bitmap is rendered at a time. Pending inputs are slots,
            // not tasks, so superseded documents and base images release here.
            while let request = self?.takeNextRender() {
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try autoreleasepool {
                            let rendered = try renderer.render(
                                document: request.document,
                                baseImage: request.baseImage.image,
                                scale: request.baseImage.scale
                            )
                            let logicalSize = request.logicalDocument.outputLogicalSize
                            return CapturedImage(
                                image: rendered,
                                colorSpace: rendered.colorSpace,
                                pixelSize: CGSize(width: rendered.width, height: rendered.height),
                                logicalSize: logicalSize,
                                scale: logicalSize.width > 0 ? CGFloat(rendered.width) / logicalSize.width : request.baseImage.scale,
                                sourceMetadata: request.baseImage.sourceMetadata
                            )
                        }
                    }
                }.value
                self?.finishRender(request, result: result)
            }
            self?.renderPipelineTask = nil
        }
    }

    private func takeNextRender() -> RenderRequest? {
        if let request = pendingAuthoritativeRender {
            pendingAuthoritativeRender = nil
            if isCurrent(request) {
                activeRender = request
                return request
            }
        }
        if let request = pendingInteractiveRender {
            pendingInteractiveRender = nil
            if isCurrent(request) {
                activeRender = request
                return request
            }
        }
        return nil
    }

    private func isCurrent(_ request: RenderRequest) -> Bool {
        guard request.baseGeneration == baseGeneration,
              request.logicalDocument == controller.document
        else { return false }
        switch request.kind {
        case .authoritative:
            return request.generation == authoritativeRenderGeneration
        case .interactive:
            return request.generation == interactiveRenderGeneration
                && request.excludedAnnotationIDs == previewExcludedAnnotationIDs
        }
    }

    private func finishRender(_ request: RenderRequest, result: Result<CapturedImage, Error>) {
        activeRender = nil
        guard isCurrent(request) else {
            AppLog.export.debug("Discarded superseded annotation render: generation=\(request.generation, privacy: .public)")
            return
        }
        switch result {
        case .success(let image):
            switch request.kind {
            case .authoritative:
                authoritativeRenderFailure = nil
                acceptSuccessfulAuthoritativeRender(image, document: request.logicalDocument)
            case .interactive:
                previewImage = image
                renderedPreviewExcludedAnnotationIDs = request.excludedAnnotationIDs
                renderedPreviewDocument = request.logicalDocument
            }
            AppLog.export.debug(
                "Rendered annotation generation \(request.generation, privacy: .public): authoritative=\(request.kind == .authoritative, privacy: .public), annotations=\(request.document.annotations.count, privacy: .public), pixels=\(image.image.width, privacy: .public)x\(image.image.height, privacy: .public)"
            )
        case .failure(let error):
            let kind = request.kind == .authoritative ? "authoritative" : "interactive"
            if request.kind == .authoritative {
                authoritativeRenderFailure = (request.generation, error)
            }
            reportRenderFailure(error, key: "\(kind)-\(request.generation)")
        }
    }

    private func reportRenderFailure(_ error: Error, key: String) {
        AppLog.export.error(
            "Annotation render \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        onError?(error)
    }

    private static func makeDefaultStyle(
        for tool: AnnotationTool,
        editorSettings: EditorSettings,
        backingScale: CGFloat
    ) -> AnnotationStyle {
        let colorHex = editorSettings.defaultColorHex(for: tool)
        guard let defaultColor = AnnotationColorPalette.color(fromHex: colorHex) else {
            preconditionFailure(
                "A validated editor configuration must provide a #RRGGBB default for every annotation tool."
            )
        }
        let factoryHighlightHex = AnnotationColorPalette.hexString(for: .systemYellow)
        let semanticColor = tool == .highlight
            && editorSettings.availableColorHexes.contains(factoryHighlightHex)
            ? RGBAColor.systemYellow
            : defaultColor
        let style = AnnotationStyle(
            strokeColor: semanticColor,
            lineWidth: editorSettings.defaultLineWidthUnit.logicalPoints(
                fromDisplayedValue: editorSettings.defaultLineWidth,
                backingScale: backingScale
            ),
            fontSize: editorSettings.logicalDefaultFontSize(backingScale: backingScale),
            fontName: tool == .text ? editorSettings.defaultTextFontName : nil,
            arrowHeadStyle: editorSettings.defaultArrowHeadStyle,
            cornerRadius: editorSettings.logicalDefaultRectangleCornerRadius(
                backingScale: backingScale
            )
        )
        return tool == .highlight ? style.asHighlightStyle() : style
    }

}

/// Document identity is shared by History, pinned surfaces and Canvas windows.
/// Weak entries discover existing presentation owners without keeping closed
/// screenshots alive; an in-flight History open is retained and deduplicated.
@MainActor
final class AnnotationSessionRegistry {
    private final class Entry {
        weak var session: AnnotationEditingSession?

        init(_ session: AnnotationEditingSession) {
            self.session = session
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var pendingOpens: [UUID: Task<AnnotationEditingSession, Error>] = [:]

    func session(for documentID: UUID) -> AnnotationEditingSession? {
        guard let entry = entries[documentID] else { return nil }
        guard let session = entry.session else {
            entries[documentID] = nil
            return nil
        }
        return session
    }

    @discardableResult
    func register(_ candidate: AnnotationEditingSession) -> AnnotationEditingSession {
        let documentID = candidate.controller.document.id
        if let existing = session(for: documentID) {
            return existing
        }
        entries[documentID] = Entry(candidate)
        return candidate
    }

    /// Take the authorization and reserve the document synchronously at the
    /// command boundary, before any load, render or recorder can be scheduled.
    func openHistory(
        id: UUID,
        store: any ScreenshotHistoryStoring,
        settingsStore: SettingsStore,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker,
        onError: ((Error) -> Void)? = nil
    ) -> Task<AnnotationEditingSession, Error> {
        if let pending = pendingOpens[id] { return pending }
        if let existing = session(for: id), existing.isHistoryRecordingAuthorized {
            return Task { existing }
        }
        let authorization = store.writeAuthority.authorization(for: id)
        let task = Task { @MainActor [self] in
            defer { pendingOpens[id] = nil }
            do {
                let record = try await store.load(id: id)
                guard store.writeAuthority.isCurrent(authorization) else {
                    throw HistoryWriteAuthorizationError.revoked
                }
                let candidate = session(for: id) ?? AnnotationEditingSession(
                    capturedImage: record.baseImage,
                    previewImage: record.previewImage,
                    document: record.document,
                    editorSettings: settingsStore.settings.editor,
                    updateSensitiveActivityTracker: updateSensitiveActivityTracker
                )
                _ = try await candidate.resolvedPreviewImage()
                guard store.writeAuthority.isCurrent(authorization) else {
                    throw HistoryWriteAuthorizationError.revoked
                }
                let canonical = register(candidate)
                if !canonical.hasHistoryRecorder {
                    canonical.attachHistoryRecorder(HistorySessionRecorder(
                        session: canonical,
                        store: store,
                        settingsStore: settingsStore,
                        updateSensitiveActivityTracker: updateSensitiveActivityTracker,
                        authorization: authorization,
                        onError: onError
                    ))
                }
                return canonical
            } catch {
                guard store.writeAuthority.isCurrent(authorization) else {
                    throw HistoryWriteAuthorizationError.revoked
                }
                throw error
            }
        }
        pendingOpens[id] = task
        return task
    }
}
