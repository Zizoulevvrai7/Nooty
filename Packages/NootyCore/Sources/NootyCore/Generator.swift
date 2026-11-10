import Foundation

/// Générateur pseudo-aléatoire déterministe (SplitMix64).
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Valeur dans [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    public mutating func uuid() -> UUID {
        let a = next(), b = next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: a >> (UInt64(i) * 8))
            bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (UInt64(i) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Génère des traits ressemblant à de l'écriture, de façon déterministe, pour les tests de charge.
public enum StrokeGenerator {
    public static func handwriting(
        count: Int, pageWidth: Double, pageHeight: Double, seed: UInt64, createdAt: Double
    ) -> [Stroke] {
        var rng = SplitMix64(seed: seed)
        let margin = 28.0
        let lines = max(1, Int((Double(count) / 60).rounded(.up)))
        let lineHeight = max(6, (pageHeight - 2 * margin) / Double(lines))
        var x = margin
        var y = margin + lineHeight
        var strokes: [Stroke] = []
        strokes.reserveCapacity(count)
        for i in 0..<count {
            let w = 4 + rng.unit() * 6
            if x + w > pageWidth - margin {
                x = margin
                y += lineHeight
                if y > pageHeight - margin { y = margin + lineHeight }
            }
            let n = 24 + Int(rng.unit() * 24)
            let phase = rng.unit() * .pi * 2
            let loops = 1 + rng.unit() * 2
            let h = lineHeight * (0.35 + rng.unit() * 0.4)
            var pts: [InkPoint] = []
            pts.reserveCapacity(n)
            for k in 0..<n {
                let u = Double(k) / Double(n - 1)
                let angle = phase + u * loops * .pi * 2
                pts.append(InkPoint(
                    x: x + u * w + cos(angle) * w * 0.18,
                    y: y - h / 2 + sin(angle) * h / 2,
                    timeOffset: Double(k) * 0.008,
                    width: 1.6, height: 1.6,
                    force: 0.5 + 0.5 * abs(sin(angle / 2)),
                    azimuth: 0.6, altitude: 1.1
                ))
            }
            strokes.append(Stroke(
                id: rng.uuid(), tool: .pen, color: .ink, points: pts,
                createdAt: createdAt + Double(i), randomSeed: UInt32(truncatingIfNeeded: rng.next())
            ))
            x += w + 2 + rng.unit() * 3
        }
        return strokes
    }
}
