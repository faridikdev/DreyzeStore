import Foundation

enum DownloadURLPolicy: Sendable {
    case httpsOnly
    case loopbackHTTPForTests

    func allows(_ url: URL?) -> Bool {
        guard let url,
              url.user == nil, url.password == nil,
              url.host?.isEmpty == false,
              url.fragment == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        guard case .loopbackHTTPForTests = self, url.scheme?.lowercased() == "http" else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
    }
}

protocol PackageDownloadTransport: Sendable {
    func download(
        intent: PackageDownloadIntent,
        destinationURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> PackageTransferResponse
    func cancel(transferID: UUID)
    func setBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void)
}

final class URLSessionPackageDownloadTransport: NSObject, PackageDownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    enum SessionMode: Sendable { case background, foregroundForTests }

    private struct Context {
        let intent: PackageDownloadIntent
        let destinationURL: URL
        let onProgress: @Sendable (DownloadProgress) -> Void
        var continuation: CheckedContinuation<PackageTransferResponse, Error>?
        var taskIdentifier: Int?
        var cancelled = false
    }

    private let storage: PackageStorage
    private let urlPolicy: DownloadURLPolicy
    private let lock = NSRecursiveLock()
    private let sessionBox = SessionBox()
    private var contexts: [UUID: Context] = [:]
    private var transfersByTask: [Int: UUID] = [:]
    private var backgroundEventsCompletionHandler: (@Sendable () -> Void)?
    private(set) var sessionIdentifier: String?

    init(storage: PackageStorage, mode: SessionMode = .background, urlPolicy: DownloadURLPolicy = .httpsOnly) {
        self.storage = storage
        self.urlPolicy = urlPolicy
        let configuration: URLSessionConfiguration
        switch mode {
        case .background:
            let identifier = "com.dreyzestore.ios.package-downloads"
            sessionIdentifier = identifier
            configuration = .background(withIdentifier: identifier)
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
        case .foregroundForTests:
            configuration = .ephemeral
        }
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = PackageLimits.transferTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.dreyzestore.ios.package-download-delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        sessionBox.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    private final class SessionBox: @unchecked Sendable {
        var session: URLSession!
    }

    private var activeSession: URLSession { sessionBox.session }

    func download(
        intent: PackageDownloadIntent,
        destinationURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> PackageTransferResponse {
        guard urlPolicy.allows(intent.release.downloadURL),
              destinationURL.standardizedFileURL == storage.temporaryURL(for: intent.id).standardizedFileURL else {
            throw PackageDownloadFailure(.insecureURL)
        }
        if let outcome = storage.outcome(for: intent.id) {
            return try response(for: outcome, intent: intent, destinationURL: destinationURL)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard contexts[intent.id] == nil else {
                    lock.unlock()
                    continuation.resume(throwing: PackageDownloadFailure(.duplicateDownload))
                    return
                }
                contexts[intent.id] = Context(intent: intent, destinationURL: destinationURL, onProgress: onProgress, continuation: continuation)
                lock.unlock()

                activeSession.getAllTasks { [weak self] tasks in
                    guard let self else {
                        continuation.resume(throwing: PackageDownloadFailure(.unknown))
                        return
                    }
                    guard !self.isCancelled(intent.id) else {
                        self.complete(intent.id, result: .failure(PackageDownloadFailure(.cancelled)))
                        return
                    }
                    if let task = tasks.first(where: { $0.taskDescription == intent.id.uuidString }) as? URLSessionDownloadTask {
                        self.attach(task, to: intent.id)
                        if task.state == .suspended { task.resume() }
                        return
                    }
                    if let savedOutcome = self.storage.outcome(for: intent.id) {
                        do { self.complete(intent.id, result: .success(try self.response(for: savedOutcome, intent: intent, destinationURL: destinationURL))) }
                        catch { self.complete(intent.id, result: .failure(error)) }
                        return
                    }
                    var request = URLRequest(url: intent.release.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
                    request.httpMethod = "GET"
                    request.httpShouldHandleCookies = false
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    let task = self.activeSession.downloadTask(with: request)
                    task.taskDescription = intent.id.uuidString
                    self.attach(task, to: intent.id)
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel(transferID: intent.id)
        }
    }

    func cancel(transferID: UUID) {
        lock.lock()
        if var context = contexts[transferID] {
            context.cancelled = true
            contexts[transferID] = context
        }
        lock.unlock()
        activeSession.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == transferID.uuidString }.forEach { $0.cancel() }
        }
    }

    func setBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        backgroundEventsCompletionHandler = handler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = transferID(for: downloadTask), let intent = storage.intent(for: id) else { downloadTask.cancel(); return }
        let limit = min(PackageLimits.maximumDownloadBytes, intent.release.size)
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            storage.save(outcome: PackageTransferOutcome(result: .failed, finalURL: nil, statusCode: nil, receivedBytes: totalBytesWritten, failureCode: .sizeLimit), for: id)
            downloadTask.cancel()
            return
        }
        lock.lock()
        let callback = contexts[id]?.onProgress
        lock.unlock()
        callback?(DownloadProgress(receivedBytes: totalBytesWritten, expectedBytes: intent.release.size))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = transferID(for: downloadTask), let intent = storage.intent(for: id),
              let response = downloadTask.response as? HTTPURLResponse,
              urlPolicy.allows(response.url) else {
            if let id = transferID(for: downloadTask) {
                storage.removeTemporaryFile(for: id)
                storage.save(outcome: PackageTransferOutcome(result: .failed, finalURL: nil, statusCode: nil, receivedBytes: nil, failureCode: .insecureURL), for: id)
                complete(id, result: .failure(PackageDownloadFailure(.insecureURL)))
            }
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            storage.removeTemporaryFile(for: id)
            storage.save(outcome: PackageTransferOutcome(result: .failed, finalURL: nil, statusCode: response.statusCode, receivedBytes: nil, failureCode: .http), for: id)
            complete(id, result: .failure(PackageDownloadFailure(.http, httpStatus: response.statusCode)))
            return
        }
        do {
            let maximumBytes = min(PackageLimits.maximumDownloadBytes, intent.release.size)
            let responseBytes = try storage.storeDownloadedTemporaryFile(from: location, transferID: id, maximumBytes: maximumBytes)
            guard responseBytes <= maximumBytes else { throw PackageDownloadFailure(.sizeLimit) }
            let outcome = PackageTransferOutcome(result: .completed, finalURL: response.url, statusCode: response.statusCode, receivedBytes: responseBytes, failureCode: nil)
            storage.save(outcome: outcome, for: id)
            do { complete(id, result: .success(try self.response(for: outcome, intent: intent, destinationURL: storage.temporaryURL(for: id)))) }
            catch { complete(id, result: .failure(error)) }
        } catch let failure as PackageDownloadFailure {
            storage.removeTemporaryFile(for: id)
            storage.save(outcome: PackageTransferOutcome(result: .failed, finalURL: nil, statusCode: nil, receivedBytes: nil, failureCode: failure.code), for: id)
            complete(id, result: .failure(failure))
        } catch {
            storage.removeTemporaryFile(for: id)
            let failure = PackageDownloadFailure(PackageStorage.isInsufficientStorage(error) ? .insufficientStorage : .network)
            storage.save(outcome: PackageTransferOutcome(result: .failed, finalURL: nil, statusCode: nil, receivedBytes: nil, failureCode: failure.code), for: id)
            complete(id, result: .failure(failure))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let id = transferID(for: task) else {
            completionHandler(nil)
            return
        }
        guard urlPolicy.allows(response.url), urlPolicy.allows(request.url) else {
            storage.save(outcome: PackageTransferOutcome(result: .failed, finalURL: nil, statusCode: nil, receivedBytes: nil, failureCode: .insecureURL), for: id)
            task.cancel()
            completionHandler(nil)
            return
        }
        guard storage.consumeRedirectBudget(for: id) else {
            storage.save(outcome: PackageTransferOutcome(result: .failed, finalURL: nil, statusCode: nil, receivedBytes: nil, failureCode: .redirectLimit), for: id)
            task.cancel()
            completionHandler(nil)
            return
        }
        var safeRequest = request
        safeRequest.httpShouldHandleCookies = false
        if response.url?.host?.caseInsensitiveCompare(request.url?.host ?? "") != .orderedSame {
            ["Authorization", "Cookie", "Proxy-Authorization", "X-Api-Key"].forEach { safeRequest.setValue(nil, forHTTPHeaderField: $0) }
        }
        completionHandler(safeRequest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = transferID(for: task) else { return }
        if let error {
            let existing = storage.outcome(for: id)
            let failure: PackageDownloadFailure
            if existing?.result == .failed, let code = existing?.failureCode {
                failure = PackageDownloadFailure(code, httpStatus: existing?.statusCode)
            } else {
                failure = Self.map(error)
                storage.save(outcome: PackageTransferOutcome(result: .failed, finalURL: nil, statusCode: nil, receivedBytes: nil, failureCode: failure.code), for: id)
            }
            complete(id, result: .failure(failure))
            return
        }
        guard let context = context(for: id) else { return }
        guard let outcome = storage.outcome(for: id) else {
            complete(id, result: .failure(PackageDownloadFailure(.network)))
            return
        }
        do { complete(id, result: .success(try response(for: outcome, intent: context.intent, destinationURL: context.destinationURL))) }
        catch { complete(id, result: .failure(error)) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }

    private func attach(_ task: URLSessionDownloadTask, to id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard var context = contexts[id] else { task.cancel(); return }
        context.taskIdentifier = task.taskIdentifier
        contexts[id] = context
        transfersByTask[task.taskIdentifier] = id
    }

    private func transferID(for task: URLSessionTask) -> UUID? {
        if let id = task.taskDescription.flatMap(UUID.init(uuidString:)) { return id }
        lock.lock(); defer { lock.unlock() }
        return transfersByTask[task.taskIdentifier]
    }

    private func isCancelled(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return contexts[id]?.cancelled ?? false
    }

    private func context(for id: UUID) -> Context? {
        lock.lock(); defer { lock.unlock() }
        return contexts[id]
    }

    private func complete(_ id: UUID, result: Result<PackageTransferResponse, Error>) {
        lock.lock()
        guard var context = contexts.removeValue(forKey: id), let continuation = context.continuation else {
            lock.unlock()
            return
        }
        context.continuation = nil
        if let taskIdentifier = context.taskIdentifier { transfersByTask.removeValue(forKey: taskIdentifier) }
        lock.unlock()
        continuation.resume(with: result)
    }

    private func response(for outcome: PackageTransferOutcome, intent: PackageDownloadIntent, destinationURL: URL) throws -> PackageTransferResponse {
        guard outcome.result == .completed else {
            throw PackageDownloadFailure(outcome.failureCode ?? .network, httpStatus: outcome.statusCode)
        }
        guard let finalURL = outcome.finalURL, urlPolicy.allows(finalURL),
              let statusCode = outcome.statusCode, (200..<300).contains(statusCode),
              let bytes = outcome.receivedBytes, bytes <= PackageLimits.maximumDownloadBytes,
              storage.temporaryFileIsOwned(destinationURL, transferID: intent.id) else {
            throw PackageDownloadFailure(.invalidArchive)
        }
        return PackageTransferResponse(fileURL: destinationURL, finalURL: finalURL, statusCode: statusCode, receivedBytes: bytes)
    }

    private static func map(_ error: Error) -> PackageDownloadFailure {
        if error is CancellationError { return PackageDownloadFailure(.cancelled) }
        if let urlError = error as? URLError {
            return PackageDownloadFailure(urlError.code == .timedOut ? .timeout : (urlError.code == .cancelled ? .cancelled : .network))
        }
        if PackageStorage.isInsufficientStorage(error) { return PackageDownloadFailure(.insufficientStorage) }
        return PackageDownloadFailure(.network)
    }
}
