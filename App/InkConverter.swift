import NootyCore
import PencilKit
import UIKit

/// Conversion entre les traits PencilKit et le modèle documentaire de Nooty.
/// Toutes les données de chaque point sont conservées, afin que la conversion aller-retour
/// redonne le même tracé.
enum InkConverter {
    static func tool(_ type: PKInk.InkType) -> InkTool {
        switch type {
        case .pen: return .pen
        case .pencil: return .pencil
        case .marker: return .marker
        case .monoline: return .monoline
        case .fountainPen: return .fountainPen
        case .watercolor: return .watercolor
        case .crayon: return .crayon
        @unknown default: return .pen
        }
    }

    static func inkType(_ tool: InkTool) -> PKInk.InkType {
        switch tool {
        case .pen: return .pen
        case .pencil: return .pencil
        case .marker: return .marker
        case .monoline: return .monoline
        case .fountainPen: return .fountainPen
        case .watercolor: return .watercolor
        case .crayon: return .crayon
        }
    }

    static func rgba(_ color: UIColor) -> RGBA {
        let c = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !c.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            c.getWhite(&w, alpha: &a)
            r = w
            g = w
            b = w
        }
        return RGBA(r: r, g: g, b: b, a: a)
    }

    static func uiColor(_ c: RGBA) -> UIColor {
        UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static func stroke(from s: PKStroke, id: UUID = UUID()) -> Stroke {
        let points = s.path.map { p in
            InkPoint(
                x: p.location.x, y: p.location.y, timeOffset: p.timeOffset,
                width: p.size.width, height: p.size.height, opacity: p.opacity, force: p.force,
                azimuth: p.azimuth, altitude: p.altitude, secondaryScale: p.secondaryScale
            )
        }
        let t = s.transform
        return Stroke(
            id: id,
            tool: tool(s.ink.inkType),
            color: rgba(s.ink.color),
            points: points,
            transform: AffineMatrix(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty),
            mask: s.mask.map { elements(of: $0.cgPath) },
            // Arrondi à la milliseconde : l'empreinte d'identité reste stable après rechargement.
            createdAt: (s.path.creationDate.timeIntervalSince1970 * 1000).rounded(),
            randomSeed: s.randomSeed
        )
    }

    static func pkStroke(_ s: Stroke) -> PKStroke {
        let points = s.points.map { p in
            PKStrokePoint(
                location: CGPoint(x: p.x, y: p.y), timeOffset: p.timeOffset,
                size: CGSize(width: p.width, height: p.height), opacity: p.opacity, force: p.force,
                azimuth: p.azimuth, altitude: p.altitude, secondaryScale: p.secondaryScale
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: s.createdAt / 1000))
        let m = s.transform
        return PKStroke(
            ink: PKInk(inkType(s.tool), color: uiColor(s.color)),
            path: path,
            transform: CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty),
            mask: s.mask.map(bezier),
            randomSeed: s.randomSeed
        )
    }

    static func drawing(_ strokes: [Stroke]) -> PKDrawing {
        PKDrawing(strokes: strokes.map(pkStroke))
    }

    static func elements(of path: CGPath) -> [PathElement] {
        var out: [PathElement] = []
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            let p = e.points
            switch e.type {
            case .moveToPoint: out.append(.move(p[0].x, p[0].y))
            case .addLineToPoint: out.append(.line(p[0].x, p[0].y))
            case .addQuadCurveToPoint: out.append(.quad(p[0].x, p[0].y, p[1].x, p[1].y))
            case .addCurveToPoint: out.append(.cubic(p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y))
            case .closeSubpath: out.append(.close)
            @unknown default: break
            }
        }
        return out
    }

    static func bezier(_ elements: [PathElement]) -> UIBezierPath {
        let path = CGMutablePath()
        for e in elements {
            switch e {
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): path.addLine(to: CGPoint(x: x, y: y))
            case let .quad(cx, cy, x, y): path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case let .cubic(c1x, c1y, c2x, c2y, x, y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            case .close: path.closeSubpath()
            }
        }
        return UIBezierPath(cgPath: path)
    }
}
