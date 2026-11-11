import NootyCore
import UIKit
import Vision

/// Reconnaissance de l'écriture par Vision, sur l'appareil, sans connexion.
/// La qualité dépend de l'écriture ; le résultat est toujours présenté avant d'être utilisé.
enum HandwritingRecognizer {
    static func recognize(_ image: UIImage) -> String {
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let preferred = ["fr-FR", "en-US"]
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = preferred.filter(supported.contains)
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).sorted {
            // Lecture de haut en bas (le repère de Vision a son origine en bas).
            let a = $0.boundingBox, b = $1.boundingBox
            return abs(a.midY - b.midY) > 0.01 ? a.midY > b.midY : a.minX < b.minX
        }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// Texte reconnu, modifiable, à copier ou à insérer dans la page.
final class RecognizedTextViewController: UIViewController {
    private let textView = UITextView()
    private let text: String
    private let onInsert: (String) -> Void

    init(text: String, onInsert: @escaping (String) -> Void) {
        self.text = text
        self.onInsert = onInsert
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("ocr.convert")
        view.backgroundColor = Theme.panel
        textView.text = text.isEmpty ? "" : text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        let note = UILabel()
        note.text = text.isEmpty ? L("ocr.nothing") : L("ocr.note")
        note.numberOfLines = 0
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = Theme.secondaryText
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: L("ocr.insert"), primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                let t = self.textView.text ?? ""
                self.dismiss(animated: true) { if !t.isEmpty { self.onInsert(t) } }
            }),
            UIBarButtonItem(title: L("ocr.copy"), primaryAction: UIAction { [weak self] _ in
                UIPasteboard.general.string = self?.textView.text
            }),
        ]
    }
}

/// Recherche dans le bloc-notes : texte saisi, texte des PDF, écriture reconnue et transcriptions.
final class NotebookSearchViewController: UITableViewController, UISearchBarDelegate {
    private weak var editor: NotebookViewController?
    private let search = UISearchBar()
    private var index = NotebookTextIndex()
    private var hits: [NotebookTextIndex.Hit] = []
    private var indexing = false

    init(editor: NotebookViewController) {
        self.editor = editor
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("search.title")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        search.placeholder = L("search.placeholder")
        search.delegate = self
        search.sizeToFit()
        tableView.tableHeaderView = search
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "hit")
        loadIndex()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.becomeFirstResponder()
    }

    private func loadIndex() {
        guard let editor else { return }
        index = editor.store.loadIndex()
        // Le texte saisi est toujours à jour ; l'écriture reconnue l'est après indexation.
        for (i, info) in editor.manifest.pages.enumerated() {
            let immediate = editor.immediateText(page: i)
            let old = index.pages[info.id] ?? ""
            if !old.contains(immediate) { index.pages[info.id] = [immediate, old].joined(separator: "\n") }
        }
        if !indexing {
            indexing = true
            navigationItem.prompt = L("search.indexing")
            editor.rebuildIndex { [weak self] in
                guard let self, let editor = self.editor else { return }
                self.index = editor.store.loadIndex()
                self.navigationItem.prompt = nil
                self.refresh()
            }
        }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        refresh()
    }

    private func refresh() {
        guard let editor else { return }
        hits = index.search(search.text ?? "", pageOrder: editor.manifest.pages.map(\.id), recordingOrder: editor.manifest.recordings.map(\.id))
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        hits.isEmpty && !(search.text ?? "").isEmpty ? 1 : hits.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "hit", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if hits.isEmpty {
            content.text = L("search.noResult")
            cell.selectionStyle = .none
        } else {
            let hit = hits[indexPath.row]
            if let page = hit.pageIndex {
                content.text = L("page.number", page + 1)
                content.image = UIImage(systemName: "doc.text")
            } else {
                content.text = editor?.manifest.recordings.first { $0.id == hit.recordingID }?.title ?? L("audio.title")
                content.image = UIImage(systemName: "waveform")
            }
            content.secondaryText = hit.snippet
            content.secondaryTextProperties.numberOfLines = 3
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !hits.isEmpty else { return }
        let hit = hits[indexPath.row]
        dismiss(animated: true) { [weak editor] in
            if let page = hit.pageIndex { editor?.scrollToPage(page, animated: true) }
            if let id = hit.recordingID { editor?.audioController?.openRecording(id, query: nil) }
        }
    }
}
