import Testing
@testable import StreamCore

struct SearchRelevanceTests {
    @Test func exactTitleBeatsEarlierPartialMatches() {
        let titles = ["All Night", "Up All Night", "All Night Wrong", "Run All Night"]
        #expect(SearchRelevance.sorted(titles, query: "all night wrong", title: { $0 }) == ["All Night Wrong", "All Night", "Up All Night", "Run All Night"])
    }
    @Test func normalizesCaseAccentsPunctuationAndWhitespace() {
        #expect(SearchRelevance.sorted(["Amelie Returns", "Amélie!"], query: "  AMELIE  ", title: { $0 }).first == "Amélie!")
    }
    @Test func phraseAndWholeWordsOutrankUnrelatedMatches() {
        let titles = ["Nightfall", "Wrong Night All", "The All Night Wrong Story", "All Night Wrong Again", "All Night Wrong"]
        #expect(SearchRelevance.sorted(titles, query: "all night wrong", title: { $0 }) == titles.reversed().map { $0 })
    }
    @Test func emptyQueryPreservesOrder() {
        #expect(SearchRelevance.sorted(["B", "A"], query: "?!", title: { $0 }) == ["B", "A"])
    }
}
