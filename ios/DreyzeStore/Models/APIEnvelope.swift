import Foundation

public struct APIEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    public let data: Value
    public let meta: APIResponseMetadata?
}

public struct APIResponseMetadata: Decodable, Sendable {
    public let requestId: String?
    public let nextCursor: String?
    public let page: Int?
    public let pageSize: Int?
    public let hasMore: Bool?
}

public struct APIErrorEnvelope: Decodable, Sendable {
    public let error: APIErrorBody
}

public struct APIErrorBody: Decodable, Sendable {
    public let code: String
    public let message: String
    public let requestId: String?
}
