import Foundation

/// Portion continue d'un enregistrement : entre deux pauses.
/// `wallStart` est l'heure réelle (ms depuis 1970) du début de la portion,
/// `offset` sa position dans le fichier audio (secondes), `length` sa durée (secondes).
public struct RecordingSpan: Equatable, Sendable {
    public var wallStart: Double
    public var offset: Double
    public var length: Double

    public init(wallStart: Double, offset: Double, length: Double) {
        self.wallStart = wallStart
        self.offset = offset
        self.length = length
    }
}

/// Segment de transcription, positionné dans le fichier audio (secondes).
public struct TranscriptSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct AudioRecording: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// Fichier audio dans les ressources du bloc-notes.
    public var resource: String
    public var spans: [RecordingSpan]
    public var transcript: [TranscriptSegment]
    public var summary: String?

    public init(id: UUID = UUID(), title: String, resource: String, spans: [RecordingSpan] = [], transcript: [TranscriptSegment] = [], summary: String? = nil) {
        self.id = id
        self.title = title
        self.resource = resource
        self.spans = spans
        self.transcript = transcript
        self.summary = summary
    }

    /// Durée totale du fichier audio, en secondes.
    public var duration: Double { spans.map { $0.offset + $0.length }.max() ?? 0 }

    public var startedAt: Double? { spans.first?.wallStart }

    /// Position dans l'audio (secondes) correspondant à une heure réelle, si l'enregistrement
    /// tournait à ce moment-là. Pendant une pause, renvoie nil.
    public func audioTime(atWall wall: Double) -> Double? {
        for span in spans {
            let end = span.wallStart + span.length * 1000
            if wall >= span.wallStart && wall <= end {
                return span.offset + (wall - span.wallStart) / 1000
            }
        }
        return nil
    }

    /// Heure réelle correspondant à une position dans l'audio.
    public func wallTime(atAudio t: Double) -> Double? {
        for span in spans where t >= span.offset && t <= span.offset + span.length {
            return span.wallStart + (t - span.offset) * 1000
        }
        return nil
    }

    /// Texte complet de la transcription.
    public var transcriptText: String {
        transcript.map(\.text).joined(separator: " ")
    }
}

struct RecordingSpanDTO: Codable {
    var wallStart: Double
    var offset: Double
    var length: Double
}

struct TranscriptSegmentDTO: Codable {
    var start: Double
    var end: Double
    var text: String
}

struct AudioRecordingDTO: Codable {
    var id: String
    var title: String
    var resource: String
    var spans: [RecordingSpanDTO]
    var transcript: [TranscriptSegmentDTO]
    var summary: String?

    init(_ r: AudioRecording) {
        id = r.id.uuidString
        title = r.title
        resource = r.resource
        spans = r.spans.map { RecordingSpanDTO(wallStart: $0.wallStart, offset: $0.offset, length: $0.length) }
        transcript = r.transcript.map { TranscriptSegmentDTO(start: $0.start, end: $0.end, text: $0.text) }
        summary = r.summary
    }

    func validated() throws -> AudioRecording {
        guard let uuid = UUID(uuidString: id) else { throw FormatError.invalid("identifiant d’enregistrement") }
        try require(ResourceName.isValid(resource) && resource.lowercased().hasSuffix(".m4a"), "fichier audio")
        guard let cleanTitle = LibraryIndex.normalizedTitle(title) else { throw FormatError.invalid("titre d’enregistrement") }
        try require(spans.count <= 10_000 && transcript.count <= 200_000, "enregistrement trop long")
        let s = try spans.map { d -> RecordingSpan in
            try require([d.wallStart, d.offset, d.length].allSatisfy { $0.isFinite && $0 >= 0 }, "portion d’enregistrement")
            return RecordingSpan(wallStart: d.wallStart, offset: d.offset, length: d.length)
        }
        let t = try transcript.map { d -> TranscriptSegment in
            try require(d.start.isFinite && d.end.isFinite && d.start >= 0 && d.end >= d.start, "segment de transcription")
            try require(d.text.count <= 10_000, "segment trop long")
            return TranscriptSegment(start: d.start, end: d.end, text: d.text)
        }
        if let summary { try require(summary.count <= 200_000, "résumé trop long") }
        return AudioRecording(id: uuid, title: cleanTitle, resource: resource, spans: s, transcript: t, summary: summary)
    }
}
