import AppKit

/// Small pictures of each animation's first frame, kept in the app's own support folder
/// so the Home screen can show them without opening every file.
enum Thumbnails {
    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("SwiftCel/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stable file name for a document path.
    private static func name(for path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        return String(hash, radix: 16) + ".png"
    }

    static func url(for path: String) -> URL? {
        return folder?.appendingPathComponent(name(for: path))
    }

    static func save(doc: Doc, for path: String) {
        guard let target = url(for: path) else { return }
        let scale = min(1, 400 / max(1, doc.width))
        guard let img = Renderer.image(doc: doc, frame: 0, scale: scale),
              let data = Renderer.pngData(img) else { return }
        try? data.write(to: target)
    }

    static func load(for path: String) -> NSImage? {
        guard let source = url(for: path), FileManager.default.fileExists(atPath: source.path) else { return nil }
        return NSImage(contentsOf: source)
    }
}

/// The Home screen: a card for starting a new animation, then one for every animation
/// SwiftCel knows about, newest first.
final class HomeView: NSView {
    var onNew: (() -> Void)?
    var onOpen: ((String) -> Void)?
    var onOpenOther: (() -> Void)?
    var onChange: (() -> Void)?

    private var paths: [String] = []
    private var pictures: [String: NSImage] = [:]
    private var scrollY: CGFloat = 0
    private var actions: [Action] = []
    private let topBar: CGFloat = 54
    private let cardW: CGFloat = 212
    private let cardH: CGFloat = 196

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 580))
        let a = Action { [weak self] in
            self?.onOpenOther?()
        }
        actions.append(a)
        let other = NSButton(title: "Open Other…", target: a, action: #selector(Action.fire))
        other.bezelStyle = .rounded
        other.frame = NSRect(x: bounds.width - 136, y: 13, width: 122, height: 28)
        other.autoresizingMask = [.minXMargin]
        addSubview(other)
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    /// Re-reads the list of animations and their pictures.
    func reload() {
        paths = Prefs.recentFiles
        pictures.removeAll()
        for p in paths {
            if let img = Thumbnails.load(for: p) {
                pictures[p] = img
            }
        }
        needsDisplay = true
    }

    private var columns: Int {
        return max(1, Int((bounds.width - 16) / cardW))
    }

    /// Card 0 is "New Animation"; card i + 1 is paths[i].
    private func cardRect(_ i: Int) -> NSRect {
        let col = CGFloat(i % columns)
        let rowIndex = CGFloat(i / columns)
        return NSRect(x: 14 + col * cardW, y: topBar + 12 + rowIndex * cardH - scrollY, width: cardW - 14, height: cardH - 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.panel, Theme.panelDark, in: bounds, flipped: true)
        let grid = NSRect(x: 0, y: topBar, width: bounds.width, height: max(0, bounds.height - topBar))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: grid).addClip()
        for i in 0...paths.count {
            let card = cardRect(i)
            if card.maxY < grid.minY || card.minY > grid.maxY { continue }
            let body = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            Theme.frameEmpty.setFill()
            body.fill()
            Theme.line.setStroke()
            body.lineWidth = 1
            body.stroke()
            let picture = NSRect(x: card.minX + 10, y: card.minY + 10, width: card.width - 20, height: 120)

            if i == 0 {
                // New Animation
                Theme.gradient(Theme.pressedBottom, Theme.pressedTop, in: picture, flipped: true)
                let plus = NSBezierPath()
                plus.move(to: NSPoint(x: picture.midX - 18, y: picture.midY))
                plus.line(to: NSPoint(x: picture.midX + 18, y: picture.midY))
                plus.move(to: NSPoint(x: picture.midX, y: picture.midY - 18))
                plus.line(to: NSPoint(x: picture.midX, y: picture.midY + 18))
                plus.lineWidth = 5
                plus.lineCapStyle = .round
                Theme.accentInk.setStroke()
                plus.stroke()
                Theme.label("New Animation", at: NSPoint(x: picture.minX, y: picture.maxY + 10), color: Theme.text, size: 13, bold: true)
                Theme.label("Choose a size and frame rate", at: NSPoint(x: picture.minX, y: picture.maxY + 29), color: Theme.dim, size: 10)
                continue
            }

            let path = paths[i - 1]
            let url = URL(fileURLWithPath: path)
            NSColor.white.setFill()
            picture.fill()
            if let img = pictures[path], img.size.width > 0, img.size.height > 0 {
                // Fit the whole first frame inside the picture area.
                let k = min(picture.width / img.size.width, picture.height / img.size.height)
                let w = img.size.width * k
                let h = img.size.height * k
                let target = NSRect(x: picture.midX - w / 2, y: picture.midY - h / 2, width: w, height: h)
                Theme.pasteboard.setFill()
                picture.fill()
                img.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                Theme.row.setFill()
                picture.fill()
                Theme.label("No preview yet", at: NSPoint(x: picture.minX + 8, y: picture.midY - 7), color: Theme.dim, size: 10)
            }
            Theme.line.setStroke()
            NSBezierPath(rect: picture.insetBy(dx: 0.5, dy: 0.5)).stroke()

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: picture.minX, y: picture.maxY, width: picture.width, height: 50)).addClip()
            Theme.label(url.deletingPathExtension().lastPathComponent, at: NSPoint(x: picture.minX, y: picture.maxY + 10),
                        color: Theme.text, size: 13, bold: true)
            Theme.label("in " + url.deletingLastPathComponent().lastPathComponent, at: NSPoint(x: picture.minX, y: picture.maxY + 29),
                        color: Theme.dim, size: 10)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()

        Theme.bar(in: NSRect(x: 0, y: 0, width: bounds.width, height: topBar), flipped: true)
        Theme.label("Your animations", at: NSPoint(x: 18, y: 16), color: Theme.text, size: 18, bold: true)
    }

    private func card(at p: NSPoint) -> Int? {
        guard p.y > topBar else { return nil }
        for i in 0...paths.count where cardRect(i).contains(p) {
            return i
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        guard let i = card(at: convert(e.locationInWindow, from: nil)) else { return }
        if i == 0 {
            onNew?()
        } else {
            onOpen?(paths[i - 1])
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let i = card(at: convert(e.locationInWindow, from: nil)), i > 0 else { return }
        let path = paths[i - 1]
        let popup = NSMenu()
        func add(_ title: String, _ fn: @escaping () -> Void) {
            let a = Action(fn)
            let it = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
            it.target = a
            it.representedObject = a
            popup.addItem(it)
        }
        add("Open") { [weak self] in self?.onOpen?(path) }
        add("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        popup.addItem(NSMenuItem.separator())
        add("Remove from Home") { [weak self] in
            Prefs.forgetRecent(path)
            self?.reload()
            self?.onChange?()
        }
        NSMenu.popUpContextMenu(popup, with: e, for: self)
    }

    override func scrollWheel(with e: NSEvent) {
        let rows = CGFloat((paths.count + 1 + columns - 1) / columns)
        let contentH = rows * cardH + 24
        let visible = bounds.height - topBar
        scrollY = max(0, min(max(0, contentH - visible), scrollY - e.scrollingDeltaY))
        needsDisplay = true
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsDisplay = true
    }
}
