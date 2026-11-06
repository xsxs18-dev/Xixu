import UIKit

/// Paged hex viewer with in-place byte editing.
final class HexViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let path: String
    private var size: Int64 = 0
    private var loaded = false
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let titleView: TitleView
    private var bytesPerRow = 8
    private let pageSize = 1 << 16
    private var pages: [Int: [UInt8]] = [:]
    private var pageOrder: [Int] = []
    private var loading = Set<Int>()
    private var patches: [Int64: UInt8] = [:] {
        didSet {
            isModalInPresentation = !patches.isEmpty
            updateItems()
        }
    }

    private let font = Theme.mono(12)
    private lazy var charWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width

    init(path: String) {
        self.path = path
        titleView = TitleView(title: Paths.name(path), subtitle: nil)
        super.init(nibName: nil, bundle: nil)
        title = Paths.name(path)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.titleView = titleView
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.close()
        })

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        tableView.estimatedRowHeight = 20
        tableView.separatorStyle = .none
        tableView.register(HexRowCell.self, forCellReuseIdentifier: "row")
        tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)

        updateItems()
        Task { @MainActor in
            do {
                let info = try await FS.shared.stat(self.path)
                self.size = info.entry.size
                self.loaded = true
                self.titleView.subtitle.text = "\(Format.bytes(self.size)) · \(Format.exactBytes(self.size))"
                self.tableView.reloadData()
                if self.size == 0 {
                    self.tableView.backgroundView = EmptyStateView(title: L("Empty File"))
                }
            } catch {
                self.tableView.backgroundView = EmptyStateView(title: L("Can't Open File"), message: error.localizedDescription)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let available = tableView.bounds.width - tableView.layoutMargins.left - tableView.layoutMargins.right
        var best = 4
        for candidate in [16, 12, 8, 4] {
            let chars = CGFloat(10 + candidate * 3 + 2 + candidate)
            if chars * charWidth <= available {
                best = candidate
                break
            }
        }
        if best != bytesPerRow {
            bytesPerRow = best
            tableView.reloadData()
        }
    }

    private func updateItems() {
        let save = UIBarButtonItem(title: L("Save"), primaryAction: UIAction { [weak self] _ in self?.save() })
        save.style = .done
        save.isEnabled = !patches.isEmpty
        let menu = UIBarButtonItem(title: L("More"), image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: UIMenu(children: [
            UIAction(title: L("Go to Offset…"), image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in self?.goToOffset() },
            UIAction(title: L("Discard Changes"), image: UIImage(systemName: "arrow.uturn.backward"),
                     attributes: patches.isEmpty ? .disabled : []) { [weak self] _ in
                self?.patches.removeAll()
                self?.tableView.reloadData()
            },
        ]))
        navigationItem.rightBarButtonItems = [save, menu]
    }

    // MARK: - Data

    private var rowCount: Int {
        guard loaded, size > 0 else { return 0 }
        return Int((size + Int64(bytesPerRow) - 1) / Int64(bytesPerRow))
    }

    private func original(at offset: Int64) -> UInt8? {
        let page = Int(offset / Int64(pageSize))
        guard let bytes = pages[page] else {
            request(page)
            return nil
        }
        let index = Int(offset - Int64(page) * Int64(pageSize))
        return index < bytes.count ? bytes[index] : nil
    }

    private func byte(at offset: Int64) -> UInt8? {
        if let patched = patches[offset] { return patched }
        return original(at: offset)
    }

    private func request(_ page: Int) {
        guard !loading.contains(page) else { return }
        loading.insert(page)
        Task { @MainActor in
            let data = try? await FS.shared.read(self.path, offset: Int64(page) * Int64(self.pageSize), length: self.pageSize)
            self.loading.remove(page)
            guard let data = data else { return }
            self.pages[page] = [UInt8](data)
            self.pageOrder.append(page)
            if self.pageOrder.count > 64 {
                let evicted = self.pageOrder.removeFirst()
                self.pages[evicted] = nil
            }
            if let visible = self.tableView.indexPathsForVisibleRows, !visible.isEmpty {
                self.tableView.reloadRows(at: visible, with: .none)
            }
        }
    }

    private func rowBytes(_ row: Int) -> [UInt8?] {
        let start = Int64(row) * Int64(bytesPerRow)
        let count = Int(min(Int64(bytesPerRow), size - start))
        return (0..<max(count, 0)).map { byte(at: start + Int64($0)) }
    }

    private func text(for row: Int) -> NSAttributedString {
        let start = Int64(row) * Int64(bytesPerRow)
        let bytes = rowBytes(row)
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        result.append(NSAttributedString(string: String(format: "%08llX  ", start),
                                         attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel]))
        for i in 0..<bytesPerRow {
            if i < bytes.count {
                let offset = start + Int64(i)
                if let b = bytes[i] {
                    var attributes = base
                    if patches[offset] != nil { attributes[.foregroundColor] = Theme.accent }
                    result.append(NSAttributedString(string: String(format: "%02X", b), attributes: attributes))
                } else {
                    result.append(NSAttributedString(string: "··", attributes: [.font: font, .foregroundColor: UIColor.quaternaryLabel]))
                }
            } else {
                result.append(NSAttributedString(string: "  ", attributes: base))
            }
            result.append(NSAttributedString(string: i == bytesPerRow / 2 - 1 ? "  " : " ", attributes: base))
        }
        var ascii = ""
        for b in bytes {
            if let b = b, b >= 0x20 && b < 0x7F { ascii.append(Character(UnicodeScalar(b))) } else { ascii.append(".") }
        }
        result.append(NSAttributedString(string: " " + ascii, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        return result
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rowCount }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! HexRowCell
        cell.label.attributedText = text(for: indexPath.row)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        edit(row: indexPath.row)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let row = indexPath.row
        let start = Int64(row) * Int64(bytesPerRow)
        let bytes = rowBytes(row).compactMap { $0 }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: L("Copy Hex"), image: UIImage(systemName: "number")) { _ in
                    UIPasteboard.general.string = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                },
                UIAction(title: L("Copy Text"), image: UIImage(systemName: "textformat")) { _ in
                    UIPasteboard.general.string = String(decoding: bytes, as: UTF8.self)
                },
                UIAction(title: L("Copy Offset"), image: UIImage(systemName: "arrow.right.to.line")) { _ in
                    UIPasteboard.general.string = String(format: "0x%llX", start)
                },
            ])
        }
    }

    // MARK: - Editing

    private func edit(row: Int) {
        let start = Int64(row) * Int64(bytesPerRow)
        let bytes = rowBytes(row)
        guard !bytes.isEmpty, !bytes.contains(where: { $0 == nil }) else { return }
        let current = bytes.compactMap { $0 }.map { String(format: "%02X", $0) }.joined(separator: " ")
        prompt(title: String(format: L("Edit Bytes at 0x%llX"), start), message: L("Hexadecimal, one pair per byte."),
               text: current, action: L("Apply")) { [weak self] value in
            guard let self = self else { return }
            let digits = value.filter { !$0.isWhitespace }
            guard digits.count == bytes.count * 2, digits.allSatisfy(\.isHexDigit) else {
                Haptics.error()
                self.showError(XixuError(code: EINVAL, message: LF("Enter exactly %d bytes in hex.", bytes.count), subject: nil),
                               title: L("Invalid Bytes"))
                return
            }
            var index = digits.startIndex
            for i in 0..<bytes.count {
                let next = digits.index(index, offsetBy: 2)
                guard let value = UInt8(digits[index..<next], radix: 16) else { return }
                index = next
                let offset = start + Int64(i)
                if self.original(at: offset) == value {
                    self.patches[offset] = nil
                } else {
                    self.patches[offset] = value
                }
            }
            self.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        }
    }

    private func save(then completion: (() -> Void)? = nil) {
        guard !patches.isEmpty else { return }
        var runs: [(Int64, [UInt8])] = []
        for offset in patches.keys.sorted() {
            let value = patches[offset]!
            if let last = runs.last, last.0 + Int64(last.1.count) == offset {
                runs[runs.count - 1].1.append(value)
            } else {
                runs.append((offset, [value]))
            }
        }
        Task { @MainActor in
            do {
                for (offset, bytes) in runs {
                    _ = try await FS.shared.call(Request(op: "patch", path: self.path, data: Data(bytes), offset: offset))
                }
                for (offset, value) in self.patches {
                    let page = Int(offset / Int64(self.pageSize))
                    let index = Int(offset - Int64(page) * Int64(self.pageSize))
                    if var bytes = self.pages[page], index < bytes.count {
                        bytes[index] = value
                        self.pages[page] = bytes
                    }
                }
                self.patches.removeAll()
                self.tableView.reloadData()
                Haptics.success()
                RootController.shared?.toast(L("Saved"))
                announceChanges([Paths.parent(self.path)])
                completion?()
            } catch {
                self.showError(error, title: L("Can't Save"))
            }
        }
    }

    private func goToOffset() {
        prompt(title: L("Go to Offset"), message: L("Decimal, or hexadecimal with 0x."), placeholder: "0x0", action: L("Go")) { [weak self] value in
            guard let self = self else { return }
            let text = value.lowercased()
            let offset: Int64?
            if text.hasPrefix("0x") {
                offset = Int64(text.dropFirst(2), radix: 16)
            } else {
                offset = Int64(text) ?? Int64(text, radix: 16)
            }
            guard let target = offset, target >= 0, target < self.size else {
                Haptics.error()
                return
            }
            let row = Int(target / Int64(self.bytesPerRow))
            let indexPath = IndexPath(row: row, section: 0)
            self.tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
            self.tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.tableView.deselectRow(at: indexPath, animated: true)
            }
        }
    }

    private func close() {
        guard !patches.isEmpty else {
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

private final class HexRowCell: UITableViewCell {
    let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
