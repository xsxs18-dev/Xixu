import UIKit
import UniformTypeIdentifiers

/// Tools tab: cleaner, Wi-Fi transfer, app installation and backups, system actions.
final class ToolsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    private struct Tool {
        let title: String
        let detail: String?
        let symbol: String
        let color: UIColor
        let action: (ToolsViewController) -> Void
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var sections: [(title: String?, tools: [Tool])] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Tools")
        navigationItem.largeTitleDisplayMode = .always
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)

        sections = [
            (nil, [
                Tool(title: L("Cleaner"), detail: L("Caches, logs and leftovers"), symbol: "wind", color: .systemGreen) { vc in
                    vc.navigationController?.pushViewController(CleanerViewController(), animated: true)
                },
                Tool(title: L("Wi-Fi Transfer"), detail: L("Upload and download in a browser"), symbol: "wifi", color: .systemBlue) { vc in
                    vc.navigationController?.pushViewController(TransferViewController(), animated: true)
                },
            ]),
            (L("Apps"), [
                Tool(title: L("Install IPA…"), detail: L("With TrollStore or appinst"), symbol: "arrow.down.app.fill", color: .systemIndigo) { vc in
                    vc.pickIPA()
                },
                Tool(title: L("Backups"), detail: AppBackups.directory, symbol: "clock.arrow.circlepath", color: .systemOrange) { _ in
                    Task { @MainActor in
                        _ = try? await FS.shared.call(Request(op: "mkdirs", path: AppBackups.directory))
                        RootController.shared?.reveal(AppBackups.directory)
                    }
                },
            ]),
            (L("System"), [
                Tool(title: L("Respring"), detail: nil, symbol: "arrow.clockwise", color: .systemPurple) { vc in
                    vc.confirm(title: L("Respring?"), message: L("SpringBoard restarts. Open apps are closed."), action: L("Respring"),
                               destructive: false, source: nil) { Ops.respring() }
                },
                Tool(title: L("Refresh Icon Cache"), detail: nil, symbol: "square.grid.3x3.fill", color: .systemCyan) { vc in
                    vc.uicache()
                },
            ]),
        ]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
        if let selected = tableView.indexPathForSelectedRow { tableView.deselectRow(at: selected, animated: animated) }
    }

    private func pickIPA() {
        var types: [UTType] = []
        for id in ["com.apple.itunes.ipa", "com.opa334.trollstore.tipa"] {
            if let type = UTType(id) { types.append(type) }
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types + [.zip], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            Ops.installIPA(url.path, from: self)
        }
    }

    private func uicache() {
        Task { @MainActor in
            do {
                let response = try await Activity.shared.run(L("Refreshing Icon Cache"), Request(op: "uicache"))
                if response.numbers?.first == 0 {
                    Haptics.success()
                    RootController.shared?.toast(L("Icon cache refreshed"))
                } else {
                    self.presentModal(LogViewController(title: L("Icon Cache"), text: response.text ?? "", offerRespring: false))
                }
            } catch {
                self.showError(error)
            }
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].tools.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let tool = sections[indexPath.section].tools[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        c.text = tool.title
        c.secondaryText = tool.detail
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.font = .systemFont(ofSize: 13)
        c.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        c.textToSecondaryTextVerticalPadding = 2
        c.image = Icons.squircle(tool.symbol, tool.color, size: 32)
        c.imageToTextPadding = 14
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let tool = sections[indexPath.section].tools[indexPath.row]
        tool.action(self)
        if !(tool.title == L("Cleaner") || tool.title == L("Wi-Fi Transfer")) {
            tableView.deselectRow(at: indexPath, animated: true)
        }
    }
}

// MARK: - Cleaner

final class CleanerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private struct Category {
        let id: String
        let title: String
        let symbol: String
        let color: UIColor
        var bytes: Int64 = 0
        var items: Int64 = 0
    }

    private var categories: [Category] = [
        Category(id: "app_caches", title: L("App Caches"), symbol: "square.grid.2x2.fill", color: .systemBlue),
        Category(id: "app_temp", title: L("App Temporary Files"), symbol: "clock.fill", color: .systemTeal),
        Category(id: "safari", title: L("Safari & WebKit Caches"), symbol: "safari.fill", color: .systemIndigo),
        Category(id: "temp", title: L("Temporary Files"), symbol: "hourglass", color: .systemGray),
        Category(id: "crash_logs", title: L("Crash Logs"), symbol: "exclamationmark.triangle.fill", color: .systemOrange),
        Category(id: "logs", title: L("Logs"), symbol: "doc.text.fill", color: .systemGray2),
        Category(id: "packages", title: L("Package Downloads"), symbol: "shippingbox.fill", color: .systemBrown),
        Category(id: "shared_caches", title: L("Other Caches"), symbol: "tray.2.fill", color: .systemPurple),
    ]
    private var selected: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "cleanerSelection") ?? ["app_caches", "app_temp", "safari", "temp", "crash_logs", "logs", "packages"]) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "cleanerSelection") }
    }
    private var scanned = false
    private var busy = false
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let totalLabel = UILabel()
    private let captionLabel = UILabel()
    private let cleanButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Cleaner")
        navigationItem.largeTitleDisplayMode = .never
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)

        totalLabel.font = .systemFont(ofSize: 40, weight: .bold)
        totalLabel.textAlignment = .center
        totalLabel.adjustsFontSizeToFitWidth = true
        captionLabel.font = .systemFont(ofSize: 15)
        captionLabel.textColor = .secondaryLabel
        captionLabel.textAlignment = .center
        let header = UIStackView(arrangedSubviews: [totalLabel, captionLabel])
        header.axis = .vertical
        header.spacing = 2
        header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 110)
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 22, left: 20, bottom: 14, right: 20)
        tableView.tableHeaderView = header

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .large
        config.buttonSize = .large
        config.title = L("Clean")
        cleanButton.configuration = config
        cleanButton.addAction(UIAction { [weak self] _ in self?.confirmClean() }, for: .primaryActionTriggered)
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 120))
        cleanButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(cleanButton)
        let note = UILabel()
        note.text = L("Only caches, logs and temporary files are removed. Apps rebuild them when needed.")
        note.font = .systemFont(ofSize: 13)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        note.textAlignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(note)
        NSLayoutConstraint.activate([
            cleanButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            cleanButton.leadingAnchor.constraint(equalTo: footer.layoutMarginsGuide.leadingAnchor, constant: 8),
            cleanButton.trailingAnchor.constraint(equalTo: footer.layoutMarginsGuide.trailingAnchor, constant: -8),
            note.topAnchor.constraint(equalTo: cleanButton.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: footer.layoutMarginsGuide.leadingAnchor, constant: 8),
            note.trailingAnchor.constraint(equalTo: footer.layoutMarginsGuide.trailingAnchor, constant: -8),
        ])
        tableView.tableFooterView = footer
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Scan"), image: UIImage(systemName: "arrow.clockwise"),
                                                            primaryAction: UIAction { [weak self] _ in self?.scan() }, menu: nil)
        scan()
    }

    private var selectedBytes: Int64 {
        categories.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    private func updateHeader() {
        if busy && !scanned {
            totalLabel.text = "–"
            captionLabel.text = L("Scanning…")
        } else {
            totalLabel.text = Format.bytes(selectedBytes)
            captionLabel.text = busy ? L("Working…") : L("can be freed")
        }
        cleanButton.isEnabled = scanned && !busy && selectedBytes > 0
    }

    private func scan() {
        guard !busy else { return }
        busy = true
        updateHeader()
        Task { @MainActor in
            do {
                let response = try await FS.shared.call(Request(op: "cleanScan", flags: self.categories.map(\.id)))
                let numbers = response.numbers ?? []
                for (i, id) in (response.strings ?? []).enumerated() where i * 2 + 1 < numbers.count {
                    if let index = self.categories.firstIndex(where: { $0.id == id }) {
                        self.categories[index].bytes = numbers[i * 2]
                        self.categories[index].items = numbers[i * 2 + 1]
                    }
                }
                self.scanned = true
            } catch {
                self.showError(error)
            }
            self.busy = false
            self.updateHeader()
            self.tableView.reloadData()
        }
    }

    private func confirmClean() {
        let list = categories.filter { selected.contains($0.id) && $0.items > 0 }.map(\.id)
        guard !list.isEmpty else { return }
        confirm(title: LF("Free %@?", Format.bytes(selectedBytes)), message: L("Selected caches, logs and temporary files are deleted."),
                action: L("Clean"), source: cleanButton) { [weak self] in
            self?.clean(list)
        }
    }

    private func clean(_ list: [String]) {
        busy = true
        updateHeader()
        Task { @MainActor in
            do {
                let response = try await Activity.shared.run(L("Cleaning"), Request(op: "clean", flags: list))
                let freed = response.numbers?.first ?? 0
                Haptics.success()
                RootController.shared?.toast(LF("Freed %@", Format.bytes(freed)))
            } catch {
                self.showError(error)
            }
            self.busy = false
            self.scan()
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { categories.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let category = categories[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = UIListContentConfiguration.valueCell()
        c.text = category.title
        c.image = Icons.squircle(category.symbol, category.color)
        if scanned {
            c.secondaryText = category.items == 0 ? L("Clean") : Format.bytes(category.bytes)
        } else {
            c.secondaryText = "…"
        }
        c.secondaryTextProperties.font = Theme.digits(15)
        cell.contentConfiguration = c
        cell.accessoryType = selected.contains(category.id) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let id = categories[indexPath.row].id
        var set = selected
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        selected = set
        Haptics.tap()
        tableView.reloadRows(at: [indexPath], with: .none)
        updateHeader()
    }
}

// MARK: - App backups

enum AppBackups {
    static let directory = "/var/mobile/Documents/Xixu Backups"

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    static func backup(_ app: AppRegistry.App, from vc: UIViewController) {
        guard let data = app.dataPath else {
            vc.showError(XixuError(code: 0, message: L("This app has no data container."), subject: app.name))
            return
        }
        Task { @MainActor in
            do {
                _ = try await FS.shared.call(Request(op: "mkdirs", path: directory))
                let staging = Staging.newDirectory()
                try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
                let manifest: [String: Any] = ["bundleID": app.bundleID, "name": app.name, "version": app.version,
                                               "date": ISO8601DateFormatter().string(from: Date()), "groups": app.groups.map(\.id)]
                let manifestPath = (staging as NSString).appendingPathComponent("Xixu-Backup.json")
                try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: manifestPath))
                var paths = [data]
                var names = ["Data"]
                for group in app.groups {
                    paths.append(group.path)
                    names.append("Groups/" + group.id)
                }
                paths.append(manifestPath)
                names.append("Xixu-Backup.json")
                let target = Paths.join(directory, "\(app.bundleID)_\(stamp.string(from: Date())).xixubackup")
                _ = try await Activity.shared.run(LF("Backing Up %@", app.name),
                                                  Request(op: "compress", paths: paths, dest: target, names: names))
                Haptics.success()
                RootController.shared?.toast(L("Backup saved"), action: L("Show")) {
                    RootController.shared?.reveal(target, isDirectory: false)
                }
            } catch {
                vc.showError(error)
            }
        }
    }

    /// Backups of one app, newest first.
    static func list(for app: AppRegistry.App) async -> [Entry] {
        let entries = (try? await FS.shared.list(directory)) ?? []
        return entries.filter { $0.name.hasPrefix(app.bundleID + "_") && $0.name.hasSuffix(".xixubackup") }
            .sorted { $0.mtime > $1.mtime }
    }

    static func restore(_ app: AppRegistry.App, executable: String?, from vc: UIViewController) {
        guard let data = app.dataPath else {
            vc.showError(XixuError(code: 0, message: L("This app has no data container."), subject: app.name))
            return
        }
        Task { @MainActor in
            let backups = await list(for: app)
            guard !backups.isEmpty else {
                vc.showError(XixuError(code: 0, message: LF("No backups found in %@.", directory), subject: nil), title: L("No Backups"))
                return
            }
            let sheet = UIAlertController(title: L("Restore Backup"), message: LF("The current data of %@ is replaced.", app.name),
                                          preferredStyle: .actionSheet)
            for backup in backups.prefix(10) {
                sheet.addAction(UIAlertAction(title: "\(Format.date(backup.mtime)) · \(Format.bytes(backup.size))", style: .default) { _ in
                    run(Paths.join(directory, backup.name), app: app, data: data, executable: executable, from: vc)
                })
            }
            sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = vc.view
                pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
            }
            vc.topPresenter.present(sheet, animated: true)
        }
    }

    private static func run(_ backup: String, app: AppRegistry.App, data: String, executable: String?, from vc: UIViewController) {
        Task { @MainActor in
            do {
                _ = try await Activity.shared.run(LF("Restoring %@", app.name),
                                                  Request(op: "restoreApp", path: backup, paths: app.groups.map(\.path), dest: data,
                                                          text: executable ?? "", names: app.groups.map(\.id)))
                Haptics.success()
                RootController.shared?.toast(L("Backup restored"))
            } catch {
                vc.showError(error)
            }
        }
    }

    static func exportIPA(_ app: AppRegistry.App, from vc: UIViewController) {
        guard let bundle = app.bundlePath else { return }
        Task { @MainActor in
            do {
                _ = try await FS.shared.call(Request(op: "mkdirs", path: directory))
                let base = "\(app.name) \(app.version)".trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
                var target = Paths.join(directory, base + ".ipa")
                var n = 2
                while try await FS.shared.exists([target]).first == true {
                    target = Paths.join(directory, "\(base) \(n).ipa")
                    n += 1
                }
                _ = try await Activity.shared.run(LF("Exporting %@", app.name),
                                                  Request(op: "compress", paths: [bundle], dest: target, names: ["Payload/" + Paths.name(bundle)]))
                Haptics.success()
                RootController.shared?.toast(L("IPA exported"), action: L("Show")) {
                    RootController.shared?.reveal(target, isDirectory: false)
                }
            } catch {
                vc.showError(error)
            }
        }
    }
}
