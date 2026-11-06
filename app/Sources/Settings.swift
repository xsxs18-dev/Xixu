import UIKit

final class SettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Row {
        case toggle(String, String, UIColor, Bool, (Bool) -> Void)
        case accent
        case action(String, String, UIColor, Bool, () -> Void)
        case value(String, String, Bool)
    }

    private struct Section {
        var title: String?
        var footer: String?
        var rows: [Row]
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var sections: [Section] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Settings")
        navigationItem.largeTitleDisplayMode = .always
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)
        build()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        build()
    }

    private func build() {
        var result: [Section] = []
        result.append(Section(title: L("Browsing"), footer: nil, rows: [
            .toggle(L("Show Hidden Files"), "eye.fill", .systemGray, Prefs.showHidden) { Prefs.showHidden = $0 },
            .toggle(L("Folders on Top"), "folder.fill", .systemBlue, Prefs.foldersFirst) { Prefs.foldersFirst = $0 },
            .toggle(L("Show App Names for Containers"), "square.grid.2x2.fill", .systemTeal, Prefs.resolveContainers) { Prefs.resolveContainers = $0 },
            .toggle(L("Show Thumbnails"), "photo.fill", .systemGreen, Prefs.thumbnails) { Prefs.thumbnails = $0 },
            .toggle(L("Show Permissions in List"), "lock.fill", .systemOrange, Prefs.showDetails) { Prefs.showDetails = $0 },
        ]))
        result.append(Section(title: L("Deleting"), footer: L("Items on another volume are deleted permanently after you confirm."), rows: [
            .toggle(L("Use Trash"), "trash.fill", .systemRed, Prefs.useTrash) { Prefs.useTrash = $0 },
            .action(L("Empty Trash…"), "xmark.bin.fill", .systemRed, true) { [weak self] in self?.emptyTrash() },
        ]))
        result.append(Section(title: L("Appearance"), footer: nil, rows: [.accent]))
        let root = FS.shared.isRoot
        var status: [Row] = [
            .value(L("Access"), root ? L("Root") : L("Limited"), false),
            .value(L("Jailbreak"), JB.scheme, false),
        ]
        if !JB.root.isEmpty { status.append(.value(L("Jailbreak Root"), JB.displayRoot, true)) }
        status.append(.value(L("Helper"), FS.shared.helperPath ?? L("Not installed"), FS.shared.helperPath != nil))
        result.append(Section(title: L("Status"),
                              footer: root ? nil : L("The root helper is not running. Reinstalling the package usually fixes this."),
                              rows: status))

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        result.append(Section(title: L("About"), footer: nil, rows: [
            .value(L("Version"), "\(version) (\(build))", false),
        ]))
        sections = result
        tableView.reloadData()
    }

    private func emptyTrash() {
        confirm(title: L("Empty Trash?"), message: L("All items in the Trash are deleted permanently. This can't be undone."),
                action: L("Empty Trash"), source: nil) {
            Task { @MainActor in
                do {
                    _ = try await Activity.shared.run(L("Emptying Trash"), Request(op: "emptyTrash"))
                    Haptics.success()
                    RootController.shared?.toast(L("Trash Emptied"))
                } catch {
                    self.showError(error)
                }
                announceChanges([Engine.trashRoot])
            }
        }
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        switch sections[indexPath.section].rows[indexPath.row] {
        case let .toggle(title, symbol, color, on, handler):
            var c = UIListContentConfiguration.cell()
            c.text = title
            c.image = Icons.squircle(symbol, color)
            cell.contentConfiguration = c
            let toggle = UISwitch()
            toggle.isOn = on
            toggle.addAction(UIAction { [weak toggle] _ in
                handler(toggle?.isOn ?? false)
                Haptics.tap()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .accent:
            var c = UIListContentConfiguration.cell()
            c.text = L("Accent Color")
            c.image = Icons.squircle("paintbrush.fill", .systemPink)
            cell.contentConfiguration = c
            var config = UIButton.Configuration.plain()
            let current = Theme.accents.indices.contains(Prefs.accent) ? Theme.accents[Prefs.accent] : Theme.accents[0]
            config.title = current.name
            config.image = dot(current.color)
            config.imagePadding = 8
            config.baseForegroundColor = .secondaryLabel
            let button = UIButton(configuration: config)
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: Theme.accents.enumerated().map { index, accent in
                UIAction(title: accent.name, image: dot(accent.color), state: index == Prefs.accent ? .on : .off) { [weak self] _ in
                    Prefs.accent = index
                    Haptics.tap()
                    self?.build()
                }
            })
            button.sizeToFit()
            cell.accessoryView = button
            cell.selectionStyle = .none
        case let .action(title, symbol, color, destructive, _):
            var c = UIListContentConfiguration.cell()
            c.text = title
            c.textProperties.color = destructive ? .systemRed : .label
            c.image = Icons.squircle(symbol, color)
            cell.contentConfiguration = c
            cell.accessoryType = destructive ? .none : .disclosureIndicator
        case let .value(title, value, mono):
            var c = UIListContentConfiguration.valueCell()
            c.text = title
            c.secondaryText = value
            c.secondaryTextProperties.font = mono ? Theme.mono(13) : .preferredFont(forTextStyle: .body)
            c.secondaryTextProperties.lineBreakMode = .byTruncatingHead
            c.prefersSideBySideTextAndSecondaryText = !mono
            cell.contentConfiguration = c
            cell.selectionStyle = mono ? .default : .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case let .action(_, _, _, _, handler):
            handler()
        case let .value(_, value, mono) where mono:
            UIPasteboard.general.string = value
            Haptics.tap()
            RootController.shared?.toast(L("Copied"))
        default:
            break
        }
    }

    private func dot(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 14, height: 14)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}
