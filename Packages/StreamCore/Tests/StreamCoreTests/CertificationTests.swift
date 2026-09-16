import Testing
import Foundation
@testable import StreamCore

/// Replays a canned TMDB body for whatever is asked.
private final class TMDBStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data("{}".utf8)
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized: the stub keeps its scripted body in static storage, and Swift
/// Testing runs cases in parallel by default.
@Suite("TMDB age classification", .serialized)
struct CertificationTests {

    private func client() -> TMDBClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TMDBStubProtocol.self]
        return TMDBClient(session: URLSession(configuration: configuration))
    }

    private func certification(
        _ json: String, type: MediaType, id: Int = Int.random(in: 1...1_000_000)
    ) async -> String? {
        TMDBStubProtocol.body = Data(json.utf8)
        // A fresh id every call: `TMDBClient` caches per id for the session, so a
        // reused one would return the previous case's answer.
        return await client().enrichment(tmdbId: id, type: type, apiKey: "k")?.certification
    }

    @Test("A series rating is read from content_ratings")
    func seriesRating() async {
        let value = await certification("""
        {"content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-MA"}]}}
        """, type: .series)
        #expect(value == "TV-MA")
    }

    @Test("A film rating is read from release_dates")
    func filmRating() async {
        let value = await certification("""
        {"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"R"}]}]}}
        """, type: .movie)
        #expect(value == "R")
    }

    /// The one that would ship a blank badge. TMDB lists a film once per release
    /// window — cinema, digital, physical — and only some carry a rating, with the
    /// unrated ones usually listed first.
    @Test("An empty certification is skipped for a later one that has a value")
    func skipsEmptyWindows() async {
        let value = await certification("""
        {"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[
          {"certification":""},{"certification":"  "},{"certification":"PG-13"}
        ]}]}}
        """, type: .movie)
        #expect(value == "PG-13")
    }

    @Test("A region with only blank entries falls through to the US")
    func fallsBackToUS() async {
        // The device region is whatever the test host reports, so this asserts the
        // fallback rather than the preference: a region that is present but blank
        // must not shadow a usable US rating.
        let value = await certification("""
        {"release_dates":{"results":[
          {"iso_3166_1":"ZZ","release_dates":[{"certification":""}]},
          {"iso_3166_1":"US","release_dates":[{"certification":"NC-17"}]}
        ]}}
        """, type: .movie)
        #expect(value == "NC-17")
    }

    @Test("No classification anywhere yields nil rather than an empty chip")
    func missingIsNil() async {
        let none = await certification("""
        {"release_dates":{"results":[]}}
        """, type: .movie)
        #expect(none == nil)

        let blank = await certification("""
        {"content_ratings":{"results":[{"iso_3166_1":"US","rating":""}]}}
        """, type: .series)
        #expect(blank == nil)

        let absent = await certification("{\"tagline\":\"x\"}", type: .movie)
        #expect(absent == nil)
    }

    @Test("The rest of the enrichment still decodes when ratings are absent")
    func ratingsAreOptional() async {
        TMDBStubProtocol.body = Data("""
        {"tagline":"Some tagline","production_companies":[{"id":1,"name":"Studio"}]}
        """.utf8)
        let result = await client().enrichment(tmdbId: 424_242, type: .movie, apiKey: "k")
        #expect(result?.tagline == "Some tagline")
        #expect(result?.companies.first?.name == "Studio")
        #expect(result?.certification == nil)
    }
}
