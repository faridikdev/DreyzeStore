import Foundation

public struct APIConfiguration: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              let host = baseURL.host,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              (scheme == "https" || (scheme == "http" && Self.isLoopback(host))) else {
            throw ConfigurationError.invalidAPIBaseURL
        }
        self.baseURL = baseURL
    }

    public static func from(bundle: Bundle = .main) throws -> APIConfiguration {
        guard let value = bundle.object(forInfoDictionaryKey: "DreyzeAPIBaseURL") as? String,
              let url = URL(string: value),
              !value.isEmpty else {
            throw ConfigurationError.missingAPIBaseURL
        }
        return try APIConfiguration(baseURL: url)
    }

    private static func isLoopback(_ host: String) -> Bool {
        #if DEBUG
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
        #else
        return false
        #endif
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case missingAPIBaseURL
    case invalidAPIBaseURL
}
