import Testing
import Foundation
@testable import StreamCore

/// A stored duration shorter than the position it is paired with is not a
/// duration. Two records in the live library reached 263% and 121% complete that
/// way and were marked watched; both were part-watched episodes.
@MainActor
struct ImpossibleDurationTests {

    private func store() -> WatchStateStore {
        WatchStateStore(defaults: UserDefaults(suiteName: "impossible-duration-\(UUID().uuidString)")!)
    }

    @Test func aDurationShorterThanThePositionIsNotStored() {
        let state = store()
        // The real shape of Alien: Earth S01E01 as it was written: 46 minutes in
        // to a 56-minute episode, with libVLC reporting the 17 minutes that
        // remained after the resume point as the length.
        state.record(
            videoId: "tt13623632:1:1",
            metaId: "tt13623632",
            type: .series,
            position: .seconds(2772),
            duration: .seconds(1056)
        )
        let saved = state.progress(for: "tt13623632:1:1")
        #expect(saved?.position == .seconds(2772))
        #expect(saved?.duration == nil)
        #expect(saved?.isFinished == false)
        // Still resumable, which is the point — the position was never wrong.
        #expect(saved?.isResumable == true)
    }

    @Test func anEarlierSoundDurationIsKeptInsteadOfTheBadOne() {
        let state = store()
        state.record(
            videoId: "tt13623632:1:1",
            metaId: "tt13623632",
            type: .series,
            position: .seconds(120),
            duration: .seconds(3360)
        )
        // Same episode resumed later, now reporting a nonsense length.
        state.record(
            videoId: "tt13623632:1:1",
            metaId: "tt13623632",
            type: .series,
            position: .seconds(2772),
            duration: .seconds(1056)
        )
        #expect(state.progress(for: "tt13623632:1:1")?.duration == .seconds(3360))
        #expect(state.progress(for: "tt13623632:1:1")?.isFinished == false)
    }

    /// Playing a file to its end reports a last time just past the length. That
    /// is normal and must still count as finished.
    @Test func aSmallOvershootAtTheEndIsStillATrustedDuration() {
        let state = store()
        state.record(
            videoId: "tt13654226",
            metaId: "tt13654226",
            type: .movie,
            position: .seconds(7669),
            duration: .seconds(7667)
        )
        let saved = state.progress(for: "tt13654226")
        #expect(saved?.duration == .seconds(7667))
        #expect(saved?.isFinished == true)
    }

    @Test func anOrdinaryRecordIsUntouched() {
        let state = store()
        state.record(
            videoId: "tt13654226",
            metaId: "tt13654226",
            type: .movie,
            position: .seconds(900),
            duration: .seconds(7667)
        )
        #expect(state.progress(for: "tt13654226")?.duration == .seconds(7667))
        #expect(state.progress(for: "tt13654226")?.isFinished == false)
    }
}
