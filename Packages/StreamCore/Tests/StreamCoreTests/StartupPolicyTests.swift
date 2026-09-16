import Foundation
import Testing
@testable import StreamCore

@Suite("Playback startup timing")
struct StartupPolicyTests {
    private func source(cached: Bool, direct: Bool = true) -> RankedStream {
        let stream = direct ? Stream(url: "https://example.test/video.mkv") : Stream(infoHash: "abc")
        var attributes = ReleaseParser.parse(stream)
        attributes.isCached = cached
        attributes.resolution = .fullHD
        return RankedStream(stream: stream, attributes: attributes)
    }

    @Test func cachedPlayableSourceGetsShortWindow() {
        #expect(StartupPolicy.selectionDelay(for: [source(cached: true)], preferences: .init()) == .milliseconds(500))
    }

    @Test func unusableBatchDoesNotStartCountdown() {
        #expect(StartupPolicy.selectionDelay(for: [source(cached: true, direct: false)], preferences: .init()) == nil)
        var preferences = RankingPreferences()
        preferences.maxSizeBytes = 1
        var candidate = source(cached: true)
        candidate.attributes.sizeBytes = 100
        #expect(StartupPolicy.selectionDelay(for: [candidate], preferences: preferences) == nil)
    }

    @Test func uncertainAndOverCeilingSourcesKeepGracePeriod() {
        #expect(StartupPolicy.selectionDelay(for: [source(cached: false)], preferences: .init()) == .seconds(3))
        var preferences = RankingPreferences()
        preferences.maxResolution = .hd
        #expect(StartupPolicy.selectionDelay(for: [source(cached: true)], preferences: preferences) == .seconds(3))
        preferences.preferCached = false
        #expect(StartupPolicy.selectionDelay(for: [source(cached: true)], preferences: preferences) == .seconds(3))
    }

    @Test func retriesCannotExtendTotalBudget() {
        #expect(StartupPolicy.attemptBudget(elapsed: .zero, hasAlternates: true) == .seconds(12))
        #expect(StartupPolicy.attemptBudget(elapsed: .seconds(36), hasAlternates: true) == .seconds(9))
        #expect(StartupPolicy.attemptBudget(elapsed: .seconds(36), hasAlternates: false) == .seconds(9))
        #expect(StartupPolicy.attemptBudget(elapsed: .seconds(46), hasAlternates: false) == .zero)
    }
}
