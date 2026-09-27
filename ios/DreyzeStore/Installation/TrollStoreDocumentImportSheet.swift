import SwiftUI
import UIKit

struct TrollStoreDocumentImportSheet: UIViewControllerRepresentable {
    let package: VerifiedPackage
    let onCompletion: (String?, Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> TrollStoreDocumentImportController {
        let controller = TrollStoreDocumentImportController(packageURL: package.localURL)
        controller.onCompletion = onCompletion
        return controller
    }

    func updateUIViewController(_ controller: TrollStoreDocumentImportController, context: Context) {
        controller.onCompletion = onCompletion
    }
}

/// Presents Apple's document Open In menu for an already revalidated IPA.
/// TrollStore registers `com.apple.itunes.ipa` and consumes the security-scoped
/// document URL in its scene delegate, where it shows its own install prompt.
@MainActor
final class TrollStoreDocumentImportController: UIViewController, UIDocumentInteractionControllerDelegate {
    private let packageURL: URL
    private var documentController: UIDocumentInteractionController?
    private var didAttemptPresentation = false
    private var didFinish = false
    private var isSendingDocument = false
    var onCompletion: ((String?, Bool, Error?) -> Void)?

    init(packageURL: URL) {
        self.packageURL = packageURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAttemptPresentation else { return }
        didAttemptPresentation = true

        guard packageURL.isFileURL,
              packageURL.pathExtension.lowercased() == "ipa",
              FileManager.default.isReadableFile(atPath: packageURL.path) else {
            finish(destination: nil, completed: false, error: TrollStoreImportError.invalidPackageURL)
            return
        }

        let interaction = UIDocumentInteractionController(url: packageURL)
        interaction.uti = TrollStoreImportTarget.ipaContentTypeIdentifier
        interaction.delegate = self
        documentController = interaction
        let anchor = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        guard interaction.presentOpenInMenu(from: anchor, in: view, animated: true) else {
            finish(destination: nil, completed: false, error: TrollStoreImportError.noCompatibleIPAHandler)
            return
        }
    }

    func documentInteractionController(
        _ controller: UIDocumentInteractionController,
        willBeginSendingToApplication application: String?
    ) {
        isSendingDocument = true
    }

    func documentInteractionController(
        _ controller: UIDocumentInteractionController,
        didEndSendingToApplication application: String?
    ) {
        finish(destination: application, completed: true, error: nil)
    }

    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        // Selecting an app dismisses the menu before iOS reports that sending
        // the document finished. Do not race that completion into cancellation.
        guard !isSendingDocument else { return }
        finish(destination: nil, completed: false, error: nil)
    }

    private func finish(destination: String?, completed: Bool, error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        onCompletion?(destination, completed, error)
        documentController?.delegate = nil
        documentController = nil
    }
}

private enum TrollStoreImportError: LocalizedError {
    case invalidPackageURL
    case noCompatibleIPAHandler

    var errorDescription: String? {
        switch self {
        case .invalidPackageURL:
            "The verified IPA is no longer available in DreyzeStore's package storage."
        case .noCompatibleIPAHandler:
            "No installed app can open IPA documents. Install TrollStore on a supported device, then try again."
        }
    }
}
