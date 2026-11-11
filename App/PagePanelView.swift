import NootyCore
import UIKit

protocol PagePanelDataSource: AnyObject {
    var panelPages: [PageInfo] { get }
    var panelCurrentIndex: Int { get }
    func panelThumbnail(_ index: Int, width: CGFloat) -> UIImage?
    func panelSelect(_ index: Int)
    func panelMove(from: Int, to: Int)
    func panelMenu(for index: Int) -> UIMenu
    func panelToggleBookmark(_ index: Int)
    func panelAddPage()
    func panelClose()
}

/// Panneau latéral des pages : miniatures (réorganisables), signets et plan.
final class PagePanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout,
    UITableViewDataSource, UITableViewDelegate {
    weak var dataSource: PagePanelDataSource?

    private enum Mode: Int { case pages, bookmarks, outline }

    private let segments = UISegmentedControl(items: [
        UIImage(systemName: "doc")!, UIImage(systemName: "bookmark")!, UIImage(systemName: "list.bullet.indent")!,
    ])
    private let titleLabel = UILabel()
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
        backgroundColor = Theme.sheet
        overrideUserInterfaceStyle = .dark
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 16
        accessibilityViewIsModal = false

        let close = ChromeButton.make("xmark", L("common.close")) { [weak self] _ in self?.dataSource?.panelClose() }
        titleLabel.text = L("panel.pages")
        titleLabel.font = Theme.rounded(18, .semibold, style: .headline)
        titleLabel.textColor = Theme.chromeText
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header

        for (i, key) in ["panel.pages", "panel.bookmarks", "panel.outline"].enumerated() {
            segments.imageForSegment(at: i)?.accessibilityLabel = L(key)
        }
        segments.selectedSegmentTintColor = Theme.chromeLine
        segments.backgroundColor = Theme.sheetCard
        segments.selectedSegmentIndex = 0
        segments.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.mode = Mode(rawValue: self.segments.selectedSegmentIndex) ?? .pages
            self.titleLabel.text = L(["panel.pages", "panel.bookmarks", "panel.outline"][self.mode.rawValue])
            self.reload()
        }, for: .valueChanged)

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.register(PageThumbCell.self, forCellWithReuseIdentifier: "page")
        grid.register(AddPageCell.self, forCellWithReuseIdentifier: "add")
        grid.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(reorder(_:))))

        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        list.register(UITableViewCell.self, forCellReuseIdentifier: "row")

        empty.textColor = Theme.chromeMuted
        empty.font = .preferredFont(forTextStyle: .callout)
        empty.numberOfLines = 0
        empty.textAlignment = .center

        let spacer = UIView()
        let top = UIStackView(arrangedSubviews: [spacer, titleLabel, close])
        top.alignment = .center
        spacer.widthAnchor.constraint(equalTo: close.widthAnchor).isActive = true
        let header = UIStackView(arrangedSubviews: [top, segments])
        header.axis = .vertical
        header.spacing = 10
        for v in [header, grid, list, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            segments.heightAnchor.constraint(equalToConstant: 38),
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
        rows.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let pages = dataSource?.panelPages ?? []
        // Dernière tuile : ajouter une page, aux proportions de la dernière page.
        let p = pages.indices.contains(indexPath.item) ? pages[indexPath.item] : pages.last
        guard let p else { return CGSize(width: thumbWidth, height: thumbWidth) }
        return CGSize(width: thumbWidth, height: thumbWidth * CGFloat(p.height / p.width) + 30)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let index = indexPath.item
        if index >= rows.count {
            return collectionView.dequeueReusableCell(withReuseIdentifier: "add", for: indexPath)
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PageThumbCell
        let pages = dataSource?.panelPages ?? []
        if thumbnails[index] == nil { thumbnails[index] = dataSource?.panelThumbnail(index, width: thumbWidth * 2) }
        cell.configure(image: thumbnails[index], number: index + 1, current: index == dataSource?.panelCurrentIndex,
                       bookmarked: pages.indices.contains(index) && pages[index].bookmarked)
        cell.menu = { [weak self] in self?.dataSource?.panelMenu(for: index) ?? UIMenu() }
        cell.onBookmark = { [weak self] in
            self?.dataSource?.panelToggleBookmark(index)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item >= rows.count { dataSource?.panelAddPage() } else { dataSource?.panelSelect(indexPath.item) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let index = indexPaths.first?.item, index < rows.count else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.dataSource?.panelMenu(for: index) }
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { indexPath.item < rows.count }

    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                        atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        IndexPath(item: min(proposedIndexPath.item, rows.count - 1), section: 0)
    }

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
        cell.backgroundColor = Theme.sheetCard
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        dataSource?.panelSelect(rows[indexPath.row])
    }
}

final class PageThumbCell: UICollectionViewCell {
    var menu: (() -> UIMenu)?
    var onBookmark: (() -> Void)?
    private let image = UIImageView()
    private let number = UILabel()
    private let mark = UIButton(type: .system)
    private let more = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFit
        image.backgroundColor = .white
        image.layer.cornerRadius = 6
        image.layer.cornerCurve = .continuous
        image.clipsToBounds = true
        number.font = Theme.rounded(14, .semibold, style: .caption1)
        number.textColor = Theme.chromeText
        mark.addAction(UIAction { [weak self] _ in self?.onBookmark?() }, for: .primaryActionTriggered)
        more.setImage(ChromeButton.symbol("chevron.down", size: 12, weight: .semibold), for: .normal)
        more.tintColor = Theme.chromeMuted
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.menu?().children ?? []) }])
        more.accessibilityLabel = L("page.options")
        for v in [image, number, mark, more] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            image.bottomAnchor.constraint(equalTo: number.topAnchor, constant: -4),
            number.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            number.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            number.heightAnchor.constraint(equalToConstant: 24),
            more.centerYAnchor.constraint(equalTo: number.centerYAnchor),
            more.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            more.widthAnchor.constraint(equalToConstant: 36),
            more.heightAnchor.constraint(equalToConstant: 32),
            mark.topAnchor.constraint(equalTo: image.topAnchor),
            mark.trailingAnchor.constraint(equalTo: image.trailingAnchor),
            mark.widthAnchor.constraint(equalToConstant: 40),
            mark.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func configure(image img: UIImage?, number n: Int, current: Bool, bookmarked: Bool) {
        image.image = img
        image.layer.borderColor = (current ? Theme.coral : UIColor.clear).cgColor
        image.layer.borderWidth = current ? 3 : 0
        number.text = "\(n)"
        mark.setImage(ChromeButton.symbol(bookmarked ? "bookmark.fill" : "bookmark", size: 16, weight: .medium), for: .normal)
        mark.tintColor = bookmarked ? Theme.coral : UIColor(white: 0.55, alpha: 1)
        mark.accessibilityLabel = bookmarked ? L("page.unbookmark") : L("page.bookmark")
        image.isAccessibilityElement = true
        image.accessibilityLabel = L("page.number", n) + (bookmarked ? ", " + L("panel.bookmarked") : "")
        image.accessibilityTraits = current ? [.button, .selected] : .button
        number.isAccessibilityElement = false
    }
}

/// Dernière tuile du panneau : une page en pointillés pour en ajouter une.
final class AddPageCell: UICollectionViewCell {
    private let dash = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dash.strokeColor = Theme.coral.cgColor
        dash.fillColor = UIColor.clear.cgColor
        dash.lineDashPattern = [6, 5]
        dash.lineWidth = 2
        contentView.layer.addSublayer(dash)
        let plus = UIImageView(image: ChromeButton.symbol("plus", size: 26, weight: .light))
        plus.tintColor = Theme.coral
        plus.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(plus)
        NSLayoutConstraint.activate([
            plus.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -14),
        ])
        isAccessibilityElement = true
        accessibilityLabel = L("page.addLast")
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = contentView.bounds.inset(by: UIEdgeInsets(top: 3, left: 3, bottom: 31, right: 3))
        dash.path = UIBezierPath(roundedRect: r, cornerRadius: 8).cgPath
    }
}
