import NootyCore
import PDFKit
import UIKit

/// Transformation de fichiers importés en pages de bloc-notes.
enum Importers {
    static let maxPDFBytes = 500 * 1024 * 1024

    /// Copie le PDF dans les ressources et décrit une page par page de PDF, avec ses dimensions et sa rotation.
    static func pdfPages(from data: Data, into dir: URL) throws -> [PageInfo] {
        guard data.count <= maxPDFBytes else { throw ImportError.tooLarge }
        guard let document = PDFDocument(data: data) else { throw ImportError.unreadablePDF }
        if document.isLocked { throw ImportError.protectedPDF }
        guard document.pageCount > 0, document.pageCount <= NotebookManifest.maxPages else { throw ImportError.unreadablePDF }
        let name = try NotebookStore.addResource(data, ext: "pdf", in: dir)
        return (0..<document.pageCount).compactMap { i in
            guard let page = document.page(at: i) else { return nil }
            let size = PageRenderer.displayedSize(of: page)
            return PageInfo(
                width: min(20_000, max(10, Double(size.width))), height: min(20_000, max(10, Double(size.height))),
                background: Background.standard(.blank), backdrop: .pdf(resource: name, pageIndex: i)
            )
        }
    }

    /// Une page par image (scan, photos), au format A4 dans le sens de l'image.
    static func imagePages(_ images: [UIImage], into dir: URL) throws -> [PageInfo] {
        try images.map { image in
            guard let data = image.jpegData(compressionQuality: 0.85) else { throw ImportError.unreadableImage }
            let name = try NotebookStore.addResource(data, ext: "jpg", in: dir)
            let landscape = image.size.width > image.size.height
            let dims = PaperSize.a4.size(landscape: landscape)
            return PageInfo(width: dims.width, height: dims.height, background: .standard(.blank, paper: .white), backdrop: .image(resource: name))
        }
    }

    /// Texte natif de chaque page d'un PDF, pour la recherche.
    static func pdfText(_ url: URL, pageIndex: Int) -> String {
        PDFCache.shared.document(url)?.page(at: pageIndex)?.string ?? ""
    }
}

enum ImportError: LocalizedError {
    case tooLarge, unreadablePDF, protectedPDF, unreadableImage, unsupported

    var errorDescription: String? {
        switch self {
        case .tooLarge: return L("import.tooLarge")
        case .unreadablePDF: return L("import.unreadablePDF")
        case .protectedPDF: return L("import.protectedPDF")
        case .unreadableImage: return L("import.unreadableImage")
        case .unsupported: return L("import.unsupported")
        }
    }
}
