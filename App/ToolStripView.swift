import NootyCore
import UIKit

/// Barre d'outils de l'éditeur : outils à gauche, options de l'outil courant à droite.
final class ToolStripView: UIView {
    var state: ToolState { didSet { if state != oldValue { rebuild() } } }
    /// Appelé quand l'utilisateur change un réglage.
    var onChange: ((ToolState) -> Void)?
    /// Appelé pour modifier la couleur d'une pastille déjà sélectionnée.
    var onEditColor: ((_ index: Int, _ current: UIColor) -> Void)?

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

        let tools: [(ToolKind, String, String)] = [
            (.pen, state.penStyle.symbol, L("tool.pen")),
            (.highlighter, "highlighter", L("tool.highlighter")),
            (.eraser, "eraser", L("tool.eraser")),
            (.lasso, "lasso", L("tool.lasso")),
        ]
        for (kind, symbol, label) in tools {
            stack.addArrangedSubview(iconButton(symbol, label, selected: state.kind == kind) { [weak self] in
                self?.update { $0.kind = kind }
            })
        }
        stack.addArrangedSubview(divider())

        switch state.kind {
        case .pen, .highlighter:
            if state.kind == .pen { stack.addArrangedSubview(penStyleButton()) }
            for i in 0..<ToolState.widthCount {
                stack.addArrangedSubview(widthButton(index: i))
            }
            stack.addArrangedSubview(divider())
            for (i, hex) in state.colors.enumerated() {
                stack.addArrangedSubview(swatch(index: i, color: ToolState.color(hex)))
            }
        case .eraser:
            let mode = UISegmentedControl(items: [L("eraser.stroke"), L("eraser.precise")])
            mode.selectedSegmentIndex = state.eraserMode == .stroke ? 0 : 1
            mode.addAction(UIAction { [weak self, weak mode] _ in
                self?.update { $0.eraserMode = mode?.selectedSegmentIndex == 0 ? .stroke : .precise }
            }, for: .valueChanged)
            mode.accessibilityLabel = L("eraser.mode")
            mode.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(mode)
            if state.eraserMode == .precise {
                for i in ToolState.eraserSizes.indices { stack.addArrangedSubview(eraserSizeButton(index: i)) }
            }
        case .lasso:
            let hint = UILabel()
            hint.text = L("lasso.hint")
            hint.font = .preferredFont(forTextStyle: .footnote)
            hint.adjustsFontForContentSizeCategory = true
            hint.textColor = Theme.secondaryText
            hint.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(hint)
        }
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

    private func penStyleButton() -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = state.penStyle.title
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.baseForegroundColor = Theme.text
        config.cornerStyle = .large
        let button = UIButton(configuration: config)
        button.menu = UIMenu(title: L("pen.style"), options: .singleSelection, children: PenStyle.allCases.map { style in
            UIAction(title: style.title, image: UIImage(systemName: style.symbol), state: style == state.penStyle ? .on : .off) { [weak self] _ in
                self?.update { $0.penStyle = style }
            }
        })
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = L("pen.style")
        button.accessibilityValue = state.penStyle.title
        return sized(button, width: 92)
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
        return dotButton(diameter: [5, 9, 14][index], selected: state.widthIndex == index, label: labels[index]) { [weak self] in
            self?.update { $0.widthIndex = index }
        }
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
            UIColor.black.withAlphaComponent(0.18).setStroke()
            let edge = UIBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 22, height: 22))
            edge.lineWidth = 1
            edge.stroke()
        }.withRenderingMode(.alwaysOriginal)
        var config = UIButton.Configuration.plain()
        config.image = image
        config.contentInsets = .zero
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if self.state.colorIndex == index {
                self.onEditColor?(index, color)
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
