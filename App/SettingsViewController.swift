import NootyCore
import UIKit

enum AppearanceSettings {
    static var style: UIUserInterfaceStyle {
        get { UIUserInterfaceStyle(rawValue: UserDefaults.standard.integer(forKey: "nooty.appearance")) ?? .unspecified }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "nooty.appearance")
            apply()
        }
    }

    static func apply() {
        for scene in UIApplication.shared.connectedScenes {
            (scene as? UIWindowScene)?.windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
}

/// Réglages : apparence, écriture, audio et transcription, IA, stockage, confidentialité, licences.
final class SettingsViewController: UITableViewController, UITextFieldDelegate {
    private let store: LibraryStore
    private enum Section: Int, CaseIterable { case appearance, writing, audio, ai, storage, about }

    init(store: LibraryStore) {
        self.store = store
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("settings.title")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        L("settings.section.\(Section(rawValue: section)!)")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .audio: return L("settings.audioFooter")
        case .ai: return L("settings.aiFooter")
        case .storage: return L("settings.storageFooter")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .appearance: return 1
        case .writing: return 2
        case .audio: return 3
        case .ai: return 4
        case .storage: return 2
        case .about: return 2
        }
    }

    private func toggle(_ cell: UITableViewCell, _ on: Bool, _ change: @escaping (Bool) -> Void) {
        let s = UISwitch()
        s.isOn = on
        s.addAction(UIAction { [weak s] _ in change(s?.isOn ?? false) }, for: .valueChanged)
        cell.accessoryView = s
        cell.selectionStyle = .none
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        cell.accessoryView = nil
        cell.accessoryType = .none
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.appearance, _):
            content.text = L("settings.appearance")
            content.secondaryText = L("settings.appearance.\(AppearanceSettings.style.rawValue)")
            cell.accessoryType = .disclosureIndicator
        case (.writing, 0):
            content.text = L("action.fingerDraws")
            toggle(cell, UserDefaults.standard.bool(forKey: "nooty.fingerDraws")) { UserDefaults.standard.set($0, forKey: "nooty.fingerDraws") }
        case (.writing, _):
            content.text = L("shape.hold")
            var tools = ToolState.load()
            toggle(cell, tools.holdToShape) { tools.holdToShape = $0; tools.save() }
        case (.audio, 0):
            content.text = L("settings.transcription")
            toggle(cell, TranscriptionSettings.enabled) { TranscriptionSettings.enabled = $0 }
        case (.audio, 1):
            content.text = L("settings.transcriptionServer")
            toggle(cell, TranscriptionSettings.allowServer) { TranscriptionSettings.allowServer = $0 }
        case (.audio, _):
            content.text = L("settings.language")
            content.secondaryText = Locale.current.localizedString(forIdentifier: TranscriptionSettings.language) ?? TranscriptionSettings.language
            cell.accessoryType = .disclosureIndicator
        case (.ai, 0):
            content.text = L("settings.aiEnabled")
            toggle(cell, AISettings.enabled) { AISettings.enabled = $0 }
        case (.ai, 1):
            content.text = L("settings.aiKey")
            content.secondaryText = (AISettings.apiKey ?? "").isEmpty ? L("settings.aiKeyNone") : L("settings.aiKeySet")
            cell.accessoryType = .disclosureIndicator
        case (.ai, 2):
            content.text = L("settings.aiModel")
            content.secondaryText = AISettings.model
            cell.accessoryType = .disclosureIndicator
        case (.ai, _):
            content.text = L("settings.aiAsk")
            toggle(cell, AISettings.askEveryTime) { AISettings.askEveryTime = $0 }
        case (.storage, 0):
            content.text = L("settings.storageUsed")
            content.secondaryText = ByteCountFormatter.string(fromByteCount: Self.size(of: store.root), countStyle: .file)
            cell.selectionStyle = .none
        case (.storage, _):
            content.text = L("settings.backup")
            content.textProperties.color = Theme.accent
        case (.about, 0):
            content.text = L("settings.version")
            content.secondaryText = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            cell.selectionStyle = .none
        case (.about, _):
            content.text = L("settings.licenses")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            if let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.appearance, _):
            choose(L("settings.appearance"), [(UIUserInterfaceStyle.unspecified, L("settings.appearance.0")), (.light, L("settings.appearance.1")), (.dark, L("settings.appearance.2"))]) { AppearanceSettings.style = $0 }
        case (.audio, 2):
            choose(L("settings.language"), ["fr-FR", "en-US", "en-GB", "es-ES", "de-DE", "it-IT", "ar-SA"].map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }) { TranscriptionSettings.language = $0 }
        case (.ai, 1):
            prompt(L("settings.aiKey"), message: L("settings.aiKeyMessage"), initial: "", secure: true) { AISettings.apiKey = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        case (.ai, 2):
            prompt(L("settings.aiModel"), message: L("settings.aiModelMessage"), initial: AISettings.model, secure: false) { AISettings.model = $0 }
        case (.storage, 1):
            backupAll()
        case (.about, 1):
            navigationController?.pushViewController(LicensesViewController(), animated: true)
        default:
            break
        }
    }

    private func choose<T>(_ title: String, _ options: [(T, String)], apply: @escaping (T) -> Void) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (value, label) in options {
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                apply(value)
                self?.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = CGRect(x: tableView.bounds.midX, y: 100, width: 1, height: 1)
        present(sheet, animated: true)
    }

    private func prompt(_ title: String, message: String, initial: String, secure: Bool, apply: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initial
            field.isSecureTextEntry = secure
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("common.save"), style: .default) { [weak self, weak alert] _ in
            apply(alert?.textFields?.first?.text ?? "")
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    /// Sauvegarde : un fichier .nooty par document, enregistrés dans un dossier choisi (iCloud Drive, Drive…).
    private func backupAll() {
        var urls: [URL] = []
        for entry in store.index.items where entry.kind.hasFiles && entry.trashedAt == nil {
            if let url = try? store.exportNooty(entry.id) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        present(picker, animated: true)
    }
}

final class LicensesViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("settings.licenses")
        view.backgroundColor = Theme.panel
        let text = UITextView()
        text.isEditable = false
        text.font = .preferredFont(forTextStyle: .body)
        text.text = L("licenses.text")
        text.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: view.topAnchor), text.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor), text.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
