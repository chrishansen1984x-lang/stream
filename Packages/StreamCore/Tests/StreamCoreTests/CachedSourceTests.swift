import Testing
import Foundation
@testable import StreamCore

/// `preferCached` is the ranker's strongest intrinsic signal, and against the
/// live AIOStreams setup it never once fired: 28 streams, none detected as
/// cached. These are that addon's real shapes, captured 2026-08-21.
struct CachedSourceTests {

    /// Already in the debrid library — instantly playable. AIOStreams says so
    /// with `folderSize` and a ⤓ in its description, and with nothing else.
    private func libraryStream() -> StreamCore.Stream {
        StreamCore.Stream(
            url: "https://aiostreams.example/playback/token",
            name: "Mutiny.2026.2160p.AMZN.WEB-DL.DDP5.1.H.264.HUNSUB-BBM.mkv, DD+,4K,Amazon",
            description: "⤓        Mutiny (2026) | ⚑ EN | ⛁ 10.4 GB · ⟳ 95 min |  ♛ Library",
            behaviorHints: StreamBehaviorHints(
                videoSize: 10_396_015_481,
                folderSize: 20_792_030_962,
                filename: "Mutiny.2026.2160p.AMZN.WEB-DL.DDP5.1.H.264.HUNSUB-BBM.mkv"
            )
        )
    }

    /// From an indexer, not the library: it would have to be fetched first.
    private func indexerStream() -> StreamCore.Stream {
        StreamCore.Stream(
            url: "https://aiostreams.example/playback/token",
            name: "Dolly.2026.VOSTFR.1080p.WEB-DL.H264-Slay3R.mkv, FHD",
            description: " ⌁           Dolly (2026) | ⛁ 4.32 GB · ⟳ 83 min | ∅ Comet",
            behaviorHints: StreamBehaviorHints(
                videoSize: 4_316_584_198,
                filename: "Dolly.2026.VOSTFR.1080p.WEB-DL.H264-Slay3R.mkv"
            )
        )
    }

    @Test func libraryResultsCountAsCached() {
        #expect(ReleaseParser.parse(libraryStream()).isCached)
    }

    @Test func indexerResultsDoNot() {
        #expect(!ReleaseParser.parse(indexerStream()).isCached)
    }

    /// `folderSize` says "the folder is in the library". It must never be
    /// mistaken for the size of the file — 20.8 GB of folder, 10.4 GB of film.
    @Test func sizeStillComesFromVideoSizeAlone() {
        #expect(ReleaseParser.parse(libraryStream()).sizeBytes == 10_396_015_481)
    }

    /// The point of the change: a cached library copy must beat an uncached
    /// indexer copy of the same resolution. Before it, they scored identically
    /// on this signal and the tie fell to whatever else happened to differ.
    @Test func rankerPrefersTheLibraryCopy() {
        let preferences = RankingPreferences(preferCached: true)
        let ranked = StreamRanker.rank(
            [
                RankedStream(stream: indexerStream(), attributes: ReleaseParser.parse(indexerStream())),
                RankedStream(stream: libraryStream(), attributes: ReleaseParser.parse(libraryStream()))
            ],
            preferences: preferences
        )
        #expect(ranked.first?.stream.behaviorHints?.folderSize != nil)
    }

    /// The markers other addons use still work.
    @Test func lightningBoltStillMeansCached() {
        #expect(ReleaseParser.parse("⚡ Some.Release.1080p.mkv").isCached)
        #expect(ReleaseParser.parse("[TB+] Some.Release.1080p.mkv").isCached)
        #expect(!ReleaseParser.parse("Some.Release.1080p.mkv").isCached)
    }

    /// `folderSize` decodes, and is kept apart from `videoSize`.
    @Test func folderSizeDecodesFromTheAddonPayload() throws {
        let json = """
        {"streams":[{"url":"https://x/y","behaviorHints":{"videoSize":2729844538,"folderSize":18791422917}}]}
        """
        let response = try JSONDecoder().decode(StreamsResponse.self, from: Data(json.utf8))
        let hints = try #require(response.streams.first?.behaviorHints)
        #expect(hints.videoSize == 2_729_844_538)
        #expect(hints.folderSize == 18_791_422_917)
    }
}
