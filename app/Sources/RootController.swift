import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        signal(SIGPIPE, SIG_IGN)
        Prefs.register()
        Staging.cleanUp()
        DispatchQueue.global(qos: .userInitiated).async { _ = FS.shared }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = Theme.accent
        window.rootViewController = RootController()
        window.makeKeyAndVisible()
        self.window = window
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak window] _ in
            window?.tintColor = Theme.accent
        }
    }
}

final class RootController: UITabBarController, UITabBarControllerDelegate {
    static weak var shared: RootController?

    private let shelf = ShelfView()
    private var shelfShown = false
    private var toastView: ToastView?
    private var toastTimer: Timer?
    private var lastSelectedTab: UIViewController?
    private var lastFilesTap: TimeInterval = 0

    private(set) lazy var filesTabs = FilesTabsController(delegate: self)
    let searchNav = UINavigationController(rootViewController: SearchViewController())
    let appsNav = UINavigationController(rootViewController: AppsViewController())
    let toolsNav = UINavigationController(rootViewController: ToolsViewController())
    let settingsNav = UINavigationController(rootViewController: SettingsViewController())
    private var shelfBottom: NSLayoutConstraint?

    /// Navigation stack of the visible Files tab.
    var filesNav: UINavigationController { filesTabs.currentNav }

    private var otherNavs: [UINavigationController] { [searchNav, appsNav, toolsNav, settingsNav] }

    override func viewDidLoad() {
        super.viewDidLoad()
        RootController.shared = self
        delegate = self

        searchNav.tabBarItem = UITabBarItem(title: L("Search"), image: UIImage(systemName: "magnifyingglass"), selectedImage: UIImage(systemName: "magnifyingglass"))
        appsNav.tabBarItem = UITabBarItem(title: L("Apps"), image: UIImage(systemName: "square.grid.2x2"), selectedImage: UIImage(systemName: "square.grid.2x2.fill"))
        toolsNav.tabBarItem = UITabBarItem(title: L("Tools"), image: UIImage(systemName: "wrench.and.screwdriver"), selectedImage: UIImage(systemName: "wrench.and.screwdriver.fill"))
        settingsNav.tabBarItem = UITabBarItem(title: L("Settings"), image: UIImage(systemName: "gearshape"), selectedImage: UIImage(systemName: "gearshape.fill"))
        for nav in otherNavs {
            nav.navigationBar.prefersLargeTitles = true
            nav.delegate = self
        }
        viewControllers = [filesTabs, searchNav, appsNav, toolsNav, settingsNav]
        lastSelectedTab = filesTabs

        shelf.translatesAutoresizingMaskIntoConstraints = false
        shelf.alpha = 0
        shelf.isHidden = true
        view.addSubview(shelf)
        let width = shelf.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -20)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            shelf.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            width,
            shelf.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        let bottom = shelf.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -8)
        bottom.isActive = true
        shelfBottom = bottom
        shelf.onPrimary = { [weak self] in self?.shelfPrimary() }
        shelf.onClose = { [weak self] in self?.shelfClose() }
        shelf.linkAction = { [weak self] in self?.pasteAsLink() }

        let center = NotificationCenter.default
        for name in [Notification.Name.clipboardChanged, .activityChanged, .editingChanged] {
            center.addObserver(self, selector: #selector(stateChanged), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(updateChanged), name: .updateChanged, object: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await UpdateManager.shared.check()
        }
    }

    @objc private func stateChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stateChanged() }
            return
        }
        updateShelf()
        if !Activity.shared.jobs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.updateShelf() }
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        if viewController === filesTabs {
            let now = ProcessInfo.processInfo.systemUptime
            if lastSelectedTab === filesTabs && now - lastFilesTap < 0.4 {
                filesNav.popToRootViewController(animated: true)
                Haptics.tap()
                lastFilesTap = 0
            } else {
                lastFilesTap = now
            }
        } else {
            lastFilesTap = 0
        }
        lastSelectedTab = viewController
        updateShelf()
    }

    @objc private func updateChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateChanged() }
            return
        }
        guard UpdateManager.shared.state == .available,
              let release = UpdateManager.shared.latest,
              UserDefaults.standard.string(forKey: "lastUpdateNotice") != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: "lastUpdateNotice")
        toast(L("New version available"), action: L("Update")) { [weak self] in
            self?.presentModal(UpdateViewController())
        }
    }

    private var filesSelected: Bool { selectedViewController === filesTabs }

    /// The folder the user is looking at, if any.
    var currentFolder: String? {
        guard filesSelected,
              let browser = filesNav.topViewController as? BrowserViewController,
              !browser.isEditing else { return nil }
        return browser.path
    }

    private var isEditingSomewhere: Bool {
        (filesNav.topViewController as? BrowserViewController)?.isEditing == true && filesSelected
    }

    func updateShelf() {
        let jobs = Activity.shared.jobs
        let visibleJob = jobs.first { Date().timeIntervalSince($0.started) > 0.35 }
        var show = false
        if let job = visibleJob {
            shelf.showJob(job, more: jobs.count - 1)
            show = true
        } else if !Clipboard.shared.isEmpty && !isEditingSomewhere {
            shelf.showClipboard(Clipboard.shared, canPaste: currentFolder != nil)
            show = true
        }
        shelfBottom?.constant = filesSelected ? -8 - filesTabs.stripHeight : -8
        setShelf(visible: show)
    }

    private func setShelf(visible: Bool) {
        guard visible != shelfShown else { return }
        shelfShown = visible
        let inset: CGFloat = visible ? 70 : 0
        for nav in otherNavs {
            nav.additionalSafeAreaInsets.bottom = inset
        }
        filesTabs.shelfInset = inset
        if visible {
            shelf.isHidden = false
            shelf.transform = CGAffineTransform(translationX: 0, y: 16)
        }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.shelf.alpha = visible ? 1 : 0
            self.shelf.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 16)
            self.view.layoutIfNeeded()
        } completion: { _ in
            if !self.shelfShown { self.shelf.isHidden = true }
        }
    }

    private func shelfPrimary() {
        guard Activity.shared.jobs.isEmpty, let dir = currentFolder, let vc = filesNav.topViewController else { return }
        Ops.paste(into: dir, from: vc)
    }

    private func pasteAsLink() {
        guard let dir = currentFolder, let vc = filesNav.topViewController else { return }
        Ops.paste(into: dir, from: vc, asLink: true)
    }

    private func shelfClose() {
        if let job = Activity.shared.jobs.first {
            Activity.shared.cancel(job)
        } else {
            Clipboard.shared.clear()
        }
    }

    // MARK: - Toast

    func toast(_ text: String, action: String? = nil, handler: (() -> Void)? = nil) {
        toastTimer?.invalidate()
        toastView?.removeFromSuperview()
        let toast = ToastView(text: text, action: action, handler: handler)
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        let anchor = shelfShown ? shelf.topAnchor : tabBar.topAnchor
        let extra: CGFloat = !shelfShown && filesSelected ? filesTabs.stripHeight : 0
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: anchor, constant: -10 - extra),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        toast.alpha = 0
        toast.transform = CGAffineTransform(translationX: 0, y: 8)
        UIView.animate(withDuration: 0.25) {
            toast.alpha = 1
            toast.transform = .identity
        }
        toastView = toast
        toast.onTap = { [weak self] in self?.hideToast() }
        toastTimer = Timer.scheduledTimer(withTimeInterval: action == nil ? 2.2 : 4.5, repeats: false) { [weak self] _ in
            self?.hideToast()
        }
    }

    private func hideToast() {
        guard let toast = toastView else { return }
        toastView = nil
        UIView.animate(withDuration: 0.2, animations: { toast.alpha = 0 }) { _ in toast.removeFromSuperview() }
    }

    func openInNewTab(_ path: String) {
        selectedViewController = filesTabs
        filesTabs.newTab(path: path)
        updateShelf()
    }

    /// Switches to the Files tab and opens a path.
    func reveal(_ path: String, isDirectory: Bool = true) {
        selectedViewController = filesTabs
        if presentedViewController != nil { dismiss(animated: true) }
        Navigator.show(isDirectory ? path : Paths.parent(path), in: filesNav, highlight: isDirectory ? nil : path)
        updateShelf()
    }
}

extension RootController: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        if filesTabs.allNavs.contains(navigationController) {
            filesTabs.refreshStrip(animated: true)
            filesTabs.save()
        }
        updateShelf()
    }
}

/// Floating bar above the tab bar: clipboard contents or a running job.
final class ShelfView: UIView {
    var onPrimary: (() -> Void)?
    var onClose: (() -> Void)?
    var linkAction: (() -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let primary = UIButton(type: .system)
    private let close = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)

        blur.layer.cornerRadius = 16
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        blur.layer.borderWidth = 1 / UIScreen.main.scale
        blur.layer.borderColor = UIColor.separator.cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        icon.contentMode = .center
        icon.tintColor = tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabel
        detailLabel.lineBreakMode = .byTruncatingMiddle
        progress.trackTintColor = UIColor.tertiarySystemFill

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.title = L("Paste")
        primary.configuration = config
        primary.setContentHuggingPriority(.required, for: .horizontal)
        primary.setContentCompressionResistancePriority(.required, for: .horizontal)
        primary.addAction(UIAction { [weak self] _ in self?.onPrimary?() }, for: .primaryActionTriggered)
        primary.menu = UIMenu(children: [
            UIAction(title: L("Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.onPrimary?() },
            UIAction(title: L("Paste as Symbolic Link"), image: UIImage(systemName: "link")) { [weak self] _ in self?.linkAction?() },
        ])

        close.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
        close.tintColor = .tertiaryLabel
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)

        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel, progress])
        labels.axis = .vertical
        labels.spacing = 3
        let row = UIStackView(arrangedSubviews: [icon, labels, primary, close])
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -10),
            icon.widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        icon.tintColor = tintColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        blur.layer.borderColor = UIColor.separator.cgColor
    }

    func showClipboard(_ clip: Clipboard, canPaste: Bool) {
        icon.image = UIImage(systemName: clip.isCut ? "scissors" : "doc.on.doc")
        titleLabel.text = clip.paths.count == 1 ? Paths.name(clip.paths[0]) : Ops.countText(clip.paths.count)
        if canPaste {
            detailLabel.text = clip.isCut ? L("Ready to move here") : L("Ready to paste here")
        } else {
            detailLabel.text = L("Open a folder to paste")
        }
        progress.isHidden = true
        primary.isHidden = false
        primary.isEnabled = canPaste
        primary.configuration?.title = clip.isCut ? L("Move") : L("Paste")
    }

    func showJob(_ job: Job, more: Int) {
        icon.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        titleLabel.text = more > 0 ? "\(job.title) (+\(more))" : job.title
        if let p = job.progress, p > 0 {
            detailLabel.text = "\(Int(p * 100)) %" + (job.detail.map { " · \($0)" } ?? "")
            progress.isHidden = false
            progress.setProgress(Float(p), animated: true)
        } else {
            detailLabel.text = job.detail ?? L("Working…")
            progress.isHidden = true
        }
        primary.isHidden = true
    }
}

final class ToastView: UIView {
    var onTap: (() -> Void)?
    private let handler: (() -> Void)?

    init(text: String, action: String?, handler: (() -> Void)?) {
        self.handler = handler
        super.init(frame: .zero)
        backgroundColor = UIColor.label.withAlphaComponent(0.88)
        layer.cornerRadius = 19
        layer.cornerCurve = .continuous

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .systemBackground
        label.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [label])
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let action = action {
            let button = UIButton(type: .system)
            button.setTitle(action, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.tintColor = Theme.accent
            button.addAction(UIAction { [weak self] _ in
                self?.handler?()
                self?.onTap?()
            }, for: .primaryActionTriggered)
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }
}

/// Builds the folder hierarchy as a navigation stack so Back always means "parent".
enum Navigator {
    static func ancestors(of path: String) -> [String] {
        var result: [String] = ["/"]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append(current)
        }
        return result
    }

    static func show(_ path: String, in nav: UINavigationController, highlight: String? = nil, animated: Bool = true) {
        guard let home = nav.viewControllers.first else { return }
        var stack: [UIViewController] = [home]
        let existing = nav.viewControllers.compactMap { $0 as? BrowserViewController }
        for p in ancestors(of: path) {
            if let vc = existing.first(where: { $0.path == p }) {
                stack.append(vc)
            } else {
                stack.append(BrowserViewController(path: p))
            }
        }
        if let target = stack.last as? BrowserViewController { target.highlightPath = highlight }
        nav.setViewControllers(stack, animated: animated)
    }
}
