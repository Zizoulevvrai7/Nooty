import LocalAuthentication
import NootyCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Bibliothèque : dossiers, blocs-notes, tableaux blancs et documents ; favoris, corbeille, recherche.
final class LibraryViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private enum Scope: Int {
        case documents, favorites, trash
    }

    private enum Row: Hashable {
        case entry(UUID)
        case hit(UUID, Int)
    }

    private let store: LibraryStore
    private let folderID: UUID?
    private var scope = Scope.documents
    private var query = ""
    private var contentHits: [(entry: LibraryEntry, hits: [NotebookTextIndex.Hit])] = []
    private var sort: LibrarySort {
        get { LibrarySort(rawValue: UserDefaults.standard.string(forKey: "nooty.library.sort") ?? "") ?? .modified }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nooty.library.sort") }
    }
    private var listMode: Bool {
        get { UserDefaults.standard.bool(forKey: "nooty.library.list") }
        set { UserDefaults.standard.set(newValue, forKey: "nooty.library.list") }
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private let emptyLabel = UILabel()
    private let scopeControl = UISegmentedControl(items: [L("library.documents"), L("library.favorites"), L("library.trash")])
    private let thumbnails = NSCache<NSString, UIImage>()
    private var pickerHolder: AnyObject?

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

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        view.addSubview(collectionView)

        let gridCell = UICollectionView.CellRegistration<LibraryCell, UUID> { [weak self] cell, _, id in
            guard let self, let item = self.store.index.item(id) else { return }
            cell.configure(item, thumbnail: self.thumbnail(for: item), childCount: self.store.index.children(of: item.id).count, trashed: self.scope == .trash)
            cell.menuButton.menu = self.menu(for: item)
        }
        let listCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
            guard let self, let item = self.store.index.item(id) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.title
            content.secondaryText = self.detail(for: item)
            content.image = self.thumbnail(for: item)?.preparingThumbnail(of: CGSize(width: 60, height: 80)) ?? UIImage(systemName: Self.symbol(for: item.kind))
            content.imageProperties.maximumSize = CGSize(width: 44, height: 56)
            content.imageProperties.tintColor = InkConverter.uiColor(item.color)
            cell.contentConfiguration = content
            let menuButton = UIButton(type: .system)
            menuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            menuButton.menu = self.menu(for: item)
            menuButton.showsMenuAsPrimaryAction = true
            menuButton.accessibilityLabel = L("library.actions")
            var accessories: [UICellAccessory] = [.customView(configuration: .init(customView: menuButton, placement: .trailing()))]
            if item.favorite { accessories.insert(.customView(configuration: .init(customView: UIImageView(image: UIImage(systemName: "star.fill")), placement: .trailing())), at: 0) }
            if item.locked { accessories.insert(.customView(configuration: .init(customView: UIImageView(image: UIImage(systemName: "lock.fill")), placement: .trailing())), at: 0) }
            cell.accessories = accessories
        }
        let hitCell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self, case let .hit(id, n) = row, let group = self.contentHits.first(where: { $0.entry.id == id }), group.hits.indices.contains(n) else { return }
            let hit = group.hits[n]
            var content = UIListContentConfiguration.subtitleCell()
            content.text = group.entry.title + " · " + (hit.pageIndex.map { L("page.number", $0 + 1) } ?? L("audio.title"))
            content.secondaryText = hit.snippet
            content.secondaryTextProperties.numberOfLines = 2
            content.image = UIImage(systemName: hit.pageIndex == nil ? "waveform" : "text.magnifyingglass")
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Row>(collectionView: collectionView) { [weak self] cv, indexPath, row in
            switch row {
            case let .entry(id):
                return (self?.listMode ?? false) || self?.query.isEmpty == false
                    ? cv.dequeueConfiguredReusableCell(using: listCell, for: indexPath, item: id)
                    : cv.dequeueConfiguredReusableCell(using: gridCell, for: indexPath, item: id)
            case .hit:
                return cv.dequeueConfiguredReusableCell(using: hitCell, for: indexPath, item: row)
            }
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
            let search = UISearchController(searchResultsController: nil)
            search.searchResultsUpdater = self
            search.obscuresBackgroundDuringPresentation = false
            search.searchBar.placeholder = L("library.searchPlaceholder")
            navigationItem.searchController = search
            navigationItem.hidesSearchBarWhenScrolling = false
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: L("settings.title"), image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
                self?.presentSettings()
            })
        }

        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: LibraryStore.didChange, object: store)
        reload(animated: false)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            guard let self else { return nil }
            if self.listMode || !self.query.isEmpty {
                var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                config.backgroundColor = .clear
                return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            }
            let width = environment.container.effectiveContentSize.width
            let columns = max(2, Int(width / 170))
            // Largeur fixe par colonne : une rangée incomplète reste alignée à gauche.
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(262)), subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 14
            section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 40, trailing: 20)
            return section
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reload(animated: false)
        if folderID == nil, let warning = store.startupWarning, presentedViewController == nil, !didShowWarning {
            didShowWarning = true
            showError(warning, title: L("app.name"))
        }
    }

    private var didShowWarning = false

    @objc private func libraryChanged() {
        if let folderID, store.index.item(folderID) == nil || store.index.isEffectivelyTrashed(folderID) {
            navigationController?.popToRootViewController(animated: false)
            return
        }
        reload(animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        let wasEmpty = query.isEmpty
        query = text
        contentHits = text.trimmingCharacters(in: .whitespaces).count >= 2 ? store.searchContent(text) : []
        if wasEmpty != query.isEmpty { collectionView.setCollectionViewLayout(makeLayout(), animated: false) }
        reload(animated: false)
    }

    // MARK: - Contenu

    private func currentItems() -> [LibraryEntry] {
        if !query.isEmpty { return store.index.search(query) }
        switch scope {
        case .documents: return store.index.children(of: folderID, sort: sort)
        case .favorites: return store.index.favorites(sort: sort)
        case .trash: return store.index.trashed()
        }
    }

    private func reload(animated: Bool) {
        title = folderID.flatMap { store.index.item($0)?.title } ?? L("library.title")
        let items = currentItems()
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map { .entry($0.id) }, toSection: 0)
        if !query.isEmpty {
            snapshot.appendSections([1])
            for group in contentHits { snapshot.appendItems(group.hits.indices.map { .hit(group.entry.id, $0) }, toSection: 1) }
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(existing.contains))
        dataSource.apply(snapshot, animatingDifferences: animated && view.window != nil)

        emptyLabel.isHidden = !snapshot.itemIdentifiers.isEmpty
        if !query.isEmpty {
            emptyLabel.text = L("search.noResult")
        } else {
            switch scope {
            case .documents: emptyLabel.text = folderID == nil ? L("library.empty") : L("library.emptyFolder")
            case .favorites: emptyLabel.text = L("library.emptyFavorites")
            case .trash: emptyLabel.text = L("library.emptyTrash")
            }
        }
        configureBarButtons(hasItems: !items.isEmpty)
    }

    static func symbol(for kind: LibraryEntryKind) -> String {
        switch kind {
        case .folder: return "folder.fill"
        case .notebook: return "book.closed.fill"
        case .whiteboard: return "rectangle.on.rectangle"
        case .document: return "doc.text.fill"
        }
    }

    private func detail(for item: LibraryEntry) -> String {
        if item.kind == .folder {
            let n = store.index.children(of: item.id).count
            return n == 1 ? L("library.oneItem") : L("library.items", n)
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: Date(timeIntervalSince1970: item.updatedAt / 1000))
    }

    private func thumbnail(for item: LibraryEntry) -> UIImage? {
        guard item.kind.hasFiles else { return nil }
        if item.locked { return UIImage(systemName: "lock.fill") }
        let url = store.thumbnailURL(item.id)
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(item.id.uuidString)-\(stamp)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    private func configureBarButtons(hasItems: Bool) {
        if scope == .trash, query.isEmpty {
            let empty = UIBarButtonItem(title: L("trash.empty"), primaryAction: UIAction { [weak self] _ in self?.confirmEmptyTrash() })
            empty.tintColor = .systemRed
            empty.isEnabled = hasItems
            navigationItem.rightBarButtonItems = [empty]
            return
        }
        let new = UIBarButtonItem(title: L("library.new"), image: UIImage(systemName: "plus.circle.fill"), primaryAction: nil, menu: UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("library.newNotebook"), image: UIImage(systemName: "book.closed")) { [weak self] _ in self?.presentNewNotebook() },
                UIAction(title: L("library.newBoard"), image: UIImage(systemName: "rectangle.on.rectangle")) { [weak self] _ in self?.createBoard() },
                UIAction(title: L("library.newDocument"), image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.createDocument() },
                UIAction(title: L("library.newFolder"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.promptNewFolder() },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("library.import"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.importFiles() },
                UIAction(title: L("library.scan"), image: UIImage(systemName: "doc.viewfinder")) { [weak self] _ in self?.scan() },
                UIAction(title: L("library.photos"), image: UIImage(systemName: "photo")) { [weak self] _ in self?.importPhotos() },
            ]),
        ]))
        let current = sort
        let display = UIMenu(options: .displayInline, children: [
            UIAction(title: L("library.grid"), image: UIImage(systemName: "square.grid.2x2"), state: listMode ? .off : .on) { [weak self] _ in self?.setListMode(false) },
            UIAction(title: L("library.list"), image: UIImage(systemName: "list.bullet"), state: listMode ? .on : .off) { [weak self] _ in self?.setListMode(true) },
        ])
        let sorting = UIMenu(title: L("sort.title"), options: [.displayInline, .singleSelection], children: [
            (LibrarySort.modified, L("sort.modified")), (.created, L("sort.created")), (.name, L("sort.name")),
        ].map { (value: LibrarySort, title: String) in
            UIAction(title: title, state: value == current ? .on : .off) { [weak self] _ in
                self?.sort = value
                self?.reload(animated: true)
            }
        })
        let viewItem = UIBarButtonItem(title: L("sort.title"), image: UIImage(systemName: "arrow.up.arrow.down"), primaryAction: nil, menu: UIMenu(children: [display, sorting]))
        navigationItem.rightBarButtonItems = scope == .documents && query.isEmpty ? [new, viewItem] : [viewItem]
    }

    private func setListMode(_ on: Bool) {
        listMode = on
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        configureBarButtons(hasItems: true)
    }

    // MARK: - Ouverture

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case let .entry(id):
            guard let item = store.index.item(id) else { return }
            if scope == .trash, query.isEmpty {
                let alert = UIAlertController(title: item.title, message: L("trash.openHint"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("trash.restore"), style: .default) { [weak self] _ in self?.store.mutate { $0.restore(id) } })
                alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
                present(alert, animated: true)
                return
            }
            open(item)
        case let .hit(id, n):
            guard let item = store.index.item(id), let group = contentHits.first(where: { $0.entry.id == id }), group.hits.indices.contains(n) else { return }
            let hit = group.hits[n]
            open(item) { editor in
                guard let editor = editor as? NotebookViewController else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let page = hit.pageIndex { editor.scrollToPage(page, animated: true) }
                    if let r = hit.recordingID { editor.audioController?.openRecording(r, query: nil) }
                }
            }
        }
    }

    private func open(_ item: LibraryEntry, then: ((UIViewController) -> Void)? = nil) {
        if item.kind == .folder {
            navigationController?.pushViewController(LibraryViewController(store: store, folderID: item.id), animated: true)
            return
        }
        Self.makeEditor(for: item, library: store, from: self) { [weak self] editor in
            guard let editor else { return }
            self?.navigationController?.pushViewController(editor, animated: true)
            then?(editor)
        }
    }

    /// Crée l'écran d'édition adapté au type de document, après authentification s'il est verrouillé.
    static func makeEditor(for item: LibraryEntry, library: LibraryStore, from vc: UIViewController, completion: @escaping (UIViewController?) -> Void) {
        let build = {
            do {
                switch item.kind {
                case .folder: completion(nil)
                case .document: completion(try DocumentViewController(library: library, itemID: item.id))
                case .notebook, .whiteboard: completion(try NotebookViewController(library: library, itemID: item.id))
                }
            } catch {
                let alert = UIAlertController(title: L("common.error"), message: L("notebook.openFailed", error.localizedDescription), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                vc.present(alert, animated: true)
                completion(nil)
            }
        }
        guard item.locked else { return build() }
        authenticate(reason: L("lock.reason", item.title)) { ok in
            if ok { build() } else { completion(nil) }
        }
    }

    static func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Sans code configuré sur l'iPad, le verrou ne peut pas protéger : on ouvre.
            completion(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private func showError(_ message: String, title: String = L("common.error")) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Actions

    private func menu(for item: LibraryEntry) -> UIMenu {
        let id = item.id
        if scope == .trash, query.isEmpty {
            return UIMenu(children: [
                UIAction(title: L("trash.restore"), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.store.mutate { $0.restore(id) } },
                UIAction(title: L("trash.deleteForever"), image: UIImage(systemName: "trash.slash"), attributes: .destructive) { [weak self] _ in self?.confirmDeleteForever(item) },
            ])
        }
        var actions: [UIMenuElement] = [
            UIAction(title: L("item.rename"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.promptRename(item) },
            UIAction(title: item.favorite ? L("item.unfavorite") : L("item.favorite"), image: UIImage(systemName: item.favorite ? "star.slash" : "star")) { [weak self] _ in
                self?.store.mutate { $0.setFavorite(id, !item.favorite) }
            },
        ]
        if item.kind.hasFiles {
            actions.append(UIAction(title: L("item.duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                do { try self?.store.duplicateNotebook(id) } catch { self?.showError(error.localizedDescription) }
            })
            actions.append(UIAction(title: L("export.nooty"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportEntry(item) })
            actions.append(UIAction(title: item.locked ? L("lock.remove") : L("lock.add"), image: UIImage(systemName: item.locked ? "lock.open" : "lock")) { [weak self] _ in
                guard let self else { return }
                if item.locked {
                    Self.authenticate(reason: L("lock.reason", item.title)) { ok in if ok { self.store.mutate { $0.setLocked(id, false) } } }
                } else {
                    self.store.mutate { $0.setLocked(id, true) }
                }
            })
        }
        var targets: [UIMenuElement] = []
        if item.parentID != nil {
            targets.append(UIAction(title: L("library.title"), image: UIImage(systemName: "house")) { [weak self] _ in self?.store.mutate { $0.move(id, to: nil, now: nowMs()) } })
        }
        for folder in store.index.moveTargets(for: id) where folder.id != item.parentID {
            let path = (store.index.ancestors(of: folder.id).map(\.title) + [folder.title]).joined(separator: " › ")
            targets.append(UIAction(title: path, image: UIImage(systemName: "folder")) { [weak self] _ in self?.store.mutate { $0.move(id, to: folder.id, now: nowMs()) } })
        }
        if !targets.isEmpty { actions.append(UIMenu(title: L("item.move"), image: UIImage(systemName: "folder"), children: targets)) }
        actions.append(UIMenu(title: L("item.color"), image: UIImage(systemName: "paintpalette"), children: Theme.coverColors.enumerated().map { n, color in
            UIAction(title: L("color.slot", n + 1), image: TextFormatBar.dot(InkConverter.uiColor(color)), state: color == item.color ? .on : .off) { [weak self] _ in
                self?.store.mutate { $0.setColor(id, color) }
            }
        }))
        actions.append(UIAction(title: L("item.trash"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.store.closeTab(id)
            self?.store.mutate { $0.trash(id, now: nowMs()) }
        })
        return UIMenu(children: actions)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, case let .entry(id)? = dataSource.itemIdentifier(for: indexPath), let item = store.index.item(id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.menu(for: item) }
    }

    private func exportEntry(_ item: LibraryEntry) {
        do {
            let url = try store.exportNooty(item.id)
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(share, animated: true)
        } catch {
            showError(error.localizedDescription)
        }
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
        alert.addAction(UIAlertAction(title: confirm, style: .default) { [weak alert] _ in action(alert?.textFields?.first?.text ?? "") })
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
        let form = NewNotebookViewController { [weak self] title, background, size, landscape in
            guard let self else { return }
            do {
                let item = try self.store.createNotebook(title: title, parent: self.folderID, background: background, size: size, landscape: landscape)
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

    private func createBoard() {
        do {
            open(try store.createNotebook(title: "", parent: folderID, background: .standard(.dots), kind: .whiteboard))
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func createDocument() {
        do {
            open(try store.createDocument(title: "", parent: folderID))
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func importFiles() {
        let types = [UTType.pdf, .image, UTType(filenameExtension: "nooty") ?? .data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        let delegate = DocumentPickerDelegate { [weak self] urls in self?.importURLs(urls) }
        pickerHolder = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    func importURLs(_ urls: [URL]) {
        var images: [UIImage] = []
        for url in urls {
            do {
                let ext = url.pathExtension.lowercased()
                let title = url.deletingPathExtension().lastPathComponent
                if ext == "nooty" {
                    try store.importNooty(try Data(contentsOf: url), parent: folderID)
                } else if ext == "pdf" {
                    let data = try Data(contentsOf: url)
                    try store.createImported(title: title, parent: folderID) { try Importers.pdfPages(from: data, into: $0) }
                } else if let image = UIImage(contentsOfFile: url.path) {
                    images.append(image)
                } else {
                    throw ImportError.unsupported
                }
            } catch {
                showError("\(url.lastPathComponent) : \(error.localizedDescription)")
            }
        }
        if !images.isEmpty { createFromImages(images, title: L("library.imported")) }
    }

    private func createFromImages(_ images: [UIImage], title: String) {
        do {
            let item = try store.createImported(title: title, parent: folderID) { try Importers.imagePages(images, into: $0) }
            open(item)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func scan() {
        guard VNDocumentCameraViewController.isSupported else { return showError(L("scan.unsupported")) }
        let scanner = VNDocumentCameraViewController()
        let delegate = ScanDelegate { [weak self] images in self?.createFromImages(images, title: L("library.scanTitle")) }
        pickerHolder = delegate
        scanner.delegate = delegate
        present(scanner, animated: true)
    }

    private func importPhotos() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 50
        let picker = PHPickerViewController(configuration: config)
        let delegate = PhotoPickerDelegate { [weak self] images in
            if !images.isEmpty { self?.createFromImages(images, title: L("library.imported")) }
        }
        pickerHolder = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func presentSettings() {
        let nav = UINavigationController(rootViewController: SettingsViewController(store: store))
        nav.modalPresentationStyle = .formSheet
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
