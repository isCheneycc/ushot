import Combine
import CoreGraphics
import Foundation

@MainActor
public final class AnnotationDocumentController: ObservableObject {
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

    public private(set) var undoStack: [Change] = []
    public private(set) var redoStack: [Change] = []

    public init(document: AnnotationDocument) {
        state = State(document: document, selectedItemIDs: [])
    }

    public var document: AnnotationDocument { state.document }
    public var selectedItemIDs: Set<UUID> {
        get { state.selectedItemIDs }
        set {
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

    public func perform(label: String, mutation: (inout AnnotationDocument) -> Void) {
        commit(label: label, selectionAfterChange: { _, existingSelection in
            existingSelection
        }, mutation: mutation)
    }

    private func commit(
        label: String,
        selectionAfterChange: (AnnotationDocument, Set<UUID>) -> Set<UUID>,
        mutation: (inout AnnotationDocument) -> Void
    ) {
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
