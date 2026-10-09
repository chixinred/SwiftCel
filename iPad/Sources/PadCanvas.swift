import UIKit

/// The stage. Apple Pencil draws with pressure; two fingers move and pinch the view;
/// a two-finger tap undoes and a three-finger tap redoes.
///
/// It is built from three see-through sheets, so that drawing never waits on a full redraw:
/// - `sceneLayer` holds a finished picture of the frame. It is only re-rendered when the
///   animation changes, and while you pinch or drag it is slid and stretched on the
///   graphics chip at once, with quick low-resolution renders filling in behind.
/// - `liveLayer` shows the stroke you are drawing. It is built from small pieces, so each
///   new bit of stroke only redraws its own piece instead of the whole stroke.
/// - `overlay` draws the selection, transform handles, marquee and lasso on top.
final class PadCanvasView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate,
                           UIScribbleInteractionDelegate {
    let state: AppState

    private(set) var zoom: CGFloat = 1
    private var pan = CGPoint(x: 40, y: 40)
    /// How far the stage is turned, in radians. Two fingers twist it.
    private(set) var angle: CGFloat = 0

    /// Stage (document) coordinates to view coordinates: scale, then turn, then shift.
    private var viewTransform: CGAffineTransform {
        return CGAffineTransform(translationX: pan.x, y: pan.y).rotated(by: angle).scaledBy(x: zoom, y: zoom)
    }
    private var needsFit = true
    private var lastSize = CGSize.zero
    /// True while the view is being dragged or pinched.
    private var navigating = false

    // The rendered picture of the stage and where it was taken from.
    private let sceneLayer = CALayer()
    /// The view transform the picture was rendered with.
    private var sceneTransform = CGAffineTransform.identity
    /// How long the last full render took, so playback can drop to a lighter one.
    private var lastRenderTime: CFTimeInterval = 0
    private var sceneSize = CGSize.zero
    private var sceneScale: CGFloat = 0
    /// Goes up by one every time the animation changes, so a picture can tell whether
    /// it shows the latest art.
    private var contentGeneration = 0
    private var shownGeneration = -1
    private var renderInFlight = false
    private let sceneWorker = SceneWorker()
    /// Finished strokes kept on screen until a picture that includes them arrives.
    private var waitingSheets: [(generation: Int, sheet: CALayer?)] = []

    // The stroke being drawn, in pieces.
    private let liveLayer = CALayer()
    private var chunkLayer: CAShapeLayer?
    private var chunkPath = CGMutablePath()
    private var chunkCount = 0

    private let overlay = PadCanvasOverlay()
    private let strokeWorker = StrokeWorker()

    // In-progress touch
    private var drawingTouch: UITouch?
    private var activeTool: Tool?
    private var stroke: [StrokePoint] = []
    private var sprayed = Set<Int64>()
    private var live: CGMutablePath?
    private var dragStartView = CGPoint.zero
    private var dragStartDoc = CGPoint.zero
    private var lastDoc = CGPoint.zero
    private var currentDoc = CGPoint.zero
    private var panStart = CGPoint.zero
    private var movingSelection = false
    private var movedCheckpoint = false
    private var marquee: CGRect?
    /// The lasso loop being drawn, in view coordinates.
    private var lassoPoints: [CGPoint] = []
    private var toolBeforeEraser: Tool = .brush

    // Transform tool
    private enum Grab {
        case move
        case rotate
        case scale(Int)
    }
    private var grab: Grab?
    private var grabBox = CGRect.zero
    private var grabApplied = CGAffineTransform.identity
    private let handleX: [CGFloat] = [0, 0.5, 1, 1, 1, 0.5, 0, 0]
    private let handleY: [CGFloat] = [0, 0, 0, 0.5, 1, 1, 1, 0.5]

    init(state: AppState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        isOpaque = true
        backgroundColor = Theme.pasteboard
        isMultipleTouchEnabled = true
        clipsToBounds = true

        // No animations: each sheet must change the instant it is told to.
        let still: [String: CAAction] = ["contents": NSNull(), "transform": NSNull(), "bounds": NSNull(),
                                         "position": NSNull(), "sublayerTransform": NSNull(),
                                         "sublayers": NSNull(), "opacity": NSNull()]
        sceneLayer.actions = still
        sceneLayer.anchorPoint = .zero
        sceneLayer.contentsGravity = .resize
        liveLayer.actions = still
        liveLayer.anchorPoint = .zero
        layer.addSublayer(sceneLayer)
        layer.addSublayer(liveLayer)
        overlay.canvas = self
        addSubview(overlay)

        state.observe { [weak self] in
            self?.invalidate()
        }
        strokeWorker.deliver = { [weak self] job, shape in
            self?.apply(job, shape: shape)
        }
        sceneWorker.deliver = { [weak self] job, image, seconds in
            self?.sceneArrived(job, image: image, seconds: seconds)
        }

        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = fingers
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumNumberOfTouches = 2
        drag.maximumNumberOfTouches = 2
        drag.allowedTouchTypes = fingers
        drag.allowedScrollTypesMask = .all
        drag.delegate = self
        addGestureRecognizer(drag)

        let twist = UIRotationGestureRecognizer(target: self, action: #selector(twisted(_:)))
        twist.allowedTouchTypes = fingers
        twist.delegate = self
        addGestureRecognizer(twist)

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undoTapped(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = fingers
        undoTap.delegate = self
        addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redoTapped(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = fingers
        redoTap.delegate = self
        addGestureRecognizer(redoTap)

        // Scribble (iPadOS handwriting-to-text) watches the Pencil whenever there is a text
        // box on screen, and holds a stroke back until it decides it isn't handwriting.
        // That made strokes appear only after lifting the Pencil. The stage opts out.
        addInteraction(UIScribbleInteraction(delegate: self))

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The overlay is the only part drawn with `draw(_:)`, so redraw requests go to it.
    override func setNeedsDisplay() {
        super.setNeedsDisplay()
        overlay.setNeedsDisplay()
    }

    /// The animation changed: re-render the stage picture soon (once, however many
    /// changes arrive together) and redraw the overlay.
    func invalidate() {
        contentGeneration += 1
        requestScene()
        overlay.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        liveLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        liveLayer.position = .zero
        if bounds.size != lastSize {
            // Keep the same part of the stage in the middle when the view changes size.
            if !needsFit && lastSize.width > 0 {
                pan.x += (bounds.width - lastSize.width) / 2
                pan.y += (bounds.height - lastSize.height) / 2
            }
            lastSize = bounds.size
            if needsFit && applyFit() {
                DispatchQueue.main.async { [weak self] in
                    self?.state.changed()
                }
            }
            invalidate()
        }
    }

    private var pixelScale: CGFloat {
        let s = window?.screen.scale ?? UIScreen.main.scale
        return s > 0 ? s : 2
    }

    // MARK: Coordinates

    private func toDoc(_ v: CGPoint) -> CGPoint {
        return v.applying(viewTransform.inverted())
    }

    private func toView(_ d: CGPoint) -> CGPoint {
        return d.applying(viewTransform)
    }

    /// Moves `pan` so that stage point `d` sits under view point `v`.
    private func pin(_ d: CGPoint, to v: CGPoint) {
        let turned = CGPoint(x: d.x * zoom, y: d.y * zoom).applying(CGAffineTransform(rotationAngle: angle))
        pan = CGPoint(x: v.x - turned.x, y: v.y - turned.y)
    }

    func zoomBy(_ factor: CGFloat, at v: CGPoint, notify: Bool = true) {
        let d = toDoc(v)
        zoom = max(0.05, min(64, zoom * factor))
        pin(d, to: v)
        state.zoom = zoom
        if notify {
            state.changed()
        } else {
            viewMoved()
        }
    }

    /// Turns the stage around view point `v`.
    func rotateBy(_ radians: CGFloat, at v: CGPoint) {
        let d = toDoc(v)
        angle += radians
        // Keep it between -180° and 180°.
        while angle > .pi { angle -= 2 * .pi }
        while angle < -.pi { angle += 2 * .pi }
        pin(d, to: v)
        viewMoved()
    }

    /// Puts the stage back upright, keeping the middle of the view where it is.
    func resetRotation() {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let d = toDoc(c)
        angle = 0
        pin(d, to: c)
        state.changed()
    }

    func zoomCentered(by factor: CGFloat) {
        zoomBy(factor, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func setZoom(_ z: CGFloat) {
        zoomCentered(by: z / zoom)
    }

    @discardableResult
    private func applyFit() -> Bool {
        let doc = state.doc
        guard bounds.width > 100, bounds.height > 100 else { return false }
        let z = min((bounds.width - 60) / doc.width, (bounds.height - 60) / doc.height)
        zoom = max(0.05, min(64, z))
        angle = 0
        pan = CGPoint(x: (bounds.width - doc.width * zoom) / 2, y: (bounds.height - doc.height * zoom) / 2)
        needsFit = false
        state.zoom = zoom
        return true
    }

    func fit() {
        if applyFit() {
            state.changed()
        } else {
            needsFit = true
        }
    }

    // MARK: The stage picture

    /// Pan or zoom changed: move the picture we have straight away, then ask for a fresh one.
    private func viewMoved() {
        // Where the current picture's pixels belong now: back to the stage, then out again.
        let shift = sceneTransform.inverted().concatenating(viewTransform)
        let now = CATransform3DMakeAffineTransform(viewTransform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sceneLayer.setAffineTransform(shift)
        // Strokes still being finished move along with the stage.
        liveLayer.sublayers?.forEach { $0.sublayerTransform = now }
        CATransaction.commit()
        requestScene()
        overlay.setNeedsDisplay()
    }

    /// The picture sharpness wanted right now: lighter while moving the view, and during
    /// playback if full sharpness can't keep up.
    private var wantedScale: CGFloat {
        if navigating { return 1 }
        if state.isPlaying && lastRenderTime > 0.6 / Double(max(1, state.doc.fps)) { return 1 }
        return pixelScale
    }

    private var sceneIsCurrent: Bool {
        return shownGeneration == contentGeneration && sceneTransform == viewTransform
            && sceneSize == bounds.size && sceneScale >= wantedScale
    }

    /// Asks for a fresh picture of the stage. Pictures are drawn on a background thread,
    /// one at a time, so touches and gestures never wait for them; if more changes arrive
    /// meanwhile, the next picture starts as soon as the current one lands.
    private func requestScene() {
        if renderInFlight || sceneIsCurrent { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderInFlight = true
        let ghosts = state.onionSkin && !state.isPlaying ? state.onionFrames() : []
        let job = SceneJob(doc: state.doc, frame: state.frame, clipToStage: state.clipToStage,
                           ghosts: ghosts.map { SceneJob.Ghost(frame: $0.frame, alpha: $0.alpha, later: $0.later) },
                           tint: state.onion.tint, tintBefore: state.onion.tintBefore.cgColor,
                           tintAfter: state.onion.tintAfter.cgColor, symbol: state.editingSymbol,
                           pasteboard: Theme.pasteboard.cgColor, transform: viewTransform, zoom: zoom,
                           size: bounds.size, scale: wantedScale, generation: contentGeneration)
        sceneWorker.render(job)
    }

    private func sceneArrived(_ job: SceneJob, image: CGImage?, seconds: CFTimeInterval) {
        renderInFlight = false
        if job.scale >= pixelScale { lastRenderTime = seconds }
        if let image = image {
            // The picture was taken at `job.transform`; place it for wherever the view is now.
            let shift = job.transform.inverted().concatenating(viewTransform)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backgroundColor = UIColor(cgColor: job.pasteboard)
            sceneLayer.bounds = CGRect(origin: .zero, size: job.size)
            sceneLayer.position = .zero
            sceneLayer.contents = image
            sceneLayer.setAffineTransform(shift)
            CATransaction.commit()
            sceneTransform = job.transform
            sceneSize = job.size
            sceneScale = job.scale
            shownGeneration = job.generation
        }
        // Finished strokes that this picture now includes can go.
        let shown = shownGeneration
        let done = waitingSheets.filter { $0.generation <= shown }
        waitingSheets.removeAll { $0.generation <= shown }
        for entry in done {
            remove(entry.sheet)
        }
        requestScene()
    }

    // MARK: The stroke in progress

    /// The sheet holding the stroke being drawn. Each stroke gets its own, so a finished
    /// stroke can stay on screen while its final shape is worked out in the background.
    private var strokeLayer: CALayer?

    private func startLive(color: RGBA) {
        var solid = color
        solid.a = 1
        liveFill = solid.cgColor
        let sheet = CALayer()
        sheet.actions = ["sublayerTransform": NSNull(), "sublayers": NSNull(), "bounds": NSNull(),
                         "position": NSNull(), "opacity": NSNull()]
        sheet.anchorPoint = .zero
        sheet.bounds = CGRect(origin: .zero, size: bounds.size)
        sheet.position = .zero
        // A see-through colour is applied to the whole stroke at once, so the pieces
        // don't darken where they overlap.
        sheet.opacity = Float(max(0.02, color.a))
        sheet.sublayerTransform = CATransform3DMakeAffineTransform(viewTransform)
        if state.clipToStage {
            let mask = CAShapeLayer()
            var t = viewTransform
            mask.path = CGPath(rect: CGRect(x: 0, y: 0, width: state.doc.width, height: state.doc.height), transform: &t)
            mask.frame = sheet.bounds
            sheet.mask = mask
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.addSublayer(sheet)
        CATransaction.commit()
        strokeLayer = sheet
        newChunk()
    }

    private var liveFill: CGColor = UIColor.black.cgColor

    private func newChunk() {
        let piece = CAShapeLayer()
        piece.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        piece.fillColor = liveFill
        piece.fillRule = .nonZero
        piece.strokeColor = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer?.addSublayer(piece)
        CATransaction.commit()
        chunkLayer = piece
        chunkPath = CGMutablePath()
        chunkCount = 0
    }

    /// Adds a bit of stroke. Only the newest piece is redrawn; once a piece holds enough,
    /// it is left alone and a new one is started.
    private func appendLive(_ bit: CGPath) {
        chunkPath.addPath(bit)
        chunkCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chunkLayer?.path = chunkPath.copy()
        CATransaction.commit()
        if chunkCount >= 24 { newChunk() }
    }

    /// Lets go of the current stroke's sheet (it stays on screen until removed).
    private func detachLive() -> CALayer? {
        let sheet = strokeLayer
        strokeLayer = nil
        chunkLayer = nil
        chunkPath = CGMutablePath()
        chunkCount = 0
        clearPrediction()
        return sheet
    }

    private func remove(_ sheet: CALayer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheet?.removeFromSuperlayer()
        CATransaction.commit()
    }

    /// A finished stroke's shape has been worked out: add it to the art, and take the live
    /// stroke away once the new picture of the stage is up, so nothing flickers.
    private func apply(_ job: StrokeJob, shape: CGPath?) {
        statsStrokeTime = job.seconds
        if let shape = shape {
            switch job.tool {
            case .brush:
                state.addFill(shape, color: job.color)
            case .eraser:
                state.erase(shape)
            case .pencil:
                if !shape.isEmpty { state.addSeparate(shape, color: job.color) }
            default:
                break
            }
        }
        // The live stroke stays until a picture including the new art is on screen.
        if shownGeneration >= contentGeneration {
            remove(job.sheet)
        } else {
            waitingSheets.append((generation: contentGeneration, sheet: job.sheet))
            requestScene()
        }
    }

    // MARK: Predicted touches

    /// Where the Pencil is about to be, drawn faintly ahead of the stroke so the line
    /// keeps up with the tip. It is replaced on every move and never becomes art.
    private var predictionLayer: CAShapeLayer?

    private func showPrediction(_ points: [StrokePoint]) {
        guard let sheet = strokeLayer, let last = stroke.last, !points.isEmpty, activeTool != .pencil else {
            clearPrediction()
            return
        }
        let path = CGMutablePath()
        var from = last
        for p in points {
            Brush.addDab(path, from: from, to: p)
            from = p
        }
        let shape: CAShapeLayer
        if let existing = predictionLayer, existing.superlayer === sheet {
            shape = existing
        } else {
            shape = CAShapeLayer()
            shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            shape.fillRule = .nonZero
            shape.strokeColor = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sheet.addSublayer(shape)
            CATransaction.commit()
            predictionLayer = shape
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.fillColor = liveFill
        shape.path = path
        CATransaction.commit()
    }

    private func clearPrediction() {
        guard let shape = predictionLayer else { return }
        predictionLayer = nil
        remove(shape)
    }

    // MARK: The overlay

    func drawOverlay(in ctx: CGContext) {
        ctx.saveGState()
        ctx.concatenate(viewTransform)
        if state.clipToStage {
            ctx.clip(to: CGRect(x: 0, y: 0, width: state.doc.width, height: state.doc.height))
        }

        // Line, rectangle and oval previews
        if let tool = activeTool {
            let ink = state.color.cgColor
            switch tool {
            case .line:
                ctx.beginPath()
                ctx.move(to: dragStartDoc)
                ctx.addLine(to: currentDoc)
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(state.size)
                ctx.setLineCap(.round)
                ctx.strokePath()
            case .rect:
                ctx.setFillColor(ink)
                ctx.fill(dragRect())
            case .oval:
                ctx.setFillColor(ink)
                ctx.fillEllipse(in: dragRect())
            default:
                break
            }
        }

        // Selection highlight
        let chosen = state.selectedShapes
        if !chosen.isEmpty {
            for shape in chosen {
                ctx.addPath(shape.path)
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.3))
                ctx.fillPath(using: .winding)
                ctx.addPath(shape.path)
                ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 1))
                ctx.setLineWidth(1.5 / zoom)
                ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
                ctx.strokePath()
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()

        drawTransformBox(in: ctx)

        if let m = marquee {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.stroke(m)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if lassoPoints.count > 1 {
            // The lasso loop, closed back to where it started.
            ctx.beginPath()
            ctx.addLines(between: lassoPoints)
            ctx.closePath()
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 0.08))
            ctx.fillPath(using: .winding)
            ctx.beginPath()
            ctx.addLines(between: lassoPoints)
            ctx.closePath()
            ctx.setLineWidth(1.5)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.strokePath()
            ctx.beginPath()
            ctx.addLines(between: lassoPoints)
            ctx.closePath()
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.85))
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if let symbol = state.doc.item(state.editingSymbol) {
            let note = "Editing symbol \u{201C}\(symbol.name)\u{201D}  -  double-tap empty space when done"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 13),
                .foregroundColor: Theme.accentInk
            ]
            let size = (note as NSString).size(withAttributes: attrs)
            let pill = CGRect(x: 12, y: 10, width: size.width + 20, height: size.height + 8)
            Theme.accent.setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 6).fill()
            (note as NSString).draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 4), withAttributes: attrs)
        }
    }

    private func dragRect() -> CGRect {
        let dx = currentDoc.x - dragStartDoc.x
        let dy = currentDoc.y - dragStartDoc.y
        return CGRect(x: min(dragStartDoc.x, dragStartDoc.x + dx), y: min(dragStartDoc.y, dragStartDoc.y + dy),
                      width: abs(dx), height: abs(dy))
    }

    // MARK: Strokes

    private func pressure(of touch: UITouch) -> CGFloat {
        guard state.usePressure, touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        // A normal writing grip is well under half of the Pencil's range, so the top
        // of the curve is reached early and the low end is opened up.
        let n = max(0, min(1, touch.force / (touch.maximumPossibleForce * 0.55)))
        return 0.12 + 0.88 * pow(n, 0.75)
    }

    private func dabPath(from a: StrokePoint, to b: StrokePoint) -> CGPath {
        let p = CGMutablePath()
        Brush.addDab(p, from: a, to: b)
        return p
    }

    private func addStrokePoint(_ d: CGPoint, pressure: CGFloat, force: Bool = false) {
        let r = max(0.25, state.size / 2 * pressure)
        let sp = StrokePoint(p: d, r: r)
        if let last = stroke.last {
            let gap = (d - last.p).length
            if !force && gap < max(0.75 / zoom, r * 0.12) { return }
            if activeTool == .pencil {
                let specks = CGMutablePath()
                Brush.addSpray(specks, from: last.p, to: d, radius: r, seen: &sprayed)
                live?.addPath(specks)
                appendLive(specks)
            } else {
                let dab = dabPath(from: last, to: sp)
                live?.addPath(dab)
                appendLive(dab)
            }
        } else if activeTool == .pencil {
            let specks = CGMutablePath()
            Brush.addSpray(specks, from: d, to: d, radius: r, seen: &sprayed)
            live?.addPath(specks)
            appendLive(specks)
        } else {
            let dab = dabPath(from: sp, to: sp)
            live?.addPath(dab)
            appendLive(dab)
        }
        stroke.append(sp)
    }

    // MARK: Transform tool

    private func handlePoint(_ i: Int, in box: CGRect) -> CGPoint {
        return CGPoint(x: box.minX + handleX[i] * box.width, y: box.minY + handleY[i] * box.height)
    }

    /// The round rotation knob sits a little above the top edge of the box.
    private func rotateKnob(for box: CGRect) -> CGPoint {
        // Out from the middle of the top edge, whichever way the stage is turned.
        let top = toView(CGPoint(x: box.midX, y: box.minY))
        let up = CGPoint(x: 0, y: -1).applying(CGAffineTransform(rotationAngle: angle))
        return CGPoint(x: top.x + up.x * 34, y: top.y + up.y * 34)
    }

    private func grabAt(_ v: CGPoint, box: CGRect, reach: CGFloat) -> Grab? {
        let knob = rotateKnob(for: box)
        if hypot(v.x - knob.x, v.y - knob.y) < reach + 2 { return .rotate }
        var nearest: Int? = nil
        var best = reach
        for i in 0..<8 {
            let h = toView(handlePoint(i, in: box))
            let dist = hypot(v.x - h.x, v.y - h.y)
            if dist < best {
                best = dist
                nearest = i
            }
        }
        if let i = nearest { return .scale(i) }
        if box.insetBy(dx: -2 / zoom, dy: -2 / zoom).contains(toDoc(v)) { return .move }
        return nil
    }

    /// The whole transform for the gesture so far, from where it started to `d`.
    private func transformFor(_ g: Grab, to d: CGPoint) -> CGAffineTransform {
        let box = grabBox
        switch g {
        case .move:
            return CGAffineTransform(translationX: d.x - dragStartDoc.x, y: d.y - dragStartDoc.y)
        case .rotate:
            let c = CGPoint(x: box.midX, y: box.midY)
            let from = atan2(dragStartDoc.y - c.y, dragStartDoc.x - c.x)
            let angle = atan2(d.y - c.y, d.x - c.x) - from
            return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y)
        case .scale(let i):
            let anchor = handlePoint((i + 4) % 8, in: box)
            let handle = handlePoint(i, in: box)
            var sx: CGFloat = 1
            var sy: CGFloat = 1
            if handleX[i] != 0.5 {
                let span = handle.x - anchor.x
                if abs(span) > 0.001 { sx = (d.x - anchor.x) / span }
            }
            if handleY[i] != 0.5 {
                let span = handle.y - anchor.y
                if abs(span) > 0.001 { sy = (d.y - anchor.y) / span }
            }
            if abs(sx) < 0.01 { sx = sx < 0 ? -0.01 : 0.01 }
            if abs(sy) < 0.01 { sy = sy < 0 ? -0.01 : 0.01 }
            return CGAffineTransform(translationX: anchor.x, y: anchor.y).scaledBy(x: sx, y: sy)
                .translatedBy(x: -anchor.x, y: -anchor.y)
        }
    }

    private func drawTransformBox(in ctx: CGContext) {
        guard state.tool == .transform, let box = state.selectionBox else { return }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map { toView($0) }
        let knob = rotateKnob(for: box)
        let blue = CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 1)
        ctx.setStrokeColor(blue)
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        ctx.addLines(between: corners)
        ctx.closePath()
        ctx.strokePath()
        ctx.beginPath()
        ctx.move(to: toView(CGPoint(x: box.midX, y: box.minY)))
        ctx.addLine(to: knob)
        ctx.strokePath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for i in 0..<8 {
            let h = toView(handlePoint(i, in: box))
            let r = CGRect(x: h.x - 6, y: h.y - 6, width: 12, height: 12)
            ctx.fill(r)
            ctx.stroke(r)
        }
        let dot = CGRect(x: knob.x - 7, y: knob.y - 7, width: 14, height: 14)
        ctx.fillEllipse(in: dot)
        ctx.strokeEllipse(in: dot)
    }

    // MARK: Touches

    private func begin(_ touch: UITouch) {
        let v = touch.preciseLocation(in: self)
        let d = toDoc(v)
        dragStartView = v
        dragStartDoc = d
        lastDoc = d
        currentDoc = d
        let pencil = touch.type == .pencil
        if pencil && !PadPrefs.pencilSeen { PadPrefs.pencilSeen = true }
        // A finger moves the stage unless fingers are allowed to draw.
        let tool: Tool = (pencil || touch.type == .indirectPointer || PadPrefs.fingerDraws) ? state.tool : .hand
        if state.isPlaying { state.stop() }

        switch tool {
        case .hand:
            activeTool = .hand
            panStart = pan
            navigating = true
        case .brush, .eraser, .pencil:
            guard state.canEdit else {
                state.beep()
                return
            }
            activeTool = tool
            stroke = []
            sprayed.removeAll()
            live = CGMutablePath()
            startLive(color: tool == .eraser ? state.doc.background : state.color)
            addStrokePoint(d, pressure: pressure(of: touch), force: true)
            // A stroke only touches the live sheet; nothing else needs redrawing.
            return
        case .line, .rect, .oval:
            guard state.canEdit else {
                state.beep()
                return
            }
            activeTool = tool
        case .bucket, .eyedropper:
            // Applied when the touch lifts, so a two-finger tap doesn't fill first.
            activeTool = tool
        case .transform:
            guard state.canEdit else {
                state.beep()
                return
            }
            movedCheckpoint = false
            grab = nil
            if let box = state.selectionBox {
                grab = grabAt(v, box: box, reach: pencil ? 14 : 22)
            }
            if grab == nil {
                if let hit = state.hitAny(d) {
                    state.selectOnly(layer: hit.layer, index: hit.index)
                    grab = .move
                } else {
                    state.selection.removeAll()
                }
            }
            if grab != nil, let box = state.selectionBox {
                activeTool = .transform
                grabBox = box
                grabApplied = CGAffineTransform.identity
            }
        case .lasso:
            guard state.canEdit else {
                state.beep()
                return
            }
            movedCheckpoint = false
            if let hit = state.hitAny(d), state.isSelected(layer: hit.layer, index: hit.index) {
                // Dragging what the lasso picked moves it, as with the Selection tool.
                activeTool = .select
                movingSelection = true
            } else {
                activeTool = .lasso
                lassoPoints = [v]
            }
        case .select:
            activeTool = .select
            movedCheckpoint = false
            if touch.tapCount == 2 {
                // Double-tap a symbol to edit it; double-tap empty space to finish.
                if let hit = state.hitAny(d) {
                    if hit.layer != state.layer { state.selectOnly(layer: hit.layer, index: hit.index) }
                    let shapes = state.currentShapes
                    if shapes.indices.contains(hit.index), state.doc.item(shapes[hit.index].ref)?.isSymbol == true {
                        activeTool = nil
                        state.enterEdit(shapes[hit.index].ref)
                        return
                    }
                } else if state.editingSymbol != nil {
                    activeTool = nil
                    state.exitEdit()
                    return
                }
            }
            if let hit = state.hitAny(d) {
                if addToSelection {
                    state.toggleSelected(layer: hit.layer, index: hit.index)
                } else if !state.isSelected(layer: hit.layer, index: hit.index) {
                    state.selectOnly(layer: hit.layer, index: hit.index)
                }
                movingSelection = state.hasSelection
            } else {
                if !addToSelection { state.selection.removeAll() }
                movingSelection = false
                marquee = CGRect(origin: v, size: .zero)
            }
        }
        setNeedsDisplay()
    }

    /// On: tapping art adds it to (or removes it from) the selection instead of replacing it.
    var addToSelection = false

    /// True while a finger or the Pencil is down on the stage.
    var isBusy: Bool {
        return drawingTouch != nil || navigating
    }

    private func move(_ touch: UITouch, with event: UIEvent?) {
        guard let tool = activeTool else { return }
        let v = touch.preciseLocation(in: self)
        let d = toDoc(v)
        currentDoc = d
        switch tool {
        case .hand:
            pan = CGPoint(x: panStart.x + v.x - dragStartView.x, y: panStart.y + v.y - dragStartView.y)
            viewMoved()
            return
        case .brush, .eraser, .pencil:
            // The Pencil reports faster than the screen refreshes; use every sample.
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for s in samples {
                addStrokePoint(toDoc(s.preciseLocation(in: self)), pressure: pressure(of: s))
            }
            // Draw a little ahead of the tip, where the Pencil is predicted to be next.
            let ahead = (event?.predictedTouches(for: touch) ?? []).map { t -> StrokePoint in
                StrokePoint(p: toDoc(t.preciseLocation(in: self)), r: max(0.25, state.size / 2 * pressure(of: t)))
            }
            showPrediction(ahead)
            lastDoc = d
            return
        case .lasso:
            if let last = lassoPoints.last, hypot(v.x - last.x, v.y - last.y) >= 2 {
                lassoPoints.append(v)
            }
        case .transform:
            if let g = grab {
                let total = transformFor(g, to: d)
                let delta = grabApplied.inverted().concatenating(total)
                state.transformSelection(delta, checkpoint: !movedCheckpoint)
                movedCheckpoint = true
                grabApplied = total
            }
        case .select:
            if movingSelection {
                let dx = d.x - lastDoc.x
                let dy = d.y - lastDoc.y
                if dx != 0 || dy != 0 {
                    state.translateSelection(dx: dx, dy: dy, checkpoint: !movedCheckpoint)
                    movedCheckpoint = true
                }
            } else {
                marquee = CGRect(x: min(v.x, dragStartView.x), y: min(v.y, dragStartView.y),
                                 width: abs(v.x - dragStartView.x), height: abs(v.y - dragStartView.y))
            }
        default:
            break
        }
        lastDoc = d
        setNeedsDisplay()
    }

    private func finish(_ touch: UITouch?, cancelled: Bool) {
        guard let tool = activeTool else { return }
        let d: CGPoint
        if let t = touch {
            d = toDoc(t.preciseLocation(in: self))
        } else {
            d = currentDoc
        }
        currentDoc = d
        let points = stroke
        let sprayPath = live
        activeTool = nil
        grab = nil
        stroke = []
        live = nil
        let area = marquee
        marquee = nil
        let loop = lassoPoints
        lassoPoints = []
        movingSelection = false

        if tool == .hand {
            navigating = false
            requestScene()
            return
        }
        if cancelled {
            remove(detachLive())
            setNeedsDisplay()
            return
        }

        switch tool {
        case .brush, .eraser, .pencil:
            // Working out the finished shape can take a moment on a long stroke, so it is
            // done in the background. The stroke stays on screen until it is ready, and
            // the next stroke can start straight away.
            let job = StrokeJob(tool: tool, points: points, spray: sprayPath?.copy(),
                                smoothing: tool == .eraser ? min(state.smoothing, 25) : state.smoothing,
                                zoom: zoom, legacy: state.legacyBrush, color: state.color,
                                sheet: detachLive())
            strokeWorker.submit(job)
        case .line:
            if (d - dragStartDoc).length > 0.5 {
                state.addFill(Brush.lineShape(from: dragStartDoc, to: d, width: state.size), color: state.color)
            }
        case .rect:
            let r = dragRect()
            if r.width > 0.5 && r.height > 0.5 {
                state.addFill(CGPath(rect: r, transform: nil), color: state.color)
            }
        case .oval:
            let r = dragRect()
            if r.width > 0.5 && r.height > 0.5 {
                state.addFill(CGPath(ellipseIn: r, transform: nil), color: state.color)
            }
        case .lasso:
            if loop.count >= 3 {
                let path = CGMutablePath()
                path.addLines(between: loop.map { toDoc($0) })
                path.closeSubpath()
                state.lassoSelect(path, adding: addToSelection)
            } else if !addToSelection {
                state.deselect()
            }
        case .bucket:
            state.bucket(at: d)
        case .eyedropper:
            state.pickColor(at: d)
        case .select:
            if let m = area, m.width > 2 || m.height > 2 {
                // The marquee is square to the screen, so on a turned stage it is a turned
                // rectangle on the stage.
                let region = CGMutablePath()
                region.addLines(between: [CGPoint(x: m.minX, y: m.minY), CGPoint(x: m.maxX, y: m.minY),
                                          CGPoint(x: m.maxX, y: m.maxY), CGPoint(x: m.minX, y: m.maxY)].map { toDoc($0) })
                region.closeSubpath()
                let box = region.boundingBoxOfPath
                func touches(_ shape: Shape) -> Bool {
                    let b = shape.path.boundingBoxOfPath
                    guard box.intersects(b) else { return false }
                    return angle == 0 || region.intersects(CGPath(rect: b, transform: nil))
                }
                if state.editingSymbol != nil {
                    let shapes = state.currentShapes
                    for i in shapes.indices where touches(shapes[i]) {
                        state.selection.insert(i)
                    }
                } else {
                    // The marquee picks up art on every visible, unlocked layer.
                    let doc = state.doc
                    for li in doc.layers.indices where doc.layers[li].visible && !doc.layers[li].locked {
                        let shapes = doc.layers[li].shapes(at: state.frame)
                        var found = Set<Int>()
                        for i in shapes.indices where touches(shapes[i]) {
                            found.insert(i)
                        }
                        state.addToSelection(layer: li, indexes: found)
                    }
                }
                state.changed()
            }
        default:
            break
        }
        setNeedsDisplay()
    }

    /// Never turn drawing on the stage into text.
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        return false
    }

    // MARK: Performance readout

    /// View > Show Performance: a small readout in the corner of the stage, for finding
    /// out where any slowness comes from.
    var showStats = false {
        didSet {
            statsLabel.isHidden = !showStats
            if showStats {
                if statsLink == nil {
                    let link = CADisplayLink(target: self, selector: #selector(statsTick(_:)))
                    link.add(to: .main, forMode: .common)
                    statsLink = link
                }
                if statsLabel.superview == nil {
                    statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                    statsLabel.textColor = UIColor.white
                    statsLabel.backgroundColor = UIColor(white: 0, alpha: 0.6)
                    statsLabel.numberOfLines = 0
                    statsLabel.layer.cornerRadius = 5
                    statsLabel.clipsToBounds = true
                    statsLabel.isUserInteractionEnabled = false
                    addSubview(statsLabel)
                }
            } else {
                statsLink?.invalidate()
                statsLink = nil
            }
        }
    }
    private let statsLabel = UILabel()
    private var statsLink: CADisplayLink?
    private var statsLastTick: CFTimeInterval = 0
    private var statsWindowStart: CFTimeInterval = 0
    private var statsFrames = 0
    private var statsWorstGap: CFTimeInterval = 0
    private var statsTouches = 0
    private var statsWorstDelay: CFTimeInterval = 0
    var statsStrokeTime: CFTimeInterval = 0

    @objc private func statsTick(_ link: CADisplayLink) {
        let now = link.timestamp
        if statsLastTick > 0 { statsWorstGap = max(statsWorstGap, now - statsLastTick) }
        statsLastTick = now
        statsFrames += 1
        if statsWindowStart == 0 { statsWindowStart = now }
        let span = now - statsWindowStart
        guard span >= 1 else { return }
        let fps = Double(statsFrames) / span
        let lines = [
            String(format: "screen  %3.0f fps   worst frame %4.0f ms", fps, statsWorstGap * 1000),
            String(format: "pencil  %3.0f samples/s   input delay %4.0f ms", Double(statsTouches) / span, statsWorstDelay * 1000),
            String(format: "stage picture %4.0f ms   stroke finish %4.0f ms", lastRenderTime * 1000, statsStrokeTime * 1000)
        ]
        statsLabel.text = lines.map { " " + $0 + " " }.joined(separator: "\n")
        let size = statsLabel.sizeThatFits(CGSize(width: 600, height: 200))
        statsLabel.frame = CGRect(x: bounds.width - size.width - 10, y: 10, width: size.width, height: size.height + 6)
        statsWindowStart = now
        statsFrames = 0
        statsWorstGap = 0
        statsTouches = 0
        statsWorstDelay = 0
    }

    /// Notes how many Pencil samples arrived, and how late, for the readout.
    private func noteInput(_ touch: UITouch, event: UIEvent?) {
        guard showStats else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        statsTouches += samples.count
        let delay = CACurrentMediaTime() - touch.timestamp
        if delay < 5 { statsWorstDelay = max(statsWorstDelay, delay) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawingTouch == nil else { return }
        let chosen = touches.first(where: { $0.type == .pencil }) ?? touches.first
        guard let touch = chosen else { return }
        drawingTouch = touch
        begin(touch)
        if activeTool == nil { drawingTouch = nil }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        noteInput(touch, event: event)
        move(touch, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        drawingTouch = nil
        finish(touch, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        drawingTouch = nil
        finish(nil, cancelled: true)
    }

    // MARK: Gestures

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // Nothing interrupts a Pencil stroke.
        if let touch = drawingTouch, touch.type == .pencil { return false }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    private var pinching = false
    private var dragging = false
    private var twisting = false

    private func isActive(_ g: UIGestureRecognizer) -> Bool {
        return g.state == .began || g.state == .changed
    }

    /// The stage is redrawn properly once both two-finger gestures have stopped.
    private func settle() {
        if pinching || dragging || twisting {
            navigating = true
        } else if navigating {
            navigating = false
            requestScene()
            state.changed()
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        pinching = isActive(g)
        settle()
        if g.state == .changed {
            zoomBy(g.scale, at: g.location(in: self), notify: false)
            g.scale = 1
        }
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        dragging = isActive(g)
        settle()
        if g.state == .changed {
            let t = g.translation(in: self)
            pan.x += t.x
            pan.y += t.y
            g.setTranslation(.zero, in: self)
            viewMoved()
        }
    }

    /// Two fingers twisting turn the stage. It settles back to upright, or to a quarter
    /// turn, when let go within a few degrees of one.
    @objc private func twisted(_ g: UIRotationGestureRecognizer) {
        twisting = isActive(g)
        if g.state == .changed {
            rotateBy(g.rotation, at: g.location(in: self))
            g.rotation = 0
        }
        if g.state == .ended || g.state == .cancelled {
            let quarter = CGFloat.pi / 2
            let nearest = (angle / quarter).rounded() * quarter
            if abs(angle - nearest) < 6 * .pi / 180 && nearest != angle {
                rotateBy(nearest - angle, at: g.location(in: self))
            }
        }
        settle()
    }

    @objc private func undoTapped(_ g: UITapGestureRecognizer) {
        if g.state == .ended { state.undo() }
    }

    @objc private func redoTapped(_ g: UITapGestureRecognizer) {
        if g.state == .ended { state.redo() }
    }

    /// Double-tapping the side of the Pencil swaps between the eraser and the last tool.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if state.tool == .eraser {
            state.tool = toolBeforeEraser
        } else {
            toolBeforeEraser = state.tool
            state.tool = .eraser
            state.selection.removeAll()
        }
        state.changed()
    }
}

/// The see-through sheet over the stage that draws selection, handles and the lasso.
final class PadCanvasOverlay: UIView {
    weak var canvas: PadCanvasView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        canvas?.drawOverlay(in: ctx)
    }
}

/// One finished stroke waiting for its final shape.
final class StrokeJob {
    let tool: Tool
    let points: [StrokePoint]
    let spray: CGPath?
    let smoothing: CGFloat
    let zoom: CGFloat
    let legacy: Bool
    let color: RGBA
    /// The live stroke on screen, removed once the shape is in place.
    let sheet: CALayer?
    /// How long working out the shape took, for the performance readout.
    var seconds: CFTimeInterval = 0

    init(tool: Tool, points: [StrokePoint], spray: CGPath?, smoothing: CGFloat, zoom: CGFloat,
         legacy: Bool, color: RGBA, sheet: CALayer?) {
        self.tool = tool
        self.points = points
        self.spray = spray
        self.smoothing = smoothing
        self.zoom = zoom
        self.legacy = legacy
        self.color = color
        self.sheet = sheet
    }

    /// The finished shape: the brush maths for brush and eraser, the specks for the pencil.
    func makeShape() -> CGPath? {
        switch tool {
        case .brush, .eraser:
            if legacy {
                return Brush.smoothedShape(points: points, smoothing: smoothing, zoom: zoom)
            }
            return Brush.modernShape(points: points, smoothing: smoothing, zoom: zoom)
        case .pencil:
            return spray
        default:
            return nil
        }
    }
}

/// Works out finished stroke shapes one at a time, away from the main thread, and hands
/// them back in the order they were drawn.
final class StrokeWorker {
    private let queue = DispatchQueue(label: "swiftcel.strokes", qos: .userInteractive)
    var deliver: ((StrokeJob, CGPath?) -> Void)?

    func submit(_ job: StrokeJob) {
        queue.async {
            let started = CACurrentMediaTime()
            let shape = job.makeShape()
            job.seconds = CACurrentMediaTime() - started
            DispatchQueue.main.async {
                self.deliver?(job, shape)
            }
        }
    }
}

/// Everything needed to draw one picture of the stage, copied so it can be drawn on a
/// background thread while the app carries on.
struct SceneJob {
    struct Ghost {
        let frame: Int
        let alpha: CGFloat
        let later: Bool
    }
    let doc: Doc
    let frame: Int
    let clipToStage: Bool
    let ghosts: [Ghost]
    let tint: Bool
    let tintBefore: CGColor
    let tintAfter: CGColor
    let symbol: String?
    let pasteboard: CGColor
    let transform: CGAffineTransform
    let zoom: CGFloat
    let size: CGSize
    let scale: CGFloat
    let generation: Int

    /// Draws the pasteboard, the stage with its shadow, onion skins and the frame.
    func draw(in ctx: CGContext) {
        ctx.setFillColor(pasteboard)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.saveGState()
        ctx.concatenate(transform)

        let stage = CGRect(x: 0, y: 0, width: doc.width, height: doc.height)
        // A soft drop shadow made of a few see-through bands.
        let unit = 1 / max(zoom, 0.0001)
        for i in 1...4 {
            let spread = CGFloat(i) * 2.5 * unit
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.07))
            ctx.fill(stage.insetBy(dx: -spread, dy: -spread).offsetBy(dx: 0, dy: 2 * unit))
        }
        ctx.setFillColor(doc.background.cgColor)
        ctx.fill(stage)

        ctx.saveGState()
        if clipToStage { ctx.clip(to: stage) }
        for ghost in ghosts {
            ctx.saveGState()
            ctx.setAlpha(max(0.02, min(1, ghost.alpha)))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            Renderer.drawFrame(doc, frame: ghost.frame, in: ctx)
            if tint {
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(ghost.later ? tintAfter : tintBefore)
                ctx.fill(ctx.boundingBoxOfClipPath)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        if let item = doc.item(symbol) {
            // Editing a symbol: the scene is ghosted and the symbol's own art is shown alone.
            ctx.saveGState()
            ctx.setAlpha(0.18)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            Renderer.drawFrame(doc, frame: frame, in: ctx)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            Renderer.drawShapes(item.shapes ?? [], doc: doc, in: ctx)
        } else {
            Renderer.drawFrame(doc, frame: frame, in: ctx)
        }
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
        ctx.setLineWidth(unit)
        ctx.stroke(stage)
        ctx.restoreGState()
    }

    func makeImage() -> CGImage? {
        let w = Int((size.width * scale).rounded())
        let h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(in: ctx)
        return ctx.makeImage()
    }
}

/// Draws stage pictures on a background thread and hands them back on the main thread.
final class SceneWorker {
    private let queue = DispatchQueue(label: "swiftcel.scene", qos: .userInteractive)
    var deliver: ((SceneJob, CGImage?, CFTimeInterval) -> Void)?

    func render(_ job: SceneJob) {
        queue.async {
            let started = CACurrentMediaTime()
            let image = job.makeImage()
            let seconds = CACurrentMediaTime() - started
            DispatchQueue.main.async {
                self.deliver?(job, image, seconds)
            }
        }
    }
}
