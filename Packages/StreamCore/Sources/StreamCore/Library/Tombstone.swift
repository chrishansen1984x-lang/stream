import Foundation

/// A record that something was deleted.
///
/// Both synced stores merge by union — the watchlist keeps every entry either side
/// has, watch progress keeps the newest record per video. That is right for adds
/// and edits and wrong for deletes: an absent entry is indistinguishable from one
/// the other device has not heard about yet, so a removal was always undone by the
/// next merge. Removing a title put it straight back, on every device, forever.
///
/// A deletion therefore has to be a thing that exists rather than a thing that is
/// missing. These travel in the synced payload beside the data.
public struct Tombstone: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var deletedAt: Date

    public init(id: String, deletedAt: Date = .now) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// Merging and expiry, shared by both stores.
public enum TombstoneSet {

    /// How long a deletion is remembered.
    ///
    /// Long enough that a device left off for a season still honours it when it
    /// syncs, short enough that the list cannot grow without bound. A tombstone
    /// older than this is dropped, and a stale copy of the entry on some
    /// long-dormant device could then reappear — the alternative is keeping every
    /// deletion the user ever made for the life of the account.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// Newest deletion per id wins; anything past its retention is dropped.
    public static func merged(
        _ a: [Tombstone],
        _ b: [Tombstone],
        now: Date = .now
    ) -> [Tombstone] {
        var byId: [String: Tombstone] = [:]
        for var stone in a + b {
            // Clamped to now. `deletedAt` is wall-clock from whichever device did
            // the deleting, and a device whose clock runs fast would otherwise
            // stamp a tombstone in the future — suppressing every legitimate write
            // made between now and that bogus time, on every device, silently.
            // Losing a delete to a skewed clock is recoverable; losing an evening's
            // watch history to one is not.
            stone.deletedAt = min(stone.deletedAt, now)
            guard now.timeIntervalSince(stone.deletedAt) < retention else { continue }
            if let existing = byId[stone.id], existing.deletedAt >= stone.deletedAt { continue }
            byId[stone.id] = stone
        }
        return Array(byId.values)
    }

    /// Whether a record with this timestamp has been deleted since.
    ///
    /// Strictly `>`, so an exact tie keeps the data. Ties are not hypothetical
    /// once `merged` clamps a future-dated tombstone to `now`: a re-add in that
    /// same instant would land on exactly the clamped time and be swallowed. The
    /// standing rule here is that silently losing something the user still wants
    /// is worse than a deletion occasionally failing to stick.
    public static func suppresses(
        _ tombstones: [String: Tombstone],
        id: String,
        timestamp: Date
    ) -> Bool {
        guard let stone = tombstones[id] else { return false }
        return stone.deletedAt > timestamp
    }
}
