#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import ImageIO

enum Tool: Int, CaseIterable {
    case select, transform, lasso, brush, pencil, eraser, bucket, eyedropper, line, rect, oval, hand

    var title: String {
        switch self {
        case .select: return "Selection (V)"
        case .transform: return "Transform (Q): scale, rotate and move the selection"
        case .lasso: return "Lasso (L): loop around art to select it, cutting through shapes"
        case .brush: return "Brush (B)"
        case .pencil: return "Pencil (Y)"
        case .eraser: return "Eraser (E)"
        case .bucket: return "Paint Bucket (K)"
        case .eyedropper: return "Eyedropper (I)"
        case .line: return "Line (N)"
        case .rect: return "Rectangle (R)"
        case .oval: return "Oval (O)"
        case .hand: return "Hand (H, or hold Space)"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .transform: return "arrow.up.left.and.arrow.down.right"
        case .lasso: return "lasso"
        case .brush: return "paintbrush.pointed.fill"
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .bucket: return "drop.fill"
        case .eyedropper: return "eyedropper"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .hand: return "hand.raised"
        }
    }

    var letter: String {
        switch self {
        case .select: return "v"
        case .transform: return "q"
        case .lasso: return "l"
        case .brush: return "b"
        case .pencil: return "y"
        case .eraser: return "e"
        case .bucket: return "k"
        case .eyedropper: return "i"
        case .line: return "n"
        case .rect: return "r"
        case .oval: return "o"
        case .hand: return "h"
        }
    }

    /// Tools that work with the selection, so switching to them keeps it.
    var keepsSelection: Bool {
        return self == .select || self == .transform || self == .lasso
    }

    var hasSize: Bool {
        return self == .brush || self == .pencil || self == .eraser || self == .line
    }
}

#if os(macOS)
extension RGBA {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    var nsColor: NSColor {
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
#else
extension RGBA {
    init(_ color: UIColor) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Wide-colour picks can fall outside 0...1; the document stores plain sRGB.
        self.init(r: max(0, min(1, r)), g: max(0, min(1, g)), b: max(0, min(1, b)), a: max(0, min(1, a)))
    }

    var uiColor: UIColor {
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}
#endif

/// Wraps a closure so it can be the target of a control or menu item.
final class Action: NSObject {
    private let fn: () -> Void

    init(_ fn: @escaping () -> Void) {
        self.fn = fn
    }

    @objc func fire() {
        fn()
    }
}

final class AppState {
    /// How a document's soundtrack path becomes a file, and how a chosen file becomes the
    /// path stored in the document. The Mac keeps full paths; the iPad replaces these so a
    /// soundtrack copied into the app is stored relative to the app's own folder, which
    /// moves when the app is reinstalled.
    static var audioFile: (String) -> URL = { URL(fileURLWithPath: $0) }
    static var audioReference: (URL) -> String = { $0.path }

    var doc = Doc()
    var layer = 0
    var frame = 0
    var tool: Tool = .brush
    var color = RGBA.black
    var sizes: [Tool: CGFloat] = [.brush: 12, .pencil: 12, .eraser: 24, .line: 2]
    var smoothing: CGFloat = 50
    var usePressure = true
    /// On: the brush re-fits its outline loosely on release (the classic wobble).
    /// Off: the modern brush, which keeps the stroke as drawn. Remembered between launches.
    var legacyBrush: Bool = (UserDefaults.standard.object(forKey: "legacyBrush") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(legacyBrush, forKey: "legacyBrush")
        }
    }
    var onionSkin = false
    /// On: playback starts over at the end. Off: it plays once and stops on the last frame.
    var loopPlayback: Bool = (UserDefaults.standard.object(forKey: "loopPlayback") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(loopPlayback, forKey: "loopPlayback")
        }
    }
    var onion = OnionSettings.load() {
        didSet {
            onion.save()
        }
    }
    /// When on, the stage view hides anything drawn outside the stage rectangle.
    var clipToStage = false
    /// Selected art on the current layer, as indexes into that layer's art on this frame.
    var selection = Set<Int>() {
        didSet {
            // Clearing the selection clears it on every layer.
            if selection.isEmpty && !holdExtras && !extraSelection.isEmpty {
                extraSelection.removeAll()
            }
        }
    }
    /// Selected art on other layers: layer index to art indexes. A selection can span
    /// layers; the current layer's part lives in `selection`.
    private(set) var extraSelection: [Int: Set<Int>] = [:]
    private var holdExtras = false
    /// Frames picked in the timeline (any layers). Keyframe commands apply to all of them.
    var frameSelection = Set<FrameRef>()
    /// The library row that is highlighted.
    var selectedItem: String?
    /// When set, the drawing tools work on this symbol's own art instead of the timeline.
    var editingSymbol: String?
    var clipboard: [Shape] = []
    var fileURL: URL?
    var dirty = false
    var zoom: CGFloat = 1
    /// Set by the app delegate; keeps this class free of main-thread-only AppKit calls.
    var beep: () -> Void = {}

    private var undoStack: [Doc] = []
    private var redoStack: [Doc] = []
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private var scrubTimer: Timer?
    private var fadingLayer: Int?
    private var curveEdit: String?
    private var backgroundEdit = false
    /// When set, playback loops inside these frames only (the graph editor's Play Tween).
    private(set) var playRange: ClosedRange<Int>?
    private var loadedAudioPath: String?
    private var audioPeaks: [Float] = []
    private let peaksPerSecond: Double = 60
    private var listeners: [() -> Void] = []

    func observe(_ fn: @escaping () -> Void) {
        listeners.append(fn)
    }

    func changed() {
        for l in listeners { l() }
    }

    // MARK: Current context

    var size: CGFloat {
        get { return sizes[tool] ?? 2 }
        set { sizes[tool] = max(1, min(200, newValue)) }
    }

    var canEdit: Bool {
        if editingSymbol != nil { return true }
        guard doc.layers.indices.contains(layer) else { return false }
        return doc.layers[layer].visible && !doc.layers[layer].locked
    }

    var currentShapes: [Shape] {
        if let id = editingSymbol { return doc.item(id)?.shapes ?? [] }
        guard doc.layers.indices.contains(layer) else { return [] }
        return doc.layers[layer].shapes(at: frame)
    }

    var isPlaying: Bool {
        return timer != nil
    }

    // MARK: Undo

    func checkpoint() {
        undoStack.append(doc)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        dirty = true
        fadingLayer = nil
        curveEdit = nil
        backgroundEdit = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(doc)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        restore(next)
    }

    private func restore(_ d: Doc) {
        doc = d
        dirty = true
        selection.removeAll()
        layer = max(0, min(layer, doc.layers.count - 1))
        fadingLayer = nil
        if doc.item(editingSymbol) == nil { editingSymbol = nil }
        frameSelection.removeAll()
        if doc.item(selectedItem) == nil { selectedItem = nil }
        if doc.audioPath != loadedAudioPath { loadAudio() }
        changed()
    }

    func load(_ d: Doc, url: URL?) {
        stop()
        doc = d
        if doc.layers.isEmpty { doc.layers = [Layer(name: "Layer 1")] }
        doc.length = max(1, doc.length, doc.longestLayer)
        loadAudio()
        fileURL = url
        dirty = false
        undoStack.removeAll()
        redoStack.removeAll()
        selection.removeAll()
        frameSelection.removeAll()
        editingSymbol = nil
        selectedItem = nil
        layer = 0
        frame = 0
        changed()
    }

    // MARK: Shapes

    func mutateShapes(checkpoint cp: Bool = true, _ body: (inout [Shape]) -> Void) {
        if let id = editingSymbol {
            guard let index = doc.items.firstIndex(where: { $0.id == id }) else { return }
            if cp { checkpoint() }
            var art = doc.items[index].shapes ?? []
            body(&art)
            doc.library?[index].shapes = art
            changed()
            return
        }
        guard doc.layers.indices.contains(layer) else { return }
        if cp { checkpoint() }
        var k = doc.layers[layer].keyIndex(at: frame)
        if frame > k, let span = doc.layers[layer].tweenSpan(at: frame) {
            // Editing partway through a tween: pin what is showing here as a new keyframe
            // first, so the change lands on this frame and the tween carries on either side.
            let shown = doc.layers[layer].shapes(at: frame)
            doc.layers[layer].keys[frame] = KeyFrame(shapes: shown, tween: span.tween)
            k = frame
        }
        var key = doc.layers[layer].keys[k] ?? KeyFrame()
        var shapes = key.shapes
        body(&shapes)
        key.shapes = shapes
        doc.layers[layer].keys[k] = key
        if frame >= doc.length { doc.length = frame + 1 }
        changed()
    }

    /// Adds a fill. Like the old merge-drawing model, it fuses with same-coloured art it
    /// touches, unless something of another colour sits on top of that art.
    func addFill(_ path: CGPath, color fill: RGBA) {
        guard canEdit else {
            beep()
            return
        }
        selection.removeAll()
        let box = path.boundingBoxOfPath
        mutateShapes { shapes in
            var merged = path
            var remove: [Int] = []
            var i = shapes.count - 1
            while i >= 0 {
                let s = shapes[i]
                let sBox = s.path.boundingBoxOfPath
                if !s.isInstance && s.color == fill && sBox.intersects(box) && s.path.intersects(path, using: .winding) {
                    var covered = false
                    var j = i + 1
                    while j < shapes.count {
                        let above = shapes[j]
                        if (above.isInstance || above.color != fill) && above.path.boundingBoxOfPath.intersects(sBox)
                            && above.path.intersects(s.path, using: .winding) {
                            covered = true
                            break
                        }
                        j += 1
                    }
                    if !covered {
                        merged = merged.union(s.path, using: .winding)
                        remove.append(i)
                    }
                }
                i -= 1
            }
            for index in remove {
                shapes.remove(at: index)
            }
            shapes.append(Shape(path: merged, color: fill))
        }
    }

    /// Adds a fill as its own shape, without fusing it into neighbouring art. Used for
    /// the pencil's spray, whose thousands of specks would make fusing very slow.
    func addSeparate(_ path: CGPath, color fill: RGBA) {
        guard canEdit else {
            beep()
            return
        }
        selection.removeAll()
        mutateShapes { shapes in
            shapes.append(Shape(path: path, color: fill))
        }
    }

    func erase(_ path: CGPath) {
        guard canEdit else {
            beep()
            return
        }
        selection.removeAll()
        let box = path.boundingBoxOfPath
        mutateShapes { shapes in
            var out: [Shape] = []
            for s in shapes {
                if s.isInstance {
                    out.append(s)   // symbols and bitmaps aren't erased; edit or break them apart
                } else if s.path.boundingBoxOfPath.intersects(box) {
                    let cut = s.path.subtracting(path, using: .winding)
                    let cutBox = cut.boundingBoxOfPath
                    if !cut.isEmpty && cutBox.width > 0.05 && cutBox.height > 0.05 {
                        out.append(Shape(path: cut, color: s.color))
                    }
                } else {
                    out.append(s)
                }
            }
            shapes = out
        }
    }

    func hitTest(_ pt: CGPoint) -> Int? {
        let shapes = currentShapes
        var i = shapes.count - 1
        while i >= 0 {
            if shapes[i].path.contains(pt, using: .winding) { return i }
            i -= 1
        }
        return nil
    }

    /// Recolours the fill under the pointer, or fills an enclosed gap between fills.
    func bucket(at pt: CGPoint) {
        guard canEdit else {
            beep()
            return
        }
        let fill = color
        if let hit = hitTest(pt) {
            if currentShapes[hit].isInstance { return }
            if currentShapes[hit].color != fill {
                mutateShapes { shapes in
                    shapes[hit].color = fill
                }
            }
            return
        }
        // With a reference layer, its lines decide where the paint goes; the paint itself
        // still lands on the layer you are working on.
        var walls = currentShapes
        if editingSymbol == nil, let r = referenceLayer, r != layer, doc.layers[r].visible {
            walls = doc.layers[r].shapes(at: frame)
        }
        let shapes = walls.filter { !$0.isInstance }
        guard let firstShape = shapes.first else { return }
        var all = firstShape.path
        for s in shapes.dropFirst() {
            all = all.union(s.path, using: .winding)
        }
        let big = all.boundingBoxOfPath.insetBy(dx: -50, dy: -50)
        guard big.contains(pt) else { return }
        let rest = CGPath(rect: big, transform: nil).subtracting(all, using: .winding)
        let outside = CGPoint(x: big.minX + 1, y: big.minY + 1)
        for region in rest.componentsSeparated(using: .winding) {
            if !region.contains(pt, using: .winding) { continue }
            if region.contains(outside, using: .winding) { return }
            // Grow the fill a hair so no seam shows against the art that encloses it.
            let rim = region.copy(strokingWithWidth: 1, lineCap: .round, lineJoin: .round, miterLimit: 2)
            let grown = region.union(rim, using: .winding)
            mutateShapes { shapes in
                shapes.insert(Shape(path: grown, color: fill), at: 0)
            }
            return
        }
    }

    func pickColor(at pt: CGPoint) {
        for l in doc.layers where l.visible {
            let shapes = l.shapes(at: frame)
            var i = shapes.count - 1
            while i >= 0 {
                if !shapes[i].isInstance && shapes[i].path.contains(pt, using: .winding) {
                    color = shapes[i].color
                    changed()
                    return
                }
                i -= 1
            }
        }
    }

    // MARK: Selection

    // MARK: Selection across layers

    var hasSelection: Bool {
        return !selection.isEmpty || !extraSelection.isEmpty
    }

    /// Everything selected, on every layer, as it shows on this frame.
    var selectedShapes: [Shape] {
        var out: [Shape] = []
        let here = currentShapes
        for i in selection.sorted() where here.indices.contains(i) {
            out.append(here[i])
        }
        if editingSymbol != nil { return out }
        for (li, set) in extraSelection where doc.layers.indices.contains(li) && li != layer {
            let shapes = doc.layers[li].shapes(at: frame)
            for i in set.sorted() where shapes.indices.contains(i) {
                out.append(shapes[i])
            }
        }
        return out
    }

    func isSelected(layer li: Int, index: Int) -> Bool {
        if li == layer { return selection.contains(index) }
        return extraSelection[li]?.contains(index) ?? false
    }

    /// The topmost art under a point on any visible, unlocked layer.
    func hitAny(_ pt: CGPoint) -> (layer: Int, index: Int)? {
        if editingSymbol != nil {
            if let i = hitTest(pt) { return (layer, i) }
            return nil
        }
        for li in doc.layers.indices where doc.layers[li].visible && !doc.layers[li].locked {
            let shapes = doc.layers[li].shapes(at: frame)
            var i = shapes.count - 1
            while i >= 0 {
                if shapes[i].path.contains(pt, using: .winding) { return (li, i) }
                i -= 1
            }
        }
        return nil
    }

    /// Selects one piece of art and nothing else, making its layer the current layer.
    func selectOnly(layer li: Int, index: Int) {
        guard doc.layers.indices.contains(li) else { return }
        holdExtras = true
        layer = li
        selection = [index]
        holdExtras = false
        extraSelection.removeAll()
        changed()
    }

    /// Adds a piece of art to the selection, or removes it if it is already selected.
    func toggleSelected(layer li: Int, index: Int) {
        holdExtras = true
        if li == layer {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        } else {
            var set = extraSelection[li] ?? []
            if set.contains(index) { set.remove(index) } else { set.insert(index) }
            extraSelection[li] = set.isEmpty ? nil : set
        }
        holdExtras = false
        changed()
    }

    /// The lasso, on the current layer. Art wholly inside the loop is selected. Art that the
    /// loop crosses is cut in two along it, the way the classic lasso worked, and the piece
    /// inside is selected, so it can be moved, recoloured or deleted on its own. Symbol and
    /// bitmap copies can't be cut; they are selected when the loop touches them.
    func lassoSelect(_ loop: CGPath, adding: Bool) {
        guard canEdit else {
            beep()
            return
        }
        let area = loop.boundingBoxOfPath
        let previous = adding ? selection : Set<Int>()
        if !adding { selection.removeAll() }
        guard area.width > 0.5 || area.height > 0.5 else {
            changed()
            return
        }
        func tiny(_ p: CGPath) -> Bool {
            let b = p.boundingBoxOfPath
            return p.isEmpty || b.isNull || b.width * b.height < 0.25
        }
        let shapes = currentShapes
        var whole = Set<Int>()
        var cuts: [Int: (inside: CGPath, outside: CGPath)] = [:]
        for (i, s) in shapes.enumerated() where s.path.boundingBoxOfPath.intersects(area) {
            if s.isInstance {
                if loop.intersects(s.path, using: .winding) { whole.insert(i) }
                continue
            }
            let inside = s.path.intersection(loop, using: .winding)
            if tiny(inside) { continue }
            let outside = s.path.subtracting(loop, using: .winding)
            if tiny(outside) {
                whole.insert(i)
            } else {
                cuts[i] = (inside, outside)
            }
        }
        if cuts.isEmpty {
            selection = previous.union(whole)
            changed()
            return
        }
        // Cut the crossed shapes: the outside piece stays where the shape was and the
        // inside piece sits just above it, so stacking order is kept.
        var picked = Set<Int>()
        mutateShapes { list in
            var out: [Shape] = []
            for (i, s) in list.enumerated() {
                if let pieces = cuts[i] {
                    var rest = s
                    rest.path = pieces.outside
                    out.append(rest)
                    if previous.contains(i) { picked.insert(out.count - 1) }
                    var piece = s
                    piece.path = pieces.inside
                    out.append(piece)
                    picked.insert(out.count - 1)
                } else {
                    out.append(s)
                    if whole.contains(i) || previous.contains(i) { picked.insert(out.count - 1) }
                }
            }
            list = out
        }
        selection = picked
        changed()
    }

    /// Adds art on any layer to the selection (used by the marquee).
    func addToSelection(layer li: Int, indexes: Set<Int>) {
        guard !indexes.isEmpty else { return }
        if li == layer {
            selection.formUnion(indexes)
        } else {
            extraSelection[li] = (extraSelection[li] ?? []).union(indexes)
        }
    }

    /// Runs `body` once for each layer holding selected art, with that layer made current
    /// and `selection` set to its part, then puts things back.
    private func eachSelectedLayer(_ body: () -> Void) {
        if editingSymbol != nil || extraSelection.isEmpty {
            body()
            return
        }
        let home = layer
        let others = extraSelection
        holdExtras = true
        body()
        let homeAfter = selection
        var kept: [Int: Set<Int>] = [:]
        for (li, set) in others where li != home && doc.layers.indices.contains(li) {
            layer = li
            selection = set
            body()
            if !selection.isEmpty { kept[li] = selection }
        }
        layer = home
        selection = homeAfter
        extraSelection = kept
        holdExtras = false
        changed()
    }

    /// Moves selected art from other layers onto the current layer, keeping its stacking
    /// order, so the whole selection can be treated as one group.
    private func gatherSelection() {
        guard editingSymbol == nil, !extraSelection.isEmpty else { return }
        let home = layer
        let homeSel = selection
        let others = extraSelection
        var below: [Shape] = []
        var above: [Shape] = []
        holdExtras = true
        for li in doc.layers.indices.reversed() where li != home {
            guard let set = others[li], !set.isEmpty else { continue }
            let shapes = doc.layers[li].shapes(at: frame)
            var picked: [Shape] = []
            for i in set.sorted() where shapes.indices.contains(i) {
                picked.append(shapes[i])
            }
            layer = li
            selection = set
            deleteHere()
            // A higher index is a lower layer.
            if li > home { below += picked } else { above += picked }
        }
        layer = home
        var newSelection = Set<Int>()
        mutateShapes(checkpoint: false) { shapes in
            let shift = below.count
            for i in homeSel { newSelection.insert(i + shift) }
            for i in 0..<shift { newSelection.insert(i) }
            let start = shift + shapes.count
            for i in 0..<above.count { newSelection.insert(start + i) }
            shapes = below + shapes + above
        }
        selection = newSelection
        extraSelection = [:]
        holdExtras = false
    }

    func deleteSelection() {
        guard hasSelection else { return }
        checkpoint()
        eachSelectedLayer { self.deleteHere() }
    }

    private func deleteHere() {
        guard !selection.isEmpty, canEdit else { return }
        let sel = selection
        selection.removeAll()
        mutateShapes(checkpoint: false) { shapes in
            var kept: [Shape] = []
            for (i, s) in shapes.enumerated() where !sel.contains(i) {
                kept.append(s)
            }
            shapes = kept
        }
    }

    func translateSelection(dx: CGFloat, dy: CGFloat, checkpoint cp: Bool) {
        guard hasSelection else { return }
        if cp { checkpoint() }
        eachSelectedLayer { self.translateHere(dx: dx, dy: dy) }
    }

    private func translateHere(dx: CGFloat, dy: CGFloat) {
        guard !selection.isEmpty, canEdit else { return }
        let sel = selection
        mutateShapes(checkpoint: false) { shapes in
            var t = CGAffineTransform(translationX: dx, y: dy)
            for i in sel where shapes.indices.contains(i) {
                if let moved = shapes[i].path.copy(using: &t) {
                    shapes[i].path = moved
                }
                if var m = shapes[i].m, m.count == 6 {
                    m[4] += dx
                    m[5] += dy
                    shapes[i].m = m
                }
            }
        }
    }

    /// The box around everything selected, in stage coordinates.
    var selectionBox: CGRect? {
        var box = CGRect.null
        for s in selectedShapes {
            box = box.union(s.path.boundingBoxOfPath)
        }
        return box.isNull || box.isEmpty ? nil : box
    }

    /// Applies a transform to the selected art. Fills are reshaped; symbol and bitmap
    /// copies keep their own transform, so they stay sharp and editable.
    func transformSelection(_ t: CGAffineTransform, checkpoint cp: Bool) {
        guard hasSelection else { return }
        if cp { checkpoint() }
        eachSelectedLayer { self.transformHere(t) }
    }

    private func transformHere(_ t: CGAffineTransform) {
        guard !selection.isEmpty, canEdit else { return }
        let sel = selection
        mutateShapes(checkpoint: false) { shapes in
            var tt = t
            for i in sel where shapes.indices.contains(i) {
                if let moved = shapes[i].path.copy(using: &tt) {
                    shapes[i].path = moved
                }
                if shapes[i].isInstance {
                    let m = shapes[i].transform.concatenating(t)
                    shapes[i].m = [m.a, m.b, m.c, m.d, m.tx, m.ty]
                }
            }
        }
    }

    func flipSelection(horizontal: Bool) {
        guard let box = selectionBox else {
            beep()
            return
        }
        let t = CGAffineTransform(translationX: box.midX, y: box.midY)
            .scaledBy(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
            .translatedBy(x: -box.midX, y: -box.midY)
        transformSelection(t, checkpoint: true)
    }

    func rotateSelection(degrees: CGFloat) {
        guard let box = selectionBox else {
            beep()
            return
        }
        let t = CGAffineTransform(translationX: box.midX, y: box.midY)
            .rotated(by: degrees * CGFloat.pi / 180)
            .translatedBy(x: -box.midX, y: -box.midY)
        transformSelection(t, checkpoint: true)
    }

    /// Moves the selected art above or below everything else on its layer and frame.
    func arrangeSelection(toFront: Bool) {
        guard hasSelection else {
            beep()
            return
        }
        checkpoint()
        eachSelectedLayer { self.arrangeHere(toFront: toFront) }
    }

    private func arrangeHere(toFront: Bool) {
        guard !selection.isEmpty, canEdit else { return }
        let sel = selection
        var newSelection = Set<Int>()
        mutateShapes(checkpoint: false) { shapes in
            var picked: [Shape] = []
            var rest: [Shape] = []
            for (i, s) in shapes.enumerated() {
                if sel.contains(i) { picked.append(s) } else { rest.append(s) }
            }
            if toFront {
                shapes = rest + picked
                newSelection = Set(rest.count..<(rest.count + picked.count))
            } else {
                shapes = picked + rest
                newSelection = Set(0..<picked.count)
            }
        }
        selection = newSelection
        changed()
    }

    func recolorSelection() {
        guard hasSelection else { return }
        checkpoint()
        eachSelectedLayer { self.recolorHere() }
    }

    private func recolorHere() {
        guard !selection.isEmpty, canEdit else { return }
        let sel = selection
        let fill = color
        mutateShapes(checkpoint: false) { shapes in
            for i in sel where shapes.indices.contains(i) {
                shapes[i].color = fill
            }
        }
    }

    /// Selects all art on this frame, on every visible, unlocked layer.
    func selectAll() {
        tool = .select
        selection.removeAll()
        if editingSymbol != nil {
            selection = Set(currentShapes.indices)
            changed()
            return
        }
        holdExtras = true
        for li in doc.layers.indices where doc.layers[li].visible && !doc.layers[li].locked {
            addToSelection(layer: li, indexes: Set(doc.layers[li].shapes(at: frame).indices))
        }
        holdExtras = false
        changed()
    }

    func deselect() {
        selection.removeAll()
        changed()
    }

    func copySelection() {
        clipboard = hasSelection ? selectedShapes : currentShapes
    }

    func paste() {
        guard !clipboard.isEmpty, canEdit else { return }
        let incoming = clipboard
        selection.removeAll()
        var newSelection = Set<Int>()
        mutateShapes { shapes in
            for s in incoming {
                newSelection.insert(shapes.count)
                shapes.append(s)
            }
        }
        tool = .select
        selection = newSelection
        changed()
    }

    // MARK: Frames and layers

    func goto(_ f: Int) {
        let clamped = max(0, min(9999, f))
        if clamped == frame { return }
        frame = clamped
        selection.removeAll()
        scrubAudio()
        changed()
    }

    func selectLayer(_ index: Int) {
        guard doc.layers.indices.contains(index), index != layer else { return }
        layer = index
        selection.removeAll()
        changed()
    }

    /// The frames a keyframe command applies to: the timeline selection when several
    /// frames are picked, otherwise just the playhead on the current layer.
    var frameTargets: [FrameRef] {
        let picked = frameSelection.filter { doc.layers.indices.contains($0.layer) && !doc.layers[$0.layer].locked }
        if picked.count > 1 {
            return picked.sorted { ($0.layer, $0.frame) < ($1.layer, $1.frame) }
        }
        return [FrameRef(layer: layer, frame: frame)]
    }

    func insertKeyframe(blank: Bool) {
        checkpoint()
        selection.removeAll()
        for t in frameTargets {
            doc.insertKeyframe(layer: t.layer, frame: t.frame, blank: blank)
        }
        changed()
    }

    func clearKeyframe() {
        checkpoint()
        selection.removeAll()
        for t in frameTargets {
            doc.clearKeyframe(layer: t.layer, frame: t.frame)
        }
        changed()
    }

    /// Slides the selected keyframes earlier or later in time, on whichever layers they are.
    func moveSelectedKeyframes(by delta: Int) {
        guard delta != 0 else { return }
        var moved = Set<FrameRef>()
        var touched = false
        for li in doc.layers.indices where !doc.layers[li].locked {
            var keys = doc.layers[li].keys
            var carried: [(Int, KeyFrame)] = []
            for ref in frameSelection where ref.layer == li {
                if let k = keys[ref.frame] {
                    carried.append((ref.frame, k))
                }
            }
            if carried.isEmpty { continue }
            if !touched {
                checkpoint()
                touched = true
            }
            for (f, _) in carried { keys[f] = nil }
            for (f, k) in carried {
                let target = max(0, f + delta)
                keys[target] = k
                moved.insert(FrameRef(layer: li, frame: target))
            }
            if keys[0] == nil { keys[0] = KeyFrame() }
            doc.layers[li].keys = keys
        }
        if !touched { return }
        selection.removeAll()
        doc.length = max(doc.length, doc.longestLayer)
        // The picked block travels with its keyframes.
        var shifted = Set<FrameRef>()
        for ref in frameSelection {
            shifted.insert(FrameRef(layer: ref.layer, frame: max(0, ref.frame + delta)))
        }
        frameSelection = shifted.union(moved)
        changed()
    }

    /// The frames a frame command applies to, grouped by layer.
    private var frameTargetsByLayer: [Int: Set<Int>] {
        var out: [Int: Set<Int>] = [:]
        for t in frameTargets {
            out[t.layer, default: []].insert(t.frame)
        }
        return out
    }

    /// Adds frames. With several frames picked in the timeline, each picked layer gets as
    /// many new frames as were picked on it, starting where its picked frames start.
    func insertFrame() {
        checkpoint()
        for (li, set) in frameTargetsByLayer {
            guard let first = set.min() else { continue }
            for _ in 0..<set.count {
                doc.insertFrame(layer: li, frame: first)
            }
        }
        changed()
    }

    /// Removes frames and closes the gap. With several frames picked in the timeline it
    /// removes all of them, on every layer they are on.
    func removeFrame() {
        checkpoint()
        selection.removeAll()
        let before = doc.length
        var counts: [Int: Int] = [:]
        for (li, set) in frameTargetsByLayer {
            let inside = set.filter { $0 < before }
            doc.removeFrames(layer: li, frames: inside)
            counts[li] = inside.count
        }
        // The animation only gets shorter by what came out of every unlocked layer.
        var shared = Int.max
        for li in doc.layers.indices where !doc.layers[li].locked {
            shared = min(shared, counts[li] ?? 0)
        }
        if shared == Int.max { shared = 0 }
        doc.length = max(1, doc.longestLayer, before - shared)
        frameSelection.removeAll()
        if frame > doc.length - 1 { frame = doc.length - 1 }
        changed()
    }

    func addLayer() {
        checkpoint()
        frameSelection.removeAll()
        selection.removeAll()
        let index = max(0, min(layer, doc.layers.count))
        doc.layers.insert(Layer(name: "Layer \(doc.layers.count + 1)"), at: index)
        layer = index
        changed()
    }

    func deleteLayer() {
        guard doc.layers.count > 1, doc.layers.indices.contains(layer) else {
            beep()
            return
        }
        checkpoint()
        frameSelection.removeAll()
        selection.removeAll()
        doc.layers.remove(at: layer)
        layer = max(0, min(layer, doc.layers.count - 1))
        doc.length = max(1, doc.length)
        changed()
    }

    /// Moves a layer to a new place in the stack (used when dragging it in the timeline).
    func moveLayer(from: Int, to: Int, checkpoint cp: Bool) {
        guard from != to, doc.layers.indices.contains(from), doc.layers.indices.contains(to) else { return }
        if cp { checkpoint() }
        selection.removeAll()
        frameSelection.removeAll()
        let moving = doc.layers.remove(at: from)
        doc.layers.insert(moving, at: to)
        if layer == from {
            layer = to
        } else if from < layer && to >= layer {
            layer -= 1
        } else if from > layer && to <= layer {
            layer += 1
        }
        changed()
    }

    func moveLayer(by delta: Int) {
        let target = layer + delta
        guard doc.layers.indices.contains(layer), doc.layers.indices.contains(target) else { return }
        checkpoint()
        frameSelection.removeAll()
        doc.layers.swapAt(layer, target)
        layer = target
        changed()
    }

    func renameLayer(_ name: String) {
        guard doc.layers.indices.contains(layer), !name.isEmpty else { return }
        checkpoint()
        doc.layers[layer].name = name
        changed()
    }

    var layerOpacity: CGFloat {
        guard doc.layers.indices.contains(layer) else { return 1 }
        return doc.layers[layer].alpha
    }

    /// Sets the current layer's opacity. One drag of the slider is one undo step.
    func setLayerOpacity(_ value: CGFloat) {
        guard doc.layers.indices.contains(layer) else { return }
        if fadingLayer != layer {
            checkpoint()
            fadingLayer = layer
        }
        doc.layers[layer].opacity = max(0, min(1, value))
        dirty = true
        changed()
    }

    func toggleVisible(_ index: Int) {
        guard doc.layers.indices.contains(index) else { return }
        checkpoint()
        doc.layers[index].visible.toggle()
        changed()
    }

    /// Turns a layer's clipping mask on or off. The bottom layer has nothing beneath it to
    /// clip to, so it can't be one.
    func toggleClip(_ index: Int) {
        guard doc.layers.indices.contains(index), index < doc.layers.count - 1 else {
            beep()
            return
        }
        checkpoint()
        doc.layers[index].clip = doc.layers[index].isClipped ? nil : true
        changed()
    }

    /// Makes a layer the reference layer, or stops it being one. Only one layer is the
    /// reference at a time.
    func toggleReference(_ index: Int) {
        guard doc.layers.indices.contains(index) else { return }
        checkpoint()
        let on = !doc.layers[index].isReference
        for i in doc.layers.indices {
            doc.layers[i].reference = nil
        }
        if on { doc.layers[index].reference = true }
        changed()
    }

    /// The reference layer, if there is one.
    var referenceLayer: Int? {
        return doc.layers.firstIndex { $0.isReference }
    }

    func toggleLocked(_ index: Int) {
        guard doc.layers.indices.contains(index) else { return }
        checkpoint()
        doc.layers[index].locked.toggle()
        changed()
    }

    // MARK: Library (symbols and bitmaps)

    private func addToLibrary(_ item: LibraryItem) {
        var lib = doc.items
        lib.append(item)
        doc.library = lib
        selectedItem = item.id
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(doc.items.map { $0.name })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Recomputes every instance's outline box, after the art inside a symbol changed.
    private func refreshInstanceBoxes() {
        let lib = doc.items
        func fix(_ shapes: [Shape]) -> [Shape] {
            return shapes.map { s in
                guard let item = doc.item(s.ref) else { return s }
                return Shape(instanceOf: item, transform: s.transform, library: lib)
            }
        }
        // Inner symbols first, so outer boxes are measured from fresh inner ones.
        for _ in 0..<3 {
            for i in doc.items.indices where doc.items[i].isSymbol {
                let fixed = fix(doc.items[i].shapes ?? [])
                doc.library?[i].shapes = fixed
            }
        }
        for li in doc.layers.indices {
            let keys = doc.layers[li].keys
            for (k, key) in keys {
                var fixed = key
                fixed.shapes = fix(key.shapes)
                doc.layers[li].keys[k] = fixed
            }
        }
    }

    /// Adds an image file to the library and places it on the stage.
    @discardableResult
    func importBitmap(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(source, 0, nil),
              img.width > 0, img.height > 0 else { return false }
        checkpoint()
        let name = uniqueName(url.deletingPathExtension().lastPathComponent)
        let item = LibraryItem(id: UUID().uuidString, name: name, kind: "bitmap", shapes: nil, image: data,
                               width: CGFloat(img.width), height: CGFloat(img.height))
        addToLibrary(item)
        placeInstance(of: item.id, checkpoint: false)
        return true
    }

    /// Puts an instance of a library item in the middle of the stage (shrunk to fit if
    /// it is larger than the stage).
    func placeInstance(of id: String?, checkpoint cp: Bool = true) {
        guard let item = doc.item(id), canEdit else {
            beep()
            return
        }
        if item.id == editingSymbol {
            beep()   // a symbol can't contain itself
            return
        }
        let box = item.bounds(in: doc.items)
        let fit = min(1, doc.width / max(1, box.width), doc.height / max(1, box.height))
        let scale = item.isSymbol ? 1 : fit
        var t = CGAffineTransform(translationX: doc.width / 2 - box.midX * scale, y: doc.height / 2 - box.midY * scale)
        t = t.scaledBy(x: scale, y: scale)
        let instance = Shape(instanceOf: item, transform: t, library: doc.items)
        var index = 0
        mutateShapes(checkpoint: cp) { shapes in
            index = shapes.count
            shapes.append(instance)
        }
        tool = .select
        selection = [index]
        changed()
    }

    /// Turns the selected art into a new symbol and leaves one instance of it in place.
    func convertSelectionToSymbol(named rawName: String) {
        // Art selected on other layers is brought onto this layer first, so the symbol
        // can hold all of it.
        let gathered = editingSymbol == nil && !extraSelection.isEmpty && canEdit
        if gathered {
            checkpoint()
            gatherSelection()
        }
        let shapes = currentShapes
        let picked = selection.filter { shapes.indices.contains($0) }.sorted()
        guard !picked.isEmpty, canEdit else {
            beep()
            return
        }
        var box = CGRect.null
        for i in picked { box = box.union(shapes[i].path.boundingBoxOfPath) }
        if box.isNull { return }
        // Symbol art is stored relative to its own top-left corner.
        var toLocal = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        var art: [Shape] = []
        for i in picked {
            var s = shapes[i]
            if let moved = s.path.copy(using: &toLocal) { s.path = moved }
            if var m = s.m, m.count == 6 {
                m[4] -= box.minX
                m[5] -= box.minY
                s.m = m
            }
            art.append(s)
        }
        if !gathered { checkpoint() }
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        let name = uniqueName(trimmed.isEmpty ? "Symbol" : trimmed)
        let item = LibraryItem(id: UUID().uuidString, name: name, kind: "symbol", shapes: art, image: nil,
                               width: box.width, height: box.height)
        addToLibrary(item)
        let instance = Shape(instanceOf: item, transform: CGAffineTransform(translationX: box.minX, y: box.minY),
                             library: doc.items)
        let first = picked[0]
        let chosen = Set(picked)
        var newIndex = 0
        mutateShapes(checkpoint: false) { all in
            var out: [Shape] = []
            for (i, s) in all.enumerated() {
                if i == first {
                    newIndex = out.count
                    out.append(instance)
                } else if !chosen.contains(i) {
                    out.append(s)
                }
            }
            all = out
        }
        tool = .select
        selection = [newIndex]
        changed()
    }

    /// Replaces selected symbol instances with loose copies of their art.
    func breakApart() {
        let shapes = currentShapes
        let lib = doc.items
        let picked = selection.filter { shapes.indices.contains($0) && doc.item(shapes[$0].ref)?.isSymbol == true }
        guard !picked.isEmpty, canEdit else {
            beep()
            return
        }
        selection.removeAll()
        mutateShapes { all in
            var out: [Shape] = []
            for (i, s) in all.enumerated() {
                guard picked.contains(i), let item = doc.item(s.ref) else {
                    out.append(s)
                    continue
                }
                var t = s.transform
                for inner in item.shapes ?? [] {
                    if let innerItem = doc.item(inner.ref) {
                        out.append(Shape(instanceOf: innerItem, transform: inner.transform.concatenating(t), library: lib))
                    } else if let moved = inner.path.copy(using: &t) {
                        out.append(Shape(path: moved, color: inner.color))
                    }
                }
            }
            all = out
        }
    }

    func renameItem(_ id: String?, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard let index = doc.items.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        checkpoint()
        doc.library?[index].name = name
        changed()
    }

    /// Removes an item from the library along with every instance of it.
    func deleteItem(_ id: String?) {
        guard let id = id, doc.item(id) != nil else { return }
        checkpoint()
        if editingSymbol == id { editingSymbol = nil }
        selection.removeAll()
        doc.library = doc.items.filter { $0.id != id }
        for i in doc.items.indices {
            if let art = doc.items[i].shapes {
                let kept = art.filter { $0.ref != id }
                doc.library?[i].shapes = kept
            }
        }
        for li in doc.layers.indices {
            let keys = doc.layers[li].keys
            for (k, key) in keys {
                var kept = key
                kept.shapes = key.shapes.filter { $0.ref != id }
                doc.layers[li].keys[k] = kept
            }
        }
        if selectedItem == id { selectedItem = nil }
        refreshInstanceBoxes()
        changed()
    }

    func enterEdit(_ id: String?) {
        guard let item = doc.item(id), item.isSymbol else {
            beep()
            return
        }
        stop()
        selection.removeAll()
        editingSymbol = item.id
        selectedItem = item.id
        changed()
    }

    func exitEdit() {
        guard editingSymbol != nil else { return }
        selection.removeAll()
        editingSymbol = nil
        refreshInstanceBoxes()
        changed()
    }

    // MARK: Audio

    var audioName: String? {
        guard let path = doc.audioPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// True when the document names a soundtrack that could not be opened.
    var audioMissing: Bool {
        return doc.audioPath != nil && player == nil
    }

    private func loadAudio() {
        player?.stop()
        player = nil
        audioPeaks = []
        loadedAudioPath = doc.audioPath
        guard let path = doc.audioPath else { return }
        let url = AppState.audioFile(path)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.prepareToPlay()
        player = p
        audioPeaks = AppState.readPeaks(url: url, perSecond: peaksPerSecond)
    }

    /// Loudest sample in each slice of the file, for the timeline's waveform.
    private static func readPeaks(url: URL, perSecond: Double) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let binSize = max(1, Int(format.sampleRate / perSecond))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { return [] }
        var out: [Float] = []
        var peak: Float = 0
        var count = 0
        while true {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            let samples = channels[0]
            for i in 0..<n {
                let v = abs(samples[i])
                if v > peak { peak = v }
                count += 1
                if count >= binSize {
                    out.append(peak)
                    peak = 0
                    count = 0
                }
            }
        }
        return out
    }

    func audioPeak(atFrame f: Int) -> Float {
        let fps = Double(max(1, doc.fps))
        let a = Int(Double(f) / fps * peaksPerSecond)
        let b = max(a + 1, Int(Double(f + 1) / fps * peaksPerSecond))
        if a >= audioPeaks.count { return 0 }
        var m: Float = 0
        for i in a..<min(b, audioPeaks.count) {
            m = max(m, audioPeaks[i])
        }
        return m
    }

    /// Attaches a soundtrack and stretches the timeline to cover it. Returns false if the
    /// file can't be played.
    @discardableResult
    func importAudio(_ url: URL) -> Bool {
        stop()
        let previous = doc.audioPath
        checkpoint()
        doc.audioPath = AppState.audioReference(url)
        loadAudio()
        guard let p = player else {
            doc.audioPath = previous
            loadAudio()
            changed()
            return false
        }
        let frames = Int((p.duration * Double(max(1, doc.fps))).rounded(.up))
        doc.length = max(doc.length, min(9999, frames))
        changed()
        return true
    }

    func removeAudio() {
        guard doc.audioPath != nil else { return }
        stop()
        checkpoint()
        doc.audioPath = nil
        loadAudio()
        changed()
    }

    /// The soundtrack file, when one is attached and playable.
    var audioURL: URL? {
        guard player != nil, let path = doc.audioPath else { return nil }
        return AppState.audioFile(path)
    }

    /// Plays a short slice of the soundtrack at the current frame, for scrubbing.
    private func scrubAudio() {
        guard timer == nil, let p = player else { return }
        scrubTimer?.invalidate()
        scrubTimer = nil
        let fps = Double(max(1, doc.fps))
        let t = Double(frame) / fps
        if t >= p.duration {
            p.pause()
            return
        }
        p.currentTime = t
        p.play()
        let slice = Timer(timeInterval: max(0.09, 2.0 / fps), repeats: false) { [weak self] _ in
            guard let self = self, self.timer == nil else { return }
            self.player?.pause()
        }
        RunLoop.main.add(slice, forMode: .common)
        scrubTimer = slice
    }

    private func startAudio() {
        guard let p = player else { return }
        let t = Double(frame) / Double(max(1, doc.fps))
        if t < p.duration {
            p.currentTime = t
            p.play()
        }
    }

    /// One playback tick. While the soundtrack is running it sets the pace, so picture
    /// and sound can't drift apart.
    private func advance() {
        let length = max(1, doc.length)
        // Normally the whole animation plays; the graph editor can narrow it to one tween.
        let first = max(0, min(length - 1, playRange?.lowerBound ?? 0))
        let last = max(first, min(length - 1, playRange?.upperBound ?? (length - 1)))
        let repeats = loopPlayback || playRange != nil
        let fps = Double(max(1, doc.fps))
        if let p = player, p.isPlaying {
            let f = Int(p.currentTime * fps)
            if f <= last {
                frame = max(first, f)
            } else if repeats {
                p.currentTime = Double(first) / fps
                frame = first
            } else {
                frame = last
                stop()
            }
            return
        }
        if frame + 1 > last {
            if repeats {
                frame = first
                startAudio()
            } else {
                frame = last
                stop()
            }
            return
        }
        frame += 1
    }

    // MARK: Document settings

    func setStageSize(width: Int, height: Int) {
        let w = CGFloat(max(16, min(8192, width)))
        let h = CGFloat(max(16, min(8192, height)))
        if w == doc.width && h == doc.height { return }
        checkpoint()
        doc.width = w
        doc.height = h
        changed()
    }

    /// Sets the stage's background colour. One drag in the colour picker is one undo step.
    func setBackground(_ c: RGBA) {
        var solid = c
        solid.a = 1
        if solid == doc.background { return }
        if !backgroundEdit {
            checkpoint()
            backgroundEdit = true
        }
        doc.background = solid
        dirty = true
        changed()
    }

    func applyDocumentSettings(width: Int, height: Int, fps: Int, background: RGBA) {
        checkpoint()
        doc.width = CGFloat(max(16, min(8192, width)))
        doc.height = CGFloat(max(16, min(8192, height)))
        doc.background = background
        setFPS(fps)
        changed()
    }

    // MARK: Storyboard

    var boardLayer: Int? {
        return doc.layers.firstIndex { $0.isBoard == true }
    }

    /// The board's panels in order: each keyframe on the storyboard layer, with the
    /// number of frames it is held for.
    var boardPanels: [BoardPanel] {
        guard let li = boardLayer else { return [] }
        let layer = doc.layers[li]
        let starts = layer.keys.keys.sorted()
        var out: [BoardPanel] = []
        for (n, k) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : max(doc.length, k + 1)
            out.append(BoardPanel(start: k, length: end - k, note: layer.keys[k]?.note ?? ""))
        }
        return out
    }

    /// The panel the playhead is in.
    var currentPanel: Int? {
        return boardPanels.lastIndex { $0.start <= frame }
    }

    private func boardItems() -> [(key: KeyFrame, length: Int)] {
        guard let li = boardLayer else { return [] }
        var out: [(key: KeyFrame, length: Int)] = []
        for p in boardPanels {
            out.append((key: doc.layers[li].keys[p.start] ?? KeyFrame(), length: p.length))
        }
        return out
    }

    /// Lays the panels back onto the storyboard layer end to end, then shows panel `index`.
    private func writeBoard(_ items: [(key: KeyFrame, length: Int)], show index: Int?) {
        guard let li = boardLayer else { return }
        var keys: [Int: KeyFrame] = [:]
        var starts: [Int] = []
        var at = 0
        for item in items {
            keys[at] = item.key
            starts.append(at)
            at += max(1, item.length)
        }
        if keys[0] == nil { keys[0] = KeyFrame() }
        doc.layers[li].keys = keys
        var needed = 1
        for (i, l) in doc.layers.enumerated() where i != li {
            needed = max(needed, l.lastKey + 1)
        }
        doc.length = max(at, needed)
        selection.removeAll()
        frameSelection.removeAll()
        layer = li
        if let i = index, starts.indices.contains(i) {
            frame = starts[i]
        } else if frame > doc.length - 1 {
            frame = doc.length - 1
        }
        changed()
    }

    /// Adds a blank panel after the current one, creating the storyboard layer if needed.
    func addPanel() {
        stop()
        checkpoint()
        let hold = max(1, doc.fps * 2)
        if boardLayer == nil {
            var board = Layer(name: "Storyboard")
            board.isBoard = true
            doc.layers.insert(board, at: 0)
            doc.length = max(doc.length, hold)
            selection.removeAll()
            frameSelection.removeAll()
            layer = 0
            frame = 0
            tool = .brush
            changed()
            return
        }
        var items = boardItems()
        let place = min(items.count, (currentPanel ?? items.count - 1) + 1)
        items.insert((key: KeyFrame(), length: hold), at: place)
        writeBoard(items, show: place)
    }

    func duplicatePanel() {
        guard let i = currentPanel else {
            beep()
            return
        }
        stop()
        checkpoint()
        var items = boardItems()
        guard items.indices.contains(i) else { return }
        items.insert(items[i], at: i + 1)
        writeBoard(items, show: i + 1)
    }

    func deletePanel() {
        var items = boardItems()
        guard let i = currentPanel, items.indices.contains(i), items.count > 1 else {
            beep()
            return
        }
        stop()
        checkpoint()
        items.remove(at: i)
        writeBoard(items, show: min(i, items.count - 1))
    }

    func movePanel(by delta: Int) {
        var items = boardItems()
        guard let i = currentPanel, items.indices.contains(i), items.indices.contains(i + delta) else {
            beep()
            return
        }
        stop()
        checkpoint()
        items.swapAt(i, i + delta)
        writeBoard(items, show: i + delta)
    }

    /// Sets how many frames the current panel is held for; later panels move to suit.
    func setPanelLength(_ frames: Int) {
        var items = boardItems()
        guard let i = currentPanel, items.indices.contains(i) else { return }
        let length = max(1, min(2000, frames))
        if items[i].length == length { return }
        stop()
        checkpoint()
        items[i].length = length
        writeBoard(items, show: i)
    }

    func setPanelNote(_ text: String) {
        guard let li = boardLayer, let i = currentPanel else { return }
        let panels = boardPanels
        guard panels.indices.contains(i), panels[i].note != text else { return }
        checkpoint()
        doc.layers[li].keys[panels[i].start]?.note = text.isEmpty ? nil : text
        changed()
    }

    // MARK: Tweens

    /// The easing of the tween covering the current frame on the current layer, if any.
    var currentTweenEase: String? {
        guard doc.layers.indices.contains(layer) else { return nil }
        let k = doc.layers[layer].keyIndex(at: frame)
        return doc.layers[layer].keys[k]?.tween?.ease
    }

    var currentTween: Tween? {
        guard doc.layers.indices.contains(layer) else { return nil }
        let k = doc.layers[layer].keyIndex(at: frame)
        return doc.layers[layer].keys[k]?.tween
    }

    /// The tween the graph editor is showing: the one being looped, or else the one under
    /// the playhead on the current layer.
    var graphSpan: (start: Int, end: Int, tween: Tween)? {
        guard doc.layers.indices.contains(layer) else { return nil }
        if let r = playRange, let t = doc.layers[layer].keys[r.lowerBound]?.tween {
            return (r.lowerBound, r.upperBound, t)
        }
        return doc.layers[layer].tweenSpan(at: frame)
    }

    var graphTween: Tween? {
        return graphSpan?.tween ?? currentTween
    }

    /// The keyframe whose tween the graph editor edits.
    private var graphKey: Int? {
        guard doc.layers.indices.contains(layer) else { return nil }
        return playRange?.lowerBound ?? doc.layers[layer].keyIndex(at: frame)
    }

    /// Plays just the tween under the playhead, over and over, so its easing can be
    /// adjusted while watching it.
    func playTween() {
        guard let span = graphSpan, span.end > span.start else {
            beep()
            return
        }
        stop()
        playRange = span.start...span.end
        frame = span.start
        selection.removeAll()
        play()
    }

    /// Sets one of the named easings on the tween the graph editor is showing.
    func setGraphEase(_ id: String) {
        guard let k = graphKey, doc.layers[layer].keys[k]?.tween != nil else {
            beep()
            return
        }
        checkpoint()
        doc.layers[layer].keys[k]?.tween = Tween(ease: id)
        changed()
    }

    /// Gives the tween at the playhead a custom easing curve (x1, y1, x2, y2). A run of
    /// calls while dragging a handle counts as one undo step; `endCurveEdit` closes it.
    func setTweenCurve(_ c: [CGFloat]) {
        guard doc.layers.indices.contains(layer), c.count == 4, let k = graphKey else { return }
        guard doc.layers[layer].keys[k]?.tween != nil else {
            beep()
            return
        }
        let id = "\(layer):\(k)"
        if curveEdit != id {
            checkpoint()
            curveEdit = id
        }
        doc.layers[layer].keys[k]?.tween = Tween(ease: "custom", curve: c)
        dirty = true
        changed()
    }

    func endCurveEdit() {
        curveEdit = nil
    }

    /// Starts (or re-eases) a tween from the keyframe governing the current frame to the
    /// next keyframe on this layer. Pass nil to remove it.
    func setTween(ease: String?) {
        guard doc.layers.indices.contains(layer), !doc.layers[layer].locked else {
            beep()
            return
        }
        checkpoint()
        selection.removeAll()
        for t in frameTargets {
            let k = doc.layers[t.layer].keyIndex(at: t.frame)
            guard doc.layers[t.layer].keys[k] != nil else { continue }
            if let ease = ease {
                doc.layers[t.layer].keys[k]?.tween = Tween(ease: ease)
            } else {
                doc.layers[t.layer].keys[k]?.tween = nil
            }
        }
        changed()
    }

    // MARK: Onion skin

    /// The neighbouring frames to ghost: frame, opacity, and whether it is a later one.
    /// Faintest first, so nearer ghosts draw on top.
    func onionFrames() -> [(frame: Int, alpha: CGFloat, later: Bool)] {
        let o = onion
        let before = max(0, min(OnionSettings.maxRange, o.before))
        let after = max(0, min(OnionSettings.maxRange, o.after))
        var out: [(frame: Int, alpha: CGFloat, later: Bool)] = []
        var d = 1
        while d <= before {
            if frame - d >= 0 {
                out.append((frame: frame - d, alpha: o.opacityBefore * pow(0.75, CGFloat(d - 1)), later: false))
            }
            d += 1
        }
        d = 1
        while d <= after {
            if frame + d < doc.length {
                out.append((frame: frame + d, alpha: o.opacityAfter * pow(0.75, CGFloat(d - 1)), later: true))
            }
            d += 1
        }
        return out.sorted { $0.alpha < $1.alpha }
    }

    /// Sets how many earlier and later frames the onion skin shows.
    func setOnionRange(before: Int? = nil, after: Int? = nil) {
        var o = onion
        if let b = before { o.before = max(0, min(OnionSettings.maxRange, b)) }
        if let a = after { o.after = max(0, min(OnionSettings.maxRange, a)) }
        if o.before == onion.before && o.after == onion.after { return }
        onion = o
        changed()
    }

    // MARK: Playback

    func play() {
        guard timer == nil, doc.length > 1 else { return }
        selection.removeAll()
        // With looping off, pressing Play on the last frame starts again from the top.
        if !loopPlayback && frame >= doc.length - 1 { frame = 0 }
        let interval = 1.0 / Double(max(1, doc.fps))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.advance()
            self.changed()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scrubTimer?.invalidate()
        scrubTimer = nil
        startAudio()
        changed()
    }

    func stop() {
        guard let t = timer else { return }
        t.invalidate()
        timer = nil
        playRange = nil
        player?.pause()
        changed()
    }

    func togglePlay() {
        if isPlaying { stop() } else { play() }
    }

    func setFPS(_ fps: Int) {
        let clamped = max(1, min(60, fps))
        if clamped == doc.fps { return }
        doc.fps = clamped
        dirty = true
        if isPlaying {
            stop()
            play()
        } else {
            changed()
        }
    }
}
