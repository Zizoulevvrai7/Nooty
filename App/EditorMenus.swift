import NootyCore
import PencilKit
import UIKit

/// Police et taille des nouvelles zones de texte, conservées d'une session à l'autre.
enum TextDefaults {
    static var font: FontFamily {
        get { FontFamily(rawValue: UserDefaults.standard.string(forKey: "nooty.text.font") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nooty.text.font") }
    }

    static var size: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "nooty.text.size")
            return v >= 6 && v <= 200 ? v : 17
        }
        set { UserDefaults.standard.set(min(200, max(6, newValue)), forKey: "nooty.text.size") }
    }
}

/// Barre principale et menus de l'éditeur.
extension NotebookViewController {
    // MARK: - Outils

    func applyToolState(_ state: ToolState) {
        tools = state
        tools.save()
        contextBar.state = tools
        applyTool()
        rebuildToolbar()
    }

    private func toolButton(_ kind: ToolKind) -> UIButton {
        let active = tools.kind == kind || (kind == .pen && tools.kind == .pencil)
        let symbol: String
        switch kind {
        case .pen: symbol = tools.kind == .pencil ? "pencil.and.scribble" : tools.penStyle.symbol
        default: symbol = kind.symbol
        }
        return ChromeButton.make(symbol, kind.title, selected: active) { [weak self] b in
            guard let self else { return }
            // Toucher l'outil déjà choisi ouvre ses réglages.
            if active, [.pen, .eraser, .shape].contains(kind) {
                self.presentToolMenu(from: b)
            } else if kind == .pen {
                var next = self.tools
                next.kind = self.lastPenKind
                self.applyToolState(next)
            } else {
                self.setTool(kind)
            }
        }
    }

    /// Le bouton Stylo rend le dernier stylo ou crayon utilisé.
    var lastPenKind: ToolKind {
        get { UserDefaults.standard.string(forKey: "nooty.lastPenKind") == "pencil" ? .pencil : .pen }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nooty.lastPenKind") }
    }

    func rebuildToolbar() {
        if tools.kind == .pen || tools.kind == .pencil { lastPenKind = tools.kind }
        let panelButton = ChromeButton.make("sidebar.left", L("panel.pages"), selected: panelLeading?.constant == 0) { [weak self] _ in self?.togglePanel() }
        let search = ChromeButton.make("magnifyingglass", L("search.title")) { [weak self] _ in self?.presentSearch() }
        let ai = ChromeButton.make("sparkles", L("ai.title")) { [weak self] _ in self?.presentAssistant() }
        let reading = ChromeButton.make(readOnly ? "eye.fill" : "eye", L("readOnly.title"), selected: readOnly,
                                        title: readOnly ? L("readOnly.title") : nil) { [weak self] _ in self?.toggleReadOnly() }
        reading.accessibilityValue = readOnly ? L("readOnly.on") : L("readOnly.off")
        EditorToolbar.fill(toolbar.leading, [panelButton, search, ai, ChromeButton.divider(), reading])

        if readOnly {
            EditorToolbar.fill(toolbar.center, [])
        } else {
            var center: [UIView] = [ToolKind.lasso, .pen, .highlighter, .eraser, .shape, .text, .tape, .laser].map(toolButton)
            center.insert(ChromeButton.divider(), at: 1)
            center.append(ChromeButton.divider())
            center.append(ChromeButton.make("photo.badge.plus", L("insert.title")) { [weak self] b in self?.presentInsertMenu(from: b) })
            EditorToolbar.fill(toolbar.center, center)
        }

        var trailing: [UIView] = []
        if !readOnly {
            let recording = audioController?.isRecording == true
            trailing.append(ChromeButton.make(recording ? "mic.fill" : "mic", L("audio.record"), selected: recording) { [weak self] _ in
                guard let self, let audio = self.audioController else { return }
                if audio.isRecording { audio.presentLiveTranscript() } else { audio.startRecording() }
            })
            trailing.append(ChromeButton.make("doc.badge.plus", L("page.add")) { [weak self] b in self?.presentAddPageMenu(from: b) })
        }
        let share = ChromeButton.make("square.and.arrow.up", L("export.title")) { [weak self] b in self?.presentShareMenu(from: b) }
        shareSource = share
        trailing.append(share)
        trailing.append(ChromeButton.make("ellipsis.circle", L("action.more")) { [weak self] b in self?.presentMoreMenu(from: b) })
        EditorToolbar.fill(toolbar.trailing, trailing)
    }

    func toggleReadOnly() {
        commitTextEditing()
        clearSelection()
        readOnly.toggle()
        contextRow.isHidden = readOnly
        applyTool()
        rebuildToolbar()
        view.setNeedsLayout()
        UIAccessibility.post(notification: .announcement, argument: readOnly ? L("readOnly.on") : L("readOnly.off"))
    }

    func goHome() {
        commitTextEditing()
        navigationController?.popToRootViewController(animated: true)
    }

    /// Menu de l'onglet actif.
    func documentMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: L("item.rename"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.promptRename() },
            UIAction(title: L("page.goTo"), image: UIImage(systemName: "arrow.forward.to.line")) { [weak self] _ in self?.promptGoToPage() },
        ])
    }

    func promptRename() {
        let alert = UIAlertController(title: L("item.rename"), message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.entry?.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("common.save"), style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text else { return }
            self.library.mutate { $0.rename(self.itemID, to: text, now: nowMs()) }
            self.title = self.entry?.title
            self.tabBar.reload()
        })
        present(alert, animated: true)
    }

    // MARK: - Menus des outils

    func presentToolMenu(from source: UIView) {
        switch tools.kind {
        case .pen, .pencil: presentPenMenu(from: source)
        case .eraser: presentEraserMenu(from: source)
        case .shape: presentShapeMenu(from: source)
        default: break
        }
    }

    private func menu(_ title: String, width: CGFloat = 360, _ build: @escaping (SheetMenuController) -> [SheetMenuController.Section]) -> SheetMenuController {
        SheetMenuController(title: title, width: width, build: build)
    }

    private func show(_ menu: SheetMenuController, from source: UIView) {
        commitTextEditing()
        SheetMenuController.present(menu, from: self, source: source)
    }

    private var drawingSettings: [SheetMenuController.Item] {
        [
            .row(.init(L("shape.hold"), symbol: "hand.point.up.left.and.text", subtitle: L("shape.holdHint"), accessory: .toggle(tools.holdToShape, { [weak self] on in
                guard let self else { return }
                var next = self.tools
                next.holdToShape = on
                self.applyToolState(next)
            }))),
            .row(.init(L("action.fingerDraws"), symbol: "hand.draw", accessory: .toggle(fingerDraws, { [weak self] on in
                self?.fingerDraws = on
                self?.applyInputPolicy()
            }))),
        ]
    }

    func presentPenMenu(from source: UIView) {
        let m = menu(L("pen.style")) { [weak self] _ in
            guard let self else { return [] }
            let preview = StrokePreviewView(tool: self.tools)
            // Les trois stylos, puis le crayon.
            var tiles: [SheetMenuController.Tile] = []
            for style in [PenStyle?.some(.fountain), .some(.ball), .some(.brush), nil] {
                let selected = style.map { self.tools.kind == .pen && self.tools.penStyle == $0 } ?? (self.tools.kind == .pencil)
                let title = style?.title ?? L("tool.pencil")
                let symbol = style?.symbol ?? "pencil.and.scribble"
                tiles.append(SheetMenuController.Tile(title: title, image: ChromeButton.symbol(symbol, size: 22), selected: selected) { [weak self] in
                    guard let self else { return }
                    var next = self.tools
                    if let style {
                        next.kind = .pen
                        next.penStyle = style
                    } else {
                        next.kind = .pencil
                    }
                    self.applyToolState(next)
                })
            }
            return [
                .init(nil, [.view(preview, height: 96), .tiles(tiles)]),
                .init(nil, [self.widthSlider(index: self.tools.widthIndex, title: L("width.title")) { [weak preview, weak self] in
                    if let self { preview?.tool = self.tools }
                }]),
                .init(L("menu.settings"), self.drawingSettings),
            ]
        }
        show(m, from: source)
    }

    /// Curseur d'épaisseur d'un préréglage, affiché en millimètres.
    func widthSlider(index: Int, title: String, changed: (() -> Void)? = nil) -> SheetMenuController.Item {
        let type: PencilInk = tools.kind == .highlighter ? .marker : tools.kind == .pencil ? .pencil : .pen(tools.penStyle)
        let factor = tools.widths[min(index, tools.widths.count - 1)]
        return .slider(.init(title: title, value: Float(factor), range: Float(ToolState.widthRange.lowerBound)...Float(ToolState.widthRange.upperBound),
                             format: { Measure.mm(type.points(factor: Double($0))) }) { [weak self] value in
            guard let self else { return }
            var next = self.tools
            next.setWidth(Double(value), at: index)
            self.tools = next
            self.tools.save()
            self.contextBar.state = next
            self.applyTool()
            changed?()
        })
    }

    func presentWidthMenu(index: Int, from source: UIView) {
        let m = menu(L("width.settings"), width: 340) { [weak self] _ in
            guard let self else { return [] }
            return [.init(nil, [self.widthSlider(index: index, title: L("width.title"))])]
        }
        show(m, from: source)
    }

    func presentEraserMenu(from source: UIView) {
        let m = menu(L("tool.eraser")) { [weak self] _ in
            guard let self else { return [] }
            let modes = EraserMode.allCases.map { mode in
                SheetMenuController.Tile(title: mode.title, image: ChromeButton.symbol(mode.symbol, size: 22), selected: self.tools.eraserMode == mode) { [weak self] in
                    guard let self else { return }
                    var next = self.tools
                    next.eraserMode = mode
                    self.applyToolState(next)
                }
            }
            var sections: [SheetMenuController.Section] = [.init(L("eraser.mode"), [.tiles(modes)])]
            if self.tools.eraserMode != .stroke {
                let labels = [L("eraser.small"), L("eraser.medium"), L("eraser.large")]
                let sizes = ToolState.eraserSizes.indices.map { i in
                    SheetMenuController.Tile(title: labels[i], image: ChromeButton.symbol("circle.fill", size: [8, 14, 22][i]), selected: self.tools.eraserSizeIndex == i) { [weak self] in
                        guard let self else { return }
                        var next = self.tools
                        next.eraserSizeIndex = i
                        self.applyToolState(next)
                    }
                }
                sections.append(.init(L("eraser.size"), [.tiles(sizes)]))
            }
            let page = self.currentPageIndex()
            sections.append(.init(nil, [
                .row(.init(L("page.clear"), symbol: "eraser.line.dashed", subtitle: L("page.number", page + 1), destructive: true) { [weak self] in
                    self?.clearPage(page)
                }),
            ]))
            return sections
        }
        show(m, from: source)
    }

    func presentShapeMenu(from source: UIView) {
        let m = menu(L("shape.stroke")) { [weak self] _ in
            guard let self else { return [] }
            let kinds = ShapeKind.allCases.map { kind in
                SheetMenuController.Tile(title: kind.title, image: ChromeButton.symbol(kind.symbol, size: 20), selected: self.tools.shapeKind == kind) { [weak self] in
                    guard let self else { return }
                    var next = self.tools
                    next.shapeKind = kind
                    self.applyToolState(next)
                }
            }
            let width = Float(self.tools.penWidths[self.tools.penWidthIndex])
            return [
                .init(nil, [.tiles(Array(kinds.prefix(3))), .tiles(Array(kinds.dropFirst(3)))]),
                .init(nil, [.slider(.init(title: L("width.title"), value: width,
                                          range: Float(ToolState.widthRange.lowerBound)...Float(ToolState.widthRange.upperBound),
                                          format: { Measure.mm(ToolState.width(for: .monoline, factor: Double($0))) }) { [weak self] value in
                    guard let self else { return }
                    var next = self.tools
                    next.penWidths[next.penWidthIndex] = Double(value)
                    self.tools = next
                    self.tools.save()
                    self.contextBar.state = next
                })]),
                .init(L("menu.settings"), [self.drawingSettings[0]]),
            ]
        }
        show(m, from: source)
    }

    // MARK: - Texte

    func presentFontMenu(from source: UIView) {
        let editing = editingTextElement()
        let current = editing?.font ?? TextDefaults.font
        let m = menu(L("text.font"), width: 340) { [weak self] _ in
            FontFamily.Group.allCases.compactMap { group -> SheetMenuController.Section? in
                let fonts = FontFamily.available.filter { $0.group == group }
                guard !fonts.isEmpty else { return nil }
                return SheetMenuController.Section(group.title, fonts.map { family -> SheetMenuController.Item in
                    .row(SheetMenuController.Row(family.displayName, accessory: .check(family == current), font: family.font(size: 19)) { [weak self] in
                        self?.chooseFont(family)
                    })
                })
            }
        }
        SheetMenuController.present(m, from: self, source: source)
    }

    func chooseFont(_ family: FontFamily) {
        TextDefaults.font = family
        contextBar.textStyle = (TextDefaults.font, TextDefaults.size)
        if editingTextElement() != nil {
            changeEditingText { $0.font = family }
            (textEditor?.inputAccessoryView as? TextFormatBar)?.refresh()
        }
    }

    func changeTextSize(by delta: Double) {
        TextDefaults.size = TextDefaults.size + delta
        contextBar.textStyle = (TextDefaults.font, TextDefaults.size)
    }

    // MARK: - Pages

    /// Position d'insertion choisie dans le menu « Ajouter une page ».
    private static var addPosition = 1

    func presentAddPageMenu(from source: UIView) {
        let current = currentPageIndex()
        let m = menu(L("page.add"), width: 380) { [weak self] _ in
            guard let self else { return [] }
            let info = self.manifest.pages[min(current, self.manifest.pages.count - 1)]
            let target: () -> Int = { [weak self] in
                switch Self.addPosition {
                case 0: return current
                case 1: return current + 1
                default: return self?.manifest.pages.count ?? 0
                }
            }
            let tiles = NewNotebookViewController.templates.map { kind, key in
                var bg = Background.standard(kind)
                bg.color = info.background.color
                let thumb = PaperRenderer.image(bg, pageSize: CGSize(width: info.width, height: info.height), width: 120)
                return SheetMenuController.Tile(title: L(key), image: thumb, thumbnail: true, selected: kind == info.background.kind) { [weak self] in
                    guard let self else { return }
                    self.presentedViewController?.dismiss(animated: true)
                    self.insertPages([self.blankPage(like: current, template: kind)], at: target())
                }
            }
            return [
                .init(nil, [.segmented([L("page.before"), L("page.after"), L("page.last")], selected: Self.addPosition, { Self.addPosition = $0 })]),
                .init(L("page.templates"), [.tiles(tiles)]),
                .init(nil, [
                    .row(.init(L("page.fromImage"), symbol: "photo") { [weak self] in self?.pickPhotos(asPages: true) }),
                    .row(.init(L("page.fromScan"), symbol: "doc.viewfinder") { [weak self] in self?.scanDocument() }),
                    .row(.init(L("page.fromCamera"), symbol: "camera") { [weak self] in self?.takePhoto(asPage: true) }),
                    .row(.init(L("page.fromPDF"), symbol: "square.and.arrow.down") { [weak self] in self?.importPDFPages() }),
                ]),
            ]
        }
        show(m, from: source)
    }

    func presentTemplateMenu(page index: Int) -> SheetMenuController {
        menu(L("page.template")) { [weak self] _ in
            guard let self, self.manifest.pages.indices.contains(index) else { return [] }
            let info = self.manifest.pages[index]
            let tiles = NewNotebookViewController.templates.map { kind, key in
                var bg = Background.standard(kind)
                bg.color = info.background.color
                return SheetMenuController.Tile(title: L(key), image: PaperRenderer.image(bg, pageSize: CGSize(width: info.width, height: info.height), width: 120),
                                                thumbnail: true, selected: kind == info.background.kind) { [weak self] in self?.setTemplate(kind, page: index) }
            }
            let papers = NewNotebookViewController.papers
            let selected = papers.firstIndex { $0.0.rgba == info.background.color }
            return [
                .init(nil, [.tiles(tiles)]),
                .init(L("new.paperColor"), [.swatches(papers.map { InkConverter.uiColor($0.0.rgba) }, selected: selected, { [weak self] i in
                    self?.setPaperColor(papers[i].0, page: index)
                })]),
            ]
        }
    }

    func presentShareMenu(from source: UIView) {
        let current = currentPageIndex()
        let m = menu(L("export.title")) { [weak self] _ in
            guard let self else { return [] }
            let all = Array(self.manifest.pages.indices)
            return [
                .init(L("export.thisPage"), [
                    .row(.init(L("export.pagePDF"), symbol: "doc.richtext") { [weak self] in self?.exportPDF(pages: [current]) }),
                    .row(.init(L("export.pageImage"), symbol: "photo") { [weak self] in self?.exportImage(page: current) }),
                ]),
                .init(L("export.everything"), [
                    .row(.init(L("export.allPDF"), symbol: "doc.on.doc") { [weak self] in self?.exportPDF(pages: all) }),
                    .row(.init(L("export.allPDFNoPaper"), symbol: "doc") { [weak self] in self?.exportPDF(pages: all, paper: false) }),
                    .row(.init(L("export.nooty"), symbol: "shippingbox", subtitle: L("export.nootyHint")) { [weak self] in self?.exportNooty() }),
                    .row(.init(L("export.print"), symbol: "printer", accessory: .chevron) { [weak self] in self?.printPages() }),
                ]),
            ]
        }
        show(m, from: source)
    }

    func presentMoreMenu(from source: UIView) {
        let index = currentPageIndex()
        let m = menu(L("action.more"), width: 380) { [weak self] menu in
            guard let self, self.manifest.pages.indices.contains(index) else { return [] }
            let info = self.manifest.pages[index]
            let header = PageHeaderView(title: L("page.number", index + 1), subtitle: info.title,
                                        image: self.panelThumbnail(index, width: 80))
            let count = self.manifest.pages.count
            let targets = self.library.index.items.filter {
                $0.kind == .notebook && $0.id != self.itemID && !self.library.index.isEffectivelyTrashed($0.id) && !$0.locked
            }
            let copyTo = SheetMenuController(title: L("page.copyTo")) { [weak self] _ in
                guard !targets.isEmpty else { return [.init(nil, [.row(.init(L("page.noOtherNotebook"), enabled: false))])] }
                return [SheetMenuController.Section(nil, targets.map { t -> SheetMenuController.Item in
                    .row(SheetMenuController.Row(t.title, symbol: "book.closed") { [weak self] in self?.copyPage(index, to: t.id) })
                })]
            }
            return [
                .init(nil, [
                    .view(header, height: 72),
                    .row(.init(info.bookmarked ? L("page.unbookmark") : L("page.bookmark"), symbol: info.bookmarked ? "bookmark.fill" : "bookmark") { [weak self] in
                        self?.toggleBookmark(index)
                    }),
                    .row(.init(L("page.duplicate"), symbol: "plus.square.on.square") { [weak self] in self?.duplicatePage(index) }),
                    .row(.init(L("page.copyTo"), symbol: "doc.on.doc", accessory: .chevron, dismisses: false) { [weak menu] in menu?.push(copyTo) }),
                    .row(.init(L("outline.add"), symbol: "list.bullet.indent", accessory: info.title.map { SheetMenuController.Accessory.value($0) } ?? SheetMenuController.Accessory.none) { [weak self] in
                        self?.promptPageTitle(index)
                    }),
                    .row(.init(L("page.template"), symbol: "paintpalette", accessory: .chevron, dismisses: false) { [weak self, weak menu] in
                        guard let self else { return }
                        menu?.push(self.presentTemplateMenu(page: index))
                    }),
                    .row(.init(L("page.goTo"), symbol: "arrow.right.square", accessory: .value("1–\(count)")) { [weak self] in self?.promptGoToPage() }),
                ]),
                .init(L("menu.study"), [
                    .row(.init(L("ocr.convert"), symbol: "text.viewfinder") { [weak self] in self?.convertHandwriting(page: index) }),
                    .row(.init(L("cards.title"), symbol: "rectangle.on.rectangle.angled") { [weak self] in self?.presentFlashcards() }),
                    .row(.init(L("audio.recordings"), symbol: "waveform", accessory: .value("\(self.manifest.recordings.count)")) { [weak self] in
                        self?.audioController?.presentRecordings()
                    }),
                    .row(.init(L("tape.revealAll"), symbol: "eye") { [weak self] in self?.setAllTapes(revealed: true) }),
                    .row(.init(L("tape.hideAll"), symbol: "eye.slash") { [weak self] in self?.setAllTapes(revealed: false) }),
                ]),
                .init(L("page.clearOrDelete"), [
                    .row(.init(L("page.clear"), symbol: "eraser.line.dashed", destructive: true) { [weak self] in self?.clearPage(index) }),
                    .row(.init(L("page.delete"), symbol: "trash", destructive: true, enabled: count > 1) { [weak self] in self?.confirmDeletePage(index) }),
                ]),
                .init(L("menu.settings"), self.drawingSettings + [
                    .row(.init(L("action.fit"), symbol: "arrow.left.and.right") { [weak self] in self?.fitWidth() }),
                ]),
            ]
        }
        show(m, from: source)
    }

    // MARK: - Insertion

    func presentInsertMenu(from source: UIView) {
        let m = menu(L("insert.title")) { [weak self] _ in
            guard self != nil else { return [] }
            let collection = ElementCollection.shared.items().prefix(12)
            var saved: [SheetMenuController.Item] = collection.map { url -> SheetMenuController.Item in
                .row(.init(L("collection.item"), image: ElementCollection.shared.thumbnail(url)) { [weak self] in
                    if let image = UIImage(contentsOfFile: url.path) { self?.insertImage(image) }
                })
            }
            if saved.isEmpty { saved = [.row(.init(L("collection.empty"), enabled: false))] }
            return [
                .init(nil, [
                    .row(.init(L("insert.photos"), symbol: "photo.on.rectangle") { [weak self] in self?.pickPhotos(asPages: false) }),
                    .row(.init(L("insert.camera"), symbol: "camera") { [weak self] in self?.takePhoto(asPage: false) }),
                    .row(.init(L("insert.files"), symbol: "folder") { [weak self] in self?.pickImageFile() }),
                    .row(.init(L("insert.paste"), symbol: "doc.on.clipboard", enabled: UIPasteboard.general.hasImages) { [weak self] in
                        if let image = UIPasteboard.general.image { self?.insertImage(image) }
                    }),
                ]),
                .init(nil, [
                    .row(.init(L("insert.text"), symbol: "textformat") { [weak self] in self?.insertTextBox(sticky: false) }),
                    .row(.init(L("insert.sticky"), symbol: "note.text") { [weak self] in self?.insertTextBox(sticky: true) }),
                ]),
                .init(L("collection.title"), saved),
            ]
        }
        show(m, from: source)
    }

    // MARK: - Panneau

    func panelToggleBookmark(_ index: Int) { toggleBookmark(index) }

    func panelAddPage() {
        insertPages([blankPage(like: manifest.pages.count - 1)], at: manifest.pages.count)
        panel.reload(dirty: true)
    }
}

/// Aperçu du trait : une courbe tracée par le vrai moteur d'encre avec l'outil courant.
final class StrokePreviewView: UIView {
    var tool: ToolState { didSet { setNeedsLayout() } }
    private let imageView = UIImageView()

    init(tool: ToolState) {
        self.tool = tool
        super.init(frame: .zero)
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, let ink = tool.pkTool as? PKInkingTool else { return }
        // Une encre trop sombre sur le graphite est montrée claire, comme sur papier noir.
        var color = ink.color
        var white: CGFloat = 0
        color.getWhite(&white, alpha: nil)
        if white < 0.3 { color = Theme.chromeText }
        let w = bounds.width * 0.6, h = bounds.height * 0.5
        let x0 = (bounds.width - w) / 2, y0 = bounds.height / 2
        let points = (0...60).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 60
            let y = y0 + sin(t * .pi * 2 - .pi / 2) * h * -0.45
            // Pression croissante puis décroissante : les encres sensibles s'élargissent au centre.
            let force = 0.3 + sin(t * .pi) * 1.4
            return PKStrokePoint(location: CGPoint(x: x0 + t * w, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: ink.width, height: ink.width),
                                 opacity: 1, force: force, azimuth: .pi / 4, altitude: .pi / 3)
        }
        let stroke = PKStroke(ink: PKInk(ink.inkType, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()),
                              transform: .identity, mask: nil)
        let drawing = PKDrawing(strokes: [stroke])
        imageView.image = drawing.image(from: bounds, scale: window?.screen.scale ?? 2)
    }
}

/// En-tête du menu Options : la page courante et sa miniature.
final class PageHeaderView: UIView {
    init(title: String, subtitle: String?, image: UIImage?) {
        super.init(frame: .zero)
        backgroundColor = Theme.sheetCard
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        let label = UILabel()
        label.text = title
        label.font = Theme.rounded(19, .semibold, style: .title3)
        label.textColor = Theme.chromeText
        let sub = UILabel()
        sub.text = subtitle
        sub.font = .preferredFont(forTextStyle: .footnote)
        sub.textColor = Theme.chromeMuted
        sub.isHidden = subtitle == nil
        let texts = UIStackView(arrangedSubviews: [label, sub])
        texts.axis = .vertical
        let thumb = UIImageView(image: image)
        thumb.contentMode = .scaleAspectFit
        thumb.backgroundColor = .white
        thumb.layer.cornerRadius = 4
        thumb.clipsToBounds = true
        let row = UIStackView(arrangedSubviews: [texts, thumb])
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            thumb.widthAnchor.constraint(equalToConstant: 42),
            thumb.heightAnchor.constraint(equalToConstant: 56),
        ])
        isAccessibilityElement = true
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }
}
