import NootyCore
import UIKit

/// Vignette d'un carnet (couverture avec aperçu de la première page) ou d'un dossier.
final class LibraryCell: UICollectionViewCell {
    private let cover = UIView()
    private let preview = UIImageView()
    private let spine = UIView()
    private let folderIcon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let star = UIImageView(image: UIImage(systemName: "star.fill"))
    let menuButton = UIButton(type: .system)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.layer.cornerRadius = 10
        cover.layer.cornerCurve = .continuous
        cover.layer.shadowColor = UIColor.black.cgColor
        cover.layer.shadowOpacity = 0.16
        cover.layer.shadowRadius = 8
        cover.layer.shadowOffset = CGSize(width: 0, height: 3)

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.contentMode = .scaleAspectFill
        preview.clipsToBounds = true
        preview.layer.cornerRadius = 10
        preview.layer.cornerCurve = .continuous
        preview.layer.borderWidth = 1
        preview.layer.borderColor = Theme.hairline.cgColor

        spine.translatesAutoresizingMaskIntoConstraints = false
        spine.layer.cornerRadius = 10
        spine.layer.cornerCurve = .continuous
        spine.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]

        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.contentMode = .scaleAspectFit
        folderIcon.image = UIImage(systemName: "folder.fill")

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.secondaryText
        detailLabel.textAlignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        star.tintColor = UIColor(hex: 0xE8A200)
        star.translatesAutoresizingMaskIntoConstraints = false

        menuButton.setImage(UIImage(systemName: "ellipsis.circle.fill"), for: .normal)
        menuButton.tintColor = Theme.secondaryText
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = L("library.actions")
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(cover)
        cover.addSubview(preview)
        cover.addSubview(spine)
        contentView.addSubview(folderIcon)
        contentView.addSubview(star)
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(menuButton)

        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cover.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            cover.heightAnchor.constraint(equalToConstant: 150),
            cover.widthAnchor.constraint(equalToConstant: 112),
            preview.topAnchor.constraint(equalTo: cover.topAnchor),
            preview.bottomAnchor.constraint(equalTo: cover.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
            spine.topAnchor.constraint(equalTo: cover.topAnchor),
            spine.bottomAnchor.constraint(equalTo: cover.bottomAnchor),
            spine.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
            spine.widthAnchor.constraint(equalToConstant: 12),
            folderIcon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            folderIcon.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 128),
            folderIcon.heightAnchor.constraint(equalToConstant: 110),
            star.topAnchor.constraint(equalTo: cover.topAnchor, constant: -6),
            star.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: 8),
            star.widthAnchor.constraint(equalToConstant: 22),
            star.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            menuButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 0),
            menuButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 44),
            menuButton.heightAnchor.constraint(equalToConstant: 34),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func prepareForReuse() {
        super.prepareForReuse()
        preview.image = nil
    }

    func configure(_ item: LibraryItem, thumbnail: UIImage?, childCount: Int, trashed: Bool) {
        let color = InkConverter.uiColor(item.color)
        let isFolder = item.kind == .folder
        cover.isHidden = isFolder
        folderIcon.isHidden = !isFolder
        folderIcon.tintColor = color
        spine.backgroundColor = color
        preview.backgroundColor = thumbnail == nil ? color.withAlphaComponent(0.18) : .white
        preview.image = thumbnail
        star.isHidden = !item.favorite || trashed
        titleLabel.text = item.title
        if isFolder {
            detailLabel.text = childCount == 1 ? L("library.oneItem") : L("library.items", childCount)
        } else {
            detailLabel.text = Self.dateFormatter.string(from: Date(timeIntervalSince1970: item.updatedAt / 1000))
        }
        contentView.alpha = trashed ? 0.6 : 1

        // Un seul élément d'accessibilité pour la vignette, plus le bouton d'actions.
        titleLabel.isAccessibilityElement = true
        titleLabel.accessibilityTraits = .button
        titleLabel.accessibilityLabel = [
            isFolder ? L("library.folder") : L("library.notebook"), item.title, detailLabel.text ?? "",
            item.favorite ? L("library.favorite") : "",
        ].filter { !$0.isEmpty }.joined(separator: ", ")
        detailLabel.isAccessibilityElement = false
        accessibilityElements = [titleLabel, menuButton]
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
