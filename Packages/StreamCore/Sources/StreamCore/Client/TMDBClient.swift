import Foundation
import os

/// Supplementary artwork the addon protocol does not carry.
///
/// Cinemeta provides text credits but no network, studio, or cast imagery. TMDB
/// does, and every Cinemeta item already includes a `moviedb_id`, so the lookup
/// needs no matching heuristics.
///
/// Deliberately optional: the app works fully without a key, and every call fails
/// soft. TMDB is an enrichment, never a dependency.
public actor TMDBClient {
    public struct Company: Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var logoPath: String?

        /// Logos are mostly white-on-transparent, which suits a dark UI.
        public var logoURL: URL? {
            guard let logoPath else { return nil }
            return URL(string: "https://image.tmdb.org/t/p/w300\(logoPath)")
        }
    }

    public struct CastMember: Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var character: String?
        public var profilePath: String?

        public var profileURL: URL? {
            guard let profilePath else { return nil }
            return URL(string: "https://image.tmdb.org/t/p/w185\(profilePath)")
        }
    }

    public enum CreditScenes: String, Hashable, Sendable {
        case during, after, duringAndAfter

        public var label: String {
            switch self {
            case .during: "Mid-credits scene"
            case .after: "After-credits scene"
            case .duringAndAfter: "Mid- & after-credits scenes"
            }
        }
    }

    public struct Enrichment: Hashable, Sendable {
        /// TV networks, or production companies for films.
        public var companies: [Company] = []
        public var cast: [CastMember] = []
        public var crew: [CastMember] = []
        public var tagline: String?
        /// Age classification for the viewer's own region — "PG-13", "TV-MA", "15".
        ///
        /// Cinemeta carries no certification at all, so this is the only source.
        /// Films and series report it under different keys and shapes, which is why
        /// the two are unpicked separately below.
        public var certification: String?
        /// Nil means unreported, not confirmation that no extra scene exists.
        public var creditScenes: CreditScenes?
    }

    /// A movie or series as TMDB describes it.
    ///
    /// Carries a TMDB id, not an IMDb one, so it cannot be opened directly — the
    /// addon protocol is keyed on `tt…`. Resolution happens on tap, for the single
    /// title chosen, rather than eagerly for a whole shelf.
    public struct TMDBTitle: Hashable, Sendable, Identifiable {
        public var id: Int
        public var title: String
        public var posterPath: String?
        public var year: String?
        public var character: String?
        public var isSeries: Bool

        public var posterURL: URL? {
            guard let posterPath else { return nil }
            return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
        }
    }

    private var themeCache: [String: (Date, [TMDBTitle])] = [:]

    /// Keyword matches are exact so an unknown theme never becomes an unfiltered shelf.
    public func titles(for theme: GenreTheme, apiKey: String) async throws -> [TMDBTitle] {
        guard !apiKey.isEmpty else { return [] }
        if let cached = themeCache[theme.id], Date().timeIntervalSince(cached.0) < 3600 {
            return cached.1
        }
        let page = try await browse(theme: theme, apiKey: apiKey)
        themeCache[theme.id] = (Date(), page.titles)
        return page.titles
    }

    public struct MoviePage: Sendable {
        public var titles: [TMDBTitle]
        public var hasMore: Bool
    }

    public struct BrowseOptions: Hashable, Sendable {
        public var sort = "popularity.desc"
        public var decade = 0
        public var runtime = 0
        public var rating = 0
        public init() {}
        public var queryItems: [URLQueryItem] {
            var result = [URLQueryItem(name: "sort_by", value: sort),
                          URLQueryItem(name: "vote_count.gte", value: sort == "vote_average.desc" ? "100" : "10")]
            if decade > 0 {
                result.append(URLQueryItem(name: "primary_release_date.gte", value: "\(decade)-01-01"))
            }
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            result.append(URLQueryItem(name: "primary_release_date.lte", value: decade > 0 ? min(today, "\(decade + 9)-12-31") : today))
            if runtime > 0 {
                result.append(URLQueryItem(name: "with_runtime.gte", value: "1"))
                result.append(URLQueryItem(name: "with_runtime.lte", value: String(runtime)))
            }
            if rating > 0 { result.append(URLQueryItem(name: "vote_average.gte", value: String(rating))) }
            return result
        }
    }

    private var keywordIDs: [String: Int] = [:]

    public func browse(theme: GenreTheme, options: BrowseOptions = .init(), page: Int = 1, apiKey: String) async throws -> MoviePage {
        guard !apiKey.isEmpty else { return MoviePage(titles: [], hasMore: false) }
        func fetch(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
            var url = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
            url.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + query
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 12
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            return data
        }
        let keywordID: Int
        if let cached = keywordIDs[theme.keyword] { keywordID = cached }
        else {
            struct Keywords: Decodable {
                struct Entry: Decodable { let id: Int; let name: String }
                let results: [Entry]
            }
            let data = try await fetch("search/keyword", [URLQueryItem(name: "query", value: theme.keyword)])
            let keywords = try JSONDecoder().decode(Keywords.self, from: data)
            guard let keyword = keywords.results.first(where: { $0.name.caseInsensitiveCompare(theme.keyword) == .orderedSame }) else {
                return MoviePage(titles: [], hasMore: false)
            }
            keywordID = keyword.id
            keywordIDs[theme.keyword] = keyword.id
        }
        try Task.checkCancellation()
        let data = try await fetch("discover/movie", options.queryItems + [
            URLQueryItem(name: "with_genres", value: String(theme.genreID)),
            URLQueryItem(name: "with_keywords", value: String(keywordID)),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "include_video", value: "false"),
            URLQueryItem(name: "page", value: String(page))
        ])
        let payload = try JSONDecoder().decode(TMDBDiscoverResponse.self, from: data)
        var seen = Set<Int>()
        let titles = (payload.results ?? []).filter { seen.insert($0.id).inserted }.map {
            TMDBTitle(id: $0.id, title: $0.title ?? $0.name ?? "Untitled", posterPath: $0.posterPath,
                      year: $0.releaseDate.map { String($0.prefix(4)) }, character: nil, isSeries: false)
        }
        try Task.checkCancellation()
        return MoviePage(titles: titles, hasMore: page < min(payload.totalPages ?? 1, 500))
    }

    private let session: URLSession
    private let logger = Logger(subsystem: "com.stream.core", category: "TMDB")

    /// Whose classification to show. A US rating on a UK viewer's screen is the
    /// wrong answer to "can my kids watch this", so the device's own region wins
    /// and the US is only the fallback for regions TMDB has no board for.
    private static var preferredRegion: String {
        Locale.current.region?.identifier ?? "US"
    }

    /// Cached per TMDB id — detail pages are revisited and this data never changes
    /// within a session.
    private var cache: [String: Enrichment] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func enrichment(tmdbId: Int, type: MediaType, apiKey: String) async -> Enrichment? {
        guard !apiKey.isEmpty else { return nil }

        let path = type == .series ? "tv" : "movie"
        let cacheKey = "\(path)/\(tmdbId)"
        if let cached = cache[cacheKey] { return cached }

        // Fetch supplementary movie facts in the existing detail request.
        let ratings = type == .series ? "content_ratings" : "release_dates"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)/\(tmdbId)")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "append_to_response", value: type == .movie ? "credits,\(ratings),keywords" : "credits,\(ratings)")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                logger.debug("TMDB returned \(http.statusCode) for \(cacheKey)")
                return nil
            }

            let payload = try JSONDecoder().decode(TMDBResponse.self, from: data)
            let result = Enrichment(
                // Series carry `networks`; films carry `production_companies`.
                companies: (payload.networks ?? payload.productionCompanies ?? [])
                    .map { Company(id: $0.id, name: $0.name, logoPath: $0.logoPath) },
                cast: (payload.credits?.cast ?? [])
                    .map { CastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profilePath) },
                crew: (payload.credits?.crew ?? []).map { CastMember(id: $0.id, name: $0.name, character: $0.job, profilePath: $0.profilePath) },
                tagline: payload.tagline?.isEmpty == false ? payload.tagline : nil,
                certification: payload.certification(for: Self.preferredRegion),
                creditScenes: type == .movie ? payload.creditScenes : nil
            )

            cache[cacheKey] = result
            return result
        } catch {
            logger.debug("TMDB lookup failed for \(cacheKey): \(error.localizedDescription)")
            return nil
        }
    }
}

extension TMDBClient {
    /// Search is only a fallback when title credits do not supply a person ID.
    public func person(named name: String, apiKey: String) async -> CastMember? {
        guard !apiKey.isEmpty else { return nil }
        var url = URLComponents(string: "https://api.themoviedb.org/3/search/person")!
        url.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "query", value: name), URLQueryItem(name: "include_adult", value: "false")]
        struct Response: Decodable { let results: [TMDBCastMember] }
        do {
            let (data, response) = try await session.data(from: url.url!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let matches = try JSONDecoder().decode(Response.self, from: data).results.filter {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            guard matches.count == 1, let person = matches.first else { return nil }
            return CastMember(id: person.id, name: person.name, character: nil, profilePath: person.profilePath)
        } catch { return nil }
    }

    public func personProfile(personId: Int, apiKey: String) async throws -> PersonProfile {
        guard !apiKey.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var url = URLComponents(string: "https://api.themoviedb.org/3/person/\(personId)")!
        url.queryItems = [URLQueryItem(name: "api_key", value: apiKey),
                          URLQueryItem(name: "append_to_response", value: "combined_credits")]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(TMDBPersonResponse.self, from: data)
        try Task.checkCancellation()
        return PersonProfile(biography: payload.biography?.trimmingCharacters(in: .whitespacesAndNewlines),
                             department: payload.knownForDepartment, profilePath: payload.profilePath,
                             credits: payload.combinedCredits.merged)
    }

    /// A person's filmography, most popular first.
    public func credits(personId: Int, apiKey: String) async -> [TMDBTitle] {
        guard !apiKey.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.themoviedb.org/3/person/\(personId)/combined_credits")
        components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components?.url else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            let payload = try JSONDecoder().decode(TMDBCombinedCredits.self, from: data)

            return payload.merged.map(\.title)
        } catch {
            logger.debug("TMDB person credits failed for \(personId): \(error.localizedDescription)")
            return []
        }
    }

    /// What TMDB thinks is actually like this title.
    ///
    /// The detail page used to fill "More like this" by asking an addon for the
    /// title's *first* genre, which for anything tagged "Drama, Horror" produced a
    /// drama shelf — The Devil's Candy offering Shawshank and Interstellar. TMDB
    /// keeps real recommendations built from what people actually watch together,
    /// and the id needed to ask for them is already in every Cinemeta record.
    ///
    /// `recommendations` is the curated set and is sometimes empty; `similar` is
    /// generated from keywords and genres and almost never is. Trying the good one
    /// first and falling back costs a second request only when the first is bare.
    public func recommendations(tmdbId: Int, type: MediaType, apiKey: String) async -> [TMDBTitle] {
        guard !apiKey.isEmpty else { return [] }
        let path = type == .series ? "tv" : "movie"

        for endpoint in ["recommendations", "similar"] {
            var components = URLComponents(
                string: "https://api.themoviedb.org/3/\(path)/\(tmdbId)/\(endpoint)"
            )
            components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
            guard let url = components?.url else { continue }

            do {
                let (data, _) = try await session.data(from: url)
                let payload = try JSONDecoder().decode(TMDBDiscoverResponse.self, from: data)
                var seen = Set<Int>()
                let titles = (payload.results ?? [])
                    .filter { seen.insert($0.id).inserted }
                    .map { entry in
                        TMDBTitle(
                            id: entry.id,
                            title: entry.title ?? entry.name ?? "Untitled",
                            posterPath: entry.posterPath,
                            year: (entry.releaseDate ?? entry.firstAirDate)
                                .flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
                            character: nil,
                            isSeries: type == .series
                        )
                    }
                    // A tile with no artwork is a grey box in a row of posters.
                    .filter { $0.posterPath != nil }
                if !titles.isEmpty { return Array(titles.prefix(20)) }
            } catch {
                logger.debug("TMDB \(endpoint) failed for \(tmdbId): \(error.localizedDescription)")
            }
        }
        return []
    }

    /// Films currently in cinemas.
    ///
    /// The one shelf not sourced from an addon: no addon publishes a theatrical
    /// window, and TMDB maintains it per-region.
    public func nowPlaying(apiKey: String, region: String? = nil) async -> [TMDBTitle] {
        guard !apiKey.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.themoviedb.org/3/movie/now_playing")
        var query = [URLQueryItem(name: "api_key", value: apiKey)]
        // Theatrical releases are regional; default to the device's own locale.
        let resolvedRegion = region ?? Locale.current.region?.identifier
        if let resolvedRegion {
            query.append(URLQueryItem(name: "region", value: resolvedRegion))
        }
        components?.queryItems = query
        guard let url = components?.url else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            let payload = try JSONDecoder().decode(TMDBDiscoverResponse.self, from: data)

            var seen = Set<Int>()
            return (payload.results ?? [])
                .filter { seen.insert($0.id).inserted }
                .map { entry in
                    TMDBTitle(
                        id: entry.id,
                        title: entry.title ?? entry.name ?? "Untitled",
                        posterPath: entry.posterPath,
                        year: entry.releaseDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
                        character: nil,
                        isSeries: false
                    )
                }
        } catch {
            logger.debug("TMDB now playing failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Resolves a TMDB id to an IMDb id.
    ///
    /// Needed because the addon protocol is keyed on IMDb ids (`tt…`) while TMDB
    /// credits only carry TMDB ids — without this, a filmography can be displayed
    /// but not opened.
    public func imdbId(tmdbId: Int, isSeries: Bool, apiKey: String) async -> String? {
        guard !apiKey.isEmpty else { return nil }

        let path = isSeries ? "tv" : "movie"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)/\(tmdbId)/external_ids")
        components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components?.url else { return nil }

        guard let (data, _) = try? await session.data(from: url),
              let payload = try? JSONDecoder().decode(TMDBExternalIds.self, from: data),
              let imdb = payload.imdbId, imdb.hasPrefix("tt")
        else { return nil }

        return imdb
    }
}

// MARK: - Wire format

private struct TMDBPersonResponse: Decodable {
    var biography: String?
    var knownForDepartment: String?
    var profilePath: String?
    var combinedCredits: TMDBCombinedCredits
    enum CodingKeys: String, CodingKey {
        case biography
        case knownForDepartment = "known_for_department"
        case profilePath = "profile_path"
        case combinedCredits = "combined_credits"
    }
}

private struct TMDBCombinedCredits: Decodable {
    var cast: [TMDBCreditEntry]?
    var crew: [TMDBCreditEntry]?

    var merged: [PersonCredit] {
        var result: [String: PersonCredit] = [:]
        for (entries, isCast) in [(cast ?? [], true), (crew ?? [], false)] {
            for entry in entries {
                guard entry.mediaType == nil || entry.mediaType == "movie" || entry.mediaType == "tv" else { continue }
                let isSeries = entry.mediaType == "tv"
                let id = "\(isSeries ? "tv" : "movie"):\(entry.id)"
                let date = (entry.releaseDate ?? entry.firstAirDate).flatMap { $0.count >= 4 ? $0 : nil }
                let role: PersonRole = isCast ? .acting : PersonCredit.role(for: entry.job, department: entry.department)
                var credit = result[id] ?? PersonCredit(
                    title: TMDBClient.TMDBTitle(id: entry.id, title: entry.title ?? entry.name ?? "Untitled",
                        posterPath: entry.posterPath, year: date.map { String($0.prefix(4)) },
                        character: entry.character ?? entry.job, isSeries: isSeries),
                    roles: [], characters: [], jobs: [], genreIDs: [], popularity: 0, releaseDate: date)
                credit.roles.insert(role)
                credit.genreIDs.formUnion(entry.genreIDs ?? [])
                credit.popularity = max(credit.popularity, entry.popularity ?? 0)
                if credit.releaseDate == nil { credit.releaseDate = date; credit.title.year = date.map { String($0.prefix(4)) } }
                if credit.title.posterPath == nil { credit.title.posterPath = entry.posterPath }
                if isCast, let character = entry.character?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !character.isEmpty, !credit.characters.contains(character) { credit.characters.append(character) }
                if !isCast, let job = entry.job?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !job.isEmpty, !credit.jobs.contains(job) { credit.jobs.append(job) }
                result[id] = credit
            }
        }
        return PersonCredit.filtered(Array(result.values), role: nil, genreID: nil, sort: .popular)
    }
}

private struct TMDBDiscoverResponse: Decodable {
    var results: [TMDBCreditEntry]?
    var totalPages: Int?
    enum CodingKeys: String, CodingKey { case results; case totalPages = "total_pages" }
}

private struct TMDBCreditEntry: Decodable {
    var job: String?
    var department: String?
    var genreIDs: [Int]?
    var id: Int
    var title: String?
    var name: String?
    var character: String?
    var posterPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var mediaType: String?
    var popularity: Double?

    private enum CodingKeys: String, CodingKey {
        case id, title, name, character, popularity, job, department
        case genreIDs = "genre_ids"
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case mediaType = "media_type"
    }
}

private struct TMDBExternalIds: Decodable {
    var imdbId: String?

    private enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
    }
}

private struct TMDBResponse: Decodable {
    var tagline: String?
    var networks: [TMDBCompany]?
    var productionCompanies: [TMDBCompany]?
    var credits: TMDBCredits?
    var contentRatings: TMDBRegionList<TMDBContentRating>?
    var releaseDates: TMDBRegionList<TMDBReleaseDateGroup>?
    var keywords: TMDBMovieKeywords?

    var creditScenes: TMDBClient.CreditScenes? {
        let ids = Set((keywords?.keywords ?? []).map(\.id))
        switch (ids.contains(179431), ids.contains(179430)) {
        case (true, true): return .duringAndAfter
        case (true, false): return .during
        case (false, true): return .after
        case (false, false): return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tagline, networks, credits, keywords
        case productionCompanies = "production_companies"
        case contentRatings = "content_ratings"
        case releaseDates = "release_dates"
    }

    /// The classification for `region`, falling back to the US.
    ///
    /// TMDB lets any contributor add a row, so a region can carry several entries
    /// and blank ones are common — every candidate is trimmed and empties dropped
    /// rather than surfacing an empty badge.
    func certification(for region: String) -> String? {
        func pick<T>(_ list: TMDBRegionList<T>?, _ value: (T) -> [String]) -> String? {
            guard let results = list?.results else { return nil }
            for wanted in [region, "US"] {
                let found = results
                    .filter { $0.iso31661 == wanted }
                    .flatMap { value($0.payload) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                if let found { return found }
            }
            return nil
        }
        if let series = pick(contentRatings, { [$0.rating ?? ""] }) { return series }
        // Films list one entry per release window (cinema, digital, physical) and
        // only some carry a certification.
        return pick(releaseDates, { ($0.releaseDates ?? []).map { $0.certification ?? "" } })
    }
}

/// TMDB's `{ "results": [ { "iso_3166_1": "US", … } ] }` shape, whose payload key
/// differs per endpoint.
private struct TMDBRegionList<Payload: Decodable>: Decodable {
    struct Entry: Decodable {
        var iso31661: String?
        var payload: Payload

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            iso31661 = try container.decodeIfPresent(String.self, forKey: .iso31661)
            payload = try Payload(from: decoder)
        }

        private enum CodingKeys: String, CodingKey {
            case iso31661 = "iso_3166_1"
        }
    }

    var results: [Entry]?
}

private struct TMDBContentRating: Decodable {
    var rating: String?
}

private struct TMDBReleaseDateGroup: Decodable {
    var releaseDates: [TMDBReleaseDate]?

    private enum CodingKeys: String, CodingKey {
        case releaseDates = "release_dates"
    }
}

private struct TMDBReleaseDate: Decodable {
    var certification: String?
}

private struct TMDBCompany: Decodable {
    var id: Int
    var name: String
    var logoPath: String?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case logoPath = "logo_path"
    }
}

private struct TMDBCredits: Decodable {
    var cast: [TMDBCastMember]?
    var crew: [TMDBCastMember]?
}

private struct TMDBCastMember: Decodable {
    var job: String?
    var department: String?
    var genreIDs: [Int]?
    var id: Int
    var name: String
    var character: String?
    var profilePath: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, character, job
        case profilePath = "profile_path"
    }
}

private struct TMDBMovieKeywords: Decodable {
    struct Keyword: Decodable { var id: Int }
    var keywords: [Keyword]?
}
