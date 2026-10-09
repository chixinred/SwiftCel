#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

extension RGBA {
    /// The colour as the platform's own colour type.
    var platformColor: PlatformColor {
        #if os(macOS)
        return nsColor
        #else
        return uiColor
        #endif
    }
}

/// A theme is four colours you choose; every other shade in the interface is worked
/// out from them, so any combination stays consistent.
struct Palette: Codable, Equatable {
    var name: String
    /// The surface of the panels.
    var panel: RGBA
    /// Selection, the playhead, pressed tools.
    var accent: RGBA
    /// Labels and icons.
    var text: RGBA
    /// The area around the stage.
    var pasteboard: RGBA

    static func gray(_ v: CGFloat) -> RGBA {
        return RGBA(r: v, g: v, b: v, a: 1)
    }

    static let porcelain = Palette(name: "Porcelain",
                                   panel: RGBA(r: 0.930, g: 0.935, b: 0.945, a: 1),
                                   accent: RGBA(r: 0.26, g: 0.53, b: 0.93, a: 1),
                                   text: gray(0.13), pasteboard: gray(0.72))
    static let graphite = Palette(name: "Graphite",
                                  panel: RGBA(r: 0.205, g: 0.215, b: 0.235, a: 1),
                                  accent: RGBA(r: 1.00, g: 0.64, b: 0.20, a: 1),
                                  text: gray(0.90), pasteboard: gray(0.27))
    static let midnight = Palette(name: "Midnight",
                                  panel: RGBA(r: 0.115, g: 0.150, b: 0.230, a: 1),
                                  accent: RGBA(r: 0.30, g: 0.80, b: 0.95, a: 1),
                                  text: RGBA(r: 0.86, g: 0.91, b: 0.98, a: 1),
                                  pasteboard: RGBA(r: 0.07, g: 0.09, b: 0.14, a: 1))
    static let paper = Palette(name: "Paper",
                               panel: RGBA(r: 0.945, g: 0.915, b: 0.855, a: 1),
                               accent: RGBA(r: 0.80, g: 0.33, b: 0.20, a: 1),
                               text: RGBA(r: 0.22, g: 0.17, b: 0.12, a: 1),
                               pasteboard: RGBA(r: 0.74, g: 0.70, b: 0.63, a: 1))
    static let bolt = Palette(name: "Bolt",
                              panel: RGBA(r: 0.17, g: 0.16, b: 0.15, a: 1),
                              accent: RGBA(r: 1.00, g: 0.80, b: 0.12, a: 1),
                              text: RGBA(r: 0.96, g: 0.93, b: 0.84, a: 1),
                              pasteboard: RGBA(r: 0.10, g: 0.095, b: 0.09, a: 1))

    static let builtIn: [Palette] = [porcelain, graphite, midnight, paper, bolt]
}

private func mix(_ a: RGBA, _ b: RGBA, _ t: CGFloat) -> RGBA {
    return RGBA(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: 1)
}

/// Scales a colour's saturation, keeping its brightness and hue.
private func saturated(_ c: RGBA, by factor: CGFloat) -> RGBA {
    let hi = max(c.r, c.g, c.b)
    let lo = min(c.r, c.g, c.b)
    if hi - lo < 0.0001 { return c }
    // Each channel's distance below the brightest one grows by k; k is capped so that
    // the darkest channel stops at zero.
    let k = min(factor, hi / (hi - lo))
    return RGBA(r: hi - (hi - c.r) * k, g: hi - (hi - c.g) * k, b: hi - (hi - c.b) * k, a: c.a)
}

private func luminance(_ c: RGBA) -> CGFloat {
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
}

/// Every shade the interface draws with, derived from a palette.
private struct Shades {
    let dark: Bool
    let panel: PlatformColor
    let panelDark: PlatformColor
    let row: PlatformColor
    let line: PlatformColor
    let highlight: PlatformColor
    let grip: PlatformColor
    let text: PlatformColor
    let dim: PlatformColor
    let accent: PlatformColor
    let accentInk: PlatformColor
    let accentText: PlatformColor
    let barTop: PlatformColor
    let barBottom: PlatformColor
    let keyTop: PlatformColor
    let keyBottom: PlatformColor
    let pressedTop: PlatformColor
    let pressedBottom: PlatformColor
    let frameEmpty: PlatformColor
    let frameFilled: PlatformColor
    let beyondA: PlatformColor
    let beyondB: PlatformColor
    let frameLine: PlatformColor
    let pasteboard: PlatformColor

    init(_ p: Palette) {
        let white = Palette.gray(1)
        let black = Palette.gray(0)
        let isDark = luminance(p.panel) < 0.5
        // Shading tones lean toward the accent and are pushed more saturated, so gradients
        // and bevels read as colour rather than plain grey.
        func shade(_ c: RGBA, _ lean: CGFloat) -> PlatformColor {
            return saturated(mix(c, p.accent, lean), by: 1.6).platformColor
        }
        dark = isDark
        panel = p.panel.platformColor
        text = p.text.platformColor
        accent = p.accent.platformColor
        pasteboard = p.pasteboard.platformColor
        dim = mix(p.text, p.panel, 0.22).platformColor
        grip = p.text.platformColor.withAlphaComponent(0.50)
        accentInk = luminance(p.accent) > 0.62 ? Palette.gray(0.10).platformColor : PlatformColor.white
        pressedTop = shade(mix(p.accent, black, 0.15), 0)
        pressedBottom = shade(mix(p.accent, white, 0.22), 0)
        frameFilled = shade(mix(p.panel, p.text, 0.38), 0.16)
        if isDark {
            panelDark = shade(mix(p.panel, black, 0.25), 0.11)
            row = shade(mix(p.panel, white, 0.05), 0.11)
            line = shade(mix(p.panel, black, 0.85), 0.11)
            highlight = PlatformColor(white: 1, alpha: 0.16)
            accentText = mix(p.accent, white, 0.42).platformColor
            barTop = shade(mix(p.panel, white, 0.14), 0.11)
            barBottom = shade(mix(p.panel, white, 0.02), 0.11)
            keyTop = shade(mix(p.panel, white, 0.17), 0.04)
            keyBottom = shade(mix(p.panel, white, 0.04), 0.11)
            frameEmpty = shade(mix(p.panel, white, 0.18), 0.04)
            beyondA = shade(mix(p.panel, black, 0.18), 0.11)
            beyondB = shade(mix(p.panel, black, 0.34), 0.11)
            frameLine = shade(mix(p.panel, black, 0.62), 0.11)
        } else {
            panelDark = shade(mix(p.panel, black, 0.07), 0.11)
            row = shade(mix(p.panel, black, 0.025), 0.11)
            line = shade(mix(p.panel, p.text, 0.58), 0.11)
            highlight = PlatformColor(white: 1, alpha: 0.75)
            accentText = mix(p.accent, p.text, 0.62).platformColor
            barTop = shade(mix(p.panel, white, 0.50), 0.11)
            barBottom = shade(mix(p.panel, black, 0.11), 0.11)
            keyTop = shade(mix(p.panel, white, 1.0), 0.04)
            keyBottom = shade(mix(p.panel, black, 0.08), 0.11)
            frameEmpty = shade(mix(p.panel, white, 0.85), 0.04)
            beyondA = shade(mix(p.panel, black, 0.18), 0.11)
            beyondB = shade(mix(p.panel, black, 0.10), 0.11)
            frameLine = shade(mix(p.panel, black, 0.28), 0.11)
        }
    }
}

enum Theme {
    private static var shades = Shades(Palette.porcelain)

    /// The palette in use. Setting it re-derives every shade; the app then redraws.
    static var palette = Palette.porcelain {
        didSet {
            shades = Shades(palette)
        }
    }

    static var isDark: Bool { return shades.dark }
    static var panel: PlatformColor { return shades.panel }
    /// The slightly deeper tone at the foot of a panel and behind the dividers.
    static var panelDark: PlatformColor { return shades.panelDark }
    static var row: PlatformColor { return shades.row }
    static var line: PlatformColor { return shades.line }
    static var highlight: PlatformColor { return shades.highlight }
    static var grip: PlatformColor { return shades.grip }
    static var text: PlatformColor { return shades.text }
    static var dim: PlatformColor { return shades.dim }
    static var accent: PlatformColor { return shades.accent }
    /// Text drawn on top of the accent colour.
    static var accentInk: PlatformColor { return shades.accentInk }
    static var accentText: PlatformColor { return shades.accentText }
    static var barTop: PlatformColor { return shades.barTop }
    static var barBottom: PlatformColor { return shades.barBottom }
    static var keyTop: PlatformColor { return shades.keyTop }
    static var keyBottom: PlatformColor { return shades.keyBottom }
    static var pressedTop: PlatformColor { return shades.pressedTop }
    static var pressedBottom: PlatformColor { return shades.pressedBottom }
    /// Timeline cells: an empty frame, a frame with art, and the two stripes past the end.
    static var frameEmpty: PlatformColor { return shades.frameEmpty }
    static var frameFilled: PlatformColor { return shades.frameFilled }
    static var beyondA: PlatformColor { return shades.beyondA }
    static var beyondB: PlatformColor { return shades.beyondB }
    static var frameLine: PlatformColor { return shades.frameLine }
    static var pasteboard: PlatformColor { return shades.pasteboard }

    // MARK: Saved themes

    private static let currentKey = "theme.current"
    private static let customKey = "theme.custom"

    /// Themes the user has saved, in the order they were made.
    static var custom: [Palette] = []

    static var all: [Palette] {
        return Palette.builtIn + custom
    }

    static func isBuiltIn(_ name: String) -> Bool {
        return Palette.builtIn.contains { $0.name == name }
    }

    static func load() {
        let store = UserDefaults.standard
        if let data = store.data(forKey: customKey),
           let saved = try? JSONDecoder().decode([Palette].self, from: data) {
            custom = saved
        }
        if let data = store.data(forKey: currentKey),
           let saved = try? JSONDecoder().decode(Palette.self, from: data) {
            palette = saved
        }
    }

    static func persist() {
        let store = UserDefaults.standard
        if let data = try? JSONEncoder().encode(custom) {
            store.set(data, forKey: customKey)
        }
        if let data = try? JSONEncoder().encode(palette) {
            store.set(data, forKey: currentKey)
        }
    }

    /// Saves the current palette under `name`, replacing a saved theme of the same name.
    /// Built-in names can't be overwritten, so those get " 2" added.
    static func saveCurrent(as rawName: String) {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "My Theme" }
        if isBuiltIn(name) { name += " 2" }
        palette.name = name
        if let index = custom.firstIndex(where: { $0.name == name }) {
            custom[index] = palette
        } else {
            custom.append(palette)
        }
        persist()
    }

    static func deleteCustom(named name: String) {
        custom.removeAll { $0.name == name }
        if palette.name == name {
            palette = Palette.porcelain
        }
        persist()
    }

    #if os(macOS)
    // MARK: Drawing helpers

    /// Vertical gradient with `top` at the top edge of `rect`, whichever way the view is flipped.
    static func gradient(_ top: NSColor, _ bottom: NSColor, in rect: NSRect, flipped: Bool) {
        guard let g = NSGradient(starting: top, ending: bottom) else { return }
        g.draw(in: rect, angle: flipped ? 90 : -90)
    }

    /// A raised strip: gradient, a light line along the top and a dark line along the bottom.
    static func bar(in rect: NSRect, flipped: Bool) {
        gradient(barTop, barBottom, in: rect, flipped: flipped)
        let topEdge = flipped ? rect.minY : rect.maxY - 1
        let bottomEdge = flipped ? rect.maxY - 1 : rect.minY
        highlight.setFill()
        NSRect(x: rect.minX, y: topEdge, width: rect.width, height: 1).fill(using: .sourceOver)
        line.setFill()
        NSRect(x: rect.minX, y: bottomEdge, width: rect.width, height: 1).fill()
    }

    static func label(_ s: String, at p: NSPoint, color: NSColor, size: CGFloat = 11, bold: Bool = false) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
    #else
    // MARK: Drawing helpers

    /// Vertical gradient with `top` at the top edge of `rect`. (`flipped` is only
    /// meaningful on the Mac; iPad views always have their origin at the top.)
    static func gradient(_ top: UIColor, _ bottom: UIColor, in rect: CGRect, flipped: Bool = true) {
        guard let ctx = UIGraphicsGetCurrentContext(), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let g = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    /// Fills with ordinary blending, so see-through colours tint what is beneath them.
    static func fill(_ color: UIColor, _ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    /// A raised strip: gradient, a light line along the top and a dark line along the bottom.
    static func bar(in rect: CGRect, flipped: Bool = true) {
        gradient(barTop, barBottom, in: rect)
        fill(highlight, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
        fill(line, CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
    }

    static func label(_ s: String, at p: CGPoint, color: UIColor, size: CGFloat = 11, bold: Bool = false) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
    #endif
}

#if os(macOS)
/// The titled strip at the top of a panel.
final class PanelHeader: NSView {
    private let title: String
    let headerDrag = HeaderDrag()

    override func mouseDown(with e: NSEvent) {
        headerDrag.down(e)
    }

    override func mouseDragged(with e: NSEvent) {
        headerDrag.dragged(e)
    }

    override func mouseUp(with e: NSEvent) {
        headerDrag.up(e)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor.openHand)
    }

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bar(in: bounds, flipped: true)
        // Grip dots, then the title.
        Theme.grip.setFill()
        for i in 0..<3 {
            NSRect(x: 7 + CGFloat(i) * 4, y: bounds.midY - 3, width: 2, height: 2).fill(using: .sourceOver)
            NSRect(x: 7 + CGFloat(i) * 4, y: bounds.midY + 1, width: 2, height: 2).fill(using: .sourceOver)
        }
        Theme.label(title.uppercased(), at: NSPoint(x: 24, y: 4), color: Theme.text, size: 10, bold: true)
    }
}

/// The floating window for editing a theme's four colours.
final class ThemeEditor: NSObject {
    private let panel: NSPanel
    private let nameField = NSTextField(string: "")
    private var wells: [NSColorWell] = []
    private var actions: [Action] = []
    private let onChange: () -> Void

    /// `onChange` is called whenever the palette or the list of saved themes changes.
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 252),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Customize Theme"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        guard let content = panel.contentView else { return }

        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.frame = NSRect(x: 16, y: 212, width: 90, height: 18)
        content.addSubview(nameLabel)
        nameField.frame = NSRect(x: 110, y: 209, width: 174, height: 22)
        content.addSubview(nameField)

        let titles = ["Panels", "Accent", "Text and icons", "Around the stage"]
        for (i, title) in titles.enumerated() {
            let y = CGFloat(170 - i * 34)
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 16, y: y + 4, width: 150, height: 18)
            content.addSubview(label)
            let well = NSColorWell(frame: NSRect(x: 228, y: y, width: 56, height: 26))
            let a = Action { [weak self] in
                self?.wellChanged()
            }
            actions.append(a)
            well.target = a
            well.action = #selector(Action.fire)
            content.addSubview(well)
            wells.append(well)
        }

        addButton("Save Theme", x: 16, width: 128, to: content) { [weak self] in
            self?.save()
        }
        addButton("Delete Theme", x: 156, width: 128, to: content) { [weak self] in
            self?.delete()
        }
        let note = NSTextField(labelWithString: "Changes show straight away. Save to keep them in the Theme menu.")
        note.frame = NSRect(x: 16, y: 8, width: 268, height: 14)
        note.font = NSFont.systemFont(ofSize: 9)
        note.textColor = NSColor.secondaryLabelColor
        content.addSubview(note)
        sync()
    }

    private func addButton(_ title: String, x: CGFloat, width: CGFloat, to view: NSView, _ fn: @escaping () -> Void) {
        let a = Action(fn)
        actions.append(a)
        let b = NSButton(title: title, target: a, action: #selector(Action.fire))
        b.bezelStyle = .rounded
        b.frame = NSRect(x: x, y: 28, width: width, height: 28)
        view.addSubview(b)
    }

    func show() {
        sync()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Copies the palette in use into the controls.
    func sync() {
        guard wells.count == 4 else { return }
        let p = Theme.palette
        nameField.stringValue = p.name
        wells[0].color = p.panel.nsColor
        wells[1].color = p.accent.nsColor
        wells[2].color = p.text.nsColor
        wells[3].color = p.pasteboard.nsColor
    }

    private func opaque(_ well: NSColorWell) -> RGBA {
        var c = RGBA(well.color)
        c.a = 1
        return c
    }

    private func wellChanged() {
        guard wells.count == 4 else { return }
        var p = Theme.palette
        p.panel = opaque(wells[0])
        p.accent = opaque(wells[1])
        p.text = opaque(wells[2])
        p.pasteboard = opaque(wells[3])
        Theme.palette = p
        Theme.persist()
        onChange()
    }

    private func save() {
        Theme.saveCurrent(as: nameField.stringValue)
        nameField.stringValue = Theme.palette.name
        onChange()
    }

    private func delete() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard Theme.custom.contains(where: { $0.name == name }) else {
            NSSound.beep()   // built-in themes and unsaved names can't be deleted
            return
        }
        Theme.deleteCustom(named: name)
        sync()
        onChange()
    }
}
#endif
