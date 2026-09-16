import Testing
import Foundation
@testable import StreamCore

@Suite("Resume feed")
struct ResumeFeedTests {

    private func series(_ episodes: [(Int, Int)]) throws -> MetaDetail {
        let videos = episodes.map { season, episode in
            """
            {"id":"tt1:\(season):\(episode)","season":\(season),"episode":\(episode),\
            "name":"Episode \(episode)"}
            """
        }
        let json = """
        {"meta":{"id":"tt1","type":"series","name":"Show","videos":[\(videos.joined(separator: ","))]}}
        """
        return try JSONDecoder().decode(MetaResponse.self, from: Data(json.utf8)).meta
    }

    private func finished(_ videoId: String, ago: TimeInterval) -> WatchProgress {
        WatchProgress(
            videoId: videoId, metaId: "tt1", type: .series,
            position: .seconds(1800), duration: .seconds(1800),
            updatedAt: Date().addingTimeInterval(-ago)
        )
    }

    private func partial(_ videoId: String, ago: TimeInterval) -> WatchProgress {
        WatchProgress(
            videoId: videoId, metaId: "tt1", type: .series,
            position: .seconds(211), duration: .seconds(1839),
            updatedAt: Date().addingTimeInterval(-ago)
        )
    }

    @Test("Finishing an episode offers the next one, not the one you abandoned")
    func offersNextEpisode() throws {
        // The live case: S02E01–E03 finished, S01E02 abandoned at 11%.
        let meta = try series([(1, 1), (1, 2), (2, 1), (2, 2), (2, 3), (2, 4)])
        let progress = [
            "tt1:2:1": finished("tt1:2:1", ago: 40000),
            "tt1:2:2": finished("tt1:2:2", ago: 30000),
            "tt1:2:3": finished("tt1:2:3", ago: 100),
            "tt1:1:2": partial("tt1:1:2", ago: 20000)
        ]

        let entry = try #require(ResumeFeed.entry(meta: meta, progress: progress))

        #expect(entry.videoId == "tt1:2:4")
        #expect(entry.episodeCode == "S02E04")
        #expect(entry.isUpNext)
        #expect(entry.fractionComplete == 0)
    }

    @Test("A part-watched episode is offered with its resume point")
    func offersResume() throws {
        let meta = try series([(1, 1), (1, 2)])
        let progress = ["tt1:1:2": partial("tt1:1:2", ago: 60)]

        let entry = try #require(ResumeFeed.entry(meta: meta, progress: progress))

        #expect(entry.videoId == "tt1:1:2")
        #expect(entry.isUpNext == false)
        #expect(entry.resumePosition == .seconds(211))
    }

    @Test("A fully watched series leaves the shelf")
    func finishedSeriesDropsOut() throws {
        let meta = try series([(1, 1), (1, 2)])
        let progress = [
            "tt1:1:1": finished("tt1:1:1", ago: 200),
            "tt1:1:2": finished("tt1:1:2", ago: 100)
        ]

        #expect(ResumeFeed.entry(meta: meta, progress: progress) == nil)
    }

    @Test("A series never played is not on the shelf")
    func untouchedIsAbsent() throws {
        let meta = try series([(1, 1)])
        #expect(ResumeFeed.entry(meta: meta, progress: [:]) == nil)
    }

    @Test("Candidates collapse a series to one lookup, newest first")
    func candidatesDeduplicate() {
        let records = [
            "tt1:1:1": finished("tt1:1:1", ago: 500),
            "tt1:1:2": finished("tt1:1:2", ago: 400),
            "tt2": WatchProgress(
                videoId: "tt2", metaId: "tt2", type: .movie,
                position: .seconds(600), duration: .seconds(7000),
                updatedAt: Date().addingTimeInterval(-100)
            )
        ]

        let candidates = ResumeFeed.candidates(in: records)

        #expect(candidates.map(\.metaId) == ["tt2", "tt1"])
    }
}
