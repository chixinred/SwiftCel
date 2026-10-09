import AppKit

final class TimelineView: NSView {
    let state: AppState
    var onRename: (() -> Void)?
    var onEditCurve: (() -> Void)?

    private let nameW: CGFloat = 176
    private let rulerH: CGFloat = 24
    private let rowH: CGFloat = 22
    private var cellW: CGFloat { return Prefs.frameWidth }
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var scrubbing = false
    /// Which onion skin range marker is being dragged: -1 earlier, +1 later, 0 neither.
    private var onionDrag = 0
    /// The layer row being dragged up or down the stack, or -1.
    private var layerDrag = -1
    private var layerDragMoved = false
    /// Frame selection: where a range starts, whether a range is being dragged out, and
    /// (when dragging selected keyframes) the frame the drag began on and how far it has gone.
    private var frameAnchor: FrameRef?
    private var rangeDragging = false
    private var keyDragStart: Int?
    private var keyDragDelta = 0
    private var keyDragCell: FrameRef?
    private let footerH: CGFloat = 24
    private var loopButton: NSButton?
    private var actions: [Action] = []
    let headerDrag = HeaderDrag()
    /// The grip in the corner above the layer names; drag it to move the timeline.
    private var gripRect: NSRect { return NSRect(x: 124, y: 0, width: nameW - 124, height: rulerH) }

    init(state: AppState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 160))
        state.observe { [weak self] in
            self?.followPlayhead()
            self?.loopButton?.state = (self?.state.loopPlayback ?? true) ? .on : .off
            self?.needsDisplay = true
        }
        addButton("+", x: 4, tip: "New layer") { [weak self] in self?.state.addLayer() }
        addButton("−", x: 32, tip: "Delete layer") { [weak self] in self?.state.deleteLayer() }
        addButton("↑", x: 66, tip: "Move layer up") { [weak self] in self?.state.moveLayer(by: -1) }
        addButton("↓", x: 94, tip: "Move layer down") { [weak self] in self?.state.moveLayer(by: 1) }

        // Loop switch, bottom-left corner.
        let loopAction = Action { [weak self] in
            guard let self = self else { return }
            self.state.loopPlayback.toggle()
            self.state.changed()
        }
        actions.append(loopAction)
        let loop = NSButton(title: "Loop", target: loopAction, action: #selector(Action.fire))
        if let img = NSImage(systemSymbolName: "repeat", accessibilityDescription: "Loop playback") {
            loop.image = img
            loop.imagePosition = .imageOnly
        }
        loop.setButtonType(.pushOnPushOff)
        loop.bezelStyle = .smallSquare
        loop.toolTip = "Loop playback: on repeats the animation, off plays it once"
        loop.refusesFirstResponder = true
        loop.frame = NSRect(x: 4, y: bounds.height - footerH + 2, width: 30, height: 20)
        loop.autoresizingMask = [.minYMargin]   // stay pinned to the bottom edge
        loop.state = state.loopPlayback ? .on : .off
        addSubview(loop)
        loopButton = loop
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    private func addButton(_ title: String, x: CGFloat, tip: String, _ fn: @escaping () -> Void) {
        let a = Action(fn)
        actions.append(a)
        let b = NSButton(title: title, target: a, action: #selector(Action.fire))
        b.bezelStyle = .smallSquare
        b.frame = NSRect(x: x, y: 2, width: 26, height: 20)
        b.toolTip = tip
        b.refusesFirstResponder = true
        addSubview(b)
    }

    private func followPlayhead() {
        let visible = max(cellW, bounds.width - nameW)
        let x = CGFloat(state.frame) * cellW
        if x < scrollX {
            scrollX = x
        } else if x + cellW > scrollX + visible {
            scrollX = x + cellW - visible
        }
    }

    private func text(_ s: String, at p: NSPoint, color: NSColor, size: CGFloat = 11) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        let doc = state.doc
        Theme.panelDark.setFill()
        bounds.fill()

        let firstFrame = max(0, Int(scrollX / cellW))
        let lastFrame = firstFrame + max(0, Int((bounds.width - nameW) / cellW)) + 2
        let gridRect = NSRect(x: nameW, y: rulerH, width: max(0, bounds.width - nameW), height: max(0, bounds.height - rulerH))

        // Layer rows
        for (i, layer) in doc.layers.enumerated() {
            let y = rulerH + CGFloat(i) * rowH - scrollY
            if y + rowH <= rulerH || y >= bounds.height { continue }
            let current = i == state.layer
            let nameRect = NSRect(x: 0, y: y, width: nameW, height: rowH)
            if current {
                Theme.gradient(Theme.pressedBottom, Theme.pressedTop, in: nameRect, flipped: true)
            } else {
                Theme.row.setFill()
                nameRect.fill()
            }
            let ink = current ? Theme.accentInk : Theme.text
            // A clipped layer is indented under its base with a hooked arrow; the
            // reference layer carries a ring after its name.
            var label = layer.name
            if layer.isReference { label += "  \u{25CE}" }
            if layer.isClipped {
                text("\u{21B3}", at: NSPoint(x: 6, y: y + 4), color: ink)
                text(label, at: NSPoint(x: 22, y: y + 4), color: ink)
            } else {
                text(label, at: NSPoint(x: 8, y: y + 4), color: ink)
            }
            text(layer.visible ? "●" : "○", at: NSPoint(x: nameW - 42, y: y + 4), color: ink)
            text(layer.locked ? "🔒" : "·", at: NSPoint(x: nameW - 22, y: y + 4), color: ink)
            Theme.line.setFill()
            NSRect(x: 0, y: y + rowH - 1, width: bounds.width, height: 1).fill()

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: gridRect).addClip()
            for f in firstFrame...lastFrame {
                let x = nameW + CGFloat(f) * cellW - scrollX
                let cell = NSRect(x: x, y: y, width: cellW, height: rowH - 1)
                let governing = layer.keyIndex(at: f)
                let hasArt = !(layer.keys[governing]?.shapes.isEmpty ?? true)
                if f < doc.length {
                    (hasArt ? Theme.frameFilled : Theme.frameEmpty).setFill()
                } else {
                    (f % 5 == 4 ? Theme.beyondA : Theme.beyondB).setFill()
                }
                cell.fill()
                if f < doc.length, f >= governing, let span = layer.tweenSpan(at: f), f < span.end {
                    // Tween span: accent wash with a line running to the next keyframe.
                    Theme.accent.withAlphaComponent(0.42).setFill()
                    cell.fill(using: .sourceOver)
                    Theme.accent.setFill()
                    let midY = y + rowH / 2 - 1
                    let startX = f == span.start ? x + cellW / 2 + 3 : x
                    NSRect(x: startX, y: midY, width: x + cellW - startX, height: 1.5).fill()
                    if f == span.end - 1 {
                        let tip = NSBezierPath()
                        tip.move(to: NSPoint(x: x + cellW, y: midY + 0.75))
                        tip.line(to: NSPoint(x: x + cellW - 5, y: midY - 3))
                        tip.line(to: NSPoint(x: x + cellW - 5, y: midY + 4.5))
                        tip.close()
                        tip.fill()
                    }
                }
                if state.frameSelection.contains(FrameRef(layer: i, frame: f)) {
                    Theme.accent.withAlphaComponent(0.45).setFill()
                    cell.fill(using: .sourceOver)
                }
                if keyDragStart != nil, keyDragDelta != 0, f - keyDragDelta >= 0,
                   state.frameSelection.contains(FrameRef(layer: i, frame: f - keyDragDelta)) {
                    // Where the dragged frames will land.
                    Theme.accent.setStroke()
                    let ghost = NSBezierPath(rect: cell.insetBy(dx: 1, dy: 1))
                    ghost.lineWidth = 2
                    ghost.stroke()
                }
                if f < doc.length, layer.keys[f] != nil {
                    // Keyframe: solid dot when it holds art, hollow when blank.
                    Theme.line.setFill()
                    NSRect(x: x, y: y, width: 1, height: rowH - 1).fill()
                    let dot = NSBezierPath(ovalIn: NSRect(x: x + cellW / 2 - 2.5, y: y + rowH - 9, width: 5, height: 5))
                    Theme.text.set()
                    if hasArt { dot.fill() } else { dot.stroke() }
                } else if f >= doc.length {
                    Theme.frameLine.setFill()
                    NSRect(x: x + cellW - 1, y: y, width: 1, height: rowH - 1).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Soundtrack row, under the layers
        if let audio = state.audioName {
            let y = rulerH + CGFloat(doc.layers.count) * rowH - scrollY
            if y + rowH > rulerH && y < bounds.height {
                let nameRect = NSRect(x: 0, y: y, width: nameW, height: rowH)
                Theme.row.setFill()
                nameRect.fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: nameRect.insetBy(dx: 4, dy: 0)).addClip()
                let label = (state.audioMissing ? "♪ missing: " : "♪ ") + audio
                text(label, at: NSPoint(x: 8, y: y + 4), color: Theme.dim)
                NSGraphicsContext.restoreGraphicsState()

                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: gridRect).addClip()
                Theme.frameEmpty.setFill()
                NSRect(x: nameW, y: y, width: max(0, bounds.width - nameW), height: rowH - 1).fill()
                Theme.accent.setFill()
                for f in firstFrame...lastFrame {
                    let peak = CGFloat(min(1, state.audioPeak(atFrame: f)))
                    if peak <= 0 { continue }
                    let h = max(1, peak * (rowH - 4))
                    let x = nameW + CGFloat(f) * cellW - scrollX
                    NSRect(x: x + 1, y: y + (rowH - 1 - h) / 2, width: cellW - 2, height: h).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                Theme.line.setFill()
                NSRect(x: 0, y: y + rowH - 1, width: bounds.width, height: 1).fill()
            }
        }

        // Ruler
        Theme.bar(in: NSRect(x: 0, y: 0, width: bounds.width, height: rulerH), flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: nameW, y: 0, width: max(0, bounds.width - nameW), height: bounds.height)).addClip()
        for f in firstFrame...lastFrame {
            let x = nameW + CGFloat(f) * cellW - scrollX
            Theme.dim.setFill()
            NSRect(x: x, y: rulerH - 5, width: 1, height: 4).fill()
            if f == 0 || (f + 1) % 5 == 0 {
                text("\(f + 1)", at: NSPoint(x: x + 2, y: 4), color: Theme.text, size: 9)
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
            let earlier = o.tint ? o.tintBefore.nsColor : Theme.dim
            let later = o.tint ? o.tintAfter.nsColor : Theme.dim
            earlier.withAlphaComponent(0.28).setFill()
            NSRect(x: left, y: rulerH - 9, width: max(0, headLeft - left), height: 8).fill(using: .sourceOver)
            later.withAlphaComponent(0.28).setFill()
            NSRect(x: headRight, y: rulerH - 9, width: max(0, right - headRight), height: 8).fill(using: .sourceOver)
            for (x, color) in [(left, earlier), (right, later)] {
                let knob = NSBezierPath(roundedRect: NSRect(x: x - 3.5, y: rulerH - 13, width: 7, height: 12), xRadius: 2, yRadius: 2)
                color.setFill()
                knob.fill()
                Theme.line.setStroke()
                knob.lineWidth = 1
                knob.stroke()
            }
        }

        // Playhead
        let px = nameW + CGFloat(state.frame) * cellW - scrollX
        Theme.accent.withAlphaComponent(0.45).setFill()
        NSRect(x: px, y: 0, width: cellW, height: rulerH).fill(using: .sourceOver)
        Theme.accent.setFill()
        NSRect(x: px + cellW / 2 - 0.5, y: 0, width: 1, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Footer strip along the bottom, holding the loop switch.
        let footer = NSRect(x: 0, y: bounds.height - footerH, width: bounds.width, height: footerH)
        Theme.bar(in: footer, flipped: true)
        Theme.line.setFill()
        NSRect(x: 0, y: footer.minY, width: bounds.width, height: 1).fill()
        let loopNote = state.loopPlayback ? "Loop on" : "Loop off"
        text(loopNote, at: NSPoint(x: 40, y: footer.minY + 6), color: Theme.dim, size: 10)

        Theme.grip.setFill()
        for i in 0..<6 {
            NSRect(x: gripRect.minX + 10 + CGFloat(i) * 4, y: rulerH / 2 - 3, width: 2, height: 2).fill(using: .sourceOver)
            NSRect(x: gripRect.minX + 10 + CGFloat(i) * 4, y: rulerH / 2 + 1, width: 2, height: 2).fill(using: .sourceOver)
        }
        Theme.line.setFill()
        NSRect(x: nameW - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: rulerH - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Where an onion range marker sits on the ruler: the outer edge of the furthest
    /// ghosted frame on that side.
    private func onionMarkerX(later: Bool) -> CGFloat {
        let o = state.onion
        let edge = later ? state.frame + 1 + o.after : max(0, state.frame - o.before)
        return nameW + CGFloat(edge) * cellW - scrollX
    }

    private func dragOnionMarker(to p: NSPoint) {
        // Snap to the nearest frame boundary.
        let boundary = Int(((p.x - nameW + scrollX) / cellW).rounded())
        if onionDrag < 0 {
            state.setOnionRange(before: state.frame - boundary)
        } else if onionDrag > 0 {
            state.setOnionRange(after: boundary - state.frame - 1)
        }
    }

    private func row(at p: NSPoint) -> Int? {
        if p.y < rulerH { return nil }
        let r = Int(floor((p.y - rulerH + scrollY) / rowH))
        return state.doc.layers.indices.contains(r) ? r : nil
    }

    private func scrub(to p: NSPoint) {
        let f = Int(floor((p.x - nameW + scrollX) / cellW))
        state.stop()
        state.goto(max(0, f))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        scrubbing = false
        if gripRect.contains(p) {
            headerDrag.down(e)
            return
        }
        if p.y >= bounds.height - footerH { return }
        onionDrag = 0
        if state.onionSkin && p.y < rulerH && p.x >= nameW {
            let toLeft = abs(p.x - onionMarkerX(later: false))
            let toRight = abs(p.x - onionMarkerX(later: true))
            if min(toLeft, toRight) <= 5 {
                onionDrag = toLeft < toRight ? -1 : 1
                return
            }
        }
        if p.x >= nameW {
            rangeDragging = false
            keyDragStart = nil
            keyDragDelta = 0
            keyDragCell = nil
            guard p.y >= rulerH, let r = row(at: p) else {
                // The ruler (and empty space) scrubs the playhead.
                scrubbing = true
                scrub(to: p)
                return
            }
            let cell = FrameRef(layer: r, frame: frameIndex(at: p))
            let mods = e.modifierFlags
            if mods.contains(.shift), let anchor = frameAnchor {
                state.frameSelection = cells(from: anchor, to: cell)
            } else if mods.contains(.command) {
                if state.frameSelection.contains(cell) {
                    state.frameSelection.remove(cell)
                } else {
                    state.frameSelection.insert(cell)
                }
                frameAnchor = cell
            } else if state.frameSelection.contains(cell)
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
        if p.x >= nameW - 48 && p.x < nameW - 26 {
            state.toggleVisible(r)
        } else if p.x >= nameW - 26 {
            state.toggleLocked(r)
        } else {
            state.selectLayer(r)
            if e.clickCount == 2 {
                onRename?()
            } else {
                // Holding and dragging the name moves the layer up or down the stack.
                layerDrag = r
                layerDragMoved = false
            }
        }
    }

    override func mouseDragged(with e: NSEvent) {
        if headerDrag.isTracking {
            headerDrag.dragged(e)
        } else if layerDrag >= 0 {
            let p = convert(e.locationInWindow, from: nil)
            let count = state.doc.layers.count
            let target = max(0, min(count - 1, Int(floor((p.y - rulerH + scrollY) / rowH))))
            if target != layerDrag {
                state.moveLayer(from: layerDrag, to: target, checkpoint: !layerDragMoved)
                layerDragMoved = true
                layerDrag = target
            }
        } else if let start = keyDragStart {
            keyDragDelta = frameIndex(at: convert(e.locationInWindow, from: nil)) - start
            needsDisplay = true
        } else if rangeDragging, let anchor = frameAnchor {
            let p = convert(e.locationInWindow, from: nil)
            let count = state.doc.layers.count
            let r = max(0, min(count - 1, Int(floor((p.y - rulerH + scrollY) / rowH))))
            let cell = FrameRef(layer: r, frame: frameIndex(at: p))
            state.frameSelection = cells(from: anchor, to: cell)
            state.goto(cell.frame)
            state.changed()
        } else if onionDrag != 0 {
            dragOnionMarker(to: convert(e.locationInWindow, from: nil))
        } else if scrubbing {
            scrub(to: convert(e.locationInWindow, from: nil))
        }
    }

    override func mouseUp(with e: NSEvent) {
        headerDrag.up(e)
        scrubbing = false
        onionDrag = 0
        layerDrag = -1
        if keyDragStart != nil {
            if keyDragDelta != 0 {
                state.moveSelectedKeyframes(by: keyDragDelta)
            } else if let cell = keyDragCell {
                // A plain click on a selected keyframe narrows the selection to it.
                state.frameSelection = [cell]
                frameAnchor = cell
                state.changed()
            }
        }
        keyDragStart = nil
        keyDragDelta = 0
        keyDragCell = nil
        rangeDragging = false
    }

    private func frameIndex(at p: NSPoint) -> Int {
        return max(0, Int(floor((p.x - nameW + scrollX) / cellW)))
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

    // MARK: Right-click menu

    private func menuItem(_ title: String, enabled: Bool = true, _ fn: @escaping () -> Void) -> NSMenuItem {
        let a = Action(fn)
        let it = NSMenuItem(title: title, action: enabled ? #selector(Action.fire) : nil, keyEquivalent: "")
        it.target = a
        it.representedObject = a   // keeps the action alive while the menu is open
        it.isEnabled = enabled
        return it
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if p.y >= bounds.height - footerH { return }
        let s = state
        let popup = NSMenu()
        popup.autoenablesItems = false
        let layerRow = row(at: p)
        let audioRow = Int(floor((p.y - rulerH + scrollY) / rowH)) == s.doc.layers.count && s.audioName != nil

        if p.x >= nameW {
            // Frames: act on the frame (and layer) under the pointer.
            if let r = layerRow { s.selectLayer(r) }
            s.stop()
            s.goto(max(0, Int(floor((p.x - nameW + scrollX) / cellW))))
            // Right-clicking outside the picked frames starts over with this one; inside,
            // the keyframe commands below apply to every picked frame.
            if let r = layerRow {
                let cell = FrameRef(layer: r, frame: s.frame)
                if !s.frameSelection.contains(cell) {
                    s.frameSelection = [cell]
                    frameAnchor = cell
                    s.changed()
                }
            }
            let onKey = s.doc.layers.indices.contains(s.layer) && s.doc.layers[s.layer].keys[s.frame] != nil
            let many = s.frameTargets.count > 1
            popup.addItem(menuItem(many ? "Insert Frames" : "Insert Frame") { s.insertFrame() })
            popup.addItem(menuItem(many ? "Remove \(s.frameTargets.count) Frames" : "Remove Frame") { s.removeFrame() })
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem("Insert Keyframe", enabled: !onKey) { s.insertKeyframe(blank: false) })
            popup.addItem(menuItem("Insert Blank Keyframe") { s.insertKeyframe(blank: true) })
            popup.addItem(menuItem("Clear Keyframe", enabled: onKey) { s.clearKeyframe() })
            popup.addItem(NSMenuItem.separator())
            let ease = s.currentTweenEase
            if ease == nil {
                popup.addItem(menuItem("Create Tween") { s.setTween(ease: "linear") })
            } else {
                popup.addItem(menuItem("Remove Tween") { s.setTween(ease: nil) })
                for option in Tweening.eases {
                    let entry = menuItem("    " + option.title) { s.setTween(ease: option.id) }
                    entry.state = option.id == ease ? .on : .off
                    popup.addItem(entry)
                }
                let custom = menuItem("    Custom Curve…") { [weak self] in self?.onEditCurve?() }
                custom.state = ease == "custom" ? .on : .off
                popup.addItem(custom)
            }
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem("Copy Frame Art") {
                s.selection.removeAll()
                s.copySelection()
            })
            popup.addItem(menuItem("Paste Art Here", enabled: !s.clipboard.isEmpty) { s.paste() })
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem(s.onionSkin ? "Turn Onion Skin Off" : "Turn Onion Skin On") {
                s.onionSkin.toggle()
                s.changed()
            })
        } else if let r = layerRow {
            // Layer names
            s.selectLayer(r)
            let layer = s.doc.layers[r]
            popup.addItem(menuItem("New Layer") { s.addLayer() })
            popup.addItem(menuItem("Rename Layer…") { [weak self] in self?.onRename?() })
            popup.addItem(menuItem("Delete Layer", enabled: s.doc.layers.count > 1) { s.deleteLayer() })
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem("Move Layer Up", enabled: r > 0) { s.moveLayer(by: -1) })
            popup.addItem(menuItem("Move Layer Down", enabled: r < s.doc.layers.count - 1) { s.moveLayer(by: 1) })
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem(layer.visible ? "Hide Layer" : "Show Layer") { s.toggleVisible(r) })
            popup.addItem(menuItem(layer.locked ? "Unlock Layer" : "Lock Layer") { s.toggleLocked(r) })
            popup.addItem(NSMenuItem.separator())
            popup.addItem(menuItem(layer.isClipped ? "Release Clipping Mask" : "Create Clipping Mask",
                                   enabled: r < s.doc.layers.count - 1) { s.toggleClip(r) })
            popup.addItem(menuItem(layer.isReference ? "Stop Using as Reference" : "Use as Reference Layer") {
                s.toggleReference(r)
            })
        } else if audioRow {
            popup.addItem(menuItem("Remove Audio") { s.removeAudio() })
        } else {
            popup.addItem(menuItem("New Layer") { s.addLayer() })
        }
        NSMenu.popUpContextMenu(popup, with: e, for: self)
    }

    override func scrollWheel(with e: NSEvent) {
        scrollX = max(0, scrollX - e.scrollingDeltaX)
        let rows = state.doc.layers.count + (state.audioName == nil ? 0 : 1)
        let contentH = CGFloat(rows) * rowH
        let maxY = max(0, contentH - (bounds.height - rulerH - footerH))
        scrollY = max(0, min(maxY, scrollY - e.scrollingDeltaY))
        needsDisplay = true
    }
}
