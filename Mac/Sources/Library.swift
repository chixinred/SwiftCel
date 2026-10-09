import AppKit

/// The library: the document's symbols and bitmaps, listed under Properties.
final class LibraryPanel: NSView {
    let state: AppState
    var onImport: (() -> Void)?
    var onNewSymbol: (() -> Void)?
    var onRename: (() -> Void)?

    private var actions: [Action] = []
    let header = PanelHeader(title: "Library")
    private let listTop: CGFloat = 78
    private let rowH: CGFloat = 30
    private var scrollY: CGFloat = 0
    private var editButton: NSButton?

    init(state: AppState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: PropertiesPanel.width, height: 230))
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 22)
        header.autoresizingMask = [.width]
        addSubview(header)

        addButton("Import Bitmap…", x: 6, y: 27, w: 106, tip: "Add an image file to the library and place it on the stage") { [weak self] in
            self?.onImport?()
        }
        addButton("New Symbol", x: 114, y: 27, w: 100, tip: "Turn the selected art into a reusable symbol") { [weak self] in
            self?.onNewSymbol?()
        }
        addButton("Place", x: 6, y: 51, w: 50, tip: "Put the highlighted item on the stage") { [weak self] in
            guard let self = self else { return }
            self.state.placeInstance(of: self.state.selectedItem)
        }
        editButton = addButton("Edit", x: 58, y: 51, w: 50, tip: "Edit the highlighted symbol's art, or finish editing") { [weak self] in
            guard let self = self else { return }
            if self.state.editingSymbol != nil {
                self.state.exitEdit()
            } else {
                self.state.enterEdit(self.state.selectedItem)
            }
        }
        addButton("Rename", x: 110, y: 51, w: 56, tip: "Rename the highlighted item") { [weak self] in
            self?.onRename?()
        }
        addButton("Delete", x: 168, y: 51, w: 46, tip: "Remove the highlighted item and every copy of it on the stage") { [weak self] in
            guard let self = self else { return }
            self.state.deleteItem(self.state.selectedItem)
        }

        state.observe { [weak self] in
            guard let self = self else { return }
            self.editButton?.title = self.state.editingSymbol != nil ? "Done" : "Edit"
            self.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    @discardableResult
    private func addButton(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat, tip: String,
                           _ fn: @escaping () -> Void) -> NSButton {
        let a = Action(fn)
        actions.append(a)
        let b = NSButton(title: title, target: a, action: #selector(Action.fire))
        b.bezelStyle = .smallSquare
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: 10)
        b.frame = NSRect(x: x, y: y, width: w, height: 21)
        b.toolTip = tip
        b.refusesFirstResponder = true
        addSubview(b)
        return b
    }

    private func drawThumbnail(_ item: LibraryItem, in box: NSRect) {
        NSColor.white.setFill()
        box.fill()
        Theme.line.setStroke()
        NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
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

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds, flipped: true)
        let items = state.doc.items

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: listTop, width: bounds.width, height: max(0, bounds.height - listTop))).addClip()
        if items.isEmpty {
            Theme.label("Nothing here yet.", at: NSPoint(x: 12, y: listTop + 8), color: Theme.dim)
            Theme.label("Import a bitmap, or select art on", at: NSPoint(x: 12, y: listTop + 28), color: Theme.dim, size: 10)
            Theme.label("the stage and click New Symbol.", at: NSPoint(x: 12, y: listTop + 42), color: Theme.dim, size: 10)
        }
        for (i, item) in items.enumerated() {
            let y = listTop + CGFloat(i) * rowH - scrollY
            if y + rowH < listTop || y > bounds.height { continue }
            let row = NSRect(x: 0, y: y, width: bounds.width, height: rowH)
            let selected = item.id == state.selectedItem
            if selected {
                Theme.gradient(Theme.pressedBottom, Theme.pressedTop, in: row, flipped: true)
            } else {
                Theme.row.setFill()
                row.fill()
            }
            drawThumbnail(item, in: NSRect(x: 6, y: y + 3, width: 24, height: 24))
            let ink = selected ? Theme.accentInk : Theme.text
            let sub = selected ? Theme.accentInk : Theme.dim
            var name = item.name
            if item.id == state.editingSymbol { name += "  (editing)" }
            Theme.label(name, at: NSPoint(x: 38, y: y + 2), color: ink)
            Theme.label(item.isSymbol ? "Symbol" : "Bitmap", at: NSPoint(x: 38, y: y + 16), color: sub, size: 9)
            Theme.line.setFill()
            NSRect(x: 0, y: y + rowH - 1, width: bounds.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        Theme.line.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: listTop - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard p.y >= listTop else { return }
        let index = Int(floor((p.y - listTop + scrollY) / rowH))
        let items = state.doc.items
        guard items.indices.contains(index) else {
            state.selectedItem = nil
            state.changed()
            return
        }
        state.selectedItem = items[index].id
        if e.clickCount == 2 {
            state.placeInstance(of: items[index].id)
        } else {
            state.changed()
        }
    }

    override func scrollWheel(with e: NSEvent) {
        let contentH = CGFloat(state.doc.items.count) * rowH
        let maxY = max(0, contentH - (bounds.height - listTop))
        scrollY = max(0, min(maxY, scrollY - e.scrollingDeltaY))
        needsDisplay = true
    }
}
