import Foundation

public enum LibraryEntryKind: String, Sendable {
    case folder, notebook, whiteboard, document

    /// Vrai pour les éléments qui ont un dossier de fichiers (tout sauf les dossiers de la bibliothèque).
    public var hasFiles: Bool { self != .folder }
}

/// Entrée de la bibliothèque : un dossier ou un carnet.
public struct LibraryEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: LibraryEntryKind
    /// Dossier parent ; nil à la racine.
    public var parentID: UUID?
    public var title: String
    /// Dates en millisecondes depuis 1970.
    public var createdAt: Double
    public var updatedAt: Double
    public var favorite: Bool
    /// Couleur de la couverture ou du dossier.
    public var color: RGBA
    /// Date de mise à la corbeille ; nil si l'élément n'y est pas.
    public var trashedAt: Double?
    /// Ouverture protégée par Face ID ou le code de l'iPad.
    public var locked: Bool

    public init(
        id: UUID = UUID(), kind: LibraryEntryKind, parentID: UUID? = nil, title: String,
        createdAt: Double, updatedAt: Double? = nil, favorite: Bool = false,
        color: RGBA = .ink, trashedAt: Double? = nil, locked: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.favorite = favorite
        self.color = color
        self.trashedAt = trashedAt
        self.locked = locked
    }
}

public enum LibrarySort: String, CaseIterable, Sendable {
    case name, modified, created
}

/// Index de la bibliothèque. Toutes les opérations sont pures et déterministes.
public struct LibraryIndex: Equatable, Sendable {
    public static let maxTitleLength = 120
    public static let maxItems = 100_000

    public private(set) var items: [LibraryEntry]

    public init(items: [LibraryEntry] = []) {
        self.items = items
        repair()
    }

    public func item(_ id: UUID) -> LibraryEntry? {
        items.first { $0.id == id }
    }

    private func indexOf(_ id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// Vrai si l'élément ou l'un de ses dossiers parents est dans la corbeille.
    public func isEffectivelyTrashed(_ id: UUID) -> Bool {
        var current = item(id)
        var guardCount = 0
        while let it = current, guardCount <= items.count {
            if it.trashedAt != nil { return true }
            current = it.parentID.flatMap(item)
            guardCount += 1
        }
        return false
    }

    /// Tous les descendants d'un dossier, à tous les niveaux.
    public func descendants(of id: UUID) -> [UUID] {
        var out: [UUID] = []
        var queue = [id]
        while let next = queue.popLast() {
            for child in items where child.parentID == next {
                out.append(child.id)
                queue.append(child.id)
            }
        }
        return out
    }

    /// Chemin depuis la racine jusqu'au parent de l'élément (dossiers ancêtres).
    public func ancestors(of id: UUID) -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        var current = item(id)?.parentID.flatMap(item)
        while let it = current, out.count <= items.count {
            out.insert(it, at: 0)
            current = it.parentID.flatMap(item)
        }
        return out
    }

    private func sorted(_ list: [LibraryEntry], by sort: LibrarySort) -> [LibraryEntry] {
        list.sorted { a, b in
            let fa = a.kind == .folder, fb = b.kind == .folder
            if fa != fb { return fa }
            switch sort {
            case .name:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .modified:
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            case .created:
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Contenu d'un dossier (ou de la racine), hors corbeille, dossiers en premier.
    public func children(of parent: UUID?, sort: LibrarySort = .name) -> [LibraryEntry] {
        sorted(items.filter { $0.parentID == parent && $0.trashedAt == nil }, by: sort)
    }

    public func favorites(sort: LibrarySort = .name) -> [LibraryEntry] {
        sorted(items.filter { $0.favorite && !isEffectivelyTrashed($0.id) }, by: sort)
    }

    /// Éléments mis directement à la corbeille (leur contenu les suit sans être listé).
    public func trashed() -> [LibraryEntry] {
        items.filter { $0.trashedAt != nil }.sorted { ($0.trashedAt ?? 0) > ($1.trashedAt ?? 0) }
    }

    /// Dossiers pouvant recevoir l'élément : ni lui-même, ni ses descendants, ni la corbeille.
    public func moveTargets(for id: UUID) -> [LibraryEntry] {
        let excluded = Set(descendants(of: id) + [id])
        return sorted(items.filter { $0.kind == .folder && !excluded.contains($0.id) && !isEffectivelyTrashed($0.id) }, by: .name)
    }

    /// Nettoie un titre saisi : espaces superflus retirés, longueur bornée. nil si vide.
    public static func normalizedTitle(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxTitleLength))
    }

    /// Titre libre dans un dossier : « Titre », puis « Titre 2 », « Titre 3 »…
    public func uniqueTitle(_ base: String, in parent: UUID?) -> String {
        let taken = Set(items.filter { $0.parentID == parent && $0.trashedAt == nil }.map { $0.title.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Modifications

    @discardableResult
    public mutating func add(_ item: LibraryEntry) -> Bool {
        guard indexOf(item.id) == nil, items.count < Self.maxItems else { return false }
        var copy = item
        if let parent = copy.parentID, self.item(parent)?.kind != .folder { copy.parentID = nil }
        items.append(copy)
        return true
    }

    @discardableResult
    public mutating func rename(_ id: UUID, to raw: String, now: Double) -> Bool {
        guard let i = indexOf(id), let title = Self.normalizedTitle(raw) else { return false }
        items[i].title = title
        items[i].updatedAt = now
        return true
    }

    public mutating func setFavorite(_ id: UUID, _ value: Bool) {
        if let i = indexOf(id) { items[i].favorite = value }
    }

    public mutating func setLocked(_ id: UUID, _ value: Bool) {
        if let i = indexOf(id) { items[i].locked = value }
    }

    /// Éléments hors corbeille dont le titre contient la recherche (sans tenir compte des accents ni de la casse).
    public func search(_ query: String) -> [LibraryEntry] {
        let q = TextSearch.normalize(query)
        guard !q.isEmpty else { return [] }
        return sorted(items.filter { !isEffectivelyTrashed($0.id) && TextSearch.normalize($0.title).contains(q) }, by: .name)
    }

    public mutating func setColor(_ id: UUID, _ color: RGBA) {
        if let i = indexOf(id) { items[i].color = color }
    }

    public mutating func touch(_ id: UUID, now: Double) {
        if let i = indexOf(id) { items[i].updatedAt = now }
    }

    public mutating func trash(_ id: UUID, now: Double) {
        if let i = indexOf(id) { items[i].trashedAt = now }
    }

    /// Sort l'élément de la corbeille. Si son dossier d'origine a disparu ou est
    /// lui-même à la corbeille, l'élément revient à la racine.
    public mutating func restore(_ id: UUID) {
        guard let i = indexOf(id) else { return }
        items[i].trashedAt = nil
        if let parent = items[i].parentID, item(parent) == nil || isEffectivelyTrashed(parent) {
            items[i].parentID = nil
        }
    }

    /// Supprime définitivement l'élément et tout son contenu.
    /// Retourne les identifiants des carnets dont les fichiers doivent être effacés.
    @discardableResult
    public mutating func deletePermanently(_ id: UUID) -> [UUID] {
        let doomed = Set(descendants(of: id) + [id])
        let notebooks = items.filter { doomed.contains($0.id) && $0.kind.hasFiles }.map(\.id)
        items.removeAll { doomed.contains($0.id) }
        return notebooks
    }

    /// Déplace l'élément dans un dossier (nil : racine). Refuse un dossier dans lui-même
    /// ou dans l'un de ses descendants, et toute destination qui n'est pas un dossier.
    @discardableResult
    public mutating func move(_ id: UUID, to parent: UUID?, now: Double) -> Bool {
        guard let i = indexOf(id) else { return false }
        if let parent {
            guard let target = item(parent), target.kind == .folder else { return false }
            if parent == id || descendants(of: id).contains(parent) { return false }
        }
        items[i].parentID = parent
        items[i].updatedAt = now
        return true
    }

    /// Répare les références invalides : parent absent ou non-dossier, cycles.
    private mutating func repair() {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in items.indices {
            guard let parent = items[i].parentID else { continue }
            if byID[parent]?.kind != .folder { items[i].parentID = nil }
        }
        for i in items.indices {
            var seen: Set<UUID> = [items[i].id]
            var current = items[i].parentID
            while let p = current {
                if !seen.insert(p).inserted {
                    items[i].parentID = nil
                    break
                }
                current = items.first { $0.id == p }?.parentID
            }
        }
    }
}

// MARK: - Fichier d'index

public enum LibraryCodec {
    public static let format = "nooty.library"
    public static let maxBytes = 64 * 1024 * 1024

    public static func encode(_ index: LibraryIndex) throws -> Data {
        let file = LibraryFileDTO(format: format, schemaVersion: NootyFormat.schemaVersion, items: index.items.map(LibraryEntryDTO.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> LibraryIndex {
        try checkHeader(data, format: format, maxBytes: maxBytes, currentVersion: NootyFormat.schemaVersion)
        let file: LibraryFileDTO
        do {
            file = try JSONDecoder().decode(LibraryFileDTO.self, from: data)
        } catch {
            throw FormatError.invalid("structure")
        }
        try require(file.items.count <= LibraryIndex.maxItems, "trop d’éléments")
        var seen = Set<UUID>()
        let items: [LibraryEntry] = try file.items.map { dto in
            let item = try dto.validated()
            try require(seen.insert(item.id).inserted, "identifiant en double")
            return item
        }
        return LibraryIndex(items: items)
    }
}

struct LibraryFileDTO: Codable {
    var format: String
    var schemaVersion: Int
    var items: [LibraryEntryDTO]
}

struct LibraryEntryDTO: Codable {
    var id: String
    var kind: String
    var parentID: String?
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var favorite: Bool
    var color: String
    var trashedAt: Double?
    var locked: Bool?

    init(_ i: LibraryEntry) {
        id = i.id.uuidString
        kind = i.kind.rawValue
        parentID = i.parentID?.uuidString
        title = i.title
        createdAt = i.createdAt
        updatedAt = i.updatedAt
        favorite = i.favorite
        color = i.color.hex
        trashedAt = i.trashedAt
        locked = i.locked
    }

    func validated() throws -> LibraryEntry {
        guard let uuid = UUID(uuidString: id) else { throw FormatError.invalid("identifiant") }
        guard let itemKind = LibraryEntryKind(rawValue: kind) else { throw FormatError.invalid("type d’élément") }
        guard let cleanTitle = LibraryIndex.normalizedTitle(title) else { throw FormatError.invalid("titre") }
        guard let rgba = RGBA(hex: color) else { throw FormatError.invalid("couleur") }
        var parent: UUID?
        if let parentID {
            guard let p = UUID(uuidString: parentID) else { throw FormatError.invalid("dossier parent") }
            parent = p
        }
        try require(createdAt.isFinite && createdAt >= 0 && updatedAt.isFinite && updatedAt >= 0, "dates")
        if let trashedAt { try require(trashedAt.isFinite && trashedAt >= 0, "date de corbeille") }
        return LibraryEntry(
            id: uuid, kind: itemKind, parentID: parent, title: cleanTitle, createdAt: createdAt,
            updatedAt: updatedAt, favorite: favorite, color: rgba, trashedAt: trashedAt, locked: locked ?? false
        )
    }
}
