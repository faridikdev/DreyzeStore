import CryptoKit
import Darwin
import Foundation
import Security

struct WindowsCompanionPairingPayload: Decodable, Sendable {
    let version: Int
    let endpoint: URL
    let certificateSHA256: String
    let pairingCode: String

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 8_192,
              let data = text.data(using: .utf8),
              let value = try? JSONDecoder.companion.decode(Self.self, from: data),
              value.version == 1,
              isPrivateHTTPSAPI(value.endpoint),
              value.certificateSHA256.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              value.pairingCode.range(of: "^[A-Za-z0-9]{12}$", options: .regularExpression) != nil else {
            throw CompanionClientError.invalidPairingPayload
        }
        return value
    }

    private static func isPrivateHTTPSAPI(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              let host = parts.host,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path == "/api/v1" || parts.path == "/api/v1/" else { return false }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let octets = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            return octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }
        var ipv6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
        return withUnsafeBytes(of: ipv6.__u6_addr.__u6_addr8) { bytes in
            bytes.count >= 1 && (bytes[0] & 0xfe) == 0xfc
        }
    }
}

struct PairedWindowsCompanion: Codable, Equatable, Sendable {
    var clientID: String
    var endpoint: URL
    var certificateSHA256: String
    var token: String
    var pairedAt: Date
    var deviceUDID: String?
    var deviceName: String?
    var deviceProductVersion: String?
    var developerMode: Bool?
    var signingConfigured: Bool
    var signingIdentity: String?
    var teamIdentifier: String?
    var signingMessage: String?
    var certificateExpiresAt: Date?
    var provisioningExpiresAt: Date?
    var connectionError: String?
}

enum WindowsCompanionPairingStore {
    private static let service = "com.dreyzestore.ios.windows-companion"
    private static let account = "paired-companion-v1"
    private static let lock = NSLock()

    static func load() -> PairedWindowsCompanion? {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder.companion.decode(PairedWindowsCompanion.self, from: data)
    }

    static func save(_ value: PairedWindowsCompanion) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder.companion.encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionClientError.keychain(status) }
    }

    static func remove() {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum CompanionClientError: Error, LocalizedError {
    case invalidPairingPayload
    case tlsPinMismatch
    case invalidResponse
    case server(Int, String)
    case signingNotConfigured
    case noTrustedDevice
    case developerModeRequired
    case installationUnconfirmed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPairingPayload: "The pairing data is invalid. Scan the current QR code or check the endpoint and certificate fingerprint."
        case .tlsPinMismatch: "The computer’s security certificate changed. Pair with the computer again on the same trusted network."
        case .invalidResponse: "The Windows Companion returned an unexpected response."
        case let .server(_, message): message
        case .signingNotConfigured: "Import an Apple Development certificate and a provisioning profile in Windows Companion first."
        case .noTrustedDevice: "Connect and trust an iPhone in Windows Companion."
        case .developerModeRequired: "Enable Developer Mode on the iPhone in Settings → Privacy & Security, then reconnect it."
        case .installationUnconfirmed: "The Companion did not confirm the exact installed app version from the iPhone."
        case let .keychain(status): "The paired computer could not be saved securely (Keychain status \(status))."
        }
    }
}

private struct PairRequest: Encodable {
    let code: String
    let clientID: String

    private enum CodingKeys: String, CodingKey { case code, clientID = "clientId" }
}

private struct PairResponse: Decodable {
    let token: String
    let pairedAt: Date
}

enum WindowsCompanionPairing {
    static func pair(payloadText: String) async throws -> PairedWindowsCompanion {
        let payload = try WindowsCompanionPairingPayload.decode(payloadText)
        var record = try await WindowsCompanionService.pair(using: payload)
        try WindowsCompanionPairingStore.save(record)
        do {
            record = try await WindowsCompanionService(record: record).refreshedRecord()
        } catch {
            record.connectionError = "The iPhone is paired. Connect a trusted iPhone and signing identity in Windows Companion."
        }
        try WindowsCompanionPairingStore.save(record)
        return record
    }

    static func refresh() async throws -> PairedWindowsCompanion {
        guard let record = WindowsCompanionPairingStore.load() else { throw CompanionClientError.invalidPairingPayload }
        let updated = try await WindowsCompanionService(record: record).refreshedRecord()
        try WindowsCompanionPairingStore.save(updated)
        return updated
    }

    static func manualPayload(endpoint: String, code: String, fingerprint: String) throws -> String {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CompanionClientError.invalidPairingPayload
        }
        let payload: [String: Any] = [
            "version": 1,
            "endpoint": url.absoluteString,
            "certificateSHA256": fingerprint.trimmingCharacters(in: .whitespacesAndNewlines),
            "pairingCode": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { throw CompanionClientError.invalidPairingPayload }
        _ = try WindowsCompanionPairingPayload.decode(text)
        return text
    }

    static func forget() {
        WindowsCompanionPairingStore.remove()
    }
}

private struct CompanionDevice: Decodable, Sendable {
    let udid: String
    let name: String
    let productVersion: String?
    let developerMode: Bool?
    let trusted: Bool
}

private struct CompanionSigningStatus: Decodable {
    let configured: Bool
    let identityLabel: String?
    let teamId: String?
    let limitation: String?
    let certificateExpiresAt: Date?
    let provisioningExpiresAt: Date?
}

private struct PackageExpectation: Encodable {
    let requestID: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let minimumOSVersion: String?
    let sha256: String
    let size: Int64
    let appName: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId", bundleIdentifier, version, build, minimumOSVersion, sha256, size, appName
    }
}

struct CompanionInstalledApp: Decodable {
    let bundleIdentifier: String
    let version: String?
    let build: String?
}

struct CompanionInstallReceipt: Decodable {
    let requestID: String
    let state: String
    let detail: CompanionInstallDetail?

    private enum CodingKeys: String, CodingKey { case requestID = "requestId", state, detail }

    init(from decoder: Decoder) throws {
        if let scalar = try? decoder.singleValueContainer(), let state = try? scalar.decode(String.self) {
            requestID = ""
            self.state = state
            detail = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        if let scalarState = try? container.decode(String.self, forKey: .state) {
            state = scalarState
            detail = try container.decodeIfPresent(CompanionInstallDetail.self, forKey: .detail)
        } else {
            let nested = try container.decode(CompanionInstallStateObject.self, forKey: .state)
            state = nested.state
            if let nestedDetail = nested.detail {
                detail = nestedDetail
            } else {
                detail = try container.decodeIfPresent(CompanionInstallDetail.self, forKey: .detail)
            }
        }
    }
}

struct CompanionInstallStateObject: Decodable {
    let state: String
    let detail: CompanionInstallDetail?
}

struct CompanionInstallDetail: Decodable {
    let code: String?
    let message: String?
    let app: CompanionInstalledApp?
    let installedAt: Date?
}

private struct CompanionHTTPResponse {
    let data: Data
    let status: Int
}

private final class PinnedCompanionSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let expectedFingerprint: String
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(fingerprint: String) {
        expectedFingerprint = fingerprint.lowercased()
        super.init()
    }

    func data(for request: URLRequest) async throws -> CompanionHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Self.serverError(data: data, status: http.statusCode) }
        return CompanionHTTPResponse(data: data, status: http.statusCode)
    }

    func upload(file: URL, for request: URLRequest) async throws -> CompanionHTTPResponse {
        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw CompanionClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Self.serverError(data: data, status: http.statusCode) }
        return CompanionHTTPResponse(data: data, status: http.statusCode)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let certificate = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedFingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private static func serverError(data: Data, status: Int) -> CompanionClientError {
        let message = (try? JSONDecoder.companion.decode(CompanionAPIError.self, from: data).error)
            ?? "Windows Companion returned HTTP \(status)."
        return .server(status, message)
    }
}

private struct CompanionAPIError: Decodable { let error: String }

private struct WindowsCompanionService {
    let record: PairedWindowsCompanion
    private let session: PinnedCompanionSession

    init(record: PairedWindowsCompanion) {
        self.record = record
        self.session = PinnedCompanionSession(fingerprint: record.certificateSHA256)
    }

    static func pair(using payload: WindowsCompanionPairingPayload) async throws -> PairedWindowsCompanion {
        let clientID = UUID().uuidString.lowercased()
        let unpaired = PairedWindowsCompanion(
            clientID: clientID,
            endpoint: payload.endpoint,
            certificateSHA256: payload.certificateSHA256.lowercased(),
            token: "",
            pairedAt: Date(),
            deviceUDID: nil,
            deviceName: nil,
            deviceProductVersion: nil,
            developerMode: nil,
            signingConfigured: false,
            signingIdentity: nil,
            teamIdentifier: nil,
            signingMessage: nil,
            certificateExpiresAt: nil,
            provisioningExpiresAt: nil,
            connectionError: nil
        )
        let service = WindowsCompanionService(record: unpaired)
        let requestData = try JSONEncoder.companion.encode(PairRequest(code: payload.pairingCode.uppercased(), clientID: clientID))
        let response = try await service.request(path: "pair", method: "POST", body: requestData, authenticated: false)
        let pair = try JSONDecoder.companion.decode(PairResponse.self, from: response.data)
        guard pair.token.utf8.count == 64,
              pair.token.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }) else {
            throw CompanionClientError.invalidResponse
        }
        return PairedWindowsCompanion(
            clientID: clientID,
            endpoint: payload.endpoint,
            certificateSHA256: payload.certificateSHA256.lowercased(),
            token: pair.token,
            pairedAt: pair.pairedAt,
            deviceUDID: nil,
            deviceName: nil,
            deviceProductVersion: nil,
            developerMode: nil,
            signingConfigured: false,
            signingIdentity: nil,
            teamIdentifier: nil,
            signingMessage: nil,
            certificateExpiresAt: nil,
            provisioningExpiresAt: nil,
            connectionError: nil
        )
    }

    func refreshedRecord() async throws -> PairedWindowsCompanion {
        let devices: [CompanionDevice] = try await json(path: "device")
        let signing: CompanionSigningStatus = try await json(path: "signing")
        let device = devices.first(where: \.trusted)
        var updated = record
        updated.deviceUDID = device?.udid
        updated.deviceName = device?.name
        updated.deviceProductVersion = device?.productVersion
        updated.developerMode = device?.developerMode
        updated.signingIdentity = signing.identityLabel
        updated.teamIdentifier = signing.teamId
        updated.signingMessage = signing.limitation
        updated.certificateExpiresAt = signing.certificateExpiresAt
        updated.provisioningExpiresAt = signing.provisioningExpiresAt
        updated.signingConfigured = signing.configured
            && (signing.provisioningExpiresAt.map { $0 > Date() } ?? true)
        updated.connectionError = nil
        return updated
    }

    func install(package: VerifiedPackage, onProgress: @escaping @Sendable (InstallationProgress) async -> Void, requestID: String, setActiveRequest: @Sendable (String?) -> Void) async throws -> InstalledApplication {
        try Task.checkCancellation()
        await onProgress(.connectingToCompanion)
        let devices: [CompanionDevice] = try await json(path: "device")
        guard let target = devices.first(where: { $0.udid.caseInsensitiveCompare(record.deviceUDID ?? "") == .orderedSame && $0.trusted }) else {
            throw CompanionClientError.noTrustedDevice
        }
        if target.developerMode == false { throw CompanionClientError.developerModeRequired }
        let signing: CompanionSigningStatus = try await json(path: "signing")
        guard signing.configured else { throw CompanionClientError.signingNotConfigured }

        let expectation = PackageExpectation(
            requestID: requestID,
            bundleIdentifier: package.bundleIdentifier,
            version: package.version,
            build: package.build,
            minimumOSVersion: package.minimumOSVersion,
            sha256: package.sha256.lowercased(),
            size: package.size,
            appName: package.bundleIdentifier
        )
        let metadata = try JSONEncoder.companion.encode(expectation).base64EncodedString().replacingOccurrences(of: "=", with: "")
        var request = try makeRequest(path: "install", method: "POST", body: nil)
        request.setValue(metadata, forHTTPHeaderField: "X-Dreyze-Package")
        request.setValue(target.udid, forHTTPHeaderField: "X-Dreyze-UDID")
        request.timeoutInterval = 60 * 60
        await onProgress(.transferringPackage)
        setActiveRequest(requestID)
        let uploaded = try await session.upload(file: package.localURL, for: request)
        let accepted = try JSONDecoder.companion.decode(CompanionInstallReceipt.self, from: uploaded.data)
        guard uploaded.status == 202, accepted.requestID == requestID || accepted.requestID.isEmpty else {
            throw CompanionClientError.invalidResponse
        }

        for _ in 0..<1_800 {
            try Task.checkCancellation()
            let receipt: CompanionInstallReceipt = try await json(path: "install/\(requestID)")
            switch receipt.state {
            case "received": break
            case "verifying": await onProgress(.verifyingOnCompanion)
            case "signing": await onProgress(.signing)
            case "installing", "confirming": await onProgress(.installing)
            case "installed":
                guard let app = receipt.detail?.app,
                      app.bundleIdentifier == package.bundleIdentifier,
                      app.version == package.version,
                      app.build == package.build else { throw CompanionClientError.installationUnconfirmed }
                setActiveRequest(nil)
                return InstalledApplication(
                    bundleIdentifier: app.bundleIdentifier,
                    version: app.version ?? package.version,
                    build: app.build,
                    sourceIdentifier: "windows-companion",
                    installedAt: receipt.detail?.installedAt
                )
            case "failed":
                throw CompanionClientError.server(409, receipt.detail?.message ?? "The installation failed on Windows Companion.")
            case "cancelled":
                throw CancellationError()
            default: throw CompanionClientError.invalidResponse
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw CompanionClientError.server(408, "The Companion did not finish installation before the local request timed out.")
    }

    func cancel(requestID: String) async {
        _ = try? await request(path: "install/\(requestID)", method: "DELETE")
    }

    func uninstall(udid: String, bundleIdentifier: String) async throws {
        let body = try JSONEncoder.companion.encode(UninstallBody(udid: udid, bundleIdentifier: bundleIdentifier))
        _ = try await request(path: "uninstall", method: "POST", body: body)
    }

    func installedApps(udid: String) async throws -> [CompanionInstalledApp] {
        var parts = URLComponents(url: record.endpoint.appendingPathComponent("apps"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "udid", value: udid)]
        guard let url = parts?.url else { throw CompanionClientError.invalidResponse }
        let response = try await session.data(for: authenticatedRequest(url: url))
        return try JSONDecoder.companion.decode([CompanionInstalledApp].self, from: response.data)
    }

    private func json<T: Decodable>(path: String) async throws -> T {
        let response = try await request(path: path)
        return try JSONDecoder.companion.decode(T.self, from: response.data)
    }

    private func request(path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> CompanionHTTPResponse {
        let url = record.endpoint.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated {
            request.setValue("Bearer \(record.token)", forHTTPHeaderField: "Authorization")
            request.setValue(record.clientID, forHTTPHeaderField: "X-Dreyze-Client-Id")
            request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "X-Dreyze-Timestamp")
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Dreyze-Nonce")
        }
        return try await session.data(for: request)
    }

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        let url = record.endpoint.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: 60 * 60)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(record.token)", forHTTPHeaderField: "Authorization")
        request.setValue(record.clientID, forHTTPHeaderField: "X-Dreyze-Client-Id")
        request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "X-Dreyze-Timestamp")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Dreyze-Nonce")
        return request
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(record.token)", forHTTPHeaderField: "Authorization")
        request.setValue(record.clientID, forHTTPHeaderField: "X-Dreyze-Client-Id")
        request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "X-Dreyze-Timestamp")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Dreyze-Nonce")
        return request
    }
}

private struct UninstallBody: Encodable {
    let udid: String
    let bundleIdentifier: String
}

public final class WindowsCompanionInstallationBackend: InstallationBackend, @unchecked Sendable {
    public let identifier = "windows-companion"
    public let capabilities: InstallationCapabilities = [.confirmedInstall, .installedState, .inventory, .uninstall]
    private let activeRequestLock = NSLock()
    private var activeRequestID: String?
    private let activeSessionLock = NSLock()
    private var activeService: WindowsCompanionService?

    public init() { }

    public var displayName: String {
        "Windows Companion"
    }

    public var availability: BackendAvailability {
        guard let record = WindowsCompanionPairingStore.load(), !record.token.isEmpty else {
            return .requiresConfiguration(reason: "Pair DreyzeStore with a Windows Companion on the same trusted local network.")
        }
        guard record.deviceUDID != nil else {
            return .unavailable(reason: record.connectionError ?? "Connect and trust an iPhone in Windows Companion.")
        }
        if record.developerMode == false {
            return .requiresConfiguration(reason: "Enable Developer Mode on the paired iPhone in Settings → Privacy & Security.")
        }
        guard record.signingConfigured else {
            return .requiresConfiguration(reason: "Import a local Apple Development identity and device-matched provisioning profile in Windows Companion.")
        }
        return .available
    }

    public func refreshAvailability() async {
        guard let record = WindowsCompanionPairingStore.load(), !record.token.isEmpty else { return }
        do {
            let updated = try await WindowsCompanionService(record: record).refreshedRecord()
            try WindowsCompanionPairingStore.save(updated)
        } catch {
            var updated = record
            updated.deviceUDID = nil
            updated.deviceName = nil
            updated.connectionError = "Could not reach the paired Windows Companion. Check that both devices are on the same network."
            try? WindowsCompanionPairingStore.save(updated)
        }
    }

    public func install(package: VerifiedPackage) async -> InstallationDirective {
        await install(package: package, onProgress: { _ in })
    }

    public func install(package: VerifiedPackage, onProgress: @escaping @Sendable (InstallationProgress) async -> Void) async -> InstallationDirective {
        guard let record = WindowsCompanionPairingStore.load(),
              let udid = record.deviceUDID,
              record.signingConfigured else {
            return .unsupported(.configurationRequired("Pair a trusted iPhone and configure local Apple Development signing in Windows Companion."))
        }
        guard package.localURL.isFileURL,
              package.localURL.pathExtension.lowercased() == "ipa",
              FileManager.default.isReadableFile(atPath: package.localURL.path) else {
            return .failed(.packageRejected("Only a managed, verified IPA can be sent to Windows Companion."))
        }
        let service = WindowsCompanionService(record: record)
        activeSessionLock.withLock { activeService = service }
        let requestID = UUID().uuidString.lowercased()
        do {
            let installed = try await service.install(package: package, onProgress: onProgress, requestID: requestID) { [weak self] value in
                guard let self else { return }
                self.activeRequestLock.withLock { self.activeRequestID = value }
            }
            activeSessionLock.withLock { activeService = nil }
            activeRequestLock.withLock { activeRequestID = nil }
            guard installed.bundleIdentifier == package.bundleIdentifier,
                  installed.version == package.version,
                  installed.build == package.build else { throw CompanionClientError.installationUnconfirmed }
            _ = udid
            return .installed(installed)
        } catch is CancellationError {
            await cancelInstall()
            return .cancelled
        } catch {
            activeSessionLock.withLock { activeService = nil }
            activeRequestLock.withLock { activeRequestID = nil }
            return .failed(InstallationFailure(
                code: .installationFailed,
                title: "Installation Failed",
                userMessage: error.localizedDescription,
                technicalDetails: String(reflecting: error)
            ))
        }
    }

    public func cancelInstall() async {
        let requestID = activeRequestLock.withLock { activeRequestID }
        let service = activeSessionLock.withLock { activeService }
        if let requestID, let service { await service.cancel(requestID: requestID) }
    }

    public func uninstall(bundleIdentifier: String) async -> UninstallationResult {
        guard let record = WindowsCompanionPairingStore.load(), let udid = record.deviceUDID else {
            return .unsupported(reason: "Pair a connected iPhone with Windows Companion first.")
        }
        do {
            try await WindowsCompanionService(record: record).uninstall(udid: udid, bundleIdentifier: bundleIdentifier)
            let remaining = try await WindowsCompanionService(record: record).installedApps(udid: udid)
            guard !remaining.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                return .failed(InstallationFailure(code: .installationUnconfirmed, title: "Removal Couldn’t Be Confirmed", userMessage: "The iPhone still reports this app as installed.", technicalDetails: "Companion inventory still contains \(bundleIdentifier)."))
            }
            return .uninstalled
        } catch {
            return .failed(InstallationFailure(code: .installationFailed, title: "Couldn’t Remove App", userMessage: error.localizedDescription, technicalDetails: String(reflecting: error)))
        }
    }

    public func queryInstalledState(bundleIdentifier: String) async -> InstalledState {
        guard let record = WindowsCompanionPairingStore.load(), let udid = record.deviceUDID else {
            return .unavailable(reason: "Pair a connected iPhone with Windows Companion first.")
        }
        do {
            guard let app = try await WindowsCompanionService(record: record).installedApps(udid: udid)
                .first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return .notInstalled }
            return .installed(InstalledApplication(
                bundleIdentifier: app.bundleIdentifier,
                version: app.version ?? "Unknown",
                build: app.build,
                sourceIdentifier: "windows-companion-device-inventory"
            ))
        } catch {
            return .unavailable(reason: "The installed-app inventory could not be read from the paired iPhone.")
        }
    }
}

extension JSONDecoder {
    static var companion: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let regular = ISO8601DateFormatter()
            regular.formatOptions = [.withInternetDateTime]
            if let date = regular.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 timestamp")
        }
        return decoder
    }
}

extension JSONEncoder {
    static var companion: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
