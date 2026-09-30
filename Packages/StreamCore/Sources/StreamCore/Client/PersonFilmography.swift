import Foundation

public enum PersonRole: String, CaseIterable, Sendable {
    case acting = "Acting", directing = "Directing", writing = "Writing", other = "Other work"
}

public enum FilmographySort: String, CaseIterable, Sendable {
    case popular = "Popular first", newest = "Newest first", oldest = "Oldest first"
}

public struct PersonCredit: Identifiable, Hashable, Sendable {
    public var title: TMDBClient.TMDBTitle
    public var roles: Set<PersonRole>
    public var characters: [String]
    public var jobs: [String]
    public var genreIDs: Set<Int>
    public var popularity: Double
    public var releaseDate: String?
    public var id: String { "\(title.isSeries ? "tv" : "movie"):\(title.id)" }

    public func caption(for role: PersonRole?) -> String {
        var parts: [String] = []
        if role == nil || role == .acting {
            parts += characters.map { "As \($0)" }
            if characters.isEmpty && roles.contains(.acting) { parts.append("Actor") }
        }
        if role == nil { parts += jobs }
        else if role == .directing { parts += jobs.filter { Self.role(for: $0, department: nil) == .directing } }
        else if role == .writing { parts.append("Writer") }
        else if role == .other { parts += jobs.filter { Self.role(for: $0, department: nil) == .other } }
        return parts.joined(separator: " · ")
    }

    static func role(for job: String?, department: String?) -> PersonRole {
        if ["Director", "Co-Director"].contains(job ?? "") { return .directing }
        if department == "Writing" || ["Writer", "Screenplay", "Story", "Characters", "Novel", "Teleplay", "Screenstory", "Adaptation", "Original Story", "Original Film Writer"].contains(job ?? "") { return .writing }
        return .other
    }

    public static func filtered(_ credits: [Self], role: PersonRole?, genreID: Int?, sort: FilmographySort) -> [Self] {
        credits.filter { (role == nil || $0.roles.contains(role!)) && (genreID == nil || $0.genreIDs.contains(genreID!)) }
            .sorted { a, b in
                if sort != .popular {
                    if a.releaseDate == nil && b.releaseDate != nil { return false }
                    if a.releaseDate != nil && b.releaseDate == nil { return true }
                    if let first = a.releaseDate, let second = b.releaseDate, first != second {
                        return sort == .newest ? first > second : first < second
                    }
                }
                if a.popularity != b.popularity { return a.popularity > b.popularity }
                if a.title.title != b.title.title { return a.title.title < b.title.title }
                return a.id < b.id
            }
    }

    public static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance", 878: "Science Fiction",
        10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
        10759: "Action & Adventure", 10762: "Kids", 10763: "News", 10764: "Reality",
        10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk", 10768: "War & Politics"
    ]
}

public struct PersonProfile: Sendable {
    public var biography: String?
    public var department: String?
    public var profilePath: String?
    public var credits: [PersonCredit]

    public var profileURL: URL? {
        profilePath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") }
    }
}
