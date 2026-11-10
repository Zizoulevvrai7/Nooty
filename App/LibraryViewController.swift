import NootyCore
import UIKit

/// Bibliothèque : dossiers et carnets, favoris, corbeille.
final class LibraryViewController: UIViewController, UICollectionViewDelegate {
    private enum Scope: Int {
        case documents, favorites, trash
    }

    private let store: LibraryStore
    private let folderID: UUID?
    private var scope = Scope.documents
    private var sort: LibrarySort {
        get { LibrarySort(rawValue: UserDefaults.standard.string(forKey: "nooty.library.sort") ?? "") ?? .modified }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nooty.library.sort") }
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    private let emptyLabel = UILabel()
    private let scopeControl = UISegmentedControl(items: [L("library.documents"), L("library.favorites"), L("library.trash")])
    private let thumbnails = NSCache<NSString, UIImage>()

    init(store: LibraryStore, folderID: UUID?) {
        self.store = store
        self.folderID = folderID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.desk
        navigationItem.largeTitleDisplayMode = folderID == nil ? .always : .never
        navigationItem.backButtonDisplayMode = .minimal

        let layout = UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(2, Int(width / 170))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(262)),
                repeatingSubitem: item, count: columns
            )
            group.interItemSpacing = .fixed(12)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 14
            section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 40, trailing: 20)
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<LibraryCell, UUID> { [weak self] cell, _, id in
            guard let self, let item = self.store.index.item(id) else { return }
            cell.configure(
                item, thumbnail: self.thumbnail(for: item),
                childCount: self.store.index.children(of: item.id).count, trashed: self.scope == .trash
            )
            cell.menuButton.menu = self.menu(for: item)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.font = .preferredFont(forTextStyle: .title3)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -24),
        ])

        if folderID == nil {
            scopeControl.selectedSegmentIndex = 0
            scopeControl.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.scope = Scope(rawValue: self.scopeControl.selectedSegmentIndex) ?? .documents
                self.reload(animated: false)
            }, for: .valueChanged)
            navigationItem.titleView = scopeControl
        }

        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: LibraryStore.didChange, object: store)
        reload(animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if folderID == nil, let warning = store.startupWarning, presentedViewController == nil, !didShowWarning {
            didShowWarning = true
            let alert = UIAlertController(title: L("app.name"), message: warning, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private var didShowWarning = false

    @objc private func libraryChanged() {
        // Un dossier supprimé ou mis à la corbeille ailleurs ne doit pas rester affiché.
        if let folderID, store.index.item(folderID) == nil || store.index.isEffectivelyTrashed(folderID) {
            navigationController?.popToRootViewController(animated: false)
            return
        }
        reload(animated: true)
    }

    // MARK: - Contenu

    private func currentItems() -> [LibraryEntry] {
        switch scope {
        case .documents: return store.index.children(of: folderID, sort: sort)
        case .favorites: return store.index.favorites(sort: sort)
        case .trash: return store.index.trashed()
        }
    }

    private func reload(animated: Bool) {
        title = folderID.flatMap { store.index.item($0)?.title } ?? L("library.title")
        let items = currentItems()
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.id))
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(items.map(\.id).filter(existing.contains))
        dataSource.apply(snapshot, animatingDifferences: animated && view.window != nil)

        emptyLabel.isHidden = !items.isEmpty
        switch scope {
        case .documents: emptyLabel.text = folderID == nil ? L("library.empty") : L("library.emptyFolder")
        case .favorites: emptyLabel.text = L("library.emptyFavorites")
        case .trash: emptyLabel.text = L("library.emptyTrash")
        }
        configureBarButtons(hasItems: !items.isEmpty)
    }

    private func thumbnail(for item: LibraryEntry) -> UIImage? {
        guard item.kind == .notebook else { return nil }
        let key = "\(item.id.uuidString)-\(item.updatedAt)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: store.thumbnailURL(item.id).path) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    private func configureBarButtons(hasItems: Bool) {
        if scope == .trash {
            let empty = UIBarButtonItem(title: L("trash.empty"), primaryAction: UIAction { [weak self] _ in self?.confirmEmptyTrash() })
            empty.tintColor = .systemRed
            empty.isEnabled = hasItems
            navigationItem.rightBarButtonItems = [empty]
            return
        }
        let new = UIBarButtonItem(title: L("library.new"), image: UIImage(systemName: "plus.circle.fill"), primaryAction: nil, menu: UIMenu(children: [
            UIAction(title: L("library.newNotebook"), image: UIImage(systemName: "book.closed")) { [weak self] _ in self?.presentNewNotebook() },
            UIAction(title: L("library.newFolder"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.promptNewFolder() },
        ]))
        let current = sort
        let sortItem = UIBarButtonItem(title: L("sort.title"), image: UIImage(systemName: "arrow.up.arrow.down"), primaryAction: nil, menu: UIMenu(title: L("sort.title"), options: .singleSelection, children: [
            (LibrarySort.modified, L("sort.modified")), (.created, L("sort.created")), (.name, L("sort.name")),
        ].map { (value: LibrarySort, title: String) in
            UIAction(title: title, state: value == current ? .on : .off) { [weak self] _ in
                self?.sort = value
                self?.reload(animated: true)
            }
        }))
        navigationItem.rightBarButtonItems = scope == .documents ? [new, sortItem] : [sortItem]
    }

    // MARK: - Ouverture

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = store.index.item(id) else { return }
        if scope == .trash {
            let alert = UIAlertController(title: item.title, message: L("trash.openHint"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("trash.restore"), style: .default) { [weak self] _ in self?.store.mutate { $0.restore(id) } })
            alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
            present(alert, animated: true)
            return
        }
        open(item)
    }

    private func open(_ item: LibraryEntry) {
        switch item.kind {
        case .folder:
            navigationController?.pushViewController(LibraryViewController(store: store, folderID: item.id), animated: true)
        case .notebook:
            do {
                let editor = try NotebookViewController(library: store, itemID: item.id)
                navigationController?.pushViewController(editor, animated: true)
            } catch {
                showError(L("notebook.openFailed", error.localizedDescription))
            }
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: L("common.error"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Actions

    private func menu(for item: LibraryEntry) -> UIMenu {
        let id = item.id
        if scope == .trash {
            return UIMenu(children: [
                UIAction(title: L("trash.restore"), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                    self?.store.mutate { $0.restore(id) }
                },
                UIAction(title: L("trash.deleteForever"), image: UIImage(systemName: "trash.slash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDeleteForever(item)
                },
            ])
        }
        var actions: [UIMenuElement] = [
            UIAction(title: L("item.rename"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.promptRename(item) },
            UIAction(
                title: item.favorite ? L("item.unfavorite") : L("item.favorite"),
                image: UIImage(systemName: item.favorite ? "star.slash" : "star")
            ) { [weak self] _ in self?.store.mutate { $0.setFavorite(id, !item.favorite) } },
        ]
        if item.kind == .notebook {
            actions.append(UIAction(title: L("item.duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                do { try self?.store.duplicateNotebook(id) } catch { self?.showError(error.localizedDescription) }
            })
        }
        var targets: [UIMenuElement] = []
        if item.parentID != nil {
            targets.append(UIAction(title: L("library.title"), image: UIImage(systemName: "house")) { [weak self] _ in
                self?.store.mutate { $0.move(id, to: nil, now: nowMs()) }
            })
        }
        for folder in store.index.moveTargets(for: id) where folder.id != item.parentID {
            let path = (store.index.ancestors(of: folder.id).map(\.title) + [folder.title]).joined(separator: " › ")
            targets.append(UIAction(title: path, image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.store.mutate { $0.move(id, to: folder.id, now: nowMs()) }
            })
        }
        if !targets.isEmpty {
            actions.append(UIMenu(title: L("item.move"), image: UIImage(systemName: "folder"), children: targets))
        }
        actions.append(UIMenu(title: L("item.color"), image: UIImage(systemName: "paintpalette"), children: Theme.coverColors.enumerated().map { n, color in
            UIAction(title: L("color.slot", n + 1), image: Self.colorDot(InkConverter.uiColor(color)), state: color == item.color ? .on : .off) { [weak self] _ in
                self?.store.mutate { $0.setColor(id, color) }
            }
        }))
        actions.append(UIAction(title: L("item.trash"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.store.mutate { $0.trash(id, now: nowMs()) }
        })
        return UIMenu(children: actions)
    }

    private static func colorDot(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 18, height: 18)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath), let item = store.index.item(id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.menu(for: item) }
    }

    private func promptText(title: String, initial: String, placeholder: String, confirm: String, action: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initial
            field.placeholder = placeholder
            field.autocapitalizationType = .sentences
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: confirm, style: .default) { [weak alert] _ in
            action(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    private func promptRename(_ item: LibraryEntry) {
        promptText(title: L("item.rename"), initial: item.title, placeholder: L("library.namePlaceholder"), confirm: L("common.save")) { [weak self] text in
            self?.store.mutate { $0.rename(item.id, to: text, now: nowMs()) }
        }
    }

    private func promptNewFolder() {
        promptText(title: L("library.newFolder"), initial: "", placeholder: L("library.namePlaceholder"), confirm: L("common.create")) { [weak self] text in
            guard let self else { return }
            self.store.createFolder(title: text, parent: self.folderID)
        }
    }

    private func presentNewNotebook() {
        let form = NewNotebookViewController { [weak self] title, background in
            guard let self else { return }
            do {
                let item = try self.store.createNotebook(title: title, parent: self.folderID, background: background)
                self.open(item)
            } catch {
                self.showError(error.localizedDescription)
            }
        }
        let nav = UINavigationController(rootViewController: form)
        nav.modalPresentationStyle = .formSheet
        nav.view.tintColor = Theme.accent
        present(nav, animated: true)
    }

    private func confirmDeleteForever(_ item: LibraryEntry) {
        let alert = UIAlertController(title: L("trash.deleteForever"), message: L("trash.deleteMessage", item.title), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("common.delete"), style: .destructive) { [weak self] _ in self?.store.deletePermanently(item.id) })
        present(alert, animated: true)
    }

    private func confirmEmptyTrash() {
        let alert = UIAlertController(title: L("trash.empty"), message: L("trash.emptyMessage"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("trash.empty"), style: .destructive) { [weak self] _ in self?.store.emptyTrash() })
        present(alert, animated: true)
    }
}
