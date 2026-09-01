import SwiftUI
import UIKit

/// DEBUG-only share sheet for capture export (AirDrop / Files / Mac).
struct CaptureExportShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
