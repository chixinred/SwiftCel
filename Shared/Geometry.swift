import Foundation
import CoreGraphics

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { return CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { return CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { return CGPoint(x: a.x * s, y: a.y * s) }

    var length: CGFloat { return hypot(x, y) }

    var unit: CGPoint {
        let l = length
        return l > 1e-9 ? CGPoint(x: x / l, y: y / l) : CGPoint(x: 1, y: 0)
    }
}

struct StrokePoint {
    var p: CGPoint
    var r: CGFloat
}

/// The brush: paint a fat filled shape, then on release re-fit its outline with a
/// handful of quadratic curves. The two sides of a stroke are fitted independently,
/// which is where the slightly lumpy, tapered, wobbly look comes from.
enum Brush {

    // MARK: Raw stroke

    /// One brush dab swept from `a` to `b`, as a closed polygon. Every dab winds the
    /// same way, so filling or normalising with the winding rule gives their union.
    static func addDab(_ path: CGMutablePath, from a: StrokePoint, to b: StrokePoint) {
        let steps = 10
        let d = b.p - a.p
        if d.length < 1e-4 {
            let r = max(a.r, b.r)
            let n = steps * 2
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n) * 2 * CGFloat.pi
                let q = CGPoint(x: a.p.x + cos(t) * r, y: a.p.y + sin(t) * r)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
            return
        }
        let ang = atan2(d.y, d.x)
        for i in 0...steps {
            let t = ang + CGFloat.pi / 2 + CGFloat(i) / CGFloat(steps) * CGFloat.pi
            let q = CGPoint(x: a.p.x + cos(t) * a.r, y: a.p.y + sin(t) * a.r)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        for i in 0...steps {
            let t = ang - CGFloat.pi / 2 + CGFloat(i) / CGFloat(steps) * CGFloat.pi
            let q = CGPoint(x: b.p.x + cos(t) * b.r, y: b.p.y + sin(t) * b.r)
            path.addLine(to: q)
        }
        path.closeSubpath()
    }

    static func rawPath(_ pts: [StrokePoint]) -> CGPath {
        let path = CGMutablePath()
        if pts.count == 1 {
            addDab(path, from: pts[0], to: pts[0])
        } else if pts.count > 1 {
            for i in 1..<pts.count {
                addDab(path, from: pts[i - 1], to: pts[i])
            }
        }
        return path
    }

    /// Light 1-2-1 averaging of the pointer path, to calm hand and sensor jitter.
    static func smoothInput(_ input: [StrokePoint], passes: Int) -> [StrokePoint] {
        var pts = input
        if pts.count < 3 || passes < 1 { return pts }
        for _ in 0..<passes {
            let src = pts
            for i in 1..<(src.count - 1) {
                let x = (src[i - 1].p.x + 2 * src[i].p.x + src[i + 1].p.x) / 4
                let y = (src[i - 1].p.y + 2 * src[i].p.y + src[i + 1].p.y) / 4
                let r = (src[i - 1].r + 2 * src[i].r + src[i + 1].r) / 4
                pts[i] = StrokePoint(p: CGPoint(x: x, y: y), r: r)
            }
        }
        return pts
    }

    // MARK: Spray texture (pencil)

    /// Scatters one-pixel specks around the segment from `a` to `b`, denser toward the
    /// middle. Specks sit on the pixel grid and `seen` stops the same pixel being added
    /// twice, so a stroke never holds more specks than the area it covers.
    static func addSpray(_ path: CGMutablePath, from a: CGPoint, to b: CGPoint, radius: CGFloat,
                         seen: inout Set<Int64>) {
        let r = max(0.5, radius)
        let dist = (b - a).length
        let step = max(0.5, r * 0.3)
        let steps = max(1, Int((dist / step).rounded(.up)))
        let perStep = max(2, Int((2.0 * r * step).rounded()))
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let cx = a.x + (b.x - a.x) * t
            let cy = a.y + (b.y - a.y) * t
            for _ in 0..<perStep {
                let ang = CGFloat.random(in: 0..<(2 * CGFloat.pi))
                let rad = r * pow(CGFloat.random(in: 0...1), 0.7)
                let x = (cx + cos(ang) * rad).rounded(.down)
                let y = (cy + sin(ang) * rad).rounded(.down)
                let key = (Int64(x) << 32) ^ (Int64(y) & 0xFFFF_FFFF)
                if seen.insert(key).inserted {
                    path.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }

    // MARK: Outline handling

    static func contours(of path: CGPath) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var cur: [CGPoint] = []
        func flush() {
            if let f = cur.first, let l = cur.last, cur.count > 1, (f - l).length < 1e-6 {
                cur.removeLast()
            }
            if cur.count > 2 { out.append(cur) }
            cur = []
        }
        path.applyWithBlock { ep in
            let e = ep.pointee
            switch e.type {
            case .moveToPoint:
                flush()
                cur.append(e.points[0])
            case .addLineToPoint:
                cur.append(e.points[0])
            case .addQuadCurveToPoint:
                cur.append(e.points[1])
            case .addCurveToPoint:
                cur.append(e.points[2])
            case .closeSubpath:
                flush()
            @unknown default:
                break
            }
        }
        flush()
        return out
    }

    static func area(_ pts: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        let n = pts.count
        if n < 3 { return 0 }
        for i in 0..<n {
            let a = pts[i]
            let b = pts[(i + 1) % n]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Ramer-Douglas-Peucker: keep only the points that stray more than `eps` from the chord.
    static func rdp(_ pts: [CGPoint], eps: CGFloat) -> [CGPoint] {
        let n = pts.count
        if n < 3 { return pts }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[n - 1] = true
        var stack: [(Int, Int)] = [(0, n - 1)]
        while let top = stack.popLast() {
            let a = top.0
            let b = top.1
            if b <= a + 1 { continue }
            let pa = pts[a]
            let pb = pts[b]
            let dx = pb.x - pa.x
            let dy = pb.y - pa.y
            let len = hypot(dx, dy)
            var best: CGFloat = -1
            var bi = -1
            for i in (a + 1)..<b {
                let p = pts[i]
                let dist: CGFloat
                if len > 1e-9 {
                    dist = abs((p.x - pa.x) * dy - (p.y - pa.y) * dx) / len
                } else {
                    dist = hypot(p.x - pa.x, p.y - pa.y)
                }
                if dist > best {
                    best = dist
                    bi = i
                }
            }
            if best > eps && bi >= 0 {
                keep[bi] = true
                stack.append((a, bi))
                stack.append((bi, b))
            }
        }
        var out: [CGPoint] = []
        for i in 0..<n where keep[i] {
            out.append(pts[i])
        }
        return out
    }

    static func simplifyClosed(_ pts: [CGPoint], eps: CGFloat) -> [CGPoint] {
        let n = pts.count
        if n < 8 { return pts }
        var far = 0
        var farDist: CGFloat = -1
        for i in 0..<n {
            let d = (pts[i] - pts[0]).length
            if d > farDist {
                farDist = d
                far = i
            }
        }
        if far == 0 { return pts }
        let first = rdp(Array(pts[0...far]), eps: eps)
        let second = rdp(Array(pts[far...]) + [pts[0]], eps: eps)
        return Array(first.dropLast()) + Array(second.dropLast())
    }

    /// Tangents in and out of each anchor. Gentle turns get one shared tangent (smooth);
    /// turns sharper than `cornerDeg` keep a corner.
    private static func tangents(_ v: [CGPoint], closed: Bool, cornerDeg: CGFloat) -> (tin: [CGPoint], tout: [CGPoint]) {
        let n = v.count
        var tin = [CGPoint](repeating: CGPoint(x: 1, y: 0), count: n)
        var tout = tin
        let allowCorners = !closed || n >= 6
        for i in 0..<n {
            if !closed && i == 0 {
                let u = (v[1] - v[0]).unit
                tin[i] = u
                tout[i] = u
                continue
            }
            if !closed && i == n - 1 {
                let u = (v[n - 1] - v[n - 2]).unit
                tin[i] = u
                tout[i] = u
                continue
            }
            let a = v[(i + n - 1) % n]
            let b = v[i]
            let c = v[(i + 1) % n]
            let u1 = (b - a).unit
            let u2 = (c - b).unit
            let dot = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
            let turn = acos(dot) * 180 / CGFloat.pi
            if allowCorners && turn > cornerDeg {
                tin[i] = u1
                tout[i] = u2
            } else {
                let t = (c - a).unit
                tin[i] = t
                tout[i] = t
            }
        }
        return (tin, tout)
    }

    /// Two quadratic curves per span, passing through every anchor.
    private static func addSpan(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, tout: CGPoint, tin: CGPoint) {
        let d = (p1 - p0).length
        let c1 = p0 + tout * (d / 4)
        let c2 = p1 - tin * (d / 4)
        let mid = (c1 + c2) * 0.5
        path.addQuadCurve(to: mid, control: c1)
        path.addQuadCurve(to: p1, control: c2)
    }

    static func addFittedClosed(_ v: [CGPoint], to path: CGMutablePath, cornerDeg: CGFloat) {
        let n = v.count
        guard n >= 3 else { return }
        let t = tangents(v, closed: true, cornerDeg: cornerDeg)
        path.move(to: v[0])
        for i in 0..<n {
            let j = (i + 1) % n
            addSpan(path, from: v[i], to: v[j], tout: t.tout[i], tin: t.tin[j])
        }
        path.closeSubpath()
    }

    static func addFittedOpen(_ v: [CGPoint], to path: CGMutablePath, cornerDeg: CGFloat) {
        let n = v.count
        guard n >= 2 else { return }
        path.move(to: v[0])
        if n == 2 {
            path.addLine(to: v[1])
            return
        }
        let t = tangents(v, closed: false, cornerDeg: cornerDeg)
        for i in 0..<(n - 1) {
            addSpan(path, from: v[i], to: v[i + 1], tout: t.tout[i], tin: t.tin[i + 1])
        }
    }

    // MARK: Public entry points

    /// `smoothing` is 0...100. The tolerance is measured in screen pixels, so zooming in
    /// keeps more detail, just as it used to.
    static func tolerance(smoothing: CGFloat, zoom: CGFloat) -> (eps: CGFloat, corner: CGFloat, passes: Int) {
        let s = max(0, min(1, smoothing / 100))
        let epsScreen = 0.25 + 4.75 * pow(s, 1.5)
        let corner = 50 + 60 * s
        let passes = Int((s * 4).rounded())
        return (epsScreen / max(zoom, 0.01), corner, passes)
    }

    static func smoothOutline(_ outline: CGPath, eps: CGFloat, cornerDeg: CGFloat) -> CGPath? {
        let out = CGMutablePath()
        for c in contours(of: outline) {
            if abs(area(c)) < eps * eps { continue }
            var anchors = simplifyClosed(c, eps: eps)
            if anchors.count < 4 {
                anchors = simplifyClosed(c, eps: eps * 0.25)
            }
            if anchors.count < 3 { continue }
            addFittedClosed(anchors, to: out, cornerDeg: cornerDeg)
        }
        return out.isEmpty ? nil : out
    }

    static func smoothedShape(points: [StrokePoint], smoothing: CGFloat, zoom: CGFloat) -> CGPath? {
        guard !points.isEmpty else { return nil }
        var total: CGFloat = 0
        for p in points { total += p.r }
        let avgR = total / CGFloat(points.count)
        let tol = tolerance(smoothing: smoothing, zoom: zoom)
        // Never smooth away more than about half the brush width, or thin strokes pinch shut.
        let eps = min(tol.eps, 0.25 / max(zoom, 0.01) + avgR * 0.5)
        let pts = smoothInput(points, passes: tol.passes)
        let outline = rawPath(pts).normalized(using: .winding)
        if let fitted = smoothOutline(outline, eps: eps, cornerDeg: tol.corner) {
            return fitted
        }
        return outline.isEmpty ? nil : outline
    }

    // MARK: Modern brush

    private static func catmullRom(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ t: CGFloat) -> CGFloat {
        let t2 = t * t
        let t3 = t2 * t
        let k1: CGFloat = c - a
        let k2: CGFloat = 2 * a - 5 * b + 4 * c - d
        let k3: CGFloat = 3 * b - a - 3 * c + d
        return 0.5 * (2 * b + k1 * t + k2 * t2 + k3 * t3)
    }

    /// Adds points along a smooth curve through the samples wherever they are further
    /// apart than `maxGap`, so fast strokes don't come out as straight segments.
    static func densify(_ pts: [StrokePoint], maxGap: CGFloat) -> [StrokePoint] {
        let n = pts.count
        if n < 3 { return pts }
        var out: [StrokePoint] = [pts[0]]
        for i in 0..<(n - 1) {
            let p0 = pts[max(0, i - 1)].p
            let p1 = pts[i].p
            let p2 = pts[i + 1].p
            let p3 = pts[min(n - 1, i + 2)].p
            let gap = (p2 - p1).length
            let pieces = min(16, max(1, Int((gap / max(maxGap, 0.01)).rounded(.up))))
            if pieces > 1 {
                for k in 1..<pieces {
                    let t = CGFloat(k) / CGFloat(pieces)
                    let x = catmullRom(p0.x, p1.x, p2.x, p3.x, t)
                    let y = catmullRom(p0.y, p1.y, p2.y, p3.y, t)
                    let r = pts[i].r + (pts[i + 1].r - pts[i].r) * t
                    out.append(StrokePoint(p: CGPoint(x: x, y: y), r: r))
                }
            }
            out.append(pts[i + 1])
        }
        return out
    }

    /// The modern brush: the shape you get is the shape you drew. `smoothing` only
    /// steadies the hand (how much the pointer path is averaged); the outline itself is
    /// kept accurate instead of being re-fitted loosely.
    static func modernShape(points: [StrokePoint], smoothing: CGFloat, zoom: CGFloat) -> CGPath? {
        guard !points.isEmpty else { return nil }
        let z = max(zoom, 0.01)
        let s = max(0, min(1, smoothing / 100))
        let passes = Int((s * 8).rounded())
        let steadied = smoothInput(points, passes: passes)
        let pts = densify(steadied, maxGap: 2 / z)
        let outline = rawPath(pts).normalized(using: .winding)
        if let fitted = smoothOutline(outline, eps: 0.12 / z, cornerDeg: 40) {
            return fitted
        }
        return outline.isEmpty ? nil : outline
    }

    static func pencilShape(points: [CGPoint], width: CGFloat, smoothing: CGFloat, zoom: CGFloat) -> CGPath? {
        guard let first = points.first else { return nil }
        let tol = tolerance(smoothing: smoothing, zoom: zoom)
        let smoothed = smoothInput(points.map { StrokePoint(p: $0, r: 0) }, passes: tol.passes).map { $0.p }
        let anchors = rdp(smoothed, eps: tol.eps)
        var span: CGFloat = 0
        for p in anchors { span = max(span, (p - first).length) }
        if anchors.count < 2 || span < 0.01 {
            let r = width / 2
            return CGPath(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: width, height: width), transform: nil)
        }
        let line = CGMutablePath()
        addFittedOpen(anchors, to: line, cornerDeg: tol.corner)
        let stroked = line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return stroked.normalized(using: .winding)
    }

    static func lineShape(from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
        let line = CGMutablePath()
        line.move(to: a)
        line.addLine(to: b)
        let stroked = line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return stroked.normalized(using: .winding)
    }
}

/// Paths are stored as SVG path data, so saved files and SVG export share one format.
enum PathText {
    private static func num(_ v: CGFloat) -> String {
        return String(format: "%.2f", Double(v))
    }

    static func string(from path: CGPath) -> String {
        var parts: [String] = []
        path.applyWithBlock { ep in
            let e = ep.pointee
            switch e.type {
            case .moveToPoint:
                parts.append("M \(num(e.points[0].x)) \(num(e.points[0].y))")
            case .addLineToPoint:
                parts.append("L \(num(e.points[0].x)) \(num(e.points[0].y))")
            case .addQuadCurveToPoint:
                parts.append("Q \(num(e.points[0].x)) \(num(e.points[0].y)) \(num(e.points[1].x)) \(num(e.points[1].y))")
            case .addCurveToPoint:
                parts.append("C \(num(e.points[0].x)) \(num(e.points[0].y)) \(num(e.points[1].x)) \(num(e.points[1].y)) \(num(e.points[2].x)) \(num(e.points[2].y))")
            case .closeSubpath:
                parts.append("Z")
            @unknown default:
                break
            }
        }
        return parts.joined(separator: " ")
    }

    static func path(from text: String) -> CGPath {
        let path = CGMutablePath()
        let tokens = text.split(separator: " ").map { String($0) }
        var i = 0
        func take() -> CGFloat {
            var v: CGFloat = 0
            if i < tokens.count, let d = Double(tokens[i]) {
                v = CGFloat(d)
            }
            i += 1
            return v
        }
        func point() -> CGPoint {
            let x = take()
            let y = take()
            return CGPoint(x: x, y: y)
        }
        var started = false
        while i < tokens.count {
            let cmd = tokens[i]
            i += 1
            switch cmd {
            case "M":
                path.move(to: point())
                started = true
            case "L":
                let p = point()
                if started { path.addLine(to: p) }
            case "Q":
                let c = point()
                let p = point()
                if started { path.addQuadCurve(to: p, control: c) }
            case "C":
                let c1 = point()
                let c2 = point()
                let p = point()
                if started { path.addCurve(to: p, control1: c1, control2: c2) }
            case "Z":
                if started { path.closeSubpath() }
            default:
                break
            }
        }
        return path
    }
}
