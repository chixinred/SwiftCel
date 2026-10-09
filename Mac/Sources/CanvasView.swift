import AppKit

final class CanvasView: NSView {
    let state: AppState

    private(set) var zoom: CGFloat = 1
    private var pan = CGPoint(x: 40, y: 40)
    private var cache: CGImage?
    private var needsFit = true

    // In-progress gesture
    private var activeTool: Tool?
    private var stroke: [StrokePoint] = []
    private var sprayed = Set<Int64>()

    // Transform tool: what was grabbed, the selection box at that moment, and how much
    // of the gesture has been applied so far.
    private enum Grab {
        case move
        case rotate
        case scale(Int)
    }
    private var grab: Grab?
    private var grabBox = CGRect.zero
    private var grabApplied = CGAffineTransform.identity
    private let handleX: [CGFloat] = [0, 0.5, 1, 1, 1, 0.5, 0, 0]
    private let handleY: [CGFloat] = [0, 0, 0, 0.5, 1, 1, 1, 0.5]
    private var live: CGMutablePath?
    private var dragStartView = CGPoint.zero
    private var dragStartDoc = CGPoint.zero
    private var lastDoc = CGPoint.zero
    private var currentDoc = CGPoint.zero
    private var panStart = CGPoint.zero
    private var movingSelection = false
    private var movedCheckpoint = false
    private var marquee: CGRect?
    /// The lasso loop being drawn, in view coordinates.
    private var lassoPoints: [NSPoint] = []
    private var hover: CGPoint?
    private var spaceDown = false
    private var shiftDown = false
    private var commandDown = false
    private var tracking: NSTrackingArea?
    private var clipAction: Action?
    private let clipButton = NSButton(title: "", target: nil, action: nil)

    init(state: AppState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        state.observe { [weak self] in
            guard let self = self else { return }
            self.clipButton.state = self.state.clipToStage ? .on : .off
            self.invalidate()
        }

        // Corner button: show only what is inside the stage.
        let action = Action { [weak self] in
            guard let self = self else { return }
            self.state.clipToStage = self.clipButton.state == .on
            self.state.changed()
        }
        clipAction = action
        clipButton.target = action
        clipButton.action = #selector(Action.fire)
        clipButton.setButtonType(.pushOnPushOff)
        clipButton.bezelStyle = .smallSquare
        if let img = NSImage(systemSymbolName: "crop", accessibilityDescription: "Show only the stage") {
            clipButton.image = img
            clipButton.imagePosition = .imageOnly
        } else {
            clipButton.title = "▣"
        }
        clipButton.toolTip = "Show only what is inside the stage"
        clipButton.refusesFirstResponder = true
        addSubview(clipButton)
        placeClipButton()
    }

    private func placeClipButton() {
        clipButton.frame = NSRect(x: max(0, bounds.width - 34), y: 8, width: 26, height: 24)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }
    override var acceptsFirstResponder: Bool { return true }
    override var isOpaque: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    func invalidate() {
        cache = nil
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeClipButton()
        invalidate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor.crosshair)
    }

    /// Screen pixels per point of this view, including any enlargement of the interface.
    private var pixelScale: CGFloat {
        let s = convertToBacking(NSSize(width: 1, height: 1)).width
        return s > 0 ? s : 2
    }

    // MARK: Coordinates

    private func toDoc(_ v: CGPoint) -> CGPoint {
        return CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom)
    }

    private func viewPoint(_ e: NSEvent) -> CGPoint {
        return convert(e.locationInWindow, from: nil)
    }

    func zoomBy(_ factor: CGFloat, at v: CGPoint) {
        let d = toDoc(v)
        zoom = max(0.05, min(64, zoom * factor))
        pan = CGPoint(x: v.x - d.x * zoom, y: v.y - d.y * zoom)
        state.zoom = zoom
        state.changed()
    }

    func zoomCentered(by factor: CGFloat) {
        zoomBy(factor, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func setZoom(_ z: CGFloat) {
        zoomCentered(by: z / zoom)
    }

    @discardableResult
    private func applyFit() -> Bool {
        let doc = state.doc
        guard bounds.width > 100, bounds.height > 100 else { return false }
        let z = min((bounds.width - 80) / doc.width, (bounds.height - 80) / doc.height)
        zoom = max(0.05, min(64, z))
        pan = CGPoint(x: (bounds.width - doc.width * zoom) / 2, y: (bounds.height - doc.height * zoom) / 2)
        needsFit = false
        state.zoom = zoom
        return true
    }

    func fit() {
        if applyFit() { state.changed() }
    }

    // MARK: Drawing

    private func drawScene(in ctx: CGContext) {
        let doc = state.doc
        ctx.setFillColor(Theme.pasteboard.cgColor)
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)

        let stage = CGRect(x: 0, y: 0, width: doc.width, height: doc.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: CGColor(gray: 0, alpha: 0.55))
        ctx.setFillColor(doc.background.cgColor)
        ctx.fill(stage)
        ctx.restoreGState()

        ctx.saveGState()
        if state.clipToStage { ctx.clip(to: stage) }

        if state.onionSkin && !state.isPlaying {
            let earlierTint = state.onion.tintBefore.cgColor
            let laterTint = state.onion.tintAfter.cgColor
            for ghost in state.onionFrames() {
                ctx.saveGState()
                ctx.setAlpha(max(0.02, min(1, ghost.alpha)))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                Renderer.drawFrame(doc, frame: ghost.frame, in: ctx)
                if state.onion.tint {
                    // Recolour only what this ghost drew.
                    ctx.setBlendMode(.sourceAtop)
                    ctx.setFillColor(ghost.later ? laterTint : earlierTint)
                    ctx.fill(ctx.boundingBoxOfClipPath)
                }
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }

        if let symbol = doc.item(state.editingSymbol) {
            // Editing a symbol: the scene is ghosted and the symbol's own art is shown alone.
            ctx.saveGState()
            ctx.setAlpha(0.18)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            Renderer.drawFrame(doc, frame: state.frame, in: ctx)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            Renderer.drawShapes(symbol.shapes ?? [], doc: doc, in: ctx)
        } else {
            Renderer.drawFrame(doc, frame: state.frame, in: ctx)
        }
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
        ctx.setLineWidth(1 / zoom)
        ctx.stroke(stage)
        ctx.restoreGState()
    }

    private func rebuildCache() {
        let scale = pixelScale
        let w = Int((bounds.width * scale).rounded())
        let h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        drawScene(in: ctx)
        cache = ctx.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if needsFit && applyFit() {
            // Tell the panels about the new zoom once this drawing pass is over.
            DispatchQueue.main.async { [weak self] in
                self?.state.changed()
            }
        }
        if cache == nil { rebuildCache() }
        if let img = cache {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)
        if state.clipToStage {
            ctx.clip(to: CGRect(x: 0, y: 0, width: state.doc.width, height: state.doc.height))
        }

        // Stroke in progress
        if let tool = activeTool {
            let ink = tool == .eraser ? state.doc.background.cgColor : state.color.cgColor
            switch tool {
            case .brush, .eraser, .pencil:
                if let l = live {
                    ctx.addPath(l)
                    ctx.setFillColor(ink)
                    ctx.fillPath(using: .winding)
                }
            case .line:
                ctx.beginPath()
                ctx.move(to: dragStartDoc)
                ctx.addLine(to: currentDoc)
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(state.size)
                ctx.setLineCap(.round)
                ctx.strokePath()
            case .rect:
                ctx.setFillColor(ink)
                ctx.fill(dragRect())
            case .oval:
                ctx.setFillColor(ink)
                ctx.fillEllipse(in: dragRect())
            default:
                break
            }
        }

        // Selection highlight
        let chosen = state.selectedShapes
        if !chosen.isEmpty {
            for shape in chosen {
                ctx.addPath(shape.path)
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.3))
                ctx.fillPath(using: .winding)
                ctx.addPath(shape.path)
                ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 1))
                ctx.setLineWidth(1.5 / zoom)
                ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
                ctx.strokePath()
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()

        drawTransformBox(in: ctx)

        if let m = marquee {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.stroke(m)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if lassoPoints.count > 1 {
            // The lasso loop, closed back to where it started.
            ctx.beginPath()
            ctx.addLines(between: lassoPoints)
            ctx.closePath()
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 0.08))
            ctx.fillPath(using: .winding)
            ctx.beginPath()
            ctx.addLines(between: lassoPoints)
            ctx.closePath()
            ctx.setLineWidth(1)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.strokePath()
            ctx.beginPath()
            ctx.addLines(between: lassoPoints)
            ctx.closePath()
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.85))
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if let symbol = state.doc.item(state.editingSymbol) {
            let note = "Editing symbol \u{201C}\(symbol.name)\u{201D}  -  press Esc or double-click empty space when done"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.white
            ]
            let size = (note as NSString).size(withAttributes: attrs)
            let pill = NSRect(x: 12, y: 10, width: size.width + 20, height: size.height + 8)
            Theme.accent.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            (note as NSString).draw(at: NSPoint(x: pill.minX + 10, y: pill.minY + 4), withAttributes: attrs)
        }

        // Brush-size ring under the pointer
        if let h = hover, activeTool == nil, !spaceDown, state.tool == .brush || state.tool == .eraser || state.tool == .pencil {
            let r = max(1, state.size / 2 * zoom)
            let ring = CGRect(x: h.x - r, y: h.y - r, width: r * 2, height: r * 2)
            ctx.setLineWidth(1)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.strokeEllipse(in: ring.insetBy(dx: -1, dy: -1))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
            ctx.strokeEllipse(in: ring)
        }
    }

    private func dragRect() -> CGRect {
        var dx = currentDoc.x - dragStartDoc.x
        var dy = currentDoc.y - dragStartDoc.y
        if shiftDown {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: min(dragStartDoc.x, dragStartDoc.x + dx), y: min(dragStartDoc.y, dragStartDoc.y + dy),
                      width: abs(dx), height: abs(dy))
    }

    // MARK: Mouse and tablet

    private func addStrokePoint(_ d: CGPoint, event e: NSEvent, force: Bool = false) {
        var pressure: CGFloat = 1
        if state.usePressure && e.subtype == .tabletPoint {
            pressure = 0.12 + 0.88 * max(0, min(1, CGFloat(e.pressure)))
        }
        let r = max(0.25, state.size / 2 * pressure)
        let sp = StrokePoint(p: d, r: r)
        if let last = stroke.last {
            let gap = (d - last.p).length
            if !force && gap < max(0.75 / zoom, r * 0.12) { return }
            if activeTool == .pencil {
                if let l = live { Brush.addSpray(l, from: last.p, to: d, radius: r, seen: &sprayed) }
            } else {
                live?.addPath(dabPath(from: last, to: sp))
            }
        } else if activeTool == .pencil {
            if let l = live { Brush.addSpray(l, from: d, to: d, radius: r, seen: &sprayed) }
        } else {
            live?.addPath(dabPath(from: sp, to: sp))
        }
        stroke.append(sp)
    }

    /// Turns a finished stroke into a fill, with the legacy or the modern brush.
    private func strokeShape(_ points: [StrokePoint], smoothing: CGFloat) -> CGPath? {
        if state.legacyBrush {
            return Brush.smoothedShape(points: points, smoothing: smoothing, zoom: zoom)
        }
        return Brush.modernShape(points: points, smoothing: smoothing, zoom: zoom)
    }

    // MARK: Transform tool

    private func toView(_ d: CGPoint) -> CGPoint {
        return CGPoint(x: d.x * zoom + pan.x, y: d.y * zoom + pan.y)
    }

    private func handlePoint(_ i: Int, in box: CGRect) -> CGPoint {
        return CGPoint(x: box.minX + handleX[i] * box.width, y: box.minY + handleY[i] * box.height)
    }

    /// The round rotation knob sits a little above the top edge of the box.
    private func rotateKnob(for box: CGRect) -> CGPoint {
        let top = toView(CGPoint(x: box.midX, y: box.minY))
        return CGPoint(x: top.x, y: top.y - 26)
    }

    private func grabAt(_ v: CGPoint, box: CGRect) -> Grab? {
        let knob = rotateKnob(for: box)
        if hypot(v.x - knob.x, v.y - knob.y) < 9 { return .rotate }
        for i in 0..<8 {
            let h = toView(handlePoint(i, in: box))
            if hypot(v.x - h.x, v.y - h.y) < 8 { return .scale(i) }
        }
        if box.insetBy(dx: -2 / zoom, dy: -2 / zoom).contains(toDoc(v)) { return .move }
        return nil
    }

    /// The whole transform for the gesture so far, from where it started to `d`.
    private func transformFor(_ g: Grab, to d: CGPoint) -> CGAffineTransform {
        let box = grabBox
        switch g {
        case .move:
            return CGAffineTransform(translationX: d.x - dragStartDoc.x, y: d.y - dragStartDoc.y)
        case .rotate:
            let c = CGPoint(x: box.midX, y: box.midY)
            let from = atan2(dragStartDoc.y - c.y, dragStartDoc.x - c.x)
            var angle = atan2(d.y - c.y, d.x - c.x) - from
            if shiftDown {
                let step = CGFloat.pi / 12
                angle = (angle / step).rounded() * step
            }
            return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y)
        case .scale(let i):
            let anchor = handlePoint((i + 4) % 8, in: box)
            let handle = handlePoint(i, in: box)
            let corner = handleX[i] != 0.5 && handleY[i] != 0.5
            if commandDown && !corner {
                // Command-dragging a side square slants the art: the grabbed edge slides
                // along itself while the opposite edge stays put.
                var slant = CGAffineTransform.identity
                if handleX[i] == 0.5 {
                    let span = handle.y - anchor.y
                    if abs(span) > 0.001 { slant.c = (d.x - dragStartDoc.x) / span }
                } else {
                    let span = handle.x - anchor.x
                    if abs(span) > 0.001 { slant.b = (d.y - dragStartDoc.y) / span }
                }
                return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                    .concatenating(slant)
                    .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
            }
            var sx: CGFloat = 1
            var sy: CGFloat = 1
            if handleX[i] != 0.5 {
                let span = handle.x - anchor.x
                if abs(span) > 0.001 { sx = (d.x - anchor.x) / span }
            }
            if handleY[i] != 0.5 {
                let span = handle.y - anchor.y
                if abs(span) > 0.001 { sy = (d.y - anchor.y) / span }
            }
            if corner && shiftDown {
                let u = max(abs(sx), abs(sy))
                sx = sx < 0 ? -u : u
                sy = sy < 0 ? -u : u
            }
            if abs(sx) < 0.01 { sx = sx < 0 ? -0.01 : 0.01 }
            if abs(sy) < 0.01 { sy = sy < 0 ? -0.01 : 0.01 }
            return CGAffineTransform(translationX: anchor.x, y: anchor.y).scaledBy(x: sx, y: sy)
                .translatedBy(x: -anchor.x, y: -anchor.y)
        }
    }

    private func drawTransformBox(in ctx: CGContext) {
        guard state.tool == .transform, let box = state.selectionBox else { return }
        let a = toView(CGPoint(x: box.minX, y: box.minY))
        let b = toView(CGPoint(x: box.maxX, y: box.maxY))
        let frame = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let knob = rotateKnob(for: box)
        let blue = CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 1)
        ctx.setStrokeColor(blue)
        ctx.setLineWidth(1)
        ctx.stroke(frame)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: frame.midX, y: frame.minY))
        ctx.addLine(to: knob)
        ctx.strokePath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for i in 0..<8 {
            let h = toView(handlePoint(i, in: box))
            let r = CGRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)
            ctx.fill(r)
            ctx.stroke(r)
        }
        let dot = CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10)
        ctx.fillEllipse(in: dot)
        ctx.strokeEllipse(in: dot)
    }

    private func dabPath(from a: StrokePoint, to b: StrokePoint) -> CGPath {
        let p = CGMutablePath()
        Brush.addDab(p, from: a, to: b)
        return p
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let v = viewPoint(e)
        let d = toDoc(v)
        dragStartView = v
        dragStartDoc = d
        lastDoc = d
        currentDoc = d
        shiftDown = e.modifierFlags.contains(.shift)
        commandDown = e.modifierFlags.contains(.command)
        let tool: Tool = spaceDown ? .hand : state.tool
        if state.isPlaying { state.stop() }

        switch tool {
        case .hand:
            activeTool = .hand
            panStart = pan
        case .brush, .eraser, .pencil:
            guard state.canEdit else {
                NSSound.beep()
                return
            }
            activeTool = tool
            stroke = []
            sprayed.removeAll()
            live = CGMutablePath()
            addStrokePoint(d, event: e, force: true)
        case .line, .rect, .oval:
            guard state.canEdit else {
                NSSound.beep()
                return
            }
            activeTool = tool
        case .bucket:
            state.bucket(at: d)
        case .eyedropper:
            state.pickColor(at: d)
        case .transform:
            guard state.canEdit else {
                NSSound.beep()
                return
            }
            movedCheckpoint = false
            grab = nil
            if let box = state.selectionBox {
                grab = grabAt(v, box: box)
            }
            if grab == nil {
                // Nothing grabbed: click art to select it, or empty space to deselect.
                if let hit = state.hitAny(d) {
                    if shiftDown {
                        if !state.isSelected(layer: hit.layer, index: hit.index) {
                            state.toggleSelected(layer: hit.layer, index: hit.index)
                        }
                    } else {
                        state.selectOnly(layer: hit.layer, index: hit.index)
                    }
                    grab = .move
                } else {
                    state.selection.removeAll()
                }
            }
            if grab != nil, let box = state.selectionBox {
                activeTool = .transform
                grabBox = box
                grabApplied = CGAffineTransform.identity
            }
        case .lasso:
            guard state.canEdit else {
                NSSound.beep()
                return
            }
            movedCheckpoint = false
            if let hit = state.hitAny(d), state.isSelected(layer: hit.layer, index: hit.index) {
                // Dragging what the lasso picked moves it, as with the Selection tool.
                activeTool = .select
                movingSelection = true
            } else {
                activeTool = .lasso
                lassoPoints = [v]
            }
        case .select:
            activeTool = .select
            movedCheckpoint = false
            if e.clickCount == 2 {
                // Double-click a symbol to edit it; double-click empty space to finish.
                if let hit = state.hitAny(d) {
                    if hit.layer != state.layer { state.selectOnly(layer: hit.layer, index: hit.index) }
                    let shapes = state.currentShapes
                    if shapes.indices.contains(hit.index), state.doc.item(shapes[hit.index].ref)?.isSymbol == true {
                        activeTool = nil
                        state.enterEdit(shapes[hit.index].ref)
                        return
                    }
                } else if state.editingSymbol != nil {
                    activeTool = nil
                    state.exitEdit()
                    return
                }
            }
            if let hit = state.hitAny(d) {
                // Art on any layer can be clicked. Shift adds to (or removes from) the
                // selection, even across layers.
                if shiftDown {
                    state.toggleSelected(layer: hit.layer, index: hit.index)
                } else if !state.isSelected(layer: hit.layer, index: hit.index) {
                    state.selectOnly(layer: hit.layer, index: hit.index)
                }
                movingSelection = state.hasSelection
            } else {
                if !shiftDown { state.selection.removeAll() }
                movingSelection = false
                marquee = CGRect(origin: v, size: .zero)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let tool = activeTool else { return }
        let v = viewPoint(e)
        let d = toDoc(v)
        currentDoc = d
        shiftDown = e.modifierFlags.contains(.shift)
        commandDown = e.modifierFlags.contains(.command)
        hover = v
        switch tool {
        case .hand:
            pan = CGPoint(x: panStart.x + v.x - dragStartView.x, y: panStart.y + v.y - dragStartView.y)
            invalidate()
        case .brush, .eraser, .pencil:
            addStrokePoint(d, event: e)
        case .lasso:
            if let last = lassoPoints.last, hypot(v.x - last.x, v.y - last.y) >= 2 {
                lassoPoints.append(v)
            }
        case .transform:
            if let g = grab {
                let total = transformFor(g, to: d)
                let delta = grabApplied.inverted().concatenating(total)
                state.transformSelection(delta, checkpoint: !movedCheckpoint)
                movedCheckpoint = true
                grabApplied = total
            }
        case .select:
            if movingSelection {
                let dx = d.x - lastDoc.x
                let dy = d.y - lastDoc.y
                if dx != 0 || dy != 0 {
                    state.translateSelection(dx: dx, dy: dy, checkpoint: !movedCheckpoint)
                    movedCheckpoint = true
                }
            } else {
                marquee = CGRect(x: min(v.x, dragStartView.x), y: min(v.y, dragStartView.y),
                                 width: abs(v.x - dragStartView.x), height: abs(v.y - dragStartView.y))
            }
        default:
            break
        }
        lastDoc = d
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let tool = activeTool else { return }
        let v = viewPoint(e)
        let d = toDoc(v)
        currentDoc = d
        let points = stroke
        let sprayPath = live
        activeTool = nil
        grab = nil
        stroke = []
        live = nil

        switch tool {
        case .brush:
            if let shape = strokeShape(points, smoothing: state.smoothing) {
                state.addFill(shape, color: state.color)
            }
        case .eraser:
            if let shape = strokeShape(points, smoothing: min(state.smoothing, 25)) {
                state.erase(shape)
            }
        case .pencil:
            if let spray = sprayPath, !spray.isEmpty, let frozen = spray.copy() {
                state.addSeparate(frozen, color: state.color)
            }
        case .line:
            if (d - dragStartDoc).length > 0.5 {
                state.addFill(Brush.lineShape(from: dragStartDoc, to: d, width: state.size), color: state.color)
            }
        case .rect:
            let r = dragRect()
            if r.width > 0.5 && r.height > 0.5 {
                state.addFill(CGPath(rect: r, transform: nil), color: state.color)
            }
        case .oval:
            let r = dragRect()
            if r.width > 0.5 && r.height > 0.5 {
                state.addFill(CGPath(ellipseIn: r, transform: nil), color: state.color)
            }
        case .lasso:
            let loop = lassoPoints
            lassoPoints = []
            if loop.count >= 3 {
                let path = CGMutablePath()
                path.addLines(between: loop.map { toDoc($0) })
                path.closeSubpath()
                state.lassoSelect(path, adding: e.modifierFlags.contains(.shift))
            } else if !e.modifierFlags.contains(.shift) {
                state.deselect()
            }
        case .select:
            if let m = marquee, m.width > 2 || m.height > 2 {
                let a = toDoc(CGPoint(x: m.minX, y: m.minY))
                let b = toDoc(CGPoint(x: m.maxX, y: m.maxY))
                let area = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                if state.editingSymbol != nil {
                    let shapes = state.currentShapes
                    for i in shapes.indices where area.intersects(shapes[i].path.boundingBoxOfPath) {
                        state.selection.insert(i)
                    }
                } else {
                    // The marquee picks up art on every visible, unlocked layer.
                    let doc = state.doc
                    for li in doc.layers.indices where doc.layers[li].visible && !doc.layers[li].locked {
                        let shapes = doc.layers[li].shapes(at: state.frame)
                        var found = Set<Int>()
                        for i in shapes.indices where area.intersects(shapes[i].path.boundingBoxOfPath) {
                            found.insert(i)
                        }
                        state.addToSelection(layer: li, indexes: found)
                    }
                }
            }
            marquee = nil
            movingSelection = false
        default:
            break
        }
        needsDisplay = true
    }

    // MARK: Right-click menu

    /// Asks the app to name and create a symbol from the selection.
    var onConvertToSymbol: (() -> Void)?

    private func menuItem(_ title: String, enabled: Bool = true, _ fn: @escaping () -> Void) -> NSMenuItem {
        let a = Action(fn)
        let it = NSMenuItem(title: title, action: enabled ? #selector(Action.fire) : nil, keyEquivalent: "")
        it.target = a
        it.representedObject = a   // keeps the action alive while the menu is open
        it.isEnabled = enabled
        return it
    }

    override func rightMouseDown(with e: NSEvent) {
        guard activeTool == nil else { return }
        window?.makeFirstResponder(self)
        let d = toDoc(viewPoint(e))
        let s = state
        if s.isPlaying { s.stop() }
        let popup = NSMenu()
        popup.autoenablesItems = false

        if let hit = s.hitAny(d) {
            // Right-clicking art selects it, unless it is already part of the selection.
            if !s.isSelected(layer: hit.layer, index: hit.index) {
                s.selectOnly(layer: hit.layer, index: hit.index)
            }
            if !s.tool.keepsSelection { s.tool = .select }
            s.changed()

            let shapes = s.currentShapes
            var symbolRef: String? = nil
            for i in s.selection.sorted() where shapes.indices.contains(i) {
                if s.doc.item(shapes[i].ref)?.isSymbol == true {
                    symbolRef = shapes[i].ref
                    break
                }
            }
            popup.addItem(menuItem("Convert to Symbol…") { [weak self] in self?.onConvertToSymbol?() })
            if let ref = symbolRef {
                popup.addItem(menuItem("Edit Symbol") { s.enterEdit(ref) })
                popup.addItem(menuItem("Break Apart") { s.breakApart() })
            }
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem("Cut") {
                s.copySelection()
                s.deleteSelection()
            })
            popup.addItem(menuItem("Copy") { s.copySelection() })
            popup.addItem(menuItem("Paste in Place", enabled: !s.clipboard.isEmpty) { s.paste() })
            popup.addItem(menuItem("Delete") { s.deleteSelection() })
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem("Bring to Front") { s.arrangeSelection(toFront: true) })
            popup.addItem(menuItem("Send to Back") { s.arrangeSelection(toFront: false) })
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem("Flip Horizontal") { s.flipSelection(horizontal: true) })
            popup.addItem(menuItem("Flip Vertical") { s.flipSelection(horizontal: false) })
            popup.addItem(menuItem("Rotate 90° Right") { s.rotateSelection(degrees: 90) })
            popup.addItem(menuItem("Rotate 90° Left") { s.rotateSelection(degrees: -90) })
        } else {
            // Empty space
            popup.addItem(menuItem("Paste in Place", enabled: !s.clipboard.isEmpty) { s.paste() })
            popup.addItem(menuItem("Select All") { s.selectAll() })
            if s.hasSelection {
                popup.addItem(menuItem("Deselect All") { s.deselect() })
            }
            if s.editingSymbol != nil {
                popup.addItem(NSMenuItem.separator())
                popup.addItem(menuItem("Finish Editing Symbol") { s.exitEdit() })
            }
        }
        NSMenu.popUpContextMenu(popup, with: e, for: self)
    }

    override func mouseMoved(with e: NSEvent) {
        hover = viewPoint(e)
        if state.tool == .brush || state.tool == .eraser || state.tool == .pencil {
            needsDisplay = true
        }
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            zoomBy(exp(e.scrollingDeltaY * 0.01), at: viewPoint(e))
        } else {
            pan.x += e.scrollingDeltaX
            pan.y += e.scrollingDeltaY
            invalidate()
        }
    }

    override func magnify(with e: NSEvent) {
        zoomBy(1 + e.magnification, at: viewPoint(e))
    }

    // MARK: Keyboard

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 {
            spaceDown = false
            needsDisplay = true
        } else {
            super.keyUp(with: e)
        }
    }

    override func keyDown(with e: NSEvent) {
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 49:
            spaceDown = true
            return
        case 53:
            state.exitEdit()
            return
        case 51, 117:
            state.deleteSelection()
            return
        case 36, 76:
            state.togglePlay()
            return
        case 123:
            if !state.hasSelection {
                state.stop()
                state.goto(state.frame - 1)
            } else {
                state.translateSelection(dx: shift ? -10 : -1, dy: 0, checkpoint: true)
            }
            return
        case 124:
            if !state.hasSelection {
                state.stop()
                state.goto(state.frame + 1)
            } else {
                state.translateSelection(dx: shift ? 10 : 1, dy: 0, checkpoint: true)
            }
            return
        case 125:
            state.translateSelection(dx: 0, dy: shift ? 10 : 1, checkpoint: true)
            return
        case 126:
            state.translateSelection(dx: 0, dy: shift ? -10 : -1, checkpoint: true)
            return
        case 96:
            if shift { state.removeFrame() } else { state.insertFrame() }
            return
        case 97:
            if shift { state.clearKeyframe() } else { state.insertKeyframe(blank: false) }
            return
        case 98:
            state.insertKeyframe(blank: true)
            return
        default:
            break
        }
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
            super.keyDown(with: e)
            return
        }
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        switch ch {
        case ",":
            state.stop()
            state.goto(state.frame - 1)
        case ".":
            state.stop()
            state.goto(state.frame + 1)
        case "[":
            state.size = state.size - (state.size > 20 ? 4 : 1)
            state.changed()
        case "]":
            state.size = state.size + (state.size >= 20 ? 4 : 1)
            state.changed()
        default:
            if let tool = Tool.allCases.first(where: { $0.letter == ch }) {
                state.tool = tool
                if !tool.keepsSelection { state.selection.removeAll() }
                state.changed()
            } else {
                super.keyDown(with: e)
            }
        }
    }
}
