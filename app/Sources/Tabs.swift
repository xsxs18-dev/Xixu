import UIKit

/// The Files tab: several independent folder tabs with a slim tab strip.
final class FilesTabsController: UIViewController {
    private(set) var tabs: [UINavigationController] = []
    private(set) var index = 0
    private let strip = TabStripView()
    let stripHeight: CGFloat = 44
    weak var navigationDelegate: UINavigationControllerDelegate?

    /// Extra bottom inset requested by the root controller (floating shelf).
    var shelfInset: CGFloat = 0 {
        didSet { applyInsets() }
    }

    var currentNav: UINavigationController { tabs[index] }
    var allNavs: [UINavigationController] { tabs }

    init(delegate: UINavigationControllerDelegate?) {
        navigationDelegate = delegate
        super.init(nibName: nil, bundle: nil)
        let saved = UserDefaults.standard.stringArray(forKey: "tabs") ?? []
        let paths = saved.isEmpty ? [""] : Array(saved.prefix(12))
        tabs = paths.map { makeTab(path: $0.isEmpty ? nil : $0) }
        index = min(max(UserDefaults.standard.integer(forKey: "tabIndex"), 0), tabs.count - 1)
        tabBarItem = UITabBarItem(title: L("Files"), image: UIImage(systemName: "folder"), selectedImage: UIImage(systemName: "folder.fill"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        for nav in tabs { addChild(nav); nav.didMove(toParent: self) }
        show(tabs[index], from: nil, forward: true, animated: false)
        view.addSubview(strip)
        strip.onSelect = { [weak self] i in self?.select(i, animated: true) }
        strip.onClose = { [weak self] i in self?.close(i) }
        strip.onAdd = { [weak self] in self?.newTab(path: nil) }
        strip.onCloseOthers = { [weak self] i in self?.closeOthers(i) }
        strip.onDuplicate = { [weak self] i in
            guard let self = self else { return }
            self.newTab(path: self.path(of: self.tabs[i]))
        }
        applyInsets()
        refreshStrip(animated: false)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The container's own safe area ends at the top of the tab bar.
        let bottom = view.bounds.maxY - view.safeAreaInsets.bottom
        strip.frame = CGRect(x: 0, y: bottom - stripHeight, width: view.bounds.width, height: stripHeight)
        currentNav.view.frame = view.bounds
        view.bringSubviewToFront(strip)
    }

    // MARK: - Tabs

    private func makeTab(path: String?) -> UINavigationController {
        let nav = UINavigationController(rootViewController: HomeViewController())
        nav.navigationBar.prefersLargeTitles = true
        Theme.apply(to: nav)
        nav.delegate = navigationDelegate
        nav.additionalSafeAreaInsets.bottom = stripHeight + shelfInset
        if let path = path { Navigator.show(path, in: nav, animated: false) }
        return nav
    }

    private func path(of nav: UINavigationController) -> String? {
        (nav.topViewController as? BrowserViewController)?.path
    }

    func title(of nav: UINavigationController) -> String {
        if let browser = nav.topViewController as? BrowserViewController {
            return browser.title ?? Paths.name(browser.path)
        }
        return nav.topViewController?.title ?? L("Files")
    }

    func newTab(path: String?) {
        let nav = makeTab(path: path)
        addChild(nav)
        nav.didMove(toParent: self)
        tabs.insert(nav, at: index + 1)
        Haptics.tap()
        select(index + 1, animated: true)
    }

    func select(_ i: Int, animated: Bool) {
        guard tabs.indices.contains(i) else { return }
        guard i != index else {
            refreshStrip(animated: animated)
            return
        }
        let old = tabs[index]
        index = i
        show(tabs[i], from: old, forward: i > tabs.firstIndex(of: old) ?? 0, animated: animated)
        refreshStrip(animated: animated)
        save()
        RootController.shared?.updateShelf()
    }

    func close(_ i: Int) {
        guard tabs.count > 1, tabs.indices.contains(i) else { return }
        let closing = tabs[i]
        let wasCurrent = i == index
        tabs.remove(at: i)
        if wasCurrent {
            index = min(i, tabs.count - 1)
            show(tabs[index], from: closing, forward: false, animated: true)
        } else if i < index {
            index -= 1
        }
        closing.willMove(toParent: nil)
        if !wasCurrent { closing.view.removeFromSuperview() }
        closing.removeFromParent()
        Haptics.tap()
        refreshStrip(animated: true)
        save()
    }

    func closeOthers(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        let keep = tabs[i]
        for nav in tabs where nav !== keep {
            nav.willMove(toParent: nil)
            nav.view.removeFromSuperview()
            nav.removeFromParent()
        }
        tabs = [keep]
        index = 0
        if keep.view.superview == nil { show(keep, from: nil, forward: true, animated: false) }
        refreshStrip(animated: true)
        save()
    }

    private func show(_ nav: UINavigationController, from old: UINavigationController?, forward: Bool, animated: Bool) {
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if nav.view.superview !== view { view.insertSubview(nav.view, at: 0) }
        guard let old = old, old !== nav, animated else {
            if let old = old, old !== nav { old.view.removeFromSuperview() }
            return
        }
        let shift: CGFloat = forward ? 28 : -28
        nav.view.alpha = 0
        nav.view.transform = CGAffineTransform(translationX: shift, y: 0)
        view.insertSubview(nav.view, aboveSubview: old.view)
        view.bringSubviewToFront(strip)
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            nav.view.alpha = 1
            nav.view.transform = .identity
            old.view.alpha = 0
            old.view.transform = CGAffineTransform(translationX: -shift * 0.5, y: 0)
        } completion: { _ in
            old.view.removeFromSuperview()
            old.view.alpha = 1
            old.view.transform = .identity
        }
    }

    private func applyInsets() {
        for nav in tabs { nav.additionalSafeAreaInsets.bottom = stripHeight + shelfInset }
    }

    func refreshStrip(animated: Bool) {
        guard isViewLoaded else { return }
        strip.update(titles: tabs.map { title(of: $0) }, selected: index, animated: animated)
    }

    func save() {
        UserDefaults.standard.set(tabs.map { path(of: $0) ?? "" }, forKey: "tabs")
        UserDefaults.standard.set(index, forKey: "tabIndex")
    }
}

/// Horizontal strip of tab pills with a sliding selection capsule.
final class TabStripView: UIView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onDuplicate: ((Int) -> Void)?

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let hairline = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let indicator = UIView()
    private let addButton = UIButton(type: .system)
    private var pills: [TabPill] = []
    private var selected = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(background)
        hairline.backgroundColor = .separator
        addSubview(hairline)

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        addSubview(scroll)
        indicator.backgroundColor = .tertiarySystemFill
        indicator.layer.cornerCurve = .continuous
        scroll.addSubview(indicator)
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        scroll.addSubview(stack)

        addButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        addButton.accessibilityLabel = L("New Tab")
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .primaryActionTriggered)
        addSubview(addButton)

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / max(UIScreen.main.scale, 1))
        addButton.frame = CGRect(x: bounds.width - 48, y: 0, width: 44, height: bounds.height)
        scroll.frame = CGRect(x: 8, y: 0, width: bounds.width - 60, height: bounds.height)
        let size = stack.systemLayoutSizeFitting(CGSize(width: UIView.layoutFittingCompressedSize.width, height: bounds.height))
        stack.frame = CGRect(x: 0, y: 0, width: size.width, height: bounds.height)
        scroll.contentSize = CGSize(width: size.width, height: bounds.height)
        moveIndicator(animated: false)
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        let next = gesture.direction == .left ? selected + 1 : selected - 1
        if pills.indices.contains(next) { onSelect?(next) }
    }

    func update(titles: [String], selected: Int, animated: Bool) {
        let rebuild = titles.count != pills.count
        if rebuild {
            pills.forEach { $0.removeFromSuperview() }
            pills = titles.indices.map { makePill($0) }
            pills.forEach { stack.addArrangedSubview($0) }
        }
        self.selected = selected
        for (i, pill) in pills.enumerated() {
            configure(pill, title: titles[i], isSelected: i == selected, closable: titles.count > 1)
        }
        setNeedsLayout()
        layoutIfNeeded()
        moveIndicator(animated: animated && !rebuild)
        if pills.indices.contains(selected) {
            scroll.scrollRectToVisible(pills[selected].frame.insetBy(dx: -24, dy: 0), animated: animated)
        }
    }

    private func makePill(_ i: Int) -> TabPill {
        let pill = TabPill()
        pill.index = i
        pill.onSelect = { [weak self] index in self?.onSelect?(index) }
        pill.onClose = { [weak self] index in self?.onClose?(index) }
        pill.menuProvider = { [weak self] index in
            guard let self = self else { return [] }
            var items: [UIMenuElement] = [
                UIAction(title: L("Duplicate Tab"), image: UIImage(systemName: "plus.square.on.square")) { _ in self.onDuplicate?(index) },
            ]
            if self.pills.count > 1 {
                items.append(UIAction(title: L("Close Other Tabs"), image: UIImage(systemName: "xmark.square")) { _ in self.onCloseOthers?(index) })
                items.append(UIAction(title: L("Close Tab"), image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in self.onClose?(index) })
            }
            return items
        }
        return pill
    }

    private func configure(_ pill: TabPill, title: String, isSelected: Bool, closable: Bool) {
        pill.configure(title: title, selected: isSelected, closable: closable)
    }

    private func moveIndicator(animated: Bool) {
        guard pills.indices.contains(selected) else { return }
        let target = pills[selected].frame.insetBy(dx: 0, dy: (pills[selected].frame.height - 30) / 2)
        let frame = CGRect(x: target.minX, y: (bounds.height - 30) / 2, width: target.width, height: 30)
        let change = {
            self.indicator.frame = frame
            self.indicator.layer.cornerRadius = 15
        }
        if animated {
            UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        } else {
            change()
        }
    }
}

/// One tab: title (tap to switch, long-press for a menu) and a close button on the active tab.
private final class TabPill: UIView {
    var index = 0
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var menuProvider: ((Int) -> [UIMenuElement])?

    private let titleButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    init() {
        super.init(frame: .zero)
        titleButton.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.onSelect?(self.index)
        }, for: .primaryActionTriggered)
        titleButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            guard let self = self else { return done([]) }
            done(self.menuProvider?(self.index) ?? [])
        }])
        titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.accessibilityLabel = L("Close Tab")
        closeButton.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.onClose?(self.index)
        }, for: .primaryActionTriggered)
        closeButton.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let row = UIStackView(arrangedSubviews: [titleButton, closeButton])
        row.alignment = .center
        row.spacing = -6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, selected: Bool, closable: Bool) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.titleLineBreakMode = .byTruncatingMiddle
        config.baseForegroundColor = selected ? .label : .secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var a = attributes
            a.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            return a
        }
        titleButton.configuration = config
        closeButton.isHidden = !(selected && closable)
    }
}
