import Foundation

/// User-tunable rules for sorting and filtering streams.
///
/// This is the surface the audit calls the real differentiator (§4.2): auto-play-best
/// is only as good as these rules.
public struct RankingPreferences: Codable, Hashable, Sendable {
    /// Best-first ladder. A stream matching an earlier entry outranks a later one.
    public var resolutionLadder: [StreamAttributes.Resolution]
    public var excludeLowQualitySources: Bool
    public var excludeHDR: Bool
    public var preferCached: Bool
    public var maxSizeBytes: Int64?
    /// Highest resolution auto-play will choose. `nil` means no ceiling.
    ///
    /// Deliberately *not* a filter. Anything above it stays in the source list and
    /// stays selectable by hand — the setting says "don't pick 4K for me", not
    /// "pretend 4K does not exist".
    ///
    /// Also deliberately part of the synced preferences, so it applies to every
    /// device at once. A ceiling is arguably a per-device concern — 1080p on a
    /// phone over cellular, 4K on the Apple TV — and moving it to local
    /// `UserDefaults` is the known change if this ever ships. Left global for now.
    public var maxResolution: StreamAttributes.Resolution?
    public var requiredLanguages: Set<String>
    /// User-authored regex rules, applied in order.
    public var tagRules: [TagRule]

    public init(
        resolutionLadder: [StreamAttributes.Resolution] = [.fourK, .twoK, .fullHD, .hd, .sd],
        excludeLowQualitySources: Bool = true,
        excludeHDR: Bool = false,
        preferCached: Bool = true,
        maxSizeBytes: Int64? = nil,
        maxResolution: StreamAttributes.Resolution? = nil,
        requiredLanguages: Set<String> = [],
        tagRules: [TagRule] = []
    ) {
        self.resolutionLadder = resolutionLadder
        self.excludeLowQualitySources = excludeLowQualitySources
        self.excludeHDR = excludeHDR
        self.preferCached = preferCached
        self.maxSizeBytes = maxSizeBytes
        self.maxResolution = maxResolution
        self.requiredLanguages = requiredLanguages
        self.tagRules = tagRules
    }
}

/// A user-defined regex rule that boosts, penalizes, or hides matching streams.
public struct TagRule: Codable, Hashable, Sendable, Identifiable {
    public enum Effect: String, Codable, Hashable, Sendable, CaseIterable {
        case prefer, deprioritize, exclude

        public var label: String {
            switch self {
            case .prefer: "Prefer"
            case .deprioritize: "Deprioritize"
            case .exclude: "Hide"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var pattern: String
    public var effect: Effect
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        effect: Effect,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.effect = effect
        self.isEnabled = isEnabled
    }

    /// Invalid regex must not crash or silently match everything — it simply never matches.
    public func matches(_ text: String) -> Bool {
        guard isEnabled,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

/// Sorts and filters resolved streams according to `RankingPreferences`.
public enum StreamRanker {

    public static func rank(
        _ streams: [RankedStream],
        preferences: RankingPreferences = .init()
    ) -> [RankedStream] {
        streams
            .filter { include($0, preferences: preferences) }
            .sorted { score($0, preferences: preferences) > score($1, preferences: preferences) }
    }

    /// The stream auto-play should pick. Nil when everything was filtered out.
    public static func best(
        of streams: [RankedStream],
        preferences: RankingPreferences = .init()
    ) -> RankedStream? {
        autoPlayOrder(of: streams, preferences: preferences).first
    }

    /// Every source auto-play may choose, best first.
    ///
    /// `score` puts an over-ceiling release last but still in the list, because it
    /// stays selectable by hand. That was sufficient while auto-play only ever took
    /// element zero — a fallback chain walks *down* the list, so the demotion alone
    /// would let it play exactly what the ceiling exists to refuse. The ceiling is
    /// applied here as a filter, once, so the winner and every fallback obey it.
    ///
    /// The exception is a title where nothing is within the ceiling: the pick would
    /// have been an over-ceiling release regardless, so play rather than refuse.
    public static func autoPlayOrder(
        of streams: [RankedStream],
        preferences: RankingPreferences = .init(),
        limit: Int? = nil
    ) -> [RankedStream] {
        // Auto-play must never hand the player something it cannot fetch.
        var ordered = rank(streams, preferences: preferences)
            .filter { $0.stream.isDirectlyPlayable }

        if let ceiling = preferences.maxResolution {
            let within = ordered.filter { ($0.attributes.resolution ?? ceiling) <= ceiling }
            if !within.isEmpty { ordered = within }
        }

        if let limit { ordered = Array(ordered.prefix(limit)) }
        return ordered
    }

    // MARK: - Filtering

    /// How many candidates the user's own filters removed.
    ///
    /// The difference between "this title has no sources" and "its only source is
    /// one you asked to hide" matters: the first is the addon's problem, the
    /// second is a setting the viewer can change, and telling them to "try again
    /// later" for the second is simply wrong.
    public static func excludedCount(
        of streams: [RankedStream],
        preferences: RankingPreferences
    ) -> Int {
        streams.filter { !include($0, preferences: preferences) }.count
    }

    private static func include(_ item: RankedStream, preferences: RankingPreferences) -> Bool {
        let attributes = item.attributes
        let searchText = item.stream.displayTitle

        if preferences.tagRules.contains(where: { $0.effect == .exclude && $0.matches(searchText) }) {
            return false
        }
        if preferences.excludeLowQualitySources, attributes.source?.isLowQuality == true {
            return false
        }
        if preferences.excludeHDR, !attributes.hdr.isEmpty {
            return false
        }
        if let limit = preferences.maxSizeBytes, let size = attributes.sizeBytes, size > limit {
            return false
        }
        if !preferences.requiredLanguages.isEmpty {
            guard !attributes.languages.isDisjoint(with: preferences.requiredLanguages) else { return false }
        }
        return true
    }

    // MARK: - Scoring

    /// Weights are deliberately spread across decades so higher-priority factors
    /// dominate lower ones rather than accumulating into upsets.
    private static func score(_ item: RankedStream, preferences: RankingPreferences) -> Double {
        let attributes = item.attributes
        let searchText = item.stream.displayTitle
        var total: Double = 0

        // User rules outrank every intrinsic quality signal.
        for rule in preferences.tagRules where rule.matches(searchText) {
            switch rule.effect {
            case .prefer: total += 10_000
            case .deprioritize: total -= 10_000
            case .exclude: break
            }
        }

        // Instantly-available debrid results beat marginally better uncached ones.
        if preferences.preferCached, attributes.isCached { total += 5_000 }

        if let resolution = attributes.resolution,
           let rank = preferences.resolutionLadder.firstIndex(of: resolution) {
            total += Double(1_000 * (preferences.resolutionLadder.count - rank))
        }

        // Over the user's ceiling: demoted far enough that it can never be the
        // automatic pick, but still ranked, still listed, still selectable.
        //
        // The magnitude has to clear everything that could otherwise lift a 4K
        // release above a 1080p one — `preferCached` (5_000), a full sweep of the
        // resolution ladder (5_000), and a user `prefer` tag rule (10_000). This is
        // the one signal that deliberately outranks a tag rule: both are explicit
        // user instructions, and the more specific one wins.
        if let ceiling = preferences.maxResolution,
           let resolution = attributes.resolution,
           resolution > ceiling {
            total -= 100_000
        }

        if let source = attributes.source {
            total += Double(source.rawValue) * 50
        }

        // Prefer what the hardware can decode; software 4K HEVC is marginal on Apple TV.
        if attributes.videoCodec?.isHardwareFriendly == true { total += 120 }
        if attributes.audioCodec?.requiresSoftwareDecode == true { total -= 40 }

        // Heavily penalised rather than excluded: the profile is inferred from the
        // release name, so this must not hide a source that would actually play.
        //
        // The magnitude has to clear `preferCached` (5_000) plus a full sweep of the
        // resolution ladder (5_000). At 3_000 it did not: a cached Profile 5 release
        // still outranked every uncached alternative, including strictly better HDR10
        // ones. That is the ordinary debrid case, and it is how a Profile 5 file became
        // auto-play's pick and rendered magenta. Matching the tag-rule weight rather
        // than exceeding it leaves a user `prefer` rule able to cancel this exactly,
        // which is the intended hierarchy — user rules outrank intrinsic signals.
        if attributes.isLikelyDolbyVisionProfile5 {
            total -= 10_000
        } else if attributes.hdr.contains(.dolbyVision) {
            total += 90
        } else if !attributes.hdr.isEmpty {
            total += 60
        }

        // Seeders only matter for torrents, and with sharply diminishing returns.
        if let seeders = attributes.seeders, seeders > 0 {
            total += min(200, log2(Double(seeders + 1)) * 25)
        }

        // A mild nudge toward larger (higher-bitrate) files, capped so a 60 GB remux
        // does not automatically beat a well-encoded 12 GB release.
        if let size = attributes.sizeBytes {
            total += min(100, Double(size) / 1_073_741_824 * 8)
        }

        // Direct HTTPS is the only thing an App Store build can actually play.
        if item.stream.isDirectlyPlayable { total += 300 }

        return total
    }
}
