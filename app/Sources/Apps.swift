import UIKit

/// Installed apps with quick access to their folders.
final class AppsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let segmented = UISegmentedControl(items: [L("User"), L("System")])
    private var all: [AppRegistry.App] = []
    private var visible: [AppRegistry.App] = []
    private var query = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Apps")
        navigationItem.largeTitleDisplayMode = .always

        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = L("Name or Bundle ID")
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        segmented.selectedSegmentIndex = 0
        segmented.addAction(UIAction { [weak self] _ in self?.filter() }, for: .valueChanged)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        segmented.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(segmented)
        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: header.layoutMarginsGuide.trailingAnchor),
            segmented.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        tableView.tableHeaderView = header

        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.rowHeight = 58
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.load(force: true) }, for: .valueChanged)
        tableView.refreshControl = refresh
        view.addSubview(tableView)

        NotificationCenter.default.addObserver(self, selector: #selector(appsLoaded), name: .appsLoaded, object: nil)
        load(force: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
        if let selected = tableView.indexPathForSelectedRow { tableView.deselectRow(at: selected, animated: animated) }
    }

    @objc private func appsLoaded() {
        all = AppRegistry.shared.apps
        filter()
    }

    private func load(force: Bool) {
        if all.isEmpty { tableView.backgroundView = EmptyStateView(title: nil, loading: true) }
        DispatchQueue.global(qos: .userInitiated).async {
            if force { AppRegistry.shared.reloadNow() }
            let apps = AppRegistry.shared.apps
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.all = apps
                self.tableView.refreshControl?.endRefreshing()
                self.filter()
            }
        }
    }

    private func filter() {
        let system = segmented.selectedSegmentIndex == 1
        visible = all.filter { app in
            guard app.isSystem == system else { return false }
            guard !query.isEmpty else { return true }
            return app.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || app.bundleID.range(of: query, options: .caseInsensitive) != nil
        }
        if visible.isEmpty {
            tableView.backgroundView = EmptyStateView(title: query.isEmpty ? L("No Apps") : L("No Results"),
                                                      message: all.isEmpty ? L("LaunchServices returned no apps.") : nil,
                                                      symbol: query.isEmpty ? "square.grid.2x2" : "magnifyingglass")
        } else {
            tableView.backgroundView = nil
        }
        tableView.reloadData()
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        filter()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        visible.isEmpty ? nil : (visible.count == 1 ? L("1 app") : LF("%d apps", visible.count))
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let app = visible[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "app") ?? UITableViewCell(style: .default, reuseIdentifier: "app")
        var c = UIListContentConfiguration.subtitleCell()
        c.text = app.name
        c.secondaryText = app.version.isEmpty ? app.bundleID : "\(app.bundleID) · \(app.version)"
        c.secondaryTextProperties.font = .systemFont(ofSize: 13)
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        c.textToSecondaryTextVerticalPadding = 3
        c.image = AppRegistry.shared.icon(for: app.bundleID, size: 36) ?? Icons.squircle("app.fill", .systemGray3, size: 36)
        c.imageProperties.maximumSize = CGSize(width: 36, height: 36)
        c.imageProperties.reservedLayoutSize = CGSize(width: 36, height: 36)
        c.imageToTextPadding = 12
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        navigationController?.pushViewController(AppDetailViewController(app: visible[indexPath.row]), animated: true)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let app = visible[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions: [UIMenuElement] = []
            if let bundle = app.bundlePath {
                actions.append(UIAction(title: L("Show App Bundle"), image: UIImage(systemName: "app")) { _ in
                    RootController.shared?.reveal(bundle)
                })
            }
            if let data = app.dataPath {
                actions.append(UIAction(title: L("Show Data Container"), image: UIImage(systemName: "tray.full")) { _ in
                    RootController.shared?.reveal(data)
                })
            }
            actions.append(UIAction(title: L("Open App"), image: UIImage(systemName: "arrow.up.forward.app")) { _ in
                AppRegistry.shared.open(app.bundleID)
            })
            actions.append(UIAction(title: L("Copy Bundle ID"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = app.bundleID
                RootController.shared?.toast(L("Copied"))
            })
            return UIMenu(children: actions)
        }
    }
}

final class AppDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Row {
        case header
        case folder(String, String, String)
        case file(String, String, String)
        case executable(String)
        case open
        case copyID
        case manage(String, String, UIColor, Bool)
    }

    private let app: AppRegistry.App
    private var sections: [(title: String?, rows: [Row])] = []
    private var preferencesPath: String?
    private var executablePath: String?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(app: AppRegistry.App) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
        title = app.name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)
        build()
        Task { @MainActor in await self.inspect() }
    }

    private func inspect() async {
        var candidates: [String] = []
        if let data = app.dataPath { candidates.append(data + "/Library/Preferences/\(app.bundleID).plist") }
        candidates.append("/var/mobile/Library/Preferences/\(app.bundleID).plist")
        if let exists = try? await FS.shared.exists(candidates) {
            preferencesPath = zip(candidates, exists).first { $0.1 }?.0
        }
        if let bundle = app.bundlePath,
           let data = try? await FS.shared.read(bundle + "/Info.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let executable = plist["CFBundleExecutable"] as? String {
            executablePath = bundle + "/" + executable
        }
        build()
    }

    private func build() {
        var result: [(String?, [Row])] = [(nil, [.header])]
        var folders: [Row] = []
        if let bundle = app.bundlePath { folders.append(.folder(L("App Bundle"), bundle, "app")) }
        if let data = app.dataPath { folders.append(.folder(L("Data Container"), data, "tray.full")) }
        for group in app.groups { folders.append(.folder(group.id, group.path, "square.stack.3d.up")) }
        if !folders.isEmpty { result.append((L("Folders"), folders)) }

        var files: [Row] = []
        if let bundle = app.bundlePath { files.append(.file("Info.plist", bundle + "/Info.plist", "list.bullet.indent")) }
        if let prefs = preferencesPath { files.append(.file(L("Preferences"), prefs, "slider.horizontal.3")) }
        if let executable = executablePath { files.append(.executable(executable)) }
        if !files.isEmpty { result.append((L("Files"), files)) }

        var manage: [Row] = []
        if app.bundlePath != nil {
            manage.append(.manage(L("Home Screen Name…"), "character.cursor.ibeam", .systemBlue, false))
        }
        if app.dataPath != nil {
            manage.append(.manage(L("Back Up Data"), "arrow.up.doc.fill", .systemGreen, false))
            manage.append(.manage(L("Restore Backup…"), "clock.arrow.circlepath", .systemOrange, false))
        }
        if app.bundlePath != nil {
            manage.append(.manage(L("Export as IPA"), "square.and.arrow.up.fill", .systemIndigo, false))
        }
        if !manage.isEmpty { result.append((L("Manage"), manage)) }

        result.append((nil, [.open, .copyID]))
        sections = result
        tableView.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].title == L("Manage")
            ? L("Backups are saved in /var/mobile/Documents/Xixu Backups. Exported App Store apps stay encrypted and only install for the same Apple ID.")
            : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        c.secondaryTextProperties.font = .systemFont(ofSize: 12)
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.lineBreakMode = .byTruncatingHead
        c.textToSecondaryTextVerticalPadding = 2
        c.imageProperties.reservedLayoutSize = CGSize(width: 30, height: 30)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .header:
            c.text = app.name
            c.textProperties.font = .systemFont(ofSize: 20, weight: .semibold)
            let type = app.isSystem ? L("System") : L("User")
            c.secondaryText = [app.bundleID, app.version, type].filter { !$0.isEmpty }.joined(separator: " · ")
            c.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            c.secondaryTextProperties.numberOfLines = 2
            c.image = AppRegistry.shared.icon(for: app.bundleID, size: 60) ?? Icons.squircle("app.fill", .systemGray3, size: 60)
            c.imageProperties.maximumSize = CGSize(width: 60, height: 60)
            c.imageProperties.reservedLayoutSize = CGSize(width: 60, height: 60)
            c.imageToTextPadding = 14
            c.textToSecondaryTextVerticalPadding = 4
            cell.selectionStyle = .none
        case let .folder(title, path, symbol):
            c.text = title
            c.secondaryText = path
            c.image = Icons.squircle(symbol, symbol == "app" ? .systemTeal : (symbol == "tray.full" ? .systemGreen : .systemCyan))
            cell.accessoryType = .disclosureIndicator
        case let .file(title, path, symbol):
            c.text = title
            c.secondaryText = path
            c.image = Icons.squircle(symbol, symbol == "list.bullet.indent" ? .systemGray : .systemIndigo)
            cell.accessoryType = .disclosureIndicator
        case .executable(let path):
            c.text = L("Executable & Entitlements")
            c.secondaryText = path
            c.image = Icons.squircle("cpu", .systemPurple)
            cell.accessoryType = .disclosureIndicator
        case .open:
            c = UIListContentConfiguration.cell()
            c.text = L("Open App")
            c.textProperties.color = Theme.accent
        case .copyID:
            c = UIListContentConfiguration.cell()
            c.text = L("Copy Bundle ID")
            c.textProperties.color = Theme.accent
        case let .manage(title, symbol, color, _):
            c = UIListContentConfiguration.cell()
            c.text = title
            c.image = Icons.squircle(symbol, color)
        }
        cell.contentConfiguration = c
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .header:
            break
        case let .folder(_, path, _):
            RootController.shared?.reveal(path)
        case let .file(_, path, _):
            Opener.open(path: path, from: self)
        case .executable(let path):
            presentModal(MachOViewController(path: path))
        case .open:
            AppRegistry.shared.open(app.bundleID)
        case .copyID:
            UIPasteboard.general.string = app.bundleID
            Haptics.tap()
            RootController.shared?.toast(L("Copied"))
        case let .manage(title, _, _, _):
            switch title {
            case L("Home Screen Name…"): Ops.renameApp(app, from: self)
            case L("Back Up Data"): AppBackups.backup(app, from: self)
            case L("Restore Backup…"): AppBackups.restore(app, executable: executablePath.map(Paths.name), from: self)
            default: AppBackups.exportIPA(app, from: self)
            }
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let path: String
        switch sections[indexPath.section].rows[indexPath.row] {
        case let .folder(_, p, _): path = p
        case let .file(_, p, _): path = p
        case .executable(let p): path = p
        default: return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: L("Copy Path"), image: UIImage(systemName: "doc.on.clipboard")) { _ in
                Ops.copyPaths([path])
            }])
        }
    }
}
