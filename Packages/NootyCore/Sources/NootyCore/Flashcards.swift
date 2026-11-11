import Foundation

/// Carte de révision recto-verso, planifiée selon la méthode des boîtes de Leitner.
public struct Flashcard: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var front: String
    public var back: String
    /// Boîte de 0 (à apprendre) à 5 (maîtrisée).
    public var box: Int
    /// Prochaine révision (ms depuis 1970).
    public var due: Double

    public init(id: UUID = UUID(), front: String, back: String, box: Int = 0, due: Double = 0) {
        self.id = id
        self.front = front
        self.back = back
        self.box = box
        self.due = due
    }
}

public enum Leitner {
    /// Intervalle avant la prochaine révision, en jours, pour chaque boîte.
    public static let intervals: [Double] = [0, 1, 3, 7, 14, 30]
    private static let day = 86_400_000.0

    /// Met à jour une carte après une réponse : réussie, elle monte d'une boîte ;
    /// ratée, elle revient à la boîte 0 et sera reproposée immédiatement.
    public static func review(_ card: Flashcard, knew: Bool, now: Double) -> Flashcard {
        var c = card
        c.box = knew ? min(c.box + 1, intervals.count - 1) : 0
        c.due = now + intervals[c.box] * day
        return c
    }

    /// Cartes à réviser maintenant, les plus en retard d'abord.
    public static func dueCards(_ cards: [Flashcard], now: Double) -> [Flashcard] {
        cards.filter { $0.due <= now }.sorted { ($0.due, $0.box) < ($1.due, $1.box) }
    }
}

struct FlashcardDTO: Codable {
    var id: String
    var front: String
    var back: String
    var box: Int
    var due: Double

    init(_ c: Flashcard) {
        id = c.id.uuidString
        front = c.front
        back = c.back
        box = c.box
        due = c.due
    }

    func validated() throws -> Flashcard {
        guard let uuid = UUID(uuidString: id) else { throw FormatError.invalid("identifiant de carte") }
        try require(front.count <= 20_000 && back.count <= 20_000, "carte trop longue")
        try require(due.isFinite && due >= 0, "date de révision")
        return Flashcard(id: uuid, front: front, back: back, box: min(max(0, box), Leitner.intervals.count - 1), due: due)
    }
}
