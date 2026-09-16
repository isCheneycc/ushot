import CoreGraphics
import Foundation

/// Built from presentation-space endpoints so scaling an annotation does not
/// distort its pen width. Rendering and selection use these same cubic paths.
struct HandDrawnArrowGeometry: Equatable, Sendable {
    struct Stroke: Equatable, Sendable {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
        let lineWidth: CGFloat

        var path: CGPath {
            let path = CGMutablePath()
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)
            return path
        }

        func point(at progress: CGFloat) -> CGPoint {
            let remainder = 1 - progress
            let a = remainder * remainder * remainder
            let b = 3 * remainder * remainder * progress
            let c = 3 * remainder * progress * progress
            let d = progress * progress * progress
            return CGPoint(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y
            )
        }

        func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
            path.copy(
                strokingWithWidth: lineWidth + 2 * max(0, tolerance),
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            ).contains(point)
        }
    }

    let shaft: Stroke
    let wings: [Stroke]

    var strokes: [Stroke] { [shaft] + wings }

    init?(start: CGPoint, tip: CGPoint, lineWidth: CGFloat, seed: UUID) {
        let dx = tip.x - start.x
        let dy = tip.y - start.y
        let length = hypot(dx, dy)
        guard start.x.isFinite, start.y.isFinite,
              tip.x.isFinite, tip.y.isFinite,
              length.isFinite, length >= 0.5,
              lineWidth.isFinite
        else { return nil }

        let unit = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        // Short arrows must retain an open head even at a large tool width.
        let penWidth = min(max(0.5, lineWidth), max(0.5, length * 0.1))
        // Keep the shaft within one pen stroke of its centerline. The narrow
        // open head supplies the hand-drawn character without duplicate marks.
        let shaftVariation = min(length * 0.0018, penWidth * 0.3)
        var variation = Variation(seed: seed)
        func position(_ distance: CGFloat, _ deviation: CGFloat) -> CGPoint {
            CGPoint(
                x: start.x + unit.x * distance + normal.x * deviation,
                y: start.y + unit.y * distance + normal.y * deviation
            )
        }
        shaft = Stroke(
            start: start,
            control1: position(
                length / 3,
                shaftVariation * variation.signedValue()
            ),
            control2: position(
                length * 2 / 3,
                shaftVariation * variation.signedValue()
            ),
            end: tip,
            lineWidth: penWidth
        )

        let tangentLength = hypot(tip.x - shaft.control2.x, tip.y - shaft.control2.y)
        let tangent = CGPoint(
            x: (tip.x - shaft.control2.x) / tangentLength,
            y: (tip.y - shaft.control2.y) / tangentLength
        )
        let headNormal = CGPoint(x: -tangent.y, y: tangent.x)
        let headLength = min(max(12, penWidth * 12), length * 0.24)
        let halfWidth = headLength * 0.34
        let sides: [CGFloat] = [-1, 1]
        var headStrokes: [Stroke] = []
        for side in sides {
            let reach = headLength * (1 + 0.04 * variation.signedValue())
            let spread = halfWidth * (1 + 0.08 * variation.signedValue()) * side
            let wingStart = CGPoint(
                x: tip.x - tangent.x * reach + headNormal.x * spread,
                y: tip.y - tangent.y * reach + headNormal.y * spread
            )
            let deviation = min(penWidth * 0.7, headLength * 0.055) * variation.signedValue()
            let wingDX = tip.x - wingStart.x
            let wingDY = tip.y - wingStart.y
            let bendX = headNormal.x * deviation
            let bendY = headNormal.y * deviation
            let control1 = CGPoint(
                x: wingStart.x + wingDX / 3 + bendX,
                y: wingStart.y + wingDY / 3 + bendY
            )
            let control2 = CGPoint(
                x: wingStart.x + wingDX * 2 / 3 + bendX * 0.6,
                y: wingStart.y + wingDY * 2 / 3 + bendY * 0.6
            )
            headStrokes.append(Stroke(
                start: wingStart,
                control1: control1,
                control2: control2,
                end: tip,
                lineWidth: penWidth * (0.98 + 0.02 * variation.signedValue())
            ))
        }
        wings = headStrokes
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        strokes.contains { $0.contains(point, tolerance: tolerance) }
    }

    private struct Variation {
        private var state: UInt64

        init(seed: UUID) {
            // Swift's Hasher is salted per process. FNV-1a plus SplitMix64
            // preserves the same pen marks across history reloads and exports.
            state = seed.uuidString.utf8.reduce(14_695_981_039_346_656_037) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
        }

        mutating func signedValue() -> CGFloat {
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            return CGFloat(value >> 11) / CGFloat(UInt64(1) << 53) * 2 - 1
        }
    }
}
