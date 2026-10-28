import CoreGraphics
import SwiftUI

/// The bubble outline (story 40): a closed Catmull-Rom spline through the radial factors of
/// `BlobGeometry.outline` (points evenly spaced counter-clockwise from +x), so it is a soft drop with no
/// corners or straight cuts. The jelly squash and the spin are baked into the points; everything is an
/// affine map of a smooth curve, so the result stays smooth.
enum BlobPath {
    /// - Parameters:
    ///   - center, radius: where and how big, in the caller's space (the layer renderer is y-up).
    ///   - squash: ±0.08 along `squashAngle`; `rotation` spins the outline (radians).
    ///   - scale: extra uniform scale around the centre (pulse ring, hover).
    static func make(outline: [Double], center: CGPoint, radius: CGFloat, squash: Double = 0,
                     squashAngle: Double = 0, rotation: Double = 0, scale: CGFloat = 1) -> CGPath {
        let path = CGMutablePath()
        add(to: path, outline: outline, center: center, radius: radius, squash: squash,
            squashAngle: squashAngle, rotation: rotation, scale: scale)
        return path
    }

    static func add(to path: CGMutablePath, outline: [Double], center: CGPoint, radius: CGFloat, squash: Double = 0,
                    squashAngle: Double = 0, rotation: Double = 0, scale: CGFloat = 1) {
        let factors = outline.count >= 3 ? outline : Array(repeating: 1, count: 10)
        let n = factors.count
        // Prototype order: rotate(sa) · scale(1 + sq, 1 − sq) · rotate(−sa + rot), around the centre.
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: squashAngle)
            .scaledBy(x: 1 + squash, y: 1 - squash)
            .rotated(by: -squashAngle + rotation)
            .scaledBy(x: radius * scale, y: radius * scale)
        let points: [CGPoint] = factors.enumerated().map { i, f in
            let a = Double(i) / Double(n) * 2 * .pi
            return CGPoint(x: cos(a) * f, y: sin(a) * f).applying(transform)
        }
        func p(_ i: Int) -> CGPoint { points[(i % n + n) % n] }
        path.move(to: p(0))
        for i in 0..<n {
            let p0 = p(i - 1), p1 = p(i), p2 = p(i + 1), p3 = p(i + 2)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
    }

    /// The farthest the outline can reach from the centre, as a multiple of the radius (plus spline overshoot).
    static func reach(outline: [Double], squash: Double, scale: CGFloat = 1) -> CGFloat {
        CGFloat((outline.max() ?? 1) * (1 + abs(squash)) * 1.02) * scale
    }
}

/// SwiftUI wrapper of `BlobPath` for views that need the outline as a `Shape` (y-down; fits the rect).
struct BlobShape: Shape {
    var outline: [Double] = Array(repeating: 1, count: 10)
    var squash: Double = 0
    var squashAngle: Double = 0
    var rotation: Double = 0

    func path(in rect: CGRect) -> Path {
        Path(BlobPath.make(outline: outline, center: CGPoint(x: rect.midX, y: rect.midY),
                           radius: min(rect.width, rect.height) / 2, squash: squash,
                           squashAngle: squashAngle, rotation: rotation))
    }
}
