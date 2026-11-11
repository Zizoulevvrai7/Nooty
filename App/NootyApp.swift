import SwiftUI
import UIKit

@main
struct NootyApp: App {
    var body: some Scene {
        WindowGroup {
            RootContainer()
                .ignoresSafeArea()
        }
    }
}

/// L'interface est écrite en UIKit : PencilKit, le zoom et les grilles y sont plus prévisibles.
struct RootContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let root: UIViewController
        do {
            let store = LibraryStore(root: try LibraryStore.defaultRoot())
            store.importPrototypePageIfNeeded()
            root = LibraryViewController(store: store, folderID: nil)
        } catch {
            root = StorageErrorViewController(message: error.localizedDescription)
        }
        let nav = UINavigationController(rootViewController: root)
        DispatchQueue.main.async { AppearanceSettings.apply() }
        nav.navigationBar.prefersLargeTitles = true
        nav.navigationBar.tintColor = Theme.accent
        nav.view.tintColor = Theme.accent
        return nav
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

/// Affiché si le dossier de stockage de l'application est inaccessible.
final class StorageErrorViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.desk
        title = L("app.name")
        let label = UILabel()
        label.text = L("storage.unavailable", message)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = Theme.text
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }
}
