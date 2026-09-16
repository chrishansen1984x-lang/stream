import Testing
import Foundation
@testable import StreamCore

@Suite("Up next resolution")
struct UpNextResolverTests {

    private func series(_ episodes: [(season: Int, episode: Int)]) throws -> MetaDetail {
        let videos = episodes.map { entry in
            """
            {"id":"tt1:\(entry.season):\(entry.episode)","season":\(entry.season),\
            "episode":\(entry.episode),"name":"S\(entry.season)E\(entry.episode)"}
            """
        }
        let json = """
        {"meta":{"id":"tt1","type":"series","name":"Show","videos":[\(videos.joined(separator: ","))]}}
        """
        return try JSONDecoder().decode(MetaResponse.self, from: Data(json.utf8)).meta
    }

    private func movie() throws -> MetaDetail {
        let json = #"{"meta":{"id":"tt9","type":"movie","name":"Film"}}"#
        return try JSONDecoder().decode(MetaResponse.self, from: Data(json.utf8)).meta
    }

    private func progress(
        _ videoId: String,
        position: Duration,
        duration: Duration,
        updatedAt: Date = .now
    ) -> WatchProgress {
        WatchProgress(
            videoId: videoId, metaId: "tt1", type: .series,
            position: position, duration: duration, updatedAt: updatedAt
        )
    }

    @Test("An abandoned early episode does not outrank later finished ones")
    func staleInProgressIsSkipped() throws {
        // The reported case: S01E02 was started by accident, so it carries the
        // newest timestamp, but S02E01 and S02E02 have since been finished.
        let meta = try series([(1, 1), (1, 2), (2, 1), (2, 2), (2, 3)])
        let records = [
            "tt1:2:1": progress("tt1:2:1", position: .seconds(2400), duration: .seconds(2400),
                                updatedAt: .now.addingTimeInterval(-7200)),
            "tt1:2:2": progress("tt1:2:2", position: .seconds(2400), duration: .seconds(2400),
                                updatedAt: .now.addingTimeInterval(-3600)),
            "tt1:1:2": progress("tt1:1:2", position: .seconds(120), duration: .seconds(2400),
                                updatedAt: .now)
        ]

        let next = UpNextResolver.resolve(meta: meta, progress: records)

        #expect(next.videoId == "tt1:2:3")
        #expect(next.isResume == false)
    }

    @Test("A part-watched episode after the furthest finished one still wins")
    func forwardInProgressStillResumes() throws {
        let meta = try series([(1, 1), (1, 2), (1, 3)])
        let records = [
            "tt1:1:1": progress("tt1:1:1", position: .seconds(2400), duration: .seconds(2400),
                                updatedAt: .now.addingTimeInterval(-3600)),
            "tt1:1:3": progress("tt1:1:3", position: .seconds(300), duration: .seconds(2400),
                                updatedAt: .now)
        ]

        let next = UpNextResolver.resolve(meta: meta, progress: records)

        #expect(next.videoId == "tt1:1:3")
        #expect(next.resumePosition == .seconds(300))
    }

    @Test("Nothing watched starts at the first episode")
    func freshSeries() throws {
        let meta = try series([(1, 1), (1, 2), (2, 1)])
        let next = UpNextResolver.resolve(meta: meta, progress: [:])

        #expect(next.videoId == "tt1:1:1")
        #expect(next.isResume == false)
    }

    @Test("A part-watched episode is resumed")
    func resumesInProgress() throws {
        let meta = try series([(1, 1), (1, 2)])
        let records = ["tt1:1:2": progress("tt1:1:2", position: .seconds(600), duration: .seconds(2400))]

        let next = UpNextResolver.resolve(meta: meta, progress: records)

        #expect(next.videoId == "tt1:1:2")
        #expect(next.isResume)
        #expect(next.resumePosition == .seconds(600))
        #expect(next.remaining == .seconds(1800))
    }

    @Test("The most recently touched episode wins when several are in progress")
    func mostRecentInProgress() throws {
        let meta = try series([(1, 1), (1, 2), (1, 3)])
        let old = Date(timeIntervalSinceNow: -10_000)
        let records = [
            "tt1:1:1": progress("tt1:1:1", position: .seconds(300), duration: .seconds(2400), updatedAt: old),
            "tt1:1:3": progress("tt1:1:3", position: .seconds(300), duration: .seconds(2400))
        ]

        #expect(UpNextResolver.resolve(meta: meta, progress: records).videoId == "tt1:1:3")
    }

    @Test("A finished episode advances to the next one, across a season boundary")
    func advancesAfterFinished() throws {
        let meta = try series([(1, 1), (1, 2), (2, 1)])
        // 95% through counts as finished.
        let records = ["tt1:1:2": progress("tt1:1:2", position: .seconds(2280), duration: .seconds(2400))]

        let next = UpNextResolver.resolve(meta: meta, progress: records)

        #expect(next.videoId == "tt1:2:1")
        #expect(next.isResume == false)
    }

    @Test("A fully watched series offers a rewatch rather than nothing")
    func fullyWatchedWrapsAround() throws {
        let meta = try series([(1, 1), (1, 2)])
        let records = [
            "tt1:1:1": progress("tt1:1:1", position: .seconds(2400), duration: .seconds(2400)),
            "tt1:1:2": progress("tt1:1:2", position: .seconds(2400), duration: .seconds(2400))
        ]

        #expect(UpNextResolver.resolve(meta: meta, progress: records).videoId == "tt1:1:1")
    }

    @Test("Specials are never auto-selected")
    func specialsExcluded() throws {
        // Season 0 sorts last for display but must not be picked as "next".
        let meta = try series([(0, 1), (1, 1), (1, 2)])
        #expect(UpNextResolver.resolve(meta: meta, progress: [:]).videoId == "tt1:1:1")
    }

    @Test("Barely-started playback does not create a resume point")
    func belowThresholdIsNotResumable() throws {
        let meta = try series([(1, 1), (1, 2)])
        // 30s in — an accidental tap, not a viewing.
        let records = ["tt1:1:2": progress("tt1:1:2", position: .seconds(30), duration: .seconds(2400))]

        let next = UpNextResolver.resolve(meta: meta, progress: records)

        #expect(next.videoId == "tt1:1:1")
        #expect(next.isResume == false)
    }

    @Test("Movies resume in place")
    func movieResume() throws {
        let meta = try movie()
        let records = [
            "tt9": WatchProgress(
                videoId: "tt9", metaId: "tt9", type: .movie,
                position: .seconds(1200), duration: .seconds(5400)
            )
        ]

        let next = UpNextResolver.resolve(meta: meta, progress: records)

        #expect(next.videoId == "tt9")
        #expect(next.episode == nil)
        #expect(next.isResume)
    }
}

@Suite("Watch progress")
struct WatchProgressTests {

    @Test("The credits count as finished, and a film gets a longer tail than an episode")
    func completionThreshold() {
        func made(_ position: Double, _ type: MediaType = .movie) -> WatchProgress {
            WatchProgress(
                videoId: "v", metaId: "m", type: type,
                position: .seconds(position), duration: .seconds(100)
            )
        }
        // Films: the last 12%. Credits are a fixed length, so the longer the
        // runtime the more of it they are — a percentage that suits an episode
        // leaves a blockbuster sitting in Continue watching through all of them.
        #expect(made(87).isFinished == false)
        #expect(made(89).isFinished)
        #expect(made(100).isFinished)

        // Episodes: the last 6%. Their credits are short and the final scene
        // frequently is not.
        #expect(made(89, .series).isFinished == false)
        #expect(made(95, .series).isFinished)
    }

    @Test("Progress with no known duration never reports finished")
    func unknownDuration() {
        // A live stream or an unparsed length must not be marked watched.
        let record = WatchProgress(videoId: "v", metaId: "m", type: .movie, position: .seconds(9999))
        #expect(record.fractionComplete == 0)
        #expect(record.isFinished == false)
        #expect(record.remaining == nil)
    }

    @Test("Store ignores writes below the meaningful threshold")
    @MainActor
    func storeIgnoresTinyPositions() {
        let defaults = UserDefaults(suiteName: "test.watch.\(UUID().uuidString)")!
        let store = WatchStateStore(defaults: defaults)

        store.record(videoId: "v", metaId: "m", type: .movie, position: .seconds(10), duration: .seconds(6000))
        #expect(store.progress(for: "v") == nil)

        store.record(videoId: "v", metaId: "m", type: .movie, position: .seconds(120), duration: .seconds(6000))
        #expect(store.progress(for: "v") != nil)
    }

    @Test("Continue-watching shows one entry per title")
    @MainActor
    func continueWatchingDeduplicates() {
        let defaults = UserDefaults(suiteName: "test.watch.\(UUID().uuidString)")!
        let store = WatchStateStore(defaults: defaults)

        // Two episodes of the same series must not both appear in the feed.
        store.record(videoId: "s:1:1", metaId: "s", type: .series, position: .seconds(300), duration: .seconds(2400))
        store.record(videoId: "s:1:2", metaId: "s", type: .series, position: .seconds(300), duration: .seconds(2400))
        store.record(videoId: "m", metaId: "m", type: .movie, position: .seconds(300), duration: .seconds(2400))

        let feed = store.continueWatching
        #expect(feed.count == 2)
        #expect(feed.first?.videoId == "m")
    }
}


@Suite("Watch completion")
@MainActor
struct WatchCompletionTests {

    private func store() -> WatchStateStore {
        let defaults = UserDefaults(suiteName: "completion-\(UUID().uuidString)")!
        return WatchStateStore(defaults: defaults, storageKey: "watchProgress")
    }

    @Test("Finishing overwrites a part-watched record despite the position guard")
    func finishBeatsThreshold() {
        let store = store()
        store.record(
            videoId: "tt1:1:2", metaId: "tt1", type: .series,
            position: .seconds(120), duration: .seconds(2400)
        )
        #expect(store.progress(for: "tt1:1:2")?.isResumable == true)

        // The engine reports a time of zero once the media stops, so this is the
        // path that must not fall through the minimum-position guard.
        store.markFinished(
            videoId: "tt1:1:2", metaId: "tt1", type: .series, duration: .seconds(2400)
        )

        #expect(store.progress(for: "tt1:1:2")?.isFinished == true)
        #expect(store.progress(for: "tt1:1:2")?.isResumable == false)
    }

    @Test("Finishing works when no length was ever reported")
    func finishWithoutDuration() {
        let store = store()
        store.markFinished(videoId: "tt1:1:1", metaId: "tt1", type: .series)

        #expect(store.progress(for: "tt1:1:1")?.isFinished == true)
    }

    @Test("Marking unwatched clears the record")
    func clearing() {
        let store = store()
        store.record(
            videoId: "tt1:1:2", metaId: "tt1", type: .series,
            position: .seconds(600), duration: .seconds(2400)
        )

        store.markUnwatched(videoId: "tt1:1:2")

        #expect(store.progress(for: "tt1:1:2") == nil)
    }
}

@Suite("Resume card data")
struct ResumeCardDataTests {

    private func record(_ videoId: String) -> WatchProgress {
        WatchProgress(
            videoId: videoId, metaId: "tt1", type: .series,
            position: .seconds(300), duration: .seconds(2400)
        )
    }

    @Test("Episode code is parsed from the protocol video id")
    func episodeCode() {
        #expect(record("tt16026746:2:3").episodeCode == "S02E03")
        #expect(record("tt16026746:10:12").episodeCode == "S10E12")
    }

    @Test("A movie id has no episode code")
    func movieHasNoCode() {
        #expect(record("tt10872600").episodeCode == nil)
    }

    @Test("A malformed id does not produce a bogus code")
    func malformed() {
        #expect(record("tt1:abc:2").episodeCode == nil)
        #expect(record("tt1:2").episodeCode == nil)
    }
}

@Suite("Snapshot preservation")
@MainActor
struct SnapshotPreservationTests {

    @Test("A periodic progress write keeps the card snapshot")
    func periodicWriteKeepsSnapshot() {
        let defaults = UserDefaults(suiteName: "snapshot-\(UUID().uuidString)")!
        let store = WatchStateStore(defaults: defaults, storageKey: "watchProgress")

        store.record(
            videoId: "tt1:2:3", metaId: "tt1", type: .series,
            position: .seconds(120), duration: .seconds(2400)
        )
        store.attachSnapshot(
            videoId: "tt1:2:3", metaName: "Show", poster: "p.jpg",
            still: "still.jpg", episodeName: "Rise of Apocalypse"
        )

        // What the player does every 15 seconds while playing.
        store.record(
            videoId: "tt1:2:3", metaId: "tt1", type: .series,
            position: .seconds(300), duration: .seconds(2400)
        )

        #expect(store.progress(for: "tt1:2:3")?.still == "still.jpg")
        #expect(store.progress(for: "tt1:2:3")?.episodeName == "Rise of Apocalypse")
    }
}

@Suite("Continue watching staleness")
@MainActor
struct ContinueWatchingStalenessTests {

    private func store() -> WatchStateStore {
        WatchStateStore(
            defaults: UserDefaults(suiteName: "stale-\(UUID().uuidString)")!,
            storageKey: "watchProgress"
        )
    }

    @Test("An episode watched past is dropped from continue watching")
    func supersededIsHidden() {
        let store = store()
        // The real shape of the reported bug, taken from live data: S02E01–E03
        // finished, S01E02 abandoned at 11% and touched more recently than two
        // of them.
        for episode in 1...3 {
            store.markFinished(
                videoId: "tt1:2:\(episode)", metaId: "tt1", type: .series,
                duration: .seconds(1800)
            )
        }
        store.record(
            videoId: "tt1:1:2", metaId: "tt1", type: .series,
            position: .seconds(211), duration: .seconds(1839)
        )

        #expect(store.continueWatching.isEmpty)
    }

    @Test("An episode ahead of the furthest finished one is kept")
    func forwardIsKept() {
        let store = store()
        store.markFinished(
            videoId: "tt1:2:1", metaId: "tt1", type: .series, duration: .seconds(1800)
        )
        store.record(
            videoId: "tt1:2:2", metaId: "tt1", type: .series,
            position: .seconds(400), duration: .seconds(1800)
        )

        #expect(store.continueWatching.map(\.videoId) == ["tt1:2:2"])
    }

    @Test("A part-watched movie is unaffected")
    func movieUnaffected() {
        let store = store()
        store.record(
            videoId: "tt9", metaId: "tt9", type: .movie,
            position: .seconds(400), duration: .seconds(7000)
        )

        #expect(store.continueWatching.map(\.videoId) == ["tt9"])
    }
}

@Suite("Removing a title from continue watching")
@MainActor
struct ClearTitleTests {

    private func store() -> WatchStateStore {
        WatchStateStore(
            defaults: UserDefaults(suiteName: "cleartitle-\(UUID().uuidString)")!,
            storageKey: "watchProgress"
        )
    }

    @Test("Clearing a series forgets every episode, not just the one on the card")
    func clearsWholeSeries() {
        let store = store()
        store.markFinished(videoId: "tt1:1:1", metaId: "tt1", type: .series, duration: .seconds(1800))
        store.record(
            videoId: "tt1:1:2", metaId: "tt1", type: .series,
            position: .seconds(300), duration: .seconds(1800)
        )
        store.record(
            videoId: "tt9", metaId: "tt9", type: .movie,
            position: .seconds(300), duration: .seconds(7000)
        )

        store.clearTitle(metaId: "tt1")

        #expect(store.progress(for: "tt1:1:1") == nil)
        #expect(store.progress(for: "tt1:1:2") == nil)
        // An unrelated title is untouched.
        #expect(store.progress(for: "tt9") != nil)
    }

    @Test("Clearing a title it does not have changes nothing")
    func unknownTitleIsSafe() {
        let store = store()
        store.record(
            videoId: "tt9", metaId: "tt9", type: .movie,
            position: .seconds(300), duration: .seconds(7000)
        )

        store.clearTitle(metaId: "nope")

        #expect(store.progress(for: "tt9") != nil)
    }
}

@Suite("Credits are a length, not a fraction")
struct CompletionThresholdTests {

    private func record(_ type: MediaType, minutes: Double, remaining: Double) -> WatchProgress {
        let duration = Duration.seconds(minutes * 60)
        let position = Duration.seconds((minutes - remaining) * 60)
        return WatchProgress(
            videoId: "tt1", metaId: "tt1", type: type,
            position: position, duration: duration,
            playedSeconds: (minutes - remaining) * 60
        )
    }

    /// The case that prompted the change: still in Continue watching with twelve
    /// and a half minutes left, every second of it credits.
    @Test("A blockbuster sitting in its credits counts as watched")
    func longFilmInCredits() {
        #expect(record(.movie, minutes: 148, remaining: 12.5).isFinished)
    }

    @Test("A film with a reel still to go does not")
    func longFilmStillPlaying() {
        #expect(!record(.movie, minutes: 148, remaining: 25).isFinished)
    }

    /// An episode's credits are a minute and its last scene often is not, so the
    /// film rule would strand five minutes of a forty-five minute show.
    @Test("An episode keeps the stricter rule")
    func episodeIsStricter() {
        #expect(!record(.series, minutes: 45, remaining: 5).isFinished)
        #expect(record(.series, minutes: 45, remaining: 2).isFinished)
    }

    @Test("A short film is not completed early by the looser rule")
    func shortFilm() {
        #expect(!record(.movie, minutes: 90, remaining: 15).isFinished)
        #expect(record(.movie, minutes: 90, remaining: 9).isFinished)
    }

    /// The fast-forward guard still governs: reaching the end is not watching it.
    @Test("Scrubbing to the credits still does not count")
    func scrubbingStillRefused() {
        var scrubbed = record(.movie, minutes: 148, remaining: 12.5)
        scrubbed.playedSeconds = 120
        #expect(!scrubbed.isFinished)
    }
}
