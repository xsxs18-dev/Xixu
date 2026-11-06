import Foundation
import Darwin

/// Maps one request to the engine. Used by xixuhelper and by the in-app
/// fallback, so both behave identically.
enum Dispatcher {
    static func handle(_ r: Request, ctx: OpContext) throws -> Response {
        var out = Response(id: r.id)

        func path() throws -> String {
            guard let p = r.path, !p.isEmpty else { throw FSError.message("Missing path") }
            return p
        }
        func paths() throws -> [String] {
            guard let p = r.paths, !p.isEmpty else { throw FSError.message("Missing paths") }
            return p
        }
        func dest() throws -> String {
            guard let d = r.dest, !d.isEmpty else { throw FSError.message("Missing destination") }
            return d
        }

        switch r.op {
        case "ping":
            out.text = "uid=\(getuid()) euid=\(geteuid()) root=\(JB.root) scheme=\(JB.scheme)"

        case "list":
            out.entries = try Engine.list(try path(), containers: r.has("containers"))

        case "stat":
            out.stat = try Engine.statInfo(try path())

        case "exists":
            out.numbers = try paths().map { Engine.exists($0) ? 1 : 0 }

        case "mkdir":
            out.text = try Engine.makeDirectory(try path())

        case "touch":
            out.text = try Engine.createFile(try path(), contents: r.data)

        case "symlink":
            out.text = try Engine.makeSymlink(at: try path(), target: r.text ?? "")

        case "rename":
            out.text = try Engine.renameItem(try path(), to: r.text ?? "")

        case "copy", "move", "link":
            let conflict = Engine.Conflict(rawValue: r.text ?? "") ?? .keepBoth
            out.strings = try Engine.transfer(r.op, sources: try paths(), into: try dest(), conflict: conflict, ctx: ctx)

        case "duplicate":
            out.strings = try Engine.duplicate(try paths(), ctx: ctx)

        case "delete":
            try Engine.delete(try paths(), ctx: ctx)

        case "trash":
            out.strings = try paths().map { try Engine.trash($0) }

        case "trashList":
            out.entries = Engine.trashList()

        case "restore":
            out.strings = try paths().map { try Engine.restore($0) }

        case "emptyTrash":
            try Engine.emptyTrash(ctx: ctx)

        case "chmod":
            guard let mode = r.mode else { throw FSError.message("Missing mode") }
            try Engine.changeMode(try paths(), mode: mode_t(mode & 0o7777), recursive: r.has("recursive"), ctx: ctx)

        case "chown":
            let uid = r.uid.map { uid_t($0) } ?? uid_t.max
            let gid = r.gid.map { gid_t($0) } ?? gid_t.max
            try Engine.changeOwner(try paths(), uid: uid, gid: gid, recursive: r.has("recursive"), ctx: ctx)

        case "read":
            out.data = try Engine.read(try path(), offset: r.offset ?? 0, length: r.length)

        case "write":
            try Engine.write(try path(), data: r.data ?? Data())

        case "patch":
            try Engine.patch(try path(), offset: r.offset ?? 0, data: r.data ?? Data())

        case "usage":
            out.numbers = try Engine.usage(try paths(), ctx: ctx)

        case "hash":
            out.strings = try Engine.hashes(try path(), ctx: ctx)

        case "search":
            let found = try Engine.search(root: try path(), query: r.text ?? "",
                                          mode: r.has("regex") ? "regex" : (r.has("glob") ? "glob" : "contains"),
                                          hidden: r.has("hidden"), limit: r.length ?? 5000, ctx: ctx)
            out.numbers = [Int64(found)]

        case "stage":
            out.strings = try Engine.stage(try paths(), into: try dest(), ctx: ctx)

        case "extract":
            let archive = try path()
            out.text = try Archive.extract(archive, into: r.dest ?? Paths.parent(archive), ctx: ctx)

        case "compress":
            out.text = try Archive.compress(try paths(), names: r.names, to: try dest(), ctx: ctx)

        case "archiveList":
            out.entries = try Archive.list(try path())

        case "debInfo":
            let info = Tools.debInfo(try path())
            if let error = info.error { throw FSError.message(error.trimmingCharacters(in: .whitespacesAndNewlines)) }
            out.text = info.fields
            out.strings = info.files

        case "install":
            let result = Tools.install(try path(), ctx: ctx)
            out.text = result.1
            out.numbers = [Int64(result.0)]

        case "uicache":
            let result = Tools.uicache()
            out.text = result.1
            out.numbers = [Int64(result.0)]

        case "respring":
            out.text = Tools.respring()

        case "mkdirs":
            let dir = try path()
            try Engine.makeDirectories(dir)
            out.text = dir

        case "append":
            try Engine.append(try path(), data: r.data ?? Data())

        case "cleanScan":
            let list = r.flags ?? Cleaner.categories
            out.strings = list
            out.numbers = try Cleaner.scan(list, ctx: ctx)

        case "clean":
            out.numbers = try Cleaner.clean(r.flags ?? [], ctx: ctx)

        case "installIPA":
            let result = try AppTools.installIPA(try path(), ctx: ctx)
            out.strings = [result.method]
            out.numbers = [Int64(result.status)]
            out.text = result.output

        case "renameApp":
            out.text = try AppTools.rename(try path(), to: r.text ?? "")

        case "refreshApp":
            let result = AppTools.refresh(try path())
            out.numbers = [Int64(result.0)]
            out.text = result.1

        case "restoreApp":
            try AppTools.restore(try path(), data: try dest(), groups: r.paths ?? [], groupIDs: r.names ?? [],
                                 executable: r.text ?? "", ctx: ctx)

        default:
            throw FSError.message("Unknown operation \(r.op)")
        }
        return out
    }

    static func failure(_ id: Int, _ error: Error) -> Response {
        if let e = error as? FSError {
            return Response(id: id, error: e.message, code: e.code, subject: e.subject)
        }
        return Response(id: id, error: error.localizedDescription, code: EIO)
    }
}
