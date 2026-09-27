import CryptoKit
import Foundation
import ZIPFoundation

public struct VerifiedPackage: Equatable, Sendable {
    public let localURL: URL
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let minimumOSVersion: String
    public let size: Int64
    public let sha256: String
    public let verifiedAt: Date
    public let sourceIdentifier: String
    public let sourceName: String

    fileprivate init(localURL: URL, release: PackageDownloadRelease, size: Int64, sha256: String, verifiedAt: Date) {
        self.localURL = localURL
        self.bundleIdentifier = release.bundleIdentifier
        self.version = release.version
        self.build = release.build
        self.minimumOSVersion = release.minimumOSVersion
        self.size = size
        self.sha256 = sha256
        self.verifiedAt = verifiedAt
        self.sourceIdentifier = release.sourceIdentifier
        self.sourceName = release.sourceName
    }
}

struct VerifiedPackageDigest: Sendable {
    let size: Int64
    let sha256: String

    fileprivate init(size: Int64, sha256: String) {
        self.size = size
        self.sha256 = sha256
    }
}

struct PackageValidationReceipt: Sendable {
    let transferID: UUID
    let size: Int64
    let sha256: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let minimumOSVersion: String

    fileprivate init(intent: PackageDownloadIntent, digest: VerifiedPackageDigest) {
        transferID = intent.id
        size = digest.size
        sha256 = digest.sha256
        bundleIdentifier = intent.release.bundleIdentifier
        version = intent.release.version
        build = intent.release.build
        minimumOSVersion = intent.release.minimumOSVersion
    }
}

struct PackageValidationLimits: Sendable {
    var maximumEntries = PackageLimits.maximumArchiveEntries
    var maximumCentralDirectoryBytes = 128 * 1_024 * 1_024
    var maximumEntryUncompressedBytes = PackageLimits.maximumEntryUncompressedBytes
    var maximumArchiveUncompressedBytes = PackageLimits.maximumArchiveUncompressedBytes
    var maximumCompressionRatio = PackageLimits.maximumCompressionRatio
    var maximumPathDepth = 64
    var maximumInfoPlistBytes = PackageLimits.maximumInfoPlistBytes
    var maximumSymlinkTargetBytes = PackageLimits.maximumSymlinkTargetBytes
    var maximumPackageBytes = PackageLimits.maximumDownloadBytes
}

struct PackageValidator: Sendable {
    let storage: PackageStorage
    var limits = PackageValidationLimits()

    func verifyDownloadedPackage(at fileURL: URL, intent: PackageDownloadIntent) throws -> VerifiedPackage {
        do {
            let digest = try verifyChecksum(at: fileURL, intent: intent)
            return try inspectAndStore(at: fileURL, intent: intent, digest: digest)
        } catch {
            storage.removeTransferFiles(intent.id)
            throw error
        }
    }

    func verifyChecksum(at fileURL: URL, intent: PackageDownloadIntent) throws -> VerifiedPackageDigest {
        guard storage.temporaryFileIsOwned(fileURL, transferID: intent.id) else { throw PackageVerificationError.unsafeArchive }
        try Self.validateExpectedMetadata(intent.release, maximumPackageBytes: limits.maximumPackageBytes)
        let size = try Self.regularFileSize(fileURL)
        guard size > 0, size <= limits.maximumPackageBytes else { throw PackageDownloadFailure(.sizeLimit) }
        guard size == intent.release.size else { throw PackageDownloadFailure(.sizeMismatch) }
        let digest = try Self.sha256(fileURL)
        guard Self.constantTimeSHA256Match(expected: intent.release.sha256, actual: digest) else {
            throw PackageDownloadFailure(.checksumMismatch)
        }
        return VerifiedPackageDigest(size: size, sha256: digest)
    }

    func inspectAndStore(at fileURL: URL, intent: PackageDownloadIntent, digest: VerifiedPackageDigest) throws -> VerifiedPackage {
        guard storage.temporaryFileIsOwned(fileURL, transferID: intent.id) else { throw PackageVerificationError.unsafeArchive }
        let release = intent.release
        let currentSize = try Self.regularFileSize(fileURL)
        guard currentSize == digest.size, currentSize == release.size else { throw PackageDownloadFailure(.sizeMismatch) }
        let currentSHA256 = try Self.sha256(fileURL)
        guard Self.constantTimeSHA256Match(expected: digest.sha256, actual: currentSHA256),
              Self.constantTimeSHA256Match(expected: release.sha256, actual: currentSHA256) else {
            throw PackageDownloadFailure(.checksumMismatch)
        }
        let inspected = try inspectArchive(at: fileURL)
        guard inspected.bundleIdentifier == release.bundleIdentifier,
              inspected.version == release.version,
              inspected.build == release.build,
              Self.normalizedOSVersion(inspected.minimumOSVersion) == Self.normalizedOSVersion(release.minimumOSVersion) else {
            throw PackageDownloadFailure(.invalidMetadata)
        }
        let verifiedAt = Date()
        let receipt = PackageValidationReceipt(intent: intent, digest: digest)
        let (_, storedURL) = try storage.storeVerifiedPackage(
            from: fileURL,
            intent: intent,
            receipt: receipt,
            verifiedAt: verifiedAt
        )
        return VerifiedPackage(localURL: storedURL, release: release, size: digest.size, sha256: digest.sha256, verifiedAt: verifiedAt)
    }

    func revalidateStoredPackage(_ package: StoredVerifiedPackage) throws -> VerifiedPackage {
        guard let fileURL = storage.packageURL(for: package) else { throw PackageVerificationError.unsafeArchive }
        let release = PackageDownloadRelease(
            appID: package.appID,
            name: package.name,
            developer: package.developer,
            bundleIdentifier: package.bundleIdentifier,
            version: package.version,
            build: package.build,
            minimumOSVersion: package.minimumOSVersion,
            downloadURL: package.iconURL,
            sha256: package.sha256,
            size: package.size,
            sourceIdentifier: package.sourceIdentifier,
            sourceName: package.sourceName,
            iconURL: package.iconURL
        )
        try Self.validateExpectedMetadata(release, maximumPackageBytes: limits.maximumPackageBytes)
        let actualSize = try Self.regularFileSize(fileURL)
        guard actualSize == package.size else { throw PackageDownloadFailure(.sizeMismatch) }
        let digest = try Self.sha256(fileURL)
        guard Self.constantTimeSHA256Match(expected: package.sha256, actual: digest) else {
            throw PackageDownloadFailure(.checksumMismatch)
        }
        let inspected = try inspectArchive(at: fileURL)
        guard inspected.bundleIdentifier == package.bundleIdentifier,
              inspected.version == package.version,
              inspected.build == package.build,
              Self.normalizedOSVersion(inspected.minimumOSVersion) == Self.normalizedOSVersion(package.minimumOSVersion) else {
            throw PackageDownloadFailure(.invalidMetadata)
        }
        let finalSize = try Self.regularFileSize(fileURL)
        let finalDigest = try Self.sha256(fileURL)
        guard finalSize == actualSize,
              Self.constantTimeSHA256Match(expected: package.sha256, actual: finalDigest) else {
            throw PackageDownloadFailure(.checksumMismatch)
        }
        return VerifiedPackage(localURL: fileURL, release: release, size: finalSize, sha256: finalDigest, verifiedAt: package.verifiedAt)
    }

    /// Re-establishes the package boundary immediately before installation.
    /// The receipt must still map to an IPA and metadata record owned by this
    /// PackageStorage instance; current bytes and IPA metadata are then checked
    /// again. No caller-provided path or server-only metadata can pass this gate.
    func revalidateForInstallation(_ package: VerifiedPackage) throws -> VerifiedPackage {
        guard let stored = storage.storedPackage(matching: package) else {
            throw PackageVerificationError.unsafeArchive
        }
        let current = try revalidateStoredPackage(stored)
        guard current.localURL.standardizedFileURL == package.localURL.standardizedFileURL,
              current.bundleIdentifier == package.bundleIdentifier,
              current.version == package.version,
              current.build == package.build,
              current.minimumOSVersion == package.minimumOSVersion,
              current.size == package.size,
              Self.constantTimeSHA256Match(expected: package.sha256, actual: current.sha256),
              current.sourceIdentifier == package.sourceIdentifier,
              current.sourceName == package.sourceName else {
            throw PackageVerificationError.unsafeArchive
        }
        return current
    }

    private func inspectArchive(at fileURL: URL) throws -> InspectedPackageMetadata {
        try Self.preflightCentralDirectory(
            at: fileURL,
            maximumEntries: limits.maximumEntries,
            maximumBytes: limits.maximumCentralDirectoryBytes
        )
        let archive: Archive
        do { archive = try Archive(url: fileURL, accessMode: .read) }
        catch { throw PackageVerificationError.invalidArchive }

        var entries: [Entry] = []
        var paths = Set<String>()
        var totalUncompressed: UInt64 = 0
        for entry in archive {
            try Self.checkCancellation()
            guard entries.count < limits.maximumEntries else { throw PackageVerificationError.unsafeArchive }
            guard entry.type == .file || entry.type == .directory || entry.type == .symlink else {
                throw PackageVerificationError.unsafeArchive
            }
            let path = try Self.normalizedArchivePath(entry.path, type: entry.type)
            guard Self.pathComponents(path).count <= limits.maximumPathDepth else { throw PackageVerificationError.unsafeArchive }
            let key = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard paths.insert(key).inserted else { throw PackageVerificationError.unsafeArchive }
            guard entry.uncompressedSize <= limits.maximumEntryUncompressedBytes else { throw PackageVerificationError.unsafeArchive }
            let (newTotal, overflow) = totalUncompressed.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, newTotal <= limits.maximumArchiveUncompressedBytes else { throw PackageVerificationError.unsafeArchive }
            totalUncompressed = newTotal
            if entry.uncompressedSize > 0 {
                guard entry.compressedSize > 0 else { throw PackageVerificationError.unsafeArchive }
                let ratio = entry.uncompressedSize / entry.compressedSize
                guard ratio < limits.maximumCompressionRatio ||
                      (ratio == limits.maximumCompressionRatio && entry.uncompressedSize % entry.compressedSize == 0) else {
                    throw PackageVerificationError.unsafeArchive
                }
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else { throw PackageVerificationError.invalidArchive }

        let hasPayload = entries.contains { $0.path == "Payload/" || $0.path.hasPrefix("Payload/") }
        guard hasPayload else { throw PackageVerificationError.missingPayload }
        let appRoots = Set(entries.compactMap { entry -> String? in
            let components = Self.pathComponents(entry.path)
            guard components.count >= 2, components[0] == "Payload", components[1].hasSuffix(".app") else { return nil }
            return "Payload/\(components[1])"
        })
        guard appRoots.count == 1, let appRoot = appRoots.first else { throw PackageVerificationError.missingApplicationBundle }
        let appRootName = appRoot.components(separatedBy: "/")[1]

        for entry in entries {
            let components = Self.pathComponents(entry.path)
            guard let top = components.first else { throw PackageVerificationError.unsafeArchive }
            if top == "Payload" {
                guard components.count == 1 || (components.count >= 2 && components[1] == appRootName) else {
                    throw PackageVerificationError.unsafeArchive
                }
                if components.count == 1 || components.count == 2 {
                    guard entry.type == .directory else { throw PackageVerificationError.unsafeArchive }
                }
            }
        }

        let nonDirectoryPaths = Set(entries.compactMap { entry -> String? in
            guard entry.type != .directory else { return nil }
            return Self.normalizedPathKey(entry.path)
        })
        for entry in entries {
            let components = Self.pathComponents(Self.normalizedPathKey(entry.path))
            guard components.count > 1 else { continue }
            for depth in 1..<components.count {
                let ancestor = components.prefix(depth).joined(separator: "/")
                guard !nonDirectoryPaths.contains(ancestor) else { throw PackageVerificationError.unsafeArchive }
            }
        }

        let infoPath = "\(appRoot)/Info.plist"
        guard let infoEntry = entries.first(where: { $0.path == infoPath }), infoEntry.type == .file else {
            throw PackageVerificationError.missingInfoPlist
        }
        guard infoEntry.uncompressedSize <= UInt64(limits.maximumInfoPlistBytes) else { throw PackageVerificationError.unsafeArchive }
        let infoData = try Self.read(entry: infoEntry, from: archive, maximumBytes: limits.maximumInfoPlistBytes)
        let plist: Any
        do { plist = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) }
        catch { throw PackageVerificationError.malformedMetadata }
        guard let values = plist as? [String: Any] else { throw PackageVerificationError.malformedMetadata }

        guard let bundleIdentifier = values["CFBundleIdentifier"] as? String,
              let executable = values["CFBundleExecutable"] as? String,
              let version = values["CFBundleShortVersionString"] as? String,
              let build = values["CFBundleVersion"] as? String,
              let minimumOSVersion = values["MinimumOSVersion"] as? String,
              Self.isSafeLeaf(executable) else { throw PackageVerificationError.malformedMetadata }
        let executablePath = "\(appRoot)/\(executable)"
        guard entries.contains(where: { $0.path == executablePath && $0.type == .file }) else {
            throw PackageVerificationError.missingExecutable
        }

        for entry in entries where entry.type == .symlink {
            guard entry.path.hasPrefix(appRoot + "/"), entry.uncompressedSize <= UInt64(limits.maximumSymlinkTargetBytes) else {
                throw PackageVerificationError.unsafeArchive
            }
            let linkData = try Self.read(entry: entry, from: archive, maximumBytes: limits.maximumSymlinkTargetBytes)
            guard let target = String(data: linkData, encoding: .utf8), Self.isContainedSymlink(target, linkPath: entry.path, appRoot: appRoot) else {
                throw PackageVerificationError.unsafeArchive
            }
        }

        return InspectedPackageMetadata(bundleIdentifier: bundleIdentifier, version: version, build: build, minimumOSVersion: minimumOSVersion)
    }

    private static func normalizedArchivePath(_ path: String, type: Entry.EntryType) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 1_024,
              !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.controlCharacters.contains($0) }),
              !path.contains(":") else { throw PackageVerificationError.unsafeArchive }
        let withoutTrailingSlash = type == .directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = withoutTrailingSlash.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PackageVerificationError.unsafeArchive
        }
        return withoutTrailingSlash
    }

    private static func preflightCentralDirectory(at fileURL: URL, maximumEntries: Int, maximumBytes: Int) throws {
        let archiveSize = try regularFileSize(fileURL)
        guard archiveSize >= 22 else { throw PackageVerificationError.invalidArchive }
        let tailLength = min(archiveSize, 22 + 65_535)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(archiveSize - tailLength))
        guard let tailData = try handle.read(upToCount: Int(tailLength)), tailData.count >= 22 else {
            throw PackageVerificationError.invalidArchive
        }
        let tail = Array(tailData)
        var endRecordIndex: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            guard readUInt32(tail, at: index) == 0x06054b50,
                  let commentLength = readUInt16(tail, at: index + 20),
                  index + 22 + Int(commentLength) == tail.count else { continue }
            endRecordIndex = index
            break
        }
        guard let endRecordIndex,
              readUInt16(tail, at: endRecordIndex + 4) == 0,
              readUInt16(tail, at: endRecordIndex + 6) == 0,
              let entriesOnDisk = readUInt16(tail, at: endRecordIndex + 8),
              let totalEntries = readUInt16(tail, at: endRecordIndex + 10),
              let centralSize = readUInt32(tail, at: endRecordIndex + 12),
              let centralOffset = readUInt32(tail, at: endRecordIndex + 16) else {
            throw PackageVerificationError.invalidArchive
        }
        guard entriesOnDisk == totalEntries,
              totalEntries != UInt16.max,
              centralSize != UInt32.max,
              centralOffset != UInt32.max,
              totalEntries > 0 else { throw PackageVerificationError.unsafeArchive }
        let directoryEnd = UInt64(centralOffset).addingReportingOverflow(UInt64(centralSize))
        guard !directoryEnd.overflow,
              directoryEnd.partialValue <= UInt64(archiveSize - tailLength + Int64(endRecordIndex)),
              UInt64(centralSize) <= UInt64(max(0, maximumBytes)),
              Int(totalEntries) <= maximumEntries else {
            throw PackageVerificationError.unsafeArchive
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func normalizedPathKey(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isSafeLeaf(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains(":")
    }

    private static func isContainedSymlink(_ target: String, linkPath: String, appRoot: String) -> Bool {
        guard !target.isEmpty, target.utf8.count <= PackageLimits.maximumSymlinkTargetBytes,
              !target.hasPrefix("/"), !target.hasPrefix("\\"), !target.contains("\\"), !target.contains(":"),
              !target.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.controlCharacters.contains($0) }) else { return false }
        let rootComponents = pathComponents(appRoot)
        var resolved = pathComponents(linkPath).dropLast().map { $0 }
        for component in target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard resolved.count > rootComponents.count else { return false }
                resolved.removeLast()
            } else {
                resolved.append(component)
            }
        }
        return resolved.count >= rootComponents.count && Array(resolved.prefix(rootComponents.count)) == rootComponents
    }

    private static func read(entry: Entry, from archive: Archive, maximumBytes: Int) throws -> Data {
        var data = Data()
        do {
            _ = try archive.extract(entry, bufferSize: min(defaultReadChunkSize, maximumBytes), consumer: { chunk in
                try Self.checkCancellation()
                guard chunk.count <= maximumBytes - data.count else { throw PackageVerificationError.unsafeArchive }
                data.append(chunk)
            })
        } catch let error as PackageVerificationError { throw error }
        catch { throw PackageVerificationError.invalidArchive }
        return data
    }

    private static func validateExpectedMetadata(_ release: PackageDownloadRelease, maximumPackageBytes: Int64) throws {
        guard release.size > 0, release.size <= maximumPackageBytes,
              isValidSHA256(release.sha256),
              release.bundleIdentifier.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil,
              isValidVersion(release.version), isValidBuild(release.build), isValidVersion(release.minimumOSVersion) else {
            throw PackageVerificationError.malformedMetadata
        }
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func isValidVersion(_ value: String) -> Bool {
        value.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil
    }

    private static func isValidBuild(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }

    private static func normalizedOSVersion(_ value: String) -> [UInt64]? {
        guard isValidVersion(value) else { return nil }
        let components = value.split(separator: ".").compactMap { UInt64($0) }
        guard components.count == value.split(separator: ".").count else { return nil }
        var normalized = components
        while normalized.count > 1 && normalized.last == 0 { normalized.removeLast() }
        return normalized
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { throw PackageVerificationError.invalidArchive }
        return Int64(size)
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    private static func constantTimeSHA256Match(expected: String, actual: String) -> Bool {
        guard isValidSHA256(expected), isValidSHA256(actual) else { return false }
        let lhs = Array(expected.lowercased().utf8)
        let rhs = Array(actual.lowercased().utf8)
        var difference: UInt8 = 0
        for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

private struct InspectedPackageMetadata {
    let bundleIdentifier: String
    let version: String
    let build: String
    let minimumOSVersion: String
}
