import UIKit

/// Installed apps via LaunchServices (private API, looked up at runtime).
final class AppRegistry {
    static let shared = AppRegistry()

    struct App {
        let bundleID: String
        let name: String
        let version: String
        let isSystem: Bool
        let bundlePath: String?
        let dataPath: String?
        let groups: [(id: String, path: String)]
    }

    private let lock = NSLock()
    private var byID: [String: App] = [:]
    private var list: [App] = []
    private var loaded = false
    private let icons = NSCache<NSString, UIImage>()

    var apps: [App] {
        loadIfNeeded()
        lock.lock(); defer { lock.unlock() }
        return list
    }

    func app(_ bundleID: String) -> App? {
        loadIfNeeded()
        lock.lock(); defer { lock.unlock() }
        return byID[bundleID]
    }

    func name(for bundleID: String) -> String? {
        app(bundleID)?.name
    }

    /// Re-reads LaunchServices on a background queue (e.g. after an install).
    func reload() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let found = enumerate()
            store(found)
        }
    }

    /// Re-reads LaunchServices synchronously; call off the main thread.
    func reloadNow() {
        store(enumerate())
    }

    func loadIfNeeded() {
        lock.lock()
        if loaded { lock.unlock(); return }
        loaded = true
        lock.unlock()
        store(enumerate())
    }

    private func store(_ found: [App]) {
        var map: [String: App] = [:]
        for app in found { map[app.bundleID] = app }
        lock.lock()
        list = found
        byID = map
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .appsLoaded, object: nil) }
    }

    private func enumerate() -> [App] {
        var found: [App] = []
        for proxy in XXInstalledApplications() {
            let app = makeApp(proxy)
            if let app = app { found.append(app) }
        }
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return found
    }

    private func makeApp(_ proxy: NSObject) -> App? {
        guard let id = value(proxy, "applicationIdentifier") as? String ?? value(proxy, "bundleIdentifier") as? String else { return nil }
        let name = value(proxy, "localizedName") as? String ?? (id.split(separator: ".").last.map(String.init) ?? id)
        let version = value(proxy, "shortVersionString") as? String ?? value(proxy, "bundleVersion") as? String ?? ""
        let type = value(proxy, "applicationType") as? String ?? "User"
        let bundle = (value(proxy, "bundleURL") as? URL)?.path
        let data = (value(proxy, "dataContainerURL") as? URL)?.path
        var groups: [(String, String)] = []
        if let dict = value(proxy, "groupContainerURLs") as? [String: URL] {
            groups = dict.map { ($0.key, $0.value.path) }.sorted { $0.0 < $1.0 }
        }
        return App(bundleID: id, name: name, version: version, isSystem: type != "User",
                   bundlePath: bundle, dataPath: data.flatMap { $0.contains("/Containers/Data/") ? $0 : nil },
                   groups: groups)
    }

    private func value(_ object: NSObject, _ key: String) -> Any? {
        XXSafeValueForKey(object, key)
    }

    // MARK: - Icons

    /// Icon read from the app bundle with public API (no private UIKit calls).
    func icon(for bundleID: String, size: CGFloat = 60) -> UIImage? {
        guard let path = app(bundleID)?.bundlePath else { return nil }
        return Icons.app(bundlePath: path, size: size)
    }

    func open(_ bundleID: String) {
        _ = XXOpenApplication(bundleID)
    }
}
