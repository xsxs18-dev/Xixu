import UIKit
import Darwin

/// Properties sheet: sizes, dates, owner, permissions, checksums.
final class InfoViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum CalcState {
        case idle
        case running(String?)
        case done
        case failed(String)
    }

    private enum InfoAction {
        case showInFolder, copyPath, favorite
    }

    private enum Row {
        case header
        case detail(String, String, mono: Bool)
        case link(String, String, target: String, isDirectory: Bool)
        case usage
        case owner
        case group
        case permissions
        case recursive
        case hashCalc
        case action(InfoAction)
    }

    private struct Section {
        var title: String?
        var footer: String?
        var rows: [Row]
    }

    private let path: String
    private var info: StatInfo?
    private var loadError: Error?
    private var sections: [Section] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private var recursive = false
    private var usageState = CalcState.idle
    private var usage: [Int64] = []
    private var usageJob: Int?
    private var hashState = CalcState.idle
    private var hashes: [String] = []
    private var hashJob: Int?

    init(path: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
        title = L("Info")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        if let sheet = navigationController?.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundView = EmptyStateView(title: nil, loading: true)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        Task { @MainActor in await self.reloadInfo() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || navigationController == nil {
            if let id = usageJob { FS.shared.cancel(id) }
            if let id = hashJob { FS.shared.cancel(id) }
        }
    }

    @MainActor
    private func reloadInfo() async {
        do {
            info = try await FS.shared.stat(path)
            loadError = nil
        } catch {
            info = nil
            loadError = error
        }
        rebuild()
    }

    // MARK: - Model

    private var isDirectory: Bool {
        guard let e = info?.entry else { return false }
        return e.kind == .directory || (e.kind == .symlink && e.linkDir == true)
    }

    private var kind: FileKind {
        guard let e = info?.entry else { return .other }
        return FileKind.of(name: e.name, isDirectory: isDirectory, entryKind: e.kind, mode: e.mode)
    }

    private func rebuild() {
        guard let info = info else {
            sections = []
            tableView.backgroundView = EmptyStateView(title: L("Can't Load Info"), message: loadError?.localizedDescription)
            tableView.reloadData()
            return
        }
        tableView.backgroundView = nil
        let e = info.entry
        var result: [Section] = [Section(title: nil, footer: nil, rows: [.header])]

        var general: [Row] = []
        general.append(.detail(L("Kind"), e.kind == .symlink ? L("Symbolic Link") : kind.name, mono: false))
        if e.kind == .directory {
            general.append(.usage)
        } else if e.kind == .file {
            general.append(.detail(L("Size"), "\(Format.bytes(e.size)) (\(Format.exactBytes(e.size)))", mono: false))
        }
        general.append(.link(L("Where"), Paths.parent(path), target: path, isDirectory: false))
        if e.kind == .symlink, let link = e.link {
            let target = link.hasPrefix("/") ? link : Paths.standardized(Paths.join(Paths.parent(path), link))
            general.append(.link(L("Link Target"), link, target: target, isDirectory: e.linkDir == true))
        }
        if let real = info.realPath, real != path, real != "/private" + path {
            general.append(.link(L("Resolved Path"), real, target: real, isDirectory: isDirectory))
        }
        if let id = e.label, e.kind == .directory {
            if let name = AppRegistry.shared.name(for: id) {
                general.append(.detail(L("App"), name, mono: false))
            }
            general.append(.detail(L("Bundle ID"), id, mono: true))
        }
        result.append(Section(title: L("General"), footer: nil, rows: general))

        result.append(Section(title: L("Dates"), footer: nil, rows: [
            .detail(L("Created"), Format.fullDate(info.btime), mono: false),
            .detail(L("Modified"), Format.fullDate(e.mtime), mono: false),
            .detail(L("Accessed"), Format.fullDate(info.atime), mono: false),
            .detail(L("Changed"), Format.fullDate(info.ctime), mono: false),
        ]))

        var permissions: [Row] = [.owner, .group, .permissions]
        if e.kind == .directory { permissions.append(.recursive) }
        var footer: String?
        if e.kind == .symlink {
            footer = L("The permissions of a symbolic link can't be changed. Edit the target instead.")
        } else if recursive {
            footer = L("Changes apply to this folder and everything inside it.")
        } else if !FS.shared.isRoot {
            footer = L("Without the root helper only items owned by mobile can be changed.")
        }
        result.append(Section(title: L("Permissions"), footer: footer, rows: permissions))

        if e.kind == .file {
            var rows: [Row] = []
            if case .done = hashState, hashes.count == 3 {
                rows = [.detail("MD5", hashes[0], mono: true), .detail("SHA-1", hashes[1], mono: true),
                        .detail("SHA-256", hashes[2], mono: true)]
            } else {
                rows = [.hashCalc]
            }
            result.append(Section(title: L("Checksums"), footer: nil, rows: rows))
        }

        result.append(Section(title: L("Advanced"), footer: nil, rows: [
            .detail(L("Inode"), "\(info.inode)", mono: true),
            .detail(L("Links"), "\(info.links)", mono: true),
            .detail(L("Device"), "\(info.device)", mono: true),
            .detail(L("Flags"), String(format: "0x%08x", info.flags), mono: true),
            .detail(L("Allocated"), Format.bytes(info.blocks * 512), mono: false),
        ]))

        var actions: [Row] = [.action(.showInFolder), .action(.copyPath)]
        if isDirectory { actions.append(.action(.favorite)) }
        result.append(Section(title: nil, footer: nil, rows: actions))

        sections = result
        tableView.reloadData()
    }

    private func indexPath(where match: (Row) -> Bool) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let r = section.rows.firstIndex(where: match) { return IndexPath(row: r, section: s) }
        }
        return nil
    }

    private func reloadRow(where match: (Row) -> Bool) {
        guard let ip = indexPath(where: match) else { return }
        tableView.reloadRows(at: [ip], with: .none)
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let info = info else { return UITableViewCell() }
        let e = info.entry
        switch sections[indexPath.section].rows[indexPath.row] {
        case .header:
            let cell = InfoHeaderCell()
            var image: UIImage?
            var isAppIcon = false
            if let id = e.label, e.kind == .directory, let icon = AppRegistry.shared.icon(for: id, size: 56) {
                image = icon
                isAppIcon = true
            } else if kind == .app, let icon = Icons.app(bundlePath: path, size: 56) {
                image = icon
                isAppIcon = true
            } else {
                image = Icons.file(FileItem(path: path, entry: e), size: 56, dark: traitCollection.userInterfaceStyle == .dark)
            }
            var detail = e.kind == .symlink ? L("Symbolic Link") : kind.name
            if e.kind == .file { detail += " · " + Format.bytes(e.size) }
            cell.configure(image: image, appIcon: isAppIcon, tint: isDirectory ? Theme.accent : .secondaryLabel,
                           name: e.name, detail: detail)
            return cell

        case let .detail(title, value, mono):
            let cell = makeValueCell(title, value, mono: mono)
            cell.selectionStyle = mono ? .default : .none
            return cell

        case let .link(title, value, _, _):
            let cell = makeValueCell(title, value, mono: true)
            cell.accessoryType = .disclosureIndicator
            return cell

        case .usage:
            return makeUsageCell()

        case .owner:
            let current = Int(e.uid)
            let name = info.owner ?? "?"
            let options: [(String, Int)] = [("root", 0), ("mobile", 501)]
            return makeMenuCell(L("Owner"), value: "\(name) (\(current))", menu: idMenu(options, current: current, isUser: true))

        case .group:
            let current = Int(e.gid)
            let name = info.group ?? "?"
            let options: [(String, Int)] = [("wheel", 0), ("mobile", 501), ("admin", 80), ("staff", 20)]
            return makeMenuCell(L("Group"), value: "\(name) (\(current))", menu: idMenu(options, current: current, isUser: false))

        case .permissions:
            let cell = PermissionGridCell()
            cell.configure(mode: e.mode, kind: e.kind, locked: e.kind == .symlink)
            cell.onChange = { [weak self, weak cell] newMode, oldMode in
                self?.applyMode(newMode) { cell?.configure(mode: oldMode, kind: e.kind, locked: false) }
            }
            return cell

        case .recursive:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var c = UIListContentConfiguration.cell()
            c.text = L("Apply to Enclosed Items")
            cell.contentConfiguration = c
            let toggle = UISwitch()
            toggle.isOn = recursive
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                self?.recursive = toggle?.isOn ?? false
                Haptics.tap()
                self?.updatePermissionsFooter()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
            return cell

        case .hashCalc:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var c = UIListContentConfiguration.cell()
            switch hashState {
            case .running(let text):
                c.text = L("Calculating…")
                c.secondaryText = text
                c.textProperties.color = .secondaryLabel
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
                cell.selectionStyle = .none
            case .failed(let message):
                c.text = L("Calculate Checksums")
                c.textProperties.color = Theme.accent
                c.secondaryText = message
                c.secondaryTextProperties.color = .systemRed
            default:
                c.text = L("Calculate Checksums")
                c.textProperties.color = Theme.accent
            }
            cell.contentConfiguration = c
            return cell

        case .action(let action):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var c = UIListContentConfiguration.cell()
            c.textProperties.color = Theme.accent
            switch action {
            case .showInFolder:
                c.text = L("Show in Folder")
                c.image = UIImage(systemName: "folder")
            case .copyPath:
                c.text = L("Copy Path")
                c.image = UIImage(systemName: "doc.on.doc")
            case .favorite:
                let isFavorite = Bookmarks.isFavorite(path)
                c.text = isFavorite ? L("Remove from Favorites") : L("Add to Favorites")
                c.image = UIImage(systemName: isFavorite ? "star.slash" : "star")
            }
            c.imageProperties.tintColor = Theme.accent
            cell.contentConfiguration = c
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case let .detail(_, value, mono) where mono:
            UIPasteboard.general.string = value
            Haptics.tap()
            RootController.shared?.toast(L("Copied"))
        case let .link(_, _, target, isDirectory):
            RootController.shared?.reveal(target, isDirectory: isDirectory)
        case .usage:
            if case .running = usageState { return }
            calculateUsage()
        case .hashCalc:
            if case .running = hashState { return }
            calculateHashes()
        case .action(let action):
            switch action {
            case .showInFolder:
                RootController.shared?.reveal(path, isDirectory: false)
            case .copyPath:
                Ops.copyPaths([path])
            case .favorite:
                let wasFavorite = Bookmarks.isFavorite(path)
                Bookmarks.toggleFavorite(path)
                Haptics.tap()
                RootController.shared?.toast(wasFavorite ? L("Removed from Favorites") : L("Added to Favorites"))
                tableView.reloadRows(at: [indexPath], with: .none)
            }
        default:
            break
        }
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .header, .owner, .group, .permissions, .recursive:
            return false
        case let .detail(_, _, mono):
            return mono
        case .usage:
            if case .running = usageState { return false }
            if case .done = usageState { return false }
            return true
        case .hashCalc:
            if case .running = hashState { return false }
            return true
        default:
            return true
        }
    }

    // MARK: - Cells

    private func makeValueCell(_ title: String, _ value: String, mono: Bool) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c: UIListContentConfiguration
        if mono {
            c = UIListContentConfiguration.subtitleCell()
            c.textProperties.font = .preferredFont(forTextStyle: .footnote)
            c.textProperties.color = .secondaryLabel
            c.secondaryTextProperties.font = Theme.mono(14)
            c.secondaryTextProperties.color = .label
            c.secondaryTextProperties.numberOfLines = 0
            c.textToSecondaryTextVerticalPadding = 3
        } else {
            c = UIListContentConfiguration.valueCell()
            c.secondaryTextProperties.numberOfLines = 0
        }
        c.text = title
        c.secondaryText = value
        cell.contentConfiguration = c
        return cell
    }

    private func makeUsageCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.valueCell()
        c.text = L("Size")
        switch usageState {
        case .idle:
            c.secondaryText = L("Calculate")
            c.secondaryTextProperties.color = Theme.accent
        case .running(let text):
            c.secondaryText = text.map { LF("%@ items…", $0) } ?? L("Calculating…")
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        case .failed(let message):
            c.secondaryText = message
            c.secondaryTextProperties.color = .systemRed
        case .done:
            c = UIListContentConfiguration.subtitleCell()
            c.text = L("Size")
            c.textProperties.font = .preferredFont(forTextStyle: .footnote)
            c.textProperties.color = .secondaryLabel
            c.textToSecondaryTextVerticalPadding = 3
            if usage.count >= 4 {
                let folders = max(0, usage[3] - 1)
                c.secondaryText = LF("%@ (%@ on disk)", Format.bytes(usage[0]), Format.bytes(usage[1])) + "\n"
                    + LF("%lld files · %lld folders", usage[2], folders)
            }
            c.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
            c.secondaryTextProperties.color = .label
            c.secondaryTextProperties.numberOfLines = 0
        }
        cell.contentConfiguration = c
        return cell
    }

    private func makeMenuCell(_ title: String, value: String, menu: UIMenu) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.cell()
        c.text = title
        cell.contentConfiguration = c
        var config = UIButton.Configuration.plain()
        config.title = value
        config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = Theme.mono(15)
            return a
        }
        let button = UIButton(configuration: config)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.sizeToFit()
        cell.accessoryView = button
        cell.selectionStyle = .none
        return cell
    }

    private func idMenu(_ options: [(String, Int)], current: Int, isUser: Bool) -> UIMenu {
        var actions: [UIMenuElement] = options.map { name, id in
            UIAction(title: "\(name) (\(id))", state: id == current ? .on : .off) { [weak self] _ in
                self?.changeOwnership(uid: isUser ? id : nil, gid: isUser ? nil : id)
            }
        }
        actions.append(UIAction(title: L("Other…")) { [weak self] _ in
            self?.prompt(title: isUser ? L("User ID") : L("Group ID"), text: "\(current)", action: L("Change"), keyboard: .numberPad) { value in
                guard let id = Int(value), id >= 0 else { return }
                self?.changeOwnership(uid: isUser ? id : nil, gid: isUser ? nil : id)
            }
        })
        return UIMenu(children: actions)
    }

    private func updatePermissionsFooter() {
        guard let info = info, info.entry.kind == .directory,
              let section = sections.firstIndex(where: { $0.title == L("Permissions") }) else { return }
        sections[section].footer = recursive ? L("Changes apply to this folder and everything inside it.")
            : (FS.shared.isRoot ? nil : L("Without the root helper only items owned by mobile can be changed."))
        UIView.performWithoutAnimation {
            tableView.reloadSections(IndexSet(integer: section), with: .none)
        }
    }

    // MARK: - Actions

    private var recursiveFlags: [String]? { recursive && isDirectory ? ["recursive"] : nil }

    private func applyMode(_ mode: UInt16, revert: @escaping () -> Void) {
        let request = Request(op: "chmod", paths: [path], mode: Int(mode & 0o7777), flags: recursiveFlags)
        runAttributeChange(request, title: L("Changing Permissions"), revert: revert)
    }

    private func changeOwnership(uid: Int?, gid: Int?) {
        let request = Request(op: "chown", paths: [path], uid: uid, gid: gid, flags: recursiveFlags)
        runAttributeChange(request, title: L("Changing Owner"), revert: nil)
    }

    private func runAttributeChange(_ request: Request, title: String, revert: (() -> Void)?) {
        let useActivity = request.has("recursive")
        let dirs = [Paths.parent(path)] + (isDirectory ? [path] : [])
        Task { @MainActor in
            do {
                if useActivity {
                    _ = try await Activity.shared.run(title, request)
                } else {
                    _ = try await FS.shared.call(request)
                }
                Haptics.tap()
                announceChanges(dirs)
            } catch {
                revert?()
                self.showError(error)
            }
            await self.reloadInfo()
        }
    }

    private func calculateUsage() {
        var request = Request(op: "usage", paths: [path])
        request.id = FS.shared.makeID()
        usageJob = request.id
        usageState = .running(nil)
        reloadRow { if case .usage = $0 { return true }; return false }
        Task { @MainActor in
            do {
                let response = try await FS.shared.call(request) { [weak self] update in
                    guard let self = self, case .running = self.usageState else { return }
                    self.usageState = .running(update.text)
                    self.reloadRow { if case .usage = $0 { return true }; return false }
                }
                self.usage = response.numbers ?? []
                self.usageState = .done
            } catch {
                self.usageState = (error as? XixuError)?.isCancelled == true ? .idle : .failed(error.localizedDescription)
            }
            self.usageJob = nil
            self.reloadRow { if case .usage = $0 { return true }; return false }
        }
    }

    private func calculateHashes() {
        var request = Request(op: "hash", path: path)
        request.id = FS.shared.makeID()
        hashJob = request.id
        hashState = .running(nil)
        reloadRow { if case .hashCalc = $0 { return true }; return false }
        Task { @MainActor in
            do {
                let response = try await FS.shared.call(request) { [weak self] update in
                    guard let self = self, case .running = self.hashState, let p = update.progress else { return }
                    self.hashState = .running("\(Int(p * 100)) %")
                    self.reloadRow { if case .hashCalc = $0 { return true }; return false }
                }
                self.hashes = response.strings ?? []
                self.hashState = self.hashes.count == 3 ? .done : .failed(L("No result"))
                self.hashJob = nil
                self.rebuild()
                return
            } catch {
                self.hashState = (error as? XixuError)?.isCancelled == true ? .idle : .failed(error.localizedDescription)
            }
            self.hashJob = nil
            self.reloadRow { if case .hashCalc = $0 { return true }; return false }
        }
    }
}

// MARK: - Header cell

private final class InfoHeaderCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameView = UITextView()
    private let detailLabel = UILabel()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        backgroundConfiguration = .clear()
        selectionStyle = .none

        iconView.contentMode = .scaleAspectFit
        iconView.clipsToBounds = true
        iconView.layer.cornerCurve = .continuous
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameView.isEditable = false
        nameView.isScrollEnabled = false
        nameView.isSelectable = true
        nameView.backgroundColor = .clear
        nameView.textContainerInset = .zero
        nameView.textContainer.lineFragmentPadding = 0
        nameView.font = .systemFont(ofSize: 19, weight: .semibold)
        nameView.textColor = .label

        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [nameView, detailLabel])
        text.axis = .vertical
        text.spacing = 3
        let row = UIStackView(arrangedSubviews: [iconView, text])
        row.alignment = .center
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(image: UIImage?, appIcon: Bool, tint: UIColor, name: String, detail: String) {
        iconView.image = image
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 0
        nameView.text = name
        detailLabel.text = detail
    }
}

// MARK: - Permission grid

private final class PermissionGridCell: UITableViewCell {
    /// (new mode, previous mode)
    var onChange: ((UInt16, UInt16) -> Void)?

    private var mode: UInt16 = 0
    private var kind: Entry.Kind = .file
    private var locked = false
    private var toggles: [(bit: UInt16, label: String, button: UIButton)] = []
    private let octalLabel = UILabel()
    private let stringLabel = UILabel()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none

        octalLabel.font = Theme.mono(22, .semibold)
        stringLabel.font = Theme.mono(14)
        stringLabel.textColor = .secondaryLabel
        stringLabel.textAlignment = .right
        let summary = UIStackView(arrangedSubviews: [octalLabel, stringLabel])
        summary.alignment = .firstBaseline
        summary.distribution = .equalSpacing

        let header = makeRow(title: "", views: [L("Read"), L("Write"), L("Execute")].map { text -> UIView in
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            return label
        })

        var rows: [UIView] = [summary, header]
        for (title, shift) in [(L("Owner"), UInt16(6)), (L("Group"), UInt16(3)), (L("Everyone"), UInt16(0))] {
            let buttons = [(UInt16(4) << shift, "r"), (UInt16(2) << shift, "w"), (UInt16(1) << shift, "x")].map { bit, letter in
                makeToggle(bit: bit, label: letter, accessibility: "\(title) \(letter)")
            }
            rows.append(makeRow(title: title, views: buttons))
        }
        let special = [(UInt16(0o4000), L("Set UID")), (UInt16(0o2000), L("Set GID")), (UInt16(0o1000), L("Sticky"))].map { bit, title in
            makeToggle(bit: bit, label: title, accessibility: title)
        }
        rows.append(makeRow(title: L("Special"), views: special))

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: summary)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeRow(title: String, views: [UIView]) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true
        let cells = UIStackView(arrangedSubviews: views)
        cells.distribution = .fillEqually
        cells.spacing = 6
        let row = UIStackView(arrangedSubviews: [label, cells])
        row.alignment = .center
        row.spacing = 8
        return row
    }

    private func makeToggle(bit: UInt16, label: String, accessibility: String) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityLabel = accessibility
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.toggle(bit) }, for: .primaryActionTriggered)
        toggles.append((bit, label, button))
        return button
    }

    func configure(mode: UInt16, kind: Entry.Kind, locked: Bool) {
        self.mode = mode
        self.kind = kind
        self.locked = locked
        refresh()
    }

    private func toggle(_ bit: UInt16) {
        guard !locked else { return }
        let old = mode
        mode ^= bit
        Haptics.tap()
        refresh()
        onChange?(mode, old)
    }

    private func refresh() {
        octalLabel.text = Format.octal(mode)
        stringLabel.text = Format.permissions(mode, kind: kind)
        for toggle in toggles {
            let on = mode & toggle.bit != 0
            var config: UIButton.Configuration = on ? .tinted() : .gray()
            config.cornerStyle = .medium
            config.buttonSize = .small
            config.baseForegroundColor = on ? tintColor : .tertiaryLabel
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
            var title = AttributedString(toggle.label)
            title.font = toggle.label.count == 1 ? Theme.mono(15, .semibold) : .systemFont(ofSize: 12, weight: .medium)
            config.attributedTitle = title
            toggle.button.configuration = config
            toggle.button.isEnabled = !locked
            toggle.button.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        refresh()
    }
}
