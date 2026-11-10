import NootyCore
import PencilKit
import UIKit

/// Éditeur d'un carnet : toutes les pages défilent sur une surface d'écriture continue.
final class NotebookViewController: UIViewController, PKCanvasViewDelegate, UIColorPickerViewControllerDelegate, UINavigationItemRenameDelegate {
    private let library: LibraryStore
    private let itemID: UUID
    private let store: NotebookStore
    private var manifest: NotebookManifest
    private var layout: PageLayout

    private let canvas = PKCanvasView()
    private let pagesView = PagesBackgroundView()
    private let toolStrip: ToolStripView
    private let pageLabel = PaddedLabel()
    private var undoItem: UIBarButtonItem!
    private var redoItem: UIBarButtonItem!

    private var tools: ToolState
    private var editingColorIndex: Int?
    private var fingerDraws: Bool {
        get { UserDefaults.standard.bool(forKey: "nooty.fingerDraws") }
        set { UserDefaults.standard.set(newValue, forKey: "nooty.fingerDraws") }
    }

    private var pendingSave: DispatchWorkItem?
    /// Incrémenté à chaque modification ; une sauvegarde qui le rattrape signifie « tout est enregistré ».
    private var changeGeneration = 0
    private var savedGeneration = 0
    private var contentChanged = false
    private var isApplyingDrawing = false
    private var didInitialLayout = false
    private var didAppear = false
    private var damagedPages = 0

    init(library: LibraryStore, itemID: UUID) throws {
        self.library = library
        self.itemID = itemID
        let opened = try NotebookStore.open(directory: library.notebookDirectory(itemID))
        store = opened.store
        manifest = opened.manifest
        layout = PageLayout(pages: opened.manifest.pages)
        damagedPages = opened.damagedPages
        let initialTools = ToolState.load()
        tools = initialTools
        toolStrip = ToolStripView(state: initialTools)
        super.init(nibName: nil, bundle: nil)

        isApplyingDrawing = true
        canvas.drawing = InkConverter.drawing(layout.place(opened.pages))
        isApplyingDrawing = false
        let drawing = canvas.drawing
        let current = manifest
        store.queue.async { [store] in store.prime(drawing: drawing, manifest: current) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    // MARK: - Cycle de vie

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.desk
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.style = .editor
        navigationItem.renameDelegate = self
        title = library.index.item(itemID)?.title

        pagesView.frame = view.bounds
        pagesView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pagesView)

        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Le papier reste clair en mode sombre : l'encre n'est pas inversée.
        canvas.overrideUserInterfaceStyle = .light
        canvas.minimumZoomScale = 0.3
        canvas.maximumZoomScale = 6
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsHorizontalScrollIndicator = false
        canvas.accessibilityLabel = L("canvas.label")
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvas)
        applyTool()
        applyInputPolicy()

        toolStrip.translatesAutoresizingMaskIntoConstraints = false
        toolStrip.onChange = { [weak self] state in
            self?.tools = state
            state.save()
            self?.applyTool()
        }
        toolStrip.onEditColor = { [weak self] index, color in self?.editColor(at: index, current: color) }
        view.addSubview(toolStrip)

        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = .preferredFont(forTextStyle: .footnote)
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textColor = Theme.secondaryText
        pageLabel.backgroundColor = Theme.panel
        pageLabel.layer.cornerRadius = 12
        pageLabel.layer.masksToBounds = true
        pageLabel.layer.borderWidth = 1
        pageLabel.layer.borderColor = Theme.hairline.cgColor
        view.addSubview(pageLabel)

        let guide = view.safeAreaLayoutGuide
        let preferredWidth = toolStrip.widthAnchor.constraint(equalToConstant: 760)
        preferredWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            toolStrip.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            toolStrip.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            toolStrip.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 10),
            toolStrip.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -10),
            preferredWidth,
            pageLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            pageLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
        ])

        undoItem = UIBarButtonItem(title: L("action.undo"), image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
            self?.canvas.undoManager?.undo()
            self?.refreshUndoButtons()
        })
        redoItem = UIBarButtonItem(title: L("action.redo"), image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak self] _ in
            self?.canvas.undoManager?.redo()
            self?.refreshUndoButtons()
        })
        let addPage = UIBarButtonItem(title: L("page.add"), image: UIImage(systemName: "doc.badge.plus"), primaryAction: nil, menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.addPageActions() ?? []) },
        ]))
        let more = UIBarButtonItem(title: L("action.more"), image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreActions() ?? []) },
        ]))
        navigationItem.rightBarButtonItems = [more, addPage, redoItem, undoItem]

        pagesView.setPages(manifest.pages, layout: layout)
        refreshUndoButtons()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(flushForBackground), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(flushForBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.becomeFirstResponder()
        guard !didAppear else { return }
        didAppear = true
        // L'ouverture du carnet ne doit pas pouvoir être annulée.
        canvas.undoManager?.removeAllActions()
        refreshUndoButtons()
        if damagedPages > 0 {
            let alert = UIAlertController(title: L("common.error"), message: L("notebook.damaged", damagedPages), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent else { return }
        manifest.lastPageIndex = currentPageIndex()
        let hadChanges = contentChanged
        saveNow(wait: true)
        if hadChanges || !FileManager.default.fileExists(atPath: library.thumbnailURL(itemID).path) {
            if let image = makeThumbnail() { store.queue.sync { store.writeThumbnail(image) } }
        }
        if hadChanges { library.mutate { $0.touch(itemID, now: nowMs()) } }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didInitialLayout, view.bounds.width > 0 {
            didInitialLayout = true
            fitWidth()
            scrollToPage(manifest.lastPageIndex, animated: false)
        }
        updateInsets()
        syncBackground()
    }

    // MARK: - Outils

    private func applyTool() {
        canvas.tool = tools.pkTool
    }

    private func applyInputPolicy() {
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
    }

    private func editColor(at index: Int, current: UIColor) {
        editingColorIndex = index
        let picker = UIColorPickerViewController()
        picker.selectedColor = current
        picker.supportsAlpha = false
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = toolStrip
        picker.popoverPresentationController?.sourceRect = toolStrip.bounds
        present(picker, animated: true)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !continuously, let index = editingColorIndex else { return }
        var rgba = InkConverter.rgba(color)
        rgba.a = 1
        tools.setColor(String(rgba.hex.prefix(7)), at: index)
        tools.save()
        toolStrip.state = tools
        applyTool()
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        editingColorIndex = nil
    }

    private func refreshUndoButtons() {
        undoItem?.isEnabled = canvas.undoManager?.canUndo ?? false
        redoItem?.isEnabled = canvas.undoManager?.canRedo ?? false
    }

    // MARK: - Renommage

    func navigationItem(_: UINavigationItem, didEndRenamingWith title: String) {
        library.mutate { $0.rename(itemID, to: title, now: nowMs()) }
        self.title = library.index.item(itemID)?.title
    }

    // MARK: - Disposition et défilement

    private func updateContentSize() {
        canvas.contentSize = CGSize(width: CGFloat(layout.width) * canvas.zoomScale, height: CGFloat(layout.height) * canvas.zoomScale)
    }

    private func updateInsets() {
        let horizontal = max(12, (canvas.bounds.width - canvas.contentSize.width) / 2)
        let inset = UIEdgeInsets(
            top: view.safeAreaInsets.top + 58 + 20, left: horizontal,
            bottom: view.safeAreaInsets.bottom + 80, right: horizontal
        )
        if canvas.contentInset != inset { canvas.contentInset = inset }
    }

    private func fitWidth() {
        guard layout.width > 0 else { return }
        let target = (view.bounds.width - 24) / CGFloat(layout.width)
        canvas.setZoomScale(min(canvas.maximumZoomScale, max(canvas.minimumZoomScale, target)), animated: false)
        updateContentSize()
        updateInsets()
        syncBackground()
    }

    private func syncBackground() {
        pagesView.place(origin: CGPoint(x: -canvas.contentOffset.x, y: -canvas.contentOffset.y), scale: canvas.zoomScale)
        let index = currentPageIndex()
        let text = L("page.position", index + 1, manifest.pages.count)
        if pageLabel.text != text { pageLabel.text = text }
    }

    /// Page située au milieu de l'écran.
    private func currentPageIndex() -> Int {
        let middle = (canvas.contentOffset.y + canvas.bounds.height / 2) / max(canvas.zoomScale, 0.01)
        return layout.pageIndex(atY: middle)
    }

    private func scrollToPage(_ index: Int, animated: Bool) {
        guard layout.frames.indices.contains(index) else { return }
        let y = CGFloat(layout.frames[index].y) * canvas.zoomScale - canvas.contentInset.top
        let maxY = max(-canvas.contentInset.top, canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height)
        canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: min(max(y, -canvas.contentInset.top), maxY)), animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncBackground()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentSize()
        updateInsets()
        syncBackground()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        refreshUndoButtons()
        guard !isApplyingDrawing else { return }
        markChanged()
    }

    // MARK: - Pages

    /// Modifie la liste des pages. Les traits suivent leur page ; l'historique d'annulation est
    /// vidé, car il porte sur des positions qui n'existent plus.
    private func restructure(_ change: (inout [PageInfo], inout [[Stroke]]) -> Void) {
        var pages = layout.split(canvas.drawing.strokes.map { InkConverter.stroke(from: $0) })
        var infos = manifest.pages
        change(&infos, &pages)
        guard !infos.isEmpty, infos.count == pages.count else { return }
        manifest.pages = infos
        layout = PageLayout(pages: infos)
        isApplyingDrawing = true
        canvas.drawing = InkConverter.drawing(layout.place(pages))
        isApplyingDrawing = false
        canvas.undoManager?.removeAllActions()
        pagesView.setPages(manifest.pages, layout: layout)
        updateContentSize()
        updateInsets()
        syncBackground()
        refreshUndoButtons()
        markChanged()
    }

    private func addPage(at index: Int) {
        guard manifest.pages.count < NotebookManifest.maxPages else { return }
        let model = manifest.pages[min(max(0, currentPageIndex()), manifest.pages.count - 1)]
        let page = PageInfo(width: model.width, height: model.height, background: model.background)
        restructure { infos, pages in
            let at = min(max(0, index), infos.count)
            infos.insert(page, at: at)
            pages.insert([], at: at)
        }
        view.layoutIfNeeded()
        scrollToPage(min(index, manifest.pages.count - 1), animated: true)
    }

    private func addPageActions() -> [UIMenuElement] {
        let current = currentPageIndex()
        return [
            UIAction(title: L("page.addAfter"), image: UIImage(systemName: "arrow.down.doc")) { [weak self] _ in self?.addPage(at: current + 1) },
            UIAction(title: L("page.addBefore"), image: UIImage(systemName: "arrow.up.doc")) { [weak self] _ in self?.addPage(at: current) },
            UIAction(title: L("page.addLast"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                guard let self else { return }
                self.addPage(at: self.manifest.pages.count)
            },
        ]
    }

    private func setTemplate(_ kind: BackgroundKind) {
        let index = currentPageIndex()
        guard manifest.pages.indices.contains(index) else { return }
        let old = manifest.pages[index].background
        var next = Background.standard(kind)
        next.color = old.color
        guard next != old else { return }
        manifest.pages[index].background = next
        pagesView.setPages(manifest.pages, layout: layout)
        markChanged()
    }

    private func confirmDeletePage() {
        let index = currentPageIndex()
        guard manifest.pages.count > 1 else { return }
        let alert = UIAlertController(title: L("page.deleteTitle", index + 1), message: L("page.deleteMessage"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("common.delete"), style: .destructive) { [weak self] _ in
            self?.restructure { infos, pages in
                guard infos.indices.contains(index), infos.count > 1 else { return }
                infos.remove(at: index)
                pages.remove(at: index)
            }
        })
        present(alert, animated: true)
    }

    private func moreActions() -> [UIMenuElement] {
        let index = currentPageIndex()
        let currentKind = manifest.pages.indices.contains(index) ? manifest.pages[index].background.kind : .blank
        let templates = UIMenu(title: L("page.template"), image: UIImage(systemName: "doc.plaintext"), options: .singleSelection, children: NewNotebookViewController.templates.map { kind, key in
            UIAction(title: L(key), state: kind == currentKind ? .on : .off) { [weak self] _ in self?.setTemplate(kind) }
        })
        let delete = UIAction(
            title: L("page.delete"), image: UIImage(systemName: "trash"),
            attributes: manifest.pages.count > 1 ? .destructive : [.destructive, .disabled]
        ) { [weak self] _ in self?.confirmDeletePage() }
        let finger = UIAction(title: L("action.fingerDraws"), image: UIImage(systemName: "hand.draw"), state: fingerDraws ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.fingerDraws.toggle()
            self.applyInputPolicy()
        }
        let fit = UIAction(title: L("action.fit"), image: UIImage(systemName: "arrow.left.and.right")) { [weak self] _ in self?.fitWidth() }
        return [
            UIMenu(options: .displayInline, children: [templates, delete]),
            UIMenu(options: .displayInline, children: [fit, finger]),
        ]
    }

    // MARK: - Enregistrement

    private func markChanged() {
        changeGeneration += 1
        contentChanged = true
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow(wait: false) }
        pendingSave = item
        // Court délai : regroupe les modifications rapprochées sans laisser une action longtemps non enregistrée.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func saveNow(wait: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        guard savedGeneration < changeGeneration || manifest.lastPageIndex != lastSavedPageIndex else { return }
        let drawing = canvas.drawing
        let generation = changeGeneration
        var snapshot = manifest
        snapshot.updatedAt = nowMs()
        lastSavedPageIndex = manifest.lastPageIndex
        let store = store
        let work = {
            let outcome = Result { try store.save(drawing: drawing, manifest: snapshot) }
            DispatchQueue.main.async { [weak self] in self?.finishSave(outcome, generation: generation) }
        }
        if wait { store.queue.sync(execute: work) } else { store.queue.async(execute: work) }
    }

    private lazy var lastSavedPageIndex = manifest.lastPageIndex

    private func finishSave(_ outcome: Result<NotebookStore.SaveResult, Error>, generation: Int) {
        switch outcome {
        case .success:
            savedGeneration = max(savedGeneration, generation)
            if saveErrorShown {
                saveErrorShown = false
                pageLabel.textColor = Theme.secondaryText
            }
        case let .failure(error):
            pageLabel.textColor = .systemRed
            guard !saveErrorShown, presentedViewController == nil, view.window != nil else { return }
            saveErrorShown = true
            let alert = UIAlertController(title: L("common.error"), message: L("save.error", error.localizedDescription), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private var saveErrorShown = false

    @objc private func flushForBackground() {
        guard pendingSave != nil || savedGeneration < changeGeneration else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "nooty.save")
        saveNow(wait: true)
        UIApplication.shared.endBackgroundTask(task)
    }

    // MARK: - Miniature

    private func makeThumbnail() -> UIImage? {
        guard let frame = layout.frames.first, let info = manifest.pages.first, frame.width > 0 else { return nil }
        let width: CGFloat = 336
        let scale = width / CGFloat(frame.width)
        let size = CGSize(width: width, height: (CGFloat(frame.height) * scale).rounded())
        let pageRect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        var ink: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = canvas.drawing.image(from: pageRect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            PaperRenderer.draw(info.background, pageRect: rect, scale: scale, clip: rect, in: context.cgContext)
            ink?.draw(in: rect)
        }
    }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}
