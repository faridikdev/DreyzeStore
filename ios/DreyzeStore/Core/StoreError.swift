import Foundation

public enum StoreError: Error, Equatable, Sendable {
    case configurationUnavailable
    case invalidRequest
    case networkUnavailable
    case invalidResponse
    case serverFailure(statusCode: Int)
    case decodingFailure

    public var userMessage: String {
        switch self {
        case .configurationUnavailable:
            "The store server is not configured for this build."
        case .invalidRequest, .invalidResponse, .decodingFailure:
            "The store returned information that could not be read. Please try again."
        case .networkUnavailable:
            "Check your internet connection and try again."
        case .serverFailure(let statusCode) where statusCode == 404:
            "This app is no longer available."
        case .serverFailure:
            "The store is temporarily unavailable. Please try again."
        }
    }
}
