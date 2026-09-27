import SwiftUI
import UIKit

@MainActor
final class DreyzeStoreAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DownloadManager.shared.restorePendingDownloads()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.shared.setBackgroundEventsCompletionHandler(identifier: identifier) {
            completionHandler()
        }
        DownloadManager.shared.restorePendingDownloads()
    }
}

@main
struct DreyzeStoreApp: App {
    @UIApplicationDelegateAdaptor(DreyzeStoreAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
