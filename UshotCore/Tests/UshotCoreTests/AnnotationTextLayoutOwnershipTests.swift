import Combine
import CoreGraphics
import Foundation
import XCTest
@testable import UshotCore

final class AnnotationTextLayoutOwnershipTests: XCTestCase {
    func testCurrentPayloadRoundTripsAndMissingFieldDecodesAsLegacyTight() throws {
        let style = AnnotationStyle(fontSize: 18)
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 40, y: 60),
            text: "Owned layout",
            style: style,
            maximumWrapWidth: 90
        )
        let item = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(layout.rect),
            style: style,
            text: "Owned layout",
            textLayout: layout.payload
        )

        let encoded = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(AnnotationItem.self, from: encoded), item)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "textLayout")
        let legacy = try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.textLayout)
        guard case .rect(let legacyRect) = legacy.geometry else {
            return XCTFail("Decoded legacy text must retain rectangle geometry.")
        }
        XCTAssertEqual(
            AnnotationTextLayout.contentRect(from: legacyRect, layout: nil),
            legacyRect.standardized
        )
    }

    func testPresentInvalidPayloadFailsFast() throws {
        let item = legacyItem(alignment: .leading, scale: 1)
        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["textLayout"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))

        object["textLayout"] = [
            "version": AnnotationTextLayoutPayload.currentVersion + 1,
            "chromeMode": AnnotationTextLayoutPayload.ChromeMode.legacyTight.rawValue,
            "wrapWidth": 80
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))

        object["textLayout"] = [
            "version": AnnotationTextLayoutPayload.currentVersion,
            "chromeMode": AnnotationTextLayoutPayload.ChromeMode.legacyTight.rawValue,
            "wrapWidth": 0
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))

        let layoutOwnedItem = try explicitLayoutItem()
        let layoutOwnedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(layoutOwnedItem)
            ) as? [String: Any]
        )

        var nonTextObject = layoutOwnedObject
        nonTextObject["kind"] = AnnotationKind.rectangle.rawValue
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: nonTextObject)
        ))

        let lineItem = AnnotationItem(
            kind: .line,
            zIndex: 0,
            geometry: .line(start: .zero, end: CGPoint(x: 20, y: 20))
        )
        let lineObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(lineItem)
            ) as? [String: Any]
        )
        var nonRectObject = layoutOwnedObject
        nonRectObject["geometry"] = try XCTUnwrap(lineObject["geometry"])
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: nonRectObject)
        ))

        var mismatchedWidthObject = layoutOwnedObject
        var mismatchedPayload = try XCTUnwrap(
            mismatchedWidthObject["textLayout"] as? [String: Any]
        )
        mismatchedPayload["wrapWidth"] = try XCTUnwrap(
            layoutOwnedItem.textLayout
        ).wrapWidth + 10
        mismatchedWidthObject["textLayout"] = mismatchedPayload
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: mismatchedWidthObject)
        ))

        guard case .rect(let ownedRect) = layoutOwnedItem.geometry else {
            return XCTFail("Explicit layout fixture must use rectangle geometry.")
        }
        let insets = AnnotationTextLayout.chromeInsets(for: layoutOwnedItem.textLayout)
        let zeroContentHeightItem = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(CGRect(
                x: ownedRect.minX,
                y: ownedRect.minY,
                width: ownedRect.width,
                height: insets.height * 2
            )),
            style: layoutOwnedItem.style,
            text: layoutOwnedItem.text
        )
        let zeroContentHeightObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(zeroContentHeightItem)
            ) as? [String: Any]
        )
        var invalidHeightObject = layoutOwnedObject
        invalidHeightObject["geometry"] = try XCTUnwrap(zeroContentHeightObject["geometry"])
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: invalidHeightObject)
        ))

        for heightDelta in [CGFloat(-1), 1] {
            let mismatchedHeightCarrier = AnnotationItem(
                kind: .text,
                zIndex: 0,
                geometry: .rect(CGRect(
                    x: ownedRect.minX,
                    y: ownedRect.minY,
                    width: ownedRect.width,
                    height: ownedRect.height + heightDelta
                )),
                style: layoutOwnedItem.style,
                text: layoutOwnedItem.text
            )
            let carrierObject = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(mismatchedHeightCarrier)
                ) as? [String: Any]
            )
            var mismatchedHeightObject = layoutOwnedObject
            mismatchedHeightObject["geometry"] = try XCTUnwrap(
                carrierObject["geometry"]
            )
            XCTAssertThrowsError(try JSONDecoder().decode(
                AnnotationItem.self,
                from: JSONSerialization.data(withJSONObject: mismatchedHeightObject)
            ))
        }
    }

    func testEncodingRejectsEveryStaleExplicitLayoutOwner() throws {
        let original = try explicitLayoutItem()

        var changedText = original
        changedText.text = "Explicit layouv"
        XCTAssertThrowsError(try JSONEncoder().encode(changedText))

        var changedFontSize = original
        changedFontSize.style.fontSize += 1
        XCTAssertThrowsError(try JSONEncoder().encode(changedFontSize))

        var changedAlignment = original
        changedAlignment.style.textAlignment = .trailing
        XCTAssertThrowsError(try JSONEncoder().encode(changedAlignment))

        var changedGeometry = original
        guard case .rect(let rect) = changedGeometry.geometry else {
            return XCTFail("Explicit layout fixture must use rectangle geometry.")
        }
        changedGeometry.geometry = .rect(CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width + 1,
            height: rect.height
        ))
        XCTAssertThrowsError(try JSONEncoder().encode(changedGeometry))

        var changedKind = original
        changedKind.kind = .rectangle
        XCTAssertThrowsError(try JSONEncoder().encode(changedKind))
    }

    func testCurrentPayloadDecodesWithoutResolvingTheCurrentMachineFont() throws {
        let original = try explicitLayoutItem()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(original)
            ) as? [String: Any]
        )
        let unavailableName = "Ushot-Intentionally-Unavailable-Font"
        var style = try XCTUnwrap(object["style"] as? [String: Any])
        style["fontName"] = unavailableName
        object["style"] = style
        var payload = try XCTUnwrap(object["textLayout"] as? [String: Any])
        var input = try XCTUnwrap(payload["input"] as? [String: Any])
        input["fontName"] = unavailableName
        payload["input"] = input
        object["textLayout"] = payload

        let decoded = try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.style.fontName, unavailableName)
        XCTAssertNoThrow(try JSONEncoder().encode(decoded))
        guard case .rect(let decodedRect) = decoded.geometry,
              let decodedPayload = decoded.textLayout,
              let layoutEngineRevision = decodedPayload.layoutEngineRevision
        else {
            return XCTFail("Decoded current text must retain explicit rectangle layout.")
        }
        let persistedPlan = try AnnotationTextLayout.persistedPlan(
            text: decoded.text ?? "",
            style: decoded.style,
            payload: decodedPayload
        )
        let baseline = AnnotationTextLayout.baselineY(
            in: decodedRect,
            text: decoded.text ?? "",
            style: decoded.style,
            layout: decodedPayload
        )
        let anchor = AnnotationTextLayout.alignmentAnchor(
            in: decodedRect,
            text: decoded.text ?? "",
            style: decoded.style,
            layout: decodedPayload
        )
        let reconstructedRect = AnnotationTextLayout.annotationRect(
            baselineAnchor: anchor,
            text: decoded.text ?? "",
            style: decoded.style,
            layout: decodedPayload
        )
        let placedLines = AnnotationTextLayout.placedLines(
            in: decodedRect,
            text: decoded.text ?? "",
            style: decoded.style,
            layout: decodedPayload
        )
        XCTAssertTrue(baseline.isFinite)
        XCTAssertEqual(reconstructedRect, decodedRect)
        XCTAssertEqual(placedLines.count, persistedPlan.lines.count)
        XCTAssertThrowsError(try AnnotationTextLayout.renderingTypesetter(
            text: decoded.text ?? "",
            style: decoded.style,
            plan: persistedPlan,
            layoutEngineRevision: layoutEngineRevision,
            foregroundColor: CGColor(gray: 0, alpha: 1)
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .fontUnavailable(unavailableName)
            )
        }
        let unavailableContext = try makeBitmapContext()
        XCTAssertThrowsError(try AnnotationVectorRenderer().draw(
            item: decoded,
            in: unavailableContext,
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .fontUnavailable(unavailableName)
            )
        }
        let baseImage = try XCTUnwrap(makeBitmapContext().makeImage())
        let document = AnnotationDocument(
            baseImageReference: ImageReference(pixelSize: CGSize(width: 320, height: 200)),
            canvasSize: CGSize(width: 320, height: 200),
            annotations: [decoded]
        )
        XCTAssertThrowsError(try AnnotationRenderer().render(
            document: document,
            baseImage: baseImage,
            scale: 1
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .fontUnavailable(unavailableName)
            )
        }

        var invalidSizeObject = object
        var invalidStyle = style
        invalidStyle["fontSize"] = 0
        invalidSizeObject["style"] = invalidStyle
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: invalidSizeObject)
        ))
    }

    func testRuntimeShapeMismatchIsVisibleWithoutInvalidatingHistory() throws {
        let original = try explicitLayoutItem()
        let context = try makeBitmapContext()
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        XCTAssertTrue(try AnnotationVectorRenderer().draw(
            item: original,
            in: context,
            colorSpace: colorSpace
        ))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(original)
            ) as? [String: Any]
        )
        var payload = try XCTUnwrap(object["textLayout"] as? [String: Any])
        var plan = try XCTUnwrap(payload["plan"] as? [String: Any])
        var lines = try XCTUnwrap(plan["lines"] as? [[String: Any]])
        lines[0]["shapeFingerprint"] = String(repeating: "0", count: 64)
        plan["lines"] = lines
        payload["plan"] = plan
        object["textLayout"] = payload

        let decoded = try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNoThrow(try JSONEncoder().encode(decoded))
        guard case .rect(let decodedRect) = decoded.geometry,
              let decodedPayload = decoded.textLayout
        else {
            return XCTFail("Shape-change fixture must retain explicit rectangle layout.")
        }
        let persistedPlan = try AnnotationTextLayout.persistedPlan(
            text: decoded.text ?? "",
            style: decoded.style,
            payload: decodedPayload
        )
        XCTAssertEqual(
            AnnotationTextLayout.placedLines(
                in: decodedRect,
                text: decoded.text ?? "",
                style: decoded.style,
                layout: decodedPayload
            ).count,
            persistedPlan.lines.count
        )
        XCTAssertTrue(AnnotationTextLayout.baselineY(
            in: decodedRect,
            text: decoded.text ?? "",
            style: decoded.style,
            layout: decodedPayload
        ).isFinite)
        XCTAssertThrowsError(try AnnotationVectorRenderer().draw(
            item: decoded,
            in: try makeBitmapContext(),
            colorSpace: colorSpace
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .shapeChanged(lineIndex: 0)
            )
        }
    }

    func testShapeFingerprintBindsExactGlyphOutlineElementStream() {
        let first = makeOutlineProbePath(
            internalElement: { path in
                path.move(to: CGPoint(x: 2, y: 2))
                path.addLine(to: CGPoint(x: 8, y: 8))
            }
        )
        let identical = makeOutlineProbePath(
            internalElement: { path in
                path.move(to: CGPoint(x: 2, y: 2))
                path.addLine(to: CGPoint(x: 8, y: 8))
            }
        )
        let changedCoordinate = makeOutlineProbePath(
            internalElement: { path in
                path.move(to: CGPoint(x: 2, y: 2))
                path.addLine(to: CGPoint(x: 8, y: 7))
            }
        )
        let changedElementType = makeOutlineProbePath(
            internalElement: { path in
                path.move(to: CGPoint(x: 2, y: 2))
                path.addQuadCurve(
                    to: CGPoint(x: 8, y: 8),
                    control: CGPoint(x: 5, y: 5)
                )
            }
        )

        XCTAssertEqual(first.boundingBox, identical.boundingBox)
        XCTAssertEqual(first.boundingBox, changedCoordinate.boundingBox)
        XCTAssertEqual(first.boundingBox, changedElementType.boundingBox)
        XCTAssertEqual(
            AnnotationTextLayout.stableGlyphOutlineFingerprint(first),
            AnnotationTextLayout.stableGlyphOutlineFingerprint(identical)
        )
        XCTAssertNotEqual(
            AnnotationTextLayout.stableGlyphOutlineFingerprint(first),
            AnnotationTextLayout.stableGlyphOutlineFingerprint(changedCoordinate),
            "A changed outline coordinate must not hide behind the same glyph bounds."
        )
        XCTAssertNotEqual(
            AnnotationTextLayout.stableGlyphOutlineFingerprint(first),
            AnnotationTextLayout.stableGlyphOutlineFingerprint(changedElementType),
            "A changed Core Graphics element type must change the shape fingerprint."
        )
    }

    func testFontSourceDigestIsStableAndMissingSourcesAreTyped() throws {
        let font = AnnotationTextLayout.font(
            style: AnnotationStyle(fontSize: 18)
        ) as CTFont
        let first = try AnnotationTextLayout.stableFontSourceFingerprint(font)
        let second = try AnnotationTextLayout.stableFontSourceFingerprint(font)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)

        enum ProbeError: Error { case unreadable }
        let fallbackDigest = Data(repeating: 0xA5, count: 32)
        XCTAssertEqual(
            try AnnotationTextLayout.resolveFontSourceDigest(
                fontName: "Fallback Probe",
                fileDigest: { throw ProbeError.unreadable },
                tableDigest: { fallbackDigest }
            ),
            fallbackDigest
        )
        XCTAssertThrowsError(try AnnotationTextLayout.resolveFontSourceDigest(
            fontName: "Unavailable Source Probe",
            fileDigest: { throw ProbeError.unreadable },
            tableDigest: { nil }
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .fontSourceUnavailable("Unavailable Source Probe")
            )
        }
    }

    func testNoURLFontTableCacheNeverCrossHitsDistinctEqualFontObjects() throws {
        let first = try XCTUnwrap(CTFontCreateUIFontForLanguage(.system, 18, nil))
        let second = try XCTUnwrap(CTFontCreateUIFontForLanguage(.system, 18, nil))
        XCTAssertFalse(first === second)
        XCTAssertTrue(CFEqual(first, second))

        var cache: [AnnotationTextLayout.FontObjectCacheKey: Int] = [:]
        cache[AnnotationTextLayout.FontObjectCacheKey(font: first)] = 1
        cache[AnnotationTextLayout.FontObjectCacheKey(font: first)] = 2
        XCTAssertEqual(cache.count, 1, "The exact immutable CTFont may reuse its table digest.")
        cache[AnnotationTextLayout.FontObjectCacheKey(font: second)] = 3
        XCTAssertEqual(
            cache.count,
            2,
            "A separately created CTFont must rescan all tables even when CFEqual reports equality."
        )
    }

    func testTransientGeometryPlanCannotEnterRendererReadyPayload() throws {
        let text = "Transient geometry"
        let style = AnnotationStyle(fontSize: 18)
        let plan = AnnotationTextLayout.layoutPlan(
            in: text,
            style: style,
            wrapWidth: 120
        )
        XCTAssertEqual(
            Set(plan.lines.map(\.shapeFingerprint)),
            [AnnotationTextLayout.transientShapeFingerprint]
        )
        XCTAssertFalse(AnnotationTextLayout.isRendererReadyPlan(plan))
        XCTAssertThrowsError(try JSONEncoder().encode(plan))
        XCTAssertThrowsError(try AnnotationTextLayoutPayload(
            chromeMode: .uniformPadded,
            wrapWidth: plan.wrapWidth,
            leadingOverhang: plan.requiredLeadingOverhang,
            trailingOverhang: plan.requiredTrailingOverhang,
            input: AnnotationTextLayoutInput(text: text, style: style),
            plan: plan
        )) { error in
            guard case AnnotationTextLayoutValidationError
                .malformedPersistedPlan = error
            else {
                return XCTFail("Expected transient payload rejection, got \(error)")
            }
        }

        let rendererReady = try AnnotationTextLayout.safeLayoutPayload(
            for: text,
            style: style,
            proposedWrapWidth: 120,
            chromeMode: .uniformPadded
        )
        XCTAssertTrue(try XCTUnwrap(rendererReady.plan).lines.allSatisfy {
            $0.shapeFingerprint.count == 64
        })
    }

    func testLargeEmojiFingerprintUsesCompleteSourceWithoutRasterLimit() throws {
        let text = "😀"
        let style = AnnotationStyle(fontSize: 512)
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 100, y: 700),
            text: text,
            style: style,
            maximumWrapWidth: 800
        )
        let repeatedPayload = try AnnotationTextLayout.safeLayoutPayload(
            for: text,
            style: style,
            proposedWrapWidth: layout.payload.wrapWidth,
            chromeMode: layout.payload.chromeMode
        )
        XCTAssertEqual(
            repeatedPayload.plan?.lines.map(\.shapeFingerprint),
            layout.payload.plan?.lines.map(\.shapeFingerprint),
            "The same 512-point color glyph must produce a stable complete-source fingerprint."
        )
        let item = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(layout.rect),
            style: style,
            text: text,
            textLayout: layout.payload
        )
        XCTAssertNoThrow(try AnnotationTextLayout.validateEditingCapability(
            text: text,
            style: style,
            rect: layout.rect,
            layout: layout.payload
        ))
        XCTAssertTrue(try AnnotationVectorRenderer().draw(
            item: item,
            in: try makeBitmapContext(width: 1_024, height: 1_024),
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        ))
    }

    func testRendererRejectsRawNegativeExplicitTextGeometry() throws {
        var item = try explicitLayoutItem()
        guard case .rect(let rect) = item.geometry else {
            return XCTFail("Explicit layout fixture must use rectangle geometry.")
        }
        item.geometry = .rect(CGRect(
            x: rect.maxX,
            y: rect.minY,
            width: -rect.width,
            height: rect.height
        ))
        XCTAssertThrowsError(try AnnotationVectorRenderer().draw(
            item: item,
            in: try makeBitmapContext(),
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextLayoutValidationError,
                .nonPositiveRectangle
            )
        }
        XCTAssertThrowsError(try AnnotationTextLayout.validateEditingCapability(
            text: item.text ?? "",
            style: item.style,
            rect: {
                guard case .rect(let invalidRect) = item.geometry else {
                    return .zero
                }
                return invalidRect
            }(),
            layout: item.textLayout
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextLayoutValidationError,
                .nonPositiveRectangle
            )
        }
    }

    func testCounterFontFailureThrowsBeforeDrawingAnyPixels() throws {
        var style = AnnotationStyle(
            strokeColor: .systemRed,
            fillColor: .white
        )
        let unavailableName = "Ushot-Intentionally-Unavailable-Font"
        style.fontName = unavailableName
        let item = AnnotationItem(
            kind: .counter,
            zIndex: 0,
            geometry: .rect(CGRect(x: 20, y: 20, width: 44, height: 44)),
            style: style,
            counterValue: 12
        )
        let context = try makeBitmapContext()
        XCTAssertThrowsError(try AnnotationVectorRenderer().draw(
            item: item,
            in: context,
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .fontUnavailable(unavailableName)
            )
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
    }

    func testPersistedPlanTamperingFailsWithoutRuntimeRelayout() throws {
        let original = try explicitLayoutItem()
        let encoded = try JSONEncoder().encode(original)
        let originalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        func assertRejected(
            _ mutation: (inout [String: Any]) throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            var object = originalObject
            try mutation(&object)
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    AnnotationItem.self,
                    from: JSONSerialization.data(withJSONObject: object)
                ),
                file: file,
                line: line
            )
        }

        try assertRejected { object in
            var payload = try XCTUnwrap(object["textLayout"] as? [String: Any])
            var plan = try XCTUnwrap(payload["plan"] as? [String: Any])
            plan["contentHeight"] = try XCTUnwrap(plan["contentHeight"] as? CGFloat) + 1
            payload["plan"] = plan
            object["textLayout"] = payload
        }
        try assertRejected { object in
            var payload = try XCTUnwrap(object["textLayout"] as? [String: Any])
            var plan = try XCTUnwrap(payload["plan"] as? [String: Any])
            var lines = try XCTUnwrap(plan["lines"] as? [[String: Any]])
            lines[0]["shapeFingerprint"] = "NOT-A-SHA256"
            plan["lines"] = lines
            payload["plan"] = plan
            object["textLayout"] = payload
        }
        try assertRejected { object in
            var payload = try XCTUnwrap(object["textLayout"] as? [String: Any])
            var plan = try XCTUnwrap(payload["plan"] as? [String: Any])
            var lines = try XCTUnwrap(plan["lines"] as? [[String: Any]])
            lines[0]["utf16Range"] = [999, 1]
            plan["lines"] = lines
            payload["plan"] = plan
            object["textLayout"] = payload
        }
        try assertRejected { object in
            var payload = try XCTUnwrap(object["textLayout"] as? [String: Any])
            var plan = try XCTUnwrap(payload["plan"] as? [String: Any])
            var lines = try XCTUnwrap(plan["lines"] as? [[String: Any]])
            lines[0]["baselineOffset"] = 1
            plan["lines"] = lines
            payload["plan"] = plan
            object["textLayout"] = payload
        }
    }

    func testSchemaOneLegacyDocumentMigratesLosslesslyAndReencodesAsSchemaTwo() throws {
        let original = makeDocument(item: legacyItem(alignment: .center, scale: 1.5))
        var legacyObject = try documentJSONObject(original)
        legacyObject["schemaVersion"] = 1

        let migrated = try JSONDecoder().decode(
            AnnotationDocument.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertEqual(migrated, original)
        XCTAssertEqual(migrated.schemaVersion, AnnotationDocument.currentSchemaVersion)
        XCTAssertNil(try XCTUnwrap(migrated.annotations.first).textLayout)
        guard case .rect(let originalRect) = try XCTUnwrap(original.annotations.first).geometry,
              case .rect(let migratedRect) = try XCTUnwrap(migrated.annotations.first).geometry
        else {
            return XCTFail("Legacy migration must preserve rectangle geometry.")
        }
        XCTAssertEqual(migratedRect, originalRect)

        let reencodedObject = try documentJSONObject(migrated)
        XCTAssertEqual(
            reencodedObject["schemaVersion"] as? Int,
            AnnotationDocument.currentSchemaVersion
        )
    }

    func testSchemaOneDocumentRejectsVersionTwoTextLayoutState() throws {
        let original = makeDocument(item: try explicitLayoutItem())
        var legacyObject = try documentJSONObject(original)
        legacyObject["schemaVersion"] = 1

        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationDocument.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        ))
    }

    func testSchemaTwoDocumentWithExplicitPayloadRoundTrips() throws {
        let original = makeDocument(item: try explicitLayoutItem())
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, AnnotationDocument.currentSchemaVersion)
        XCTAssertEqual(
            try XCTUnwrap(decoded.annotations.first).textLayout,
            try XCTUnwrap(original.annotations.first).textLayout
        )

        let publishedV1Admission = try JSONDecoder().decode(
            PublishedV1DocumentAdmission.self,
            from: encoded
        )
        XCTAssertFalse(
            publishedV1Admission.acceptsDocument,
            "The published schema-1 reader's admission gate must reject a schema-2 document."
        )
    }

    func testZeroAndFutureDocumentSchemasAreRejected() throws {
        let original = makeDocument(item: legacyItem(alignment: .leading, scale: 1))
        for unsupportedVersion in [0, AnnotationDocument.currentSchemaVersion + 1] {
            var object = try documentJSONObject(original)
            object["schemaVersion"] = unsupportedVersion
            XCTAssertThrowsError(try JSONDecoder().decode(
                AnnotationDocument.self,
                from: JSONSerialization.data(withJSONObject: object)
            ))
        }
    }

    func testEncodingNoncurrentInMemorySchemaIsRejected() throws {
        var document = makeDocument(item: legacyItem(alignment: .trailing, scale: 1))
        document.schemaVersion = 1

        XCTAssertThrowsError(try JSONEncoder().encode(document))
    }

    func testLegacyNoOpReflowIsExactlyStableAcrossAlignmentAndUniformScale() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for alignment in AnnotationTextAlignment.allCases {
            for scale in [CGFloat(0.5), 1.5] {
                let item = legacyItem(alignment: alignment, scale: scale)
                let originalLines = AnnotationTextLayout.visualLines(
                    in: item.text ?? "",
                    style: item.style,
                    wrapWidth: AnnotationTextLayout.canonicalWrapWidth(for: item)
                )

                let result = try AnnotationTextLayout.reflowedTextItem(
                    item,
                    text: item.text ?? "",
                    fontSize: item.style.fontSize,
                    wrapWidthStrategy: .preserve
                )

                XCTAssertEqual(result, item)
                XCTAssertEqual(try encoder.encode(result), try encoder.encode(item))
                XCTAssertNil(result.textLayout)
                XCTAssertEqual(result.transform.scaleX, scale)
                XCTAssertEqual(result.transform.scaleY, scale)
                let wrapWidth = AnnotationTextLayout.canonicalWrapWidth(for: item)
                let fieldWidth = AnnotationTextLayout.presentationFieldWidth(
                    canonicalWrapWidth: wrapWidth,
                    chromeMode: .legacyTight,
                    canvasScale: 2,
                    uniformTransformScale: scale
                )
                XCTAssertEqual(fieldWidth, wrapWidth * 2 * scale, accuracy: 0.001)
                XCTAssertEqual(
                    AnnotationTextLayout.canonicalWrapWidth(
                        fromPresentationFieldWidth: fieldWidth,
                        chromeMode: .legacyTight,
                        canvasScale: 2,
                        uniformTransformScale: scale
                    ),
                    wrapWidth,
                    accuracy: 0.001
                )
                XCTAssertEqual(
                    AnnotationTextLayout.visualLines(
                        in: result.text ?? "",
                        style: result.style,
                        wrapWidth: AnnotationTextLayout.canonicalWrapWidth(for: result)
                    ),
                    originalLines
                )
            }
        }
    }

    func testLegacySemanticEditMaterializesExplicitTightLayoutWithoutMovingBaseline() throws {
        let item = legacyItem(alignment: .trailing, scale: 1.5)
        guard case .rect(let originalRect) = item.geometry else {
            return XCTFail("Fixture must use rectangle geometry.")
        }
        let originalAnchor = AnnotationTextLayout.alignmentAnchor(
            in: originalRect,
            text: item.text ?? "",
            style: item.style,
            layout: nil
        )

        let result = try AnnotationTextLayout.reflowedTextItem(
            item,
            text: "Legacy text plus enough words to wrap",
            fontSize: item.style.fontSize,
            wrapWidthStrategy: .preserve
        )
        let payload = try XCTUnwrap(result.textLayout)
        XCTAssertEqual(payload.chromeMode, .legacyTight)
        XCTAssertEqual(
            payload.wrapWidth,
            AnnotationTextLayout.canonicalWrapWidth(for: item),
            accuracy: 0.001
        )
        guard case .rect(let resultRect) = result.geometry else {
            return XCTFail("Reflowed text must use rectangle geometry.")
        }
        let resultAnchor = AnnotationTextLayout.alignmentAnchor(
            in: resultRect,
            text: result.text ?? "",
            style: result.style,
            layout: result.textLayout
        )
        XCTAssertEqual(resultAnchor.x, originalAnchor.x, accuracy: 0.001)
        XCTAssertEqual(resultAnchor.y, originalAnchor.y, accuracy: 0.001)
    }

    @MainActor
    func testControllerTextEditReflowsAtomicallyAndOneUndoRestoresCompleteItem() throws {
        let style = AnnotationStyle(fontSize: 18, textAlignment: .center)
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 120, y: 100),
            text: "Short",
            style: style,
            maximumWrapWidth: 72
        )
        let original = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(layout.rect),
            style: style,
            text: "Short",
            textLayout: layout.payload
        )
        let controller = AnnotationDocumentController(document: makeDocument(item: original))
        let longText = "A much longer inspector sentence that must remain inside its selection bounds."

        try controller.updateTextItemLayout(
            id: original.id,
            text: longText,
            fontSize: 27,
            wrapWidthStrategy: .scaleWithFont
        )

        XCTAssertEqual(controller.undoStack.count, 1)
        let updated = try XCTUnwrap(controller.document.annotations.first)
        let wrapWidth = AnnotationTextLayout.canonicalWrapWidth(for: updated)
        let plan = AnnotationTextLayout.layoutPlan(
            in: longText,
            style: updated.style,
            wrapWidth: wrapWidth
        )
        XCTAssertGreaterThan(plan.lineCount, 1)
        XCTAssertEqual(plan.lines.first?.consumedUTF16Range.location, 0)
        XCTAssertEqual(
            plan.lines.last.map { NSMaxRange($0.consumedUTF16Range) },
            longText.utf16.count
        )
        for pair in zip(plan.lines, plan.lines.dropFirst()) {
            XCTAssertEqual(
                NSMaxRange(pair.0.consumedUTF16Range),
                pair.1.consumedUTF16Range.location
            )
        }
        guard case .rect(let updatedRect) = updated.geometry else {
            return XCTFail("Updated text must retain rectangle geometry.")
        }
        let content = AnnotationTextLayout.contentRect(
            from: updatedRect,
            layout: updated.textLayout
        )
        let baseline = AnnotationTextLayout.alignmentAnchor(
            in: updatedRect,
            text: updated.text ?? "",
            style: updated.style,
            layout: updated.textLayout
        ).y
        let lastBaseline = baseline
            + (plan.lines.last?.baselineOffset ?? 0)
        XCTAssertGreaterThanOrEqual(
            lastBaseline - (plan.lines.last?.metrics.descent ?? 0),
            content.minY - 0.01
        )

        controller.undo()
        XCTAssertEqual(controller.document.annotations, [original])
    }

    @MainActor
    func testControllerCapabilityFailurePublishesNoPartialTextState() throws {
        var original = legacyItem(alignment: .leading, scale: 1)
        let unavailableFontName = "Ushot-Intentionally-Unavailable-Controller-Font"
        original.style.fontName = unavailableFontName
        let controller = AnnotationDocumentController(
            document: makeDocument(item: original)
        )
        let initialState = controller.state
        var publicationCount = 0
        let observation = controller.objectWillChange.sink {
            publicationCount += 1
        }

        XCTAssertThrowsError(try controller.updateTextItemLayout(
            id: original.id,
            text: "Changed text",
            fontSize: original.style.fontSize,
            wrapWidthStrategy: .preserve
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .fontUnavailable(unavailableFontName)
            )
        }
        XCTAssertEqual(controller.state, initialState)
        XCTAssertEqual(publicationCount, 0)
        XCTAssertTrue(controller.undoStack.isEmpty)
        XCTAssertTrue(controller.redoStack.isEmpty)

        let transaction = controller.beginContinuousEdit(
            label: "Unavailable text preview",
            owner: "test-capability-failure",
            itemID: original.id
        )
        XCTAssertThrowsError(try controller.previewTextItemLayout(
            transaction: transaction,
            id: original.id,
            text: "Preview text",
            fontSize: original.style.fontSize,
            wrapWidthStrategy: .preserve
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .fontUnavailable(unavailableFontName)
            )
        }
        XCTAssertEqual(controller.state, initialState)
        XCTAssertEqual(publicationCount, 0)
        XCTAssertTrue(controller.undoStack.isEmpty)
        XCTAssertTrue(controller.isContinuousEditActive(transaction))
        XCTAssertTrue(controller.cancelContinuousEdit(transaction))
        withExtendedLifetime(observation) {}
    }

    func testFontResizeScalesCanonicalWrapWidthAndPreservesBaseline() throws {
        let style = AnnotationStyle(fontSize: 18, textAlignment: .leading)
        let payload = try AnnotationTextLayout.safeLayoutPayload(
            for: "Wrap width resize consistency",
            style: style,
            proposedWrapWidth: 96,
            chromeMode: .uniformPadded,
        )
        let rect = AnnotationTextLayout.annotationRect(
            baselineAnchor: CGPoint(x: 35, y: 90),
            text: "Wrap width resize consistency",
            style: style,
            canonicalWrapWidth: payload.wrapWidth,
            chromeMode: payload.chromeMode
        )
        let item = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(rect),
            style: style,
            text: "Wrap width resize consistency",
            textLayout: payload
        )
        let beforeAnchor = AnnotationTextLayout.alignmentAnchor(
            in: rect,
            text: item.text ?? "",
            style: style,
            layout: payload
        )

        let resized = try AnnotationTextLayout.reflowedTextItem(
            item,
            text: item.text ?? "",
            fontSize: 27,
            wrapWidthStrategy: .scaleWithFont
        )
        XCTAssertEqual(try XCTUnwrap(resized.textLayout).wrapWidth, 144, accuracy: 0.001)
        guard case .rect(let resizedRect) = resized.geometry else {
            return XCTFail("Resized text must retain rectangle geometry.")
        }
        XCTAssertEqual(
            AnnotationTextLayout.contentRect(
                from: resizedRect,
                layout: resized.textLayout
            ).width,
            144,
            accuracy: 0.001
        )
        let afterAnchor = AnnotationTextLayout.alignmentAnchor(
            in: resizedRect,
            text: resized.text ?? "",
            style: resized.style,
            layout: resized.textLayout
        )
        XCTAssertEqual(afterAnchor.x, beforeAnchor.x, accuracy: 0.001)
        XCTAssertEqual(afterAnchor.y, beforeAnchor.y, accuracy: 0.001)
    }

    func testMaximumFontSizeRecomputesLineCountAtAvailableWidthCap() {
        let style = AnnotationStyle(fontSize: 12)
        let text = String(repeating: "Boundary wrap ", count: 12)
        let maximumWrapWidth: CGFloat = 108
        let maximumHeight: CGFloat = 220
        let result = AnnotationTextLayout.maximumFontSize(
            text: text,
            style: style,
            wrapWidthAtInitialSize: 96,
            initialFontSize: 12,
            upperBound: 48,
            maximumContentHeight: maximumHeight,
            maximumWrapWidth: maximumWrapWidth
        )
        let resolvedWrapWidth = min(maximumWrapWidth, 96 * result / 12)
        let resolvedLineCount = AnnotationTextLayout.visualLineCount(
            in: text,
            style: style,
            wrapWidth: resolvedWrapWidth,
            size: result
        )
        let resolvedHeight = AnnotationTextLayout.lineAdvance(
            style: style,
            size: result
        ) * CGFloat(resolvedLineCount)
        XCTAssertLessThanOrEqual(resolvedHeight, maximumHeight + 0.01)
        XCTAssertLessThan(result, 48)

        let probeSize = min(48, result + 0.05)
        let probeWrapWidth = min(maximumWrapWidth, 96 * probeSize / 12)
        let cappedCount = AnnotationTextLayout.visualLineCount(
            in: text,
            style: style,
            wrapWidth: probeWrapWidth,
            size: probeSize
        )
        let uncappedCount = AnnotationTextLayout.visualLineCount(
            in: text,
            style: style,
            wrapWidth: 96 * probeSize / 12,
            size: probeSize
        )
        XCTAssertGreaterThan(cappedCount, uncappedCount)
        XCTAssertGreaterThan(
            AnnotationTextLayout.lineAdvance(style: style, size: probeSize)
                * CGFloat(cappedCount),
            maximumHeight
        )
    }

    private func legacyItem(
        alignment: AnnotationTextAlignment,
        scale: CGFloat
    ) -> AnnotationItem {
        let style = AnnotationStyle(fontSize: 18, textAlignment: alignment)
        let text = "Legacy wrapped text"
        let wrapWidth: CGFloat = 88
        let rect = AnnotationTextLayout.annotationRect(
            baselineAnchor: CGPoint(x: 110, y: 90),
            text: text,
            style: style,
            canonicalWrapWidth: wrapWidth,
            chromeMode: .legacyTight
        )
        return AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(rect),
            style: style,
            transform: AnnotationTransform(scaleX: scale, scaleY: scale),
            text: text
        )
    }

    private func explicitLayoutItem() throws -> AnnotationItem {
        let style = AnnotationStyle(fontSize: 18, textAlignment: .leading)
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 60, y: 90),
            text: "Explicit layout",
            style: style,
            maximumWrapWidth: 96
        )
        return AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(layout.rect),
            style: style,
            text: "Explicit layout",
            textLayout: layout.payload
        )
    }

    private func makeOutlineProbePath(
        internalElement: (CGMutablePath) -> Void
    ) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 10, height: 10))
        internalElement(path)
        return path.copy()!
    }

    private func makeBitmapContext(
        width: Int = 320,
        height: Int = 200
    ) throws -> CGContext {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    private func documentJSONObject(
        _ document: AnnotationDocument
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(document)
            ) as? [String: Any]
        )
    }

    private func makeDocument(item: AnnotationItem) -> AnnotationDocument {
        AnnotationDocument(
            baseImageReference: ImageReference(pixelSize: CGSize(width: 320, height: 200)),
            canvasSize: CGSize(width: 320, height: 200),
            annotations: [item]
        )
    }

    /// Mirrors the published 0.1.7 history/render admission boundary: its
    /// synthesized item decoding ignores fields it does not know, but the
    /// document is usable only when the stored schema equals version 1.
    private struct PublishedV1DocumentAdmission: Decodable {
        let schemaVersion: Int

        var acceptsDocument: Bool { schemaVersion == 1 }
    }
}
