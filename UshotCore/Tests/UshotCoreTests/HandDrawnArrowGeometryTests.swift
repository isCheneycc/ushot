import CoreGraphics
import Foundation
import Testing
@testable import UshotCore

struct HandDrawnArrowGeometryTests {
    private let seed = UUID(uuid: (
        0x46, 0xa3, 0x58, 0x9a, 0x4b, 0xa1, 0x45, 0x68,
        0x92, 0xac, 0x52, 0xda, 0x7b, 0x1b, 0xc8, 0x61
    ))

    @Test func penMarksRemainIdenticalAcrossDocumentPersistence() throws {
        let item = makeArrow()
        let restored = try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONEncoder().encode(item)
        )
        let geometry = try geometry(for: item)

        #expect(restored == item)
        #expect(try self.geometry(for: restored) == geometry)
        #expect(try self.geometry(for: item) == geometry)
        #expect(String(decoding: try JSONEncoder().encode(ArrowHeadStyle.handDrawn), as: UTF8.self)
            == "\"handDrawn\"")
    }

    @Test func annotationIdentityChangesPenMarksWithoutMovingEndpoints() throws {
        let item = makeArrow()
        let other = AnnotationItem(
            id: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)),
            kind: .arrow,
            zIndex: 0,
            geometry: item.geometry,
            style: item.style
        )
        let first = try geometry(for: item)
        let second = try geometry(for: other)

        #expect(first != second)
        #expect(first.shaft.start == second.shaft.start)
        #expect(first.shaft.end == second.shaft.end)
    }

    @Test(arguments: [CGFloat(1.5), 3], [CGFloat(60), 180, 750])
    func shaftHitRegionFollowsCenterlineWithoutOldRetraces(lineWidth: CGFloat, length: CGFloat) throws {
        for identity in UInt8(0)..<16 {
            let seed = UUID(uuid: (identity, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
            let geometry = try #require(HandDrawnArrowGeometry(
                start: .zero,
                tip: CGPoint(x: length, y: 0),
                lineWidth: lineWidth,
                seed: seed
            ))
            for progress: CGFloat in [0.1, 0.3, 0.5, 0.7] {
                #expect(geometry.contains(CGPoint(x: length * progress, y: 0), tolerance: 0))
                for side: CGFloat in [-1, 1] {
                    #expect(!geometry.contains(
                        CGPoint(x: length * progress, y: (lineWidth * 1.5 + 1) * side),
                        tolerance: 0
                    ))
                }
            }
            #expect(geometry.strokes.allSatisfy { $0.lineWidth <= lineWidth })
        }
    }

    @Test func copiedArrowPreservesPenMarksAndSeedAcrossPersistence() throws {
        let original = makeArrow()
        let copy = AnnotationItem(
            id: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)),
            kind: .arrow,
            zIndex: 1,
            geometry: original.geometry,
            style: original.style,
            handDrawnSeed: original.handDrawnSeed ?? original.id
        )
        let restored = try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONEncoder().encode(copy)
        )

        #expect(copy.id != original.id)
        #expect(restored.handDrawnSeed == original.id)
        #expect(try geometry(for: restored) == geometry(for: original))
        let geometry = try geometry(for: original)
        for stroke in geometry.strokes {
            #expect(AnnotationHitTester().contains(stroke.point(at: 0.5), in: restored, tolerance: 0))
        }
    }

    @Test func missingSeedRemainsCompatibleWithLegacyItems() throws {
        let item = makeArrow()
        let encoded = try JSONEncoder().encode(item)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let restored = try JSONDecoder().decode(AnnotationItem.self, from: encoded)

        #expect(object["handDrawnSeed"] == nil)
        #expect(restored.handDrawnSeed == nil)
        #expect(try geometry(for: restored) == geometry(for: item))
    }

    @Test(arguments: [
        CGPoint(x: 240, y: 0),
        CGPoint(x: -80, y: 130),
        CGPoint(x: 0, y: -100),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 6, y: 6)
    ])
    func allDirectionsRetainExactEndpointsAndFiniteCurves(tip: CGPoint) throws {
        let start = CGPoint(x: 5, y: -7)
        let geometry = try #require(HandDrawnArrowGeometry(
            start: start,
            tip: tip,
            lineWidth: 6,
            seed: seed
        ))

        #expect(geometry.shaft.start == start)
        #expect(geometry.shaft.end == tip)
        #expect(geometry.wings.allSatisfy { $0.end == tip })
        for stroke in geometry.strokes {
            #expect(stroke.lineWidth > 0)
            #expect([stroke.start, stroke.control1, stroke.control2, stroke.end].allSatisfy {
                $0.x.isFinite && $0.y.isFinite
            })
        }
    }

    @Test func openHeadKeepsUnpaintedInteriorUnselected() throws {
        let item = makeArrow(lineWidth: 1)
        let geometry = try geometry(for: item)
        let wing = try #require(geometry.wings.first)
        let wingMidpoint = wing.point(at: 0.5)
        let shaftProgress = wingMidpoint.x / geometry.shaft.end.x
        let shaftPoint = geometry.shaft.point(at: shaftProgress)
        let emptyInterior = CGPoint(
            x: (wingMidpoint.x + shaftPoint.x) / 2,
            y: (wingMidpoint.y + shaftPoint.y) / 2
        )

        #expect(!geometry.contains(emptyInterior, tolerance: 0))
        #expect(!AnnotationHitTester().contains(emptyInterior, in: item, tolerance: 0))
    }

    @Test func hitTestingUsesEveryPresentationSpaceCurveAfterNonuniformTransform() throws {
        let item = makeArrow(transform: AnnotationTransform(
            translation: CGSize(width: 23, height: -18),
            rotationRadians: 0.73,
            scaleX: 1.8,
            scaleY: 0.45
        ))
        let geometry = try geometry(for: item)
        let tester = AnnotationHitTester()

        for stroke in geometry.strokes {
            for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                #expect(tester.contains(stroke.point(at: progress), in: item, tolerance: 0))
            }
        }
        #expect(!tester.contains(CGPoint(x: -1_000, y: -1_000), in: item, tolerance: 6))
    }

    @Test func hitToleranceExpandsTheSameRoundCaps() throws {
        let item = makeArrow()
        let geometry = try geometry(for: item)
        let outsideStart = CGPoint(x: -geometry.shaft.lineWidth / 2 - 2, y: 0)
        let tester = AnnotationHitTester()

        #expect(!tester.contains(outsideStart, in: item, tolerance: 0))
        #expect(tester.contains(outsideStart, in: item, tolerance: 2.1))
    }

    @Test(arguments: [CGFloat(0.5), 1, 4, 8, 20])
    func shortThickArrowsAdaptWidthWithoutOvershootingTheTip(length: CGFloat) throws {
        let item = makeArrow(tip: CGPoint(x: length, y: 0), lineWidth: 24)
        let geometry = try geometry(for: item)

        #expect(geometry.shaft.lineWidth <= max(0.5, length * 0.1))
        #expect(geometry.contains(geometry.shaft.end, tolerance: 0))
        #expect(!AnnotationHitTester().contains(
            CGPoint(x: length + geometry.shaft.lineWidth / 2 + 0.1, y: 0),
            in: item,
            tolerance: 0
        ))
    }

    @Test func degenerateAndNonfiniteInputsHaveNoGeometry() {
        #expect(HandDrawnArrowGeometry(start: .zero, tip: .zero, lineWidth: 3, seed: seed) == nil)
        #expect(HandDrawnArrowGeometry(
            start: .zero,
            tip: CGPoint(x: CGFloat.infinity, y: 0),
            lineWidth: 3,
            seed: seed
        ) == nil)
        #expect(HandDrawnArrowGeometry(
            start: .zero,
            tip: CGPoint(x: 100, y: 0),
            lineWidth: .nan,
            seed: seed
        ) == nil)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7])
    func olderRevisionsInvalidateVisibleHandDrawnArrows(revision: Int) throws {
        let document = makeDocument(revision: revision, annotations: [makeArrow()])
        let recorded = document.recordingCurrentCachedPreviewRenderRevision()
        let restored = try JSONDecoder().decode(
            AnnotationDocument.self,
            from: JSONEncoder().encode(recorded)
        )

        #expect(!document.isCachedPreviewCompatibleWithCurrentRenderer)
        #expect(document.cachedPreviewRevisionAffectedAnnotationCount == 1)
        #expect(restored.cachedPreviewRenderRevision == 8)
        #expect(restored.isCachedPreviewCompatibleWithCurrentRenderer)
        #expect(restored.annotations == document.annotations)
        #expect(document.cachedPreviewRenderRevision == revision)
    }

    @Test(arguments: [5, 6, 7])
    func revisionEightPreservesExistingStylesAndInvisibleArrows(revision: Int) {
        var hidden = makeArrow()
        hidden.isVisible = false
        let unchanged = [ArrowHeadStyle.open, .filled, .tapered, .double].map { style in
            var item = makeArrow()
            item.style.arrowHeadStyle = style
            return item
        }
        let document = makeDocument(revision: revision, annotations: unchanged + [hidden])

        #expect(document.isCachedPreviewCompatibleWithCurrentRenderer)
        #expect(document.cachedPreviewRevisionAffectedAnnotationCount == 0)
    }

    private func makeArrow(
        tip: CGPoint = CGPoint(x: 180, y: 0),
        lineWidth: CGFloat = 3,
        transform: AnnotationTransform = AnnotationTransform()
    ) -> AnnotationItem {
        AnnotationItem(
            id: seed,
            kind: .arrow,
            zIndex: 0,
            geometry: .line(start: .zero, end: tip),
            style: AnnotationStyle(lineWidth: lineWidth, arrowHeadStyle: .handDrawn),
            transform: transform
        )
    }

    private func geometry(for item: AnnotationItem) throws -> HandDrawnArrowGeometry {
        guard case .line(let start, let tip) = item.geometry else {
            throw GeometryError.expectedLine
        }
        let selection = AnnotationSelectionGeometry()
        return try #require(HandDrawnArrowGeometry(
            start: selection.transformedPoint(start, for: item),
            tip: selection.transformedPoint(tip, for: item),
            lineWidth: item.style.lineWidth,
            seed: item.handDrawnSeed ?? item.id
        ))
    }

    private func makeDocument(revision: Int, annotations: [AnnotationItem]) -> AnnotationDocument {
        AnnotationDocument(
            cachedPreviewRenderRevision: revision,
            baseImageReference: ImageReference(pixelSize: CGSize(width: 200, height: 100)),
            canvasSize: CGSize(width: 200, height: 100),
            annotations: annotations
        )
    }

    private enum GeometryError: Error {
        case expectedLine
    }
}
