import Foundation

public enum ShapeKind: String, CaseIterable, Sendable {
    case line, arrow, rectangle, ellipse, triangle, diamond
}

/// Forme géométrique définie par le rectangle tracé du point `a` au point `b`.
public struct ShapeSpec: Equatable, Sendable {
    public var kind: ShapeKind
    public var ax, ay, bx, by: Double

    public init(kind: ShapeKind, ax: Double, ay: Double, bx: Double, by: Double) {
        self.kind = kind
        self.ax = ax
        self.ay = ay
        self.bx = bx
        self.by = by
    }

    /// Contours de la forme sous forme de polylignes (une flèche en a deux).
    public func polylines(step: Double = 2) -> [[(x: Double, y: Double)]] {
        let minX = min(ax, bx), maxX = max(ax, bx), minY = min(ay, by), maxY = max(ay, by)
        func densify(_ corners: [(Double, Double)], closed: Bool) -> [(x: Double, y: Double)] {
            var pts = corners
            if closed, let first = corners.first { pts.append(first) }
            var out: [(x: Double, y: Double)] = []
            for i in 0..<max(0, pts.count - 1) {
                let (x0, y0) = pts[i], (x1, y1) = pts[i + 1]
                let n = max(1, Int((hypot(x1 - x0, y1 - y0) / step).rounded(.up)))
                for k in 0..<n {
                    let t = Double(k) / Double(n)
                    out.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
                }
            }
            if let last = pts.last { out.append((last.0, last.1)) }
            return out
        }
        switch kind {
        case .line:
            return [densify([(ax, ay), (bx, by)], closed: false)]
        case .arrow:
            let angle = atan2(by - ay, bx - ax)
            let head = min(24, max(8, hypot(bx - ax, by - ay) * 0.25))
            let left = (bx - head * cos(angle - .pi / 7), by - head * sin(angle - .pi / 7))
            let right = (bx - head * cos(angle + .pi / 7), by - head * sin(angle + .pi / 7))
            return [densify([(ax, ay), (bx, by)], closed: false), densify([left, (bx, by), right], closed: false)]
        case .rectangle:
            return [densify([(minX, minY), (maxX, minY), (maxX, maxY), (minX, maxY)], closed: true)]
        case .triangle:
            return [densify([((minX + maxX) / 2, minY), (maxX, maxY), (minX, maxY)], closed: true)]
        case .diamond:
            let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
            return [densify([(cx, minY), (maxX, cy), (cx, maxY), (minX, cy)], closed: true)]
        case .ellipse:
            let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, rx = (maxX - minX) / 2, ry = (maxY - minY) / 2
            let perimeter = 2 * Double.pi * sqrt((rx * rx + ry * ry) / 2)
            let n = max(24, Int(perimeter / step))
            return [(0...n).map { k in
                let t = Double(k) / Double(n) * 2 * .pi
                return (cx + rx * cos(t), cy + ry * sin(t))
            }]
        }
    }
}

/// Reconnaissance d'une forme dessinée à main levée : segment, rectangle, triangle ou ellipse.
/// Volontairement prudente : en cas de doute, aucune forme n'est proposée.
public enum ShapeRecognizer {
    public static func recognize(_ pts: [(x: Double, y: Double)]) -> ShapeSpec? {
        guard pts.count >= 5, let first = pts.first, let last = pts.last else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let w = maxX - minX, h = maxY - minY
        let diag = hypot(w, h)
        guard diag >= 20 else { return nil }
        var length = 0.0
        for i in 1..<pts.count { length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }

        // Segment : la longueur parcourue est proche de la distance entre les extrémités.
        let chord = hypot(last.x - first.x, last.y - first.y)
        if chord > 0.9 * length {
            return ShapeSpec(kind: .line, ax: first.x, ay: first.y, bx: last.x, by: last.y)
        }

        // Les autres formes doivent être fermées.
        guard chord < 0.2 * length, w > 15, h > 15 else { return nil }

        let corners = cornerCount(pts, diag: diag)
        // Ellipse : distance au contour d'ellipse faible.
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, rx = w / 2, ry = h / 2
        let ellipseError = pts.map { abs(hypot(($0.x - cx) / rx, ($0.y - cy) / ry) - 1) }.reduce(0, +) / Double(pts.count)
        if corners <= 1 && ellipseError < 0.12 {
            return ShapeSpec(kind: .ellipse, ax: minX, ay: minY, bx: maxX, by: maxY)
        }
        if corners == 3 {
            return ShapeSpec(kind: .triangle, ax: minX, ay: minY, bx: maxX, by: maxY)
        }
        // Rectangle : les points restent près des bords de la boîte englobante.
        let edgeError = pts.map { p in min(abs(p.x - minX), abs(p.x - maxX), abs(p.y - minY), abs(p.y - maxY)) }.reduce(0, +) / Double(pts.count)
        if corners == 4 && edgeError < 0.06 * diag {
            return ShapeSpec(kind: .rectangle, ax: minX, ay: minY, bx: maxX, by: maxY)
        }
        return nil
    }

    /// Nombre de changements de direction marqués (plus de 50°), mesurés sur une trace rééchantillonnée.
    static func cornerCount(_ pts: [(x: Double, y: Double)], diag: Double) -> Int {
        let step = max(2, diag / 25)
        var resampled: [(x: Double, y: Double)] = [pts[0]]
        for p in pts.dropFirst() {
            if let l = resampled.last, hypot(p.x - l.x, p.y - l.y) >= step { resampled.append(p) }
        }
        guard resampled.count >= 6 else { return 0 }
        var count = 0
        var cooldown = 0
        let k = 2
        for i in k..<(resampled.count - k) {
            if cooldown > 0 {
                cooldown -= 1
                continue
            }
            let a = resampled[i - k], b = resampled[i], c = resampled[i + k]
            let a1 = atan2(b.y - a.y, b.x - a.x), a2 = atan2(c.y - b.y, c.x - b.x)
            var d = abs(a2 - a1)
            if d > .pi { d = 2 * .pi - d }
            if d > 50 * .pi / 180 {
                count += 1
                cooldown = 2 * k
            }
        }
        // Le point de départ d'une forme fermée est souvent un coin non détecté.
        let first = resampled[0], second = resampled[min(k, resampled.count - 1)]
        let beforeLast = resampled[resampled.count - 1 - min(k, resampled.count - 1)]
        let a1 = atan2(first.y - beforeLast.y, first.x - beforeLast.x), a2 = atan2(second.y - first.y, second.x - first.x)
        var d = abs(a2 - a1)
        if d > .pi { d = 2 * .pi - d }
        if d > 50 * .pi / 180 { count += 1 }
        return count
    }
}
