import UIKit
import Darwin

/// Start screen of the Files tab: locations, favorites, recent files.
final class HomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private struct Location {
        let title: String
        let symbol: String
        let color: UIColor
        let path: String
        var isTrash = false
    }

    private enum Section {
        case locations, favorites, recents
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var locations: [Location] = []
    private var favorites: [String] = []
    private var recents: [String] = []
    private var sections: [Section] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Files")
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Go to Folder…"), image: UIImage(systemName: "arrow.right.circle"),
                                                            primaryAction: UIAction { [weak self] _ in
            self?.presentModal(GoToViewController(start: "/var/mobile/"))
        }, menu: nil)
        navigationItem.leftBarButtonItem = editButtonItem

        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.allowsSelectionDuringEditing = false
        view.addSubview(tableView)

        locations = makeLocations()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .bookmarksChanged, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let selected = tableView.indexPathForSelectedRow { tableView.deselectRow(at: selected, animated: animated) }
        reload()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
    }

    private func makeLocations() -> [Location] {
        var list: [Location] = [Location(title: L("Root"), symbol: "internaldrive.fill", color: .systemGray, path: "/")]
        let jb = JB.displayRoot
        if !jb.isEmpty { list.append(Location(title: L("Jailbreak"), symbol: "lock.open.fill", color: .systemOrange, path: jb)) }
        list += [
            Location(title: L("Mobile"), symbol: "person.fill", color: .systemBlue, path: "/var/mobile"),
            Location(title: L("Media"), symbol: "photo.fill", color: .systemPink, path: "/var/mobile/Media"),
            Location(title: L("Preferences"), symbol: "gearshape.fill", color: .systemGray2, path: "/var/mobile/Library/Preferences"),
        ]
        if JB.scheme == "roothide" {
            list.append(Location(title: L("Tweak Preferences"), symbol: "slider.horizontal.3", color: .systemIndigo,
                                 path: JB.path("/var/mobile/Library/Preferences")))
        }
        let tweaks = JB.path("/Library/MobileSubstrate/DynamicLibraries")
        if !JB.root.isEmpty && FileManager.default.fileExists(atPath: tweaks) {
            list.append(Location(title: L("Tweaks"), symbol: "puzzlepiece.fill", color: .systemPurple,
                                 path: JB.displayRoot + "/Library/MobileSubstrate/DynamicLibraries"))
        }
        list += [
            Location(title: L("App Data"), symbol: "tray.full.fill", color: .systemGreen, path: "/var/mobile/Containers/Data/Application"),
            Location(title: L("App Bundles"), symbol: "square.grid.2x2.fill", color: .systemTeal, path: "/var/containers/Bundle/Application"),
            Location(title: L("App Groups"), symbol: "square.stack.3d.up.fill", color: .systemCyan, path: "/var/mobile/Containers/Shared/AppGroup"),
            Location(title: L("Trash"), symbol: "trash.fill", color: .systemRed, path: Engine.trashRoot, isTrash: true),
        ]
        return list
    }

    @objc private func reload() {
        favorites = Bookmarks.favorites
        recents = Bookmarks.recents
        sections = [.locations]
        if !favorites.isEmpty || isEditing { sections.append(.favorites) }
        if !recents.isEmpty { sections.append(.recents) }
        tableView.reloadData()
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .locations: return locations.count
        case .favorites: return favorites.count
        case .recents: return recents.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .locations: return L("Locations")
        case .favorites: return L("Favorites")
        case .recents: return L("Recent")
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard sections[section] == .locations, !FS.shared.isRoot else { return nil }
        return L("Limited access: the root helper is not running, so only files the mobile user can reach are available. Reinstalling Xixu usually fixes this.")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        c.secondaryTextProperties.font = .systemFont(ofSize: 12)
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.lineBreakMode = .byTruncatingHead
        c.textToSecondaryTextVerticalPadding = 2
        c.imageProperties.reservedLayoutSize = CGSize(width: 30, height: 30)
        c.imageToTextPadding = 14
        let dark = traitCollection.userInterfaceStyle == .dark
        switch sections[indexPath.section] {
        case .locations:
            let location = locations[indexPath.row]
            c.text = location.title
            c.image = Icons.squircle(location.symbol, location.color)
        case .favorites:
            let path = favorites[indexPath.row]
            c.text = path == "/" ? "/" : Paths.name(path)
            c.secondaryText = Paths.parent(path)
            c.image = Icons.folder(color: Theme.accent, size: 30)
        case .recents:
            let path = recents[indexPath.row]
            let entry = Entry(name: Paths.name(path), kind: .file, size: 0, mtime: 0, mode: 0o644, uid: 0, gid: 0)
            c.text = Paths.name(path)
            c.secondaryText = Paths.parent(path)
            c.image = Icons.file(FileItem(path: path, entry: entry), size: 30, dark: dark)
        }
        cell.contentConfiguration = c
        cell.accessoryType = sections[indexPath.section] == .recents ? .none : .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let nav = navigationController else { return }
        switch sections[indexPath.section] {
        case .locations:
            let location = locations[indexPath.row]
            if location.isTrash {
                nav.pushViewController(TrashViewController(), animated: true)
            } else {
                Navigator.show(location.path, in: nav)
            }
        case .favorites:
            Navigator.show(favorites[indexPath.row], in: nav)
        case .recents:
            tableView.deselectRow(at: indexPath, animated: true)
            Opener.open(path: recents[indexPath.row], from: self)
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        sections[indexPath.section] != .locations
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        sections[indexPath.section] == .favorites
    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath,
                   toProposedIndexPath proposed: IndexPath) -> IndexPath {
        if proposed.section == source.section { return proposed }
        return IndexPath(row: proposed.section < source.section ? 0 : favorites.count - 1, section: source.section)
    }

    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        var list = favorites
        let moved = list.remove(at: source.row)
        list.insert(moved, at: destination.row)
        favorites = list
        NotificationCenter.default.removeObserver(self, name: .bookmarksChanged, object: nil)
        Bookmarks.favorites = list
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .bookmarksChanged, object: nil)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let section = sections[indexPath.section]
        guard section != .locations else { return nil }
        let remove = UIContextualAction(style: .destructive, title: L("Remove")) { [weak self] _, _, done in
            guard let self = self else { return done(false) }
            if section == .favorites {
                Bookmarks.favorites = self.favorites.filter { $0 != self.favorites[indexPath.row] }
            } else {
                Bookmarks.recents = self.recents.filter { $0 != self.recents[indexPath.row] }
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let section = sections[indexPath.section]
        let path: String
        switch section {
        case .locations:
            let location = locations[indexPath.row]
            if location.isTrash { return nil }
            path = location.path
        case .favorites: path = favorites[indexPath.row]
        case .recents: path = recents[indexPath.row]
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(title: L("Info"), image: UIImage(systemName: "info.circle")) { _ in
                    self?.presentModal(InfoViewController(path: path))
                },
                UIAction(title: L("Copy Path"), image: UIImage(systemName: "doc.on.clipboard")) { _ in Ops.copyPaths([path]) },
            ]
            if section == .recents {
                actions.insert(UIAction(title: L("Show in Folder"), image: UIImage(systemName: "folder")) { _ in
                    RootController.shared?.reveal(path, isDirectory: false)
                }, at: 0)
                actions.append(UIAction(title: L("Clear Recents"), image: UIImage(systemName: "clock.arrow.circlepath"),
                                        attributes: .destructive) { _ in Bookmarks.recents = [] })
            } else if section == .favorites {
                actions.append(UIAction(title: L("Remove from Favorites"), image: UIImage(systemName: "star.slash"),
                                        attributes: .destructive) { _ in Bookmarks.toggleFavorite(path) })
            } else if !Bookmarks.isFavorite(path) {
                actions.append(UIAction(title: L("Add to Favorites"), image: UIImage(systemName: "star")) { _ in
                    Bookmarks.toggleFavorite(path)
                })
            }
            return UIMenu(children: actions)
        }
    }
}

// MARK: - Trash

final class TrashViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var entries: [Entry] = []
    private var loaded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Trash")
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Empty"), primaryAction: UIAction { [weak self] _ in
            self?.emptyTrash()
        })
        navigationItem.rightBarButtonItem?.tintColor = .systemRed

        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.rowHeight = UITableView.automaticDimension
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        tableView.refreshControl = refresh
        view.addSubview(tableView)

        NotificationCenter.default.addObserver(self, selector: #selector(load), name: .filesChanged, object: nil)
        load()
    }

    @objc private func load() {
        Task { @MainActor in
            do {
                let list = try await FS.shared.call(Request(op: "trashList")).entries ?? []
                self.entries = list.sorted { $0.mtime > $1.mtime }
                self.loaded = true
                self.tableView.backgroundView = list.isEmpty ? EmptyStateView(title: L("Trash Is Empty"),
                    message: L("Deleted items stay here until you empty the Trash."), symbol: "trash") : nil
            } catch {
                self.entries = []
                self.tableView.backgroundView = EmptyStateView(title: L("Can't Open Trash"), message: error.localizedDescription)
            }
            self.navigationItem.rightBarButtonItem?.isEnabled = !self.entries.isEmpty
            self.tableView.refreshControl?.endRefreshing()
            self.tableView.reloadData()
        }
    }

    private func emptyTrash() {
        guard !entries.isEmpty else { return }
        confirm(title: L("Empty Trash?"), message: LF("%@ will be deleted permanently. This can't be undone.", Ops.countText(entries.count)),
                action: L("Empty Trash"), source: navigationItem.rightBarButtonItem) {
            Task { @MainActor in
                do {
                    _ = try await Activity.shared.run(L("Emptying Trash"), Request(op: "emptyTrash"))
                    Haptics.success()
                } catch {
                    self.showError(error)
                }
                announceChanges([Engine.trashRoot])
            }
        }
    }

    private func putBack(_ entry: Entry) {
        guard let slot = entry.dir else { return }
        Ops.restore([slot], from: self)
    }

    private func deleteForever(_ entry: Entry, source: UIView?) {
        guard let slot = entry.dir else { return }
        Ops.confirmPermanentDelete([slot], from: self, source: source)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        c.text = entry.name
        c.textProperties.lineBreakMode = .byTruncatingMiddle
        let origin = entry.label.map(Paths.parent) ?? "?"
        c.secondaryText = LF("From %@ · %@", origin, Format.date(entry.mtime))
        c.secondaryTextProperties.font = Theme.digits(13)
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        c.image = Icons.file(FileItem(path: Paths.join(entry.dir ?? "/", entry.name), entry: entry), size: 34,
                             dark: traitCollection.userInterfaceStyle == .dark)
        c.imageProperties.reservedLayoutSize = CGSize(width: 34, height: 34)
        c.imageToTextPadding = 14
        cell.contentConfiguration = c
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries[indexPath.row]
        let alert = UIAlertController(title: entry.name, message: entry.label.map { LF("Originally in %@", Paths.parent($0)) },
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: L("Put Back"), style: .default) { [weak self] _ in self?.putBack(entry) })
        alert.addAction(UIAlertAction(title: L("Delete Permanently"), style: .destructive) { [weak self] _ in
            self?.deleteForever(entry, source: nil)
        })
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        if let pop = alert.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
        }
        present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let entry = entries[indexPath.row]
        let action = UIContextualAction(style: .normal, title: L("Put Back")) { [weak self] _, _, done in
            self?.putBack(entry)
            done(true)
        }
        action.image = UIImage(systemName: "arrow.uturn.backward")
        action.backgroundColor = Theme.accent
        return UISwipeActionsConfiguration(actions: [action])
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let entry = entries[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: L("Delete")) { [weak self] _, _, done in
            self?.deleteForever(entry, source: tableView.cellForRow(at: indexPath))
            done(false)
        }
        action.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [action])
    }
}

// MARK: - Go to folder

final class GoToViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let field = UITextField()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var suggestions: [Entry] = []
    private var suggestionDirectory = ""
    private var listing: [Entry] = []
    private var listedDirectory: String?
    private var timer: Timer?

    init(start: String) {
        super.init(nibName: nil, bundle: nil)
        field.text = start.hasSuffix("/") ? start : start + "/"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Go to Folder")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Go"), primaryAction: UIAction { [weak self] _ in
            self?.go()
        })
        navigationItem.rightBarButtonItem?.style = .done
        if let sheet = navigationController?.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }

        field.font = Theme.mono(16)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.keyboardType = .URL
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.backgroundColor = .secondarySystemBackground
        field.layer.cornerRadius = 10
        field.layer.cornerCurve = .continuous
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.addAction(UIAction { [weak self] _ in self?.scheduleUpdate() }, for: .editingChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            field.heightAnchor.constraint(equalToConstant: 44),
            tableView.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        update()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    private var typedPath: String {
        var text = field.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if text.hasPrefix("~") { text = "/var/mobile" + text.dropFirst() }
        if !text.hasPrefix("/") { text = "/" + text }
        return text
    }

    private func scheduleUpdate() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in self?.update() }
    }

    private func update() {
        let text = typedPath
        let directory = text.hasSuffix("/") ? String(text.dropLast()).isEmpty ? "/" : String(text.dropLast()) : Paths.parent(text)
        let prefix = text.hasSuffix("/") ? "" : Paths.name(text)
        if directory == listedDirectory {
            filter(prefix: prefix, directory: directory)
            return
        }
        Task { @MainActor in
            let entries = (try? await FS.shared.list(directory)) ?? []
            self.listing = entries
            self.listedDirectory = directory
            self.filter(prefix: prefix, directory: directory)
        }
    }

    private func filter(prefix: String, directory: String) {
        suggestionDirectory = directory
        let lower = prefix.lowercased()
        suggestions = listing
            .filter { lower.isEmpty ? !$0.name.hasPrefix(".") : $0.name.lowercased().hasPrefix(lower) }
            .sorted { a, b in
                let ad = a.kind == .directory || a.linkDir == true
                let bd = b.kind == .directory || b.linkDir == true
                if ad != bd { return ad }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        if suggestions.count > 300 { suggestions = Array(suggestions.prefix(300)) }
        tableView.reloadData()
    }

    private func go() {
        var target = typedPath
        if target.count > 1 && target.hasSuffix("/") { target.removeLast() }
        Task { @MainActor in
            do {
                let info = try await FS.shared.stat(target)
                let isDirectory = info.entry.kind == .directory || info.entry.linkDir == true
                RootController.shared?.reveal(target, isDirectory: isDirectory)
            } catch {
                Haptics.error()
                self.showError(error, title: L("Can't Go There"))
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        go()
        return false
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { suggestions.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = suggestions[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.cell()
        c.text = entry.name
        c.textProperties.font = Theme.mono(15)
        c.image = Icons.file(FileItem(path: Paths.join(suggestionDirectory, entry.name), entry: entry), size: 26,
                             dark: traitCollection.userInterfaceStyle == .dark)
        cell.contentConfiguration = c
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = suggestions[indexPath.row]
        let full = Paths.join(suggestionDirectory, entry.name)
        if entry.kind == .directory || entry.linkDir == true {
            field.text = full + "/"
            update()
        } else {
            field.text = full
            go()
        }
    }
}
