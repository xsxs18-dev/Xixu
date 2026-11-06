import UIKit

// MARK: - Parser

struct MachOSignature {
    var identifier: String?
    var teamID: String?
    var hashType: String?
    var pageCount = 0
    var adhoc = false
    var hasCMS = false
    var entitlements: String?
    var derEntitlementsSize: Int?
}

struct MachOSlice {
    var cpu = "?"
    var offset: Int64 = 0
    var size: Int64 = 0
    var is64 = false
    var fileType = "?"
    var flags: [String] = []
    var commandCount = 0
    var platform: String?
    var minOS: String?
    var sdk: String?
    var uuid: String?
    var installName: String?
    var dylibs: [(name: String, tag: String?)] = []
    var rpaths: [String] = []
    var cryptID: Int?
    var entryOffset: UInt64?
    var commandCounts: [(String, Int)] = []
    var signature: MachOSignature?
}

/// Bounds-checked reads; malformed files never crash the viewer.
private struct MachOBytes {
    let bytes: [UInt8]

    func u32(_ o: Int, big: Bool = false) -> UInt32? {
        guard o >= 0, o + 4 <= bytes.count else { return nil }
        let b = (UInt32(bytes[o]), UInt32(bytes[o + 1]), UInt32(bytes[o + 2]), UInt32(bytes[o + 3]))
        return big ? (b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3) : (b.3 << 24 | b.2 << 16 | b.1 << 8 | b.0)
    }

    func u64(_ o: Int, big: Bool = false) -> UInt64? {
        guard let a = u32(o, big: big), let b = u32(o + 4, big: big) else { return nil }
        return big ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
    }

    func u8(_ o: Int) -> UInt8? {
        guard o >= 0, o < bytes.count else { return nil }
        return bytes[o]
    }

    func cString(_ o: Int, limit: Int = 4096) -> String? {
        guard o >= 0, o < bytes.count else { return nil }
        var end = o
        while end < bytes.count && end - o < limit && bytes[end] != 0 { end += 1 }
        return String(decoding: bytes[o..<end], as: UTF8.self)
    }
}

enum MachOParser {
    static func parse(path: String) async throws -> [MachOSlice] {
        let head = MachOBytes(bytes: [UInt8](try await FS.shared.read(path, offset: 0, length: 4096)))
        guard let magic = head.u32(0, big: true) else { throw notMachO(path) }

        var ranges: [(cpu: Int32?, sub: Int32?, offset: Int64, size: Int64)] = []
        if magic == 0xCAFEBABE || magic == 0xCAFEBABF {
            let is64 = magic == 0xCAFEBABF
            guard let count = head.u32(4, big: true), count > 0, count < 32 else { throw notMachO(path) }
            let stride = is64 ? 32 : 20
            for i in 0..<Int(count) {
                let base = 8 + i * stride
                guard let cpu = head.u32(base, big: true), let sub = head.u32(base + 4, big: true) else { break }
                let offset: Int64
                let size: Int64
                if is64 {
                    guard let o = head.u64(base + 8, big: true), let s = head.u64(base + 16, big: true) else { break }
                    offset = Int64(o)
                    size = Int64(s)
                } else {
                    guard let o = head.u32(base + 8, big: true), let s = head.u32(base + 12, big: true) else { break }
                    offset = Int64(o)
                    size = Int64(s)
                }
                ranges.append((Int32(bitPattern: cpu), Int32(bitPattern: sub), offset, size))
            }
        } else {
            ranges.append((nil, nil, 0, 0))
        }

        var slices: [MachOSlice] = []
        for range in ranges {
            if let slice = try? await parseSlice(path: path, offset: range.offset, size: range.size) {
                slices.append(slice)
            }
        }
        if slices.isEmpty { throw notMachO(path) }
        return slices
    }

    private static func notMachO(_ path: String) -> XixuError {
        XixuError(code: EINVAL, message: L("This isn't a Mach-O file."), subject: Paths.name(path))
    }

    private static func parseSlice(path: String, offset: Int64, size: Int64) async throws -> MachOSlice {
        let header = MachOBytes(bytes: [UInt8](try await FS.shared.read(path, offset: offset, length: 32)))
        guard let magic = header.u32(0) else { throw notMachO(path) }
        let is64: Bool
        switch magic {
        case 0xFEEDFACF: is64 = true
        case 0xFEEDFACE: is64 = false
        default: throw notMachO(path)
        }
        var slice = MachOSlice()
        slice.offset = offset
        slice.size = size
        slice.is64 = is64
        let cpu = Int32(bitPattern: header.u32(4) ?? 0)
        let sub = Int32(bitPattern: header.u32(8) ?? 0)
        slice.cpu = cpuName(cpu, sub)
        slice.fileType = fileTypeName(header.u32(12) ?? 0)
        let ncmds = Int(header.u32(16) ?? 0)
        let sizeofcmds = Int(header.u32(20) ?? 0)
        slice.flags = flagNames(header.u32(24) ?? 0)
        slice.commandCount = ncmds

        let headerSize = is64 ? 32 : 28
        guard sizeofcmds > 0, sizeofcmds < 8 << 20 else { return slice }
        let commands = MachOBytes(bytes: [UInt8](try await FS.shared.read(path, offset: offset + Int64(headerSize), length: sizeofcmds)))

        var counts: [String: Int] = [:]
        var order: [String] = []
        var signatureRange: (Int64, Int)?
        var cursor = 0
        for _ in 0..<min(ncmds, 4096) {
            guard let cmd = commands.u32(cursor), let cmdsize = commands.u32(cursor + 4), cmdsize >= 8,
                  cursor + Int(cmdsize) <= commands.bytes.count else { break }
            let name = commandName(cmd)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1

            switch cmd {
            case 0x1B:
                if cursor + 24 <= commands.bytes.count {
                    let b = commands.bytes[(cursor + 8)..<(cursor + 24)].map { String(format: "%02X", $0) }
                    slice.uuid = "\(b[0..<4].joined())-\(b[4..<6].joined())-\(b[6..<8].joined())-\(b[8..<10].joined())-\(b[10..<16].joined())"
                }
            case 0x32:
                slice.platform = platformName(commands.u32(cursor + 8) ?? 0)
                slice.minOS = version(commands.u32(cursor + 12) ?? 0)
                slice.sdk = version(commands.u32(cursor + 16) ?? 0)
            case 0x25, 0x24, 0x2F, 0x30:
                let platforms: [UInt32: String] = [0x25: "iOS", 0x24: "macOS", 0x2F: "tvOS", 0x30: "watchOS"]
                slice.platform = slice.platform ?? platforms[cmd]
                slice.minOS = slice.minOS ?? version(commands.u32(cursor + 8) ?? 0)
                slice.sdk = slice.sdk ?? version(commands.u32(cursor + 12) ?? 0)
            case 0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023:
                if let nameOffset = commands.u32(cursor + 8), let dylib = commands.cString(cursor + Int(nameOffset)) {
                    let tags: [UInt32: String] = [0x80000018: L("weak"), 0x8000001F: L("re-export"), 0x20: L("lazy"), 0x80000023: L("upward")]
                    slice.dylibs.append((dylib, tags[cmd]))
                }
            case 0xD:
                if let nameOffset = commands.u32(cursor + 8) {
                    slice.installName = commands.cString(cursor + Int(nameOffset))
                }
            case 0x8000001C:
                if let pathOffset = commands.u32(cursor + 8), let rpath = commands.cString(cursor + Int(pathOffset)) {
                    slice.rpaths.append(rpath)
                }
            case 0x21, 0x2C:
                slice.cryptID = commands.u32(cursor + 16).map(Int.init)
            case 0x80000028:
                slice.entryOffset = commands.u64(cursor + 8)
            case 0x1D:
                if let dataoff = commands.u32(cursor + 8), let datasize = commands.u32(cursor + 12) {
                    signatureRange = (Int64(dataoff), Int(datasize))
                }
            default:
                break
            }
            cursor += Int(cmdsize)
        }
        slice.commandCounts = order.map { ($0, counts[$0] ?? 0) }

        if let (dataoff, datasize) = signatureRange, datasize > 0, datasize < 16 << 20 {
            let blob = MachOBytes(bytes: [UInt8](try await FS.shared.read(path, offset: offset + dataoff, length: datasize)))
            slice.signature = parseSignature(blob)
        }
        return slice
    }

    private static func parseSignature(_ b: MachOBytes) -> MachOSignature? {
        guard b.u32(0, big: true) == 0xFADE0CC0, let count = b.u32(8, big: true), count < 64 else { return nil }
        var signature = MachOSignature()
        for i in 0..<Int(count) {
            guard let blobOffset = b.u32(12 + i * 8 + 4, big: true) else { continue }
            let o = Int(blobOffset)
            guard let magic = b.u32(o, big: true), let length = b.u32(o + 4, big: true) else { continue }
            switch magic {
            case 0xFADE0C02:
                guard signature.identifier == nil else { continue }
                let version = b.u32(o + 8, big: true) ?? 0
                let flags = b.u32(o + 12, big: true) ?? 0
                if let identOffset = b.u32(o + 20, big: true) {
                    signature.identifier = b.cString(o + Int(identOffset))
                }
                signature.pageCount = Int(b.u32(o + 28, big: true) ?? 0)
                switch b.u8(o + 37) ?? 0 {
                case 1: signature.hashType = "SHA-1"
                case 2: signature.hashType = "SHA-256"
                case 3: signature.hashType = "SHA-256 (truncated)"
                case 4: signature.hashType = "SHA-384"
                default: signature.hashType = nil
                }
                signature.adhoc = flags & 0x2 != 0
                if version >= 0x20200, let teamOffset = b.u32(o + 48, big: true), teamOffset > 0 {
                    signature.teamID = b.cString(o + Int(teamOffset))
                }
            case 0xFADE7171:
                let end = min(o + Int(length), b.bytes.count)
                if o + 8 < end {
                    signature.entitlements = String(decoding: b.bytes[(o + 8)..<end], as: UTF8.self)
                }
            case 0xFADE7172:
                signature.derEntitlementsSize = Int(length) - 8
            case 0xFADE0B01:
                signature.hasCMS = length > 8
            default:
                break
            }
        }
        return signature
    }

    private static func cpuName(_ cpu: Int32, _ sub: Int32) -> String {
        let subtype = sub & 0xFF
        switch cpu {
        case 0x0100000C: return subtype == 2 ? "arm64e" : "arm64"
        case 0x0200000C: return "arm64_32"
        case 12:
            switch subtype {
            case 9: return "armv7"
            case 11: return "armv7s"
            case 12: return "armv7k"
            default: return "arm"
            }
        case 0x01000007: return "x86_64"
        case 7: return "i386"
        default: return String(format: "0x%X", cpu)
        }
    }

    private static func fileTypeName(_ type: UInt32) -> String {
        switch type {
        case 1: return L("Object")
        case 2: return L("Executable")
        case 6: return L("Dynamic Library")
        case 7: return L("Dynamic Linker")
        case 8: return L("Bundle")
        case 9: return L("Library Stub")
        case 10: return L("Debug Symbols")
        case 11: return L("Kernel Extension")
        case 12: return L("File Set")
        default: return "\(type)"
        }
    }

    private static func flagNames(_ flags: UInt32) -> [String] {
        let known: [(UInt32, String)] = [
            (0x1, "NOUNDEFS"), (0x4, "DYLDLINK"), (0x80, "TWOLEVEL"), (0x200000, "PIE"),
            (0x800000, "HAS_TLV"), (0x2000000, "APP_EXTENSION_SAFE"), (0x80000000, "DYLIB_IN_CACHE"),
        ]
        return known.filter { flags & $0.0 != 0 }.map(\.1)
    }

    private static func platformName(_ platform: UInt32) -> String {
        let names: [UInt32: String] = [1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS", 6: "Mac Catalyst",
                                       7: "iOS Simulator", 8: "tvOS Simulator", 9: "watchOS Simulator", 10: "DriverKit",
                                       11: "visionOS", 12: "visionOS Simulator"]
        return names[platform] ?? "\(platform)"
    }

    private static func version(_ v: UInt32) -> String {
        let major = v >> 16, minor = (v >> 8) & 0xFF, patch = v & 0xFF
        return patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
    }

    private static func commandName(_ cmd: UInt32) -> String {
        let names: [UInt32: String] = [
            0x1: "LC_SEGMENT", 0x2: "LC_SYMTAB", 0xB: "LC_DYSYMTAB", 0xC: "LC_LOAD_DYLIB", 0xD: "LC_ID_DYLIB",
            0xE: "LC_LOAD_DYLINKER", 0x19: "LC_SEGMENT_64", 0x1B: "LC_UUID", 0x1D: "LC_CODE_SIGNATURE",
            0x1E: "LC_SEGMENT_SPLIT_INFO", 0x20: "LC_LAZY_LOAD_DYLIB", 0x21: "LC_ENCRYPTION_INFO",
            0x22: "LC_DYLD_INFO", 0x80000022: "LC_DYLD_INFO_ONLY", 0x24: "LC_VERSION_MIN_MACOSX",
            0x25: "LC_VERSION_MIN_IPHONEOS", 0x26: "LC_FUNCTION_STARTS", 0x29: "LC_DATA_IN_CODE",
            0x2A: "LC_SOURCE_VERSION", 0x2B: "LC_DYLIB_CODE_SIGN_DRS", 0x2C: "LC_ENCRYPTION_INFO_64",
            0x2F: "LC_VERSION_MIN_TVOS", 0x30: "LC_VERSION_MIN_WATCHOS", 0x32: "LC_BUILD_VERSION",
            0x80000018: "LC_LOAD_WEAK_DYLIB", 0x8000001C: "LC_RPATH", 0x8000001F: "LC_REEXPORT_DYLIB",
            0x80000023: "LC_LOAD_UPWARD_DYLIB", 0x80000028: "LC_MAIN", 0x80000033: "LC_DYLD_EXPORTS_TRIE",
            0x80000034: "LC_DYLD_CHAINED_FIXUPS", 0x35: "LC_FILESET_ENTRY", 0x2E: "LC_LINKER_OPTIMIZATION_HINT",
        ]
        return names[cmd] ?? String(format: "0x%X", cmd)
    }
}

// MARK: - Viewer

final class MachOViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private struct Row {
        var title: String
        var value: String?
        var mono = false
        var action: (() -> Void)?
    }

    private struct Section {
        var title: String?
        var rows: [Row]
    }

    private let path: String
    private var slices: [MachOSlice] = []
    private var selected = 0
    private var sections: [Section] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(path: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
        title = Paths.name(path)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundView = EmptyStateView(title: nil, loading: true)
        view.addSubview(tableView)

        Task { @MainActor in
            do {
                self.slices = try await MachOParser.parse(path: self.path)
                self.tableView.backgroundView = nil
                self.setUpPicker()
                self.rebuild()
            } catch {
                self.tableView.backgroundView = EmptyStateView(title: L("Can't Read Binary"), message: error.localizedDescription)
                self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Hex Viewer"), primaryAction: UIAction { [weak self] _ in
                    guard let self = self else { return }
                    let path = self.path
                    let presenter = self.presentingViewController
                    self.dismiss(animated: true) { presenter?.presentModal(HexViewController(path: path), fullScreen: true) }
                })
            }
        }
    }

    private func setUpPicker() {
        guard slices.count > 1 else { return }
        let control = UISegmentedControl(items: slices.map(\.cpu))
        control.selectedSegmentIndex = 0
        control.addAction(UIAction { [weak self, weak control] _ in
            self?.selected = control?.selectedSegmentIndex ?? 0
            self?.rebuild()
        }, for: .valueChanged)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 52))
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: container.layoutMarginsGuide.leadingAnchor),
        ])
        tableView.tableHeaderView = container
    }

    private func rebuild() {
        guard slices.indices.contains(selected) else { return }
        let s = slices[selected]
        var result: [Section] = []

        var header = [
            Row(title: L("Architecture"), value: s.cpu + (s.is64 ? "" : " (32-bit)")),
            Row(title: L("Type"), value: s.fileType),
            Row(title: L("Load Commands"), value: "\(s.commandCount)"),
        ]
        if !s.flags.isEmpty { header.append(Row(title: L("Flags"), value: s.flags.joined(separator: " "), mono: true)) }
        if slices.count > 1 {
            header.append(Row(title: L("Slice"), value: "\(Format.bytes(s.size)) @ 0x\(String(s.offset, radix: 16))", mono: true))
        }
        if let entry = s.entryOffset { header.append(Row(title: L("Entry Point"), value: String(format: "0x%llX", entry), mono: true)) }
        result.append(Section(title: nil, rows: header))

        var build: [Row] = []
        if let platform = s.platform { build.append(Row(title: L("Platform"), value: platform)) }
        if let minOS = s.minOS { build.append(Row(title: L("Minimum OS"), value: minOS)) }
        if let sdk = s.sdk { build.append(Row(title: L("SDK"), value: sdk)) }
        if let uuid = s.uuid { build.append(Row(title: "UUID", value: uuid, mono: true)) }
        if let cryptID = s.cryptID {
            build.append(Row(title: L("Encryption"), value: cryptID == 0 ? L("Not encrypted") : LF("Encrypted (cryptid %d)", cryptID)))
        }
        if !build.isEmpty { result.append(Section(title: L("Build"), rows: build)) }

        var signing: [Row] = []
        if let sig = s.signature {
            if let id = sig.identifier { signing.append(Row(title: L("Identifier"), value: id, mono: true)) }
            signing.append(Row(title: L("Team ID"), value: sig.teamID ?? L("None"), mono: sig.teamID != nil))
            let kind = sig.adhoc ? L("Ad-hoc") : (sig.hasCMS ? L("Certificate") : L("Unsigned blob"))
            signing.append(Row(title: L("Signature"), value: kind))
            if let hash = sig.hashType { signing.append(Row(title: L("Hash"), value: "\(hash) · \(LF("%d pages", sig.pageCount))")) }
            if let xml = sig.entitlements {
                let name = Paths.name(path)
                signing.append(Row(title: L("Show Entitlements"), value: nil, action: { [weak self] in
                    self?.navigationController?.pushViewController(TextEditorViewController(title: LF("%@ Entitlements", name), text: xml), animated: true)
                }))
            } else if s.signature?.derEntitlementsSize == nil {
                signing.append(Row(title: L("Entitlements"), value: L("None")))
            }
            if let der = sig.derEntitlementsSize {
                signing.append(Row(title: L("DER Entitlements"), value: Format.bytes(Int64(der))))
            }
        } else {
            signing.append(Row(title: L("Signature"), value: L("Not signed")))
        }
        result.append(Section(title: L("Code Signature"), rows: signing))

        if let install = s.installName {
            result.append(Section(title: L("Install Name"), rows: [Row(title: install, value: nil, mono: true)]))
        }
        if !s.dylibs.isEmpty {
            result.append(Section(title: LF("Linked Libraries (%d)", s.dylibs.count),
                                  rows: s.dylibs.map { Row(title: $0.name, value: $0.tag, mono: true) }))
        }
        if !s.rpaths.isEmpty {
            result.append(Section(title: L("Run Paths"), rows: s.rpaths.map { Row(title: $0, value: nil, mono: true) }))
        }
        result.append(Section(title: L("Load Commands"), rows: s.commandCounts.map { Row(title: $0.0, value: "\($0.1)", mono: true) }))
        sections = result
        tableView.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c: UIListContentConfiguration
        if row.action != nil {
            c = UIListContentConfiguration.cell()
            c.text = row.title
            c.textProperties.color = Theme.accent
            cell.accessoryType = .disclosureIndicator
        } else if row.value == nil || row.title.hasPrefix("/") || row.title.hasPrefix("@") {
            c = UIListContentConfiguration.subtitleCell()
            c.text = row.title
            c.secondaryText = row.value
            c.textProperties.font = row.mono ? Theme.mono(13) : .preferredFont(forTextStyle: .body)
            c.textProperties.numberOfLines = 0
            c.secondaryTextProperties.color = .secondaryLabel
        } else {
            c = UIListContentConfiguration.valueCell()
            c.text = row.title
            c.secondaryText = row.value
            c.secondaryTextProperties.font = row.mono ? Theme.mono(13) : .preferredFont(forTextStyle: .body)
            c.secondaryTextProperties.numberOfLines = 0
        }
        cell.contentConfiguration = c
        cell.selectionStyle = row.action == nil ? .none : .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        sections[indexPath.section].rows[indexPath.row].action?()
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let row = sections[indexPath.section].rows[indexPath.row]
        let text = row.value.map { row.title.hasPrefix("/") || row.title.hasPrefix("@") ? row.title : $0 } ?? row.title
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: L("Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }])
        }
    }
}
