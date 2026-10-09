#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How onion skinning shows the neighbouring frames. The range (`before`, `after`) is
/// set by dragging the two markers on the timeline ruler; the rest is in the settings window.
struct OnionSettings: Codable {
    static let maxRange = 20

    /// How many earlier and later frames to show.
    var before: Int = 2
    var after: Int = 2
    /// Opacity of the nearest earlier and later ghost; further ones fade from there.
    var opacityBefore: CGFloat = 0.30
    var opacityAfter: CGFloat = 0.30
    /// Recolour the ghosts with the two tint colours.
    var tint: Bool = true
    var tintBefore: RGBA = RGBA(r: 0.90, g: 0.20, b: 0.18, a: 1)
    var tintAfter: RGBA = RGBA(r: 0.10, g: 0.62, b: 0.30, a: 1)

    private static let key = "onion.settings.v2"

    static func load() -> OnionSettings {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(OnionSettings.self, from: data) {
            return saved
        }
        return OnionSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: OnionSettings.key)
        }
    }
}

#if os(macOS)
/// The floating window with the onion skin's tint and opacity controls.
final class OnionEditor: NSObject {
    private let state: AppState
    private let panel: NSPanel
    private var actions: [Action] = []
    private let beforeLabel = NSTextField(labelWithString: "")
    private let afterLabel = NSTextField(labelWithString: "")
    private let beforeSlider = NSSlider(value: 30, minValue: 5, maxValue: 100, target: nil, action: nil)
    private let afterSlider = NSSlider(value: 30, minValue: 5, maxValue: 100, target: nil, action: nil)
    private let tintBox = NSButton(checkboxWithTitle: "Tint the ghosts", target: nil, action: nil)
    private let beforeWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 56, height: 26))
    private let afterWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 56, height: 26))

    init(state: AppState) {
        self.state = state
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 268),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Onion Skin Settings"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        guard let content = panel.contentView else { return }

        beforeLabel.frame = NSRect(x: 16, y: 232, width: 288, height: 18)
        beforeSlider.frame = NSRect(x: 16, y: 208, width: 288, height: 20)
        afterLabel.frame = NSRect(x: 16, y: 178, width: 288, height: 18)
        afterSlider.frame = NSRect(x: 16, y: 154, width: 288, height: 20)
        tintBox.frame = NSRect(x: 14, y: 118, width: 292, height: 20)
        let earlier = NSTextField(labelWithString: "Earlier frames")
        earlier.frame = NSRect(x: 34, y: 88, width: 180, height: 18)
        beforeWell.frame = NSRect(x: 248, y: 84, width: 56, height: 26)
        let later = NSTextField(labelWithString: "Later frames")
        later.frame = NSRect(x: 34, y: 54, width: 180, height: 18)
        afterWell.frame = NSRect(x: 248, y: 50, width: 56, height: 26)
        let note = NSTextField(labelWithString: "To choose how many frames show, drag the two markers")
        note.frame = NSRect(x: 16, y: 22, width: 292, height: 14)
        let note2 = NSTextField(labelWithString: "either side of the playhead on the timeline ruler.")
        note2.frame = NSRect(x: 16, y: 8, width: 292, height: 14)
        for n in [note, note2] {
            n.font = NSFont.systemFont(ofSize: 10)
            n.textColor = NSColor.secondaryLabelColor
        }
        let views: [NSView] = [beforeLabel, beforeSlider, afterLabel, afterSlider, tintBox, earlier, beforeWell,
                               later, afterWell, note, note2]
        for v in views {
            content.addSubview(v)
        }
        let controls: [NSControl] = [beforeSlider, afterSlider, tintBox, beforeWell, afterWell]
        for c in controls {
            let a = Action { [weak self] in
                self?.changed()
            }
            actions.append(a)
            c.target = a
            c.action = #selector(Action.fire)
        }
        sync()
    }

    func show() {
        sync()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func sync() {
        let o = state.onion
        beforeSlider.doubleValue = Double(o.opacityBefore * 100)
        afterSlider.doubleValue = Double(o.opacityAfter * 100)
        tintBox.state = o.tint ? .on : .off
        beforeWell.color = o.tintBefore.nsColor
        afterWell.color = o.tintAfter.nsColor
        updateLabels()
    }

    private func updateLabels() {
        let o = state.onion
        beforeLabel.stringValue = "Earlier frames opacity: \(Int((o.opacityBefore * 100).rounded()))%"
        afterLabel.stringValue = "Later frames opacity: \(Int((o.opacityAfter * 100).rounded()))%"
        beforeWell.isEnabled = o.tint
        afterWell.isEnabled = o.tint
    }

    private func opaque(_ well: NSColorWell) -> RGBA {
        var c = RGBA(well.color)
        c.a = 1
        return c
    }

    private func changed() {
        var o = state.onion
        o.opacityBefore = CGFloat(beforeSlider.doubleValue.rounded()) / 100
        o.opacityAfter = CGFloat(afterSlider.doubleValue.rounded()) / 100
        o.tint = tintBox.state == .on
        o.tintBefore = opaque(beforeWell)
        o.tintAfter = opaque(afterWell)
        state.onion = o
        // Changing a setting is a request to see it, so make sure onion skin is on.
        state.onionSkin = true
        updateLabels()
        state.changed()
    }
}
#endif
