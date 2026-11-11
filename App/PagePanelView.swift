import NootyCore
import UIKit

protocol PagePanelDataSource: AnyObject {
    var panelPages: [PageInfo] { get }
    var panelCurrentIndex: Int { get }
    func panelThumbnail(_ index: Int, width: CGFloat) -> UIImage?
    func panelSelect(_ index: Int)
    func panelMove(from: Int, to: Int)
    func panelMenu(for index: Int) -> UIMenu
    func panelClose()
}

/// Panneau latéral des pages : miniatures (réorganisables), signets et plan.
final class PagePanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout,
    UITableViewDataSource, UITableViewDelegate {
    weak var dataSource: PagePanelDataSource?

    private enum Mode: Int { case pages, bookmarks, outline }

    private let segments = UISegmentedControl(items: [L("panel.pages"), L("panel.bookmarks"), L("panel.outline")])
    private let grid: UICollectionView
    private let list = UITableView(frame: .zero, style: .insetGrouped)
    private let empty = UILabel()
    private var mode = Mode.pages
    private var thumbnails: [Int: UIImage] = [:]
    private var rows: [Int] = []

    override init(frame: CGRect) {
        let flow = UICollectionViewFlowLayout()
        flow.minimumLineSpacing = 18
        flow.minimumInteritemSpacing = 12
        flow.sectionInset = UIEdgeInsets(top: 12, left: 14, bottom: 30, right: 14)
        grid = UICollectionView(frame: .zero, collectionViewLayout: flow)
        super.init(frame: frame)
        backgroundColor = Theme.panel
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 16
        accessibilityViewIsModal = false

        let close = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in self?.dataSource?.panelClose() })
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = Theme.secondaryText
        close.accessibilityLabel = L("common.close")

        segments.selectedSegmentIndex = 0
        segments.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.mode = Mode(rawValue: self.segments.selectedSegmentIndex) ?? .pages
            self.reload()
        }, for: .valueChanged)

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.register(PageThumbCell.self, forCellWithReuseIdentifier: "page")
        grid.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(reorder(_:))))

        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        list.register(UITableViewCell.self, forCellReuseIdentifier: "row")

        empty.textColor = Theme.secondaryText
        empty.font = .preferredFont(forTextStyle: .callout)
        empty.numberOfLines = 0
        empty.textAlignment = .center

        let header = UIStackView(arrangedSubviews: [segments, close])
        header.spacing = 8
        header.alignment = .center
        for v in [header, grid, list, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    /// Recharge le contenu ; `dirty` vide le cache des miniatures.
    func reload(dirty: Bool = false) {
        if dirty { thumbnails.removeAll() }
        let pages = dataSource?.panelPages ?? []
        grid.isHidden = mode != .pages
        list.isHidden = mode == .pages
        switch mode {
        case .pages:
            rows = Array(pages.indices)
            grid.reloadData()
            let current = dataSource?.panelCurrentIndex ?? 0
            if pages.indices.contains(current) {
                grid.scrollToItem(at: IndexPath(item: current, section: 0), at: .centeredVertically, animated: false)
            }
        case .bookmarks:
            rows = pages.indices.filter { pages[$0].bookmarked }
            list.reloadData()
        case .outline:
            rows = pages.indices.filter { pages[$0].title != nil }
            list.reloadData()
        }
        empty.isHidden = mode == .pages || !rows.isEmpty
        empty.text = mode == .bookmarks ? L("panel.noBookmarks") : L("panel.noOutline")
    }

    // MARK: - Miniatures

    private var thumbWidth: CGFloat { max(80, (bounds.width - 14 * 2 - 12) / 2) }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let pages = dataSource?.panelPages ?? []
        guard pages.indices.contains(indexPath.item) else { return CGSize(width: thumbWidth, height: thumbWidth) }
        let p = pages[indexPath.item]
        return CGSize(width: thumbWidth, height: thumbWidth * CGFloat(p.height / p.width) + 24)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PageThumbCell
        let index = indexPath.item
        let pages = dataSource?.panelPages ?? []
        if thumbnails[index] == nil { thumbnails[index] = dataSource?.panelThumbnail(index, width: thumbWidth * 2) }
        cell.configure(image: thumbnails[index], number: index + 1, current: index == dataSource?.panelCurrentIndex,
                       bookmarked: pages.indices.contains(index) && pages[index].bookmarked)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        dataSource?.panelSelect(indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let index = indexPaths.first?.item else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.dataSource?.panelMenu(for: index) }
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { true }

    func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        thumbnails.removeAll()
        dataSource?.panelMove(from: sourceIndexPath.item, to: destinationIndexPath.item)
    }

    @objc private func reorder(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            if let path = grid.indexPathForItem(at: g.location(in: grid)) { grid.beginInteractiveMovementForItem(at: path) }
        case .changed:
            grid.updateInteractiveMovementTargetPosition(g.location(in: grid))
        case .ended:
            grid.endInteractiveMovement()
        default:
            grid.cancelInteractiveMovement()
        }
    }

    // MARK: - Signets et plan

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let index = rows[indexPath.row]
        let pages = dataSource?.panelPages ?? []
        var content = cell.defaultContentConfiguration()
        content.text = pages.indices.contains(index) ? (pages[index].title ?? L("page.number", index + 1)) : ""
        content.secondaryText = L("page.number", index + 1)
        content.image = UIImage(systemName: mode == .bookmarks ? "bookmark.fill" : "list.bullet.indent")
        content.imageProperties.tintColor = Theme.accent
        cell.contentConfiguration = content
        cell.backgroundColor = Theme.desk
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        dataSource?.panelSelect(rows[indexPath.row])
    }
}

final class PageThumbCell: UICollectionViewCell {
    private let image = UIImageView()
    private let number = UILabel()
    private let mark = UIImageView(image: UIImage(systemName: "bookmark.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFit
        image.backgroundColor = .white
        image.layer.borderWidth = 1
        image.layer.cornerRadius = 4
        image.clipsToBounds = true
        number.font = .preferredFont(forTextStyle: .caption1)
        number.textAlignment = .center
        number.textColor = Theme.secondaryText
        mark.tintColor = Theme.accent
        for v in [image, number, mark] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: contentView.topAnchor),
            image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            image.bottomAnchor.constraint(equalTo: number.topAnchor, constant: -4),
            number.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            number.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            number.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            number.heightAnchor.constraint(equalToConstant: 18),
            mark.topAnchor.constraint(equalTo: image.topAnchor, constant: -2),
            mark.trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func configure(image img: UIImage?, number n: Int, current: Bool, bookmarked: Bool) {
        image.image = img
        image.layer.borderColor = (current ? Theme.accent : Theme.hairline).cgColor
        image.layer.borderWidth = current ? 3 : 1
        number.text = "\(n)"
        mark.isHidden = !bookmarked
        isAccessibilityElement = true
        accessibilityLabel = L("page.number", n) + (bookmarked ? ", " + L("panel.bookmarked") : "")
        accessibilityTraits = current ? [.button, .selected] : .button
    }
}
