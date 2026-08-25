import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation

public struct AnnotationTextLineMetrics: Codable, Equatable, Sendable {
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    public init(
        width: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat
    ) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
    }

    public var typographicHeight: CGFloat {
        ascent + descent + leading
    }
}

/// One TextKit-resolved visual line. Persisted ownership is expressed only in
/// UTF-16, the native TextKit coordinate space; Swift grapheme segmentation can
/// evolve between OS releases and therefore is not durable document state.
/// `consumedUTF16Range` includes a terminating hard line break;
/// `utf16Range` contains only drawable text.
public struct AnnotationTextLayoutLine: Codable, Equatable, Sendable {
    public let text: String
    public let utf16Range: NSRange
    public let consumedUTF16Range: NSRange
    public let metrics: AnnotationTextLineMetrics
    public let glyphBounds: CGRect
    /// Renderer-ready plans store SHA-256 over the resolved Core Text runs,
    /// font identities/variations, glyph IDs, positions, advances and actual
    /// outline or source-backed bitmap appearance. Geometry-only transient plans
    /// carry an explicit non-SHA marker and are rejected by every payload and
    /// encoding boundary.
    public let shapeFingerprint: String
    /// Core Text line origin relative to the content rectangle's minimum X.
    public let originX: CGFloat
    public let baselineOffset: CGFloat

    public var width: CGFloat { metrics.width }

    public init(
        text: String,
        utf16Range: NSRange,
        consumedUTF16Range: NSRange,
        metrics: AnnotationTextLineMetrics,
        glyphBounds: CGRect,
        shapeFingerprint: String,
        originX: CGFloat,
        baselineOffset: CGFloat
    ) {
        self.text = text
        self.utf16Range = utf16Range
        self.consumedUTF16Range = consumedUTF16Range
        self.metrics = metrics
        self.glyphBounds = glyphBounds
        self.shapeFingerprint = shapeFingerprint
        self.originX = originX
        self.baselineOffset = baselineOffset
    }
}

/// Immutable output of the same TextKit 1 layout stack used by the inline
/// editor. Geometry and bitmap rendering consume this plan instead of each
/// independently guessing where word wrapping occurred.
public struct AnnotationTextLayoutPlan: Codable, Equatable, Sendable {
    public let lines: [AnnotationTextLayoutLine]
    public let wrapWidth: CGFloat
    public let lineAdvance: CGFloat
    public let topExtent: CGFloat
    public let bottomExtent: CGFloat
    /// Persisted total content height. Keeping this authored value on the wire
    /// lets a decoder validate geometry without asking a later TextKit runtime
    /// to reproduce the original font/fallback metrics.
    public let contentHeight: CGFloat

    public var lineCount: Int { lines.count }
    public var requiredLeadingOverhang: CGFloat {
        max(0, -(lines.map { $0.originX + $0.glyphBounds.minX }.min() ?? 0))
    }
    public var requiredTrailingOverhang: CGFloat {
        max(0, (lines.map { $0.originX + $0.glyphBounds.maxX }.max() ?? 0) - wrapWidth)
    }

    public init(
        lines: [AnnotationTextLayoutLine],
        wrapWidth: CGFloat,
        lineAdvance: CGFloat,
        topExtent: CGFloat,
        bottomExtent: CGFloat
    ) {
        precondition(!lines.isEmpty, "A text layout plan must contain at least one visual line.")
        self.lines = lines
        self.wrapWidth = wrapWidth
        self.lineAdvance = lineAdvance
        self.topExtent = topExtent
        self.bottomExtent = bottomExtent
        contentHeight = topExtent + bottomExtent
            + max(0, -(lines.last?.baselineOffset ?? 0))
    }

    private enum CodingKeys: String, CodingKey {
        case lines
        case wrapWidth
        case lineAdvance
        case topExtent
        case bottomExtent
        case contentHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decode(
            [AnnotationTextLayoutLine].self,
            forKey: .lines
        )
        wrapWidth = try container.decode(CGFloat.self, forKey: .wrapWidth)
        lineAdvance = try container.decode(CGFloat.self, forKey: .lineAdvance)
        topExtent = try container.decode(CGFloat.self, forKey: .topExtent)
        bottomExtent = try container.decode(CGFloat.self, forKey: .bottomExtent)
        contentHeight = try container.decode(CGFloat.self, forKey: .contentHeight)
    }

    public func encode(to encoder: Encoder) throws {
        guard AnnotationTextLayout.isRendererReadyPlan(self) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "A transient annotation text plan cannot be encoded."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lines, forKey: .lines)
        try container.encode(wrapWidth, forKey: .wrapWidth)
        try container.encode(lineAdvance, forKey: .lineAdvance)
        try container.encode(topExtent, forKey: .topExtent)
        try container.encode(bottomExtent, forKey: .bottomExtent)
        try container.encode(contentHeight, forKey: .contentHeight)
    }
}

/// Exact layout-affecting inputs that authored a persisted TextKit plan.
/// This binding makes same-length text and typography mutations observable at
/// encode/decode time without depending on the current machine's font engine.
public struct AnnotationTextLayoutInput: Codable, Equatable, Sendable {
    public let text: String
    public let fontSize: CGFloat
    public let fontName: String?
    public let fontWeight: AnnotationFontWeight
    public let textAlignment: AnnotationTextAlignment

    public init(text: String, style: AnnotationStyle) {
        self.text = text
        fontSize = style.fontSize
        fontName = style.fontName
        fontWeight = style.fontWeight
        textAlignment = style.textAlignment
    }

    public func matches(text: String, style: AnnotationStyle) -> Bool {
        self.text == text
            && fontSize == style.fontSize
            && fontName == style.fontName
            && fontWeight == style.fontWeight
            && textAlignment == style.textAlignment
    }

    var style: AnnotationStyle {
        AnnotationStyle(
            fontSize: fontSize,
            fontName: fontName,
            fontWeight: fontWeight,
            textAlignment: textAlignment
        )
    }
}

/// A canonical TextKit line positioned in untransformed document coordinates.
/// Consumers apply the annotation transform and canvas projection only after
/// this placement has been resolved, so editing and bitmap rendering cannot
/// independently round line origins at presentation scale.
public struct AnnotationTextPlacedLine: Equatable, Sendable {
    public let line: AnnotationTextLayoutLine
    public let origin: CGPoint

    public init(line: AnnotationTextLayoutLine, origin: CGPoint) {
        self.line = line
        self.origin = origin
    }
}

public enum AnnotationTextLayoutValidationError: Error, Equatable, Sendable {
    case nonFiniteRectangle
    case nonPositiveRectangle
    case widthMismatch(expected: CGFloat, actual: CGFloat)
    case heightMismatch(expected: CGFloat, actual: CGFloat)
    case overhangMismatch(
        expectedLeading: CGFloat,
        actualLeading: CGFloat,
        expectedTrailing: CGFloat,
        actualTrailing: CGFloat
    )
    case typographicBoundsOutsideContent(lineIndex: Int)
    case glyphBoundsOutsideContent(lineIndex: Int)
    case unsupportedLegacyMultilineText
    case invalidFontSize(CGFloat)
    case invalidFontName
    case unavailableFont(String)
    case missingPersistedPlan
    case layoutInputMismatch
    case malformedPersistedPlan(String)
}

public enum AnnotationTextRenderingError: LocalizedError, Equatable, Sendable {
    case fontUnavailable(String)
    case fontSourceUnavailable(String)
    case unsupportedLayoutEngineRevision(Int)
    case shapeChanged(lineIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .fontUnavailable(let name):
            return "The annotation font '\(name)' is not available on this Mac."
        case .fontSourceUnavailable(let name):
            return "The installed annotation font '\(name)' has no verifiable source content."
        case .unsupportedLayoutEngineRevision(let revision):
            return "The saved annotation text layout revision \(revision) is not supported by this version of Ushot."
        case .shapeChanged(let lineIndex):
            return "The saved annotation text appearance cannot be reproduced for line \(lineIndex + 1) on this Mac."
        }
    }
}

extension AnnotationTextLayoutValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nonFiniteRectangle:
            return "The annotation text rectangle must be finite."
        case .nonPositiveRectangle:
            return "The annotation text rectangle must have positive width and height."
        case .widthMismatch(let expected, let actual):
            return "The annotation text rectangle width is \(actual); expected \(expected)."
        case .heightMismatch(let expected, let actual):
            return "The annotation text rectangle height is \(actual); expected \(expected)."
        case .overhangMismatch(
            let expectedLeading,
            let actualLeading,
            let expectedTrailing,
            let actualTrailing
        ):
            return "The annotation text overhangs are \(actualLeading)/\(actualTrailing); expected \(expectedLeading)/\(expectedTrailing)."
        case .typographicBoundsOutsideContent(let lineIndex):
            return "Annotation text line \(lineIndex) has typographic bounds outside its content rectangle."
        case .glyphBoundsOutsideContent(let lineIndex):
            return "Annotation text line \(lineIndex) has glyph bounds outside its content rectangle."
        case .unsupportedLegacyMultilineText:
            return "A legacy zero-overhang text layout cannot contain multiple lines."
        case .invalidFontSize(let size):
            return "The annotation text font size \(size) must be positive and finite."
        case .invalidFontName:
            return "The annotation text font name cannot be empty."
        case .unavailableFont(let name):
            return "The saved annotation font '\(name)' is not installed on this Mac."
        case .missingPersistedPlan:
            return "The annotation text layout payload has no renderer-ready plan."
        case .layoutInputMismatch:
            return "The annotation text layout plan does not belong to the current text and typography."
        case .malformedPersistedPlan(let reason):
            return "The annotation text layout plan is malformed: \(reason)."
        }
    }
}

public enum AnnotationTextWrapWidthStrategy: Equatable, Sendable {
    /// Keep the canonical untransformed content width unchanged.
    case preserve
    /// Scale content width by the same ratio as the font size. Active and
    /// selected text resizing both use this strategy.
    case scaleWithFont
}

public struct AnnotationTextLayoutResolution: Equatable, Sendable {
    public let rect: CGRect
    public let payload: AnnotationTextLayoutPayload

    public init(rect: CGRect, payload: AnnotationTextLayoutPayload) {
        self.rect = rect
        self.payload = payload
    }
}

/// The single source of truth for annotation typography.
///
/// Annotation rectangles store an alignment anchor on the first line's Core
/// Text baseline. Additional hard line breaks grow the rectangle downward in
/// Y-up canvas space without moving that first baseline. Both the bitmap
/// renderer and the native inline editor resolve their font, width and
/// baseline from this type so entering and committing text cannot silently
/// switch fonts or coordinate conventions.
public enum AnnotationTextLayout {
    /// Logical-point range supported by interactive text editing controls.
    /// Rendering remains capable of opening documents outside this range;
    /// the range only constrains new direct manipulation.
    public static let editableFontSizeRange: ClosedRange<CGFloat> = 4...96
    /// Empty space between the accent chrome and the first/last glyphs.
    /// Editor, selected chrome, commit geometry and hit testing share this.
    public static let horizontalChromePadding: CGFloat = 8
    public static let verticalChromePadding: CGFloat = 4

    /// Persisted layout geometry is authored from one TextKit plan. A hundredth
    /// of a point is already below the renderer's meaningful document-space
    /// precision while still rejecting a distinct stored layout generation.
    public static let persistedGeometryTolerance: CGFloat = 0.01

    static let transientShapeFingerprint = "ushot-transient-text-shape"

    private static let rectangleHeightFactor: CGFloat = 1.5
    private static let baselineOffsetFromCenterFactor: CGFloat = -0.36

    public static func font(
        style: AnnotationStyle,
        size: CGFloat? = nil
    ) -> NSFont {
        do {
            return try resolvedFont(style: style, size: size)
        } catch {
            preconditionFailure("Cannot resolve annotation font: \(error)")
        }
    }

    /// Resolves the requested primary font without converting a missing local
    /// capability into a process-terminating invariant failure. Authoring and
    /// editing boundaries must use this API instead of `font(style:size:)`.
    public static func resolvedFont(
        style: AnnotationStyle,
        size: CGFloat? = nil
    ) throws -> NSFont {
        let pointSize = size ?? style.fontSize
        guard pointSize.isFinite, pointSize > 0 else {
            throw AnnotationTextLayoutValidationError.invalidFontSize(pointSize)
        }
        if let fontName = style.fontName {
            guard let font = NSFont(name: fontName, size: pointSize) else {
                throw AnnotationTextRenderingError.fontUnavailable(fontName)
            }
            return font
        }

        let weight: NSFont.Weight
        switch style.fontWeight {
        case .regular: weight = .regular
        case .medium: weight = .medium
        case .semibold: weight = .semibold
        case .bold: weight = .bold
        }
        return NSFont.systemFont(ofSize: pointSize, weight: weight)
    }

    public static func lineMetrics(
        for text: String,
        style: AnnotationStyle,
        size: CGFloat? = nil
    ) -> AnnotationTextLineMetrics {
        let font = font(style: style, size: size)
        return lineMetrics(for: text, font: font)
    }

    static func lineMetrics(
        for text: String,
        font: NSFont
    ) -> AnnotationTextLineMetrics {
        guard !text.isEmpty else {
            return AnnotationTextLineMetrics(
                width: 0,
                ascent: font.ascender,
                descent: max(0, -font.descender),
                leading: max(0, font.leading)
            )
        }

        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font as CTFont
            ]
        ))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            &leading
        ))
        return AnnotationTextLineMetrics(
            width: max(0, width),
            ascent: max(0, ascent),
            descent: max(0, descent),
            leading: max(0, leading)
        )
    }

    /// Hard-broken visual lines. An empty string is one empty line so a caret
    /// still occupies a field; a trailing newline is a real extra line.
    public static func lines(in text: String) -> [String] {
        let segments = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).map(String.init)
        return segments.isEmpty ? [""] : segments
    }

    public static func lineCount(in text: String) -> Int {
        lines(in: text).count
    }

    public static func firstLine(of text: String) -> String {
        String(text.prefix { !$0.isNewline })
    }

    public static func lineAdvance(for font: NSFont) -> CGFloat {
        max(1, ceil(font.ascender - font.descender + font.leading))
    }

    public static func lineAdvance(
        style: AnnotationStyle,
        size: CGFloat? = nil
    ) -> CGFloat {
        lineAdvance(for: font(style: style, size: size))
    }

    public static func maximumLineWidth(
        for text: String,
        style: AnnotationStyle,
        size: CGFloat? = nil
    ) -> CGFloat {
        lines(in: text).map { lineMetrics(for: $0, style: style, size: size).width }.max() ?? 0
    }

    /// Geometry-only measurement for a font already admitted by a throwing
    /// authoring/editing boundary. This overload never performs a second font
    /// lookup, so a font registration change cannot turn measurement into a
    /// hidden precondition failure.
    public static func maximumLineWidth(
        for text: String,
        resolvedFont: NSFont
    ) -> CGFloat {
        lines(in: text).map { lineMetrics(for: $0, font: resolvedFont).width }.max() ?? 0
    }

    /// Produces the canonical word-wrapped layout used by selection geometry,
    /// rendering and inline-editor measurements. This intentionally uses the
    /// TextKit 1 objects that back `NSTextView`; Core Text's independent
    /// typesetter does not make identical ownership decisions around spaces,
    /// composed characters and paragraph terminators.
    public static func layoutPlan(
        in text: String,
        style: AnnotationStyle,
        wrapWidth: CGFloat,
        size: CGFloat? = nil
    ) -> AnnotationTextLayoutPlan {
        layoutPlan(
            in: text,
            style: style,
            wrapWidth: wrapWidth,
            resolvedFont: font(style: style, size: size)
        )
    }

    static func layoutPlan(
        in text: String,
        style: AnnotationStyle,
        wrapWidth: CGFloat,
        resolvedFont font: NSFont
    ) -> AnnotationTextLayoutPlan {
        precondition(
            wrapWidth.isFinite && wrapWidth > 0,
            "Annotation text wrap width must be positive and finite."
        )
        let advance = lineAdvance(for: font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = advance
        paragraphStyle.maximumLineHeight = advance
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = nsTextAlignment(style.textAlignment)

        // AppKit's single-container TextKit 1 stack stops layout at U+000C on
        // current macOS releases. Treat form-feed as the hard break it already
        // is semantically, while preserving the document string and every
        // UTF-16 offset (U+000C and U+000A are both one code unit).
        let layoutText = normalizedTextForLayout(
            text,
            revision: AnnotationTextLayoutPayload.currentAuthoringLayoutEngineRevision
        )
        let attributed = NSAttributedString(
            string: layoutText,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
        )
        // Keep one full-document Core Text typesetter beside TextKit. TextKit
        // owns the visual ranges and fragment origins; the full typesetter
        // supplies metrics and ink for those exact ranges without losing the
        // enclosing paragraph's bidi context at a soft-wrap boundary.
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(
            width: wrapWidth,
            height: .greatestFiniteMagnitude
        ))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let nsText = text as NSString
        var result: [AnnotationTextLayoutLine] = []
        let laidOutGlyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.enumerateLineFragments(
            forGlyphRange: laidOutGlyphRange
        ) { _, usedRect, _, glyphRange, _ in
            let consumedRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            let drawableRange = drawableUTF16Range(
                from: consumedRange,
                in: text
            )
            result.append(makePlanLine(
                text: text,
                nsText: nsText,
                drawableRange: drawableRange,
                consumedRange: consumedRange,
                primaryFont: font,
                typesetter: typesetter,
                // A glyph range is logical-order data. Its first glyph can sit
                // at the visual trailing edge of a right-to-left line, so its
                // location is not the line fragment's drawing origin. TextKit's
                // used rect is the canonical visual origin for LTR, RTL and
                // mixed-direction lines alike.
                originX: usedRect.minX,
                baselineOffset: -CGFloat(result.count) * advance
            ))
        }

        // TextKit represents the caret line after a terminal paragraph break
        // as an extra line fragment instead of a glyph line. Preserve that
        // real empty visual line, as well as the sole line of an empty string.
        if text.isEmpty || hasTrailingHardLineBreak(text) {
            let emptyRange = NSRange(location: attributed.length, length: 0)
            let emptyOriginX: CGFloat
            if text.isEmpty {
                switch style.textAlignment {
                case .leading: emptyOriginX = 0
                case .center: emptyOriginX = wrapWidth / 2
                case .trailing: emptyOriginX = wrapWidth
                }
            } else {
                emptyOriginX = layoutManager.extraLineFragmentUsedRect.minX
            }
            result.append(makePlanLine(
                text: text,
                nsText: nsText,
                drawableRange: emptyRange,
                consumedRange: emptyRange,
                primaryFont: font,
                typesetter: typesetter,
                originX: emptyOriginX,
                baselineOffset: -CGFloat(result.count) * advance
            ))
        }
        precondition(
            !result.isEmpty,
            "TextKit did not produce a visual line for non-empty annotation text."
        )
        var nextConsumedLocation = 0
        for (lineIndex, line) in result.enumerated() {
            precondition(
                line.consumedUTF16Range.location == nextConsumedLocation
                    && isUTF16ScalarBoundary(
                        line.consumedUTF16Range.location,
                        in: nsText
                    )
                    && isUTF16ScalarBoundary(
                        NSMaxRange(line.consumedUTF16Range),
                        in: nsText
                    )
                    && isValidZeroLengthConsumedLine(
                        lineIndex: lineIndex,
                        lineCount: result.count,
                        range: line.consumedUTF16Range,
                        text: text
                    ),
                "TextKit produced incomplete or unstable UTF-16 line ownership."
            )
            nextConsumedLocation = NSMaxRange(line.consumedUTF16Range)
        }
        precondition(
            nextConsumedLocation == nsText.length,
            "TextKit did not cover the complete annotation string."
        )

        // Core Text may select taller fallback runs for characters that the
        // requested font does not cover (emoji is the common case). Resolve a
        // canonical advance that keeps both typographic boxes and actual ink
        // from overlapping across each adjacent line. Line height does not
        // participate in horizontal TextKit ownership, so ranges/originX remain
        // those of the single canonical stack above.
        let requiredAdvance = zip(result, result.dropFirst()).reduce(advance) {
            current, pair in
            let (upper, lower) = pair
            let typographicSeparation = upper.metrics.descent
                + lower.metrics.ascent
                + max(upper.metrics.leading, lower.metrics.leading)
            let glyphSeparation: CGFloat
            if upper.glyphBounds.isEmpty || lower.glyphBounds.isEmpty {
                glyphSeparation = 0
            } else {
                glyphSeparation = lower.glyphBounds.maxY - upper.glyphBounds.minY
            }
            return max(current, typographicSeparation, glyphSeparation)
        }
        let resolvedAdvance = max(1, ceil(requiredAdvance))
        let resolvedLines = result.enumerated().map { index, line in
            AnnotationTextLayoutLine(
                text: line.text,
                utf16Range: line.utf16Range,
                consumedUTF16Range: line.consumedUTF16Range,
                metrics: line.metrics,
                glyphBounds: line.glyphBounds,
                shapeFingerprint: line.shapeFingerprint,
                originX: line.originX,
                baselineOffset: -CGFloat(index) * resolvedAdvance
            )
        }

        // The outer extents belong to the first and last visual lines. The
        // pairwise advance above guarantees every intermediate line stays
        // between them without overlap.
        let primaryExtents = fontVerticalExtents(font)
        let firstLine = resolvedLines[0]
        let lastLine = resolvedLines[resolvedLines.count - 1]
        let topExtent = max(
            primaryExtents.top,
            firstLine.metrics.ascent,
            firstLine.glyphBounds.isEmpty ? 0 : firstLine.glyphBounds.maxY
        )
        let bottomExtent = max(
            primaryExtents.bottom,
            lastLine.metrics.descent,
            lastLine.glyphBounds.isEmpty ? 0 : max(0, -lastLine.glyphBounds.minY)
        )
        return AnnotationTextLayoutPlan(
            lines: resolvedLines,
            wrapWidth: wrapWidth,
            lineAdvance: resolvedAdvance,
            topExtent: topExtent,
            bottomExtent: bottomExtent
        )
    }

    /// Converts one geometry-only TextKit plan into a renderer-ready persisted
    /// snapshot. Font-source verification is deliberately isolated here: hover,
    /// resize and other transient geometry probes remain synchronous and cannot
    /// accidentally construct durable document state.
    static func rendererReadyLayoutPlan(
        in text: String,
        style: AnnotationStyle,
        wrapWidth: CGFloat,
        resolvedFont font: NSFont
    ) throws -> AnnotationTextLayoutPlan {
        let transientPlan = layoutPlan(
            in: text,
            style: style,
            wrapWidth: wrapWidth,
            resolvedFont: font
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = transientPlan.lineAdvance
        paragraphStyle.maximumLineHeight = transientPlan.lineAdvance
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = nsTextAlignment(style.textAlignment)
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(
            string: normalizedTextForLayout(
                text,
                revision: AnnotationTextLayoutPayload.currentAuthoringLayoutEngineRevision
            ),
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font as CTFont,
                .paragraphStyle: paragraphStyle
            ]
        ))
        let rendererReadyLines = try transientPlan.lines.enumerated().map {
            lineIndex, line in
            let shapedLine: CTLine?
            if line.utf16Range.length == 0 {
                shapedLine = nil
            } else {
                shapedLine = CTTypesetterCreateLine(
                    typesetter,
                    CFRange(
                        location: line.utf16Range.location,
                        length: line.utf16Range.length
                    )
                )
            }
            if let shapedLine {
                guard lineMetricsMatch(lineMetrics(for: shapedLine), line.metrics),
                      rectMatches(
                        CTLineGetBoundsWithOptions(
                            shapedLine,
                            [.useGlyphPathBounds]
                        ),
                        line.glyphBounds
                      )
                else {
                    throw AnnotationTextRenderingError.shapeChanged(
                        lineIndex: lineIndex
                    )
                }
            } else {
                guard line.metrics.width == 0, line.glyphBounds == .zero else {
                    throw AnnotationTextRenderingError.shapeChanged(
                        lineIndex: lineIndex
                    )
                }
            }
            return AnnotationTextLayoutLine(
                text: line.text,
                utf16Range: line.utf16Range,
                consumedUTF16Range: line.consumedUTF16Range,
                metrics: line.metrics,
                glyphBounds: line.glyphBounds,
                shapeFingerprint: try textShapeFingerprint(
                    line: shapedLine,
                    primaryFont: font,
                    revision: AnnotationTextLayoutPayload
                        .currentAuthoringLayoutEngineRevision
                ),
                originX: line.originX,
                baselineOffset: line.baselineOffset
            )
        }
        let result = AnnotationTextLayoutPlan(
            lines: rendererReadyLines,
            wrapWidth: transientPlan.wrapWidth,
            lineAdvance: transientPlan.lineAdvance,
            topExtent: transientPlan.topExtent,
            bottomExtent: transientPlan.bottomExtent
        )
        guard isRendererReadyPlan(result) else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "renderer-ready authoring produced a non-SHA shape fingerprint"
            )
        }
        return result
    }

    /// Reconstructs and structurally validates the immutable renderer-ready
    /// plan owned by a current payload. This path deliberately does not create
    /// NSTextStorage, NSLayoutManager or a current-runtime layout plan: a later
    /// macOS/font engine must not redefine whether saved history is valid.
    public static func persistedPlan(
        text: String,
        style: AnnotationStyle,
        payload: AnnotationTextLayoutPayload
    ) throws -> AnnotationTextLayoutPlan {
        try validatePersistedTextStyle(style)
        guard payload.version == AnnotationTextLayoutPayload.currentVersion,
              payload.layoutEngineRevision.map(
                AnnotationTextLayoutPayload.supportedLayoutEngineRevisions.contains
              ) == true,
              let input = payload.input,
              let plan = payload.plan
        else {
            throw AnnotationTextLayoutValidationError.missingPersistedPlan
        }
        guard input.matches(text: text, style: style) else {
            throw AnnotationTextLayoutValidationError.layoutInputMismatch
        }
        guard plan.wrapWidth.isFinite,
              abs(plan.wrapWidth - payload.wrapWidth) < persistedGeometryTolerance,
              plan.lineAdvance.isFinite,
              plan.lineAdvance > 0,
              plan.topExtent.isFinite,
              plan.topExtent > 0,
              plan.bottomExtent.isFinite,
              plan.bottomExtent >= 0,
              plan.contentHeight.isFinite,
              plan.contentHeight > 0,
              !plan.lines.isEmpty
        else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "invalid plan dimensions"
            )
        }

        let nsText = text as NSString
        var nextConsumedLocation = 0
        for (lineIndex, line) in plan.lines.enumerated() {
            let drawable = line.utf16Range
            let consumed = line.consumedUTF16Range
            guard drawable.location >= 0,
                  drawable.length >= 0,
                  consumed.location == nextConsumedLocation,
                  consumed.length >= 0,
                  NSMaxRange(drawable) <= nsText.length,
                  NSMaxRange(consumed) <= nsText.length,
                  isUTF16ScalarBoundary(drawable.location, in: nsText),
                  isUTF16ScalarBoundary(NSMaxRange(drawable), in: nsText),
                  isUTF16ScalarBoundary(consumed.location, in: nsText),
                  isUTF16ScalarBoundary(NSMaxRange(consumed), in: nsText),
                  isValidZeroLengthConsumedLine(
                    lineIndex: lineIndex,
                    lineCount: plan.lines.count,
                    range: consumed,
                    text: text
                  ),
                  drawable == drawableUTF16Range(from: consumed, in: text)
            else {
                throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                    "line \(lineIndex) has invalid UTF-16 ownership"
                )
            }
            guard line.text == nsText.substring(with: drawable)
            else {
                throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                    "line \(lineIndex) does not match its source text"
                )
            }
            let metrics = line.metrics
            let glyphBounds = line.glyphBounds
            guard metrics.width.isFinite,
                  metrics.width >= 0,
                  metrics.ascent.isFinite,
                  metrics.ascent >= 0,
                  metrics.descent.isFinite,
                  metrics.descent >= 0,
                  metrics.leading.isFinite,
                  metrics.leading >= 0,
                  glyphBounds.origin.x.isFinite,
                  glyphBounds.origin.y.isFinite,
                  glyphBounds.size.width.isFinite,
                  glyphBounds.size.height.isFinite,
                  glyphBounds.width >= 0,
                  glyphBounds.height >= 0,
                  isLowercaseSHA256(line.shapeFingerprint),
                  line.originX.isFinite,
                  line.baselineOffset.isFinite,
                  abs(
                    line.baselineOffset
                        + CGFloat(lineIndex) * plan.lineAdvance
                  ) < persistedGeometryTolerance
            else {
                throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                    "line \(lineIndex) has invalid metrics or baseline"
                )
            }
            if drawable.length == 0 {
                guard metrics.width == 0, glyphBounds == .zero else {
                    throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                        "line \(lineIndex) has nonempty geometry for an empty line"
                    )
                }
            }
            nextConsumedLocation = NSMaxRange(consumed)
        }
        guard nextConsumedLocation == nsText.length else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "line ranges do not cover the complete source text"
            )
        }
        for (upper, lower) in zip(plan.lines, plan.lines.dropFirst()) {
            let typographicSeparation = upper.metrics.descent
                + lower.metrics.ascent
                + max(upper.metrics.leading, lower.metrics.leading)
            let glyphSeparation: CGFloat
            if upper.glyphBounds.isEmpty || lower.glyphBounds.isEmpty {
                glyphSeparation = 0
            } else {
                glyphSeparation = lower.glyphBounds.maxY
                    - upper.glyphBounds.minY
            }
            guard plan.lineAdvance + persistedGeometryTolerance
                    >= max(typographicSeparation, glyphSeparation)
            else {
                throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                    "line advance permits adjacent lines to overlap"
                )
            }
        }
        let expectedContentHeight = plan.topExtent
            + plan.bottomExtent
            + max(0, -(plan.lines.last?.baselineOffset ?? 0))
        guard abs(plan.contentHeight - expectedContentHeight)
                < persistedGeometryTolerance
        else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "content height does not match persisted line baselines"
            )
        }
        guard abs(plan.requiredLeadingOverhang - payload.leadingOverhang)
                < persistedGeometryTolerance,
              abs(plan.requiredTrailingOverhang - payload.trailingOverhang)
                < persistedGeometryTolerance
        else {
            throw AnnotationTextLayoutValidationError.overhangMismatch(
                expectedLeading: plan.requiredLeadingOverhang,
                actualLeading: payload.leadingOverhang,
                expectedTrailing: plan.requiredTrailingOverhang,
                actualTrailing: payload.trailingOverhang
            )
        }
        return plan
    }

    /// Validates the complete explicit geometry against its persisted plan.
    /// Missing legacy payloads intentionally retain their published geometry
    /// and do not enter this API.
    @discardableResult
    public static func validateExplicitLayout(
        text: String,
        style: AnnotationStyle,
        rect: CGRect,
        payload: AnnotationTextLayoutPayload
    ) throws -> AnnotationTextLayoutPlan {
        let plan = try persistedPlan(text: text, style: style, payload: payload)
        try validateGeometry(rect: rect, payload: payload, plan: plan)
        return plan
    }

    /// One-time admission for the unpublished geometry-only v2 draft. Its
    /// current-runtime dependency is contained here and the result is replaced
    /// immediately by a complete current snapshot owned by AnnotationItem.
    static func validateDraftRuntimeLayoutForMigration(
        text: String,
        style: AnnotationStyle,
        rect: CGRect,
        payload: AnnotationTextLayoutPayload
    ) throws -> AnnotationTextLayoutPlan {
        try validatePersistedTextStyle(style)
        let resolvedFont = try resolvedFont(style: style)
        let plan = layoutPlan(
            in: text,
            style: style,
            wrapWidth: payload.wrapWidth,
            resolvedFont: resolvedFont
        )
        try validateGeometry(rect: rect, payload: payload, plan: plan)
        return plan
    }

    private static func validateGeometry(
        rect: CGRect,
        payload: AnnotationTextLayoutPayload,
        plan: AnnotationTextLayoutPlan
    ) throws {
        try validateRawTextRectangle(rect)
        let standardized = rect.standardized
        let insets = chromeInsets(for: payload.chromeMode)
        let expectedWidth = insets.width * 2
            + payload.leadingOverhang
            + payload.wrapWidth
            + payload.trailingOverhang
        guard abs(standardized.width - expectedWidth) < persistedGeometryTolerance else {
            throw AnnotationTextLayoutValidationError.widthMismatch(
                expected: expectedWidth,
                actual: standardized.width
            )
        }
        let expectedHeight = insets.height * 2 + plan.contentHeight
        guard abs(standardized.height - expectedHeight) < persistedGeometryTolerance else {
            throw AnnotationTextLayoutValidationError.heightMismatch(
                expected: expectedHeight,
                actual: standardized.height
            )
        }
        guard abs(plan.requiredLeadingOverhang - payload.leadingOverhang)
                < persistedGeometryTolerance,
              abs(plan.requiredTrailingOverhang - payload.trailingOverhang)
                < persistedGeometryTolerance
        else {
            throw AnnotationTextLayoutValidationError.overhangMismatch(
                expectedLeading: plan.requiredLeadingOverhang,
                actualLeading: payload.leadingOverhang,
                expectedTrailing: plan.requiredTrailingOverhang,
                actualTrailing: payload.trailingOverhang
            )
        }

        let content = standardized.insetBy(dx: insets.width, dy: insets.height)
        let containerMinX = content.minX + payload.leadingOverhang
        let firstBaseline = content.maxY - plan.topExtent
        let toleratedContent = content.insetBy(
            dx: -persistedGeometryTolerance,
            dy: -persistedGeometryTolerance
        )
        for (lineIndex, line) in plan.lines.enumerated() {
            let baseline = firstBaseline + line.baselineOffset
            guard baseline - line.metrics.descent >= toleratedContent.minY,
                  baseline + line.metrics.ascent <= toleratedContent.maxY
            else {
                throw AnnotationTextLayoutValidationError
                    .typographicBoundsOutsideContent(lineIndex: lineIndex)
            }
            guard line.glyphBounds.isEmpty
                    || toleratedContent.contains(line.glyphBounds.offsetBy(
                        dx: containerMinX + line.originX,
                        dy: baseline
                    ))
            else {
                throw AnnotationTextLayoutValidationError
                    .glyphBoundsOutsideContent(lineIndex: lineIndex)
            }
        }
    }

    static func validateRawTextRectangle(_ rect: CGRect) throws {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.maxX.isFinite,
              rect.maxY.isFinite
        else {
            throw AnnotationTextLayoutValidationError.nonFiniteRectangle
        }
        guard rect.size.width > 0, rect.size.height > 0 else {
            throw AnnotationTextLayoutValidationError.nonPositiveRectangle
        }
    }

    /// Admits the one unpublished zero-overhang payload generation solely so
    /// it can be converted into the current canonical plan. Its historical
    /// rectangle represented exactly one 1.5×font-size line; arbitrary heights
    /// or multiline text are corruption, not geometry that migration may guess
    /// a new baseline from.
    static func validateLegacyZeroOverhangLayoutForMigration(
        text: String,
        style: AnnotationStyle,
        rect: CGRect,
        payload: AnnotationTextLayoutPayload
    ) throws {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.maxX.isFinite,
              rect.maxY.isFinite
        else {
            throw AnnotationTextLayoutValidationError.nonFiniteRectangle
        }
        guard rect.size.width > 0, rect.size.height > 0 else {
            throw AnnotationTextLayoutValidationError.nonPositiveRectangle
        }
        try validateAuthoringFont(style)
        guard !text.contains(where: \.isNewline) else {
            throw AnnotationTextLayoutValidationError.unsupportedLegacyMultilineText
        }
        let insets = chromeInsets(for: payload.chromeMode)
        let expectedWidth = insets.width * 2 + payload.wrapWidth
        guard abs(rect.width - expectedWidth) < persistedGeometryTolerance else {
            throw AnnotationTextLayoutValidationError.widthMismatch(
                expected: expectedWidth,
                actual: rect.width
            )
        }
        let expectedHeight = insets.height * 2
            + max(1, style.fontSize * rectangleHeightFactor)
        guard expectedHeight.isFinite,
              abs(rect.height - expectedHeight) < persistedGeometryTolerance
        else {
            throw AnnotationTextLayoutValidationError.heightMismatch(
                expected: expectedHeight,
                actual: rect.height
            )
        }
    }

    static func validatePersistedTextStyle(
        _ style: AnnotationStyle
    ) throws {
        guard style.fontSize.isFinite, style.fontSize > 0 else {
            throw AnnotationTextLayoutValidationError.invalidFontSize(style.fontSize)
        }
        if let fontName = style.fontName,
           fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AnnotationTextLayoutValidationError.invalidFontName
        }
    }

    static func validateAuthoringFont(_ style: AnnotationStyle) throws {
        try validatePersistedTextStyle(style)
        _ = try resolvedFont(style: style)
    }

    /// Admission boundary for installing an editable NSTextView. Rendering an
    /// empty annotation owns no pixels and may remain readable without its
    /// font, but editing always needs that font. Existing nonempty snapshots
    /// additionally prove the current fallback stack reproduces the saved
    /// shape before interactive state can replace the read-only presentation.
    public static func validateEditingCapability(
        text: String,
        style: AnnotationStyle,
        rect: CGRect? = nil,
        layout payload: AnnotationTextLayoutPayload?
    ) throws {
        try validatePersistedTextStyle(style)
        guard let payload else {
            if let rect { try validateRawTextRectangle(rect) }
            let primaryFont = try resolvedFont(style: style)
            try validateFontSources(
                in: text,
                primaryFont: primaryFont
            )
            return
        }
        let plan: AnnotationTextLayoutPlan
        if let rect {
            plan = try validateExplicitLayout(
                text: text,
                style: style,
                rect: rect,
                payload: payload
            )
        } else {
            plan = try persistedPlan(text: text, style: style, payload: payload)
        }
        guard let layoutEngineRevision = payload.layoutEngineRevision else {
            throw AnnotationTextLayoutValidationError.missingPersistedPlan
        }
        _ = try renderingTypesetter(
            text: text,
            style: style,
            plan: plan,
            layoutEngineRevision: layoutEngineRevision,
            foregroundColor: CGColor(gray: 0, alpha: 1)
        )
    }

    /// Builds the full-context typesetter used for rendering and proves that
    /// the current font/fallback stack reproduces the persisted shaped lines.
    /// A mismatch is an environment capability error, not document corruption.
    static func validateFontSources(
        in text: String,
        primaryFont: NSFont
    ) throws {
        _ = try fontSourceDigestCache.digest(for: primaryFont as CTFont)
        guard !text.isEmpty else { return }
        let attributed = NSAttributedString(
            string: normalizedTextForLayout(
                text,
                revision: AnnotationTextLayoutPayload.currentAuthoringLayoutEngineRevision
            ),
            attributes: [.font: primaryFont]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            _ = try fontSourceDigestCache.digest(
                for: runFont(run, primaryFont: primaryFont)
            )
        }
    }

    static func renderingTypesetter(
        text: String,
        style: AnnotationStyle,
        plan: AnnotationTextLayoutPlan,
        layoutEngineRevision: Int,
        foregroundColor: CGColor
    ) throws -> CTTypesetter {
        guard AnnotationTextLayoutPayload.supportedLayoutEngineRevisions.contains(
            layoutEngineRevision
        ) else {
            throw AnnotationTextRenderingError.unsupportedLayoutEngineRevision(
                layoutEngineRevision
            )
        }
        let primaryFont = try resolvedFont(style: style)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = plan.lineAdvance
        paragraphStyle.maximumLineHeight = plan.lineAdvance
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = nsTextAlignment(style.textAlignment)
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(
            string: normalizedTextForLayout(
                text,
                revision: layoutEngineRevision
            ),
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): primaryFont as CTFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foregroundColor,
                .paragraphStyle: paragraphStyle
            ]
        ))
        for (lineIndex, persistedLine) in plan.lines.enumerated() {
            let currentLine: CTLine?
            if persistedLine.utf16Range.length == 0 {
                currentLine = nil
            } else {
                currentLine = CTTypesetterCreateLine(
                    typesetter,
                    CFRange(
                        location: persistedLine.utf16Range.location,
                        length: persistedLine.utf16Range.length
                    )
                )
            }
            guard try textShapeFingerprint(
                line: currentLine,
                primaryFont: primaryFont,
                revision: layoutEngineRevision
            ) == persistedLine.shapeFingerprint
            else {
                throw AnnotationTextRenderingError.shapeChanged(lineIndex: lineIndex)
            }
            if let currentLine {
                let metrics = lineMetrics(for: currentLine)
                let glyphBounds = CTLineGetBoundsWithOptions(
                    currentLine,
                    [.useGlyphPathBounds]
                )
                guard lineMetricsMatch(metrics, persistedLine.metrics),
                      rectMatches(glyphBounds, persistedLine.glyphBounds)
                else {
                    throw AnnotationTextRenderingError.shapeChanged(lineIndex: lineIndex)
                }
            } else {
                let metrics = AnnotationTextLineMetrics(
                    width: 0,
                    ascent: primaryFont.ascender,
                    descent: max(0, -primaryFont.descender),
                    leading: max(0, primaryFont.leading)
                )
                guard lineMetricsMatch(metrics, persistedLine.metrics),
                      persistedLine.glyphBounds == .zero
                else {
                    throw AnnotationTextRenderingError.shapeChanged(lineIndex: lineIndex)
                }
            }
        }
        return typesetter
    }

    /// Resolves all line origins from the canonical document-space plan. The
    /// returned points are Core Text baseline origins in the annotation's local
    /// document coordinates; callers project them as one affine operation.
    public static func placedLines(
        in rect: CGRect,
        text: String,
        style: AnnotationStyle,
        layout payload: AnnotationTextLayoutPayload?
    ) -> [AnnotationTextPlacedLine] {
        let content = contentRect(from: rect, layout: payload)
        let textContainer = textContainerRect(from: rect, layout: payload)
        let plan: AnnotationTextLayoutPlan
        if let payload {
            do {
                plan = try persistedPlan(text: text, style: style, payload: payload)
            } catch {
                preconditionFailure("Cannot place an invalid persisted annotation text plan: \(error)")
            }
        } else {
            plan = layoutPlan(
                in: text,
                style: style,
                wrapWidth: max(1, content.width)
            )
        }
        return placedLines(
            plan: plan,
            textContainer: textContainer,
            firstBaseline: baselineY(
                in: rect,
                style: style,
                layout: payload,
                plan: plan
            )
        )
    }

    static func placedLines(
        plan: AnnotationTextLayoutPlan,
        textContainer: CGRect,
        firstBaseline: CGFloat
    ) -> [AnnotationTextPlacedLine] {
        plan.lines.map { line in
            AnnotationTextPlacedLine(
                line: line,
                origin: CGPoint(
                    x: textContainer.minX + line.originX,
                    y: firstBaseline + line.baselineOffset
                )
            )
        }
    }

    /// Soft-wrapped visual lines resolved by the canonical TextKit plan.
    public static func visualLines(
        in text: String,
        style: AnnotationStyle,
        wrapWidth: CGFloat,
        size: CGFloat? = nil
    ) -> [String] {
        layoutPlan(
            in: text,
            style: style,
            wrapWidth: wrapWidth,
            size: size
        ).lines.map(\.text)
    }

    public static func visualLineCount(
        in text: String,
        style: AnnotationStyle,
        wrapWidth: CGFloat,
        size: CGFloat? = nil
    ) -> Int {
        layoutPlan(
            in: text,
            style: style,
            wrapWidth: wrapWidth,
            size: size
        ).lineCount
    }

    /// Resolves a new annotation using current uniform chrome. `maximumWrapWidth`
    /// is a constraint rather than stored presentation state: text that fits is
    /// allowed to stay compact, while overflowing text owns the exact boundary.
    public static func newTextLayout(
        baselineAnchor: CGPoint,
        text: String,
        style: AnnotationStyle,
        maximumWrapWidth: CGFloat? = nil
    ) throws -> AnnotationTextLayoutResolution {
        if let maximumWrapWidth,
           (!maximumWrapWidth.isFinite || maximumWrapWidth <= 0) {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "new text layout requires a positive finite maximum wrap width"
            )
        }
        let resolvedFont = try resolvedFont(style: style)
        let contentWidth = resolvedContentWidth(
            for: text,
            resolvedFont: resolvedFont,
            maximumWrapWidth: maximumWrapWidth
        )
        let payload = try safeLayoutPayload(
            for: text,
            style: style,
            proposedWrapWidth: contentWidth,
            chromeMode: .uniformPadded,
            resolvedFont: resolvedFont
        )
        return AnnotationTextLayoutResolution(
            rect: annotationRect(
                baselineAnchor: baselineAnchor,
                text: text,
                style: style,
                layout: payload
            ),
            payload: payload
        )
    }

    public static func annotationRect(
        baselineAnchor: CGPoint,
        text: String,
        style: AnnotationStyle,
        wrapWidth: CGFloat? = nil,
        chromeMode: AnnotationTextLayoutPayload.ChromeMode = .uniformPadded
    ) -> CGRect {
        let contentWidth = resolvedContentWidth(
            for: text,
            style: style,
            maximumWrapWidth: wrapWidth
        )
        let plan = layoutPlan(
            in: text,
            style: style,
            wrapWidth: contentWidth
        )
        return annotationRect(
            baselineAnchor: baselineAnchor,
            style: style,
            plan: plan,
            chromeMode: chromeMode,
            leadingOverhang: plan.requiredLeadingOverhang,
            trailingOverhang: plan.requiredTrailingOverhang
        )
    }

    public static func annotationRect(
        baselineAnchor: CGPoint,
        text: String,
        style: AnnotationStyle,
        canonicalWrapWidth: CGFloat,
        chromeMode: AnnotationTextLayoutPayload.ChromeMode
    ) -> CGRect {
        precondition(
            canonicalWrapWidth.isFinite && canonicalWrapWidth > 0,
            "Canonical annotation text wrap width must be positive and finite."
        )
        let plan = layoutPlan(
            in: text,
            style: style,
            wrapWidth: canonicalWrapWidth
        )
        return annotationRect(
            baselineAnchor: baselineAnchor,
            style: style,
            plan: plan,
            chromeMode: chromeMode,
            leadingOverhang: plan.requiredLeadingOverhang,
            trailingOverhang: plan.requiredTrailingOverhang
        )
    }

    public static func annotationRect(
        baselineAnchor: CGPoint,
        text: String,
        style: AnnotationStyle,
        layout payload: AnnotationTextLayoutPayload
    ) -> CGRect {
        let plan: AnnotationTextLayoutPlan
        do {
            plan = try persistedPlan(text: text, style: style, payload: payload)
        } catch {
            preconditionFailure("Cannot resolve a rectangle from an invalid annotation text plan: \(error)")
        }
        return annotationRect(
            baselineAnchor: baselineAnchor,
            style: style,
            plan: plan,
            chromeMode: payload.chromeMode,
            leadingOverhang: payload.leadingOverhang,
            trailingOverhang: payload.trailingOverhang
        )
    }

    private static func annotationRect(
        baselineAnchor: CGPoint,
        style: AnnotationStyle,
        plan: AnnotationTextLayoutPlan,
        chromeMode: AnnotationTextLayoutPayload.ChromeMode,
        leadingOverhang: CGFloat,
        trailingOverhang: CGFloat
    ) -> CGRect {
        let insets = chromeInsets(for: chromeMode)
        let x = lineOriginX(
            alignmentAnchorX: baselineAnchor.x,
            lineWidth: plan.wrapWidth,
            alignment: style.textAlignment
        ) - leadingOverhang - insets.width
        return CGRect(
            x: x,
            y: baselineAnchor.y
                - max(0, -(plan.lines.last?.baselineOffset ?? 0))
                - plan.bottomExtent
                - insets.height,
            width: leadingOverhang
                + plan.wrapWidth
                + trailingOverhang
                + insets.width * 2,
            height: plan.contentHeight + insets.height * 2
        )
    }

    /// Returns explicit chrome padding. No geometry-based generation inference
    /// is permitted: a missing payload is resolved by callers as legacy tight.
    public static func chromeInsets(
        for chromeMode: AnnotationTextLayoutPayload.ChromeMode
    ) -> CGSize {
        switch chromeMode {
        case .legacyTight:
            return .zero
        case .uniformPadded:
            return CGSize(
                width: horizontalChromePadding,
                height: verticalChromePadding
            )
        }
    }

    public static func chromeInsets(
        for payload: AnnotationTextLayoutPayload?
    ) -> CGSize {
        chromeInsets(for: payload?.chromeMode ?? .legacyTight)
    }

    public static func presentationFieldWidth(
        canonicalWrapWidth: CGFloat,
        chromeMode: AnnotationTextLayoutPayload.ChromeMode,
        canvasScale: CGFloat,
        uniformTransformScale: CGFloat
    ) -> CGFloat {
        precondition(
            canonicalWrapWidth.isFinite && canonicalWrapWidth > 0
                && canvasScale.isFinite && canvasScale > 0
                && uniformTransformScale.isFinite && uniformTransformScale > 0,
            "Text field presentation width requires finite positive geometry."
        )
        let horizontalInset = chromeInsets(for: chromeMode).width
        return (canonicalWrapWidth + horizontalInset * 2)
            * canvasScale
            * uniformTransformScale
    }

    public static func presentationFieldWidth(
        layout payload: AnnotationTextLayoutPayload,
        canvasScale: CGFloat,
        uniformTransformScale: CGFloat
    ) -> CGFloat {
        precondition(
            canvasScale.isFinite && canvasScale > 0
                && uniformTransformScale.isFinite && uniformTransformScale > 0,
            "Text field presentation width requires finite positive geometry."
        )
        let chrome = chromeInsets(for: payload.chromeMode).width
        return (
            chrome * 2
                + payload.leadingOverhang
                + payload.wrapWidth
                + payload.trailingOverhang
        ) * canvasScale * uniformTransformScale
    }

    public static func canonicalWrapWidth(
        fromPresentationFieldWidth fieldWidth: CGFloat,
        chromeMode: AnnotationTextLayoutPayload.ChromeMode,
        canvasScale: CGFloat,
        uniformTransformScale: CGFloat
    ) -> CGFloat {
        precondition(
            fieldWidth.isFinite && fieldWidth > 0
                && canvasScale.isFinite && canvasScale > 0
                && uniformTransformScale.isFinite && uniformTransformScale > 0,
            "Text field inversion requires finite positive geometry."
        )
        let horizontalInset = chromeInsets(for: chromeMode).width
        let result = fieldWidth / (canvasScale * uniformTransformScale)
            - horizontalInset * 2
        precondition(
            result.isFinite && result > 0,
            "Text field inversion produced a non-positive canonical wrap width."
        )
        return result
    }

    public static func contentRect(
        from rect: CGRect,
        layout payload: AnnotationTextLayoutPayload?
    ) -> CGRect {
        let insets = chromeInsets(for: payload)
        let content = rect.standardized.insetBy(dx: insets.width, dy: insets.height)
        precondition(
            content.width > 0 && content.height > 0,
            "Annotation text chrome cannot consume its complete geometry."
        )
        if let payload {
            precondition(
                abs(
                    content.width
                        - payload.leadingOverhang
                        - payload.wrapWidth
                        - payload.trailingOverhang
                ) < persistedGeometryTolerance,
                "Persisted annotation text layout must match its complete content rectangle."
            )
        }
        return content
    }

    public static func textContainerRect(
        from rect: CGRect,
        layout payload: AnnotationTextLayoutPayload?
    ) -> CGRect {
        let content = contentRect(from: rect, layout: payload)
        guard let payload else { return content }
        let container = CGRect(
            x: content.minX + payload.leadingOverhang,
            y: content.minY,
            width: payload.wrapWidth,
            height: content.height
        )
        precondition(
            container.width > 0 && container.height > 0,
            "Annotation text container must retain positive geometry."
        )
        return container
    }

    public static func canonicalWrapWidth(for item: AnnotationItem) -> CGFloat {
        guard item.kind == .text, case .rect(let rect) = item.geometry else {
            preconditionFailure("Canonical text wrap width requires a text rectangle.")
        }
        if let payload = item.textLayout {
            _ = textContainerRect(from: rect, layout: payload)
            return payload.wrapWidth
        }
        return contentRect(from: rect, layout: nil).width
    }

    public static func alignmentAnchor(
        in rect: CGRect,
        text: String,
        style: AnnotationStyle,
        layout payload: AnnotationTextLayoutPayload?
    ) -> CGPoint {
        let content = textContainerRect(from: rect, layout: payload)
        let x: CGFloat
        switch style.textAlignment {
        case .leading: x = content.minX
        case .center: x = content.midX
        case .trailing: x = content.maxX
        }
        return CGPoint(
            x: x,
            y: baselineY(
                in: rect,
                text: text,
                style: style,
                layout: payload
            )
        )
    }

    public static func lineOriginX(
        in rect: CGRect,
        lineWidth: CGFloat,
        alignment: AnnotationTextAlignment
    ) -> CGFloat {
        let standardized = rect.standardized
        let alignmentAnchorX: CGFloat
        switch alignment {
        case .leading: alignmentAnchorX = standardized.minX
        case .center: alignmentAnchorX = standardized.midX
        case .trailing: alignmentAnchorX = standardized.maxX
        }
        return lineOriginX(
            alignmentAnchorX: alignmentAnchorX,
            lineWidth: lineWidth,
            alignment: alignment
        )
    }

    public static func lineOriginX(
        in rect: CGRect,
        lineWidth: CGFloat,
        style: AnnotationStyle,
        layout payload: AnnotationTextLayoutPayload?
    ) -> CGFloat {
        lineOriginX(
            in: textContainerRect(from: rect, layout: payload),
            lineWidth: lineWidth,
            alignment: style.textAlignment
        )
    }

    public static func lineOriginX(
        alignmentAnchorX: CGFloat,
        lineWidth: CGFloat,
        alignment: AnnotationTextAlignment
    ) -> CGFloat {
        switch alignment {
        case .leading: return alignmentAnchorX
        case .center: return alignmentAnchorX - lineWidth / 2
        case .trailing: return alignmentAnchorX - lineWidth
        }
    }

    /// Origin for fixed-frame, single-line labels such as Counter badges.
    ///
    /// These labels do not own text-selection chrome and must never infer
    /// padding or soft wrapping from their enclosing shape geometry.
    static func fixedFrameSingleLineOrigin(
        for text: String,
        in rect: CGRect,
        style: AnnotationStyle
    ) -> CGPoint {
        fixedFrameSingleLineOrigin(
            for: text,
            in: rect,
            style: style,
            font: font(style: style)
        )
    }

    static func fixedFrameSingleLineOrigin(
        for text: String,
        in rect: CGRect,
        style: AnnotationStyle,
        font: NSFont
    ) -> CGPoint {
        precondition(
            !text.contains(where: \.isNewline),
            "A fixed-frame single-line label cannot contain a line break."
        )
        let lineWidth = lineMetrics(for: text, font: font).width
        return CGPoint(
            x: lineOriginX(
                in: rect,
                lineWidth: lineWidth,
                alignment: style.textAlignment
            ),
            y: rect.standardized.midY
                + style.fontSize * baselineOffsetFromCenterFactor
        )
    }

    public static func baselineY(
        in rect: CGRect,
        text: String,
        style: AnnotationStyle,
        layout payload: AnnotationTextLayoutPayload?
    ) -> CGFloat {
        if payload == nil
            || payload?.decodedFromLegacyZeroOverhangVersion == true
            || payload?.decodedFromDraftRuntimeRecomputedVersion == true {
            return legacyBaselineY(
                in: contentRect(from: rect, layout: payload),
                style: style
            )
        }
        guard let payload else {
            preconditionFailure("Explicit text baseline resolution lost its layout payload.")
        }
        let plan: AnnotationTextLayoutPlan
        do {
            plan = try persistedPlan(text: text, style: style, payload: payload)
        } catch {
            preconditionFailure("Cannot resolve a baseline from an invalid annotation text plan: \(error)")
        }
        return baselineY(
            in: rect,
            style: style,
            layout: payload,
            plan: plan
        )
    }

    static func baselineY(
        in rect: CGRect,
        style: AnnotationStyle,
        layout payload: AnnotationTextLayoutPayload?,
        plan: AnnotationTextLayoutPlan
    ) -> CGFloat {
        let content = contentRect(from: rect, layout: payload)
        guard let payload,
              !payload.decodedFromLegacyZeroOverhangVersion,
              !payload.decodedFromDraftRuntimeRecomputedVersion
        else {
            return legacyBaselineY(in: content, style: style)
        }
        precondition(
            abs(plan.wrapWidth - payload.wrapWidth) < persistedGeometryTolerance,
            "Explicit annotation text baseline requires its matching TextKit plan."
        )
        return content.maxY - plan.topExtent
    }

    private static func legacyBaselineY(
        in content: CGRect,
        style: AnnotationStyle
    ) -> CGFloat {
        let singleHeight = max(1, style.fontSize * rectangleHeightFactor)
        let firstLineMidY = content.maxY - singleHeight / 2
        return firstLineMidY + style.fontSize * baselineOffsetFromCenterFactor
    }

    /// Atomically changes text and/or font size while preserving the first-line
    /// baseline. A missing legacy payload remains absent for a semantic no-op;
    /// the first real layout mutation materializes an explicit legacy payload.
    public static func reflowedTextItem(
        _ item: AnnotationItem,
        text: String,
        fontSize: CGFloat,
        wrapWidthStrategy: AnnotationTextWrapWidthStrategy = .preserve
    ) throws -> AnnotationItem {
        guard item.kind == .text, case .rect(let rect) = item.geometry else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "text reflow requires a text annotation with rectangle geometry"
            )
        }
        guard fontSize.isFinite, fontSize > 0 else {
            throw AnnotationTextLayoutValidationError.invalidFontSize(fontSize)
        }
        let originalText = item.text ?? ""
        if originalText == text && abs(item.style.fontSize - fontSize) < 0.000_001 {
            return item
        }

        let baseline = alignmentAnchor(
            in: rect,
            text: originalText,
            style: item.style,
            layout: item.textLayout
        )
        let originalWrapWidth = canonicalWrapWidth(for: item)
        let proposedWrapWidth: CGFloat
        switch wrapWidthStrategy {
        case .preserve:
            proposedWrapWidth = originalWrapWidth
        case .scaleWithFont:
            proposedWrapWidth = originalWrapWidth * fontSize / item.style.fontSize
        }
        guard proposedWrapWidth.isFinite, proposedWrapWidth > 0 else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "text reflow produced an invalid canonical wrap width"
            )
        }

        let chromeMode = item.textLayout?.chromeMode ?? .legacyTight
        var result = item
        result.text = text
        result.style.fontSize = fontSize
        let payload = try safeLayoutPayload(
            for: text,
            style: result.style,
            proposedWrapWidth: proposedWrapWidth,
            chromeMode: chromeMode
        )
        result.textLayout = payload
        result.geometry = .rect(annotationRect(
            baselineAnchor: baseline,
            text: text,
            style: result.style,
            layout: payload
        ))
        return result
    }

    /// Computes the largest font size whose dynamically rewrapped lines fit a
    /// height budget. Line count is recomputed at every candidate size.
    public static func maximumFontSize(
        text: String,
        style: AnnotationStyle,
        wrapWidthAtInitialSize: CGFloat,
        initialFontSize: CGFloat,
        upperBound: CGFloat,
        maximumContentHeight: CGFloat,
        maximumWrapWidth: CGFloat? = nil
    ) -> CGFloat {
        precondition(
            wrapWidthAtInitialSize.isFinite && wrapWidthAtInitialSize > 0
                && initialFontSize.isFinite && initialFontSize > 0
                && upperBound.isFinite && upperBound >= initialFontSize
                && maximumContentHeight.isFinite && maximumContentHeight > 0,
            "Maximum text font-size resolution requires finite positive bounds."
        )
        func requiredHeight(at fontSize: CGFloat) -> CGFloat {
            let proportionalWrapWidth = wrapWidthAtInitialSize * fontSize / initialFontSize
            let candidateWrapWidth = maximumWrapWidth.map {
                precondition(
                    $0.isFinite && $0 > 0,
                    "Maximum candidate text wrap width must be positive and finite."
                )
                return min(proportionalWrapWidth, $0)
            } ?? proportionalWrapWidth
            let plan = layoutPlan(
                in: text,
                style: style,
                wrapWidth: candidateWrapWidth,
                size: fontSize
            )
            return plan.contentHeight
        }

        guard requiredHeight(at: initialFontSize) <= maximumContentHeight,
              upperBound > initialFontSize
        else { return initialFontSize }
        guard requiredHeight(at: upperBound) > maximumContentHeight else {
            return upperBound
        }

        var lower = initialFontSize
        var upper = upperBound
        for _ in 0..<16 {
            let candidate = (lower + upper) / 2
            if requiredHeight(at: candidate) <= maximumContentHeight {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return lower
    }

    /// Throwing editing boundary for the largest usable font size. The caller
    /// supplies the already admitted font generation; candidate sizes are
    /// immutable Core Text copies of that object, rather than fresh name-based
    /// lookups that could disappear midway through one pointer interaction.
    public static func maximumEditableFontSize(
        text: String,
        style: AnnotationStyle,
        wrapWidthAtInitialSize: CGFloat,
        initialFontSize: CGFloat,
        upperBound: CGFloat,
        maximumContentHeight: CGFloat,
        maximumWrapWidth: CGFloat? = nil,
        resolvedFont: NSFont
    ) throws -> CGFloat {
        try validatePersistedTextStyle(style)
        try validateFontSources(in: text, primaryFont: resolvedFont)
        precondition(
            wrapWidthAtInitialSize.isFinite && wrapWidthAtInitialSize > 0
                && initialFontSize.isFinite && initialFontSize > 0
                && upperBound.isFinite && upperBound >= initialFontSize
                && maximumContentHeight.isFinite && maximumContentHeight > 0,
            "Maximum text font-size resolution requires finite positive bounds."
        )
        if let maximumWrapWidth {
            precondition(
                maximumWrapWidth.isFinite && maximumWrapWidth > 0,
                "Maximum candidate text wrap width must be positive and finite."
            )
        }

        func requiredHeight(at fontSize: CGFloat) -> CGFloat {
            let proportionalWrapWidth = wrapWidthAtInitialSize * fontSize / initialFontSize
            let candidateWrapWidth = maximumWrapWidth.map {
                min(proportionalWrapWidth, $0)
            } ?? proportionalWrapWidth
            let candidateFont = CTFontCreateCopyWithAttributes(
                resolvedFont as CTFont,
                fontSize,
                nil,
                nil
            ) as NSFont
            return layoutPlan(
                in: text,
                style: style,
                wrapWidth: candidateWrapWidth,
                resolvedFont: candidateFont
            ).contentHeight
        }

        guard requiredHeight(at: initialFontSize) <= maximumContentHeight,
              upperBound > initialFontSize
        else { return initialFontSize }
        guard requiredHeight(at: upperBound) > maximumContentHeight else {
            return upperBound
        }

        var lower = initialFontSize
        var upper = upperBound
        for _ in 0..<16 {
            let candidate = (lower + upper) / 2
            if requiredHeight(at: candidate) <= maximumContentHeight {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return lower
    }

    private static func resolvedContentWidth(
        for text: String,
        style: AnnotationStyle,
        maximumWrapWidth: CGFloat?
    ) -> CGFloat {
        resolvedContentWidth(
            for: text,
            resolvedFont: font(style: style),
            maximumWrapWidth: maximumWrapWidth
        )
    }

    private static func resolvedContentWidth(
        for text: String,
        resolvedFont: NSFont,
        maximumWrapWidth: CGFloat?
    ) -> CGFloat {
        let unwrappedWidth = max(1, ceil(lines(in: text).map {
            lineMetrics(for: $0, font: resolvedFont).width
        }.max() ?? 0))
        guard let maximumWrapWidth else { return unwrappedWidth }
        precondition(
            maximumWrapWidth.isFinite && maximumWrapWidth > 0,
            "Maximum annotation text wrap width must be positive and finite."
        )
        return max(1, min(unwrappedWidth, maximumWrapWidth))
    }

    /// Resolves the exact persisted TextKit container width plus the asymmetric
    /// ink space that does not participate in wrapping.
    public static func safeLayoutPayload(
        for text: String,
        style: AnnotationStyle,
        proposedWrapWidth: CGFloat,
        chromeMode: AnnotationTextLayoutPayload.ChromeMode
    ) throws -> AnnotationTextLayoutPayload {
        try safeLayoutPayload(
            for: text,
            style: style,
            proposedWrapWidth: proposedWrapWidth,
            chromeMode: chromeMode,
            resolvedFont: resolvedFont(style: style)
        )
    }

    /// Authors a renderer-ready payload from one already admitted immutable
    /// font object. Interactive callers use this overload so one edit
    /// generation cannot resolve different source bytes between layout and
    /// persistence.
    public static func safeLayoutPayload(
        for text: String,
        style: AnnotationStyle,
        proposedWrapWidth: CGFloat,
        chromeMode: AnnotationTextLayoutPayload.ChromeMode,
        resolvedFont: NSFont
    ) throws -> AnnotationTextLayoutPayload {
        guard proposedWrapWidth.isFinite, proposedWrapWidth > 0 else {
            throw AnnotationTextLayoutValidationError.malformedPersistedPlan(
                "renderer-ready authoring requires a positive finite wrap width"
            )
        }
        let plan = try rendererReadyLayoutPlan(
            in: text,
            style: style,
            wrapWidth: proposedWrapWidth,
            resolvedFont: resolvedFont
        )
        return try AnnotationTextLayoutPayload(
            chromeMode: chromeMode,
            wrapWidth: proposedWrapWidth,
            leadingOverhang: plan.requiredLeadingOverhang,
            trailingOverhang: plan.requiredTrailingOverhang,
            input: AnnotationTextLayoutInput(text: text, style: style),
            plan: plan
        )
    }

    private static func nsTextAlignment(
        _ alignment: AnnotationTextAlignment
    ) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    private static func fontVerticalExtents(
        _ font: NSFont
    ) -> (top: CGFloat, bottom: CGFloat) {
        let fontBounds = font.boundingRectForFont
        let top = max(font.ascender, fontBounds.maxY)
        let bottom = max(max(0, -font.descender), max(0, -fontBounds.minY))
        precondition(
            top.isFinite && bottom.isFinite && top > 0,
            "Annotation font produced invalid vertical bounds."
        )
        return (top, bottom)
    }

    private static func normalizedTextForLayout(
        _ text: String,
        revision: Int
    ) -> String {
        switch revision {
        case 1:
            return text.replacingOccurrences(of: "\u{000C}", with: "\n")
        default:
            preconditionFailure(
                "Unsupported annotation text authoring layout revision \(revision)."
            )
        }
    }

    private static func hasTrailingHardLineBreak(_ text: String) -> Bool {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return drawableUTF16Range(from: fullRange, in: text) != fullRange
    }

    private static func isUTF16ScalarBoundary(
        _ location: Int,
        in text: NSString
    ) -> Bool {
        guard location > 0, location < text.length else {
            return location == 0 || location == text.length
        }
        let previous = text.character(at: location - 1)
        let current = text.character(at: location)
        return !((0xD800...0xDBFF).contains(previous)
            && (0xDC00...0xDFFF).contains(current))
    }

    private static func isValidZeroLengthConsumedLine(
        lineIndex: Int,
        lineCount: Int,
        range: NSRange,
        text: String
    ) -> Bool {
        guard range.length == 0 else { return true }
        let textLength = (text as NSString).length
        if text.isEmpty {
            return lineCount == 1 && lineIndex == 0 && range.location == 0
        }
        return lineIndex == lineCount - 1
            && range.location == textLength
            && hasTrailingHardLineBreak(text)
    }

    static func isRendererReadyPlan(_ plan: AnnotationTextLayoutPlan) -> Bool {
        !plan.lines.isEmpty && plan.lines.allSatisfy {
            isLowercaseSHA256($0.shapeFingerprint)
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func drawableUTF16Range(
        from consumedRange: NSRange,
        in text: String
    ) -> NSRange {
        guard consumedRange.length > 0 else { return consumedRange }
        let nsText = text as NSString
        let end = NSMaxRange(consumedRange)
        guard end <= nsText.length else { return consumedRange }
        let finalUnit = nsText.character(at: end - 1)
        let terminatorLength: Int
        if finalUnit == 0x0A,
           consumedRange.length >= 2,
           nsText.character(at: end - 2) == 0x0D {
            terminatorLength = 2
        } else if (0x0A...0x0D).contains(finalUnit)
                    || finalUnit == 0x0085
                    || finalUnit == 0x2028
                    || finalUnit == 0x2029 {
            terminatorLength = 1
        } else {
            return consumedRange
        }
        return NSRange(
            location: consumedRange.location,
            length: consumedRange.length - terminatorLength
        )
    }

    private static func makePlanLine(
        text: String,
        nsText: NSString,
        drawableRange: NSRange,
        consumedRange: NSRange,
        primaryFont: NSFont,
        typesetter: CTTypesetter,
        originX: CGFloat,
        baselineOffset: CGFloat
    ) -> AnnotationTextLayoutLine {
        precondition(
            NSMaxRange(drawableRange) <= nsText.length
                && NSMaxRange(consumedRange) <= nsText.length,
            "TextKit produced a line range outside the annotation string."
        )
        let lineText = nsText.substring(with: drawableRange)
        let metrics: AnnotationTextLineMetrics
        let glyphBounds: CGRect
        if lineText.isEmpty {
            metrics = AnnotationTextLineMetrics(
                width: 0,
                ascent: primaryFont.ascender,
                descent: max(0, -primaryFont.descender),
                leading: max(0, primaryFont.leading)
            )
            glyphBounds = .zero
        } else {
            let line = CTTypesetterCreateLine(
                typesetter,
                CFRange(location: drawableRange.location, length: drawableRange.length)
            )
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            ))
            metrics = AnnotationTextLineMetrics(
                width: max(0, width),
                ascent: max(0, ascent),
                descent: max(0, descent),
                leading: max(0, leading)
            )
            glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        }
        return AnnotationTextLayoutLine(
            text: lineText,
            utf16Range: drawableRange,
            consumedUTF16Range: consumedRange,
            metrics: metrics,
            glyphBounds: glyphBounds,
            shapeFingerprint: transientShapeFingerprint,
            originX: originX,
            baselineOffset: baselineOffset
        )
    }

    private static func lineMetrics(
        for line: CTLine
    ) -> AnnotationTextLineMetrics {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            &leading
        ))
        return AnnotationTextLineMetrics(
            width: max(0, width),
            ascent: max(0, ascent),
            descent: max(0, descent),
            leading: max(0, leading)
        )
    }

    private static func lineMetricsMatch(
        _ lhs: AnnotationTextLineMetrics,
        _ rhs: AnnotationTextLineMetrics
    ) -> Bool {
        abs(lhs.width - rhs.width) < persistedGeometryTolerance
            && abs(lhs.ascent - rhs.ascent) < persistedGeometryTolerance
            && abs(lhs.descent - rhs.descent) < persistedGeometryTolerance
            && abs(lhs.leading - rhs.leading) < persistedGeometryTolerance
    }

    private static func rectMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < persistedGeometryTolerance
            && abs(lhs.origin.y - rhs.origin.y) < persistedGeometryTolerance
            && abs(lhs.size.width - rhs.size.width) < persistedGeometryTolerance
            && abs(lhs.size.height - rhs.size.height) < persistedGeometryTolerance
    }

    /// Produces an architecture-independent digest of the actual Core Text
    /// shape selected for a visual line. Foreground color is deliberately not
    /// included: it does not affect shaping and remains mutable annotation
    /// style, while glyph/font/position drift must never pass silently.
    private static func textShapeFingerprint(
        line: CTLine?,
        primaryFont: NSFont,
        revision: Int
    ) throws -> String {
        var data = Data()
        switch revision {
        case 1:
            appendFingerprintString("ushot.annotation-text-shape.v1", to: &data)
        default:
            preconditionFailure(
                "Unsupported annotation text shape revision \(revision)."
            )
        }
        try appendFingerprintFont(primaryFont as CTFont, to: &data)
        guard let line else {
            appendFingerprintInteger(0, to: &data)
            return SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        }

        let runs = CTLineGetGlyphRuns(line) as NSArray
        appendFingerprintInteger(runs.count, to: &data)
        for case let run as CTRun in runs {
            let stringRange = CTRunGetStringRange(run)
            appendFingerprintInteger(stringRange.location, to: &data)
            appendFingerprintInteger(stringRange.length, to: &data)
            appendFingerprintInteger(Int(CTRunGetStatus(run).rawValue), to: &data)

            let runFont = runFont(run, primaryFont: primaryFont)
            try appendFingerprintFont(runFont, to: &data)
            appendFingerprintTransform(CTRunGetTextMatrix(run), to: &data)

            let glyphCount = CTRunGetGlyphCount(run)
            appendFingerprintInteger(glyphCount, to: &data)
            guard glyphCount > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            glyphs.withUnsafeMutableBufferPointer { buffer in
                CTRunGetGlyphs(
                    run,
                    CFRange(location: 0, length: glyphCount),
                    buffer.baseAddress!
                )
            }
            positions.withUnsafeMutableBufferPointer { buffer in
                CTRunGetPositions(
                    run,
                    CFRange(location: 0, length: glyphCount),
                    buffer.baseAddress!
                )
            }
            advances.withUnsafeMutableBufferPointer { buffer in
                CTRunGetAdvances(
                    run,
                    CFRange(location: 0, length: glyphCount),
                    buffer.baseAddress!
                )
            }
            for glyph in glyphs {
                appendFingerprintInteger(Int(glyph), to: &data)
                appendFingerprintGlyphAppearance(
                    glyph,
                    font: runFont,
                    to: &data
                )
            }
            for position in positions {
                appendFingerprintCGFloat(position.x, to: &data)
                appendFingerprintCGFloat(position.y, to: &data)
            }
            for advance in advances {
                appendFingerprintCGFloat(advance.width, to: &data)
                appendFingerprintCGFloat(advance.height, to: &data)
            }
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static let fontSourceDigestCache = FontSourceDigestCache()

    private static func runFont(
        _ run: CTRun,
        primaryFont: NSFont
    ) -> CTFont {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes.object(
            forKey: kCTFontAttributeName as String
        ) else {
            return primaryFont as CTFont
        }
        let object = value as AnyObject
        precondition(
            CFGetTypeID(object) == CTFontGetTypeID(),
            "Core Text returned a non-font glyph-run font attribute."
        )
        return unsafeBitCast(object, to: CTFont.self)
    }

    /// Chooses the complete file digest first and the complete set of readable
    /// font tables second. A malformed or unreadable source never becomes a
    /// stable sentinel: callers either receive 32 authenticated digest bytes or
    /// the same typed capability error used by rendering/edit admission.
    static func resolveFontSourceDigest(
        fontName: String,
        fileDigest: () throws -> Data?,
        tableDigest: () throws -> Data?
    ) throws -> Data {
        do {
            if let digest = try fileDigest(), digest.count == SHA256.byteCount {
                return digest
            }
        } catch {
            // A source URL can become unreadable after Core Text resolves the
            // face. Falling back to every exposed table still binds all font
            // bytes Core Text can use; failure of both paths is reported below.
        }
        do {
            if let digest = try tableDigest(), digest.count == SHA256.byteCount {
                return digest
            }
        } catch {
            // Preserve one public capability boundary rather than leaking
            // filesystem/font-parser implementation errors to document code.
        }
        throw AnnotationTextRenderingError.fontSourceUnavailable(fontName)
    }

    static func stableFontSourceFingerprint(_ font: CTFont) throws -> String {
        fingerprintHexDigest(try fontSourceDigestCache.digest(for: font))
    }

    private struct FontFileCacheKey: Hashable {
        let canonicalURL: URL
        let fileResourceIdentifier: AnyHashable
        let generationIdentifier: AnyHashable
        let fileSize: Int
        let modificationTimeBits: UInt64
    }

    /// A no-URL font has no external generation identifier that can prove two
    /// separately created Core Text objects still expose the same bytes. Keep
    /// the exact immutable CTFont alive and reuse its table digest only for
    /// that object identity; a new object must rescan every available table
    /// even when Core Text considers both descriptors equal.
    struct FontObjectCacheKey: Hashable {
        let font: CTFont

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.font === rhs.font
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(font))
        }
    }

    private enum FontSourceReadError: Error {
        case missingFileMetadata
        case changedWhileReading
        case invalidTableDirectory
        case unreadableTable(CTFontTableTag)
    }

    private final class FontSourceDigestCache: @unchecked Sendable {
        /// No-URL fonts have no durable generation key, so their entries must
        /// retain the exact CTFont object. Keep that correctness guarantee
        /// without retaining every dynamically registered font for the entire
        /// process lifetime. Eviction only forces a complete table rescan.
        private static let maximumTableDigestCount = 32

        private let lock = NSLock()
        private var fileDigests: [FontFileCacheKey: Data] = [:]
        private var tableDigests: [FontObjectCacheKey: Data] = [:]
        private var tableDigestRecency: [FontObjectCacheKey] = []

        func digest(for font: CTFont) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            let fontName = CTFontCopyPostScriptName(font) as String
            return try AnnotationTextLayout.resolveFontSourceDigest(
                fontName: fontName,
                fileDigest: { try self.fileDigest(for: font) },
                tableDigest: { try self.tableDigest(for: font) }
            )
        }

        private func fileDigest(for font: CTFont) throws -> Data? {
            let descriptor = CTFontCopyFontDescriptor(font)
            guard let sourceURL = CTFontDescriptorCopyAttribute(
                descriptor,
                kCTFontURLAttribute
            ) as? URL else {
                return nil
            }
            let canonicalURL = sourceURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let initialKey = try fileCacheKey(for: canonicalURL)
            if let cached = fileDigests[initialKey] {
                return cached
            }

            let handle = try FileHandle(forReadingFrom: canonicalURL)
            defer { handle.closeFile() }
            var hasher = SHA256()
            var bytesRead = 0
            while let chunk = try handle.read(upToCount: 1_048_576),
                  !chunk.isEmpty {
                let (nextCount, overflow) = bytesRead.addingReportingOverflow(
                    chunk.count
                )
                guard !overflow else {
                    throw FontSourceReadError.changedWhileReading
                }
                bytesRead = nextCount
                hasher.update(data: chunk)
            }
            guard bytesRead == initialKey.fileSize,
                  try fileCacheKey(for: canonicalURL) == initialKey
            else {
                throw FontSourceReadError.changedWhileReading
            }
            let digest = Data(hasher.finalize())
            fileDigests[initialKey] = digest
            return digest
        }

        private func fileCacheKey(for canonicalURL: URL) throws -> FontFileCacheKey {
            let values = try canonicalURL.resourceValues(forKeys: [
                .fileResourceIdentifierKey,
                .generationIdentifierKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isRegularFileKey
            ])
            guard values.isRegularFile == true,
                  let resourceIdentifier = values.fileResourceIdentifier
                    as? AnyHashable,
                  let generationIdentifier = values.generationIdentifier
                    as? AnyHashable,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  let modificationDate = values.contentModificationDate
            else {
                throw FontSourceReadError.missingFileMetadata
            }
            return FontFileCacheKey(
                canonicalURL: canonicalURL,
                fileResourceIdentifier: resourceIdentifier,
                generationIdentifier: generationIdentifier,
                fileSize: fileSize,
                modificationTimeBits: modificationDate
                    .timeIntervalSinceReferenceDate
                    .bitPattern
            )
        }

        private func tableDigest(for font: CTFont) throws -> Data? {
            let cacheKey = FontObjectCacheKey(font: font)
            if let cached = tableDigests[cacheKey] {
                if let index = tableDigestRecency.firstIndex(of: cacheKey) {
                    tableDigestRecency.remove(at: index)
                }
                tableDigestRecency.append(cacheKey)
                return cached
            }
            guard let availableTables = CTFontCopyAvailableTables(font, []) else {
                return nil
            }
            let tableCount = CFArrayGetCount(availableTables)
            guard tableCount > 0 else { return nil }
            var tags: [CTFontTableTag] = []
            tags.reserveCapacity(tableCount)
            for index in 0..<tableCount {
                guard let rawTag = CFArrayGetValueAtIndex(
                    availableTables,
                    index
                ) else {
                    throw FontSourceReadError.invalidTableDirectory
                }
                // Core Text stores CTFontTableTag directly in pointer bits.
                let encodedTag = UInt(bitPattern: rawTag)
                guard encodedTag <= UInt(UInt32.max) else {
                    throw FontSourceReadError.invalidTableDirectory
                }
                tags.append(CTFontTableTag(encodedTag))
            }
            tags.sort()
            guard zip(tags, tags.dropFirst()).allSatisfy(!=) else {
                throw FontSourceReadError.invalidTableDirectory
            }

            var hasher = SHA256()
            var header = Data()
            AnnotationTextLayout.appendFingerprintString(
                "ushot.annotation-text-complete-font-tables.v1",
                to: &header
            )
            AnnotationTextLayout.appendFingerprintInteger(
                tags.count,
                to: &header
            )
            hasher.update(data: header)
            for tag in tags {
                guard let table = CTFontCopyTable(font, tag, []) else {
                    throw FontSourceReadError.unreadableTable(tag)
                }
                let tableData = table as Data
                var tableHeader = Data()
                AnnotationTextLayout.appendFingerprintInteger(
                    Int(tag),
                    to: &tableHeader
                )
                AnnotationTextLayout.appendFingerprintInteger(
                    tableData.count,
                    to: &tableHeader
                )
                hasher.update(data: tableHeader)
                // No per-table size cap: this fallback must cover every byte,
                // including all bitmap strikes and color representations.
                hasher.update(data: tableData)
            }
            let digest = Data(hasher.finalize())
            tableDigests[cacheKey] = digest
            tableDigestRecency.append(cacheKey)
            if tableDigestRecency.count > Self.maximumTableDigestCount {
                let evicted = tableDigestRecency.removeFirst()
                tableDigests.removeValue(forKey: evicted)
            }
            return digest
        }
    }

    private static func appendFingerprintFont(
        _ font: CTFont,
        to data: inout Data
    ) throws {
        appendFingerprintString("ushot.annotation-text-font.v1", to: &data)
        appendFingerprintString(CTFontCopyPostScriptName(font) as String, to: &data)
        appendFingerprintString(CTFontCopyFullName(font) as String, to: &data)
        appendFingerprintString(
            CTFontCopyName(font, kCTFontVersionNameKey) as String? ?? "",
            to: &data
        )
        appendFingerprintCGFloat(CTFontGetSize(font), to: &data)
        appendFingerprintTransform(CTFontGetMatrix(font), to: &data)
        appendFingerprintVariation(font, to: &data)
        appendFingerprintString(
            "ushot.annotation-text-font-source-sha256.v1",
            to: &data
        )
        let sourceDigest = try fontSourceDigestCache.digest(for: font)
        precondition(
            sourceDigest.count == SHA256.byteCount,
            "The verified font source digest must be SHA-256."
        )
        appendFingerprintInteger(sourceDigest.count, to: &data)
        data.append(sourceDigest)
    }

    private static func appendFingerprintVariation(
        _ font: CTFont,
        to data: inout Data
    ) {
        appendFingerprintString(
            "ushot.annotation-text-font-variation.v1",
            to: &data
        )
        guard let variation = CTFontCopyVariation(font) else {
            appendFingerprintInteger(0, to: &data)
            return
        }
        let dictionary = variation as NSDictionary
        let coordinates: [(identifier: UInt32, value: Double)] = dictionary.map {
            key, value in
            guard let identifier = key as? NSNumber,
                  let coordinate = value as? NSNumber,
                  coordinate.doubleValue.isFinite
            else {
                preconditionFailure(
                    "Core Text returned malformed font variation coordinates."
                )
            }
            return (identifier.uint32Value, coordinate.doubleValue)
        }.sorted { lhs, rhs in
            lhs.identifier < rhs.identifier
        }
        precondition(
            zip(coordinates, coordinates.dropFirst()).allSatisfy {
                $0.identifier != $1.identifier
            },
            "Core Text returned duplicate font variation identifiers."
        )
        appendFingerprintInteger(coordinates.count, to: &data)
        for coordinate in coordinates {
            appendFingerprintInteger(Int(coordinate.identifier), to: &data)
            appendFingerprintDouble(coordinate.value, to: &data)
        }
    }

    private static func appendFingerprintGlyphAppearance(
        _ glyph: CGGlyph,
        font: CTFont,
        to data: inout Data
    ) {
        appendFingerprintString(
            "ushot.annotation-text-glyph-appearance.v1",
            to: &data
        )
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            appendFingerprintString("outline", to: &data)
            appendFingerprintPath(path, to: &data)
            return
        }

        var mutableGlyph = glyph
        var glyphBounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(
            font,
            .default,
            &mutableGlyph,
            &glyphBounds,
            1
        )
        appendFingerprintString("no-outline", to: &data)
        if glyphBounds.isNull {
            appendFingerprintString("invisible-null-bounds", to: &data)
            return
        }
        precondition(
            glyphBounds.origin.x.isFinite
                && glyphBounds.origin.y.isFinite
                && glyphBounds.width.isFinite
                && glyphBounds.height.isFinite
                && glyphBounds.width >= 0
                && glyphBounds.height >= 0,
            "Core Text returned non-finite or negative glyph bounds."
        )
        appendFingerprintRect(glyphBounds, to: &data)
        if glyphBounds.isEmpty {
            // Spaces and non-drawing control glyphs intentionally have no ink.
            // Their glyph ID, advance, font identity/variation and this stable
            // sentinel remain bound without pretending an absent path exists.
            appendFingerprintString("invisible-empty-bounds", to: &data)
            return
        }
        // Color/bitmap fonts can select a different representation for another
        // text matrix or size. Their complete source file (or every available
        // table when no file exists) is already bound in the run-font identity,
        // so this per-glyph marker remains valid for every embedded strike and
        // color format without rasterizing one arbitrary presentation.
        appendFingerprintString("visible-source-backed-no-outline", to: &data)
    }

    /// Stable element-stream digest used both by production fingerprints and
    /// focused regression tests. The stream records an explicit element type,
    /// point count and every finite coordinate; equal bounds or glyph metrics
    /// cannot hide a changed curve.
    static func stableGlyphOutlineFingerprint(_ path: CGPath) -> String {
        var data = Data()
        appendFingerprintPath(path, to: &data)
        return fingerprintHexDigest(data)
    }

    private static func appendFingerprintPath(
        _ path: CGPath,
        to data: inout Data
    ) {
        appendFingerprintString(
            "ushot.annotation-text-glyph-outline.v1",
            to: &data
        )
        var elementData = Data()
        var elementCount = 0
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let (typeCode, pointCount): (Int, Int)
            switch element.type {
            case .moveToPoint:
                (typeCode, pointCount) = (0, 1)
            case .addLineToPoint:
                (typeCode, pointCount) = (1, 1)
            case .addQuadCurveToPoint:
                (typeCode, pointCount) = (2, 2)
            case .addCurveToPoint:
                (typeCode, pointCount) = (3, 3)
            case .closeSubpath:
                (typeCode, pointCount) = (4, 0)
            @unknown default:
                preconditionFailure("Core Graphics returned an unknown path element.")
            }
            appendFingerprintInteger(typeCode, to: &elementData)
            appendFingerprintInteger(pointCount, to: &elementData)
            for pointIndex in 0..<pointCount {
                let point = element.points[pointIndex]
                appendFingerprintCGFloat(point.x, to: &elementData)
                appendFingerprintCGFloat(point.y, to: &elementData)
            }
            elementCount += 1
        }
        appendFingerprintInteger(elementCount, to: &data)
        appendFingerprintInteger(elementData.count, to: &data)
        data.append(elementData)
    }

    private static func appendFingerprintRect(
        _ rect: CGRect,
        to data: inout Data
    ) {
        appendFingerprintCGFloat(rect.origin.x, to: &data)
        appendFingerprintCGFloat(rect.origin.y, to: &data)
        appendFingerprintCGFloat(rect.width, to: &data)
        appendFingerprintCGFloat(rect.height, to: &data)
    }

    private static func appendFingerprintTransform(
        _ transform: CGAffineTransform,
        to data: inout Data
    ) {
        appendFingerprintCGFloat(transform.a, to: &data)
        appendFingerprintCGFloat(transform.b, to: &data)
        appendFingerprintCGFloat(transform.c, to: &data)
        appendFingerprintCGFloat(transform.d, to: &data)
        appendFingerprintCGFloat(transform.tx, to: &data)
        appendFingerprintCGFloat(transform.ty, to: &data)
    }

    private static func appendFingerprintString(
        _ value: String,
        to data: inout Data
    ) {
        let bytes = Array(value.utf8)
        appendFingerprintInteger(bytes.count, to: &data)
        data.append(contentsOf: bytes)
    }

    private static func appendFingerprintInteger(
        _ value: Int,
        to data: inout Data
    ) {
        var encoded = UInt64(bitPattern: Int64(value)).bigEndian
        withUnsafeBytes(of: &encoded) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendFingerprintCGFloat(
        _ value: CGFloat,
        to data: inout Data
    ) {
        appendFingerprintDouble(Double(value), to: &data)
    }

    private static func appendFingerprintDouble(
        _ value: Double,
        to data: inout Data
    ) {
        precondition(
            value.isFinite,
            "Annotation text shape fingerprint geometry must be finite."
        )
        // Positive and negative zero are geometrically identical. Canonicalize
        // them so harmless arithmetic sign bits cannot invalidate history.
        var encoded = (value == 0 ? 0 : value).bitPattern.bigEndian
        withUnsafeBytes(of: &encoded) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func fingerprintHexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

}
