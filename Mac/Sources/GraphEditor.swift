import AppKit

/// The graph editor: shows the easing of the tween under the playhead as a curve of
/// progress against time, with two handles to reshape it.
final class GraphView: NSView {
    static let size = NSSize(width: 300, height: 356)

    let state: AppState
    private var actions: [Action] = []
    /// Control points of the curve: x1, y1, x2, y2.
    private var curve: [CGFloat] = [0, 0, 1, 1]
    private var dragging = -1
    private var playButton: NSButton?

    // Plot geometry. Progress may overshoot, so there is room above 1 and below 0.
    private let plotX: CGFloat = 44
    private let plotW: CGFloat = 220
    private let zeroY: CGFloat = 222
    private let unitH: CGFloat = 120
    private let lowest: CGFloat = -0.5
    private let highest: CGFloat = 1.5

    init(state: AppState) {
        self.state = state
        super.init(frame: NSRect(origin: .zero, size: GraphView.size))
        let presets: [(String, String?, [CGFloat])] = [
            ("Linear", "linear", []),
            ("Ease In", "in", []),
            ("Ease Out", "out", []),
            ("In and Out", "inOut", []),
            ("Overshoot", nil, [0.34, 1.40, 0.64, 1.0]),
            ("Anticipate", nil, [0.36, 0.0, 0.66, -0.40]),
            ("Snap", nil, [0.10, 0.90, 0.20, 1.0]),
            ("Slow Middle", nil, [0.10, 0.60, 0.90, 0.40])
        ]
        for (i, preset) in presets.enumerated() {
            let column = CGFloat(i % 4)
            let rowIndex = CGFloat(i / 4)
            let a = Action { [weak self] in
                guard let self = self else { return }
                if let id = preset.1 {
                    self.state.setGraphEase(id)
                } else {
                    self.state.setTweenCurve(preset.2)
                    self.state.endCurveEdit()
                }
            }
            actions.append(a)
            let b = NSButton(title: preset.0, target: a, action: #selector(Action.fire))
            b.bezelStyle = .smallSquare
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 10)
            b.frame = NSRect(x: 8 + column * 71, y: 300 + rowIndex * 25, width: 69, height: 22)
            b.refusesFirstResponder = true
            addSubview(b)
        }
        // Play Tween: loops just this tween while the curve is being shaped.
        let playAction = Action { [weak self] in
            guard let self = self else { return }
            if self.state.isPlaying {
                self.state.stop()
            } else {
                self.state.playTween()
            }
        }
        actions.append(playAction)
        let play = NSButton(title: "Play Tween", target: playAction, action: #selector(Action.fire))
        play.bezelStyle = .rounded
        play.controlSize = .small
        play.font = NSFont.systemFont(ofSize: 11)
        play.frame = NSRect(x: GraphView.size.width - 100, y: 3, width: 92, height: 22)
        play.refusesFirstResponder = true
        addSubview(play)
        playButton = play

        state.observe { [weak self] in
            self?.sync()
        }
        sync()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    private func sync() {
        if dragging < 0, let tween = state.graphTween {
            curve = Tweening.bezier(for: tween)
        }
        playButton?.title = state.isPlaying ? "Stop" : "Play Tween"
        playButton?.isEnabled = state.isPlaying || state.graphSpan != nil
        needsDisplay = true
    }

    private func toView(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        return NSPoint(x: plotX + x * plotW, y: zeroY - y * unitH)
    }

    private func handlePoint(_ i: Int) -> NSPoint {
        return i == 0 ? toView(curve[0], curve[1]) : toView(curve[2], curve[3])
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds, flipped: true)
        let hasTween = state.graphTween != nil

        // Heading
        var heading = "No tween at the playhead"
        if hasTween, state.doc.layers.indices.contains(state.layer),
           let span = state.graphSpan {
            heading = "\(state.doc.layers[state.layer].name): frames \(span.start + 1) to \(span.end + 1)"
        } else if hasTween {
            heading = "Tween has no keyframe to run to yet"
        }
        Theme.label(heading, at: NSPoint(x: 10, y: 8), color: Theme.text, size: 11, bold: true)
        if !hasTween {
            Theme.label("Right-click a frame and choose Create Tween first.", at: NSPoint(x: 10, y: 24), color: Theme.dim, size: 10)
        }

        // Plot background and grid
        let top = toView(0, highest)
        let plot = NSRect(x: plotX, y: top.y, width: plotW, height: (highest - lowest) * unitH)
        Theme.frameEmpty.setFill()
        plot.fill()
        Theme.frameLine.setFill()
        for i in 0...4 {
            let x = plotX + CGFloat(i) / 4 * plotW
            NSRect(x: x, y: plot.minY, width: 1, height: plot.height).fill()
        }
        for v in [-0.5, 0.0, 0.5, 1.0, 1.5] {
            let y = toView(0, CGFloat(v)).y
            NSRect(x: plotX, y: y, width: plotW, height: 1).fill()
        }
        // The band from 0 to 1 is where an ordinary ease lives.
        Theme.dim.setStroke()
        let unit = NSBezierPath(rect: NSRect(x: plotX + 0.5, y: toView(0, 1).y + 0.5, width: plotW, height: unitH))
        unit.lineWidth = 1
        unit.stroke()
        Theme.label("end", at: NSPoint(x: 10, y: toView(0, 1).y - 7), color: Theme.dim, size: 9)
        Theme.label("start", at: NSPoint(x: 10, y: toView(0, 0).y - 7), color: Theme.dim, size: 9)
        Theme.label("time", at: NSPoint(x: plotX + plotW - 22, y: plot.maxY + 3), color: Theme.dim, size: 9)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        let from = toView(0, 0)
        let to = toView(1, 1)
        let h1 = handlePoint(0)
        let h2 = handlePoint(1)
        let ink = hasTween ? Theme.accent : Theme.dim

        // Handle arms
        Theme.dim.setStroke()
        let arms = NSBezierPath()
        arms.move(to: from)
        arms.line(to: h1)
        arms.move(to: to)
        arms.line(to: h2)
        arms.lineWidth = 1
        arms.stroke()

        // The curve
        ink.setStroke()
        let path = NSBezierPath()
        path.move(to: from)
        path.curve(to: to, controlPoint1: h1, controlPoint2: h2)
        path.lineWidth = 2.5
        path.stroke()

        // Where the playhead is along the tween
        if hasTween, state.doc.layers.indices.contains(state.layer),
           let span = state.graphSpan, span.end > span.start {
            let progress = CGFloat(state.frame - span.start) / CGFloat(span.end - span.start)
            let value = Tweening.cubic(curve, max(0, min(1, progress)))
            let p = toView(max(0, min(1, progress)), value)
            Theme.text.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }

        // Handles
        for h in [h1, h2] {
            let knob = NSBezierPath(ovalIn: NSRect(x: h.x - 6, y: h.y - 6, width: 12, height: 12))
            NSColor.white.setFill()
            knob.fill()
            ink.setStroke()
            knob.lineWidth = 2
            knob.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        dragging = -1
        guard state.graphTween != nil else {
            if p.y < 296 { NSSound.beep() }
            return
        }
        var best: CGFloat = 14
        for i in 0..<2 {
            let h = handlePoint(i)
            let d = hypot(p.x - h.x, p.y - h.y)
            if d < best {
                best = d
                dragging = i
            }
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard dragging >= 0 else { return }
        let p = convert(e.locationInWindow, from: nil)
        let x = max(0, min(1, (p.x - plotX) / plotW))
        let y = max(lowest, min(highest, (zeroY - p.y) / unitH))
        curve[dragging * 2] = x
        curve[dragging * 2 + 1] = y
        state.setTweenCurve(curve)
    }

    override func mouseUp(with e: NSEvent) {
        if dragging >= 0 {
            dragging = -1
            state.endCurveEdit()
            sync()
        }
    }
}
