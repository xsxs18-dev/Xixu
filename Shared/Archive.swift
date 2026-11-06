import Foundation
import Darwin

/// Archive support on top of the system libarchive: zip, tar (gz/bz2/xz),
/// 7z, rar, cpio, ar, iso, xar … for reading, zip for writing.
enum Archive {
    private static let formatRaw: Int32 = 0x90000

    private static func message(_ a: OpaquePointer?) -> String {
        if let a = a, let s = archive_error_string(a) { return String(cString: s) }
        return "Archive error"
    }

    static func baseName(_ name: String) -> String {
        let lower = name.lowercased()
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma", ".tar.lz4"] where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        let parts = Paths.split(name)
        return parts.ext.isEmpty ? name + " Contents" : parts.base
    }

    /// Strips absolute prefixes and any "." / ".." components.
    static func sanitize(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." && $0 != ".." && !$0.isEmpty }.joined(separator: "/")
    }

    // MARK: - Listing

    static func list(_ path: String, limit: Int = 100_000) throws -> [Entry] {
        guard let a = archive_read_new() else { throw FSError.message("libarchive unavailable") }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_filename(a, path, 1 << 16) == LA_OK else {
            throw FSError.message(message(a), subject: Paths.name(path))
        }
        var out: [Entry] = []
        var entry: OpaquePointer?
        while out.count < limit {
            let r = archive_read_next_header(a, &entry)
            if r == LA_EOF { break }
            if r < LA_WARN { throw FSError.message(message(a), subject: Paths.name(path)) }
            guard let entry = entry, let raw = archive_entry_pathname(entry) else { continue }
            let type = archive_entry_filetype(entry)
            let kind: Entry.Kind
            switch type & S_IFMT {
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symlink
            case S_IFREG: kind = .file
            default: kind = .other
            }
            out.append(Entry(name: String(cString: raw), kind: kind, size: archive_entry_size(entry),
                             mtime: Double(archive_entry_mtime(entry)), mode: UInt16(type), uid: 0, gid: 0))
            archive_read_data_skip(a)
        }
        return out
    }

    // MARK: - Extract

    /// Extracts next to the archive. A single top-level item lands directly in
    /// `dir`; several go into a folder named after the archive.
    /// Unpacks everything into an existing folder as-is (used for restores).
    static func unpack(_ path: String, into dir: String, ctx: OpContext) throws {
        _ = try extract(path, into: dir, ctx: ctx, lift: false)
    }

    static func extract(_ path: String, into dir: String, ctx: OpContext) throws -> String {
        try extract(path, into: dir, ctx: ctx, lift: true)
    }

    private static func extract(_ path: String, into dir: String, ctx: OpContext, lift: Bool) throws -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { throw FSError.posix(errno, path) }
        let total = max(Double(st.st_size), 1)
        let base = baseName(Paths.name(path))

        let staging = Paths.join(dir, ".xixu-extract-\(UInt32.random(in: 0...UInt32.max))")
        guard mkdir(staging, 0o755) == 0 else { throw FSError.posix(errno, dir) }
        var keepStaging = false
        defer { if !keepStaging { try? Engine.removeTree(staging, ctx: nil) } }

        guard let a = archive_read_new() else { throw FSError.message("libarchive unavailable") }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        archive_read_support_format_raw(a)
        guard archive_read_open_filename(a, path, 1 << 16) == LA_OK else {
            throw FSError.message(message(a), subject: Paths.name(path))
        }
        guard let w = archive_write_disk_new() else { throw FSError.message("libarchive unavailable") }
        defer { archive_write_free(w) }
        archive_write_disk_set_options(w, LA_EXTRACT_PERM | LA_EXTRACT_TIME | LA_EXTRACT_SECURE_SYMLINKS
                                          | LA_EXTRACT_SECURE_NODOTDOT | LA_EXTRACT_SECURE_NOABSOLUTEPATHS)
        archive_write_disk_set_standard_lookup(w)

        var entry: OpaquePointer?
        var count = 0
        while true {
            try ctx.check()
            let r = archive_read_next_header(a, &entry)
            if r == LA_EOF { break }
            if r < LA_WARN { throw FSError.message(message(a), subject: Paths.name(path)) }
            guard let entry = entry else { continue }
            var name = archive_entry_pathname(entry).map { sanitize(String(cString: $0)) } ?? ""
            if archive_format(a) == formatRaw {
                name = Paths.split(Paths.name(path)).base
            }
            if name.isEmpty {
                archive_read_data_skip(a)
                continue
            }
            archive_entry_copy_pathname(entry, Paths.join(staging, name))
            if let hard = archive_entry_hardlink(entry) {
                archive_entry_copy_hardlink(entry, Paths.join(staging, sanitize(String(cString: hard))))
            }
            if archive_write_header(w, entry) < LA_WARN {
                throw FSError.message(message(w), subject: name)
            }
            var block: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            while true {
                let rr = archive_read_data_block(a, &block, &size, &offset)
                if rr == LA_EOF { break }
                if rr < LA_WARN { throw FSError.message(message(a), subject: name) }
                if archive_write_data_block(w, block, size, offset) < Int(LA_WARN) {
                    throw FSError.message(message(w), subject: name)
                }
                ctx.progress(Double(archive_filter_bytes(a, -1)) / total)
                try ctx.check()
            }
            archive_write_finish_entry(w)
            count += 1
        }
        archive_write_close(w)
        guard count > 0 else { throw FSError.message("The archive is empty", subject: Paths.name(path)) }

        Engine.inheritOwnerRecursive(staging)
        chmod(staging, 0o755)

        if !lift {
            // Move everything from the staging folder straight into `dir`.
            for name in (try? Engine.names(staging)) ?? [] {
                let target = Paths.join(dir, name)
                try? Engine.removeTree(target, ctx: nil)
                guard rename(Paths.join(staging, name), target) == 0 else { throw FSError.posix(errno, target) }
            }
            return dir
        }

        let items = (try? Engine.names(staging)) ?? []
        if items.count == 1 {
            let only = Paths.join(staging, items[0])
            var target = Paths.join(dir, items[0])
            if Engine.exists(target) { target = Engine.uniqueName(in: dir, for: items[0]) }
            if rename(only, target) == 0 { return target }
        }
        var target = Paths.join(dir, base)
        if Engine.exists(target) { target = Engine.uniqueName(in: dir, for: base) }
        guard rename(staging, target) == 0 else { throw FSError.posix(errno, target) }
        keepStaging = true
        return target
    }

    // MARK: - Compress

    static func compress(_ paths: [String], names: [String]? = nil, to zipPath: String, ctx: OpContext) throws -> String {
        let total = max(paths.reduce(Int64(0)) { $0 + Engine.measure($1) }, 1)
        guard let a = archive_write_new() else { throw FSError.message("libarchive unavailable") }
        defer { archive_write_free(a) }
        archive_write_set_format_zip(a)
        guard archive_write_open_filename(a, zipPath) == LA_OK else {
            throw FSError.message(message(a), subject: Paths.name(zipPath))
        }
        var success = false
        defer { if !success { unlink(zipPath) } }

        let size = 1 << 18
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var done: Int64 = 0

        func add(_ path: String, _ rel: String) throws {
            try ctx.check()
            if path == zipPath { return }
            var st = stat()
            guard lstat(path, &st) == 0, let e = archive_entry_new() else { return }
            defer { archive_entry_free(e) }
            archive_entry_copy_stat(e, &st)
            archive_entry_copy_pathname(e, rel)
            let type = st.st_mode & S_IFMT
            if type == S_IFLNK {
                archive_entry_copy_symlink(e, Engine.readLink(path) ?? "")
                archive_entry_set_size(e, 0)
            } else if type == S_IFDIR {
                archive_entry_set_size(e, 0)
            } else if type != S_IFREG {
                return
            }
            guard archive_write_header(a, e) >= LA_WARN else {
                throw FSError.message(message(a), subject: Paths.name(path))
            }
            if type == S_IFREG {
                let fd = open(path, O_RDONLY)
                guard fd >= 0 else { throw FSError.posix(errno, path) }
                defer { close(fd) }
                while true {
                    try ctx.check()
                    let n = read(fd, buffer, size)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw FSError.posix(errno, path)
                    }
                    if n == 0 { break }
                    if archive_write_data(a, buffer, n) < 0 {
                        throw FSError.message(message(a), subject: Paths.name(path))
                    }
                    done += Int64(n)
                    ctx.progress(Double(done) / Double(total))
                }
            }
            if type == S_IFDIR {
                for name in try Engine.names(path).sorted() {
                    try add(Paths.join(path, name), rel + "/" + name)
                }
            }
        }

        for (i, p) in paths.enumerated() {
            let name = names.flatMap { i < $0.count ? $0[i] : nil } ?? Paths.name(p)
            try add(p, name)
        }
        guard archive_write_close(a) == LA_OK else {
            throw FSError.message(message(a), subject: Paths.name(zipPath))
        }
        success = true
        Engine.inheritOwner(zipPath)
        return zipPath
    }
}
