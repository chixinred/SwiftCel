import Foundation
import CoreGraphics

/// Marks a keyframe as the start of a tween: the frames up to the next keyframe on the
/// same layer are worked out by blending the two.
struct Tween: Codable {
    /// "linear", "in", "out", "inOut", or "custom" (then `curve` holds the shape)
    var ease: String = "linear"
    /// A custom easing curve as two control points: x1, y1, x2, y2. Time runs along x
    /// from 0 to 1 and progress along y; y may go below 0 or above 1 to overshoot.
    var curve: [CGFloat]? = nil
}

enum Tweening {
    static let eases: [(id: String, title: String)] = [
        ("linear", "Linear"),
        ("in", "Ease In"),
        ("out", "Ease Out"),
        ("inOut", "Ease In and Out")
    ]

    /// Maps progress 0...1 through an easing curve.
    static func ease(_ kind: String, _ t: CGFloat) -> CGFloat {
        let x = max(0, min(1, t))
        switch kind {
        case "in":
            return x * x
        case "out":
            return 1 - (1 - x) * (1 - x)
        case "inOut":
            return x * x * (3 - 2 * x)
        default:
            return x
        }
    }

    /// The easing as a curve: the two control points of a cubic from (0,0) to (1,1).
    static func bezier(for tween: Tween) -> [CGFloat] {
        switch tween.ease {
        case "in":
            return [0.42, 0, 1, 1]
        case "out":
            return [0, 0, 0.58, 1]
        case "inOut":
            return [0.42, 0, 0.58, 1]
        case "custom":
            if let c = tween.curve, c.count == 4 { return c }
            return [0, 0, 1, 1]
        default:
            return [0, 0, 1, 1]
        }
    }

    /// Progress at time `t` along a curve given by its control points.
    static func cubic(_ c: [CGFloat], _ t: CGFloat) -> CGFloat {
        guard c.count == 4 else { return t }
        let x = max(0, min(1, t))
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let x1 = max(0, min(1, c[0]))
        let x2 = max(0, min(1, c[2]))
        // Find the curve parameter whose x matches the time; x only ever increases.
        var lo: CGFloat = 0
        var hi: CGFloat = 1
        var s: CGFloat = x
        for _ in 0..<28 {
            s = (lo + hi) / 2
            let inv = 1 - s
            let bx = 3 * inv * inv * s * x1 + 3 * inv * s * s * x2 + s * s * s
            if bx < x { lo = s } else { hi = s }
        }
        let inv = 1 - s
        return 3 * inv * inv * s * c[1] + 3 * inv * s * s * c[3] + s * s * s
    }

    /// How far along a tween is at time `t` (0...1), following its easing.
    static func progress(_ tween: Tween, _ t: CGFloat) -> CGFloat {
        if tween.ease == "linear" { return max(0, min(1, t)) }
        return cubic(bezier(for: tween), t)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        return a + (b - a) * t
    }

    /// Blends the art of two keyframes. Symbol and bitmap copies are paired up by which
    /// library item they are (first with first, second with second) and moved, scaled,
    /// rotated and faded between their two states. Loose fills simply hold.
    static func blend(_ from: [Shape], _ to: [Shape], t: CGFloat) -> [Shape] {
        var pool: [String: [Shape]] = [:]
        for s in to {
            if let r = s.ref {
                pool[r, default: []].append(s)
            }
        }
        var seen: [String: Int] = [:]
        var out: [Shape] = []
        for s in from {
            guard let r = s.ref else {
                out.append(s)
                continue
            }
            let n = seen[r, default: 0]
            seen[r] = n + 1
            if let partners = pool[r], n < partners.count {
                out.append(mix(s, partners[n], t: t))
            } else {
                out.append(s)
            }
        }
        return out
    }

    private static func mix(_ a: Shape, _ b: Shape, t: CGFloat) -> Shape {
        let ma = a.transform
        let mb = b.transform
        let detA = ma.a * ma.d - ma.b * ma.c
        let detB = mb.a * mb.d - mb.b * mb.c
        if abs(detA) < 1e-9 || abs(detB) < 1e-9 { return a }

        // Split each transform into rotation and scale. A flip shows up as negative height.
        let sxA = hypot(ma.a, ma.b)
        let sxB = hypot(mb.a, mb.b)
        if sxA < 1e-9 || sxB < 1e-9 { return a }
        let syA = detA / sxA
        let syB = detB / sxB
        // Slant: how far the second axis leans along the first.
        let shA = (ma.a * ma.c + ma.b * ma.d) / sxA
        let shB = (mb.a * mb.c + mb.b * mb.d) / sxB
        let rotA = atan2(ma.b, ma.a)
        var turn = atan2(mb.b, mb.a) - rotA
        // Take the short way round.
        while turn > CGFloat.pi { turn -= 2 * CGFloat.pi }
        while turn < -CGFloat.pi { turn += 2 * CGFloat.pi }

        let rot = rotA + turn * t
        let sx = lerp(sxA, sxB, t)
        let sy = lerp(syA, syB, t)
        let sh = lerp(shA, shB, t)

        // Travel in a straight line between the two centres, so a copy that turns as it
        // moves doesn't swing off course.
        let boxA = a.path.boundingBoxOfPath
        let boxB = b.path.boundingBoxOfPath
        let centre = CGPoint(x: lerp(boxA.midX, boxB.midX, t), y: lerp(boxA.midY, boxB.midY, t))
        let local = CGPoint(x: boxA.midX, y: boxA.midY).applying(ma.inverted())

        let ca = cos(rot)
        let sa = sin(rot)
        let m11 = sx * ca
        let m12 = sx * sa
        let m21 = -sy * sa + sh * ca
        let m22 = sy * ca + sh * sa
        let tx = centre.x - (m11 * local.x + m21 * local.y)
        let ty = centre.y - (m12 * local.x + m22 * local.y)
        let m = CGAffineTransform(a: m11, b: m12, c: m21, d: m22, tx: tx, ty: ty)

        var out = a
        var carry = ma.inverted().concatenating(m)
        if let moved = a.path.copy(using: &carry) {
            out.path = moved
        }
        out.m = [m.a, m.b, m.c, m.d, m.tx, m.ty]
        out.color.a = lerp(a.color.a, b.color.a, t)
        return out
    }
}
