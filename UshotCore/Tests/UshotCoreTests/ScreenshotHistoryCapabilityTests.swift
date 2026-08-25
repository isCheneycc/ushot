import CoreGraphics
import Foundation
import XCTest
@testable import UshotCore

final class ScreenshotHistoryCapabilityTests: XCTestCase {
    private static let unavailableFontName =
        "Ushot-Intentionally-Unavailable-History-Migration-Font"

    func testLoadPreservesLegacyTextMigrationCapabilityError() async throws {
        for payloadVersion in [1, 2] {
            let fixture = try await makeFixture(payloadVersion: payloadVersion)
            defer { removeFixture(at: fixture.root) }

            do {
                _ = try await fixture.store.load(id: fixture.recordID)
                XCTFail("History load unexpectedly accepted text layout v\(payloadVersion).")
            } catch {
                XCTAssertEqual(
                    error as? AnnotationTextRenderingError,
                    .fontUnavailable(Self.unavailableFontName)
                )
            }
        }
    }

    func testListKeepsLegacyTextCapabilityRecordVisibleBesideNormalRecord() async throws {
        for payloadVersion in [1, 2] {
            let fixture = try await makeFixture(payloadVersion: payloadVersion)
            defer { removeFixture(at: fixture.root) }
            let validRecordID = UUID()
            try await fixture.store.save(try makeRecord(id: validRecordID))

            let summaries = try await fixture.store.list()
            XCTAssertEqual(
                Set(summaries.map(\.id)),
                Set([fixture.recordID, validRecordID])
            )
            let limitedSummary = try XCTUnwrap(
                summaries.first { $0.id == fixture.recordID }
            )
            let validSummary = try XCTUnwrap(
                summaries.first { $0.id == validRecordID }
            )
            XCTAssertFalse(limitedSummary.cachedPreviewIsAuthoritative)
            XCTAssertTrue(validSummary.cachedPreviewIsAuthoritative)
            XCTAssertEqual(
                limitedSummary.previewFileURL.resolvingSymlinksInPath(),
                fixture.root
                    .appendingPathComponent(fixture.recordID.uuidString, isDirectory: true)
                    .appendingPathComponent("preview.png")
                    .resolvingSymlinksInPath()
            )

            let validRecord = try await fixture.store.load(id: validRecordID)
            XCTAssertEqual(validRecord.metadata.id, validRecordID)
            do {
                _ = try await fixture.store.load(id: fixture.recordID)
                XCTFail("History load unexpectedly accepted text layout v\(payloadVersion).")
            } catch {
                XCTAssertEqual(
                    error as? AnnotationTextRenderingError,
                    .fontUnavailable(Self.unavailableFontName)
                )
            }
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent(fixture.recordID.uuidString, isDirectory: true)
                    .path
            ))
        }
    }

    private func makeFixture(
        payloadVersion: Int
    ) async throws -> (
        store: SystemScreenshotHistoryStore,
        recordID: UUID,
        root: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "UshotHistoryCapabilityTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = SystemScreenshotHistoryStore(rootDirectory: root)
        let recordID = UUID()
        try await store.save(try makeRecord(id: recordID))

        let documentURL = root
            .appendingPathComponent(recordID.uuidString, isDirectory: true)
            .appendingPathComponent("document.json")
        var documentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: documentURL))
                as? [String: Any]
        )
        documentObject["annotations"] = [try legacyTextItemObject(
            payloadVersion: payloadVersion
        )]
        try JSONSerialization.data(
            withJSONObject: documentObject,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: documentURL, options: .atomic)

        return (store, recordID, root)
    }

    private func legacyTextItemObject(
        payloadVersion: Int
    ) throws -> [String: Any] {
        var style = AnnotationStyle(fontSize: 18)
        style.fontName = Self.unavailableFontName
        let item = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(CGRect(x: 12, y: 14, width: 132, height: 35)),
            style: style,
            text: "Capability boundary"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
                as? [String: Any]
        )
        switch payloadVersion {
        case 1:
            object["textLayout"] = [
                "version": 1,
                "chromeMode": "legacyTight",
                "wrapWidth": 132
            ]
        case 2:
            object["textLayout"] = [
                "version": 2,
                "chromeMode": "uniformPadded",
                "wrapWidth": 120,
                "leadingOverhang": 0,
                "trailingOverhang": 0
            ]
        default:
            XCTFail("Unsupported legacy text layout fixture version \(payloadVersion).")
        }
        return object
    }

    private func makeRecord(id: UUID) throws -> ScreenshotHistoryRecord {
        let image = try makeCapturedImage()
        let document = AnnotationDocument(
            id: id,
            baseImageReference: ImageReference(
                relativePath: "base.png",
                pixelSize: image.pixelSize,
                colorSpaceName: image.colorSpace?.name as String?
            ),
            canvasSize: image.logicalSize
        )
        return ScreenshotHistoryRecord(
            metadata: HistoryRecordMetadata.make(
                documentID: id,
                baseImage: image
            ),
            document: document,
            baseImage: image,
            previewImage: image
        )
    }

    private func makeCapturedImage() throws -> CapturedImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 8 * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let fillColor = try XCTUnwrap(CGColor(
            colorSpace: colorSpace,
            components: [0.2, 0.4, 0.6, 1]
        ))
        context.setFillColor(fillColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        return CapturedImage(
            image: image,
            colorSpace: colorSpace,
            pixelSize: CGSize(width: 8, height: 8),
            logicalSize: CGSize(width: 8, height: 8),
            scale: 1,
            sourceMetadata: CaptureSourceMetadata(
                kind: .region,
                displayIDs: [1],
                windowID: nil,
                desktopFrame: CGRect(x: 0, y: 0, width: 8, height: 8)
            )
        )
    }

    private func removeFixture(at root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            XCTFail("History capability fixture cleanup failed: \(error)")
        }
    }
}
