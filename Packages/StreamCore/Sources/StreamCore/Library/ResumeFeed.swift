import Foundation

/// One row of the continue-watching shelf.
///
/// Not a `WatchProgress`. A progress record answers "how far into this video did
/// you get", which is the wrong question for a series — after finishing S02E03 the
/// honest answer is "you are on S02E04", and no record for S02E04 exists yet.
public struct ResumeEntry: Identifiable, Hashable, Sendable {
    public var metaId: String
    public var type: MediaType
    /// The video this row would play.
    public var videoId: String
    /// Show or film name.
    public var title: String
    public var episodeCode: String?
    public var episodeName: String?
    /// 16:9 artwork.
    public var still: String?
    public var poster: String?
    public var fractionComplete: Double
    public var remaining: Duration?
    public var resumePosition: Duration?
    /// Most recent activity anywhere in this title, used to order the shelf.
    public var lastActivity: Date

    public var id: String { videoId }

    /// True when this row is the *next* thing rather than a partly-watched one.
    /// Those two deserve different wording: "S02E04" against "12:04 left".
    public var isUpNext: Bool { resumePosition == nil }

    public init(
        metaId: String,
        type: MediaType,
        videoId: String,
        title: String,
        episodeCode: String? = nil,
        episodeName: String? = nil,
        still: String? = nil,
        poster: String? = nil,
        fractionComplete: Double = 0,
        remaining: Duration? = nil,
        resumePosition: Duration? = nil,
        lastActivity: Date
    ) {
        self.metaId = metaId
        self.type = type
        self.videoId = videoId
        self.title = title
        self.episodeCode = episodeCode
        self.episodeName = episodeName
        self.still = still
        self.poster = poster
        self.fractionComplete = fractionComplete
        self.remaining = remaining
        self.resumePosition = resumePosition
        self.lastActivity = lastActivity
    }
}

public enum ResumeFeed {

    /// Builds the shelf row for one title, or nil if it does not belong there.
    ///
    /// Dropped in two cases: nothing of it has ever been played, and everything of
    /// it has been finished. `UpNextResolver` deliberately offers episode one for a
    /// completed series so the detail page's Play button still does something —
    /// that is right there and wrong here, where it would park finished shows at
    /// the top of the shelf forever.
    public static func entry(
        meta: MetaDetail,
        progress: [String: WatchProgress]
    ) -> ResumeEntry? {
        let related = progress.values.filter { $0.metaId == meta.id }
        guard let lastActivity = related.map(\.updatedAt).max() else { return nil }

        guard meta.type == .series, !meta.videos.isEmpty else {
            guard let record = related.first, record.isResumable else { return nil }
            return ResumeEntry(
                metaId: meta.id,
                type: meta.type,
                videoId: meta.id,
                title: meta.name,
                still: record.still ?? meta.background,
                poster: record.poster ?? meta.poster,
                fractionComplete: record.fractionComplete,
                remaining: record.remaining,
                resumePosition: record.position,
                lastActivity: lastActivity
            )
        }

        let ordered = meta.seasons.filter { $0.number > 0 }.flatMap(\.episodes)
        let episodes = ordered.isEmpty ? meta.videos : ordered
        guard !episodes.isEmpty else { return nil }

        // Every aired episode finished: there is nothing to continue.
        let aired = episodes.filter { !$0.isUpcoming }
        if !aired.isEmpty, aired.allSatisfy({ progress[$0.id]?.isFinished == true }) {
            return nil
        }

        let upNext = UpNextResolver.resolve(meta: meta, progress: progress)
        guard let episode = upNext.episode else { return nil }
        // An episode that has not aired is not something to offer.
        guard !episode.isUpcoming else { return nil }

        let record = progress[episode.id]
        return ResumeEntry(
            metaId: meta.id,
            type: .series,
            videoId: episode.id,
            title: meta.name,
            episodeCode: episode.episodeCode ?? record?.episodeCode,
            episodeName: episode.displayName,
            still: episode.thumbnail ?? record?.still ?? meta.background,
            poster: meta.poster,
            fractionComplete: record?.fractionComplete ?? 0,
            remaining: upNext.remaining,
            resumePosition: upNext.resumePosition,
            lastActivity: lastActivity
        )
    }

    /// Titles worth building a row for, most recently touched first.
    ///
    /// One id per title — a series with six records must not cost six lookups.
    public static func candidates(
        in records: [String: WatchProgress],
        limit: Int = 12
    ) -> [(metaId: String, type: MediaType)] {
        var latest: [String: (date: Date, type: MediaType)] = [:]
        for record in records.values {
            // A finished film has no row to build, and counting it here spent one
            // of the twelve slots on a title `entry` would then drop. A finished
            // episode stays: the row it produces is the *next* episode.
            if record.type == .movie, record.isFinished { continue }
            if let existing = latest[record.metaId], existing.date >= record.updatedAt { continue }
            latest[record.metaId] = (record.updatedAt, record.type)
        }
        return latest
            .sorted { $0.value.date > $1.value.date }
            .prefix(limit)
            .map { ($0.key, $0.value.type) }
    }
}
