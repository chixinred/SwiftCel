import UIKit

/// Applies the theme in use to a window: tint, light or dark controls, and a redraw
/// of every panel.
@MainActor func padApplyTheme(to window: UIWindow?) {
    guard let window = window else { return }
    window.tintColor = Theme.isDark ? Theme.accentText : Theme.accent
    window.overrideUserInterfaceStyle = Theme.isDark ? .dark : .light
    padRedrawAll(window)
}

/// Settings that only exist on the iPad.
enum PadPrefs {
    private static let store = UserDefaults.standard

    /// Set the first time an Apple Pencil touches the stage.
    static var pencilSeen: Bool {
        get { return store.bool(forKey: "pad.pencilSeen") }
        set { store.set(newValue, forKey: "pad.pencilSeen") }
    }

    /// Whether a finger draws. Until the user chooses, fingers draw only while no
    /// Pencil has been used; after that they move and zoom the stage instead.
    static var fingerDraws: Bool {
        get {
            if store.object(forKey: "pad.fingerDraws") == nil { return !pencilSeen }
            return store.bool(forKey: "pad.fingerDraws")
        }
        set { store.set(newValue, forKey: "pad.fingerDraws") }
    }
}

/// The animations kept on this iPad: every .swcel file in the app's Documents folder
/// (which also shows up in the Files app under "On My iPad > SwiftCel").
enum Shelf {
    static var folder: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var thumbFolder: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Thumbnails", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let kinds: Set<String> = ["swcel", "swiftcel", "wonky"]

    /// Saved animations, most recently changed first.
    static func list() -> [URL] {
        let fm = FileManager.default
        let found = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let docs = found.filter { kinds.contains($0.pathExtension.lowercased()) }
        return docs.sorted { modified($0) > modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? Date.distantPast
    }

    static func title(_ url: URL) -> String {
        return url.deletingPathExtension().lastPathComponent
    }

    /// A file name in the shelf that is not taken yet.
    static func freshURL(named raw: String) -> URL {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if base.isEmpty { base = "Untitled" }
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(base + ".swcel")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).swcel")
            n += 1
        }
        return candidate
    }

    private static func thumbURL(for url: URL) -> URL {
        var hash: UInt64 = 5381
        for byte in url.lastPathComponent.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        return thumbFolder.appendingPathComponent(String(hash, radix: 16) + ".png")
    }

    static func load(_ url: URL) -> Doc? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Doc.self, from: data)
    }

    @discardableResult
    static func save(_ doc: Doc, to url: URL, picture: Bool = true) -> Bool {
        guard let data = try? JSONEncoder().encode(doc) else { return false }
        // Queued behind any background save still running, so an older copy can never
        // land on top of this one.
        let written: Bool = saver.sync {
            (try? data.write(to: url, options: [.atomic])) != nil
        }
        if !written { return false }
        // The Home screen's picture is only redrawn when asked, as it costs a render.
        guard picture else { return true }
        let scale = min(1, 480 / max(1, doc.width))
        if let img = Renderer.image(doc: doc, frame: 0, scale: scale),
           let png = Renderer.pngData(img) {
            try? png.write(to: thumbURL(for: url))
        }
        return true
    }

    private static let saver = DispatchQueue(label: "swiftcel.save", qos: .utility)

    /// Writes the animation (without redrawing its Home picture) on a background queue,
    /// then reports back on the main thread whether it worked.
    static func saveInBackground(_ doc: Doc, to url: URL, done: @escaping (Bool) -> Void) {
        saver.async {
            var ok = false
            if let data = try? JSONEncoder().encode(doc) {
                ok = (try? data.write(to: url, options: [.atomic])) != nil
            }
            DispatchQueue.main.async {
                done(ok)
            }
        }
    }

    static func thumbnail(for url: URL) -> UIImage? {
        let source = thumbURL(for: url)
        if let img = UIImage(contentsOfFile: source.path) { return img }
        // No picture yet (a file copied in through the Files app): make one.
        guard let doc = load(url) else { return nil }
        let scale = min(1, 480 / max(1, doc.width))
        guard let img = Renderer.image(doc: doc, frame: 0, scale: scale) else { return nil }
        if let png = Renderer.pngData(img) { try? png.write(to: source) }
        return UIImage(cgImage: img)
    }

    static func rename(_ url: URL, to name: String) -> URL? {
        let target = freshURL(named: name)
        let fm = FileManager.default
        let oldThumb = thumbURL(for: url)
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            return nil
        }
        try? fm.moveItem(at: oldThumb, to: thumbURL(for: target))
        return target
    }

    @discardableResult
    static func duplicate(_ url: URL) -> URL? {
        let target = freshURL(named: title(url) + " copy")
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            return nil
        }
        return target
    }

    /// Where imported soundtracks are kept.
    static var audioFolder: URL {
        let dir = folder.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a sound file into the Audio folder (under a name not taken yet).
    static func keepAudio(_ outside: URL) -> URL? {
        let fm = FileManager.default
        let scoped = outside.startAccessingSecurityScopedResource()
        defer {
            if scoped { outside.stopAccessingSecurityScopedResource() }
        }
        let base = outside.deletingPathExtension().lastPathComponent
        let ext = outside.pathExtension
        var target = audioFolder.appendingPathComponent(outside.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = audioFolder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        do {
            try fm.copyItem(at: outside, to: target)
        } catch {
            return nil
        }
        return target
    }

    /// Makes soundtracks stored relative to the app's folder ("Audio/song.m4a"), since the
    /// folder itself moves whenever the app is reinstalled. A full path from the Mac falls
    /// back to a file of the same name in the Audio folder.
    static func installAudioPaths() {
        AppState.audioReference = { url in
            let root = Shelf.folder.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        }
        AppState.audioFile = { stored in
            if !stored.hasPrefix("/") {
                return Shelf.folder.appendingPathComponent(stored)
            }
            let full = URL(fileURLWithPath: stored)
            if FileManager.default.fileExists(atPath: full.path) { return full }
            return Shelf.audioFolder.appendingPathComponent(full.lastPathComponent)
        }
    }

    static func delete(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: thumbURL(for: url))
        try? fm.removeItem(at: url)
    }

    /// Copies a file from somewhere else (Files, AirDrop, another app) onto the shelf.
    static func adopt(_ outside: URL) -> URL? {
        if outside.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            return outside
        }
        let scoped = outside.startAccessingSecurityScopedResource()
        defer {
            if scoped { outside.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: outside),
              (try? JSONDecoder().decode(Doc.self, from: data)) != nil else { return nil }
        let target = freshURL(named: title(outside))
        do {
            try data.write(to: target, options: [.atomic])
        } catch {
            return nil
        }
        return target
    }
}

extension UIViewController {
    /// A one-button message.
    func tell(_ title: String, _ detail: String) {
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    /// Asks for one line of text.
    func ask(_ title: String, detail: String? = nil, value: String, button: String, numbers: Bool = false,
             done: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = value
            field.clearButtonMode = .whileEditing
            field.keyboardType = numbers ? .numberPad : .default
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: button, style: .default) { [weak alert] _ in
            done(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true, completion: nil)
    }

    /// The form for a stage's size, frame rate and (for a new animation) its name.
    func askStage(title: String, button: String, name: String?, doc: Doc,
                  done: @escaping (_ name: String, _ width: Int, _ height: Int, _ fps: Int) -> Void) {
        let alert = UIAlertController(title: title, message: "Width and height are in pixels.", preferredStyle: .alert)
        if let name = name {
            alert.addTextField { field in
                field.text = name
                field.placeholder = "Name"
                field.autocapitalizationType = .words
                field.clearButtonMode = .whileEditing
            }
        }
        let numbers: [(String, Int)] = [("Width", Int(doc.width)), ("Height", Int(doc.height)), ("Frames per second", doc.fps)]
        for entry in numbers {
            alert.addTextField { field in
                field.text = String(entry.1)
                field.placeholder = entry.0
                field.keyboardType = .numberPad
                let tag = UILabel()
                tag.text = "  " + entry.0 + "  "
                tag.font = UIFont.systemFont(ofSize: 12)
                tag.textColor = UIColor.secondaryLabel
                tag.sizeToFit()
                field.rightView = tag
                field.rightViewMode = .always
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: button, style: .default) { [weak alert] _ in
            let fields = alert?.textFields ?? []
            let offset = name == nil ? 0 : 1
            func number(_ i: Int, _ fallback: Int) -> Int {
                guard fields.indices.contains(i + offset), let v = Int(fields[i + offset].text ?? "") else { return fallback }
                return v
            }
            let chosen = name == nil ? "" : (fields.first?.text ?? "")
            done(chosen,
                 max(16, min(8192, number(0, Int(doc.width)))),
                 max(16, min(8192, number(1, Int(doc.height)))),
                 max(1, min(60, number(2, doc.fps))))
        })
        present(alert, animated: true, completion: nil)
    }
}
