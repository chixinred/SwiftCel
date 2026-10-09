import AppKit

/// The splash art with the credits stamped on the plate under the sign. Shown briefly at
/// launch and again from About SwiftCel.
///
/// The picture is Splash.png and the wording is Credits.txt, both next to build.command;
/// edit either and rebuild. In Credits.txt each line is one line on the plate, the first
/// line is the bold one, and {version} is replaced with the app's version.
final class SplashView: NSView {
    /// Size of the artwork in pixels.
    static let artSize = NSSize(width: 917, height: 705)
    /// Where the credits start, measured down from the top of the artwork (just under the sign).
    private let textTop: CGFloat = 533

    var onDismiss: (() -> Void)?
    var hint = "Click anywhere to begin"
    private let image: NSImage?
    private var lines: [String] = []

    init(scale: CGFloat) {
        if let url = Bundle.main.url(forResource: "Splash", withExtension: "png") {
            image = NSImage(contentsOf: url)
        } else {
            image = nil
        }
        super.init(frame: NSRect(x: 0, y: 0, width: (SplashView.artSize.width * scale).rounded(),
                                 height: (SplashView.artSize.height * scale).rounded()))
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        var text = "Version {version}\nFrame-by-frame animation for Mac and iPad"
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "txt"),
           let saved = try? String(contentsOf: url, encoding: .utf8) {
            text = saved
        }
        lines = text.replacingOccurrences(of: "{version}", with: version)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    /// Draws a centred line that looks pressed into the metal: a light edge just below dark text.
    private func stamp(_ s: String, centreY: CGFloat, size: CGFloat, bold: Bool, ink: NSColor) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let dark: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let light: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.55)]
        let text = s as NSString
        let extent = text.size(withAttributes: dark)
        let origin = NSPoint(x: (bounds.width - extent.width) / 2, y: centreY - extent.height / 2)
        text.draw(at: NSPoint(x: origin.x, y: origin.y + 1), withAttributes: light)
        text.draw(at: origin, withAttributes: dark)
    }

    override func draw(_ dirtyRect: NSRect) {
        let k = bounds.width / SplashView.artSize.width
        if let img = image {
            NSGraphicsContext.current?.imageInterpolation = .high
            img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            // The picture is missing from the app; fall back to a plain plate.
            NSColor(srgbRed: 0.70, green: 0.74, blue: 0.68, alpha: 1).setFill()
            bounds.fill()
            stamp("SwiftCel", centreY: bounds.height * 0.42, size: 54 * k, bold: true, ink: NSColor(white: 0.12, alpha: 1))
        }
        let ink = NSColor(srgbRed: 0.15, green: 0.18, blue: 0.16, alpha: 1)
        let soft = NSColor(srgbRed: 0.24, green: 0.28, blue: 0.25, alpha: 1)
        var y = textTop * k
        for (i, line) in lines.enumerated() {
            let last = i == lines.count - 1 && lines.count > 2
            let size: CGFloat = i == 0 ? 19 : (last ? 12.5 : 15)
            let step: CGFloat = i == 0 ? 31 : 25
            stamp(line, centreY: y + step * k / 2, size: size * k, bold: i == 0, ink: i == 0 ? ink : soft)
            y += step * k
        }
        stamp(hint, centreY: 684 * k, size: 12 * k, bold: false, ink: soft.withAlphaComponent(0.75))
    }

    override func mouseDown(with e: NSEvent) {
        onDismiss?()
    }
}
