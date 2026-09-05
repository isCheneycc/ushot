import AppKit
import Combine
import UshotCore

@MainActor
final class AnnotationEditingSession: ObservableObject {
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
    private var authoritativeRenderTask: Task<CapturedImage, Error>?
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
        configuredRegionCornerRadius: CGFloat? = nil
    ) {
        baseImage = capturedImage
        self.previewImage = previewImage ?? capturedImage
        self.authoritativePreviewImage = previewImage ?? capturedImage
        self.renderer = renderer
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
        let generation = authoritativeRenderGeneration
        let updateSensitiveActivityTracker = updateSensitiveActivityTracker
        let lease = updateSensitiveActivityTracker.begin(
            operation: "authoritative-annotation-render"
        )
        let renderTask = makeRenderTask(document: sourceDocument)
        // Every output waiter shares this publication boundary. Receiving the
        // same pixels must not publish another history snapshot or debounce.
        authoritativeRenderTask = Task { [weak self, renderTask] in
            defer { updateSensitiveActivityTracker.finish(lease) }
            do {
                let rendered = try await renderTask.value
                guard let self,
                      generation == self.authoritativeRenderGeneration,
                      sourceDocument == self.controller.document
                else { return rendered }
                self.acceptSuccessfulAuthoritativeRender(
                    rendered,
                    document: sourceDocument
                )
                AppLog.export.debug(
                    "Rendered authoritative annotation generation \(generation, privacy: .public): annotations=\(sourceDocument.annotations.count, privacy: .public), pixels=\(rendered.image.width, privacy: .public)x\(rendered.image.height, privacy: .public), scale=\(rendered.scale, privacy: .public)x"
                )
                return rendered
            } catch {
                if let self, generation == self.authoritativeRenderGeneration {
                    self.reportRenderFailure(error, key: "authoritative-\(generation)")
                }
                throw error
            }
        }
        scheduleInteractivePreview(document: sourceDocument)
    }

    func resolvedPreviewImage() async throws -> CapturedImage {
        while true {
            let document = controller.document
            if authoritativeRenderedDocument == document {
                return authoritativePreviewImage
            }
            let generation = authoritativeRenderGeneration
            guard let task = authoritativeRenderTask else {
                scheduleRender(document: document)
                continue
            }
            do {
                let rendered = try await task.value
                guard generation == authoritativeRenderGeneration,
                      document == controller.document
                else { continue }
                return rendered
            } catch {
                guard generation == authoritativeRenderGeneration else { continue }
                throw error
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
        Self.makeDefaultStyle(
            for: tool,
            editorSettings: editorSettings,
            backingScale: baseImage.scale
        )
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
        var style = currentToolDefaultStyle
        style.arrowHeadStyle = arrowHeadStyle
        currentToolDefaultStyle = style
        if currentStyleOrigin == .toolDefault {
            adoptCurrentStyle(style, origin: .toolDefault)
        }
    }

    func attachHistoryRecorder(_ recorder: HistorySessionRecorder) {
        precondition(historyRecorder == nil, "An annotation session must have one history persistence owner.")
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
        authoritativeRenderGeneration += 1
        interactiveRenderGeneration += 1
        authoritativeRenderTask?.cancel()
        authoritativeRenderTask = nil
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
    }

    private func acceptSuccessfulAuthoritativeRender(
        _ rendered: CapturedImage,
        document: AnnotationDocument
    ) {
        authoritativeRenderedDocument = document
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
        let generation = interactiveRenderGeneration
        let excludedAnnotationIDs = previewExcludedAnnotationIDs

        guard !excludedAnnotationIDs.isEmpty else {
            if authoritativeRenderedDocument == document {
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
        let task = makeRenderTask(document: previewDocument, logicalDocument: document)
        Task { [weak self, task] in
            do {
                let preview = try await task.value
                guard let self,
                      generation == self.interactiveRenderGeneration,
                      document == self.controller.document,
                      excludedAnnotationIDs == self.previewExcludedAnnotationIDs
                else { return }
                self.previewImage = preview
                self.renderedPreviewExcludedAnnotationIDs = excludedAnnotationIDs
                self.renderedPreviewDocument = document
                AppLog.export.debug(
                    "Rendered interaction background generation \(generation, privacy: .public): excluded=\(excludedAnnotationIDs.count, privacy: .public), annotations=\(document.annotations.count, privacy: .public)"
                )
            } catch {
                guard let self, generation == self.interactiveRenderGeneration else { return }
                self.reportRenderFailure(error, key: "interactive-\(generation)")
            }
        }
    }

    private func makeRenderTask(
        document: AnnotationDocument,
        logicalDocument: AnnotationDocument? = nil
    ) -> Task<CapturedImage, Error> {
        let baseImage = baseImage
        let renderer = renderer
        let logicalDocument = logicalDocument ?? document
        return Task<CapturedImage, Error> {
            let rendered = try await Task.detached(priority: .userInitiated) {
                try renderer.render(
                    document: document,
                    baseImage: baseImage.image,
                    scale: baseImage.scale
                )
            }.value
            let logicalSize = logicalDocument.outputLogicalSize
            return CapturedImage(
                image: rendered,
                colorSpace: rendered.colorSpace,
                pixelSize: CGSize(width: rendered.width, height: rendered.height),
                logicalSize: logicalSize,
                scale: logicalSize.width > 0 ? CGFloat(rendered.width) / logicalSize.width : baseImage.scale,
                sourceMetadata: baseImage.sourceMetadata
            )
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
