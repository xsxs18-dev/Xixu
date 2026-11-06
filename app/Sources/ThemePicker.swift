import UIKit

/// Four small presets. Xixu keeps the user-selected accent; the others have a fixed palette.
final class ThemePickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let styles = ThemeStyle.allCases

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Theme")
        navigationItem.largeTitleDisplayMode = .never
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        view.addSubview(tableView)
    }

    func numberOfSections(in tableView: UITableView) -> Int { 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { styles.count }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        L("Xixu follows your iPhone's light or dark mode unless a theme chooses its own look.")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let style = styles[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = style.title
        content.secondaryText = style.detail
        content.secondaryTextProperties.numberOfLines = 2
        content.image = Icons.squircle(style.symbol, style.previewColor, size: 36)
        content.imageProperties.reservedLayoutSize = CGSize(width: 36, height: 36)
        cell.contentConfiguration = content
        cell.accessoryType = style == Prefs.themeStyle ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let selected = styles[indexPath.row]
        guard selected != Prefs.themeStyle else { return }
        Prefs.themeStyle = selected
        Haptics.tap()
        tableView.reloadData()
    }
}

private extension ThemeStyle {
    var symbol: String {
        switch self {
        case .xixu: return "sparkles"
        case .ios: return "iphone"
        case .macos: return "desktopcomputer"
        case .linux: return "terminal.fill"
        }
    }

    var previewColor: UIColor {
        switch self {
        case .xixu:
            let i = Prefs.accent
            return Theme.accents.indices.contains(i) ? Theme.accents[i].color : .systemBlue
        case .ios: return .systemBlue
        case .macos: return UIColor(red: 0.04, green: 0.43, blue: 0.91, alpha: 1)
        case .linux: return UIColor(red: 0.91, green: 0.33, blue: 0.13, alpha: 1)
        }
    }
}
