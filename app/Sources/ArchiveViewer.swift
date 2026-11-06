import UIKit

/// Lists what is inside an archive and extracts it next to itself.
final class ArchiveViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {
    private let path: String
    private var entries: [Entry] = []
    private var visible: [Entry] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let titleView: TitleView

    init(path: String) {
        self.path = path
        titleView = TitleView(title: Paths.name(path), subtitle: L("Reading…"))
        super.init(nibName: nil, bundle: nil)
        title = Paths.name(path)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.titleView = titleView
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let extract = UIBarButtonItem(title: L("Extract"), primaryAction: UIAction { [weak self] _ in self?.extract() })
        let ext = Paths.split(path).ext.lowercased()
        if ext == "ipa" || ext == "tipa" {
            let install = UIBarButtonItem(title: L("Install"), primaryAction: UIAction { [weak self] _ in
                guard let self = self else { return }
                Ops.installIPA(self.path, from: self)
            })
            install.style = .done
            navigationItem.rightBarButtonItems = [install, extract]
        } else {
            extract.style = .done
            navigationItem.rightBarButtonItem = extract
        }

        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundView = EmptyStateView(title: nil, loading: true)
        view.addSubview(tableView)

        Task { @MainActor in
            do {
                let list = try await FS.shared.call(Request(op: "archiveList", path: self.path)).entries ?? []
                self.entries = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.visible = self.entries
                let files = list.filter { $0.kind != .directory }
                let total = files.reduce(Int64(0)) { $0 + max($1.size, 0) }
                self.titleView.subtitle.text = "\(Ops.countText(files.count)) · \(Format.bytes(total))"
                self.tableView.backgroundView = list.isEmpty ? EmptyStateView(title: L("Empty Archive")) : nil
                self.tableView.reloadData()
            } catch {
                self.titleView.subtitle.text = nil
                self.navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
                self.tableView.backgroundView = EmptyStateView(title: L("Can't Read Archive"), message: error.localizedDescription)
            }
        }
    }

    private func extract() {
        Ops.extract(path, from: self) { [weak self] output in
            self?.dismiss(animated: true) {
                RootController.shared?.reveal(output, isDirectory: true)
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        visible = text.isEmpty ? entries : entries.filter { $0.name.range(of: text, options: .caseInsensitive) != nil }
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = visible[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry") ?? UITableViewCell(style: .default, reuseIdentifier: "entry")
        var c = UIListContentConfiguration.valueCell()
        c.text = entry.name
        c.textProperties.font = Theme.mono(13)
        c.textProperties.lineBreakMode = .byTruncatingHead
        c.textProperties.numberOfLines = 1
        c.secondaryText = entry.kind == .directory ? nil : Format.bytes(entry.size)
        c.secondaryTextProperties.font = Theme.digits(13)
        c.image = Theme.symbol(entry.kind == .directory ? "folder.fill" : (entry.kind == .symlink ? "link" : "doc"), 15)
        c.imageProperties.tintColor = entry.kind == .directory ? Theme.accent : .secondaryLabel
        c.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
        cell.contentConfiguration = c
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let name = visible[indexPath.row].name
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: L("Copy Path"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = name
            }])
        }
    }
}

/// Debian package: control fields, file list, install.
final class DebViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private struct Field {
        let name: String
        var value: String
    }

    private enum Row {
        case header
        case field(String, String)
        case text(String)
        case files
    }

    private let path: String
    private var fields: [Field] = []
    private var files: [String] = []
    private var sections: [(title: String?, rows: [Row])] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(path: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
        title = Paths.name(path)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let install = UIBarButtonItem(title: L("Install"), primaryAction: UIAction { [weak self] _ in
            guard let self = self else { return }
            Ops.install(self.path, from: self)
        })
        install.style = .done
        install.isEnabled = false
        let more = UIBarButtonItem(title: L("More"), image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: UIMenu(children: [
            UIAction(title: L("Extract"), image: UIImage(systemName: "tray.and.arrow.up")) { [weak self] _ in
                guard let self = self else { return }
                Ops.extract(self.path, from: self) { output in
                    self.dismiss(animated: true) { RootController.shared?.reveal(output, isDirectory: true) }
                }
            },
            UIAction(title: L("Show Contents"), image: UIImage(systemName: "doc.zipper")) { [weak self] _ in
                guard let self = self else { return }
                self.navigationController?.pushViewController(ArchiveViewController(path: self.path), animated: true)
            },
        ]))
        navigationItem.rightBarButtonItems = [install, more]

        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundView = EmptyStateView(title: nil, loading: true)
        view.addSubview(tableView)

        Task { @MainActor in
            do {
                let response = try await FS.shared.call(Request(op: "debInfo", path: self.path))
                self.fields = Self.parse(response.text ?? "")
                self.files = (response.strings ?? []).compactMap(Self.fileName)
                self.tableView.backgroundView = nil
                install.isEnabled = true
                self.build()
            } catch {
                self.tableView.backgroundView = EmptyStateView(title: L("Can't Read Package"), message: error.localizedDescription)
            }
        }
    }

    private static func parse(_ text: String) -> [Field] {
        var result: [Field] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !result.isEmpty else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                result[result.count - 1].value += "\n" + (trimmed == "." ? "" : trimmed)
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                result.append(Field(name: name, value: value))
            }
        }
        return result
    }

    /// "drwxr-xr-x root/wheel 0 2024-01-01 00:00 ./usr/" -> "/usr/"
    private static func fileName(_ line: String) -> String? {
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count == 6 else { return nil }
        var name = String(parts[5])
        if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        if name.hasPrefix("./") { name.removeFirst() }
        return name == "/" ? nil : name
    }

    private func value(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func build() {
        var result: [(String?, [Row])] = [(nil, [.header])]
        var details: [Row] = []
        for name in ["Package", "Version", "Architecture", "Section", "Author", "Maintainer"] {
            if let v = value(name), !v.isEmpty { details.append(.field(name, v)) }
        }
        if let size = value("Installed-Size"), let kb = Int64(size) {
            details.append(.field(L("Installed Size"), Format.bytes(kb * 1024)))
        }
        result.append((L("Package"), details))
        if let description = value("Description"), !description.isEmpty {
            result.append((L("Description"), [.text(description)]))
        }
        var relations: [Row] = []
        for name in ["Depends", "Pre-Depends", "Recommends", "Suggests", "Conflicts", "Breaks", "Replaces", "Provides"] {
            if let v = value(name), !v.isEmpty { relations.append(.field(name, v)) }
        }
        if !relations.isEmpty { result.append((L("Relationships"), relations)) }
        if !files.isEmpty { result.append((nil, [.files])) }
        sections = result
        tableView.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch sections[indexPath.section].rows[indexPath.row] {
        case .header:
            var c = UIListContentConfiguration.subtitleCell()
            c.text = value("Name") ?? value("Package") ?? Paths.name(path)
            c.textProperties.font = .systemFont(ofSize: 20, weight: .semibold)
            var parts: [String] = []
            if let version = value("Version") { parts.append(version) }
            if let author = value("Author") ?? value("Maintainer") {
                parts.append(author.replacingOccurrences(of: #"\s*<[^>]*>"#, with: "", options: .regularExpression))
            }
            c.secondaryText = parts.joined(separator: " · ")
            c.image = Theme.symbol("shippingbox", 30)
            c.imageProperties.tintColor = Theme.accent
            c.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            c.textToSecondaryTextVerticalPadding = 4
            cell.contentConfiguration = c
        case let .field(name, value):
            var c = UIListContentConfiguration.subtitleCell()
            c.text = name
            c.textProperties.font = .preferredFont(forTextStyle: .footnote)
            c.textProperties.color = .secondaryLabel
            c.secondaryText = value
            c.secondaryTextProperties.font = name == "Package" || name == "Architecture" ? Theme.mono(15) : .preferredFont(forTextStyle: .body)
            c.secondaryTextProperties.color = .label
            c.secondaryTextProperties.numberOfLines = 0
            c.textToSecondaryTextVerticalPadding = 3
            cell.contentConfiguration = c
        case .text(let text):
            var c = UIListContentConfiguration.cell()
            c.text = text
            c.textProperties.numberOfLines = 0
            cell.contentConfiguration = c
        case .files:
            var c = UIListContentConfiguration.valueCell()
            c.text = L("Files")
            c.secondaryText = "\(files.count)"
            c.image = UIImage(systemName: "list.bullet")
            cell.contentConfiguration = c
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if case .files = sections[indexPath.section].rows[indexPath.row] {
            navigationController?.pushViewController(DebFilesViewController(files: files), animated: true)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let text: String
        switch sections[indexPath.section].rows[indexPath.row] {
        case let .field(_, value): text = value
        case .text(let value): text = value
        default: return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: L("Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }])
        }
    }
}

private final class DebFilesViewController: UITableViewController, UISearchResultsUpdating {
    private let files: [String]
    private var visible: [String]

    init(files: [String]) {
        self.files = files
        visible = files
        super.init(style: .plain)
        title = L("Files")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        visible = text.isEmpty ? files : files.filter { $0.range(of: text, options: .caseInsensitive) != nil }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let name = visible[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "file") ?? UITableViewCell(style: .default, reuseIdentifier: "file")
        var c = UIListContentConfiguration.cell()
        c.text = name
        c.textProperties.font = Theme.mono(13)
        c.textProperties.lineBreakMode = .byTruncatingHead
        c.image = Theme.symbol(name.hasSuffix("/") ? "folder.fill" : "doc", 14)
        c.imageProperties.tintColor = name.hasSuffix("/") ? Theme.accent : .secondaryLabel
        c.imageProperties.reservedLayoutSize = CGSize(width: 20, height: 20)
        cell.contentConfiguration = c
        cell.selectionStyle = .none
        return cell
    }
}
