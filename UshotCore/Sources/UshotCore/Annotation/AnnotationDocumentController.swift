import Combine
import CoreGraphics
import Foundation

@MainActor
public final class AnnotationDocumentController: ObservableObject {
    public struct ContinuousEditToken: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let generation: UInt64
        public let owner: String
        public let itemID: UUID?
    }

    public enum Alignment: Sendable {
        case leading, horizontalCenter, trailing, top, verticalCenter, bottom
    }

    public enum DistributionAxis: Sendable {
        case horizontal, vertical
    }
    public struct Change: Sendable {
        public let label: String
        public let before: AnnotationDocument
        public let after: AnnotationDocument
    }

    public struct State: Equatable, Sendable {
        public let document: AnnotationDocument
        public let selectedItemIDs: Set<UUID>

        public init(document: AnnotationDocument, selectedItemIDs: Set<UUID>) {
            self.document = document
            self.selectedItemIDs = selectedItemIDs
        }
    }

    @Published public private(set) var state: State

    @Published public private(set) var undoStack: [Change] = []
    @Published public private(set) var redoStack: [Change] = []

    private struct ContinuousEdit {
        let token: ContinuousEditToken
        let label: String
        let initialState: State
        let itemKind: AnnotationKind?
    }

    private var continuousEditGeneration: UInt64 = 0
    private var activeContinuousEdit: ContinuousEdit?

    public init(document: AnnotationDocument) {
        state = State(document: document, selectedItemIDs: [])
    }

    public var document: AnnotationDocument { state.document }
    public var selectedItemIDs: Set<UUID> {
        get { state.selectedItemIDs }
        set {
            guard newValue != state.selectedItemIDs else { return }
            commitActiveContinuousEdit(reason: "selection-change")
            publish(
                document: state.document,
                selectedItemIDs: newValue,
                reason: "selection"
            )
        }
    }

    public var documentPublisher: AnyPublisher<AnnotationDocument, Never> {
        $state.map(\.document).removeDuplicates().eraseToAnyPublisher()
    }

    public var selectedItemIDsPublisher: AnyPublisher<Set<UUID>, Never> {
        $state.map(\.selectedItemIDs).removeDuplicates().eraseToAnyPublisher()
    }

    public var statePublisher: AnyPublisher<State, Never> {
        $state.removeDuplicates().eraseToAnyPublisher()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Starts one gesture- or focus-owned inspector edit. Preview updates made
    /// with the returned token publish immediately but do not enter the undo
    /// timeline until the matching token commits.
    @discardableResult
    public func beginContinuousEdit(
        label: String,
        owner: String,
        itemID: UUID? = nil
    ) -> ContinuousEditToken {
        precondition(!label.isEmpty, "A continuous edit requires a non-empty undo label.")
        precondition(!owner.isEmpty, "A continuous edit requires an observable owner.")
        commitActiveContinuousEdit(reason: "owner-replaced")
        precondition(
            continuousEditGeneration < UInt64.max,
            "Continuous edit generation exhausted."
        )
        continuousEditGeneration += 1
        let itemKind: AnnotationKind?
        if let itemID {
            guard let item = document.annotations.first(where: { $0.id == itemID }) else {
                preconditionFailure("A continuous item edit requires an existing annotation identity.")
            }
            itemKind = item.kind
        } else {
            itemKind = nil
        }
        let token = ContinuousEditToken(
            id: UUID(),
            generation: continuousEditGeneration,
            owner: owner,
            itemID: itemID
        )
        activeContinuousEdit = ContinuousEdit(
            token: token,
            label: label,
            initialState: state,
            itemKind: itemKind
        )
        AppLog.capture.debug(
            "Began continuous annotation edit: owner=\(owner, privacy: .public), generation=\(token.generation, privacy: .public), itemScoped=\(itemID != nil, privacy: .public)"
        )
        return token
    }

    public func isContinuousEditActive(_ token: ContinuousEditToken) -> Bool {
        activeContinuousEdit?.token == token
    }

    /// Publishes a live continuous-edit preview without adding an undo entry.
    /// A stale token is rejected and cannot mutate a newer transaction.
    @discardableResult
    public func previewContinuousEdit(
        _ token: ContinuousEditToken,
        mutation: (inout AnnotationDocument) -> Void
    ) -> Bool {
        guard let active = activeContinuousEdit, active.token == token else {
            logRejectedContinuousEdit(token, action: "preview")
            return false
        }
        validateContinuousEditIdentity(active, in: document)
        var preview = document
        mutation(&preview)
        normalizeZIndices(in: &preview)
        validateContinuousEditIdentity(active, in: preview)
        let validIDs = Set(preview.annotations.map(\.id))
        let selection = selectedItemIDs.intersection(validIDs)
        publish(
            document: preview,
            selectedItemIDs: selection,
            reason: "continuous-preview-\(token.owner)"
        )
        return true
    }

    /// Commits the complete live preview as exactly one undo entry.
    @discardableResult
    public func commitContinuousEdit(_ token: ContinuousEditToken) -> Bool {
        guard let active = activeContinuousEdit, active.token == token else {
            logRejectedContinuousEdit(token, action: "commit")
            return false
        }
        validateContinuousEditIdentity(active, in: document)
        finishContinuousEdit(active, reason: "owner-commit")
        return true
    }

    /// Restores the complete document and selection captured at begin time.
    @discardableResult
    public func cancelContinuousEdit(_ token: ContinuousEditToken) -> Bool {
        guard let active = activeContinuousEdit, active.token == token else {
            logRejectedContinuousEdit(token, action: "cancel")
            return false
        }
        activeContinuousEdit = nil
        publish(
            document: active.initialState.document,
            selectedItemIDs: active.initialState.selectedItemIDs,
            reason: "continuous-cancel-\(token.owner)"
        )
        AppLog.capture.notice(
            "Cancelled continuous annotation edit: owner=\(token.owner, privacy: .public), generation=\(token.generation, privacy: .public)"
        )
        return true
    }

    public func perform(label: String, mutation: (inout AnnotationDocument) -> Void) {
        commitActiveContinuousEdit(reason: "discrete-edit")
        commit(label: label, selectionAfterChange: { _, existingSelection in
            existingSelection
        }, mutation: mutation)
    }

    private func commit(
        label: String,
        selectionAfterChange: (AnnotationDocument, Set<UUID>) -> Set<UUID>,
        mutation: (inout AnnotationDocument) -> Void
    ) {
        commitActiveContinuousEdit(reason: "discrete-commit")
        let before = document
        var after = document
        mutation(&after)
        normalizeZIndices(in: &after)
        guard after != before else { return }
        undoStack.append(Change(label: label, before: before, after: after))
        redoStack.removeAll()
        let requestedSelection = selectionAfterChange(after, selectedItemIDs)
        let validIDs = Set(after.annotations.map(\.id))
        let reconciledSelection = requestedSelection.intersection(validIDs)
        let removedSelectionCount = requestedSelection.count - reconciledSelection.count
        if removedSelectionCount > 0 {
            AppLog.capture.notice(
                "Reconciled annotation selection during atomic document commit: reason=\(label, privacy: .public), removed=\(removedSelectionCount, privacy: .public), annotations=\(after.annotations.count, privacy: .public)"
            )
        }
        publish(
            document: after,
            selectedItemIDs: reconciledSelection,
            reason: label
        )
    }

    public func add(_ item: AnnotationItem) {
        commit(label: "Add \(item.kind.rawValue)", selectionAfterChange: { _, _ in
            [item.id]
        }) { document in
            var item = item
            item.zIndex = document.annotations.count
            document.annotations.append(item)
        }
    }

    public func updateItem(id: UUID, mutation: (inout AnnotationItem) -> Void) {
        perform(label: "Edit annotation") { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
            guard !document.annotations[index].isLocked else { return }
            mutation(&document.annotations[index])
        }
    }

    /// Applies an inspector-style text/content edit as one document mutation.
    /// Geometry, typography and persisted layout ownership therefore enter the
    /// same undo record and can never expose an intermediate clipped item.
    public func updateTextItemLayout(
        id: UUID,
        text: String,
        fontSize: CGFloat,
        wrapWidthStrategy: AnnotationTextWrapWidthStrategy,
        additionalMutation: (inout AnnotationItem) -> Void = { _ in }
    ) throws {
        guard let original = document.annotations.first(where: { $0.id == id }),
              !original.isLocked
        else { return }
        guard original.kind == .text else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "atomic text layout updates require a text annotation"
            )
        }
        var updated = try AnnotationTextLayout.reflowedTextItem(
            original,
            text: text,
            fontSize: fontSize,
            wrapWidthStrategy: wrapWidthStrategy
        )
        let layoutOwnedItem = updated
        additionalMutation(&updated)
        guard
            updated.id == layoutOwnedItem.id
                && updated.kind == .text
                && updated.text == layoutOwnedItem.text
                && updated.style.fontSize == layoutOwnedItem.style.fontSize
                && updated.style.fontName == layoutOwnedItem.style.fontName
                && updated.style.fontWeight == layoutOwnedItem.style.fontWeight
                && updated.style.textAlignment == layoutOwnedItem.style.textAlignment
                && updated.geometry == layoutOwnedItem.geometry
                && updated.textLayout == layoutOwnedItem.textLayout
        else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "additional inspector mutation changed layout-owned text state"
            )
        }
        perform(label: "Edit text layout") { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == id }),
                  !document.annotations[index].isLocked
            else { return }
            document.annotations[index] = updated
            if original.textLayout == nil, updated.textLayout != nil {
                AppLog.capture.notice(
                    "Materialized explicit legacy text layout after semantic edit: id=\(id.uuidString, privacy: .public), wrapWidth=\(updated.textLayout?.wrapWidth ?? 0, privacy: .public)"
                )
            }
        }
    }

    @discardableResult
    public func previewTextItemLayout(
        transaction: ContinuousEditToken,
        id: UUID,
        text: String,
        fontSize: CGFloat,
        wrapWidthStrategy: AnnotationTextWrapWidthStrategy,
        additionalMutation: (inout AnnotationItem) -> Void = { _ in }
    ) throws -> Bool {
        guard transaction.itemID == id else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "a continuous text preview must retain its annotation identity"
            )
        }
        guard let active = activeContinuousEdit, active.token == transaction else {
            logRejectedContinuousEdit(transaction, action: "preview")
            return false
        }
        validateContinuousEditIdentity(active, in: document)
        guard let original = document.annotations.first(where: { $0.id == id }) else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "a continuous text preview lost its annotation identity"
            )
        }
        guard !original.isLocked else {
            return previewContinuousEdit(transaction) { _ in }
        }
        guard original.kind == .text else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "continuous text layout updates require a text annotation"
            )
        }
        var updated = try AnnotationTextLayout.reflowedTextItem(
            original,
            text: text,
            fontSize: fontSize,
            wrapWidthStrategy: wrapWidthStrategy
        )
        let layoutOwnedItem = updated
        additionalMutation(&updated)
        guard
            updated.id == layoutOwnedItem.id
                && updated.kind == .text
                && updated.text == layoutOwnedItem.text
                && updated.style.fontSize == layoutOwnedItem.style.fontSize
                && updated.style.fontName == layoutOwnedItem.style.fontName
                && updated.style.fontWeight == layoutOwnedItem.style.fontWeight
                && updated.style.textAlignment == layoutOwnedItem.style.textAlignment
                && updated.geometry == layoutOwnedItem.geometry
                && updated.textLayout == layoutOwnedItem.textLayout
        else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "additional inspector mutation changed layout-owned text state"
            )
        }
        return previewContinuousEdit(transaction) { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == id }) else {
                return
            }
            guard !document.annotations[index].isLocked else { return }
            document.annotations[index] = updated
            if original.textLayout == nil, updated.textLayout != nil {
                AppLog.capture.notice(
                    "Materialized explicit legacy text layout during continuous edit: id=\(id.uuidString, privacy: .public), wrapWidth=\(updated.textLayout?.wrapWidth ?? 0, privacy: .public)"
                )
            }
        }
    }

    public func deleteSelection() {
        let ids = selectedItemIDs
        let documentBeforeDeletion = document
        commit(label: "Delete annotation", selectionAfterChange: { _, _ in [] }) { document in
            document.annotations.removeAll { ids.contains($0.id) && !$0.isLocked }
        }
        if document == documentBeforeDeletion {
            selectedItemIDs.removeAll()
        }
    }

    public func duplicateSelection(offset: CGSize = CGSize(width: 10, height: -10)) {
        let selected = document.orderedAnnotations.filter { selectedItemIDs.contains($0.id) }
        var newIDs: Set<UUID> = []
        let documentBeforeDuplication = document
        commit(label: "Duplicate annotation", selectionAfterChange: { _, _ in newIDs }) { document in
            for original in selected {
                let id = UUID()
                newIDs.insert(id)
                var copy = AnnotationItem(
                    id: id,
                    name: original.name + " Copy",
                    kind: original.kind,
                    zIndex: document.annotations.count,
                    geometry: original.geometry,
                    style: original.style,
                    opacity: original.opacity,
                    transform: original.transform,
                    isVisible: original.isVisible,
                    isLocked: false,
                    text: original.text,
                    textLayout: original.textLayout,
                    counterValue: original.counterValue
                )
                copy.transform.translation.width += offset.width
                copy.transform.translation.height += offset.height
                document.annotations.append(copy)
            }
        }
        if document == documentBeforeDuplication {
            selectedItemIDs = newIDs
        }
    }

    public func moveSelection(by offset: CGSize) {
        let ids = selectedItemIDs
        perform(label: "Move annotation") { document in
            for index in document.annotations.indices where ids.contains(document.annotations[index].id) {
                guard !document.annotations[index].isLocked,
                      document.annotations[index].kind.allowsUserTranslation
                else { continue }
                document.annotations[index].transform.translation.width += offset.width
                document.annotations[index].transform.translation.height += offset.height
            }
        }
    }

    public func bringSelectionToFront() {
        reorderSelection(toFront: true)
    }

    public func sendSelectionToBack() {
        reorderSelection(toFront: false)
    }

    public func moveSelectionForward() {
        stepSelection(direction: 1)
    }

    public func moveSelectionBackward() {
        stepSelection(direction: -1)
    }

    public func undo() {
        commitActiveContinuousEdit(reason: "undo")
        guard let change = undoStack.popLast() else { return }
        redoStack.append(change)
        let validIDs = Set(change.before.annotations.map(\.id))
        publish(
            document: change.before,
            selectedItemIDs: selectedItemIDs.intersection(validIDs),
            reason: "undo"
        )
    }

    public func redo() {
        commitActiveContinuousEdit(reason: "redo")
        guard let change = redoStack.popLast() else { return }
        undoStack.append(change)
        let validIDs = Set(change.after.annotations.map(\.id))
        publish(
            document: change.after,
            selectedItemIDs: selectedItemIDs.intersection(validIDs),
            reason: "redo"
        )
    }

    /// Moves an existing edit timeline onto a newly cropped base image without
    /// treating the crop-frame adjustment as an undoable annotation action.
    public func rebaseCanvas(
        baseImageReference: ImageReference,
        canvasSize: CGSize,
        translation: CGSize
    ) {
        commitActiveContinuousEdit(reason: "rebase-canvas")
        precondition(
            canvasSize.width >= 2 && canvasSize.height >= 2,
            "A rebased annotation canvas must remain non-empty."
        )
        precondition(
            translation.width.isFinite && translation.height.isFinite,
            "A rebased annotation canvas requires a finite translation."
        )

        let rebasedDocument = rebased(
            document,
            baseImageReference: baseImageReference,
            canvasSize: canvasSize,
            translation: translation
        )
        undoStack = undoStack.map { change in
            Change(
                label: change.label,
                before: rebased(
                    change.before,
                    baseImageReference: baseImageReference,
                    canvasSize: canvasSize,
                    translation: translation
                ),
                after: rebased(
                    change.after,
                    baseImageReference: baseImageReference,
                    canvasSize: canvasSize,
                    translation: translation
                )
            )
        }
        redoStack = redoStack.map { change in
            Change(
                label: change.label,
                before: rebased(
                    change.before,
                    baseImageReference: baseImageReference,
                    canvasSize: canvasSize,
                    translation: translation
                ),
                after: rebased(
                    change.after,
                    baseImageReference: baseImageReference,
                    canvasSize: canvasSize,
                    translation: translation
                )
            )
        }
        publish(
            document: rebasedDocument,
            selectedItemIDs: selectedItemIDs.intersection(Set(rebasedDocument.annotations.map(\.id))),
            reason: "rebase-canvas"
        )
    }

    /// Updates canvas corner radius across the live document and edit timeline
    /// without creating an undoable annotation action. Used when region draft
    /// geometry changes so the effective radius reclamps with selection size.
    public func applyCanvasCornerRadius(_ cornerRadius: CGFloat) {
        commitActiveContinuousEdit(reason: "canvas-corner-radius")
        precondition(
            cornerRadius.isFinite && cornerRadius >= 0,
            "Canvas corner radius must be a finite non-negative value."
        )
        func withCornerRadius(_ source: AnnotationDocument) -> AnnotationDocument {
            guard source.canvasEffects.cornerRadius != cornerRadius else { return source }
            var copy = source
            copy.canvasEffects.cornerRadius = cornerRadius
            return copy
        }

        undoStack = undoStack.map { change in
            Change(
                label: change.label,
                before: withCornerRadius(change.before),
                after: withCornerRadius(change.after)
            )
        }
        redoStack = redoStack.map { change in
            Change(
                label: change.label,
                before: withCornerRadius(change.before),
                after: withCornerRadius(change.after)
            )
        }
        publish(
            document: withCornerRadius(document),
            selectedItemIDs: selectedItemIDs,
            reason: "canvas-corner-radius"
        )
    }

    public func nextCounterValue() -> Int {
        (document.annotations.compactMap(\.counterValue).max() ?? 0) + 1
    }

    public func setVisibility(id: UUID, isVisible: Bool) {
        perform(label: isVisible ? "Show layer" : "Hide layer") { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
            document.annotations[index].isVisible = isVisible
        }
    }

    public func setLocked(id: UUID, isLocked: Bool) {
        perform(label: isLocked ? "Lock layer" : "Unlock layer") { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
            document.annotations[index].isLocked = isLocked
        }
    }

    public func rename(id: UUID, name: String) {
        perform(label: "Rename layer") { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
            document.annotations[index].name = name
        }
    }

    public func alignSelection(_ alignment: Alignment) {
        let selected = document.annotations.filter {
            selectedItemIDs.contains($0.id) && !$0.isLocked && $0.kind.allowsUserTranslation
        }
        guard selected.count >= 2 else { return }
        let bounds = selected.map(transformedBounds)
        let group = bounds.reduce(CGRect.null) { $0.union($1) }
        perform(label: "Align annotations") { document in
            for index in document.annotations.indices where selectedItemIDs.contains(document.annotations[index].id) {
                guard !document.annotations[index].isLocked,
                      document.annotations[index].kind.allowsUserTranslation
                else { continue }
                let itemBounds = transformedBounds(document.annotations[index])
                let delta: CGSize
                switch alignment {
                case .leading: delta = CGSize(width: group.minX - itemBounds.minX, height: 0)
                case .horizontalCenter: delta = CGSize(width: group.midX - itemBounds.midX, height: 0)
                case .trailing: delta = CGSize(width: group.maxX - itemBounds.maxX, height: 0)
                case .top: delta = CGSize(width: 0, height: group.maxY - itemBounds.maxY)
                case .verticalCenter: delta = CGSize(width: 0, height: group.midY - itemBounds.midY)
                case .bottom: delta = CGSize(width: 0, height: group.minY - itemBounds.minY)
                }
                document.annotations[index].transform.translation.width += delta.width
                document.annotations[index].transform.translation.height += delta.height
            }
        }
    }

    public func distributeSelection(along axis: DistributionAxis) {
        let selected = document.annotations.filter {
            selectedItemIDs.contains($0.id) && !$0.isLocked && $0.kind.allowsUserTranslation
        }
        guard selected.count >= 3 else { return }
        let sorted = selected.sorted {
            let lhs = transformedBounds($0)
            let rhs = transformedBounds($1)
            return axis == .horizontal ? lhs.midX < rhs.midX : lhs.midY < rhs.midY
        }
        let firstCenter = axis == .horizontal ? transformedBounds(sorted[0]).midX : transformedBounds(sorted[0]).midY
        let lastCenter = axis == .horizontal ? transformedBounds(sorted[sorted.count - 1]).midX : transformedBounds(sorted[sorted.count - 1]).midY
        let step = (lastCenter - firstCenter) / CGFloat(sorted.count - 1)
        perform(label: "Distribute annotations") { document in
            for (position, item) in sorted.enumerated() where position > 0 && position < sorted.count - 1 {
                guard let index = document.annotations.firstIndex(where: { $0.id == item.id }) else { continue }
                let bounds = transformedBounds(document.annotations[index])
                let target = firstCenter + CGFloat(position) * step
                if axis == .horizontal {
                    document.annotations[index].transform.translation.width += target - bounds.midX
                } else {
                    document.annotations[index].transform.translation.height += target - bounds.midY
                }
            }
        }
    }

    public func topmostItem(at point: CGPoint, tolerance: CGFloat = 6) -> AnnotationItem? {
        let hitTester = AnnotationHitTester()
        return document.orderedAnnotations.reversed().first {
            !$0.isLocked && hitTester.contains(point, in: $0, tolerance: tolerance)
        }
    }

    private func reorderSelection(toFront: Bool) {
        let ids = selectedItemIDs
        perform(label: "Reorder annotation") { document in
            let selected = document.orderedAnnotations.filter { ids.contains($0.id) }
            let unselected = document.orderedAnnotations.filter { !ids.contains($0.id) }
            document.annotations = toFront ? unselected + selected : selected + unselected
        }
    }

    private func stepSelection(direction: Int) {
        let ids = selectedItemIDs
        perform(label: "Reorder annotation") { document in
            var ordered = document.orderedAnnotations
            let indices = ordered.indices.filter { ids.contains(ordered[$0].id) }
            let traversal = direction > 0 ? indices.reversed() : indices
            for index in traversal {
                let target = index + direction
                guard ordered.indices.contains(target), !ids.contains(ordered[target].id) else { continue }
                ordered.swapAt(index, target)
            }
            document.annotations = ordered
        }
    }

    private func normalizeZIndices(in document: inout AnnotationDocument) {
        document.annotations = document.annotations.enumerated().map { index, item in
            var item = item
            item.zIndex = index
            return item
        }
    }

    private func commitActiveContinuousEdit(reason: String) {
        guard let active = activeContinuousEdit else { return }
        validateContinuousEditIdentity(active, in: document)
        finishContinuousEdit(active, reason: reason)
    }

    private func finishContinuousEdit(_ active: ContinuousEdit, reason: String) {
        precondition(
            activeContinuousEdit?.token == active.token,
            "Only the active continuous edit may finish its generation."
        )
        activeContinuousEdit = nil
        let before = active.initialState.document
        let after = document
        if after != before {
            undoStack.append(Change(label: active.label, before: before, after: after))
            redoStack.removeAll()
        }
        AppLog.capture.debug(
            "Finished continuous annotation edit: owner=\(active.token.owner, privacy: .public), generation=\(active.token.generation, privacy: .public), changed=\(after != before, privacy: .public), reason=\(reason, privacy: .public)"
        )
    }

    private func validateContinuousEditIdentity(
        _ active: ContinuousEdit,
        in document: AnnotationDocument
    ) {
        guard let itemID = active.token.itemID else { return }
        guard let item = document.annotations.first(where: { $0.id == itemID }) else {
            preconditionFailure("An active continuous edit cannot lose its annotation identity.")
        }
        precondition(
            item.kind == active.itemKind,
            "An active continuous edit cannot change its annotation kind."
        )
    }

    private func logRejectedContinuousEdit(
        _ token: ContinuousEditToken,
        action: String
    ) {
        AppLog.capture.notice(
            "Rejected stale continuous annotation edit action: action=\(action, privacy: .public), owner=\(token.owner, privacy: .public), generation=\(token.generation, privacy: .public), activeGeneration=\(self.activeContinuousEdit?.token.generation ?? 0, privacy: .public)"
        )
    }

    private func publish(
        document: AnnotationDocument,
        selectedItemIDs: Set<UUID>,
        reason: String
    ) {
        let validIDs = Set(document.annotations.map(\.id))
        precondition(
            selectedItemIDs.isSubset(of: validIDs),
            "Annotation selection must be published in the same state as its document."
        )
        let updatedState = State(
            document: document,
            selectedItemIDs: selectedItemIDs
        )
        guard updatedState != state else { return }
        state = updatedState
        AppLog.capture.debug(
            "Published atomic annotation editor state: reason=\(reason, privacy: .public), annotations=\(document.annotations.count, privacy: .public), selected=\(selectedItemIDs.count, privacy: .public)"
        )
    }

    private func rebased(
        _ source: AnnotationDocument,
        baseImageReference: ImageReference,
        canvasSize: CGSize,
        translation: CGSize
    ) -> AnnotationDocument {
        var result = source
        result.baseImageReference = baseImageReference
        result.canvasSize = canvasSize
        for index in result.annotations.indices {
            result.annotations[index].transform.translation.width += translation.width
            result.annotations[index].transform.translation.height += translation.height
        }
        if let crop = result.crop.rect?.standardized {
            let translated = crop.offsetBy(dx: translation.width, dy: translation.height)
            let bounded = translated.intersection(CGRect(origin: .zero, size: canvasSize))
            result.crop.rect = bounded.width >= 1 && bounded.height >= 1 ? bounded : nil
        }
        return result
    }

    private func transformedBounds(_ item: AnnotationItem) -> CGRect {
        let bounds = item.geometry.boundingBox
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(
            x: center.x + item.transform.translation.width,
            y: center.y + item.transform.translation.height
        )
        transform = transform.rotated(by: item.transform.rotationRadians)
        transform = transform.scaledBy(x: item.transform.scaleX, y: item.transform.scaleY)
        transform = transform.translatedBy(x: -center.x, y: -center.y)
        return bounds.applying(transform)
    }
}
