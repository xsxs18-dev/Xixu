import Foundation
import Darwin

struct XixuError: LocalizedError {
    let code: Int32
    let message: String
    let subject: String?

    var errorDescription: String? {
        let reason: String
        switch code {
        case EPERM where message == "Protected system folder":
            reason = L("This is a protected system folder. Items inside it can still be changed.")
        case EACCES:
            reason = L("Permission denied.")
        case EPERM:
            reason = L("Operation not permitted.")
        case ENOENT:
            reason = L("The item no longer exists.")
        case EEXIST:
            reason = L("An item with this name already exists.")
        case ENOTEMPTY:
            reason = L("The folder is not empty.")
        case ENOSPC:
            reason = L("There is not enough free space.")
        case EROFS:
            reason = L("The volume is read-only.")
        case EXDEV:
            reason = L("The Trash is on another volume.")
        case ECANCELED:
            reason = L("Cancelled.")
        case EFBIG:
            reason = L("The file is too large.")
        case ENOTDIR:
            reason = L("Not a folder.")
        case EISDIR:
            reason = L("This is a folder.")
        default:
            reason = message
        }
        if let s = subject, !s.isEmpty, s != "/" { return "\(s): \(reason)" }
        return reason
    }

    var isCancelled: Bool { code == ECANCELED }
}

protocol Transport: AnyObject {
    var isAlive: Bool { get }
    func send(_ request: Request, handler: @escaping (Response) -> Void)
    func cancel(_ id: Int)
}

/// Talks to a running xixuhelper over its stdin/stdout.
final class HelperTransport: Transport {
    private let pid: pid_t
    private let input: Int32
    private let output: Int32
    private let lock = NSLock()
    private var handlers: [Int: (Response) -> Void] = [:]
    private var alive = true
    private let writer = DispatchQueue(label: "xixu.helper.writer", qos: .userInitiated)
    private let encoder = JSONEncoder()

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return alive
    }

    static func launch(path: String, asRoot: Bool) -> HelperTransport? {
        var toChild: [Int32] = [0, 0]
        var fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0 else { return nil }
        guard pipe(&fromChild) == 0 else {
            close(toChild[0]); close(toChild[1])
            return nil
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        for fd in toChild + fromChild { posix_spawn_file_actions_addclose(&actions, fd) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if asRoot {
            _ = posix_spawnattr_set_persona_np(&attr, 99, 1) // POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
            _ = posix_spawnattr_set_persona_uid_np(&attr, 0)
            _ = posix_spawnattr_set_persona_gid_np(&attr, 0)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        let environment: [String] = ["HOME=/var/mobile", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        close(toChild[0])
        close(fromChild[1])
        guard rc == 0 else {
            close(toChild[1])
            close(fromChild[0])
            return nil
        }
        _ = fcntl(toChild[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fromChild[0], F_SETFD, FD_CLOEXEC)
        return HelperTransport(pid: pid, input: toChild[1], output: fromChild[0])
    }

    private init(pid: pid_t, input: Int32, output: Int32) {
        self.pid = pid
        self.input = input
        self.output = output
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "xixu.helper.reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func send(_ request: Request, handler: @escaping (Response) -> Void) {
        lock.lock()
        guard alive else {
            lock.unlock()
            handler(Response(id: request.id, error: "The root helper stopped", code: EIO))
            return
        }
        handlers[request.id] = handler
        lock.unlock()
        write(request)
    }

    func cancel(_ id: Int) {
        write(Request(op: "cancel", target: id))
    }

    func terminate() {
        close(input)
        kill(pid, SIGTERM)
    }

    private func write(_ request: Request) {
        guard var data = try? encoder.encode(request) else { return }
        data.append(0x0A)
        let fd = input
        writer.async {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, base + off, raw.count - off)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    off += n
                }
            }
        }
    }

    private func readLoop() {
        let decoder = JSONDecoder()
        var buffer: [UInt8] = []
        var scanFrom = 0
        let size = 1 << 16
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { chunk.deallocate() }

        while true {
            let n = Darwin.read(output, chunk, size)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: UnsafeRawBufferPointer(start: chunk, count: n))
            while let newline = buffer[scanFrom...].firstIndex(of: 0x0A) {
                let line = Data(buffer[0..<newline])
                buffer.removeFirst(newline + 1)
                scanFrom = 0
                guard let response = try? decoder.decode(Response.self, from: line) else { continue }
                lock.lock()
                let handler = handlers[response.id]
                if response.done { handlers[response.id] = nil }
                lock.unlock()
                handler?(response)
            }
            scanFrom = buffer.count
        }

        lock.lock()
        alive = false
        let pending = handlers
        handlers.removeAll()
        lock.unlock()
        close(output)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        for (id, handler) in pending {
            handler(Response(id: id, error: "The root helper stopped", code: EIO))
        }
    }
}

/// Runs the engine inside the app (as mobile) when no helper is available.
final class LocalTransport: Transport {
    private let lock = NSLock()
    private var contexts: [Int: OpContext] = [:]
    let isAlive = true

    func send(_ request: Request, handler: @escaping (Response) -> Void) {
        let ctx = OpContext(id: request.id, sink: handler)
        lock.lock(); contexts[request.id] = ctx; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response: Response
            do {
                response = try Dispatcher.handle(request, ctx: ctx)
            } catch {
                response = Dispatcher.failure(request.id, error)
            }
            self?.lock.lock(); self?.contexts[request.id] = nil; self?.lock.unlock()
            handler(response)
        }
    }

    func cancel(_ id: Int) {
        lock.lock(); let ctx = contexts[id]; lock.unlock()
        ctx?.cancel()
    }
}

/// Entry point for every file system call the app makes.
final class FS {
    static let shared = FS()

    enum Access { case root, limited }

    private(set) var access: Access = .limited
    private(set) var helperPath: String?
    private var transport: Transport
    private let local = LocalTransport()
    private let lock = NSLock()
    private var counter = 0
    private var lastConnect: CFAbsoluteTime = 0
    private let connectLock = NSLock()

    private init() {
        transport = local
        helperPath = [JB.path(JB.helperSuffix), "/var/jb" + JB.helperSuffix]
            .first { Darwin.access($0, X_OK) == 0 }
        connect()
    }

    var isRoot: Bool { access == .root }

    func makeID() -> Int {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return counter
    }

    private func connect() {
        lastConnect = CFAbsoluteTimeGetCurrent()
        guard let path = helperPath else {
            transport = local
            access = .limited
            return
        }
        for asRoot in [true, false] {
            guard let helper = HelperTransport.launch(path: path, asRoot: asRoot) else { continue }
            let semaphore = DispatchSemaphore(value: 0)
            var reply: String?
            helper.send(Request(id: makeID(), op: "ping")) { response in
                reply = response.text
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 2) == .success, let text = reply, text.contains("euid=0") {
                transport = helper
                access = .root
                return
            }
            helper.terminate()
        }
        transport = local
        access = .limited
    }

    private func currentTransport() -> Transport {
        connectLock.lock()
        defer { connectLock.unlock() }
        if transport.isAlive { return transport }
        if CFAbsoluteTimeGetCurrent() - lastConnect > 1 { connect() }
        return transport.isAlive ? transport : local
    }

    func cancel(_ id: Int) {
        connectLock.lock()
        let t = transport
        connectLock.unlock()
        t.cancel(id)
        local.cancel(id)
    }

    /// Sends a request. `progress` is called on the main queue for
    /// intermediate updates (progress, streamed results).
    func call(_ request: Request, progress: ((Response) -> Void)? = nil) async throws -> Response {
        var req = request
        if req.id == 0 { req.id = makeID() }
        let t = currentTransport()
        return try await withCheckedThrowingContinuation { continuation in
            t.send(req) { response in
                if !response.done {
                    if let progress = progress {
                        DispatchQueue.main.async { progress(response) }
                    }
                    return
                }
                if let error = response.error {
                    continuation.resume(throwing: XixuError(code: response.code ?? EIO, message: error, subject: response.subject))
                } else {
                    continuation.resume(returning: response)
                }
            }
        }
    }

    // MARK: - Conveniences

    func list(_ path: String) async throws -> [Entry] {
        try await call(Request(op: "list", path: path, flags: Prefs.resolveContainers ? ["containers"] : nil)).entries ?? []
    }

    func stat(_ path: String) async throws -> StatInfo {
        guard let info = try await call(Request(op: "stat", path: path)).stat else { throw XixuError(code: EIO, message: "No data", subject: nil) }
        return info
    }

    func read(_ path: String, offset: Int64 = 0, length: Int? = nil) async throws -> Data {
        try await call(Request(op: "read", path: path, offset: offset, length: length)).data ?? Data()
    }

    func write(_ path: String, data: Data) async throws {
        _ = try await call(Request(op: "write", path: path, data: data))
    }

    func exists(_ paths: [String]) async throws -> [Bool] {
        (try await call(Request(op: "exists", paths: paths)).numbers ?? []).map { $0 != 0 }
    }

    func stage(_ paths: [String]) async throws -> [String] {
        try await call(Request(op: "stage", paths: paths, dest: Staging.newDirectory())).strings ?? []
    }
}

/// Private copies handed to Quick Look, the share sheet and SQLite.
enum Staging {
    static let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("Xixu")

    static func newDirectory() -> String {
        (root as NSString).appendingPathComponent(UUID().uuidString)
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
