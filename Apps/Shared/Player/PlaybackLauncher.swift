import Foundation
import Observation
import StreamCore

/// Resolves sources and picks one automatically.
///
/// This is the default path: pressing Play resolves every capable addon, ranks the
/// results against the user's preferences, and starts the winner. The source list is
/// an opt-in for people who want to override — most users should never see it.
@Observable
@MainActor
final class PlaybackLauncher {

    enum Phase: Equatable {
        case idle
        case resolving
        case ready(RankedStream)
        case unavailable
    }

    private(set) var phase: Phase = .idle
    private(set) var target: StreamTarget?

    /// The rest of the ranked list, best first, minus the winner.
    ///
    /// Handed to the player so a source that turns out to be a placeholder can be
    /// stepped past without the viewer seeing the provider's excuse.
    private(set) var alternates: [RankedStream] = []

    /// How many sources are worth carrying. Each rejected one costs a preflight
    /// round trip before the next is tried, and a title whose first five are all
    /// placeholders has a problem no amount of retrying fixes.
    private static let maximumAlternates = 5

    // Naming the addon being waited on was tried here and removed. Startup time
    // really is dominated by the addons — measured 0.6s to 7.5s for one stream
    // request, median 3.5s — but "Asking AIOStreams…" narrates internal mechanics
    // at the one moment the viewer wants the app to get on with it, and the source
    // list already refuses to do the same thing a few screens away. The spinner
    // says "Loading…" and nothing else.

    /// How long to keep waiting for more sources once the first ones land.
    ///
    /// Play used to consume the resolver's whole stream before choosing, so every
    /// press waited out `StreamResolver.deadline` — fifteen seconds — whenever a
    /// single addon was slow to answer, which is most of the time. Addons are
    /// independent servers with wildly different latency, and the fast ones are
    /// usually the debrid aggregators that return the source actually worth
    /// playing. This keeps the "best source is often not the first to arrive"
    /// property while capping the wait at roughly first-response plus this.
    private static let settleWindow: Duration = .seconds(3)

    private var task: Task<Void, Never>?
    private var settle: Task<Void, Never>?
    private var collected: [RankedStream] = []
    /// A caller waiting on `resolveRanked`.
    private var continuation: CheckedContinuation<[RankedStream], Never>?

    /// The ranked list, awaited rather than observed through `phase`.
    ///
    /// For callers with no view to watch the phase — auto-advance in the player —
    /// which had its own copy of this and drained the resolver to its
    /// fifteen-second deadline instead of settling. Empty when nothing is playable
    /// or the launcher is cancelled.
    func resolveRanked(
        target: StreamTarget,
        registry: AddonRegistry,
        resolver: StreamResolver,
        preferences: RankingPreferences
    ) async -> [RankedStream] {
        await withCheckedContinuation { continuation in
            self.continuation?.resume(returning: [])
            self.continuation = continuation
            play(target: target, registry: registry, resolver: resolver, preferences: preferences)
        }
    }

    func play(
        target: StreamTarget,
        registry: AddonRegistry,
        resolver: StreamResolver,
        preferences: RankingPreferences
    ) {
        task?.cancel()
        settle?.cancel()
        settle = nil
        collected = []
        self.target = target
        phase = .resolving

        #if DEBUG
        // Zero for the whole startup measurement. Everything downstream — addon
        // responses, the ranker, the player open, the first frame — is reported
        // relative to this press.
        let capable = registry.enabledAddons.filter {
            $0.supports(.stream, type: target.type, id: target.videoId)
        }
        PlaybackClock.begin(
            "PLAY pressed  \(target.videoId)  "
            + "(\(capable.count) of \(registry.enabledAddons.count) addons can answer)"
        )
        #endif

        task = Task { @MainActor [weak self] in
            for await result in resolver.resolve(
                type: target.type,
                id: target.videoId,
                from: registry.enabledAddons
            ) {
                guard let self, !Task.isCancelled else { return }
                switch result {
                case .success(let batch):
                    #if DEBUG
                    PlaybackClock.mark("addon \(batch.first?.addonName ?? "?") → \(batch.count) stream(s)")
                    #endif
                case .failure(let failure):
                    #if DEBUG
                    PlaybackClock.mark("addon \(failure.addonName) FAILED: \(failure.message)")
                    #endif
                }
                guard case .success(let batch) = result, !batch.isEmpty else { continue }
                self.collected.append(contentsOf: batch)
                self.startSettling(preferences: preferences)
            }
            // Every addon answered before the window elapsed — decide now rather
            // than waiting out a timer with nothing left to wait for.
            self?.decide(preferences: preferences)
        }
    }

    /// Starts the grace period, once, on the first usable batch.
    private func startSettling(preferences: RankingPreferences) {
        guard settle == nil else { return }
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleWindow)
            guard !Task.isCancelled else { return }
            self?.decide(preferences: preferences)
        }
    }

    /// Picks a winner from whatever has arrived. Idempotent: whichever of the
    /// stream ending and the settle window firing happens first wins, and the
    /// other becomes a no-op.
    private func decide(preferences: RankingPreferences) {
        guard phase == .resolving else { return }
        task?.cancel()
        settle?.cancel()

        // `best` only returns directly-playable sources, so auto-play never hands
        // the player a magnet or an external link it cannot open.
        // `autoPlayOrder`, not `rank`: the resolution ceiling is a demotion in the
        // score, which was enough while auto-play only took the first entry. A
        // fallback chain walks down the list, so the ceiling has to be a filter.
        let ranked = StreamRanker.autoPlayOrder(of: collected, preferences: preferences)
        continuation?.resume(returning: ranked)
        continuation = nil
        if let winner = ranked.first {
            alternates = Array(ranked.dropFirst().prefix(Self.maximumAlternates))
            #if DEBUG
            PlaybackClock.mark(
                "ranker picked \(winner.stream.displayTitle.prefix(60)) "
                + "from \(collected.count) (\(winner.addonName))"
            )
            #endif
            phase = .ready(winner)
        } else {
            #if DEBUG
            PlaybackClock.mark("ranker found nothing playable in \(collected.count)")
            #endif
            phase = .unavailable
        }
    }

    func cancel() {
        continuation?.resume(returning: [])
        continuation = nil
        task?.cancel()
        task = nil
        settle?.cancel()
        settle = nil
        collected = []
        alternates = []
        phase = .idle
        target = nil
    }

    func finish() {
        phase = .idle
        target = nil
    }
}
