import Foundation

/// Recherche plein texte simple, insensible à la casse et aux accents.
public enum TextSearch {
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Extrait autour de la première occurrence de la recherche, ou nil si elle est absente.
    public static func snippet(_ text: String, query: String, radius: Int = 40) -> String? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        let flat = words.joined(separator: " ")
        let normalized = normalize(flat)
        guard let range = normalized.range(of: q) else { return nil }
        // Le pliage peut changer la longueur de certains caractères : on travaille en positions relatives.
        let ratio = Double(flat.count) / Double(max(1, normalized.count))
        let start = Int(Double(normalized.distance(from: normalized.startIndex, to: range.lowerBound)) * ratio)
        let lower = max(0, start - radius)
        let upper = min(flat.count, start + q.count + radius)
        let a = flat.index(flat.startIndex, offsetBy: lower)
        let b = flat.index(flat.startIndex, offsetBy: upper)
        return (lower > 0 ? "…" : "") + flat[a..<b] + (upper < flat.count ? "…" : "")
    }
}

/// Texte indexé d'un bloc-notes, reconstructible : texte saisi, texte des PDF, écriture reconnue
/// et transcriptions. Stocké à part du contenu.
public struct NotebookTextIndex: Equatable, Sendable {
    /// Texte de chaque page, par identifiant de page.
    public var pages: [UUID: String]
    /// Transcription de chaque enregistrement.
    public var recordings: [UUID: String]

    public init(pages: [UUID: String] = [:], recordings: [UUID: String] = [:]) {
        self.pages = pages
        self.recordings = recordings
    }

    public struct Hit: Equatable, Sendable {
        public var pageIndex: Int?
        public var recordingID: UUID?
        public var snippet: String
    }

    /// Résultats dans l'ordre des pages, puis des enregistrements.
    public func search(_ query: String, pageOrder: [UUID], recordingOrder: [UUID]) -> [Hit] {
        var hits: [Hit] = []
        for (i, id) in pageOrder.enumerated() {
            if let text = pages[id], let s = TextSearch.snippet(text, query: query) {
                hits.append(Hit(pageIndex: i, recordingID: nil, snippet: s))
            }
        }
        for id in recordingOrder {
            if let text = recordings[id], let s = TextSearch.snippet(text, query: query) {
                hits.append(Hit(pageIndex: nil, recordingID: id, snippet: s))
            }
        }
        return hits
    }

    public func encoded() throws -> Data {
        let dto = [
            "pages": Dictionary(uniqueKeysWithValues: pages.map { ($0.key.uuidString, $0.value) }),
            "recordings": Dictionary(uniqueKeysWithValues: recordings.map { ($0.key.uuidString, $0.value) }),
        ]
        return try JSONEncoder().encode(dto)
    }

    /// Lecture tolérante : un index abîmé est simplement reconstruit.
    public static func decode(_ data: Data) -> NotebookTextIndex {
        guard data.count < 64 * 1024 * 1024,
              let dto = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return NotebookTextIndex() }
        func map(_ d: [String: String]?) -> [UUID: String] {
            Dictionary(uniqueKeysWithValues: (d ?? [:]).compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
        return NotebookTextIndex(pages: map(dto["pages"]), recordings: map(dto["recordings"]))
    }
}
