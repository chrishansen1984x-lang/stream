import Foundation

/// A catalog row item. Deliberately tolerant: only `id`, `type`, and `name` are
/// reliably present across addons.
public struct MetaPreview: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: MediaType
    public var name: String
    public var poster: String?
    public var background: String?
    public var logo: String?
    public var description: String?
    @LenientString public var releaseInfo: String?
    @LenientString public var imdbRating: String?
    @LenientString public var year: String?
    @LenientString public var runtime: String?
    @LenientStringArray public var genres: [String]
    public var behaviorHints: MetaBehaviorHints?

    private enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description
        case releaseInfo, imdbRating, year, runtime, genres, genre, behaviorHints
    }

    public init(
        id: String,
        type: MediaType,
        name: String,
        poster: String? = nil,
        background: String? = nil,
        logo: String? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        imdbRating: String? = nil,
        year: String? = nil,
        runtime: String? = nil,
        genres: [String] = [],
        behaviorHints: MetaBehaviorHints? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.year = year
        self.runtime = runtime
        self.genres = genres
        self.behaviorHints = behaviorHints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = (try? container.decode(MediaType.self, forKey: .type)) ?? .movie
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled"
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
        background = try container.decodeIfPresent(String.self, forKey: .background)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        _releaseInfo = try container.decode(LenientString.self, forKey: .releaseInfo)
        _imdbRating = try container.decode(LenientString.self, forKey: .imdbRating)
        _year = try container.decode(LenientString.self, forKey: .year)
        _runtime = try container.decode(LenientString.self, forKey: .runtime)

        // Cinemeta sends both `genres` and a legacy `genre`; prefer the former.
        let primary = try container.decode(LenientStringArray.self, forKey: .genres)
        if primary.wrappedValue.isEmpty {
            _genres = try container.decode(LenientStringArray.self, forKey: .genre)
        } else {
            _genres = primary
        }

        behaviorHints = try container.decodeIfPresent(MetaBehaviorHints.self, forKey: .behaviorHints)
    }

    // Written by hand because `genre` is a decode-only fallback key with no property,
    // which blocks synthesis.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(poster, forKey: .poster)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try container.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(runtime, forKey: .runtime)
        try container.encode(genres, forKey: .genres)
        try container.encodeIfPresent(behaviorHints, forKey: .behaviorHints)
    }

    /// Year shown under a poster — `releaseInfo` carries ranges like "2008–2013".
    public var yearLabel: String? { releaseInfo ?? year }
}

public struct MetaBehaviorHints: Codable, Hashable, Sendable {
    public var defaultVideoId: String?
    public var hasScheduledVideos: Bool?
}

/// One episode of a series (the protocol calls these "videos").
public struct Video: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var title: String?
    @LenientInt public var season: Int?
    @LenientInt public var episode: Int?
    @LenientInt public var number: Int?
    public var thumbnail: String?
    public var overview: String?
    public var description: String?
    public var released: Date?
    public var firstAired: Date?
    @LenientString public var rating: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, title, season, episode, number
        case thumbnail, overview, description, released, firstAired, rating
    }

    public var displayName: String {
        name ?? title ?? "Episode \(episodeNumber.map(String.init) ?? "?")"
    }

    /// Addons disagree on `episode` vs `number`; both mean the same thing.
    public var episodeNumber: Int? { episode ?? number }

    public var summary: String? { overview ?? description }

    public var airDate: Date? { released ?? firstAired }

    /// Hasn't aired yet. Such episodes carry no thumbnail or synopsis, so the UI
    /// presents them differently rather than rendering empty artwork.
    public var isUpcoming: Bool {
        guard let airDate else { return false }
        return airDate > .now
    }

    /// "S01E05" — nil for specials with no season.
    public var episodeCode: String? {
        guard let season, let episodeNumber else { return nil }
        return String(format: "S%02dE%02d", season, episodeNumber)
    }
}

/// Full detail for one item.
public struct MetaDetail: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: MediaType
    public var name: String
    public var poster: String?
    public var background: String?
    public var logo: String?
    public var description: String?
    @LenientString public var releaseInfo: String?
    @LenientString public var imdbRating: String?
    @LenientString public var year: String?
    @LenientString public var runtime: String?
    @LenientString public var country: String?
    @LenientString public var awards: String?
    /// Series production status — "Continuing", "Ended".
    @LenientString public var status: String?
    /// TMDB identifier, supplied by Cinemeta. Used to fetch artwork the addon
    /// protocol does not carry.
    @LenientInt public var moviedbId: Int?
    @LenientStringArray public var genres: [String]
    @LenientStringArray public var cast: [String]
    @LenientStringArray public var director: [String]
    @LenientStringArray public var writer: [String]
    public var videos: [Video]
    public var trailers: [Trailer]
    public var behaviorHints: MetaBehaviorHints?

    private enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description
        case releaseInfo, imdbRating, year, runtime, country, awards, status
        case genres, genre, cast, director, writer, videos, trailers, behaviorHints
        case moviedbId = "moviedb_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = (try? container.decode(MediaType.self, forKey: .type)) ?? .movie
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled"
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
        background = try container.decodeIfPresent(String.self, forKey: .background)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        _releaseInfo = try container.decode(LenientString.self, forKey: .releaseInfo)
        _imdbRating = try container.decode(LenientString.self, forKey: .imdbRating)
        _year = try container.decode(LenientString.self, forKey: .year)
        _runtime = try container.decode(LenientString.self, forKey: .runtime)
        _country = try container.decode(LenientString.self, forKey: .country)
        _awards = try container.decode(LenientString.self, forKey: .awards)
        _status = try container.decode(LenientString.self, forKey: .status)
        _moviedbId = try container.decode(LenientInt.self, forKey: .moviedbId)

        let primary = try container.decode(LenientStringArray.self, forKey: .genres)
        _genres = primary.wrappedValue.isEmpty
            ? try container.decode(LenientStringArray.self, forKey: .genre)
            : primary

        _cast = try container.decode(LenientStringArray.self, forKey: .cast)
        _director = try container.decode(LenientStringArray.self, forKey: .director)
        _writer = try container.decode(LenientStringArray.self, forKey: .writer)
        videos = (try? container.decode([Video].self, forKey: .videos)) ?? []
        trailers = (try? container.decode([Trailer].self, forKey: .trailers)) ?? []
        behaviorHints = try container.decodeIfPresent(MetaBehaviorHints.self, forKey: .behaviorHints)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(poster, forKey: .poster)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try container.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(runtime, forKey: .runtime)
        try container.encodeIfPresent(country, forKey: .country)
        try container.encodeIfPresent(awards, forKey: .awards)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(moviedbId, forKey: .moviedbId)
        try container.encode(genres, forKey: .genres)
        try container.encode(cast, forKey: .cast)
        try container.encode(director, forKey: .director)
        try container.encode(writer, forKey: .writer)
        try container.encode(videos, forKey: .videos)
        try container.encode(trailers, forKey: .trailers)
        try container.encodeIfPresent(behaviorHints, forKey: .behaviorHints)
    }

    public var yearLabel: String? { releaseInfo ?? year }

    /// Episodes grouped into seasons, ascending, with season 0 (specials) sorted last.
    public var seasons: [Season] {
        let grouped = Dictionary(grouping: videos) { $0.season ?? 0 }
        return grouped
            .map { Season(number: $0.key, episodes: $0.value.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }) }
            .sorted { lhs, rhs in
                if lhs.number == 0 { return false }
                if rhs.number == 0 { return true }
                return lhs.number < rhs.number
            }
    }

    public var preview: MetaPreview {
        MetaPreview(
            id: id,
            type: type,
            name: name,
            poster: poster,
            background: background,
            logo: logo,
            description: description,
            releaseInfo: releaseInfo,
            imdbRating: imdbRating,
            year: year,
            runtime: runtime,
            genres: genres
        )
    }
}

/// A trailer, as Cinemeta supplies it: a bare YouTube id.
public struct Trailer: Codable, Hashable, Sendable, Identifiable {
    /// The YouTube video id.
    public var source: String
    /// "Trailer", "Teaser", "Clip".
    public var type: String?

    public var id: String { source }

    public var isTrailer: Bool {
        type == nil || type?.caseInsensitiveCompare("Trailer") == .orderedSame
    }

    /// Watch URL. Deliberately the canonical youtube.com link rather than a
    /// `youtube://` deep link, so it opens the app where installed and falls back
    /// to the browser where it is not.
    public var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(source)")
    }

    /// The YouTube app's own scheme, for a platform with no browser to fall back
    /// to. On tvOS the https link above opens nothing at all.
    public var appURL: URL? {
        URL(string: "youtube://www.youtube.com/watch?v=\(source)")
    }
}

public struct Season: Hashable, Sendable, Identifiable {
    public var number: Int
    public var episodes: [Video]

    public var id: Int { number }
    public var displayName: String { number == 0 ? "Specials" : "Season \(number)" }
}
