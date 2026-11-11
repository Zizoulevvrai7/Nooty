import NootyCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Délégués des sélecteurs du système, conservés par l'éditeur pendant leur présentation.
final class PhotoPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    private let done: ([UIImage]) -> Void

    init(done: @escaping ([UIImage]) -> Void) {
        self.done = done
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let group = DispatchGroup()
        var images = [UIImage?](repeating: nil, count: results.count)
        for (i, r) in results.enumerated() where r.itemProvider.canLoadObject(ofClass: UIImage.self) {
            group.enter()
            r.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async {
                    images[i] = image
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [done] in done(images.compactMap { $0 }) }
    }
}

final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let done: (UIImage?) -> Void

    init(done: @escaping (UIImage?) -> Void) {
        self.done = done
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        done(info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let done: ([URL]) -> Void

    init(done: @escaping ([URL]) -> Void) {
        self.done = done
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        done(urls)
    }
}

final class ScanDelegate: NSObject, VNDocumentCameraViewControllerDelegate {
    private let done: ([UIImage]) -> Void

    init(done: @escaping ([UIImage]) -> Void) {
        self.done = done
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
        controller.dismiss(animated: true) { [done] in done(images) }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true)
    }
}

/// Réglage fin de l'épaisseur d'un préréglage.
final class WidthSliderViewController: UIViewController {
    private let slider = UISlider()
    private let onChange: (Double) -> Void

    init(value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        preferredContentSize = CGSize(width: 300, height: 90)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.panel
        let label = UILabel()
        label.text = L("width.adjust")
        label.font = .preferredFont(forTextStyle: .headline)
        slider.accessibilityLabel = L("width.adjust")
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onChange(Double(self.slider.value))
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [label, slider])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

/// Recadrage d'une image : un cadre à déplacer et à redimensionner par ses coins.
final class ImageCropViewController: UIViewController {
    private let image: UIImage
    private var crop: CGRect
    private let done: (Rect) -> Void
    private let imageView = UIImageView()
    private let cropLayer = CAShapeLayer()
    private let shade = CAShapeLayer()
    private var startCrop: CGRect = .zero
    private var dragMode = 0

    init(image: UIImage, crop: NootyCore.Rect?, done: @escaping (Rect) -> Void) {
        self.image = image
        self.crop = crop.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = L("element.crop")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                let c = self.crop.standardized
                self.done(Rect(x: Double(c.minX), y: Double(c.minY), width: Double(c.width), height: Double(c.height)))
                self.dismiss(animated: true)
            }),
            UIBarButtonItem(title: L("crop.reset"), primaryAction: UIAction { [weak self] _ in
                self?.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                self?.redraw()
            }),
        ]
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        view.addSubview(imageView)
        shade.fillRule = .evenOdd
        shade.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        cropLayer.strokeColor = UIColor.white.cgColor
        cropLayer.fillColor = UIColor.clear.cgColor
        cropLayer.lineWidth = 2
        imageView.layer.addSublayer(shade)
        imageView.layer.addSublayer(cropLayer)
        imageView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        imageView.frame = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 24, dy: 24)
        redraw()
    }

    private var imageRect: CGRect { AVMakeRectFit(image.size, in: imageView.bounds) }

    private func viewRect(_ c: CGRect) -> CGRect {
        let r = imageRect
        return CGRect(x: r.minX + c.minX * r.width, y: r.minY + c.minY * r.height, width: c.width * r.width, height: c.height * r.height)
    }

    private func redraw() {
        let v = viewRect(crop)
        cropLayer.path = UIBezierPath(rect: v).cgPath
        let path = UIBezierPath(rect: imageRect)
        path.append(UIBezierPath(rect: v))
        shade.path = path.cgPath
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return }
        switch g.state {
        case .began:
            startCrop = crop
            let p = g.location(in: imageView)
            let v = viewRect(crop)
            let near: (CGPoint) -> Bool = { hypot($0.x - p.x, $0.y - p.y) < 44 }
            if near(CGPoint(x: v.minX, y: v.minY)) { dragMode = 1 }
            else if near(CGPoint(x: v.maxX, y: v.minY)) { dragMode = 2 }
            else if near(CGPoint(x: v.minX, y: v.maxY)) { dragMode = 3 }
            else if near(CGPoint(x: v.maxX, y: v.maxY)) { dragMode = 4 }
            else { dragMode = v.contains(p) ? 5 : 0 }
        case .changed:
            let t = g.translation(in: imageView)
            let dx = t.x / r.width, dy = t.y / r.height
            var c = startCrop
            switch dragMode {
            case 1: c = CGRect(x: c.minX + dx, y: c.minY + dy, width: c.width - dx, height: c.height - dy)
            case 2: c = CGRect(x: c.minX, y: c.minY + dy, width: c.width + dx, height: c.height - dy)
            case 3: c = CGRect(x: c.minX + dx, y: c.minY, width: c.width - dx, height: c.height + dy)
            case 4: c = CGRect(x: c.minX, y: c.minY, width: c.width + dx, height: c.height + dy)
            case 5: c = c.offsetBy(dx: dx, dy: dy)
            default: return
            }
            c.size.width = max(0.05, min(1, c.width))
            c.size.height = max(0.05, min(1, c.height))
            c.origin.x = max(0, min(1 - c.width, c.minX))
            c.origin.y = max(0, min(1 - c.height, c.minY))
            crop = c
            redraw()
        default:
            break
        }
    }
}

/// Éléments réutilisables : images enregistrées pour être réinsérées dans n'importe quel bloc-notes.
final class ElementCollection {
    static let shared = ElementCollection()

    private var folder: URL? {
        guard let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = docs.appendingPathComponent("Bibliotheque/elements", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func add(_ data: Data) {
        guard let folder, let image = UIImage(data: data), let png = image.pngData() else { return }
        try? png.write(to: folder.appendingPathComponent("\(UUID().uuidString).png"), options: .atomic)
    }

    func items() -> [URL] {
        guard let folder else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "png" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func thumbnail(_ url: URL) -> UIImage? {
        ImageCache.shared.image(url)?.preparingThumbnail(of: CGSize(width: 60, height: 60))
    }
}

/// Barre de mise en forme affichée au-dessus du clavier pendant l'édition d'une zone de texte.
final class TextFormatBar: UIToolbar {
    private weak var editor: NotebookViewController?

    init(editor: NotebookViewController) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 48))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private func item(_ symbol: String, _ label: String, on: Bool = false, _ action: @escaping () -> Void) -> UIBarButtonItem {
        let b = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak self] _ in
            action()
            self?.refresh()
        })
        b.accessibilityLabel = label
        b.tintColor = on ? Theme.accent : Theme.text
        return b
    }

    func refresh() {
        guard let editor, let t = editor.editingTextElement() else { return }
        let align = UIMenu(title: L("text.alignment"), options: .singleSelection, children: [
            (TextAlignment.left, "text.alignleft"), (.center, "text.aligncenter"), (.right, "text.alignright"),
        ].map { a, symbol in
            UIAction(title: L("align.\(a.rawValue)"), image: UIImage(systemName: symbol), state: a == t.alignment ? .on : .off) { [weak self] _ in
                self?.editor?.changeEditingText { $0.alignment = a }
                self?.refresh()
            }
        })
        let palette = ["#111111", "#1D2A44", "#C62828", "#2E7D32", "#1565C0", "#C2500F", "#7A4FB5"]
        let colors = UIMenu(title: L("text.color"), children: palette.compactMap { hex in
            guard let c = RGBA(hex: hex) else { return nil }
            return UIAction(title: ColorNames.name(InkConverter.uiColor(c)), image: Self.dot(InkConverter.uiColor(c)), state: c == t.color ? .on : .off) { [weak self] _ in
                self?.editor?.changeEditingText { $0.color = c }
                self?.refresh()
            }
        })
        let fills = UIMenu(title: L("text.fill"), children: [nil, "#FFE98A", "#BDE7C4", "#BFDCF7", "#F7C6DB", "#FFD6A5"].map { hex in
            let c = hex.flatMap(RGBA.init(hex:))
            return UIAction(title: c.map { ColorNames.name(InkConverter.uiColor($0)) } ?? L("text.noFill"), image: c.map { Self.dot(InkConverter.uiColor($0)) }, state: c == t.fill ? .on : .off) { [weak self] _ in
                self?.editor?.changeEditingText { $0.fill = c }
                self?.refresh()
            }
        })
        let fontItem = UIBarButtonItem(title: t.font.displayName)
        fontItem.primaryAction = UIAction(title: t.font.displayName) { [weak self, weak fontItem] _ in
            guard let self, let editor = self.editor else { return }
            let menu = SheetMenuController(title: L("text.font"), width: 340) { [weak editor] _ in
                FontFamily.Group.allCases.compactMap { group -> SheetMenuController.Section? in
                    let fonts = FontFamily.available.filter { $0.group == group }
                    guard !fonts.isEmpty else { return nil }
                    return SheetMenuController.Section(group.title, fonts.map { family -> SheetMenuController.Item in
                        .row(SheetMenuController.Row(family.displayName, accessory: .check(family == t.font), font: family.font(size: 19)) { [weak editor] in
                            editor?.chooseFont(family)
                        })
                    })
                }
            }
            SheetMenuController.present(menu, from: editor, item: fontItem)
        }
        fontItem.accessibilityLabel = L("text.font")
        items = [
            fontItem,
            item("textformat.size.smaller", L("text.smaller")) { [weak self] in self?.editor?.changeEditingText { $0.fontSize = max(6, $0.fontSize - 2) } },
            item("textformat.size.larger", L("text.larger")) { [weak self] in self?.editor?.changeEditingText { $0.fontSize = min(200, $0.fontSize + 2) } },
            item("bold", L("text.bold"), on: t.bold) { [weak self] in self?.editor?.changeEditingText { $0.bold.toggle() } },
            item("italic", L("text.italic"), on: t.italic) { [weak self] in self?.editor?.changeEditingText { $0.italic.toggle() } },
            item("underline", L("text.underline"), on: t.underline) { [weak self] in self?.editor?.changeEditingText { $0.underline.toggle() } },
            UIBarButtonItem(image: UIImage(systemName: "text.alignleft"), menu: align),
            UIBarButtonItem(image: UIImage(systemName: "paintpalette"), menu: colors),
            UIBarButtonItem(image: UIImage(systemName: "note.text"), menu: fills),
            .flexibleSpace(),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.editor?.commitTextEditing() }),
        ]
    }

    static func dot(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 18, height: 18)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}
