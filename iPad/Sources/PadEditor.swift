import UIKit
import UniformTypeIdentifiers

/// The editing screen, laid out like the Mac app: a menu bar along the top, tools down
/// the left, Properties and Library down the right, and the timeline under the stage.
/// Changes are saved as you go.
final class EditorViewController: UIViewController, UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate {
    let state = AppState()
    private var url: URL

    private var canvas: PadCanvasView!
    private var timeline: PadTimelineView!
    private var tools: PadToolPanel!
    private var properties: PadPropertiesPanel!
    private var library: PadLibraryPanel!
    private let topBar = PadSurface(.bar)

    private var menuButtons: [UIButton] = []
    private var rightKeys: [PadKeyButton] = []
    private let titleLabel = UILabel()
    private var saveTimer: Timer?
    private var lastLayerCount = -1
    /// Whether the Properties and Library column is showing. Remembered between launches.
    private var showPanels: Bool = (UserDefaults.standard.object(forKey: "pad.showPanels") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showPanels, forKey: "pad.showPanels") }
    }

    init(doc: Doc, url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        state.load(doc, url: url)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return [.bottom] }

    // MARK: Building

    private func menuButton(_ title: String, _ build: @escaping () -> [UIMenuElement]) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        b.showsMenuAsPrimaryAction = true
        // Built fresh each time it opens, so ticks and greyed-out items are current.
        let live = UIDeferredMenuElement.uncached { done in
            done(build())
        }
        b.menu = UIMenu(title: "", children: [live])
        let w = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .medium)]).width
        b.frame.size = CGSize(width: ceil(w) + 20, height: 34)
        return b
    }

    private func item(_ title: String, _ symbol: String? = nil, ticked: Bool = false, enabled: Bool = true,
                      destructive: Bool = false, _ fn: @escaping () -> Void) -> UIAction {
        var attrs: UIMenuElement.Attributes = []
        if !enabled { attrs.insert(.disabled) }
        if destructive { attrs.insert(.destructive) }
        var image: UIImage? = nil
        if let s = symbol { image = UIImage(systemName: s) }
        return UIAction(title: title, image: image, attributes: attrs, state: ticked ? .on : .off) { _ in
            fn()
        }
    }

    private func group(_ items: [UIMenuElement]) -> UIMenu {
        return UIMenu(title: "", options: .displayInline, children: items)
    }

    private func submenu(_ title: String, _ symbol: String? = nil, _ items: [UIMenuElement]) -> UIMenu {
        var image: UIImage? = nil
        if let s = symbol { image = UIImage(systemName: s) }
        return UIMenu(title: title, image: image, children: items)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.pasteboard
        state.beep = {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        canvas = PadCanvasView(state: state)
        view.addSubview(canvas)

        timeline = PadTimelineView(state: state)
        timeline.onRename = { [weak self] in self?.renameLayer() }
        timeline.onDeleteLayer = { [weak self] in self?.deleteLayer() }
        view.addSubview(timeline)

        tools = PadToolPanel(state: state)
        tools.onPickColor = { [weak self] in self?.pickFillColor() }
        view.addSubview(tools)

        properties = PadPropertiesPanel(state: state)
        properties.onStageResized = { [weak self] in self?.canvas.fit() }
        view.addSubview(properties)

        library = PadLibraryPanel(state: state)
        library.onImport = { [weak self] in self?.importImage() }
        library.onNewSymbol = { [weak self] in self?.convertToSymbol() }
        library.onRename = { [weak self] in self?.renameLibraryItem() }
        view.addSubview(library)

        view.addSubview(topBar)

        // The menu bar
        menuButtons = [
            menuButton("") { [weak self] in self?.appMenu() ?? [] },
            menuButton("File") { [weak self] in self?.fileMenu() ?? [] },
            menuButton("Edit") { [weak self] in self?.editMenu() ?? [] },
            menuButton("View") { [weak self] in self?.viewMenu() ?? [] },
            menuButton("Modify") { [weak self] in self?.modifyMenu() ?? [] },
            menuButton("Timeline") { [weak self] in self?.timelineMenu() ?? [] },
            menuButton("Layer") { [weak self] in self?.layerMenu() ?? [] }
        ]
        // The first menu is the app's own, shown as the wordmark.
        let markH: CGFloat = 17
        let markW = WordmarkView.width(forHeight: markH)
        let appButton = menuButtons[0]
        appButton.frame.size = CGSize(width: markW + 20, height: 34)
        appButton.accessibilityLabel = "SwiftCel"
        let mark = WordmarkView(frame: CGRect(x: 10, y: (34 - markH) / 2, width: markW, height: markH))
        appButton.addSubview(mark)
        for b in menuButtons {
            topBar.addSubview(b)
        }
        rightKeys = [
            PadKeyButton("Undo", symbol: "arrow.uturn.backward", width: 38, height: 28) { [weak self] in self?.state.undo() },
            PadKeyButton("Redo", symbol: "arrow.uturn.forward", width: 38, height: 28) { [weak self] in self?.state.redo() }
        ]
        for k in rightKeys {
            topBar.addSubview(k)
        }
        titleLabel.font = UIFont.boldSystemFont(ofSize: 13)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        topBar.addSubview(titleLabel)

        state.observe { [weak self] in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appLeaving),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let w = view.bounds.width
        let h = view.bounds.height
        let barH: CGFloat = 38

        topBar.frame = CGRect(x: 0, y: 0, width: w, height: safe.top + barH)
        var x = safe.left + 6
        for b in menuButtons {
            b.frame.origin = CGPoint(x: x, y: safe.top + (barH - b.frame.height) / 2)
            x += b.frame.width
        }
        var rx = w - safe.right - 8
        for k in rightKeys.reversed() {
            rx -= k.frame.width
            k.frame.origin = CGPoint(x: rx, y: safe.top + (barH - k.frame.height) / 2)
            rx -= 5
        }
        titleLabel.frame = CGRect(x: x + 6, y: safe.top, width: max(0, rx - x - 12), height: barH)
        titleLabel.isHidden = titleLabel.frame.width < 60

        // Tools and the right-hand column run the full height; the timeline sits under
        // the stage, between them.
        let top = topBar.frame.maxY
        tools.frame = CGRect(x: safe.left, y: top, width: PadToolPanel.width, height: h - top)
        let columnW: CGFloat = showPanels ? PadPropertiesPanel.width : 0
        let columnX = w - safe.right - columnW
        let columnH = h - top
        let libraryH = min(300, max(190, columnH * 0.36))
        properties.isHidden = !showPanels
        library.isHidden = !showPanels
        properties.frame = CGRect(x: columnX, y: top, width: PadPropertiesPanel.width, height: columnH - libraryH)
        library.frame = CGRect(x: columnX, y: h - libraryH, width: PadPropertiesPanel.width, height: libraryH)

        let middleX = tools.frame.maxX
        let middleW = max(0, columnX - middleX)
        let rows = max(3, min(6, state.doc.layers.count + (state.audioName == nil ? 0 : 1)))
        let timelineH = PadTimelineView.height(rows: rows) + safe.bottom
        timeline.frame = CGRect(x: middleX, y: h - timelineH, width: middleW, height: timelineH)
        canvas.frame = CGRect(x: middleX, y: top, width: middleW, height: max(0, h - timelineH - top))
    }

    // MARK: Keeping the bars current

    private func refresh() {
        titleLabel.text = Shelf.title(url)
        titleLabel.textColor = Theme.dim
        for b in menuButtons {
            b.setTitleColor(Theme.text, for: .normal)
        }
        let rowCount = state.doc.layers.count + (state.audioName == nil ? 0 : 1)
        if rowCount != lastLayerCount {
            // The timeline grows and shrinks with the number of layers.
            lastLayerCount = rowCount
            view.setNeedsLayout()
        }
        if state.dirty { scheduleSave() }
    }

    /// Redraws every panel after the theme (or another look setting) changes.
    private func themeChanged() {
        padApplyTheme(to: view.window)
        view.backgroundColor = Theme.pasteboard
        canvas.invalidate()
        state.changed()
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(timeInterval: 2.5, target: self, selector: #selector(saveQuietly),
                                         userInfo: nil, repeats: false)
    }

    /// The timed save. It waits while you are drawing, and writes the file in the
    /// background so the stage never stalls on it.
    @objc private func saveQuietly() {
        if canvas.isBusy {
            scheduleSave()
            return
        }
        guard state.dirty else { return }
        state.dirty = false
        let doc = state.doc
        let target = url
        Shelf.saveInBackground(doc, to: target) { [weak self] ok in
            if !ok { self?.state.dirty = true }
        }
    }

    /// Writes the animation to its file if anything has changed since the last save.
    func saveNow(picture: Bool = true) {
        saveTimer?.invalidate()
        saveTimer = nil
        guard state.dirty || picture else { return }
        if Shelf.save(state.doc, to: url, picture: picture) {
            state.dirty = false
        }
    }

    @objc private func appLeaving() {
        state.stop()
        saveNow()
    }

    private func goHome() {
        state.stop()
        state.exitEdit()
        saveNow()
        navigationController?.popViewController(animated: true)
    }

    // MARK: Menus

    private func appMenu() -> [UIMenuElement] {
        return [
            group([
                item("About SwiftCel", "bolt.fill") { [weak self] in
                    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
                    self?.tell("SwiftCel for iPad", "Version \(version)\nFrame-by-frame animation with a classic brush.")
                },
                item("Preferences\u{2026}", "gearshape") { [weak self] in self?.showPreferences() }
            ]),
            item("Home", "house") { [weak self] in self?.goHome() }
        ]
    }

    private func fileMenu() -> [UIMenuElement] {
        return [
            group([
                item("Home", "house") { [weak self] in self?.goHome() },
                item("Rename\u{2026}", "character.cursor.ibeam") { [weak self] in self?.renameDocument() },
                item("Duplicate", "plus.square.on.square") { [weak self] in
                    guard let self = self else { return }
                    self.saveNow()
                    if Shelf.duplicate(self.url) != nil {
                        self.tell("Duplicated", "The copy is on the Home screen.")
                    }
                }
            ]),
            group([
                item("Stage Settings\u{2026}", "rectangle.dashed") { [weak self] in self?.stageSettings() },
                item("Import Bitmap\u{2026}", "photo") { [weak self] in self?.importImage() }
            ]),
            group([
                item("Import Audio\u{2026}", "waveform") { [weak self] in self?.importAudio() },
                item("Remove Audio", enabled: state.audioName != nil, destructive: true) { [weak self] in
                    self?.state.removeAudio()
                }
            ]),
            submenu("Export", "square.and.arrow.up", [
                item("This Frame as PNG") { [weak self] in self?.export("png") },
                item("This Frame as SVG") { [weak self] in self?.export("svg") },
                item("Animated GIF") { [weak self] in self?.export("gif") },
                item("Video (MP4)") { [weak self] in self?.export("mp4") },
                item("SwiftCel File (.swcel)") { [weak self] in self?.export("swcel") }
            ])
        ]
    }

    private func editMenu() -> [UIMenuElement] {
        let s = state
        let has = s.hasSelection
        return [
            group([
                item("Undo", "arrow.uturn.backward") { s.undo() },
                item("Redo", "arrow.uturn.forward") { s.redo() }
            ]),
            group([
                item("Cut", "scissors", enabled: has) {
                    s.copySelection()
                    s.deleteSelection()
                },
                item("Copy", "doc.on.doc", enabled: has) { s.copySelection() },
                item("Paste in Place", "doc.on.clipboard", enabled: !s.clipboard.isEmpty) { s.paste() },
                item("Delete", "trash", enabled: has, destructive: true) { s.deleteSelection() }
            ]),
            group([
                item("Select All") {
                    if !s.tool.keepsSelection { s.tool = .select }
                    s.selectAll()
                    s.changed()
                },
                item("Deselect All", enabled: has) {
                    s.deselect()
                    s.changed()
                },
                item("Tap Adds to Selection", ticked: canvas.addToSelection) { [weak self] in
                    guard let c = self?.canvas else { return }
                    c.addToSelection = !c.addToSelection
                }
            ])
        ]
    }

    private func viewMenu() -> [UIMenuElement] {
        let s = state
        return [
            group([
                item("Fit Stage on Screen", "arrow.up.left.and.arrow.down.right") { [weak self] in self?.canvas.fit() },
                item("Actual Size (100%)") { [weak self] in self?.canvas.setZoom(1) },
                item("Zoom In", "plus.magnifyingglass") { [weak self] in self?.canvas.zoomCentered(by: 1.5) },
                item("Zoom Out", "minus.magnifyingglass") { [weak self] in self?.canvas.zoomCentered(by: 1 / 1.5) },
                item("Reset Rotation", "arrow.uturn.left.circle", enabled: canvas.angle != 0) { [weak self] in
                    self?.canvas.resetRotation()
                }
            ]),
            group([
                item("Properties and Library", ticked: showPanels) { [weak self] in
                    guard let self = self else { return }
                    self.showPanels = !self.showPanels
                    self.view.setNeedsLayout()
                },
                item("Onion Skin", ticked: s.onionSkin) {
                    s.onionSkin = !s.onionSkin
                    s.changed()
                },
                item("Show Only the Stage", ticked: s.clipToStage) {
                    s.clipToStage = !s.clipToStage
                    s.changed()
                },
                item("Draw with a Finger", ticked: PadPrefs.fingerDraws) {
                    PadPrefs.fingerDraws = !PadPrefs.fingerDraws
                },
                item("Show Performance", ticked: canvas.showStats) { [weak self] in
                    guard let c = self?.canvas else { return }
                    c.showStats = !c.showStats
                }
            ])
        ]
    }

    private func modifyMenu() -> [UIMenuElement] {
        let s = state
        let has = s.hasSelection
        var symbolRef: String? = nil
        let shapes = s.currentShapes
        for i in s.selection.sorted() where shapes.indices.contains(i) {
            if s.doc.item(shapes[i].ref)?.isSymbol == true {
                symbolRef = shapes[i].ref
                break
            }
        }
        var symbols: [UIMenuElement] = [
            item("Convert to Symbol\u{2026}", enabled: has && s.editingSymbol == nil) { [weak self] in self?.convertToSymbol() }
        ]
        if let ref = symbolRef {
            symbols.append(item("Edit Symbol") { s.enterEdit(ref) })
            symbols.append(item("Break Apart") { s.breakApart() })
        }
        if s.editingSymbol != nil {
            symbols.append(item("Finish Editing Symbol", "checkmark") { s.exitEdit() })
        }
        return [
            group(symbols),
            group([
                item("Bring to Front", enabled: has) { s.arrangeSelection(toFront: true) },
                item("Send to Back", enabled: has) { s.arrangeSelection(toFront: false) }
            ]),
            group([
                item("Flip Horizontal", enabled: has) { s.flipSelection(horizontal: true) },
                item("Flip Vertical", enabled: has) { s.flipSelection(horizontal: false) },
                item("Rotate 90\u{00B0} Right", enabled: has) { s.rotateSelection(degrees: 90) },
                item("Rotate 90\u{00B0} Left", enabled: has) { s.rotateSelection(degrees: -90) }
            ])
        ]
    }

    private func timelineMenu() -> [UIMenuElement] {
        let s = state
        let ease = s.currentTweenEase
        var tweens: [UIMenuElement] = []
        if ease == nil {
            tweens.append(item("Create Tween") { s.setTween(ease: "linear") })
        } else {
            for e in Tweening.eases {
                let id = e.id
                tweens.append(item(e.title, ticked: ease == id) { s.setTween(ease: id) })
            }
            tweens.append(item("Remove Tween", destructive: true) { s.setTween(ease: nil) })
        }
        let many = s.frameTargets.count > 1
        return [
            group([
                item(s.isPlaying ? "Stop" : "Play", s.isPlaying ? "stop.fill" : "play.fill") { s.togglePlay() },
                item("Loop Playback", "repeat", ticked: s.loopPlayback) {
                    s.loopPlayback = !s.loopPlayback
                    s.changed()
                },
                item("Frame Rate\u{2026}", "speedometer") { [weak self] in self?.askFrameRate() }
            ]),
            group([
                item(many ? "Insert Frames" : "Insert Frame") { s.insertFrame() },
                item(many ? "Remove \(s.frameTargets.count) Frames" : "Remove Frame") { s.removeFrame() }
            ]),
            group([
                item("Insert Keyframe") { s.insertKeyframe(blank: false) },
                item("Insert Blank Keyframe") { s.insertKeyframe(blank: true) },
                item("Clear Keyframe") { s.clearKeyframe() }
            ]),
            group(tweens),
            group([
                item("Copy Frame Art") {
                    s.selection.removeAll()
                    s.copySelection()
                },
                item("Paste Art Here", enabled: !s.clipboard.isEmpty) { s.paste() }
            ])
        ]
    }

    private func layerMenu() -> [UIMenuElement] {
        let s = state
        let count = s.doc.layers.count
        let r = s.layer
        let has = s.doc.layers.indices.contains(r)
        return [
            group([
                item("New Layer", "plus") { s.addLayer() },
                item("Rename Layer\u{2026}", "character.cursor.ibeam") { [weak self] in self?.renameLayer() },
                item("Delete Layer", "trash", enabled: count > 1, destructive: true) { [weak self] in self?.deleteLayer() }
            ]),
            group([
                item("Move Layer Up", "arrow.up", enabled: r > 0) { s.moveLayer(by: -1) },
                item("Move Layer Down", "arrow.down", enabled: r < count - 1) { s.moveLayer(by: 1) }
            ]),
            group([
                item(has && !s.doc.layers[r].visible ? "Show Layer" : "Hide Layer", enabled: has) { s.toggleVisible(r) },
                item(has && s.doc.layers[r].locked ? "Unlock Layer" : "Lock Layer", enabled: has) { s.toggleLocked(r) }
            ]),
            group([
                item("Clipping Mask", "square.on.square.dashed", ticked: has && s.doc.layers[r].isClipped,
                     enabled: has && r < count - 1) { s.toggleClip(r) },
                item("Reference Layer", "scope", ticked: has && s.doc.layers[r].isReference, enabled: has) {
                    s.toggleReference(r)
                }
            ])
        ]
    }

    // MARK: Menu commands

    private func renameDocument() {
        ask("Rename Animation", value: Shelf.title(url), button: "Rename") { [weak self] name in
            guard let self = self else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != Shelf.title(self.url) else { return }
            self.saveNow()
            if let moved = Shelf.rename(self.url, to: trimmed) {
                self.url = moved
                self.state.fileURL = moved
                self.refresh()
            }
        }
    }

    private func stageSettings() {
        askStage(title: "Stage Settings", button: "Apply", name: nil, doc: state.doc) { [weak self] _, w, h, fps in
            guard let self = self else { return }
            self.state.applyDocumentSettings(width: w, height: h, fps: fps, background: self.state.doc.background)
            self.canvas.fit()
        }
    }

    private func askFrameRate() {
        ask("Frame Rate", detail: "Frames per second, from 1 to 60.", value: String(state.doc.fps), button: "Set",
            numbers: true) { [weak self] text in
            guard let self = self, let fps = Int(text) else { return }
            self.state.setFPS(fps)
            self.state.changed()
        }
    }

    private func renameLayer() {
        guard state.doc.layers.indices.contains(state.layer) else { return }
        ask("Rename Layer", value: state.doc.layers[state.layer].name, button: "Rename") { [weak self] name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self?.state.renameLayer(trimmed) }
        }
    }

    private func deleteLayer() {
        guard state.doc.layers.count > 1, state.doc.layers.indices.contains(state.layer) else {
            state.beep()
            return
        }
        let name = state.doc.layers[state.layer].name
        let sure = UIAlertController(title: "Delete layer \u{201C}\(name)\u{201D}?", message: "You can undo this.",
                                     preferredStyle: .alert)
        sure.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        sure.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.state.deleteLayer()
        })
        present(sure, animated: true, completion: nil)
    }

    private func convertToSymbol() {
        guard state.hasSelection else { return }
        ask("Convert to Symbol", detail: "The selected art becomes a reusable symbol in the library.",
            value: "Symbol \(state.doc.items.count + 1)", button: "Convert") { [weak self] name in
            self?.state.convertSelectionToSymbol(named: name)
        }
    }

    private func renameLibraryItem() {
        guard let picked = state.doc.item(state.selectedItem) else {
            state.beep()
            return
        }
        ask("Rename", value: picked.name, button: "Rename") { [weak self] name in
            self?.state.renameItem(picked.id, to: name)
        }
    }

    /// The colour picker behind the swatch under the tools.
    private func pickFillColor() {
        let picker = UIColorPickerViewController()
        picker.selectedColor = state.color.uiColor
        picker.supportsAlpha = true
        picker.title = "Fill colour"
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = tools
        picker.popoverPresentationController?.sourceRect = CGRect(x: tools.bounds.midX, y: tools.bounds.height * 0.6, width: 1, height: 1)
        present(picker, animated: true, completion: nil)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor,
                                   continuously: Bool) {
        let c = RGBA(color)
        if padSameColor(c, state.color) { return }
        state.color = c
        if state.hasSelection {
            state.recolorSelection()
        } else {
            state.changed()
        }
    }

    // MARK: Import and export

    private var pickingAudio = false

    private func importImage() {
        pickingAudio = false
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.image], asCopy: true)
        picker.delegate = self
        present(picker, animated: true, completion: nil)
    }

    private func importAudio() {
        pickingAudio = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio], asCopy: true)
        picker.delegate = self
        present(picker, animated: true, completion: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let picked = urls.first else { return }
        if pickingAudio {
            // The sound is copied into the app's Audio folder, so it stays with the animation.
            guard let kept = Shelf.keepAudio(picked) else {
                tell("Couldn't import that sound", "There may not be enough free space on this iPad.")
                return
            }
            if !state.importAudio(kept) {
                tell("Couldn't import that sound", "SwiftCel can import MP3, M4A, AAC, WAV and AIFF files.")
            }
            view.setNeedsLayout()
            return
        }
        if state.editingSymbol != nil { state.exitEdit() }
        if !state.importBitmap(picked) {
            tell("Couldn't import that image", "SwiftCel can import PNG, JPEG, GIF, TIFF and HEIC pictures.")
        }
    }

    private func showPreferences() {
        let prefs = PadPreferencesViewController()
        prefs.onChange = { [weak self] in self?.themeChanged() }
        let sheet = UINavigationController(rootViewController: prefs)
        sheet.modalPresentationStyle = .formSheet
        present(sheet, animated: true, completion: nil)
    }

    private func export(_ kind: String) {
        state.stop()
        saveNow()
        let doc = state.doc
        let frame = state.frame
        let audio = state.audioURL
        let name = Shelf.title(url)
        let source = url
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("SwiftCel Export", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let wait = UIAlertController(title: "Exporting…", message: kind == "mp4" || kind == "gif" ? "Rendering every frame." : nil,
                                     preferredStyle: .alert)
        present(wait, animated: true) {
            DispatchQueue.global(qos: .userInitiated).async {
                var out: URL? = nil
                switch kind {
                case "png":
                    let target = folder.appendingPathComponent(String(format: "%@_%04d.png", name, frame + 1))
                    if let img = Renderer.image(doc: doc, frame: frame), let data = Renderer.pngData(img),
                       (try? data.write(to: target)) != nil {
                        out = target
                    }
                case "svg":
                    let target = folder.appendingPathComponent(String(format: "%@_%04d.svg", name, frame + 1))
                    if (try? Renderer.svg(doc: doc, frame: frame).write(to: target, atomically: true, encoding: .utf8)) != nil {
                        out = target
                    }
                case "gif":
                    let target = folder.appendingPathComponent(name + ".gif")
                    if Renderer.writeGIF(doc: doc, to: target) { out = target }
                case "mp4":
                    let target = folder.appendingPathComponent(name + ".mp4")
                    if Renderer.writeVideo(doc: doc, audio: audio, to: target) { out = target }
                default:
                    out = source
                }
                DispatchQueue.main.async { [weak self] in
                    wait.dismiss(animated: true) {
                        guard let self = self else { return }
                        guard let file = out else {
                            self.tell("The export didn't work", "There may not be enough free space on this iPad.")
                            return
                        }
                        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                        sheet.popoverPresentationController?.sourceView = self.topBar
                        sheet.popoverPresentationController?.sourceRect = CGRect(x: 80, y: self.topBar.bounds.height - 4, width: 1, height: 1)
                        self.present(sheet, animated: true, completion: nil)
                    }
                }
            }
        }
    }
}
