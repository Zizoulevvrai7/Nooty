import NootyCore
import UIKit

/// Boutons de l'habillage graphite de l'éditeur.
enum ChromeButton {
    static func symbol(_ name: String, size: CGFloat = 19, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight)) ?? UIImage(systemName: "circle")
    }

    /// Bouton carré à pictogramme. Choisi : fond corail léger, pictogramme corail.
    static func make(_ name: String, _ label: String, selected: Bool = false, chevron: Bool = false, title: String? = nil,
                     image: UIImage? = nil, action: ((UIButton) -> Void)? = nil) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = image ?? symbol(name)
        config.baseForegroundColor = selected ? Theme.coral : Theme.chromeText
        config.background.backgroundColor = selected ? Theme.coralWash : .clear
        config.background.cornerRadius = 12
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 9)
        if let title {
            config.title = title
            config.imagePadding = 6
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = Theme.rounded(15, .semibold)
                return a
            }
        }
        if chevron {
            config.indicator = .none
            config.imagePlacement = .leading
        }
        let button = UIButton(configuration: config)
        if let action { button.addAction(UIAction { [weak button] _ in if let button { action(button) } }, for: .primaryActionTriggered) }
        if chevron {
            let mark = UIImageView(image: symbol("chevron.down", size: 10, weight: .bold))
            mark.tintColor = selected ? Theme.coral : Theme.chromeMuted
            mark.isUserInteractionEnabled = false
            mark.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(mark)
            button.configuration?.contentInsets.trailing = 22
            NSLayoutConstraint.activate([
                mark.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -7),
                mark.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        button.accessibilityLabel = label
        button.largeContentTitle = label
        button.showsLargeContentViewer = true
        button.addInteraction(UILargeContentViewerInteraction())
        button.toolTip = label
        if selected { button.accessibilityTraits.insert(.selected) }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 44),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return button
    }

    static func divider(height: CGFloat = 26) -> UIView {
        let v = UIView()
        v.backgroundColor = Theme.chromeLine
        v.isAccessibilityElement = false
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 1), v.heightAnchor.constraint(equalToConstant: height)])
        return v
    }

    /// Pictogramme d'épaisseur : un trait horizontal plus ou moins gras.
    static func widthGlyph(_ thickness: CGFloat) -> UIImage {
        let size = CGSize(width: 28, height: 28)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let t = min(10, max(1.5, thickness))
            UIColor.black.setFill()
            UIBezierPath(roundedRect: CGRect(x: 3, y: (size.height - t) / 2, width: size.width - 6, height: t), cornerRadius: t / 2).fill()
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// Barre principale : trois groupes (navigation, outils, document). Le groupe central défile
/// si la fenêtre est étroite (Split View).
final class EditorToolbar: UIView {
    let leading = UIStackView()
    let center = UIStackView()
    let trailing = UIStackView()
    private let scroll = UIScrollView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.chrome
        for s in [leading, center, trailing] {
            s.axis = .horizontal
            s.alignment = .center
            s.spacing = 4
            s.translatesAutoresizingMaskIntoConstraints = false
        }
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leading)
        addSubview(scroll)
        scroll.addSubview(center)
        addSubview(trailing)
        let fit = scroll.widthAnchor.constraint(equalTo: center.widthAnchor)
        fit.priority = .defaultHigh
        let centered = scroll.centerXAnchor.constraint(equalTo: centerXAnchor)
        centered.priority = .defaultLow
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            leading.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            centered, fit,
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            center.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            center.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            center.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            center.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            center.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = L("tools.label")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    static func fill(_ stack: UIStackView, _ views: [UIView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(stack.addArrangedSubview)
    }
}

/// Pastille flottante : fond graphite relevé, coins très arrondis.
class ChromePill: UIView {
    let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.chromeRaised
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.chromeLine.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }
}

/// Réglages de l'outil courant, sous la barre principale : style, épaisseurs, couleurs.
final class ContextToolBar: ChromePill {
    var state: ToolState { didSet { if state != oldValue { rebuild() } } }
    var onChange: ((ToolState) -> Void)?
    /// Pastille déjà choisie touchée : modifier sa couleur.
    var onEditColor: ((_ index: Int, _ current: UIColor, _ source: UIView) -> Void)?
    /// Épaisseur déjà choisie touchée : régler sa valeur.
    var onEditWidth: ((_ index: Int, _ source: UIView) -> Void)?
    /// Menus de l'outil (type de stylo, gomme, forme, police).
    var onToolMenu: ((_ source: UIView) -> Void)?
    var onFontMenu: ((_ source: UIView) -> Void)?
    var onTextSize: ((_ delta: Double) -> Void)?
    /// Police et taille des nouvelles zones de texte.
    var textStyle: (font: FontFamily, size: Double) = (.system, 17) { didSet { if state.kind == .text { rebuild() } } }

    init(state: ToolState) {
        self.state = state
        super.init(frame: .zero)
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = L("tools.options")
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private func update(_ change: (inout ToolState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    private func add(_ v: UIView) { stack.addArrangedSubview(v) }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch state.kind {
        case .pen, .pencil:
            let symbol = state.kind == .pencil ? "pencil.and.scribble" : state.penStyle.symbol
            let title = state.kind == .pencil ? L("tool.pencil") : state.penStyle.title
            add(ChromeButton.make(symbol, L("pen.style"), selected: true, chevron: true) { [weak self] b in self?.onToolMenu?(b) })
            stack.arrangedSubviews.last?.accessibilityValue = title
            add(ChromeButton.divider())
            addWidths()
            add(ChromeButton.divider())
            addColors()
        case .highlighter:
            addWidths()
            add(ChromeButton.divider())
            addColors()
        case .eraser:
            for mode in EraserMode.allCases {
                add(ChromeButton.make(mode.symbol, mode.title, selected: state.eraserMode == mode) { [weak self] _ in
                    self?.update { $0.eraserMode = mode }
                })
            }
            if state.eraserMode != .stroke {
                add(ChromeButton.divider())
                let labels = [L("eraser.small"), L("eraser.medium"), L("eraser.large")]
                for i in ToolState.eraserSizes.indices {
                    let dot = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { _ in
                        let d: CGFloat = [7, 13, 21][i]
                        UIColor.black.setFill()
                        UIBezierPath(ovalIn: CGRect(x: (26 - d) / 2, y: (26 - d) / 2, width: d, height: d)).fill()
                    }.withRenderingMode(.alwaysTemplate)
                    add(ChromeButton.make("", labels[i], selected: state.eraserSizeIndex == i, image: dot) { [weak self] _ in
                        self?.update { $0.eraserSizeIndex = i }
                    })
                }
            }
            add(ChromeButton.divider())
            add(ChromeButton.make("slider.horizontal.3", L("eraser.options")) { [weak self] b in self?.onToolMenu?(b) })
        case .shape:
            for kind in ShapeKind.allCases {
                add(ChromeButton.make(kind.symbol, kind.title, selected: state.shapeKind == kind) { [weak self] _ in
                    self?.update { $0.shapeKind = kind }
                })
            }
            add(ChromeButton.divider())
            let w = ToolState.width(for: .monoline, factor: state.penWidths[state.penWidthIndex])
            add(ChromeButton.make("", L("shape.stroke"), image: ChromeButton.widthGlyph(w * 1.6)) { [weak self] b in self?.onToolMenu?(b) })
            add(ChromeButton.divider())
            addColors()
        case .text:
            let font = textStyle.font
            var config = UIButton.Configuration.plain()
            config.title = font.displayName
            config.baseForegroundColor = Theme.chromeText
            config.background.backgroundColor = Theme.coralWash
            config.background.cornerRadius = 12
            config.image = ChromeButton.symbol("chevron.down", size: 10, weight: .bold)
            config.imagePlacement = .trailing
            config.imagePadding = 8
            config.titleLineBreakMode = .byTruncatingTail
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = font.font(size: 16)
                return a
            }
            let fontButton = UIButton(configuration: config)
            fontButton.addAction(UIAction { [weak self, weak fontButton] _ in
                if let fontButton { self?.onFontMenu?(fontButton) }
            }, for: .primaryActionTriggered)
            fontButton.accessibilityLabel = L("text.font")
            fontButton.accessibilityValue = font.displayName
            fontButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                fontButton.heightAnchor.constraint(equalToConstant: 44),
                fontButton.widthAnchor.constraint(lessThanOrEqualToConstant: 210),
                fontButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            ])
            add(fontButton)
            add(ChromeButton.make("minus", L("text.smaller")) { [weak self] _ in self?.onTextSize?(-1) })
            let size = UILabel()
            size.text = "\(Int(textStyle.size)) pt"
            size.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            size.textColor = Theme.chromeText
            size.textAlignment = .center
            size.widthAnchor.constraint(equalToConstant: 52).isActive = true
            size.accessibilityLabel = L("text.size", Int(textStyle.size))
            add(size)
            add(ChromeButton.make("plus", L("text.larger")) { [weak self] _ in self?.onTextSize?(1) })
            add(ChromeButton.divider())
            addColors()
        case .tape:
            addColors()
        case .lasso, .laser:
            let hint = UILabel()
            hint.text = L("hint.\(state.kind.rawValue)")
            hint.font = Theme.rounded(14, .medium, style: .footnote)
            hint.textColor = Theme.chromeMuted
            let holder = UIView()
            hint.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.topAnchor.constraint(equalTo: holder.topAnchor),
                hint.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                hint.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
                hint.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
            ])
            add(holder)
        }
    }

    private func addWidths() {
        let labels = [L("width.fine"), L("width.medium"), L("width.thick")]
        let type = state.kind == .highlighter ? PencilInk.marker : state.kind == .pencil ? .pencil : .pen(state.penStyle)
        for i in 0..<ToolState.widthCount {
            let w = type.points(factor: state.widths[i])
            let selected = state.widthIndex == i
            let b = ChromeButton.make("", labels[i], selected: selected, image: ChromeButton.widthGlyph(w * (state.kind == .highlighter ? 0.5 : 1.4))) { [weak self] b in
                guard let self else { return }
                if self.state.widthIndex == i { self.onEditWidth?(i, b) } else { self.update { $0.widthIndex = i } }
            }
            b.accessibilityValue = Measure.mm(w)
            if selected { b.accessibilityHint = L("width.editHint") }
            add(b)
        }
    }

    private func addColors() {
        for (i, hex) in state.colors.enumerated() {
            let color = ToolState.color(hex)
            let selected = state.colorIndex == i
            var config = UIButton.Configuration.plain()
            config.image = Swatch.image(color, selected: selected, diameter: 24)
            config.contentInsets = .zero
            let b = UIButton(configuration: config)
            b.addAction(UIAction { [weak self, weak b] _ in
                guard let self, let b else { return }
                if self.state.colorIndex == i { self.onEditColor?(i, color, b) } else { self.update { $0.colorIndex = i } }
            }, for: .primaryActionTriggered)
            b.accessibilityLabel = ColorNames.name(color)
            b.accessibilityHint = selected ? L("color.editHint") : nil
            if selected { b.accessibilityTraits.insert(.selected) }
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 40), b.heightAnchor.constraint(equalToConstant: 44)])
            add(b)
        }
    }
}

/// Encre du moteur, pour convertir un facteur d'épaisseur en points.
enum PencilInk {
    case pen(PenStyle), pencil, marker

    func points(factor: Double) -> CGFloat {
        switch self {
        case let .pen(style): return ToolState.width(for: style.inkType, factor: factor)
        case .pencil: return ToolState.width(for: .pencil, factor: factor)
        case .marker: return ToolState.width(for: .marker, factor: factor)
        }
    }
}

/// Épaisseurs exprimées en millimètres (1 point de page = 0,3528 mm).
enum Measure {
    static func mm(_ points: CGFloat) -> String {
        let f = NumberFormatter()
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 1
        return (f.string(from: NSNumber(value: Double(points) * 0.3528)) ?? "") + " mm"
    }
}

/// Onglets des documents ouverts : maison à gauche, onglet actif fondu dans la barre d'outils.
final class DocumentTabsView: UIView {
    var onHome: (() -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    /// Menu de l'onglet actif (renommer…).
    var activeMenu: (() -> UIMenu)?
    private let library: LibraryStore
    private let current: UUID
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init(library: LibraryStore, current: UUID) {
        self.library = library
        self.current = current
        super.init(frame: .zero)
        backgroundColor = Theme.chromeDeep
        let home = ChromeButton.make("house", L("tabs.home")) { [weak self] _ in self?.onHome?() }
        home.configuration?.baseForegroundColor = Theme.chromeMuted
        scroll.showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.alignment = .bottom
        stack.spacing = 0
        for v in [home, scroll, stack] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(home)
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            home.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            home.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: home.trailingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        accessibilityLabel = L("tabs.label")
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var ids = library.openTabs
        if !ids.contains(current) { ids.append(current) }
        let tabs = ids.compactMap { library.index.item($0) }
        for entry in tabs { stack.addArrangedSubview(tab(entry)) }
        // Espace libre à droite des onglets.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
    }

    private func tab(_ entry: LibraryEntry) -> UIView {
        let selected = entry.id == current
        let id = entry.id
        let tab = UIView()
        tab.backgroundColor = selected ? Theme.chrome : .clear
        tab.layer.cornerRadius = 12
        tab.layer.cornerCurve = .continuous
        tab.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        var config = UIButton.Configuration.plain()
        config.title = entry.title
        config.baseForegroundColor = selected ? Theme.chromeText : Theme.chromeMuted
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 6)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = Theme.rounded(15, selected ? .semibold : .medium)
            return a
        }
        if selected {
            config.image = ChromeButton.symbol("chevron.down", size: 10, weight: .bold)
            config.imagePlacement = .trailing
            config.imagePadding = 6
        }
        let title = UIButton(configuration: config)
        if selected, let activeMenu {
            title.menu = UIMenu(children: [UIDeferredMenuElement.uncached { done in done(activeMenu().children) }])
            title.showsMenuAsPrimaryAction = true
        } else {
            title.addAction(UIAction { [weak self] _ in self?.onSelect?(id) }, for: .primaryActionTriggered)
        }
        title.accessibilityLabel = entry.title
        if selected { title.accessibilityTraits.insert(.selected) }
        let close = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in self?.onClose?(id) })
        close.setImage(ChromeButton.symbol("xmark", size: 11, weight: .semibold), for: .normal)
        close.tintColor = Theme.chromeMuted
        close.accessibilityLabel = L("tabs.close") + " " + entry.title
        let row = UIStackView(arrangedSubviews: [title, close])
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: tab.topAnchor),
            row.bottomAnchor.constraint(equalTo: tab.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -6),
            close.widthAnchor.constraint(equalToConstant: 36),
            close.heightAnchor.constraint(equalToConstant: 36),
            tab.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            tab.widthAnchor.constraint(greaterThanOrEqualToConstant: selected ? 200 : 150),
            tab.heightAnchor.constraint(equalToConstant: 40),
        ])
        return tab
    }
}

extension EraserMode {
    var symbol: String {
        switch self {
        case .precise: return "smallcircle.filled.circle"
        case .standard: return "eraser"
        case .stroke: return "scribble.variable"
        }
    }
}
