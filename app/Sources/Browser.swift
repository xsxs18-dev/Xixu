import UIKit
import Darwin
import QuickLookThumbnailing
import UniformTypeIdentifiers
import PhotosUI

/// One folder. Lists, sorts, filters, searches recursively and hosts every file action.
final class BrowserViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating,
    UISearchBarDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {

    let path: String
    var highlightPath: String?
    /// App name for container folders, set by whoever pushes us.
    var customTitle: String?

    private var all: [FileItem] = []
    private var shown: [FileItem] = []
    private var results: [FileItem] = []
    private var lookup: [String: FileItem] = [:]
    private var loaded = false
    private var loadError: Error?
    private var lastLoad: CFAbsoluteTime = 0
    private var appliedOnce = false
    private var reconfigureAllOnNextApply = false
    private var freeSpace: Int64?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private weak var footerCell: UICollectionViewListCell?
    private weak var headerCell: UICollectionViewListCell?
    private let refresher = UIRefreshControl()
    private var loadingTimer: Timer?

    private var searchController: UISearchController!
    private var query = ""
    private var scope = 0
    private var searchID: Int?
    private var searchRunning = false
    private var searchTimer: Timer?

    private var moreItem: UIBarButtonItem!
    private var addItem: UIBarButtonItem!

    private var isRecursive: Bool { scope == 1 && !query.isEmpty }
    private var currentList: [FileItem] { isRecursive ? results : shown }

    init(path: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let id = searchID { FS.shared.cancel(id) }
    }

    private var displayTitle: String {
        if let custom = customTitle { return custom }
        if path == "/" { return L("Root") }
        if path == JB.displayRoot || path == JB.root { return L("Jailbreak") }
        return Paths.name(path)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = displayTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        setUpCollection()
        setUpSearch()
        setUpTitle()
        setUpBarItems()
        updateNavItems()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(filesChanged(_:)), name: .filesChanged, object: nil)
        center.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
        center.addObserver(self, selector: #selector(appsLoaded), name: .appsLoaded, object: nil)
        center.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)

        load(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if loaded && CFAbsoluteTimeGetCurrent() - lastLoad > 2 { load(animated: true) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isEditing && navigationController?.topViewController !== self { setEditing(false, animated: false) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if appliedOnce && previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            reconfigureAllOnNextApply = true
            apply(animated: false)
        }
    }

    @objc private func foreground() {
        if viewIfLoaded?.window != nil { load(animated: true) }
    }

    // MARK: - Setup

    private func setUpCollection() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.keyboardDismissMode = .onDrag
        refresher.addTarget(self, action: #selector(pulled), for: .valueChanged)
        collectionView.refreshControl = refresher
        view.addSubview(collectionView)

        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self = self, let item = self.lookup[id] else { return }
            self.configure(cell, item)
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, _ in
            self?.footerCell = cell
            self?.configureFooter(cell)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, _ in
            self?.headerCell = cell
            self?.configureHeader(cell)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, indexPath, id in
            cv.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return cv.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }
            return cv.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.headerMode = self?.isRecursive == true ? .supplementary : .none
            config.footerMode = .supplementary
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in self?.trailingSwipe(indexPath) }
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in self?.leadingSwipe(indexPath) }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func setUpSearch() {
        let controller = UISearchController(searchResultsController: nil)
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchResultsUpdater = self
        controller.searchBar.delegate = self
        controller.searchBar.placeholder = L("Search")
        controller.searchBar.scopeButtonTitles = [L("This Folder"), L("Subfolders")]
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.spellCheckingType = .no
        navigationItem.searchController = controller
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        searchController = controller
    }

    private func setUpTitle() {
        var config = UIButton.Configuration.plain()
        config.title = displayTitle
        config.subtitle = path
        config.titleAlignment = .center
        config.titleLineBreakMode = .byTruncatingMiddle
        config.subtitleLineBreakMode = .byTruncatingHead
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var a = attributes
            a.font = .systemFont(ofSize: 16, weight: .semibold)
            a.foregroundColor = .label
            return a
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var a = attributes
            a.font = .systemFont(ofSize: 11, weight: .regular)
            a.foregroundColor = .secondaryLabel
            return a
        }
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.titleMenuElements() ?? [])
        }])
        let maxWidth = min(UIScreen.main.bounds.width - 140, 460)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        navigationItem.titleView = button
    }

    private func setUpBarItems() {
        moreItem = UIBarButtonItem(title: L("More"), image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil,
                                   menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
                                       done(self?.moreMenuElements() ?? [])
                                   }]))
        addItem = UIBarButtonItem(title: L("New"), image: UIImage(systemName: "plus"), primaryAction: nil,
                                  menu: UIMenu(children: addMenuElements()))
    }

    // MARK: - Menus

    private func titleMenuElements() -> [UIMenuElement] {
        var ancestors: [UIMenuElement] = []
        for p in Navigator.ancestors(of: path).dropLast().reversed() {
            let title = p == "/" ? "/" : Paths.name(p)
            ancestors.append(UIAction(title: title, image: UIImage(systemName: "folder")) { [weak self] _ in self?.go(to: p) })
        }
        let actions: [UIMenuElement] = [
            UIAction(title: L("Copy Path"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let self = self else { return }
                Ops.copyPaths([self.path])
            },
            UIAction(title: L("Go to Folder…"), image: UIImage(systemName: "arrow.right.circle")) { [weak self] _ in
                guard let self = self else { return }
                self.presentModal(GoToViewController(start: self.path))
            },
        ]
        return [UIMenu(options: .displayInline, children: ancestors), UIMenu(options: .displayInline, children: actions)]
    }

    private func go(to target: String) {
        guard let nav = navigationController else { return }
        if let vc = nav.viewControllers.first(where: { ($0 as? BrowserViewController)?.path == target }) {
            nav.popToViewController(vc, animated: true)
        } else {
            Navigator.show(target, in: nav)
        }
    }

    private func moreMenuElements() -> [UIMenuElement] {
        let select = UIAction(title: L("Select"), image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
            self?.setEditing(true, animated: true)
        }

        let current = Prefs.sortKey
        let ascending = Prefs.sortAscending
        var sortActions: [UIMenuElement] = SortKey.allCases.map { key in
            let image = key == current ? UIImage(systemName: ascending ? "chevron.up" : "chevron.down") : nil
            return UIAction(title: key.title, image: image, state: key == current ? .on : .off) { _ in
                if key == Prefs.sortKey {
                    Prefs.sortAscending.toggle()
                } else {
                    Prefs.sortAscending = key == .name || key == .kind
                    Prefs.sortKey = key
                }
            }
        }
        sortActions.append(UIAction(title: L("Folders on Top"), state: Prefs.foldersFirst ? .on : .off) { _ in
            Prefs.foldersFirst.toggle()
        })
        let sort = UIMenu(title: L("Sort By"), image: UIImage(systemName: "arrow.up.arrow.down"), children: sortActions)

        let hidden = UIAction(title: L("Show Hidden Files"), image: UIImage(systemName: "eye"), state: Prefs.showHidden ? .on : .off) { _ in
            Prefs.showHidden.toggle()
        }

        let favorite = Bookmarks.isFavorite(path)
        let folderActions: [UIMenuElement] = [
            UIAction(title: favorite ? L("Remove from Favorites") : L("Add to Favorites"),
                     image: UIImage(systemName: favorite ? "star.slash" : "star")) { [weak self] _ in
                guard let self = self else { return }
                Bookmarks.toggleFavorite(self.path)
                Haptics.tap()
                RootController.shared?.toast(favorite ? L("Removed from Favorites") : L("Added to Favorites"))
            },
            UIAction(title: L("Info"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
                guard let self = self else { return }
                self.presentModal(InfoViewController(path: self.path))
            },
            UIAction(title: L("Copy Path"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let self = self else { return }
                Ops.copyPaths([self.path])
            },
            UIAction(title: L("Go to Folder…"), image: UIImage(systemName: "arrow.right.circle")) { [weak self] _ in
                guard let self = self else { return }
                self.presentModal(GoToViewController(start: self.path))
            },
            UIAction(title: L("Open in New Tab"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                guard let self = self else { return }
                RootController.shared?.openInNewTab(self.path)
            },
        ]
        return [
            UIMenu(options: .displayInline, children: [select]),
            UIMenu(options: .displayInline, children: [sort, hidden]),
            UIMenu(options: .displayInline, children: folderActions),
        ]
    }

    private func addMenuElements() -> [UIMenuElement] {
        let create: [UIMenuElement] = [
            UIAction(title: L("New Folder"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                guard let self = self else { return }
                Ops.newFolder(in: self.path, from: self)
            },
            UIAction(title: L("New File"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                guard let self = self else { return }
                Ops.newFile(in: self.path, from: self)
            },
            UIAction(title: L("New Symbolic Link"), image: UIImage(systemName: "link.badge.plus")) { [weak self] _ in
                guard let self = self else { return }
                Ops.newSymlink(in: self.path, from: self)
            },
        ]
        let importing: [UIMenuElement] = [
            UIAction(title: L("Import from Files"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                self?.importFromFiles()
            },
            UIAction(title: L("Import from Photos"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                self?.importFromPhotos()
            },
        ]
        return [UIMenu(options: .displayInline, children: create), UIMenu(options: .displayInline, children: importing)]
    }

    private func updateNavItems() {
        if isEditing {
            let selectedCount = collectionView.indexPathsForSelectedItems?.count ?? 0
            let allSelected = selectedCount > 0 && selectedCount == currentList.count
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: allSelected ? L("Deselect All") : L("Select All"),
                                                               primaryAction: UIAction { [weak self] _ in self?.toggleSelectAll() })
            navigationItem.rightBarButtonItems = [UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.setEditing(false, animated: true)
            })]
        } else {
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItems = [moreItem, addItem]
        }
    }

    // MARK: - Loading

    @objc private func pulled() { load(animated: true) }

    private func load(animated: Bool) {
        loadingTimer?.invalidate()
        if !loaded {
            loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                guard let self = self, !self.loaded else { return }
                self.collectionView.backgroundView = EmptyStateView(title: nil, loading: true)
            }
        }
        let target = path
        Task { @MainActor in
            do {
                let entries = try await FS.shared.list(target)
                self.all = entries.map { FileItem(dir: target, entry: $0) }
                self.loadError = nil
            } catch {
                self.all = []
                self.loadError = error
            }
            self.loaded = true
            self.lastLoad = CFAbsoluteTimeGetCurrent()
            self.loadingTimer?.invalidate()
            self.freeSpace = Self.availableSpace(target)
            self.refresher.endRefreshing()
            self.rebuildList(animated: animated && self.appliedOnce)
            self.revealHighlight()
        }
    }

    private static func availableSpace(_ path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    private func rebuildList(animated: Bool) {
        var list = all
        if !Prefs.showHidden { list = list.filter { !$0.isHidden } }
        if scope == 0 && !query.isEmpty {
            list = list.filter {
                $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || $0.displayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        shown = sorted(list)
        apply(animated: animated)
    }

    private func sorted(_ list: [FileItem]) -> [FileItem] {
        let key = Prefs.sortKey
        let ascending = Prefs.sortAscending
        let foldersFirst = Prefs.foldersFirst
        return list.sorted { a, b in
            if foldersFirst && a.isDirectory != b.isDirectory { return a.isDirectory }
            var result: ComparisonResult
            switch key {
            case .name:
                result = a.displayName.localizedStandardCompare(b.displayName)
            case .date:
                result = a.entry.mtime == b.entry.mtime ? .orderedSame : (a.entry.mtime < b.entry.mtime ? .orderedAscending : .orderedDescending)
            case .size:
                result = a.entry.size == b.entry.size ? .orderedSame : (a.entry.size < b.entry.size ? .orderedAscending : .orderedDescending)
            case .kind:
                result = Paths.split(a.name).ext.lowercased().compare(Paths.split(b.name).ext.lowercased())
            }
            if result == .orderedSame {
                result = a.displayName.localizedStandardCompare(b.displayName)
                return result == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func apply(animated: Bool) {
        let list = currentList
        let previous = lookup
        var map: [String: FileItem] = [:]
        map.reserveCapacity(list.count)
        for item in list where map[item.path] == nil { map[item.path] = item }
        lookup = map

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        var seen = Set<String>()
        snapshot.appendItems(list.compactMap { seen.insert($0.path).inserted ? $0.path : nil })
        if reconfigureAllOnNextApply {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            reconfigureAllOnNextApply = false
        } else {
            let changed = snapshot.itemIdentifiers.filter { id in
                if let old = previous[id], let new = map[id] { return old.entry != new.entry }
                return false
            }
            if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
        appliedOnce = true
        updateBackground()
        if let footer = footerCell { configureFooter(footer) }
        if let header = headerCell { configureHeader(header) }
        if isEditing { updateToolbar() }
    }

    private func reconfigure(_ ids: [String]) {
        var snapshot = dataSource.snapshot()
        let valid = ids.filter { snapshot.indexOfItem($0) != nil }
        guard !valid.isEmpty else { return }
        snapshot.reconfigureItems(valid)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func updateBackground() {
        guard loaded else { return }
        let list = currentList
        if let error = loadError, !isRecursive {
            collectionView.backgroundView = EmptyStateView(title: L("Can't Open Folder"), message: error.localizedDescription,
                                                           symbol: "exclamationmark.triangle")
        } else if list.isEmpty {
            if isRecursive {
                collectionView.backgroundView = searchRunning ? EmptyStateView(title: nil, loading: true)
                    : EmptyStateView(title: L("No Results"), symbol: "magnifyingglass")
            } else if !query.isEmpty {
                collectionView.backgroundView = EmptyStateView(title: L("No Results"), symbol: "magnifyingglass")
            } else {
                let hiddenCount = Prefs.showHidden ? 0 : all.filter(\.isHidden).count
                collectionView.backgroundView = EmptyStateView(title: L("Empty Folder"),
                                                               message: hiddenCount > 0 ? LF("%d hidden items", hiddenCount) : nil,
                                                               symbol: "folder")
            }
        } else {
            collectionView.backgroundView = nil
        }
    }

    private func configureFooter(_ cell: UICollectionViewListCell) {
        var c = UIListContentConfiguration.plainFooter()
        if !isRecursive && loaded && loadError == nil && !shown.isEmpty {
            var parts = [Ops.countText(shown.count)]
            if let free = freeSpace { parts.append(LF("%@ available", Format.bytes(free))) }
            c.text = parts.joined(separator: " · ")
        } else {
            c.text = nil
        }
        c.textProperties.alignment = .center
        c.textProperties.font = Theme.digits(12)
        c.textProperties.color = .secondaryLabel
        cell.contentConfiguration = c
        cell.backgroundConfiguration = .clear()
    }

    private func configureHeader(_ cell: UICollectionViewListCell) {
        var c = UIListContentConfiguration.plainHeader()
        let count = results.count == 1 ? L("1 result") : LF("%d results", results.count)
        c.text = searchRunning ? LF("Searching… · %@", count) : count
        c.textProperties.font = Theme.digits(12, .medium)
        c.textProperties.color = .secondaryLabel
        cell.contentConfiguration = c
    }

    private func revealHighlight() {
        guard let target = highlightPath, let indexPath = dataSource.indexPath(for: target) else { return }
        highlightPath = nil
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, !self.isEditing else { return }
            self.collectionView.deselectItem(at: indexPath, animated: true)
        }
    }

    // MARK: - Notifications

    @objc private func filesChanged(_ note: Notification) {
        guard let dirs = note.userInfo?["dirs"] as? Set<String> else {
            load(animated: true)
            return
        }
        let variants: Set<String> = [path, "/private" + path, path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path]
        if !dirs.isDisjoint(with: variants) {
            load(animated: true)
        } else if isRecursive, dirs.contains(where: { Paths.isInside($0, path) }) {
            startSearch()
        }
    }

    @objc private func prefsChanged() {
        reconfigureAllOnNextApply = true
        load(animated: true)
    }

    @objc private func appsLoaded() {
        reconfigureAllOnNextApply = true
        rebuildList(animated: false)
    }

    // MARK: - Cells

    private enum IconStyle {
        case drawn
        case picture
        case appIcon
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: FileItem) {
        var c = UIListContentConfiguration.subtitleCell()
        c.text = item.displayName
        c.textProperties.font = .preferredFont(forTextStyle: .body)
        c.textProperties.lineBreakMode = .byTruncatingMiddle
        c.textProperties.numberOfLines = 1
        c.textProperties.color = item.isHidden ? .secondaryLabel : .label
        c.secondaryText = subtitle(for: item)
        c.secondaryTextProperties.font = Theme.digits(13)
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        c.secondaryTextProperties.numberOfLines = 1
        c.textToSecondaryTextVerticalPadding = 3

        let (image, style) = icon(for: item)
        c.image = image
        c.imageProperties.reservedLayoutSize = CGSize(width: 34, height: 34)
        c.imageProperties.maximumSize = CGSize(width: 34, height: 34)
        switch style {
        case .drawn, .appIcon:
            c.imageProperties.cornerRadius = 0
        case .picture:
            c.imageProperties.cornerRadius = 5
        }
        c.imageToTextPadding = 14
        c.directionalLayoutMargins.top = 10
        c.directionalLayoutMargins.bottom = 10
        cell.contentConfiguration = c

        var accessories: [UICellAccessory] = []
        if item.isDirectory { accessories.append(.disclosureIndicator(displayed: .whenNotEditing)) }
        accessories.append(.multiselect(displayed: .whenEditing))
        cell.accessories = accessories
    }

    private func subtitle(for item: FileItem) -> String {
        let e = item.entry
        if isRecursive, let dir = e.dir {
            var location: String
            if dir == path {
                location = displayTitle
            } else {
                let prefix = path == "/" ? "/" : path + "/"
                location = dir.hasPrefix(prefix) ? String(dir.dropFirst(prefix.count)) : dir
            }
            if e.kind == .file { location += " · " + Format.bytes(e.size) }
            return location
        }
        var parts: [String] = []
        if Prefs.showDetails {
            parts.append(Format.permissions(e.mode, kind: e.kind) + " " + ownerName(e.uid))
        }
        if let id = item.containerID {
            parts.append(item.displayName == id ? Format.date(e.mtime) : id)
        } else if item.isSymlink {
            parts.append("→ " + (e.link ?? "?"))
        } else {
            parts.append(Format.date(e.mtime))
            if e.kind == .file { parts.append(Format.bytes(e.size)) }
        }
        return parts.joined(separator: " · ")
    }

    private func ownerName(_ uid: UInt32) -> String {
        switch uid {
        case 0: return "root"
        case 501: return "mobile"
        default: return "\(uid)"
        }
    }

    private func icon(for item: FileItem) -> (UIImage?, IconStyle) {
        if let id = item.containerID, let image = AppRegistry.shared.icon(for: id, size: 34) {
            return (image, .appIcon)
        }
        if item.kind == .app, let image = Icons.app(bundlePath: item.path, size: 34) {
            return (image, .appIcon)
        }
        if Prefs.thumbnails, item.entry.kind == .file, [.image, .video, .pdf].contains(item.kind) {
            let key = Thumbnails.key(item)
            if let thumb = Thumbnails.cache.object(forKey: key as NSString) { return (thumb, .picture) }
            requestThumbnail(item, key: key)
        }
        return (Icons.file(item, size: 34, dark: traitCollection.userInterfaceStyle == .dark), .drawn)
    }

    private func requestThumbnail(_ item: FileItem, key: String) {
        guard !Thumbnails.pending.contains(key), !Thumbnails.failed.contains(key),
              Darwin.access(item.path, R_OK) == 0 else { return }
        Thumbnails.pending.insert(key)
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: item.path), size: CGSize(width: 34, height: 34),
                                                   scale: traitCollection.displayScale, representationTypes: .thumbnail)
        let id = item.path
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async {
                Thumbnails.pending.remove(key)
                guard let image = representation?.uiImage else {
                    Thumbnails.failed.insert(key)
                    return
                }
                Thumbnails.cache.setObject(image, forKey: key as NSString)
                self?.reconfigure([id])
            }
        }
    }

    // MARK: - Selection

    private func item(at indexPath: IndexPath) -> FileItem? {
        dataSource.itemIdentifier(for: indexPath).flatMap { lookup[$0] }
    }

    private var selectedItems: [FileItem] {
        (collectionView.indexPathsForSelectedItems ?? []).sorted().compactMap { item(at: $0) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isEditing {
            updateToolbar()
            updateNavItems()
            return
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = item(at: indexPath) else { return }
        open(item)
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if isEditing {
            updateToolbar()
            updateNavItems()
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        true
    }

    func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        setEditing(true, animated: true)
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            let vc = BrowserViewController(path: item.path)
            if item.displayName != item.name { vc.customTitle = item.displayName }
            navigationController?.pushViewController(vc, animated: true)
        } else {
            Opener.open(item, from: self, siblings: isRecursive ? [] : shown)
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        if !editing {
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
        navigationItem.hidesBackButton = editing
        updateNavItems()
        updateToolbar()
        navigationController?.setToolbarHidden(!editing, animated: animated)
        NotificationCenter.default.post(name: .editingChanged, object: self)
    }

    private func toggleSelectAll() {
        let selected = collectionView.indexPathsForSelectedItems?.count ?? 0
        let total = collectionView.numberOfItems(inSection: 0)
        if selected == total {
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        } else {
            for row in 0..<total {
                collectionView.selectItem(at: IndexPath(item: row, section: 0), animated: false, scrollPosition: [])
            }
        }
        updateToolbar()
        updateNavItems()
    }

    private func updateToolbar() {
        let selection = selectedItems
        let paths = selection.map(\.path)
        let enabled = !selection.isEmpty

        func button(_ symbol: String, _ title: String, _ handler: @escaping (UIBarButtonItem) -> Void) -> UIBarButtonItem {
            let item = UIBarButtonItem(title: title, image: UIImage(systemName: symbol), primaryAction: nil, menu: nil)
            item.primaryAction = UIAction(title: title, image: UIImage(systemName: symbol)) { [weak item] _ in
                if let item = item { handler(item) }
            }
            item.isEnabled = enabled
            return item
        }

        let copy = button("doc.on.doc", L("Copy")) { [weak self] _ in
            Clipboard.shared.set(paths, cut: false)
            self?.setEditing(false, animated: true)
        }
        let cut = button("scissors", L("Cut")) { [weak self] _ in
            Clipboard.shared.set(paths, cut: true)
            self?.setEditing(false, animated: true)
        }
        let share = button("square.and.arrow.up", L("Share")) { [weak self] item in
            guard let self = self else { return }
            Ops.share(paths, from: self, source: item)
        }
        let compress = button("doc.zipper", L("Compress")) { [weak self] _ in
            guard let self = self else { return }
            Ops.compress(paths, from: self)
            self.setEditing(false, animated: true)
        }
        let delete = button("trash", L("Delete")) { [weak self] item in
            guard let self = self else { return }
            Ops.delete(paths, from: self, source: item) { [weak self] in self?.setEditing(false, animated: true) }
        }
        let more = UIBarButtonItem(title: L("More"), image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: UIMenu(children: [
            UIAction(title: L("Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                guard let self = self else { return }
                Ops.duplicate(paths, from: self)
                self.setEditing(false, animated: true)
            },
            UIAction(title: L("Copy Paths"), image: UIImage(systemName: "doc.on.clipboard")) { _ in Ops.copyPaths(paths) },
        ]))
        more.isEnabled = enabled
        let flex = UIBarButtonItem.flexibleSpace()
        toolbarItems = [copy, flex, cut, flex, share, flex, compress, flex, more, flex, delete]
    }

    // MARK: - Swipe and context menus

    private func trailingSwipe(_ indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isEditing, let item = item(at: indexPath) else { return nil }
        let toTrash = Prefs.useTrash && !Ops.isInTrash(item.path)
        let delete = UIContextualAction(style: .destructive, title: toTrash ? L("Trash") : L("Delete")) { [weak self] _, _, done in
            guard let self = self else { return done(false) }
            Ops.delete([item.path], from: self, source: nil)
            done(true)
        }
        delete.image = UIImage(systemName: "trash")
        let info = UIContextualAction(style: .normal, title: L("Info")) { [weak self] _, _, done in
            self?.presentModal(InfoViewController(path: item.path))
            done(true)
        }
        info.image = UIImage(systemName: "info.circle")
        info.backgroundColor = .systemGray
        return UISwipeActionsConfiguration(actions: [delete, info])
    }

    private func leadingSwipe(_ indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isEditing, let item = item(at: indexPath) else { return nil }
        let copy = UIContextualAction(style: .normal, title: L("Copy")) { _, _, done in
            Clipboard.shared.set([item.path], cut: false)
            Haptics.tap()
            done(true)
        }
        copy.image = UIImage(systemName: "doc.on.doc")
        copy.backgroundColor = Theme.accent
        let config = UISwipeActionsConfiguration(actions: [copy])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing, let item = item(at: indexPath) else { return nil }
        let cell = collectionView.cellForItem(at: indexPath)
        let siblings = isRecursive ? [] : shown
        let directory = path
        return UIContextMenuConfiguration(identifier: item.path as NSString, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            return ItemMenu.menu(for: [item], from: self, siblings: siblings, source: cell, currentDirectory: directory)
        }
    }

    // MARK: - Search

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        let newScope = searchController.searchBar.selectedScopeButtonIndex
        guard text != query || newScope != scope else { return }
        let wasRecursive = isRecursive
        query = text
        scope = newScope
        if wasRecursive != isRecursive {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        cancelSearch()
        if scope == 1 {
            results = []
            if !query.isEmpty {
                searchRunning = true
                searchTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.startSearch() }
            }
            apply(animated: false)
            if !isRecursive { rebuildList(animated: false) }
        } else {
            rebuildList(animated: false)
        }
    }

    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
        updateSearchResults(for: searchController)
    }

    private func cancelSearch() {
        searchTimer?.invalidate()
        searchTimer = nil
        if let id = searchID { FS.shared.cancel(id) }
        searchID = nil
        searchRunning = false
    }

    private func startSearch() {
        cancelSearch()
        guard isRecursive else { return }
        var text = query
        var flags: [String] = []
        if text.count > 2 && text.hasPrefix("/") && text.hasSuffix("/") {
            flags.append("regex")
            text = String(text.dropFirst().dropLast())
        } else if text.contains("*") || text.contains("?") {
            flags.append("glob")
        }
        if Prefs.showHidden { flags.append("hidden") }
        var request = Request(op: "search", path: path, text: text, length: 5000, flags: flags)
        request.id = FS.shared.makeID()
        let id = request.id
        searchID = id
        searchRunning = true
        results = []
        apply(animated: false)
        Task { @MainActor in
            do {
                _ = try await FS.shared.call(request) { [weak self] update in
                    guard let self = self, self.searchID == id, let entries = update.entries else { return }
                    self.results += entries.compactMap { entry in entry.dir.map { FileItem(dir: $0, entry: entry) } }
                    self.apply(animated: false)
                }
            } catch {
                if self.searchID == id, let e = error as? XixuError, !e.isCancelled {
                    self.showError(error, title: L("Search Failed"))
                }
            }
            if self.searchID == id {
                self.searchID = nil
                self.searchRunning = false
                self.apply(animated: false)
            }
        }
    }

    // MARK: - Import

    private func importFromFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importFiles(urls.map(\.path))
    }

    private func importFromPhotos() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let staging = Staging.newDirectory()
        let group = DispatchGroup()
        let lock = NSLock()
        var files: [String] = []
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            let types = provider.registeredTypeIdentifiers
            let preferred = types.first { id in
                guard let type = UTType(id) else { return false }
                return type.conforms(to: .movie) || type.conforms(to: .image)
            } ?? types.first
            guard let type = preferred else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }
                let dir = (staging as NSString).appendingPathComponent("\(index)")
                let target = (dir as NSString).appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(atPath: url.path, toPath: target)
                    lock.lock(); files.append(target); lock.unlock()
                } catch {}
            }
        }
        group.notify(queue: .main) { [weak self] in
            if !files.isEmpty { self?.importFiles(files) }
        }
    }

    private func importFiles(_ files: [String]) {
        guard !files.isEmpty else { return }
        let destination = path
        Task { @MainActor in
            do {
                _ = try await Activity.shared.run(L("Importing"), Request(op: "move", paths: files, dest: destination, text: "keepboth"))
                Haptics.success()
                RootController.shared?.toast(files.count == 1 ? L("1 item imported") : LF("%d items imported", files.count))
            } catch {
                self.showError(error)
            }
            announceChanges([destination])
        }
    }
}

/// Thumbnail cache shared by all folders.
private enum Thumbnails {
    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600
        return c
    }()
    static var pending = Set<String>()
    static var failed = Set<String>()

    static func key(_ item: FileItem) -> String { "\(item.path)|\(item.entry.mtime)|\(item.entry.size)" }
}

/// The context menu for one or more items.
enum ItemMenu {
    static func menu(for items: [FileItem], from vc: UIViewController, siblings: [FileItem], source: UIView?,
                     currentDirectory: String? = nil) -> UIMenu {
        guard let first = items.first else { return UIMenu() }
        let paths = items.map(\.path)
        let single = items.count == 1
        var sections: [UIMenuElement] = []

        if single {
            var open: [UIMenuElement] = []
            if !first.isDirectory {
                open.append(Opener.openWithMenu(for: first, from: vc, siblings: siblings))
            }
            open.append(UIAction(title: L("Info"), image: UIImage(systemName: "info.circle")) { [weak vc] _ in
                vc?.presentModal(InfoViewController(path: first.path))
            })
            if first.isDirectory {
                open.append(UIAction(title: L("Open in New Tab"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                    RootController.shared?.openInNewTab(first.path)
                })
            }
            if let dir = currentDirectory, first.parent != dir {
                open.append(UIAction(title: L("Show in Folder"), image: UIImage(systemName: "folder")) { _ in
                    RootController.shared?.reveal(first.path, isDirectory: false)
                })
            }
            sections.append(UIMenu(options: .displayInline, children: open))
        }

        var edit: [UIMenuElement] = [
            UIAction(title: L("Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                Clipboard.shared.set(paths, cut: false)
            },
            UIAction(title: L("Cut"), image: UIImage(systemName: "scissors")) { _ in
                Clipboard.shared.set(paths, cut: true)
            },
            UIAction(title: L("Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak vc] _ in
                guard let vc = vc else { return }
                Ops.duplicate(paths, from: vc)
            },
        ]
        if single {
            edit.append(UIAction(title: L("Rename"), image: UIImage(systemName: "pencil")) { [weak vc] _ in
                guard let vc = vc else { return }
                Ops.rename(first, from: vc)
            })
            edit.append(UIAction(title: L("Make Symbolic Link"), image: UIImage(systemName: "link")) { [weak vc] _ in
                guard let vc = vc else { return }
                Ops.newSymlink(in: first.parent, target: first.path, from: vc)
            })
        }
        sections.append(UIMenu(options: .displayInline, children: edit))

        var package: [UIMenuElement] = [
            UIAction(title: L("Compress"), image: UIImage(systemName: "doc.zipper")) { [weak vc] _ in
                guard let vc = vc else { return }
                Ops.compress(paths, from: vc)
            },
        ]
        if single && (first.kind == .archive || first.kind == .ipa) {
            package.append(UIAction(title: L("Extract"), image: UIImage(systemName: "tray.and.arrow.up")) { [weak vc] _ in
                guard let vc = vc else { return }
                Ops.extract(first.path, from: vc)
            })
        }
        if single && first.kind == .ipa {
            package.append(UIAction(title: L("Install App"), image: UIImage(systemName: "arrow.down.app")) { [weak vc] _ in
                guard let vc = vc else { return }
                Ops.installIPA(first.path, from: vc)
            })
        }
        if single && first.kind == .deb {
            package.append(UIAction(title: L("Install"), image: UIImage(systemName: "arrow.down.circle")) { [weak vc] _ in
                guard let vc = vc else { return }
                Ops.install(first.path, from: vc)
            })
        }
        sections.append(UIMenu(options: .displayInline, children: package))

        var more: [UIMenuElement] = [
            UIAction(title: L("Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak vc, weak source] _ in
                guard let vc = vc else { return }
                Ops.share(paths, from: vc, source: source)
            },
            UIAction(title: single ? L("Copy Path") : L("Copy Paths"), image: UIImage(systemName: "doc.on.clipboard")) { _ in
                Ops.copyPaths(paths)
            },
        ]
        if single && first.isDirectory {
            let favorite = Bookmarks.isFavorite(first.path)
            more.append(UIAction(title: favorite ? L("Remove from Favorites") : L("Add to Favorites"),
                                 image: UIImage(systemName: favorite ? "star.slash" : "star")) { _ in
                Bookmarks.toggleFavorite(first.path)
                Haptics.tap()
            })
        }
        sections.append(UIMenu(options: .displayInline, children: more))

        let toTrash = Prefs.useTrash && !paths.contains(where: Ops.isInTrash)
        sections.append(UIAction(title: toTrash ? L("Move to Trash") : L("Delete"), image: UIImage(systemName: "trash"),
                                 attributes: .destructive) { [weak vc, weak source] _ in
            guard let vc = vc else { return }
            Ops.delete(paths, from: vc, source: source)
        })
        return UIMenu(children: sections)
    }
}
