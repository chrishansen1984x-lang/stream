import Foundation
import Observation
import os

/// How far through a single video the viewer got.
public struct WatchProgress: Codable, Hashable, Sendable, Identifiable {
    /// Protocol video id — `tt0903747:1:1` for an episode, `tt10872600` for a movie.
    public var videoId: String
    /// The movie or series this belongs to, so a series can be queried as a whole.
    public var metaId: String
    public var type: MediaType
    public var position: Duration
    public var duration: Duration?
    public var updatedAt: Date
    /// Title and artwork are denormalized so a continue-watching shelf renders
    /// instantly and offline, instead of issuing a metadata request per row.
    public var metaName: String?
    public var poster: String?
    /// 16:9 artwork — the episode still for a series, the backdrop for a movie.
    /// A resume card is landscape, and a portrait poster cropped to 16:9 is a
    /// band across someone's face.
    public var still: String?
    /// The episode's own title, so a resume card can say which one it is.
    public var episodeName: String?
    /// Seconds of this title genuinely played, accumulated across sessions.
    ///
    /// The playhead's *position* says nothing about whether anything was
    /// watched: dragging the scrubber to the end satisfies `fractionComplete`
    /// exactly as well as sitting through the film, which is how a film skipped
    /// through got reported to a tracker as watched. This counts only time that
    /// advanced the way playback advances it; seeks are excluded at the source.
    ///
    /// Optional because records written before it existed carry no count, and
    /// `isFinished` falls back to the old rule for those rather than refusing
    /// to ever complete them.
    public var playedSeconds: Double?

    public var id: String { videoId }

    public init(
        videoId: String,
        metaId: String,
        type: MediaType,
        position: Duration,
        duration: Duration? = nil,
        updatedAt: Date = .now,
        metaName: String? = nil,
        poster: String? = nil,
        still: String? = nil,
        episodeName: String? = nil,
        playedSeconds: Double? = nil
    ) {
        self.videoId = videoId
        self.metaId = metaId
        self.type = type
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.metaName = metaName
        self.poster = poster
        self.still = still
        self.episodeName = episodeName
        self.playedSeconds = playedSeconds
    }

    /// Treated as watched past this fraction — the tail is credits.
    ///
    /// Split by type because credits are a roughly fixed *length*, not a fraction,
    /// and one percentage cannot serve both. A blockbuster runs ten minutes or more
    /// of them: Spider-Man: No Way Home sat in Continue watching at 91.6% with
    /// twelve and a half minutes left, all of it credits. An episode's credits are
    /// a minute, and its last scene often is not — so episodes keep the stricter
    /// rule rather than losing five minutes of a forty-five minute show.
    public static func completionThreshold(for type: MediaType) -> Double {
        type == .movie ? 0.88 : 0.94
    }

    /// Ignored below this much progress, so an accidental tap does not create a
    /// resume point.
    public static let minimumMeaningfulPosition = Duration.seconds(60)

    public var fractionComplete: Double {
        guard let duration, duration > .zero else { return 0 }
        return min(1, position.secondsValue / duration.secondsValue)
    }

    /// At least this much of the runtime must actually have been played before the
    /// position alone is allowed to mean "watched".
    ///
    /// Deliberately well below the completion threshold: people skip recaps,
    /// credits and the odd slow stretch, and none of that should stop a film they
    /// sat through from counting. It only has to be high enough that scrubbing to
    /// the end does not clear it.
    public static let minimumPlayedFraction = 0.5

    public var isFinished: Bool {
        guard fractionComplete >= Self.completionThreshold(for: type) else { return false }
        // No count recorded — an older record, or an engine that does not report
        // one. Fall back to the position rule rather than never completing it.
        guard let playedSeconds, let duration, duration > .zero else { return true }
        return playedSeconds >= duration.secondsValue * Self.minimumPlayedFraction
    }

    /// Worth offering a resume for: started meaningfully, not yet finished.
    public var isResumable: Bool {
        !isFinished && position >= Self.minimumMeaningfulPosition
    }

    /// Season and episode numbers from the protocol video id, for ordering.
    public var seasonEpisode: (season: Int, episode: Int)? {
        let parts = videoId.split(separator: ":")
        guard parts.count >= 3,
              let season = Int(parts[parts.count - 2]),
              let episode = Int(parts[parts.count - 1])
        else { return nil }
        return (season, episode)
    }

    /// "S02E03", parsed from the protocol video id (`tt16026746:2:3`).
    ///
    /// Derived rather than stored: the id is the only thing guaranteed present on
    /// every record, including ones synced from a device that never had metadata.
    public var episodeCode: String? {
        let parts = videoId.split(separator: ":")
        guard parts.count >= 3,
              let season = Int(parts[parts.count - 2]),
              let episode = Int(parts[parts.count - 1])
        else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    public var remaining: Duration? {
        guard let duration, duration > position else { return nil }
        return duration - position
    }
}

/// What pressing Play should actually do.
public struct UpNext: Hashable, Sendable {
    public var videoId: String
    /// The episode to play; nil for movies.
    public var episode: Video?
    public var resumePosition: Duration?
    public var remaining: Duration?

    public var isResume: Bool { resumePosition != nil }
}

/// Decides which video Play starts, and where.
public enum UpNextResolver {

    /// For a movie: resume it, or start it.
    ///
    /// For a series, in priority order:
    /// 1. an episode already part-watched — the most recently touched one
    /// 2. the episode after the furthest finished one
    /// 3. the first episode
    ///
    /// Specials (season 0) are never auto-selected; they are not part of the
    /// through-line and picking one as "next" is always wrong.
    public static func resolve(meta: MetaDetail, progress: [String: WatchProgress]) -> UpNext {
        guard meta.type == .series, !meta.videos.isEmpty else {
            let existing = progress[meta.id]
            return UpNext(
                videoId: meta.id,
                episode: nil,
                resumePosition: existing?.isResumable == true ? existing?.position : nil,
                remaining: existing?.isResumable == true ? existing?.remaining : nil
            )
        }

        let ordered = meta.seasons
            .filter { $0.number > 0 }
            .flatMap(\.episodes)

        let episodes = ordered.isEmpty ? meta.videos : ordered

        let lastFinishedIndex = episodes.lastIndex { progress[$0.id]?.isFinished == true }

        // 1. Something already in progress.
        //
        // An episode that sits *before* the furthest one you have finished is
        // skipped: you started it, abandoned it, and have since watched past it,
        // so offering it as "up next" is wrong no matter how recently it was
        // touched. Without this, one accidental play early in a series captures
        // the Play button permanently.
        let inProgress = episodes.enumerated()
            .compactMap { index, episode -> (Video, WatchProgress)? in
                guard let record = progress[episode.id], record.isResumable else { return nil }
                if let lastFinishedIndex, index < lastFinishedIndex { return nil }
                return (episode, record)
            }
            .max { $0.1.updatedAt < $1.1.updatedAt }

        if let (episode, record) = inProgress {
            return UpNext(
                videoId: episode.id,
                episode: episode,
                resumePosition: record.position,
                remaining: record.remaining
            )
        }

        // 2. The one after the furthest finished episode.
        if let lastFinishedIndex {
            let nextIndex = episodes.index(after: lastFinishedIndex)
            if nextIndex < episodes.endIndex {
                return UpNext(videoId: episodes[nextIndex].id, episode: episodes[nextIndex])
            }
            // Fully watched — offer a rewatch from the top rather than nothing.
            return UpNext(videoId: episodes[0].id, episode: episodes[0])
        }

        // 3. Nothing watched yet.
        return UpNext(videoId: episodes[0].id, episode: episodes[0])
    }
}

/// Local watch history.
///
/// Deliberately bounded and `UserDefaults`-backed: tvOS allows roughly 500 KB of
/// app-local persistent storage (`AUDIT.md` §4.3), so this can never grow without
/// limit. It is also the seam where CloudKit sync lands later — callers only ever
/// touch `progress(for:)` and `record(...)`.
/// What is stored and synced: the records plus the deletions.
///
/// Decoding falls back to a bare `[String: WatchProgress]`, which is what every
/// existing install and the sync Worker already hold.
struct WatchProgressPayload: Codable {
    var records: [String: WatchProgress]
    var tombstones: [Tombstone]

    init(records: [String: WatchProgress], tombstones: [Tombstone]) {
        self.records = records
        self.tombstones = tombstones
    }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let records = try? container.decode([String: WatchProgress].self, forKey: .records) {
            self.records = records
            self.tombstones = (try? container.decode([Tombstone].self, forKey: .tombstones)) ?? []
            return
        }
        let legacy = try decoder.singleValueContainer().decode([String: WatchProgress].self)
        self.records = legacy
        self.tombstones = []
    }
}

@Observable
@MainActor
public final class WatchStateStore {
    /// Oldest records are dropped past this count. ~200 records is tens of KB.
    public static let maximumRecords = 200

    public private(set) var records: [String: WatchProgress] = [:]

    /// Fired the moment a record crosses `completionThreshold`, and only then.
    ///
    /// The transition, not the state: `record` runs every fifteen seconds while
    /// something plays, so firing on "is finished" would report the same watch
    /// dozens of times. Trackers dedupe, but a queue that fills with the same id
    /// is still a queue that fills.
    public var onFinished: ((WatchProgress) -> Void)?
    /// Deletions, so removing something from Continue watching sticks.
    private(set) var tombstones: [Tombstone] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let cloud: CloudKeyValueStore?
    private let logger = Logger(subsystem: "com.stream.core", category: "WatchState")

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "watchProgress",
        cloud: CloudKeyValueStore? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.cloud = cloud
        load()

        if let cloud {
            // Merge whatever iCloud already holds, then keep merging as other
            // devices report progress.
            merge(remote: cloud.data(forKey: storageKey))
            cloud.observe(key: storageKey) { [weak self] data in
                self?.merge(remote: data)
            }
        }
    }

    /// Reconciles remote records with local ones, newest write per video winning.
    ///
    /// Deliberately per-record rather than replacing the whole blob: two devices
    /// watching different things would otherwise clobber each other, and whichever
    /// synced last would erase the other's progress entirely.
    /// Snapshot for pushing to a remote backend.
    public func exportData() -> Data? {
        try? JSONEncoder().encode(WatchProgressPayload(records: records, tombstones: tombstones))
    }

    /// Merges a snapshot from any remote backend — iCloud or the sync Worker.
    public func mergeRemote(_ data: Data?) {
        merge(remote: data)
    }

    private func merge(remote data: Data?) {
        guard let data,
              let incoming = try? JSONDecoder().decode(WatchProgressPayload.self, from: data)
        else { return }

        let stones = TombstoneSet.merged(tombstones, incoming.tombstones)
        let byTombstoneId = Dictionary(uniqueKeysWithValues: stones.map { ($0.id, $0) })

        func survives(_ record: WatchProgress) -> Bool {
            !TombstoneSet.suppresses(byTombstoneId, id: record.videoId, timestamp: record.updatedAt)
        }

        // Both sides are filtered, not just the incoming one: a record deleted on
        // *this* device is still sitting in `records` until the merge drops it,
        // and the union below would otherwise keep it alive forever.
        var merged = records.filter { survives($0.value) }
        for (videoId, remoteRecord) in incoming.records where survives(remoteRecord) {
            if let localRecord = merged[videoId] {
                if remoteRecord.updatedAt > localRecord.updatedAt {
                    merged[videoId] = remoteRecord
                }
            } else {
                merged[videoId] = remoteRecord
            }
        }

        guard merged != records || stones != tombstones else { return }
        records = merged
        tombstones = stones
        prune()
        // Local only — writing back to iCloud here would loop between devices.
        persistLocally()
    }

    public func progress(for videoId: String) -> WatchProgress? {
        records[videoId]
    }

    /// All progress for one movie or series, most recent first.
    public func progress(forMeta metaId: String) -> [WatchProgress] {
        records.values
            .filter { $0.metaId == metaId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func record(
        videoId: String,
        metaId: String,
        type: MediaType,
        position: Duration,
        duration: Duration?,
        metaName: String? = nil,
        poster: String? = nil,
        /// Seconds genuinely played, this session only. Added to whatever earlier
        /// sessions banked — a film watched over three evenings has to accumulate,
        /// or the last sitting alone would never clear `minimumPlayedFraction`.
        playedSeconds: Double? = nil,
        /// Overridable so a remote record keeps the timestamp it was paused at,
        /// rather than looking like it just happened and winning every merge.
        updatedAt: Date = .now
    ) {
        // Below the threshold there is nothing worth remembering, and writing it
        // would evict a real record under the cap.
        guard position >= WatchProgress.minimumMeaningfulPosition else { return }

        // A duration shorter than the position is not a duration. It cannot
        // happen in a sound pipeline and it did happen: libVLC reports the
        // length of what *remains* when a media is opened with `:start-time=`,
        // so resuming an episode 45 minutes in reported a 17-minute length, and
        // `position / duration` — 263% — sailed past the completion threshold
        // and marked a part-watched episode finished. `PlaybackController` no
        // longer sends one, and this makes sure nothing else can: a length that
        // contradicts the position is dropped rather than stored, and an earlier
        // sound one is kept in preference to it.
        //
        // The tolerance is for the ordinary overshoot at the end of a file,
        // where the last time report can land just past the reported length.
        var duration = duration
        if let reported = duration, position > reported + .seconds(5) {
            let previous = records[videoId]?.duration
            duration = (previous.map { $0 > position } ?? false) ? previous : nil
        }

        // Writing progress supersedes any earlier deletion of this video, the
        // way `WatchlistStore.add` does for a re-add. Without it, resuming
        // something you had removed from Continue watching produced records that
        // the surviving tombstone filtered straight back out on the next merge —
        // an entire session's progress, gone with no error.
        clearTombstone(for: videoId)
        let wasFinished = records[videoId]?.isFinished ?? false
        records[videoId] = WatchProgress(
            videoId: videoId,
            metaId: metaId,
            type: type,
            position: position,
            duration: duration,
            updatedAt: updatedAt,
            // Preserve an earlier snapshot if this call did not supply one.
            metaName: metaName ?? records[videoId]?.metaName,
            poster: poster ?? records[videoId]?.poster,
            // Carried explicitly. These are only ever filled by the backfill,
            // so rebuilding the record without them would blank the resume
            // card's artwork on every periodic write.
            still: records[videoId]?.still,
            episodeName: records[videoId]?.episodeName,
            playedSeconds: playedSeconds.map { $0 + (records[videoId]?.playedSeconds ?? 0) }
                ?? records[videoId]?.playedSeconds
        )
        prune()
        announceIfNewlyFinished(videoId, wasFinished: wasFinished)
        save()
    }

    /// Records a watch as complete, bypassing the minimum-position guard.
    ///
    /// That guard exists so an accidental tap never creates a resume point, but a
    /// completion is precisely where it does harm: libVLC reports a time of zero
    /// once the media stops, so an episode played to the end would be written as
    /// "barely started" and — since the guard drops such writes — silently leave
    /// the old part-watched record in place forever.
    public func markFinished(
        videoId: String,
        metaId: String,
        type: MediaType,
        duration: Duration? = nil,
        metaName: String? = nil,
        poster: String? = nil,
        updatedAt: Date = .now
    ) {
        // Position must equal duration for `fractionComplete` to reach 1. With no
        // length reported anywhere, any equal pair works — the ratio is what the
        // completion test reads.
        let length = duration ?? records[videoId]?.duration ?? .seconds(1)

        // Writing progress supersedes any earlier deletion of this video, the
        // way `WatchlistStore.add` does for a re-add. Without it, resuming
        // something you had removed from Continue watching produced records that
        // the surviving tombstone filtered straight back out on the next merge —
        // an entire session's progress, gone with no error.
        clearTombstone(for: videoId)
        let wasFinished = records[videoId]?.isFinished ?? false
        records[videoId] = WatchProgress(
            videoId: videoId,
            metaId: metaId,
            type: type,
            position: length,
            duration: length,
            updatedAt: updatedAt,
            metaName: metaName ?? records[videoId]?.metaName,
            poster: poster ?? records[videoId]?.poster,
            still: records[videoId]?.still,
            episodeName: records[videoId]?.episodeName,
            // Marking something watched by hand is a statement, not a
            // measurement — it has to satisfy the played rule on its own or
            // the record would come back unfinished.
            playedSeconds: length.secondsValue
        )
        prune()
        announceIfNewlyFinished(videoId, wasFinished: wasFinished)
        save()
    }

    /// Forgets a video entirely, so it reads as never started.
    public func markUnwatched(videoId: String) {
        guard records.removeValue(forKey: videoId) != nil else { return }
        tombstones = TombstoneSet.merged(tombstones, [Tombstone(id: videoId)])
        save()
    }

    /// Fills in a title and poster for a record that has none.
    ///
    /// Records written before the snapshot existed, or by a caller that had no
    /// metadata to hand, would otherwise render as blank tiles forever.
    public func attachSnapshot(
        videoId: String,
        metaName: String?,
        poster: String?,
        still: String? = nil,
        episodeName: String? = nil
    ) {
        guard var existing = records[videoId] else { return }

        let updated = WatchProgress(
            videoId: existing.videoId,
            metaId: existing.metaId,
            type: existing.type,
            position: existing.position,
            duration: existing.duration,
            updatedAt: existing.updatedAt,
            metaName: existing.metaName ?? metaName,
            poster: existing.poster ?? poster,
            still: existing.still ?? still,
            episodeName: existing.episodeName ?? episodeName,
            // Carried, not defaulted. Rebuilding the record without it erased
            // the played-time count on every backfill, which put the record
            // back on the position-only completion rule.
            playedSeconds: existing.playedSeconds
        )
        guard updated != existing else { return }
        existing = updated
        records[videoId] = existing
        save()
    }

    /// Records still missing any part of their card snapshot.
    ///
    /// Was `metaName == nil || poster == nil`, which meant records written before
    /// landscape artwork existed were considered complete and never backfilled.
    public var needingSnapshot: [WatchProgress] {
        continueWatching.filter {
            $0.metaName == nil || $0.poster == nil || $0.still == nil
        }
    }

    public func clear(videoId: String) {
        records[videoId] = nil
        save()
    }

    /// Forgets a whole title, so it leaves the continue-watching shelf.
    ///
    /// Every record for the title, not just the episode on the card: the shelf is
    /// built from `ResumeFeed`, which resolves the *next* episode from progress
    /// across the series. Clearing one record would simply promote the next one.
    public func clearTitle(metaId: String) {
        let before = records
        records = records.filter { $0.value.metaId != metaId }
        guard records.count != before.count else { return }
        let removed = before.keys.filter { records[$0] == nil }
        tombstones = TombstoneSet.merged(tombstones, removed.map { Tombstone(id: $0) })
        save()
    }

    public func clearAll() {
        records = [:]
        save()
    }

    /// Continue-watching feed: one entry per title, most recent first.
    ///
    /// Episodes you have since watched past are excluded, by the same rule
    /// `UpNextResolver` uses. Without it, one episode abandoned early sat at the
    /// front of the shelf indefinitely — it is the most recently *touched* thing
    /// that is still unfinished, but it is not where you are in the show.
    public var continueWatching: [WatchProgress] {
        var seen = Set<String>()
        return records.values
            .filter(\.isResumable)
            .filter { !isSuperseded($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.metaId).inserted }
    }

    /// True when the same title has a *finished* episode later in the running
    /// order than this one.
    private func isSuperseded(_ record: WatchProgress) -> Bool {
        guard let position = record.seasonEpisode else { return false }
        return records.values.contains { other in
            other.metaId == record.metaId
                && other.isFinished
                && other.seasonEpisode.map { $0 > position } == true
        }
    }

    /// Drops the deletion record for a video that has just been written again.
    /// Calls `onFinished` only when this write is what completed the item.
    private func announceIfNewlyFinished(_ videoId: String, wasFinished: Bool) {
        guard !wasFinished, let record = records[videoId], record.isFinished else { return }
        onFinished?(record)
    }

    private func clearTombstone(for videoId: String) {
        tombstones.removeAll { $0.id == videoId }
    }

    private func prune() {
        guard records.count > Self.maximumRecords else { return }
        let keep = records.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maximumRecords)
        records = Dictionary(uniqueKeysWithValues: keep.map { ($0.videoId, $0) })
    }

    private func save() {
        persistLocally()
        if let data = try? JSONEncoder().encode(records) {
            cloud?.set(data, forKey: storageKey)
        }
    }

    private func persistLocally() {
        do {
            let payload = WatchProgressPayload(records: records, tombstones: tombstones)
            defaults.set(try JSONEncoder().encode(payload), forKey: storageKey)
        } catch {
            logger.error("Failed to persist watch state: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(WatchProgressPayload.self, from: data)
        else { return }
        records = payload.records
        tombstones = payload.tombstones
    }

}

extension Duration {
    var secondsValue: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
