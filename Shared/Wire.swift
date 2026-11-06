import Foundation

// Messages exchanged between the app and xixuhelper. One JSON object per
// line in both directions. The same types are used when the app runs the
// engine in-process (no helper available).

struct Entry: Codable, Hashable {
    enum Kind: UInt8, Codable {
        case file = 0
        case directory = 1
        case symlink = 2
        case other = 3
    }

    var name: String
    var kind: Kind
    var size: Int64
    var mtime: Double
    var mode: UInt16
    var uid: UInt32
    var gid: UInt32
    /// Symlink target as stored in the link.
    var link: String?
    /// Symlink resolves to a directory (nil: dangling link).
    var linkDir: Bool?
    /// Bundle identifier of a container directory, or the original path of a trashed item.
    var label: String?
    /// Parent directory, set for search results and trash items.
    var dir: String?

    enum CodingKeys: String, CodingKey {
        case name = "n", kind = "k", size = "s", mtime = "t", mode = "m", uid = "u", gid = "g"
        case link = "l", linkDir = "ld", label = "b", dir = "d"
    }
}

struct StatInfo: Codable {
    var entry: Entry
    var atime: Double
    var ctime: Double
    var btime: Double
    var inode: UInt64
    var links: Int
    var device: Int32
    var flags: UInt32
    var blocks: Int64
    var owner: String?
    var group: String?
    var realPath: String?
}

struct Request: Codable {
    var id: Int = 0
    var op: String
    var path: String? = nil
    var paths: [String]? = nil
    var dest: String? = nil
    var text: String? = nil
    var data: Data? = nil
    var offset: Int64? = nil
    var length: Int? = nil
    var mode: Int? = nil
    var uid: Int? = nil
    var gid: Int? = nil
    var flags: [String]? = nil
    var target: Int? = nil
    /// Archive names for `paths` (compress) or ids for group containers (restore).
    var names: [String]? = nil

    func has(_ flag: String) -> Bool { flags?.contains(flag) ?? false }
}

struct Response: Codable {
    var id: Int
    /// false for progress updates and streamed search results.
    var done: Bool = true
    var error: String? = nil
    var code: Int32? = nil
    var subject: String? = nil
    var entries: [Entry]? = nil
    var stat: StatInfo? = nil
    var data: Data? = nil
    var text: String? = nil
    var strings: [String]? = nil
    var numbers: [Int64]? = nil
    var progress: Double? = nil
}

struct FSError: Error {
    var code: Int32
    var message: String
    var subject: String?

    static func posix(_ code: Int32, _ path: String) -> FSError {
        FSError(code: code, message: String(cString: strerror(code)), subject: Paths.name(path))
    }

    static func message(_ text: String, code: Int32 = EINVAL, subject: String? = nil) -> FSError {
        FSError(code: code, message: text, subject: subject)
    }

    static let cancelled = FSError(code: ECANCELED, message: "Cancelled", subject: nil)
}

/// Progress, cancellation and streaming for one running request.
final class OpContext {
    let id: Int
    private let sink: (Response) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var lastReport: CFAbsoluteTime = 0

    init(id: Int, sink: @escaping (Response) -> Void) {
        self.id = id
        self.sink = sink
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func check() throws {
        if isCancelled { throw FSError.cancelled }
    }

    func progress(_ fraction: Double, _ text: String? = nil, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force && now - lastReport < 0.08 { return }
        lastReport = now
        sink(Response(id: id, done: false, text: text, progress: min(max(fraction, 0), 1)))
    }

    func emit(_ entries: [Entry]) {
        sink(Response(id: id, done: false, entries: entries))
    }
}

enum Paths {
    static func join(_ dir: String, _ name: String) -> String {
        if dir.hasSuffix("/") { return dir + name }
        return dir + "/" + name
    }

    static func name(_ path: String) -> String {
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }

    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    /// "/a/b" is inside "/a" (or equal to it).
    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    /// "photo.jpg" -> ("photo", "jpg"); ".bashrc" -> (".bashrc", "").
    static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        if ext.isEmpty || ext.count > 12 || ext.contains(" ") { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    static func standardized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        if p.isEmpty { p = "/" }
        return p
    }
}
