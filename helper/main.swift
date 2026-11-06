// xixuhelper – the root side of Xixu.
//
// Spawned by the app (root persona, or via its setuid bit) and kept alive for
// the whole session. Requests arrive as JSON lines on stdin, responses and
// progress leave as JSON lines on stdout. It exits when the app closes the pipe.

import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)

/// Only root (persona spawn) or the installed Xixu app may drive us.
func callerAllowed() -> Bool {
    if getuid() == 0 { return true }
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(getppid(), &buf, UInt32(buf.count)) > 0 else { return false }
    let parent = Engine.realPath(String(cString: buf)) ?? String(cString: buf)
    let app = (Engine.realPath(JB.path("/Applications")) ?? JB.path("/Applications")) + "/Xixu.app/"
    return parent.hasPrefix(app)
}

guard callerAllowed() else {
    FileHandle.standardError.write("xixuhelper: caller not allowed\n".data(using: .utf8)!)
    exit(1)
}

if geteuid() == 0 {
    _ = setgid(0)
    _ = setuid(0)
}
umask(0o022)

final class Server {
    private let outLock = NSLock()
    private let ctxLock = NSLock()
    private var contexts: [Int: OpContext] = [:]
    private let encoder = JSONEncoder()
    private let work = DispatchQueue(label: "xixu.helper.work", qos: .userInitiated, attributes: .concurrent)

    func send(_ response: Response) {
        outLock.lock()
        defer { outLock.unlock() }
        guard var data = try? encoder.encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(STDOUT_FILENO, base + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    exit(0) // app is gone
                }
                off += n
            }
        }
    }

    func run() {
        let decoder = JSONDecoder()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else { continue }
            if request.op == "cancel" {
                ctxLock.lock()
                let ctx = request.target.flatMap { contexts[$0] }
                ctxLock.unlock()
                ctx?.cancel()
                continue
            }
            let ctx = OpContext(id: request.id) { [weak self] in self?.send($0) }
            ctxLock.lock()
            contexts[request.id] = ctx
            ctxLock.unlock()
            work.async { [self] in
                let response: Response
                do {
                    response = try Dispatcher.handle(request, ctx: ctx)
                } catch {
                    response = Dispatcher.failure(request.id, error)
                }
                ctxLock.lock()
                contexts[request.id] = nil
                ctxLock.unlock()
                send(response)
            }
        }
        exit(0)
    }
}

Server().run()
