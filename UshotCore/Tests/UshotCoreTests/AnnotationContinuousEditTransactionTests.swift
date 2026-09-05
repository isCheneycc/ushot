import Combine
import CoreGraphics
import XCTest
@testable import UshotCore

final class AnnotationContinuousEditTransactionTests: XCTestCase {
    @MainActor
    func testContinuousCommitPublishesUndoAvailabilityWithoutAnotherDocumentChange() throws {
        let original = try makeTextItem()
        let controller = AnnotationDocumentController(document: makeDocument(item: original))
        let transaction = controller.beginContinuousEdit(
            label: "Edit opacity",
            owner: "test-observable-timeline",
            itemID: original.id
        )
        XCTAssertTrue(controller.previewContinuousEdit(transaction) { document in
            document.annotations[0].opacity = 0.5
        })

        var publishedTimelineChanges = 0
        let observation = controller.objectWillChange.sink {
            publishedTimelineChanges += 1
        }

        XCTAssertTrue(controller.commitContinuousEdit(transaction))
        XCTAssertTrue(controller.canUndo)
        XCTAssertGreaterThan(publishedTimelineChanges, 0)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testUnchangedTextUpdatesKeepTheCurrentInspectorTransactionOpen() throws {
        let original = try makeTextItem()
        let controller = AnnotationDocumentController(document: makeDocument(item: original))
        let transaction = controller.beginContinuousEdit(
            label: "Edit text inspector",
            owner: "test-text-no-op",
            itemID: original.id
        )
        XCTAssertTrue(controller.previewContinuousEdit(transaction) { document in
            document.annotations[0].opacity = 0.5
        })
        var publications = 0
        let observation = controller.documentPublisher.dropFirst().sink { _ in
            publications += 1
        }

        try controller.updateTextItemLayout(
            id: original.id,
            text: original.text ?? "",
            fontSize: original.style.fontSize,
            wrapWidthStrategy: .preserve
        )
        XCTAssertTrue(try controller.previewTextItemLayout(
            transaction: transaction,
            id: original.id,
            text: original.text ?? "",
            fontSize: original.style.fontSize,
            wrapWidthStrategy: .preserve
        ))

        XCTAssertTrue(controller.isContinuousEditActive(transaction))
        XCTAssertTrue(controller.undoStack.isEmpty)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(controller.cancelContinuousEdit(transaction))
        XCTAssertEqual(controller.document.annotations, [original])
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testTwentyTextPreviewsCreateOneUndoThatRestoresCompleteItem() throws {
        let original = try makeTextItem()
        let controller = AnnotationDocumentController(document: makeDocument(item: original))
        controller.selectedItemIDs = [original.id]
        let transaction = controller.beginContinuousEdit(
            label: "Edit text inspector",
            owner: "test-text-inspector",
            itemID: original.id
        )

        for index in 1...20 {
            let applied = try controller.previewTextItemLayout(
                transaction: transaction,
                id: original.id,
                text: "Preview \(index) grows into multiple visual lines for the inspector transaction.",
                fontSize: 18 + CGFloat(index),
                wrapWidthStrategy: .scaleWithFont
            ) { item in
                item.style.lineWidth = CGFloat(index)
                item.opacity = 1 - CGFloat(index) / 100
                item.transform.rotationRadians = CGFloat(index) / 20
            }
            XCTAssertTrue(applied)
            XCTAssertTrue(controller.undoStack.isEmpty)
            XCTAssertTrue(controller.redoStack.isEmpty)
        }

        let finalItem = try XCTUnwrap(controller.document.annotations.first)
        XCTAssertNotEqual(finalItem, original)
        XCTAssertNotEqual(finalItem.geometry, original.geometry)
        XCTAssertNotEqual(finalItem.style, original.style)
        XCTAssertNotEqual(finalItem.textLayout, original.textLayout)
        XCTAssertTrue(controller.commitContinuousEdit(transaction))
        XCTAssertEqual(controller.undoStack.count, 1)

        controller.undo()
        XCTAssertEqual(controller.document.annotations, [original])
        XCTAssertEqual(controller.selectedItemIDs, [original.id])
    }

    @MainActor
    func testCancelRestoresCompleteStartingDocumentAndSelectionWithoutUndo() throws {
        let original = try makeTextItem()
        let startingDocument = makeDocument(item: original)
        let controller = AnnotationDocumentController(document: startingDocument)
        controller.selectedItemIDs = [original.id]
        let startingState = controller.state
        let transaction = controller.beginContinuousEdit(
            label: "Edit inspector",
            owner: "test-cancel",
            itemID: original.id
        )

        XCTAssertTrue(controller.previewContinuousEdit(transaction) { document in
            document.background = .padded(color: .black, amount: 64)
            document.canvasEffects.cornerRadius = 22
            document.annotations[0].opacity = 0.2
            document.annotations[0].transform.translation = CGSize(width: 35, height: -18)
        })
        XCTAssertNotEqual(controller.state, startingState)
        XCTAssertTrue(controller.undoStack.isEmpty)

        XCTAssertTrue(controller.cancelContinuousEdit(transaction))
        XCTAssertEqual(controller.state, startingState)
        XCTAssertTrue(controller.undoStack.isEmpty)
        XCTAssertTrue(controller.redoStack.isEmpty)
    }

    @MainActor
    func testStaleGenerationCannotCommitCancelOrPreviewNewTransaction() throws {
        let original = try makeTextItem()
        let controller = AnnotationDocumentController(document: makeDocument(item: original))
        controller.selectedItemIDs = [original.id]
        let first = controller.beginContinuousEdit(
            label: "First edit",
            owner: "test-first",
            itemID: original.id
        )
        XCTAssertTrue(controller.previewContinuousEdit(first) { document in
            document.annotations[0].opacity = 0.7
        })

        let second = controller.beginContinuousEdit(
            label: "Second edit",
            owner: "test-second",
            itemID: original.id
        )
        XCTAssertEqual(controller.undoStack.count, 1)
        let secondStartingDocument = controller.document
        XCTAssertTrue(controller.previewContinuousEdit(second) { document in
            document.annotations[0].style.lineWidth = 9
        })
        let secondPreviewDocument = controller.document

        XCTAssertFalse(controller.previewContinuousEdit(first) { document in
            document.annotations.removeAll()
        })
        XCTAssertFalse(controller.commitContinuousEdit(first))
        XCTAssertFalse(controller.cancelContinuousEdit(first))
        XCTAssertEqual(controller.document, secondPreviewDocument)
        XCTAssertTrue(controller.isContinuousEditActive(second))

        XCTAssertTrue(controller.cancelContinuousEdit(second))
        XCTAssertEqual(controller.document, secondStartingDocument)
        XCTAssertEqual(controller.undoStack.count, 1)
        XCTAssertEqual(try XCTUnwrap(controller.document.annotations.first).opacity, 0.7)
    }

    @MainActor
    func testOrdinaryPerformRetainsDiscreteUndoSemantics() throws {
        let original = try makeTextItem()
        let controller = AnnotationDocumentController(document: makeDocument(item: original))

        controller.perform(label: "First") { document in
            document.annotations[0].opacity = 0.8
        }
        controller.perform(label: "Second") { document in
            document.annotations[0].opacity = 0.6
        }

        XCTAssertEqual(controller.undoStack.map(\.label), ["First", "Second"])
        controller.undo()
        XCTAssertEqual(controller.document.annotations[0].opacity, 0.8)
        controller.undo()
        XCTAssertEqual(controller.document.annotations, [original])
    }

    @MainActor
    func testSelectionChangeCommitsActiveItemEditAndInvalidatesItsToken() throws {
        let original = try makeTextItem()
        let second = AnnotationItem(
            kind: .rectangle,
            zIndex: 1,
            geometry: .rect(CGRect(x: 180, y: 40, width: 60, height: 50))
        )
        var document = makeDocument(item: original)
        document.annotations.append(second)
        let controller = AnnotationDocumentController(document: document)
        controller.selectedItemIDs = [original.id]
        let transaction = controller.beginContinuousEdit(
            label: "Edit opacity",
            owner: "test-selection-change",
            itemID: original.id
        )
        XCTAssertTrue(controller.previewContinuousEdit(transaction) { document in
            document.annotations[0].opacity = 0.4
        })

        controller.selectedItemIDs = [second.id]

        XCTAssertEqual(controller.undoStack.count, 1)
        XCTAssertEqual(controller.selectedItemIDs, [second.id])
        XCTAssertFalse(controller.isContinuousEditActive(transaction))
        XCTAssertFalse(controller.cancelContinuousEdit(transaction))
        XCTAssertEqual(controller.document.annotations[0].opacity, 0.4)
    }

    private func makeTextItem() throws -> AnnotationItem {
        let style = AnnotationStyle(lineWidth: 2, fontSize: 18, textAlignment: .leading)
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 32, y: 96),
            text: "Original",
            style: style,
            maximumWrapWidth: 110
        )
        return AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(layout.rect),
            style: style,
            text: "Original",
            textLayout: layout.payload
        )
    }

    private func makeDocument(item: AnnotationItem) -> AnnotationDocument {
        AnnotationDocument(
            baseImageReference: ImageReference(pixelSize: CGSize(width: 320, height: 240)),
            canvasSize: CGSize(width: 320, height: 240),
            annotations: [item]
        )
    }
}
