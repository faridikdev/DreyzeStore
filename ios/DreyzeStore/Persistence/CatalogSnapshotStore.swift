import CryptoKit
import Foundation

public struct CatalogSnapshot: Sendable {
    public let data: Data
    public let receivedAt: Date
    public init(data: Data, receivedAt: Date) { self.data = data; self.receivedAt = receivedAt }
}

public protocol CatalogSnapshotStore: Sendable {
    func load(key: String, now: Date, maximumAge: TimeInterval) async throws -> CatalogSnapshot?
    func save(key: String, data: Data, receivedAt: Date) async throws
    func clear() async throws
}

public actor FileCatalogSnapshotStore: CatalogSnapshotStore {
    private struct Record: Codable {
        let receivedAt: Date
        let data: Data
    }

    private let directory: URL
    private let maximumBytes: Int
    private let maximumEntryBytes: Int

    public init(directory: URL? = nil, maximumBytes: Int = 8 * 1_024 * 1_024, maximumEntryBytes: Int = 3 * 1_024 * 1_024) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DreyzeCatalog", isDirectory: true)
        self.maximumBytes = maximumBytes
        self.maximumEntryBytes = maximumEntryBytes
    }

    public func load(key: String, now: Date = Date(), maximumAge: TimeInterval = 7 * 24 * 60 * 60) async throws -> CatalogSnapshot? {
        let file = fileURL(for: key)
        guard let raw = try? Data(contentsOf: file),
              let record = try? JSONDecoder.catalogCache.decode(Record.self, from: raw) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        guard record.data.count <= maximumEntryBytes, record.receivedAt <= now,
              now.timeIntervalSince(record.receivedAt) <= maximumAge else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return CatalogSnapshot(data: record.data, receivedAt: record.receivedAt)
    }

    public func save(key: String, data: Data, receivedAt: Date = Date()) async throws {
        guard data.count <= maximumEntryBytes else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = Record(receivedAt: receivedAt, data: data)
        let encoded = try JSONEncoder.catalogCache.encode(record)
        try encoded.write(to: fileURL(for: key), options: .atomic)
        try trimIfNeeded()
    }

    public func clear() async throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func storageBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return 0 }
        return files.reduce(into: Int64(0)) { total, file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    private func trimIfNeeded() throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries: [(URL, Int, Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            return (file, size, modified)
        }.sorted { $0.2 > $1.2 }
        var total = 0
        for (file, size, modified) in entries {
            if Date().timeIntervalSince(modified) > 7 * 24 * 60 * 60 || total + size > maximumBytes {
                try? FileManager.default.removeItem(at: file)
            } else {
                total += size
            }
        }
    }
}

private extension JSONEncoder {
    static var catalogCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var catalogCache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
