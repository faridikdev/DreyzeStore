import Foundation

public enum StoreError: Error, Equatable, Sendable {
    case invalidRequest
    case networkUnavailable
    case invalidResponse
    case serverFailure(statusCode: Int)
    case decodingFailure
}
