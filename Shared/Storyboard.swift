#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One storyboard panel: a keyframe on the storyboard layer and the frames it is held for.
struct BoardPanel {
    var start: Int
    var length: Int
    var note: String
}

#if os(macOS)
/// The storyboard window. The board is a view of the special "Storyboard" layer: every
/// keyframe on it is a panel, how long it is held is the panel's duration, and each panel
/// can carry a caption. Because it is a real layer, panels are drawn on the stage with
/// the normal tools, the animatic is simply the timeline playing (with its audio), and
/// the finished board sits under the animation as a guide.
final class StoryboardView: NSView {
    let state: AppState
    var onExport: (() -> Void)?

    private var actions: [Action] = []
    private var thumbs: [Int: CGImage] = [:]
    private var scrollY: CGFloat = 0
    private let topBar: CGFloat = 40
    private let bottomBar: CGFloat = 62
    private let cardW: CGFloat = 184
    private let captionField = NSTextField(string: "")
    private let framesField = NSTextField(string: "")
    private let captionLabel = NSTextField(labelWithString: "Caption")
    private let framesLabel = NSTextField(labelWithString: "Frames")
    private let timeLabel = NSTextField(labelWithString: "")
    private var playButton: NSButton?

    init(state: AppState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 780, height: 520))
        var x: CGFloat = 10
        func button(_ title: String, _ width: CGFloat, _ tip: String, _ fn: @escaping () -> Void) -> NSButton {
            let a = Action(fn)
            actions.append(a)
            let b = NSButton(title: title, target: a, action: #selector(Action.fire))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            b.frame = NSRect(x: x, y: 8, width: width, height: 24)
            b.toolTip = tip
            b.refusesFirstResponder = true
            addSubview(b)
            x += width + 4
            return b
        }
        _ = button("New Panel", 86, "Add a blank panel after the current one") { [weak self] in self?.state.addPanel() }
        _ = button("Duplicate", 80, "Copy the current panel") { [weak self] in self?.state.duplicatePanel() }
        _ = button("Delete", 64, "Delete the current panel") { [weak self] in self?.state.deletePanel() }
        _ = button("◀ Earlier", 78, "Move the current panel earlier") { [weak self] in self?.state.movePanel(by: -1) }
        _ = button("Later ▶", 72, "Move the current panel later") { [weak self] in self?.state.movePanel(by: 1) }
        x += 10
        playButton = button("Play Animatic", 104, "Play the board from the start, with audio") { [weak self] in
            guard let self = self else { return }
            if self.state.isPlaying {
                self.state.stop()
            } else {
                self.state.goto(0)
                self.state.play()
            }
        }
        _ = button("Export Sheet…", 100, "Save the board as a printable PDF") { [weak self] in self?.onExport?() }

        for f in [captionField, framesField] {
            f.font = NSFont.systemFont(ofSize: 12)
            addSubview(f)
        }
        for l in [captionLabel, framesLabel, timeLabel] {
            l.font = NSFont.systemFont(ofSize: 11)
            addSubview(l)
        }
        captionField.placeholderString = "Dialogue, action or camera note for this panel"
        let captionAction = Action { [weak self] in
            guard let self = self else { return }
            self.state.setPanelNote(self.captionField.stringValue)
        }
        let framesAction = Action { [weak self] in
            guard let self = self else { return }
            self.state.setPanelLength(Int(self.framesField.intValue))
        }
        actions.append(captionAction)
        actions.append(framesAction)
        captionField.target = captionAction
        captionField.action = #selector(Action.fire)
        framesField.target = framesAction
        framesField.action = #selector(Action.fire)

        layoutControls()
        state.observe { [weak self] in
            self?.sync()
        }
        sync()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    private func layoutControls() {
        let y = bounds.height - bottomBar
        captionLabel.frame = NSRect(x: 12, y: y + 8, width: 60, height: 16)
        captionField.frame = NSRect(x: 12, y: y + 26, width: max(120, bounds.width - 230), height: 24)
        framesLabel.frame = NSRect(x: bounds.width - 206, y: y + 8, width: 60, height: 16)
        framesField.frame = NSRect(x: bounds.width - 206, y: y + 26, width: 64, height: 24)
        timeLabel.frame = NSRect(x: bounds.width - 134, y: y + 30, width: 124, height: 16)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutControls()
        needsDisplay = true
    }

    private func sync() {
        // Thumbnails are redrawn after any change, but kept while the animatic plays.
        if !state.isPlaying { thumbs.removeAll() }
        let panels = state.boardPanels
        let current = state.currentPanel
        let has = current != nil && panels.indices.contains(current ?? -1)
        captionField.isEnabled = has
        framesField.isEnabled = has
        for l in [captionLabel, framesLabel, timeLabel] { l.textColor = Theme.text }
        if let i = current, panels.indices.contains(i) {
            if captionField.currentEditor() == nil { captionField.stringValue = panels[i].note }
            if framesField.currentEditor() == nil { framesField.stringValue = "\(panels[i].length)" }
            let seconds = Double(panels[i].length) / Double(max(1, state.doc.fps))
            timeLabel.stringValue = String(format: "= %.2f seconds", seconds)
        } else {
            if captionField.currentEditor() == nil { captionField.stringValue = "" }
            if framesField.currentEditor() == nil { framesField.stringValue = "" }
            timeLabel.stringValue = ""
        }
        playButton?.title = state.isPlaying ? "Stop" : "Play Animatic"
        needsDisplay = true
    }

    // MARK: Cards

    private var thumbSize: NSSize {
        let w = cardW - 24
        let ratio = state.doc.height / max(1, state.doc.width)
        return NSSize(width: w, height: min(150, max(40, w * ratio)))
    }

    private var cardH: CGFloat {
        return thumbSize.height + 64
    }

    private var columns: Int {
        return max(1, Int((bounds.width - 12) / cardW))
    }

    private func cardRect(_ i: Int) -> NSRect {
        let col = CGFloat(i % columns)
        let rowIndex = CGFloat(i / columns)
        return NSRect(x: 8 + col * cardW, y: topBar + 6 + rowIndex * (cardH + 8) - scrollY, width: cardW - 8, height: cardH)
    }

    private func thumbnail(for panel: BoardPanel) -> CGImage? {
        if let hit = thumbs[panel.start] { return hit }
        let scale = min(2.0, max(0.1, 2 * thumbSize.width / max(1, state.doc.width)))
        guard let img = Renderer.image(doc: state.doc, frame: panel.start, scale: scale) else { return nil }
        thumbs[panel.start] = img
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds, flipped: true)
        let panels = state.boardPanels
        let grid = NSRect(x: 0, y: topBar, width: bounds.width, height: max(0, bounds.height - topBar - bottomBar))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: grid).addClip()
        if panels.isEmpty {
            Theme.label("No storyboard yet.", at: NSPoint(x: 16, y: topBar + 16), color: Theme.text, size: 13, bold: true)
            Theme.label("Click New Panel to start one. It adds a Storyboard layer to the timeline;", at: NSPoint(x: 16, y: topBar + 40), color: Theme.dim)
            Theme.label("each panel is a drawing on that layer, held for as long as you set.", at: NSPoint(x: 16, y: topBar + 56), color: Theme.dim)
        }
        let current = state.currentPanel
        let fps = Double(max(1, state.doc.fps))
        for (i, panel) in panels.enumerated() {
            let card = cardRect(i)
            if card.maxY < grid.minY || card.minY > grid.maxY { continue }
            let selected = i == current
            let body = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (selected ? Theme.frameEmpty : Theme.row).setFill()
            body.fill()
            (selected ? Theme.accent : Theme.line).setStroke()
            body.lineWidth = selected ? 2.5 : 1
            body.stroke()

            let size = thumbSize
            let thumb = NSRect(x: card.minX + 8, y: card.minY + 8, width: size.width, height: size.height)
            state.doc.background.nsColor.setFill()
            thumb.fill()
            if let img = thumbnail(for: panel), let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.translateBy(x: thumb.minX, y: thumb.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height))
                ctx.restoreGState()
            }
            Theme.line.setStroke()
            NSBezierPath(rect: thumb.insetBy(dx: 0.5, dy: 0.5)).stroke()

            let seconds = Double(panel.length) / fps
            Theme.label("\(i + 1)", at: NSPoint(x: thumb.minX, y: thumb.maxY + 5), color: Theme.text, size: 12, bold: true)
            let timing = String(format: "%d fr  /  %.1f s", panel.length, seconds)
            Theme.label(timing, at: NSPoint(x: thumb.minX + 26, y: thumb.maxY + 6), color: Theme.dim, size: 10)
            // Caption, wrapped to two lines.
            let noteRect = NSRect(x: thumb.minX, y: thumb.maxY + 24, width: size.width, height: 28)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: panel.note.isEmpty ? Theme.dim : Theme.text
            ]
            let shown = panel.note.isEmpty ? "No caption" : panel.note
            (shown as NSString).draw(with: noteRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        Theme.bar(in: NSRect(x: 0, y: 0, width: bounds.width, height: topBar), flipped: true)
        Theme.line.setFill()
        NSRect(x: 0, y: bounds.height - bottomBar, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        window?.makeFirstResponder(nil)
        guard p.y > topBar, p.y < bounds.height - bottomBar else { return }
        let panels = state.boardPanels
        for (i, panel) in panels.enumerated() where cardRect(i).contains(p) {
            state.stop()
            if let li = state.boardLayer { state.selectLayer(li) }
            if state.frame == panel.start { state.changed() } else { state.goto(panel.start) }
            if e.clickCount == 2 { window?.makeFirstResponder(captionField) }
            return
        }
    }

    override func scrollWheel(with e: NSEvent) {
        let count = state.boardPanels.count
        let rows = CGFloat((count + columns - 1) / columns)
        let contentH = rows * (cardH + 8) + 12
        let visible = bounds.height - topBar - bottomBar
        scrollY = max(0, min(max(0, contentH - visible), scrollY - e.scrollingDeltaY))
        needsDisplay = true
    }
}

/// Writes the board as a printable sheet: six panels to a landscape page, each with its
/// number, timing and caption.
enum BoardSheet {
    static func writePDF(state: AppState, to url: URL) -> Bool {
        let panels = state.boardPanels
        guard !panels.isEmpty else { return false }
        var page = CGRect(x: 0, y: 0, width: 792, height: 612)
        guard let pdf = CGContext(url as CFURL, mediaBox: &page, nil) else { return false }
        let doc = state.doc
        let fps = Double(max(1, doc.fps))
        let margin: CGFloat = 36
        let gap: CGFloat = 18
        let perRow = 3
        let perPage = 6
        let cellW = (page.width - margin * 2 - gap * CGFloat(perRow - 1)) / CGFloat(perRow)
        let thumbH = min(150, cellW * doc.height / max(1, doc.width))
        let cellH: CGFloat = 250
        let title = state.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let ink = NSColor(white: 0.1, alpha: 1)
        let soft = NSColor(white: 0.4, alpha: 1)

        var index = 0
        var pageNumber = 1
        while index < panels.count {
            pdf.beginPDFPage(nil)
            let g = NSGraphicsContext(cgContext: pdf, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g

            let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: ink]
            ("\(title) - storyboard" as NSString).draw(at: NSPoint(x: margin, y: page.height - margin - 6), withAttributes: heading)
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: soft]
            ("Page \(pageNumber)" as NSString).draw(at: NSPoint(x: page.width - margin - 40, y: page.height - margin - 2), withAttributes: small)

            var slot = 0
            while slot < perPage && index < panels.count {
                let panel = panels[index]
                let col = CGFloat(slot % perRow)
                let rowIndex = CGFloat(slot / perRow)
                let x = margin + col * (cellW + gap)
                let top = page.height - margin - 34 - rowIndex * cellH
                let thumb = CGRect(x: x, y: top - thumbH, width: cellW, height: thumbH)
                pdf.setFillColor(doc.background.cgColor)
                pdf.fill(thumb)
                let scale = min(3.0, max(0.2, 2 * cellW / max(1, doc.width)))
                if let img = Renderer.image(doc: doc, frame: panel.start, scale: scale) {
                    pdf.draw(img, in: thumb)
                }
                pdf.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
                pdf.setLineWidth(1)
                pdf.stroke(thumb)

                let number: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: ink]
                ("\(index + 1)" as NSString).draw(at: NSPoint(x: x, y: thumb.minY - 16), withAttributes: number)
                let seconds = Double(panel.length) / fps
                let timing = String(format: "%d frames  /  %.1f s", panel.length, seconds)
                (timing as NSString).draw(at: NSPoint(x: x + 24, y: thumb.minY - 15), withAttributes: small)
                let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ink]
                let noteRect = NSRect(x: x, y: thumb.minY - 20 - 58, width: cellW, height: 58)
                (panel.note as NSString).draw(with: noteRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: body)

                slot += 1
                index += 1
            }
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
            pageNumber += 1
        }
        pdf.closePDF()
        return true
    }
}
#endif
