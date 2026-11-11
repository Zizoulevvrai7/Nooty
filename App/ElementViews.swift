import NootyCore
import UIKit

/// Calque des éléments (images, textes, notes, rubans) superposé aux pages.
/// Le contenu est positionné en coordonnées de la surface d'écriture (points de page empilés)
/// et suit le défilement et le zoom par une simple transformation.
final class ElementsLayerView: UIView {
    enum Content { case content, tapes }

    let kind: Content
    var resources: URL?
    /// Appelé quand on touche un ruban (calque des rubans uniquement).
    var onTapeTap: ((_ pageIndex: Int, _ id: UUID) -> Void)?
    var tapesInteractive = true

    private let canvas = UIView()
    private var views: [UUID: UIView] = [:]
    private var locations: [UUID: Int] = [:]
    private var scale: CGFloat = 1

    init(kind: Content) {
        self.kind = kind
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        canvas.layer.anchorPoint = .zero
        canvas.isOpaque = false
        addSubview(canvas)
        isUserInteractionEnabled = kind == .tapes
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func place(offset: CGPoint, scale: CGFloat) {
        self.scale = scale
        canvas.transform = .identity
        canvas.layer.position = CGPoint(x: -offset.x, y: -offset.y)
        canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// Ajuste la netteté du texte au zoom courant (appelé à la fin d'un zoom).
    func refreshSharpness() {
        let target = UIScreen.main.scale * max(1, scale)
        for v in views.values where v is TextElementView {
            v.contentScaleFactor = target
            v.setNeedsDisplay()
        }
    }

    /// Reconstruit les vues des éléments des pages.
    func update(elements: [[PageElement]], layout: PageLayout, hidden: Set<UUID> = []) {
        canvas.bounds = CGRect(x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
        var keep = Set<UUID>()
        for (pageIndex, list) in elements.enumerated() where pageIndex < layout.frames.count {
            let page = layout.frames[pageIndex]
            for element in list {
                let isTape = PageRenderer.isTape(element)
                guard isTape == (kind == .tapes) else { continue }
                keep.insert(element.id)
                let view = views[element.id] ?? makeView(for: element)
                views[element.id] = view
                locations[element.id] = pageIndex
                if view.superview == nil { canvas.addSubview(view) }
                configure(view, element: element, origin: CGPoint(x: page.x, y: page.y))
                view.isHidden = hidden.contains(element.id)
                canvas.bringSubviewToFront(view)
            }
        }
        for (id, view) in views where !keep.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
            locations[id] = nil
        }
    }

    private func makeView(for element: PageElement) -> UIView {
        switch element {
        case .image:
            let v = UIImageView()
            v.contentMode = .scaleToFill
            v.clipsToBounds = true
            return v
        case .text:
            return TextElementView()
        case .tape:
            let v = UIView()
            v.layer.cornerRadius = 3
            v.isAccessibilityElement = true
            v.accessibilityTraits = .button
            v.accessibilityLabel = L("tape.label")
            v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapeTapped(_:))))
            return v
        }
    }

    private func configure(_ view: UIView, element: PageElement, origin: CGPoint) {
        let f = element.frame
        view.transform = .identity
        view.bounds = CGRect(x: 0, y: 0, width: f.width, height: f.height)
        view.center = CGPoint(x: origin.x + f.midX, y: origin.y + f.midY)
        switch element {
        case let .image(i):
            guard let imageView = view as? UIImageView else { return }
            if let resources { imageView.image = ImageCache.shared.image(resources.appendingPathComponent(i.resource)) }
            imageView.layer.contentsRect = i.crop.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            view.transform = CGAffineTransform(rotationAngle: i.rotation)
        case let .text(t):
            (view as? TextElementView)?.element = t
            view.transform = CGAffineTransform(rotationAngle: t.rotation)
        case let .tape(t):
            var c = t.color
            if t.revealed { c.a = 0.22 }
            view.backgroundColor = InkConverter.uiColor(c)
            view.layer.borderWidth = t.revealed ? 1 : 0
            view.layer.borderColor = InkConverter.uiColor(t.color).cgColor
            view.accessibilityValue = t.revealed ? L("tape.revealed") : L("tape.hidden")
        }
    }

    @objc private func tapeTapped(_ g: UITapGestureRecognizer) {
        guard let view = g.view, let id = views.first(where: { $0.value === view })?.key, let page = locations[id] else { return }
        onTapeTap?(page, id)
    }

    /// Les rubans ne captent que les touchers qui tombent sur eux ; le reste passe au canevas.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard kind == .tapes, tapesInteractive else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === canvas ? nil : hit
    }
}

/// Affiche une zone de texte ou une note, avec le même rendu que l'export.
final class TextElementView: UIView {
    var element: TextElement? { didSet { if element != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func draw(_ rect: CGRect) {
        guard let element, let ctx = UIGraphicsGetCurrentContext() else { return }
        var e = element
        e.rotation = 0
        e.frame = Rect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height))
        PageRenderer.drawElement(.text(e), pageRect: .zero, scale: 1, resources: URL(fileURLWithPath: "/"), context: ctx)
        accessibilityLabel = element.text
    }
}

/// Cadre de sélection d'un élément : déplacer, redimensionner, faire pivoter.
/// Placé au-dessus du canevas ; ne capte que les touchers sur la sélection et ses poignées.
final class SelectionOverlayView: UIView {
    /// Cadre de l'élément à l'écran, avant rotation.
    var box: CGRect = .zero { didSet { setNeedsLayout() } }
    var rotation: CGFloat = 0 { didSet { setNeedsLayout() } }
    var keepsAspect = false
    var isActive: Bool { !box.isEmpty }

    var onMove: ((CGPoint) -> Void)?
    var onResize: ((CGSize) -> Void)?
    var onRotate: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    private let frameLayer = CAShapeLayer()
    private let resizeHandle = UIView()
    private let rotateHandle = UIView()
    private var startBox: CGRect = .zero
    private var startRotation: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        frameLayer.fillColor = UIColor.clear.cgColor
        frameLayer.strokeColor = Theme.accent.cgColor
        frameLayer.lineWidth = 1.5
        frameLayer.lineDashPattern = [6, 4]
        layer.addSublayer(frameLayer)
        for (handle, symbol) in [(resizeHandle, "arrow.up.left.and.arrow.down.right"), (rotateHandle, "arrow.clockwise")] {
            handle.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            handle.backgroundColor = Theme.accent
            handle.layer.cornerRadius = 15
            handle.layer.borderWidth = 2
            handle.layer.borderColor = UIColor.white.cgColor
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
            icon.tintColor = .white
            icon.frame = handle.bounds.insetBy(dx: 7, dy: 7)
            icon.contentMode = .scaleAspectFit
            handle.addSubview(icon)
            addSubview(handle)
        }
        resizeHandle.accessibilityLabel = L("selection.resize")
        rotateHandle.accessibilityLabel = L("selection.rotate")
        resizeHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
        rotateHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(rotate(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(move(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private func rotated(_ p: CGPoint) -> CGPoint {
        let c = CGPoint(x: box.midX, y: box.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(rotation) - dy * sin(rotation), y: c.y + dx * sin(rotation) + dy * cos(rotation))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        isHidden = box.isEmpty
        let path = UIBezierPath(rect: box.insetBy(dx: -4, dy: -4))
        path.apply(CGAffineTransform(translationX: -box.midX, y: -box.midY).concatenating(CGAffineTransform(rotationAngle: rotation)).concatenating(CGAffineTransform(translationX: box.midX, y: box.midY)))
        frameLayer.path = path.cgPath
        resizeHandle.center = rotated(CGPoint(x: box.maxX + 4, y: box.maxY + 4))
        rotateHandle.center = rotated(CGPoint(x: box.midX, y: box.minY - 30))
    }

    private func containsInBox(_ point: CGPoint) -> Bool {
        let c = CGPoint(x: box.midX, y: box.midY)
        let dx = point.x - c.x, dy = point.y - c.y
        let local = CGPoint(x: c.x + dx * cos(-rotation) - dy * sin(-rotation), y: c.y + dx * sin(-rotation) + dy * cos(-rotation))
        return box.insetBy(dx: -8, dy: -8).contains(local)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isActive else { return nil }
        for handle in [resizeHandle, rotateHandle] where handle.frame.insetBy(dx: -10, dy: -10).contains(point) { return handle }
        return containsInBox(point) ? self : nil
    }

    @objc private func move(_ g: UIPanGestureRecognizer) {
        if g.state == .changed {
            onMove?(g.translation(in: self))
            g.setTranslation(.zero, in: self)
        } else if g.state == .ended || g.state == .cancelled {
            onEnd?()
        }
    }

    @objc private func resize(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            startBox = box
        case .changed:
            let t = g.translation(in: self)
            // Déplacement exprimé dans le repère de l'élément.
            let dx = t.x * cos(-rotation) - t.y * sin(-rotation)
            let dy = t.x * sin(-rotation) + t.y * cos(-rotation)
            var w = max(24, startBox.width + dx)
            var h = max(24, startBox.height + dy)
            if keepsAspect, startBox.width > 0 {
                let k = max(w / startBox.width, h / startBox.height)
                w = startBox.width * k
                h = startBox.height * k
            }
            onResize?(CGSize(width: w, height: h))
        case .ended, .cancelled:
            onEnd?()
        default:
            break
        }
    }

    @objc private func rotate(_ g: UIPanGestureRecognizer) {
        let c = CGPoint(x: box.midX, y: box.midY)
        let p = g.location(in: self)
        let angle = atan2(p.y - c.y, p.x - c.x) + .pi / 2
        switch g.state {
        case .began:
            startRotation = rotation
        case .changed:
            // Aimantation aux multiples de 15°.
            let step = CGFloat.pi / 12
            let snapped = (angle / step).rounded() * step
            onRotate?(abs(snapped - angle) < 0.05 ? snapped : angle)
        case .ended, .cancelled:
            onEnd?()
        default:
            break
        }
    }
}

/// Dessins éphémères : aperçu des formes et pointeur laser.
final class SketchOverlayView: UIView {
    private let preview = CAShapeLayer()
    private var laserLayers: [CAShapeLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        preview.fillColor = UIColor.clear.cgColor
        preview.lineCap = .round
        preview.lineJoin = .round
        layer.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func showPreview(_ path: CGPath?, color: UIColor, width: CGFloat, dashed: Bool = false) {
        preview.path = path
        preview.strokeColor = color.cgColor
        preview.lineWidth = width
        preview.lineDashPattern = dashed ? [6, 4] : nil
        preview.fillColor = UIColor.clear.cgColor
    }

    func showFill(_ path: CGPath?, color: UIColor) {
        preview.path = path
        preview.fillColor = color.cgColor
        preview.strokeColor = UIColor.clear.cgColor
    }

    /// Trace du pointeur laser, qui s'efface d'elle-même.
    func laser(_ path: CGPath) {
        let glow = CAShapeLayer()
        glow.path = path
        glow.strokeColor = UIColor.systemRed.cgColor
        glow.fillColor = UIColor.clear.cgColor
        glow.lineWidth = 4
        glow.lineCap = .round
        glow.lineJoin = .round
        glow.shadowColor = UIColor.systemRed.cgColor
        glow.shadowOpacity = 0.9
        glow.shadowRadius = 6
        glow.shadowOffset = .zero
        layer.addSublayer(glow)
        laserLayers.append(glow)
        if laserLayers.count > 40 { laserLayers.removeFirst().removeFromSuperlayer() }
    }

    func fadeLaser() {
        let layers = laserLayers
        laserLayers.removeAll()
        CATransaction.begin()
        CATransaction.setCompletionBlock { layers.forEach { $0.removeFromSuperlayer() } }
        for l in layers {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.9
            fade.beginTime = CACurrentMediaTime() + 0.6
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            l.add(fade, forKey: "fade")
        }
        CATransaction.commit()
    }
}
