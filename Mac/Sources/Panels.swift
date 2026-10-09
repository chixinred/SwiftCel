import AppKit

/// The tool strip: a single column of bevelled keys.
final class ToolPanel: NSView {
    static let width: CGFloat = 42

    let state: AppState
    private var rects: [Tool: NSRect] = [:]
    private var tips: [NSString] = []
    private let headerH: CGFloat = 22
    private var swatchRect = NSRect.zero
    let headerDrag = HeaderDrag()

    init(state: AppState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: ToolPanel.width, height: 500))
        let key: CGFloat = 28
        let gap: CGFloat = 3
        let left = (ToolPanel.width - key) / 2
        for (i, tool) in Tool.allCases.enumerated() {
            let r = NSRect(x: left, y: headerH + 8 + CGFloat(i) * (key + gap), width: key, height: key)
            rects[tool] = r
            let tip = tool.title as NSString
            tips.append(tip)
            _ = addToolTip(r, owner: tip, userData: nil)
        }
        let rowCount = CGFloat(Tool.allCases.count)
        swatchRect = NSRect(x: left, y: headerH + 8 + rowCount * (key + gap) + 10, width: key, height: 22)
        state.observe { [weak self] in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    private func icon(for tool: Tool, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(config)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds, flipped: true)
        Theme.bar(in: NSRect(x: 0, y: 0, width: bounds.width, height: headerH), flipped: true)
        Theme.grip.setFill()
        for i in 0..<4 {
            NSRect(x: bounds.midX - 7 + CGFloat(i) * 4, y: headerH / 2 - 1, width: 2, height: 2).fill(using: .sourceOver)
        }

        for tool in Tool.allCases {
            guard let r = rects[tool] else { continue }
            let selected = tool == state.tool
            let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if selected {
                // Pressed in: dark well, lit from below.
                Theme.gradient(Theme.pressedTop, Theme.pressedBottom, in: r, flipped: true)
            } else {
                Theme.gradient(Theme.keyTop, Theme.keyBottom, in: r, flipped: true)
                Theme.highlight.setFill()
                NSRect(x: r.minX, y: r.minY + 1, width: r.width, height: 1).fill(using: .sourceOver)
            }
            NSGraphicsContext.restoreGraphicsState()
            (selected ? Theme.accentText : Theme.line).setStroke()
            shape.lineWidth = 1
            shape.stroke()

            let ink = selected ? NSColor.white : Theme.text
            if let img = icon(for: tool, color: ink) {
                let s = img.size
                let target = NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height)
                img.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                Theme.label(tool.letter.uppercased(), at: NSPoint(x: r.midX - 4, y: r.midY - 7), color: ink, size: 12, bold: true)
            }
        }

        // Current fill colour
        let well = NSBezierPath(roundedRect: swatchRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSColor.white.setFill()
        well.fill()
        state.color.nsColor.setFill()
        well.fill()
        Theme.line.setStroke()
        well.stroke()

        Theme.line.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDragged(with e: NSEvent) {
        headerDrag.dragged(e)
    }

    override func mouseUp(with e: NSEvent) {
        headerDrag.up(e)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if p.y < headerH {
            headerDrag.down(e)
            return
        }
        for (tool, r) in rects where r.contains(p) {
            state.tool = tool
            // Selection and Transform share the selection; other tools drop it.
            if !tool.keepsSelection { state.selection.removeAll() }
            state.changed()
            return
        }
    }
}

/// Fill colour, brush size, smoothing and playback settings, down the right edge.
final class PropertiesPanel: NSView {
    static let width: CGFloat = 220

    let state: AppState
    private var actions: [Action] = []

    private let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 56, height: 28))
    private let sizeLabel = NSTextField(labelWithString: "Size")
    private let sizeSlider = NSSlider(value: 12, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let smoothLabel = NSTextField(labelWithString: "Smoothing")
    private let smoothSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let pressureBox = NSButton(checkboxWithTitle: "Use tablet pressure", target: nil, action: nil)
    private let legacyBox = NSButton(checkboxWithTitle: "Legacy mode", target: nil, action: nil)
    private let onionBox = NSButton(checkboxWithTitle: "Onion skin", target: nil, action: nil)
    private let onionButton = NSButton(title: "Onion Skin Settings…", target: nil, action: nil)
    var onOnionSettings: (() -> Void)?
    private let layerNameLabel = NSTextField(labelWithString: "")
    private let opacityLabel = NSTextField(labelWithString: "Opacity")
    private let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let fpsLabel = NSTextField(labelWithString: "Frame rate")
    private let fpsSlider = NSSlider(value: 24, minValue: 1, maxValue: 60, target: nil, action: nil)
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let info = NSTextField(labelWithString: "")
    let header = PanelHeader(title: "Properties")
    private var captions: [NSTextField] = []
    private let stageWidthField = NSTextField(string: "")
    private let stageHeightField = NSTextField(string: "")
    private let backgroundWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
    /// Called after the stage size is changed here, so the view can be refitted.
    var onStageResized: (() -> Void)?
    private var stackTop: NSLayoutConstraint?
    private var stageLabels: [NSTextField] = []
    private var content: NSStackView?
    private var scrollY: CGFloat = 0

    init(state: AppState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: PropertiesPanel.width, height: 500))

        wire(well) { [weak self] in
            guard let self = self else { return }
            self.state.color = RGBA(self.well.color)
            if self.state.hasSelection {
                self.state.recolorSelection()
            } else {
                self.state.changed()
            }
        }
        wire(sizeSlider) { [weak self] in
            guard let self = self else { return }
            self.state.size = CGFloat(self.sizeSlider.doubleValue.rounded())
            self.state.changed()
        }
        wire(smoothSlider) { [weak self] in
            guard let self = self else { return }
            self.state.smoothing = CGFloat(self.smoothSlider.doubleValue.rounded())
            self.state.changed()
        }
        wire(pressureBox) { [weak self] in
            guard let self = self else { return }
            self.state.usePressure = self.pressureBox.state == .on
        }
        wire(legacyBox) { [weak self] in
            guard let self = self else { return }
            self.state.legacyBrush = self.legacyBox.state == .on
            self.state.changed()
        }
        legacyBox.toolTip = "On: the classic brush that re-fits and wobbles the stroke when you let go. Off: a modern brush that keeps the stroke as drawn."
        wire(onionBox) { [weak self] in
            guard let self = self else { return }
            self.state.onionSkin = self.onionBox.state == .on
            self.state.changed()
        }
        wire(opacitySlider) { [weak self] in
            guard let self = self else { return }
            self.state.setLayerOpacity(CGFloat(self.opacitySlider.doubleValue.rounded()) / 100)
        }
        wire(onionButton) { [weak self] in
            self?.onOnionSettings?()
        }
        onionButton.bezelStyle = .rounded
        onionButton.controlSize = .small
        onionButton.font = NSFont.systemFont(ofSize: 11)
        wire(fpsSlider) { [weak self] in
            guard let self = self else { return }
            self.state.setFPS(Int(self.fpsSlider.doubleValue.rounded()))
        }
        wire(playButton) { [weak self] in
            self?.state.togglePlay()
        }

        header.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(header)   // after the stack, so scrolled settings pass under the header
        content = stack
        if #available(macOS 14.0, *) {
            clipsToBounds = true
        }
        let top = stack.topAnchor.constraint(equalTo: header.bottomAnchor)
        stackTop = top
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 22),
            top,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let brushCaption = caption("Fill and brush")
        let animCaption = caption("Animation")
        let layerCaption = caption("Selected layer")
        let docCaption = caption("Document")
        let stageLabel = NSTextField(labelWithString: "Stage size and background")
        let times = NSTextField(labelWithString: "×")
        let stageRow = NSStackView(views: [stageWidthField, times, stageHeightField, backgroundWell])
        stageRow.orientation = .horizontal
        stageRow.spacing = 6
        for f in [stageWidthField, stageHeightField] {
            f.font = NSFont.systemFont(ofSize: 11)
            f.controlSize = .small
            f.widthAnchor.constraint(equalToConstant: 54).isActive = true
        }
        backgroundWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        backgroundWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stageLabel.font = NSFont.systemFont(ofSize: 11)
        stageLabels = [stageLabel, times]
        let applyStage: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.state.setStageSize(width: Int(self.stageWidthField.intValue), height: Int(self.stageHeightField.intValue))
            self.onStageResized?()
        }
        wire(stageWidthField, applyStage)
        wire(stageHeightField, applyStage)
        wire(backgroundWell) { [weak self] in
            guard let self = self else { return }
            self.state.setBackground(RGBA(self.backgroundWell.color))
        }
        let rows: [NSView] = [brushCaption, well, sizeLabel, sizeSlider, smoothLabel, smoothSlider, pressureBox, legacyBox,
                              layerCaption, layerNameLabel, opacityLabel, opacitySlider,
                              animCaption, onionBox, onionButton, fpsLabel, fpsSlider, playButton,
                              docCaption, stageLabel, stageRow, info]
        for v in rows {
            stack.addArrangedSubview(v)
        }
        stack.setCustomSpacing(12, after: well)
        stack.setCustomSpacing(10, after: smoothSlider)
        stack.setCustomSpacing(20, after: legacyBox)
        stack.setCustomSpacing(20, after: opacitySlider)
        stack.setCustomSpacing(10, after: onionButton)
        stack.setCustomSpacing(12, after: fpsSlider)
        stack.setCustomSpacing(20, after: playButton)
        stack.setCustomSpacing(16, after: stageRow)

        for slider in [sizeSlider, smoothSlider, opacitySlider, fpsSlider] {
            slider.widthAnchor.constraint(equalToConstant: 190).isActive = true
            slider.refusesFirstResponder = true
            slider.controlSize = .small
        }
        well.widthAnchor.constraint(equalToConstant: 56).isActive = true
        well.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for b in [pressureBox, legacyBox, onionBox, onionButton, playButton] {
            b.refusesFirstResponder = true
        }
        for l in [sizeLabel, smoothLabel, layerNameLabel, opacityLabel, fpsLabel] {
            l.textColor = Theme.text
            l.font = NSFont.systemFont(ofSize: 11)
        }
        playButton.bezelStyle = .rounded
        info.textColor = Theme.dim
        info.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        info.maximumNumberOfLines = 4

        state.observe { [weak self] in
            self?.sync()
        }
        sync()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds, flipped: false)
        Theme.line.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = NSFont.boldSystemFont(ofSize: 9)
        l.textColor = Theme.accentText
        captions.append(l)
        return l
    }

    private func wire(_ control: NSControl, _ fn: @escaping () -> Void) {
        let a = Action(fn)
        actions.append(a)
        control.target = a
        control.action = #selector(Action.fire)
    }

    /// The settings scroll when the panel is too short to show them all.
    override func scrollWheel(with e: NSEvent) {
        clampScroll(scrollY - e.scrollingDeltaY)
    }

    private func clampScroll(_ wanted: CGFloat) {
        guard let stack = content else { return }
        let room = bounds.height - 22
        let limit = max(0, stack.fittingSize.height - room)
        scrollY = max(0, min(limit, wanted))
        stackTop?.constant = -scrollY
    }

    private func sync() {
        clampScroll(scrollY)
        for l in stageLabels { l.textColor = Theme.text }
        if stageWidthField.currentEditor() == nil { stageWidthField.stringValue = "\(Int(state.doc.width))" }
        if stageHeightField.currentEditor() == nil { stageHeightField.stringValue = "\(Int(state.doc.height))" }
        if RGBA(backgroundWell.color) != state.doc.background {
            backgroundWell.color = state.doc.background.nsColor
        }
        // Colours are re-applied each time, so a theme change takes effect at once.
        for l in captions { l.textColor = Theme.accentText }
        for l in [sizeLabel, smoothLabel, layerNameLabel, opacityLabel, fpsLabel] { l.textColor = Theme.text }
        info.textColor = Theme.dim
        needsDisplay = true
        let fill = state.color.nsColor
        if RGBA(well.color) != state.color {
            well.color = fill
        }
        let tool = state.tool
        sizeSlider.isEnabled = tool.hasSize
        sizeSlider.doubleValue = Double(state.size)
        sizeLabel.stringValue = tool.hasSize ? "Size: \(Int(state.size)) px" : "Size"
        smoothSlider.doubleValue = Double(state.smoothing)
        smoothLabel.stringValue = "Smoothing: \(Int(state.smoothing))"
        pressureBox.state = state.usePressure ? .on : .off
        legacyBox.state = state.legacyBrush ? .on : .off
        smoothLabel.toolTip = state.legacyBrush
            ? "How loosely the outline is re-fitted when you let go."
            : "How much your hand is steadied while drawing."
        let hasLayer = state.doc.layers.indices.contains(state.layer)
        layerNameLabel.stringValue = hasLayer ? state.doc.layers[state.layer].name : ""
        let percent = Int((state.layerOpacity * 100).rounded())
        opacitySlider.isEnabled = hasLayer
        opacitySlider.doubleValue = Double(percent)
        opacityLabel.stringValue = "Opacity: \(percent)%"
        onionBox.state = state.onionSkin ? .on : .off
        fpsSlider.doubleValue = Double(state.doc.fps)
        fpsLabel.stringValue = "Frame rate: \(state.doc.fps) fps"
        playButton.title = state.isPlaying ? "Stop" : "Play"
        let w = Int(state.doc.width)
        let h = Int(state.doc.height)
        let pct = Int((state.zoom * 100).rounded())
        info.stringValue = "Frame \(state.frame + 1) of \(state.doc.length)\nStage \(w) × \(h)\nZoom \(pct)%"
    }
}
