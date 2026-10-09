import AppKit

enum PanelKind {
    case tools, props, timeline
}

/// Tracks a press-and-drag on a panel's header strip, so a plain click does nothing
/// and a real drag moves the panel.
final class HeaderDrag {
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: ((NSPoint) -> Void)?
    private var start: NSPoint?
    private var active = false

    var isTracking: Bool { return start != nil }

    func down(_ e: NSEvent) {
        start = e.locationInWindow
        active = false
    }

    func dragged(_ e: NSEvent) {
        guard let s = start else { return }
        let p = e.locationInWindow
        if !active && hypot(p.x - s.x, p.y - s.y) > 5 {
            active = true
        }
        if active { onDrag?(p) }
    }

    func up(_ e: NSEvent) {
        if active { onDrop?(e.locationInWindow) }
        start = nil
        active = false
    }
}

/// The translucent strip that shows where a dragged panel will land.
final class DropHint: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.accent.withAlphaComponent(0.30).setFill()
        bounds.fill(using: .sourceOver)
        Theme.accent.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        edge.lineWidth = 3
        edge.stroke()
    }
}

/// Lays out the stage and the three panels. Panels can be dragged by their header to
/// the other side of the window, resized at their inner edge, or hidden.
final class WorkspaceView: NSView {
    private let canvas: NSView
    private let tools: NSView
    private let props: NSView
    private let timeline: NSView
    private let library: NSView
    private let hint = DropHint()
    private let gap: CGFloat = 5
    private let store = UserDefaults.standard

    private(set) var toolsOnRight = false
    private(set) var propsOnLeft = false
    private(set) var timelineOnTop = false
    private(set) var showTools = true
    private(set) var showProps = true
    private(set) var showTimeline = true
    private var propsWidth: CGFloat = PropertiesPanel.width
    private var timelineHeight: CGFloat = 170
    private var libraryHeight: CGFloat = 230

    private var propsDivider = NSRect.zero
    private var timelineDivider = NSRect.zero
    private var libraryDivider = NSRect.zero
    private enum Resize {
        case idle, props, timeline, library
    }
    private var resizing = Resize.idle

    init(frame: NSRect, canvas: NSView, tools: NSView, props: NSView, timeline: NSView, library: NSView) {
        self.canvas = canvas
        self.tools = tools
        self.props = props
        self.timeline = timeline
        self.library = library
        super.init(frame: frame)
        restore()
        for v in [canvas, timeline, tools, props, library] {
            v.autoresizingMask = []
            addSubview(v)
        }
        hint.isHidden = true
        addSubview(hint)
        layoutPanels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    // MARK: Saved arrangement

    private func flag(_ key: String, _ fallback: Bool) -> Bool {
        return store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
    }

    private func restore() {
        toolsOnRight = flag("ws.toolsOnRight", false)
        propsOnLeft = flag("ws.propsOnLeft", false)
        timelineOnTop = flag("ws.timelineOnTop", false)
        showTools = flag("ws.showTools", true)
        showProps = flag("ws.showProps", true)
        showTimeline = flag("ws.showTimeline", true)
        let w = store.double(forKey: "ws.propsWidth")
        if w > 0 { propsWidth = CGFloat(w) }
        let h = store.double(forKey: "ws.timelineHeight")
        if h > 0 { timelineHeight = CGFloat(h) }
        let lh = store.double(forKey: "ws.libraryHeight")
        if lh > 0 { libraryHeight = CGFloat(lh) }
    }

    private func save() {
        store.set(toolsOnRight, forKey: "ws.toolsOnRight")
        store.set(propsOnLeft, forKey: "ws.propsOnLeft")
        store.set(timelineOnTop, forKey: "ws.timelineOnTop")
        store.set(showTools, forKey: "ws.showTools")
        store.set(showProps, forKey: "ws.showProps")
        store.set(showTimeline, forKey: "ws.showTimeline")
        store.set(Double(propsWidth), forKey: "ws.propsWidth")
        store.set(Double(timelineHeight), forKey: "ws.timelineHeight")
        store.set(Double(libraryHeight), forKey: "ws.libraryHeight")
    }

    // MARK: Layout

    private var clampedPropsWidth: CGFloat {
        return max(PropertiesPanel.width, min(propsWidth, max(PropertiesPanel.width, bounds.width - 320)))
    }

    private var clampedTimelineHeight: CGFloat {
        return max(72, min(timelineHeight, max(72, bounds.height - 180)))
    }

    func layoutPanels() {
        var r = bounds
        timeline.isHidden = !showTimeline
        tools.isHidden = !showTools
        props.isHidden = !showProps
        timelineDivider = NSRect.zero
        propsDivider = NSRect.zero

        // Side panels run the full height; the timeline only spans the stage column.
        if showTools {
            let w = ToolPanel.width
            if toolsOnRight {
                tools.frame = NSRect(x: r.maxX - w, y: r.minY, width: w, height: r.height)
                r = NSRect(x: r.minX, y: r.minY, width: max(0, r.width - w), height: r.height)
            } else {
                tools.frame = NSRect(x: r.minX, y: r.minY, width: w, height: r.height)
                r = NSRect(x: r.minX + w, y: r.minY, width: max(0, r.width - w), height: r.height)
            }
        }
        if showProps {
            let w = clampedPropsWidth
            if propsOnLeft {
                props.frame = NSRect(x: r.minX, y: r.minY, width: w, height: r.height)
                propsDivider = NSRect(x: r.minX + w, y: r.minY, width: gap, height: r.height)
                r = NSRect(x: r.minX + w + gap, y: r.minY, width: max(0, r.width - w - gap), height: r.height)
            } else {
                props.frame = NSRect(x: r.maxX - w, y: r.minY, width: w, height: r.height)
                propsDivider = NSRect(x: r.maxX - w - gap, y: r.minY, width: gap, height: r.height)
                r = NSRect(x: r.minX, y: r.minY, width: max(0, r.width - w - gap), height: r.height)
            }
        }
        // The library sits under Properties, sharing its column.
        library.isHidden = !showProps
        libraryDivider = NSRect.zero
        if showProps {
            let col = props.frame
            let lh = max(110, min(libraryHeight, max(110, col.height - 220)))
            props.frame = NSRect(x: col.minX, y: col.minY, width: col.width, height: max(0, col.height - lh - gap))
            libraryDivider = NSRect(x: col.minX, y: col.maxY - lh - gap, width: col.width, height: gap)
            library.frame = NSRect(x: col.minX, y: col.maxY - lh, width: col.width, height: lh)
        }
        if showTimeline {
            let h = clampedTimelineHeight
            if timelineOnTop {
                timeline.frame = NSRect(x: r.minX, y: r.minY, width: r.width, height: h)
                timelineDivider = NSRect(x: r.minX, y: r.minY + h, width: r.width, height: gap)
                r = NSRect(x: r.minX, y: r.minY + h + gap, width: r.width, height: max(0, r.height - h - gap))
            } else {
                timeline.frame = NSRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
                timelineDivider = NSRect(x: r.minX, y: r.maxY - h - gap, width: r.width, height: gap)
                r = NSRect(x: r.minX, y: r.minY, width: r.width, height: max(0, r.height - h - gap))
            }
        }
        canvas.frame = r
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// How large the interface is drawn (1 = normal). The view's own coordinate space is
    /// made smaller than its frame, so everything inside, text included, is drawn bigger.
    var uiScale: CGFloat = 1 {
        didSet { applyScale() }
    }

    private func applyScale() {
        let s = max(1, min(2, uiScale))
        setBoundsSize(NSSize(width: frame.width / s, height: frame.height / s))
        layoutPanels()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScale()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutPanels()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelDark.setFill()
        bounds.fill()
        // Divider handles: a short grip in the middle of each.
        Theme.grip.setFill()
        if propsDivider.width > 0 {
            NSRect(x: propsDivider.midX - 0.5, y: propsDivider.midY - 14, width: 1, height: 28).fill(using: .sourceOver)
        }
        if libraryDivider.height > 0 {
            NSRect(x: libraryDivider.midX - 14, y: libraryDivider.midY - 0.5, width: 28, height: 1).fill(using: .sourceOver)
        }
        if timelineDivider.height > 0 {
            NSRect(x: timelineDivider.midX - 14, y: timelineDivider.midY - 0.5, width: 28, height: 1).fill(using: .sourceOver)
        }
    }

    override func resetCursorRects() {
        if propsDivider.width > 0 {
            addCursorRect(propsDivider, cursor: NSCursor.resizeLeftRight)
        }
        if libraryDivider.height > 0 {
            addCursorRect(libraryDivider, cursor: NSCursor.resizeUpDown)
        }
        if timelineDivider.height > 0 {
            addCursorRect(timelineDivider, cursor: NSCursor.resizeUpDown)
        }
    }

    // MARK: Resizing at the dividers

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if propsDivider.insetBy(dx: -2, dy: 0).contains(p) {
            resizing = .props
        } else if libraryDivider.insetBy(dx: 0, dy: -2).contains(p) {
            resizing = .library
        } else if timelineDivider.insetBy(dx: 0, dy: -2).contains(p) {
            resizing = .timeline
        } else {
            resizing = .idle
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch resizing {
        case .props:
            propsWidth = propsOnLeft ? p.x - props.frame.minX : props.frame.maxX - p.x
            propsWidth = clampedPropsWidth
            layoutPanels()
        case .timeline:
            timelineHeight = timelineOnTop ? p.y - timeline.frame.minY : timeline.frame.maxY - p.y
            timelineHeight = clampedTimelineHeight
            layoutPanels()
        case .library:
            libraryHeight = max(110, library.frame.maxY - p.y)
            layoutPanels()
        case .idle:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        if resizing != .idle { save() }
        resizing = .idle
    }

    // MARK: Moving panels

    private func target(for kind: PanelKind, at windowPoint: NSPoint) -> (far: Bool, frame: NSRect) {
        let p = convert(windowPoint, from: nil)
        switch kind {
        case .timeline:
            let top = p.y < bounds.midY
            let h = clampedTimelineHeight
            let column = showTimeline ? timeline.frame : canvas.frame
            return (top, NSRect(x: column.minX, y: top ? 0 : bounds.height - h, width: column.width, height: h))
        case .tools:
            let right = p.x > bounds.midX
            let w = ToolPanel.width
            return (right, NSRect(x: right ? bounds.width - w : 0, y: 0, width: w, height: bounds.height))
        case .props:
            let left = p.x < bounds.midX
            let w = clampedPropsWidth
            return (left, NSRect(x: left ? 0 : bounds.width - w, y: 0, width: w, height: bounds.height))
        }
    }

    func dragging(_ kind: PanelKind, at windowPoint: NSPoint) {
        hint.frame = target(for: kind, at: windowPoint).frame
        hint.isHidden = false
        hint.needsDisplay = true
    }

    func drop(_ kind: PanelKind, at windowPoint: NSPoint) {
        hint.isHidden = true
        let t = target(for: kind, at: windowPoint)
        switch kind {
        case .timeline: timelineOnTop = t.far
        case .tools: toolsOnRight = t.far
        case .props: propsOnLeft = t.far
        }
        save()
        layoutPanels()
    }

    func swapSide(_ kind: PanelKind) {
        switch kind {
        case .timeline: timelineOnTop.toggle()
        case .tools: toolsOnRight.toggle()
        case .props: propsOnLeft.toggle()
        }
        save()
        layoutPanels()
    }

    func toggleVisible(_ kind: PanelKind) {
        switch kind {
        case .timeline: showTimeline.toggle()
        case .tools: showTools.toggle()
        case .props: showProps.toggle()
        }
        save()
        layoutPanels()
    }

    func reset() {
        toolsOnRight = false
        propsOnLeft = false
        timelineOnTop = false
        showTools = true
        showProps = true
        showTimeline = true
        propsWidth = PropertiesPanel.width
        timelineHeight = 170
        libraryHeight = 230
        save()
        layoutPanels()
    }
}
