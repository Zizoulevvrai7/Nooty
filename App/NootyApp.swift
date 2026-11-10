import SwiftUI

@main
struct NootyApp: App {
    var body: some Scene {
        WindowGroup {
            EditorContainer()
                .ignoresSafeArea()
        }
    }
}

/// L'éditeur est écrit en UIKit : PencilKit, son sélecteur d'outils et le zoom y sont plus prévisibles.
struct EditorContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> EditorViewController {
        EditorViewController()
    }

    func updateUIViewController(_ controller: EditorViewController, context: Context) {}
}
