import UIKit
import Darwin

/// A running long operation shown in the shelf.
final class Job {
    let id: Int
    let title: String
    let started = Date()
    var progress: Double?
    var detail: String?

    init(id: Int, title: String) {
        self.id = id
        self.title = title
    }
}

final class Activity {
    static let shared = Activity()
    private(set) var jobs: [Job] = []

    func run(_ title: String, _ request: Request) async throws -> Response {
        var req = request
        req.id = FS.shared.makeID()
        let job = Job(id: req.id, title: title)
        jobs.append(job)
        post()
        defer {
            jobs.removeAll { $0 === job }
            post()
        }
        return try await FS.shared.call(req) { [weak self] response in
            if let p = response.progress { job.progress = p }
            if let t = response.text, !t.isEmpty { job.detail = t }
            self?.post()
        }
    }

    func cancel(_ job: Job) {
        FS.shared.cancel(job.id)
    }

    private func post() {
        NotificationCenter.default.post(name: .activityChanged, object: nil)
    }
}

/// User-facing file operations shared by the browser, search and the trash.
enum Ops {
    static func countText(_ n: Int) -> String {
        n == 1 ? L("1 item") : LF("%d items", n)
    }

    // MARK: Paste

    static func paste(into dir: String, from vc: UIViewController, asLink: Bool = false) {
        let clip = Clipboard.shared
        guard !clip.isEmpty else { return }
        let sources = clip.paths
        let cut = clip.isCut && !asLink
        Task { @MainActor in
            do {
                let targets = sources.map { Paths.join(dir, Paths.name($0)) }
                let exists = try await FS.shared.exists(targets)
                var conflicts = 0
                for (i, src) in sources.enumerated() where i < exists.count && exists[i] && targets[i] != src {
                    conflicts += 1
                }
                var policy = Engine.Conflict.keepBoth
                if conflicts > 0 {
                    guard let choice = await askConflict(conflicts, from: vc) else { return }
                    policy = choice
                }
                let op = asLink ? "link" : (cut ? "move" : "copy")
                let title = asLink ? L("Creating Links") : (cut ? L("Moving") : L("Copying"))
                _ = try await Activity.shared.run(title, Request(op: op, paths: sources, dest: dir, text: policy.rawValue))
                if cut { clip.clear() }
                announceChanges([dir] + (cut ? sources.map(Paths.parent) : []))
                Haptics.success()
            } catch {
                announceChanges([dir])
                vc.showError(error)
            }
        }
    }

    @MainActor
    static func askConflict(_ count: Int, from vc: UIViewController) async -> Engine.Conflict? {
        await withCheckedContinuation { continuation in
            let message = count == 1
                ? L("An item with the same name already exists in this location.")
                : LF("%d items with the same names already exist in this location.", count)
            let alert = UIAlertController(title: L("Items Already Exist"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("Keep Both"), style: .default) { _ in continuation.resume(returning: .keepBoth) })
            alert.addAction(UIAlertAction(title: L("Replace"), style: .destructive) { _ in continuation.resume(returning: .replace) })
            alert.addAction(UIAlertAction(title: L("Skip"), style: .default) { _ in continuation.resume(returning: .skip) })
            alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in continuation.resume(returning: nil) })
            vc.topPresenter.present(alert, animated: true)
        }
    }

    // MARK: Delete

    static func isInTrash(_ path: String) -> Bool {
        Paths.isInside(path, Engine.trashRoot) || Paths.isInside(path, "/private" + Engine.trashRoot)
    }

    static func delete(_ paths: [String], from vc: UIViewController, source: Any?, completion: (() -> Void)? = nil) {
        guard !paths.isEmpty else { return }
        if !Prefs.useTrash || paths.contains(where: isInTrash) {
            confirmPermanentDelete(paths, from: vc, source: source, completion: completion)
            return
        }
        Task { @MainActor in
            var slots: [String] = []
            var otherVolume: [String] = []
            var failure: Error?
            for path in paths {
                do {
                    let response = try await FS.shared.call(Request(op: "trash", paths: [path]))
                    slots += response.strings ?? []
                } catch let error as XixuError where error.code == EXDEV {
                    otherVolume.append(path)
                } catch {
                    failure = error
                    break
                }
            }
            announceChanges(paths.map(Paths.parent))
            completion?()
            if !slots.isEmpty {
                Haptics.success()
                let text = slots.count == 1 ? L("Moved to Trash") : LF("Moved %d items to Trash", slots.count)
                RootController.shared?.toast(text, action: L("Undo")) {
                    restore(slots, from: vc)
                }
            }
            if let failure = failure {
                vc.showError(failure)
            } else if !otherVolume.isEmpty {
                let names = otherVolume.map(Paths.name).joined(separator: ", ")
                vc.confirm(title: L("Delete Permanently?"),
                           message: LF("%@ can't be moved to the Trash because it is on another volume. Delete it permanently? This can't be undone.", names),
                           action: L("Delete"), source: nil) {
                    runDelete(otherVolume, from: vc, completion: completion)
                }
            }
        }
    }

    static func confirmPermanentDelete(_ paths: [String], from vc: UIViewController, source: Any?, completion: (() -> Void)? = nil) {
        let title = paths.count == 1
            ? LF("Delete “%@”?", Paths.name(paths[0]))
            : LF("Delete %d Items?", paths.count)
        vc.confirm(title: title, message: L("This can't be undone."), action: L("Delete"), source: source) {
            runDelete(paths, from: vc, completion: completion)
        }
    }

    static func runDelete(_ paths: [String], from vc: UIViewController, completion: (() -> Void)?) {
        Task { @MainActor in
            do {
                _ = try await Activity.shared.run(L("Deleting"), Request(op: "delete", paths: paths))
                Haptics.success()
            } catch {
                vc.showError(error)
            }
            announceChanges(paths.map(Paths.parent))
            completion?()
        }
    }

    static func restore(_ slots: [String], from vc: UIViewController) {
        Task { @MainActor in
            do {
                let restored = try await FS.shared.call(Request(op: "restore", paths: slots)).strings ?? []
                announceChanges(restored.map(Paths.parent) + [Engine.trashRoot])
                Haptics.success()
            } catch {
                vc.showError(error)
            }
        }
    }

    // MARK: Create / rename

    static func rename(_ item: FileItem, from vc: UIViewController) {
        vc.prompt(title: L("Rename"), text: item.name, action: L("Rename"), selectBaseName: !item.isDirectory) { name in
            guard name != item.name else { return }
            Task { @MainActor in
                do {
                    _ = try await FS.shared.call(Request(op: "rename", path: item.path, text: name))
                    announceChanges([item.parent])
                } catch {
                    vc.showError(error)
                }
            }
        }
    }

    static func newFolder(in dir: String, from vc: UIViewController) {
        vc.prompt(title: L("New Folder"), text: L("Untitled Folder"), action: L("Create")) { name in
            Task { @MainActor in
                do {
                    _ = try await FS.shared.call(Request(op: "mkdir", path: Paths.join(dir, name)))
                    announceChanges([dir])
                } catch {
                    vc.showError(error)
                }
            }
        }
    }

    static func newFile(in dir: String, from vc: UIViewController) {
        vc.prompt(title: L("New File"), text: "untitled.txt", action: L("Create"), selectBaseName: true) { name in
            Task { @MainActor in
                do {
                    _ = try await FS.shared.call(Request(op: "touch", path: Paths.join(dir, name)))
                    announceChanges([dir])
                } catch {
                    vc.showError(error)
                }
            }
        }
    }

    static func newSymlink(in dir: String, target: String? = nil, from vc: UIViewController) {
        let alert = UIAlertController(title: L("New Symbolic Link"), message: L("The link points to the target path."), preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L("Name")
            field.text = target.map(Paths.name)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = L("Target path")
            field.text = target
            field.font = Theme.mono(14)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Create"), style: .default) { [weak alert] _ in
            let name = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let target = alert?.textFields?[1].text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !name.isEmpty, !target.isEmpty else { return }
            Task { @MainActor in
                do {
                    _ = try await FS.shared.call(Request(op: "symlink", path: Paths.join(dir, name), text: target))
                    announceChanges([dir])
                } catch {
                    vc.showError(error)
                }
            }
        })
        vc.topPresenter.present(alert, animated: true)
    }

    static func duplicate(_ paths: [String], from vc: UIViewController) {
        Task { @MainActor in
            do {
                _ = try await Activity.shared.run(L("Duplicating"), Request(op: "duplicate", paths: paths))
                Haptics.success()
            } catch {
                vc.showError(error)
            }
            announceChanges(paths.map(Paths.parent))
        }
    }

    // MARK: Archives / packages

    static func compress(_ paths: [String], from vc: UIViewController) {
        guard let first = paths.first else { return }
        let dir = Paths.parent(first)
        let base = paths.count == 1 ? Paths.name(first) : L("Archive")
        Task { @MainActor in
            do {
                var target = Paths.join(dir, base + ".zip")
                var n = 2
                while try await FS.shared.exists([target]).first == true {
                    target = Paths.join(dir, "\(base) \(n).zip")
                    n += 1
                }
                _ = try await Activity.shared.run(L("Compressing"), Request(op: "compress", paths: paths, dest: target))
                announceChanges([dir])
                Haptics.success()
            } catch {
                announceChanges([dir])
                vc.showError(error)
            }
        }
    }

    static func extract(_ path: String, from vc: UIViewController, completion: ((String) -> Void)? = nil) {
        Task { @MainActor in
            do {
                let result = try await Activity.shared.run(L("Extracting"), Request(op: "extract", path: path))
                announceChanges([Paths.parent(path)])
                Haptics.success()
                if let out = result.text {
                    RootController.shared?.toast(LF("Extracted “%@”", Paths.name(out)))
                    completion?(out)
                }
            } catch {
                announceChanges([Paths.parent(path)])
                vc.showError(error)
            }
        }
    }

    static func install(_ path: String, from vc: UIViewController) {
        vc.confirm(title: LF("Install “%@”?", Paths.name(path)),
                   message: L("The package and its dependencies are installed with APT."),
                   action: L("Install"), destructive: false, source: nil) {
            Task { @MainActor in
                do {
                    let response = try await Activity.shared.run(L("Installing"), Request(op: "install", path: path))
                    let ok = response.numbers?.first == 0
                    if ok { Haptics.success() } else { Haptics.error() }
                    let log = LogViewController(title: ok ? L("Installed") : L("Installation Failed"),
                                                text: response.text ?? "", offerRespring: ok)
                    vc.presentModal(log)
                } catch {
                    vc.showError(error)
                }
            }
        }
    }

    static func installIPA(_ path: String, from vc: UIViewController) {
        vc.confirm(title: LF("Install “%@”?", Paths.name(path)),
                   message: L("The app is installed with TrollStore or appinst."),
                   action: L("Install"), destructive: false, source: nil) {
            Task { @MainActor in
                do {
                    let response = try await Activity.shared.run(L("Installing"), Request(op: "installIPA", path: path))
                    let method = response.strings?.first ?? ""
                    if response.numbers?.first == 0 {
                        Haptics.success()
                        RootController.shared?.toast(LF("Installed with %@", method))
                    } else {
                        Haptics.error()
                        vc.presentModal(LogViewController(title: L("Installation Failed"), text: response.text ?? "", offerRespring: false))
                    }
                } catch let error as XixuError where error.message == "No installer found" {
                    vc.showError(XixuError(code: 0, message: L("Install TrollStore Lite, or appinst together with AppSync Unified, from your package manager."), subject: nil),
                                 title: L("No Installer Found"))
                } catch {
                    vc.showError(error)
                }
            }
        }
    }

    /// Changes the Home Screen name of an installed app.
    static func renameApp(_ app: AppRegistry.App, from vc: UIViewController) {
        guard let bundle = app.bundlePath else { return }
        vc.prompt(title: L("Home Screen Name"), message: L("Changes the name in Info.plist and in every language of the app."),
                  text: app.name, action: L("Rename")) { name in
            Task { @MainActor in
                do {
                    _ = try await Activity.shared.run(L("Renaming"), Request(op: "renameApp", path: bundle, text: name))
                    Haptics.success()
                    AppRegistry.shared.reload()
                    RootController.shared?.toast(L("Renamed. A respring shows the new name everywhere."), action: L("Respring")) {
                        Ops.respring()
                    }
                } catch {
                    vc.showError(error)
                }
            }
        }
    }

    /// After editing Info.plist or InfoPlist.strings inside an app, LaunchServices must re-read the bundle.
    static func refreshAppIfNeeded(after path: String) {
        guard let range = path.range(of: ".app/", options: .backwards) else { return }
        let name = Paths.name(path)
        guard name == "Info.plist" || name == "InfoPlist.strings" else { return }
        let bundle = String(path[..<range.upperBound].dropLast())
        Task { _ = try? await FS.shared.call(Request(op: "refreshApp", path: bundle)) }
    }

    // MARK: Misc

    static func copyPaths(_ paths: [String]) {
        UIPasteboard.general.string = paths.joined(separator: "\n")
        Haptics.tap()
        RootController.shared?.toast(paths.count == 1 ? L("Path Copied") : L("Paths Copied"))
    }

    static func share(_ paths: [String], from vc: UIViewController, source: Any?) {
        Task { @MainActor in
            do {
                let urls = try await readableURLs(paths)
                let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                if let pop = sheet.popoverPresentationController {
                    if let item = source as? UIBarButtonItem { pop.barButtonItem = item }
                    else if let view = source as? UIView { pop.sourceView = view; pop.sourceRect = view.bounds }
                    else { pop.sourceView = vc.view; pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0) }
                }
                vc.topPresenter.present(sheet, animated: true)
            } catch {
                vc.showError(error)
            }
        }
    }

    /// URLs the app process itself can read; anything else is copied out by the helper first.
    static func readableURLs(_ paths: [String]) async throws -> [URL] {
        var urls: [URL] = []
        var staged: [String] = []
        for p in paths {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            if exists && Darwin.access(p, R_OK) == 0 && (!isDir.boolValue || Darwin.access(p, R_OK | X_OK) == 0) {
                urls.append(URL(fileURLWithPath: p))
            } else {
                staged.append(p)
            }
        }
        if !staged.isEmpty {
            urls += try await FS.shared.stage(staged).map { URL(fileURLWithPath: $0) }
        }
        return urls
    }

    static func respring() {
        Task { _ = try? await FS.shared.call(Request(op: "respring")) }
    }
}

/// Shows command output, e.g. after installing a package.
final class LogViewController: UIViewController {
    private let text: String
    private let offerRespring: Bool

    init(title: String, text: String, offerRespring: Bool) {
        self.text = text
        self.offerRespring = offerRespring
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let textView = UITextView()
        textView.isEditable = false
        textView.font = Theme.mono(12)
        textView.text = text.isEmpty ? L("No output.") : text
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        if offerRespring {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Respring"), primaryAction: UIAction { _ in
                Ops.respring()
            })
        }
        DispatchQueue.main.async {
            textView.scrollRangeToVisible(NSRange(location: max(0, (textView.text as NSString).length - 1), length: 1))
        }
    }
}
