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

    @Test("Crew names retain their person IDs")
    func crewIdentity() async {
        TMDBStubProtocol.status = 200
        TMDBStubProtocol.body = Data(#"{"credits":{"crew":[{"id":123,"name":"A Writer","job":"Writer"}]}}"#.utf8)
        let result = await client().enrichment(tmdbId: 10, type: .movie, apiKey: "test")
        #expect(result?.crew.first?.id == 123)
        #expect(result?.crew.first?.character == "Writer")
    }

    @Test("Filmography includes crew work and keeps movie and TV IDs distinct")
    func crewFilmography() async {
        TMDBStubProtocol.status = 200
        TMDBStubProtocol.body = Data(#"{"cast":[],"crew":[{"id":1,"title":"Film","media_type":"movie","job":"Director"},{"id":1,"title":"Film","media_type":"movie","job":"Writer"},{"id":1,"name":"Series","media_type":"tv","job":"Writer"}]}"#.utf8)
        let credits = await client().credits(personId: 123, apiKey: "test")
        #expect(credits.count == 2)
        #expect(credits.contains { $0.isSeries })
        #expect(credits.contains { !$0.isSeries })
    }

    @Test("Ambiguous names are not guessed")
    func ambiguousPerson() async {
        TMDBStubProtocol.status = 200
        TMDBStubProtocol.body = Data(#"{"results":[{"id":1,"name":"Alex"},{"id":2,"name":"Alex"}]}"#.utf8)
        let person = await client().person(named: "Alex", apiKey: "test")
        #expect(person == nil)
    }

    @Test("Credit scene tags distinguish during, after, both, and unreported",
          arguments: [[], [179430], [179431], [179430, 179431], [123]])
    func creditScenes(ids: [Int]) async throws {
        TMDBStubProtocol.status = 200
        TMDBStubProtocol.body = try JSONSerialization.data(withJSONObject: ["keywords": ["keywords": ids.map { ["id": $0] }]])
        let result = await client().enrichment(tmdbId: 10, type: .movie, apiKey: "test")
        let expected: TMDBClient.CreditScenes? = ids.contains(179430)
            ? (ids.contains(179431) ? .duringAndAfter : .after)
            : (ids.contains(179431) ? .during : nil)
        #expect(result?.creditScenes == expected)
        let series = await client().enrichment(tmdbId: 10, type: .series, apiKey: "test")
        #expect(series?.creditScenes == nil)
    }

    @Test("Person pages merge all roles, retain full credits, and combine filters")
    func personFilmography() async throws {
        TMDBStubProtocol.status = 200
        var cast: [[String: Any]] = (1...45).map {
            ["id": $0, "title": "Film \($0)", "media_type": "movie", "character": "Character",
             "genre_ids": [35], "release_date": "2000-01-01", "popularity": Double($0)]
        }
        cast.append(["id": 1, "name": "Series", "media_type": "tv", "genre_ids": [18]])
        TMDBStubProtocol.body = try JSONSerialization.data(withJSONObject: [
            "biography": "A biography", "profile_path": "/portrait.jpg", "known_for_department": "Acting",
            "combined_credits": ["cast": cast, "crew": [
                ["id": 1, "title": "Film 1", "media_type": "movie", "job": "Director", "department": "Directing"],
                ["id": 1, "title": "Film 1", "media_type": "movie", "job": "Screenplay", "department": "Writing"],
                ["id": 2, "title": "Film 2", "media_type": "movie", "job": "Assistant Director", "department": "Directing"]
            ]]
        ])
        let profile = try await client().personProfile(personId: 1, apiKey: "test")
        #expect(profile.biography == "A biography")
        #expect(profile.profileURL?.absoluteString == "https://image.tmdb.org/t/p/w342/portrait.jpg")
        #expect(profile.credits.count == 46)
        let film = try #require(profile.credits.first { $0.id == "movie:1" })
        #expect(film.roles == [.acting, .directing, .writing])
        #expect(film.caption(for: nil).contains("Screenplay"))
        #expect(film.caption(for: .directing) == "Director")
        let directedComedy = PersonCredit.filtered(profile.credits, role: .directing, genreID: 35, sort: .popular)
        #expect(directedComedy.map(\.id) == ["movie:1"])
        #expect(PersonCredit.filtered(profile.credits, role: .writing, genreID: 18, sort: .newest).isEmpty)
        for sort in [FilmographySort.newest, .oldest] {
            #expect(PersonCredit.filtered(profile.credits, role: nil, genreID: nil, sort: sort).last?.id == "tv:1")
        }
    }

    @Test("Person page request failures remain errors, not empty filmographies")
    func personRequestFailure() async {
        TMDBStubProtocol.status = 503
        defer { TMDBStubProtocol.status = 200 }
        do {
            _ = try await client().personProfile(personId: 1, apiKey: "test")
            Issue.record("Expected failure")
        } catch { }
    }

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
