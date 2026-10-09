import UIKit

// The pieces every iPad panel is built from. They draw with the same theme shades as
// the Mac app, so the two look alike and change together when the theme changes.

/// A bevelled key, like the small square buttons in the Mac app's panels.
final class PadKeyButton: UIControl {
    var title: String {
        didSet { setNeedsDisplay() }
    }
    var symbol: String? {
        didSet { setNeedsDisplay() }
    }
    /// A key that stays pressed in, for switches such as Loop.
    var isOn = false {
        didSet { setNeedsDisplay() }
    }
    var fontSize: CGFloat = 13
    private let fn: () -> Void

    init(_ title: String, symbol: String? = nil, width: CGFloat? = nil, height: CGFloat = 30, _ fn: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.fn = fn
        let measured = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .medium)]).width
        super.init(frame: CGRect(x: 0, y: 0, width: width ?? ceil(measured) + 18, height: height))
        backgroundColor = UIColor.clear
        isOpaque = false
        contentMode = .redraw
        accessibilityLabel = title
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isHighlighted: Bool {
        didSet { setNeedsDisplay() }
    }

    override var isEnabled: Bool {
        didSet { setNeedsDisplay() }
    }

    @objc private func fire() {
        fn()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let pressed = isOn || isHighlighted
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = UIBezierPath(roundedRect: body, cornerRadius: 5)
        ctx.saveGState()
        shape.addClip()
        if pressed {
            Theme.gradient(Theme.pressedTop, Theme.pressedBottom, in: bounds)
        } else {
            Theme.gradient(Theme.keyTop, Theme.keyBottom, in: bounds)
            Theme.fill(Theme.highlight, CGRect(x: 0, y: 1, width: bounds.width, height: 1))
        }
        ctx.restoreGState()
        (pressed ? Theme.accentText : Theme.line).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        var ink = pressed ? Theme.accentInk : Theme.text
        if !isEnabled { ink = ink.withAlphaComponent(0.35) }
        var drewIcon = false
        if let name = symbol {
            let config = UIImage.SymbolConfiguration(pointSize: min(17, bounds.height * 0.5), weight: .medium)
            if let img = UIImage(systemName: name, withConfiguration: config)?.withTintColor(ink, renderingMode: .alwaysOriginal) {
                img.draw(at: CGPoint(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2))
                drewIcon = true
            }
        }
        if !drewIcon {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: ink
            ]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                     withAttributes: attrs)
        }
    }
}

/// The titled strip at the top of a panel.
final class PadPanelHeader: UIView {
    static let height: CGFloat = 26
    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: CGRect(x: 0, y: 0, width: 200, height: PadPanelHeader.height))
        isOpaque = true
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ rect: CGRect) {
        Theme.bar(in: bounds)
        for i in 0..<3 {
            Theme.fill(Theme.grip, CGRect(x: 8 + CGFloat(i) * 4, y: bounds.midY - 3, width: 2, height: 2))
            Theme.fill(Theme.grip, CGRect(x: 8 + CGFloat(i) * 4, y: bounds.midY + 1, width: 2, height: 2))
        }
        Theme.label(title.uppercased(), at: CGPoint(x: 26, y: bounds.midY - 7), color: Theme.text, size: 11, bold: true)
        Theme.fill(Theme.line, CGRect(x: 0, y: 0, width: 1, height: bounds.height))
        Theme.fill(Theme.line, CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))
    }
}

/// A plain themed surface: either a raised bar or a panel's body.
final class PadSurface: UIView {
    enum Kind {
        case bar
        case panel
        /// The panel gradient without edge lines, for a whole-screen background.
        case backdrop
    }
    private let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ rect: CGRect) {
        switch kind {
        case .bar:
            Theme.bar(in: bounds)
        case .backdrop:
            Theme.gradient(Theme.panel, Theme.panelDark, in: bounds)
        case .panel:
            Theme.gradient(Theme.panel, Theme.panelDark, in: bounds)
            Theme.fill(Theme.line, CGRect(x: 0, y: 0, width: 1, height: bounds.height))
            Theme.fill(Theme.line, CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))
        }
    }
}

/// Redraws a view and everything inside it, after the theme changes.
@MainActor func padRedrawAll(_ view: UIView) {
    view.setNeedsDisplay()
    view.setNeedsLayout()
    for child in view.subviews {
        padRedrawAll(child)
    }
}

/// Whether two colours are the same to within what a colour picker can tell apart.
func padSameColor(_ a: RGBA, _ b: RGBA) -> Bool {
    return abs(a.r - b.r) < 0.004 && abs(a.g - b.g) < 0.004 && abs(a.b - b.b) < 0.004 && abs(a.a - b.a) < 0.004
}
