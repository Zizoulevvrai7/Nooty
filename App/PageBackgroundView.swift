import NootyCore
import UIKit

enum Palette {
    static let desk = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : UIColor(red: 0.92, green: 0.906, blue: 0.875, alpha: 1) }
    static let panel = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : UIColor(red: 1, green: 0.992, blue: 0.973, alpha: 1) }
    static let accent = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.96, green: 0.64, blue: 0.42, alpha: 1) : UIColor(red: 0.76, green: 0.31, blue: 0.06, alpha: 1) }
}

/// Dessine le bureau, la page et son motif sous le canevas transparent.
/// Seule la zone visible est dessinée, à l'échelle courante : le motif reste net à tout zoom.
final class PageBackgroundView: UIView {
    var pageSize = CGSize(width: Page.a4Width, height: Page.a4Height) { didSet { setNeedsDisplay() } }
    var background = Background.standard(.ruled) { didSet { setNeedsDisplay() } }
    /// Position de l'origine de la page dans cette vue, et échelle page → écran.
    private(set) var origin = CGPoint.zero
    private(set) var scale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        contentMode = .redraw
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func place(origin: CGPoint, scale: CGFloat) {
        guard origin != self.origin || scale != self.scale else { return }
        self.origin = origin
        self.scale = scale
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        Palette.desk.setFill()
        ctx.fill(rect)

        let page = CGRect(x: origin.x, y: origin.y, width: pageSize.width * scale, height: pageSize.height * scale)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 12, color: UIColor.black.withAlphaComponent(0.18).cgColor)
        InkConverter.uiColor(background.color).setFill()
        ctx.fill(page)
        ctx.restoreGState()

        let visible = page.intersection(rect)
        guard !visible.isNull, background.kind != .blank else { return }
        let step = background.spacing * scale
        guard step >= (background.kind == .dots ? 6 : 3) else { return } // trop dense pour être utile

        ctx.saveGState()
        ctx.clip(to: visible)
        let line = InkConverter.uiColor(background.lineColor)
        let width = max(0.5, min(1.5, 0.8 * scale))
        let firstRow = max(1, Int(((visible.minY - page.minY) / step).rounded(.down)))
        let firstCol = max(1, Int(((visible.minX - page.minX) / step).rounded(.down)))
        var rows: [CGFloat] = []
        var row = firstRow
        while page.minY + CGFloat(row) * step <= visible.maxY {
            rows.append(page.minY + CGFloat(row) * step)
            row += 1
        }
        var cols: [CGFloat] = []
        var col = firstCol
        while page.minX + CGFloat(col) * step <= visible.maxX {
            cols.append(page.minX + CGFloat(col) * step)
            col += 1
        }

        switch background.kind {
        case .blank:
            break
        case .ruled, .grid:
            ctx.setStrokeColor(line.cgColor)
            ctx.setLineWidth(width)
            for y in rows {
                ctx.move(to: CGPoint(x: visible.minX, y: y))
                ctx.addLine(to: CGPoint(x: visible.maxX, y: y))
            }
            if background.kind == .grid {
                for x in cols {
                    ctx.move(to: CGPoint(x: x, y: visible.minY))
                    ctx.addLine(to: CGPoint(x: x, y: visible.maxY))
                }
            }
            ctx.strokePath()
        case .dots:
            ctx.setFillColor(line.cgColor)
            let r = max(1, min(3, 1.4 * scale))
            for y in rows {
                for x in cols { ctx.fillEllipse(in: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)) }
            }
        }
        ctx.restoreGState()
    }
}
