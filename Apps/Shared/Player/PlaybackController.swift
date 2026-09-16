import Foundation
import Observation
import AVFoundation
import SwiftVLC
import StreamCore

#if canImport(UIKit)
import UIKit
#endif

/// Shared observable state and controls for AVPlayer and libVLC.
@Observable
@MainActor
final class PlaybackController {

    enum Engine: Equatable {
        case avPlayer
        case software
    }

    enum Status: Equatable {
        case idle
        case loading
        case playing
        case paused
        case ended
        case failed(String)
    }

    private(set) var engine: Engine
    private(set) var status: Status = .idle {
        // Refresh the now-playing entry to keep the system transport controls active.
        didSet { if status != oldValue { publishNowPlaying() } }
    }
    private(set) var currentTime: Duration = .zero {
        didSet { throttledNowPlayingRefresh() }
    }
    private(set) var duration: Duration?
    /// Native pixel dimensions, once the decoder reports them. Drives the macOS
    /// window's aspect lock, so it is nil until the first frame is decoded.
    private(set) var videoSize: CGSize?

    /// Prevents periodic position updates from overriding the user's scrub gesture.
    var isScrubbing = false

    /// Playback time accumulated from small forward position changes.
    /// Seek jumps are excluded from watched-time tracking.
    private(set) var playedSeconds: Double = 0
    /// Previous reported position used to calculate playback time.
    private var lastTick: Duration?

    /// Maximum position delta counted as playback rather than a seek.
    private static let maximumPlaybackStep: Double = 2

    #if DEBUG
    /// Active controller for the debug-only `stream://seek` test hook.
    static weak var debugCurrent: PlaybackController?

    /// Seeks the active player and samples its position twice to detect a seek
    /// that initially succeeds but later returns to the old position.
    static func debugSeekProbe(to seconds: Int, fast: Bool) {
        guard let controller = debugCurrent else {
            tracePlayback("seek probe: no player on screen")
            return
        }
        let before = Int(controller.currentTime.seconds)
        controller.seek(to: .seconds(seconds), fast: fast)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            let near = Int(controller.currentTime.seconds)
            try? await Task.sleep(for: .seconds(3))
            tracePlayback(
                "seek probe: \(before)s -> asked \(seconds)s (fast=\(fast))"
                + "  +0.7s=\(near)s  +3.7s=\(Int(controller.currentTime.seconds))s"
            )
        }
    }
    #endif

    /// A selectable audio or subtitle track.
    ///
    /// A local type rather than SwiftVLC's, so views don't need to import the
    /// playback library and the AVPlayer path could populate it later.
    struct MediaTrack: Identifiable, Hashable {
        var id: String
        var name: String
        var language: String?
        var isSelected: Bool

        /// "English — Surround 5.1" where possible, falling back to whatever the
        /// container labelled the track.
        var displayName: String {
            guard let language, let readable = Locale.current.localizedString(forLanguageCode: language) else {
                return name
            }
            return name.localizedCaseInsensitiveContains(readable) ? name : "\(readable) · \(name)"
        }
    }

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    /// Set once the *user* picks a track, so the automatic pass stops.
    private var hasUserChosenAudio = false
    /// The track set the automatic pass last ran against. libVLC discovers audio
    /// tracks progressively, so the pass has to re-run as the list grows rather
    /// than commit to whatever was known first.
    private var lastAudioTrackIDs: [String] = []
    private var hasCheckedSubtitles = false
    #if DEBUG
    private var hasTracedTracks = false
    #endif
    /// Resume point held until libVLC reports the media is open and seekable.
    private var pendingSeek: Duration?

    /// The `:start-time=` a resumed session was opened with.
    ///
    /// libVLC does not present a resumed media as the same timeline: it reports
    /// the length of what *remains*, and takes seek targets relative to this
    /// point — while reporting the current time absolutely. Measured on one
    /// 7667s film: `start-time=600` gives `length=7067`, `start-time=1800` gives
    /// `5867`; resuming at 900 and seeking to 300 lands at 1202, not 300.
    ///
    /// Left uncorrected that mixes two origins in one timeline, and every symptom
    /// follows from it: a ten-second skip from 15:00 jumped to 30:00 (and so did
    /// skipping *backwards*), the scrubber was scaled to the wrong total, and the
    /// duration written to `WatchState` was short by exactly this much — which put
    /// `position / duration` over the completion threshold and marked part-watched
    /// episodes finished. Two records in the library reached 263% and 121%.
    ///
    /// So the offset is held here and the media's own timeline is restored at the
    /// two places it leaks: length coming out, seek targets going in.
    private var resumeOffset: Duration = .zero

    /// Resolved source URL, retained for reopening when seeking before `resumeOffset`.
    /// Reopening uses the resolved URL to avoid repeating the redirect.
    private var currentURL: URL?

    /// Resolving and vetting the source, before either engine is handed it.
    private var preflightTask: Task<Void, Never>?
    /// Ranked sources still to try if the current one turns out to be a placeholder.
    private var pendingAlternates: [PlaybackRequest.Alternate] = []
    /// The advertised size of whatever is loaded, so a re-load keeps the size check.
    private var currentExpectedBytes: Int64?
    /// Where this item was asked to start, so a source that never opens can be
    /// replaced by the next one at the same point.
    private var currentResumePoint: Duration?
    /// Loading message while trying fallback sources. Nil for the initial attempt.
    private(set) var loadingNote: String?
    /// Number of rejected sources, included in the failure message.
    private var rejectedSources = 0
    /// True when the current failure came from the pre-flight — a placeholder or
    /// a slate — rather than from an engine that could not decode the source.
    private(set) var failedBeforeDecoding = false

    /// Whether switching to libVLC could help. Not after a pre-flight rejection:
    /// no decoder ran, and the retry would re-probe the same placeholder.
    var canRetryWithSoftwareEngine: Bool {
        engine != .software && !failedBeforeDecoding
    }

    /// Reuses an ephemeral URLSession across source preflight requests.
    private static let preflight = SourcePreflight()

    /// Pending libVLC shutdown shared across controller lifetimes.
    private static var pendingStop: Task<Void, Never>?
    /// Number of sessions still releasing their sources. Shutdowns may overlap.
    private static var draining = 0
    /// Media-opening task, cancelled during teardown.
    private var playTask: Task<Void, Never>?
    /// Fails a source that never produces a first frame.
    private var watchdog: Task<Void, Never>?
    /// The system's transport controls — AirPods, media keys, Control Centre.
    private let nowPlaying = NowPlaying()
    private var lastNowPlayingUpdate: Date = .distantPast
    /// Title for the now-playing slot, set by the view that owns the request.
    var nowPlayingTitle: String = "" {
        didSet { publishNowPlaying() }
    }
    /// Source-opening timeout, allowing for slow remux startup.
    private static let openTimeout: Duration = .seconds(45)
    /// Shorter opening timeout when another ranked source is available.
    private static let openTimeoutWithAlternates: Duration = .seconds(25)

    private(set) var avPlayer: AVPlayer?
    private(set) var vlcPlayer: SwiftVLC.Player?

    private var timeObserver: Any?
    #if DEBUG
    private var logTask: Task<Void, Never>?
    #endif
    private var endObserver: (any NSObjectProtocol)?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var eventTask: Task<Void, Never>?
    private var avStatusTask: Task<Void, Never>?
    private var tailWatchdog: Task<Void, Never>?
    /// When the position first stopped moving within `tailWindow` of the end.
    private var tailSince: ContinuousClock.Instant?
    /// When the position first stopped moving anywhere else.
    private var stallSince: ContinuousClock.Instant?
    /// Where the last automatic recovery reopened from. Nil once playback has
    /// run well past it, so the next stall may be recovered too — and set while
    /// it has not, so two stalls in the same place are not reopened forever.
    private var recoveredFrom: Duration?
    /// Where playback stopped for good: stalled, reopened, stalled again.
    private(set) var stalledAt: Duration?
    /// Fraction of the runtime past which a stall is the end rather than a
    /// fault. Per item, set by the view from `WatchProgress.completionThreshold`.
    var completionThreshold: Double = 0.9

    init(engine: Engine) {
        self.engine = engine
    }

    // MARK: - Lifecycle

    /// ISO 639 code preferred for audio, e.g. "en". Multi-language releases often
    /// default to whichever track the muxer listed first, which is frequently not
    /// the viewer's language.
    var preferredAudioLanguage: String = "en"

    /// `expectedBytes` is the addon's `videoSize` for this source, when it gave
    /// one — the pre-flight compares it against what the provider actually
    /// serves. Never `folderSize`; see `SourcePreflight.resolve`.
    func load(
        url: URL,
        startAt resumePoint: Duration? = nil,
        expectedBytes: Int64? = nil,
        alternates: [PlaybackRequest.Alternate] = [],
        // Carried across the fallback chain. `load` is re-entered for each source
        // tried, so a counter reset here would always report one attempt.
        attempt: Int = 0
    ) {
        pendingAlternates = alternates
        rejectedSources = attempt
        if attempt == 0 { loadingNote = nil }
        failedBeforeDecoding = false
        stalledAt = nil
        #if DEBUG
        // Lets `stream://seek` drive the on-screen player. Synthetic mouse and
        // keyboard input does not work in this environment, so without a hook
        // the scrubber cannot be exercised at all.
        Self.debugCurrent = self
        PlaybackClock.mark("controller.load  engine=\(engine)")
        #endif
        status = .loading
        hasUserChosenAudio = false
        lastAudioTrackIDs = []
        hasCheckedSubtitles = false
        #if DEBUG
        hasTracedTracks = false
        #endif
        pendingSeek = nil
        // Per item, not per controller: auto-advance re-loads this same
        // controller for the next episode, which starts from zero.
        resumeOffset = .zero
        currentURL = url
        currentExpectedBytes = expectedBytes
        currentResumePoint = resumePoint
        // Per session. The store adds this to whatever earlier sessions banked.
        playedSeconds = 0
        lastTick = nil
        configureAudioSession()
        activateRemoteControls()
        // Both engines, started here rather than inside the libVLC path. AVPlayer
        // stalls the same way — and it is the engine the router hands every
        // extension-less debrid link to, so it is the more likely one to sit
        // there.
        // One budget for the chain, not one per source: restarting it on every
        // fallback made `.loading` unbounded — six probes then a fresh 45s, on a
        // bare spinner, with no way back.
        // A retry that tore the previous session down re-enters with the chain's
        // attempt count and no watchdog at all — the teardown cancelled it — so a
        // wedged link on that path spun forever. Restart whenever there is none.
        if attempt == 0 || watchdog == nil || watchdog?.isCancelled == true {
            startOpenWatchdog()
        }
        startTailWatchdog()

        // One request before either engine sees the source: it follows the
        // redirect libVLC drops on the floor, and it catches the provider serving
        // a placeholder clip in place of the film. Both are measured in
        // `SourcePreflight`. The watchdog is already running, so a slow probe
        // fails the same way a slow source does rather than hanging.
        preflightTask?.cancel()
        preflightTask = Task { @MainActor [weak self] in
            let outcome = await Self.preflight.resolve(url, advertisedBytes: expectedBytes)
            // Still loading: a probe that resolves after the watchdog gave up must
            // not overwrite the failure the viewer is reading.
            guard let self, !Task.isCancelled, self.status == .loading else { return }

            switch outcome {
            case .failure(let problem):
                #if DEBUG
                PlaybackClock.mark("preflight REJECTED: \(problem.message)")
                #endif
                // A provider that has not finished caching serves a playable error
                // clip rather than an error. That used to end here, with its excuse
                // on screen and a source list that gives no way to tell which entry
                // will work. The ranker already ordered the alternatives, so step to
                // the next one instead of asking the viewer to guess.
                if let next = self.pendingAlternates.first {
                    self.pendingAlternates.removeFirst()
                    self.loadingNote = "Trying another source "
                        + "(\(self.rejectedSources + 2) of "
                        + "\(self.rejectedSources + 2 + self.pendingAlternates.count))"
                    #if DEBUG
                    PlaybackClock.mark(
                        "source \(self.rejectedSources + 1) rejected, "
                        + "\(self.pendingAlternates.count) left to try"
                    )
                    #endif
                    self.engine = next.preferSoftware ? .software : .avPlayer
                    self.load(
                        url: next.url,
                        startAt: resumePoint,
                        expectedBytes: next.expectedBytes,
                        alternates: self.pendingAlternates,
                        attempt: self.rejectedSources + 1
                    )
                    return
                }
                self.watchdog?.cancel()
                self.tailWatchdog?.cancel()
                // A size or slate rejection, not a decode failure: no engine saw
                // the source, so offering the other engine — or trying it
                // automatically, as the view does — re-probes the same
                // placeholder and fails identically.
                self.failedBeforeDecoding = true
                self.loadingNote = nil
                self.status = .failed(
                    self.rejectedSources > 0
                        ? "\(problem.message)\n\nTried \(self.rejectedSources + 1) sources."
                        : problem.message
                )

            case .success(let resolved):
                #if DEBUG
                if resolved.url != url {
                    PlaybackClock.mark("preflight resolved → \(resolved.url.host() ?? "?")")
                }
                #endif
                // The resolved URL, not the original: handing libVLC a URL that
                // still redirects is the whole failure this exists to avoid.
                self.currentURL = resolved.url
                self.start(url: resolved.url, resumePoint: resumePoint)
            }
        }
    }

    /// Hands the source to whichever engine is selected.
    private func start(url: URL, resumePoint: Duration?) {
        switch engine {
        case .avPlayer:
            loadAVPlayer(url: url, resumePoint: resumePoint)
        case .software:
            loadSoftware(url: url, resumePoint: resumePoint)
        }
    }

    /// Swaps in a different source, tearing down the current one first.
    ///
    /// The engine is re-chosen per item rather than fixed for the life of the
    /// player: auto-advance can move from an MP4 to an MKV, and keeping the
    /// previous engine would hand AVPlayer a container it cannot open.
    func replaceItem(
        url: URL,
        engine newEngine: Engine,
        expectedBytes: Int64? = nil,
        alternates: [PlaybackRequest.Alternate] = []
    ) {
        teardown()
        engine = newEngine
        // A new item: its stalls are its own.
        recoveredFrom = nil
        load(
            url: url,
            expectedBytes: expectedBytes,
            alternates: alternates
        )
    }

    /// Switches engine on an already-loaded URL.
    ///
    /// Routing is a heuristic on addon metadata, so it will sometimes pick AVPlayer
    /// for something it cannot actually decode. This is the recovery path.
    func retryWithSoftwareEngine() {
        // `currentURL`, not a URL from the view: that one is the source the chain
        // *started* with, and after a fallback it is a source already rejected.
        // Re-loading it without `expectedBytes` also disabled the size check, so a
        // placeholder the preflight had just refused would play — and be written to
        // the library as the finished film.
        guard canRetryWithSoftwareEngine, let url = currentURL else { return }
        let resumePoint = currentTime
        let bytes = currentExpectedBytes
        let remaining = pendingAlternates
        let attempted = rejectedSources
        teardown()
        engine = .software
        load(
            url: url,
            startAt: resumePoint > .seconds(5) ? resumePoint : nil,
            expectedBytes: bytes,
            alternates: remaining,
            attempt: attempted
        )
    }

    func teardown() {
        #if DEBUG
        logTask?.cancel()
        logTask = nil
        #endif
        eventTask?.cancel()
        eventTask = nil
        avStatusTask?.cancel()
        avStatusTask = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        if let timeObserver, let avPlayer {
            avPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        avPlayer?.pause()
        // Releases the item, and with it the connection to the source.
        //
        // Pausing and dropping the reference does not: AVFoundation keeps the
        // item's loader alive until it collects the player, so the socket stayed
        // open. That is the same fault the libVLC teardown below had, and it bites
        // hardest on the engine-fallback path — the router hands an extension-less
        // debrid link to AVPlayer, AVPlayer cannot open the MKV inside it, and the
        // retry on libVLC then meets a source that already has a connection open
        // and will not grant another. libVLC sat there logging nothing.
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil

        preflightTask?.cancel()
        preflightTask = nil
        playTask?.cancel()
        playTask = nil
        watchdog?.cancel()
        watchdog = nil
        tailWatchdog?.cancel()
        tailWatchdog = nil

        // libVLC's `stop()` is asynchronous — SwiftVLC's own documentation says
        // so, and points at `stopAndWait()` for teardown that must not race the
        // output drain. Calling it and dropping the reference on the next line
        // left the previous session still draining, still holding its HTTP
        // connection to the source. A debrid endpoint that caps concurrent
        // connections then refused the next play, so libVLC sat in its access
        // module and logged nothing at all while the very same URL fetched fine
        // from curl. Fresh launches always worked; second and third plays in one
        // session did not.
        //
        // The task retains the player so the drain finishes even though nothing
        // else references it, and each stop chains behind the last so two
        // sessions can never be draining at once.
        if let player = vlcPlayer {
            vlcPlayer = nil
            // Not chained behind the previous stop. Chaining them meant each new
            // play waited on every stop before it, and a drain that takes seconds
            // — they do — stacked up until starting anything took most of a
            // minute. Only the most recent one matters; older drains finish on
            // their own, retained by their own task.
            Self.draining += 1
            Self.pendingStop = Task { @MainActor in
                await player.stopAndWait()
                Self.draining -= 1
            }
        }

        videoSize = nil
        status = .idle
        nowPlaying.deactivate()

        #if os(iOS) || os(tvOS)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        // Hands the audio back, so whatever the film interrupted can resume.
        // Best effort: mid-session teardowns re-activate a moment later.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - System transport controls

    private func activateRemoteControls() {
        nowPlaying.activate(handlers: .init(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            skip: { [weak self] seconds in self?.skip(by: .seconds(seconds)) },
            seek: { [weak self] position in self?.seek(to: .seconds(position)) }
        ))
        publishNowPlaying()
    }

    /// Keeps the system's idea of what is playing in step with ours.
    ///
    /// Called on every state and time change rather than once, because the slot is
    /// only held for as long as the info is fresh — a stale entry gets dropped and
    /// the buttons go back to Music.
    /// Elapsed time changes several times a second; the system needs it roughly,
    /// not exactly, and rewriting the dictionary that often is pure waste.
    private func throttledNowPlayingRefresh() {
        let now = Date()
        guard now.timeIntervalSince(lastNowPlayingUpdate) > 2 else { return }
        lastNowPlayingUpdate = now
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        nowPlaying.update(
            title: nowPlayingTitle,
            elapsed: currentTime.seconds,
            duration: duration?.seconds,
            rate: status == .playing ? 1 : 0
        )
    }

    // MARK: - Transport

    func togglePlayPause() {
        switch status {
        case .playing: pause()
        case .paused, .ended: play()
        default: break
        }
    }

    func play() {
        switch engine {
        case .avPlayer:
            avPlayer?.play()
        case .software:
            try? vlcPlayer?.play()
        }
        // Not while opening. The status is what the open watchdog checks, and a
        // Lock Screen or AirPods play arriving mid-open flipped it to `.playing`,
        // so a wedged source never timed out. The engines report `.playing`
        // themselves once they genuinely are.
        if status != .loading { status = .playing }
    }

    func pause() {
        switch engine {
        case .avPlayer:
            avPlayer?.pause()
        case .software:
            vlcPlayer?.pause()
        }
        status = .paused
    }

    /// Moves the position.
    ///
    /// `fast` lands on the nearest keyframe instead of decoding up to an exact
    /// time. SwiftVLC documents this as the mode for a scrubber in flight: a
    /// precise seek over HTTP has to fetch and decode from the preceding
    /// keyframe, which a drag issues faster than the demuxer can service.
    func seek(to target: Duration, fast: Bool = false) {
        currentTime = target
        switch engine {
        case .avPlayer:
            // Matching tolerances: exact only for the seek that commits.
            let tolerance: CMTime = fast ? CMTime(seconds: 1, preferredTimescale: 600) : .zero
            avPlayer?.seek(
                to: CMTime(seconds: target.seconds, preferredTimescale: 600),
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
            )
        case .software:
            // `:start-time=` does not hide the earlier part of the media, it
            // never opens it: the demuxer starts there, so libVLC's timeline
            // begins at the resume point and a seek before it clamps to the
            // resume rather than going back. Rewinding into what you already
            // watched is an ordinary thing to want, so it reopens instead.
            //
            // Only on the seek that commits. A scrubber drag issues one of these
            // several times a second and reopening on each would be unusable —
            // during the drag the clamp below is a fine preview.
            if !fast, target < resumeOffset - .seconds(1), let url = currentURL {
                #if DEBUG
                Self.tracePlayback(
                    "seek to \(Int(target.seconds))s is before the resume point"
                    + " (\(Int(resumeOffset.seconds))s) — reopening"
                )
                #endif
                reopen(url: url, at: target)
                return
            }
            do {
                // Back onto libVLC's own timeline, which starts at the resume
                // point. `currentTime` above stays in the media's timeline, so a
                // seek issued from it — every skip, every scrubber drag — would
                // otherwise be applied twice: from 15:00, "back ten seconds"
                // landed at 30:00.
                let onItsTimeline = max(.zero, target - resumeOffset)
                try vlcPlayer?.seek(to: onItsTimeline, fast: fast)
            } catch {
                // `try?` here hid the reason a scrub did nothing. libVLC refuses
                // a seek outright on media it considers unseekable, and that is
                // a different bug from one that seeks to the wrong place.
                #if DEBUG
                Self.tracePlayback("seek FAILED to \(Int(target.seconds))s fast=\(fast): \(error)")
                #endif
            }
        }
    }

    /// Reloads the same source with a new demuxer start position.
    ///
    /// The only way back to a point before the current `:start-time=`. Costs an
    /// open — a second or two on a debrid link — which is why it is reserved for
    /// a seek that has actually been committed.
    private func reopen(url: URL, at target: Duration) {
        // Kept across the reopen: the size check, and the rest of the ranked
        // list — a stall that survives the reopen steps to the next source, and
        // that list used to be dropped here.
        let bytes = currentExpectedBytes
        let remaining = pendingAlternates
        let attempted = rejectedSources
        teardown()
        engine = .software
        load(url: url, startAt: target, expectedBytes: bytes, alternates: remaining, attempt: attempted)
        loadingNote = nil
    }

    /// Replaces the current source with the next ranked one, at `startAt`.
    ///
    /// One path for every way a source can turn out not to be the film — a
    /// placeholder, an open that never completes, an engine error, a file that
    /// gives out partway. False, with nothing changed, when the list is spent.
    @discardableResult
    private func stepToNextSource(startAt: Duration?, reason: String) -> Bool {
        guard let next = pendingAlternates.first else { return false }
        pendingAlternates.removeFirst()
        let attempted = rejectedSources + 1
        let remaining = pendingAlternates
        #if DEBUG
        Self.tracePlayback(
            "source \(attempted) dropped (\(reason)) — trying the next, \(remaining.count) left after it"
        )
        #endif
        teardown()
        engine = next.preferSoftware ? .software : .avPlayer
        recoveredFrom = nil
        load(
            url: next.url,
            startAt: startAt,
            expectedBytes: next.expectedBytes,
            alternates: remaining,
            attempt: attempted
        )
        loadingNote = "Trying another source (\(attempted + 1) of \(attempted + 1 + remaining.count))"
        return true
    }

    /// Reopens at the point a stall gave up, on the viewer's say-so.
    func retryFromStall() {
        guard let url = currentURL, let position = stalledAt else { return }
        recoveredFrom = nil
        reopen(url: url, at: position)
    }

    func skip(by offset: Duration) {
        let target = currentTime + offset
        let clamped = max(.zero, min(target, duration ?? target))
        seek(to: clamped)
    }

    // MARK: - AVPlayer path

    private func loadAVPlayer(url: URL, resumePoint: Duration?) {
        #if DEBUG
        Self.tracePlayback("AVPlayer  (software-decode setting does not apply to this path)")
        // The libVLC path logged its source and this one did not, so an AVPlayer
        // failure left no record of what it had been handed.
        Self.tracePlayback("   source=\(url.absoluteString)")
        #endif
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        avPlayer = player

        // The libVLC path gets `endReached` from its event stream; AVPlayer has
        // no equivalent in the polling above, so without this observer playback
        // simply stopped at the last frame and nothing downstream ever learned
        // the video had finished.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.status = .ended
            }
        }

        // Periodic observation is the only way to drive a scrubber from AVPlayer.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isScrubbing {
                    self.accumulatePlayed(to: .seconds(time.seconds))
                    self.currentTime = .seconds(time.seconds)
                }
                if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = .seconds(seconds)
                }
                // `presentationSize` is zero until the first frame is ready, and
                // AVPlayerItem does not publish it, so it is polled here.
                if let size = player.currentItem?.presentationSize,
                   size.width > 0, size.height > 0, self.videoSize != size {
                    #if DEBUG
                    PlaybackClock.markOnce(
                        "videoSize",
                        "FIRST FRAME  \(Int(size.width))x\(Int(size.height))"
                    )
                    #endif
                    self.videoSize = size
                }
            }
        }

        avStatusTask = Task { [weak self] in
            // AVPlayerItem reports failure asynchronously; polling its status is
            // simpler than KVO here and only runs until the item resolves.
            for await _ in Timer.publish(every: 0.4, on: .main, in: .common).autoconnect().values {
                guard let self, let item = self.avPlayer?.currentItem else { return }
                if item.status == .failed {
                    let reason = item.error?.localizedDescription ?? "This source could not be decoded."
                    #if DEBUG
                    PlaybackClock.mark("AVPlayer item FAILED: \(reason)")
                    #endif
                    if self.stepToNextSource(startAt: self.currentResumePoint, reason: "AVPlayer failed") { return }
                    self.status = .failed(reason)
                    return
                }
                if item.status == .readyToPlay {
                    #if DEBUG
                    PlaybackClock.markOnce("av-ready", "AVPlayer readyToPlay")
                    #endif
                    if let target = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: target)
                    }
                    if self.status == .loading {
                        self.watchdog?.cancel()
                        self.status = .playing
                    }
                    return
                }
            }
        }

        // AVPlayer discards a seek issued before the item is ready, so the
        // resume point waits for readiness the same way the libVLC path does.
        if let resumePoint {
            pendingSeek = resumePoint
        }
        player.play()
        #if DEBUG
        PlaybackClock.mark("AVPlayer play() issued")
        #endif
    }

    // MARK: - Software (libVLC) path

    #if DEBUG
    /// Records which decode path actually ran.
    ///
    /// The colour bug has now survived two fixes aimed at the libVLC path, and I
    /// have no 10-bit HEVC source to reproduce it against. This says plainly
    /// which engine opened the media and whether the software instance was used,
    /// so the next occurrence is diagnosable instead of guessed at.
    /// Where the trace lands.
    ///
    /// A sandboxed app cannot write to the real `/tmp`, so on iOS and tvOS every
    /// write failed silently through `try?` and the log read as "playback was
    /// never attempted" when it had been. The container's own temp directory is
    /// reachable with `devicectl device copy from --source tmp/…`.
    static var traceURL: URL {
        #if os(macOS)
        URL(fileURLWithPath: "/tmp/stream-playback.log")
        #else
        URL.temporaryDirectory.appending(path: "stream-playback.log")
        #endif
    }

    /// Wall-clock stamp with milliseconds.
    ///
    /// `.standard` time formatting rounds to the second, which is coarser than
    /// every leg of a startup this audit needs to separate — an addon response
    /// and a ranker decision landed on the same second and looked simultaneous.
    private static let traceStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss.SSS"
        return formatter
    }()

    static func tracePlayback(_ message: String) {
        let line = "\(traceStamp.string(from: Date()))  \(message)\n"
        let url = traceURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    #endif

    /// Instance pinned to the software video decoder.
    ///
    /// The green/magenta swap on 10-bit HEVC comes from VideoToolbox handing
    /// `samplebufferdisplay` a 10-bit `x420` CVPixelBuffer directly. libVLC's own
    /// log settled this after three wrong guesses:
    ///
    ///   before: `video decoder module "videotoolbox"` -> `output chroma: x420`
    ///   after:  `video decoder module "avcodec"` -> `I0AL -> CVPP -> CVPB`
    ///
    /// `--codec=avcodec` is what actually selects it. Neither `:avcodec-hw=none`
    /// (libVLC 3 spelling) nor `--dec-dev=none` changed the decoder at all — both
    /// were verified inert against the log.
    ///
    /// Switching the decoder alone did not fix it, which places the swap in the
    /// renderer. `samplebufferdisplay` is VLC's newer Metal path for CoreMedia
    /// buffers; libVLC picks video outputs by priority and ignores `--vout`, so
    /// `--force-darwin-legacy-display` is the sanctioned way off it and onto the
    /// OpenGL display.
    ///
    /// `--avcodec-chroma=I420` was tried here and is *not a valid option*: it made
    /// `VLCInstance` throw, `try?` swallowed it, and playback silently fell back
    /// to the shared instance and VideoToolbox. Every argument added here must be
    /// checked against instance creation, which is why the trace below reports
    /// whether this instance actually exists rather than asserting it.
    private static let softwareInstance: VLCInstance? = {
        var arguments = VLCInstance.defaultArguments
        #if os(macOS)
        // macOS only. `caopengllayer` is a Mac module — tvOS and iOS have no
        // OpenGL path at all — so forcing it there left libVLC with no video
        // output to open. On the Apple TV the media opened and then nothing
        // followed: no module selection, no length, no first frame, for as long
        // as it was left running.
        arguments.append("--force-darwin-legacy-display")
        #endif
        return try? VLCInstance(arguments: arguments)
    }()

    #if DEBUG
    /// What the software path will actually use, for the on-screen badge.
    static var softwareInstanceDescription: String {
        guard softwareInstance != nil else { return "INSTANCE FAILED → hardware" }
        #if os(macOS)
        return "vtoolbox+legacy-vout"
        #else
        // No legacy vout off macOS, so saying so was a lie in the one log that
        // would have shown this bug for what it was.
        return "vtoolbox+default-vout"
        #endif
    }
    #endif

    private func loadSoftware(url: URL, resumePoint: Duration?) {
        #if DEBUG
        Self.tracePlayback("libVLC  instance=\(Self.softwareInstanceDescription)")
        // The source URL, so the exact same stream can be opened in another
        // player. Whether the file itself is sound has never been checked, and
        // every fix so far has assumed our pipeline is at fault.
        Self.tracePlayback("   source=\(url.absoluteString)")
        // The same instance the player below gets, or the log describes something
        // that is not what is playing.
        startDecoderLogCapture(instance: Self.softwareInstance ?? .shared)
        #endif
        // Decoder-device selection happens when the instance is built, not per
        // media: libVLC's log showed `using decoder device module "videotoolbox"`
        // even with `:dec-dev=none` set on the media. An earlier instance attempt
        // was blamed for the colour and reverted, wrongly — the log has since
        // shown the same swap on the shared instance.
        // Always this app's own instance, never `VLCInstance.shared`.
        //
        // Which one was used once depended on a "force software decoding"
        // setting, and flipping that setting's default turned playback off on the
        // Apple TV. The setting is gone: it never selected a decoder (see
        // `softwareInstance`, which passes no `--codec`). Measured on
        // the device, same URL, freshly launched process each time: on the
        // dedicated instance the media opens and libVLC logs its whole module
        // chain; on the shared instance nothing follows the open at all — no
        // module selection, no length, no error. Why the shared instance behaves
        // differently is not established; that it does is, repeatedly, so nothing
        // routes through it.
        let player = SwiftVLC.Player(instance: Self.softwareInstance ?? .shared)
        vlcPlayer = player

        // Consume the event stream rather than polling: libVLC pushes state,
        // time, and length changes as they happen.
        eventTask = Task { [weak self] in
            for await event in player.events {
                guard let self else { return }
                if let state = event.stateChanged {
                    #if DEBUG
                    PlaybackClock.markOnce("state-\(state)", "libVLC state=\(state)")
                    #endif
                    switch state {
                    case .playing:
                        // Genuinely started, so the watchdog has nothing to catch.
                        self.watchdog?.cancel()
                        self.status = .playing
                    case .paused: self.status = .paused
                    case .buffering, .opening: self.status = .loading
                    case .error:
                        if self.stepToNextSource(startAt: self.currentResumePoint, reason: "libVLC error") { return }
                        self.status = .failed("This source could not be opened.")
                    case .stopped, .stopping, .idle: break
                    }
                }
                if let time = event.timeChanged, !self.isScrubbing {
                    self.accumulatePlayed(to: time)
                    self.currentTime = time
                }
                #if DEBUG
                if let seekable = event.seekableChanged {
                    Self.tracePlayback("seekable=\(seekable)")
                }
                #endif
                if let length = event.lengthChanged, length > .zero {
                    // What libVLC reports is the remainder after `:start-time=`.
                    // The rest of the app — scrubber, skip clamp, watch state —
                    // means the whole media, so the offset goes back on here.
                    let whole = length + self.resumeOffset
                    #if DEBUG
                    PlaybackClock.markOnce(
                        "length",
                        "libVLC length=\(Int(length.seconds))s"
                        + (self.resumeOffset > .zero
                           ? "  (+\(Int(self.resumeOffset.seconds))s resume = \(Int(whole.seconds))s)"
                           : "")
                    )
                    Self.tracePlayback("length=\(Int(whole.seconds))s")
                    #endif
                    self.duration = whole
                    // Length is the first reliable signal that the media is open
                    // and seekable, so the held resume point is applied here.
                    self.applyPendingSeek(player: player, length: length)
                }
                if event.endReached != nil {
                    self.status = .ended
                }
                // Adaptive streams can change resolution mid-playback, so this is
                // re-read on every event rather than captured once.
                if let size = player.videoSize, size != self.videoSize {
                    #if DEBUG
                    // The decoder only reports dimensions once it has produced a
                    // picture, so this is the closest thing to "first frame".
                    PlaybackClock.markOnce(
                        "videoSize",
                        "FIRST FRAME  \(Int(size.width))x\(Int(size.height))"
                    )
                    #endif
                    self.videoSize = size
                }
                self.refreshTracks(from: player)
            }
        }

        // Opening waits for any previous session to finish releasing. Starting
        // while the old player still held the source is what made a second play
        // hang indefinitely.
        playTask = Task { @MainActor [weak self] in
            // Bounded. Waiting on the drain outright meant a wedged or slow
            // release held the screen black for as long as it took — measured at
            // seven seconds, and SwiftVLC's own ceiling is ten. Past this the new
            // player starts anyway: an occasional collision with a lingering
            // connection is a better failure than a player that will not open.
            var waited = Duration.zero
            let limit = Duration.seconds(2.5)
            while Self.draining > 0, waited < limit {
                try? await Task.sleep(for: .milliseconds(100))
                waited += .milliseconds(100)
            }
            guard let self, !Task.isCancelled else { return }
            #if DEBUG
            if waited > .zero {
                Self.tracePlayback("waited \(waited.seconds)s for the previous session to release")
            }
            #endif
            self.open(url: url, on: player, resumePoint: resumePoint)
        }
    }

    /// Gives up on a source that never opens.
    ///
    /// libVLC has no timeout of its own: handed a slow or wedged link it sits in
    /// its access module indefinitely, producing no events and no error. On screen
    /// that is an endless spinner, indistinguishable from a dead link — which is
    /// exactly how a slow BDRemux and a broken URL looked the same.
    /// Hands back the seconds played since the last time this was asked, and
    /// starts counting again.
    ///
    /// Read-and-reset rather than a running total, because `recordProgress` fires
    /// every fifteen seconds and the store *adds* what it is given — handing over
    /// the cumulative figure each time would count the same minute over and over
    /// and clear the threshold on a film barely started.
    func consumePlayedSeconds() -> Double {
        defer { playedSeconds = 0 }
        return playedSeconds
    }

    /// Adds a time report to the played total, if it looks like playback.
    ///
    /// A backward step is a rewind and a large forward one is a seek; neither is
    /// time spent watching. Rewatching a stretch does count twice, deliberately —
    /// it was watched twice.
    private func accumulatePlayed(to time: Duration) {
        defer { lastTick = time }
        guard status == .playing, let lastTick else { return }
        let step = time.seconds - lastTick.seconds
        guard step > 0, step <= Self.maximumPlaybackStep else { return }
        playedSeconds += step
    }

    /// How close to the length counts as the end.
    ///
    /// Containers routinely report a length a beat longer than the last decodable
    /// frame, so an exact comparison never fires.
    private static let tailWindow: Double = 3

    /// How long the position may sit still inside that window before the media is
    /// treated as finished.
    private static let tailStallTimeout: Double = 6

    /// How long the position may sit still *anywhere else* while the engine says
    /// playing before something is done about it.
    ///
    /// Long enough to sit through a genuine rebuffer on a slow link; short
    /// enough that a frozen frame does not read as the app hanging. libVLC 4
    /// reports no buffering state, so a rebuffer and a hang look identical from
    /// here — which is why the first response is a reopen, not a verdict.
    private static let stallTimeout: Double = 20

    /// The shorter wait for a stall at the spot a reopen already came back to.
    /// The reopen has just fetched the same bytes; if they stop in the same place
    /// there is nothing left to wait for.
    private static let repeatedStallTimeout: Double = 6

    /// A file that ends at the same second twice, this far in, has simply ended.
    ///
    /// Remuxes state a length their picture does not reach — Ash vs Evil Dead
    /// S01E06 gave out at 25:45 of a stated 27:59, S01E04 at 28:09 of 33:11, both
    /// with the episode over and the credits rolled. That is below the completion
    /// threshold, which is a rule about where credits *start*, so those sittings
    /// were treated as faults and sent to another source. Past this fraction a
    /// reproducible end is the end; below it, it is a broken copy.
    private static let endOfContentFraction: Double = 0.8

    /// Ends the sitting when the media has plainly run out but no engine said so.
    ///
    /// Both engines do report the end — AVPlayer through
    /// `didPlayToEndTimeNotification`, libVLC through `endReached` — and when they
    /// do, this never runs. Neither fires when an HTTP source simply stops
    /// delivering bytes: the position stalls a second or two short of the length and
    /// the player sits on the last frame indefinitely, so the film is never marked
    /// finished and the screen never closes. The position is the one signal that is
    /// always present, so it is the one to fall back to.
    /// Polled rather than driven by position updates.
    ///
    /// The condition being watched for is "the position stopped moving", and both
    /// engines emit position updates only when it moves — so hanging this off them
    /// meant it could never fire in exactly the case it exists for.
    /// Not only at the tail. Ash vs Evil Dead S01E04 froze at 28:09 of 33:11:
    /// the MKV demuxer went looking for its seek index, hit end of stream, and
    /// libVLC sat there reporting `playing` with the clock stopped — no end
    /// event, no stop, nothing SwiftVLC could synthesize an end from. The
    /// three-second tail window never applied, so the episode was neither
    /// finished nor advanced, and the only way out was marking it by hand.
    ///
    /// A stall anywhere is now handled in three steps: past the completion
    /// threshold it is the end; before it, the source is reopened once at the
    /// same position, which is also the right answer to a dropped connection;
    /// and a second stall in the same place stops with the position on screen
    /// and the decision — watched, retry, close — handed to the viewer.
    private func startTailWatchdog() {
        tailWatchdog?.cancel()
        tailSince = nil
        stallSince = nil
        var lastSeen: Duration?
        tailWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }

                guard self.status == .playing, !self.isScrubbing,
                      let duration = self.duration, duration > .zero else {
                    self.tailSince = nil
                    self.stallSince = nil
                    lastSeen = self.currentTime
                    continue
                }
                let position = self.currentTime
                let remaining = duration.seconds - position.seconds
                let moved = lastSeen.map { abs(position.seconds - $0.seconds) > 0.25 } ?? true
                lastSeen = position

                if moved {
                    self.tailSince = nil
                    self.stallSince = nil
                    // A recovery that has played on for a while has plainly
                    // worked, so the next stall may be recovered too.
                    if let from = self.recoveredFrom, position > from + .seconds(30) {
                        self.recoveredFrom = nil
                    }
                    continue
                }

                // Inside the tail: containers report a length a beat past the
                // last frame, so a short stall here is simply the end.
                if remaining >= 0, remaining <= Self.tailWindow {
                    let started = self.tailSince ?? .now
                    self.tailSince = started
                    if started.duration(to: .now) >= .seconds(Self.tailStallTimeout) {
                        self.tailSince = nil
                        #if DEBUG
                        Self.tracePlayback(
                            "tail stall at \(Int(position.seconds))s of \(Int(duration.seconds))s — treating as ended"
                        )
                        #endif
                        self.status = .ended
                        return
                    }
                    continue
                }

                // Whether this is the spot the last reopen came back to. A stall
                // that reproduces at the same second is the file ending, not the
                // network; one somewhere else is a new stall.
                let repeated = self.recoveredFrom.map { abs($0.seconds - position.seconds) < 2 } ?? false
                let started = self.stallSince ?? .now
                self.stallSince = started
                let timeout = repeated ? Self.repeatedStallTimeout : Self.stallTimeout
                guard started.duration(to: .now) >= .seconds(timeout) else { continue }
                self.stallSince = nil

                let fraction = position.seconds / duration.seconds
                if fraction >= self.completionThreshold
                    || (repeated && fraction >= Self.endOfContentFraction) {
                    #if DEBUG
                    Self.tracePlayback(
                        "stall at \(Int(position.seconds))s of \(Int(duration.seconds))s"
                        + (repeated ? " reproduced after a reopen" : " past the completion threshold")
                        + " — treating as ended"
                    )
                    #endif
                    self.status = .ended
                    return
                }

                if self.recoveredFrom == nil, let url = self.currentURL {
                    #if DEBUG
                    Self.tracePlayback(
                        "stall at \(Int(position.seconds))s of \(Int(duration.seconds))s — reopening there"
                    )
                    #endif
                    self.recoveredFrom = position
                    // Tears this task down with the rest of the session.
                    self.reopen(url: url, at: position)
                    return
                }

                // The same bytes gave the same stall, so the fault is in this copy
                // of the file: on TorBox, Ash vs Evil Dead died at the same second
                // of the same episode across sittings — a partly cached file that
                // the CDN advertises at full length. Another copy of the episode
                // is the fix, and the ranked list is already here, so step to it
                // at the same position rather than asking the viewer to.
                if self.stepToNextSource(startAt: position, reason: "stall reproduced after a reopen") {
                    return
                }

                #if DEBUG
                Self.tracePlayback(
                    "stall at \(Int(position.seconds))s persisted after a reopen — no other source, stopping"
                )
                #endif
                self.stalledAt = position
                self.status = .failed(
                    "Playback stopped at \(position.timecode) and could not be resumed."
                )
                return
            }
        }
    }

    private func startOpenWatchdog() {
        watchdog?.cancel()
        let budget = pendingAlternates.isEmpty ? Self.openTimeout : Self.openTimeoutWithAlternates
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: budget)
            guard let self, !Task.isCancelled, self.status == .loading else { return }
            #if DEBUG
            Self.tracePlayback("OPEN TIMED OUT after \(budget)")
            #endif
            // Stop the probe as well as the wait. One still in flight would
            // otherwise land afterwards and put the player back into `.loading`.
            self.preflightTask?.cancel()
            // A source that never starts is not the film any more than a
            // placeholder is, so it is stepped past the same way.
            if self.stepToNextSource(startAt: self.currentResumePoint, reason: "open timed out") { return }
            self.tailWatchdog?.cancel()
            self.status = .failed(
                "This source did not start playing. It may be slow or unavailable — try another."
            )
        }
    }

    /// Builds the media and starts it. Separated so the wait above reads as a
    /// wait rather than burying the open inside it.
    private func open(url: URL, on player: SwiftVLC.Player, resumePoint: Duration?) {
        do {
            // Built as a Media rather than played straight from the URL, so
            // per-item decoder options can be attached.
            let media = try Media(url: url)
            // Both two- and three-letter codes: containers are inconsistent about
            // which they declare, and libVLC matches literally.
            let wanted = preferredAudioLanguage.lowercased()
            media.addOption(":audio-language=\(wanted),\(wanted)g,\(Self.threeLetterCode(for: wanted))")

            // Resume is a demuxer start position, not a seek.
            //
            // Seeking once the media reported its length looked right — the first
            // frame was the resume point — and then playback fell back to zero: on
            // a network container the demuxer is not reliably seekable that early,
            // so libVLC accepted the seek and then started from the beginning.
            // `start-time` is applied when the demuxer opens, which has no race.
            if let resumePoint, resumePoint > .seconds(1) {
                // Whole seconds, because that is what the option takes — and the
                // offset has to match what libVLC was actually given, not what it
                // was asked for, or every seek is out by the fraction dropped here.
                let startTime = Duration.seconds(Int(resumePoint.seconds))
                resumeOffset = startTime
                media.addOption(":start-time=\(Int(startTime.seconds))")
                #if DEBUG
                Self.tracePlayback("resume: start-time=\(Int(resumePoint.seconds))s")
                #endif
            }

            try player.play(media)
            #if DEBUG
            PlaybackClock.mark("libVLC play(media) returned")
            #endif

            // Nothing held for the software path any more — `start-time` above
            // does the work. AVPlayer still uses `pendingSeek`, which waits for
            // `readyToPlay`.
            pendingSeek = nil
        } catch {
            // Traced, not just stored. A throw here produced exactly the same log
            // as a hang — header, source, then silence — so three failed plays on
            // the Apple TV were indistinguishable from libVLC never starting.
            #if DEBUG
            Self.tracePlayback("OPEN FAILED: \(error)")
            #endif
            if stepToNextSource(startAt: resumePoint, reason: "open threw") { return }
            status = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    /// Captures libVLC's own account of which decoder and output it chose.
    ///
    /// Three fixes have now been aimed at this colour bug from reasoning alone
    /// and all three missed. This records what libVLC actually negotiates —
    /// codec, chroma, and video output — so the next occurrence is read rather
    /// than guessed.
    private func startDecoderLogCapture(instance: VLCInstance) {
        logTask?.cancel()
        logTask = Task { [weak self] in
            var written = 0
            for await entry in instance.logStream(minimumLevel: .debug) {
                guard self != nil, written < 250 else { return }
                let module = entry.module ?? ""
                let text = entry.message.lowercased()
                // Was a decoder-only filter — "avcodec, videotoolbox, vout,
                // chroma, filter, swscale" — which is upstream of nothing that
                // matters when a source never opens at all. A stall lives in the
                // access and demux modules, and every line from them was being
                // dropped, which is why a wedged open logged "nothing".
                let interesting = [
                    "avcodec", "videotoolbox", "vout", "chroma", "filter", "swscale",
                    "access", "http", "tls", "stream", "demux", "mkv", "mp4", "es",
                    "prefetch", "main", "input"
                ]
                guard interesting.contains(where: { module.contains($0) || text.contains($0) })
                else { continue }
                written += 1
                Self.tracePlayback("   vlc[\(module)] \(entry.message)")
            }
        }
    }
    #endif

    /// Best-effort ISO 639-2 code for the common cases; libVLC is given a list,
    /// so an imperfect extra entry is harmless.
    private static func threeLetterCode(for code: String) -> String {
        Locale(identifier: code).language.languageCode?.identifier(.alpha3) ?? code
    }

    /// Applies a held resume point once the media is genuinely seekable.
    ///
    /// Guarded against a resume point beyond the media's length, which would seek
    /// to the end and immediately fire `endReached`.
    private func applyPendingSeek(player: SwiftVLC.Player, length: Duration) {
        guard let target = pendingSeek else { return }
        pendingSeek = nil

        guard target > .seconds(1), target < length - .seconds(5) else { return }
        try? player.seek(to: target)
        currentTime = target
    }

    // MARK: - Tracks

    private func refreshTracks(from player: SwiftVLC.Player) {
        let audio = player.audioTracks.map(Self.map)
        let subtitles = player.subtitleTracks.map(Self.map)

        if audio != audioTracks { audioTracks = audio }
        if subtitles != subtitleTracks { subtitleTracks = subtitles }

        #if DEBUG
        // What the container actually offers, once. The automatic language pick
        // matches on `track.language`, so when it lands on the wrong language the
        // only useful question is whether the tracks are tagged at all.
        if !hasTracedTracks, !audio.isEmpty {
            hasTracedTracks = true
            let listed = player.audioTracks.map {
                "\($0.name) [lang=\($0.language ?? "nil") codec=\($0.codecString ?? "nil")]"
            }
            Self.tracePlayback("audio tracks: \(listed.joined(separator: " | "))")
            Self.tracePlayback(
                "audio selected: \(player.selectedAudioTrack?.language ?? "nil")"
                + "  wanted: \(preferredAudioLanguage)"
            )
        }
        #endif

        applyPreferredAudioIfNeeded(player: player)
        disableMismatchedSubtitlesIfNeeded(player: player)
    }

    /// Turns off subtitles that aren't in the preferred language.
    ///
    /// Containers frequently mark a foreign-language subtitle track as "forced",
    /// and libVLC honours that — so an English audio track ends up with Polish
    /// subtitles burned over it. Only forced subtitles *in the preferred language*
    /// are worth keeping automatically.
    private func disableMismatchedSubtitlesIfNeeded(player: SwiftVLC.Player) {
        guard !hasCheckedSubtitles, !player.subtitleTracks.isEmpty else { return }
        hasCheckedSubtitles = true

        guard let selected = player.selectedSubtitleTrack else { return }
        let wanted = preferredAudioLanguage.lowercased().prefix(2)

        if selected.language?.lowercased().hasPrefix(wanted) != true {
            player.selectedSubtitleTrack = nil
            subtitleTracks = player.subtitleTracks.map(Self.map)
        }
    }

    private static func map(_ track: SwiftVLC.Track) -> MediaTrack {
        MediaTrack(
            id: track.id,
            name: track.name,
            language: track.language,
            isSelected: track.isSelected
        )
    }

    /// Chooses the best track in the preferred language as tracks appear.
    /// Manual choices disable automatic selection for the current playback.
    private func applyPreferredAudioIfNeeded(player: SwiftVLC.Player) {
        guard !hasUserChosenAudio, player.audioTracks.count > 1 else { return }
        // Re-runs whenever the track list changes. Committing on the first
        // non-empty set chose a Russian dub from a two-track snapshot of a
        // five-track file, because the rest had not been demuxed yet.
        let ids = player.audioTracks.map(\.id)
        guard ids != lastAudioTrackIDs else { return }
        lastAudioTrackIDs = ids

        let candidates = player.audioTracks.filter {
            Self.language($0.language, matches: preferredAudioLanguage)
        }
        guard !candidates.isEmpty else { return }

        // Highest score wins; earlier tracks win ties, so a release that lists
        // them sensibly keeps its own order.
        var best = candidates[0]
        var bestScore = Self.audioPreferenceScore(best)
        for track in candidates.dropFirst() {
            let score = Self.audioPreferenceScore(track)
            if score > bestScore {
                best = track
                bestScore = score
            }
        }

        #if DEBUG
        Self.tracePlayback(
            "audio chose: \(best.name) (score \(bestScore))"
            + " from \(candidates.count) candidate(s)"
        )
        #endif
        guard player.selectedAudioTrack?.id != best.id else { return }
        player.selectedAudioTrack = best
        audioTracks = player.audioTracks.map(Self.map)
    }

    /// Whether a container's language field means the preferred language.
    ///
    /// The field is release-supplied and inconsistent: it arrives as `en`, `eng`,
    /// or the spelled-out `English`. Prefix matching alone handles the first three
    /// and "English", but breaks on languages whose name does not start with their
    /// code — `de` never matches "German" — so the spelled-out name is compared
    /// explicitly too.
    private static func language(_ value: String?, matches preferred: String) -> Bool {
        guard let value = value?.lowercased(), !value.isEmpty else { return false }
        let code = preferred.lowercased().prefix(2)
        if value.hasPrefix(code) { return true }
        let english = Locale(identifier: "en").localizedString(forLanguageCode: String(code))
        return value == english?.lowercased()
    }

    private static func audioPreferenceScore(_ track: SwiftVLC.Track) -> Int {
        #if os(macOS)
        let preferCompatibleCodec = false
        #else
        // Retain the existing mobile workaround for silent HD audio tracks.
        let preferCompatibleCodec = true
        #endif
        return AudioTrackPreference.score(
            name: track.name, description: track.trackDescription,
            codec: track.codecString, preferCompatibleCodec: preferCompatibleCodec
        )
    }

    func selectAudioTrack(id: String) {
        guard let player = vlcPlayer,
              let track = player.audioTracks.first(where: { $0.id == id })
        else { return }
        // An explicit choice must stick, so the automatic pass is disabled.
        hasUserChosenAudio = true
        player.selectedAudioTrack = track
        audioTracks = player.audioTracks.map(Self.map)
    }

    func selectSubtitleTrack(id: String?) {
        // AVPlayer has no equivalent, and `subtitleTracks` is only ever populated
        // from libVLC — so on that path this is a no-op and the menu is empty.
        guard let player = vlcPlayer else { return }
        if let id {
            let match = player.subtitleTracks.first { $0.id == id }
            #if DEBUG
            Self.tracePlayback(
                "subtitle select id=\(id) matched=\(match?.name ?? "NONE")"
                + " of \(player.subtitleTracks.map(\.id).joined(separator: ","))"
            )
            #endif
            player.selectedSubtitleTrack = match
        } else {
            player.selectedSubtitleTrack = nil
        }
        subtitleTracks = player.subtitleTracks.map(Self.map)
        #if DEBUG
        Self.tracePlayback(
            "subtitle now selected: \(player.selectedSubtitleTrack?.name ?? "off")"
        )
        #endif
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        // Without .playback, audio is muted by the ring switch and stops on lock.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        // A call, an alarm or Siri takes the audio and the system stops
        // playback. Without this the status stayed `.playing` and the overlay
        // offered a pause button for a film that was not moving.
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated {
                if began { self?.pause() }
            }
        }
        #endif
    }
}

#if DEBUG
/// Stopwatch for one "press Play → first frame", written into the trace log.
///
/// The trace already recorded *what* happened; nothing recorded *when*, beyond a
/// timestamp rounded to the second. Every leg of a startup — addon response,
/// ranker decision, player open, first frame — is shorter than that, so the
/// question "where do the seconds go" could not be answered from the log at all.
/// Marks are relative to the press, which is the only zero a viewer cares about.
@MainActor
enum PlaybackClock {
    private static var start: ContinuousClock.Instant?

    /// Restarts the stopwatch. Called on each Play press, so a second play in one
    /// session measures itself rather than continuing the first one's clock.
    static func begin(_ label: String) {
        start = .now
        seen = []
        PlaybackController.tracePlayback("⏱ T+0ms       \(label)")
    }

    /// The `stream://play` deep link bypasses the launcher, so a run started
    /// there has no press to measure from; the first mark becomes the zero.
    static func mark(_ label: String) {
        guard let start else {
            begin(label)
            return
        }
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        let stamp = String(format: "T+%.0fms", milliseconds)
        PlaybackController.tracePlayback("⏱ \(stamp.padding(toLength: 12, withPad: " ", startingAt: 0))\(label)")
    }

    /// Marks only the first time a given key is seen in the current run — for
    /// events the engines emit repeatedly, like a resolution change.
    static func markOnce(_ key: String, _ label: String) {
        guard !seen.contains(key) else { return }
        seen.insert(key)
        mark(label)
    }

    private static var seen: Set<String> = []
}
#endif

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// "1:23:45" or "4:05".
    var timecode: String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
