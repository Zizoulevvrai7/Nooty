import NootyCore
import UIKit

/// Création d'un carnet : nom, modèle de papier et teinte.
final class NewNotebookViewController: UIViewController, UITextFieldDelegate {
    static let templates: [(BackgroundKind, String)] = [
        (.seyes, "paper.seyes"), (.ruled, "paper.ruled"), (.grid, "paper.grid"), (.dots, "paper.dots"), (.blank, "paper.blank"),
    ]
    static let papers: [(PaperColor, String)] = [(.white, "paperColor.white"), (.ivory, "paperColor.ivory"), (.yellow, "paperColor.yellow")]

    private let onCreate: (String, Background, PaperSize, Bool) -> Void
    private var kind: BackgroundKind
    private var paper: PaperColor
    private var size = PaperSize(rawValue: UserDefaults.standard.string(forKey: "nooty.lastSize") ?? "") ?? .a4
    private var landscape = UserDefaults.standard.bool(forKey: "nooty.lastLandscape")
    private let sizeControl = UISegmentedControl(items: PaperSize.allCases.map { L("size.\($0.rawValue)") })
    private let orientation = UISegmentedControl(items: [L("orientation.portrait"), L("orientation.landscape")])
    private let nameField = UITextField()
    private let templateRow = UIStackView()
    private let paperRow = UIStackView()

    init(onCreate: @escaping (String, Background, PaperSize, Bool) -> Void) {
        self.onCreate = onCreate
        kind = BackgroundKind(rawValue: UserDefaults.standard.string(forKey: "nooty.lastTemplate") ?? "") ?? .seyes
        paper = PaperColor(rawValue: UserDefaults.standard.string(forKey: "nooty.lastPaper") ?? "") ?? .white
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.panel
        title = L("new.title")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let create = UIBarButtonItem(title: L("common.create"), primaryAction: UIAction { [weak self] _ in self?.create() })
        create.style = .done
        navigationItem.rightBarButtonItem = create

        nameField.placeholder = L("library.untitled")
        nameField.borderStyle = .roundedRect
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .done
        nameField.autocapitalizationType = .sentences
        nameField.delegate = self
        nameField.accessibilityLabel = L("new.name")
        nameField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        templateRow.axis = .horizontal
        templateRow.spacing = 14
        templateRow.alignment = .top
        paperRow.axis = .horizontal
        paperRow.spacing = 14

        let templateScroll = UIScrollView()
        templateScroll.showsHorizontalScrollIndicator = false
        templateRow.translatesAutoresizingMaskIntoConstraints = false
        templateScroll.addSubview(templateRow)
        NSLayoutConstraint.activate([
            templateRow.topAnchor.constraint(equalTo: templateScroll.contentLayoutGuide.topAnchor),
            templateRow.bottomAnchor.constraint(equalTo: templateScroll.contentLayoutGuide.bottomAnchor),
            templateRow.leadingAnchor.constraint(equalTo: templateScroll.contentLayoutGuide.leadingAnchor),
            templateRow.trailingAnchor.constraint(equalTo: templateScroll.contentLayoutGuide.trailingAnchor),
            templateRow.heightAnchor.constraint(equalTo: templateScroll.frameLayoutGuide.heightAnchor),
            templateScroll.heightAnchor.constraint(equalToConstant: 200),
        ])

        let paperHolder = UIView()
        paperRow.translatesAutoresizingMaskIntoConstraints = false
        paperHolder.addSubview(paperRow)
        NSLayoutConstraint.activate([
            paperRow.topAnchor.constraint(equalTo: paperHolder.topAnchor),
            paperRow.bottomAnchor.constraint(equalTo: paperHolder.bottomAnchor),
            paperRow.leadingAnchor.constraint(equalTo: paperHolder.leadingAnchor),
            paperRow.trailingAnchor.constraint(lessThanOrEqualTo: paperHolder.trailingAnchor),
        ])

        sizeControl.selectedSegmentIndex = PaperSize.allCases.firstIndex(of: size) ?? 0
        sizeControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.size = PaperSize.allCases[self.sizeControl.selectedSegmentIndex]
            self.rebuildChoices()
        }, for: .valueChanged)
        orientation.selectedSegmentIndex = landscape ? 1 : 0
        orientation.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.landscape = self.orientation.selectedSegmentIndex == 1
            self.rebuildChoices()
        }, for: .valueChanged)
        let column = UIStackView(arrangedSubviews: [
            header(L("new.name")), nameField, header(L("new.paper")), templateScroll, header(L("new.paperColor")), paperHolder,
            header(L("new.size")), sizeControl, orientation,
        ])
        column.setCustomSpacing(24, after: paperHolder)
        column.axis = .vertical
        column.spacing = 10
        column.setCustomSpacing(24, after: nameField)
        column.setCustomSpacing(24, after: templateScroll)
        column.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
        ])
        rebuildChoices()
    }

    private func header(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.text
        label.accessibilityTraits = .header
        return label
    }

    private func rebuildChoices() {
        templateRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        paperRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let dims = size.size(landscape: landscape)
        let pageSize = CGSize(width: dims.width, height: dims.height)
        for (value, key) in Self.templates {
            let image = PaperRenderer.image(.standard(value, paper: paper), pageSize: CGSize(width: pageSize.width / 3.2, height: pageSize.height / 3.2), width: landscape ? 140 : 104)
            templateRow.addArrangedSubview(tile(image: image, title: L(key), selected: value == kind) { [weak self] in
                self?.kind = value
                self?.rebuildChoices()
            })
        }
        for (value, key) in Self.papers {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44)).image { _ in
                InkConverter.uiColor(value.rgba).setFill()
                UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 40, height: 40)).fill()
            }
            paperRow.addArrangedSubview(tile(image: image, title: L(key), selected: value == paper) { [weak self] in
                self?.paper = value
                self?.rebuildChoices()
            })
        }
    }

    private func tile(image: UIImage, title: String, selected: Bool, action: @escaping () -> Void) -> UIView {
        let picture = UIImageView(image: image)
        picture.layer.cornerRadius = image.size.width < 60 ? image.size.width / 2 : 8
        picture.layer.masksToBounds = true
        picture.layer.borderWidth = selected ? 3 : 1
        picture.layer.borderColor = (selected ? Theme.accent : Theme.hairline).cgColor
        picture.widthAnchor.constraint(equalToConstant: image.size.width).isActive = true
        picture.heightAnchor.constraint(equalToConstant: image.size.height).isActive = true

        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = selected ? Theme.accent : Theme.text
        label.textAlignment = .center

        let column = UIStackView(arrangedSubviews: [picture, label])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 6
        column.isUserInteractionEnabled = false

        let button = UIButton(type: .custom, primaryAction: UIAction { _ in action() })
        column.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            column.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2),
            column.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
            column.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        button.accessibilityLabel = title
        if selected { button.accessibilityTraits.insert(.selected) }
        return button
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        create()
        return true
    }

    private func create() {
        UserDefaults.standard.set(kind.rawValue, forKey: "nooty.lastTemplate")
        UserDefaults.standard.set(paper.rawValue, forKey: "nooty.lastPaper")
        UserDefaults.standard.set(size.rawValue, forKey: "nooty.lastSize")
        UserDefaults.standard.set(landscape, forKey: "nooty.lastLandscape")
        let title = nameField.text ?? ""
        let background = Background.standard(kind, paper: paper)
        let size = size, landscape = landscape
        dismiss(animated: true) { [onCreate] in onCreate(title, background, size, landscape) }
    }
}
