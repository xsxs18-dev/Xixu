import UIKit
import CryptoKit

/// One small request for the latest public release, followed by a verified package install.
@MainActor final class UpdateManager {
    struct Release {
        let version: String
        let notes: String
        let page: URL
        let asset: URL
        let assetName: String
        let size: Int64
        let sha256: String
    }

    enum State: Equatable {
        case idle, checking, upToDate, available, downloading, installing, installed, failed(String)
    }

    static let shared = UpdateManager()
    private(set) var state: State = .idle { didSet { notify() } }
    private(set) var latest: Release?
    private var lastCheck: Date?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var isWorking: Bool { state == .checking || state == .downloading || state == .installing }

    func check(force: Bool = false) async {
        guard !isWorking else { return }
        if !force, let last = lastCheck,
           Date().timeIntervalSince(last) < 3 * 3600 { return }
        state = .checking
        do {
            let release = try await fetchLatest()
            latest = release
            lastCheck = Date()
            state = Self.isNewer(release.version, than: Self.currentVersion) ? .available : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() async {
        guard state == .available, let release = latest else { return }
        guard FS.shared.isRoot else {
            state = .failed(L("The root helper is not running. Reinstall Xixu to update it."))
            return
        }
        state = .downloading
        var local: URL?
        defer { if let local = local { try? FileManager.default.removeItem(at: local) } }
        do {
            let (download, response) = try await URLSession.shared.download(from: release.asset)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError(L("The update could not be downloaded."))
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("Xixu-\(UUID().uuidString).deb")
            try FileManager.default.moveItem(at: download, to: target)
            local = target
            let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size == release.size, size > 0 else { throw UpdateError(L("The downloaded package is incomplete.")) }
            let hash = SHA256.hash(data: try Data(contentsOf: target, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard hash == release.sha256 else { throw UpdateError(L("The downloaded package failed verification.")) }

            state = .installing
            let result = try await Activity.shared.run(L("Installing Update"), Request(op: "selfUpdate", path: target.path))
            guard result.numbers?.first == 0 else {
                let detail = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdateError(detail.isEmpty ? L("The update could not be installed.") : String(detail.suffix(700)))
            }
            Haptics.success()
            state = .installed
        } catch {
            Haptics.error()
            state = .failed(error.localizedDescription)
        }
    }

    private struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let digest: String?
            let browser_download_url: URL
            let state: String
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    private func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/xsxs18-dev/Xixu/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Xixu/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(L("Could not check GitHub for updates."))
        }
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        guard Self.parts(version) != nil else { throw UpdateError(L("The latest release has an invalid version.")) }
        let suffix: String
        switch JB.scheme {
        case "rootless": suffix = "_rootless_iphoneos-arm64.deb"
        case "roothide": suffix = "_roothide_iphoneos-arm64e.deb"
        default: throw UpdateError(L("This jailbreak is not supported by the updater."))
        }
        guard let asset = payload.assets.first(where: { $0.state == "uploaded" && $0.name.hasSuffix(suffix) }),
              asset.size > 0, asset.size < 50_000_000,
              asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path.hasPrefix("/xsxs18-dev/Xixu/releases/download/"),
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw UpdateError(L("No verified package was found for this jailbreak."))
        }
        let sha = String(digest.dropFirst("sha256:".count)).lowercased()
        guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError(L("The release has no valid checksum."))
        }
        let notes = (payload.body ?? "").components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(version: version, notes: notes, page: payload.html_url,
                       asset: asset.browser_download_url, assetName: asset.name, size: asset.size, sha256: sha)
    }

    private static func parts(_ version: String) -> [Int]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        return numbers.count == pieces.count ? numbers : nil
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let newer = parts(candidate), let older = parts(current) else { return false }
        for i in 0..<max(newer.count, older.count) {
            let a = i < newer.count ? newer[i] : 0
            let b = i < older.count ? older[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func notify() {
        NotificationCenter.default.post(name: .updateChanged, object: nil)
    }
}

/// A compact, native update sheet with one clear action at a time.
final class UpdateViewController: UIViewController {
    private let icon = UIImageView()
    private let headline = UILabel()
    private let detail = UILabel()
    private let notesTitle = UILabel()
    private let notes = UILabel()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Software Update")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L("Close"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("GitHub"), primaryAction: UIAction { _ in
            let page = UpdateManager.shared.latest?.page ?? URL(string: "https://github.com/xsxs18-dev/Xixu/releases/latest")!
            UIApplication.shared.open(page)
        })
        view.backgroundColor = .systemGroupedBackground

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let content = UIStackView(arrangedSubviews: [icon, headline, detail, notesTitle, notes])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        icon.image = UIImage(named: "AppIcon60x60")
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 16
        icon.clipsToBounds = true
        headline.font = .systemFont(ofSize: 25, weight: .bold)
        headline.textAlignment = .center
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0
        notesTitle.font = .preferredFont(forTextStyle: .headline)
        notesTitle.text = L("What's New")
        notes.textColor = .secondaryLabel
        notes.font = .preferredFont(forTextStyle: .body)
        notes.numberOfLines = 0
        notes.textAlignment = .left

        let footer = UIStackView(arrangedSubviews: [spinner, status, button])
        footer.axis = .vertical
        footer.alignment = .center
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.textColor = .secondaryLabel
        status.textAlignment = .center
        status.numberOfLines = 0
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.act() }, for: .primaryActionTriggered)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 30),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            icon.widthAnchor.constraint(equalToConstant: 72), icon.heightAnchor.constraint(equalToConstant: 72),
            notes.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            button.widthAnchor.constraint(equalTo: footer.widthAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .updateChanged, object: nil)
        refresh()
        Task { @MainActor in await UpdateManager.shared.check() }
    }

    @objc private func refresh() {
        let manager = UpdateManager.shared
        let release = manager.latest
        headline.text = release.map { "Xixu \($0.version)" } ?? "Xixu"
        detail.text = LF("Installed: %@", UpdateManager.currentVersion)
        notes.text = release?.notes.isEmpty == false ? release?.notes : L("Release notes will appear here.")
        notesTitle.isHidden = release == nil
        notes.isHidden = release == nil
        let working = manager.state == .checking || manager.state == .downloading || manager.state == .installing
        working ? spinner.startAnimating() : spinner.stopAnimating()
        button.isEnabled = !working
        switch manager.state {
        case .idle: status.text = nil; button.configuration?.title = L("Check for Updates")
        case .checking: status.text = L("Checking for updates…"); button.configuration?.title = L("Checking…")
        case .upToDate: status.text = L("Xixu is up to date."); button.configuration?.title = L("Check Again")
        case .available: status.text = L("New version available"); button.configuration?.title = L("Update")
        case .downloading: status.text = L("Downloading update…"); button.configuration?.title = L("Downloading…")
        case .installing: status.text = L("Installing update…"); button.configuration?.title = L("Installing…")
        case .installed: status.text = L("Update installed. Close and reopen Xixu."); button.configuration?.title = L("Done")
        case .failed(let message): status.text = message; button.configuration?.title = L("Try Again")
        }
    }

    private func act() {
        switch UpdateManager.shared.state {
        case .available:
            Task { @MainActor in await UpdateManager.shared.install() }
        case .installed:
            dismiss(animated: true)
        default:
            Task { @MainActor in await UpdateManager.shared.check(force: true) }
        }
    }
}
