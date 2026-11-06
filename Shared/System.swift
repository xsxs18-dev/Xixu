import Foundation
import Darwin

/// Jailbreak root detection. Works for rootless (/var/jb) and roothide
/// (random .jbroot-XXXX folder): the root is derived from where our own
/// executable lives, so nothing depends on a fixed path.
enum JB {
    static let helperSuffix = "/usr/libexec/xixuhelper"
    static let appSuffix = "/Applications/Xixu.app"

    static let root: String = {
        if let exe = Bundle.main.executablePath, let real = Engine.realPath(exe) {
            if real.hasSuffix(helperSuffix) {
                return String(real.dropLast(helperSuffix.count))
            }
            let bundle = Paths.parent(real)
            if bundle.hasSuffix(appSuffix) {
                return String(bundle.dropLast(appSuffix.count))
            }
        }
        if let jb = Engine.realPath("/var/jb") { return jb }
        return ""
    }()

    static var scheme: String {
        if root.contains("/.jbroot-") { return "roothide" }
        return root.isEmpty ? "rootful" : "rootless"
    }

    /// Path a user would recognise: "/var/jb" on rootless, the real folder on roothide.
    static var displayRoot: String {
        if scheme == "rootless", Engine.realPath("/var/jb") == root { return "/var/jb" }
        return root
    }

    static func path(_ p: String) -> String { root + p }
}

/// Runs bootstrap tools as the current user and captures their output.
enum Tools {
    static func find(_ name: String) -> String? {
        for dir in ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin"] {
            let p = JB.path(dir + "/" + name)
            if access(p, X_OK) == 0 { return p }
        }
        return nil
    }

    static func run(_ argv: [String], ctx: OpContext? = nil) -> (status: Int32, output: String) {
        guard let exe = argv.first, access(exe, X_OK) == 0 else {
            return (-1, "\(argv.first ?? "?"): not found")
        }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return (-1, String(cString: strerror(errno))) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])

        let binDirs = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"]
        let path = (binDirs.map { JB.path($0) } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        let env = ["PATH=\(path)", "LANG=C", "LC_ALL=C", "HOME=/var/root", "DEBIAN_FRONTEND=noninteractive", "TERM=dumb"]

        let cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer {
            cargv.forEach { free($0) }
            cenv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, nil, cargv, cenv)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            return (-1, String(cString: strerror(rc)))
        }

        // Keep draining the pipe, but bound memory and the JSON reply size.
        var output = Data()
        let outputLimit = 1 << 20
        let size = 16384
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            let n = read(fds[0], buffer, size)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            output.append(buffer.assumingMemoryBound(to: UInt8.self), count: n)
            if output.count > outputLimit { output.removeFirst(output.count - outputLimit) }
            if let text = String(data: output.suffix(400), encoding: .utf8)?
                .split(separator: "\n").last {
                ctx?.progress(0, String(text))
            }
        }
        close(fds[0])

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        return (code, String(decoding: output, as: UTF8.self))
    }

    static func pids(named name: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        var out: [pid_t] = []
        var buf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(n)) where pid > 0 {
            buf.withUnsafeMutableBytes { _ = proc_name(pid, $0.baseAddress, 256) }
            if String(cString: buf) == name { out.append(pid) }
        }
        return out
    }

    static func respring() -> String {
        if let sbreload = find("sbreload") {
            let r = run([sbreload])
            if r.status == 0 { return "" }
        }
        let pids = pids(named: "SpringBoard")
        for pid in pids { kill(pid, SIGKILL) }
        return pids.isEmpty ? "SpringBoard not found" : ""
    }

    static func uicache() -> (Int32, String) {
        guard let tool = find("uicache") else { return (-1, "uicache is not installed") }
        return run([tool, "-a"])
    }

    /// Installs a .deb with apt (resolves dependencies) and falls back to dpkg.
    static func install(_ path: String, ctx: OpContext) -> (Int32, String) {
        if let apt = find("apt-get") ?? find("apt") {
            let r = run([apt, "install", "-y", "--allow-downgrades", "--allow-unauthenticated",
                         "-o", "Dpkg::Options::=--force-confdef", path], ctx: ctx)
            if r.status == 0 { return r }
            if let dpkg = find("dpkg") {
                let d = run([dpkg, "-i", path], ctx: ctx)
                return (d.status, r.output + "\n" + d.output)
            }
            return r
        }
        guard let dpkg = find("dpkg") else { return (-1, "dpkg is not installed") }
        return run([dpkg, "-i", path], ctx: ctx)
    }

    /// Control fields and file list of a .deb.
    static func debInfo(_ path: String) -> (fields: String, files: [String], error: String?) {
        guard let tool = find("dpkg-deb") else { return ("", [], "dpkg-deb is not installed") }
        let fields = run([tool, "-f", path])
        if fields.status != 0 { return ("", [], fields.output) }
        let files = run([tool, "-c", path])
        let lines = files.output.split(separator: "\n").map(String.init)
        return (fields.output, lines, nil)
    }
}
