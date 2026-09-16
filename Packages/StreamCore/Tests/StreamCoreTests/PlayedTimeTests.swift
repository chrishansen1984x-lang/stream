import Testing
import Foundation
@testable import StreamCore

@Suite("Watched means played, not scrubbed")
@MainActor
struct PlayedTimeTests {

    private func store(_ suite: String) -> WatchStateStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WatchStateStore(defaults: defaults, storageKey: "watchProgress")
    }

    @Test("Scrubbing to the end does not count as watched")
    func scrubbingDoesNotComplete() {
        let s = store("played.scrub")
        // Watched two minutes, then dragged the scrubber to 95%.
        s.record(videoId: "v1", metaId: "m1", type: .movie,
                 position: .seconds(120), duration: .seconds(6000), playedSeconds: 120)
        s.record(videoId: "v1", metaId: "m1", type: .movie,
                 position: .seconds(5700), duration: .seconds(6000), playedSeconds: 1)

        let record = s.progress(for: "v1")
        #expect(record?.fractionComplete ?? 0 >= 0.92, "position did reach the threshold")
        #expect(record?.isFinished == false, "a skipped-through film was marked watched")
        #expect(record?.isResumable == true, "and it should still be resumable")
    }

    @Test("Actually watching it does count")
    func watchingCompletes() {
        let s = store("played.watch")
        // Fifteen-second checkpoints, the way the player writes them.
        var played = 0.0
        while played < 5700 {
            played += 15
            s.record(videoId: "v1", metaId: "m1", type: .movie,
                     position: .seconds(played), duration: .seconds(6000), playedSeconds: 15)
        }
        #expect(s.progress(for: "v1")?.isFinished == true, "a film watched through was not completed")
    }

    @Test("Watching across several sittings accumulates")
    func accumulatesAcrossSessions() {
        let s = store("played.sessions")
        // Three evenings, a third each. No single session clears the bar.
        for third in 1...3 {
            s.record(videoId: "v1", metaId: "m1", type: .movie,
                     position: .seconds(Double(third) * 1900),
                     duration: .seconds(6000),
                     playedSeconds: 1900)
        }
        #expect(s.progress(for: "v1")?.isFinished == true,
                "a film watched over three sittings was not completed")
    }

    @Test("Skipping the credits still completes it")
    func skippingSomeIsFine() {
        let s = store("played.skip")
        // Watched 60% honestly, then jumped to the end. Well over the played floor.
        s.record(videoId: "v1", metaId: "m1", type: .movie,
                 position: .seconds(3600), duration: .seconds(6000), playedSeconds: 3600)
        s.record(videoId: "v1", metaId: "m1", type: .movie,
                 position: .seconds(5700), duration: .seconds(6000), playedSeconds: 2)
        #expect(s.progress(for: "v1")?.isFinished == true,
                "skipping ahead near the end should not stop it completing")
    }

    @Test("Marking watched by hand still works")
    func markFinishedStillCompletes() {
        let s = store("played.manual")
        s.markFinished(videoId: "v1", metaId: "m1", type: .movie, duration: .seconds(6000))
        #expect(s.progress(for: "v1")?.isFinished == true,
                "an explicit mark-as-watched was refused by the played rule")
    }

    @Test("Records written before the count existed keep the old rule")
    func legacyRecordsUnaffected() {
        // No playedSeconds — every record in every existing install.
        let legacy = WatchProgress(
            videoId: "v1", metaId: "m1", type: .movie,
            position: .seconds(5700), duration: .seconds(6000)
        )
        #expect(legacy.playedSeconds == nil)
        #expect(legacy.isFinished, "an existing finished record stopped being finished")
    }

    @Test("The completion hook does not fire for a scrub")
    func hookIgnoresScrubbing() {
        let s = store("played.hook")
        var fired: [String] = []
        s.onFinished = { fired.append($0.videoId) }

        s.record(videoId: "v1", metaId: "m1", type: .movie,
                 position: .seconds(120), duration: .seconds(6000), playedSeconds: 120)
        s.record(videoId: "v1", metaId: "m1", type: .movie,
                 position: .seconds(5900), duration: .seconds(6000), playedSeconds: 1)
        #expect(fired.isEmpty, "a scrub was reported to trackers as a finished watch")
    }
}
