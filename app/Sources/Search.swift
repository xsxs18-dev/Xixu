import UIKit

/// File system wide search with streamed results.
final class SearchViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UISearchResultsUpdating {
    private struct Scope {
        let title: String
        let path: String
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchController = UISearchController(searchResultsController: nil)
    private var scopes: [Scope] = []
    private var results: [FileItem] = []
    private var searchID: Int?
    private var running = false
    private var query = ""
    private var timer: Timer?
    private let statusLabel = UILabel()

    private var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentSearches") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(8)), forKey: "recentSearches") }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Search")
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .always

        scopes = [Scope(title: L("Everywhere"), path: "/"), Scope(title: L("Mobile"), path: "/var/mobile")]
        if !JB.root.isEmpty { scopes.append(Scope(title: L("Jailbreak"), path: JB.displayRoot)) }
        scopes.append(Scope(title: L("Apps"), path: "/var/mobile/Containers"))

        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = L("Files, folders, *.plist or /regex/")
        searchController.searchBar.scopeButtonTitles = scopes.map(\.title)
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.autocorrectionType = .no
        searchController.searchBar.spellCheckingType = .no
        searchController.automaticallyShowsScopeBar = false
        searchController.searchBar.showsScopeBar = true
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Options"), image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
                                                            primaryAction: nil, menu: UIMenu(children: [UIDeferredMenuElement.uncached { done in
            done([UIAction(title: L("Include Hidden Files"), state: Prefs.showHidden ? .on : .off) { _ in Prefs.showHidden.toggle() }])
        }]))

        statusLabel.font = Theme.digits(13, .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.frame = CGRect(x: 0, y: 0, width: 300, height: 34)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.rowHeight = UITableView.automaticDimension
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)
        updateState()
    }

    deinit {
        if let id = searchID { FS.shared.cancel(id) }
    }

    // MARK: - Searching

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard text != query else { return }
        query = text
        timer?.invalidate()
        if text.count >= 2 {
            timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in self?.start() }
        } else {
            cancel()
            results = []
            updateState()
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        timer?.invalidate()
        start()
        searchBar.resignFirstResponder()
    }

    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
        if !query.isEmpty { start() }
    }

    private func cancel() {
        if let id = searchID { FS.shared.cancel(id) }
        searchID = nil
        running = false
    }

    private func start() {
        cancel()
        guard !query.isEmpty else { return }
        var text = query
        var flags: [String] = []
        if text.count > 2 && text.hasPrefix("/") && text.hasSuffix("/") {
            flags.append("regex")
            text = String(text.dropFirst().dropLast())
        } else if text.contains("*") || text.contains("?") {
            flags.append("glob")
        }
        if Prefs.showHidden { flags.append("hidden") }
        let scopeIndex = max(0, min(searchController.searchBar.selectedScopeButtonIndex, scopes.count - 1))
        var request = Request(op: "search", path: scopes[scopeIndex].path, text: text, length: 3000, flags: flags)
        request.id = FS.shared.makeID()
        let id = request.id
        searchID = id
        running = true
        results = []
        recent = [query] + recent.filter { $0 != query }
        updateState()
        Task { @MainActor in
            do {
                _ = try await FS.shared.call(request) { [weak self] update in
                    guard let self = self, self.searchID == id, let entries = update.entries else { return }
                    let first = self.results.count
                    self.results += entries.compactMap { e in e.dir.map { FileItem(dir: $0, entry: e) } }
                    if first == 0 {
                        self.updateState()
                    } else {
                        let paths = (first..<self.results.count).map { IndexPath(row: $0, section: 0) }
                        UIView.performWithoutAnimation { self.tableView.insertRows(at: paths, with: .none) }
                        self.updateStatus()
                    }
                }
            } catch {
                if self.searchID == id, let e = error as? XixuError, !e.isCancelled { self.showError(error, title: L("Search Failed")) }
            }
            if self.searchID == id {
                self.searchID = nil
                self.running = false
                self.updateState()
            }
        }
    }

    private func updateStatus() {
        let count = results.count == 1 ? L("1 result") : LF("%d results", results.count)
        statusLabel.text = running ? LF("Searching… · %@", count) : count
        statusLabel.sizeToFit()
    }

    private func updateState() {
        if query.isEmpty && results.isEmpty {
            tableView.tableHeaderView = nil
            tableView.backgroundView = recent.isEmpty
                ? EmptyStateView(title: L("Search Your Files"), message: L("Find anything on the device by name, wildcard or regular expression."),
                                 symbol: "magnifyingglass")
                : nil
        } else if results.isEmpty {
            tableView.tableHeaderView = nil
            tableView.backgroundView = running ? EmptyStateView(title: nil, loading: true)
                : EmptyStateView(title: L("No Results"), symbol: "magnifyingglass")
        } else {
            tableView.backgroundView = nil
            updateStatus()
            let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 34))
            statusLabel.frame = CGRect(x: 20, y: 8, width: tableView.bounds.width - 40, height: 20)
            header.addSubview(statusLabel)
            tableView.tableHeaderView = header
        }
        tableView.reloadData()
    }

    private var showsRecent: Bool { query.isEmpty && results.isEmpty && !recent.isEmpty }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        showsRecent ? recent.count : results.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        showsRecent ? L("Recent Searches") : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if showsRecent {
            var c = UIListContentConfiguration.cell()
            c.text = recent[indexPath.row]
            c.image = UIImage(systemName: "clock.arrow.circlepath")
            c.imageProperties.tintColor = .tertiaryLabel
            cell.contentConfiguration = c
            return cell
        }
        let item = results[indexPath.row]
        var c = UIListContentConfiguration.subtitleCell()
        c.text = item.displayName
        c.textProperties.lineBreakMode = .byTruncatingMiddle
        var detail = item.parent
        if item.entry.kind == .file { detail += " · " + Format.bytes(item.entry.size) }
        c.secondaryText = detail
        c.secondaryTextProperties.font = Theme.digits(12)
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.lineBreakMode = .byTruncatingHead
        c.textToSecondaryTextVerticalPadding = 3
        c.image = Icons.file(item, size: 34, dark: traitCollection.userInterfaceStyle == .dark)
        c.imageProperties.reservedLayoutSize = CGSize(width: 34, height: 34)
        c.imageToTextPadding = 14
        cell.contentConfiguration = c
        cell.accessoryType = item.isDirectory ? .disclosureIndicator : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if showsRecent {
            let text = recent[indexPath.row]
            searchController.isActive = true
            searchController.searchBar.text = text
            query = text
            start()
            return
        }
        let item = results[indexPath.row]
        if item.isDirectory {
            RootController.shared?.reveal(item.path)
        } else {
            Opener.open(item, from: self, siblings: [])
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard !showsRecent else { return nil }
        let item = results[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            return ItemMenu.menu(for: [item], from: self, siblings: [], source: cell, currentDirectory: "")
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard showsRecent else { return nil }
        let remove = UIContextualAction(style: .destructive, title: L("Remove")) { [weak self] _, _, done in
            guard let self = self else { return done(false) }
            let text = self.recent[indexPath.row]
            self.recent = self.recent.filter { $0 != text }
            self.updateState()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }
}
