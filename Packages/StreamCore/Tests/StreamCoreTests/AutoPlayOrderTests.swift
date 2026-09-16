import Testing
import Foundation
@testable import StreamCore

/// `autoPlayOrder` is the list a fallback chain walks, so anything in it can be
/// played without the viewer choosing it. That is a stronger contract than
/// `rank`, which only has to put the right thing first.
@Suite("Sources auto-play may choose")
struct AutoPlayOrderTests {

    private func stream(_ name: String, url: String = "https://example.test/a.mkv") -> RankedStream {
        let raw = StreamCore.Stream(url: url, name: name)
        return RankedStream(stream: raw, attributes: ReleaseParser.parse(raw))
    }

    private func magnet(_ name: String) -> RankedStream {
        let raw = StreamCore.Stream(infoHash: "abc123", name: name)
        return RankedStream(stream: raw, attributes: ReleaseParser.parse(raw))
    }

    /// The defect this exists to prevent: the ceiling is a score demotion, which
    /// kept an over-ceiling release out of first place but left it sitting in the
    /// list where a chain would walk straight down to it.
    @Test("An over-ceiling source is never offered while a permitted one exists")
    func ceilingIsAFilterNotJustADemotion() {
        let streams = [
            stream("Show.S01E01.2160p.WEB-DL.x265", url: "https://example.test/4k.mkv"),
            stream("Show.S01E01.1080p.WEB-DL.x264", url: "https://example.test/1080.mkv")
        ]
        var preferences = RankingPreferences()
        preferences.maxResolution = .fullHD

        let order = StreamRanker.autoPlayOrder(of: streams, preferences: preferences)
        #expect(order.allSatisfy { (entry: RankedStream) in
            (entry.attributes.resolution ?? .fullHD) <= .fullHD
        })
        #expect(!order.contains { (entry: RankedStream) in
            entry.stream.url?.contains("4k") == true
        })
    }

    /// Refusing to play anything would be worse than honouring the ceiling: the
    /// winner would have been over it either way, so the ceiling has nothing left
    /// to protect.
    @Test("A title with nothing under the ceiling still plays")
    func ceilingYieldsWhenEverythingIsAboveIt() {
        let streams = [stream("Show.S01E01.2160p.WEB-DL.x265")]
        var preferences = RankingPreferences()
        preferences.maxResolution = .fullHD

        #expect(!StreamRanker.autoPlayOrder(of: streams, preferences: preferences).isEmpty)
    }

    @Test("The winner is the same source `best` would pick")
    func agreesWithBest() {
        let streams = [
            stream("Show.S01E01.720p.WEB-DL.x264", url: "https://example.test/720.mkv"),
            stream("Show.S01E01.2160p.WEB-DL.x265", url: "https://example.test/4k.mkv"),
            stream("Show.S01E01.1080p.WEB-DL.x264", url: "https://example.test/1080.mkv")
        ]
        let best = StreamRanker.best(of: streams)
        let order = StreamRanker.autoPlayOrder(of: streams)
        #expect(order.first?.id == best?.id)
        #expect(order.count == 3)
    }

    @Test("A limit trims from the end, keeping the best")
    func limitKeepsTheBest() {
        let streams = [
            stream("Show.S01E01.720p.WEB-DL.x264", url: "https://example.test/720.mkv"),
            stream("Show.S01E01.2160p.WEB-DL.x265", url: "https://example.test/4k.mkv"),
            stream("Show.S01E01.1080p.WEB-DL.x264", url: "https://example.test/1080.mkv")
        ]
        let full = StreamRanker.autoPlayOrder(of: streams)
        let capped = StreamRanker.autoPlayOrder(of: streams, limit: 2)
        #expect(capped.count == 2)
        #expect(capped.map(\.id) == full.prefix(2).map(\.id))
    }

    @Test("Nothing playable yields an empty list rather than a magnet link")
    func excludesWhatThePlayerCannotFetch() {
        let entry = magnet("Show.S01E01.1080p.WEB-DL.x264")
        #expect(StreamRanker.autoPlayOrder(of: [entry]).isEmpty)
        #expect(StreamRanker.best(of: [entry]) == nil)
    }
}
