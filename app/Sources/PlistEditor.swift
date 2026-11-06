import UIKit

// MARK: - Model

private extension Notification.Name {
    static let plistDocumentChanged = Notification.Name("XixuPlistDocumentChanged")
}

final class PlistNode {
    enum Kind: CaseIterable {
        case dictionary, array, string, integer, real, boolean, date, data

        var title: String {
            switch self {
            case .dictionary: return L("Dictionary")
            case .array: return L("Array")
            case .string: return L("String")
            case .integer: return L("Integer")
            case .real: return L("Real")
            case .boolean: return L("Boolean")
            case .date: return L("Date")
            case .data: return L("Data")
            }
        }
    }

    var key: String
    var kind: Kind
    var children: [PlistNode] = []
    var string = ""
    var integer: Int64 = 0
    var real: Double = 0
    var boolean = false
    var date = Date()
    var data = Data()

    init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
    }

    init(key: String, value: Any) {
        self.key = key
        switch value {
        case let dict as [String: Any]:
            kind = .dictionary
            children = dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { PlistNode(key: $0, value: dict[$0]!) }
        case let array as [Any]:
            kind = .array
            children = array.enumerated().map { PlistNode(key: "\($0.offset)", value: $0.element) }
        case let s as String:
            kind = .string
            string = s
        case let d as Date:
            kind = .date
            date = d
        case let d as Data:
            kind = .data
            data = d
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                kind = .boolean
                boolean = n.boolValue
            } else if CFNumberIsFloatType(n) {
                kind = .real
                real = n.doubleValue
            } else {
                kind = .integer
                integer = n.int64Value
            }
        default:
            kind = .string
            string = "\(value)"
        }
    }

    var isContainer: Bool { kind == .dictionary || kind == .array }

    func value() -> Any {
        switch kind {
        case .dictionary:
            var dict: [String: Any] = [:]
            for child in children { dict[child.key] = child.value() }
            return dict
        case .array: return children.map { $0.value() }
        case .string: return string
        case .integer: return NSNumber(value: integer)
        case .real: return NSNumber(value: real)
        case .boolean: return NSNumber(value: boolean)
        case .date: return date
        case .data: return data
        }
    }

    func copy() -> PlistNode {
        let node = PlistNode(key: key, value: value())
        if kind == .array || kind == .dictionary { node.kind = kind }
        return node
    }

    var preview: String {
        switch kind {
        case .dictionary, .array: return children.count == 1 ? L("1 item") : LF("%d items", children.count)
        case .string: return string.replacingOccurrences(of: "\n", with: " ↵ ")
        case .integer: return "\(integer)"
        case .real: return "\(real)"
        case .boolean: return boolean ? "YES" : "NO"
        case .date: return Format.fullDate(date.timeIntervalSince1970)
        case .data:
            let head = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            return "<\(head)\(data.count > 16 ? "…" : "")>"
        }
    }

    var typeTag: String {
        switch kind {
        case .dictionary, .array: return "\(kind.title) · \(children.count)"
        case .data: return "\(kind.title) · \(Format.bytes(Int64(data.count)))"
        default: return kind.title
        }
    }

    func convert(to target: Kind) {
        guard target != kind else { return }
        let text: String
        switch kind {
        case .string: text = string
        case .integer: text = "\(integer)"
        case .real: text = "\(real)"
        case .boolean: text = boolean ? "1" : "0"
        case .date: text = ISO8601DateFormatter().string(from: date)
        case .data: text = String(decoding: data, as: UTF8.self)
        case .dictionary, .array: text = ""
        }
        switch target {
        case .string: string = text
        case .integer: integer = Int64(text) ?? Int64(Double(text) ?? 0)
        case .real: real = Double(text) ?? 0
        case .boolean: boolean = ["1", "true", "yes", "on"].contains(text.lowercased())
        case .date: date = ISO8601DateFormatter().date(from: text) ?? Date()
        case .data: data = Data(text.utf8)
        case .dictionary:
            if kind == .array {
                for (i, child) in children.enumerated() { child.key = "Item \(i)" }
            } else {
                children = []
            }
        case .array:
            if kind != .dictionary { children = [] }
        }
        kind = target
        if kind == .array { renumber() }
    }

    func renumber() {
        guard kind == .array else { return }
        for (i, child) in children.enumerated() { child.key = "\(i)" }
    }

    func uniqueKey(_ base: String) -> String {
        if !children.contains(where: { $0.key == base }) { return base }
        var n = 2
        while children.contains(where: { $0.key == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }
}

final class PlistDocument {
    let path: String
    let root: PlistNode
    var format: PropertyListSerialization.PropertyListFormat
    var dirty = false {
        didSet { NotificationCenter.default.post(name: .plistDocumentChanged, object: self) }
    }

    init(path: String, root: PlistNode, format: PropertyListSerialization.PropertyListFormat) {
        self.path = path
        self.root = root
        self.format = format
    }

    func encoded() throws -> Data {
        let target: PropertyListSerialization.PropertyListFormat = format == .binary ? .binary : .xml
        return try PropertyListSerialization.data(fromPropertyList: root.value(), format: target, options: 0)
    }

    func xml() -> String {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: root.value(), format: .xml, options: 0) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func changed() {
        dirty = true
    }
}

// MARK: - Editor

/// Shows one container of a property list. The root instance loads the file.
final class PlistEditorViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {
    private let path: String
    private var document: PlistDocument?
    private var node: PlistNode?
    private let isRoot: Bool
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var filter = ""
    private var visible: [PlistNode] = []

    init(path: String) {
        self.path = path
        isRoot = true
        super.init(nibName: nil, bundle: nil)
        title = Paths.name(path)
    }

    private init(document: PlistDocument, node: PlistNode) {
        path = document.path
        self.document = document
        self.node = node
        isRoot = false
        super.init(nibName: nil, bundle: nil)
        title = node.key
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.keyboardDismissMode = .onDrag
        view.addSubview(tableView)

        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true

        if isRoot {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.close()
            })
        }
        NotificationCenter.default.addObserver(self, selector: #selector(documentChanged), name: .plistDocumentChanged, object: nil)

        if document == nil {
            load()
        } else {
            refresh()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if document != nil { refresh() }
    }

    private func load() {
        tableView.backgroundView = EmptyStateView(title: nil, loading: true)
        Task { @MainActor in
            do {
                let data = try await FS.shared.read(self.path)
                var format = PropertyListSerialization.PropertyListFormat.xml
                let value = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
                let root = PlistNode(key: Paths.name(self.path), value: value)
                let document = PlistDocument(path: self.path, root: root, format: format)
                self.document = document
                self.node = root
                if format == .openStep {
                    RootController.shared?.toast(L("Old-style property list: it is saved as XML."))
                }
                self.refresh()
            } catch {
                self.tableView.backgroundView = nil
                self.showParseError(error)
            }
        }
    }

    private func showParseError(_ error: Error) {
        let message = (error as? XixuError)?.localizedDescription ?? L("This file isn't a valid property list.")
        let empty = EmptyStateView(title: L("Can't Read Property List"), message: message)
        tableView.backgroundView = empty
        let alert = UIAlertController(title: L("Can't Read Property List"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Open as Text"), style: .default) { [weak self] _ in
            guard let self = self else { return }
            let path = self.path
            let presenter = self.presentingViewController
            self.dismiss(animated: true) {
                presenter?.presentModal(TextEditorViewController(path: path), fullScreen: true)
            }
        })
        alert.addAction(UIAlertAction(title: L("Close"), style: .cancel) { [weak self] _ in self?.dismiss(animated: true) })
        present(alert, animated: true)
    }

    @objc private func documentChanged(_ note: Notification) {
        guard (note.object as? PlistDocument) === document else { return }
        updateItems()
    }

    private func refresh() {
        guard let node = node else { return }
        if filter.isEmpty {
            visible = node.children
        } else {
            visible = node.children.filter {
                $0.key.range(of: filter, options: .caseInsensitive) != nil || $0.preview.range(of: filter, options: .caseInsensitive) != nil
            }
        }
        tableView.backgroundView = visible.isEmpty ? EmptyStateView(title: filter.isEmpty ? L("No Items") : L("No Results")) : nil
        tableView.reloadData()
        updateItems()
    }

    private func updateItems() {
        guard let document = document, let node = node else { return }
        let save = UIBarButtonItem(title: L("Save"), primaryAction: UIAction { [weak self] _ in self?.save() })
        save.style = .done
        save.isEnabled = document.dirty
        let add = UIBarButtonItem(title: L("Add"), image: UIImage(systemName: "plus"), primaryAction: nil,
                                  menu: UIMenu(title: L("Add Item"), children: PlistNode.Kind.allCases.map { kind in
            UIAction(title: kind.title) { [weak self] _ in self?.addItem(kind, to: node) }
        }))
        var items = [save, add]
        if isRoot {
            items.append(UIBarButtonItem(title: L("More"), image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil,
                                         menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
                done(self?.rootMenu() ?? [])
            }])))
        }
        navigationItem.rightBarButtonItems = items
        isModalInPresentation = document.dirty
    }

    private func rootMenu() -> [UIMenuElement] {
        guard let document = document else { return [] }
        let formats: [UIMenuElement] = [
            UIAction(title: "XML", state: document.format != .binary ? .on : .off) { _ in
                document.format = .xml
                document.changed()
            },
            UIAction(title: L("Binary"), state: document.format == .binary ? .on : .off) { _ in
                document.format = .binary
                document.changed()
            },
        ]
        return [
            UIAction(title: L("View as XML"), image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { [weak self] _ in
                guard let self = self else { return }
                self.navigationController?.pushViewController(TextEditorViewController(title: Paths.name(self.path), text: document.xml()), animated: true)
            },
            UIAction(title: L("Copy as XML"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = document.xml()
                RootController.shared?.toast(L("Copied"))
            },
            UIMenu(title: L("Save Format"), image: UIImage(systemName: "doc.badge.gearshape"), children: formats),
        ]
    }

    func updateSearchResults(for searchController: UISearchController) {
        filter = searchController.searchBar.text ?? ""
        refresh()
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let node = node, !visible.isEmpty else { return nil }
        return node.typeTag
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = visible[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        c.text = node?.kind == .array ? LF("Item %@", item.key) : item.key
        c.textProperties.lineBreakMode = .byTruncatingMiddle
        c.secondaryText = item.typeTag
        c.secondaryTextProperties.font = .systemFont(ofSize: 12)
        c.secondaryTextProperties.color = .secondaryLabel
        c.textToSecondaryTextVerticalPadding = 2
        cell.contentConfiguration = c

        switch item.kind {
        case .dictionary, .array:
            cell.accessoryType = .disclosureIndicator
        case .boolean:
            let toggle = UISwitch()
            toggle.isOn = item.boolean
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                item.boolean = toggle?.isOn ?? false
                Haptics.tap()
                self?.document?.changed()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        default:
            let label = UILabel()
            label.text = item.preview
            label.font = item.kind == .string ? .preferredFont(forTextStyle: .body) : Theme.digits(16)
            label.textColor = .secondaryLabel
            label.lineBreakMode = .byTruncatingTail
            label.textAlignment = .right
            let width = min(label.intrinsicContentSize.width, tableView.bounds.width * 0.5)
            label.frame = CGRect(x: 0, y: 0, width: width, height: 22)
            cell.accessoryView = label
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let document = document else { return }
        let item = visible[indexPath.row]
        if item.isContainer {
            navigationController?.pushViewController(PlistEditorViewController(document: document, node: item), animated: true)
        } else {
            edit(item)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = visible[indexPath.row]
        var actions: [UIContextualAction] = []
        let delete = UIContextualAction(style: .destructive, title: L("Delete")) { [weak self] _, _, done in
            self?.remove(item)
            done(true)
        }
        actions.append(delete)
        if node?.kind == .dictionary {
            let rename = UIContextualAction(style: .normal, title: L("Rename")) { [weak self] _, _, done in
                self?.rename(item)
                done(true)
            }
            rename.backgroundColor = .systemGray
            actions.append(rename)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let item = visible[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            let types = PlistNode.Kind.allCases.map { kind in
                UIAction(title: kind.title, state: kind == item.kind ? .on : .off) { [weak self] _ in
                    item.convert(to: kind)
                    self?.document?.changed()
                    self?.refresh()
                }
            }
            var actions: [UIMenuElement] = [
                UIMenu(title: L("Change Type"), image: UIImage(systemName: "arrow.triangle.2.circlepath"), children: types),
                UIAction(title: L("Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    self?.duplicate(item)
                },
                UIAction(title: L("Copy Value"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    if item.isContainer,
                       let data = try? PropertyListSerialization.data(fromPropertyList: item.value(), format: .xml, options: 0) {
                        UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
                    } else {
                        UIPasteboard.general.string = item.kind == .string ? item.string : item.preview
                    }
                },
            ]
            if self.node?.kind == .dictionary {
                actions.append(UIAction(title: L("Rename"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.rename(item) })
            }
            actions.append(UIAction(title: L("Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.remove(item)
            })
            return UIMenu(children: actions)
        }
    }

    // MARK: - Editing

    private func edit(_ item: PlistNode) {
        switch item.kind {
        case .string:
            if item.string.contains("\n") || item.string.count > 80 {
                let editor = PlistStringEditor(text: item.string) { [weak self] value in
                    item.string = value
                    self?.document?.changed()
                    self?.refresh()
                }
                presentModal(editor)
            } else {
                prompt(title: item.key, text: item.string, action: L("Done")) { [weak self] value in
                    item.string = value
                    self?.document?.changed()
                    self?.refresh()
                }
            }
        case .integer, .real:
            let current = item.kind == .integer ? "\(item.integer)" : "\(item.real)"
            prompt(title: item.key, text: current, action: L("Done"), keyboard: .numbersAndPunctuation) { [weak self] value in
                if item.kind == .integer {
                    guard let number = Int64(value) else { return self?.invalid() ?? () }
                    item.integer = number
                } else {
                    guard let number = Double(value.replacingOccurrences(of: ",", with: ".")) else { return self?.invalid() ?? () }
                    item.real = number
                }
                self?.document?.changed()
                self?.refresh()
            }
        case .date:
            let picker = PlistDatePicker(date: item.date) { [weak self] date in
                item.date = date
                self?.document?.changed()
                self?.refresh()
            }
            presentModal(picker)
        case .data:
            guard item.data.count <= 4096 else {
                RootController.shared?.toast(L("Data larger than 4 KB can't be edited here."))
                return
            }
            let hex = item.data.map { String(format: "%02x", $0) }.joined(separator: " ")
            prompt(title: item.key, message: L("Hexadecimal bytes"), text: hex, action: L("Done")) { [weak self] value in
                let digits = value.filter { !$0.isWhitespace }
                guard digits.count % 2 == 0, digits.allSatisfy(\.isHexDigit) else { return self?.invalid() ?? () }
                var bytes: [UInt8] = []
                var index = digits.startIndex
                while index < digits.endIndex {
                    let next = digits.index(index, offsetBy: 2)
                    bytes.append(UInt8(digits[index..<next], radix: 16) ?? 0)
                    index = next
                }
                item.data = Data(bytes)
                self?.document?.changed()
                self?.refresh()
            }
        case .boolean, .dictionary, .array:
            break
        }
    }

    private func invalid() {
        Haptics.error()
        RootController.shared?.toast(L("Invalid value"))
    }

    private func addItem(_ kind: PlistNode.Kind, to container: PlistNode) {
        if container.kind == .dictionary {
            prompt(title: L("New Key"), text: container.uniqueKey("New Item"), action: L("Add")) { [weak self] key in
                guard !container.children.contains(where: { $0.key == key }) else {
                    Haptics.error()
                    RootController.shared?.toast(L("This key already exists."))
                    return
                }
                let node = PlistNode(key: key, kind: kind)
                container.children.append(node)
                container.children.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                self?.document?.changed()
                self?.refresh()
            }
        } else {
            container.children.append(PlistNode(key: "\(container.children.count)", kind: kind))
            document?.changed()
            refresh()
        }
    }

    private func remove(_ item: PlistNode) {
        guard let container = node else { return }
        container.children.removeAll { $0 === item }
        container.renumber()
        document?.changed()
        refresh()
    }

    private func duplicate(_ item: PlistNode) {
        guard let container = node, let index = container.children.firstIndex(where: { $0 === item }) else { return }
        let copy = item.copy()
        if container.kind == .dictionary { copy.key = container.uniqueKey(item.key) }
        container.children.insert(copy, at: index + 1)
        container.renumber()
        document?.changed()
        refresh()
    }

    private func rename(_ item: PlistNode) {
        guard let container = node, container.kind == .dictionary else { return }
        prompt(title: L("Rename Key"), text: item.key, action: L("Rename")) { [weak self] key in
            guard key != item.key else { return }
            guard !container.children.contains(where: { $0.key == key }) else {
                Haptics.error()
                RootController.shared?.toast(L("This key already exists."))
                return
            }
            item.key = key
            container.children.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            self?.document?.changed()
            self?.refresh()
        }
    }

    private func save(then completion: (() -> Void)? = nil) {
        guard let document = document else { return }
        Task { @MainActor in
            do {
                let data = try document.encoded()
                try await FS.shared.write(document.path, data: data)
                document.dirty = false
                Haptics.success()
                RootController.shared?.toast(L("Saved"))
                announceChanges([Paths.parent(document.path)])
                Ops.refreshAppIfNeeded(after: document.path)
                completion?()
            } catch {
                self.showError(error, title: L("Can't Save"))
            }
        }
    }

    private func close() {
        guard let document = document, document.dirty else {
            dismiss(animated: true)
            return
        }
        let alert = UIAlertController(title: L("Save Changes?"), message: L("Your changes are lost if you don't save them."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Save"), style: .default) { [weak self] _ in
            self?.save { self?.dismiss(animated: true) }
        })
        alert.addAction(UIAlertAction(title: L("Don't Save"), style: .destructive) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        present(alert, animated: true)
    }
}

/// Multi-line string value editor.
private final class PlistStringEditor: UIViewController {
    private let textView = UITextView()
    private let initial: String
    private let completion: (String) -> Void

    init(text: String, completion: @escaping (String) -> Void) {
        initial = text
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        title = L("Edit String")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.text = initial
        textView.font = .preferredFont(forTextStyle: .body)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self = self else { return }
            self.completion(self.textView.text)
            self.dismiss(animated: true)
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }
}

/// Date value editor.
private final class PlistDatePicker: UIViewController {
    private let picker = UIDatePicker()
    private let completion: (Date) -> Void

    init(date: Date, completion: @escaping (Date) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        picker.date = date
        title = L("Edit Date")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        picker.datePickerMode = .dateAndTime
        picker.preferredDatePickerStyle = .inline
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        if let sheet = navigationController?.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self = self else { return }
            self.completion(self.picker.date)
            self.dismiss(animated: true)
        })
    }
}
