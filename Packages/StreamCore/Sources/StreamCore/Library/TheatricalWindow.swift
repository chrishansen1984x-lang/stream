import Foundation

/// Films currently in cinemas, so they can be hidden where they cannot be played.
///
/// A film in its theatrical window has no legitimate stream, so every catalog that
/// lists it is offering something that will not play. On a television — where the
/// remote makes every wasted row expensive and there is no quick way back — that
/// is worth removing rather than discovering at the point of pressing Play.
///
/// Matching is by title and year because there is nothing else to join on: TMDB's
/// now-playing list is keyed by TMDB id and `MetaPreview` carries only an IMDb-style
/// id, so the two never share a key. The title is normalised hard enough that
/// punctuation, case and spacing cannot cause a miss, and the year keeps a current
/// release from hiding an older film that happens to share its name.
public struct TheatricalWindow: Sendable, Equatable {
    /// Normalised title → the years that title is in cinemas under. A set because
    /// re-releases put the same title in the list under two different years.
    private let yearsByTitle: [String: Set<String>]

    /// Hides nothing. The state before the list has been fetched, and the state on
    /// every platform that does not want this.
    public init() {
        yearsByTitle = [:]
    }

    public init(nowPlaying: [TMDBClient.TMDBTitle]) {
        var built: [String: Set<String>] = [:]
        for entry in nowPlaying {
            guard let key = Self.key(entry.title) else { continue }
            built[key, default: []].formUnion(Self.year(entry.year).map { [$0] } ?? [])
        }
        yearsByTitle = built
    }

    public var isEmpty: Bool { yearsByTitle.isEmpty }

    /// Number of titles being hidden, for diagnostics.
    public var count: Int { yearsByTitle.count }

    /// Whether this catalog entry is a film currently in cinemas.
    ///
    /// Series are never matched: a show does not have a theatrical window, and a
    /// film sharing its name would otherwise hide the show.
    public func hides(_ item: MetaPreview) -> Bool {
        guard item.type == .movie, !yearsByTitle.isEmpty else { return false }
        guard let key = Self.key(item.name), let years = yearsByTitle[key] else { return false }
        // A year on only one side is not evidence of a different film, so a title
        // match alone carries it. Both sides known and disagreeing is: that is the
        // remake case the year exists to catch.
        guard let year = Self.year(item.year ?? item.releaseInfo), !years.isEmpty else { return true }
        return years.contains(year)
    }

    /// Lowercased and stripped to letters and digits, so "Spider-Man: Brand New Day"
    /// and "Spider Man Brand New Day" collapse to one key.
    private static func key(_ title: String) -> String? {
        let cleaned = title.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The leading four digits, which covers both "2026" and Cinemeta's "2026–".
    private static func year(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let prefix = raw.prefix(4)
        return prefix.count == 4 && prefix.allSatisfy(\.isNumber) ? String(prefix) : nil
    }
}
