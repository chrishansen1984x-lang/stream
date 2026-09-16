import Testing
import Foundation
@testable import StreamCore

@Suite("Deletions survive syncing")
@MainActor
struct TombstoneTests {

    private func meta(_ id: String) -> MetaPreview {
        MetaPreview(id: id, type: .movie, name: "Title \(id)")
    }

    private func store(_ suite: String) -> WatchlistStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WatchlistStore(defaults: defaults, storageKey: "watchlist")
    }

    // MARK: - The reported bug

    @Test("A removed title is not resurrected by the next merge")
    func removalSurvivesMerge() {
        let device = store("tomb.removal")
        device.add(meta("tt1"))
        device.add(meta("tt2"))

        // What the sync endpoint still holds: both titles.
        let remote = device.exportData()

        device.remove("tt1")
        #expect(device.contains("tt1") == false)

        // The pull that used to put it straight back.
        device.mergeRemote(remote)
        #expect(device.contains("tt1") == false, "removed title came back from the remote copy")
        #expect(device.contains("tt2"))
    }

    @Test("The deletion propagates to the other device rather than being lost")
    func removalPropagates() {
        let phone = store("tomb.phone")
        phone.add(meta("tt1"))
        let shared = phone.exportData()

        let mac = store("tomb.mac")
        mac.mergeRemote(shared)
        #expect(mac.contains("tt1"))

        phone.remove("tt1")
        mac.mergeRemote(phone.exportData())
        #expect(mac.contains("tt1") == false, "the delete did not travel")
    }

    @Test("Re-adding after a delete sticks")
    func reAddWins() {
        let device = store("tomb.readd")
        device.add(meta("tt1"))
        let beforeDelete = device.exportData()
        device.remove("tt1")
        device.add(meta("tt1"))

        // The stale copy from before the delete must not re-delete it.
        device.mergeRemote(beforeDelete)
        #expect(device.contains("tt1"), "a re-added title was deleted again by an old snapshot")
    }

    @Test("A delete on one device does not wipe an unrelated add on another")
    func deleteIsScoped() {
        let phone = store("tomb.scope.phone")
        phone.add(meta("tt1"))
        phone.remove("tt1")

        let mac = store("tomb.scope.mac")
        mac.add(meta("tt2"))

        mac.mergeRemote(phone.exportData())
        #expect(mac.contains("tt2"), "an unrelated title was lost")
        #expect(mac.contains("tt1") == false)
    }

    // MARK: - Watch progress after a removal

    private func watchStore(_ suite: String) -> WatchStateStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WatchStateStore(defaults: defaults, storageKey: "watchProgress")
    }

    @Test("Resuming a show removed from Continue watching keeps the new progress")
    func resumeAfterClearSurvives() {
        let device = watchStore("tomb.resume")
        device.record(videoId: "v1", metaId: "m1", type: .series,
                      position: .seconds(300), duration: .seconds(3000))
        let stale = device.exportData()

        // Removed from Continue watching...
        device.clearTitle(metaId: "m1")
        #expect(device.progress(for: "v1") == nil)

        // ...then watched again.
        device.record(videoId: "v1", metaId: "m1", type: .series,
                      position: .seconds(1200), duration: .seconds(3000))

        // The pull that used to filter the whole session back out.
        device.mergeRemote(stale)
        let kept = device.progress(for: "v1")
        #expect(kept != nil, "an entire watch session was swallowed by a stale tombstone")
        #expect(kept?.position == .seconds(1200), "progress regressed to the pre-removal value")
    }

    @Test("Removing from Continue watching still sticks across a merge")
    func clearTitleSticks() {
        let device = watchStore("tomb.cleartitle")
        device.record(videoId: "v1", metaId: "m1", type: .series,
                      position: .seconds(300), duration: .seconds(3000))
        let remote = device.exportData()

        device.clearTitle(metaId: "m1")
        device.mergeRemote(remote)
        #expect(device.progress(for: "v1") == nil, "the removal was undone by the merge")
    }

    // MARK: - The completion hook Screen scrobbles from

    @Test("onFinished fires once, on the write that completes the item")
    func finishedFiresOnTransitionOnly() {
        let defaults = UserDefaults(suiteName: "tomb.finish")!
        defaults.removePersistentDomain(forName: "tomb.finish")
        let store = WatchStateStore(defaults: defaults, storageKey: "watchProgress")

        var fired: [String] = []
        store.onFinished = { fired.append($0.videoId) }

        // Part way through: nothing to report.
        store.record(videoId: "v1", metaId: "m1", type: .movie,
                     position: .seconds(600), duration: .seconds(6000))
        #expect(fired.isEmpty)

        // Crossing the threshold reports once.
        store.record(videoId: "v1", metaId: "m1", type: .movie,
                     position: .seconds(5800), duration: .seconds(6000))
        #expect(fired == ["v1"])

        // `record` runs every fifteen seconds while something plays; the rest of
        // the file must not report the same watch again.
        store.record(videoId: "v1", metaId: "m1", type: .movie,
                     position: .seconds(5900), duration: .seconds(6000))
        #expect(fired == ["v1"], "the same watch was reported more than once")
    }

    @Test("markFinished reports too")
    func markFinishedFires() {
        let defaults = UserDefaults(suiteName: "tomb.finish2")!
        defaults.removePersistentDomain(forName: "tomb.finish2")
        let store = WatchStateStore(defaults: defaults, storageKey: "watchProgress")

        var fired: [String] = []
        store.onFinished = { fired.append($0.videoId) }
        store.markFinished(videoId: "tt0903747:1:5", metaId: "tt0903747", type: .series)
        #expect(fired == ["tt0903747:1:5"])
    }

    // MARK: - Compatibility

    @Test("A payload written before tombstones existed still loads")
    func decodesLegacyWatchlist() throws {
        let legacy = try JSONEncoder().encode([WatchlistEntry(meta: meta("tt9"))])
        let device = store("tomb.legacy")
        device.mergeRemote(legacy)
        #expect(device.contains("tt9"), "the old bare-array format no longer decodes")
    }

    @Test("A legacy watch-progress payload still loads")
    func decodesLegacyWatchProgress() throws {
        let record = WatchProgress(
            videoId: "v1", metaId: "m1", type: .movie,
            position: .seconds(60), duration: .seconds(600), updatedAt: .now
        )
        let legacy = try JSONEncoder().encode(["v1": record])
        let payload = try JSONDecoder().decode(WatchProgressPayload.self, from: legacy)
        #expect(payload.records["v1"] != nil)
        #expect(payload.tombstones.isEmpty)
    }

    // MARK: - Expiry and merge rules

    @Test("Tombstones expire so the list cannot grow forever")
    func expiry() {
        let fresh = Tombstone(id: "new", deletedAt: .now)
        let ancient = Tombstone(id: "old", deletedAt: .now.addingTimeInterval(-TombstoneSet.retention - 60))
        let merged = TombstoneSet.merged([fresh, ancient], [])
        #expect(merged.map(\.id) == ["new"])
    }

    @Test("The newest deletion per id wins")
    func newestWins() {
        // Dates near now, deliberately: anything older than the retention window
        // is expired by `merged`, which is a different rule being tested below.
        let older = Tombstone(id: "x", deletedAt: .now.addingTimeInterval(-120))
        let newer = Tombstone(id: "x", deletedAt: .now.addingTimeInterval(-60))
        let merged = TombstoneSet.merged([older], [newer])
        #expect(merged.count == 1)
        #expect(merged.first?.deletedAt == newer.deletedAt)
    }

    @Test("Merge order does not change the result")
    func mergeIsCommutative() {
        let older = Tombstone(id: "x", deletedAt: .now.addingTimeInterval(-120))
        let newer = Tombstone(id: "x", deletedAt: .now.addingTimeInterval(-60))
        #expect(
            TombstoneSet.merged([older], [newer]).first?.deletedAt
                == TombstoneSet.merged([newer], [older]).first?.deletedAt
        )
    }

    @Test("A tombstone from a fast clock cannot swallow later writes")
    func futureDatedTombstoneIsClamped() {
        // A device an hour ahead deletes something. Unclamped, that tombstone
        // out-dates every write made in the next hour on every other device.
        let now = Date()
        let fromTheFuture = Tombstone(id: "x", deletedAt: now.addingTimeInterval(3_600))
        let merged = TombstoneSet.merged([fromTheFuture], [], now: now)
        #expect(merged.first?.deletedAt == now)

        let byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        // A record written a minute from now must still survive.
        #expect(
            TombstoneSet.suppresses(byId, id: "x", timestamp: now.addingTimeInterval(60)) == false,
            "a future-dated tombstone swallowed a later legitimate write"
        )
    }

    @Test("Merging is idempotent — repeated syncs converge")
    func idempotent() {
        let device = store("tomb.idem")
        device.add(meta("tt1"))
        device.add(meta("tt2"))
        device.remove("tt1")
        let payload = device.exportData()

        let before = Set(device.entries.map(\.id))
        for _ in 0..<5 { device.mergeRemote(payload) }
        #expect(Set(device.entries.map(\.id)) == before, "repeated merges did not converge")
        #expect(device.contains("tt1") == false)
    }

    @Test("A record written after the delete is kept")
    func writeAfterDeleteWins() {
        let deleted = Date(timeIntervalSince1970: 1_000)
        let stones = ["x": Tombstone(id: "x", deletedAt: deleted)]
        #expect(TombstoneSet.suppresses(stones, id: "x", timestamp: deleted.addingTimeInterval(1)) == false)
        #expect(TombstoneSet.suppresses(stones, id: "x", timestamp: deleted.addingTimeInterval(-1)))
        // A tie keeps the data: losing something wanted is worse than a delete
        // that has to be repeated.
        #expect(TombstoneSet.suppresses(stones, id: "x", timestamp: deleted) == false)
    }
}
