import Foundation
import CoreGraphics

// The document model is all value types, so an undo step is just a copy of `Doc`.

struct RGBA: Codable, Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    var hex: String {
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

/// Every mark on the stage is a filled vector shape, the way the classic brush made them.
/// A shape can instead be an *instance* of a library item (a symbol or a bitmap): then
/// `ref` names the item, `m` is the instance's transform, and `path` is its outline box
/// on the stage, which is what selection, hit-testing and moving work with.
struct Shape: Codable {
    var path: CGPath
    var color: RGBA
    var ref: String? = nil
    var m: [CGFloat]? = nil

    enum CodingKeys: String, CodingKey {
        case d
        case color
        case ref
        case m
    }

    init(path: CGPath, color: RGBA) {
        self.path = path
        self.color = color
    }

    init(instanceOf item: LibraryItem, transform t: CGAffineTransform, library: [LibraryItem]) {
        var tt = t
        let box = item.bounds(in: library)
        self.path = CGPath(rect: box, transform: &tt)
        self.color = RGBA.black
        self.ref = item.id
        self.m = [t.a, t.b, t.c, t.d, t.tx, t.ty]
    }

    var isInstance: Bool {
        return ref != nil
    }

    var transform: CGAffineTransform {
        guard let m = m, m.count == 6 else { return CGAffineTransform.identity }
        return CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(RGBA.self, forKey: .color)
        let d = try c.decode(String.self, forKey: .d)
        path = PathText.path(from: d)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        m = try c.decodeIfPresent([CGFloat].self, forKey: .m)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(PathText.string(from: path), forKey: .d)
        try c.encodeIfPresent(ref, forKey: .ref)
        try c.encodeIfPresent(m, forKey: .m)
    }
}

/// Something reusable kept in the document's library: a symbol (vector art drawn once
/// and placed many times) or an imported bitmap.
struct LibraryItem: Codable {
    var id: String
    var name: String
    /// "symbol" or "bitmap"
    var kind: String
    var shapes: [Shape]? = nil
    /// The original image file's bytes (PNG, JPEG, ...), for bitmaps.
    var image: Data? = nil
    var width: CGFloat = 0
    var height: CGFloat = 0

    var isSymbol: Bool {
        return kind == "symbol"
    }

    /// The item's extent in its own coordinates.
    func bounds(in library: [LibraryItem]) -> CGRect {
        if !isSymbol {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        var box = CGRect.null
        for s in shapes ?? [] {
            box = box.union(s.path.boundingBoxOfPath)
        }
        return box.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : box
    }
}

/// One cell of the timeline: a frame on a layer.
struct FrameRef: Hashable {
    var layer: Int
    var frame: Int
}

struct KeyFrame: Codable {
    var shapes: [Shape] = []
    /// Set when this keyframe starts a tween toward the next keyframe.
    var tween: Tween? = nil
    /// A storyboard caption, when this keyframe is a storyboard panel.
    var note: String? = nil
}

struct Layer: Codable {
    var name: String
    var visible: Bool = true
    var locked: Bool = false
    /// True for the storyboard layer, whose keyframes are the board's panels.
    var isBoard: Bool? = nil
    /// 0...1. Optional so documents saved before layer opacity existed still open.
    var opacity: CGFloat? = nil
    /// True when this layer is a clipping mask: it only shows where the nearest layer
    /// below it that isn't clipped has art.
    var clip: Bool? = nil
    /// True for the reference layer: the paint bucket fills between its lines while
    /// putting the paint on the layer you are working on.
    var reference: Bool? = nil

    var isClipped: Bool {
        return clip == true
    }

    var isReference: Bool {
        return reference == true
    }

    var alpha: CGFloat {
        return max(0, min(1, opacity ?? 1))
    }
    /// Keyframes by frame index. A keyframe's art holds until the next keyframe.
    var keys: [Int: KeyFrame] = [0: KeyFrame()]

    init(name: String) {
        self.name = name
    }

    func keyIndex(at frame: Int) -> Int {
        var best = 0
        for k in keys.keys where k <= frame && k > best {
            best = k
        }
        return best
    }

    func nextKey(after k: Int) -> Int? {
        var best: Int? = nil
        for other in keys.keys where other > k {
            if best == nil || other < (best ?? other) { best = other }
        }
        return best
    }

    /// The tween covering `frame`, if it sits between a tweened keyframe and the next one.
    func tweenSpan(at frame: Int) -> (start: Int, end: Int, tween: Tween)? {
        let k = keyIndex(at: frame)
        guard let tween = keys[k]?.tween, let end = nextKey(after: k) else { return nil }
        return (k, end, tween)
    }

    /// What the layer shows on a frame: the governing keyframe's art, or, inside a tween,
    /// the blend between that keyframe and the next.
    func shapes(at frame: Int) -> [Shape] {
        let k = keyIndex(at: frame)
        guard let key = keys[k] else { return [] }
        guard frame > k, let span = tweenSpan(at: frame), let target = keys[span.end] else {
            return key.shapes
        }
        let progress = CGFloat(frame - span.start) / CGFloat(span.end - span.start)
        return Tweening.blend(key.shapes, target.shapes, t: Tweening.progress(span.tween, progress))
    }

    var lastKey: Int {
        return keys.keys.max() ?? 0
    }
}

struct Doc: Codable {
    var width: CGFloat = 550
    var height: CGFloat = 400
    var fps: Int = 24
    var background: RGBA = RGBA.white
    /// layers[0] is the top layer, as in the timeline list.
    var layers: [Layer] = [Layer(name: "Layer 1")]
    var length: Int = 1
    /// Path of the soundtrack file, if any. The file itself stays where it is on disk.
    var audioPath: String? = nil
    /// Symbols and bitmaps. Optional so older documents still open.
    var library: [LibraryItem]? = nil

    var items: [LibraryItem] {
        return library ?? []
    }

    func item(_ id: String?) -> LibraryItem? {
        guard let id = id else { return nil }
        return items.first { $0.id == id }
    }

    var longestLayer: Int {
        var m = 0
        for l in layers {
            m = max(m, l.lastKey)
        }
        return m + 1
    }

    mutating func insertKeyframe(layer li: Int, frame: Int, blank: Bool) {
        guard layers.indices.contains(li) else { return }
        if layers[li].keys[frame] == nil {
            let copied = blank ? [] : layers[li].shapes(at: frame)
            // A keyframe added inside a tween keeps the tween going on both sides of it.
            let carried = blank ? nil : layers[li].tweenSpan(at: frame)?.tween
            layers[li].keys[frame] = KeyFrame(shapes: copied, tween: carried)
        } else if blank {
            layers[li].keys[frame] = KeyFrame()
        }
        length = max(length, frame + 1)
    }

    mutating func clearKeyframe(layer li: Int, frame: Int) {
        guard layers.indices.contains(li), layers[li].keys[frame] != nil else { return }
        if frame == 0 {
            layers[li].keys[0] = KeyFrame()
        } else {
            layers[li].keys[frame] = nil
        }
    }

    mutating func insertFrame(layer li: Int, frame: Int) {
        guard layers.indices.contains(li) else { return }
        if frame >= length {
            length = frame + 1
            return
        }
        let hadLater = layers[li].keys.keys.contains { $0 > frame }
        var shifted: [Int: KeyFrame] = [:]
        for (k, v) in layers[li].keys {
            shifted[k > frame ? k + 1 : k] = v
        }
        layers[li].keys = shifted
        if !hadLater || layers[li].lastKey >= length {
            length += 1
        }
    }

    /// Takes a set of frames out of one layer, closing the gap. A drawing that is only
    /// partly inside the removed frames is kept and simply holds for less time; a drawing
    /// that is entirely inside them goes.
    mutating func removeFrames(layer li: Int, frames: Set<Int>) {
        guard layers.indices.contains(li), !frames.isEmpty else { return }
        let ordered = layers[li].keys.keys.sorted()
        let removed = frames.sorted()
        var out: [Int: KeyFrame] = [:]
        for (n, k) in ordered.enumerated() {
            guard let key = layers[li].keys[k] else { continue }
            // The frames this keyframe's drawing is held for.
            let end = n + 1 < ordered.count ? ordered[n + 1] - 1 : max(length - 1, k)
            var keep: Int? = nil
            var f = k
            while f <= end {
                if !frames.contains(f) {
                    keep = f
                    break
                }
                f += 1
            }
            guard let survivor = keep else { continue }
            var gone = 0
            for r in removed where r < survivor { gone += 1 }
            out[survivor - gone] = key
        }
        if out[0] == nil { out[0] = KeyFrame() }
        layers[li].keys = out
    }

    mutating func removeFrame(layer li: Int, frame: Int) {
        guard layers.indices.contains(li), frame < length else { return }
        var keys = layers[li].keys
        if frame > 0 {
            keys[frame] = nil
        } else if keys[1] != nil {
            keys[0] = nil
        }
        var shifted: [Int: KeyFrame] = [:]
        for (k, v) in keys {
            shifted[k > frame ? k - 1 : k] = v
        }
        if shifted[0] == nil {
            shifted[0] = KeyFrame()
        }
        layers[li].keys = shifted
        length = max(1, length - 1, longestLayer)
    }
}
