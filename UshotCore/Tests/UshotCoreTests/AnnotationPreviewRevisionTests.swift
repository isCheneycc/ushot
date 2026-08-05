import CoreGraphics
import Foundation
import XCTest
@testable import UshotCore

final class AnnotationPreviewRevisionTests: XCTestCase {
    func testNewDocumentRecordsCurrentPreviewRendererRevision() {
        let document = makeDocument()

        XCTAssertEqual(
            document.cachedPreviewRenderRevision,
            AnnotationDocument.currentCachedPreviewRenderRevision
        )
        XCTAssertTrue(document.isCachedPreviewCompatibleWithCurrentRenderer)
    }

    func testLegacyJSONWithoutPreviewRevisionStillDecodes() throws {
        let encoded = try JSONEncoder().encode(makeDocument())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "cachedPreviewRenderRevision")
        let legacyJSON = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: legacyJSON)

        XCTAssertEqual(
            decoded.cachedPreviewRenderRevision,
            AnnotationDocument.legacyCachedPreviewRenderRevision
        )
        XCTAssertTrue(decoded.isCachedPreviewCompatibleWithCurrentRenderer)
    }

    func testLegacyPreviewOnlyRefreshesForChangedArrowStyles() {
        for style in [ArrowHeadStyle.filled, .double, .tapered] {
            let document = makeDocument(
                cachedPreviewRenderRevision: AnnotationDocument.legacyCachedPreviewRenderRevision,
                annotations: [makeArrow(style: style)]
            )

            XCTAssertFalse(
                document.isCachedPreviewCompatibleWithCurrentRenderer,
                "Expected \(style.rawValue) arrows to invalidate a legacy cached preview."
            )
            XCTAssertEqual(document.cachedPreviewRevisionAffectedAnnotationCount, 1)
        }
    }

    func testLegacyPreviewRemainsCompatibleForUnaffectedHistory() {
        var hiddenFilledArrow = makeArrow(style: .filled)
        hiddenFilledArrow.isVisible = false
        let document = makeDocument(
            cachedPreviewRenderRevision: AnnotationDocument.legacyCachedPreviewRenderRevision,
            annotations: [
                AnnotationItem(
                    kind: .rectangle,
                    zIndex: 0,
                    geometry: .rect(CGRect(x: 4, y: 4, width: 20, height: 12))
                ),
                makeArrow(style: .open, zIndex: 1),
                hiddenFilledArrow
            ]
        )

        XCTAssertTrue(document.isCachedPreviewCompatibleWithCurrentRenderer)
        XCTAssertEqual(document.cachedPreviewRevisionAffectedAnnotationCount, 0)
    }

    func testSuccessfulRenderStampProducesCurrentRoundTrip() throws {
        let legacy = makeDocument(
            cachedPreviewRenderRevision: AnnotationDocument.legacyCachedPreviewRenderRevision,
            annotations: [makeArrow(style: .filled)]
        )

        let recorded = legacy.recordingCurrentCachedPreviewRenderRevision()
        let decoded = try JSONDecoder().decode(
            AnnotationDocument.self,
            from: JSONEncoder().encode(recorded)
        )

        XCTAssertEqual(
            decoded.cachedPreviewRenderRevision,
            AnnotationDocument.currentCachedPreviewRenderRevision
        )
        XCTAssertEqual(decoded, recorded)
        XCTAssertTrue(decoded.isCachedPreviewCompatibleWithCurrentRenderer)
        XCTAssertEqual(
            legacy.cachedPreviewRenderRevision,
            AnnotationDocument.legacyCachedPreviewRenderRevision,
            "Stamping a persistence copy must not mutate the editable source document."
        )
    }

    func testUnknownFuturePreviewRevisionIsNeverTrusted() {
        let document = makeDocument(
            cachedPreviewRenderRevision: AnnotationDocument.currentCachedPreviewRenderRevision + 1
        )

        XCTAssertFalse(document.isCachedPreviewCompatibleWithCurrentRenderer)
    }

    func testHistorySummariesHideOnlyIncompatibleCachedPreviews() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-preview-revision-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        let store = SystemScreenshotHistoryStore(rootDirectory: root)
        let image = try makeCapturedImage()
        let changedDocument = makeDocument(
            cachedPreviewRenderRevision: AnnotationDocument.legacyCachedPreviewRenderRevision,
            annotations: [makeArrow(style: .filled)]
        )
        let unaffectedDocument = makeDocument(
            cachedPreviewRenderRevision: AnnotationDocument.legacyCachedPreviewRenderRevision,
            annotations: [makeArrow(style: .open)]
        )

        for document in [changedDocument, unaffectedDocument] {
            try await store.save(ScreenshotHistoryRecord(
                metadata: HistoryRecordMetadata.make(
                    documentID: document.id,
                    baseImage: image
                ),
                document: document,
                baseImage: image,
                previewImage: image
            ))
        }

        let summariesByID = Dictionary(
            uniqueKeysWithValues: try await store.list().map { ($0.id, $0) }
        )
        XCTAssertFalse(try XCTUnwrap(
            summariesByID[changedDocument.id]
        ).cachedPreviewIsAuthoritative)
        XCTAssertTrue(try XCTUnwrap(
            summariesByID[unaffectedDocument.id]
        ).cachedPreviewIsAuthoritative)
    }

    func testInvalidPreviewRevisionFailsDecoding() throws {
        let encoded = try JSONEncoder().encode(makeDocument())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["cachedPreviewRenderRevision"] = 0
        let invalidJSON = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(AnnotationDocument.self, from: invalidJSON)
        )

        object["cachedPreviewRenderRevision"] = NSNull()
        let nullRevisionJSON = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(AnnotationDocument.self, from: nullRevisionJSON)
        )
    }

    private func makeDocument(
        cachedPreviewRenderRevision: Int = AnnotationDocument.currentCachedPreviewRenderRevision,
        annotations: [AnnotationItem] = []
    ) -> AnnotationDocument {
        AnnotationDocument(
            cachedPreviewRenderRevision: cachedPreviewRenderRevision,
            baseImageReference: ImageReference(pixelSize: CGSize(width: 100, height: 80)),
            canvasSize: CGSize(width: 100, height: 80),
            annotations: annotations
        )
    }

    private func makeArrow(
        style arrowHeadStyle: ArrowHeadStyle,
        zIndex: Int = 0
    ) -> AnnotationItem {
        AnnotationItem(
            kind: .arrow,
            zIndex: zIndex,
            geometry: .line(
                start: CGPoint(x: 10, y: 12),
                end: CGPoint(x: 72, y: 58)
            ),
            style: AnnotationStyle(arrowHeadStyle: arrowHeadStyle)
        )
    }

    private func makeCapturedImage() throws -> CapturedImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 100,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 100 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(try XCTUnwrap(
            CGColor(colorSpace: colorSpace, components: [0.2, 0.3, 0.4, 1])
        ))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let image = try XCTUnwrap(context.makeImage())
        return CapturedImage(
            image: image,
            colorSpace: colorSpace,
            pixelSize: CGSize(width: 100, height: 80),
            logicalSize: CGSize(width: 100, height: 80),
            scale: 1,
            sourceMetadata: CaptureSourceMetadata(
                kind: .display,
                displayIDs: [1],
                windowID: nil,
                desktopFrame: CGRect(x: 0, y: 0, width: 100, height: 80)
            )
        )
    }
}
