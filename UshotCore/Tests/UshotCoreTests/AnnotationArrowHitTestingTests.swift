import CoreGraphics
import XCTest
@testable import UshotCore

final class AnnotationArrowHitTestingTests: XCTestCase {
    private let tester = AnnotationHitTester()

    func testFilledArrowHitsVisibleWingsButNotConcaveRearNotch() throws {
        let item = makeArrow(style: .filled)
        let geometry = try renderedGeometry(for: item)

        XCTAssertTrue(tester.contains(
            centroid(geometry.headLeft, geometry.tip, geometry.headShaftJoin),
            in: item,
            tolerance: 0
        ))
        XCTAssertTrue(tester.contains(
            centroid(geometry.headRight, geometry.tip, geometry.headShaftJoin),
            in: item,
            tolerance: 0
        ))
        XCTAssertFalse(tester.contains(
            pointInsideRearNotch(of: geometry, lineWidth: item.style.lineWidth),
            in: item,
            tolerance: 0
        ))
    }

    func testDoubleArrowHitsBothHeadsWithoutFillingEitherRearNotch() throws {
        let item = makeArrow(style: .double)
        let forward = try renderedGeometry(for: item)
        let reverse = try XCTUnwrap(ArrowVectorGeometry(
            start: forward.tip,
            tip: forward.start,
            lineWidth: item.style.lineWidth
        ))

        XCTAssertTrue(tester.contains(
            centroid(forward.headLeft, forward.tip, forward.headShaftJoin),
            in: item,
            tolerance: 0
        ))
        XCTAssertTrue(tester.contains(
            centroid(reverse.headLeft, reverse.tip, reverse.headShaftJoin),
            in: item,
            tolerance: 0
        ))
        XCTAssertFalse(tester.contains(
            pointInsideRearNotch(of: forward, lineWidth: item.style.lineWidth),
            in: item,
            tolerance: 0
        ))
        XCTAssertFalse(tester.contains(
            pointInsideRearNotch(of: reverse, lineWidth: item.style.lineWidth),
            in: item,
            tolerance: 0
        ))
    }

    func testArrowHeadUsesRenderedGeometryAfterRotationAndNonuniformScale() throws {
        let item = makeArrow(
            style: .filled,
            start: CGPoint(x: 10, y: 20),
            tip: CGPoint(x: 90, y: 45),
            transform: AnnotationTransform(
                translation: CGSize(width: 13, height: -7),
                rotationRadians: 0.63,
                scaleX: 1.8,
                scaleY: 0.55
            )
        )
        let geometry = try renderedGeometry(for: item)

        XCTAssertTrue(tester.contains(
            centroid(geometry.headLeft, geometry.tip, geometry.headShaftJoin),
            in: item,
            tolerance: 0
        ))
        XCTAssertFalse(tester.contains(
            pointInsideRearNotch(of: geometry, lineWidth: item.style.lineWidth),
            in: item,
            tolerance: 0
        ))
    }

    func testOpenAndTaperedStylesFollowTheirVisiblePresentationPaths() throws {
        let open = makeArrow(style: .open)
        let openGeometry = try renderedGeometry(for: open)
        XCTAssertTrue(tester.contains(
            midpoint(openGeometry.headLeft, openGeometry.tip),
            in: open,
            tolerance: 0
        ))

        let tapered = makeArrow(style: .tapered)
        let taperedGeometry = try renderedGeometry(for: tapered)
        XCTAssertTrue(tester.contains(
            centroid(
                taperedGeometry.taperedNeckLeft,
                taperedGeometry.headLeft,
                taperedGeometry.tip
            ),
            in: tapered,
            tolerance: 0
        ))
    }

    func testShortThickFilledAndDoubleShaftsUseTheRenderedAdaptiveWidth() throws {
        for arrowHeadStyle in [ArrowHeadStyle.filled, .double] {
            let item = makeArrow(
                style: arrowHeadStyle,
                tip: CGPoint(x: 8, y: 0),
                lineWidth: 24
            )
            let geometry = try renderedGeometry(for: item)
            let shaft = arrowHeadStyle == .filled
                ? geometry.filledShaft
                : geometry.doubleShaft(with: try XCTUnwrap(ArrowVectorGeometry(
                    start: geometry.tip,
                    tip: geometry.start,
                    lineWidth: item.style.lineWidth
                )))
            let sampleX: CGFloat = arrowHeadStyle == .filled ? 1 : 4

            XCTAssertTrue(tester.contains(
                CGPoint(x: sampleX, y: shaft.lineWidth * 0.45),
                in: item,
                tolerance: 0
            ))
            XCTAssertFalse(tester.contains(
                CGPoint(x: sampleX, y: shaft.lineWidth * 0.7),
                in: item,
                tolerance: 0
            ))
            XCTAssertFalse(tester.contains(
                CGPoint(x: 10, y: 0),
                in: item,
                tolerance: 0
            ))
        }
    }

    private func makeArrow(
        style arrowHeadStyle: ArrowHeadStyle,
        start: CGPoint = .zero,
        tip: CGPoint = CGPoint(x: 100, y: 0),
        transform: AnnotationTransform = AnnotationTransform(),
        lineWidth: CGFloat = 6
    ) -> AnnotationItem {
        AnnotationItem(
            kind: .arrow,
            zIndex: 0,
            geometry: .line(start: start, end: tip),
            style: AnnotationStyle(lineWidth: lineWidth, arrowHeadStyle: arrowHeadStyle),
            transform: transform
        )
    }

    private func renderedGeometry(for item: AnnotationItem) throws -> ArrowVectorGeometry {
        guard case .line(let start, let tip) = item.geometry else {
            XCTFail("The test arrow must use line geometry.")
            throw TestError.invalidGeometry
        }
        let selectionGeometry = AnnotationSelectionGeometry()
        return try XCTUnwrap(ArrowVectorGeometry(
            start: selectionGeometry.transformedPoint(start, for: item),
            tip: selectionGeometry.transformedPoint(tip, for: item),
            lineWidth: max(0.5, item.style.lineWidth)
        ))
    }

    private func pointInsideRearNotch(
        of geometry: ArrowVectorGeometry,
        lineWidth: CGFloat
    ) -> CGPoint {
        let positionAlongNotch: CGFloat = 0.25
        let notchCenter = interpolated(
            from: geometry.headBaseCenter,
            to: geometry.headShaftJoin,
            progress: positionAlongNotch
        )
        let notchEdge = interpolated(
            from: geometry.headLeft,
            to: geometry.headShaftJoin,
            progress: positionAlongNotch
        )
        let dx = geometry.tip.x - geometry.start.x
        let dy = geometry.tip.y - geometry.start.y
        let length = hypot(dx, dy)
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let pointOutsideShaft = CGPoint(
            x: notchCenter.x + normal.x * (lineWidth / 2 + 1),
            y: notchCenter.y + normal.y * (lineWidth / 2 + 1)
        )
        return midpoint(pointOutsideShaft, notchEdge)
    }

    private func interpolated(
        from start: CGPoint,
        to end: CGPoint,
        progress: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        interpolated(from: first, to: second, progress: 0.5)
    }

    private func centroid(_ first: CGPoint, _ second: CGPoint, _ third: CGPoint) -> CGPoint {
        CGPoint(
            x: (first.x + second.x + third.x) / 3,
            y: (first.y + second.y + third.y) / 3
        )
    }

    private enum TestError: Error {
        case invalidGeometry
    }
}
