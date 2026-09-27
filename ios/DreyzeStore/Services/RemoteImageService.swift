import Foundation
import ImageIO
import UIKit

public actor RemoteImageService {
    public static let shared = RemoteImageService()
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 24 * 1_024 * 1_024, diskCapacity: 96 * 1_024 * 1_024, diskPath: "DreyzeRemoteImages")
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: configuration)
    }

    public func data(for url: URL, maximumPixelDimension: Int = 512) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { throw StoreError.invalidRequest }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(), mime.hasPrefix("image/"), data.count <= 12 * 1_024 * 1_024,
              http.expectedContentLength <= 12 * 1_024 * 1_024 || http.expectedContentLength < 0 else {
            throw StoreError.invalidResponse
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, min(maximumPixelDimension, 2_048)),
              ] as CFDictionary),
              let thumbnailData = UIImage(cgImage: thumbnail).pngData() else {
            throw StoreError.invalidResponse
        }
        return thumbnailData
    }

    public func clearCache() {
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}
