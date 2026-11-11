import NootyCore
import PDFKit
import PencilKit
import UIKit

/// Cache borné des documents PDF ouverts et des pages rendues en image.
final class PDFCache {
    static let shared = PDFCache()

    private var documents: [URL: PDFDocument] = [:]
    private var order: [URL] = []
    private let images = NSCache<NSString, UIImage>()

    private init() {
        images.totalCostLimit = 160 * 1024 * 1024
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.images.removeAllObjects()
            self?.documents.removeAll()
            self?.order.removeAll()
        }
    }

    func document(_ url: URL) -> PDFDocument? {
        if let d = documents[url] { return d }
        guard let d = PDFDocument(url: url) else { return nil }
        documents[url] = d
        order.append(url)
        if order.count > 6 { documents[order.removeFirst()] = nil }
        return d
    }

    /// Image d'une page de PDF à une largeur en pixels arrondie (paliers), mise en cache.
    func image(_ url: URL, pageIndex: Int, pixelWidth: CGFloat) -> UIImage? {
        let bucket = min(4096, max(256, pow(2, ceil(log2(max(1, pixelWidth))))))
        let key = "\(url.lastPathComponent)#\(pageIndex)@\(Int(bucket))" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let page = document(url)?.page(at: pageIndex) else { return nil }
        let bounds = PageRenderer.displayedSize(of: page)
        let size = CGSize(width: bucket, height: (bucket * bounds.height / bounds.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            PageRenderer.drawPDFPage(page, in: CGRect(origin: .zero, size: size), context: context.cgContext)
        }
        images.setObject(image, forKey: key, cost: Int(size.width * size.height * 4))
        return image
    }
}

/// Dessin complet d'une page : papier, fond importé, éléments et encre.
/// Sert aux miniatures, à l'export PDF et image, à l'impression et à la reconnaissance d'écriture.
enum PageRenderer {
    struct Options {
        var paper = true
        var ink = true
        var elements = true
        /// Résolution de l'encre rastérisée, en pixels par point de page.
        var inkScale: CGFloat = 2
    }

    static func displayedSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let quarter = ((page.rotation % 360) + 360) % 360
        return quarter == 90 || quarter == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Dessine une page de PDF dans le rectangle donné (repère UIKit, origine en haut à gauche).
    static func drawPDFPage(_ page: PDFPage, in rect: CGRect, context ctx: CGContext) {
        let size = displayedSize(of: page)
        guard size.width > 0, size.height > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / size.width, y: -rect.height / size.height)
        page.transform(ctx, for: .cropBox)
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
    }

    static func drawBackdrop(_ backdrop: Backdrop, resources: URL, in rect: CGRect, context ctx: CGContext, pixelWidth: CGFloat? = nil) {
        let url = resources.appendingPathComponent(backdrop.resource)
        switch backdrop {
        case let .pdf(_, index):
            if let pixelWidth, let image = PDFCache.shared.image(url, pageIndex: index, pixelWidth: pixelWidth) {
                image.draw(in: rect)
            } else if let page = PDFCache.shared.document(url)?.page(at: index) {
                drawPDFPage(page, in: rect, context: ctx)
            }
        case .image:
            guard let image = ImageCache.shared.image(url) else { return }
            let fit = AVMakeRectFit(image.size, in: rect)
            image.draw(in: fit)
        }
    }

    static func font(for t: TextElement, scale: CGFloat = 1) -> UIFont {
        t.font.font(size: CGFloat(t.fontSize) * scale, bold: t.bold, italic: t.italic)
    }

    static func attributed(_ t: TextElement, scale: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(string: t.text, attributes: attributes(t, scale: scale))
    }

    static func attributes(_ t: TextElement, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        switch t.alignment {
        case .left: paragraph.alignment = .natural
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: t, scale: scale),
            .foregroundColor: InkConverter.uiColor(t.color),
            .paragraphStyle: paragraph,
        ]
        if t.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    static let textInset: CGFloat = 6

    /// Dessine un élément dans un rectangle de page `pageRect` (échelle `s` points de page → contexte).
    static func drawElement(_ element: PageElement, pageRect: CGRect, scale s: CGFloat, resources: URL, context ctx: CGContext) {
        let f = element.frame
        let rect = CGRect(x: pageRect.minX + f.x * s, y: pageRect.minY + f.y * s, width: f.width * s, height: f.height * s)
        ctx.saveGState()
        func rotate(_ angle: Double) {
            guard angle != 0 else { return }
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: angle)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        switch element {
        case let .image(i):
            rotate(i.rotation)
            if let image = ImageCache.shared.image(resources.appendingPathComponent(i.resource)) {
                if let crop = i.crop, let cg = image.cgImage {
                    let px = CGRect(x: crop.x * Double(cg.width), y: crop.y * Double(cg.height), width: crop.width * Double(cg.width), height: crop.height * Double(cg.height))
                    if let part = cg.cropping(to: px.integral) {
                        UIImage(cgImage: part, scale: 1, orientation: image.imageOrientation).draw(in: rect)
                    }
                } else {
                    image.draw(in: rect)
                }
            }
        case let .text(t):
            rotate(t.rotation)
            if let fill = t.fill {
                ctx.setFillColor(InkConverter.uiColor(fill).cgColor)
                ctx.setShadow(offset: CGSize(width: 0, height: 1.5 * s), blur: 4 * s, color: UIColor.black.withAlphaComponent(0.2).cgColor)
                ctx.fill(rect)
                ctx.setShadow(offset: .zero, blur: 0)
            }
            UIGraphicsPushContext(ctx)
            attributed(t, scale: s).draw(with: rect.insetBy(dx: textInset * s, dy: textInset * s), options: [.usesLineFragmentOrigin], context: nil)
            UIGraphicsPopContext()
        case let .tape(t):
            var c = t.color
            if t.revealed { c.a = 0.25 }
            ctx.setFillColor(InkConverter.uiColor(c).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 3 * s).cgPath)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Dessine toute la page. `strokes` sont en repère local de la page.
    static func draw(
        info: PageInfo, strokes: [Stroke], elements: [PageElement], resources: URL,
        in rect: CGRect, context ctx: CGContext, options: Options = Options()
    ) {
        let s = rect.width / CGFloat(info.width)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        if options.paper {
            ctx.setFillColor(InkConverter.uiColor(info.background.color).cgColor)
            ctx.fill(rect)
            PaperRenderer.draw(info.background, pageRect: rect, scale: s, clip: rect, in: ctx)
        }
        if let backdrop = info.backdrop {
            drawBackdrop(backdrop, resources: resources, in: rect, context: ctx)
        }
        if options.elements {
            for e in elements where !isTape(e) { drawElement(e, pageRect: rect, scale: s, resources: resources, context: ctx) }
        }
        if options.ink, !strokes.isEmpty {
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = InkConverter.drawing(strokes).image(from: CGRect(x: 0, y: 0, width: info.width, height: info.height), scale: options.inkScale * s)
            }
            image?.draw(in: rect)
        }
        if options.elements {
            for e in elements where isTape(e) { drawElement(e, pageRect: rect, scale: s, resources: resources, context: ctx) }
        }
    }

    static func isTape(_ e: PageElement) -> Bool {
        if case .tape = e { return true }
        return false
    }

    /// Image d'une page entière à une largeur donnée.
    static func image(info: PageInfo, strokes: [Stroke], elements: [PageElement], resources: URL, width: CGFloat, options: Options = Options()) -> UIImage {
        let size = CGSize(width: width, height: (width * CGFloat(info.height / info.width)).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw(info: info, strokes: strokes, elements: elements, resources: resources, in: CGRect(origin: .zero, size: size), context: context.cgContext, options: options)
        }
    }

    /// Document PDF des pages données (dimensions conservées, encre rastérisée en haute résolution).
    static func pdf(pages: [(info: PageInfo, strokes: [Stroke], elements: [PageElement])], resources: URL, options: Options = Options()) -> Data {
        let first = pages.first?.info
        let bounds = CGRect(x: 0, y: 0, width: first?.width ?? Page.a4Width, height: first?.height ?? Page.a4Height)
        var opts = options
        opts.inkScale = 3
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in pages {
                let rect = CGRect(x: 0, y: 0, width: page.info.width, height: page.info.height)
                context.beginPage(withBounds: rect, pageInfo: [:])
                draw(info: page.info, strokes: page.strokes, elements: page.elements, resources: resources, in: rect, context: context.cgContext, options: opts)
            }
        }
    }
}

/// Rectangle de taille `size` centré et contenu dans `rect`, proportions conservées.
func AVMakeRectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return rect }
    let k = min(rect.width / size.width, rect.height / size.height)
    let w = size.width * k, h = size.height * k
    return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

/// Cache des images de ressources, réduites à une taille raisonnable pour l'affichage.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func image(_ url: URL) -> UIImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key, cost: cg.width * cg.height * 4)
        return image
    }
}

/// Miniature de couverture d'un bloc-notes : la première page.
enum Thumbnailer {
    static func refresh(library: LibraryStore, id: UUID) {
        let dir = library.notebookDirectory(id)
        guard let data = try? Data(contentsOf: NotebookStore.manifestURL(dir)),
              let manifest = try? NotebookCodec.decode(data), let info = manifest.pages.first else { return }
        let page = NotebookStore.readPage(dir, info.id)
        let image = PageRenderer.image(info: info, strokes: page?.strokes ?? [], elements: page?.elements ?? [], resources: NotebookStore.resourcesURL(dir), width: 336)
        try? image.pngData()?.write(to: library.thumbnailURL(id), options: .atomic)
    }
}
