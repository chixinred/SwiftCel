import UIKit

/// The tool strip: a single column of bevelled keys, with the fill colour beneath.
final class PadToolPanel: UIView {
    static let width: CGFloat = 56

    let state: AppState
    /// Called when the colour swatch under the tools is tapped.
    var onPickColor: (() -> Void)?
    private var rects: [Tool: CGRect] = [:]
    private var swatchRect = CGRect.zero
    private let headerH = PadPanelHeader.height

    init(state: AppState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: PadToolPanel.width, height: 500))
        isOpaque = true
        contentMode = .redraw
        state.observe { [weak self] in
            guard let self = self else { return }
            // Only the tool and the fill colour show here; skip redraws for anything else.
            let now = "\(self.state.tool.rawValue) \(self.state.color.hex) \(self.state.color.a)"
            if now != self.shown {
                self.shown = now
                self.setNeedsDisplay()
            }
        }
    }

    private var shown = ""
    private var icons: [String: UIImage] = [:]

    /// Tool icons are made once per size and colour, not on every redraw.
    private func icon(_ tool: Tool, size: CGFloat, ink: UIColor) -> UIImage? {
        let key = "\(tool.rawValue) \(size) \(ink.description)"
        if let made = icons[key] { return made }
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let made = UIImage(systemName: tool.symbol, withConfiguration: config)?.withTintColor(ink, renderingMode: .alwaysOriginal)
        if icons.count > 80 { icons.removeAll() }
        icons[key] = made
        return made
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keys shrink a little if the panel is too short for them all.
        let count = CGFloat(Tool.allCases.count)
        let room = bounds.height - headerH - 8 - 44 - safeAreaInsets.bottom
        let key = max(26, min(40, room / count - 4))
        let left = (bounds.width - key) / 2
        rects.removeAll()
        for (i, tool) in Tool.allCases.enumerated() {
            rects[tool] = CGRect(x: left, y: headerH + 8 + CGFloat(i) * (key + 4), width: key, height: key)
        }
        swatchRect = CGRect(x: left, y: headerH + 8 + count * (key + 4) + 8, width: key, height: 28)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds)
        Theme.bar(in: CGRect(x: 0, y: 0, width: bounds.width, height: headerH))
        let mid = bounds.width / 2
        for i in 0..<4 {
            Theme.fill(Theme.grip, CGRect(x: mid - 7 + CGFloat(i) * 4, y: headerH / 2 - 1, width: 2, height: 2))
        }

        for tool in Tool.allCases {
            guard let r = rects[tool] else { continue }
            let selected = tool == state.tool
            let shape = UIBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 5)
            ctx.saveGState()
            shape.addClip()
            if selected {
                // Pressed in: dark well, lit from below.
                Theme.gradient(Theme.pressedTop, Theme.pressedBottom, in: r)
            } else {
                Theme.gradient(Theme.keyTop, Theme.keyBottom, in: r)
                Theme.fill(Theme.highlight, CGRect(x: r.minX, y: r.minY + 1, width: r.width, height: 1))
            }
            ctx.restoreGState()
            (selected ? Theme.accentText : Theme.line).setStroke()
            shape.lineWidth = 1
            shape.stroke()

            let ink = selected ? UIColor.white : Theme.text
            if let img = icon(tool, size: (r.height * 0.46).rounded(), ink: ink) {
                img.draw(at: CGPoint(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2))
            } else {
                Theme.label(tool.letter.uppercased(), at: CGPoint(x: r.midX - 5, y: r.midY - 9), color: ink, size: 15, bold: true)
            }
        }

        // Current fill colour
        let well = UIBezierPath(roundedRect: swatchRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
        UIColor.white.setFill()
        well.fill()
        state.color.uiColor.setFill()
        well.fill()
        Theme.line.setStroke()
        well.stroke()

        Theme.fill(Theme.line, CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        if swatchRect.insetBy(dx: -6, dy: -6).contains(p) {
            onPickColor?()
            return
        }
        for (tool, r) in rects where r.insetBy(dx: -4, dy: -2).contains(p) {
            state.tool = tool
            // Selection and Transform share the selection; other tools drop it.
            if !tool.keepsSelection { state.selection.removeAll() }
            state.changed()
            return
        }
    }
}

/// Fill colour, brush size, smoothing and playback settings, down the right edge.
final class PadPropertiesPanel: UIView, UITextFieldDelegate, UIScribbleInteractionDelegate {
    static let width: CGFloat = 236

    let state: AppState
    /// Called after the stage size is changed here, so the view can be refitted.
    var onStageResized: (() -> Void)?

    private var actions: [Action] = []
    private let header = PadPanelHeader(title: "Properties")
    private let scroll = UIScrollView()
    private var captions: [UILabel] = []
    private var labels: [UILabel] = []
    private var sliders: [UISlider] = []
    private var switches: [UISwitch] = []

    let well = UIColorWell()
    private let sizeLabel = UILabel()
    private let sizeSlider = UISlider()
    private let smoothLabel = UILabel()
    private let smoothSlider = UISlider()
    private let pressureSwitch = UISwitch()
    private let legacySwitch = UISwitch()
    private let layerNameLabel = UILabel()
    private let opacityLabel = UILabel()
    private let opacitySlider = UISlider()
    private let onionSwitch = UISwitch()
    private let fpsLabel = UILabel()
    private let fpsSlider = UISlider()
    private var playButton: PadKeyButton?
    private let stageWidthField = UITextField()
    private let stageHeightField = UITextField()
    private let backgroundWell = UIColorWell()
    private let info = UILabel()

    private let inset: CGFloat = 14
    private var inner: CGFloat { return PadPropertiesPanel.width - inset - 12 }
    private var cursor: CGFloat = 12

    init(state: AppState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: PadPropertiesPanel.width, height: 500))
        isOpaque = true
        contentMode = .redraw
        clipsToBounds = true
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        scroll.delaysContentTouches = false
        addSubview(scroll)
        addSubview(header)

        // Fill and brush
        caption("Fill and brush")
        well.supportsAlpha = true
        well.title = "Fill colour"
        place(well, width: 44, height: 34, gap: 10)
        wire(well) { [weak self] in
            guard let self = self, let picked = self.well.selectedColor else { return }
            let c = RGBA(picked)
            if padSameColor(c, self.state.color) { return }
            self.state.color = c
            if self.state.hasSelection {
                self.state.recolorSelection()
            } else {
                self.state.changed()
            }
        }
        text(sizeLabel)
        slider(sizeSlider, 1, 100, gap: 6) { [weak self] in
            guard let self = self else { return }
            self.state.size = CGFloat(self.sizeSlider.value.rounded())
            self.state.changed()
        }
        text(smoothLabel)
        slider(smoothSlider, 0, 100, gap: 6) { [weak self] in
            guard let self = self else { return }
            self.state.smoothing = CGFloat(self.smoothSlider.value.rounded())
            self.state.changed()
        }
        toggle(pressureSwitch, "Use Pencil pressure", gap: 4) { [weak self] in
            guard let self = self else { return }
            self.state.usePressure = self.pressureSwitch.isOn
        }
        toggle(legacySwitch, "Legacy mode", gap: 18) { [weak self] in
            guard let self = self else { return }
            self.state.legacyBrush = self.legacySwitch.isOn
            self.state.changed()
        }

        // Selected layer
        caption("Selected layer")
        text(layerNameLabel)
        text(opacityLabel)
        slider(opacitySlider, 0, 100, gap: 18) { [weak self] in
            guard let self = self else { return }
            self.state.setLayerOpacity(CGFloat(self.opacitySlider.value.rounded()) / 100)
        }

        // Animation
        caption("Animation")
        toggle(onionSwitch, "Onion skin", gap: 6) { [weak self] in
            guard let self = self else { return }
            self.state.onionSkin = self.onionSwitch.isOn
            self.state.changed()
        }
        text(fpsLabel)
        slider(fpsSlider, 1, 60, gap: 8) { [weak self] in
            guard let self = self else { return }
            self.state.setFPS(Int(self.fpsSlider.value.rounded()))
            self.state.changed()
        }
        let play = PadKeyButton("Play", width: 76, height: 30) { [weak self] in
            self?.state.togglePlay()
        }
        playButton = play
        place(play, width: 76, height: 30, gap: 18)

        // Document
        caption("Document")
        let stageLabel = UILabel()
        stageLabel.text = "Stage size and background"
        text(stageLabel)
        let rowY = cursor
        var x = inset
        for field in [stageWidthField, stageHeightField] {
            field.frame = CGRect(x: x, y: rowY, width: 62, height: 30)
            field.borderStyle = .roundedRect
            field.font = UIFont.systemFont(ofSize: 13)
            field.keyboardType = .numbersAndPunctuation
            field.returnKeyType = .done
            field.textAlignment = .center
            field.delegate = self
            // No handwriting-to-text here: it makes Scribble watch the Pencil on the stage too.
            field.addInteraction(UIScribbleInteraction(delegate: self))
            scroll.addSubview(field)
            x += 62
            if field === stageWidthField {
                let times = UILabel(frame: CGRect(x: x, y: rowY, width: 18, height: 30))
                times.text = "\u{00D7}"
                times.textAlignment = .center
                times.font = UIFont.systemFont(ofSize: 13)
                labels.append(times)
                scroll.addSubview(times)
                x += 18
            }
        }
        backgroundWell.frame = CGRect(x: x + 10, y: rowY - 1, width: 34, height: 32)
        backgroundWell.supportsAlpha = false
        backgroundWell.title = "Stage background"
        scroll.addSubview(backgroundWell)
        wire(backgroundWell) { [weak self] in
            guard let self = self, let picked = self.backgroundWell.selectedColor else { return }
            self.state.setBackground(RGBA(picked))
        }
        cursor = rowY + 30 + 14

        info.numberOfLines = 4
        info.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        info.frame = CGRect(x: inset, y: cursor, width: inner, height: 54)
        scroll.addSubview(info)
        cursor += 54 + 14
        scroll.contentSize = CGSize(width: PadPropertiesPanel.width, height: cursor)

        state.observe { [weak self] in
            self?.syncSoon()
        }
        sync()
    }

    private var syncPending = false

    /// Many changes can arrive at once (and one per frame during playback); the panel
    /// catches up once, after they have all landed.
    private func syncSoon() {
        if syncPending { return }
        syncPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.syncPending = false
            self.sync()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Building rows

    private func wire(_ control: UIControl, _ fn: @escaping () -> Void) {
        let a = Action(fn)
        actions.append(a)
        control.addTarget(a, action: #selector(Action.fire), for: .valueChanged)
    }

    private func place(_ v: UIView, width: CGFloat, height: CGFloat, gap: CGFloat) {
        v.frame = CGRect(x: inset, y: cursor, width: width, height: height)
        scroll.addSubview(v)
        cursor += height + gap
    }

    private func caption(_ s: String) {
        let l = UILabel(frame: CGRect(x: inset, y: cursor, width: inner, height: 14))
        l.text = s.uppercased()
        l.font = UIFont.boldSystemFont(ofSize: 10)
        captions.append(l)
        scroll.addSubview(l)
        cursor += 14 + 7
    }

    private func text(_ l: UILabel) {
        l.frame = CGRect(x: inset, y: cursor, width: inner, height: 17)
        l.font = UIFont.systemFont(ofSize: 13)
        l.lineBreakMode = .byTruncatingTail
        labels.append(l)
        scroll.addSubview(l)
        cursor += 17 + 3
    }

    private func slider(_ s: UISlider, _ low: Float, _ high: Float, gap: CGFloat, _ fn: @escaping () -> Void) {
        s.minimumValue = low
        s.maximumValue = high
        s.frame = CGRect(x: inset, y: cursor, width: inner, height: 28)
        sliders.append(s)
        scroll.addSubview(s)
        wire(s, fn)
        cursor += 28 + gap
    }

    private func toggle(_ s: UISwitch, _ title: String, gap: CGFloat, _ fn: @escaping () -> Void) {
        let l = UILabel(frame: CGRect(x: inset, y: cursor, width: inner - 50, height: 28))
        l.text = title
        l.font = UIFont.systemFont(ofSize: 13)
        labels.append(l)
        scroll.addSubview(l)
        // A smaller switch, in keeping with the Mac panel's tick boxes.
        s.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
        s.center = CGPoint(x: inset + inner - 20, y: cursor + 14)
        switches.append(s)
        scroll.addSubview(s)
        wire(s, fn)
        cursor += 28 + gap
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PadPanelHeader.height)
        scroll.frame = CGRect(x: 0, y: PadPanelHeader.height, width: bounds.width,
                              height: max(0, bounds.height - PadPanelHeader.height))
    }

    override func draw(_ rect: CGRect) {
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds)
        Theme.fill(Theme.line, CGRect(x: 0, y: 0, width: 1, height: bounds.height))
        Theme.fill(Theme.line, CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))
    }

    // MARK: Stage size fields

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        let w = Int(stageWidthField.text ?? "") ?? Int(state.doc.width)
        let h = Int(stageHeightField.text ?? "") ?? Int(state.doc.height)
        state.setStageSize(width: w, height: h)
        onStageResized?()
        sync()
    }

    // MARK: Keeping the controls current

    private func sync() {
        // Colours are re-applied each time, so a theme change takes effect at once.
        for l in captions { l.textColor = Theme.accentText }
        for l in labels { l.textColor = Theme.text }
        for s in sliders { s.minimumTrackTintColor = Theme.accent }
        for s in switches { s.onTintColor = Theme.accent }
        info.textColor = Theme.dim
        setNeedsDisplay()

        if !padSameColor(RGBA(well.selectedColor ?? UIColor.clear), state.color) {
            well.selectedColor = state.color.uiColor
        }
        if !padSameColor(RGBA(backgroundWell.selectedColor ?? UIColor.clear), state.doc.background) {
            backgroundWell.selectedColor = state.doc.background.uiColor
        }
        let tool = state.tool
        sizeSlider.isEnabled = tool.hasSize
        if !sizeSlider.isTracking { sizeSlider.value = Float(state.size) }
        sizeLabel.text = tool.hasSize ? "Size: \(Int(state.size)) px" : "Size"
        if !smoothSlider.isTracking { smoothSlider.value = Float(state.smoothing) }
        smoothLabel.text = "Smoothing: \(Int(state.smoothing))"
        pressureSwitch.isOn = state.usePressure
        legacySwitch.isOn = state.legacyBrush

        let hasLayer = state.doc.layers.indices.contains(state.layer)
        layerNameLabel.text = hasLayer ? state.doc.layers[state.layer].name : ""
        let percent = Int((state.layerOpacity * 100).rounded())
        opacitySlider.isEnabled = hasLayer
        if !opacitySlider.isTracking { opacitySlider.value = Float(percent) }
        opacityLabel.text = "Opacity: \(percent)%"

        onionSwitch.isOn = state.onionSkin
        if !fpsSlider.isTracking { fpsSlider.value = Float(state.doc.fps) }
        fpsLabel.text = "Frame rate: \(state.doc.fps) fps"
        playButton?.title = state.isPlaying ? "Stop" : "Play"

        if !stageWidthField.isFirstResponder { stageWidthField.text = "\(Int(state.doc.width))" }
        if !stageHeightField.isFirstResponder { stageHeightField.text = "\(Int(state.doc.height))" }
        let w = Int(state.doc.width)
        let h = Int(state.doc.height)
        let pct = Int((state.zoom * 100).rounded())
        info.text = "Frame \(state.frame + 1) of \(state.doc.length)\nStage \(w) \u{00D7} \(h)\nZoom \(pct)%"
    }
}

/// The library: the document's symbols and bitmaps, listed under Properties.
final class PadLibraryPanel: UIView, UIGestureRecognizerDelegate {
    let state: AppState
    var onImport: (() -> Void)?
    var onNewSymbol: (() -> Void)?
    var onRename: (() -> Void)?

    private let header = PadPanelHeader(title: "Library")
    private let listTop: CGFloat = PadPanelHeader.height + 74
    private let rowH: CGFloat = 40
    private var scrollY: CGFloat = 0
    private var editButton: PadKeyButton?
    private var buttons: [PadKeyButton] = []
    private var shown = ""

    init(state: AppState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: PadPropertiesPanel.width, height: 260))
        isOpaque = true
        contentMode = .redraw
        clipsToBounds = true
        addSubview(header)

        let top = PadPanelHeader.height + 6
        addButton("Import Bitmap\u{2026}", x: 6, y: top, w: 118) { [weak self] in self?.onImport?() }
        addButton("New Symbol", x: 128, y: top, w: 102) { [weak self] in self?.onNewSymbol?() }
        addButton("Place", x: 6, y: top + 34, w: 52) { [weak self] in
            guard let self = self else { return }
            self.state.placeInstance(of: self.state.selectedItem)
        }
        editButton = addButton("Edit", x: 62, y: top + 34, w: 52) { [weak self] in
            guard let self = self else { return }
            if self.state.editingSymbol != nil {
                self.state.exitEdit()
            } else {
                self.state.enterEdit(self.state.selectedItem)
            }
        }
        addButton("Rename", x: 118, y: top + 34, w: 60) { [weak self] in self?.onRename?() }
        addButton("Delete", x: 182, y: top + 34, w: 48) { [weak self] in
            guard let self = self else { return }
            self.state.deleteItem(self.state.selectedItem)
        }

        let drag = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        for g in [drag, tap, double] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }

        state.observe { [weak self] in
            guard let self = self else { return }
            // The list only changes when the library, the highlighted item or the symbol
            // being edited changes, so other changes (like playback) skip the redraw.
            let items = self.state.doc.items.map { $0.id + $0.name + String($0.shapes?.count ?? -1) }.joined(separator: "|")
            let now = items + "/" + (self.state.selectedItem ?? "") + "/" + (self.state.editingSymbol ?? "")
            if now == self.shown { return }
            self.shown = now
            self.editButton?.title = self.state.editingSymbol != nil ? "Done" : "Edit"
            self.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @discardableResult
    private func addButton(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat, _ fn: @escaping () -> Void) -> PadKeyButton {
        let b = PadKeyButton(title, width: w, height: 28, fn)
        b.fontSize = 12
        b.frame.origin = CGPoint(x: x, y: y)
        buttons.append(b)
        addSubview(b)
        return b
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PadPanelHeader.height)
    }

    private func drawThumbnail(_ item: LibraryItem, in box: CGRect, ctx: CGContext) {
        Theme.fill(UIColor.white, box)
        Theme.line.setStroke()
        UIBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let doc = state.doc
        let extent = item.bounds(in: doc.items)
        guard extent.width > 0, extent.height > 0 else { return }
        let inner = box.insetBy(dx: 2, dy: 2)
        let scale = min(inner.width / extent.width, inner.height / extent.height)
        ctx.saveGState()
        ctx.clip(to: inner)
        ctx.translateBy(x: inner.midX - extent.midX * scale, y: inner.midY - extent.midY * scale)
        ctx.scaleBy(x: scale, y: scale)
        let preview = Shape(instanceOf: item, transform: CGAffineTransform.identity, library: doc.items)
        Renderer.drawShapes([preview], doc: doc, in: ctx)
        ctx.restoreGState()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds)
        let items = state.doc.items

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: listTop, width: bounds.width, height: max(0, bounds.height - listTop)))
        if items.isEmpty {
            Theme.label("Nothing here yet.", at: CGPoint(x: 12, y: listTop + 8), color: Theme.dim, size: 13)
            Theme.label("Import a bitmap, or select art on", at: CGPoint(x: 12, y: listTop + 30), color: Theme.dim, size: 11)
            Theme.label("the stage and tap New Symbol.", at: CGPoint(x: 12, y: listTop + 45), color: Theme.dim, size: 11)
        }
        for (i, item) in items.enumerated() {
            let y = listTop + CGFloat(i) * rowH - scrollY
            if y + rowH < listTop || y > bounds.height { continue }
            let row = CGRect(x: 0, y: y, width: bounds.width, height: rowH)
            let selected = item.id == state.selectedItem
            if selected {
                Theme.gradient(Theme.pressedBottom, Theme.pressedTop, in: row)
            } else {
                Theme.fill(Theme.row, row)
            }
            drawThumbnail(item, in: CGRect(x: 6, y: y + 4, width: 32, height: 32), ctx: ctx)
            let ink = selected ? Theme.accentInk : Theme.text
            let sub = selected ? Theme.accentInk : Theme.dim
            var name = item.name
            if item.id == state.editingSymbol { name += "  (editing)" }
            Theme.label(name, at: CGPoint(x: 46, y: y + 4), color: ink, size: 13)
            Theme.label(item.isSymbol ? "Symbol" : "Bitmap", at: CGPoint(x: 46, y: y + 22), color: sub, size: 10)
            Theme.fill(Theme.line, CGRect(x: 0, y: y + rowH - 1, width: bounds.width, height: 1))
        }
        ctx.restoreGState()

        Theme.fill(Theme.line, CGRect(x: 0, y: 0, width: 1, height: bounds.height))
        Theme.fill(Theme.line, CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))
        Theme.fill(Theme.line, CGRect(x: 0, y: listTop - 1, width: bounds.width, height: 1))
    }

    /// The list's gestures leave the buttons above it alone.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return touch.location(in: self).y >= listTop
    }

    private func item(at p: CGPoint) -> LibraryItem? {
        guard p.y >= listTop else { return nil }
        let index = Int(floor((p.y - listTop + scrollY) / rowH))
        let items = state.doc.items
        return items.indices.contains(index) ? items[index] : nil
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        guard p.y >= listTop else { return }
        state.selectedItem = item(at: p)?.id
        state.changed()
    }

    /// Double-tap an item to put a copy of it on the stage.
    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let picked = item(at: g.location(in: self)) else { return }
        state.selectedItem = picked.id
        state.placeInstance(of: picked.id)
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let contentH = CGFloat(state.doc.items.count) * rowH
        let maxY = max(0, contentH - (bounds.height - listTop))
        scrollY = max(0, min(maxY, scrollY - g.translation(in: self).y))
        g.setTranslation(.zero, in: self)
        setNeedsDisplay()
    }
}
