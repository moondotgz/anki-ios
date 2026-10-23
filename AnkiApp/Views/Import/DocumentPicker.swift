import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system file picker in copy mode. iOS copies the chosen file into the
/// app's container before handing it over, which works with every file
/// provider (iCloud Drive files not yet downloaded, third-party providers)
/// and needs no security-scoped access. SwiftUI's `fileImporter` hands back
/// security-scoped URLs that some providers refuse.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    static let contentTypes: [UTType] = {
        var types: [UTType] = [.zip, .data, .item]
        for ext in ["apkg", "colpkg"] {
            if let t = UTType(filenameExtension: ext) { types.insert(t, at: 0) }
        }
        return types
    }()

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: DocumentPicker.contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
