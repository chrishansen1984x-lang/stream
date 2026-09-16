import Testing
import Foundation
@testable import StreamCore

@Suite("Hiding films that are still in cinemas")
struct TheatricalWindowTests {

    private func nowPlaying(_ pairs: [(String, String?)]) -> TheatricalWindow {
        TheatricalWindow(nowPlaying: pairs.map { title, year in
            TMDBClient.TMDBTitle(
                id: abs(title.hashValue), title: title, posterPath: nil,
                year: year, character: nil, isSeries: false
            )
        })
    }

    private func movie(_ name: String, year: String?, id: String = "tt1") -> MetaPreview {
        MetaPreview(id: id, type: .movie, name: name, year: year)
    }

    @Test("A film in cinemas is hidden")
    func hidesCurrentRelease() {
        let window = nowPlaying([("Spider-Man: Brand New Day", "2026")])
        #expect(window.hides(movie("Spider-Man: Brand New Day", year: "2026")))
    }

    /// Cinemeta and TMDB do not punctuate identically, and a miss here is the whole
    /// feature failing silently.
    @Test("Punctuation, case and spacing do not cause a miss")
    func normalisesTitles() {
        let window = nowPlaying([("Spider-Man: Brand New Day", "2026")])
        #expect(window.hides(movie("spider man brand new day", year: "2026")))
        #expect(window.hides(movie("SPIDERMAN BRAND NEW DAY", year: "2026")))
        #expect(window.hides(movie("Spider‑Man — Brand New Day!", year: "2026")))
    }

    /// The reason the year is in the key at all.
    @Test("An older film sharing a name with a current release is not hidden")
    func doesNotHideTheOlderFilm() {
        let window = nowPlaying([("Dolly", "2026")])
        #expect(window.hides(movie("Dolly", year: "2026")))
        #expect(!window.hides(movie("Dolly", year: "1993")))
    }

    @Test("A year on only one side still matches on the title")
    func toleratesAMissingYear() {
        #expect(nowPlaying([("Mutiny", nil)]).hides(movie("Mutiny", year: "2026")))
        #expect(nowPlaying([("Mutiny", "2026")]).hides(movie("Mutiny", year: nil)))
    }

    /// Cinemeta writes a series' `releaseInfo` as a range.
    @Test("A trailing dash on the year does not break the match")
    func handlesOpenEndedYear() {
        let window = nowPlaying([("Furious", "2026")])
        var item = movie("Furious", year: nil)
        item.releaseInfo = "2026–"
        #expect(window.hides(item))
    }

    @Test("A series is never hidden, even when a film shares its name")
    func neverHidesSeries() {
        let window = nowPlaying([("Mutiny", "2026")])
        var series = movie("Mutiny", year: "2026")
        series.type = .series
        #expect(!window.hides(series))
    }

    @Test("An unrelated film is untouched")
    func leavesEverythingElseAlone() {
        let window = nowPlaying([("Spider-Man: Brand New Day", "2026")])
        #expect(!window.hides(movie("Interstellar", year: "2014")))
    }

    @Test("An empty window hides nothing at all")
    func emptyHidesNothing() {
        #expect(TheatricalWindow().isEmpty)
        #expect(!TheatricalWindow().hides(movie("Spider-Man: Brand New Day", year: "2026")))
    }

    @Test("A re-release puts the same title in under two years, both hidden")
    func handlesReRelease() {
        let window = nowPlaying([("Titanic", "1997"), ("Titanic", "2026")])
        #expect(window.hides(movie("Titanic", year: "1997")))
        #expect(window.hides(movie("Titanic", year: "2026")))
        #expect(!window.hides(movie("Titanic", year: "2012")))
    }
}
