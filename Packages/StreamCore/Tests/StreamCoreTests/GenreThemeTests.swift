import Foundation
import Testing
@testable import StreamCore

private final class ThemeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var keywordName = "slasher"
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests: [URL] = []
    static func reset(name: String = "slasher", code: Int = 200) {
        lock.withLock { keywordName = name; status = code; requests = [] }
    }
    static var urls: [URL] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (name, code) = Self.lock.withLock {
            Self.requests.append(request.url!)
            return (Self.keywordName, Self.status)
        }
        let payload = request.url!.path.contains("keyword")
            ? "{\"results\":[{\"id\":123,\"name\":\"\(name)\"}]}"
            : "{\"total_pages\":3,\"results\":[{\"id\":42,\"title\":\"A film\",\"release_date\":\"2000-01-01\"},{\"id\":42,\"title\":\"A film\"}]}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct GenreThemeTests {
    private func client() -> TMDBClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThemeProtocol.self]
        return TMDBClient(session: URLSession(configuration: config))
    }
    @Test func browsingFiltersStayWithinDecadeAndUseRatingThreshold() {
        var options = TMDBClient.BrowseOptions()
        options.decade = 1990
        options.sort = "vote_average.desc"
        options.runtime = 90
        options.rating = 7
        let query = options.queryItems
        #expect(query.contains(URLQueryItem(name: "primary_release_date.gte", value: "1990-01-01")))
        #expect(query.contains(URLQueryItem(name: "primary_release_date.lte", value: "1999-12-31")))
        #expect(query.contains(URLQueryItem(name: "vote_count.gte", value: "100")))
        #expect(query.contains(URLQueryItem(name: "with_runtime.lte", value: "90")))
        #expect(query.contains(URLQueryItem(name: "vote_average.gte", value: "7")))
    }
    @Test func paginationUsesRequestedPageAndReusesKeywordLookup() async throws {
        ThemeProtocol.reset()
        let api = client()
        let theme = GenreTheme.themes(for: "Horror")[0]
        let first = try await api.browse(theme: theme, apiKey: "test")
        #expect(first.hasMore)
        let last = try await api.browse(theme: theme, page: 3, apiKey: "test")
        #expect(!last.hasMore)
        #expect(ThemeProtocol.urls.count == 3)
        let query = URLComponents(url: ThemeProtocol.urls.last!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "page", value: "3")))
    }
    @Test func genreAliasesAndUnknownGenres() {
        #expect(GenreTheme.themes(for: "Sci-Fi") == GenreTheme.themes(for: "Science Fiction"))
        #expect(GenreTheme.themes(for: "unsupported").isEmpty)
        let horror = GenreTheme.themes(for: " Horror ")
        #expect(horror.count == 13)
        #expect(Set(horror.map(\.id)).count == horror.count)
    }
    @Test func exactKeywordAndGenreAreBothRequiredAndResultsAreCached() async throws {
        ThemeProtocol.reset()
        let api = client()
        let theme = GenreTheme.themes(for: "Horror")[0]
        let result = try await api.titles(for: theme, apiKey: "test")
        #expect(result.count == 1)
        #expect(result.first?.year == "2000")
        #expect(result.first?.isSeries == false)
        let params = URLComponents(url: ThemeProtocol.urls.last!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(params.contains(URLQueryItem(name: "with_genres", value: "27")))
        #expect(params.contains(URLQueryItem(name: "with_keywords", value: "123")))
        #expect(params.contains(URLQueryItem(name: "include_adult", value: "false")))
        _ = try await api.titles(for: theme, apiKey: "test")
        #expect(ThemeProtocol.urls.count == 2)
    }
    @Test func missingKeywordNeverFallsBackToGenericMovies() async throws {
        ThemeProtocol.reset(name: "unrelated")
        let titles = try await client().titles(for: GenreTheme.themes(for: "Horror")[0], apiKey: "test")
        #expect(titles.isEmpty)
        #expect(ThemeProtocol.urls.count == 1)
    }
    @Test func missingKeyMakesNoRequest() async throws {
        ThemeProtocol.reset()
        let titles = try await client().titles(for: GenreTheme.themes(for: "Horror")[0], apiKey: "")
        #expect(titles.isEmpty)
        #expect(ThemeProtocol.urls.isEmpty)
    }
    @Test func serverFailureIsReported() async {
        ThemeProtocol.reset(code: 503)
        do {
            _ = try await client().titles(for: GenreTheme.themes(for: "Horror")[0], apiKey: "test")
            Issue.record("Expected request failure")
        } catch { #expect(error is URLError) }
    }
}
