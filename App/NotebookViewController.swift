import NootyCore
import PencilKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Éditeur d'un bloc-notes : toutes les pages défilent sur une surface d'écriture continue.
/// Calques, de bas en haut : papier et fonds importés, images et textes, encre, rubans,
/// dessins éphémères (formes, laser), cadre de sélection.
final class NotebookViewController: UIViewController, PKCanvasViewDelegate, UIColorPickerViewControllerDelegate,
    UINavigationItemRenameDelegate, UIGestureRecognizerDelegate, UITextViewDelegate, PagePanelDataSource {
    let library: LibraryStore
    let itemID: UUID
    let store: NotebookStore
    private(set) var manifest: NotebookManifest
    private(set) var layout: PageLayout
    /// Éléments de chaque page, en repère local de la page.
    private(set) var elements: [PageElements]

    let canvas = PKCanvasView()
    private let pagesView = PagesBackgroundView()
    private let contentLayer = ElementsLayerView(kind: .content)
    private let tapeLayer = ElementsLayerView(kind: .tapes)
    private let sketch = SketchOverlayView()
    private let selection = SelectionOverlayView()
    private let toolStrip: ToolStripView
    private let selectionBar = UIStackView()
    private let pageLabel = UILabel()
    private let pagePill = UIView()
    private let panel = PagePanelView()
    private var panelLeading: NSLayoutConstraint!
    private(set) var tabBar: DocumentTabsView!
    private var undoItem: UIBarButtonItem!
    private var redoItem: UIBarButtonItem!

    private var tools: ToolState
    private var editingColorIndex: Int?
    private var fingerDraws: Bool {
        get { UserDefaults.standard.bool(forKey: "nooty.fingerDraws") }
        set { UserDefaults.standard.set(newValue, forKey: "nooty.fingerDraws") }
    }

    private lazy var toolPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolPan(_:)))
    private lazy var toolTap = UITapGestureRecognizer(target: self, action: #selector(handleToolTap(_:)))

    // Sélection et édition d'éléments
    private var selected: (page: Int, id: UUID)?
    private var gestureSnapshot: [PageElements]?
    private var textEditor: UITextView?
    private var editingText: (page: Int, id: UUID)?

    // Outils à geste
    private var panStart: CGPoint = .zero
    private var panPoints: [CGPoint] = []

    // Enregistrement
    private var pendingSave: DispatchWorkItem?
    private var changeGeneration = 0
    private var savedGeneration = 0
    private var contentChanged = false
    private var isApplyingDrawing = false
    private var didInitialLayout = false
    private var didAppear = false
    private var damagedPages = 0
    private var lastStrokeCount = 0
    private var saveErrorShown = false
    private lazy var lastSavedPageIndex = manifest.lastPageIndex
    private var indexDirty = false

    var audioController: AudioController?
    /// Dessin complet mis de côté pendant la relecture synchronisée avec l'audio.
    private var replayFull: PKDrawing?

    /// Dessin réel du bloc-notes, y compris pendant une relecture.
    var fullDrawing: PKDrawing { replayFull ?? canvas.drawing }

    init(library: LibraryStore, itemID: UUID) throws {
        self.library = library
        self.itemID = itemID
        let opened = try NotebookStore.open(directory: library.notebookDirectory(itemID))
        store = opened.store
        manifest = opened.manifest
        layout = PageLayout(pages: opened.manifest.pages)
        elements = opened.elements
        damagedPages = opened.damagedPages
        let initialTools = ToolState.load()
        tools = initialTools
        toolStrip = ToolStripView(state: initialTools)
        super.init(nibName: nil, bundle: nil)

        isApplyingDrawing = true
        canvas.drawing = InkConverter.drawing(layout.place(opened.pages))
        isApplyingDrawing = false
        lastStrokeCount = canvas.drawing.strokes.count
        let drawing = canvas.drawing
        let current = manifest
        store.queue.async { [store] in store.prime(drawing: drawing, manifest: current) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    var entry: LibraryEntry? { library.index.item(itemID) }

    // MARK: - Cycle de vie

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.desk
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.style = .editor
        navigationItem.renameDelegate = self
        title = entry?.title

        pagesView.resources = store.resourcesDirectory
        contentLayer.resources = store.resourcesDirectory
        tapeLayer.resources = store.resourcesDirectory
        tapeLayer.onTapeTap = { [weak self] page, id in self?.toggleTape(page: page, id: id) }

        for v in [pagesView, contentLayer] as [UIView] {
            v.frame = view.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(v)
        }

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

        for v in [tapeLayer, sketch, selection] as [UIView] {
            v.frame = view.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(v)
        }
        configureSelection()

        toolPan.delegate = self
        toolPan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(toolPan)
        toolTap.delegate = self
        canvas.addGestureRecognizer(toolTap)

        toolStrip.translatesAutoresizingMaskIntoConstraints = false
        toolStrip.onChange = { [weak self] state in
            self?.tools = state
            state.save()
            self?.applyTool()
        }
        toolStrip.onEditColor = { [weak self] index, color, source in self?.editColor(at: index, current: color, source: source) }
        toolStrip.onEditWidth = { [weak self] index, source in self?.editWidth(at: index, source: source) }
        view.addSubview(toolStrip)

        tabBar = DocumentTabsView(library: library, current: itemID)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] id in self?.switchToTab(id) }
        tabBar.onClose = { [weak self] id in self?.closeTab(id) }
        view.addSubview(tabBar)

        selectionBar.axis = .horizontal
        selectionBar.spacing = 2
        selectionBar.isHidden = true
        let barHolder = UIView()
        Theme.style(panel: barHolder, radius: 14)
        barHolder.translatesAutoresizingMaskIntoConstraints = false
        selectionBar.translatesAutoresizingMaskIntoConstraints = false
        barHolder.addSubview(selectionBar)
        view.addSubview(barHolder)
        selectionHolder = barHolder

        // Indicateur de page : une pastille qui contient le texte, dimensionnée par ses contraintes.
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textColor = .white
        pageLabel.text = L("page.position", 1, manifest.pages.count)
        pagePill.translatesAutoresizingMaskIntoConstraints = false
        pagePill.backgroundColor = Theme.ink.withAlphaComponent(0.82)
        pagePill.layer.cornerRadius = 13
        pagePill.layer.cornerCurve = .continuous
        pagePill.addSubview(pageLabel)
        pagePill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(promptGoToPage)))
        pagePill.isAccessibilityElement = true
        pagePill.accessibilityTraits = .button
        pagePill.accessibilityHint = L("page.goToHint")
        view.addSubview(pagePill)

        panel.dataSource = self
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        view.addSubview(panel)

        let guide = view.safeAreaLayoutGuide
        panelLeading = panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -320)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: guide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            toolStrip.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 6),
            toolStrip.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            toolStrip.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 10),
            toolStrip.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -10),
            barHolder.topAnchor.constraint(equalTo: toolStrip.bottomAnchor, constant: 8),
            barHolder.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            selectionBar.topAnchor.constraint(equalTo: barHolder.topAnchor, constant: 4),
            selectionBar.bottomAnchor.constraint(equalTo: barHolder.bottomAnchor, constant: -4),
            selectionBar.leadingAnchor.constraint(equalTo: barHolder.leadingAnchor, constant: 6),
            selectionBar.trailingAnchor.constraint(equalTo: barHolder.trailingAnchor, constant: -6),
            pageLabel.topAnchor.constraint(equalTo: pagePill.topAnchor, constant: 5),
            pageLabel.bottomAnchor.constraint(equalTo: pagePill.bottomAnchor, constant: -5),
            pageLabel.leadingAnchor.constraint(equalTo: pagePill.leadingAnchor, constant: 12),
            pageLabel.trailingAnchor.constraint(equalTo: pagePill.trailingAnchor, constant: -12),
            pagePill.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            pagePill.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: 300),
            panelLeading,
        ])

        undoItem = UIBarButtonItem(title: L("action.undo"), image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
            self?.commitTextEditing()
            self?.canvas.undoManager?.undo()
            self?.refreshUndoButtons()
        })
        redoItem = UIBarButtonItem(title: L("action.redo"), image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak self] _ in
            self?.canvas.undoManager?.redo()
            self?.refreshUndoButtons()
        })
        let panelItem = UIBarButtonItem(title: L("panel.pages"), image: UIImage(systemName: "sidebar.left"), primaryAction: UIAction { [weak self] _ in self?.togglePanel() })
        let searchItem = UIBarButtonItem(title: L("search.title"), image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.presentSearch() })
        let insert = UIBarButtonItem(title: L("insert.title"), image: UIImage(systemName: "plus.circle"), primaryAction: nil, menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.insertActions() ?? []) },
        ]))
        let addPage = UIBarButtonItem(title: L("page.add"), image: UIImage(systemName: "doc.badge.plus"), primaryAction: nil, menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.addPageActions() ?? []) },
        ]))
        let share = UIBarButtonItem(title: L("export.title"), image: UIImage(systemName: "square.and.arrow.up"), primaryAction: nil, menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.exportActions() ?? []) },
        ]))
        let more = UIBarButtonItem(title: L("action.more"), image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreActions() ?? []) },
        ]))
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItems = [panelItem, searchItem]
        navigationItem.rightBarButtonItems = [more, share, addPage, insert, redoItem, undoItem]

        pagesView.setPages(manifest.pages, layout: layout)
        refreshElementLayers()
        applyTool()
        applyInputPolicy()
        refreshUndoButtons()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(flushForBackground), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(flushForBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        library.openTab(itemID)
        audioController = AudioController(editor: self)
    }

    private var selectionHolder: UIView!

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.becomeFirstResponder()
        tabBar.reload()
        guard !didAppear else { return }
        didAppear = true
        // L'ouverture du carnet ne doit pas pouvoir être annulée.
        canvas.undoManager?.removeAllActions()
        refreshUndoButtons()
        if damagedPages > 0 {
            showAlert(L("common.error"), L("notebook.damaged", damagedPages))
        }
        audioController?.attach()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        commitTextEditing()
        guard isMovingFromParent || isBeingDismissed || navigationController?.viewControllers.contains(self) == false else { return }
        closeDocument()
    }

    /// Enregistre tout et met à jour la miniature et l'index de recherche.
    func closeDocument() {
        audioController?.stopAll()
        manifest.lastPageIndex = currentPageIndex()
        let hadChanges = contentChanged
        saveNow(wait: true)
        if hadChanges, let image = makeThumbnail() { store.queue.sync { store.writeThumbnail(image) } }
        if hadChanges {
            library.mutate { $0.touch(itemID, now: nowMs()) }
            let m = manifest, els = elements
            store.queue.async { [store] in store.collectGarbage(manifest: m, elements: els) }
        }
        if hadChanges || indexDirty { rebuildIndex() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didInitialLayout, view.bounds.width > 0 {
            didInitialLayout = true
            fitWidth()
            scrollToPage(manifest.lastPageIndex, animated: false)
        }
        updateInsets()
        syncLayers()
    }

    func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Outils

    private func applyTool() {
        canvas.tool = tools.pkTool
        let custom = !tools.kind.usesInk
        canvas.drawingGestureRecognizer.isEnabled = !custom
        toolPan.isEnabled = [.shape, .tape, .laser].contains(tools.kind)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        toolPan.allowedTouchTypes = fingerDraws ? [pencil, finger] : [pencil]
        // Avec les outils de Nooty, le défilement ne doit jamais prendre le geste du stylet :
        // sinon le geste est annulé et la forme tracée disparaît.
        if custom {
            canvas.panGestureRecognizer.allowedTouchTypes = fingerDraws ? [] : [finger]
            if fingerDraws { canvas.panGestureRecognizer.minimumNumberOfTouches = 2 }
        } else {
            canvas.panGestureRecognizer.minimumNumberOfTouches = 1
        }
        toolTap.allowedTouchTypes = [pencil, finger]
        tapeLayer.tapesInteractive = tools.kind != .tape
        if tools.kind != .lasso && tools.kind != .text { clearSelection() }
        if tools.kind != .text { commitTextEditing() }
    }

    private func applyInputPolicy() {
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        applyTool()
    }

    private func editColor(at index: Int, current: UIColor, source: UIView) {
        editingColorIndex = index
        let picker = UIColorPickerViewController()
        picker.selectedColor = current
        picker.supportsAlpha = false
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = source
        picker.popoverPresentationController?.sourceRect = source.bounds
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

    private func editWidth(at index: Int, source: UIView) {
        let slider = WidthSliderViewController(value: tools.widths[index], range: ToolState.widthRange) { [weak self] value in
            guard let self else { return }
            self.tools.setWidth(value, at: index)
            self.tools.save()
            self.toolStrip.state = self.tools
            self.applyTool()
        }
        slider.modalPresentationStyle = .popover
        slider.popoverPresentationController?.sourceView = source
        slider.popoverPresentationController?.sourceRect = source.bounds
        present(slider, animated: true)
    }

    private func refreshUndoButtons() {
        undoItem?.isEnabled = canvas.undoManager?.canUndo ?? false
        redoItem?.isEnabled = canvas.undoManager?.canRedo ?? false
    }

    // MARK: - Renommage et onglets

    func navigationItem(_: UINavigationItem, didEndRenamingWith title: String) {
        library.mutate { $0.rename(itemID, to: title, now: nowMs()) }
        self.title = entry?.title
        tabBar.reload()
    }

    private func switchToTab(_ id: UUID) {
        guard id != itemID, let nav = navigationController, let target = library.index.item(id) else { return }
        commitTextEditing()
        LibraryViewController.makeEditor(for: target, library: library, from: self) { editor in
            guard let editor else { return }
            self.closeDocument()
            var stack = nav.viewControllers
            stack.removeAll { $0 === self }
            stack.append(editor)
            nav.setViewControllers(stack, animated: false)
        }
    }

    private func closeTab(_ id: UUID) {
        if id == itemID {
            library.closeTab(id)
            navigationController?.popViewController(animated: true)
        } else {
            library.closeTab(id)
            tabBar.reload()
        }
    }

    // MARK: - Disposition et défilement

    private func updateContentSize() {
        canvas.contentSize = CGSize(width: CGFloat(layout.width) * canvas.zoomScale, height: CGFloat(layout.height) * canvas.zoomScale)
    }

    private var topChrome: CGFloat { (tabBar?.isHidden == false ? 40 : 0) + 58 + 20 }

    private func updateInsets() {
        let horizontal = max(12, (canvas.bounds.width - canvas.contentSize.width) / 2)
        let inset = UIEdgeInsets(
            top: view.safeAreaInsets.top + topChrome, left: horizontal,
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
        syncLayers()
    }

    private func syncLayers() {
        let origin = CGPoint(x: -canvas.contentOffset.x, y: -canvas.contentOffset.y)
        pagesView.place(origin: origin, scale: canvas.zoomScale)
        contentLayer.place(offset: canvas.contentOffset, scale: canvas.zoomScale)
        tapeLayer.place(offset: canvas.contentOffset, scale: canvas.zoomScale)
        let index = currentPageIndex()
        let text = L("page.position", index + 1, manifest.pages.count)
        if pageLabel.text != text {
            pageLabel.text = text
            pagePill.accessibilityLabel = text
        }
        updateSelectionBox()
        positionTextEditor()
    }

    /// Page située au milieu de l'écran.
    func currentPageIndex() -> Int {
        let middle = (canvas.contentOffset.y + canvas.bounds.height / 2) / max(canvas.zoomScale, 0.01)
        return layout.pageIndex(atY: Double(middle))
    }

    func scrollToPage(_ index: Int, animated: Bool) {
        guard layout.frames.indices.contains(index) else { return }
        let y = CGFloat(layout.frames[index].y) * canvas.zoomScale - canvas.contentInset.top
        let maxY = max(-canvas.contentInset.top, canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height)
        canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: min(max(y, -canvas.contentInset.top), maxY)), animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncLayers()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentSize()
        updateInsets()
        syncLayers()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        contentLayer.refreshSharpness()
    }

    /// Point de la surface d'écriture (points de page empilés) sous un geste.
    private func surfacePoint(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: canvas)
        return CGPoint(x: p.x / canvas.zoomScale, y: p.y / canvas.zoomScale)
    }

    /// Conversion surface → vue de l'éditeur.
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        canvas.convert(CGPoint(x: p.x * canvas.zoomScale, y: p.y * canvas.zoomScale), to: view)
    }

    private func pageOrigin(_ index: Int) -> CGPoint {
        guard layout.frames.indices.contains(index) else { return .zero }
        return CGPoint(x: layout.frames[index].x, y: layout.frames[index].y)
    }

    // MARK: - Encre

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        refreshUndoButtons()
        guard !isApplyingDrawing else {
            lastStrokeCount = canvas.drawing.strokes.count
            return
        }
        let count = canvas.drawing.strokes.count
        if count == lastStrokeCount + 1, tools.holdToShape, tools.kind == .pen || tools.kind == .pencil, let last = canvas.drawing.strokes.last,
           heldShape(last) != nil {
            lastStrokeCount = count
            // Le remplacement est différé : modifier le dessin pendant que le moteur d'encre
            // enregistre le trait peut être annulé par celui-ci.
            DispatchQueue.main.async { [weak self] in self?.convertHeldStroke(last) }
            return
        }
        lastStrokeCount = count
        audioController?.noteChange()
        markChanged()
    }

    /// Forme reconnue si le stylet est resté immobile à la fin du trait.
    private func heldShape(_ stroke: PKStroke) -> ShapeSpec? {
        let path = stroke.path
        guard path.count >= 8, let lastPoint = path.last else { return nil }
        let end = lastPoint.timeOffset
        var heldFrom = end
        for p in path.reversed() {
            if hypot(p.location.x - lastPoint.location.x, p.location.y - lastPoint.location.y) > 4 { break }
            heldFrom = p.timeOffset
        }
        guard end - heldFrom >= 0.45 else { return nil }
        let pts = path.map { p -> (x: Double, y: Double) in
            let q = p.location.applying(stroke.transform)
            return (Double(q.x), Double(q.y))
        }
        return ShapeRecognizer.recognize(pts)
    }

    /// Dessiner puis maintenir le stylet immobile : le trait est remplacé par la forme reconnue.
    private func convertHeldStroke(_ stroke: PKStroke) {
        guard let spec = heldShape(stroke) else { return }
        var drawing = canvas.drawing
        // Retire précisément le trait maintenu (même graine, même date), où qu'il soit.
        guard let index = drawing.strokes.lastIndex(where: {
            $0.randomSeed == stroke.randomSeed && $0.path.creationDate == stroke.path.creationDate
        }) else { return }
        drawing.strokes.remove(at: index)
        drawing.strokes.append(contentsOf: shapeStrokes(spec, ink: stroke.ink, width: max(1, stroke.path.first?.size.width ?? 2)))
        replaceDrawing(drawing, actionName: L("shape.title"))
    }

    private func shapeStrokes(_ spec: ShapeSpec, ink: PKInk, width: CGFloat) -> [PKStroke] {
        let start = Date()
        return spec.polylines().map { line in
            let points = line.enumerated().map { i, p in
                PKStrokePoint(
                    location: CGPoint(x: p.x, y: p.y), timeOffset: Double(i) * 0.004, size: CGSize(width: width, height: width),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: start), transform: .identity, mask: nil)
        }
    }

    /// Remplace tout le dessin de façon annulable.
    func replaceDrawing(_ drawing: PKDrawing, actionName: String) {
        endReplay()
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceDrawing(old, actionName: actionName)
        }
        canvas.undoManager?.setActionName(actionName)
        isApplyingDrawing = true
        canvas.drawing = drawing
        isApplyingDrawing = false
        lastStrokeCount = drawing.strokes.count
        markChanged()
        refreshUndoButtons()
    }

    // MARK: - Éléments

    private func refreshElementLayers() {
        var hidden = Set<UUID>()
        if let editingText { hidden.insert(editingText.id) }
        contentLayer.update(elements: elements, layout: layout, hidden: hidden)
        tapeLayer.update(elements: elements, layout: layout)
        syncLayers()
    }

    /// Applique une modification d'éléments de façon annulable.
    func setElements(_ new: [PageElements], actionName: String, undoable: Bool = true) {
        let old = gestureSnapshot ?? elements
        gestureSnapshot = nil
        if undoable, old != new {
            canvas.undoManager?.registerUndo(withTarget: self) { target in
                target.setElements(old, actionName: actionName)
            }
            canvas.undoManager?.setActionName(actionName)
        }
        elements = new
        if let s = selected, element(s.page, s.id) == nil { clearSelection() }
        refreshElementLayers()
        markChanged()
        refreshUndoButtons()
    }

    func element(_ page: Int, _ id: UUID) -> PageElement? {
        guard elements.indices.contains(page) else { return nil }
        return elements[page].first { $0.id == id }
    }

    private func updateElement(_ page: Int, _ id: UUID, live: Bool = false, _ change: (inout PageElement) -> Void) {
        guard elements.indices.contains(page), let i = elements[page].firstIndex(where: { $0.id == id }) else { return }
        var copy = elements
        change(&copy[page][i])
        if live {
            if gestureSnapshot == nil { gestureSnapshot = elements }
            elements = copy
            refreshElementLayers()
        } else {
            setElements(copy, actionName: L("element.edit"))
        }
    }

    /// Élément (hors rubans) sous un point de la surface, le plus haut d'abord.
    private func hitElement(at p: CGPoint) -> (page: Int, id: UUID)? {
        let page = layout.pageIndex(atY: Double(p.y))
        guard elements.indices.contains(page) else { return nil }
        let o = pageOrigin(page)
        let local = CGPoint(x: p.x - o.x, y: p.y - o.y)
        for e in elements[page].reversed() where !PageRenderer.isTape(e) {
            let f = e.frame
            let angle: Double
            switch e {
            case let .image(i): angle = i.rotation
            case let .text(t): angle = t.rotation
            case .tape: angle = 0
            }
            let dx = Double(local.x) - f.midX, dy = Double(local.y) - f.midY
            let lx = f.midX + dx * cos(-angle) - dy * sin(-angle), ly = f.midY + dx * sin(-angle) + dy * cos(-angle)
            if f.contains(lx, ly) { return (page, e.id) }
        }
        return nil
    }

    func insertElement(_ e: PageElement, page: Int, select: Bool = true) {
        guard elements.indices.contains(page) else { return }
        var copy = elements
        copy[page].append(e)
        setElements(copy, actionName: L("insert.title"))
        if select { selectElement(page, e.id) }
    }

    /// Rectangle centré dans la partie visible de la page courante.
    private func visibleCenter(on page: Int) -> CGPoint {
        let o = pageOrigin(page)
        let mid = CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / canvas.zoomScale, y: (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale)
        let info = manifest.pages[page]
        return CGPoint(x: min(max(mid.x - o.x, 40), CGFloat(info.width) - 40), y: min(max(mid.y - o.y, 40), CGFloat(info.height) - 40))
    }

    func insertImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.88) ?? image.pngData() else { return }
        do {
            let name = try store.addResource(data, ext: "jpg")
            let page = currentPageIndex()
            let info = manifest.pages[page]
            let width = min(Double(info.width) * 0.6, Double(image.size.width))
            let height = width * Double(image.size.height / max(1, image.size.width))
            let c = visibleCenter(on: page)
            let frame = Rect(x: Double(c.x) - width / 2, y: Double(c.y) - height / 2, width: max(20, width), height: max(20, height))
            insertElement(.image(ImageElement(frame: frame, resource: name)), page: page)
            setTool(.lasso)
        } catch {
            showAlert(L("common.error"), error.localizedDescription)
        }
    }

    func setTool(_ kind: ToolKind) {
        tools.kind = kind
        tools.save()
        toolStrip.state = tools
        applyTool()
    }

    private func insertTextBox(sticky: Bool, at point: CGPoint? = nil) {
        let page = point.map { layout.pageIndex(atY: Double($0.y)) } ?? currentPageIndex()
        let o = pageOrigin(page)
        let local = point.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) } ?? visibleCenter(on: page)
        let size = sticky ? CGSize(width: 180, height: 180) : CGSize(width: 280, height: 44)
        let x = point == nil ? Double(local.x) - Double(size.width) / 2 : Double(local.x)
        let y = point == nil ? Double(local.y) - Double(size.height) / 2 : Double(local.y) - 22
        let element = TextElement(
            frame: Rect(x: x, y: y, width: Double(size.width), height: Double(size.height)),
            fontSize: sticky ? 18 : 17, color: sticky ? .ink : tools.currentRGBA,
            fill: sticky ? RGBA(hex: "#FFE98A") : nil
        )
        insertElement(.text(element), page: page, select: false)
        beginTextEditing(page: page, id: element.id)
    }

    private func toggleTape(page: Int, id: UUID) {
        updateElement(page, id, live: false) { e in
            if case var .tape(t) = e {
                t.revealed.toggle()
                e = .tape(t)
            }
        }
    }

    private func setAllTapes(revealed: Bool) {
        var copy = elements
        for p in copy.indices {
            for i in copy[p].indices {
                if case var .tape(t) = copy[p][i] {
                    t.revealed = revealed
                    copy[p][i] = .tape(t)
                }
            }
        }
        setElements(copy, actionName: L("tape.label"))
    }

    // MARK: - Sélection

    private func configureSelection() {
        selection.onMove = { [weak self] delta in
            guard let self, let s = self.selected else { return }
            let z = Double(self.canvas.zoomScale)
            self.updateElement(s.page, s.id, live: true) { e in
                var f = e.frame
                f.x += Double(delta.x) / z
                f.y += Double(delta.y) / z
                e.frame = f
            }
        }
        selection.onResize = { [weak self] size in
            guard let self, let s = self.selected else { return }
            let z = Double(self.canvas.zoomScale)
            self.updateElement(s.page, s.id, live: true) { e in
                var f = e.frame
                f.width = max(10, Double(size.width) / z)
                f.height = max(10, Double(size.height) / z)
                e.frame = f
            }
        }
        selection.onRotate = { [weak self] angle in
            guard let self, let s = self.selected else { return }
            self.updateElement(s.page, s.id, live: true) { e in
                switch e {
                case var .image(i): i.rotation = Double(angle); e = .image(i)
                case var .text(t): t.rotation = Double(angle); e = .text(t)
                case .tape: break
                }
            }
        }
        selection.onEnd = { [weak self] in
            guard let self, self.gestureSnapshot != nil else { return }
            self.setElements(self.elements, actionName: L("element.edit"))
        }
    }

    private func selectElement(_ page: Int, _ id: UUID) {
        selected = (page, id)
        updateSelectionBox()
        rebuildSelectionBar()
    }

    func clearSelection() {
        selected = nil
        selection.box = .zero
        selectionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        selectionHolder?.isHidden = true
    }

    private func updateSelectionBox() {
        guard let s = selected, let e = element(s.page, s.id) else {
            selection.box = .zero
            return
        }
        let o = pageOrigin(s.page)
        let f = e.frame
        let a = viewPoint(CGPoint(x: o.x + CGFloat(f.x), y: o.y + CGFloat(f.y)))
        let z = canvas.zoomScale
        selection.box = CGRect(x: a.x, y: a.y, width: CGFloat(f.width) * z, height: CGFloat(f.height) * z)
        switch e {
        case let .image(i):
            selection.rotation = CGFloat(i.rotation)
            selection.keepsAspect = true
        case let .text(t):
            selection.rotation = CGFloat(t.rotation)
            selection.keepsAspect = false
        case .tape:
            selection.rotation = 0
            selection.keepsAspect = false
        }
    }

    private func barButton(_ symbol: String, _ label: String, destructive: Bool = false, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        config.baseForegroundColor = destructive ? .systemRed : Theme.text
        let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = label
        b.toolTip = label
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    private func rebuildSelectionBar() {
        selectionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let s = selected, let e = element(s.page, s.id) else {
            selectionHolder.isHidden = true
            return
        }
        selectionHolder.isHidden = false
        if case .text = e {
            selectionBar.addArrangedSubview(barButton("character.cursor.ibeam", L("element.editText")) { [weak self] in
                self?.beginTextEditing(page: s.page, id: s.id)
            })
        }
        if case .image = e {
            selectionBar.addArrangedSubview(barButton("crop", L("element.crop")) { [weak self] in self?.presentCrop(page: s.page, id: s.id) })
            selectionBar.addArrangedSubview(barButton("square.and.arrow.down", L("element.saveToCollection")) { [weak self] in
                self?.saveToCollection(page: s.page, id: s.id)
            })
        }
        selectionBar.addArrangedSubview(barButton("plus.square.on.square", L("item.duplicate")) { [weak self] in self?.duplicateSelected() })
        selectionBar.addArrangedSubview(barButton("square.3.layers.3d.top.filled", L("element.front")) { [weak self] in self?.reorderSelected(toFront: true) })
        selectionBar.addArrangedSubview(barButton("square.3.layers.3d.bottom.filled", L("element.back")) { [weak self] in self?.reorderSelected(toFront: false) })
        selectionBar.addArrangedSubview(barButton("trash", L("common.delete"), destructive: true) { [weak self] in self?.deleteSelected() })
    }

    private func duplicateSelected() {
        guard let s = selected, let e = element(s.page, s.id) else { return }
        var copy = e
        var f = copy.frame
        f.x += 16
        f.y += 16
        switch copy {
        case var .image(i): i.id = UUID(); i.frame = f; copy = .image(i)
        case var .text(t): t.id = UUID(); t.frame = f; copy = .text(t)
        case var .tape(t): t.id = UUID(); t.frame = f; copy = .tape(t)
        }
        insertElement(copy, page: s.page)
    }

    private func reorderSelected(toFront: Bool) {
        guard let s = selected, elements.indices.contains(s.page), let i = elements[s.page].firstIndex(where: { $0.id == s.id }) else { return }
        var copy = elements
        let e = copy[s.page].remove(at: i)
        if toFront { copy[s.page].append(e) } else { copy[s.page].insert(e, at: 0) }
        setElements(copy, actionName: L("element.edit"))
    }

    private func deleteSelected() {
        guard let s = selected else { return }
        var copy = elements
        copy[s.page].removeAll { $0.id == s.id }
        clearSelection()
        setElements(copy, actionName: L("common.delete"))
    }

    private func presentCrop(page: Int, id: UUID) {
        guard case let .image(img)? = element(page, id), let image = ImageCache.shared.image(store.resourceURL(img.resource)) else { return }
        let crop = ImageCropViewController(image: image, crop: img.crop) { [weak self] newCrop in
            self?.updateElement(page, id) { e in
                guard case var .image(i) = e else { return }
                // Le cadre garde sa largeur ; la hauteur suit les nouvelles proportions.
                let old = i.crop ?? Rect(x: 0, y: 0, width: 1, height: 1)
                let ratioOld = old.height / old.width, ratioNew = newCrop.height / newCrop.width
                i.frame.height = max(10, i.frame.height * ratioNew / max(0.0001, ratioOld))
                i.crop = newCrop.width >= 0.999 && newCrop.height >= 0.999 ? nil : newCrop
                e = .image(i)
            }
        }
        let nav = UINavigationController(rootViewController: crop)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func saveToCollection(page: Int, id: UUID) {
        guard case let .image(img)? = element(page, id), let data = try? Data(contentsOf: store.resourceURL(img.resource)) else { return }
        ElementCollection.shared.add(data)
        showAlert(L("collection.title"), L("collection.saved"))
    }

    // MARK: - Gestes des outils de Nooty

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === toolTap
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === toolTap {
            let p = surfacePoint(g)
            if audioController?.isPlaybackMode == true { return true }
            if tools.kind == .text { return true }
            if textEditor != nil { return true }
            return hitElement(at: p) != nil || selected != nil
        }
        return true
    }

    @objc private func handleToolTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let p = surfacePoint(g)
        if let audio = audioController, audio.isPlaybackMode, audio.seek(toStrokeAt: p, in: fullDrawing) { return }
        if textEditor != nil {
            commitTextEditing()
            if tools.kind != .text { return }
        }
        if let hit = hitElement(at: p) {
            if tools.kind == .text, case .text? = element(hit.page, hit.id) {
                beginTextEditing(page: hit.page, id: hit.id)
            } else {
                selectElement(hit.page, hit.id)
            }
            return
        }
        if selected != nil {
            clearSelection()
            return
        }
        if tools.kind == .text { insertTextBox(sticky: false, at: p) }
    }

    @objc private func handleToolPan(_ g: UIPanGestureRecognizer) {
        let p = surfacePoint(g)
        switch g.state {
        case .began:
            panStart = p
            panPoints = [p]
        case .changed:
            panPoints.append(p)
            switch tools.kind {
            case .shape:
                let spec = ShapeSpec(kind: tools.shapeKind, ax: Double(panStart.x), ay: Double(panStart.y), bx: Double(p.x), by: Double(p.y))
                sketch.showPreview(viewPath(spec.polylines(step: 4)), color: tools.currentColor, width: tools.shapeLineWidth * canvas.zoomScale)
            case .tape:
                let r = tapeRect(from: panStart, to: p)
                let a = viewPoint(r.origin), b = viewPoint(CGPoint(x: r.maxX, y: r.maxY))
                sketch.showFill(UIBezierPath(roundedRect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), cornerRadius: 3).cgPath, color: tools.currentColor.withAlphaComponent(0.85))
            case .laser:
                let path = UIBezierPath()
                for (i, q) in panPoints.suffix(60).enumerated() {
                    let v = viewPoint(q)
                    if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
                }
                sketch.showPreview(path.cgPath, color: .systemRed, width: 4)
            default:
                break
            }
        case .ended:
            sketch.showPreview(nil, color: .clear, width: 0)
            switch tools.kind {
            case .shape:
                guard hypot(p.x - panStart.x, p.y - panStart.y) > 4 else { return }
                let spec = ShapeSpec(kind: tools.shapeKind, ax: Double(panStart.x), ay: Double(panStart.y), bx: Double(p.x), by: Double(p.y))
                var drawing = fullDrawing
                drawing.strokes.append(contentsOf: shapeStrokes(spec, ink: PKInk(.monoline, color: tools.currentColor), width: tools.shapeLineWidth))
                replaceDrawing(drawing, actionName: L("shape.title"))
            case .tape:
                let r = tapeRect(from: panStart, to: p)
                guard r.width > 8 else { return }
                let page = layout.pageIndex(atY: Double(panStart.y))
                let o = pageOrigin(page)
                let frame = Rect(x: Double(r.minX - o.x), y: Double(r.minY - o.y), width: Double(r.width), height: Double(r.height))
                insertElement(.tape(TapeElement(frame: frame, color: tools.currentRGBA)), page: page, select: false)
            case .laser:
                let path = UIBezierPath()
                for (i, q) in panPoints.suffix(60).enumerated() {
                    let v = viewPoint(q)
                    if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
                }
                sketch.laser(path.cgPath)
                sketch.fadeLaser()
            default:
                break
            }
        case .cancelled, .failed:
            sketch.showPreview(nil, color: .clear, width: 0)
        default:
            break
        }
    }

    private func tapeRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let h = max(14, abs(b.y - a.y))
        let y = abs(b.y - a.y) < 14 ? a.y - 7 : min(a.y, b.y)
        return CGRect(x: min(a.x, b.x), y: y, width: abs(b.x - a.x), height: h)
    }

    private func viewPath(_ lines: [[(x: Double, y: Double)]]) -> CGPath {
        let path = UIBezierPath()
        for line in lines {
            for (i, q) in line.enumerated() {
                let v = viewPoint(CGPoint(x: q.x, y: q.y))
                if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
            }
        }
        return path.cgPath
    }

    // MARK: - Édition de texte

    private func beginTextEditing(page: Int, id: UUID) {
        commitTextEditing()
        guard case let .text(t)? = element(page, id) else { return }
        clearSelection()
        gestureSnapshot = elements
        editingText = (page, id)
        let tv = UITextView()
        tv.delegate = self
        tv.backgroundColor = t.fill.map(InkConverter.uiColor) ?? UIColor.white.withAlphaComponent(0.6)
        tv.layer.borderWidth = 1.5
        tv.layer.borderColor = Theme.accent.cgColor
        tv.isScrollEnabled = false
        tv.text = t.text
        tv.inputAccessoryView = TextFormatBar(editor: self)
        view.insertSubview(tv, belowSubview: selection)
        textEditor = tv
        applyTextStyle(t)
        refreshElementLayers()
        positionTextEditor()
        tv.becomeFirstResponder()
    }

    func editingTextElement() -> TextElement? {
        guard let e = editingText, case let .text(t)? = element(e.page, e.id) else { return nil }
        return t
    }

    /// Modifie le style de la zone de texte en cours d'édition.
    func changeEditingText(_ change: (inout TextElement) -> Void) {
        guard let e = editingText else { return }
        updateElement(e.page, e.id, live: true) { el in
            guard case var .text(t) = el else { return }
            change(&t)
            el = .text(t)
        }
        if let t = editingTextElement() { applyTextStyle(t) }
    }

    private func applyTextStyle(_ t: TextElement) {
        guard let tv = textEditor else { return }
        let z = canvas.zoomScale
        // Attributs calculés directement : une chaîne vide n'a pas d'attributs à lire.
        tv.typingAttributes = PageRenderer.attributes(t, scale: z)
        let selectionRange = tv.selectedRange
        tv.attributedText = PageRenderer.attributed(TextElement(frame: t.frame, text: tv.text, font: t.font, fontSize: t.fontSize, color: t.color, bold: t.bold, italic: t.italic, underline: t.underline, alignment: t.alignment), scale: z)
        tv.selectedRange = selectionRange
        let inset = PageRenderer.textInset * z
        tv.textContainerInset = UIEdgeInsets(top: inset, left: inset - 5, bottom: inset, right: inset - 5)
        positionTextEditor()
    }

    private func positionTextEditor() {
        guard let tv = textEditor, let e = editingText, let element = element(e.page, e.id) else { return }
        let o = pageOrigin(e.page)
        let f = element.frame
        let a = viewPoint(CGPoint(x: o.x + CGFloat(f.x), y: o.y + CGFloat(f.y)))
        let z = canvas.zoomScale
        tv.frame = CGRect(x: a.x, y: a.y, width: CGFloat(f.width) * z, height: CGFloat(f.height) * z)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let e = editingText else { return }
        let z = canvas.zoomScale
        let needed = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height / z
        updateElement(e.page, e.id, live: true) { el in
            guard case var .text(t) = el else { return }
            t.text = String(textView.text.prefix(TextElement.maxLength))
            if t.fill == nil || Double(needed) > t.frame.height { t.frame.height = max(Double(needed), t.fill == nil ? 30 : t.frame.height) }
            el = .text(t)
        }
        positionTextEditor()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        commitTextEditing()
    }

    /// Termine l'édition : enregistre le texte, ou supprime une zone restée vide.
    func commitTextEditing() {
        guard let tv = textEditor, let e = editingText else { return }
        textEditor = nil
        editingText = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        var copy = elements
        if copy.indices.contains(e.page), let i = copy[e.page].firstIndex(where: { $0.id == e.id }), case let .text(t) = copy[e.page][i],
           t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, t.fill == nil {
            copy[e.page].remove(at: i)
        }
        setElements(copy, actionName: L("element.editText"))
    }

    // MARK: - Pages

    /// Traits courants, répartis par page (repère local).
    func strokesByPage() -> [[Stroke]] {
        layout.split(fullDrawing.strokes.map { InkConverter.stroke(from: $0) })
    }

    // MARK: - Relecture synchronisée

    /// Affiche l'écriture telle qu'elle était au fil de l'enregistrement ; l'édition est suspendue.
    func beginReplay() {
        guard replayFull == nil else { return }
        commitTextEditing()
        clearSelection()
        replayFull = canvas.drawing
        canvas.drawingGestureRecognizer.isEnabled = false
        toolStrip.isUserInteractionEnabled = false
        toolStrip.alpha = 0.5
    }

    func updateReplay(wall: Double) {
        guard let full = replayFull else { return }
        let visible = full.strokes.filter { $0.path.creationDate.timeIntervalSince1970 * 1000 <= wall + 1 }
        guard visible.count != canvas.drawing.strokes.count else { return }
        isApplyingDrawing = true
        canvas.drawing = PKDrawing(strokes: visible)
        isApplyingDrawing = false
    }

    func endReplay() {
        guard let full = replayFull else { return }
        replayFull = nil
        isApplyingDrawing = true
        canvas.drawing = full
        isApplyingDrawing = false
        lastStrokeCount = full.strokes.count
        toolStrip.isUserInteractionEnabled = true
        toolStrip.alpha = 1
        applyTool()
    }

    /// Modifie la liste des pages. Traits et éléments suivent leur page ; l'historique
    /// d'annulation est vidé, car il porte sur des positions qui n'existent plus.
    func restructure(_ change: (inout [PageInfo], inout [[Stroke]], inout [PageElements]) -> Void) {
        commitTextEditing()
        clearSelection()
        endReplay()
        var pages = strokesByPage()
        var infos = manifest.pages
        var items = elements
        change(&infos, &pages, &items)
        guard !infos.isEmpty, infos.count == pages.count, infos.count == items.count else { return }
        manifest.pages = infos
        elements = items
        layout = PageLayout(pages: infos)
        isApplyingDrawing = true
        canvas.drawing = InkConverter.drawing(layout.place(pages))
        isApplyingDrawing = false
        lastStrokeCount = canvas.drawing.strokes.count
        canvas.undoManager?.removeAllActions()
        pagesView.setPages(manifest.pages, layout: layout)
        refreshElementLayers()
        updateContentSize()
        updateInsets()
        syncLayers()
        refreshUndoButtons()
        panel.reload(dirty: true)
        markChanged()
    }

    func insertPages(_ newPages: [PageInfo], at index: Int) {
        guard manifest.pages.count + newPages.count <= NotebookManifest.maxPages else { return }
        restructure { infos, pages, items in
            let at = min(max(0, index), infos.count)
            infos.insert(contentsOf: newPages, at: at)
            pages.insert(contentsOf: Array(repeating: [], count: newPages.count), at: at)
            items.insert(contentsOf: Array(repeating: [], count: newPages.count), at: at)
        }
        view.layoutIfNeeded()
        scrollToPage(min(index, manifest.pages.count - 1), animated: true)
    }

    private func blankPage(like index: Int, template: BackgroundKind? = nil) -> PageInfo {
        let model = manifest.pages[min(max(0, index), manifest.pages.count - 1)]
        var bg = model.background
        if let template {
            bg = .standard(template)
            bg.color = model.background.color
        }
        return PageInfo(width: model.width, height: model.height, background: bg)
    }

    private func addPageActions() -> [UIMenuElement] {
        let current = currentPageIndex()
        let templates = UIMenu(title: L("page.addTemplate"), image: UIImage(systemName: "doc.plaintext"), children: NewNotebookViewController.templates.map { kind, key in
            UIAction(title: L(key)) { [weak self] _ in
                guard let self else { return }
                self.insertPages([self.blankPage(like: current, template: kind)], at: current + 1)
            }
        })
        return [
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("page.addAfter"), image: UIImage(systemName: "arrow.down.doc")) { [weak self] _ in
                    guard let self else { return }
                    self.insertPages([self.blankPage(like: current)], at: current + 1)
                },
                UIAction(title: L("page.addBefore"), image: UIImage(systemName: "arrow.up.doc")) { [weak self] _ in
                    guard let self else { return }
                    self.insertPages([self.blankPage(like: current)], at: current)
                },
                UIAction(title: L("page.addLast"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                    guard let self else { return }
                    self.insertPages([self.blankPage(like: current)], at: self.manifest.pages.count)
                },
                templates,
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("page.fromImage"), image: UIImage(systemName: "photo")) { [weak self] _ in self?.pickPhotos(asPages: true) },
                UIAction(title: L("page.fromScan"), image: UIImage(systemName: "doc.viewfinder")) { [weak self] _ in self?.scanDocument() },
                UIAction(title: L("page.fromCamera"), image: UIImage(systemName: "camera")) { [weak self] _ in self?.takePhoto(asPage: true) },
                UIAction(title: L("page.fromPDF"), image: UIImage(systemName: "doc.richtext")) { [weak self] _ in self?.importPDFPages() },
            ]),
        ]
    }

    private func setTemplate(_ kind: BackgroundKind, page index: Int) {
        guard manifest.pages.indices.contains(index) else { return }
        let old = manifest.pages[index].background
        var next = Background.standard(kind)
        next.color = old.color
        guard next != old else { return }
        manifest.pages[index].background = next
        pagesView.setPages(manifest.pages, layout: layout)
        panel.reload(dirty: true)
        markChanged()
    }

    private func setPaperColor(_ paper: PaperColor, page index: Int) {
        guard manifest.pages.indices.contains(index) else { return }
        manifest.pages[index].background.color = paper.rgba
        pagesView.setPages(manifest.pages, layout: layout)
        panel.reload(dirty: true)
        markChanged()
    }

    func confirmDeletePage(_ index: Int) {
        guard manifest.pages.count > 1 else { return }
        let alert = UIAlertController(title: L("page.deleteTitle", index + 1), message: L("page.deleteMessage"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("common.delete"), style: .destructive) { [weak self] _ in
            self?.restructure { infos, pages, items in
                guard infos.indices.contains(index), infos.count > 1 else { return }
                infos.remove(at: index)
                pages.remove(at: index)
                items.remove(at: index)
            }
        })
        present(alert, animated: true)
    }

    private func clearPage(_ index: Int) {
        let alert = UIAlertController(title: L("page.clearTitle"), message: L("page.clearMessage"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("page.clear"), style: .destructive) { [weak self] _ in
            guard let self, self.layout.frames.indices.contains(index) else { return }
            let keep = self.fullDrawing.strokes.filter { stroke in
                let b = stroke.renderBounds
                return self.layout.pageIndex(atY: Double(b.midY)) != index
            }
            self.replaceDrawing(PKDrawing(strokes: keep), actionName: L("page.clear"))
            var copy = self.elements
            copy[index] = []
            self.setElements(copy, actionName: L("page.clear"))
        })
        present(alert, animated: true)
    }

    func duplicatePage(_ index: Int) {
        restructure { infos, pages, items in
            guard infos.indices.contains(index) else { return }
            var info = infos[index]
            info.id = UUID()
            info.bookmarked = false
            infos.insert(info, at: index + 1)
            pages.insert(pages[index].map { var s = $0; s.id = UUID(); s.randomSeed = UInt32.random(in: 1...UInt32.max); return s }, at: index + 1)
            items.insert(items[index].map(Self.withNewID), at: index + 1)
        }
    }

    static func withNewID(_ e: PageElement) -> PageElement {
        switch e {
        case var .image(i): i.id = UUID(); return .image(i)
        case var .text(t): t.id = UUID(); return .text(t)
        case var .tape(t): t.id = UUID(); return .tape(t)
        }
    }

    private func toggleBookmark(_ index: Int) {
        guard manifest.pages.indices.contains(index) else { return }
        manifest.pages[index].bookmarked.toggle()
        panel.reload()
        markChanged()
    }

    private func promptPageTitle(_ index: Int) {
        guard manifest.pages.indices.contains(index) else { return }
        let alert = UIAlertController(title: L("outline.title"), message: L("outline.message"), preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.manifest.pages[index].title
            field.placeholder = L("page.number", index + 1)
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("common.save"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            self.manifest.pages[index].title = LibraryIndex.normalizedTitle(alert?.textFields?.first?.text ?? "")
            self.panel.reload()
            self.markChanged()
        })
        present(alert, animated: true)
    }

    @objc private func promptGoToPage() {
        let alert = UIAlertController(title: L("page.goTo"), message: L("page.goToMessage", manifest.pages.count), preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.placeholder = "1"
        }
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("page.goToAction"), style: .default) { [weak self, weak alert] _ in
            guard let self, let n = Int(alert?.textFields?.first?.text ?? ""), n >= 1 else { return }
            self.scrollToPage(min(n, self.manifest.pages.count) - 1, animated: true)
        })
        present(alert, animated: true)
    }

    /// Copie une page dans un autre bloc-notes (ajoutée à la fin).
    private func copyPage(_ index: Int, to target: UUID) {
        saveNow(wait: true)
        let info = manifest.pages[index]
        let strokes = strokesByPage()[index]
        let items = elements[index]
        do {
            let dir = library.notebookDirectory(target)
            let opened = try NotebookStore.open(directory: dir)
            var m = opened.manifest
            var newInfo = info
            newInfo.id = UUID()
            newInfo.bookmarked = false
            // Les ressources utilisées par la page sont copiées.
            var resources = items.compactMap(\.resource)
            if let r = info.backdrop?.resource { resources.append(r) }
            try FileManager.default.createDirectory(at: opened.store.resourcesDirectory, withIntermediateDirectories: true)
            for r in resources where !FileManager.default.fileExists(atPath: opened.store.resourceURL(r).path) {
                try FileManager.default.copyItem(at: store.resourceURL(r), to: opened.store.resourceURL(r))
            }
            m.pages.append(newInfo)
            var pages = opened.pages
            pages.append(strokes.map { var s = $0; s.id = UUID(); return s })
            var els = opened.elements
            els.append(items.map(Self.withNewID))
            let targetLayout = PageLayout(pages: m.pages)
            _ = try opened.store.queue.sync { try opened.store.save(strokes: targetLayout.place(pages), elements: els, manifest: m) }
            library.mutate { $0.touch(target, now: nowMs()) }
            Thumbnailer.refresh(library: library, id: target)
            showAlert(L("page.copied"), L("page.copiedMessage", library.index.item(target)?.title ?? ""))
        } catch {
            showAlert(L("common.error"), error.localizedDescription)
        }
    }

    func pageMenu(for index: Int) -> UIMenu {
        let info = manifest.pages[index]
        let targets = library.index.items.filter { $0.kind == .notebook && $0.id != itemID && !library.index.isEffectivelyTrashed($0.id) && !$0.locked }
        let copyMenu = UIMenu(title: L("page.copyTo"), image: UIImage(systemName: "doc.on.doc"), children: targets.isEmpty
            ? [UIAction(title: L("page.noOtherNotebook"), attributes: .disabled) { _ in }]
            : targets.map { t in UIAction(title: t.title) { [weak self] _ in self?.copyPage(index, to: t.id) } })
        let templates = UIMenu(title: L("page.template"), image: UIImage(systemName: "doc.plaintext"), options: .singleSelection, children: NewNotebookViewController.templates.map { kind, key in
            UIAction(title: L(key), state: kind == info.background.kind ? .on : .off) { [weak self] _ in self?.setTemplate(kind, page: index) }
        })
        let colors = UIMenu(title: L("new.paperColor"), image: UIImage(systemName: "paintpalette"), options: .singleSelection, children: NewNotebookViewController.papers.map { paper, key in
            UIAction(title: L(key), state: paper.rgba == info.background.color ? .on : .off) { [weak self] _ in self?.setPaperColor(paper, page: index) }
        })
        return UIMenu(title: L("page.number", index + 1), children: [
            UIMenu(options: .displayInline, children: [
                UIAction(title: info.bookmarked ? L("page.unbookmark") : L("page.bookmark"), image: UIImage(systemName: info.bookmarked ? "bookmark.slash" : "bookmark")) { [weak self] _ in self?.toggleBookmark(index) },
                UIAction(title: L("outline.title"), image: UIImage(systemName: "list.bullet.indent")) { [weak self] _ in self?.promptPageTitle(index) },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("page.duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicatePage(index) },
                UIAction(title: L("page.addAfter"), image: UIImage(systemName: "arrow.down.doc")) { [weak self] _ in
                    guard let self else { return }
                    self.insertPages([self.blankPage(like: index)], at: index + 1)
                },
                copyMenu, templates, colors,
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("export.pagePDF"), image: UIImage(systemName: "doc.richtext")) { [weak self] _ in self?.exportPDF(pages: [index]) },
                UIAction(title: L("export.pageImage"), image: UIImage(systemName: "photo")) { [weak self] _ in self?.exportImage(page: index) },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("page.clear"), image: UIImage(systemName: "eraser.line.dashed"), attributes: .destructive) { [weak self] _ in self?.clearPage(index) },
                UIAction(title: L("page.delete"), image: UIImage(systemName: "trash"), attributes: manifest.pages.count > 1 ? .destructive : [.destructive, .disabled]) { [weak self] _ in self?.confirmDeletePage(index) },
            ]),
        ])
    }

    // MARK: - Panneau des pages

    private func togglePanel() {
        commitTextEditing()
        let show = panel.isHidden
        if show {
            panel.isHidden = false
            panel.reload(dirty: true)
        }
        view.layoutIfNeeded()
        panelLeading.constant = show ? 0 : -320
        UIView.animate(withDuration: 0.25, animations: { self.view.layoutIfNeeded() }, completion: { _ in
            if !show { self.panel.isHidden = true }
        })
        UIAccessibility.post(notification: .screenChanged, argument: show ? (panel as UIView) : (canvas as UIView))
    }

    var panelPages: [PageInfo] { manifest.pages }
    var panelCurrentIndex: Int { currentPageIndex() }

    private var panelStrokes: [[Stroke]]?

    func panelThumbnail(_ index: Int, width: CGFloat) -> UIImage? {
        if panelStrokes == nil || panelStrokes?.count != manifest.pages.count { panelStrokes = strokesByPage() }
        guard let strokes = panelStrokes, manifest.pages.indices.contains(index) else { return nil }
        return PageRenderer.image(info: manifest.pages[index], strokes: strokes[index], elements: elements[index], resources: store.resourcesDirectory, width: width,
                                  options: PageRenderer.Options(inkScale: 1))
    }

    func panelSelect(_ index: Int) {
        scrollToPage(index, animated: true)
        panel.reload()
    }

    func panelMove(from: Int, to: Int) {
        restructure { infos, pages, items in
            guard infos.indices.contains(from), infos.indices.contains(to) else { return }
            infos.insert(infos.remove(at: from), at: to)
            pages.insert(pages.remove(at: from), at: to)
            items.insert(items.remove(at: from), at: to)
        }
    }

    func panelMenu(for index: Int) -> UIMenu { pageMenu(for: index) }

    func panelClose() {
        togglePanel()
    }

    // MARK: - Insertion

    private func insertActions() -> [UIMenuElement] {
        var collection: [UIMenuElement] = ElementCollection.shared.items().prefix(30).map { url in
            UIAction(title: String(url.deletingPathExtension().lastPathComponent.prefix(8)) + "…", image: ElementCollection.shared.thumbnail(url)) { [weak self] _ in
                if let image = UIImage(contentsOfFile: url.path) { self?.insertImage(image) }
            }
        }
        if collection.isEmpty { collection = [UIAction(title: L("collection.empty"), attributes: .disabled) { _ in }] }
        return [
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("insert.photos"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.pickPhotos(asPages: false) },
                UIAction(title: L("insert.camera"), image: UIImage(systemName: "camera")) { [weak self] _ in self?.takePhoto(asPage: false) },
                UIAction(title: L("insert.files"), image: UIImage(systemName: "folder")) { [weak self] _ in self?.pickImageFile() },
                UIAction(title: L("insert.paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                    if let image = UIPasteboard.general.image { self?.insertImage(image) }
                },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("insert.text"), image: UIImage(systemName: "textformat")) { [weak self] _ in self?.insertTextBox(sticky: false) },
                UIAction(title: L("insert.sticky"), image: UIImage(systemName: "note.text")) { [weak self] _ in self?.insertTextBox(sticky: true) },
            ]),
            UIMenu(title: L("collection.title"), image: UIImage(systemName: "square.grid.2x2"), children: collection),
        ]
    }

    private var pickerAsPages = false
    private var pickerDelegateHolder: AnyObject?

    private func pickPhotos(asPages: Bool) {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = asPages ? 50 : 10
        let picker = PHPickerViewController(configuration: config)
        let delegate = PhotoPickerDelegate { [weak self] images in
            guard let self, !images.isEmpty else { return }
            if asPages { self.addImagePages(images) } else { images.forEach(self.insertImage) }
        }
        pickerDelegateHolder = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func takePhoto(asPage: Bool) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showAlert(L("common.error"), L("insert.noCamera"))
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        let delegate = CameraDelegate { [weak self] image in
            guard let self, let image else { return }
            if asPage { self.addImagePages([image]) } else { self.insertImage(image) }
        }
        pickerDelegateHolder = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func pickImageFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        let delegate = DocumentPickerDelegate { [weak self] urls in
            for url in urls {
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { self?.insertImage(image) }
            }
        }
        pickerDelegateHolder = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func scanDocument() {
        guard VNDocumentCameraViewController.isSupported else {
            showAlert(L("common.error"), L("scan.unsupported"))
            return
        }
        let scanner = VNDocumentCameraViewController()
        let delegate = ScanDelegate { [weak self] images in self?.addImagePages(images) }
        pickerDelegateHolder = delegate
        scanner.delegate = delegate
        present(scanner, animated: true)
    }

    private func addImagePages(_ images: [UIImage]) {
        do {
            let pages = try Importers.imagePages(images, into: store.directory)
            insertPages(pages, at: currentPageIndex() + 1)
        } catch {
            showAlert(L("common.error"), error.localizedDescription)
        }
    }

    private func importPDFPages() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        let delegate = DocumentPickerDelegate { [weak self] urls in
            guard let self, let url = urls.first else { return }
            do {
                let pages = try Importers.pdfPages(from: try Data(contentsOf: url), into: self.store.directory)
                self.insertPages(pages, at: self.currentPageIndex() + 1)
                self.indexDirty = true
            } catch {
                self.showAlert(L("common.error"), error.localizedDescription)
            }
        }
        pickerDelegateHolder = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    // MARK: - Export

    private func exportActions() -> [UIMenuElement] {
        let current = currentPageIndex()
        return [
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("export.allPDF"), image: UIImage(systemName: "doc.richtext")) { [weak self] _ in
                    guard let self else { return }
                    self.exportPDF(pages: Array(self.manifest.pages.indices))
                },
                UIAction(title: L("export.allPDFNoPaper"), image: UIImage(systemName: "doc")) { [weak self] _ in
                    guard let self else { return }
                    self.exportPDF(pages: Array(self.manifest.pages.indices), paper: false)
                },
                UIAction(title: L("export.pagePDF"), image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.exportPDF(pages: [current]) },
                UIAction(title: L("export.pageImage"), image: UIImage(systemName: "photo")) { [weak self] _ in self?.exportImage(page: current) },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("export.nooty"), image: UIImage(systemName: "shippingbox")) { [weak self] _ in self?.exportNooty() },
                UIAction(title: L("export.print"), image: UIImage(systemName: "printer")) { [weak self] _ in self?.printPages() },
            ]),
        ]
    }

    private func pageBundle(_ indices: [Int]) -> [(info: PageInfo, strokes: [Stroke], elements: [PageElement])] {
        let strokes = strokesByPage()
        return indices.filter { manifest.pages.indices.contains($0) }.map { (manifest.pages[$0], strokes[$0], elements[$0]) }
    }

    private func shareFile(_ url: URL) {
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?[1]
        present(share, animated: true)
    }

    private var baseFileName: String { LibraryStore.safeFileName(entry?.title ?? "Nooty") }

    func exportPDF(pages: [Int], paper: Bool = true) {
        commitTextEditing()
        var options = PageRenderer.Options()
        options.paper = paper
        let data = PageRenderer.pdf(pages: pageBundle(pages), resources: store.resourcesDirectory, options: options)
        let suffix = pages.count == 1 ? " - p\(pages[0] + 1)" : ""
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(baseFileName + suffix + ".pdf")
        do {
            try data.write(to: url, options: .atomic)
            shareFile(url)
        } catch {
            showAlert(L("common.error"), error.localizedDescription)
        }
    }

    private func exportImage(page: Int) {
        guard let p = pageBundle([page]).first else { return }
        let image = PageRenderer.image(info: p.info, strokes: p.strokes, elements: p.elements, resources: store.resourcesDirectory, width: CGFloat(p.info.width) * 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(baseFileName + " - p\(page + 1).png")
        do {
            try image.pngData()?.write(to: url, options: .atomic)
            shareFile(url)
        } catch {
            showAlert(L("common.error"), error.localizedDescription)
        }
    }

    private func exportNooty() {
        saveNow(wait: true)
        do {
            shareFile(try library.exportNooty(itemID))
        } catch {
            showAlert(L("common.error"), error.localizedDescription)
        }
    }

    private func printPages() {
        let data = PageRenderer.pdf(pages: pageBundle(Array(manifest.pages.indices)), resources: store.resourcesDirectory)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = entry?.title ?? "Nooty"
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }

    // MARK: - Recherche et texte

    private func presentSearch() {
        commitTextEditing()
        saveNow(wait: true)
        let search = NotebookSearchViewController(editor: self)
        let nav = UINavigationController(rootViewController: search)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    /// Texte connu sans reconnaissance d'écriture : zones de texte et texte natif des PDF.
    func immediateText(page index: Int) -> String {
        var parts = elements[index].compactMap(\.searchableText)
        if case let .pdf(resource, pageIndex)? = manifest.pages[index].backdrop {
            parts.append(Importers.pdfText(store.resourceURL(resource), pageIndex: pageIndex))
        }
        if let title = manifest.pages[index].title { parts.append(title) }
        return parts.joined(separator: "\n")
    }

    /// Reconstruit l'index de recherche : texte immédiat et reconnaissance de l'écriture, en arrière-plan.
    func rebuildIndex(completion: (() -> Void)? = nil) {
        indexDirty = false
        let strokes = strokesByPage()
        var jobs: [(UUID, String, UIImage?)] = []
        for (i, info) in manifest.pages.enumerated() {
            let ink = strokes[i].isEmpty ? nil : PageRenderer.image(info: info, strokes: strokes[i], elements: [], resources: store.resourcesDirectory, width: CGFloat(info.width) * 2,
                                                                     options: PageRenderer.Options(paper: false, ink: true, elements: false, inkScale: 1))
            jobs.append((info.id, immediateText(page: i), ink))
        }
        let recordings = manifest.recordings
        let store = store
        DispatchQueue.global(qos: .utility).async {
            var index = NotebookTextIndex()
            for (id, text, ink) in jobs {
                let handwriting = ink.map { HandwritingRecognizer.recognize($0) } ?? ""
                index.pages[id] = [text, handwriting].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            for r in recordings { index.recordings[r.id] = r.transcriptText }
            store.queue.async {
                store.saveIndex(index)
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    // MARK: - Autres actions

    private func moreActions() -> [UIMenuElement] {
        let index = currentPageIndex()
        let finger = UIAction(title: L("action.fingerDraws"), image: UIImage(systemName: "hand.draw"), state: fingerDraws ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.fingerDraws.toggle()
            self.applyInputPolicy()
        }
        let hold = UIAction(title: L("shape.hold"), image: UIImage(systemName: "hand.point.up.left.and.text"), state: tools.holdToShape ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.tools.holdToShape.toggle()
            self.tools.save()
        }
        let fit = UIAction(title: L("action.fit"), image: UIImage(systemName: "arrow.left.and.right")) { [weak self] _ in self?.fitWidth() }
        let tapes = UIMenu(title: L("tape.label"), image: UIImage(systemName: "rectangle.fill.on.rectangle.fill"), children: [
            UIAction(title: L("tape.revealAll"), image: UIImage(systemName: "eye")) { [weak self] _ in self?.setAllTapes(revealed: true) },
            UIAction(title: L("tape.hideAll"), image: UIImage(systemName: "eye.slash")) { [weak self] _ in self?.setAllTapes(revealed: false) },
        ])
        return [
            UIMenu(options: .displayInline, children: [
                pageMenu(for: index),
                UIAction(title: L("page.goTo"), image: UIImage(systemName: "arrow.forward.to.line")) { [weak self] _ in self?.promptGoToPage() },
                UIAction(title: L("ocr.convert"), image: UIImage(systemName: "text.viewfinder")) { [weak self] _ in self?.convertHandwriting(page: index) },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("cards.title"), image: UIImage(systemName: "rectangle.on.rectangle.angled")) { [weak self] _ in self?.presentFlashcards() },
                UIAction(title: L("ai.title"), image: UIImage(systemName: "sparkles")) { [weak self] _ in self?.presentAssistant() },
                tapes,
            ]),
            UIMenu(options: .displayInline, children: [fit, finger, hold]),
        ]
    }

    private func convertHandwriting(page index: Int) {
        let strokes = strokesByPage()[index]
        guard !strokes.isEmpty else {
            showAlert(L("ocr.convert"), L("ocr.empty"))
            return
        }
        let info = manifest.pages[index]
        let image = PageRenderer.image(info: info, strokes: strokes, elements: [], resources: store.resourcesDirectory, width: CGFloat(info.width) * 2,
                                       options: PageRenderer.Options(paper: false, ink: true, elements: false, inkScale: 1))
        DispatchQueue.global(qos: .userInitiated).async {
            let text = HandwritingRecognizer.recognize(image)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let result = RecognizedTextViewController(text: text) { [weak self] text in
                    guard let self else { return }
                    let page = index
                    let c = self.visibleCenter(on: page)
                    let element = TextElement(frame: Rect(x: Double(c.x) - 160, y: Double(c.y), width: 320, height: 120), text: text, color: self.tools.currentRGBA)
                    self.insertElement(.text(element), page: page)
                }
                let nav = UINavigationController(rootViewController: result)
                nav.modalPresentationStyle = .formSheet
                self.present(nav, animated: true)
            }
        }
    }

    func presentFlashcards() {
        commitTextEditing()
        let cards = FlashcardsViewController(editor: self)
        let nav = UINavigationController(rootViewController: cards)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    func presentAssistant(prefill: String? = nil) {
        commitTextEditing()
        saveNow(wait: true)
        let assistant = AssistantViewController(editor: self, prefill: prefill)
        let nav = UINavigationController(rootViewController: assistant)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    /// Modification du manifeste depuis les panneaux (audio, cartes).
    func updateManifest(_ change: (inout NotebookManifest) -> Void) {
        change(&manifest)
        indexDirty = true
        markChanged()
    }

    // MARK: - Enregistrement

    func markChanged() {
        changeGeneration += 1
        contentChanged = true
        panelStrokes = nil
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow(wait: false) }
        pendingSave = item
        // Court délai : regroupe les modifications rapprochées sans laisser une action longtemps non enregistrée.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func saveNow(wait: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        guard savedGeneration < changeGeneration || manifest.lastPageIndex != lastSavedPageIndex else { return }
        let drawing = fullDrawing
        let generation = changeGeneration
        var snapshot = manifest
        snapshot.updatedAt = nowMs()
        let els = elements
        lastSavedPageIndex = manifest.lastPageIndex
        let store = store
        let work = {
            let outcome = Result { try store.save(drawing: drawing, elements: els, manifest: snapshot) }
            DispatchQueue.main.async { [weak self] in self?.finishSave(outcome, generation: generation) }
        }
        if wait { store.queue.sync(execute: work) } else { store.queue.async(execute: work) }
    }

    private func finishSave(_ outcome: Result<NotebookStore.SaveResult, Error>, generation: Int) {
        switch outcome {
        case .success:
            savedGeneration = max(savedGeneration, generation)
            if saveErrorShown {
                saveErrorShown = false
                pagePill.backgroundColor = Theme.ink.withAlphaComponent(0.82)
            }
        case let .failure(error):
            pagePill.backgroundColor = .systemRed
            guard !saveErrorShown, presentedViewController == nil, view.window != nil else { return }
            saveErrorShown = true
            showAlert(L("common.error"), L("save.error", error.localizedDescription))
        }
    }

    @objc private func flushForBackground() {
        guard pendingSave != nil || savedGeneration < changeGeneration else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "nooty.save")
        saveNow(wait: true)
        UIApplication.shared.endBackgroundTask(task)
    }

    // MARK: - Miniature

    private func makeThumbnail() -> UIImage? {
        guard let info = manifest.pages.first else { return nil }
        let strokes = strokesByPage().first ?? []
        return PageRenderer.image(info: info, strokes: strokes, elements: elements.first ?? [], resources: store.resourcesDirectory, width: 336)
    }
}
