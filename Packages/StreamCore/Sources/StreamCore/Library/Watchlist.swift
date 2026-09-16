import Foundation
import Observation
import os

/// A saved title.
///
/// Stores a full `MetaPreview` rather than an id: the watchlist must render
/// instantly and offline, and a shelf of ids would need one metadata request per
/// row before it could show anything.
public struct WatchlistEntry: Codable, Hashable, Sendable, Identifiable {
    public var meta: MetaPreview
    public var addedAt: Date

    public var id: String { meta.id }

    public init(meta: MetaPreview, addedAt: Date = .now) {
        self.meta = meta
        self.addedAt = addedAt
    }
}

/// What is stored and synced: the entries plus the deletions.
///
/// Decoding falls back to a bare `[WatchlistEntry]`, which is what every existing
/// install and the sync Worker already hold.
struct WatchlistPayload: Codable {
    var entries: [WatchlistEntry]
    var tombstones: [Tombstone]

    init(entries: [WatchlistEntry], tombstones: [Tombstone]) {
        self.entries = entries
        self.tombstones = tombstones
    }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let entries = try? container.decode([WatchlistEntry].self, forKey: .entries) {
            self.entries = entries
            self.tombstones = (try? container.decode([Tombstone].self, forKey: .tombstones)) ?? []
            return
        }
        let legacy = try decoder.singleValueContainer().decode([WatchlistEntry].self)
        self.entries = legacy
        self.tombstones = []
    }
}

/// Titles the user saved for later.
@Observable
@MainActor
public final class WatchlistStore {
    /// Bounded like watch history, for the same tvOS storage reason (AUDIT.md §4.3).
    public static let maximumEntries = 300

    public private(set) var entries: [WatchlistEntry] = []
    /// Deletions, carried so a removal survives the next merge.
    private(set) var tombstones: [Tombstone] = []

    /// Fired on any local change, so the sync layer can push without polling.
    public var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let storageKey: String
    private let cloud: CloudKeyValueStore?
    private let logger = Logger(subsystem: "com.stream.core", category: "Watchlist")

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "watchlist",
        cloud: CloudKeyValueStore? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.cloud = cloud
        load()

        if let cloud {
            mergeRemote(cloud.data(forKey: storageKey))
            cloud.observe(key: storageKey) { [weak self] data in
                self?.mergeRemote(data)
            }
        }
    }

    /// Newest first — a watchlist is a queue, and the thing just added is the
    /// thing most likely to be wanted.
    public var sorted: [WatchlistEntry] {
        entries.sorted { $0.addedAt > $1.addedAt }
    }

    public func contains(_ id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    public func toggle(_ meta: MetaPreview) {
        if contains(meta.id) {
            remove(meta.id)
        } else {
            add(meta)
        }
    }

    public func add(_ meta: MetaPreview) {
        guard !contains(meta.id) else { return }
        // Re-adding supersedes an earlier delete, so the tombstone goes. Left in
        // place it would out-date the new entry and delete it again on merge.
        tombstones.removeAll { $0.id == meta.id }
        entries.append(WatchlistEntry(meta: meta))
        if entries.count > Self.maximumEntries {
            entries = Array(sorted.prefix(Self.maximumEntries))
        }
        save()
    }

    public func remove(_ id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        tombstones = TombstoneSet.merged(tombstones, [Tombstone(id: id)])
        save()
    }

    // MARK: - Sync

    public func exportData() -> Data? {
        try? JSONEncoder().encode(WatchlistPayload(entries: entries, tombstones: tombstones))
    }

    /// Union by id, keeping the earlier `addedAt`, minus anything deleted since.
    ///
    /// A union rather than last-writer-wins: removing on one device is far less
    /// common than adding on another, and silently losing saved titles is much
    /// worse than an occasional stale entry the user can delete again. Deletions
    /// are the exception, and they are carried explicitly — see `Tombstone`.
    public func mergeRemote(_ data: Data?) {
        guard let data,
              let incoming = try? JSONDecoder().decode(WatchlistPayload.self, from: data)
        else { return }

        let stones = TombstoneSet.merged(tombstones, incoming.tombstones)
        let byTombstoneId = Dictionary(uniqueKeysWithValues: stones.map { ($0.id, $0) })

        func survives(_ entry: WatchlistEntry) -> Bool {
            !TombstoneSet.suppresses(byTombstoneId, id: entry.id, timestamp: entry.addedAt)
        }

        // Filter *both* sides before combining. Doing it only to the incoming side
        // would leave a locally-deleted entry in place, and taking the earlier
        // `addedAt` across a re-add would date the entry back behind its own
        // tombstone and delete it a second time.
        var byId = Dictionary(
            uniqueKeysWithValues: entries.filter(survives).map { ($0.id, $0) }
        )
        for entry in incoming.entries where survives(entry) {
            if let existing = byId[entry.id] {
                if entry.addedAt < existing.addedAt { byId[entry.id] = entry }
            } else {
                byId[entry.id] = entry
            }
        }

        let merged = Array(byId.values)
        guard Set(merged.map(\.id)) != Set(entries.map(\.id)) || stones != tombstones else { return }
        entries = merged
        tombstones = stones
        persistLocally()
    }

    private func save() {
        persistLocally()
        if let data = exportData() {
            cloud?.set(data, forKey: storageKey)
        }
        onChange?()
    }

    private func persistLocally() {
        do {
            let payload = WatchlistPayload(entries: entries, tombstones: tombstones)
            defaults.set(try JSONEncoder().encode(payload), forKey: storageKey)
        } catch {
            logger.error("Failed to persist watchlist: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(WatchlistPayload.self, from: data)
        else { return }
        entries = payload.entries
        tombstones = payload.tombstones
    }
}
