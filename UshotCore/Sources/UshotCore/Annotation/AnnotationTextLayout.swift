import AppKit
import CoreGraphics
import CoreText
import Foundation

public struct AnnotationTextLineMetrics: Equatable, Sendable {
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

/// The single source of truth for single-line annotation typography.
///
/// Annotation rectangles store an alignment anchor on the Core Text baseline.
/// Both the bitmap renderer and the native inline editor resolve their font,
/// width and baseline from this type so entering and committing text cannot
/// silently switch fonts or coordinate conventions.
public enum AnnotationTextLayout {
    /// Logical-point range supported by interactive text editing controls.
    /// Rendering remains capable of opening documents outside this range;
    /// the range only constrains new direct manipulation.
    public static let editableFontSizeRange: ClosedRange<CGFloat> = 4...96

    private static let rectangleHeightFactor: CGFloat = 1.5
    private static let baselineOffsetFromCenterFactor: CGFloat = -0.36

    public static func font(
        style: AnnotationStyle,
        size: CGFloat? = nil
    ) -> NSFont {
        let pointSize = size ?? style.fontSize
        precondition(
            pointSize.isFinite && pointSize > 0,
            "Annotation text font size must be positive and finite."
        )
        if let fontName = style.fontName {
            guard let font = NSFont(name: fontName, size: pointSize) else {
                preconditionFailure(
                    "The saved annotation font '\(fontName)' is not installed on this Mac."
                )
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

    public static func annotationRect(
        baselineAnchor: CGPoint,
        text: String,
        style: AnnotationStyle
    ) -> CGRect {
        let width = max(1, ceil(lineMetrics(for: text, style: style).width))
        let height = max(1, style.fontSize * rectangleHeightFactor)
        let x = lineOriginX(
            alignmentAnchorX: baselineAnchor.x,
            lineWidth: width,
            alignment: style.textAlignment
        )
        return CGRect(
            x: x,
            y: baselineAnchor.y
                - height / 2
                - style.fontSize * baselineOffsetFromCenterFactor,
            width: width,
            height: height
        )
    }

    public static func alignmentAnchor(
        in rect: CGRect,
        style: AnnotationStyle
    ) -> CGPoint {
        let standardized = rect.standardized
        let x: CGFloat
        switch style.textAlignment {
        case .leading: x = standardized.minX
        case .center: x = standardized.midX
        case .trailing: x = standardized.maxX
        }
        return CGPoint(
            x: x,
            y: baselineY(in: standardized, style: style)
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

    public static func baselineY(
        in rect: CGRect,
        style: AnnotationStyle
    ) -> CGFloat {
        rect.standardized.midY
            + style.fontSize * baselineOffsetFromCenterFactor
    }
}
