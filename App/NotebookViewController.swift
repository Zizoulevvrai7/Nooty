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
    let pagesView = PagesBackgroundView()
    let contentLayer = ElementsLayerView(kind: .content)
    let tapeLayer = ElementsLayerView(kind: .tapes)
    let sketch = SketchOverlayView()
    let selection = SelectionOverlayView()
    let contextBar: ContextToolBar
    let toolbar = EditorToolbar()
    let chromeBackdrop = UIView()
    let undoPill = ChromePill()
    let undoButton = ChromeButton.make("arrow.uturn.backward", L("action.undo"))
    let redoButton = ChromeButton.make("arrow.uturn.forward", L("action.redo"))
    /// Rangée flottante sous la barre : annuler, réglages de l'outil, enregistrement.
    let contextRow = UIView()
    let audioSlot = UIStackView()
    let selectionPill = ChromePill()
    var selectionBar: UIStackView { selectionPill.stack }
    /// Lecture seule : outils masqués, rien ne s'écrit par erreur pendant la relecture.
    var readOnly = false
    /// Boutons d'ancrage des menus et du partage.
    weak var shareSource: UIView?
    let pageLabel = UILabel()
    let pagePill = UIView()
    let panel = PagePanelView()
    var panelLeading: NSLayoutConstraint?
    private(set) var tabBar: DocumentTabsView!

    var tools: ToolState
    var editingColorIndex: Int?
    var fingerDraws: Bool {
        get { UserDefaults.standard.bool(forKey: "nooty.fingerDraws") }
        set { UserDefaults.standard.set(newValue, forKey: "nooty.fingerDraws") }
    }

    lazy var toolPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolPan(_:)))
    lazy var toolTap = UITapGestureRecognizer(target: self, action: #selector(handleToolTap(_:)))

    // Sélection et édition d'éléments
    var selected: (page: Int, id: UUID)?
    var gestureSnapshot: [PageElements]?
    var textEditor: UITextView?
    var editingText: (page: Int, id: UUID)?

    // Outils à geste
    var panStart: CGPoint = .zero
    var panPoints: [CGPoint] = []

    // Enregistrement
    var pendingSave: DispatchWorkItem?
    var changeGeneration = 0
    var savedGeneration = 0
    var contentChanged = false
    var isApplyingDrawing = false
    var didInitialLayout = false
    var didAppear = false
    var damagedPages = 0
    var lastStrokeCount = 0
    var saveErrorShown = false
    lazy var lastSavedPageIndex = manifest.lastPageIndex
    var indexDirty = false

    var audioController: AudioController?
    /// Dessin complet mis de côté pendant la relecture synchronisée avec l'audio.
    var replayFull: PKDrawing?

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
        contextBar = ContextToolBar(state: initialTools)
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
        view.backgroundColor = Theme.editorDesk
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

        contextBar.onChange = { [weak self] state in self?.applyToolState(state) }
        contextBar.onEditColor = { [weak self] index, color, source in self?.editColor(at: index, current: color, source: source) }
        contextBar.onEditWidth = { [weak self] index, source in self?.presentWidthMenu(index: index, from: source) }
        contextBar.onToolMenu = { [weak self] source in self?.presentToolMenu(from: source) }
        contextBar.onFontMenu = { [weak self] source in self?.presentFontMenu(from: source) }
        contextBar.onTextSize = { [weak self] delta in self?.changeTextSize(by: delta) }
        contextBar.textStyle = (TextDefaults.font, TextDefaults.size)

        // Habillage : fond sombre sous la barre d'état, onglets, barre principale.
        chromeBackdrop.backgroundColor = Theme.chromeDeep
        tabBar = DocumentTabsView(library: library, current: itemID)
        tabBar.onHome = { [weak self] in self?.goHome() }
        tabBar.onSelect = { [weak self] id in self?.switchToTab(id) }
        tabBar.onClose = { [weak self] id in self?.closeTab(id) }
        tabBar.activeMenu = { [weak self] in self?.documentMenu() ?? UIMenu() }
        tabBar.reload()
        for v in [chromeBackdrop, tabBar!, toolbar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.overrideUserInterfaceStyle = .dark
            view.addSubview(v)
        }

        undoButton.addAction(UIAction { [weak self] _ in
            self?.commitTextEditing()
            self?.canvas.undoManager?.undo()
            self?.refreshUndoButtons()
        }, for: .primaryActionTriggered)
        redoButton.addAction(UIAction { [weak self] _ in
            self?.canvas.undoManager?.redo()
            self?.refreshUndoButtons()
        }, for: .primaryActionTriggered)
        undoPill.stack.addArrangedSubview(undoButton)
        undoPill.stack.addArrangedSubview(redoButton)
        audioSlot.axis = .horizontal
        for v in [undoPill, contextBar, audioSlot] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contextRow.addSubview(v)
        }
        contextRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contextRow)

        selectionPill.isHidden = true
        selectionPill.frame = CGRect(x: 0, y: 0, width: 200, height: 52)
        view.addSubview(selectionPill)
        selectionHolder = selectionPill

        // Indicateur de page : une pastille qui contient le texte, dimensionnée par ses contraintes.
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = Theme.rounded(13, .semibold, style: .footnote)
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textColor = Theme.chromeText
        pageLabel.text = L("page.position", 1, manifest.pages.count)
        pagePill.translatesAutoresizingMaskIntoConstraints = false
        pagePill.backgroundColor = Theme.chrome.withAlphaComponent(0.9)
        pagePill.layer.cornerRadius = 14
        pagePill.layer.cornerCurve = .continuous
        pagePill.addSubview(pageLabel)
        pagePill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(promptGoToPage)))
        pagePill.isAccessibilityElement = true
        pagePill.accessibilityLabel = pageLabel.text
        pagePill.accessibilityTraits = .button
        pagePill.accessibilityHint = L("page.goToHint")
        view.addSubview(pagePill)

        panel.dataSource = self
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        view.addSubview(panel)

        let guide = view.safeAreaLayoutGuide
        panelLeading = panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -340)
        let barCentered = contextBar.centerXAnchor.constraint(equalTo: contextRow.centerXAnchor)
        barCentered.priority = .defaultLow
        NSLayoutConstraint.activate([
            chromeBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            chromeBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeBackdrop.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBar.topAnchor.constraint(equalTo: guide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contextRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            contextRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            contextRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            contextRow.heightAnchor.constraint(equalToConstant: 52),
            undoPill.leadingAnchor.constraint(equalTo: contextRow.leadingAnchor),
            undoPill.topAnchor.constraint(equalTo: contextRow.topAnchor),
            contextBar.topAnchor.constraint(equalTo: contextRow.topAnchor),
            contextBar.leadingAnchor.constraint(greaterThanOrEqualTo: undoPill.trailingAnchor, constant: 10),
            contextBar.trailingAnchor.constraint(lessThanOrEqualTo: audioSlot.leadingAnchor, constant: -10),
            barCentered,
            audioSlot.trailingAnchor.constraint(equalTo: contextRow.trailingAnchor),
            audioSlot.topAnchor.constraint(equalTo: contextRow.topAnchor),
            pageLabel.topAnchor.constraint(equalTo: pagePill.topAnchor, constant: 6),
            pageLabel.bottomAnchor.constraint(equalTo: pagePill.bottomAnchor, constant: -6),
            pageLabel.leadingAnchor.constraint(equalTo: pagePill.leadingAnchor, constant: 14),
            pageLabel.trailingAnchor.constraint(equalTo: pagePill.trailingAnchor, constant: -14),
            pagePill.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            pagePill.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            panel.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: 320),
            panelLeading!,
        ])
        // Le contexte se rétrécit avant de chevaucher l'enregistrement.
        contextBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rebuildToolbar()

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

    var selectionHolder: UIView!

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

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
        if navigationController?.topViewController !== self {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
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

    func applyTool() {
        canvas.tool = tools.pkTool
        let custom = !tools.kind.usesInk
        canvas.drawingGestureRecognizer.isEnabled = !custom && !readOnly
        toolPan.isEnabled = !readOnly && [.shape, .tape, .laser].contains(tools.kind)
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

    func applyInputPolicy() {
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        applyTool()
    }

    func editColor(at index: Int, current: UIColor, source: UIView) {
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
        contextBar.state = tools
        applyTool()
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        editingColorIndex = nil
    }

    func refreshUndoButtons() {
        undoButton.isEnabled = canvas.undoManager?.canUndo ?? false
        redoButton.isEnabled = canvas.undoManager?.canRedo ?? false
    }

    // MARK: - Renommage et onglets

    func navigationItem(_: UINavigationItem, didEndRenamingWith title: String) {
        library.mutate { $0.rename(itemID, to: title, now: nowMs()) }
        self.title = entry?.title
        tabBar.reload()
    }

    func switchToTab(_ id: UUID) {
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

    func closeTab(_ id: UUID) {
        if id == itemID {
            library.closeTab(id)
            navigationController?.popViewController(animated: true)
        } else {
            library.closeTab(id)
            tabBar.reload()
        }
    }

    // MARK: - Disposition et défilement

    func updateContentSize() {
        canvas.contentSize = CGSize(width: CGFloat(layout.width) * canvas.zoomScale, height: CGFloat(layout.height) * canvas.zoomScale)
    }

    /// Hauteur couverte par l'habillage : onglets, barre principale, rangée de réglages.
    var topChrome: CGFloat { 46 + 56 + (readOnly ? 12 : 52 + 22) }

    func updateInsets() {
        let horizontal = max(12, (canvas.bounds.width - canvas.contentSize.width) / 2)
        let inset = UIEdgeInsets(
            top: view.safeAreaInsets.top + topChrome, left: horizontal,
            bottom: view.safeAreaInsets.bottom + 80, right: horizontal
        )
        if canvas.contentInset != inset { canvas.contentInset = inset }
    }

    func fitWidth() {
        guard layout.width > 0 else { return }
        let target = (view.bounds.width - 24) / CGFloat(layout.width)
        canvas.setZoomScale(min(canvas.maximumZoomScale, max(canvas.minimumZoomScale, target)), animated: false)
        updateContentSize()
        updateInsets()
        syncLayers()
    }

    func syncLayers() {
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
    func surfacePoint(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: canvas)
        return CGPoint(x: p.x / canvas.zoomScale, y: p.y / canvas.zoomScale)
    }

    /// Conversion surface → vue de l'éditeur.
    func viewPoint(_ p: CGPoint) -> CGPoint {
        canvas.convert(CGPoint(x: p.x * canvas.zoomScale, y: p.y * canvas.zoomScale), to: view)
    }

    func pageOrigin(_ index: Int) -> CGPoint {
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
    func heldShape(_ stroke: PKStroke) -> ShapeSpec? {
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
    func convertHeldStroke(_ stroke: PKStroke) {
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

    func shapeStrokes(_ spec: ShapeSpec, ink: PKInk, width: CGFloat) -> [PKStroke] {
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

    func refreshElementLayers() {
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

    func updateElement(_ page: Int, _ id: UUID, live: Bool = false, _ change: (inout PageElement) -> Void) {
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
    func hitElement(at p: CGPoint) -> (page: Int, id: UUID)? {
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
    func visibleCenter(on page: Int) -> CGPoint {
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
        var next = tools
        next.kind = kind
        applyToolState(next)
    }

    func insertTextBox(sticky: Bool, at point: CGPoint? = nil) {
        let page = point.map { layout.pageIndex(atY: Double($0.y)) } ?? currentPageIndex()
        let o = pageOrigin(page)
        let local = point.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) } ?? visibleCenter(on: page)
        let size = sticky ? CGSize(width: 180, height: 180) : CGSize(width: 280, height: 44)
        let x = point == nil ? Double(local.x) - Double(size.width) / 2 : Double(local.x)
        let y = point == nil ? Double(local.y) - Double(size.height) / 2 : Double(local.y) - 22
        let element = TextElement(
            frame: Rect(x: x, y: y, width: Double(size.width), height: Double(size.height)),
            font: TextDefaults.font, fontSize: TextDefaults.size, color: sticky ? .ink : tools.currentRGBA,
            fill: sticky ? RGBA(hex: "#FFE98A") : nil
        )
        insertElement(.text(element), page: page, select: false)
        beginTextEditing(page: page, id: element.id)
    }

    func toggleTape(page: Int, id: UUID) {
        updateElement(page, id, live: false) { e in
            if case var .tape(t) = e {
                t.revealed.toggle()
                e = .tape(t)
            }
        }
    }

    func setAllTapes(revealed: Bool) {
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

    func configureSelection() {
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

    func selectElement(_ page: Int, _ id: UUID) {
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

    func updateSelectionBox() {
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
        positionSelectionPill()
    }

    /// La barre d'actions flotte sous l'élément choisi, ou au-dessus s'il touche le bas.
    func positionSelectionPill() {
        guard !selectionPill.isHidden, selection.box != .zero else { return }
        var size = selectionPill.stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        size.width += 12
        let box = selection.box
        let bounds = view.bounds
        let x = min(max(12, box.midX - size.width / 2), bounds.width - 12 - size.width)
        var y = box.maxY + 34
        if y + size.height > bounds.height - view.safeAreaInsets.bottom - 16 { y = box.minY - size.height - 34 }
        y = max(contextRow.frame.maxY + 10, y)
        selectionPill.frame = CGRect(x: x, y: y, width: size.width, height: 52)
    }

    func barButton(_ symbol: String, _ label: String, destructive: Bool = false, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        config.baseForegroundColor = destructive ? Theme.danger : Theme.chromeText
        let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = label
        b.toolTip = label
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    func rebuildSelectionBar() {
        selectionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let s = selected, let e = element(s.page, s.id) else {
            selectionHolder.isHidden = true
            return
        }
        selectionHolder.isHidden = false
        defer { positionSelectionPill() }
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

    func duplicateSelected() {
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

    func reorderSelected(toFront: Bool) {
        guard let s = selected, elements.indices.contains(s.page), let i = elements[s.page].firstIndex(where: { $0.id == s.id }) else { return }
        var copy = elements
        let e = copy[s.page].remove(at: i)
        if toFront { copy[s.page].append(e) } else { copy[s.page].insert(e, at: 0) }
        setElements(copy, actionName: L("element.edit"))
    }

    func deleteSelected() {
        guard let s = selected else { return }
        var copy = elements
        copy[s.page].removeAll { $0.id == s.id }
        clearSelection()
        setElements(copy, actionName: L("common.delete"))
    }

    func presentCrop(page: Int, id: UUID) {
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

    func saveToCollection(page: Int, id: UUID) {
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
            if readOnly { return false }
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

    func tapeRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let h = max(14, abs(b.y - a.y))
        let y = abs(b.y - a.y) < 14 ? a.y - 7 : min(a.y, b.y)
        return CGRect(x: min(a.x, b.x), y: y, width: abs(b.x - a.x), height: h)
    }

    func viewPath(_ lines: [[(x: Double, y: Double)]]) -> CGPath {
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

    func beginTextEditing(page: Int, id: UUID) {
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

    func applyTextStyle(_ t: TextElement) {
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

    func positionTextEditor() {
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
        contextRow.isUserInteractionEnabled = false
        contextRow.alpha = 0.5
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
        contextRow.isUserInteractionEnabled = true
        contextRow.alpha = 1
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

    func blankPage(like index: Int, template: BackgroundKind? = nil) -> PageInfo {
        let model = manifest.pages[min(max(0, index), manifest.pages.count - 1)]
        var bg = model.background
        if let template {
            bg = .standard(template)
            bg.color = model.background.color
        }
        return PageInfo(width: model.width, height: model.height, background: bg)
    }

    func setTemplate(_ kind: BackgroundKind, page index: Int) {
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

    func setPaperColor(_ paper: PaperColor, page index: Int) {
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

    func clearPage(_ index: Int) {
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

    func toggleBookmark(_ index: Int) {
        guard manifest.pages.indices.contains(index) else { return }
        manifest.pages[index].bookmarked.toggle()
        panel.reload()
        markChanged()
    }

    func promptPageTitle(_ index: Int) {
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

    @objc func promptGoToPage() {
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
    func copyPage(_ index: Int, to target: UUID) {
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

    func togglePanel() {
        commitTextEditing()
        let show = panel.isHidden
        if show {
            panel.isHidden = false
            panel.reload(dirty: true)
        }
        view.layoutIfNeeded()
        panelLeading?.constant = show ? 0 : -340
        rebuildToolbar()
        UIView.animate(withDuration: 0.25, animations: { self.view.layoutIfNeeded() }, completion: { _ in
            if !show { self.panel.isHidden = true }
        })
        UIAccessibility.post(notification: .screenChanged, argument: show ? (panel as UIView) : (canvas as UIView))
    }

    var panelPages: [PageInfo] { manifest.pages }
    var panelCurrentIndex: Int { currentPageIndex() }

    var panelStrokes: [[Stroke]]?

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

    var pickerAsPages = false
    var pickerDelegateHolder: AnyObject?

    func pickPhotos(asPages: Bool) {
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

    func takePhoto(asPage: Bool) {
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

    func pickImageFile() {
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

    func scanDocument() {
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

    func addImagePages(_ images: [UIImage]) {
        do {
            let pages = try Importers.imagePages(images, into: store.directory)
            insertPages(pages, at: currentPageIndex() + 1)
        } catch {
            showAlert(L("common.error"), error.localizedDescription)
        }
    }

    func importPDFPages() {
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

    func pageBundle(_ indices: [Int]) -> [(info: PageInfo, strokes: [Stroke], elements: [PageElement])] {
        let strokes = strokesByPage()
        return indices.filter { manifest.pages.indices.contains($0) }.map { (manifest.pages[$0], strokes[$0], elements[$0]) }
    }

    func shareFile(_ url: URL) {
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let source = shareSource ?? toolbar
        share.popoverPresentationController?.sourceView = source
        share.popoverPresentationController?.sourceRect = source.bounds
        present(share, animated: true)
    }

    var baseFileName: String { LibraryStore.safeFileName(entry?.title ?? "Nooty") }

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

    func exportImage(page: Int) {
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

    func exportNooty() {
        saveNow(wait: true)
        do {
            shareFile(try library.exportNooty(itemID))
        } catch {
            showAlert(L("common.error"), error.localizedDescription)
        }
    }

    func printPages() {
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

    func presentSearch() {
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

    func convertHandwriting(page index: Int) {
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

    func finishSave(_ outcome: Result<NotebookStore.SaveResult, Error>, generation: Int) {
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

    func makeThumbnail() -> UIImage? {
        guard let info = manifest.pages.first else { return nil }
        let strokes = strokesByPage().first ?? []
        return PageRenderer.image(info: info, strokes: strokes, elements: elements.first ?? [], resources: store.resourcesDirectory, width: 336)
    }
}
