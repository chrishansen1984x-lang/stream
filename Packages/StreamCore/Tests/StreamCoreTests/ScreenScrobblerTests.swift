import Testing
import Foundation
@testable import StreamCore

/// Answers every request with a scripted status, and records what it was sent.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var failWithError = false

    static func reset(status: Int = 200, failWithError: Bool = false) {
        self.status = status
        self.failWithError = failWithError
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.bodies.append(data)
        }
        if Self.failWithError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized: the stub protocol keeps its scripted status and captured bodies in
/// static storage, and Swift Testing runs cases in parallel by default — which had
/// them reading each other's responses.
@Suite("Screen scrobbler", .serialized)
struct ScreenScrobblerTests {

    private func makeScrobbler(suite: String, token: String = "scr_test") -> ScreenScrobbler {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ScreenScrobbler(
            configuration: .init(endpoint: URL(string: "https://example.test/watch-events")!,
                                 token: token),
            session: URLSession(configuration: configuration),
            defaults: defaults
        )
    }

    @Test("A finished watch is sent with the id Stream already has")
    func sendsProtocolId() async throws {
        StubProtocol.reset()
        let scrobbler = makeScrobbler(suite: "screen.send")
        await scrobbler.record(videoId: "tt0903747:1:5", title: "Breaking Bad")

        #expect(StubProtocol.bodies.count == 1)
        let sent = try JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: Any]
        let events = sent?["events"] as? [[String: Any]]
        #expect(events?.first?["id"] as? String == "tt0903747:1:5")
        #expect(events?.first?["title"] as? String == "Breaking Bad")
        // Screen validates watchedAt as a datetime with fractional seconds.
        let watchedAt = events?.first?["watchedAt"] as? String ?? ""
        #expect(watchedAt.contains("."), "watchedAt lacks fractional seconds: \(watchedAt)")
        #expect(await scrobbler.queueDepth == 0)
    }

    @Test("Offline keeps the watch for later rather than losing it")
    func offlineQueues() async {
        StubProtocol.reset(failWithError: true)
        let scrobbler = makeScrobbler(suite: "screen.offline")
        await scrobbler.record(videoId: "tt1", title: "Film")
        #expect(await scrobbler.queueDepth == 1, "an unsent watch was dropped")

        // Back online: the queued watch goes on the next flush.
        StubProtocol.reset()
        await scrobbler.flush()
        #expect(await scrobbler.queueDepth == 0)
        #expect(StubProtocol.bodies.count == 1)
    }

    @Test("Server and authentication failures keep pending watches")
    func retryPosture() async {
        StubProtocol.reset(status: 503)
        let server = makeScrobbler(suite: "screen.5xx")
        await server.record(videoId: "tt1")
        #expect(await server.queueDepth == 1, "a server error must not discard the watch")

        // Keep watches until the user repairs authentication.
        StubProtocol.reset(status: 401)
        let rejected = makeScrobbler(suite: "screen.4xx")
        await rejected.record(videoId: "tt1")
        #expect(await rejected.queueDepth == 1, "authentication failure lost a watch")
        #expect(await rejected.lastFailure != nil, "a rejected token said nothing")
    }

    @Test(arguments: [408, 429])
    func transientClientFailuresKeepWatches(status: Int) async {
        StubProtocol.reset(status: status)
        let scrobbler = makeScrobbler(suite: "screen.retry.\(status)")
        await scrobbler.record(videoId: "tt1")
        #expect(await scrobbler.queueDepth == 1)
    }

    @Test("The queue survives a relaunch")
    func queuePersists() async {
        StubProtocol.reset(failWithError: true)
        let scrobbler = makeScrobbler(suite: "screen.persist")
        await scrobbler.record(videoId: "tt1", title: "Film")

        // A television is turned off, not backgrounded. Same suite, new instance:
        // the queue has to come back off disk.
        let relaunched = makeScrobblerReusing(suite: "screen.persist")
        #expect(await relaunched.queueDepth == 1, "the queue did not survive a relaunch")
    }

    /// Same defaults suite, without wiping it — a relaunch, not a fresh install.
    private func makeScrobblerReusing(suite: String) -> ScreenScrobbler {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ScreenScrobbler(
            configuration: .init(endpoint: URL(string: "https://example.test/watch-events")!,
                                 token: "scr_test"),
            session: URLSession(configuration: configuration),
            defaults: UserDefaults(suiteName: suite)!
        )
    }

    @Test("The same watch queued twice is only sent once")
    func deduplicatesWhileQueued() async {
        StubProtocol.reset(failWithError: true)
        let scrobbler = makeScrobbler(suite: "screen.dedupe")
        let at = Date()
        await scrobbler.record(videoId: "tt1", title: "Film", watchedAt: at)
        await scrobbler.record(videoId: "tt1", title: "Film", watchedAt: at)
        #expect(await scrobbler.queueDepth == 1)
    }

    @Test("Nothing is posted without a token")
    func requiresToken() async {
        StubProtocol.reset()
        let scrobbler = makeScrobbler(suite: "screen.notoken", token: "")
        await scrobbler.record(videoId: "tt1")
        #expect(StubProtocol.bodies.isEmpty, "posted with an empty Bearer token")
        #expect(await scrobbler.queueDepth == 1, "the watch should wait for a token")
    }
}
