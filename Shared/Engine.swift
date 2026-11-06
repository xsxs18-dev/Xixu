import Foundation
import Darwin
import CommonCrypto

/// All file system work. Runs as root inside xixuhelper, or as mobile
/// inside the app when the helper is unavailable.
enum Engine {
    static var isRoot: Bool { geteuid() == 0 }
    static let mobileID: UInt32 = 501
    static let trashRoot = "/var/mobile/Library/Xixu/Trash"

    // MARK: - Basics

    static func seconds(_ ts: timespec) -> Double {
        Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    static func kind(of mode: mode_t) -> Entry.Kind {
        switch mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    static func makeEntry(_ name: String, _ st: stat) -> Entry {
        Entry(name: name, kind: kind(of: st.st_mode), size: Int64(st.st_size),
              mtime: seconds(st.st_mtimespec), mode: UInt16(st.st_mode), uid: st.st_uid, gid: st.st_gid)
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func readLink(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buf, Int(PATH_MAX))
        guard n >= 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    static func readLinkAt(_ fd: Int32, _ name: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlinkat(fd, name, &buf, Int(PATH_MAX))
        guard n >= 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    static func direntName(_ ent: UnsafeMutablePointer<dirent>) -> String {
        var raw = ent.pointee.d_name
        let length = Int(ent.pointee.d_namlen)
        return withUnsafeBytes(of: &raw) { buf in
            let bytes = UnsafeRawBufferPointer(rebasing: buf.prefix(length))
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static func names(_ dir: String) throws -> [String] {
        guard let d = opendir(dir) else { throw FSError.posix(errno, dir) }
        defer { closedir(d) }
        var out: [String] = []
        while let ent = readdir(d) {
            let name = direntName(ent)
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    static func looksLikeUUID(_ name: String) -> Bool {
        let u = Array(name.utf8)
        guard u.count == 36 else { return false }
        for (i, c) in u.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if c != UInt8(ascii: "-") { return false }
            } else if !((c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)) {
                return false
            }
        }
        return true
    }

    static func containerIdentifier(_ dir: String) -> String? {
        let meta = Paths.join(dir, ".com.apple.mobile_container_manager.metadata.plist")
        guard let dict = NSDictionary(contentsOfFile: meta) else { return nil }
        return dict["MCMMetadataIdentifier"] as? String
    }

    private static let nameLock = NSLock()
    private static var userNames: [UInt32: String] = [:]
    private static var groupNames: [UInt32: String] = [:]

    static func userName(_ uid: uid_t) -> String? {
        nameLock.lock(); defer { nameLock.unlock() }
        if let cached = userNames[uid] { return cached }
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return nil }
        let s = String(cString: name)
        userNames[uid] = s
        return s
    }

    static func groupName(_ gid: gid_t) -> String? {
        nameLock.lock(); defer { nameLock.unlock() }
        if let cached = groupNames[gid] { return cached }
        guard let gr = getgrgid(gid), let name = gr.pointee.gr_name else { return nil }
        let s = String(cString: name)
        groupNames[gid] = s
        return s
    }

    /// New items belong to whoever owns the folder they were created in.
    static func inheritOwner(_ path: String) {
        guard isRoot else { return }
        var parent = stat()
        guard stat(Paths.parent(path), &parent) == 0 else { return }
        lchown(path, parent.st_uid, parent.st_gid)
    }

    static func inheritOwnerRecursive(_ path: String) {
        guard isRoot else { return }
        var parent = stat()
        guard stat(Paths.parent(path), &parent) == 0 else { return }
        try? walk(path, ctx: nil) { p, _ in lchown(p, parent.st_uid, parent.st_gid) }
    }

    /// Depth-first walk that does not follow symlinks. The root is visited first.
    static func walk(_ root: String, ctx: OpContext?, _ visit: (String, stat) throws -> Void) throws {
        var stack = [root]
        while let path = stack.popLast() {
            try ctx?.check()
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            try visit(path, st)
            if (st.st_mode & S_IFMT) == S_IFDIR, let children = try? names(path) {
                for name in children { stack.append(Paths.join(path, name)) }
            }
        }
    }

    static func measure(_ path: String) -> Int64 {
        var total: Int64 = 0
        try? walk(path, ctx: nil) { _, st in
            if (st.st_mode & S_IFMT) == S_IFREG { total += Int64(st.st_size) }
        }
        return total
    }

    static func uniqueName(in dir: String, for name: String) -> String {
        let parts = Paths.split(name)
        var base = parts.base
        var n = 2
        if let space = base.lastIndex(of: " "), let num = Int(base[base.index(after: space)...]), num >= 2 {
            base = String(base[..<space])
            n = num + 1
        }
        while true {
            let candidate = parts.ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(parts.ext)"
            let path = Paths.join(dir, candidate)
            if !exists(path) { return path }
            n += 1
        }
    }

    static func validateName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.utf8.count > 255 {
            throw FSError.message("Invalid name", subject: name)
        }
    }


    // MARK: - Protection

    /// Folders whose loss bricks the device or the jailbreak. They (and anything
    /// that contains them) can't be deleted, moved, renamed or replaced.
    /// Everything inside them stays editable.
    static let protectedPaths: Set<String> = {
        var set: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/bin", "/sbin", "/usr", "/etc", "/dev",
            "/private", "/private/etc", "/private/var", "/private/preboot", "/private/var/jb",
            "/private/var/mobile", "/private/var/root", "/private/var/db", "/private/var/preferences",
            "/private/var/Keychains", "/private/var/containers", "/private/var/containers/Bundle",
            "/private/var/containers/Bundle/Application", "/private/var/mobile/Containers",
            "/private/var/mobile/Containers/Data", "/private/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Shared", "/private/var/mobile/Containers/Shared/AppGroup",
            "/private/var/mobile/Library", "/private/var/mobile/Library/Preferences",
            "/private/var/mobile/Media", "/var", "/tmp",
        ]
        let jb = JB.root
        if !jb.isEmpty {
            let root = realPath(jb) ?? jb
            set.insert(root)
            for sub in ["/usr", "/usr/bin", "/usr/lib", "/usr/libexec", "/bin", "/etc", "/var", "/Library",
                        "/Applications", "/Library/MobileSubstrate", "/Library/MobileSubstrate/DynamicLibraries"] {
                set.insert(root + sub)
            }
        }
        set.insert("/private/var/mobile/Library/Xixu")
        set.insert("/private/var/mobile/Library/Xixu/Trash")
        return set
    }()

    /// Canonical spelling that keeps a final symlink itself (so "/var/jb" stays the link).
    static func canonical(_ path: String) -> String {
        let name = Paths.name(path)
        if name == "/" { return "/" }
        let parent = realPath(Paths.parent(path)) ?? Paths.parent(path)
        if name == "." || name == ".." { return realPath(path) ?? path }
        return Paths.join(parent, name)
    }

    static func guardRemoval(_ path: String) throws {
        let canon = canonical(path)
        if protectedPaths.contains(where: { Paths.isInside($0, canon) }) {
            throw FSError(code: EPERM, message: "Protected system folder", subject: Paths.name(path))
        }
    }

    // MARK: - Listing

    static func list(_ path: String, containers: Bool) throws -> [Entry] {
        guard let dir = opendir(path) else { throw FSError.posix(errno, path) }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var result: [Entry] = []
        result.reserveCapacity(64)
        while let ent = readdir(dir) {
            let name = direntName(ent)
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                result.append(Entry(name: name, kind: .other, size: 0, mtime: 0, mode: 0, uid: 0, gid: 0))
                continue
            }
            var e = makeEntry(name, st)
            if e.kind == .symlink {
                e.link = readLinkAt(fd, name)
                var target = stat()
                if fstatat(fd, name, &target, 0) == 0 {
                    e.linkDir = (target.st_mode & S_IFMT) == S_IFDIR
                }
            } else if containers && e.kind == .directory && looksLikeUUID(name) {
                e.label = containerIdentifier(Paths.join(path, name))
            }
            result.append(e)
        }
        return result
    }

    static func statInfo(_ path: String) throws -> StatInfo {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw FSError.posix(errno, path) }
        var e = makeEntry(Paths.name(path), st)
        if e.kind == .symlink {
            e.link = readLink(path)
            var target = stat()
            if stat(path, &target) == 0 { e.linkDir = (target.st_mode & S_IFMT) == S_IFDIR }
        } else if e.kind == .directory && looksLikeUUID(e.name) {
            e.label = containerIdentifier(path)
        }
        return StatInfo(entry: e,
                        atime: seconds(st.st_atimespec),
                        ctime: seconds(st.st_ctimespec),
                        btime: seconds(st.st_birthtimespec),
                        inode: st.st_ino,
                        links: Int(st.st_nlink),
                        device: st.st_dev,
                        flags: st.st_flags,
                        blocks: Int64(st.st_blocks),
                        owner: userName(st.st_uid),
                        group: groupName(st.st_gid),
                        realPath: realPath(path))
    }

    // MARK: - Creating

    static func makeDirectory(_ path: String) throws -> String {
        try validateName(Paths.name(path))
        guard mkdir(path, 0o755) == 0 else { throw FSError.posix(errno, path) }
        inheritOwner(path)
        return path
    }

    static func makeDirectories(_ path: String) throws {
        if isDirectory(path) { return }
        try makeDirectories(Paths.parent(path))
        if mkdir(path, 0o755) != 0 && errno != EEXIST { throw FSError.posix(errno, path) }
        inheritOwner(path)
    }

    static func createFile(_ path: String, contents: Data?) throws -> String {
        try validateName(Paths.name(path))
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw FSError.posix(errno, path) }
        defer { close(fd) }
        if let contents = contents, !contents.isEmpty {
            try contents.withUnsafeBytes { raw in
                try writeAll(fd, raw.baseAddress!, raw.count, path: path)
            }
        }
        inheritOwner(path)
        return path
    }

    static func makeSymlink(at path: String, target: String) throws -> String {
        try validateName(Paths.name(path))
        guard !target.isEmpty else { throw FSError.message("Invalid link target") }
        guard symlink(target, path) == 0 else { throw FSError.posix(errno, path) }
        inheritOwner(path)
        return path
    }

    static func renameItem(_ path: String, to newName: String) throws -> String {
        try validateName(newName)
        try guardRemoval(path)
        let dst = Paths.join(Paths.parent(path), newName)
        if dst == path { return dst }
        if exists(dst) && dst.lowercased() != path.lowercased() {
            throw FSError(code: EEXIST, message: String(cString: strerror(EEXIST)), subject: newName)
        }
        guard rename(path, dst) == 0 else { throw FSError.posix(errno, path) }
        return dst
    }

    // MARK: - Copy / move

    enum Conflict: String {
        case keepBoth = "keepboth"
        case replace
        case skip
    }

    final class Tally {
        var total: Int64 = 0
        var done: Int64 = 0
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// op: "copy", "move" or "link" (create symlinks to the sources).
    static func transfer(_ op: String, sources: [String], into dir: String, conflict: Conflict, ctx: OpContext) throws -> [String] {
        guard isDirectory(dir) else { throw FSError.posix(ENOTDIR, dir) }
        let tally = Tally()
        if op == "copy" {
            for src in sources { tally.total += measure(src) }
        }
        var results: [String] = []
        for src in sources {
            try ctx.check()
            let name = Paths.name(src)
            var dst = Paths.join(dir, name)
            if exists(dst) {
                if dst == src {
                    if op == "move" { results.append(dst); continue }
                    dst = uniqueName(in: dir, for: name)
                } else {
                    switch conflict {
                    case .skip:
                        continue
                    case .keepBoth:
                        dst = uniqueName(in: dir, for: name)
                    case .replace:
                        if Paths.isInside(src, dst) {
                            throw FSError.message("An item can't replace the folder it is in", subject: name)
                        }
                        try guardRemoval(dst)
                        try removeTree(dst, ctx: nil)
                    }
                }
            }
            if op != "link" && Paths.isInside(dst, src) {
                throw FSError.message("A folder can't be placed inside itself", subject: name)
            }
            switch op {
            case "link":
                guard symlink(src, dst) == 0 else { throw FSError.posix(errno, dst) }
                inheritOwner(dst)
            case "move":
                try moveItem(src, to: dst, ctx: ctx, tally: tally)
            default:
                do {
                    try copyItem(src, to: dst, ctx: ctx, tally: tally)
                } catch {
                    try? removeTree(dst, ctx: nil)
                    throw error
                }
            }
            results.append(dst)
        }
        ctx.progress(1, force: true)
        return results
    }

    static func duplicate(_ paths: [String], ctx: OpContext) throws -> [String] {
        let tally = Tally()
        for p in paths { tally.total += measure(p) }
        var out: [String] = []
        for src in paths {
            let dst = uniqueName(in: Paths.parent(src), for: Paths.name(src))
            do {
                try copyItem(src, to: dst, ctx: ctx, tally: tally)
            } catch {
                try? removeTree(dst, ctx: nil)
                throw error
            }
            out.append(dst)
        }
        return out
    }

    static func moveItem(_ src: String, to dst: String, ctx: OpContext, tally: Tally) throws {
        try guardRemoval(src)
        if rename(src, dst) == 0 { return }
        let err = errno
        guard err == EXDEV else { throw FSError.posix(err, src) }
        tally.total += measure(src)
        do {
            try copyItem(src, to: dst, ctx: ctx, tally: tally)
        } catch {
            try? removeTree(dst, ctx: nil)
            throw error
        }
        try removeTree(src, ctx: nil)
    }

    static func copyItem(_ src: String, to dst: String, ctx: OpContext, tally: Tally) throws {
        try ctx.check()
        var st = stat()
        guard lstat(src, &st) == 0 else { throw FSError.posix(errno, src) }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            guard let target = readLink(src) else { throw FSError.posix(errno, src) }
            guard symlink(target, dst) == 0 else { throw FSError.posix(errno, dst) }
            if isRoot { lchown(dst, st.st_uid, st.st_gid) }
        case S_IFDIR:
            guard mkdir(dst, 0o700) == 0 else { throw FSError.posix(errno, dst) }
            for name in try names(src) {
                try copyItem(Paths.join(src, name), to: Paths.join(dst, name), ctx: ctx, tally: tally)
            }
            if isRoot { chown(dst, st.st_uid, st.st_gid) }
            chmod(dst, st.st_mode & 0o7777)
            var times = [st.st_atimespec, st.st_mtimespec]
            utimensat(AT_FDCWD, dst, &times, 0)
        case S_IFREG:
            try copyFile(src, to: dst, st: st, ctx: ctx, tally: tally)
        default:
            throw FSError.message("Unsupported file type", subject: Paths.name(src))
        }
    }

    static func copyFile(_ src: String, to dst: String, st: stat, ctx: OpContext, tally: Tally) throws {
        // APFS clone: instant and uses no extra space when on the same volume.
        if clonefile(src, dst, 0) == 0 {
            // Cloning drops setuid/setgid; put the original mode back.
            chmod(dst, st.st_mode & 0o7777)
            tally.done += Int64(st.st_size)
            ctx.progress(tally.fraction)
            return
        }
        let input = open(src, O_RDONLY)
        guard input >= 0 else { throw FSError.posix(errno, src) }
        defer { close(input) }
        let output = open(dst, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw FSError.posix(errno, dst) }
        var finished = false
        defer {
            close(output)
            if !finished { unlink(dst) }
        }
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            try ctx.check()
            let n = Darwin.read(input, buffer, size)
            if n < 0 {
                if errno == EINTR { continue }
                throw FSError.posix(errno, src)
            }
            if n == 0 { break }
            try writeAll(output, buffer, n, path: dst)
            tally.done += Int64(n)
            ctx.progress(tally.fraction)
        }
        _ = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
        if isRoot { fchown(output, st.st_uid, st.st_gid) }
        fchmod(output, st.st_mode & 0o7777)
        var times = [st.st_atimespec, st.st_mtimespec]
        futimens(output, &times)
        if st.st_flags != 0 { fchflags(output, st.st_flags) }
        finished = true
    }

    static func writeAll(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int, path: String) throws {
        var off = 0
        while off < count {
            let w = Darwin.write(fd, buf + off, count - off)
            if w < 0 {
                if errno == EINTR { continue }
                throw FSError.posix(errno, path)
            }
            off += w
        }
    }

    // MARK: - Delete / trash

    static func removeTree(_ path: String, ctx: OpContext?) throws {
        let locked = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        var pending: [(path: String, removeDirectory: Bool)] = [(path, false)]
        while let item = pending.popLast() {
            try ctx?.check()
            if item.removeDirectory {
                guard rmdir(item.path) == 0 else { throw FSError.posix(errno, item.path) }
                continue
            }
            var st = stat()
            guard lstat(item.path, &st) == 0 else {
                if errno == ENOENT { continue }
                throw FSError.posix(errno, item.path)
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if st.st_flags & locked != 0 { chflags(item.path, 0) }
                let children = try names(item.path)
                pending.append((item.path, true))
                for name in children { pending.append((Paths.join(item.path, name), false)) }
            } else {
                if st.st_flags & locked != 0 { lchflags(item.path, 0) }
                guard unlink(item.path) == 0 else { throw FSError.posix(errno, item.path) }
            }
        }
    }

    static func delete(_ paths: [String], ctx: OpContext) throws {
        for p in paths { try guardRemoval(p) }
        for (i, p) in paths.enumerated() {
            try removeTree(p, ctx: ctx)
            ctx.progress(Double(i + 1) / Double(paths.count))
        }
    }

    static func ensureTrash() throws {
        for dir in [Paths.parent(trashRoot), trashRoot] {
            if mkdir(dir, 0o755) != 0 && errno != EEXIST { throw FSError.posix(errno, dir) }
            if isRoot { chown(dir, mobileID, mobileID) }
        }
    }

    /// Moves an item into the trash and returns its slot directory.
    static func trash(_ path: String) throws -> String {
        try guardRemoval(path)
        try ensureTrash()
        var item = stat(), bin = stat()
        guard lstat(path, &item) == 0 else { throw FSError.posix(errno, path) }
        guard stat(trashRoot, &bin) == 0 else { throw FSError.posix(errno, trashRoot) }
        let realItem = realPath(path) ?? path
        let realTrash = realPath(trashRoot) ?? trashRoot
        if Paths.isInside(realTrash, realItem) {
            throw FSError.message("This folder contains the Trash", subject: Paths.name(path))
        }
        guard item.st_dev == bin.st_dev else {
            throw FSError(code: EXDEV, message: "The Trash is on another volume", subject: Paths.name(path))
        }
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let slot = Paths.join(trashRoot, "\(stamp)-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))")
        guard mkdir(slot, 0o755) == 0 else { throw FSError.posix(errno, slot) }
        if isRoot { chown(slot, mobileID, mobileID) }
        let origin = Paths.join(slot, ".origin")
        _ = try? createFile(origin, contents: Data(path.utf8))
        guard rename(path, Paths.join(slot, Paths.name(path))) == 0 else {
            let err = errno
            try? removeTree(slot, ctx: nil)
            throw FSError.posix(err, path)
        }
        return slot
    }

    static func trashList() -> [Entry] {
        guard let slots = try? names(trashRoot) else { return [] }
        var out: [Entry] = []
        for slot in slots {
            let dir = Paths.join(trashRoot, slot)
            guard let items = try? names(dir), let item = items.first(where: { $0 != ".origin" }) else {
                try? removeTree(dir, ctx: nil)
                continue
            }
            var st = stat()
            let path = Paths.join(dir, item)
            guard lstat(path, &st) == 0 else { continue }
            var e = makeEntry(item, st)
            e.label = try? String(contentsOfFile: Paths.join(dir, ".origin"), encoding: .utf8)
            e.dir = dir
            if let ms = Double(slot.split(separator: "-").first ?? "") { e.mtime = ms / 1000 }
            if e.kind == .symlink {
                e.link = readLink(path)
                e.linkDir = isDirectory(path)
            }
            out.append(e)
        }
        return out
    }

    static func restore(_ slot: String) throws -> String {
        guard Paths.isInside(slot, trashRoot), slot != trashRoot else {
            throw FSError.message("Not an item in the Trash", subject: Paths.name(slot))
        }
        let origin = try String(contentsOfFile: Paths.join(slot, ".origin"), encoding: .utf8)
        guard let item = try names(slot).first(where: { $0 != ".origin" }) else {
            throw FSError.posix(ENOENT, slot)
        }
        let parent = Paths.parent(origin)
        try makeDirectories(parent)
        var dst = origin
        if exists(dst) { dst = uniqueName(in: parent, for: Paths.name(origin)) }
        guard rename(Paths.join(slot, item), dst) == 0 else { throw FSError.posix(errno, dst) }
        try? removeTree(slot, ctx: nil)
        return dst
    }

    static func emptyTrash(ctx: OpContext) throws {
        guard let slots = try? names(trashRoot) else { return }
        for (i, slot) in slots.enumerated() {
            try removeTree(Paths.join(trashRoot, slot), ctx: ctx)
            ctx.progress(Double(i + 1) / Double(slots.count))
        }
    }

    // MARK: - Attributes

    static func changeMode(_ paths: [String], mode: mode_t, recursive: Bool, ctx: OpContext) throws {
        if recursive { for p in paths { try guardRemoval(p) } }
        for p in paths {
            if recursive {
                try walk(p, ctx: ctx) { path, st in
                    if (st.st_mode & S_IFMT) == S_IFLNK { return }
                    if chmod(path, mode) != 0 { throw FSError.posix(errno, path) }
                }
            } else if chmod(p, mode) != 0 {
                throw FSError.posix(errno, p)
            }
        }
    }

    static func changeOwner(_ paths: [String], uid: uid_t, gid: gid_t, recursive: Bool, ctx: OpContext) throws {
        if recursive { for p in paths { try guardRemoval(p) } }
        for p in paths {
            if recursive {
                try walk(p, ctx: ctx) { path, _ in
                    if lchown(path, uid, gid) != 0 { throw FSError.posix(errno, path) }
                }
            } else if lchown(p, uid, gid) != 0 {
                throw FSError.posix(errno, p)
            }
        }
    }

    // MARK: - Contents

    static let maxRead = 64 << 20

    static func read(_ path: String, offset: Int64, length: Int?) throws -> Data {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FSError.posix(errno, path) }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        var len: Int
        if let l = length, l > 0 {
            len = l
            if (st.st_mode & S_IFMT) == S_IFREG {
                len = Int(max(0, min(Int64(l), Int64(st.st_size) - offset)))
            }
        } else {
            len = Int(max(0, Int64(st.st_size) - offset))
        }
        if len > maxRead { throw FSError.message("File is too large", code: EFBIG, subject: Paths.name(path)) }
        guard len > 0 else { return Data() }
        var data = Data(count: len)
        var total = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < len {
                let n = pread(fd, base + total, len - total, offset + Int64(total))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FSError.posix(errno, path)
                }
                if n == 0 { break }
                total += n
            }
        }
        data.count = total
        return data
    }

    /// Atomic save that keeps the original owner and permissions.
    static func write(_ path: String, data: Data) throws {
        var target = path
        var st = stat()
        var existed = false
        if lstat(path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK, let real = realPath(path) {
                target = real
                existed = stat(target, &st) == 0
            } else {
                existed = true
            }
            if existed && (st.st_mode & S_IFMT) != S_IFREG {
                throw FSError.message("Not a regular file", subject: Paths.name(path))
            }
        }
        let tmp = Paths.join(Paths.parent(target), ".\(Paths.name(target)).xixu-\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            let err = errno
            if existed { try writeInPlace(target, data: data); return }
            throw FSError.posix(err, target)
        }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(tmp) }
        }
        try data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 {
                try writeAll(fd, base, raw.count, path: target)
            }
        }
        if existed {
            let original = open(target, O_RDONLY)
            if original >= 0 {
                _ = fcopyfile(original, fd, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
                close(original)
            }
            if isRoot { fchown(fd, st.st_uid, st.st_gid) }
            fchmod(fd, st.st_mode & 0o7777)
        }
        fsync(fd)
        guard rename(tmp, target) == 0 else { throw FSError.posix(errno, target) }
        ok = true
        if !existed { inheritOwner(target) }
    }

    static func writeInPlace(_ path: String, data: Data) throws {
        let fd = open(path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { throw FSError.posix(errno, path) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 {
                try writeAll(fd, base, raw.count, path: path)
            }
        }
    }

    static func patch(_ path: String, offset: Int64, data: Data) throws {
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { throw FSError.posix(errno, path) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, base + done, raw.count - done, offset + Int64(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FSError.posix(errno, path)
                }
                done += n
            }
        }
    }

    /// [logical bytes, allocated bytes, files, folders]
    static func usage(_ paths: [String], ctx: OpContext) throws -> [Int64] {
        var bytes: Int64 = 0, allocated: Int64 = 0, files: Int64 = 0, dirs: Int64 = 0
        var seen = Set<UInt64>()
        for p in paths {
            try walk(p, ctx: ctx) { _, st in
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    dirs += 1
                case S_IFREG:
                    files += 1
                    if st.st_nlink > 1 {
                        if seen.contains(st.st_ino) { return }
                        seen.insert(st.st_ino)
                    }
                    bytes += Int64(st.st_size)
                    allocated += Int64(st.st_blocks) * 512
                default:
                    files += 1
                }
                if (files + dirs) % 2000 == 0 {
                    ctx.progress(0, "\(files + dirs)")
                }
            }
        }
        return [bytes, allocated, files, dirs]
    }

    /// [md5, sha1, sha256] in lowercase hex.
    static func hashes(_ path: String, ctx: OpContext) throws -> [String] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FSError.posix(errno, path) }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        let total = max(Int64(st.st_size), 1)
        var md5 = CC_MD5_CTX(), sha1 = CC_SHA1_CTX(), sha256 = CC_SHA256_CTX()
        CC_MD5_Init(&md5)
        CC_SHA1_Init(&sha1)
        CC_SHA256_Init(&sha256)
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var done: Int64 = 0
        while true {
            try ctx.check()
            let n = Darwin.read(fd, buffer, size)
            if n < 0 {
                if errno == EINTR { continue }
                throw FSError.posix(errno, path)
            }
            if n == 0 { break }
            CC_MD5_Update(&md5, buffer, CC_LONG(n))
            CC_SHA1_Update(&sha1, buffer, CC_LONG(n))
            CC_SHA256_Update(&sha256, buffer, CC_LONG(n))
            done += Int64(n)
            ctx.progress(Double(done) / Double(total))
        }
        var d1 = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        var d2 = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        var d3 = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_MD5_Final(&d1, &md5)
        CC_SHA1_Final(&d2, &sha1)
        CC_SHA256_Final(&d3, &sha256)
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        return [hex(d1), hex(d2), hex(d3)]
    }

    // MARK: - Search

    static func search(root: String, query: String, mode: String, hidden: Bool, limit: Int, ctx: OpContext) throws -> Int {
        let matcher: (String) -> Bool
        switch mode {
        case "regex":
            guard let re = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
                throw FSError.message("Invalid regular expression")
            }
            matcher = { name in
                re.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)) != nil
            }
        case "glob":
            matcher = { fnmatch(query, $0, FNM_CASEFOLD) == 0 }
        default:
            matcher = { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }

        let skipped: Set<String> = ["/dev", "/private/var/vm"]
        var queue = [root]
        var head = 0
        var batch: [Entry] = []
        var found = 0
        var lastEmit = CFAbsoluteTimeGetCurrent()

        func scan(_ dir: String) -> Bool {
            guard let d = opendir(dir) else { return true }
            defer { closedir(d) }
            let fd = dirfd(d)
            while let ent = readdir(d) {
                let name = direntName(ent)
                if name == "." || name == ".." { continue }
                if !hidden && name.hasPrefix(".") { continue }
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if matcher(name) {
                    var e = makeEntry(name, st)
                    e.dir = dir
                    if e.kind == .symlink {
                        e.link = readLinkAt(fd, name)
                        var target = stat()
                        if fstatat(fd, name, &target, 0) == 0 { e.linkDir = (target.st_mode & S_IFMT) == S_IFDIR }
                    }
                    batch.append(e)
                    found += 1
                    if found >= limit { return false }
                }
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    let child = Paths.join(dir, name)
                    if !skipped.contains(child) { queue.append(child) }
                }
            }
            return true
        }

        while head < queue.count {
            if ctx.isCancelled { break }
            let dir = queue[head]
            head += 1
            if head >= 8192 {
                queue.removeFirst(head)
                head = 0
            }
            let more = scan(dir)
            let now = CFAbsoluteTimeGetCurrent()
            if !batch.isEmpty && (batch.count >= 200 || now - lastEmit > 0.2) {
                ctx.emit(batch)
                batch.removeAll(keepingCapacity: true)
                lastEmit = now
            }
            if !more { break }
        }
        if !batch.isEmpty { ctx.emit(batch) }
        return found
    }

    // MARK: - Staging (hand a private copy to the app)

    static func stage(_ paths: [String], into dir: String, ctx: OpContext) throws -> [String] {
        try makeDirectories(dir)
        if isRoot { chown(dir, mobileID, mobileID) }
        let tally = Tally()
        var out: [String] = []
        for src in paths {
            let dst = Paths.join(dir, Paths.name(src))
            try? removeTree(dst, ctx: nil)
            var st = stat()
            if stat(src, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG {
                try copyFile(src, to: dst, st: st, ctx: ctx, tally: tally)
            } else {
                try copyItem(src, to: dst, ctx: ctx, tally: tally)
            }
            if isRoot {
                try? walk(dst, ctx: nil) { p, st in
                    lchown(p, mobileID, mobileID)
                    if (st.st_mode & S_IFMT) != S_IFLNK { chmod(p, (st.st_mode & 0o7777) | 0o600) }
                }
            }
            out.append(dst)
        }
        return out
    }
}
