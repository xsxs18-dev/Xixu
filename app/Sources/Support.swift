import UIKit

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

extension Notification.Name {
    static let prefsChanged = Notification.Name("XixuPrefsChanged")
    static let filesChanged = Notification.Name("XixuFilesChanged")
    static let clipboardChanged = Notification.Name("XixuClipboardChanged")
    static let activityChanged = Notification.Name("XixuActivityChanged")
    static let editingChanged = Notification.Name("XixuEditingChanged")
    static let bookmarksChanged = Notification.Name("XixuBookmarksChanged")
    static let appsLoaded = Notification.Name("XixuAppsLoaded")
    static let updateChanged = Notification.Name("XixuUpdateChanged")
}

/// Tells open folders that their contents changed.
func announceChanges(_ dirs: [String]) {
    NotificationCenter.default.post(name: .filesChanged, object: nil, userInfo: ["dirs": Set(dirs)])
}

// MARK: - Preferences

enum SortKey: String, CaseIterable {
    case name, date, size, kind

    var title: String {
        switch self {
        case .name: return L("Name")
        case .date: return L("Date")
        case .size: return L("Size")
        case .kind: return L("Kind")
        }
    }
}

enum ThemeStyle: String, CaseIterable {
    case xixu, ios, macos, linux

    var title: String {
        switch self {
        case .xixu: return "Xixu"
        case .ios: return "iOS"
        case .macos: return "macOS"
        case .linux: return "Linux"
        }
    }

    var detail: String {
        switch self {
        case .xixu: return L("The original Xixu look, with your accent color.")
        case .ios: return L("Clean, familiar, and matched to your iPhone.")
        case .macos: return L("A light Finder-inspired workspace.")
        case .linux: return L("Dark, focused, and warm orange.")
        }
    }
}

enum Prefs {
    private static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "showHidden": true,
            "foldersFirst": true,
            "sortKey": SortKey.name.rawValue,
            "sortAscending": true,
            "resolveContainers": true,
            "thumbnails": true,
            "showDetails": false,
            "useTrash": true,
            "accent": 0,
            "themeStyle": ThemeStyle.xixu.rawValue,
            "editorFontSize": 13.0,
        ])
    }

    private static func set(_ value: Any?, _ key: String) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: .prefsChanged, object: nil)
    }

    static var showHidden: Bool { get { d.bool(forKey: "showHidden") } set { set(newValue, "showHidden") } }
    static var foldersFirst: Bool { get { d.bool(forKey: "foldersFirst") } set { set(newValue, "foldersFirst") } }
    static var resolveContainers: Bool { get { d.bool(forKey: "resolveContainers") } set { set(newValue, "resolveContainers") } }
    static var thumbnails: Bool { get { d.bool(forKey: "thumbnails") } set { set(newValue, "thumbnails") } }
    static var showDetails: Bool { get { d.bool(forKey: "showDetails") } set { set(newValue, "showDetails") } }
    static var useTrash: Bool { get { d.bool(forKey: "useTrash") } set { set(newValue, "useTrash") } }
    static var accent: Int { get { d.integer(forKey: "accent") } set { set(newValue, "accent") } }
    static var themeStyle: ThemeStyle {
        get { ThemeStyle(rawValue: d.string(forKey: "themeStyle") ?? "") ?? .xixu }
        set { set(newValue.rawValue, "themeStyle") }
    }
    static var editorFontSize: CGFloat {
        get { CGFloat(d.double(forKey: "editorFontSize")) }
        set { d.set(Double(newValue), forKey: "editorFontSize") }
    }
    static var sortKey: SortKey {
        get { SortKey(rawValue: d.string(forKey: "sortKey") ?? "") ?? .name }
        set { set(newValue.rawValue, "sortKey") }
    }
    static var sortAscending: Bool { get { d.bool(forKey: "sortAscending") } set { set(newValue, "sortAscending") } }
}

/// Favorites and recently opened files.
enum Bookmarks {
    private static let d = UserDefaults.standard

    static var favorites: [String] {
        get { d.stringArray(forKey: "favorites") ?? [] }
        set {
            d.set(newValue, forKey: "favorites")
            NotificationCenter.default.post(name: .bookmarksChanged, object: nil)
        }
    }

    static var recents: [String] {
        get { d.stringArray(forKey: "recents") ?? [] }
        set {
            d.set(Array(newValue.prefix(12)), forKey: "recents")
            NotificationCenter.default.post(name: .bookmarksChanged, object: nil)
        }
    }

    static func isFavorite(_ path: String) -> Bool { favorites.contains(path) }

    static func toggleFavorite(_ path: String) {
        if isFavorite(path) { favorites.removeAll { $0 == path } } else { favorites.append(path) }
    }

    static func addRecent(_ path: String) {
        var list = recents
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        recents = list
    }
}

// MARK: - Look

enum Theme {
    static let accents: [(name: String, color: UIColor)] = [
        (L("Blue"), .systemBlue), (L("Indigo"), .systemIndigo), (L("Teal"), .systemTeal),
        (L("Green"), .systemGreen), (L("Orange"), .systemOrange), (L("Pink"), .systemPink),
        (L("Graphite"), .systemGray),
    ]

    static var accent: UIColor {
        switch Prefs.themeStyle {
        case .xixu:
            let i = Prefs.accent
            return accents.indices.contains(i) ? accents[i].color : .systemBlue
        case .ios: return .systemBlue
        case .macos: return UIColor(red: 0.04, green: 0.43, blue: 0.91, alpha: 1)
        case .linux: return UIColor(red: 0.91, green: 0.33, blue: 0.13, alpha: 1)
        }
    }

    static var interfaceStyle: UIUserInterfaceStyle {
        switch Prefs.themeStyle {
        case .macos: return .light
        case .linux: return .dark
        case .xixu, .ios: return .unspecified
        }
    }

    static var chromeColor: UIColor? {
        switch Prefs.themeStyle {
        case .macos: return UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        case .linux: return UIColor(red: 0.14, green: 0.13, blue: 0.17, alpha: 1)
        case .xixu, .ios: return nil
        }
    }

    static func apply(to window: UIWindow) {
        window.overrideUserInterfaceStyle = interfaceStyle
        window.tintColor = accent
    }

    static func apply(to navigation: UINavigationController) {
        let appearance = UINavigationBarAppearance()
        if let color = chromeColor {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = color
        } else {
            appearance.configureWithDefaultBackground()
        }
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.compactAppearance = appearance
        navigation.navigationBar.tintColor = accent
    }

    static func apply(to tabBar: UITabBar) {
        let appearance = UITabBarAppearance()
        if let color = chromeColor {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = color
        } else {
            appearance.configureWithDefaultBackground()
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = accent
    }

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func symbol(_ name: String, _ size: CGFloat = 17, _ weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
            ?? UIImage(systemName: "doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func exactBytes(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return LF("%@ bytes", f.string(from: NSNumber(value: n)) ?? "\(n)")
    }

    static let relative: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()

    static func date(_ t: Double) -> String {
        t > 0 ? relative.string(from: Date(timeIntervalSince1970: t)) : "–"
    }

    static func fullDate(_ t: Double) -> String {
        t > 0 ? full.string(from: Date(timeIntervalSince1970: t)) : "–"
    }

    static func permissions(_ mode: UInt16, kind: Entry.Kind) -> String {
        var s = ""
        switch kind {
        case .directory: s = "d"
        case .symlink: s = "l"
        case .other: s = "-"
        case .file: s = "-"
        }
        let bits: [(UInt16, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"),
                                           (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        for (i, (bit, c)) in bits.enumerated() {
            var ch: Character = mode & bit != 0 ? c : "-"
            if i == 2 && mode & 0o4000 != 0 { ch = mode & bit != 0 ? "s" : "S" }
            if i == 5 && mode & 0o2000 != 0 { ch = mode & bit != 0 ? "s" : "S" }
            if i == 8 && mode & 0o1000 != 0 { ch = mode & bit != 0 ? "t" : "T" }
            s.append(ch)
        }
        return s
    }

    static func octal(_ mode: UInt16) -> String {
        String(format: "%04o", Int(mode & 0o7777))
    }
}

// MARK: - Files

enum FileKind {
    case folder, app, package, text, code, plist, image, video, audio, pdf, document
    case archive, deb, ipa, sqlite, binary, dylib, font, other, special

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .app: return "app"
        case .package: return "cube"
        case .text: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .plist: return "list.bullet.indent"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc"
        case .archive: return "doc.zipper"
        case .deb: return "shippingbox"
        case .ipa: return "arrow.down.app"
        case .sqlite: return "cylinder.split.1x2"
        case .binary: return "terminal"
        case .dylib: return "puzzlepiece"
        case .font: return "textformat"
        case .other: return "doc"
        case .special: return "questionmark.square.dashed"
        }
    }

    var name: String {
        switch self {
        case .folder: return L("Folder")
        case .app: return L("Application")
        case .package: return L("Bundle")
        case .text: return L("Text")
        case .code: return L("Source Code")
        case .plist: return L("Property List")
        case .image: return L("Image")
        case .video: return L("Video")
        case .audio: return L("Audio")
        case .pdf: return L("PDF Document")
        case .document: return L("Document")
        case .archive: return L("Archive")
        case .deb: return L("Debian Package")
        case .ipa: return L("iOS App Package")
        case .sqlite: return L("SQLite Database")
        case .binary: return L("Executable")
        case .dylib: return L("Dynamic Library")
        case .font: return L("Font")
        case .other: return L("File")
        case .special: return L("Special File")
        }
    }

    /// Quick Look can show it.
    var isPreviewable: Bool {
        switch self {
        case .image, .video, .audio, .pdf, .document, .font: return true
        default: return false
        }
    }

    static func of(name: String, isDirectory: Bool, entryKind: Entry.Kind, mode: UInt16) -> FileKind {
        let ext = Paths.split(name).ext.lowercased()
        if isDirectory {
            switch ext {
            case "app": return .app
            case "framework", "bundle", "appex", "xpc", "lproj", "car": return .package
            default: return .folder
            }
        }
        if entryKind == .other { return .special }
        switch ext {
        case "txt", "md", "markdown", "log", "csv", "tsv", "conf", "cfg", "ini", "yml", "yaml", "toml", "list",
             "sources", "gitignore", "env", "properties", "out", "err", "rst", "nfo":
            return .text
        case "sh", "bash", "zsh", "py", "js", "mjs", "ts", "json", "c", "h", "m", "mm", "cpp", "hpp", "cc", "swift",
             "x", "xm", "xi", "java", "kt", "rb", "pl", "php", "lua", "go", "rs", "css", "html", "htm", "xml",
             "sql", "mk", "s", "asm", "diff", "patch", "svg", "js.map", "jsonl", "tbd", "modulemap", "pch":
            return .code
        case "plist", "entitlements", "strings", "stringsdict", "xcent", "loctable":
            return .plist
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "ico", "icns", "dng":
            return .image
        case "mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm":
            return .video
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "opus", "m4r", "amr":
            return .audio
        case "pdf":
            return .pdf
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "rtfd", "usdz", "reality":
            return .document
        case "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "lzma", "zst", "cpio",
             "iso", "xar", "lz4", "z", "pkg", "cab", "lha", "lzh", "xixubackup":
            return .archive
        case "deb":
            return .deb
        case "ipa", "tipa":
            return .ipa
        case "db", "sqlite", "sqlite3", "sqlitedb", "storedata", "sqlite-wal":
            return .sqlite
        case "dylib":
            return .dylib
        case "ttf", "otf", "ttc":
            return .font
        default:
            if ext.isEmpty && entryKind == .file && mode & 0o111 != 0 { return .binary }
            return .other
        }
    }
}

struct FileItem: Hashable {
    let path: String
    let entry: Entry
    let kind: FileKind
    let isDirectory: Bool

    init(path: String, entry: Entry) {
        self.path = path
        self.entry = entry
        isDirectory = entry.kind == .directory || (entry.kind == .symlink && entry.linkDir == true)
        kind = FileKind.of(name: entry.name, isDirectory: isDirectory, entryKind: entry.kind, mode: entry.mode)
    }

    init(dir: String, entry: Entry) {
        self.init(path: Paths.join(dir, entry.name), entry: entry)
    }

    var name: String { entry.name }
    var isSymlink: Bool { entry.kind == .symlink }
    var isHidden: Bool { entry.name.hasPrefix(".") }
    var parent: String { Paths.parent(path) }

    /// App name for container folders, otherwise the file name.
    var displayName: String {
        if let id = entry.label, entry.kind == .directory {
            return AppRegistry.shared.name(for: id) ?? id
        }
        return entry.name
    }

    var containerID: String? { entry.kind == .directory ? entry.label : nil }

    static func == (a: FileItem, b: FileItem) -> Bool { a.path == b.path && a.entry == b.entry }
    func hash(into h: inout Hasher) { h.combine(path) }
}

// MARK: - Clipboard

final class Clipboard {
    static let shared = Clipboard()

    private(set) var paths: [String] = []
    private(set) var isCut = false
    private(set) var sourceName = ""

    var isEmpty: Bool { paths.isEmpty }

    func set(_ paths: [String], cut: Bool) {
        self.paths = paths
        isCut = cut
        sourceName = paths.first.map { Paths.name(Paths.parent($0)) } ?? ""
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    func clear() {
        paths = []
        isCut = false
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }
}

// MARK: - Small UI helpers

enum Haptics {
    static func tap() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

extension UIViewController {
    func showError(_ error: Error, title: String? = nil) {
        if let e = error as? XixuError, e.isCancelled { return }
        Haptics.error()
        let alert = UIAlertController(title: title ?? L("Something Went Wrong"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("OK"), style: .cancel))
        topPresenter.present(alert, animated: true)
    }

    var topPresenter: UIViewController {
        var vc: UIViewController = self
        while let next = vc.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    /// Single text field prompt. `select` preselects the file name without its extension.
    func prompt(title: String, message: String? = nil, text: String = "", placeholder: String = "",
                action: String, selectBaseName: Bool = false, keyboard: UIKeyboardType = .default,
                completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.placeholder = placeholder
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.keyboardType = keyboard
            field.clearButtonMode = .whileEditing
            if selectBaseName && !text.isEmpty {
                let baseLength = Paths.split(text).base.utf16.count
                var token: NSObjectProtocol?
                token = NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification, object: field, queue: .main) { [weak field] _ in
                    if let t = token { NotificationCenter.default.removeObserver(t) }
                    token = nil
                    guard let field = field else { return }
                    if let start = field.position(from: field.beginningOfDocument, offset: 0),
                       let end = field.position(from: field.beginningOfDocument, offset: baseLength) {
                        field.selectedTextRange = field.textRange(from: start, to: end)
                    }
                }
            }
        }
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        let ok = UIAlertAction(title: action, style: .default) { [weak alert] _ in
            let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { completion(value) }
        }
        alert.addAction(ok)
        alert.preferredAction = ok
        topPresenter.present(alert, animated: true)
    }

    func confirm(title: String, message: String?, action: String, destructive: Bool = true,
                 source: Any? = nil, completion: @escaping () -> Void) {
        let style: UIAlertController.Style = source == nil ? .alert : .actionSheet
        let alert = UIAlertController(title: title, message: message, preferredStyle: style)
        alert.addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in completion() })
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        if let pop = alert.popoverPresentationController {
            if let item = source as? UIBarButtonItem { pop.barButtonItem = item }
            else if let view = source as? UIView { pop.sourceView = view; pop.sourceRect = view.bounds }
            else { pop.sourceView = view; pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0) }
        }
        topPresenter.present(alert, animated: true)
    }

    func presentModal(_ vc: UIViewController, fullScreen: Bool = false) {
        let nav = vc as? UINavigationController ?? UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = fullScreen ? .fullScreen : .pageSheet
        topPresenter.present(nav, animated: true)
    }
}

/// Two-line navigation title: name on top, a detail line below.
final class TitleView: UIView {
    let title = UILabel()
    let subtitle = UILabel()

    init(title: String, subtitle: String?) {
        super.init(frame: .zero)
        self.title.text = title
        self.title.font = .systemFont(ofSize: 16, weight: .semibold)
        self.title.textAlignment = .center
        self.title.lineBreakMode = .byTruncatingMiddle
        self.subtitle.text = subtitle
        self.subtitle.font = Theme.digits(11)
        self.subtitle.textColor = .secondaryLabel
        self.subtitle.textAlignment = .center
        self.subtitle.lineBreakMode = .byTruncatingHead
        let stack = UIStackView(arrangedSubviews: [self.title, self.subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Centered message for empty folders, errors and loading.
final class EmptyStateView: UIView {
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(title: String?, message: String? = nil, loading: Bool = false, symbol: String? = nil) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        messageLabel.text = message
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        var views: [UIView] = loading ? [spinner] : [titleLabel, messageLabel]
        if let symbol = symbol, !loading {
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .light)))
            icon.tintColor = .tertiaryLabel
            views.insert(icon, at: 0)
        }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 6
        if symbol != nil && !loading { stack.setCustomSpacing(14, after: views[0]) }
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
        if loading { spinner.startAnimating() }
    }

    required init?(coder: NSCoder) { fatalError() }
}
