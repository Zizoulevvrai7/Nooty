import UIKit

/// Menu déroulant de l'éditeur : un panneau graphite, titré, fait de sections empilées
/// (aperçu, tuiles de choix, curseurs, lignes d'action). Peut ouvrir un sous-menu.
final class SheetMenuController: UIViewController, UIPopoverPresentationControllerDelegate {
    struct Section {
        var title: String?
        var items: [Item]
        init(_ title: String? = nil, _ items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    enum Item {
        /// Vue libre (aperçu du trait, en-tête de page…) à hauteur fixe.
        case view(UIView, height: CGFloat)
        /// Grandes tuiles de choix exclusif, côte à côte.
        case tiles([Tile])
        /// Contrôle segmenté.
        case segmented([String], selected: Int, (Int) -> Void)
        case slider(Slider)
        case row(Row)
        /// Pastilles de couleur ; `nil` dans la liste = « aucune ».
        case swatches([UIColor?], selected: Int?, (Int) -> Void)
    }

    struct Tile {
        var title: String
        var image: UIImage?
        /// Miniature de papier plutôt que pictogramme.
        var thumbnail = false
        var selected = false
        var action: () -> Void
    }

    struct Slider {
        var title: String
        var value: Float
        var range: ClosedRange<Float>
        var format: (Float) -> String
        var onChange: (Float) -> Void
    }

    enum Accessory {
        case none, chevron, check(Bool), value(String)
        case toggle(Bool, (Bool) -> Void)
    }

    struct Row {
        var title: String
        var symbol: String?
        var image: UIImage?
        var subtitle: String?
        var accessory: Accessory = .none
        var destructive = false
        var enabled = true
        var font: UIFont?
        /// Ferme le menu avant d'agir (nécessaire si l'action présente une autre vue).
        var dismisses = true
        var action: (() -> Void)?

        init(_ title: String, symbol: String? = nil, image: UIImage? = nil, subtitle: String? = nil, accessory: Accessory = .none,
             destructive: Bool = false, enabled: Bool = true, font: UIFont? = nil, dismisses: Bool = true, action: (() -> Void)? = nil) {
            self.title = title
            self.symbol = symbol
            self.image = image
            self.subtitle = subtitle
            self.accessory = accessory
            self.destructive = destructive
            self.enabled = enabled
            self.font = font
            self.dismisses = dismisses
            self.action = action
        }
    }

    private let menuTitle: String
    private let build: (SheetMenuController) -> [Section]
    private let width: CGFloat
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let header = UIView()
    private let titleLabel = UILabel()
    private let back = UIButton(type: .system)

    init(title: String, width: CGFloat = 360, build: @escaping (SheetMenuController) -> [Section]) {
        menuTitle = title
        self.build = build
        self.width = width
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    // MARK: - Présentation

    /// Ouvre le menu en bulle, accroché à `source`.
    static func present(_ menu: SheetMenuController, from host: UIViewController, source: UIView? = nil, item: UIBarButtonItem? = nil, rect: CGRect? = nil) {
        let nav = UINavigationController(rootViewController: menu)
        nav.setNavigationBarHidden(true, animated: false)
        nav.overrideUserInterfaceStyle = .dark
        nav.view.backgroundColor = Theme.sheet
        nav.modalPresentationStyle = .popover
        if let pop = nav.popoverPresentationController {
            if let item {
                pop.sourceItem = item
            } else if let source {
                pop.sourceView = source
                pop.sourceRect = rect ?? source.bounds
            }
            pop.permittedArrowDirections = [.up, .down, .left, .right]
            pop.backgroundColor = Theme.sheet
            pop.delegate = menu
        }
        host.present(nav, animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func push(_ child: SheetMenuController) {
        navigationController?.pushViewController(child, animated: true)
    }

    /// Ferme le menu, puis exécute `then` (une alerte ou un sélecteur peut alors s'ouvrir).
    func close(then: (() -> Void)? = nil) {
        guard let presenter = navigationController?.presentingViewController ?? presentingViewController else {
            then?()
            return
        }
        presenter.dismiss(animated: true) { then?() }
    }

    // MARK: - Construction

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.sheet
        overrideUserInterfaceStyle = .dark

        titleLabel.text = menuTitle
        titleLabel.font = Theme.rounded(17, .semibold, style: .headline)
        titleLabel.textColor = Theme.chromeText
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        var backConfig = UIButton.Configuration.filled()
        backConfig.image = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        backConfig.baseBackgroundColor = Theme.sheetCard
        backConfig.baseForegroundColor = Theme.chromeText
        backConfig.cornerStyle = .capsule
        back.configuration = backConfig
        back.accessibilityLabel = L("common.back")
        back.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .primaryActionTriggered)

        for v in [titleLabel, back] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        view.addSubview(header)
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 58),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: back.trailingAnchor, constant: 8),
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 40),
            back.heightAnchor.constraint(equalToConstant: 40),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        back.isHidden = (navigationController?.viewControllers.first ?? self) === self
        updateSize()
    }

    /// Reconstruit le contenu à partir de l'état courant.
    func reload() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for section in build(self) {
            if let title = section.title {
                let label = UILabel()
                label.text = title
                label.font = Theme.rounded(15, .semibold, style: .subheadline)
                label.textColor = Theme.chromeMuted
                label.accessibilityTraits = .header
                let holder = UIView()
                label.translatesAutoresizingMaskIntoConstraints = false
                holder.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8),
                    label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                    label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 10),
                    label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -10),
                ])
                stack.addArrangedSubview(holder)
            }
            // Lignes et curseurs consécutifs partagent une même carte.
            var card: UIStackView?
            func flush() { card = nil }
            for item in section.items {
                switch item {
                case let .row(row):
                    if card == nil { card = newCard() }
                    if card!.arrangedSubviews.count > 0 { card!.addArrangedSubview(separator()) }
                    card!.addArrangedSubview(rowView(row))
                case let .slider(s):
                    if card == nil { card = newCard() }
                    if card!.arrangedSubviews.count > 0 { card!.addArrangedSubview(separator()) }
                    card!.addArrangedSubview(sliderView(s))
                case let .view(v, height):
                    flush()
                    v.translatesAutoresizingMaskIntoConstraints = false
                    v.heightAnchor.constraint(equalToConstant: height).isActive = true
                    stack.addArrangedSubview(v)
                case let .tiles(tiles):
                    flush()
                    stack.addArrangedSubview(tilesView(tiles))
                case let .segmented(items, selected, action):
                    flush()
                    let control = UISegmentedControl(items: items)
                    control.selectedSegmentIndex = selected
                    control.selectedSegmentTintColor = Theme.chromeLine
                    control.backgroundColor = Theme.sheetCard
                    control.setTitleTextAttributes([.foregroundColor: Theme.chromeText, .font: Theme.rounded(14, .medium)], for: .normal)
                    control.addAction(UIAction { [weak control] _ in action(control?.selectedSegmentIndex ?? 0) }, for: .valueChanged)
                    control.heightAnchor.constraint(equalToConstant: 40).isActive = true
                    stack.addArrangedSubview(control)
                case let .swatches(colors, selected, action):
                    flush()
                    stack.addArrangedSubview(swatchesView(colors, selected: selected, action: action))
                }
            }
        }
        updateSize()
    }

    private func updateSize() {
        guard isViewLoaded else { return }
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: width - 32, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let size = CGSize(width: width, height: min(720, fitting.height + 58 + 16))
        preferredContentSize = size
        navigationController?.preferredContentSize = size
    }

    private func newCard() -> UIStackView {
        let card = UIStackView()
        card.axis = .vertical
        card.backgroundColor = Theme.sheetCard
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        stack.addArrangedSubview(card)
        return card
    }

    private func separator() -> UIView {
        let holder = UIView()
        let line = UIView()
        line.backgroundColor = Theme.chromeLine
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
        ])
        return holder
    }

    // MARK: - Lignes

    private func rowView(_ row: Row) -> UIView {
        let tint = row.destructive ? Theme.danger : Theme.chromeText
        let button = MenuRowButton()
        button.isEnabled = row.enabled
        let h = UIStackView()
        h.axis = .horizontal
        h.alignment = .center
        h.spacing = 14
        h.isUserInteractionEnabled = false
        h.translatesAutoresizingMaskIntoConstraints = false
        if let image = row.image ?? row.symbol.flatMap({ UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)) }) {
            let icon = UIImageView(image: image)
            icon.tintColor = tint
            icon.contentMode = .center
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            h.addArrangedSubview(icon)
        }
        let texts = UIStackView()
        texts.axis = .vertical
        texts.spacing = 2
        let title = UILabel()
        title.text = row.title
        title.font = row.font ?? UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17))
        title.adjustsFontForContentSizeCategory = true
        title.textColor = row.enabled ? tint : Theme.chromeMuted
        title.numberOfLines = 0
        texts.addArrangedSubview(title)
        if let subtitle = row.subtitle {
            let sub = UILabel()
            sub.text = subtitle
            sub.font = .preferredFont(forTextStyle: .footnote)
            sub.textColor = Theme.chromeMuted
            sub.numberOfLines = 0
            texts.addArrangedSubview(sub)
        }
        h.addArrangedSubview(texts)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var accessibilityValue: String?
        switch row.accessory {
        case .none: break
        case .chevron:
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
            chevron.tintColor = Theme.chromeMuted
            h.addArrangedSubview(chevron)
        case let .check(on):
            let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
            check.tintColor = Theme.coral
            check.alpha = on ? 1 : 0
            h.addArrangedSubview(check)
            if on { button.accessibilityTraits.insert(.selected) }
        case let .value(text):
            let value = UILabel()
            value.text = text
            value.textColor = Theme.chromeMuted
            value.font = .preferredFont(forTextStyle: .body)
            h.addArrangedSubview(value)
            accessibilityValue = text
        case let .toggle(on, change):
            let toggle = UISwitch()
            toggle.isOn = on
            toggle.onTintColor = Theme.coral
            toggle.addAction(UIAction { [weak toggle] _ in change(toggle?.isOn ?? false) }, for: .valueChanged)
            toggle.accessibilityLabel = row.title
            // Le texte reste lisible ; l'interrupteur porte l'interaction.
            h.isUserInteractionEnabled = true
            title.isUserInteractionEnabled = false
            h.addArrangedSubview(toggle)
        }
        button.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: button.topAnchor, constant: 12),
            h.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -12),
            h.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            h.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
        if case .toggle = row.accessory {
            button.isAccessibilityElement = false
            return button
        }
        button.isAccessibilityElement = true
        button.accessibilityLabel = [row.title, row.subtitle].compactMap { $0 }.joined(separator: ", ")
        button.accessibilityValue = accessibilityValue
        button.accessibilityTraits.insert(.button)
        if let action = row.action {
            let dismisses = row.dismisses
            button.addAction(UIAction { [weak self] _ in
                if dismisses { self?.close(then: action) } else { action() }
            }, for: .primaryActionTriggered)
        }
        return button
    }

    private func sliderView(_ s: Slider) -> UIView {
        let title = UILabel()
        title.text = s.title
        title.font = Theme.rounded(14, .medium, style: .subheadline)
        title.textColor = Theme.chromeText
        let value = UILabel()
        value.text = s.format(s.value)
        value.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        value.textColor = Theme.chromeMuted
        value.setContentHuggingPriority(.required, for: .horizontal)
        let slider = UISlider()
        slider.minimumValue = s.range.lowerBound
        slider.maximumValue = s.range.upperBound
        slider.value = s.value
        slider.minimumTrackTintColor = Theme.coral
        slider.maximumTrackTintColor = Theme.chromeLine
        slider.accessibilityLabel = s.title
        slider.accessibilityValue = s.format(s.value)
        let format = s.format, change = s.onChange
        slider.addAction(UIAction { [weak slider, weak value] _ in
            guard let slider else { return }
            value?.text = format(slider.value)
            slider.accessibilityValue = format(slider.value)
            change(slider.value)
        }, for: .valueChanged)
        let top = UIStackView(arrangedSubviews: [title, value])
        let v = UIStackView(arrangedSubviews: [top, slider])
        v.axis = .vertical
        v.spacing = 6
        v.isLayoutMarginsRelativeArrangement = true
        v.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16)
        return v
    }

    private func tilesView(_ tiles: [Tile]) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        for tile in tiles {
            let b = MenuRowButton()
            b.layer.cornerRadius = 16
            b.layer.cornerCurve = .continuous
            b.backgroundColor = tile.selected && !tile.thumbnail ? Theme.sheetCard : .clear
            let icon = UIImageView(image: tile.image)
            icon.contentMode = .scaleAspectFit
            icon.tintColor = tile.selected ? Theme.coral : Theme.chromeText
            if tile.thumbnail {
                icon.layer.cornerRadius = 6
                icon.layer.cornerCurve = .continuous
                icon.clipsToBounds = true
                icon.layer.borderWidth = tile.selected ? 3 : 1
                icon.layer.borderColor = (tile.selected ? Theme.coral : Theme.chromeLine).cgColor
            }
            let label = UILabel()
            label.text = tile.title
            label.font = Theme.rounded(13, tile.selected ? .semibold : .regular, style: .caption1)
            label.textColor = tile.selected ? Theme.chromeText : Theme.chromeMuted
            label.textAlignment = .center
            label.numberOfLines = 2
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            let v = UIStackView(arrangedSubviews: [icon, label])
            v.axis = .vertical
            v.alignment = .center
            v.spacing = 8
            v.isUserInteractionEnabled = false
            v.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: b.topAnchor, constant: 12),
                v.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -10),
                v.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 4),
                v.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -4),
                icon.heightAnchor.constraint(equalToConstant: tile.thumbnail ? 84 : 28),
                icon.widthAnchor.constraint(equalToConstant: tile.thumbnail ? 60 : 32),
            ])
            b.isAccessibilityElement = true
            b.accessibilityLabel = tile.title
            b.accessibilityTraits = tile.selected ? [.button, .selected] : .button
            let action = tile.action
            b.addAction(UIAction { [weak self] _ in
                action()
                self?.reload()
            }, for: .primaryActionTriggered)
            row.addArrangedSubview(b)
        }
        return row
    }

    private func swatchesView(_ colors: [UIColor?], selected: Int?, action: @escaping (Int) -> Void) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .equalSpacing
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        for (i, color) in colors.enumerated() {
            let b = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in
                action(i)
                self?.reload()
            })
            b.configuration?.image = Swatch.image(color, selected: i == selected, diameter: 30)
            b.configuration?.contentInsets = .zero
            b.accessibilityLabel = color.map(ColorNames.name) ?? L("text.noFill")
            if i == selected { b.accessibilityTraits.insert(.selected) }
            b.widthAnchor.constraint(equalToConstant: 42).isActive = true
            b.heightAnchor.constraint(equalToConstant: 42).isActive = true
            row.addArrangedSubview(b)
        }
        return row
    }
}

/// Bouton qui s'éclaircit sous le doigt, servant de fond aux lignes et tuiles.
final class MenuRowButton: UIControl {
    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.5 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addAction(UIAction { _ in }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        if let touch, bounds.contains(touch.location(in: self)) { sendActions(for: .primaryActionTriggered) }
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .primaryActionTriggered)
        return true
    }
}

/// Pastilles de couleur dessinées : anneau corail autour de la couleur choisie.
enum Swatch {
    static func image(_ color: UIColor?, selected: Bool, diameter: CGFloat = 24) -> UIImage {
        let side = diameter + 10
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let inner = CGRect(x: 5, y: 5, width: diameter, height: diameter)
            if selected {
                Theme.coral.setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(x: 1.25, y: 1.25, width: side - 2.5, height: side - 2.5))
                ring.lineWidth = 2.5
                ring.stroke()
            }
            if let color {
                color.setFill()
                UIBezierPath(ovalIn: inner).fill()
            } else {
                // « Aucune » : disque barré.
                UIColor.white.setFill()
                UIBezierPath(ovalIn: inner).fill()
                UIColor.systemRed.setStroke()
                let bar = UIBezierPath()
                bar.move(to: CGPoint(x: inner.maxX - 4, y: inner.minY + 4))
                bar.addLine(to: CGPoint(x: inner.minX + 4, y: inner.maxY - 4))
                bar.lineWidth = 2
                bar.stroke()
            }
            UIColor.white.withAlphaComponent(0.35).setStroke()
            let edge = UIBezierPath(ovalIn: inner.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
            _ = ctx
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// Noms en français des couleurs, pour les menus et la synthèse vocale.
enum ColorNames {
    private static let named: [(UInt32, String)] = [
        (0x111111, "color.black"), (0x1D2A44, "color.navy"), (0xC62828, "color.red"), (0x2E7D32, "color.green"),
        (0x1565C0, "color.blue"), (0xC2500F, "color.orange"), (0x7A4FB5, "color.purple"), (0xFFFFFF, "color.white"),
        (0x8A8F98, "color.grey"), (0xFFE14D, "color.yellow"), (0x7CE38B, "color.green"), (0x7CC8FF, "color.blue"),
        (0xFF9EC4, "color.pink"), (0xFFB45C, "color.orange"), (0xF2B33D, "color.yellow"), (0xFFE98A, "color.yellow"),
        (0xBDE7C4, "color.green"), (0xBFDCF7, "color.blue"), (0xF7C6DB, "color.pink"), (0xFFD6A5, "color.orange"),
        (0xC0396B, "color.pink"), (0x2F6FB7, "color.blue"), (0xB58A1B, "color.yellow"),
    ]

    /// Nom de la couleur la plus proche parmi une palette de base.
    static func name(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        var best = "color.black", bestDistance = CGFloat.greatestFiniteMagnitude
        for (hex, key) in named {
            let c = UIColor(hex: hex)
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            c.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let d = pow(r - r2, 2) + pow(g - g2, 2) + pow(b - b2, 2)
            if d < bestDistance { bestDistance = d; best = key }
        }
        return L(best)
    }
}
