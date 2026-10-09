import UIKit

/// SwiftCel > Preferences: themes (picking one, and making your own), drawing with a
/// finger, and how wide the timeline's frames are.
final class PadPreferencesViewController: UITableViewController, UITextFieldDelegate {
    /// Called whenever something here changes how the app looks.
    var onChange: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case themes, customize, drawing, timeline
    }

    private let wellTitles = ["Panels", "Accent", "Text and icons", "Around the stage"]
    private var wells: [UIColorWell] = []
    private let nameField = UITextField()
    private let fingerSwitch = UISwitch()
    private let widthSlider = UISlider()
    private var actions: [Action] = []

    init() {
        super.init(style: .insetGrouped)
        title = "Preferences"
        preferredContentSize = CGSize(width: 480, height: 720)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                            action: #selector(done))
        for _ in wellTitles {
            let well = UIColorWell(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
            well.supportsAlpha = false
            wire(well, .valueChanged) { [weak self] in self?.wellChanged() }
            wells.append(well)
        }
        nameField.frame = CGRect(x: 0, y: 0, width: 220, height: 34)
        nameField.textAlignment = .right
        nameField.placeholder = "Theme name"
        nameField.returnKeyType = .done
        nameField.autocapitalizationType = .words
        nameField.delegate = self

        fingerSwitch.isOn = PadPrefs.fingerDraws
        wire(fingerSwitch, .valueChanged) { [weak self] in
            guard let self = self else { return }
            PadPrefs.fingerDraws = self.fingerSwitch.isOn
        }
        widthSlider.minimumValue = 8
        widthSlider.maximumValue = 28
        widthSlider.frame = CGRect(x: 0, y: 0, width: 220, height: 34)
        widthSlider.value = Float(Prefs.frameWidth)
        wire(widthSlider, .valueChanged) { [weak self] in
            guard let self = self else { return }
            Prefs.frameWidth = CGFloat(self.widthSlider.value.rounded())
            self.onChange?()
        }
        syncWells()
    }

    private func wire(_ control: UIControl, _ event: UIControl.Event, _ fn: @escaping () -> Void) {
        let a = Action(fn)
        actions.append(a)
        control.addTarget(a, action: #selector(Action.fire), for: event)
    }

    @objc private func done() {
        view.endEditing(true)
        dismiss(animated: true, completion: nil)
    }

    // MARK: Themes

    /// Copies the palette in use into the colour wells and the name field.
    private func syncWells() {
        guard wells.count == 4 else { return }
        let p = Theme.palette
        nameField.text = p.name
        wells[0].selectedColor = p.panel.uiColor
        wells[1].selectedColor = p.accent.uiColor
        wells[2].selectedColor = p.text.uiColor
        wells[3].selectedColor = p.pasteboard.uiColor
    }

    private func opaque(_ well: UIColorWell) -> RGBA {
        var c = RGBA(well.selectedColor ?? UIColor.gray)
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
        if p == Theme.palette { return }
        Theme.palette = p
        Theme.persist()
        onChange?()
        tableView.reloadSections(IndexSet(integer: Section.themes.rawValue), with: .none)
    }

    private func choose(_ p: Palette) {
        Theme.palette = p
        Theme.persist()
        syncWells()
        onChange?()
        tableView.reloadData()
    }

    private func saveTheme() {
        view.endEditing(true)
        Theme.saveCurrent(as: nameField.text ?? "")
        syncWells()
        onChange?()
        tableView.reloadData()
    }

    private func deleteTheme() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard Theme.custom.contains(where: { $0.name == name }) else {
            tell("Can't delete that theme", "Only themes you have saved yourself can be deleted.")
            return
        }
        Theme.deleteCustom(named: name)
        syncWells()
        onChange?()
        tableView.reloadData()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .themes: return "Theme"
        case .customize: return "Customize theme"
        case .drawing: return "Drawing"
        case .timeline: return "Timeline"
        case .none: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .customize:
            return "Changes show straight away. Give the theme a name and save it to keep it in the list."
        case .drawing:
            return "Off: one finger moves the stage and only the Pencil draws."
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .themes: return Theme.all.count
        case .customize: return wellTitles.count + 3
        case .drawing: return 1
        case .timeline: return 1
        case .none: return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var text = ""
        var color: UIColor = UIColor.label
        switch Section(rawValue: indexPath.section) {
        case .themes:
            let p = Theme.all[indexPath.row]
            text = p.name
            cell.accessoryType = p == Theme.palette ? .checkmark : .none
            cell.selectionStyle = .default
        case .customize:
            let row = indexPath.row
            if row < wellTitles.count {
                text = wellTitles[row]
                cell.accessoryView = wells[row]
            } else if row == wellTitles.count {
                text = "Name"
                cell.accessoryView = nameField
            } else if row == wellTitles.count + 1 {
                text = "Save Theme"
                color = view.tintColor
                cell.selectionStyle = .default
            } else {
                text = "Delete Theme"
                color = UIColor.systemRed
                cell.selectionStyle = .default
            }
        case .drawing:
            text = "Draw with a finger"
            cell.accessoryView = fingerSwitch
        case .timeline:
            text = "Frame width"
            cell.accessoryView = widthSlider
        case .none:
            break
        }
        var content = cell.defaultContentConfiguration()
        content.text = text
        content.textProperties.color = color
        if indexPath.section == Section.themes.rawValue {
            content.image = swatch(Theme.all[indexPath.row])
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .themes:
            choose(Theme.all[indexPath.row])
        case .customize:
            if indexPath.row == wellTitles.count + 1 {
                saveTheme()
            } else if indexPath.row == wellTitles.count + 2 {
                deleteTheme()
            }
        default:
            break
        }
    }

    /// A small picture of a palette: its panel colour with the accent and text on it.
    private func swatch(_ p: Palette) -> UIImage {
        let size = CGSize(width: 44, height: 28)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let body = UIBezierPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 43, height: 27), cornerRadius: 5)
            p.pasteboard.uiColor.setFill()
            body.fill()
            p.panel.uiColor.setFill()
            UIBezierPath(roundedRect: CGRect(x: 4, y: 4, width: 36, height: 20), cornerRadius: 3).fill()
            p.accent.uiColor.setFill()
            UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 12, height: 12)).fill()
            p.text.uiColor.setFill()
            UIBezierPath(rect: CGRect(x: 23, y: 12, width: 13, height: 4)).fill()
            UIColor.separator.setStroke()
            body.stroke()
        }
    }
}
