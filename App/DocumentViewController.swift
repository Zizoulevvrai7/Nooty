import NootyCore
import UIKit

/// Document texte : texte riche (titres, gras, italique, souligné, listes, couleurs), enregistré en RTF.
final class DocumentViewController: UIViewController, UITextViewDelegate, UINavigationItemRenameDelegate {
    private let library: LibraryStore
    private let itemID: UUID
    private let fileURL: URL
    private let textView = UITextView()
    private var pendingSave: DispatchWorkItem?
    private var changed = false

    init(library: LibraryStore, itemID: UUID) throws {
        self.library = library
        self.itemID = itemID
        fileURL = library.notebookDirectory(itemID).appendingPathComponent("document.rtf")
        super.init(nibName: nil, bundle: nil)
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        if !data.isEmpty {
            textView.attributedText = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private var bodyFont: UIFont { .systemFont(ofSize: 17) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.panel
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.style = .editor
        navigationItem.renameDelegate = self
        title = library.index.item(itemID)?.title
        textView.delegate = self
        textView.allowsEditingTextAttributes = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 32, bottom: 80, right: 32)
        textView.typingAttributes = [.font: bodyFont, .foregroundColor: UIColor.label]
        textView.inputAccessoryView = makeBar()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityLabel = L("document.label")
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            textView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            textView.widthAnchor.constraint(equalTo: view.widthAnchor).withPriority(.defaultHigh),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("export.title"), image: UIImage(systemName: "square.and.arrow.up"), primaryAction: nil, menu: UIMenu(children: [
            UIAction(title: L("export.allPDF"), image: UIImage(systemName: "doc.richtext")) { [weak self] _ in self?.exportPDF() },
            UIAction(title: L("export.rtf"), image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.exportRTF() },
            UIAction(title: L("export.nooty"), image: UIImage(systemName: "shippingbox")) { [weak self] _ in self?.exportNooty() },
        ]))
        if textView.attributedText.length == 0 { textView.becomeFirstResponder() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }

    func navigationItem(_: UINavigationItem, didEndRenamingWith title: String) {
        library.mutate { $0.rename(itemID, to: title, now: nowMs()) }
        self.title = library.index.item(itemID)?.title
    }

    // MARK: - Mise en forme

    private func makeBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 600, height: 48))
        func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIBarButtonItem {
            let b = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() })
            b.accessibilityLabel = label
            return b
        }
        let styles = UIMenu(title: L("document.style"), children: [
            UIAction(title: L("document.title")) { [weak self] _ in self?.setParagraph(size: 30, weight: .bold) },
            UIAction(title: L("document.heading")) { [weak self] _ in self?.setParagraph(size: 22, weight: .semibold) },
            UIAction(title: L("document.subheading")) { [weak self] _ in self?.setParagraph(size: 19, weight: .semibold) },
            UIAction(title: L("document.body")) { [weak self] _ in self?.setParagraph(size: 17, weight: .regular) },
        ])
        let colors = UIMenu(title: L("text.color"), children: ["#111111", "#1D2A44", "#C62828", "#2E7D32", "#1565C0", "#C2500F"].compactMap { hex in
            guard let c = RGBA(hex: hex) else { return nil }
            return UIAction(title: ColorNames.name(InkConverter.uiColor(c)), image: TextFormatBar.dot(InkConverter.uiColor(c))) { [weak self] _ in self?.apply(.foregroundColor, InkConverter.uiColor(c)) }
        })
        let fonts = UIMenu(title: L("text.font"), children: FontFamily.Group.allCases.map { group in
            UIMenu(title: group.title, children: FontFamily.available.filter { $0.group == group }.map { family in
                UIAction(title: family.displayName) { [weak self] _ in self?.setFamily(family) }
            })
        })
        bar.items = [
            UIBarButtonItem(title: L("document.style"), menu: styles),
            UIBarButtonItem(image: UIImage(systemName: "textformat"), menu: fonts),
            button("bold", L("text.bold")) { [weak self] in self?.toggleTrait(.traitBold) },
            button("italic", L("text.italic")) { [weak self] in self?.toggleTrait(.traitItalic) },
            button("underline", L("text.underline")) { [weak self] in self?.toggleUnderline() },
            button("list.bullet", L("document.list")) { [weak self] in self?.insertBullet() },
            button("checklist", L("document.checklist")) { [weak self] in self?.insertCheck() },
            UIBarButtonItem(image: UIImage(systemName: "paintpalette"), menu: colors),
            .flexibleSpace(),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.textView.resignFirstResponder() }),
        ]
        return bar
    }

    private var targetRange: NSRange {
        let r = textView.selectedRange
        return r.length > 0 ? r : (textView.text as NSString).paragraphRange(for: r)
    }

    private func edit(_ change: (NSMutableAttributedString, NSRange) -> Void) {
        let range = targetRange
        let text = NSMutableAttributedString(attributedString: textView.attributedText)
        guard range.location + range.length <= text.length else { return }
        let selection = textView.selectedRange
        change(text, range)
        textView.attributedText = text
        textView.selectedRange = selection
        textViewDidChange(textView)
    }

    private func setParagraph(size: CGFloat, weight: UIFont.Weight) {
        if targetRange.length == 0 {
            textView.typingAttributes[.font] = UIFont.systemFont(ofSize: size, weight: weight)
            return
        }
        edit { text, range in text.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: weight), range: range) }
    }

    /// Change la famille de police en gardant taille, gras et italique.
    private func setFamily(_ family: FontFamily) {
        func convert(_ font: UIFont) -> UIFont {
            let traits = font.fontDescriptor.symbolicTraits
            return family.font(size: font.pointSize, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
        }
        if targetRange.length == 0 {
            textView.typingAttributes[.font] = convert((textView.typingAttributes[.font] as? UIFont) ?? bodyFont)
            return
        }
        edit { text, range in
            text.enumerateAttribute(.font, in: range) { value, sub, _ in
                text.addAttribute(.font, value: convert((value as? UIFont) ?? self.bodyFont), range: sub)
            }
        }
    }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard textView.selectedRange.length > 0 else {
            let font = (textView.typingAttributes[.font] as? UIFont) ?? bodyFont
            var traits = font.fontDescriptor.symbolicTraits
            if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
            if let d = font.fontDescriptor.withSymbolicTraits(traits) { textView.typingAttributes[.font] = UIFont(descriptor: d, size: font.pointSize) }
            return
        }
        edit { text, range in
            text.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = (value as? UIFont) ?? bodyFont
                var traits = font.fontDescriptor.symbolicTraits
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                if let d = font.fontDescriptor.withSymbolicTraits(traits) { text.addAttribute(.font, value: UIFont(descriptor: d, size: font.pointSize), range: sub) }
            }
        }
    }

    private func toggleUnderline() {
        edit { text, range in
            let current = text.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            if current == 0 { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            else { text.removeAttribute(.underlineStyle, range: range) }
        }
    }

    private func apply(_ key: NSAttributedString.Key, _ value: Any) {
        if textView.selectedRange.length == 0 {
            textView.typingAttributes[key] = value
            return
        }
        edit { text, range in text.addAttribute(key, value: value, range: range) }
    }

    private func insertPrefix(_ prefix: String) {
        let r = (textView.text as NSString).paragraphRange(for: textView.selectedRange)
        let text = NSMutableAttributedString(attributedString: textView.attributedText)
        text.insert(NSAttributedString(string: prefix, attributes: textView.typingAttributes), at: r.location)
        textView.attributedText = text
        textView.selectedRange = NSRange(location: r.location + (prefix as NSString).length, length: 0)
        textViewDidChange(textView)
    }

    private func insertBullet() { insertPrefix("• ") }
    private func insertCheck() { insertPrefix("☐ ") }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Une liste continue à la ligne suivante.
        guard text == "\n" else { return true }
        let paragraph = (textView.text as NSString).paragraphRange(for: range)
        let line = (textView.text as NSString).substring(with: paragraph).trimmingCharacters(in: .newlines)
        for prefix in ["• ", "☐ ", "☑ "] where line.hasPrefix(prefix) {
            if line == prefix { return true }
            textView.insertText("\n" + (prefix == "☑ " ? "☐ " : prefix))
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        changed = true
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard changed else { return }
        let text = textView.attributedText ?? NSAttributedString()
        do {
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: fileURL, options: .atomic)
            changed = false
            library.mutate { $0.touch(itemID, now: nowMs()) }
            writeThumbnail()
            indexText()
        } catch {
            let alert = UIAlertController(title: L("common.error"), message: L("save.error", error.localizedDescription), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private func pdfData() -> Data {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(textView.viewPrintFormatter(), startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: Page.a4Width, height: Page.a4Height)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 48, dy: 56), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for i in 0..<max(1, renderer.numberOfPages) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private func writeThumbnail() {
        let size = CGSize(width: 336, height: 475)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = textView.attributedText ?? NSAttributedString()
            let scaled = NSMutableAttributedString(attributedString: text)
            scaled.enumerateAttribute(.font, in: NSRange(location: 0, length: scaled.length)) { value, range, _ in
                let f = (value as? UIFont) ?? bodyFont
                scaled.addAttribute(.font, value: f.withSize(f.pointSize * 0.6), range: range)
            }
            scaled.draw(with: CGRect(x: 20, y: 22, width: size.width - 40, height: size.height - 40), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
        try? image.pngData()?.write(to: library.thumbnailURL(itemID), options: .atomic)
    }

    private func indexText() {
        let dir = library.notebookDirectory(itemID)
        guard let data = try? Data(contentsOf: NotebookStore.manifestURL(dir)), let manifest = try? NotebookCodec.decode(data), let page = manifest.pages.first else { return }
        let index = NotebookTextIndex(pages: [page.id: textView.text ?? ""])
        try? index.encoded().write(to: NotebookStore.indexURL(dir), options: .atomic)
    }

    private func shareFile(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(vc, animated: true)
    }

    private var baseName: String { LibraryStore.safeFileName(library.index.item(itemID)?.title ?? "Nooty") }

    private func exportPDF() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(baseName + ".pdf")
        try? pdfData().write(to: url, options: .atomic)
        shareFile(url)
    }

    private func exportRTF() {
        saveNow()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(baseName + ".rtf")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: fileURL, to: url)
        shareFile(url)
    }

    private func exportNooty() {
        saveNow()
        do { shareFile(try library.exportNooty(itemID)) } catch {}
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
