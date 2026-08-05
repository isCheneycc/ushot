import CoreGraphics
import Foundation

public struct ImageReference: Codable, Equatable, Sendable {
    public let id: UUID
    public var relativePath: String?
    public var pixelSize: CGSize
    public var colorSpaceName: String?

    public init(
        id: UUID = UUID(),
        relativePath: String? = nil,
        pixelSize: CGSize,
        colorSpaceName: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.pixelSize = pixelSize
        self.colorSpaceName = colorSpaceName
    }
}

public struct CropState: Codable, Equatable, Sendable {
    public var rect: CGRect?

    public init(rect: CGRect? = nil) {
        self.rect = rect
    }
}

public struct RotationState: Codable, Equatable, Sendable {
    public var quarterTurnsClockwise: Int

    public init(quarterTurnsClockwise: Int = 0) {
        self.quarterTurnsClockwise = ((quarterTurnsClockwise % 4) + 4) % 4
    }
}

public enum BackgroundStyle: Codable, Equatable, Sendable {
    case transparent
    case solid(RGBAColor)
    case padded(color: RGBAColor, amount: CGFloat)
}

public struct CanvasEffects: Codable, Equatable, Sendable {
    public var cornerRadius: CGFloat
    public var shadow: AnnotationShadow?

    public init(cornerRadius: CGFloat = 0, shadow: AnnotationShadow? = nil) {
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }
}

public struct AnnotationDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    /// Revision 1 produced filled arrow heads with a flat rear edge. Revision
    /// 2 uses the current paper-plane geometry for filled, double and tapered
    /// arrow heads. This is deliberately independent from `schemaVersion`: it
    /// describes the renderer that produced a cached preview bitmap, not the
    /// structure or interpretation of the editable document itself.
    public static let legacyCachedPreviewRenderRevision = 1
    public static let currentCachedPreviewRenderRevision = 2

    public let id: UUID
    public var schemaVersion: Int
    public private(set) var cachedPreviewRenderRevision: Int
    public var baseImageReference: ImageReference
    public var canvasSize: CGSize
    public var crop: CropState
    public var rotation: RotationState
    public var background: BackgroundStyle
    public var canvasEffects: CanvasEffects
    public var annotations: [AnnotationItem]

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = AnnotationDocument.currentSchemaVersion,
        cachedPreviewRenderRevision: Int = AnnotationDocument.currentCachedPreviewRenderRevision,
        baseImageReference: ImageReference,
        canvasSize: CGSize,
        crop: CropState = CropState(),
        rotation: RotationState = RotationState(),
        background: BackgroundStyle = .transparent,
        canvasEffects: CanvasEffects = CanvasEffects(),
        annotations: [AnnotationItem] = []
    ) {
        precondition(
            cachedPreviewRenderRevision >= AnnotationDocument.legacyCachedPreviewRenderRevision,
            "A cached annotation preview render revision must be positive."
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.cachedPreviewRenderRevision = cachedPreviewRenderRevision
        self.baseImageReference = baseImageReference
        self.canvasSize = canvasSize
        self.crop = crop
        self.rotation = rotation
        self.background = background
        self.canvasEffects = canvasEffects
        self.annotations = annotations
    }

    /// Whether the persisted preview can be reused by the current renderer.
    ///
    /// A legacy preview remains byte-for-byte valid when its document does not
    /// contain a visible arrow style affected by the renderer revision. Future
    /// revisions are never trusted because this build cannot know which of its
    /// drawing semantics changed.
    public var isCachedPreviewCompatibleWithCurrentRenderer: Bool {
        if cachedPreviewRenderRevision == Self.currentCachedPreviewRenderRevision {
            return true
        }
        guard cachedPreviewRenderRevision < Self.currentCachedPreviewRenderRevision else {
            return false
        }
        return annotations.allSatisfy { item in
            guard item.isVisible, item.kind == .arrow else { return true }
            switch item.style.arrowHeadStyle {
            case .open:
                return true
            case .filled, .double, .tapered:
                return false
            }
        }
    }

    /// Number of visible annotations whose cached pixels changed in the
    /// paper-plane arrow renderer revision. This is intended for privacy-safe
    /// migration logging; it never exposes annotation content or geometry.
    public var cachedPreviewRevisionAffectedAnnotationCount: Int {
        annotations.reduce(into: 0) { count, item in
            guard item.isVisible, item.kind == .arrow else { return }
            switch item.style.arrowHeadStyle {
            case .open:
                break
            case .filled, .double, .tapered:
                count += 1
            }
        }
    }

    /// Returns a persistence copy whose cached preview is known to have been
    /// produced successfully by the current renderer. Callers must invoke this
    /// only after rendering succeeds; changing the editable document's stamp
    /// before that would make a stale bitmap appear authoritative.
    public func recordingCurrentCachedPreviewRenderRevision() -> AnnotationDocument {
        var recorded = self
        recorded.cachedPreviewRenderRevision = Self.currentCachedPreviewRenderRevision
        return recorded
    }

    public var orderedAnnotations: [AnnotationItem] {
        annotations.sorted {
            if $0.zIndex == $1.zIndex { return $0.id.uuidString < $1.id.uuidString }
            return $0.zIndex < $1.zIndex
        }
    }

    public var outputLogicalSize: CGSize {
        var size = crop.rect?.standardized.size ?? canvasSize
        if rotation.quarterTurnsClockwise % 2 == 1 {
            size = CGSize(width: size.height, height: size.width)
        }
        let backgroundPadding: CGFloat
        switch background {
        case .padded(_, let amount): backgroundPadding = max(0, amount)
        default: backgroundPadding = 0
        }
        let shadowPadding: CGFloat
        if let shadow = canvasEffects.shadow {
            shadowPadding = max(0, shadow.radius * 2 + max(abs(shadow.offset.width), abs(shadow.offset.height)))
        } else {
            shadowPadding = 0
        }
        let padding = max(backgroundPadding, shadowPadding)
        return CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
    }

    /// Rewrites the legacy highlight representation that used a transparent
    /// stroke as a renderer sentinel. The stroke is the editor-facing semantic
    /// color and must remain suitable for toolbar synchronization; translucency
    /// belongs only to the highlight fill.
    @discardableResult
    public mutating func normalizeHighlightStylesForEditing() -> Int {
        var normalizedCount = 0
        for index in annotations.indices where annotations[index].kind == .highlight {
            let normalizedStyle = annotations[index].style.asHighlightStyle()
            guard normalizedStyle != annotations[index].style else { continue }
            annotations[index].style = normalizedStyle
            normalizedCount += 1
        }
        return normalizedCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case cachedPreviewRenderRevision
        case baseImageReference
        case canvasSize
        case crop
        case rotation
        case background
        case canvasEffects
        case annotations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        if container.contains(.cachedPreviewRenderRevision) {
            cachedPreviewRenderRevision = try container.decode(
                Int.self,
                forKey: .cachedPreviewRenderRevision
            )
        } else {
            cachedPreviewRenderRevision = Self.legacyCachedPreviewRenderRevision
        }
        guard cachedPreviewRenderRevision >= Self.legacyCachedPreviewRenderRevision else {
            throw DecodingError.dataCorruptedError(
                forKey: .cachedPreviewRenderRevision,
                in: container,
                debugDescription: "A cached annotation preview render revision must be positive."
            )
        }
        baseImageReference = try container.decode(ImageReference.self, forKey: .baseImageReference)
        canvasSize = try container.decode(CGSize.self, forKey: .canvasSize)
        crop = try container.decode(CropState.self, forKey: .crop)
        rotation = try container.decode(RotationState.self, forKey: .rotation)
        background = try container.decode(BackgroundStyle.self, forKey: .background)
        canvasEffects = try container.decode(CanvasEffects.self, forKey: .canvasEffects)
        annotations = try container.decode([AnnotationItem].self, forKey: .annotations)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(cachedPreviewRenderRevision, forKey: .cachedPreviewRenderRevision)
        try container.encode(baseImageReference, forKey: .baseImageReference)
        try container.encode(canvasSize, forKey: .canvasSize)
        try container.encode(crop, forKey: .crop)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(background, forKey: .background)
        try container.encode(canvasEffects, forKey: .canvasEffects)
        try container.encode(annotations, forKey: .annotations)
    }
}

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    case text
    case counter
    case mosaic
    case blur
    case highlight
    case spotlight

    /// Blur and mosaic sample pixels from their original canvas location. Moving
    /// either annotation would detach the effect from the pixels it was created
    /// to obscure, so user-initiated translation is deliberately unavailable.
    public var allowsUserTranslation: Bool {
        switch self {
        case .mosaic, .blur:
            return false
        default:
            return true
        }
    }

    /// Freehand strokes preserve the pointer path captured by the brush. Blur
    /// and mosaic likewise keep the exact source-pixel area chosen at creation
    /// time. These annotations expose no frame-scale controls.
    public var allowsUserResize: Bool {
        switch self {
        case .freehand, .mosaic, .blur:
            return false
        default:
            return true
        }
    }

    /// Text resizing changes typography rather than applying a generic frame
    /// transform. Freehand is a path-only brush, while mosaic and blur are
    /// source-anchored effects. None may enter the standard eight-handle path.
    public var usesStandardSelectionResizeHandles: Bool {
        switch self {
        case .freehand, .text, .mosaic, .blur:
            return false
        default:
            return true
        }
    }

    /// Only annotations created by the toolbar's stroked drawing tools expose
    /// the shared line-width control. Effects, text and counters may carry the
    /// field for serialization, but it is not an editable presentation value
    /// for those kinds.
    public var supportsLineWidthEditing: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .freehand:
            return true
        case .text, .counter, .mosaic, .blur, .highlight, .spotlight:
            return false
        }
    }
}

public enum AnnotationTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    case text
    case counter
    case mosaic
    case blur
    case highlight
    case spotlight
    case crop

    public var id: String { rawValue }

    /// The document kind created by this tool. Selection and crop manipulate
    /// editor state instead of creating an annotation item.
    public var annotationKind: AnnotationKind? {
        switch self {
        case .select, .crop: return nil
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .freehand: return .freehand
        case .text: return .text
        case .counter: return .counter
        case .mosaic: return .mosaic
        case .blur: return .blur
        case .highlight: return .highlight
        case .spotlight: return .spotlight
        }
    }

    /// Whether this tool creates annotations whose visual stroke thickness is
    /// controlled by the shared toolbar line-width field.
    public var supportsLineWidthEditing: Bool {
        annotationKind?.supportsLineWidthEditing == true
    }

    /// The canonical user-facing order shared by every annotation toolbar,
    /// the Canvas Editor rail, default shortcuts and shortcut settings UI.
    public static let quickToolbarOrder: [AnnotationTool] = [
        .select, .rectangle, .ellipse, .line, .arrow, .freehand,
        .text, .counter, .mosaic, .blur, .highlight, .spotlight
    ]

    public var title: String {
        switch self {
        case .select: return NSLocalizedString("Select", comment: "Annotation tool name")
        case .rectangle: return NSLocalizedString("Rectangle", comment: "Annotation tool name")
        case .ellipse: return NSLocalizedString("Circle", comment: "Annotation tool name")
        case .line: return NSLocalizedString("Line", comment: "Annotation tool name")
        case .arrow: return NSLocalizedString("Arrow", comment: "Annotation tool name")
        case .freehand: return NSLocalizedString("Freehand", comment: "Annotation tool name")
        case .text: return NSLocalizedString("Text", comment: "Annotation tool name")
        case .counter: return NSLocalizedString("Counter", comment: "Annotation tool name")
        case .mosaic: return NSLocalizedString("Mosaic", comment: "Annotation tool name")
        case .blur: return NSLocalizedString("Blur", comment: "Annotation tool name")
        case .highlight: return NSLocalizedString("Highlight", comment: "Annotation tool name")
        case .spotlight: return NSLocalizedString("Spotlight", comment: "Annotation tool name")
        case .crop: return NSLocalizedString("Crop", comment: "Annotation tool name")
        }
    }

    /// The canonical symbol mapping shared by every annotation toolbar.
    public var toolbarSystemSymbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .freehand: return "pencil.tip"
        case .text: return "character"
        case .counter: return "1.circle"
        case .mosaic: return "square.grid.3x3.fill"
        case .blur: return "drop.halffull"
        case .highlight: return "rectangle.fill"
        case .spotlight: return "light.beacon.max"
        case .crop: return "crop"
        }
    }
}

public enum AnnotationGeometry: Codable, Equatable, Sendable {
    case rect(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case path([CGPoint])

    public var boundingBox: CGRect {
        switch self {
        case .rect(let rect):
            return rect.standardized
        case .line(let start, let end):
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        case .path(let points):
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
        }
    }
}

public struct AnnotationTransform: Codable, Equatable, Sendable {
    public var translation: CGSize
    public var rotationRadians: CGFloat
    public var scaleX: CGFloat
    public var scaleY: CGFloat

    public init(
        translation: CGSize = .zero,
        rotationRadians: CGFloat = 0,
        scaleX: CGFloat = 1,
        scaleY: CGFloat = 1
    ) {
        self.translation = translation
        self.rotationRadians = rotationRadians
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
}

public enum AnnotationFontWeight: String, Codable, CaseIterable, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

public enum AnnotationTextAlignment: String, Codable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

public enum ArrowHeadStyle: String, Codable, CaseIterable, Sendable {
    case open
    case filled
    case tapered
    case double
}

public enum ShapeFillMode: String, Codable, CaseIterable, Sendable {
    case outline
    case filled
}

public enum AnnotationMeasurementUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case pixels = "px"
    case points = "pt"

    public func displayedValue(
        forLogicalPoints logicalPoints: CGFloat,
        backingScale: CGFloat
    ) -> CGFloat {
        precondition(logicalPoints.isFinite, "Annotation measurement must be finite.")
        precondition(backingScale.isFinite && backingScale > 0, "Annotation backing scale must be positive and finite.")
        switch self {
        case .pixels:
            return logicalPoints * backingScale
        case .points:
            return logicalPoints
        }
    }

    public func logicalPoints(
        fromDisplayedValue displayedValue: CGFloat,
        backingScale: CGFloat
    ) -> CGFloat {
        precondition(displayedValue.isFinite, "Displayed annotation measurement must be finite.")
        precondition(backingScale.isFinite && backingScale > 0, "Annotation backing scale must be positive and finite.")
        switch self {
        case .pixels:
            return displayedValue / backingScale
        case .points:
            return displayedValue
        }
    }

    public func convertedDisplayedValue(
        _ displayedValue: CGFloat,
        to targetUnit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) -> CGFloat {
        targetUnit.displayedValue(
            forLogicalPoints: logicalPoints(
                fromDisplayedValue: displayedValue,
                backingScale: backingScale
            ),
            backingScale: backingScale
        )
    }
}

/// Kept as a source-compatible name for integrations compiled against the
/// original line-width-only unit model.
public typealias AnnotationLineWidthUnit = AnnotationMeasurementUnit

public struct AnnotationShadow: Codable, Equatable, Sendable {
    public var color: RGBAColor
    public var radius: CGFloat
    public var offset: CGSize

    public init(
        color: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.35),
        radius: CGFloat = 10,
        offset: CGSize = CGSize(width: 0, height: -4)
    ) {
        self.color = color
        self.radius = radius
        self.offset = offset
    }
}

public struct AnnotationStyle: Codable, Equatable, Sendable {
    public static let highlightFillAlpha: CGFloat = 0.35

    public var strokeColor: RGBAColor
    public var fillColor: RGBAColor?
    public var lineWidth: CGFloat
    public var fontSize: CGFloat
    /// The exact PostScript font name used by text annotations. `nil` means
    /// the current system font, preserving the native default across OS updates.
    public var fontName: String?
    public var fontWeight: AnnotationFontWeight
    public var textAlignment: AnnotationTextAlignment
    public var arrowHeadStyle: ArrowHeadStyle
    public var blurRadius: CGFloat
    public var mosaicBlockSize: CGFloat
    public var cornerRadius: CGFloat
    public var shadow: AnnotationShadow?

    public var shapeFillMode: ShapeFillMode {
        get { fillColor == nil ? .outline : .filled }
        set {
            fillColor = newValue == .filled ? strokeColor : nil
        }
    }

    public init(
        strokeColor: RGBAColor = .systemRed,
        fillColor: RGBAColor? = nil,
        lineWidth: CGFloat = 3,
        fontSize: CGFloat = 18,
        fontName: String? = nil,
        fontWeight: AnnotationFontWeight = .semibold,
        textAlignment: AnnotationTextAlignment = .leading,
        arrowHeadStyle: ArrowHeadStyle = .filled,
        blurRadius: CGFloat = 14,
        mosaicBlockSize: CGFloat = 12,
        cornerRadius: CGFloat = 0,
        shadow: AnnotationShadow? = nil
    ) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.fontName = fontName
        self.fontWeight = fontWeight
        self.textAlignment = textAlignment
        self.arrowHeadStyle = arrowHeadStyle
        self.blurRadius = blurRadius
        self.mosaicBlockSize = mosaicBlockSize
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    /// Changes only the editor-facing semantic color. Fill colors can represent
    /// different roles (shape paint, highlight paint, or counter text), so their
    /// behavior is resolved by `applyingColor(_:for:)` instead of inferred from
    /// whether a fill happens to exist.
    public func applyingStrokeColor(_ color: RGBAColor) -> AnnotationStyle {
        var updated = self
        updated.strokeColor = color
        return updated
    }

    /// Applies an editor color according to the annotation kind's fill
    /// semantics. Filled shapes keep their fill opacity, highlights keep their
    /// fixed translucent paint, and semantic fills such as Counter's white text
    /// remain unchanged.
    public func applyingColor(
        _ color: RGBAColor,
        for kind: AnnotationKind
    ) -> AnnotationStyle {
        var updated = applyingStrokeColor(color)
        switch kind {
        case .rectangle, .ellipse:
            if let fillColor {
                updated.fillColor = color.withAlphaComponent(fillColor.alpha)
            }
        case .highlight:
            let semanticColor = color.withAlphaComponent(1)
            updated.strokeColor = semanticColor
            updated.fillColor = semanticColor.withAlphaComponent(Self.highlightFillAlpha)
        default:
            break
        }
        return updated
    }

    /// Establishes the canonical highlight invariant. Legacy highlights used
    /// `.clear` for the stroke even though the toolbar treats `strokeColor` as
    /// the semantic editing color. A transparent legacy stroke therefore maps
    /// explicitly to the built-in system yellow instead of leaking a renderer
    /// implementation detail into editor state.
    public func asHighlightStyle() -> AnnotationStyle {
        let semanticColor: RGBAColor
        if strokeColor.alpha > .ulpOfOne {
            semanticColor = strokeColor.withAlphaComponent(1)
        } else if let fillColor, fillColor.alpha > .ulpOfOne {
            semanticColor = fillColor.withAlphaComponent(1)
        } else {
            semanticColor = .systemYellow
        }
        var updated = applyingStrokeColor(semanticColor)
        updated.fillColor = semanticColor.withAlphaComponent(Self.highlightFillAlpha)
        return updated
    }
}

public struct RGBAColor: Codable, Equatable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat
    public var colorSpace: ColorSpacePreference

    public init(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat = 1,
        colorSpace: ColorSpacePreference = .sRGB
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.colorSpace = colorSpace
    }

    public func withAlphaComponent(_ alpha: CGFloat) -> RGBAColor {
        var updated = self
        updated.alpha = alpha
        return updated
    }

    public static let systemRed = RGBAColor(red: 1, green: 0.231, blue: 0.188)
    public static let systemYellow = RGBAColor(red: 1, green: 0.8, blue: 0)
    public static let yellowHighlight = systemYellow.withAlphaComponent(
        AnnotationStyle.highlightFillAlpha
    )
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

public struct AnnotationItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: AnnotationKind
    public var zIndex: Int
    public var geometry: AnnotationGeometry
    public var style: AnnotationStyle
    public var opacity: CGFloat
    public var transform: AnnotationTransform
    public var isVisible: Bool
    public var isLocked: Bool
    public var text: String?
    public var counterValue: Int?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        kind: AnnotationKind,
        zIndex: Int,
        geometry: AnnotationGeometry,
        style: AnnotationStyle = AnnotationStyle(),
        opacity: CGFloat = 1,
        transform: AnnotationTransform = AnnotationTransform(),
        isVisible: Bool = true,
        isLocked: Bool = false,
        text: String? = nil,
        counterValue: Int? = nil
    ) {
        self.id = id
        self.name = name ?? kind.rawValue.capitalized
        self.kind = kind
        self.zIndex = zIndex
        self.geometry = geometry
        self.style = style
        self.opacity = opacity
        self.transform = transform
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.text = text
        self.counterValue = counterValue
    }
}
