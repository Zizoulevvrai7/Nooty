import Foundation

/// Empreinte d'un trait, indépendante de sa position (transformation) et de sa couleur.
/// Sert à garder un identifiant stable quand le moteur d'encre ne fournit pas d'identité.
public struct StrokeIdentityKey: Hashable, Sendable {
    let seed: UInt32
    let createdMs: Int64
    let count: Int
    let firstX: UInt32
    let firstY: UInt32
    let tool: InkTool
}

extension Stroke {
    public var identityKey: StrokeIdentityKey {
        let first = points.first
        return StrokeIdentityKey(
            seed: randomSeed,
            createdMs: Int64(createdAt.rounded()),
            count: points.count,
            firstX: Float32(first?.x ?? 0).bitPattern,
            firstY: Float32(first?.y ?? 0).bitPattern,
            tool: tool
        )
    }
}

public enum IdentityMatcher {
    /// Réattribue aux traits courants l'identifiant du trait précédent de même empreinte.
    /// Un trait déplacé ou recoloré garde son identifiant ; un trait coupé par la gomme
    /// produit de nouveaux traits, donc de nouveaux identifiants. Les doublons exacts
    /// (copier-coller) reçoivent les identifiants disponibles dans l'ordre, puis de nouveaux.
    public static func assignIDs(previous: [Stroke], current: [Stroke], makeID: () -> UUID = { UUID() }) -> [Stroke] {
        var pool: [StrokeIdentityKey: [UUID]] = [:]
        for s in previous { pool[s.identityKey, default: []].append(s.id) }
        return current.map { stroke in
            var s = stroke
            let key = s.identityKey
            if var ids = pool[key], !ids.isEmpty {
                s.id = ids.removeFirst()
                pool[key] = ids
            } else {
                s.id = makeID()
            }
            return s
        }
    }
}
