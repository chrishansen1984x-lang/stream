import Foundation
import Testing
@testable import StreamCore

private final class GatedScreenProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: GatedScreenProtocol?
    nonisolated(unsafe) private static var holding = true
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { held = nil; holding = true; count = 0 } }
    static func release() {
        let request = lock.withLock { holding = false; defer { held = nil }; return held }
        request?.respond()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let shouldHold = Self.lock.withLock {
            Self.count += 1
            if Self.holding { Self.held = self; return true }
            return false
        }
        if !shouldHold { respond() }
    }
    private func respond() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ScreenConcurrencyTests {
    @Test func overlappingFlushAndReplacementKeepTheNewestEvent() async throws {
        GatedScreenProtocol.reset()
        let name = "stream.test.concurrent." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GatedScreenProtocol.self]
        let scrobbler = ScreenScrobbler(configuration: .init(endpoint: URL(string: "https://example.test")!, token: "fake"), session: URLSession(configuration: config), defaults: defaults)
        async let first: Void = scrobbler.record(videoId: "qa", progress: 0.2)
        for _ in 0..<100 {
            if GatedScreenProtocol.requestCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(GatedScreenProtocol.requestCount == 1)
        await scrobbler.flush()
        await scrobbler.record(videoId: "qa", progress: 0.8)
        GatedScreenProtocol.release()
        await first
        #expect(GatedScreenProtocol.requestCount == 2)
        #expect(await scrobbler.queueDepth == 0)
    }
}
