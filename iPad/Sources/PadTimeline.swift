import UIKit

/// The timeline, drawn like the Mac app's: a row per layer, a column per frame.
///
/// Touch a frame to go there and pick it; drag across frames to pick a block; drag a
/// picked keyframe to move everything that is picked. Drag in the ruler to scrub, and
/// drag the two onion skin markers to set its range. Drag a layer's name up or down to
/// reorder it, and double-tap the name to rename it. Two fingers scroll.
final class PadTimelineView: UIView, UIGestureRecognizerDelegate {
    let state: AppState
    var onRename: (() -> Void)?
    var onDeleteLayer: (() -> Void)?

    private let nameW: CGFloat = 200
    private let rulerH: CGFloat = 30
    private let rowH: CGFloat = 30
    private let footerH: CGFloat = 38
    /// Frames are wider than on the Mac so a fingertip can land on one.
    private var cellW: CGFloat { return (Prefs.frameWidth * 1.45).rounded() }

    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var lastFrame = -1

    // What the touch in progress is doing.
    private var touching = false
    private var scrubbing = false
    /// Which onion skin range marker is being dragged: -1 earlier, +1 later, 0 neither.
    private var onionDrag = 0
    /// The layer row being dragged up or down the stack, or -1.
    private var layerDrag = -1
    private var layerDragMoved = false
    private var frameAnchor: FrameRef?
    private var rangeDragging = false
    private var keyDragStart: Int?
    private var keyDragDelta = 0
    private var keyDragCell: FrameRef?
    private var nameTap: (row: Int, zone: Int)?

    private var headerKeys: [PadKeyButton] = []
    private var footerKeys: [PadKeyButton] = []
    private var loopKey: PadKeyButton?
    private var playKey: PadKeyButton?
    private var onionKey: PadKeyButton?

    init(state: AppState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 190))
        isOpaque = true
        contentMode = .redraw
        isMultipleTouchEnabled = true
        clipsToBounds = true

        // Layer keys in the corner above the names, as on the Mac.
        headerKeys = [
            PadKeyButton("+", width: 34, height: 24) { [weak self] in self?.state.addLayer() },
            PadKeyButton("\u{2212}", width: 34, height: 24) { [weak self] in self?.onDeleteLayer?() },
            PadKeyButton("\u{2191}", width: 34, height: 24) { [weak self] in self?.state.moveLayer(by: -1) },
            PadKeyButton("\u{2193}", width: 34, height: 24) { [weak self] in self?.state.moveLayer(by: 1) }
        ]
        for (i, key) in headerKeys.enumerated() {
            key.fontSize = 15
            key.frame.origin = CGPoint(x: 5 + CGFloat(i) * 38, y: 3)
            addSubview(key)
        }

        // The footer: the loop switch, then playback and the keyframe commands that the
        // Mac app keeps in its right-click menu.
        let loop = PadKeyButton("Loop", symbol: "repeat", width: 36, height: 28) { [weak self] in
            guard let s = self?.state else { return }
            s.loopPlayback = !s.loopPlayback
            s.changed()
        }
        loopKey = loop
        let play = PadKeyButton("Play", symbol: "play.fill", width: 40, height: 28) { [weak self] in
            self?.state.togglePlay()
        }
        playKey = play
        let onion = PadKeyButton("Onion Skin", height: 28) { [weak self] in
            guard let s = self?.state else { return }
            s.onionSkin = !s.onionSkin
            s.changed()
        }
        onionKey = onion
        footerKeys = [
            loop,
            PadKeyButton("First", symbol: "backward.end.fill", width: 36, height: 28) { [weak self] in
                self?.state.stop()
                self?.state.goto(0)
            },
            PadKeyButton("Back", symbol: "backward.frame.fill", width: 36, height: 28) { [weak self] in
                guard let s = self?.state else { return }
                s.stop()
                s.goto(s.frame - 1)
            },
            play,
            PadKeyButton("Forward", symbol: "forward.frame.fill", width: 36, height: 28) { [weak self] in
                guard let s = self?.state else { return }
                s.stop()
                s.goto(s.frame + 1)
            },
            PadKeyButton("Keyframe", height: 28) { [weak self] in self?.state.insertKeyframe(blank: false) },
            PadKeyButton("Blank Keyframe", height: 28) { [weak self] in self?.state.insertKeyframe(blank: true) },
            PadKeyButton("Clear Keyframe", height: 28) { [weak self] in self?.state.clearKeyframe() },
            PadKeyButton("+ Frame", height: 28) { [weak self] in self?.state.insertFrame() },
            PadKeyButton("\u{2212} Frame", height: 28) { [weak self] in self?.state.removeFrame() },
            onion
        ]
        for key in footerKeys {
            key.fontSize = 12
            addSubview(key)
        }

        state.observe { [weak self] in
            guard let self = self else { return }
            if self.state.frame != self.lastFrame {
                self.lastFrame = self.state.frame
                self.followPlayhead()
            }
            self.loopKey?.isOn = self.state.loopPlayback
            self.onionKey?.isOn = self.state.onionSkin
            self.playKey?.symbol = self.state.isPlaying ? "pause.fill" : "play.fill"
            self.setNeedsDisplay()
        }

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        scroll.delegate = self
        addGestureRecognizer(scroll)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The height the timeline wants for a number of layer rows.
    static func height(rows: Int) -> CGFloat {
        return 30 + CGFloat(rows) * 30 + 38
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let y = bounds.height - safeAreaInsets.bottom - footerH + (footerH - 28) / 2
        var x: CGFloat = 6
        for (i, key) in footerKeys.enumerated() {
            key.frame.origin = CGPoint(x: x, y: y)
            // Keys that don't fit a narrow screen are left off; the Timeline menu has them all.
            key.isHidden = x + key.frame.width > bounds.width - 4
            x += key.frame.width + (i == 0 || i == 4 || i == 9 ? 12 : 5)
        }
    }

    // MARK: Geometry

    private var gridBottom: CGFloat {
        return bounds.height - safeAreaInsets.bottom - footerH
    }

    private var cellsWidth: CGFloat {
        return max(cellW, bounds.width - nameW)
    }

    private func clampScroll() {
        let frames = max(state.doc.length + 60, Int(cellsWidth / cellW) + 1)
        scrollX = max(0, min(max(0, CGFloat(frames) * cellW - cellsWidth), scrollX))
        let contentH = CGFloat(state.doc.layers.count + (state.audioName == nil ? 0 : 1)) * rowH
        scrollY = max(0, min(max(0, contentH - (gridBottom - rulerH)), scrollY))
    }

    private func followPlayhead() {
        let x = CGFloat(state.frame) * cellW
        if x < scrollX {
            scrollX = x
        } else if x + cellW > scrollX + cellsWidth {
            scrollX = x + cellW - cellsWidth
        }
    }

    private func row(at p: CGPoint) -> Int? {
        if p.y < rulerH || p.y >= gridBottom { return nil }
        let r = Int(floor((p.y - rulerH + scrollY) / rowH))
        return state.doc.layers.indices.contains(r) ? r : nil
    }

    private func frameIndex(at p: CGPoint) -> Int {
        return max(0, Int(floor((p.x - nameW + scrollX) / cellW)))
    }

    /// Where an onion range marker sits on the ruler: the outer edge of the furthest
    /// ghosted frame on that side.
    private func onionMarkerX(later: Bool) -> CGFloat {
        let o = state.onion
        let edge = later ? state.frame + 1 + o.after : max(0, state.frame - o.before)
        return nameW + CGFloat(edge) * cellW - scrollX
    }

    /// Every cell in the block between two corners.
    private func cells(from a: FrameRef, to b: FrameRef) -> Set<FrameRef> {
        var out = Set<FrameRef>()
        let lastLayer = min(max(a.layer, b.layer), state.doc.layers.count - 1)
        var li = max(0, min(a.layer, b.layer))
        while li <= lastLayer {
            var f = min(a.frame, b.frame)
            let lastFrame = min(max(a.frame, b.frame), f + 5000)
            while f <= lastFrame {
                out.insert(FrameRef(layer: li, frame: f))
                f += 1
            }
            li += 1
        }
        return out
    }

    // MARK: Drawing

    private func text(_ s: String, at p: CGPoint, color: UIColor, size: CGFloat = 13) {
        Theme.label(s, at: p, color: color, size: size)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        clampScroll()
        let doc = state.doc
        Theme.fill(Theme.panelDark, bounds)

        let firstFrame = max(0, Int(scrollX / cellW))
        let lastFrame = firstFrame + max(0, Int((bounds.width - nameW) / cellW)) + 2
        let gridRect = CGRect(x: nameW, y: rulerH, width: max(0, bounds.width - nameW), height: max(0, gridBottom - rulerH))

        // Layer rows
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: rulerH, width: bounds.width, height: max(0, gridBottom - rulerH)))
        for (i, layer) in doc.layers.enumerated() {
            let y = rulerH + CGFloat(i) * rowH - scrollY
            if y + rowH <= rulerH || y >= gridBottom { continue }
            let current = i == state.layer
            let nameRect = CGRect(x: 0, y: y, width: nameW, height: rowH)
            if current {
                Theme.gradient(Theme.pressedBottom, Theme.pressedTop, in: nameRect)
            } else {
                Theme.fill(Theme.row, nameRect)
            }
            let ink = current ? Theme.accentInk : Theme.text
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: y, width: nameW - 58, height: rowH))
            // A clipped layer is indented under its base with a hooked arrow; the
            // reference layer carries a ring after its name.
            var label = layer.name
            if layer.isReference { label += "  \u{25CE}" }
            if layer.isClipped {
                text("\u{21B3}", at: CGPoint(x: 8, y: y + 7), color: ink)
                text(label, at: CGPoint(x: 26, y: y + 7), color: ink)
            } else {
                text(label, at: CGPoint(x: 10, y: y + 7), color: ink)
            }
            ctx.restoreGState()
            text(layer.visible ? "\u{25CF}" : "\u{25CB}", at: CGPoint(x: nameW - 52, y: y + 7), color: ink)
            text(layer.locked ? "\u{1F512}" : "\u{00B7}", at: CGPoint(x: nameW - 26, y: y + 7), color: ink)
            Theme.fill(Theme.line, CGRect(x: 0, y: y + rowH - 1, width: bounds.width, height: 1))

            ctx.saveGState()
            ctx.clip(to: gridRect)
            for f in firstFrame...lastFrame {
                let x = nameW + CGFloat(f) * cellW - scrollX
                let cell = CGRect(x: x, y: y, width: cellW, height: rowH - 1)
                let governing = layer.keyIndex(at: f)
                let hasArt = !(layer.keys[governing]?.shapes.isEmpty ?? true)
                if f < doc.length {
                    Theme.fill(hasArt ? Theme.frameFilled : Theme.frameEmpty, cell)
                } else {
                    Theme.fill(f % 5 == 4 ? Theme.beyondA : Theme.beyondB, cell)
                }
                if f < doc.length, f >= governing, let span = layer.tweenSpan(at: f), f < span.end {
                    // Tween span: accent wash with a line running to the next keyframe.
                    Theme.fill(Theme.accent.withAlphaComponent(0.42), cell)
                    let midY = y + rowH / 2 - 1
                    let startX = f == span.start ? x + cellW / 2 + 4 : x
                    Theme.fill(Theme.accent, CGRect(x: startX, y: midY, width: x + cellW - startX, height: 1.5))
                    if f == span.end - 1 {
                        let tip = UIBezierPath()
                        tip.move(to: CGPoint(x: x + cellW, y: midY + 0.75))
                        tip.addLine(to: CGPoint(x: x + cellW - 6, y: midY - 3.5))
                        tip.addLine(to: CGPoint(x: x + cellW - 6, y: midY + 5))
                        tip.close()
                        Theme.accent.setFill()
                        tip.fill()
                    }
                }
                if state.frameSelection.contains(FrameRef(layer: i, frame: f)) {
                    Theme.fill(Theme.accent.withAlphaComponent(0.45), cell)
                }
                if keyDragStart != nil, keyDragDelta != 0, f - keyDragDelta >= 0,
                   state.frameSelection.contains(FrameRef(layer: i, frame: f - keyDragDelta)) {
                    // Where the dragged frames will land.
                    Theme.accent.setStroke()
                    let ghost = UIBezierPath(rect: cell.insetBy(dx: 1, dy: 1))
                    ghost.lineWidth = 2
                    ghost.stroke()
                }
                if f < doc.length, layer.keys[f] != nil {
                    // Keyframe: solid dot when it holds art, hollow when blank.
                    Theme.fill(Theme.line, CGRect(x: x, y: y, width: 1, height: rowH - 1))
                    let dot = UIBezierPath(ovalIn: CGRect(x: x + cellW / 2 - 3.5, y: y + rowH - 12, width: 7, height: 7))
                    Theme.text.setFill()
                    Theme.text.setStroke()
                    if hasArt { dot.fill() } else { dot.stroke() }
                } else if f >= doc.length {
                    Theme.fill(Theme.frameLine, CGRect(x: x + cellW - 1, y: y, width: 1, height: rowH - 1))
                }
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // Soundtrack row, under the layers
        if let audio = state.audioName {
            let y = rulerH + CGFloat(doc.layers.count) * rowH - scrollY
            if y + rowH > rulerH && y < gridBottom {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: rulerH, width: bounds.width, height: max(0, gridBottom - rulerH)))
                let nameRect = CGRect(x: 0, y: y, width: nameW, height: rowH)
                Theme.fill(Theme.row, nameRect)
                ctx.saveGState()
                ctx.clip(to: nameRect.insetBy(dx: 4, dy: 0))
                let label = (state.audioMissing ? "\u{266A} missing: " : "\u{266A} ") + audio
                text(label, at: CGPoint(x: 10, y: y + 7), color: Theme.dim)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.clip(to: gridRect)
                Theme.fill(Theme.frameEmpty, CGRect(x: nameW, y: y, width: max(0, bounds.width - nameW), height: rowH - 1))
                for f in firstFrame...lastFrame {
                    let peak = CGFloat(min(1, state.audioPeak(atFrame: f)))
                    if peak <= 0 { continue }
                    let h = max(1, peak * (rowH - 6))
                    let x = nameW + CGFloat(f) * cellW - scrollX
                    Theme.fill(Theme.accent, CGRect(x: x + 1, y: y + (rowH - 1 - h) / 2, width: cellW - 2, height: h))
                }
                ctx.restoreGState()
                Theme.fill(Theme.line, CGRect(x: 0, y: y + rowH - 1, width: bounds.width, height: 1))
                ctx.restoreGState()
            }
        }

        // Ruler
        Theme.bar(in: CGRect(x: 0, y: 0, width: bounds.width, height: rulerH))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: nameW, y: 0, width: max(0, bounds.width - nameW), height: gridBottom))
        for f in firstFrame...lastFrame {
            let x = nameW + CGFloat(f) * cellW - scrollX
            Theme.fill(Theme.dim, CGRect(x: x, y: rulerH - 6, width: 1, height: 5))
            if f == 0 || (f + 1) % 5 == 0 {
                text("\(f + 1)", at: CGPoint(x: x + 3, y: 5), color: Theme.text, size: 11)
            }
        }
        // Onion skin range: a tinted band either side of the playhead, with a marker at
        // each end that can be dragged frame by frame.
        if state.onionSkin {
            let o = state.onion
            let left = onionMarkerX(later: false)
            let right = onionMarkerX(later: true)
            let headLeft = nameW + CGFloat(state.frame) * cellW - scrollX
            let headRight = headLeft + cellW
            let earlier = o.tint ? o.tintBefore.uiColor : Theme.dim
            let later = o.tint ? o.tintAfter.uiColor : Theme.dim
            Theme.fill(earlier.withAlphaComponent(0.28), CGRect(x: left, y: rulerH - 11, width: max(0, headLeft - left), height: 10))
            Theme.fill(later.withAlphaComponent(0.28), CGRect(x: headRight, y: rulerH - 11, width: max(0, right - headRight), height: 10))
            for (x, color) in [(left, earlier), (right, later)] {
                let knob = UIBezierPath(roundedRect: CGRect(x: x - 5, y: rulerH - 17, width: 10, height: 16), cornerRadius: 3)
                color.setFill()
                knob.fill()
                Theme.line.setStroke()
                knob.lineWidth = 1
                knob.stroke()
            }
        }

        // Playhead
        let px = nameW + CGFloat(state.frame) * cellW - scrollX
        Theme.fill(Theme.accent.withAlphaComponent(0.45), CGRect(x: px, y: 0, width: cellW, height: rulerH))
        Theme.fill(Theme.accent, CGRect(x: px + cellW / 2 - 0.5, y: 0, width: 1, height: gridBottom))
        ctx.restoreGState()

        // Footer strip along the bottom.
        let footer = CGRect(x: 0, y: gridBottom, width: bounds.width, height: bounds.height - gridBottom)
        Theme.bar(in: footer)
        Theme.fill(Theme.line, CGRect(x: 0, y: footer.minY, width: bounds.width, height: 1))

        // Grip dots beside the layer keys.
        for i in 0..<6 {
            Theme.fill(Theme.grip, CGRect(x: 164 + CGFloat(i) * 4, y: rulerH / 2 - 3, width: 2, height: 2))
            Theme.fill(Theme.grip, CGRect(x: 164 + CGFloat(i) * 4, y: rulerH / 2 + 1, width: 2, height: 2))
        }
        Theme.fill(Theme.line, CGRect(x: nameW - 1, y: 0, width: 1, height: gridBottom))
        Theme.fill(Theme.line, CGRect(x: 0, y: rulerH - 1, width: bounds.width, height: 1))
        Theme.fill(Theme.line, CGRect(x: 0, y: 0, width: bounds.width, height: 1))
    }

    // MARK: Touches

    private func scrub(to p: CGPoint) {
        let f = frameIndex(at: p)
        if f != state.frame {
            state.stop()
            state.goto(f)
        }
    }

    private func dragOnionMarker(to p: CGPoint) {
        // Snap to the nearest frame boundary.
        let boundary = Int(((p.x - nameW + scrollX) / cellW).rounded())
        if onionDrag < 0 {
            state.setOnionRange(before: state.frame - boundary)
        } else if onionDrag > 0 {
            state.setOnionRange(after: boundary - state.frame - 1)
        }
        state.changed()
    }

    private func resetTouch() {
        touching = false
        scrubbing = false
        onionDrag = 0
        layerDrag = -1
        layerDragMoved = false
        rangeDragging = false
        keyDragStart = nil
        keyDragDelta = 0
        keyDragCell = nil
        nameTap = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !touching, let touch = touches.first else { return }
        let p = touch.location(in: self)
        resetTouch()
        if p.y >= gridBottom { return }
        touching = true

        if state.onionSkin && p.y < rulerH && p.x >= nameW {
            let toLeft = abs(p.x - onionMarkerX(later: false))
            let toRight = abs(p.x - onionMarkerX(later: true))
            if min(toLeft, toRight) <= 14 {
                onionDrag = toLeft < toRight ? -1 : 1
                return
            }
        }
        if p.x >= nameW {
            guard p.y >= rulerH, let r = row(at: p) else {
                // The ruler (and empty space) scrubs the playhead.
                scrubbing = true
                state.stop()
                state.goto(frameIndex(at: p))
                return
            }
            let cell = FrameRef(layer: r, frame: frameIndex(at: p))
            if state.frameSelection.contains(cell)
                && (state.frameSelection.count > 1 || state.doc.layers[r].keys[cell.frame] != nil) {
                // Pressing on a picked frame: a drag will move everything that is picked.
                keyDragStart = cell.frame
                keyDragCell = cell
            } else {
                state.frameSelection = [cell]
                frameAnchor = cell
                rangeDragging = true
            }
            state.selectLayer(r)
            state.stop()
            state.goto(cell.frame)
            state.changed()
            return
        }
        guard let r = row(at: p) else { return }
        if p.x >= nameW - 60 && p.x < nameW - 32 {
            nameTap = (row: r, zone: 1)
        } else if p.x >= nameW - 32 {
            nameTap = (row: r, zone: 2)
        } else {
            state.selectLayer(r)
            if touch.tapCount >= 2 {
                onRename?()
                resetTouch()
            } else {
                // Holding and dragging the name moves the layer up or down the stack.
                layerDrag = r
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touching, let touch = touches.first else { return }
        let p = touch.location(in: self)
        if layerDrag >= 0 {
            let count = state.doc.layers.count
            let target = max(0, min(count - 1, Int(floor((p.y - rulerH + scrollY) / rowH))))
            if target != layerDrag {
                state.moveLayer(from: layerDrag, to: target, checkpoint: !layerDragMoved)
                layerDragMoved = true
                layerDrag = target
            }
        } else if let start = keyDragStart {
            keyDragDelta = frameIndex(at: p) - start
            setNeedsDisplay()
        } else if rangeDragging, let anchor = frameAnchor {
            let count = state.doc.layers.count
            let r = max(0, min(count - 1, Int(floor((p.y - rulerH + scrollY) / rowH))))
            let cell = FrameRef(layer: r, frame: frameIndex(at: CGPoint(x: max(nameW, p.x), y: p.y)))
            state.frameSelection = cells(from: anchor, to: cell)
            state.goto(cell.frame)
            state.changed()
        } else if onionDrag != 0 {
            dragOnionMarker(to: p)
        } else if scrubbing {
            scrub(to: CGPoint(x: max(nameW, p.x), y: p.y))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touching else { return }
        if let tap = nameTap, let p = touches.first?.location(in: self), row(at: p) == tap.row {
            if tap.zone == 1 {
                state.toggleVisible(tap.row)
            } else {
                state.toggleLocked(tap.row)
            }
        }
        if keyDragStart != nil {
            if keyDragDelta != 0 {
                state.moveSelectedKeyframes(by: keyDragDelta)
            } else if let cell = keyDragCell {
                // A plain tap on a picked keyframe narrows the selection to it.
                state.frameSelection = [cell]
                frameAnchor = cell
                state.changed()
            }
        }
        resetTouch()
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        resetTouch()
        setNeedsDisplay()
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let t = g.translation(in: self)
        scrollX -= t.x
        scrollY -= t.y
        g.setTranslation(.zero, in: self)
        clampScroll()
        setNeedsDisplay()
    }
}
