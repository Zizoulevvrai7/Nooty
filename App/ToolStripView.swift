import NootyCore
import UIKit

/// Barre d'outils de l'éditeur : outils à gauche, options de l'outil courant à droite.
final class ToolStripView: UIView {
    var state: ToolState { didSet { if state != oldValue { rebuild() } } }
    /// Appelé quand l'utilisateur change un réglage.
    var onChange: ((ToolState) -> Void)?
    /// Appelé pour modifier la couleur d'une pastille déjà sélectionnée.
    var onEditColor: ((_ index: Int, _ current: UIColor, _ source: UIView) -> Void)?
    /// Appelé pour régler l'épaisseur d'un préréglage déjà sélectionné.
    var onEditWidth: ((_ index: Int, _ source: UIView) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init(state: ToolState) {
        self.state = state
        super.init(frame: .zero)
        Theme.style(panel: self, radius: 18)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        // La barre épouse son contenu ; elle ne défile que si l'écran est trop étroit.
        let fit = scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 16)
        fit.priority = .defaultHigh
        let compact = stack.widthAnchor.constraint(equalToConstant: 0)
        compact.priority = UILayoutPriority(50)
        compact.isActive = true
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            fit,
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
            heightAnchor.constraint(equalToConstant: 58),
        ])
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = L("tools.label")
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

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for kind in ToolKind.allCases {
            let symbol = kind == .pen ? state.penStyle.symbol : kind.symbol
            stack.addArrangedSubview(iconButton(symbol, kind.title, selected: state.kind == kind) { [weak self] in
                self?.update { $0.kind = kind }
            })
        }
        stack.addArrangedSubview(divider())

        switch state.kind {
        case .pen:
            stack.addArrangedSubview(menuButton(
                title: state.penStyle.title, label: L("pen.style"),
                actions: PenStyle.allCases.map { style in
                    UIAction(title: style.title, image: UIImage(systemName: style.symbol), state: style == state.penStyle ? .on : .off) { [weak self] _ in
                        self?.update { $0.penStyle = style }
                    }
                }
            ))
        case .shape:
            stack.addArrangedSubview(menuButton(
                title: state.shapeKind.title, label: L("shape.kind"),
                actions: ShapeKind.allCases.map { kind in
                    UIAction(title: kind.title, image: UIImage(systemName: kind.symbol), state: kind == state.shapeKind ? .on : .off) { [weak self] _ in
                        self?.update { $0.shapeKind = kind }
                    }
                }
            ))
        case .eraser:
            let mode = UISegmentedControl(items: EraserMode.allCases.map(\.title))
            mode.selectedSegmentIndex = EraserMode.allCases.firstIndex(of: state.eraserMode) ?? 0
            mode.addAction(UIAction { [weak self, weak mode] _ in
                guard let i = mode?.selectedSegmentIndex, EraserMode.allCases.indices.contains(i) else { return }
                self?.update { $0.eraserMode = EraserMode.allCases[i] }
            }, for: .valueChanged)
            mode.accessibilityLabel = L("eraser.mode")
            mode.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(mode)
            if state.eraserMode != .stroke {
                for i in ToolState.eraserSizes.indices { stack.addArrangedSubview(eraserSizeButton(index: i)) }
            }
        case .lasso, .text, .laser, .tape:
            let hint = UILabel()
            hint.text = L("hint.\(state.kind.rawValue)")
            hint.font = .preferredFont(forTextStyle: .footnote)
            hint.adjustsFontForContentSizeCategory = true
            hint.textColor = Theme.secondaryText
            hint.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(hint)
        case .pencil, .highlighter:
            break
        }
        if state.hasWidths {
            for i in 0..<ToolState.widthCount { stack.addArrangedSubview(widthButton(index: i)) }
        }
        if state.hasColors {
            stack.addArrangedSubview(divider())
            for (i, hex) in state.colors.enumerated() {
                stack.addArrangedSubview(swatch(index: i, color: ToolState.color(hex)))
            }
        }
    }

    private func menuButton(title: String, label: String, actions: [UIAction]) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.baseForegroundColor = Theme.text
        config.cornerStyle = .large
        let button = UIButton(configuration: config)
        button.menu = UIMenu(title: label, options: .singleSelection, children: actions)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = label
        button.accessibilityValue = title
        return sized(button, width: 92)
    }

    // MARK: - Éléments

    private func sized(_ button: UIButton, width: CGFloat = 44) -> UIButton {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    private func iconButton(_ symbol: String, _ label: String, selected: Bool, action: @escaping () -> Void) -> UIButton {
        var config = selected ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium))
            ?? UIImage(systemName: "pencil")
        config.baseForegroundColor = selected ? Theme.accent : Theme.text
        config.baseBackgroundColor = Theme.accentSoft
        config.cornerStyle = .large
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.toolTip = label
        if selected { button.accessibilityTraits.insert(.selected) }
        return sized(button)
    }

    private func divider() -> UIView {
        let v = UIView()
        v.backgroundColor = Theme.hairline
        v.isAccessibilityElement = false
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 1), v.heightAnchor.constraint(equalToConstant: 28)])
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last ?? v)
        return v
    }

    private func dotButton(diameter: CGFloat, selected: Bool, label: String, action: @escaping () -> Void) -> UIButton {
        let size = CGSize(width: 30, height: 30)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.black.setFill()
            UIBezierPath(ovalIn: CGRect(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2, width: diameter, height: diameter)).fill()
        }.withRenderingMode(.alwaysTemplate)
        var config = selected ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.image = image
        config.baseForegroundColor = selected ? Theme.accent : Theme.text
        config.baseBackgroundColor = Theme.accentSoft
        config.cornerStyle = .large
        config.contentInsets = .zero
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        if selected { button.accessibilityTraits.insert(.selected) }
        return sized(button, width: 40)
    }

    private func widthButton(index: Int) -> UIButton {
        let labels = [L("width.fine"), L("width.medium"), L("width.thick")]
        let factor = state.widths[index]
        let diameter = CGFloat(min(18, max(3, 4 + factor * 6)))
        let selected = state.widthIndex == index
        let button = dotButton(diameter: diameter, selected: selected, label: labels[index]) {}
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            if self.state.widthIndex == index {
                self.onEditWidth?(index, button)
            } else {
                self.update { $0.widthIndex = index }
            }
        }, for: .primaryActionTriggered)
        button.accessibilityHint = selected ? L("width.editHint") : nil
        return button
    }

    private func eraserSizeButton(index: Int) -> UIButton {
        let labels = [L("eraser.small"), L("eraser.medium"), L("eraser.large")]
        return dotButton(diameter: [8, 14, 22][index], selected: state.eraserSizeIndex == index, label: labels[index]) { [weak self] in
            self?.update { $0.eraserSizeIndex = index }
        }
    }

    private func swatch(index: Int, color: UIColor) -> UIButton {
        let selected = state.colorIndex == index
        let size = CGSize(width: 34, height: 34)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            if selected {
                Theme.accent.setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(x: 1.5, y: 1.5, width: 31, height: 31))
                ring.lineWidth = 2.5
                ring.stroke()
            }
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 22, height: 22)).fill()
            // Liseré clair et sombre : une pastille reste visible sur une barre claire comme sombre.
            UIColor.white.withAlphaComponent(0.55).setStroke()
            let outer = UIBezierPath(ovalIn: CGRect(x: 5.5, y: 5.5, width: 23, height: 23))
            outer.lineWidth = 1
            outer.stroke()
            UIColor.black.withAlphaComponent(0.25).setStroke()
            let edge = UIBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 22, height: 22))
            edge.lineWidth = 0.75
            edge.stroke()
        }.withRenderingMode(.alwaysOriginal)
        var config = UIButton.Configuration.plain()
        config.image = image
        config.contentInsets = .zero
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if self.state.colorIndex == index {
                self.onEditColor?(index, color, self)
            } else {
                self.update { $0.colorIndex = index }
            }
        })
        button.accessibilityLabel = L("color.slot", index + 1)
        button.accessibilityHint = selected ? L("color.editHint") : nil
        if selected { button.accessibilityTraits.insert(.selected) }
        return sized(button, width: 38)
    }
}
