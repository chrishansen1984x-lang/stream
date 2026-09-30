import Foundation
import Testing
@testable import StreamCore

private final class MemoryCloud: NSUbiquitousKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var count = 0
    var writes: Int { lock.withLock { count } }
    override func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    override func set(_ data: Data?, forKey key: String) {
        lock.withLock { values[key] = data; count += 1 }
    }
    override func synchronize() -> Bool { false }
}

@Suite @MainActor struct CloudInitializationTests {
    private func addon(_ id: String) throws -> Addon {
        let json = "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"version\":\"1\",\"types\":[\"movie\"],\"resources\":[],\"catalogs\":[]}"
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        return Addon(manifest: manifest, transportURL: URL(string: "https://example.test/\(id)/manifest.json")!)
    }

    @Test func starterAddonDoesNotOverwriteCloudBeforeDownload() throws {
        let suite = "cloud.starter.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MemoryCloud()
        let cloud = CloudKeyValueStore(store: backend, observeChanges: false)
        let registry = AddonRegistry(defaults: defaults, cloud: cloud)
        registry.installStarter(try addon("starter"))
        #expect(registry.addons.map(\.id) == ["starter"])
        #expect(backend.data(forKey: "installedAddons") == nil)
    }

    @Test func firstLaunchRecoversRicherLocalAddonListOnce() throws {
        let suite = "cloud.addonRecovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = AddonRegistry(defaults: defaults)
        local.install(try addon("starter"))
        local.install(try addon("configured"))
        let backend = MemoryCloud()
        backend.set(try JSONEncoder().encode([addon("starter")]), forKey: "installedAddons")
        let cloud = CloudKeyValueStore(store: backend, observeChanges: false)
        let recovered = AddonRegistry(defaults: defaults, cloud: cloud)
        #expect(recovered.addons.map(\.id) == ["starter", "configured"])
        let uploaded = try JSONDecoder().decode([Addon].self, from: #require(backend.data(forKey: "installedAddons")))
        #expect(uploaded.map(\.id) == ["starter", "configured"])

        backend.set(try JSONEncoder().encode([addon("starter")]), forKey: "installedAddons")
        let later = AddonRegistry(defaults: defaults, cloud: cloud)
        #expect(later.addons.map(\.id) == ["starter"])
    }

    @Test func offlineWritesReachSystemStoreAndIdenticalWritesAreSkipped() {
        let backend = MemoryCloud()
        let cloud = CloudKeyValueStore(store: backend, observeChanges: false)
        let data = Data("offline".utf8)
        cloud.set(data, forKey: "test")
        cloud.set(data, forKey: "test")
        #expect(backend.data(forKey: "test") == data)
        #expect(backend.writes == 1)
    }

    @Test func settingSeedPreservesCloudValue() {
        let backend = MemoryCloud()
        let cloud = CloudKeyValueStore(store: backend, observeChanges: false)
        let local = Data("local".utf8)
        let remote = Data("remote".utf8)
        cloud.seedIfMissing(nil, forKey: "empty")
        #expect(backend.writes == 0)
        cloud.seedIfMissing(local, forKey: "setting")
        #expect(backend.data(forKey: "setting") == local)
        backend.set(remote, forKey: "setting")
        cloud.seedIfMissing(local, forKey: "setting")
        #expect(backend.data(forKey: "setting") == remote)
    }

    @Test func firstSyncPublishesExistingWatchlistWithoutLosingRemoteTitles() {
        let suite = "cloud.initial.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = WatchlistStore(defaults: defaults)
        local.add(MetaPreview(id: "local", type: .movie, name: "Local"))
        let backend = MemoryCloud()
        let remote = WatchlistEntry(meta: MetaPreview(id: "remote", type: .movie, name: "Remote"))
        backend.set(try! JSONEncoder().encode([remote]), forKey: "watchlist")
        let cloud = CloudKeyValueStore(store: backend, observeChanges: false)
        let merged = WatchlistStore(defaults: defaults, cloud: cloud)
        #expect(merged.contains("local"))
        #expect(merged.contains("remote"))
        let uploaded = try! JSONDecoder().decode(WatchlistPayload.self, from: backend.data(forKey: "watchlist")!)
        #expect(Set(uploaded.entries.map(\.id)) == ["local", "remote"])
        let writes = backend.writes
        _ = WatchlistStore(defaults: defaults, cloud: cloud)
        #expect(backend.writes == writes)
    }

    @Test func emptyInstallationDoesNotPublishEmptyWatchlist() {
        let suite = "cloud.empty.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MemoryCloud()
        let cloud = CloudKeyValueStore(store: backend, observeChanges: false)
        _ = WatchlistStore(defaults: defaults, cloud: cloud)
        #expect(backend.writes == 0)
    }

    @Test func progressInitialSyncPreservesDeletionAndUnrelatedLocalProgress() throws {
        let suite = "cloud.progress.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = WatchStateStore(defaults: defaults)
        let earlier = Date.now.addingTimeInterval(-120)
        local.record(videoId: "removed", metaId: "removed", type: .movie,
                     position: .seconds(300), duration: .seconds(3000), updatedAt: earlier)
        local.record(videoId: "kept", metaId: "kept", type: .movie,
                     position: .seconds(600), duration: .seconds(3000), updatedAt: earlier)
        let remote = WatchProgressPayload(records: [:], tombstones: [
            Tombstone(id: "removed", deletedAt: .now.addingTimeInterval(-60))
        ])
        let backend = MemoryCloud()
        backend.set(try JSONEncoder().encode(remote), forKey: "watchProgress")
        let cloud = CloudKeyValueStore(store: backend, observeChanges: false)
        let merged = WatchStateStore(defaults: defaults, cloud: cloud)
        #expect(merged.progress(for: "removed") == nil)
        #expect(merged.progress(for: "kept")?.position == .seconds(600))
        let uploaded = try JSONDecoder().decode(WatchProgressPayload.self,
                                                from: #require(backend.data(forKey: "watchProgress")))
        #expect(uploaded.records["removed"] == nil)
        #expect(uploaded.records["kept"]?.position == .seconds(600))
        #expect(uploaded.tombstones.contains { $0.id == "removed" })
        let writes = backend.writes
        let restarted = WatchStateStore(defaults: defaults, cloud: cloud)
        #expect(restarted.progress(for: "removed") == nil)
        #expect(backend.writes == writes)
    }

    @Test func progressInitialSyncKeepsNewerRemotePosition() throws {
        let suite = "cloud.progress.newer.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = WatchStateStore(defaults: defaults)
        local.record(videoId: "film", metaId: "film", type: .movie,
                     position: .seconds(300), duration: .seconds(3000),
                     updatedAt: .now.addingTimeInterval(-120))
        let newer = WatchProgress(videoId: "film", metaId: "film", type: .movie,
                                  position: .seconds(900), duration: .seconds(3000),
                                  updatedAt: .now.addingTimeInterval(-60))
        let backend = MemoryCloud()
        backend.set(try JSONEncoder().encode(["film": newer]), forKey: "watchProgress")
        let cloud = CloudKeyValueStore(store: backend, observeChanges: false)
        let merged = WatchStateStore(defaults: defaults, cloud: cloud)
        #expect(merged.progress(for: "film")?.position == .seconds(900))
        let reloaded = WatchStateStore(defaults: defaults)
        #expect(reloaded.progress(for: "film")?.position == .seconds(900))
    }

}
