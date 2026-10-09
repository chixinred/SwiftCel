import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    var window: NSWindow!
    var canvas: CanvasView!
    var timeline: TimelineView!
    var tools: ToolPanel!
    var props: PropertiesPanel!
    var workspace: WorkspaceView!
    var library: LibraryPanel!
    private var themeEditor: ThemeEditor?
    private var onionEditor: OnionEditor?
    private var graphPanel: NSPanel?
    private var storyboardPanel: NSPanel?
    private var prefsPanel: NSPanel?
    private var homeWindow: NSWindow?
    private var homeView: HomeView?
    private var prefsView: PrefsView?
    private let recentMenu = NSMenu(title: "Open Recent")
    private var splashWindow: NSWindow?
    private let themeMenu = NSMenu(title: "Theme")
    /// A document Finder asked us to open before the window existed.
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSEvent.isMouseCoalescingEnabled = false   // full-rate pen and mouse samples
        NSColorPanel.shared.showsAlpha = true
        Theme.load()
        state.beep = { NSSound.beep() }
        buildWindow()
        buildMenus()
        state.observe { [weak self] in
            self?.updateTitle()
        }
        updateTitle()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        let openedFile = pendingURL != nil
        if let url = pendingURL {
            pendingURL = nil
            openFile(url)
        }
        applyPrefs()
        if Prefs.showHome && !openedFile {
            showHome()
        }
        if Prefs.showSplash {
            showSplash(autoClose: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return confirmDiscard() ? .terminateNow : .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return confirmDiscard()
    }

    // MARK: Window

    private func buildWindow() {
        let w: CGFloat = 1280
        let h: CGFloat = 800

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: Theme.isDark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.panelDark
        window.center()

        timeline = TimelineView(state: state)
        timeline.onRename = { [weak self] in
            self?.renameLayer()
        }
        timeline.onEditCurve = { [weak self] in
            self?.showGraphEditor()
        }
        tools = ToolPanel(state: state)
        props = PropertiesPanel(state: state)
        canvas = CanvasView(state: state)
        canvas.onConvertToSymbol = { [weak self] in
            self?.convertToSymbol()
        }
        props.onOnionSettings = { [weak self] in
            self?.showOnionSettings()
        }
        props.onStageResized = { [weak self] in
            guard let self = self else { return }
            self.canvas.fit()
            self.window.makeFirstResponder(self.canvas)
        }
        library = LibraryPanel(state: state)
        library.onImport = { [weak self] in
            self?.importBitmap()
        }
        library.onNewSymbol = { [weak self] in
            self?.convertToSymbol()
        }
        library.onRename = { [weak self] in
            self?.renameLibraryItem()
        }

        workspace = WorkspaceView(frame: NSRect(x: 0, y: 0, width: w, height: h),
                                  canvas: canvas, tools: tools, props: props, timeline: timeline,
                                  library: library)
        window.contentView = workspace

        // Dragging a panel by its header strip moves it to the other side of the window.
        connect(tools.headerDrag, .tools)
        connect(props.header.headerDrag, .props)
        connect(library.header.headerDrag, .props)
        connect(timeline.headerDrag, .timeline)
    }

    private func connect(_ drag: HeaderDrag, _ kind: PanelKind) {
        drag.onDrag = { [weak self] p in
            self?.workspace.dragging(kind, at: p)
        }
        drag.onDrop = { [weak self] p in
            self?.workspace.drop(kind, at: p)
        }
    }

    private func updateTitle() {
        let name = state.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        window.title = "\(name) - SwiftCel"
        window.isDocumentEdited = state.dirty
    }

    // MARK: Menus

    private func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                      _ fn: @escaping () -> Void) -> NSMenuItem {
        let a = Action(fn)
        let it = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = a
        it.representedObject = a   // keeps the action alive
        return it
    }

    private func fkey(_ code: Int) -> String {
        guard let u = UnicodeScalar(code) else { return "" }
        return String(Character(u))
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(title: title)
        for it in items {
            m.addItem(it)
        }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = m
        return holder
    }

    private func buildMenus() {
        let main = NSMenu()
        let s = state

        let quit = NSMenuItem(title: "Quit SwiftCel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let hide = NSMenuItem(title: "Hide SwiftCel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        main.addItem(menu("SwiftCel", [
            item("About SwiftCel") { [weak self] in self?.showSplash(autoClose: false) },
            item("Settings…", ",") { [weak self] in self?.showPreferences() },
            item("Keyboard Shortcuts", "/") { [weak self] in self?.shortcuts() },
            NSMenuItem.separator(),
            hide,
            NSMenuItem.separator(),
            quit
        ]))

        let recentHolder = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentHolder.submenu = recentMenu
        rebuildRecentMenu()
        main.addItem(menu("File", [
            item("Home", "h", [.command, .shift]) { [weak self] in self?.showHome() },
            NSMenuItem.separator(),
            item("New…", "n") { [weak self] in self?.newDocument() },
            item("Open…", "o") { [weak self] in self?.openDocument() },
            recentHolder,
            NSMenuItem.separator(),
            item("Save", "s") { [weak self] in self?.saveDocument(forceDialog: false) },
            item("Save As…", "s", [.command, .shift]) { [weak self] in self?.saveDocument(forceDialog: true) },
            NSMenuItem.separator(),
            item("Import Bitmap…", "r") { [weak self] in self?.importBitmap() },
            item("Import Audio…", "i", [.command, .shift]) { [weak self] in self?.importAudio() },
            item("Remove Audio") { s.removeAudio() },
            NSMenuItem.separator(),
            item("Export Video…", "e", [.command, .option]) { [weak self] in self?.exportVideo() },
            item("Export Animated GIF…", "e", [.command, .shift]) { [weak self] in self?.exportGIF() },
            item("Export PNG Sequence…") { [weak self] in self?.exportPNGs() },
            item("Export Frame as SVG…") { [weak self] in self?.exportSVG() },
            NSMenuItem.separator(),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        ]))

        main.addItem(menu("Edit", [
            item("Undo", "z") { [weak self] in
                if self?.sendToText(Selector(("undo:"))) == true { return }
                s.undo()
            },
            item("Redo", "z", [.command, .shift]) { [weak self] in
                if self?.sendToText(Selector(("redo:"))) == true { return }
                s.redo()
            },
            NSMenuItem.separator(),
            item("Cut", "x") { [weak self] in
                if self?.sendToText(#selector(NSText.cut(_:))) == true { return }
                s.copySelection()
                s.deleteSelection()
            },
            item("Copy", "c") { [weak self] in
                if self?.sendToText(#selector(NSText.copy(_:))) == true { return }
                s.copySelection()
            },
            item("Paste in Place", "v") { [weak self] in
                if self?.sendToText(#selector(NSText.paste(_:))) == true { return }
                s.paste()
            },
            item("Delete") { s.deleteSelection() },
            NSMenuItem.separator(),
            item("Select All", "a") { [weak self] in
                if self?.sendToText(#selector(NSText.selectAll(_:))) == true { return }
                s.selectAll()
            },
            item("Deselect All", "a", [.command, .shift]) { s.deselect() }
        ]))

        main.addItem(menu("View", [
            item("Zoom In", "=") { [weak self] in self?.canvas.zoomCentered(by: 1.25) },
            item("Zoom Out", "-") { [weak self] in self?.canvas.zoomCentered(by: 0.8) },
            item("Actual Size", "1") { [weak self] in self?.canvas.setZoom(1) },
            item("Fit Stage in Window", "0") { [weak self] in self?.canvas.fit() },
            NSMenuItem.separator(),
            item("Onion Skin", "o", [.command, .option]) { s.onionSkin.toggle(); s.changed() },
            item("Onion Skin Settings…") { [weak self] in self?.showOnionSettings() },
            NSMenuItem.separator(),
            item("Storyboard…", "b", [.command, .shift]) { [weak self] in self?.showStoryboard() },
            item("Show Only the Stage", "k", [.command, .shift]) { s.clipToStage.toggle(); s.changed() }
        ]))

        main.addItem(menu("Workspace", [
            item("Show or Hide Tools", "1", [.command, .option]) { [weak self] in self?.workspace.toggleVisible(.tools) },
            item("Show or Hide Properties", "2", [.command, .option]) { [weak self] in self?.workspace.toggleVisible(.props) },
            item("Show or Hide Timeline", "3", [.command, .option]) { [weak self] in self?.workspace.toggleVisible(.timeline) },
            NSMenuItem.separator(),
            item("Move Tools to Other Side") { [weak self] in self?.workspace.swapSide(.tools) },
            item("Move Properties to Other Side") { [weak self] in self?.workspace.swapSide(.props) },
            item("Move Timeline to Top or Bottom") { [weak self] in self?.workspace.swapSide(.timeline) },
            NSMenuItem.separator(),
            item("Reset Workspace") { [weak self] in self?.workspace.reset() }
        ]))

        main.addItem(menu("Modify", [
            item("Convert to Symbol…", fkey(NSF8FunctionKey), []) { [weak self] in self?.convertToSymbol() },
            item("Edit Selected Symbol", "e") { [weak self] in self?.editSelectedSymbol() },
            item("Finish Editing Symbol") { s.exitEdit() },
            item("Break Apart", "b") { s.breakApart() },
            NSMenuItem.separator(),
            item("Flip Horizontal") { s.flipSelection(horizontal: true) },
            item("Flip Vertical") { s.flipSelection(horizontal: false) },
            item("Rotate 90° Right", "]", [.command, .shift]) { s.rotateSelection(degrees: 90) },
            item("Rotate 90° Left", "[", [.command, .shift]) { s.rotateSelection(degrees: -90) },
            NSMenuItem.separator(),
            item("Document Settings…", "j") { [weak self] in self?.documentSettings() },
            item("Use Fill Colour as Background") {
                s.checkpoint()
                s.doc.background = RGBA(r: s.color.r, g: s.color.g, b: s.color.b, a: 1)
                s.changed()
            }
        ]))

        main.addItem(menu("Timeline", [
            item("Insert Frame", fkey(NSF5FunctionKey), []) { s.insertFrame() },
            item("Remove Frame", fkey(NSF5FunctionKey), [.shift]) { s.removeFrame() },
            NSMenuItem.separator(),
            item("Insert Keyframe", fkey(NSF6FunctionKey), []) { s.insertKeyframe(blank: false) },
            item("Insert Blank Keyframe", fkey(NSF7FunctionKey), []) { s.insertKeyframe(blank: true) },
            item("Clear Keyframe", fkey(NSF6FunctionKey), [.shift]) { s.clearKeyframe() },
            NSMenuItem.separator(),
            item("Create Tween", "t", [.command, .option]) { s.setTween(ease: s.currentTweenEase ?? "linear") },
            item("Remove Tween") { s.setTween(ease: nil) },
            item("Graph Editor…", "g", [.command, .option]) { [weak self] in self?.showGraphEditor() },
            item("Tween Easing: Linear") { s.setTween(ease: "linear") },
            item("Tween Easing: Ease In") { s.setTween(ease: "in") },
            item("Tween Easing: Ease Out") { s.setTween(ease: "out") },
            item("Tween Easing: Ease In and Out") { s.setTween(ease: "inOut") },
            NSMenuItem.separator(),
            item("Play / Stop   (Return)") { s.togglePlay() },
            item("Loop Playback On or Off", "l") { s.loopPlayback.toggle(); s.changed() },
            item("Previous Frame   (,)") { s.stop(); s.goto(s.frame - 1) },
            item("Next Frame   (.)") { s.stop(); s.goto(s.frame + 1) },
            item("Go to First Frame", fkey(NSHomeFunctionKey), []) { s.stop(); s.goto(0) }
        ]))

        main.addItem(menu("Layer", [
            item("New Layer", "l", [.command, .shift]) { s.addLayer() },
            item("Delete Layer") { s.deleteLayer() },
            item("Rename Layer…") { [weak self] in self?.renameLayer() },
            NSMenuItem.separator(),
            item("Move Layer Up") { s.moveLayer(by: -1) },
            item("Move Layer Down") { s.moveLayer(by: 1) },
            NSMenuItem.separator(),
            item("Clipping Mask On or Off") { s.toggleClip(s.layer) },
            item("Reference Layer On or Off") { s.toggleReference(s.layer) }
        ]))

        let themeHolder = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeHolder.submenu = themeMenu
        main.addItem(themeHolder)
        rebuildThemeMenu()

        let windowMenu = menu("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        ])
        main.addItem(windowMenu)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu.submenu
    }

    private func showGraphEditor() {
        if graphPanel == nil {
            let size = GraphView.size
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                                styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Graph Editor"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.contentView = GraphView(state: state)
            panel.center()
            graphPanel = panel
        }
        graphPanel?.makeKeyAndOrderFront(nil)
    }

    private func showOnionSettings() {
        if onionEditor == nil {
            onionEditor = OnionEditor(state: state)
        }
        onionEditor?.show()
    }

    /// When the cursor is in a text box (a caption, a name), the Edit commands should act
    /// on the text there rather than on the artwork. Returns true if they did.
    private func sendToText(_ action: Selector) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    // MARK: Storyboard

    private func showStoryboard() {
        if storyboardPanel == nil {
            let view = StoryboardView(state: state)
            view.onExport = { [weak self] in
                self?.exportBoardSheet()
            }
            let panel = NSPanel(contentRect: view.frame,
                                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Storyboard"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.minSize = NSSize(width: 620, height: 320)
            panel.contentView = view
            panel.center()
            storyboardPanel = panel
        }
        storyboardPanel?.makeKeyAndOrderFront(nil)
    }

    private func exportBoardSheet() {
        guard !state.boardPanels.isEmpty else {
            message("No storyboard yet", "Add some panels first.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = baseName + " storyboard.pdf"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let url = chosen.pathExtension.lowercased() == "pdf" ? chosen : chosen.appendingPathExtension("pdf")
        if BoardSheet.writePDF(state: state, to: url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            message("Export failed", "The storyboard sheet couldn't be written.")
        }
    }

    // MARK: Themes

    private func rebuildThemeMenu() {
        themeMenu.removeAllItems()
        let current = Theme.palette
        for (i, p) in Theme.all.enumerated() {
            if i == Palette.builtIn.count {
                themeMenu.addItem(NSMenuItem.separator())
            }
            let entry = item(p.name, "", []) { [weak self] in
                Theme.palette = p
                Theme.persist()
                self?.themeChanged()
            }
            entry.state = p == current ? .on : .off
            themeMenu.addItem(entry)
        }
        themeMenu.addItem(NSMenuItem.separator())
        themeMenu.addItem(item("Customize Theme…", "t", [.command, .shift]) { [weak self] in
            self?.showThemeEditor()
        })
    }

    private func showThemeEditor() {
        if themeEditor == nil {
            themeEditor = ThemeEditor { [weak self] in
                self?.themeChanged(fromEditor: true)
            }
        }
        themeEditor?.show()
    }

    private func redrawAll(_ view: NSView) {
        view.needsDisplay = true
        for sub in view.subviews {
            redrawAll(sub)
        }
    }

    /// Applies the palette in use to the window and repaints everything.
    private func themeChanged(fromEditor: Bool = false) {
        window.appearance = NSAppearance(named: Theme.isDark ? .darkAqua : .aqua)
        window.backgroundColor = Theme.panelDark
        if let content = window.contentView {
            redrawAll(content)
        }
        state.changed()
        rebuildThemeMenu()
        if !fromEditor {
            themeEditor?.sync()
        }
    }

    // MARK: Dialogs

    private func prompt(_ title: String, detail: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let result = alert.runModal()
        window.makeFirstResponder(canvas)
        return result == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    /// Shows the splash art with the credits. At launch it closes itself after a few
    /// seconds; from the About menu it stays until clicked.
    private func showSplash(autoClose: Bool) {
        dismissSplash()
        let view = SplashView(scale: 0.72)
        view.hint = autoClose ? "Click anywhere to begin" : "Click to close"
        let splash = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        splash.isReleasedWhenClosed = false
        splash.level = .floating
        splash.hasShadow = true
        splash.contentView = view
        splash.center()
        view.onDismiss = { [weak self] in
            self?.dismissSplash()
        }
        splash.orderFrontRegardless()
        splashWindow = splash
        if autoClose {
            let t = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
                self?.dismissSplash()
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func dismissSplash() {
        splashWindow?.orderOut(nil)
        splashWindow = nil
    }

    private func shortcuts() {
        message("SwiftCel", "A small frame-by-frame animation tool with an old-school smoothing brush.\n\nV select, Q transform, L lasso, B brush, Y pencil, E eraser, K paint bucket, I eyedropper, N line, R rectangle, O oval, H hand.\n[ and ] change brush size. Space-drag pans, pinch or Command-scroll zooms.\nF5 frame, F6 keyframe, F7 blank keyframe, comma and period step frames, Return plays.")
    }

    private func confirmDiscard() -> Bool {
        if !state.dirty { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocument(forceDialog: false)
        case .alertSecondButtonReturn:
            return false
        default:
            state.dirty = false   // discard confirmed; don't ask again on quit
            return true
        }
    }

    private func renameLayer() {
        guard state.doc.layers.indices.contains(state.layer) else { return }
        let current = state.doc.layers[state.layer].name
        if let name = prompt("Rename Layer", detail: "", value: current) {
            state.renameLayer(name)
        }
    }

    /// Shows the document form (used for New and for Document Settings) and returns what
    /// was entered, or nil if it was cancelled.
    private func askDocumentSettings(title: String, button: String, doc: Doc)
        -> (width: Int, height: Int, fps: Int, background: RGBA)? {
        let form = DocumentSetupView(doc: doc)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Stage size is in pixels (16 to 8192). Frame rate is 1 to 60."
        alert.accessoryView = form
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let result = form.result else {
            message("Those numbers won't work", "Stage width and height must be between 16 and 8192, and the frame rate between 1 and 60.")
            return nil
        }
        return result
    }

    private func documentSettings() {
        guard let r = askDocumentSettings(title: "Document Settings", button: "Apply", doc: state.doc) else { return }
        state.applyDocumentSettings(width: r.width, height: r.height, fps: r.fps, background: r.background)
        canvas.fit()
        window.makeFirstResponder(canvas)
    }

    // MARK: Settings

    private func showPreferences() {
        if prefsPanel == nil {
            let view = PrefsView()
            view.onChange = { [weak self] in
                self?.applyPrefs()
            }
            let panel = NSPanel(contentRect: view.frame, styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "SwiftCel Settings"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.contentView = view
            panel.center()
            prefsView = view
            prefsPanel = panel
        }
        prefsView?.sync()
        prefsPanel?.makeKeyAndOrderFront(nil)
    }

    /// Puts the current preferences into effect.
    private func applyPrefs() {
        let scale = Prefs.uiScale
        workspace.uiScale = scale
        // Keep the smallest window size usable at this scale, but never bigger than the screen.
        var least = NSSize(width: 760 * scale, height: 520 * scale)
        if let screen = window.screen ?? NSScreen.main {
            least.width = min(least.width, screen.visibleFrame.width * 0.9)
            least.height = min(least.height, screen.visibleFrame.height * 0.9)
        }
        window.minSize = least
        if let content = window.contentView {
            redrawAll(content)
        }
        state.changed()
    }

    // MARK: Home

    /// The Home screen: New Animation, and every animation SwiftCel has opened or saved.
    private func showHome() {
        if homeWindow == nil {
            let view = HomeView()
            view.onNew = { [weak self] in
                self?.homeWindow?.orderOut(nil)
                self?.window.makeKeyAndOrderFront(nil)
                self?.newDocument()
            }
            view.onOpen = { [weak self] path in
                self?.homeWindow?.orderOut(nil)
                self?.window.makeKeyAndOrderFront(nil)
                self?.openRecent(path)
            }
            view.onOpenOther = { [weak self] in
                self?.homeWindow?.orderOut(nil)
                self?.window.makeKeyAndOrderFront(nil)
                self?.openDocument()
            }
            view.onChange = { [weak self] in
                self?.rebuildRecentMenu()
            }
            let home = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable],
                                backing: .buffered, defer: false)
            home.title = "SwiftCel Home"
            home.isReleasedWhenClosed = false
            home.minSize = NSSize(width: 480, height: 330)
            home.appearance = NSAppearance(named: Theme.isDark ? .darkAqua : .aqua)
            home.contentView = view
            home.center()
            homeView = view
            homeWindow = home
        }
        homeWindow?.appearance = NSAppearance(named: Theme.isDark ? .darkAqua : .aqua)
        homeView?.reload()
        homeWindow?.makeKeyAndOrderFront(nil)
    }

    /// Records an animation as known to Home, with a fresh picture of its first frame.
    private func remember(_ url: URL) {
        Prefs.noteRecent(url)
        Thumbnails.save(doc: state.doc, for: url.path)
        rebuildRecentMenu()
        homeView?.reload()
    }

    // MARK: Recent files

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let paths = Array(Prefs.recentFiles.prefix(10))
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let entry = item(url.lastPathComponent, "", []) { [weak self] in
                self?.openRecent(path)
            }
            entry.toolTip = path
            recentMenu.addItem(entry)
        }
        if paths.isEmpty {
            let empty = NSMenuItem(title: "No Recent Animations", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            recentMenu.addItem(NSMenuItem.separator())
            recentMenu.addItem(item("Clear Menu", "", []) { [weak self] in
                Prefs.recentFiles = []
                self?.rebuildRecentMenu()
            })
        }
    }

    private func openRecent(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            message("That file has moved or been deleted", path)
            Prefs.forgetRecent(path)
            rebuildRecentMenu()
            return
        }
        guard confirmDiscard() else { return }
        openFile(URL(fileURLWithPath: path))
    }

    // MARK: Files

    private func newDocument() {
        guard confirmDiscard() else { return }
        guard let r = askDocumentSettings(title: "New Animation", button: "Create", doc: Doc()) else { return }
        var doc = Doc()
        doc.width = CGFloat(r.width)
        doc.height = CGFloat(r.height)
        doc.fps = r.fps
        doc.background = r.background
        state.load(doc, url: nil)
        canvas.fit()
        window.makeFirstResponder(canvas)
    }

    private func openDocument() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url)
    }

    private func openFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let doc = try JSONDecoder().decode(Doc.self, from: data)
            state.load(doc, url: url)
            canvas.fit()
            remember(url)
        } catch {
            message("Couldn't open that file", "It doesn't look like a SwiftCel document.")
        }
    }

    /// Double-clicking a .swcel file in Finder lands here.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil {
            pendingURL = url
            return
        }
        if confirmDiscard() {
            openFile(url)
        }
    }

    @discardableResult
    private func saveDocument(forceDialog saveAs: Bool) -> Bool {
        var url = state.fileURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (state.fileURL?.lastPathComponent ?? "Untitled.swcel")
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            url = chosen
        }
        guard let target = url else { return false }
        do {
            let data = try JSONEncoder().encode(state.doc)
            try data.write(to: target)
            state.fileURL = target
            state.dirty = false
            state.changed()
            remember(target)
            return true
        } catch {
            message("Couldn't save", error.localizedDescription)
            return false
        }
    }

    private func importBitmap() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose image files (PNG, JPEG, GIF, TIFF, HEIC)."
        guard panel.runModal() == .OK else { return }
        var failed: [String] = []
        for url in panel.urls {
            if !state.importBitmap(url) {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            message("Couldn't import", failed.joined(separator: ", ") + "\n\nThose files aren't images SwiftCel can read.")
        }
        window.makeFirstResponder(canvas)
    }

    private func convertToSymbol() {
        guard state.hasSelection else {
            message("Nothing selected", "Select the art you want to turn into a symbol first (V, then click or drag around it).")
            return
        }
        let symbolCount = state.doc.items.filter { $0.isSymbol }.count
        let suggestion = "Symbol \(symbolCount + 1)"
        if let name = prompt("Convert to Symbol", detail: "Name for the new symbol.", value: suggestion) {
            state.convertSelectionToSymbol(named: name)
        }
    }

    private func editSelectedSymbol() {
        let shapes = state.currentShapes
        for i in state.selection.sorted() where shapes.indices.contains(i) {
            if state.doc.item(shapes[i].ref)?.isSymbol == true {
                state.enterEdit(shapes[i].ref)
                return
            }
        }
        state.enterEdit(state.selectedItem)
    }

    private func renameLibraryItem() {
        guard let item = state.doc.item(state.selectedItem) else {
            NSSound.beep()
            return
        }
        if let name = prompt("Rename Library Item", detail: "", value: item.name) {
            state.renameItem(item.id, to: name)
        }
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sound file (WAV, AIFF, MP3, M4A)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !state.importAudio(url) {
            message("Couldn't use that file", "It isn't a sound file SwiftCel can play.")
        }
    }

    private var baseName: String {
        return state.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = baseName + ".mp4"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let url = chosen.pathExtension.lowercased() == "mp4" ? chosen : chosen.appendingPathExtension("mp4")
        state.stop()
        window.title = "Exporting video…"
        window.displayIfNeeded()
        let ok = Renderer.writeVideo(doc: state.doc, audio: state.audioURL, to: url)
        updateTitle()
        if ok {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            message("Export failed", "The video couldn't be written.")
        }
    }

    private func exportGIF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = baseName + ".gif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !Renderer.writeGIF(doc: state.doc, to: url) {
            message("Export failed", "The GIF couldn't be written.")
        }
    }

    private func exportPNGs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if !Renderer.writePNGSequence(doc: state.doc, to: folder, baseName: baseName) {
            message("Export failed", "Some frames couldn't be written.")
        }
    }

    private func exportSVG() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = baseName + "_\(state.frame + 1).svg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Renderer.svg(doc: state.doc, frame: state.frame).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            message("Export failed", error.localizedDescription)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
