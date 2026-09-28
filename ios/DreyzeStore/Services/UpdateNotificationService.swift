import Foundation
import UserNotifications

@MainActor
final class UpdateNotificationService {
    static let shared = UpdateNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let fingerprintKey = "dreyze.notifications.last-update-fingerprint.v1"
    private let updateRequestID = "dreyzestore-updates-available"
    private let expirationPrefix = "dreyzestore-signing-expiration-"

    private init() { }

    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func permissionIsGranted() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func synchronize(
        updates: [UpdateAvailable],
        installed: [InstalledAppRecord],
        names: [String: String],
        warningDays: Int,
        enabled: Bool
    ) async {
        guard enabled, await permissionIsGranted() else {
            removeManagedRequests()
            return
        }

        let fingerprint = updates
            .map { "\($0.app.bundleIdentifier.lowercased()):\($0.latestVersion.version):\($0.latestVersion.build)" }
            .sorted().joined(separator: "|")
        if updates.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: [updateRequestID])
            UserDefaults.standard.removeObject(forKey: fingerprintKey)
        } else if fingerprint != UserDefaults.standard.string(forKey: fingerprintKey) {
            let content = UNMutableNotificationContent()
            content.title = "Updates are ready to review"
            content.body = "\(updates.count) apps have newer published releases. Open DreyzeStore to check the current catalog."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: updateRequestID,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60 * 60, repeats: false)
            )
            try? await center.add(request)
            UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
        }

        let managedIDs = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(expirationPrefix) }
        let freshRecords = installed.filter {
            guard let expiration = $0.provisionExpiration else { return false }
            return expiration > Date() && expiration.timeIntervalSinceNow <= TimeInterval(warningDays * 24 * 60 * 60)
        }
        let desiredIDs = Set(freshRecords.map { expirationPrefix + Self.stableID($0.canonicalBundleIdentifier) })
        center.removePendingNotificationRequests(withIdentifiers: managedIDs.filter { !desiredIDs.contains($0) })
        for record in freshRecords {
            guard let expiration = record.provisionExpiration else { continue }
            let identifier = expirationPrefix + Self.stableID(record.canonicalBundleIdentifier)
            let content = UNMutableNotificationContent()
            content.title = "Signing expires soon"
            content.body = "Signing for \(names[record.canonicalBundleIdentifier] ?? record.canonicalBundleIdentifier) expires on \(expiration.formatted(date: .abbreviated, time: .omitted)). Refresh it with Windows Companion."
            content.sound = .default
            let interval = max(60, expiration.addingTimeInterval(-TimeInterval(warningDays * 24 * 60 * 60)).timeIntervalSinceNow)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
            try? await center.add(request)
        }
    }

    private func removeManagedRequests() {
        center.getPendingNotificationRequests { [updateRequestID, expirationPrefix] requests in
            let identifiers = requests.map(\.identifier).filter { $0 == updateRequestID || $0.hasPrefix(expirationPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    private static func stableID(_ value: String) -> String {
        value.unicodeScalars.reduce(into: UInt64(14695981039346656037)) { hash, scalar in
            hash ^= UInt64(scalar.value)
            hash &*= 1099511628211
        }.description
    }
}
