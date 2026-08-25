import AppKit
import CoreGraphics
import CoreText
import XCTest
@testable import UshotCore

final class AnnotationTextKitLayoutPlanTests: XCTestCase {
    func testOwnershipSentenceUsesTheThreeTextKitWordWrappedLines() throws {
        let text = "A much longer inspector sentence that must remain inside its selection bounds."
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica",
            textAlignment: .leading
        )

        let plan = AnnotationTextLayout.layoutPlan(
            in: text,
            style: style,
            wrapWidth: 217
        )

        XCTAssertEqual(plan.lineCount, 3)
        XCTAssertEqual(plan.lines.map(\.text), [
            "A much longer inspector ",
            "sentence that must remain ",
            "inside its selection bounds."
        ])
        XCTAssertEqual(plan.lines.map(\.utf16Range), [
            NSRange(location: 0, length: 24),
            NSRange(location: 24, length: 26),
            NSRange(location: 50, length: 28)
        ])
        XCTAssertEqual(
            AnnotationTextLayout.visualLines(
                in: text,
                style: style,
                wrapWidth: 217
            ),
            plan.lines.map(\.text)
        )
        XCTAssertEqual(
            AnnotationTextLayout.visualLineCount(
                in: text,
                style: style,
                wrapWidth: 217
            ),
            plan.lineCount
        )
    }

    func testRangesPreserveSpacesHardBreaksCJKAndComposedEmoji() throws {
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica",
            textAlignment: .leading
        )
        let cases: [(String, CGFloat)] = [
            ("alpha  beta   gamma \n", 80),
            ("中文排版会在宽度边界正确换行", 80),
            ("👩‍👩‍👧‍👦 café 👍🏽 sequence", 80)
        ]

        for (text, width) in cases {
            let plan = AnnotationTextLayout.layoutPlan(
                in: text,
                style: style,
                wrapWidth: width
            )
            XCTAssertEqual(
                plan.lines.map(\.text).joined(),
                text.filter { !$0.isNewline }
            )
            XCTAssertEqual(plan.lines.first?.consumedUTF16Range.location, 0)
            XCTAssertEqual(
                plan.lines.last.map { NSMaxRange($0.consumedUTF16Range) },
                text.utf16.count
            )
            for pair in zip(plan.lines, plan.lines.dropFirst()) {
                XCTAssertEqual(
                    NSMaxRange(pair.0.consumedUTF16Range),
                    pair.1.consumedUTF16Range.location
                )
            }
            for line in plan.lines {
                XCTAssertNotNil(Range(line.utf16Range, in: text))
                XCTAssertNotNil(Range(line.consumedUTF16Range, in: text))
            }
        }

        let spaced = AnnotationTextLayout.layoutPlan(
            in: cases[0].0,
            style: style,
            wrapWidth: cases[0].1
        )
        XCTAssertEqual(spaced.lines.map(\.text), ["alpha  ", "beta   ", "gamma ", ""])
        XCTAssertEqual(spaced.lines.last?.utf16Range, NSRange(location: 21, length: 0))

        let emoji = AnnotationTextLayout.layoutPlan(
            in: cases[2].0,
            style: style,
            wrapWidth: cases[2].1
        )
        XCTAssertEqual(emoji.lines.map(\.utf16Range), [
            NSRange(location: 0, length: 17),
            NSRange(location: 17, length: 5),
            NSRange(location: 22, length: 8)
        ])
    }

    func testFormFeedAndVerticalTabOwnCompleteHardBreakLayout() throws {
        let text = "first\u{000C}second\u{000B}third"
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica",
            textAlignment: .leading
        )
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 80, y: 120),
            text: text,
            style: style,
            maximumWrapWidth: 120
        )
        let plan = try AnnotationTextLayout.persistedPlan(
            text: text,
            style: style,
            payload: layout.payload
        )

        XCTAssertEqual(plan.lines.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(plan.lines.first?.consumedUTF16Range.location, 0)
        XCTAssertEqual(
            plan.lines.last.map { NSMaxRange($0.consumedUTF16Range) },
            text.utf16.count
        )
        XCTAssertNoThrow(try AnnotationTextLayout.validateExplicitLayout(
            text: text,
            style: style,
            rect: layout.rect,
            payload: layout.payload
        ))
    }

    func testWrappingOwnershipIsStableAcrossAlignmentAndWidths() {
        let text = "One  two 中文 👩‍👩‍👧‍👦 four five six"
        let widths: [CGFloat] = [64, 97, 217]
        for width in widths {
            var referenceLines: [AnnotationTextLayoutLine]?
            for alignment in AnnotationTextAlignment.allCases {
                let style = AnnotationStyle(
                    fontSize: 18,
                    fontName: "Helvetica",
                    textAlignment: alignment
                )
                let plan = AnnotationTextLayout.layoutPlan(
                    in: text,
                    style: style,
                    wrapWidth: width
                )
                if let referenceLines {
                    XCTAssertEqual(plan.lines.map(\.text), referenceLines.map(\.text))
                    XCTAssertEqual(plan.lines.map(\.utf16Range), referenceLines.map(\.utf16Range))
                    XCTAssertEqual(
                        plan.lines.map(\.consumedUTF16Range),
                        referenceLines.map(\.consumedUTF16Range)
                    )
                } else {
                    referenceLines = plan.lines
                }
                XCTAssertEqual(
                    plan.lines.map(\.baselineOffset),
                    plan.lines.indices.map { -CGFloat($0) * plan.lineAdvance }
                )
            }
        }
    }

    func testPlanOriginsExactlyMatchTextKitAcrossFontsAlignmentAndTrailingSpaces() throws {
        let fixtures = [
            ("Helvetica", "trailing spaces   "),
            ("Helvetica-Oblique", "Italic fj Ág   "),
            ("Zapfino", "Zapfino fj Ág   ")
        ]
        for (fontName, text) in fixtures {
            for alignment in AnnotationTextAlignment.allCases {
                let style = AnnotationStyle(
                    fontSize: 18,
                    fontName: fontName,
                    textAlignment: alignment
                )
                let plan = AnnotationTextLayout.layoutPlan(
                    in: text,
                    style: style,
                    wrapWidth: 217
                )
                let textKitOrigins = independentTextKitOrigins(
                    text: text,
                    style: style,
                    wrapWidth: 217
                )
                XCTAssertEqual(plan.lines.map(\.originX), textKitOrigins)

                let layout = try AnnotationTextLayout.newTextLayout(
                    baselineAnchor: CGPoint(x: 240, y: 180),
                    text: text,
                    style: style,
                    maximumWrapWidth: 217
                )
                let textContainer = AnnotationTextLayout.textContainerRect(
                    from: layout.rect,
                    layout: layout.payload
                )
                let persistedPlan = AnnotationTextLayout.layoutPlan(
                    in: text,
                    style: style,
                    wrapWidth: layout.payload.wrapWidth
                )
                let persistedTextKitOrigins = independentTextKitOrigins(
                    text: text,
                    style: style,
                    wrapWidth: layout.payload.wrapWidth
                )
                XCTAssertEqual(
                    persistedPlan.lines.map { textContainer.minX + $0.originX },
                    persistedTextKitOrigins.map { textContainer.minX + $0 }
                )
            }
        }

        let trailingStyle = AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica",
            textAlignment: .trailing
        )
        let trailingPlan = AnnotationTextLayout.layoutPlan(
            in: "trailing spaces   ",
            style: trailingStyle,
            wrapWidth: 217
        )
        let first = try XCTUnwrap(trailingPlan.lines.first)
        XCTAssertNotEqual(
            first.originX,
            217 - first.width,
            "TextKit right-aligns visible glyphs before trailing whitespace; Core Text width arithmetic is not the editor origin."
        )
    }

    func testPlanOriginsUseVisualTextKitBoundsForBidirectionalLines() throws {
        let fixtures = [
            "שלום",
            "مرحبا",
            "שלום abc",
            "abc مرحبا 123"
        ]
        for text in fixtures {
            for alignment in AnnotationTextAlignment.allCases {
                let style = AnnotationStyle(
                    fontSize: 18,
                    fontName: "Helvetica",
                    textAlignment: alignment
                )
                let plan = AnnotationTextLayout.layoutPlan(
                    in: text,
                    style: style,
                    wrapWidth: 150
                )
                let textKitOrigins = independentTextKitOrigins(
                    text: text,
                    style: style,
                    wrapWidth: 150
                )
                XCTAssertEqual(plan.lines.map(\.originX), textKitOrigins)

                let layout = try AnnotationTextLayout.newTextLayout(
                    baselineAnchor: CGPoint(x: 180, y: 120),
                    text: text,
                    style: style,
                    maximumWrapWidth: 150
                )
                let container = AnnotationTextLayout.textContainerRect(
                    from: layout.rect,
                    layout: layout.payload
                )
                let baseline = AnnotationTextLayout.baselineY(
                    in: layout.rect,
                    text: text,
                    style: style,
                    layout: layout.payload
                )
                let content = AnnotationTextLayout.contentRect(
                    from: layout.rect,
                    layout: layout.payload
                ).insetBy(dx: -0.001, dy: -0.001)
                let persistedPlan = try AnnotationTextLayout.persistedPlan(
                    text: text,
                    style: style,
                    payload: layout.payload
                )
                for line in persistedPlan.lines where !line.glyphBounds.isEmpty {
                    XCTAssertTrue(content.contains(line.glyphBounds.offsetBy(
                        dx: container.minX + line.originX,
                        dy: baseline + line.baselineOffset
                    )))
                }
            }
        }
    }

    func testSoftWrappedRTLContinuationKeepsFullParagraphBidiContext() throws {
        let text = "שלום שלום שלום 123 !!! abc"
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica",
            textAlignment: .leading
        )
        let plan = AnnotationTextLayout.layoutPlan(
            in: text,
            style: style,
            wrapWidth: 90
        )
        let continuation = try XCTUnwrap(
            plan.lines.first(where: { $0.text == "123 !!! abc" })
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = plan.lineAdvance
        paragraph.maximumLineHeight = plan.lineAdvance
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AnnotationTextLayout.font(style: style),
            .paragraphStyle: paragraph
        ]
        let typesetter = CTTypesetterCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        let contextualLine = CTTypesetterCreateLine(
            typesetter,
            CFRange(
                location: continuation.utf16Range.location,
                length: continuation.utf16Range.length
            )
        )
        let contextualDirections = (CTLineGetGlyphRuns(contextualLine) as! [CTRun])
            .map { CTRunGetStatus($0).contains(.rightToLeft) }
        XCTAssertTrue(contextualDirections.contains(true))
        XCTAssertTrue(contextualDirections.contains(false))

        let isolatedLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: continuation.text,
            attributes: attributes
        ))
        let isolatedDirections = (CTLineGetGlyphRuns(isolatedLine) as! [CTRun])
            .map { CTRunGetStatus($0).contains(.rightToLeft) }
        XCTAssertEqual(isolatedDirections, [false])
    }

    func testEmptyExplicitCaretOriginRespectsEveryAlignment() throws {
        let anchor = CGPoint(x: 180, y: 120)
        for alignment in AnnotationTextAlignment.allCases {
            let style = AnnotationStyle(
                fontSize: 18,
                fontName: "Helvetica",
                textAlignment: alignment
            )
            let emptyPayload = try AnnotationTextLayout.safeLayoutPayload(
                for: "",
                style: style,
                proposedWrapWidth: 80,
                chromeMode: .uniformPadded
            )
            let emptyRect = AnnotationTextLayout.annotationRect(
                baselineAnchor: anchor,
                text: "",
                style: style,
                layout: emptyPayload
            )
            let emptyLine = try XCTUnwrap(AnnotationTextLayout.placedLines(
                in: emptyRect,
                text: "",
                style: style,
                layout: emptyPayload
            ).first)
            XCTAssertEqual(emptyLine.origin.x, anchor.x, accuracy: 0.001)

            let typedPayload = try AnnotationTextLayout.safeLayoutPayload(
                for: "A",
                style: style,
                proposedWrapWidth: 80,
                chromeMode: .uniformPadded
            )
            let typedRect = AnnotationTextLayout.annotationRect(
                baselineAnchor: anchor,
                text: "A",
                style: style,
                layout: typedPayload
            )
            XCTAssertEqual(
                AnnotationTextLayout.alignmentAnchor(
                    in: typedRect,
                    text: "A",
                    style: style,
                    layout: typedPayload
                ),
                anchor
            )
        }
    }

    func testExplicitZapfinoGeometryContainsTypographicAndGlyphBounds() throws {
        let text = "Zapfino fj Ág\nSecond line"
        for alignment in AnnotationTextAlignment.allCases {
            let style = AnnotationStyle(
                fontSize: 18,
                fontName: "Zapfino",
                textAlignment: alignment
            )
            let layout = try AnnotationTextLayout.newTextLayout(
                baselineAnchor: CGPoint(x: 240, y: 180),
                text: text,
                style: style
            )
            let content = AnnotationTextLayout.contentRect(
                from: layout.rect,
                layout: layout.payload
            )
            let textContainer = AnnotationTextLayout.textContainerRect(
                from: layout.rect,
                layout: layout.payload
            )
            let plan = AnnotationTextLayout.layoutPlan(
                in: text,
                style: style,
                wrapWidth: layout.payload.wrapWidth
            )
            let baseline = AnnotationTextLayout.baselineY(
                in: layout.rect,
                text: text,
                style: style,
                layout: layout.payload
            )

            XCTAssertGreaterThanOrEqual(
                plan.lineAdvance,
                AnnotationTextLayout.lineAdvance(style: style)
            )
            XCTAssertEqual(content.height, plan.contentHeight, accuracy: 0.001)
            XCTAssertEqual(baseline, 180, accuracy: 0.001)
            for line in plan.lines where !line.glyphBounds.isEmpty {
                let placedGlyphBounds = line.glyphBounds.offsetBy(
                    dx: textContainer.minX + line.originX,
                    dy: baseline + line.baselineOffset
                )
                XCTAssertGreaterThanOrEqual(placedGlyphBounds.minX, content.minX - 0.001)
                XCTAssertLessThanOrEqual(placedGlyphBounds.maxX, content.maxX + 0.001)
                XCTAssertGreaterThanOrEqual(placedGlyphBounds.minY, content.minY - 0.001)
                XCTAssertLessThanOrEqual(placedGlyphBounds.maxY, content.maxY + 0.001)
                XCTAssertGreaterThanOrEqual(
                    baseline + line.baselineOffset - line.metrics.descent,
                    content.minY - 0.001
                )
                XCTAssertLessThanOrEqual(
                    baseline + line.baselineOffset + line.metrics.ascent,
                    content.maxY + 0.001
                )
            }
        }
    }

    func testExplicitLayoutValidationOwnsHeightAndPlacedLineOrigins() throws {
        let text = "First wrapped line with enough text\nSecond line\nThird line"
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica",
            textAlignment: .center
        )
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 180, y: 140),
            text: text,
            style: style,
            maximumWrapWidth: 132
        )
        let plan = try AnnotationTextLayout.validateExplicitLayout(
            text: text,
            style: style,
            rect: layout.rect,
            payload: layout.payload
        )
        let placedLines = AnnotationTextLayout.placedLines(
            in: layout.rect,
            text: text,
            style: style,
            layout: layout.payload
        )
        let container = AnnotationTextLayout.textContainerRect(
            from: layout.rect,
            layout: layout.payload
        )

        XCTAssertEqual(placedLines.map(\.line), plan.lines)
        XCTAssertEqual(
            placedLines.map(\.origin),
            plan.lines.map {
                CGPoint(
                    x: container.minX + $0.originX,
                    y: 140 + $0.baselineOffset
                )
            }
        )
        XCTAssertGreaterThanOrEqual(plan.lineCount, 3)

        for heightDelta in [CGFloat(-1), 1] {
            let invalidRect = CGRect(
                x: layout.rect.minX,
                y: layout.rect.minY,
                width: layout.rect.width,
                height: layout.rect.height + heightDelta
            )
            XCTAssertThrowsError(try AnnotationTextLayout.validateExplicitLayout(
                text: text,
                style: style,
                rect: invalidRect,
                payload: layout.payload
            )) { error in
                guard case AnnotationTextLayoutValidationError.heightMismatch = error else {
                    return XCTFail("Expected a height mismatch, received \(error).")
                }
            }
        }

        XCTAssertThrowsError(try AnnotationTextLayout.validateExplicitLayout(
            text: text,
            style: style,
            rect: CGRect(
                x: .nan,
                y: layout.rect.minY,
                width: layout.rect.width,
                height: layout.rect.height
            ),
            payload: layout.payload
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextLayoutValidationError,
                .nonFiniteRectangle
            )
        }

        XCTAssertThrowsError(try AnnotationTextLayout.validateExplicitLayout(
            text: text,
            style: style,
            rect: CGRect(
                x: layout.rect.maxX,
                y: layout.rect.minY,
                width: -layout.rect.width,
                height: layout.rect.height
            ),
            payload: layout.payload
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextLayoutValidationError,
                .nonPositiveRectangle
            )
        }
    }

    func testFallbackEmojiMetricsExpandCanonicalVerticalExtents() throws {
        let text = "😀\n😀\nArial text"
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "ArialMT",
            textAlignment: .leading
        )
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 80, y: 120),
            text: text,
            style: style,
            maximumWrapWidth: 120
        )
        let plan = try AnnotationTextLayout.validateExplicitLayout(
            text: text,
            style: style,
            rect: layout.rect,
            payload: layout.payload
        )
        let fallbackLine = try XCTUnwrap(plan.lines.first)
        let secondLine = try XCTUnwrap(plan.lines.dropFirst().first)
        XCTAssertGreaterThanOrEqual(plan.topExtent, fallbackLine.metrics.ascent)
        XCTAssertGreaterThanOrEqual(plan.topExtent, fallbackLine.glyphBounds.maxY)
        let lastLine = try XCTUnwrap(plan.lines.last)
        XCTAssertGreaterThanOrEqual(plan.bottomExtent, lastLine.metrics.descent)
        XCTAssertGreaterThanOrEqual(
            plan.bottomExtent,
            max(0, -lastLine.glyphBounds.minY)
        )
        XCTAssertGreaterThanOrEqual(
            plan.lineAdvance,
            fallbackLine.metrics.descent
                + secondLine.metrics.ascent
                + max(fallbackLine.metrics.leading, secondLine.metrics.leading)
        )
        let placedLines = AnnotationTextLayout.placedLines(
            in: layout.rect,
            text: text,
            style: style,
            layout: layout.payload
        )
        XCTAssertEqual(try XCTUnwrap(placedLines.first).origin.y, 120, accuracy: 0.001)
        let content = AnnotationTextLayout.contentRect(
            from: layout.rect,
            layout: layout.payload
        ).insetBy(dx: -0.001, dy: -0.001)
        for placedLine in placedLines where !placedLine.line.glyphBounds.isEmpty {
            XCTAssertTrue(content.contains(placedLine.line.glyphBounds.offsetBy(
                dx: placedLine.origin.x,
                dy: placedLine.origin.y
            )))
        }

        XCTAssertNoThrow(AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(layout.rect),
            style: style,
            text: text,
            textLayout: layout.payload
        ))
    }

    func testUnbreakableComposedClusterGrowsGeometryWithoutChangingTextKitOwnership() throws {
        let text = "👩‍👩‍👧‍👦"
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica",
            textAlignment: .leading
        )
        let requestedWidth: CGFloat = 5
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 80, y: 120),
            text: text,
            style: style,
            maximumWrapWidth: requestedWidth
        )
        XCTAssertEqual(layout.payload.wrapWidth, requestedWidth)
        XCTAssertGreaterThan(
            layout.payload.leadingOverhang + layout.payload.trailingOverhang,
            0
        )
        let plan = AnnotationTextLayout.layoutPlan(
            in: text,
            style: style,
            wrapWidth: layout.payload.wrapWidth
        )
        XCTAssertEqual(plan.lines.map(\.text), [text])
        let content = AnnotationTextLayout.contentRect(
            from: layout.rect,
            layout: layout.payload
        )
        let textContainer = AnnotationTextLayout.textContainerRect(
            from: layout.rect,
            layout: layout.payload
        )
        let glyphBounds = plan.lines[0].glyphBounds.offsetBy(
            dx: textContainer.minX + plan.lines[0].originX,
            dy: AnnotationTextLayout.baselineY(
                in: layout.rect,
                text: text,
                style: style,
                layout: layout.payload
            )
        )
        XCTAssertTrue(content.insetBy(dx: -0.001, dy: -0.001).contains(glyphBounds))
    }

    func testStandaloneVersionOnePayloadCannotMasqueradeAsCurrent() throws {
        let legacyJSON = """
        {
          "version": 1,
          "chromeMode": "legacyTight",
          "wrapWidth": 88
        }
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(
            AnnotationTextLayoutPayload.self,
            from: legacyJSON
        )
        XCTAssertEqual(legacy.version, 1)
        XCTAssertEqual(legacy.wrapWidth, 88)
        XCTAssertEqual(legacy.leadingOverhang, 0)
        XCTAssertEqual(legacy.trailingOverhang, 0)
        XCTAssertThrowsError(try JSONEncoder().encode(legacy))
    }

    func testInvalidOrNoncanonicalOverhangPayloadFailsClosed() throws {
        let invalidObjects: [[String: Any]] = [
            [
                "version": 2,
                "chromeMode": "uniformPadded",
                "wrapWidth": 88,
                "leadingOverhang": -1,
                "trailingOverhang": 0
            ],
            [
                "version": 2,
                "chromeMode": "uniformPadded",
                "wrapWidth": 88,
                "leadingOverhang": 0
            ],
            [
                "version": 1,
                "chromeMode": "legacyTight",
                "wrapWidth": 88,
                "leadingOverhang": 1,
                "trailingOverhang": 0
            ]
        ]
        for object in invalidObjects {
            XCTAssertThrowsError(try JSONDecoder().decode(
                AnnotationTextLayoutPayload.self,
                from: JSONSerialization.data(withJSONObject: object)
            ))
        }
    }

    func testVersionOneItemMigratesOverhangAndExpandsAroundSameBaseline() throws {
        let text = "Zapfino fj Ág"
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Zapfino",
            textAlignment: .leading
        )
        let currentLayout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 80, y: 120),
            text: text,
            style: style
        )
        let currentItem = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(currentLayout.rect),
            style: style,
            text: text,
            textLayout: currentLayout.payload
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(currentItem)
            ) as? [String: Any]
        )
        var payloadObject = try XCTUnwrap(object["textLayout"] as? [String: Any])
        payloadObject["version"] = 1
        payloadObject.removeValue(forKey: "leadingOverhang")
        payloadObject.removeValue(forKey: "trailingOverhang")
        payloadObject.removeValue(forKey: "layoutEngineRevision")
        payloadObject.removeValue(forKey: "input")
        payloadObject.removeValue(forKey: "plan")
        object["textLayout"] = payloadObject

        let legacyContent = AnnotationTextLayout.textContainerRect(
            from: currentLayout.rect,
            layout: currentLayout.payload
        )
        let legacyRect = CGRect(
            x: legacyContent.minX - AnnotationTextLayout.horizontalChromePadding,
            y: 120
                - style.fontSize * 1.5 / 2
                + style.fontSize * 0.36
                - AnnotationTextLayout.verticalChromePadding,
            width: currentLayout.payload.wrapWidth
                + AnnotationTextLayout.horizontalChromePadding * 2,
            height: style.fontSize * 1.5
                + AnnotationTextLayout.verticalChromePadding * 2
        )
        let geometryCarrier = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(legacyRect),
            style: style,
            text: text
        )
        let geometryCarrierObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(geometryCarrier)
            ) as? [String: Any]
        )
        object["geometry"] = try XCTUnwrap(geometryCarrierObject["geometry"])

        var unavailableFontObject = object
        var unavailableStyle = try XCTUnwrap(
            unavailableFontObject["style"] as? [String: Any]
        )
        let unavailableFontName = "Ushot-Intentionally-Unavailable-Migration-Font"
        unavailableStyle["fontName"] = unavailableFontName
        unavailableFontObject["style"] = unavailableStyle
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: unavailableFontObject)
        )) { error in
            XCTAssertEqual(
                error as? AnnotationTextRenderingError,
                .fontUnavailable(unavailableFontName)
            )
        }

        for invalidHeight in [CGFloat(0.001), 10_000] {
            let invalidGeometryCarrier = AnnotationItem(
                kind: .text,
                zIndex: 0,
                geometry: .rect(CGRect(
                    x: legacyRect.minX,
                    y: legacyRect.minY,
                    width: legacyRect.width,
                    height: invalidHeight
                )),
                style: style,
                text: text
            )
            let carrierObject = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(invalidGeometryCarrier)
                ) as? [String: Any]
            )
            var invalidObject = object
            invalidObject["geometry"] = try XCTUnwrap(carrierObject["geometry"])
            XCTAssertThrowsError(try JSONDecoder().decode(
                AnnotationItem.self,
                from: JSONSerialization.data(withJSONObject: invalidObject)
            ))
        }
        var multilineLegacyObject = object
        multilineLegacyObject["text"] = "Legacy first\nLegacy second"
        XCTAssertThrowsError(try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: multilineLegacyObject)
        ))

        let migrated = try JSONDecoder().decode(
            AnnotationItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let migratedPayload = try XCTUnwrap(migrated.textLayout)
        XCTAssertEqual(
            migratedPayload.version,
            AnnotationTextLayoutPayload.currentVersion
        )
        XCTAssertGreaterThan(migratedPayload.leadingOverhang, 0)
        guard case .rect(let migratedRect) = migrated.geometry else {
            return XCTFail("Migrated text must retain rectangle geometry.")
        }
        let migratedAnchor = AnnotationTextLayout.alignmentAnchor(
            in: migratedRect,
            text: text,
            style: style,
            layout: migratedPayload
        )
        XCTAssertEqual(migratedAnchor.x, 80, accuracy: 0.001)
        XCTAssertEqual(migratedAnchor.y, 120, accuracy: 0.001)
    }

    func testLegacyTightZapfinoSemanticEditPersistsOverhangWithoutMovingBaseline() throws {
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Zapfino",
            textAlignment: .leading
        )
        let legacyRect = CGRect(x: 40, y: 60, width: 120, height: 27)
        let legacy = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(legacyRect),
            style: style,
            text: "Legacy Zapfino"
        )
        let originalBaseline = AnnotationTextLayout.baselineY(
            in: legacyRect,
            text: legacy.text ?? "",
            style: style,
            layout: nil
        )

        let edited = try AnnotationTextLayout.reflowedTextItem(
            legacy,
            text: "Zapfino fj Ág",
            fontSize: style.fontSize
        )
        let payload = try XCTUnwrap(edited.textLayout)
        XCTAssertEqual(payload.chromeMode, .legacyTight)
        XCTAssertGreaterThan(payload.leadingOverhang, 0)
        guard case .rect(let rect) = edited.geometry else {
            return XCTFail("Semantic edit must keep text rectangle geometry.")
        }
        XCTAssertEqual(
            AnnotationTextLayout.baselineY(
                in: rect,
                text: edited.text ?? "",
                style: edited.style,
                layout: payload
            ),
            originalBaseline,
            accuracy: 0.001
        )
        let content = AnnotationTextLayout.contentRect(from: rect, layout: payload)
        let container = AnnotationTextLayout.textContainerRect(from: rect, layout: payload)
        let plan = AnnotationTextLayout.layoutPlan(
            in: edited.text ?? "",
            style: edited.style,
            wrapWidth: payload.wrapWidth
        )
        for line in plan.lines where !line.glyphBounds.isEmpty {
            let glyphBounds = line.glyphBounds.offsetBy(
                dx: container.minX + line.originX,
                dy: originalBaseline + line.baselineOffset
            )
            XCTAssertTrue(content.insetBy(dx: -0.001, dy: -0.001).contains(glyphBounds))
        }
    }

    func testImplicitLegacyBaselineAndNoOpGeometryRemainByteStable() throws {
        let style = AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica",
            textAlignment: .trailing
        )
        let legacyRect = CGRect(x: 22.5, y: 31.25, width: 137.75, height: 27)
        let legacy = AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(legacyRect),
            style: style,
            text: "Legacy exact geometry"
        )
        let expectedBaseline = legacyRect.midY - style.fontSize * 0.36
        XCTAssertEqual(
            AnnotationTextLayout.baselineY(
                in: legacyRect,
                text: legacy.text ?? "",
                style: style,
                layout: nil
            ),
            expectedBaseline,
            accuracy: 0.000_001
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let unchanged = try AnnotationTextLayout.reflowedTextItem(
            legacy,
            text: legacy.text ?? "",
            fontSize: style.fontSize
        )
        XCTAssertEqual(unchanged, legacy)
        XCTAssertEqual(try encoder.encode(unchanged), try encoder.encode(legacy))

        let edited = try AnnotationTextLayout.reflowedTextItem(
            legacy,
            text: "Legacy exact geometry changed",
            fontSize: style.fontSize
        )
        let payload = try XCTUnwrap(edited.textLayout)
        guard case .rect(let editedRect) = edited.geometry else {
            return XCTFail("A semantic text edit must keep rectangle geometry.")
        }
        XCTAssertEqual(payload.chromeMode, .legacyTight)
        XCTAssertEqual(
            AnnotationTextLayout.baselineY(
                in: editedRect,
                text: edited.text ?? "",
                style: edited.style,
                layout: payload
            ),
            expectedBaseline,
            accuracy: 0.001
        )
        let editedPlan = AnnotationTextLayout.layoutPlan(
            in: edited.text ?? "",
            style: edited.style,
            wrapWidth: payload.wrapWidth
        )
        XCTAssertEqual(editedRect.height, editedPlan.contentHeight, accuracy: 0.001)
    }

    func testRendererReproducesPersistedShapeMatrix() throws {
        let fixtures: [(fontName: String?, text: String, width: CGFloat)] = [
            (nil, "System 😀 fallback\n\nSecond 🧑🏽‍💻 line", 140),
            ("Arial", "Arial emoji 😀 fallback", 110),
            ("Zapfino", "Zapfino fj Ág", 140),
            ("Helvetica", "שלום שלום שלום 123 !!! abc", 90),
            ("Helvetica", "first\u{000C}second\n\nthird", 120)
        ]
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))

        for fixture in fixtures {
            for alignment in AnnotationTextAlignment.allCases {
                let style = AnnotationStyle(
                    fontSize: 18,
                    fontName: fixture.fontName,
                    textAlignment: alignment
                )
                let anchorX: CGFloat
                switch alignment {
                case .leading: anchorX = 40
                case .center: anchorX = 320
                case .trailing: anchorX = 600
                }
                let layout = try AnnotationTextLayout.newTextLayout(
                    baselineAnchor: CGPoint(x: anchorX, y: 420),
                    text: fixture.text,
                    style: style,
                    maximumWrapWidth: fixture.width
                )
                let item = AnnotationItem(
                    kind: .text,
                    zIndex: 0,
                    geometry: .rect(layout.rect),
                    style: style,
                    text: fixture.text,
                    textLayout: layout.payload
                )
                XCTAssertTrue(try AnnotationVectorRenderer().draw(
                    item: item,
                    in: try makeBitmapContext(),
                    colorSpace: colorSpace
                ), "Failed fixture \(fixture.text), alignment \(alignment)")
            }
        }
    }

    private func makeBitmapContext() throws -> CGContext {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGContext(
            data: nil,
            width: 640,
            height: 480,
            bitsPerComponent: 8,
            bytesPerRow: 640 * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    private func independentTextKitOrigins(
        text: String,
        style: AnnotationStyle,
        wrapWidth: CGFloat
    ) -> [CGFloat] {
        let font = AnnotationTextLayout.font(style: style)
        let paragraph = NSMutableParagraphStyle()
        let lineAdvance = AnnotationTextLayout.lineAdvance(for: font)
        paragraph.minimumLineHeight = lineAdvance
        paragraph.maximumLineHeight = lineAdvance
        paragraph.lineBreakMode = .byWordWrapping
        switch style.textAlignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        let storage = NSTextStorage(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(
            width: wrapWidth,
            height: .greatestFiniteMagnitude
        ))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        var origins: [CGFloat] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: layoutManager.glyphRange(for: textContainer)
        ) { _, usedRect, _, _, _ in
            origins.append(usedRect.minX)
        }
        if text.isEmpty || text.last?.isNewline == true {
            origins.append(layoutManager.extraLineFragmentUsedRect.minX)
        }
        return origins
    }
}
