import SwiftUI
import UIKit

struct ExternalPackageShareSheet: UIViewControllerRepresentable {
    let package: VerifiedPackage
    let onCompletion: (String?, Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [package.localURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, completed, _, error in
            let destination = activityType?.rawValue
            Task { @MainActor in onCompletion(destination, completed, error) }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
