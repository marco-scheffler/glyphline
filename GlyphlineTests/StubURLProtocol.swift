import Foundation

/// Serves canned responses keyed by request path, so adapter tests never hit the network.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int
        var body: Data
    }

    private static let lock = NSLock()

    /// Keyed by path. A queue per path lets a test serve paginated pages.
    // Guarded by `lock`.
    nonisolated(unsafe) private static var stubs: [String: [Stub]] = [:]
    nonisolated(unsafe) private static var recordedURLs: [URL] = []

    static var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    /// Appends a stub to the queue for `path`.
    static func enqueue(path: String, statusCode: Int = 200, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        stubs[path, default: []].append(Stub(statusCode: statusCode, body: body))
    }

    /// Clears every queued stub and every recorded URL.
    ///
    /// Instances are created by the URL loading system, not by the test, so all
    /// state lives here as type state and must be reset explicitly between tests.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs = [:]
        recordedURLs = []
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func nextStub(for path: String, url: URL) -> Stub {
        lock.lock()
        defer { lock.unlock() }
        recordedURLs.append(url)

        if var queued = stubs[path], !queued.isEmpty {
            let stub = queued.removeFirst()
            stubs[path] = queued
            return stub
        }
        return Stub(statusCode: 404, body: Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let stub = Self.nextStub(for: url.path, url: url)

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
