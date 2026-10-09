import UIKit
import UniformTypeIdentifiers

/// One card on the Home screen, drawn like the cards on the Mac app's Home.
final class ShelfCell: UICollectionViewCell {
    var isNewCard = false
    var picture: UIImage?
    var title = ""
    var detail = ""
    private let card = ShelfCardView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.owner = self
        contentView.addSubview(card)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = contentView.bounds
    }

    func refresh() {
        card.setNeedsDisplay()
    }

    override var isHighlighted: Bool {
        didSet { card.alpha = isHighlighted ? 0.7 : 1 }
    }
}

final class ShelfCardView: UIView {
    weak var owner: ShelfCell?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let cell = owner else { return }
        let body = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 7)
        Theme.frameEmpty.setFill()
        body.fill()
        Theme.line.setStroke()
        body.lineWidth = 1
        body.stroke()
        let art = CGRect(x: 10, y: 10, width: bounds.width - 20, height: bounds.height - 68)

        if cell.isNewCard {
            Theme.gradient(Theme.pressedBottom, Theme.pressedTop, in: art)
            let plus = UIBezierPath()
            plus.move(to: CGPoint(x: art.midX - 22, y: art.midY))
            plus.addLine(to: CGPoint(x: art.midX + 22, y: art.midY))
            plus.move(to: CGPoint(x: art.midX, y: art.midY - 22))
            plus.addLine(to: CGPoint(x: art.midX, y: art.midY + 22))
            plus.lineWidth = 6
            plus.lineCapStyle = .round
            Theme.accentInk.setStroke()
            plus.stroke()
        } else if let img = cell.picture, img.size.width > 0, img.size.height > 0 {
            // Fit the whole first frame inside the picture area.
            Theme.fill(Theme.pasteboard, art)
            let k = min(art.width / img.size.width, art.height / img.size.height)
            let w = img.size.width * k
            let h = img.size.height * k
            img.draw(in: CGRect(x: art.midX - w / 2, y: art.midY - h / 2, width: w, height: h))
        } else {
            Theme.fill(Theme.row, art)
            Theme.label("No preview yet", at: CGPoint(x: art.minX + 8, y: art.midY - 7), color: Theme.dim, size: 11)
        }
        Theme.line.setStroke()
        UIBezierPath(rect: art.insetBy(dx: 0.5, dy: 0.5)).stroke()

        ctx.saveGState()
        ctx.clip(to: CGRect(x: art.minX, y: art.maxY, width: art.width, height: 58))
        Theme.label(cell.title, at: CGPoint(x: art.minX, y: art.maxY + 10), color: Theme.text, size: 15, bold: true)
        Theme.label(cell.detail, at: CGPoint(x: art.minX, y: art.maxY + 32), color: Theme.dim, size: 11)
        ctx.restoreGState()
    }
}

/// Home: a card for starting a new animation, then every animation saved on this iPad.
final class HomeViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
                                UIDocumentPickerDelegate {
    private var files: [URL] = []
    private var pictures: [String: UIImage] = [:]
    private var grid: UICollectionView!
    private let backdrop = PadSurface(.backdrop)
    private let bar = PadSurface(.bar)
    private let heading = UILabel()
    private let mark = WordmarkView(frame: CGRect(x: 0, y: 0, width: 120, height: 26))
    private let count = UILabel()
    private var importKey: PadKeyButton?
    private var prefsKey: PadKeyButton?
    private let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override var prefersStatusBarHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(backdrop)

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        layout.sectionInset = UIEdgeInsets(top: 18, left: 18, bottom: 30, right: 18)
        grid = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        grid.backgroundColor = UIColor.clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(ShelfCell.self, forCellWithReuseIdentifier: "card")
        view.addSubview(grid)
        view.addSubview(bar)

        bar.addSubview(mark)
        heading.text = "Your animations"
        heading.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        bar.addSubview(heading)

        count.font = UIFont.systemFont(ofSize: 12)
        count.textAlignment = .right
        bar.addSubview(count)

        let key = PadKeyButton("Import\u{2026}", width: 96, height: 32) { [weak self] in
            self?.importTapped()
        }
        importKey = key
        bar.addSubview(key)
        let prefs = PadKeyButton("Preferences", symbol: "gearshape", width: 40, height: 32) { [weak self] in
            self?.showPreferences()
        }
        prefsKey = prefs
        bar.addSubview(prefs)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        let barH: CGFloat = 56
        backdrop.frame = view.bounds
        bar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + barH)
        let markH: CGFloat = 26
        let markW = WordmarkView.width(forHeight: markH)
        mark.frame = CGRect(x: 20, y: top + (barH - markH) / 2, width: markW, height: markH)
        heading.frame = CGRect(x: mark.frame.maxX + 18, y: top, width: 170, height: barH)
        importKey?.frame.origin = CGPoint(x: view.bounds.width - 114, y: top + (barH - 32) / 2)
        prefsKey?.frame.origin = CGPoint(x: view.bounds.width - 162, y: top + (barH - 32) / 2)
        let countX = heading.frame.maxX + 8
        count.frame = CGRect(x: countX, y: top, width: max(0, view.bounds.width - countX - 176), height: barH)
        grid.frame = CGRect(x: 0, y: bar.frame.maxY, width: view.bounds.width, height: view.bounds.height - bar.frame.maxY)
        grid.collectionViewLayout.invalidateLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The theme may have changed while an animation was open.
        padRedrawAll(view)
        reload()
    }

    private func showPreferences() {
        let prefs = PadPreferencesViewController()
        prefs.onChange = { [weak self] in
            guard let self = self else { return }
            padApplyTheme(to: self.view.window)
            self.reload()
        }
        let sheet = UINavigationController(rootViewController: prefs)
        sheet.modalPresentationStyle = .formSheet
        present(sheet, animated: true, completion: nil)
    }

    func reload() {
        files = Shelf.list()
        pictures.removeAll()
        heading.textColor = Theme.dim
        mark.setNeedsDisplay()
        count.textColor = Theme.dim
        count.text = files.isEmpty ? "Tap New Animation to start one"
            : (files.count == 1 ? "1 animation on this iPad" : "\(files.count) animations on this iPad")
        grid?.reloadData()
    }

    // MARK: Opening

    private func open(_ url: URL) {
        guard let doc = Shelf.load(url) else {
            tell("Couldn't open that animation", "It doesn't look like a SwiftCel document.")
            return
        }
        let editor = EditorViewController(doc: doc, url: url)
        navigationController?.pushViewController(editor, animated: true)
    }

    func openFromOutside(_ url: URL) {
        loadViewIfNeeded()
        if let editor = navigationController?.topViewController as? EditorViewController {
            editor.saveNow()
            navigationController?.popToRootViewController(animated: false)
        }
        reload()
        open(url)
    }

    private func newAnimation() {
        askStage(title: "New Animation", button: "Create", name: "Untitled", doc: Doc()) { [weak self] name, w, h, fps in
            guard let self = self else { return }
            var doc = Doc()
            doc.width = CGFloat(w)
            doc.height = CGFloat(h)
            doc.fps = fps
            let url = Shelf.freshURL(named: name)
            guard Shelf.save(doc, to: url) else {
                self.tell("Couldn't create the animation", "There may not be enough free space on this iPad.")
                return
            }
            self.open(url)
        }
    }

    private func importTapped() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true, completion: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var failed = 0
        for url in urls where Shelf.adopt(url) == nil {
            failed += 1
        }
        reload()
        if failed > 0 {
            tell("Some files were skipped", "Only SwiftCel animations (.swcel) can be imported here.")
        }
    }

    // MARK: Grid

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return files.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let usable = collectionView.bounds.width - 36
        let columns = max(2, floor((usable + 14) / 250))
        let w = floor((usable - (columns - 1) * 14) / columns)
        return CGSize(width: w, height: (w - 20) * 0.6 + 68)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath)
        guard let card = cell as? ShelfCell else { return cell }
        if indexPath.item == 0 {
            card.isNewCard = true
            card.picture = nil
            card.title = "New Animation"
            card.detail = "Choose a size and frame rate"
            card.refresh()
            return card
        }
        let url = files[indexPath.item - 1]
        card.isNewCard = false
        card.title = Shelf.title(url)
        card.detail = dates.string(from: Shelf.modified(url))
        if let cached = pictures[url.path] {
            card.picture = cached
        } else {
            let img = Shelf.thumbnail(for: url)
            pictures[url.path] = img
            card.picture = img
        }
        card.refresh()
        return card
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if indexPath.item == 0 {
            newAnimation()
        } else if files.indices.contains(indexPath.item - 1) {
            open(files[indexPath.item - 1])
        }
    }

    /// Touch and hold a card for Rename, Duplicate, Share and Delete.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.item > 0, files.indices.contains(indexPath.item - 1) else { return nil }
        let url = files[indexPath.item - 1]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let open = UIAction(title: "Open", image: UIImage(systemName: "pencil.and.outline")) { _ in
                self?.open(url)
            }
            let rename = UIAction(title: "Rename…", image: UIImage(systemName: "character.cursor.ibeam")) { _ in
                self?.ask("Rename Animation", value: Shelf.title(url), button: "Rename") { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed != Shelf.title(url) {
                        _ = Shelf.rename(url, to: trimmed)
                    }
                    self?.reload()
                }
            }
            let duplicate = UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { _ in
                Shelf.duplicate(url)
                self?.reload()
            }
            let share = UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                guard let self = self else { return }
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let cell = collectionView.cellForItem(at: indexPath) {
                    sheet.popoverPresentationController?.sourceView = cell
                    sheet.popoverPresentationController?.sourceRect = cell.bounds
                } else {
                    sheet.popoverPresentationController?.sourceView = self.view
                    sheet.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                }
                self.present(sheet, animated: true, completion: nil)
            }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                guard let self = self else { return }
                let sure = UIAlertController(title: "Delete \u{201C}\(Shelf.title(url))\u{201D}?",
                                             message: "This can't be undone.", preferredStyle: .alert)
                sure.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
                sure.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
                    Shelf.delete(url)
                    self.reload()
                })
                self.present(sure, animated: true, completion: nil)
            }
            return UIMenu(title: "", children: [open, rename, duplicate, share, delete])
        }
    }
}
