import Foundation
import Darwin

final class PackageStorage: @unchecked Sendable {
    static let shared = PackageStorage()

    private let fileManager: FileManager
    private let rootURL: URL
    private let temporaryDirectory: URL
    private let verifiedDirectory: URL
    private let lock = NSRecursiveLock()
    private let initializationError: Error?

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root: URL
        if let rootURL {
            root = rootURL.standardizedFileURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
            root = base.appendingPathComponent("DreyzeStore/Packages", isDirectory: true)
        }
        self.rootURL = root
        self.temporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)
        self.verifiedDirectory = root.appendingPathComponent("Verified", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: verifiedDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = root
            try? mutableRoot.setResourceValues(values)
            initializationError = nil
        } catch {
            initializationError = error
        }
    }

    func availableCapacity() -> Int64? {
        if let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        if let attributes = try? fileManager.attributesOfFileSystem(forPath: rootURL.path),
           let number = attributes[.systemFreeSize] as? NSNumber {
            return number.int64Value
        }
        return nil
    }

    func ensureCapacity(for expectedBytes: Int64) throws {
        try ensureDirectories()
        guard expectedBytes > 0, expectedBytes <= PackageLimits.maximumDownloadBytes else {
            throw PackageDownloadFailure(.sizeLimit)
        }
        if let available = availableCapacity(), available < expectedBytes + 20 * 1_024 * 1_024 {
            throw PackageDownloadFailure(.insufficientStorage)
        }
    }

    func temporaryURL(for id: UUID) -> URL {
        temporaryDirectory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("partial")
    }

    func intentURL(for id: UUID) -> URL {
        temporaryDirectory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("intent.json")
    }

    private func outcomeURL(for id: UUID) -> URL {
        temporaryDirectory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("outcome.json")
    }

    func save(intent: PackageDownloadIntent) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureCapacity(for: intent.release.size)
        let data = try JSONEncoder.packageStorage.encode(intent)
        try data.write(to: intentURL(for: intent.id), options: .atomic)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: intentURL(for: intent.id).path)
    }

    func pendingIntents() -> [PackageDownloadIntent] {
        lock.lock(); defer { lock.unlock() }
        guard (try? ensureDirectories()) != nil else { return [] }
        let files = (try? fileManager.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.lastPathComponent.hasSuffix(".intent.json"),
                  let data = try? Data(contentsOf: file),
                  let intent = try? JSONDecoder.packageStorage.decode(PackageDownloadIntent.self, from: data),
                  file.standardizedFileURL == intentURL(for: intent.id).standardizedFileURL else { return nil }
            return intent
        }
    }

    func intent(for id: UUID) -> PackageDownloadIntent? {
        lock.lock(); defer { lock.unlock() }
        guard (try? ensureDirectories()) != nil else { return nil }
        guard let data = try? Data(contentsOf: intentURL(for: id)) else { return nil }
        return try? JSONDecoder.packageStorage.decode(PackageDownloadIntent.self, from: data)
    }

    func consumeRedirectBudget(for id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var intent = intent(for: id), intent.redirectCount < PackageLimits.maximumRedirects else { return false }
        intent.redirectCount += 1
        guard let data = try? JSONEncoder.packageStorage.encode(intent), (try? data.write(to: intentURL(for: id), options: .atomic)) != nil else { return false }
        return true
    }

    func save(outcome: PackageTransferOutcome, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard (try? ensureDirectories()) != nil else { return }
        guard let data = try? JSONEncoder.packageStorage.encode(outcome),
              (try? data.write(to: outcomeURL(for: id), options: .atomic)) != nil else { return }
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: outcomeURL(for: id).path)
    }

    func outcome(for id: UUID) -> PackageTransferOutcome? {
        lock.lock(); defer { lock.unlock() }
        guard (try? ensureDirectories()) != nil else { return nil }
        guard let data = try? Data(contentsOf: outcomeURL(for: id)) else { return nil }
        return try? JSONDecoder.packageStorage.decode(PackageTransferOutcome.self, from: data)
    }

    func storeDownloadedTemporaryFile(from source: URL, transferID: UUID, maximumBytes: Int64) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectories()
        guard isRegularFile(source), let sourceSize = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PackageVerificationError.invalidArchive
        }
        let size = Int64(sourceSize)
        guard size > 0, size <= maximumBytes else { throw PackageDownloadFailure(.sizeLimit) }
        let destination = temporaryURL(for: transferID)
        if fileManager.fileExists(atPath: destination.path) {
            guard isRegularFile(destination) else { throw PackageVerificationError.unsafeArchive }
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        } catch {
            if Self.isInsufficientStorage(error) { throw PackageDownloadFailure(.insufficientStorage) }
            throw error
        }
        return size
    }

    func removeTemporaryFile(for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard (try? ensureDirectories()) != nil else { return }
        let file = temporaryURL(for: id)
        removeManagedFile(at: file)
    }

    func temporaryFileIsOwned(_ url: URL, transferID: UUID) -> Bool {
        let canonical = url.standardizedFileURL
        guard canonical == temporaryURL(for: transferID).standardizedFileURL,
              let values = try? canonical.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
        return true
    }

    func storeVerifiedPackage(from temporaryURL: URL, intent: PackageDownloadIntent, receipt: PackageValidationReceipt, verifiedAt: Date) throws -> (StoredVerifiedPackage, URL) {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectories()
        let release = intent.release
        guard temporaryFileIsOwned(temporaryURL, transferID: intent.id),
              receipt.transferID == intent.id,
              receipt.bundleIdentifier == release.bundleIdentifier,
              receipt.version == release.version,
              receipt.build == release.build,
              receipt.minimumOSVersion == release.minimumOSVersion,
              receipt.size == release.size else { throw PackageVerificationError.unsafeArchive }
        let id = intent.id.uuidString.lowercased()
        let destination = packageURL(for: id)
        guard !fileManager.fileExists(atPath: destination.path) else { throw PackageDownloadFailure(.unknown) }
        let package = StoredVerifiedPackage(
            id: id,
            appID: release.appID,
            name: release.name,
            developer: release.developer,
            bundleIdentifier: release.bundleIdentifier,
            version: release.version,
            build: release.build,
            minimumOSVersion: release.minimumOSVersion,
            sourceIdentifier: release.sourceIdentifier,
            sourceName: release.sourceName,
            iconURL: release.iconURL,
            size: receipt.size,
            sha256: receipt.sha256,
            verifiedAt: verifiedAt
        )
        try fileManager.moveItem(at: temporaryURL, to: destination)
        do {
            let metadataURL = recordURL(for: id)
            try JSONEncoder.packageStorage.encode(package).write(to: metadataURL, options: .atomic)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: metadataURL.path)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        removeTransferFilesLocked(intent.id, preservingPackage: true)
        return (package, destination)
    }

    func verifiedPackages() -> [StoredVerifiedPackage] {
        lock.lock(); defer { lock.unlock() }
        guard (try? ensureDirectories()) != nil else { return [] }
        let files = (try? fileManager.contentsOfDirectory(at: verifiedDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  file.standardizedFileURL == recordURL(for: id.uuidString.lowercased()).standardizedFileURL,
                  isRegularFile(file),
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder.packageStorage.decode(StoredVerifiedPackage.self, from: data),
                  record.id == id.uuidString.lowercased(),
                  isRegularFile(packageURL(for: record.id)),
                  fileSize(packageURL(for: record.id)) == record.size else { return nil }
            return record
        }.sorted { $0.verifiedAt > $1.verifiedAt }
    }

    @discardableResult
    func cleanOrphanedVerifiedPackages() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectories()
        let files = try fileManager.contentsOfDirectory(at: verifiedDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        var entries: [String: [String: URL]] = [:]
        for file in files {
            let ext = file.pathExtension.lowercased()
            let name = file.deletingPathExtension().lastPathComponent
            guard ext == "ipa" || ext == "json",
                  let uuid = UUID(uuidString: name), name == uuid.uuidString.lowercased() else { continue }
            entries[name, default: [:]][ext] = file
        }
        var removedBytes: Int64 = 0
        for (id, pair) in entries {
            guard let packageURL = pair["ipa"], let metadataURL = pair["json"],
                  isRegularFile(packageURL), isRegularFile(metadataURL),
                  let data = try? Data(contentsOf: metadataURL),
                  let record = try? JSONDecoder.packageStorage.decode(StoredVerifiedPackage.self, from: data),
                  record.id == id, fileSize(packageURL) == record.size else {
                for file in pair.values where isRegularFile(file) || isSymbolicLink(file) {
                    removedBytes += max(0, fileSize(file))
                    try fileManager.removeItem(at: file)
                }
                continue
            }
        }
        return removedBytes
    }

    func packageURL(for record: StoredVerifiedPackage) -> URL? {
        guard let id = UUID(uuidString: record.id), record.id == id.uuidString.lowercased() else { return nil }
        let url = packageURL(for: record.id)
        guard url.standardizedFileURL.deletingLastPathComponent() == verifiedDirectory.standardizedFileURL,
              isRegularFile(url), fileSize(url) == record.size else { return nil }
        return url
    }

    func storedPackage(matching package: VerifiedPackage) -> StoredVerifiedPackage? {
        lock.lock(); defer { lock.unlock() }
        guard let id = UUID(uuidString: package.localURL.deletingPathExtension().lastPathComponent),
              id.uuidString.lowercased() == package.localURL.deletingPathExtension().lastPathComponent,
              package.localURL.isFileURL,
              package.localURL.standardizedFileURL == packageURL(for: id.uuidString.lowercased()).standardizedFileURL,
              isRegularFile(package.localURL),
              isRegularFile(recordURL(for: id.uuidString.lowercased())),
              let data = try? Data(contentsOf: recordURL(for: id.uuidString.lowercased())) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(StoredVerifiedPackage.self, from: data),
              record.id == id.uuidString.lowercased(),
              record.bundleIdentifier == package.bundleIdentifier,
              record.version == package.version,
              record.build == package.build,
              record.minimumOSVersion == package.minimumOSVersion,
              record.size == package.size,
              record.sha256.caseInsensitiveCompare(package.sha256) == .orderedSame,
              record.sourceIdentifier == package.sourceIdentifier,
              record.sourceName == package.sourceName,
              packageURL(for: record)?.standardizedFileURL == package.localURL.standardizedFileURL else { return nil }
        return record
    }

    func deleteVerifiedPackage(id: String) throws {
        guard let uuid = UUID(uuidString: id), id == uuid.uuidString.lowercased() else { return }
        lock.lock(); defer { lock.unlock() }
        try ensureDirectories()
        for file in [packageURL(for: id), recordURL(for: id)] where fileManager.fileExists(atPath: file.path) {
            guard isRegularFile(file) || isSymbolicLink(file) else { continue }
            try fileManager.removeItem(at: file)
        }
    }

    func deleteAllVerifiedPackages() throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectories()
        let files = try fileManager.contentsOfDirectory(at: verifiedDirectory, includingPropertiesForKeys: nil)
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "ipa" || file.pathExtension == "json",
                  let id = UUID(uuidString: name), name == id.uuidString.lowercased() else { continue }
            guard isRegularFile(file) || isSymbolicLink(file) else { continue }
            try fileManager.removeItem(at: file)
        }
    }

    @discardableResult
    func cleanTemporaryFiles(preserving activeIDs: Set<UUID>, olderThan date: Date = Date().addingTimeInterval(-24 * 60 * 60)) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectories()
        let files = try fileManager.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        var removedBytes: Int64 = 0
        for file in files {
            let base = file.deletingPathExtension().deletingPathExtension().lastPathComponent
            let isActive = UUID(uuidString: base).map(activeIDs.contains) ?? false
            guard !isActive else { continue }
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard let modified = values?.contentModificationDate, modified < date else { continue }
            if values?.isRegularFile == true, values?.isSymbolicLink != true {
                removedBytes += Int64(values?.fileSize ?? 0)
            } else if values?.isSymbolicLink == true {
                removedBytes += max(0, fileSize(file))
            } else {
                continue
            }
            removeManagedFile(at: file)
        }
        return removedBytes
    }

    func removeTransferFiles(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard (try? ensureDirectories()) != nil else { return }
        removeTransferFilesLocked(id, preservingPackage: false)
    }

    func storageUsage(cacheBytes: Int64) -> PackageStorageUsage {
        lock.lock(); defer { lock.unlock() }
        guard (try? ensureDirectories()) != nil else { return PackageStorageUsage(downloadedPackages: 0, temporaryFiles: 0, cache: max(0, cacheBytes)) }
        return PackageStorageUsage(
            downloadedPackages: directorySize(verifiedDirectory),
            previousVersions: previousVersionsSize(),
            temporaryFiles: directorySize(temporaryDirectory),
            cache: max(0, cacheBytes)
        )
    }

    private func packageURL(for id: String) -> URL {
        verifiedDirectory.appendingPathComponent(id).appendingPathExtension("ipa")
    }

    private func recordURL(for id: String) -> URL {
        verifiedDirectory.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func removeTransferFilesLocked(_ id: UUID, preservingPackage: Bool) {
        removeManagedFile(at: temporaryURL(for: id))
        removeManagedFile(at: intentURL(for: id))
        removeManagedFile(at: outcomeURL(for: id))
        if !preservingPackage {
            removeManagedFile(at: packageURL(for: id.uuidString.lowercased()))
            removeManagedFile(at: recordURL(for: id.uuidString.lowercased()))
        }
    }

    private func removeManagedFile(at url: URL) {
        guard isRegularFile(url) || isSymbolicLink(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func isInsufficientStorage(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && value.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        return value.domain == NSPOSIXErrorDomain && value.code == Int(ENOSPC)
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard isRegularFile(url), let number = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return -1 }
        return Int64(number)
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard isRegularFile(file), let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private func previousVersionsSize() -> Int64 {
        let records = verifiedPackages()
        let grouped = Dictionary(grouping: records, by: { $0.bundleIdentifier.lowercased() })
        var previousIDs = Set<String>()
        for packages in grouped.values where packages.count > 1 {
            let newest = packages.max { lhs, rhs in
                if VersionComparator.isNewerRelease(
                    candidateVersion: lhs.version,
                    candidateBuild: lhs.build,
                    installedVersion: rhs.version,
                    installedBuild: rhs.build
                ) { return false }
                if VersionComparator.isNewerRelease(
                    candidateVersion: rhs.version,
                    candidateBuild: rhs.build,
                    installedVersion: lhs.version,
                    installedBuild: lhs.build
                ) { return true }
                return lhs.verifiedAt < rhs.verifiedAt
            }
            previousIDs.formUnion(packages.filter { $0.id != newest?.id }.map(\.id))
        }
        return records.filter { previousIDs.contains($0.id) }.reduce(Int64.zero) { $0 + $1.size }
    }

    private func ensureDirectories() throws {
        if let initializationError { throw initializationError }
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: verifiedDirectory, withIntermediateDirectories: true)
    }
}

private extension JSONEncoder {
    static var packageStorage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var packageStorage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
