import UIKit
import QuickLook
import Darwin

/// The ways a file can be shown. "Open With" offers all of them.
enum Viewer: CaseIterable {
    case text, hex, plist, sqlite, macho, archive, quickLook

    var title: String {
        switch self {
        case .text: return L("Text Editor")
        case .hex: return L("Hex Viewer")
        case .plist: return L("Property List Editor")
        case .sqlite: return L("SQLite Browser")
        case .macho: return L("Mach-O Inspector")
        case .archive: return L("Archive Viewer")
        case .quickLook: return L("Quick Look")
        }
    }

    var symbol: String {
        switch self {
        case .text: return "doc.text"
        case .hex: return "number"
        case .plist: return "list.bullet.indent"
        case .sqlite: return "cylinder.split.1x2"
        case .macho: return "cpu"
        case .archive: return "doc.zipper"
        case .quickLook: return "eye"
        }
    }
}

/// Decides which viewer a file opens in and presents it.
enum Opener {
    fileprivate enum Target {
        case viewer(Viewer)
        case deb
        case info
    }

    static func open(_ item: FileItem, from vc: UIViewController, siblings: [FileItem]) {
        if item.isDirectory {
            RootController.shared?.reveal(item.path)
            return
        }
        Bookmarks.addRecent(item.path)
        if let target = target(for: item.kind) {
            present(target, item: item, from: vc, siblings: siblings)
            return
        }
        Task { @MainActor in
            let target = await sniff(item.path)
            present(target, item: item, from: vc, siblings: siblings)
        }
    }

    static func open(path: String, from vc: UIViewController) {
        Task { @MainActor in
            do {
                let info = try await FS.shared.stat(path)
                let item = FileItem(path: path, entry: info.entry)
                if item.isDirectory {
                    RootController.shared?.reveal(path)
                } else {
                    open(item, from: vc, siblings: [])
                }
            } catch {
                vc.showError(error)
            }
        }
    }

    static func open(_ item: FileItem, with viewer: Viewer, from vc: UIViewController, siblings: [FileItem]) {
        Bookmarks.addRecent(item.path)
        switch viewer {
        case .text:
            vc.presentModal(TextEditorViewController(path: item.path), fullScreen: true)
        case .hex:
            vc.presentModal(HexViewController(path: item.path), fullScreen: true)
        case .plist:
            vc.presentModal(PlistEditorViewController(path: item.path), fullScreen: true)
        case .sqlite:
            vc.presentModal(SQLiteViewController(path: item.path))
        case .macho:
            vc.presentModal(MachOViewController(path: item.path))
        case .archive:
            vc.presentModal(ArchiveViewController(path: item.path))
        case .quickLook:
            quickLook(item, siblings: siblings, from: vc)
        }
    }

    static func openWithMenu(for item: FileItem, from vc: UIViewController, siblings: [FileItem]) -> UIMenu {
        let actions = Viewer.allCases.map { viewer in
            UIAction(title: viewer.title, image: UIImage(systemName: viewer.symbol)) { [weak vc] _ in
                guard let vc = vc else { return }
                open(item, with: viewer, from: vc, siblings: siblings)
            }
        }
        return UIMenu(title: L("Open With"), image: UIImage(systemName: "arrow.up.forward.app"), children: actions)
    }

    // MARK: - Routing

    private static func target(for kind: FileKind) -> Target? {
        switch kind {
        case .image, .video, .audio, .pdf, .document, .font: return .viewer(.quickLook)
        case .text, .code: return .viewer(.text)
        case .plist: return .viewer(.plist)
        case .sqlite: return .viewer(.sqlite)
        case .archive, .ipa: return .viewer(.archive)
        case .deb: return .deb
        case .binary, .dylib: return .viewer(.macho)
        case .special: return .info // sockets, FIFOs and devices would block on read
        case .folder, .app, .package, .other: return nil
        }
    }

    private static func present(_ target: Target, item: FileItem, from vc: UIViewController, siblings: [FileItem]) {
        switch target {
        case .viewer(let viewer):
            open(item, with: viewer, from: vc, siblings: siblings)
        case .deb:
            vc.presentModal(DebViewController(path: item.path))
        case .info:
            vc.presentModal(InfoViewController(path: item.path))
        }
    }

    /// Looks at the first bytes of a file without a telling extension.
    fileprivate static func sniff(_ path: String) async -> Target {
        guard let data = try? await FS.shared.read(path, offset: 0, length: 4096) else { return .viewer(.hex) }
        let b = [UInt8](data)
        func starts(_ prefix: [UInt8]) -> Bool {
            b.count >= prefix.count && Array(b[0..<prefix.count]) == prefix
        }
        func startsText(_ text: String) -> Bool { starts(Array(text.utf8)) }

        if startsText("bplist00") { return .viewer(.plist) }
        if starts(Array("SQLite format 3".utf8) + [0]) { return .viewer(.sqlite) }
        let machMagics: [[UInt8]] = [
            [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE],
            [0xBE, 0xBA, 0xFE, 0xCA], [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],
        ]
        if machMagics.contains(where: starts) { return .viewer(.macho) }
        if startsText("!<arch>\ndebian") { return .deb }
        let archiveMagics: [[UInt8]] = [
            [0x50, 0x4B, 0x03, 0x04], Array("Rar!".utf8), [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
            [0x1F, 0x8B], [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], Array("BZh".utf8), Array("!<arch>\n".utf8),
        ]
        if archiveMagics.contains(where: starts) { return .viewer(.archive) }
        let previewMagics: [[UInt8]] = [
            Array("%PDF".utf8), [0x89, 0x50, 0x4E, 0x47], [0xFF, 0xD8, 0xFF], Array("GIF8".utf8),
        ]
        if previewMagics.contains(where: starts) { return .viewer(.quickLook) }

        if !b.contains(0), let text = decodeUTF8Prefix(data) {
            let head = text.prefix(512)
            if head.contains("<plist") && (head.hasPrefix("<?xml") || head.hasPrefix("<plist") || head.contains("<!DOCTYPE plist")) {
                return .viewer(.plist)
            }
            return .viewer(.text)
        }
        return .viewer(.hex)
    }

    /// UTF-8 check that tolerates a multi-byte character cut off at the end of the sample.
    private static func decodeUTF8Prefix(_ data: Data) -> String? {
        for trim in 0...3 where data.count >= trim {
            if let s = String(data: data.dropLast(trim), encoding: .utf8) { return s }
        }
        return nil
    }

    // MARK: - Quick Look

    private final class Flag { var done = false }

    static func quickLook(_ item: FileItem, siblings: [FileItem], from vc: UIViewController) {
        let flag = Flag()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !flag.done { RootController.shared?.toast(L("Preparing Preview…")) }
        }
        Task { @MainActor in
            do {
                let staged = try await Ops.readableURLs([item.path])
                flag.done = true
                guard let main = staged.first else { return }
                var urls: [URL] = []
                var start = 0
                let others = siblings.filter { !$0.isDirectory && $0.kind.isPreviewable }
                if others.contains(where: { $0.path == item.path }) {
                    for sibling in others {
                        if sibling.path == item.path {
                            start = urls.count
                            urls.append(main)
                        } else if Darwin.access(sibling.path, R_OK) == 0 {
                            urls.append(URL(fileURLWithPath: sibling.path))
                        }
                    }
                } else {
                    urls = [main]
                }
                let preview = PreviewController()
                preview.source = PreviewSource(urls: urls)
                preview.dataSource = preview.source
                preview.delegate = preview.source
                preview.currentPreviewItemIndex = start
                vc.topPresenter.present(preview, animated: true)
            } catch {
                flag.done = true
                vc.showError(error)
            }
        }
    }
}

/// Keeps its data source alive (QLPreviewController only holds it weakly).
private final class PreviewController: QLPreviewController {
    var source: PreviewSource?
}

private final class PreviewSource: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        urls[index] as NSURL
    }

    /// Edits would only land in a staged copy, so Markup is turned off.
    func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
        .disabled
    }
}
