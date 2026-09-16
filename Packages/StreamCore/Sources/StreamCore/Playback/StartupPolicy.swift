import Foundation

/// Timing rules shared by source selection and player startup.
public enum StartupPolicy {
    public static func selectionDelay(for streams: [RankedStream], preferences: RankingPreferences) -> Duration? {
        guard let best = StreamRanker.best(of: streams, preferences: preferences) else { return nil }
        let withinCeiling = preferences.maxResolution.map {
            (best.attributes.resolution ?? $0) <= $0
        } ?? true
        return preferences.preferCached && best.attributes.isCached && withinCeiling
            ? .milliseconds(500) : .seconds(3)
    }

    public static let totalBudget: Duration = .seconds(45)

    public static func attemptBudget(elapsed: Duration, hasAlternates: Bool) -> Duration {
        min(max(.zero, totalBudget - elapsed), hasAlternates ? .seconds(12) : totalBudget)
    }
}
