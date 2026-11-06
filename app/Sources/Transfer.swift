import UIKit
import Network
import Darwin

/// Small HTTP server for Wi-Fi file transfer. Every API call needs the
/// six-digit code shown in the app; paths are confined to the shared folder.
final class TransferServer {
    static let shared = TransferServer()

    private var listener: NWListener?
    let queue = DispatchQueue(label: "xixu.transfer")
    let port: UInt16 = 8080
    private(set) var pin = TransferServer.makePin()
    var root = "/var/mobile"
    var onChange: ((String?) -> Void)?

    var isRunning: Bool { listener != nil }

    private static func makePin() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return connection.cancel() }
                HTTPConnection(connection: connection, server: self).start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .failed(let error):
                        self?.listener = nil
                        self?.onChange?(error.localizedDescription)
                    case .ready, .cancelled:
                        self?.onChange?(nil)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onChange?(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onChange?(nil)
    }

    func renewPin() { pin = Self.makePin() }

    /// IPv4 address of the Wi-Fi interface.
    static func address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    /// "/sub/dir" (relative to the shared folder) -> absolute path; nil if it escapes.
    func resolve(_ relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        if parts.contains("..") { return nil }
        var path = root
        for part in parts where part != "." && !part.isEmpty { path = Paths.join(path, part) }
        return path
    }
}

private final class HTTPConnection {
    private let connection: NWConnection
    private let server: TransferServer
    private var buffer = Data()
    private var headersDone = false
    private var method = ""
    private var path = ""
    private var query: [String: String] = [:]
    private var headers: [String: String] = [:]

    private var bodyLength = 0
    private var received = 0
    private var pending = Data()
    private var uploadTemp: String?
    private var uploadDir = ""
    private var uploadName = ""

    init(connection: NWConnection, server: TransferServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.start(queue: server.queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [self] data, _, complete, error in
            if let data = data, !data.isEmpty {
                handle(data)
            } else if complete || error != nil {
                abortUpload()
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    private func handle(_ data: Data) {
        guard headersDone else {
            buffer.append(data)
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 65536 { return send(431, json: ["error": "Headers too large"]) }
                return receive()
            }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            let body = Data(buffer[end.upperBound...])
            buffer = Data()
            headersDone = true
            parse(head)
            route(body)
            return
        }
        consumeBody(data)
    }

    private func parse(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        method = first.first ?? ""
        let target = first.count > 1 ? first[1] : "/"
        let components = URLComponents(string: "http://x" + target)
        path = components?.path ?? "/"
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        bodyLength = Int(headers["content-length"] ?? "") ?? 0
    }

    // MARK: - Routing

    private func route(_ initialBody: Data) {
        if method == "GET" && (path == "/" || path == "/index.html") {
            return send(200, type: "text/html; charset=utf-8", body: Data(TransferPage.html.utf8))
        }
        guard (headers["x-xixu-pin"] ?? query["pin"]) == server.pin else {
            return send(401, json: ["error": "Wrong code"])
        }
        switch (method, path) {
        case ("GET", "/api/list"):
            list()
        case ("GET", "/api/download"):
            download()
        case ("PUT", "/api/upload"), ("POST", "/api/upload"):
            beginUpload(initialBody)
        case ("POST", "/api/mkdir"):
            simple { dir in
                let name = self.query["name"] ?? ""
                _ = try await FS.shared.call(Request(op: "mkdir", path: Paths.join(dir, name)))
                announceChanges([dir])
            }
        case ("POST", "/api/delete"):
            simple { target in
                let op = Prefs.useTrash ? "trash" : "delete"
                do {
                    _ = try await FS.shared.call(Request(op: op, paths: [target]))
                } catch let error as XixuError where error.code == EXDEV {
                    _ = try await FS.shared.call(Request(op: "delete", paths: [target]))
                }
                announceChanges([Paths.parent(target)])
            }
        default:
            send(404, json: ["error": "Not found"])
        }
    }

    private func simple(_ work: @escaping (String) async throws -> Void) {
        guard let target = server.resolve(query["path"] ?? "/"), target != server.root || path == "/api/mkdir" else {
            return send(400, json: ["error": "Invalid path"])
        }
        Task {
            do {
                try await work(target)
                self.send(200, json: ["ok": true])
            } catch {
                self.send(500, json: ["error": error.localizedDescription])
            }
        }
    }

    private func list() {
        guard let dir = server.resolve(query["path"] ?? "/") else { return send(400, json: ["error": "Invalid path"]) }
        Task {
            do {
                let entries = try await FS.shared.list(dir)
                let items: [[String: Any]] = entries
                    .filter { Prefs.showHidden || !$0.name.hasPrefix(".") }
                    .sorted { a, b in
                        let ad = a.kind == .directory || a.linkDir == true
                        let bd = b.kind == .directory || b.linkDir == true
                        if ad != bd { return ad }
                        return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }
                    .map { e in
                        ["name": e.name, "dir": e.kind == .directory || e.linkDir == true, "size": e.size, "mtime": Int(e.mtime)]
                    }
                self.send(200, jsonArray: items)
            } catch {
                self.send(500, json: ["error": error.localizedDescription])
            }
        }
    }

    // MARK: - Download

    private func download() {
        guard let file = server.resolve(query["path"] ?? ""), file != server.root else { return send(400, json: ["error": "Invalid path"]) }
        Task {
            do {
                let info = try await FS.shared.stat(file)
                guard info.entry.kind == .file || (info.entry.kind == .symlink && info.entry.linkDir == false) else {
                    return self.send(400, json: ["error": "Not a file"])
                }
                let size = info.entry.kind == .file ? info.entry.size : Int64(try await FS.shared.read(file).count)
                let name = Paths.name(file).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "download"
                var head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\n"
                head += "Content-Disposition: attachment; filename*=UTF-8''\(name)\r\nConnection: close\r\n\r\n"
                self.connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
                    if error == nil { self.sendChunk(file, offset: 0, size: size) } else { self.connection.cancel() }
                })
            } catch {
                self.send(404, json: ["error": error.localizedDescription])
            }
        }
    }

    private func sendChunk(_ file: String, offset: Int64, size: Int64) {
        guard offset < size else { return connection.cancel() }
        Task {
            let length = Int(min(Int64(1 << 20), size - offset))
            var data: Data?
            if access(file, R_OK) == 0, let handle = FileHandle(forReadingAtPath: file) {
                handle.seek(toFileOffset: UInt64(offset))
                data = handle.readData(ofLength: length)
                handle.closeFile()
            } else {
                data = try? await FS.shared.read(file, offset: offset, length: length)
            }
            guard let chunk = data, !chunk.isEmpty else { return self.connection.cancel() }
            self.connection.send(content: chunk, completion: .contentProcessed { error in
                if error == nil { self.sendChunk(file, offset: offset + Int64(chunk.count), size: size) } else { self.connection.cancel() }
            })
        }
    }

    // MARK: - Upload

    private func beginUpload(_ initialBody: Data) {
        let name = query["name"] ?? ""
        guard let dir = server.resolve(query["dir"] ?? "/"), !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            return send(400, json: ["error": "Invalid name"])
        }
        uploadDir = dir
        uploadName = name
        uploadTemp = Paths.join(dir, ".xixu-upload-\(UInt32.random(in: 0...UInt32.max))")
        consumeBody(initialBody)
    }

    private func consumeBody(_ data: Data) {
        guard uploadTemp != nil else { return receive() }
        pending.append(data)
        received += data.count
        let finished = received >= bodyLength
        if pending.count >= (1 << 20) || finished {
            flush(finished: finished)
        } else {
            receive()
        }
    }

    private func flush(finished: Bool) {
        guard let temp = uploadTemp else { return }
        let chunk = pending
        pending = Data()
        Task {
            do {
                _ = try await FS.shared.call(Request(op: "append", path: temp, data: chunk))
                if finished {
                    try await self.finishUpload(temp)
                } else {
                    self.server.queue.async { self.receive() }
                }
            } catch {
                self.abortUpload()
                self.send(500, json: ["error": error.localizedDescription])
            }
        }
    }

    private func finishUpload(_ temp: String) async throws {
        if bodyLength == 0 {
            _ = try await FS.shared.call(Request(op: "append", path: temp, data: Data()))
        }
        let parts = Paths.split(uploadName)
        var name = uploadName
        var n = 2
        while try await FS.shared.exists([Paths.join(uploadDir, name)]).first == true {
            name = parts.ext.isEmpty ? "\(parts.base) \(n)" : "\(parts.base) \(n).\(parts.ext)"
            n += 1
        }
        _ = try await FS.shared.call(Request(op: "rename", path: temp, text: name))
        uploadTemp = nil
        announceChanges([uploadDir])
        send(200, json: ["ok": true, "name": name])
    }

    private func abortUpload() {
        guard let temp = uploadTemp else { return }
        uploadTemp = nil
        Task { _ = try? await FS.shared.call(Request(op: "delete", paths: [temp])) }
    }

    // MARK: - Responses

    private func send(_ status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        send(status, type: "application/json", body: body)
    }

    private func send(_ status: Int, jsonArray: [[String: Any]]) {
        let body = (try? JSONSerialization.data(withJSONObject: jsonArray)) ?? Data()
        send(status, type: "application/json", body: body)
    }

    private func send(_ status: Int, type: String, body: Data) {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 431: "Request Header Fields Too Large", 500: "Internal Server Error"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
        head += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}

// MARK: - Screen

final class TransferViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Row { case toggle, address, code, folder }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var error: String?
    private let folders: [(String, String)] = [
        (L("Mobile"), "/var/mobile"), (L("Media"), "/var/mobile/Media"),
        (L("Documents"), "/var/mobile/Documents"), (L("Entire Device"), "/"),
    ]

    private var server: TransferServer { TransferServer.shared }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Wi-Fi Transfer")
        navigationItem.largeTitleDisplayMode = .never
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)
        server.onChange = { [weak self] error in
            self?.error = error
            self?.tableView.reloadData()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = server.isRunning
        tableView.reloadData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private var rows: [Row] { server.isRunning ? [.toggle, .address, .code, .folder] : [.toggle, .folder] }

    private var url: String {
        "http://\(TransferServer.address() ?? "?"):\(server.port)"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let error = error { return error }
        return server.isRunning
            ? L("Open the address in a browser on a computer or phone in the same Wi-Fi and enter the code. Keep Xixu open while transferring.")
            : L("Share a folder with any browser in your Wi-Fi network. Uploads and downloads need a one-time code.")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch rows[indexPath.row] {
        case .toggle:
            var c = UIListContentConfiguration.cell()
            c.text = L("Wi-Fi Transfer")
            c.image = Icons.squircle("wifi", .systemBlue)
            cell.contentConfiguration = c
            let toggle = UISwitch()
            toggle.isOn = server.isRunning
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self = self else { return }
                if toggle?.isOn == true {
                    self.server.renewPin()
                    self.server.start()
                } else {
                    self.server.stop()
                }
                UIApplication.shared.isIdleTimerDisabled = self.server.isRunning
                Haptics.tap()
                self.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
            }, for: .valueChanged)
            cell.accessoryView = toggle
        case .address:
            var c = UIListContentConfiguration.subtitleCell()
            c.text = L("Address")
            c.textProperties.font = .preferredFont(forTextStyle: .footnote)
            c.textProperties.color = .secondaryLabel
            c.secondaryText = url
            c.secondaryTextProperties.font = .systemFont(ofSize: 22, weight: .semibold)
            c.secondaryTextProperties.color = Theme.accent
            c.textToSecondaryTextVerticalPadding = 4
            cell.contentConfiguration = c
            cell.selectionStyle = .default
        case .code:
            var c = UIListContentConfiguration.subtitleCell()
            c.text = L("Code")
            c.textProperties.font = .preferredFont(forTextStyle: .footnote)
            c.textProperties.color = .secondaryLabel
            let pin = server.pin
            c.secondaryText = String(pin.prefix(3)) + " " + String(pin.suffix(3))
            c.secondaryTextProperties.font = Theme.mono(28, .semibold)
            c.textToSecondaryTextVerticalPadding = 4
            cell.contentConfiguration = c
        case .folder:
            var c = UIListContentConfiguration.valueCell()
            c.text = L("Shared Folder")
            c.secondaryText = folders.first { $0.1 == server.root }?.0 ?? server.root
            cell.contentConfiguration = c
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "chevron.up.chevron.down"), for: .normal)
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: folders.map { title, path in
                UIAction(title: title, subtitle: path, state: path == server.root ? .on : .off) { [weak self] _ in
                    self?.server.root = path
                    self?.tableView.reloadData()
                }
            })
            button.sizeToFit()
            cell.accessoryView = button
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if rows[indexPath.row] == .address {
            UIPasteboard.general.string = url
            Haptics.tap()
            RootController.shared?.toast(L("Copied"))
        }
    }
}

/// The browser UI served at "/".
enum TransferPage {
    static let html = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Xixu</title>
<style>
:root{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--sub:#6e6e73;--line:#e5e5ea;--accent:#007aff;--hover:#f0f4ff}
@media(prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f5f5f7;--sub:#98989d;--line:#2c2c2e;--accent:#0a84ff;--hover:#24262c}}
*{box-sizing:border-box}body{margin:0;font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;background:var(--bg);color:var(--text)}
header{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:12px 20px;display:flex;align-items:center;gap:10px}
h1{font-size:17px;margin:0 8px 0 0;font-weight:600}.crumbs{flex:1;min-width:0;color:var(--sub);font-size:14px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
.crumbs a{color:var(--accent);text-decoration:none}button{font:inherit;border:0;border-radius:9px;padding:7px 14px;background:var(--accent);color:#fff;cursor:pointer}
button.ghost{background:transparent;color:var(--accent)}main{max-width:980px;margin:20px auto;padding:0 16px 80px}
.list{background:var(--card);border-radius:14px;overflow:hidden;border:1px solid var(--line)}
.row{display:flex;align-items:center;gap:12px;padding:9px 16px;border-top:1px solid var(--line)}.row:first-child{border-top:0}.row:hover{background:var(--hover)}
.icon{width:30px;height:30px;flex:none}.name{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.name a{color:inherit;text-decoration:none}
.meta{color:var(--sub);font-size:13px;font-variant-numeric:tabular-nums;white-space:nowrap;width:90px;text-align:right}.del{color:var(--sub);background:none;padding:4px 8px}
.del:hover{color:#ff3b30}.empty{padding:48px;text-align:center;color:var(--sub)}
.drop{position:fixed;inset:0;z-index:5;background:rgba(0,122,255,.12);border:3px dashed var(--accent);display:none;align-items:center;justify-content:center;font-size:20px;font-weight:600;color:var(--accent)}
.uploads{position:fixed;right:16px;bottom:16px;width:300px;display:flex;flex-direction:column;gap:8px;z-index:4}
.up{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 12px;font-size:13px;box-shadow:0 4px 18px rgba(0,0,0,.08)}
.bar{height:4px;background:var(--line);border-radius:2px;margin-top:7px;overflow:hidden}.bar i{display:block;height:100%;background:var(--accent);width:0}
.pin{position:fixed;inset:0;z-index:6;display:none;align-items:center;justify-content:center;background:var(--bg)}
.pin form{background:var(--card);padding:28px;border-radius:18px;border:1px solid var(--line);text-align:center;width:320px}
.pin input{font:600 30px ui-monospace,Menlo,monospace;letter-spacing:8px;text-align:center;width:100%;padding:10px;border-radius:10px;border:1px solid var(--line);background:var(--bg);color:var(--text);margin:16px 0}
@media(max-width:600px){.meta.date{display:none}}
</style></head><body>
<header><h1>Xixu</h1><div class="crumbs" id="crumbs"></div><button class="ghost" id="mk">New Folder</button><button id="upbtn">Upload</button><input type="file" id="pick" multiple hidden></header>
<main><div class="list" id="list"></div></main>
<div class="drop" id="drop">Drop to upload</div><div class="uploads" id="uploads"></div>
<div class="pin" id="pin"><form id="pinform"><div style="font-weight:600;font-size:17px">Enter the code shown in Xixu</div><input id="code" inputmode="numeric" autocomplete="off" maxlength="7"><button style="width:100%">Connect</button></form></div>
<script>
const $=id=>document.getElementById(id);let pin=localStorage.getItem('xixu-pin')||'';
const cwd=()=>decodeURIComponent(location.hash.slice(1))||'/';
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const join=(a,b)=>(a=='/'?'':a)+'/'+b;
const enc=s=>encodeURIComponent(s);
function api(url,opt){opt=opt||{};opt.headers={'X-Xixu-Pin':pin};return fetch(url,opt).then(r=>{if(r.status==401){$('pin').style.display='flex';$('code').focus();throw 'pin'}if(!r.ok)return r.json().then(j=>{throw j.error||r.status});return r})}
function fmt(n){if(n<1024)return n+' B';const u=['KB','MB','GB','TB'];let i=-1;do{n/=1024;i++}while(n>=1024&&i<3);return n.toFixed(n<10?1:0)+' '+u[i]}
const folder='<svg class="icon" viewBox="0 0 34 34"><rect x="1" y="4.5" width="13" height="4.5" rx="2" fill="#0066d6"/><rect x="1" y="6.5" width="32" height="23.5" rx="3.2" fill="#0066d6"/><rect x="1" y="10" width="32" height="20" rx="3.2" fill="#2e8fff"/></svg>';
function fileIcon(n){const p=n.split('.');const e=p.length>1?p.pop().toUpperCase().slice(0,4):'';
return '<svg class="icon" viewBox="0 0 34 34"><path d="M8.6 1.5H21l7 7v21.4a2.6 2.6 0 0 1-2.6 2.6H8.6A2.6 2.6 0 0 1 6 29.9V4.1a2.6 2.6 0 0 1 2.6-2.6z" fill="var(--card)" stroke="#c7c7cc" stroke-width="1"/><path d="M21 1.5v7h7" fill="none" stroke="#c7c7cc" stroke-width="1"/>'+(e?'<rect x="8.2" y="22" width="17.6" height="7" rx="1.6" fill="#8e8e93"/><text x="17" y="27.3" font-size="5.2" font-weight="800" fill="#fff" text-anchor="middle" font-family="-apple-system,Segoe UI,sans-serif">'+esc(e)+'</text>':'')+'</svg>'}
function crumbs(){const parts=cwd().split('/').filter(Boolean);let h='<a href="#/">Shared</a>',acc='';for(const p of parts){acc+='/'+p;h+=' › <a href="#'+enc(acc)+'">'+esc(p)+'</a>'}$('crumbs').innerHTML=h}
function load(){crumbs();api('/api/list?path='+enc(cwd())).then(r=>r.json()).then(items=>{
if(!items.length){$('list').innerHTML='<div class="empty">This folder is empty</div>';return}
$('list').innerHTML=items.map(i=>{const p=join(cwd(),i.name);const href=i.dir?'#'+enc(p):'/api/download?path='+enc(p)+'&pin='+enc(pin);
return '<div class="row">'+(i.dir?folder:fileIcon(i.name))+'<div class="name"><a href="'+esc(href)+'">'+esc(i.name)+'</a></div><div class="meta">'+(i.dir?'':fmt(i.size))+'</div><div class="meta date">'+new Date(i.mtime*1000).toLocaleDateString()+'</div><button class="del" data-p="'+esc(p)+'" title="Delete">✕</button></div>'}).join('');
document.querySelectorAll('.del').forEach(b=>b.onclick=()=>{if(confirm('Delete '+b.dataset.p.split('/').pop()+'?'))api('/api/delete?path='+enc(b.dataset.p),{method:'POST'}).then(load).catch(alert)})
}).catch(e=>{if(e!='pin')$('list').innerHTML='<div class="empty">'+esc(e)+'</div>'})}
function upload(files){const dir=cwd();let chain=Promise.resolve();for(const f of files){const box=document.createElement('div');box.className='up';box.innerHTML=esc(f.name)+'<div class="bar"><i></i></div>';$('uploads').appendChild(box);
chain=chain.then(()=>new Promise(done=>{const x=new XMLHttpRequest();x.open('PUT','/api/upload?dir='+enc(dir)+'&name='+enc(f.name));x.setRequestHeader('X-Xixu-Pin',pin);
x.upload.onprogress=e=>{if(e.lengthComputable)box.querySelector('i').style.width=(e.loaded/e.total*100)+'%'};
x.onload=()=>{if(x.status==200){box.remove()}else{box.innerHTML=esc(f.name)+': failed'}if(dir==cwd())load();done()};x.onerror=()=>{box.innerHTML=esc(f.name)+': failed';done()};x.send(f)}))}}
$('upbtn').onclick=()=>$('pick').click();$('pick').onchange=e=>{upload(e.target.files);e.target.value=''};
$('mk').onclick=()=>{const n=prompt('Folder name');if(n)api('/api/mkdir?path='+enc(cwd())+'&name='+enc(n),{method:'POST'}).then(load).catch(alert)};
$('pinform').onsubmit=e=>{e.preventDefault();pin=$('code').value.replace(/\D/g,'');localStorage.setItem('xixu-pin',pin);$('pin').style.display='none';load()};
let depth=0;addEventListener('dragenter',e=>{e.preventDefault();depth++;$('drop').style.display='flex'});addEventListener('dragleave',()=>{if(--depth<=0){depth=0;$('drop').style.display='none'}});
addEventListener('dragover',e=>e.preventDefault());addEventListener('drop',e=>{e.preventDefault();depth=0;$('drop').style.display='none';if(e.dataTransfer.files.length)upload(e.dataTransfer.files)});
addEventListener('hashchange',load);load();
</script></body></html>
"""#
}
