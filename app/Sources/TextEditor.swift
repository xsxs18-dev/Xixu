import UIKit

/// Plain text editor with atomic saves through the helper.
final class TextEditorViewController: UIViewController, UITextViewDelegate {
    private static let maxSize: Int64 = 16 << 20

    private let path: String?
    private let fixedText: String?
    private let textView = UITextView()
    private let titleView: TitleView
    private var encoding: String.Encoding = .utf8
    private var encodingName = "UTF-8"
    private var hasBOM = false
    private var loaded = false
    private var readOnly: Bool
    private var dirty = false {
        didSet {
            isModalInPresentation = dirty
            updateItems()
        }
    }

    init(path: String) {
        self.path = path
        fixedText = nil
        readOnly = false
        titleView = TitleView(title: Paths.name(path), subtitle: nil)
        super.init(nibName: nil, bundle: nil)
        title = Paths.name(path)
    }

    init(title: String, text: String) {
        path = nil
        fixedText = text
        readOnly = true
        titleView = TitleView(title: title, subtitle: nil)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.titleView = titleView
        navigationItem.largeTitleDisplayMode = .never

        textView.font = Theme.mono(Prefs.editorFontSize)
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 32, right: 10)
        textView.delegate = self
        textView.isEditable = false
        if #available(iOS 16.0, *) { textView.isFindInteractionEnabled = true }
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.close()
        })
        updateItems()
        load()
    }

    // MARK: - Loading

    private func load() {
        guard let path = path else {
            textView.text = fixedText
            loaded = true
            updateSubtitle()
            return
        }
        textView.text = ""
        let spinner = EmptyStateView(title: nil, loading: true)
        spinner.frame = view.bounds
        spinner.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(spinner)
        Task { @MainActor in
            defer { spinner.removeFromSuperview() }
            do {
                let info = try await FS.shared.stat(path)
                if info.entry.size > Self.maxSize {
                    self.offerHex()
                    return
                }
                let data = try await FS.shared.read(path)
                self.apply(data)
            } catch {
                self.showError(error, title: L("Can't Open File"))
            }
        }
    }

    private func apply(_ data: Data) {
        let bytes = [UInt8](data.prefix(3))
        var text: String?
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            text = String(data: data.dropFirst(3), encoding: .utf8)
            hasBOM = true
            encoding = .utf8
            encodingName = "UTF-8"
        } else if bytes.count >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF)) {
            text = String(data: data, encoding: .utf16)
            encoding = .utf16
            encodingName = "UTF-16"
        }
        if text == nil, let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
            encoding = .utf8
            encodingName = "UTF-8"
        }
        if text == nil, let latin = String(data: data, encoding: .isoLatin1) {
            text = latin
            encoding = .isoLatin1
            encodingName = "Latin-1"
        }
        textView.text = text ?? String(decoding: data, as: UTF8.self)
        loaded = true
        textView.isEditable = !readOnly
        updateSubtitle()
        updateItems()
    }

    private func offerHex() {
        guard let path = path else { return }
        let alert = UIAlertController(title: L("File Too Large"),
                                      message: L("Files over 16 MB can't be edited as text. Open it in the hex viewer instead?"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { [weak self] _ in self?.dismiss(animated: true) })
        alert.addAction(UIAlertAction(title: L("Hex Viewer"), style: .default) { [weak self] _ in
            guard let presenter = self?.presentingViewController else { return }
            self?.dismiss(animated: true) {
                presenter.presentModal(HexViewController(path: path), fullScreen: true)
            }
        })
        present(alert, animated: true)
    }

    private func updateSubtitle() {
        let lines = textView.text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        var parts: [String] = []
        if path != nil { parts.append(encodingName) }
        parts.append(lines == 1 ? L("1 line") : LF("%d lines", lines))
        if readOnly && path != nil { parts.append(L("Read Only")) }
        titleView.subtitle.text = parts.joined(separator: " · ")
    }

    // MARK: - Bar items

    private func updateItems() {
        let menu = UIBarButtonItem(title: L("More"), image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil,
                                   menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
                                       done(self?.menuElements() ?? [])
                                   }]))
        if path == nil {
            let copy = UIBarButtonItem(title: L("Copy All"), primaryAction: UIAction { [weak self] _ in
                UIPasteboard.general.string = self?.textView.text
                Haptics.tap()
                RootController.shared?.toast(L("Copied"))
            })
            navigationItem.rightBarButtonItems = [menu, copy]
            return
        }
        let save = UIBarButtonItem(title: L("Save"), primaryAction: UIAction { [weak self] _ in self?.save() })
        save.style = .done
        save.isEnabled = dirty && loaded
        navigationItem.rightBarButtonItems = [save, menu]
    }

    private func menuElements() -> [UIMenuElement] {
        var tools: [UIMenuElement] = []
        if #available(iOS 16.0, *) {
            tools.append(UIAction(title: L("Find"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                guard let self = self else { return }
                self.textView.findInteraction?.presentFindNavigator(showingReplace: !self.readOnly)
            })
        }
        tools.append(UIAction(title: L("Go to Line…"), image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in
            self?.goToLine()
        })
        let size: [UIMenuElement] = [
            UIAction(title: L("Larger Text"), image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in self?.changeFont(1) },
            UIAction(title: L("Smaller Text"), image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in self?.changeFont(-1) },
        ]
        var file: [UIMenuElement] = [
            UIAction(title: L("Copy All"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = self?.textView.text
                RootController.shared?.toast(L("Copied"))
            },
        ]
        if let path = path {
            file.append(UIAction(title: L("Read Only"), image: UIImage(systemName: "lock"), state: readOnly ? .on : .off) { [weak self] _ in
                guard let self = self else { return }
                self.readOnly.toggle()
                self.textView.isEditable = !self.readOnly && self.loaded
                self.updateSubtitle()
            })
            file.append(UIAction(title: L("Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self = self else { return }
                Ops.share([path], from: self, source: self.navigationItem.rightBarButtonItems?.last)
            })
        }
        return [
            UIMenu(options: .displayInline, children: tools),
            UIMenu(options: .displayInline, children: size),
            UIMenu(options: .displayInline, children: file),
        ]
    }

    private func changeFont(_ delta: CGFloat) {
        let size = min(max(Prefs.editorFontSize + delta, 9), 28)
        Prefs.editorFontSize = size
        textView.font = Theme.mono(size)
    }

    private func goToLine() {
        prompt(title: L("Go to Line"), placeholder: L("Line number"), action: L("Go"), keyboard: .numberPad) { [weak self] value in
            guard let self = self, let line = Int(value), line > 0 else { return }
            let text = self.textView.text as NSString
            var location = 0
            var current = 1
            while current < line && location < text.length {
                let range = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
                if range.location == NSNotFound { break }
                location = range.location + 1
                current += 1
            }
            let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            self.textView.becomeFirstResponder()
            self.textView.selectedRange = NSRange(location: lineRange.location, length: 0)
            self.textView.scrollRangeToVisible(lineRange)
        }
    }

    // MARK: - Editing

    func textViewDidChange(_ textView: UITextView) {
        if !dirty { dirty = true }
    }

    private func save(then completion: (() -> Void)? = nil) {
        guard let path = path, loaded else { return }
        var data = textView.text.data(using: encoding, allowLossyConversion: false)
        if data == nil {
            encoding = .utf8
            encodingName = "UTF-8"
            data = textView.text.data(using: .utf8)
            RootController.shared?.toast(L("Saved as UTF-8"))
        }
        guard var bytes = data else { return }
        if hasBOM && encoding == .utf8 { bytes = Data([0xEF, 0xBB, 0xBF]) + bytes }
        Task { @MainActor in
            do {
                try await FS.shared.write(path, data: bytes)
                self.dirty = false
                self.updateSubtitle()
                Haptics.success()
                RootController.shared?.toast(L("Saved"))
                announceChanges([Paths.parent(path)])
                Ops.refreshAppIfNeeded(after: path)
                completion?()
            } catch {
                self.showError(error, title: L("Can't Save"))
            }
        }
    }

    private func close() {
        guard dirty else {
            dismiss(animated: true)
            return
        }
        let alert = UIAlertController(title: L("Save Changes?"), message: L("Your changes are lost if you don't save them."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Save"), style: .default) { [weak self] _ in
            self?.save { self?.dismiss(animated: true) }
        })
        alert.addAction(UIAlertAction(title: L("Don't Save"), style: .destructive) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        present(alert, animated: true)
    }
}
