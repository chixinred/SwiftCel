#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// App-wide preferences, remembered between launches.
enum Prefs {
    private static let store = UserDefaults.standard

    /// How large the main window's interface is drawn: 1 is normal, 2 is double size.
    static var uiScale: CGFloat {
        get {
            let v = store.double(forKey: "prefs.uiScale")
            return v >= 1 && v <= 2 ? CGFloat(v) : 1
        }
        set { store.set(Double(max(1, min(2, newValue))), forKey: "prefs.uiScale") }
    }

    /// Width of one frame in the timeline, before the interface size is applied.
    static var frameWidth: CGFloat {
        get {
            let v = store.double(forKey: "prefs.frameWidth")
            return v >= 8 && v <= 28 ? CGFloat(v) : 11
        }
        set { store.set(Double(max(8, min(28, newValue))), forKey: "prefs.frameWidth") }
    }

    static var showSplash: Bool {
        get { return store.object(forKey: "prefs.showSplash") == nil ? true : store.bool(forKey: "prefs.showSplash") }
        set { store.set(newValue, forKey: "prefs.showSplash") }
    }

    static var showHome: Bool {
        get { return store.object(forKey: "prefs.showHome") == nil ? true : store.bool(forKey: "prefs.showHome") }
        set { store.set(newValue, forKey: "prefs.showHome") }
    }

    /// Paths of recently opened or saved animations, newest first.
    static var recentFiles: [String] {
        get { return store.stringArray(forKey: "prefs.recentFiles") ?? [] }
        set { store.set(newValue, forKey: "prefs.recentFiles") }
    }

    static func noteRecent(_ url: URL) {
        var list = recentFiles.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        recentFiles = Array(list.prefix(60))
    }

    static func forgetRecent(_ path: String) {
        recentFiles = recentFiles.filter { $0 != path }
    }
}

#if os(macOS)
/// The Settings window's contents.
final class PrefsView: NSView {
    var onChange: (() -> Void)?
    private var actions: [Action] = []
    private let sizeLabel = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider(value: 100, minValue: 100, maxValue: 200, target: nil, action: nil)
    private let frameLabel = NSTextField(labelWithString: "")
    private let frameSlider = NSSlider(value: 11, minValue: 8, maxValue: 28, target: nil, action: nil)
    private let splashBox = NSButton(checkboxWithTitle: "Show the splash screen when SwiftCel starts", target: nil, action: nil)
    private let homeBox = NSButton(checkboxWithTitle: "Show Home when SwiftCel starts", target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 296))
        let heading = NSTextField(labelWithString: "Seeing and clicking")
        heading.font = NSFont.boldSystemFont(ofSize: 13)
        heading.frame = NSRect(x: 18, y: 16, width: 360, height: 18)
        addSubview(heading)

        sizeLabel.frame = NSRect(x: 18, y: 46, width: 360, height: 18)
        sizeSlider.frame = NSRect(x: 18, y: 66, width: 364, height: 24)
        sizeSlider.numberOfTickMarks = 5
        sizeSlider.allowsTickMarkValuesOnly = true
        let sizeNote = note("Makes everything in the main window larger: tools, panels, timeline and text.", y: 92)

        frameLabel.frame = NSRect(x: 18, y: 124, width: 360, height: 18)
        frameSlider.frame = NSRect(x: 18, y: 144, width: 364, height: 20)
        let frameNote = note("Wider frames are easier to click and drag in the timeline.", y: 166)

        splashBox.frame = NSRect(x: 16, y: 196, width: 368, height: 20)

        let reset = NSButton(title: "Reset to Defaults", target: nil, action: nil)
        reset.bezelStyle = .rounded
        homeBox.frame = NSRect(x: 16, y: 222, width: 368, height: 20)
        reset.frame = NSRect(x: 12, y: 256, width: 150, height: 28)

        for v in [sizeLabel, sizeSlider, sizeNote, frameLabel, frameSlider, frameNote, splashBox, homeBox, reset] as [NSView] {
            addSubview(v)
        }
        wire(sizeSlider) { [weak self] in
            guard let self = self else { return }
            Prefs.uiScale = CGFloat(self.sizeSlider.doubleValue / 100)
            self.changed()
        }
        wire(frameSlider) { [weak self] in
            guard let self = self else { return }
            Prefs.frameWidth = CGFloat(self.frameSlider.doubleValue.rounded())
            self.changed()
        }
        wire(splashBox) { [weak self] in
            guard let self = self else { return }
            Prefs.showSplash = self.splashBox.state == .on
            self.changed()
        }
        wire(homeBox) { [weak self] in
            guard let self = self else { return }
            Prefs.showHome = self.homeBox.state == .on
            self.changed()
        }
        wire(reset) { [weak self] in
            Prefs.uiScale = 1
            Prefs.frameWidth = 11
            Prefs.showSplash = true
            Prefs.showHome = true
            self?.changed()
        }
        sync()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    private func note(_ text: String, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = NSColor.secondaryLabelColor
        l.frame = NSRect(x: 18, y: y, width: 366, height: 16)
        return l
    }

    private func wire(_ control: NSControl, _ fn: @escaping () -> Void) {
        let a = Action(fn)
        actions.append(a)
        control.target = a
        control.action = #selector(Action.fire)
    }

    private func changed() {
        sync()
        onChange?()
    }

    func sync() {
        let percent = Int((Prefs.uiScale * 100).rounded())
        sizeSlider.doubleValue = Double(percent)
        sizeLabel.stringValue = "Interface size: \(percent)%"
        frameSlider.doubleValue = Double(Prefs.frameWidth)
        frameLabel.stringValue = "Timeline frame width: \(Int(Prefs.frameWidth))"
        splashBox.state = Prefs.showSplash ? .on : .off
        homeBox.state = Prefs.showHome ? .on : .off
    }
}

/// The form used for New and for Document Settings: stage size, frame rate and background.
final class DocumentSetupView: NSView {
    private let presets: [(title: String, width: Int, height: Int)] = [
        ("Custom", 0, 0),
        ("Classic  550 × 400", 550, 400),
        ("HD  1280 × 720", 1280, 720),
        ("Full HD  1920 × 1080", 1920, 1080),
        ("4:3  1440 × 1080", 1440, 1080),
        ("Square  1080 × 1080", 1080, 1080),
        ("Vertical  1080 × 1920", 1080, 1920)
    ]
    private let popup = NSPopUpButton(frame: NSRect(x: 110, y: 116, width: 200, height: 26), pullsDown: false)
    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private let fpsField = NSTextField(string: "")
    private let well = NSColorWell(frame: NSRect(x: 110, y: 8, width: 56, height: 26))
    private var actions: [Action] = []

    init(doc: Doc) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
        func label(_ s: String, y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.frame = NSRect(x: 0, y: y, width: 100, height: 18)
            addSubview(l)
        }
        label("Preset", y: 120)
        label("Stage size", y: 84)
        label("Frame rate", y: 48)
        label("Background", y: 12)

        for p in presets { popup.addItem(withTitle: p.title) }
        addSubview(popup)
        widthField.frame = NSRect(x: 110, y: 80, width: 64, height: 24)
        heightField.frame = NSRect(x: 196, y: 80, width: 64, height: 24)
        fpsField.frame = NSRect(x: 110, y: 44, width: 64, height: 24)
        let times = NSTextField(labelWithString: "×")
        times.frame = NSRect(x: 179, y: 84, width: 14, height: 18)
        let unit = NSTextField(labelWithString: "pixels")
        unit.frame = NSRect(x: 266, y: 84, width: 50, height: 18)
        let perSecond = NSTextField(labelWithString: "frames per second")
        perSecond.frame = NSRect(x: 180, y: 48, width: 140, height: 18)
        for v in [widthField, heightField, fpsField, times, unit, perSecond, well] as [NSView] {
            addSubview(v)
        }

        widthField.stringValue = "\(Int(doc.width))"
        heightField.stringValue = "\(Int(doc.height))"
        fpsField.stringValue = "\(doc.fps)"
        well.color = doc.background.nsColor
        let match = presets.firstIndex { $0.width == Int(doc.width) && $0.height == Int(doc.height) } ?? 0
        popup.selectItem(at: match)

        let a = Action { [weak self] in
            guard let self = self else { return }
            let i = self.popup.indexOfSelectedItem
            guard self.presets.indices.contains(i), self.presets[i].width > 0 else { return }
            self.widthField.stringValue = "\(self.presets[i].width)"
            self.heightField.stringValue = "\(self.presets[i].height)"
        }
        actions.append(a)
        popup.target = a
        popup.action = #selector(Action.fire)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// What was entered, or nil if a number is missing or out of range.
    var result: (width: Int, height: Int, fps: Int, background: RGBA)? {
        let w = Int(widthField.intValue)
        let h = Int(heightField.intValue)
        let f = Int(fpsField.intValue)
        guard w >= 16, w <= 8192, h >= 16, h <= 8192, f >= 1, f <= 60 else { return nil }
        var bg = RGBA(well.color)
        bg.a = 1
        return (w, h, f, bg)
    }
}
#endif
