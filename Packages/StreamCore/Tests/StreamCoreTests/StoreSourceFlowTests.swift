import Foundation
import Testing
@testable import StreamCore

private final class StoreSourceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "source-flow.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        if path == "/private-config/manifest.json" {
            body = #"{"id":"test.source","name":"Test source","types":["movie","series"],"resources":["stream"],"catalogs":[]}"#
        } else if path == "/private-config/stream/movie/tt1234567.json" || path == "/private-config/stream/series/tt1234567:2:3.json" {
            body = #"{"streams":[{"name":"Test media","url":"https://media.example/video.mp4"}]}"#
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct StoreSourceFlowTests {
    @Test func configuredSourceRetainsPathAndResolvesMoviesAndEpisodes() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StoreSourceProtocol.self]
        let client = AddonClient(session: URLSession(configuration: config))
        let addon = try await client.installAddon(from: "https://source-flow.test/private-config/manifest.json")
        #expect(addon.supports(.stream, type: .movie, id: "tt1234567"))
        let movie = try await client.streams(from: addon, type: .movie, id: "tt1234567")
        let episode = try await client.streams(from: addon, type: .series, id: "tt1234567:2:3")
        #expect(movie.first?.playbackURL?.host == "media.example")
        #expect(episode.first?.addonId == "test.source")
    }
}
