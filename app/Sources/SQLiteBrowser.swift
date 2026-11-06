import UIKit
import SQLite3

/// A private, staged copy of a database. The original file is never opened.
final class SQLiteDatabase {
    enum Value {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Int)

        var display: String {
            switch self {
            case .null: return "NULL"
            case .integer(let v): return "\(v)"
            case .real(let v): return "\(v)"
            case .text(let v): return v
            case .blob(let n): return LF("<blob %@>", Format.bytes(Int64(n)))
            }
        }

        var isNull: Bool {
            if case .null = self { return true }
            return false
        }
    }

    struct Result {
        var columns: [String] = []
        var rows: [[Value]] = []
    }

    struct Object {
        let name: String
        let type: String
        let sql: String
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            handle = nil
            throw XixuError(code: EIO, message: message, subject: Paths.name(path))
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func query(_ sql: String, limit: Int = 5000) throws -> Result {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw XixuError(code: EINVAL, message: String(cString: sqlite3_errmsg(handle)), subject: nil)
        }
        defer { sqlite3_finalize(statement) }
        var result = Result()
        let count = sqlite3_column_count(statement)
        for i in 0..<count {
            result.columns.append(sqlite3_column_name(statement, i).map { String(cString: $0) } ?? "?")
        }
        while result.rows.count < limit {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw XixuError(code: EIO, message: String(cString: sqlite3_errmsg(handle)), subject: nil)
            }
            var row: [Value] = []
            row.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, i)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, i)))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, i) {
                        row.append(.text(String(cString: text)))
                    } else {
                        row.append(.null)
                    }
                case SQLITE_BLOB: row.append(.blob(Int(sqlite3_column_bytes(statement, i))))
                default: row.append(.null)
                }
            }
            result.rows.append(row)
        }
        return result
    }

    func objects() throws -> [Object] {
        let result = try query("SELECT name, type, IFNULL(sql, '') FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name")
        return result.rows.compactMap { row in
            guard row.count == 3, case .text(let name) = row[0], case .text(let type) = row[1] else { return nil }
            let sql: String
            if case .text(let s) = row[2] { sql = s } else { sql = "" }
            return Object(name: name, type: type, sql: sql)
        }
    }

    func count(_ table: String) -> Int? {
        guard let result = try? query("SELECT COUNT(*) FROM \(Self.quote(table))"),
              let first = result.rows.first?.first, case .integer(let n) = first else { return nil }
        return Int(n)
    }
}

// MARK: - Tables

final class SQLiteViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let path: String
    private var database: SQLiteDatabase?
    private var objects: [SQLiteDatabase.Object] = []
    private var counts: [String: Int] = [:]
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Query"), image: UIImage(systemName: "text.cursor"),
                                                            primaryAction: UIAction { [weak self] _ in
            guard let self = self, let db = self.database else { return }
            self.navigationController?.pushViewController(SQLiteQueryViewController(database: db), animated: true)
        }, menu: nil)
        navigationItem.rightBarButtonItem?.isEnabled = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundView = EmptyStateView(title: nil, loading: true)
        view.addSubview(tableView)
        open()
    }

    private func open() {
        let candidates = [path, path + "-wal", path + "-shm"]
        Task { @MainActor in
            do {
                let exists = try await FS.shared.exists(candidates)
                let files = zip(candidates, exists).filter { $0.1 }.map { $0.0 }
                let staged = try await FS.shared.call(Request(op: "stage", paths: files, dest: Staging.newDirectory())).strings ?? []
                guard let copy = staged.first else { throw XixuError(code: ENOENT, message: "No copy", subject: Paths.name(self.path)) }
                let db = try SQLiteDatabase(path: copy)
                let objects = try db.objects()
                var counts: [String: Int] = [:]
                for object in objects where object.type == "table" {
                    counts[object.name] = db.count(object.name)
                }
                self.database = db
                self.objects = objects
                self.counts = counts
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.tableView.backgroundView = objects.isEmpty ? EmptyStateView(title: L("No Tables")) : nil
                self.tableView.reloadData()
            } catch {
                self.tableView.backgroundView = EmptyStateView(title: L("Can't Open Database"), message: error.localizedDescription)
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { objects.count }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        objects.isEmpty ? nil : L("You are browsing a private copy. The original database is never changed.")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let object = objects[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.valueCell()
        c.text = object.name
        c.textProperties.font = Theme.mono(15)
        c.image = UIImage(systemName: object.type == "view" ? "eye" : "tablecells")
        c.imageProperties.tintColor = object.type == "view" ? .secondaryLabel : Theme.accent
        if object.type == "view" {
            c.secondaryText = L("View")
        } else if let n = counts[object.name] {
            c.secondaryText = n == 1 ? L("1 row") : LF("%d rows", n)
        }
        c.secondaryTextProperties.font = Theme.digits(15)
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let db = database else { return }
        let object = objects[indexPath.row]
        let vc = SQLiteRowsViewController(database: db, title: object.name, table: object.name, schema: object.sql, result: nil)
        navigationController?.pushViewController(vc, animated: true)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let object = objects[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: L("Show Schema"), image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { _ in
                    self?.navigationController?.pushViewController(TextEditorViewController(title: object.name, text: object.sql), animated: true)
                },
                UIAction(title: L("Copy Name"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = object.name
                },
            ])
        }
    }
}

// MARK: - Rows

/// Rows of a table (paged) or of a query result.
final class SQLiteRowsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let database: SQLiteDatabase
    private let table: String?
    private let schema: String?
    private var result = SQLiteDatabase.Result()
    private var exhausted = false
    private var loadingPage = false
    private let pageSize = 100
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(database: SQLiteDatabase, title: String, table: String?, schema: String?, result: SQLiteDatabase.Result?) {
        self.database = database
        self.table = table
        self.schema = schema
        super.init(nibName: nil, bundle: nil)
        self.title = title
        if let result = result {
            self.result = result
            exhausted = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        if let schema = schema, !schema.isEmpty {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Schema"), primaryAction: UIAction { [weak self] _ in
                guard let self = self else { return }
                self.navigationController?.pushViewController(TextEditorViewController(title: self.title ?? "", text: schema), animated: true)
            })
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)
        if table != nil { loadMore() } else { updateBackground() }
    }

    private func loadMore() {
        guard let table = table, !exhausted, !loadingPage else { return }
        loadingPage = true
        let offset = result.rows.count
        do {
            let page = try database.query("SELECT * FROM \(SQLiteDatabase.quote(table)) LIMIT \(pageSize) OFFSET \(offset)", limit: pageSize)
            if result.columns.isEmpty { result.columns = page.columns }
            result.rows += page.rows
            exhausted = page.rows.count < pageSize
            tableView.reloadData()
        } catch {
            exhausted = true
            showError(error)
        }
        loadingPage = false
        updateBackground()
    }

    private func updateBackground() {
        tableView.backgroundView = result.rows.isEmpty ? EmptyStateView(title: L("No Rows")) : nil
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { result.rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        result.columns.isEmpty ? nil : result.columns.joined(separator: " · ")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = result.rows[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        let first = row.first
        c.text = first?.display.replacingOccurrences(of: "\n", with: " ") ?? ""
        c.textProperties.font = Theme.mono(14)
        c.textProperties.numberOfLines = 1
        c.textProperties.color = first?.isNull == true ? .tertiaryLabel : .label
        var details: [String] = []
        for (i, value) in row.enumerated().dropFirst().prefix(3) where i < result.columns.count {
            details.append("\(result.columns[i]): \(value.display.replacingOccurrences(of: "\n", with: " "))")
        }
        c.secondaryText = details.joined(separator: "  ·  ")
        c.secondaryTextProperties.font = Theme.mono(11)
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= result.rows.count - 20 { loadMore() }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let vc = SQLiteRecordViewController(columns: result.columns, values: result.rows[indexPath.row])
        vc.title = LF("Row %d", indexPath.row + 1)
        navigationController?.pushViewController(vc, animated: true)
    }
}

/// One record: column → value.
private final class SQLiteRecordViewController: UITableViewController {
    private let columns: [String]
    private let values: [SQLiteDatabase.Value]

    init(columns: [String], values: [SQLiteDatabase.Value]) {
        self.columns = columns
        self.values = values
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { min(columns.count, values.count) }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        c.text = columns[indexPath.row]
        c.textProperties.font = .preferredFont(forTextStyle: .footnote)
        c.textProperties.color = .secondaryLabel
        let value = values[indexPath.row]
        c.secondaryText = value.display
        c.secondaryTextProperties.font = Theme.mono(14)
        c.secondaryTextProperties.color = value.isNull ? .tertiaryLabel : .label
        c.secondaryTextProperties.numberOfLines = 0
        c.textToSecondaryTextVerticalPadding = 3
        cell.contentConfiguration = c
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        let value = values[indexPath.row].display
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: L("Copy Value"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = value
            }])
        }
    }
}

// MARK: - Query

private final class SQLiteQueryViewController: UIViewController {
    private let database: SQLiteDatabase
    private let textView = UITextView()
    private let errorLabel = UILabel()

    init(database: SQLiteDatabase) {
        self.database = database
        super.init(nibName: nil, bundle: nil)
        title = L("Query")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Run"), primaryAction: UIAction { [weak self] _ in self?.run() })
        navigationItem.rightBarButtonItem?.style = .done

        textView.font = Theme.mono(15)
        textView.text = "SELECT * FROM sqlite_master;"
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 10
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(textView)
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.heightAnchor.constraint(equalToConstant: 160),
            errorLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 10),
            errorLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    private func run() {
        let sql = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        do {
            let result = try database.query(sql, limit: 2000)
            errorLabel.text = nil
            let vc = SQLiteRowsViewController(database: database, title: L("Results"), table: nil, schema: nil, result: result)
            navigationController?.pushViewController(vc, animated: true)
        } catch {
            Haptics.error()
            errorLabel.text = error.localizedDescription
        }
    }
}
