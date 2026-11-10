import NootyCore
import UIKit

/// Dessin du papier (couleur et réglure) pour l'éditeur, les miniatures et les aperçus de modèles.
enum PaperRenderer {
    /// - Parameters:
    ///   - pageRect: rectangle de la page dans le repère du contexte.
    ///   - scale: facteur points typographiques → unités du contexte.
    ///   - clip: zone réellement visible ; rien n'est dessiné en dehors.
    static func draw(_ bg: Background, pageRect page: CGRect, scale: CGFloat, clip: CGRect, in ctx: CGContext) {
        let visible = page.intersection(clip)
        guard !visible.isNull, !visible.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: visible)
        ctx.setFillColor(InkConverter.uiColor(bg.color).cgColor)
        ctx.fill(visible)
        defer { ctx.restoreGState() }

        let step = CGFloat(bg.spacing) * scale
        guard bg.kind != .blank, step >= 3 else { return }
        let line = InkConverter.uiColor(bg.lineColor)
        let hair = max(0.5, min(1.4, 0.8 * scale))

        func positions(from origin: CGFloat, low: CGFloat, high: CGFloat, step: CGFloat) -> [CGFloat] {
            var out: [CGFloat] = []
            var k = max(1, Int(((low - origin) / step).rounded(.down)))
            while origin + CGFloat(k) * step <= high {
                if origin + CGFloat(k) * step >= low - 1 { out.append(origin + CGFloat(k) * step) }
                k += 1
            }
            return out
        }
        func horizontals(_ ys: [CGFloat], color: UIColor, width: CGFloat) {
            guard !ys.isEmpty else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            for y in ys {
                ctx.move(to: CGPoint(x: visible.minX, y: y))
                ctx.addLine(to: CGPoint(x: visible.maxX, y: y))
            }
            ctx.strokePath()
        }
        func verticals(_ xs: [CGFloat], color: UIColor, width: CGFloat) {
            guard !xs.isEmpty else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            for x in xs {
                ctx.move(to: CGPoint(x: x, y: visible.minY))
                ctx.addLine(to: CGPoint(x: x, y: visible.maxY))
            }
            ctx.strokePath()
        }

        let rows = positions(from: page.minY, low: visible.minY, high: visible.maxY, step: step)
        let cols = positions(from: page.minX, low: visible.minX, high: visible.maxX, step: step)

        switch bg.kind {
        case .blank:
            break
        case .ruled:
            horizontals(rows, color: line, width: hair)
        case .grid:
            horizontals(rows, color: line, width: hair)
            verticals(cols, color: line, width: hair)
        case .dots:
            guard step >= 6 else { return }
            ctx.setFillColor(line.cgColor)
            let r = max(1, min(3, 1.5 * scale))
            for y in rows {
                for x in cols { ctx.fillEllipse(in: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)) }
            }
        case .seyes:
            // Interlignes fins tous les 2 mm, visibles seulement s'ils restent lisibles.
            let fine = step / 4
            if fine >= 3 {
                let all = positions(from: page.minY, low: visible.minY, high: visible.maxY, step: fine)
                let thin = all.filter { y in !rows.contains { abs($0 - y) < 0.5 } }
                horizontals(thin, color: UIColor(hex: 0xBFD6F2), width: max(0.5, hair * 0.7))
            }
            let marginX = page.minX + 4 * step
            verticals(cols.filter { abs($0 - marginX) > 0.5 }, color: UIColor(hex: 0xC9CAD9), width: max(0.5, hair * 0.7))
            horizontals(rows, color: line, width: hair * 1.15)
            if marginX >= visible.minX - 1, marginX <= visible.maxX + 1 {
                verticals([marginX], color: UIColor(hex: 0xE2536F), width: hair * 1.3)
            }
        }
    }

    /// Aperçu d'un papier, pour les miniatures et le choix du modèle.
    static func image(_ bg: Background, pageSize: CGSize, width: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: (width * pageSize.height / pageSize.width).rounded())
        return UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size)
            draw(bg, pageRect: rect, scale: width / pageSize.width, clip: rect, in: context.cgContext)
        }
    }
}

/// Affiche le bureau et les pages du carnet sous le canevas d'écriture transparent.
/// Seule la zone visible est dessinée, à l'échelle courante : la réglure reste nette à tout zoom.
final class PagesBackgroundView: UIView {
    private var frames: [CGRect] = []
    private var backgrounds: [Background] = []
    private var origin = CGPoint.zero
    private var scale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = Theme.desk
        isUserInteractionEnabled = false
        contentMode = .redraw
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func setPages(_ pages: [PageInfo], layout: PageLayout) {
        frames = layout.frames.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        backgrounds = pages.map(\.background)
        setNeedsDisplay()
    }

    /// Position de l'origine de la surface d'écriture dans cette vue, et échelle courante.
    func place(origin: CGPoint, scale: CGFloat) {
        guard origin != self.origin || scale != self.scale else { return }
        self.origin = origin
        self.scale = scale
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        Theme.desk.setFill()
        ctx.fill(rect)
        for (frame, bg) in zip(frames, backgrounds) {
            let page = CGRect(
                x: origin.x + frame.minX * scale, y: origin.y + frame.minY * scale,
                width: frame.width * scale, height: frame.height * scale
            )
            guard page.intersects(rect.insetBy(dx: -24, dy: -24)) else { continue }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10, color: UIColor.black.withAlphaComponent(0.16).cgColor)
            ctx.setFillColor(InkConverter.uiColor(bg.color).cgColor)
            ctx.fill(page)
            ctx.restoreGState()
            PaperRenderer.draw(bg, pageRect: page, scale: scale, clip: rect, in: ctx)
        }
    }
}
