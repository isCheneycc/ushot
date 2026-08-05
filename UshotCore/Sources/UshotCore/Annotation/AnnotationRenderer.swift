import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

public protocol AnnotationRendering: Sendable {
    func render(
        document: AnnotationDocument,
        baseImage: CGImage,
        scale: CGFloat
    ) throws -> CGImage
}

struct ArrowShaftGeometry: Equatable, Sendable {
    let start: CGPoint
    let end: CGPoint
    let lineWidth: CGFloat
    let roundsStart: Bool
    let roundsEnd: Bool

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        let radius = lineWidth / 2 + max(0, tolerance)
        guard length > .ulpOfOne else {
            return (roundsStart || roundsEnd)
                && hypot(point.x - start.x, point.y - start.y) <= radius
        }

        let unitX = dx / length
        let unitY = dy / length
        let pointX = point.x - start.x
        let pointY = point.y - start.y
        let axialDistance = pointX * unitX + pointY * unitY
        let perpendicularDistance = abs(pointX * unitY - pointY * unitX)
        let hitTolerance = max(0, tolerance)
        if axialDistance >= -hitTolerance,
           axialDistance <= length + hitTolerance,
           perpendicularDistance <= radius {
            return true
        }
        if roundsStart,
           hypot(point.x - start.x, point.y - start.y) <= radius {
            return true
        }
        if roundsEnd,
           hypot(point.x - end.x, point.y - end.y) <= radius {
            return true
        }
        return false
    }
}

struct ArrowVectorGeometry: Equatable, Sendable {
    let start: CGPoint
    let tip: CGPoint
    let headBaseCenter: CGPoint
    let headLeft: CGPoint
    let headRight: CGPoint
    let headShaftJoin: CGPoint
    let headShaftEnd: CGPoint
    let shaftLineWidth: CGFloat
    let taperedTailLeft: CGPoint
    let taperedTailRight: CGPoint
    let taperedNeckLeft: CGPoint
    let taperedNeckRight: CGPoint

    init?(start: CGPoint, tip: CGPoint, lineWidth: CGFloat) {
        let dx = tip.x - start.x
        let dy = tip.y - start.y
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance >= 0.5 else { return nil }

        let requestedLineWidth = max(0.5, lineWidth)
        let unit = CGPoint(x: dx / distance, y: dy / distance)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let headLength = min(max(14, requestedLineWidth * 5), distance * 0.45)
        let headHalfWidth = min(
            max(6, requestedLineWidth * 2.4),
            max(2, distance * 0.25)
        )
        let headBaseCenter = CGPoint(
            x: tip.x - unit.x * headLength,
            y: tip.y - unit.y * headLength
        )
        let taperedTailHalfWidth = min(
            max(0.75, requestedLineWidth * 0.28),
            headHalfWidth * 0.55
        )
        let taperedNeckHalfWidth = min(
            max(requestedLineWidth * 0.9, headHalfWidth * 0.38),
            headHalfWidth * 0.75
        )
        let headJoinForwardOffset = min(headLength * 0.35, headHalfWidth * 0.8)
        let shaftLineWidth = min(requestedLineWidth, headHalfWidth * 0.8)

        self.start = start
        self.tip = tip
        self.headBaseCenter = headBaseCenter
        self.shaftLineWidth = shaftLineWidth
        headLeft = CGPoint(
            x: headBaseCenter.x + normal.x * headHalfWidth,
            y: headBaseCenter.y + normal.y * headHalfWidth
        )
        headRight = CGPoint(
            x: headBaseCenter.x - normal.x * headHalfWidth,
            y: headBaseCenter.y - normal.y * headHalfWidth
        )
        headShaftJoin = CGPoint(
            x: headBaseCenter.x + unit.x * headJoinForwardOffset,
            y: headBaseCenter.y + unit.y * headJoinForwardOffset
        )
        let headShaftOverlap = min(
            max(0.5, shaftLineWidth * 0.75),
            (headLength - headJoinForwardOffset) * 0.35
        )
        headShaftEnd = CGPoint(
            x: headShaftJoin.x + unit.x * headShaftOverlap,
            y: headShaftJoin.y + unit.y * headShaftOverlap
        )
        taperedTailLeft = CGPoint(
            x: start.x + normal.x * taperedTailHalfWidth,
            y: start.y + normal.y * taperedTailHalfWidth
        )
        taperedTailRight = CGPoint(
            x: start.x - normal.x * taperedTailHalfWidth,
            y: start.y - normal.y * taperedTailHalfWidth
        )
        taperedNeckLeft = CGPoint(
            x: headShaftJoin.x + normal.x * taperedNeckHalfWidth,
            y: headShaftJoin.y + normal.y * taperedNeckHalfWidth
        )
        taperedNeckRight = CGPoint(
            x: headShaftJoin.x - normal.x * taperedNeckHalfWidth,
            y: headShaftJoin.y - normal.y * taperedNeckHalfWidth
        )
    }

    var filledShaft: ArrowShaftGeometry {
        ArrowShaftGeometry(
            start: start,
            end: headShaftEnd,
            lineWidth: shaftLineWidth,
            roundsStart: hypot(tip.x - start.x, tip.y - start.y) >= shaftLineWidth / 2,
            roundsEnd: false
        )
    }

    func doubleShaft(with reverse: ArrowVectorGeometry) -> ArrowShaftGeometry {
        ArrowShaftGeometry(
            start: reverse.headShaftEnd,
            end: headShaftEnd,
            lineWidth: min(shaftLineWidth, reverse.shaftLineWidth),
            roundsStart: false,
            roundsEnd: false
        )
    }
}

public struct AnnotationVectorRenderer: Sendable {
    public init() {}

    @discardableResult
    public func draw(
        item: AnnotationItem,
        in context: CGContext,
        colorSpace: CGColorSpace,
        canvasBounds: CGRect? = nil
    ) -> Bool {
        guard handles(item.kind, canvasBounds: canvasBounds) else { return false }

        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(max(0, min(1, item.opacity)))
        if let shadow = item.style.shadow {
            context.setShadow(
                offset: shadow.offset,
                blur: shadow.radius,
                color: shadow.color.cgColor(convertedTo: colorSpace)
            )
        }
        context.setStrokeColor(item.style.strokeColor.cgColor(convertedTo: colorSpace))
        context.setLineWidth(max(0.5, item.style.lineWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let geometryTransform = transform(
            item.transform,
            around: item.geometry.boundingBox
        )

        switch (item.kind, item.geometry) {
        case (.rectangle, .rect(let rect)):
            drawRectangle(
                rect,
                style: item.style,
                transform: geometryTransform,
                context: context,
                colorSpace: colorSpace
            )
        case (.ellipse, .rect(let rect)):
            let path = transformedPath(
                CGPath(ellipseIn: rect.standardized, transform: nil),
                by: geometryTransform
            )
            context.addPath(path)
            if let fill = item.style.fillColor {
                context.setFillColor(fill.cgColor(convertedTo: colorSpace))
                context.drawPath(using: .fillStroke)
            } else {
                context.strokePath()
            }
        case (.line, .line(let start, let end)):
            drawLine(
                from: start.applying(geometryTransform),
                to: end.applying(geometryTransform),
                context: context
            )
        case (.arrow, .line(let start, let end)):
            drawArrow(
                from: start.applying(geometryTransform),
                to: end.applying(geometryTransform),
                style: item.style,
                context: context,
                colorSpace: colorSpace
            )
        case (.freehand, .path(let points)):
            drawPath(
                points.map { $0.applying(geometryTransform) },
                context: context
            )
        case (.text, .rect(let rect)):
            applyTransform(item.transform, around: item.geometry.boundingBox, to: context)
            drawText(
                item.text ?? "",
                in: rect.standardized,
                style: item.style,
                context: context,
                colorSpace: colorSpace
            )
        case (.counter, .rect(let rect)):
            applyTransform(item.transform, around: item.geometry.boundingBox, to: context)
            drawCounter(
                item.counterValue ?? 1,
                in: rect.standardized,
                style: item.style,
                context: context,
                colorSpace: colorSpace
            )
        case (.highlight, .rect(let rect)):
            applyTransform(item.transform, around: item.geometry.boundingBox, to: context)
            context.setFillColor((item.style.fillColor ?? .yellowHighlight).cgColor(convertedTo: colorSpace))
            context.fill(rect.standardized)
        case (.spotlight, .rect(let rect)):
            guard let canvasBounds else { return false }
            let path = CGMutablePath()
            path.addRect(canvasBounds.standardized)
            path.addPath(transformedPath(
                CGPath(rect: rect.standardized, transform: nil),
                by: geometryTransform
            ))
            context.addPath(path)
            context.setFillColor(
                RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.62).cgColor(convertedTo: colorSpace)
            )
            context.drawPath(using: .eoFill)
        default:
            return false
        }
        return true
    }

    private func handles(_ kind: AnnotationKind, canvasBounds: CGRect?) -> Bool {
        switch kind {
        case .rectangle, .ellipse, .line, .arrow, .freehand, .text, .counter, .highlight:
            return true
        case .spotlight:
            return canvasBounds != nil
        default:
            return false
        }
    }

    private func drawRectangle(
        _ rect: CGRect,
        style: AnnotationStyle,
        transform: CGAffineTransform,
        context: CGContext,
        colorSpace: CGColorSpace
    ) {
        let path = transformedPath(
            CGPath(
                roundedRect: rect.standardized,
                cornerWidth: max(0, style.cornerRadius),
                cornerHeight: max(0, style.cornerRadius),
                transform: nil
            ),
            by: transform
        )
        context.addPath(path)
        if let fill = style.fillColor {
            context.setFillColor(fill.cgColor(convertedTo: colorSpace))
            context.drawPath(using: .fillStroke)
        } else {
            context.strokePath()
        }
    }

    private func drawLine(from start: CGPoint, to end: CGPoint, context: CGContext) {
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        style: AnnotationStyle,
        context: CGContext,
        colorSpace: CGColorSpace
    ) {
        guard let geometry = ArrowVectorGeometry(
            start: start,
            tip: end,
            lineWidth: max(0.5, style.lineWidth)
        ) else { return }
        let fillColor = style.strokeColor.cgColor(convertedTo: colorSpace)

        switch style.arrowHeadStyle {
        case .open:
            drawLine(from: geometry.start, to: geometry.tip, context: context)
            context.beginPath()
            context.move(to: geometry.headLeft)
            context.addLine(to: geometry.tip)
            context.addLine(to: geometry.headRight)
            context.strokePath()
        case .filled:
            drawArrowShaft(geometry.filledShaft, color: fillColor, context: context)
            fillArrowHead(geometry, color: fillColor, context: context)
        case .tapered:
            context.beginPath()
            context.move(to: geometry.taperedTailLeft)
            context.addLine(to: geometry.taperedNeckLeft)
            context.addLine(to: geometry.headLeft)
            context.addLine(to: geometry.tip)
            context.addLine(to: geometry.headRight)
            context.addLine(to: geometry.taperedNeckRight)
            context.addLine(to: geometry.taperedTailRight)
            context.closePath()
            context.setFillColor(fillColor)
            context.fillPath()
        case .double:
            if let reverse = ArrowVectorGeometry(
                start: geometry.tip,
                tip: geometry.start,
                lineWidth: max(0.5, style.lineWidth)
            ) {
                drawArrowShaft(
                    geometry.doubleShaft(with: reverse),
                    color: fillColor,
                    context: context
                )
                fillArrowHead(geometry, color: fillColor, context: context)
                fillArrowHead(reverse, color: fillColor, context: context)
            }
        }
    }

    private func drawArrowShaft(
        _ shaft: ArrowShaftGeometry,
        color: CGColor,
        context: CGContext
    ) {
        let dx = shaft.end.x - shaft.start.x
        let dy = shaft.end.y - shaft.start.y
        let length = hypot(dx, dy)
        let radius = shaft.lineWidth / 2
        let path = CGMutablePath()
        if length > .ulpOfOne {
            let angle = atan2(dy, dx)
            let normalX = -sin(angle) * radius
            let normalY = cos(angle) * radius
            let startLeft = CGPoint(x: shaft.start.x + normalX, y: shaft.start.y + normalY)
            let endLeft = CGPoint(x: shaft.end.x + normalX, y: shaft.end.y + normalY)
            let endRight = CGPoint(x: shaft.end.x - normalX, y: shaft.end.y - normalY)
            let startRight = CGPoint(x: shaft.start.x - normalX, y: shaft.start.y - normalY)
            path.move(to: startLeft)
            path.addLine(to: endLeft)
            if shaft.roundsEnd {
                path.addArc(
                    center: shaft.end,
                    radius: radius,
                    startAngle: angle + .pi / 2,
                    endAngle: angle - .pi / 2,
                    clockwise: true
                )
            } else {
                path.addLine(to: endRight)
            }
            path.addLine(to: startRight)
            if shaft.roundsStart {
                path.addArc(
                    center: shaft.start,
                    radius: radius,
                    startAngle: angle - .pi / 2,
                    endAngle: angle + .pi / 2,
                    clockwise: true
                )
            } else {
                path.addLine(to: startLeft)
            }
            path.closeSubpath()
        } else if shaft.roundsStart || shaft.roundsEnd {
            path.addEllipse(in: CGRect(
                x: shaft.start.x - radius,
                y: shaft.start.y - radius,
                width: shaft.lineWidth,
                height: shaft.lineWidth
            ))
        }
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    private func fillArrowHead(
        _ geometry: ArrowVectorGeometry,
        color: CGColor,
        context: CGContext
    ) {
        context.beginPath()
        context.move(to: geometry.headLeft)
        context.addLine(to: geometry.tip)
        context.addLine(to: geometry.headRight)
        context.addLine(to: geometry.headShaftJoin)
        context.closePath()
        context.setFillColor(color)
        context.fillPath()
    }

    private func drawPath(_ points: [CGPoint], context: CGContext) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        style: AnnotationStyle,
        context: CGContext,
        colorSpace: CGColorSpace
    ) {
        guard !text.isEmpty else { return }
        let font = AnnotationTextLayout.font(style: style)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.strokeColor.cgColor(convertedTo: colorSpace)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let lineWidth = AnnotationTextLayout.lineMetrics(
            for: text,
            style: style
        ).width
        let x = AnnotationTextLayout.lineOriginX(
            in: rect,
            lineWidth: lineWidth,
            alignment: style.textAlignment
        )
        context.textPosition = CGPoint(
            x: x,
            y: AnnotationTextLayout.baselineY(in: rect, style: style)
        )
        CTLineDraw(line, context)
    }

    private func drawCounter(
        _ value: Int,
        in rect: CGRect,
        style: AnnotationStyle,
        context: CGContext,
        colorSpace: CGColorSpace
    ) {
        context.setFillColor(style.strokeColor.cgColor(convertedTo: colorSpace))
        context.fillEllipse(in: rect)
        var textStyle = style
        textStyle.strokeColor = style.fillColor ?? .white
        textStyle.fontSize = min(rect.width, rect.height) * 0.52
        textStyle.textAlignment = .center
        drawText("\(value)", in: rect, style: textStyle, context: context, colorSpace: colorSpace)
    }

    private func applyTransform(
        _ transform: AnnotationTransform,
        around bounds: CGRect,
        to context: CGContext
    ) {
        context.concatenate(self.transform(transform, around: bounds))
    }

    private func transform(
        _ transform: AnnotationTransform,
        around bounds: CGRect
    ) -> CGAffineTransform {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var result = CGAffineTransform.identity
        result = result.translatedBy(
            x: center.x + transform.translation.width,
            y: center.y + transform.translation.height
        )
        result = result.rotated(by: transform.rotationRadians)
        result = result.scaledBy(x: transform.scaleX, y: transform.scaleY)
        result = result.translatedBy(x: -center.x, y: -center.y)
        return result
    }

    private func transformedPath(
        _ path: CGPath,
        by transform: CGAffineTransform
    ) -> CGPath {
        var transform = transform
        guard let transformed = path.copy(using: &transform) else {
            preconditionFailure("An annotation path could not apply its presentation transform.")
        }
        return transformed
    }
}

public struct AnnotationRenderer: AnnotationRendering {
    private let vectorRenderer = AnnotationVectorRenderer()
    private let effects = AnnotationEffectRenderer()

    public init() {}

    public func render(
        document: AnnotationDocument,
        baseImage: CGImage,
        scale: CGFloat
    ) throws -> CGImage {
        guard document.schemaVersion == AnnotationDocument.currentSchemaVersion else {
            throw ScreenshotAppError.exportFailed(
                description: "Unsupported annotation schema version \(document.schemaVersion)."
            )
        }
        guard scale > 0, document.canvasSize.width > 0, document.canvasSize.height > 0 else {
            throw ScreenshotAppError.exportFailed(description: "The annotation canvas has an invalid size.")
        }

        let colorSpace = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let width = Int(ceil(document.canvasSize.width * scale))
        let height = Int(ceil(document.canvasSize.height * scale))
        let context = try makeContext(width: width, height: height, colorSpace: colorSpace)
        context.scaleBy(x: scale, y: scale)
        drawImagePreservingPixelOrientation(
            baseImage,
            in: CGRect(origin: .zero, size: document.canvasSize),
            context: context
        )

        for item in document.orderedAnnotations where item.isVisible {
            draw(item: item, baseImage: baseImage, canvasSize: document.canvasSize, in: context, colorSpace: colorSpace)
        }

        guard var rendered = context.makeImage() else {
            throw ScreenshotAppError.exportFailed(description: "The annotation bitmap could not be finalized.")
        }
        var logicalSize = document.canvasSize

        if let crop = document.crop.rect?.standardized {
            let bounded = crop.intersection(CGRect(origin: .zero, size: document.canvasSize))
            guard bounded.width >= 1, bounded.height >= 1 else {
                throw ScreenshotAppError.exportFailed(description: "The crop rectangle is outside the canvas.")
            }
            let pixelCrop = CGRect(
                x: floor(bounded.minX * scale),
                y: floor((document.canvasSize.height - bounded.maxY) * scale),
                width: ceil(bounded.width * scale),
                height: ceil(bounded.height * scale)
            ).intersection(CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
            guard let cropped = rendered.cropping(to: pixelCrop) else {
                throw ScreenshotAppError.exportFailed(description: "The cropped image could not be created.")
            }
            rendered = cropped
            logicalSize = bounded.size
        }

        let turns = document.rotation.quarterTurnsClockwise
        if turns != 0 {
            rendered = try rotate(rendered, quarterTurnsClockwise: turns, colorSpace: colorSpace)
            if turns % 2 == 1 {
                logicalSize = CGSize(width: logicalSize.height, height: logicalSize.width)
            }
        }

        return try applyCanvasEffects(
            to: rendered,
            logicalSize: logicalSize,
            document: document,
            scale: scale,
            colorSpace: colorSpace
        )
    }

    private func draw(
        item: AnnotationItem,
        baseImage: CGImage,
        canvasSize: CGSize,
        in context: CGContext,
        colorSpace: CGColorSpace
    ) {
        if vectorRenderer.draw(
            item: item,
            in: context,
            colorSpace: colorSpace,
            canvasBounds: CGRect(origin: .zero, size: canvasSize)
        ) {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(max(0, min(1, item.opacity)))
        applyTransform(item.transform, around: item.geometry.boundingBox, to: context)
        if let shadow = item.style.shadow {
            context.setShadow(
                offset: shadow.offset,
                blur: shadow.radius,
                color: shadow.color.cgColor(convertedTo: colorSpace)
            )
        }

        let stroke = item.style.strokeColor.cgColor(convertedTo: colorSpace)
        context.setStrokeColor(stroke)
        context.setLineWidth(max(0.5, item.style.lineWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch (item.kind, item.geometry) {
        case (.blur, .rect(let rect)):
            drawEffect(
                effects.blurred(baseImage, radius: item.style.blurRadius),
                clippedTo: rect.standardized,
                canvasSize: canvasSize,
                context: context
            )
        case (.mosaic, .rect(let rect)):
            drawEffect(
                effects.mosaiced(baseImage, blockSize: item.style.mosaicBlockSize),
                clippedTo: rect.standardized,
                canvasSize: canvasSize,
                context: context
            )
        default:
            break
        }
    }

    private func drawEffect(
        _ image: CGImage?,
        clippedTo rect: CGRect,
        canvasSize: CGSize,
        context: CGContext
    ) {
        guard let image else { return }
        context.saveGState()
        context.clip(to: rect)
        drawImagePreservingPixelOrientation(
            image,
            in: CGRect(origin: .zero, size: canvasSize),
            context: context
        )
        context.restoreGState()
    }

    private func applyTransform(
        _ transform: AnnotationTransform,
        around bounds: CGRect,
        to context: CGContext
    ) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.translateBy(
            x: center.x + transform.translation.width,
            y: center.y + transform.translation.height
        )
        context.rotate(by: transform.rotationRadians)
        context.scaleBy(x: transform.scaleX, y: transform.scaleY)
        context.translateBy(x: -center.x, y: -center.y)
    }

    private func applyCanvasEffects(
        to image: CGImage,
        logicalSize: CGSize,
        document: AnnotationDocument,
        scale: CGFloat,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        let backgroundPadding: CGFloat
        switch document.background {
        case .padded(_, let amount): backgroundPadding = max(0, amount)
        default: backgroundPadding = 0
        }
        let shadowPadding: CGFloat
        if let shadow = document.canvasEffects.shadow {
            shadowPadding = max(0, shadow.radius * 2 + max(abs(shadow.offset.width), abs(shadow.offset.height)))
        } else {
            shadowPadding = 0
        }
        let padding = max(backgroundPadding, shadowPadding)
        guard padding > 0 || document.canvasEffects.cornerRadius > 0 || document.background != .transparent else {
            return image
        }

        let outputWidth = Int(ceil((logicalSize.width + padding * 2) * scale))
        let outputHeight = Int(ceil((logicalSize.height + padding * 2) * scale))
        let context = try makeContext(width: outputWidth, height: outputHeight, colorSpace: colorSpace)
        let contentRect = CGRect(
            x: padding * scale,
            y: padding * scale,
            width: logicalSize.width * scale,
            height: logicalSize.height * scale
        )

        switch document.background {
        case .transparent:
            context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        case .solid(let color), .padded(let color, _):
            context.setFillColor(color.cgColor(convertedTo: colorSpace))
            context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        }

        if let shadow = document.canvasEffects.shadow {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: shadow.offset.width * scale, height: shadow.offset.height * scale),
                blur: shadow.radius * scale,
                color: shadow.color.cgColor(convertedTo: colorSpace)
            )
            context.setFillColor(RGBAColor.black.cgColor(convertedTo: colorSpace))
            context.addPath(
                CGPath(
                    roundedRect: contentRect,
                    cornerWidth: document.canvasEffects.cornerRadius * scale,
                    cornerHeight: document.canvasEffects.cornerRadius * scale,
                    transform: nil
                )
            )
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        let clip = CGPath(
            roundedRect: contentRect,
            cornerWidth: document.canvasEffects.cornerRadius * scale,
            cornerHeight: document.canvasEffects.cornerRadius * scale,
            transform: nil
        )
        context.addPath(clip)
        context.clip()
        drawImagePreservingPixelOrientation(image, in: contentRect, context: context)
        context.restoreGState()

        guard let result = context.makeImage() else {
            throw ScreenshotAppError.exportFailed(description: "Canvas effects could not be finalized.")
        }
        return result
    }

    private func rotate(
        _ image: CGImage,
        quarterTurnsClockwise turns: Int,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        let turns = ((turns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let outputWidth = turns % 2 == 1 ? image.height : image.width
        let outputHeight = turns % 2 == 1 ? image.width : image.height
        let context = try makeContext(width: outputWidth, height: outputHeight, colorSpace: colorSpace)
        switch turns {
        case 1:
            context.translateBy(x: CGFloat(outputWidth), y: 0)
            context.rotate(by: .pi / 2)
        case 2:
            context.translateBy(x: CGFloat(outputWidth), y: CGFloat(outputHeight))
            context.rotate(by: .pi)
        case 3:
            context.translateBy(x: 0, y: CGFloat(outputHeight))
            context.rotate(by: -.pi / 2)
        default:
            break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else {
            throw ScreenshotAppError.exportFailed(description: "Rotation could not be finalized.")
        }
        return result
    }

    private func makeContext(
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) throws -> CGContext {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ScreenshotAppError.exportFailed(description: "A render context could not be created.")
        }
        return context
    }

    private func drawImagePreservingPixelOrientation(
        _ image: CGImage,
        in rect: CGRect,
        context: CGContext
    ) {
        context.draw(image, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    }

}

public final class AnnotationEffectRenderer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: true])

    public init() {}

    public func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(1, radius), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return context.createCGImage(output, from: input.extent)
    }

    public func mosaiced(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(2, blockSize), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return context.createCGImage(output, from: input.extent)
    }
}

private extension RGBAColor {
    func cgColor(convertedTo destination: CGColorSpace) -> CGColor {
        let sourceSpace: CGColorSpace
        switch colorSpace {
        case .sRGB:
            sourceSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3:
            sourceSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        case .genericRGB:
            sourceSpace = NSColorSpace.genericRGB.cgColorSpace!
        case .adobeRGB1998:
            sourceSpace = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        }
        let source = CGColor(
            colorSpace: sourceSpace,
            components: [red, green, blue, alpha]
        ) ?? CGColor(gray: 0, alpha: alpha)
        return source.converted(to: destination, intent: .relativeColorimetric, options: nil) ?? source
    }
}
