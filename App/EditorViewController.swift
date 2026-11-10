import NootyCore
import PencilKit
import UIKit

/// Éditeur du prototype : une page A4, l'encre PencilKit, l'enregistrement local et le diagnostic.
final class EditorViewController: UIViewController, PKCanvasViewDelegate {
    private enum Keys {
        static let fingerDraws = "nooty.fingerDraws"
        static let diagnostics = "nooty.diagnostics"
    }

    private let canvas = PKCanvasView()
    private let pageBackground = PageBackgroundView()
    private let toolPicker = PKToolPicker()
    private let store: PageStore?

    private var pageID = UUID()
    private var pageSize = CGSize(width: Page.a4Width, height: Page.a4Height)
    private var background = Background.standard(.ruled)

    private var pendingSave: DispatchWorkItem?
    /// Incrémenté à chaque modification ; une sauvegarde qui le rattrape signifie « tout est enregistré ».
    private var changeGeneration = 0
    private var savedGeneration = 0
    private var isApplyingDrawing = false
    private var didInitialLayout = false
    private var didAppear = false

    private var fingerDraws = UserDefaults.standard.bool(forKey: Keys.fingerDraws)
    private var showDiagnostics = UserDefaults.standard.bool(forKey: Keys.diagnostics)
    private var lastSave: PageStore.SaveResult?
    private var loadMs: Double?
    private var startupMessage: String?

    private let toolbar = UIStackView()
    private let statusLabel = PaddedLabel()
    private let diagnosticsLabel = PaddedLabel()
    private var undoButton: UIButton!
    private var redoButton: UIButton!
    private var fingerButton: UIButton!
    private var moreButton: UIButton!

    init() {
        store = (try? PageStore.defaultDirectory()).map(PageStore.init(directory:))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    // MARK: - Cycle de vie

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.desk

        pageBackground.frame = view.bounds
        pageBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageBackground)

        configureCanvas()
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvas)

        buildToolbar()
        buildLabels()
        loadPage()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(flushForBackground), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(flushForBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
        if !didAppear {
            didAppear = true
            // Le chargement de la page ne doit pas pouvoir être annulé.
            canvas.undoManager?.removeAllActions()
            refreshUndoButtons()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didInitialLayout, view.bounds.width > 0 {
            didInitialLayout = true
            fitWidth()
        }
        centerContent()
        syncBackground()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.centerContent()
            self.syncBackground()
        })
    }

    // MARK: - Canevas

    private func configureCanvas() {
        canvas.delegate = self
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // La page reste claire en mode sombre : l'encre n'est pas inversée.
        canvas.overrideUserInterfaceStyle = .light
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 6
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsHorizontalScrollIndicator = false
        canvas.accessibilityLabel = L("canvas.label")
        toolPicker.overrideUserInterfaceStyle = .unspecified
    }

    private func updateContentSize() {
        canvas.contentSize = CGSize(width: pageSize.width * canvas.zoomScale, height: pageSize.height * canvas.zoomScale)
    }

    private func centerContent() {
        let horizontal = max(16, (canvas.bounds.width - canvas.contentSize.width) / 2)
        let top = view.safeAreaInsets.top + 76
        let bottom = view.safeAreaInsets.bottom + 140
        let inset = UIEdgeInsets(top: top, left: horizontal, bottom: bottom, right: horizontal)
        if canvas.contentInset != inset { canvas.contentInset = inset }
    }

    private func fitWidth() {
        let target = (view.bounds.width - 32) / pageSize.width
        canvas.setZoomScale(min(canvas.maximumZoomScale, max(canvas.minimumZoomScale, target)), animated: false)
        updateContentSize()
        centerContent()
        canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        syncBackground()
        refreshDiagnostics()
    }

    private func syncBackground() {
        pageBackground.place(origin: CGPoint(x: -canvas.contentOffset.x, y: -canvas.contentOffset.y), scale: canvas.zoomScale)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncBackground()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentSize()
        centerContent()
        syncBackground()
        refreshDiagnostics()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        refreshUndoButtons()
        guard !isApplyingDrawing else { return }
        markChanged()
    }

    /// Remplace tout le dessin de façon annulable (effacer la page, test de charge).
    private func replaceDrawing(_ drawing: PKDrawing, actionName: String) {
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceDrawing(old, actionName: actionName)
        }
        canvas.undoManager?.setActionName(actionName)
        canvas.drawing = drawing
        markChanged()
        refreshUndoButtons()
    }

    // MARK: - Enregistrement

    private func loadPage() {
        guard let store else {
            startupMessage = L("save.unavailable")
            setStatus(L("save.unavailable"), error: true)
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            if let page = try store.queue.sync(execute: { try store.load() }) {
                pageID = page.id
                pageSize = CGSize(width: page.width, height: page.height)
                background = page.background
                isApplyingDrawing = true
                canvas.drawing = InkConverter.drawing(page.strokes)
                isApplyingDrawing = false
            }
            loadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            setStatus(L("save.saved"), error: false)
        } catch {
            let moved = store.queue.sync { store.quarantine() }
            let message = L("load.failed", error.localizedDescription, moved ?? "—")
            startupMessage = message
            setStatus(message, error: true)
        }
        pageBackground.pageSize = pageSize
        pageBackground.background = background
        rebuildMenu()
    }

    private func markChanged() {
        changeGeneration += 1
        scheduleSave()
    }

    private func scheduleSave() {
        guard store != nil else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow(wait: false) }
        pendingSave = item
        setStatus(L("save.saving"), error: false)
        // Court délai : regroupe les modifications rapprochées sans laisser une action longtemps non enregistrée.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func saveNow(wait: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        guard let store else { return }
        let drawing = canvas.drawing
        let generation = changeGeneration
        let id = pageID
        let size = pageSize
        let bg = background
        let work = {
            let outcome = Result { try store.save(drawing: drawing, pageID: id, size: size, background: bg) }
            DispatchQueue.main.async { [weak self] in self?.finishSave(outcome, generation: generation) }
        }
        if wait { store.queue.sync(execute: work) } else { store.queue.async(execute: work) }
    }

    private func finishSave(_ outcome: Result<PageStore.SaveResult, Error>, generation: Int) {
        switch outcome {
        case let .success(result):
            savedGeneration = max(savedGeneration, generation)
            lastSave = result
            if savedGeneration >= changeGeneration { setStatus(L("save.saved"), error: false) }
        case let .failure(error):
            setStatus(L("save.error", error.localizedDescription), error: true)
        }
        refreshDiagnostics()
    }

    @objc private func flushForBackground() {
        guard store != nil, pendingSave != nil || savedGeneration < changeGeneration else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "nooty.save")
        saveNow(wait: true)
        UIApplication.shared.endBackgroundTask(task)
    }

    // MARK: - Actions

    private func undo() {
        canvas.undoManager?.undo()
        refreshUndoButtons()
    }

    private func redo() {
        canvas.undoManager?.redo()
        refreshUndoButtons()
    }

    private func toggleFingerDrawing() {
        fingerDraws.toggle()
        UserDefaults.standard.set(fingerDraws, forKey: Keys.fingerDraws)
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        styleToggle(fingerButton, on: fingerDraws)
        refreshDiagnostics()
    }

    private func setBackground(_ kind: BackgroundKind) {
        guard background.kind != kind else { return }
        background = .standard(kind)
        pageBackground.background = background
        markChanged()
        rebuildMenu()
    }

    private func toggleDiagnostics() {
        showDiagnostics.toggle()
        UserDefaults.standard.set(showDiagnostics, forKey: Keys.diagnostics)
        refreshDiagnostics()
        rebuildMenu()
    }

    private func addStressStrokes() {
        let generated = StrokeGenerator.handwriting(
            count: 5000, pageWidth: pageSize.width, pageHeight: pageSize.height, seed: 42,
            createdAt: (Date().timeIntervalSince1970 * 1000).rounded()
        )
        var drawing = canvas.drawing
        drawing.strokes.append(contentsOf: generated.map(InkConverter.pkStroke))
        replaceDrawing(drawing, actionName: L("menu.stress"))
    }

    private func confirmClear() {
        guard !canvas.drawing.strokes.isEmpty else { return }
        let alert = UIAlertController(title: L("clear.title"), message: L("clear.message"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("clear.confirm"), style: .destructive) { [weak self] _ in
            self?.replaceDrawing(PKDrawing(), actionName: L("menu.clear"))
        })
        present(alert, animated: true)
    }

    private func exportPage() {
        guard let store else { return }
        saveNow(wait: true)
        guard FileManager.default.fileExists(atPath: store.fileURL.path) else { return }
        let share = UIActivityViewController(activityItems: [store.fileURL], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = moreButton
        share.popoverPresentationController?.sourceRect = moreButton.bounds
        present(share, animated: true)
    }

    // MARK: - Interface

    private func makeButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    private func styleToggle(_ button: UIButton, on: Bool) {
        var config = on ? UIButton.Configuration.tinted() : UIButton.Configuration.plain()
        config.image = button.configuration?.image
        config.baseForegroundColor = on ? Palette.accent : .label
        config.baseBackgroundColor = Palette.accent
        button.configuration = config
        button.accessibilityValue = on ? L("common.on") : L("common.off")
    }

    private func buildToolbar() {
        undoButton = makeButton("arrow.uturn.backward", L("action.undo")) { [weak self] in self?.undo() }
        redoButton = makeButton("arrow.uturn.forward", L("action.redo")) { [weak self] in self?.redo() }
        fingerButton = makeButton("hand.draw", L("action.fingerDraws")) { [weak self] in self?.toggleFingerDrawing() }
        let fitButton = makeButton("arrow.left.and.right", L("action.fit")) { [weak self] in self?.fitWidth() }
        moreButton = makeButton("ellipsis.circle", L("action.more")) {}
        moreButton.showsMenuAsPrimaryAction = true
        styleToggle(fingerButton, on: fingerDraws)

        let panel = UIView()
        panel.backgroundColor = Palette.panel
        panel.layer.cornerRadius = 16
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor.separator.cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.14
        panel.layer.shadowRadius = 12
        panel.layer.shadowOffset = CGSize(width: 0, height: 4)
        panel.translatesAutoresizingMaskIntoConstraints = false

        toolbar.axis = .horizontal
        toolbar.spacing = 2
        toolbar.alignment = .center
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        for v in [undoButton!, redoButton!, separator(), fingerButton!, fitButton, separator(), moreButton!] {
            toolbar.addArrangedSubview(v)
        }
        panel.addSubview(toolbar)
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
            toolbar.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -4),
            toolbar.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        refreshUndoButtons()
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 28),
        ])
        return v
    }

    private func buildLabels() {
        for label in [statusLabel, diagnosticsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.backgroundColor = Palette.panel
            label.layer.cornerRadius = 12
            label.layer.masksToBounds = true
            label.layer.borderWidth = 1
            label.layer.borderColor = UIColor.separator.cgColor
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            view.addSubview(label)
        }
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityTraits = .updatesFrequently
        diagnosticsLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        diagnosticsLabel.textColor = .label
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -12),
            diagnosticsLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            diagnosticsLabel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            diagnosticsLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -12),
        ])
        refreshDiagnostics()
    }

    private func rebuildMenu() {
        let backgrounds: [(BackgroundKind, String)] = [
            (.blank, L("bg.blank")), (.ruled, L("bg.ruled")), (.grid, L("bg.grid")), (.dots, L("bg.dots")),
        ]
        let bgMenu = UIMenu(title: L("menu.background"), image: UIImage(systemName: "doc.plaintext"), options: .singleSelection, children: backgrounds.map { kind, title in
            UIAction(title: title, state: background.kind == kind ? .on : .off) { [weak self] _ in self?.setBackground(kind) }
        })
        let diagnostics = UIAction(title: L("menu.diagnostics"), image: UIImage(systemName: "gauge.with.dots.needle.33percent"), state: showDiagnostics ? .on : .off) { [weak self] _ in
            self?.toggleDiagnostics()
        }
        let export = UIAction(title: L("menu.export"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportPage() }
        let stress = UIAction(title: L("menu.stress"), image: UIImage(systemName: "speedometer")) { [weak self] _ in self?.addStressStrokes() }
        let clear = UIAction(title: L("menu.clear"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.confirmClear() }
        moreButton.menu = UIMenu(children: [
            bgMenu,
            UIMenu(options: .displayInline, children: [diagnostics, export]),
            UIMenu(options: .displayInline, children: [stress, clear]),
        ])
    }

    private func refreshUndoButtons() {
        undoButton?.isEnabled = canvas.undoManager?.canUndo ?? false
        redoButton?.isEnabled = canvas.undoManager?.canRedo ?? false
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel.text = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabel
    }

    private func refreshDiagnostics() {
        diagnosticsLabel.isHidden = !showDiagnostics
        guard showDiagnostics else { return }
        var rows: [(String, String)] = []
        if let save = lastSave {
            let points = save.page.strokes.reduce(0) { $0 + $1.points.count }
            rows.append((L("diag.strokes"), "\(save.page.strokes.count)"))
            rows.append((L("diag.points"), "\(points)"))
            if let last = save.page.strokes.last, let st = StrokeStats(last) {
                rows.append((L("diag.lastTool"), last.tool.rawValue))
                rows.append((L("diag.force"), String(format: "%.2f – %.2f", st.forceMin, st.forceMax)))
                rows.append((L("diag.altitude"), String(format: "%.0f° – %.0f°", st.altitudeMin, st.altitudeMax)))
                rows.append((L("diag.lastPoints"), String(format: "%d (%.2f s)", st.pointCount, st.durationSeconds)))
            }
            rows.append((L("diag.save"), String(format: "%.0f ms (%.0f ms conversion)", save.totalMs, save.convertMs)))
            rows.append((L("diag.size"), ByteCountFormatter.string(fromByteCount: Int64(save.bytes), countStyle: .file)))
        } else {
            rows.append((L("diag.strokes"), "\(canvas.drawing.strokes.count)"))
        }
        if let loadMs { rows.append((L("diag.load"), String(format: "%.0f ms", loadMs))) }
        rows.append((L("diag.zoom"), String(format: "%.0f %%", canvas.zoomScale * 100)))
        rows.append((L("diag.input"), fingerDraws ? L("diag.input.any") : L("diag.input.pencil")))
        let pad = rows.map(\.0.count).max() ?? 0
        diagnosticsLabel.text = rows.map { $0.0.padding(toLength: pad, withPad: " ", startingAt: 0) + "  " + $0.1 }.joined(separator: "\n")
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
