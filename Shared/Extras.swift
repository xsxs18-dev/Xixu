import Foundation
import Darwin

// Cleaner, app installation, app backups and app renaming. Runs as root in
// xixuhelper (and, with the usual limits, inside the app as a fallback).

// MARK: - Cleaner

enum Cleaner {
    static let categories = ["app_caches", "app_temp", "safari", "temp", "crash_logs", "logs", "packages", "shared_caches"]

    private enum Mode { case contents, files }

    private struct Target {
        var path: String
        var mode: Mode
        var minAge: TimeInterval = 0
        var filter: ((String) -> Bool)?
        var skipDirs: Set<String> = []
    }

    private static let hour: TimeInterval = 3600

    /// bundle identifier -> data container path
    static func appContainers() -> [String: String] {
        let root = "/var/mobile/Containers/Data/Application"
        var map: [String: String] = [:]
        for name in (try? Engine.names(root)) ?? [] where Engine.looksLikeUUID(name) {
            let dir = Paths.join(root, name)
            if let id = Engine.containerIdentifier(dir) { map[id] = dir }
        }
        return map
    }

    private static func targets(_ category: String, containers: [String: String]) -> [Target] {
        switch category {
        case "app_caches":
            return containers.filter { $0.key != "com.apple.mobilesafari" }
                .map { Target(path: Paths.join($0.value, "Library/Caches"), mode: .contents) }
        case "app_temp":
            return containers.map { Target(path: Paths.join($0.value, "tmp"), mode: .contents, minAge: hour) }
        case "safari":
            var list = ["com.apple.mobilesafari", "com.apple.WebKit.Networking", "com.apple.WebKit.WebContent"]
                .map { Target(path: "/var/mobile/Library/Caches/" + $0, mode: .contents) }
            if let safari = containers["com.apple.mobilesafari"] {
                list.append(Target(path: Paths.join(safari, "Library/Caches"), mode: .contents))
            }
            return list
        case "temp":
            return ["/var/tmp", "/var/mobile/tmp", JB.path("/tmp"), JB.path("/var/tmp")]
                .filter { !$0.isEmpty }
                .map { Target(path: $0, mode: .contents, minAge: 24 * hour) }
        case "crash_logs":
            return ["/var/mobile/Library/Logs/CrashReporter", "/var/mobile/Library/Logs/DiagnosticReports"]
                .map { Target(path: $0, mode: .files) }
        case "logs":
            var list = [Target(path: "/var/mobile/Library/Logs", mode: .files, minAge: hour,
                               skipDirs: ["CrashReporter", "DiagnosticReports"])]
            if !JB.root.isEmpty { list.append(Target(path: JB.path("/var/log"), mode: .files, minAge: hour)) }
            return list
        case "packages":
            guard !JB.root.isEmpty else { return [] }
            let archives = JB.path("/var/cache/apt/archives")
            var list = [
                Target(path: archives, mode: .contents, filter: { $0.hasSuffix(".deb") }),
                Target(path: Paths.join(archives, "partial"), mode: .contents),
                Target(path: JB.path("/var/cache/apt"), mode: .contents, filter: { $0.hasSuffix(".bin") }),
            ]
            for app in ["org.coolstar.SileoStore", "xyz.willy.Zebra", "com.saurik.Cydia", "com.tigisoftware.Filza"] {
                list.append(Target(path: "/var/mobile/Library/Caches/" + app, mode: .contents))
                list.append(Target(path: JB.path("/var/mobile/Library/Caches/" + app), mode: .contents))
            }
            return list
        case "shared_caches":
            let owned: Set<String> = ["org.coolstar.SileoStore", "xyz.willy.Zebra", "com.saurik.Cydia",
                                      "com.tigisoftware.Filza", "com.xsxs18.xixu", "com.xsxs18.voidy"]
            let filter: (String) -> Bool = { name in
                if owned.contains(name) { return false }
                if name == "GeoServices" || name == "com.apple.parsecd" { return true }
                return name.split(separator: ".").count >= 3 && !name.hasPrefix("com.apple.")
            }
            var list = [Target(path: "/var/mobile/Library/Caches", mode: .contents, filter: filter)]
            if !JB.root.isEmpty { list.append(Target(path: JB.path("/var/mobile/Library/Caches"), mode: .contents, filter: filter)) }
            return list
        default:
            return []
        }
    }

    /// Calls `visit` for every removable item of a category.
    private static func enumerate(_ category: String, containers: [String: String], ctx: OpContext,
                                  visit: (String, stat) throws -> Void) throws {
        var seen = Set<String>()
        let now = Date().timeIntervalSince1970
        for target in targets(category, containers: containers) {
            guard let root = Engine.realPath(target.path), Engine.isDirectory(root), seen.insert(root + "|\(target.mode)").inserted else { continue }
            switch target.mode {
            case .contents:
                for name in (try? Engine.names(root)) ?? [] {
                    try ctx.check()
                    if let filter = target.filter, !filter(name) { continue }
                    let path = Paths.join(root, name)
                    var st = stat()
                    guard lstat(path, &st) == 0, seen.insert(path).inserted else { continue }
                    if target.minAge > 0 && now - Engine.seconds(st.st_mtimespec) < target.minAge { continue }
                    try visit(path, st)
                }
            case .files:
                var stack = [root]
                while let dir = stack.popLast() {
                    try ctx.check()
                    for name in (try? Engine.names(dir)) ?? [] {
                        let path = Paths.join(dir, name)
                        var st = stat()
                        guard lstat(path, &st) == 0 else { continue }
                        if (st.st_mode & S_IFMT) == S_IFDIR {
                            if dir == root && target.skipDirs.contains(name) { continue }
                            stack.append(path)
                            continue
                        }
                        if let filter = target.filter, !filter(name) { continue }
                        if target.minAge > 0 && now - Engine.seconds(st.st_mtimespec) < target.minAge { continue }
                        guard seen.insert(path).inserted else { continue }
                        try visit(path, st)
                    }
                }
            }
        }
    }

    /// Per category: [bytes, items].
    static func scan(_ list: [String], ctx: OpContext) throws -> [Int64] {
        let containers = appContainers()
        var result: [Int64] = []
        for (i, category) in list.enumerated() {
            var bytes: Int64 = 0
            var items: Int64 = 0
            try enumerate(category, containers: containers, ctx: ctx) { path, st in
                items += 1
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    try Engine.walk(path, ctx: ctx) { _, child in
                        if (child.st_mode & S_IFMT) == S_IFREG { bytes += Int64(child.st_blocks) * 512 }
                    }
                } else {
                    bytes += Int64(st.st_blocks) * 512
                }
            }
            result += [bytes, items]
            ctx.progress(Double(i + 1) / Double(list.count), category)
        }
        return result
    }

    /// Returns [freed bytes, removed items].
    static func clean(_ list: [String], ctx: OpContext) throws -> [Int64] {
        let containers = appContainers()
        var freed: Int64 = 0
        var removed: Int64 = 0
        for (i, category) in list.enumerated() {
            try enumerate(category, containers: containers, ctx: ctx) { path, st in
                var size: Int64 = Int64(st.st_blocks) * 512
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    size = 0
                    try Engine.walk(path, ctx: ctx) { _, child in size += Int64(child.st_blocks) * 512 }
                }
                try ctx.check()
                if (try? Engine.removeTree(path, ctx: ctx)) != nil {
                    freed += size
                    removed += 1
                }
            }
            ctx.progress(Double(i + 1) / Double(list.count), category)
        }
        return [freed, removed]
    }
}

// MARK: - Apps

enum AppTools {
    /// Installs an .ipa with TrollStore (Lite) or appinst.
    static func installIPA(_ path: String, ctx: OpContext) throws -> (method: String, status: Int32, output: String) {
        guard ["ipa", "tipa"].contains((path as NSString).pathExtension.lowercased()) else {
            throw FSError.message("Not an IPA file", subject: Paths.name(path))
        }
        var file = stat()
        guard stat(path, &file) == 0 else { throw FSError.posix(errno, path) }
        guard (file.st_mode & S_IFMT) == S_IFREG else {
            throw FSError.message("Not a regular file", subject: Paths.name(path))
        }
        var trollstore: [String] = [JB.path("/Applications/TrollStoreLite.app/trollstorehelper")]
        let bundles = "/var/containers/Bundle/Application"
        for uuid in (try? Engine.names(bundles)) ?? [] {
            for app in ["TrollStore.app", "TrollStoreLite.app"] {
                trollstore.append(Paths.join(Paths.join(bundles, uuid), app + "/trollstorehelper"))
            }
        }
        if let helper = trollstore.first(where: { access($0, X_OK) == 0 }) {
            let result = Tools.run([helper, "install", path], ctx: ctx)
            return ("TrollStore", result.status, result.output)
        }
        if let appinst = Tools.find("appinst") {
            let result = Tools.run([appinst, path], ctx: ctx)
            return ("appinst", result.status, result.output)
        }
        throw FSError.message("No installer found", code: ENOENT)
    }

    static func kill(executable: String) {
        guard !executable.isEmpty else { return }
        for pid in Tools.pids(named: executable) { Darwin.kill(pid, SIGKILL) }
    }

    /// Refreshes LaunchServices for one app bundle.
    static func refresh(_ bundlePath: String) -> (Int32, String) {
        guard let tool = Tools.find("uicache") else { return (-1, "uicache is not installed") }
        return Tools.run([tool, "-p", bundlePath])
    }

    /// Sets the Home Screen name in Info.plist and every localized InfoPlist.strings.
    static func rename(_ bundlePath: String, to name: String) throws -> String {
        let infoPath = Paths.join(bundlePath, "Info.plist")
        try setDisplayName(name, in: infoPath, required: true)
        for entry in (try? Engine.names(bundlePath)) ?? [] where entry.hasSuffix(".lproj") {
            let strings = Paths.join(Paths.join(bundlePath, entry), "InfoPlist.strings")
            if Engine.exists(strings) { try? setDisplayName(name, in: strings, required: false) }
        }
        return refresh(bundlePath).1
    }

    private static func setDisplayName(_ name: String, in path: String, required: Bool) throws {
        let data = try Engine.read(path, offset: 0, length: nil)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var dict = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainers], format: &format) as? [String: Any] else {
            throw FSError.message("Not a property list", subject: Paths.name(path))
        }
        if !required && dict["CFBundleDisplayName"] == nil && dict["CFBundleName"] == nil { return }
        dict["CFBundleDisplayName"] = name
        let out = try PropertyListSerialization.data(fromPropertyList: dict, format: format == .xml ? .xml : .binary, options: 0)
        try Engine.write(path, data: out)
    }

    /// Replaces an app's data (and app group) containers with the contents of a backup.
    static func restore(_ archive: String, data dataPath: String, groups: [String], groupIDs: [String],
                        executable: String, ctx: OpContext) throws {
        kill(executable: executable)
        let work = "/var/mobile/Library/Xixu/Restore-\(UInt32.random(in: 0...UInt32.max))"
        try Engine.makeDirectories(work)
        defer { try? Engine.removeTree(work, ctx: nil) }
        try Archive.unpack(archive, into: work, ctx: ctx)

        let unpackedData = Paths.join(work, "Data")
        guard Engine.isDirectory(unpackedData) else { throw FSError.message("This isn't a Xixu backup", subject: Paths.name(archive)) }
        try replaceContents(of: dataPath, with: unpackedData)
        for (i, id) in groupIDs.enumerated() where i < groups.count {
            let source = Paths.join(Paths.join(work, "Groups"), id)
            if Engine.isDirectory(source) { try replaceContents(of: groups[i], with: source) }
        }
    }

    private static func replaceContents(of target: String, with source: String) throws {
        let keep = ".com.apple.mobile_container_manager.metadata.plist"
        for name in try Engine.names(target) where name != keep {
            try Engine.removeTree(Paths.join(target, name), ctx: nil)
        }
        for name in try Engine.names(source) where name != keep {
            let dst = Paths.join(target, name)
            guard Darwin.rename(Paths.join(source, name), dst) == 0 else { throw FSError.posix(errno, dst) }
            try? Engine.walk(dst, ctx: nil) { p, _ in lchown(p, Engine.mobileID, Engine.mobileID) }
        }
    }
}

// MARK: - Small file helpers

extension Engine {
    /// Appends to a file, creating it when needed (Wi-Fi uploads arrive in chunks).
    static func append(_ path: String, data: Data) throws {
        let existed = exists(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { throw FSError.posix(errno, path) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 { try writeAll(fd, base, raw.count, path: path) }
        }
        if !existed { inheritOwner(path) }
    }
}
