import Foundation
import Observation
import os
import Security
import StreamCore

/// Root application state: installed addons, the protocol client, and user preferences.
@Observable
@MainActor
final class AppModel {
    let registry: AddonRegistry
    let client: AddonClient
    let resolver: StreamResolver
    let watchState: WatchStateStore
    let watchlist: WatchlistStore
    let tmdb = TMDBClient()
    let trakt: TraktSync
    let remoteSync: RemoteSync
    /// Reports completed playback to Screen when a server URL and token are configured.
    private(set) var screen: ScreenScrobbler?

    /// Films in cinemas, which tvOS hides because none of them will play.
    ///
    /// Held here rather than on `HomeViewModel` because Search needs the same list
    /// and has no reason to know about the home page.
    private(set) var theatrical = TheatricalWindow()

    /// Screen device token, stored in Keychain because it grants library write access.
    var screenToken: String {
        didSet {
            lastScreenTokenWrite = Keychain.set(screenToken, for: Self.screenTokenKey)
            configureScreen()
        }
    }

    /// No default server: each user supplies their own Screen endpoint.
    var screenEndpointURL: String {
        didSet {
            defaults.set(screenEndpointURL, forKey: Self.screenEndpointKey)
            configureScreen()
        }
    }

    /// Last Keychain write result, shown in Settings if saving the token fails.
    private(set) var lastScreenTokenWrite: OSStatus = errSecSuccess

    /// Optional enrichment key. Stored in preferences, never in the binary, so it
    /// stays out of source control and can be rotated without a rebuild.
    var tmdbApiKey: String {
        didSet { defaults.set(tmdbApiKey, forKey: Self.tmdbKey) }
    }

    var preferences: RankingPreferences {
        didSet { savePreferences() }
    }

    private let cloud = CloudKeyValueStore.shared

    /// Whether cloud sync is available for this build and account.
    var isCloudSyncAvailable: Bool { cloud.isAvailable }

    /// Enables addon-level error details for troubleshooting. Off by default.
    var showsDiagnostics: Bool {
        didSet { defaults.set(showsDiagnostics, forKey: Self.diagnosticsKey) }
    }

    /// ISO 639 code preferred for audio, and for keeping forced subtitles.
    /// Defaults to the device's own language rather than assuming English.
    var preferredLanguage: String {
        didSet { defaults.set(preferredLanguage, forKey: Self.languageKey) }
    }

    /// Nonfatal addon error displayed in the UI.
    var lastError: String?

    /// How deep the browse stack currently is.
    ///
    /// The macOS window toolbar belongs to the split view, so its items persist
    /// across pushes. Detail screens raise this so root-level navigation controls
    /// can step out of the way and leave just the back chevron.

    /// Set by a `stream://` URL and consumed by whichever view owns that screen.
    var pendingLink: DeepLink?

    /// Home's navigation stack.
    ///
    /// On the model rather than in `HomeView`'s `@State` because the macOS toolbar
    /// has to empty it before swapping the split view's detail column. Changing
    /// that column while a `NavigationStack`'s bound path is non-empty makes
    /// SwiftUI assert in `NavigationColumnState.boundPathChange` — going to Search
    /// from a movie page crashed the app outright.
    var homePath: [MetaPreview] = []

    /// What narrows Home: one genre, or the in-cinemas list.
    ///
    /// On the model rather than in `HomeView` because tvOS drives it from the top
    /// bar, which is a sibling of Home rather than a child of it. Every platform's
    /// menu writes here and Home reacts, so there is one path rather than one per
    /// menu — the TV's "In theatres" item sat in a menu the TV never rendered.
    enum HomeFilter: Hashable {
        case genre(String)
        case inTheatres

        var label: String {
            switch self {
            case .genre(let genre): genre
            case .inTheatres: "In theatres"
            }
        }
    }
    var homeFilter: HomeFilter?

    /// macOS sidebar visibility. Lives here rather than in `MacRootView` so the
    /// menu-bar command and the toolbar menu drive one value; a shortcut declared
    /// inside a toolbar menu never registered with the responder chain.
    var isSidebarVisible = false


    func handle(url: URL) {
        guard let link = DeepLink(url: url) else { return }
        #if DEBUG && os(macOS)
        // Acts immediately rather than queueing: a snapshot is an instruction to
        // the running window, not a destination to navigate to.
        if case .fullScreen = link {
            MacPlayerWindow.toggleFullScreen()
            return
        }
        if case .snapshot(let path, let window) = link {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                WindowSnapshot.capture(to: path, window: window)
            }
            return
        }
        if case .seek(let to, let fast) = link {
            PlaybackController.debugSeekProbe(to: to, fast: fast)
            return
        }
        #endif
        // Every open window hosts a copy of the link handlers, so a link
        // published to all of them ran once per window — one `stream://play`
        // opened, closed and reopened the player several times over, leaving two
        // libVLC instances decoding the same source. The token lets the first
        // handler to see a link claim it.
        linkToken &+= 1
        pendingLink = link
    }

    /// Publishes a link that did not arrive as a URL — currently only the one
    /// passed at launch.
    ///
    /// Must go through the same token bump as `handle(url:)`. Assigning
    /// `pendingLink` directly skipped it, and since both counters start at zero
    /// the first `claimLink()` found them equal and returned false — so on macOS,
    /// where the handler claims before acting, every launch link was dropped on
    /// the guard. `-streamLink stream://settings` did nothing at all, and the
    /// `stream://play` route it exists for could not be driven from a script.
    /// iOS and tvOS were unaffected only because `HomeView` never claims.
    func present(link: DeepLink?) {
        guard let link else { return }
        linkToken &+= 1
        pendingLink = link
    }

    /// True for the first caller after each new link, false for every other
    /// window's copy of the same handler.
    func claimLink() -> Bool {
        guard claimedToken != linkToken else { return false }
        claimedToken = linkToken
        return true
    }

    private var linkToken = 0
    private var claimedToken = 0

    private let defaults: UserDefaults
    private static let preferencesKey = "rankingPreferences"
    private static let didSeedKey = "didSeedDefaultAddons"
    private static let diagnosticsKey = "showsDiagnostics"
    private static let tmdbKey = "tmdbApiKey"
    private static let languageKey = "preferredLanguage"
    private static let screenLogger = Logger(subsystem: "com.stream.core", category: "Screen")
    private static let screenTokenKey = "screenDeviceToken"
    private static let screenEndpointKey = "screenEndpointURL"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showsDiagnostics = defaults.bool(forKey: Self.diagnosticsKey)
        self.tmdbApiKey = defaults.string(forKey: Self.tmdbKey) ?? ""
        self.screenToken = Keychain.get(Self.screenTokenKey) ?? ""
        self.screenEndpointURL = defaults.string(forKey: Self.screenEndpointKey) ?? ""
        self.preferredLanguage = defaults.string(forKey: Self.languageKey)
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        // Shared across iPhone, Mac, and Apple TV via one iCloud key-value store.
        // Nil-safe by design: signed out of iCloud, everything still works locally.
        let cloud = CloudKeyValueStore.shared
        self.registry = AddonRegistry(defaults: defaults, cloud: cloud)
        self.watchState = WatchStateStore(defaults: defaults, cloud: cloud)
        self.watchlist = WatchlistStore(defaults: defaults, cloud: cloud)
        self.trakt = TraktSync(defaults: defaults)
        self.remoteSync = RemoteSync(defaults: defaults)
        let client = AddonClient()
        self.client = client
        self.resolver = StreamResolver(client: client)

        // Prefer whatever iCloud holds; fall back to the local copy, then defaults.
        let preferenceData = cloud.data(forKey: Self.preferencesKey)
            ?? defaults.data(forKey: Self.preferencesKey)
        if let preferenceData,
           let decoded = try? JSONDecoder().decode(RankingPreferences.self, from: preferenceData) {
            self.preferences = decoded
        } else {
            self.preferences = RankingPreferences()
        }

        observePreferenceSync()

        // Any addon change now pushes, so installing on one device propagates
        // without waiting for something unrelated to trigger a sync.
        registry.onChange = { [weak self] in
            self?.pushRemoteState()
        }
        watchlist.onChange = { [weak self] in
            self?.pushRemoteState()
        }
        // One place a watch becomes complete, so one place to report it from.
        watchState.onFinished = { [weak self] record in
            self?.reportToScreen(record)
            self?.retireFromWatchlist(record)
        }
        configureScreen()
    }

    // MARK: - Screen

    /// What happened to a token the viewer entered.
    ///
    /// Three outcomes, not two: pressing Return on an empty field is not a failure
    /// and must not produce a storage error, which is the whole reason this is not
    /// a `Bool`.
    enum TokenSaveOutcome: Equatable {
        case saved
        /// Nothing was entered. A no-op, reported so callers stay silent.
        case ignored
        /// Accepted for this session, but the keychain refused to keep it.
        case notPersisted(OSStatus)
    }

    /// Stores a newly entered Screen token.
    ///
    /// Assigns first and reports persistence second. Refusing to assign on a failed
    /// write would leave `screen` nil and the whole section unchanged — which looks
    /// exactly like nothing happened, and takes Screen out for the rest of the
    /// session on top of it. The token works now either way; only its survival
    /// across a relaunch is in doubt.
    ///
    /// One write, not two: the assignment's own `didSet` is what persists.
    @discardableResult
    func saveScreenToken(_ token: String) -> TokenSaveOutcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        screenToken = trimmed
        return lastScreenTokenWrite == errSecSuccess
            ? .saved
            : .notPersisted(lastScreenTokenWrite)
    }

    /// Forgets the Screen token on purpose.
    ///
    /// Needed because `Keychain.set` will no longer erase a stored secret when it
    /// is handed an empty string — clearing the settings field is not, by itself,
    /// evidence that the viewer meant to disconnect.
    func forgetScreenToken() {
        Keychain.clear(Self.screenTokenKey)
        screenToken = ""
        screen = nil
    }

    private func configureScreen() {
        guard !screenToken.isEmpty,
              let endpoint = URL(string: screenEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil else {
            screen = nil
            return
        }
        let configuration = ScreenScrobbler.Configuration(
            endpoint: endpoint,
            token: screenToken
        )
        if let screen {
            Task { await screen.configure(configuration) }
        } else {
            screen = ScreenScrobbler(configuration: configuration)
        }
    }

    /// Reports a film you are partway through, so Screen can show it in Up next.
    ///
    /// Films only. Screen records whole episodes, and half an episode is not a
    /// watched episode — so a part-watched series entry is deliberately not sent.
    ///
    /// Reported once from the first checkpoint that clears the resumable bar, and
    /// again when the player closes. It used to be the closing report alone, which
    /// meant a film you were *still watching* had never been sent — and a film you
    /// are still watching is the one Up next most needs to know about. Returns
    /// whether anything was enqueued, so the caller can latch its once-a-sitting
    /// flag on the send rather than on the attempt.
    @discardableResult
    func reportProgressToScreen(_ record: WatchProgress) -> Bool {
        Self.screenLogger.info(
            "progress report considered: \(record.videoId, privacy: .public) type=\(String(describing: record.type), privacy: .public) resumable=\(record.isResumable, privacy: .public) finished=\(record.isFinished, privacy: .public) hasDuration=\(record.duration != nil, privacy: .public) configured=\(self.screen != nil, privacy: .public)"
        )
        guard let screen,
              record.type == .movie,
              !record.isFinished,
              record.isResumable,
              let fraction = record.duration.map({ _ in record.fractionComplete }),
              fraction > 0
        else { return false }
        Task {
            await screen.record(
                videoId: record.videoId,
                title: record.metaName,
                progress: fraction
            )
        }
        return true
    }

    /// Drops a finished film from the watchlist.
    ///
    /// The watchlist is a list of things to watch, so a film you have just watched
    /// does not belong on it — leaving it there means the row slowly fills with
    /// everything you have already seen and stops being a queue.
    ///
    /// Films only. One finished episode says nothing about whether you are done
    /// with the series, and removing a show the moment its first episode ends would
    /// be the opposite of useful.
    private func retireFromWatchlist(_ record: WatchProgress) {
        guard record.type == .movie, watchlist.contains(record.metaId) else { return }
        watchlist.remove(record.metaId)
    }

    /// Reports a finished watch, and never lets that failure reach playback.
    ///
    /// Screen keys on the same protocol video id already stored, so `videoId` goes
    /// across unchanged — `tt0903747` for a film, `tt0903747:1:5` for an episode.
    private func reportToScreen(_ record: WatchProgress) {
        guard let screen else { return }
        Task { await screen.record(videoId: record.videoId, title: record.metaName) }
    }

    /// Sends anything queued while offline. Called wherever the app comes back to
    /// life, because a television is offline for days at a time.
    func flushScreen() async {
        guard let screen else { return }
        await screen.flush()
    }

    /// Installs the metadata-only default addon on first launch so the app opens with
    /// content instead of an empty shell. Runs once — a user who removes Cinemeta
    /// should not have it silently reappear.
    func seedDefaultAddonsIfNeeded() async {
        guard !defaults.bool(forKey: Self.didSeedKey) else { return }
        // Something is installed already — restored by sync, or added by hand
        // before this ever succeeded. Nothing to seed, and nothing to retry.
        guard registry.addons.isEmpty else {
            defaults.set(true, forKey: Self.didSeedKey)
            return
        }

        var installedAny = false
        for urlString in DefaultAddons.firstRun {
            do {
                let addon = try await client.installAddon(from: urlString)
                registry.install(addon)
                installedAny = true
            } catch {
                lastError = "Could not install \(urlString): \(error.localizedDescription)"
            }
        }
        // Marked done only once it has actually happened. Setting the flag first
        // meant a first launch with no network left the app with no addons, and
        // no launch after it would try again.
        if installedAny {
            defaults.set(true, forKey: Self.didSeedKey)
        }
    }

    /// Pulls every configured sync source. Safe on every launch — each no-ops when
    /// it isn't set up, and the two are complementary rather than competing:
    /// Trakt carries watch progress, the endpoint additionally carries addons and
    /// preferences.
    func syncOnLaunch() async {
        // Coalesced. The scene becoming active and Home's own task both ask for
        // this at launch, which ran two remote pulls, two Trakt pulls and two
        // TMDB requests at once. A second caller now joins the one in flight.
        if let running = launchSync {
            await running.value
            return
        }
        let task = Task { await performLaunchSync() }
        launchSync = task
        await task.value
        launchSync = nil
    }

    private var launchSync: Task<Void, Never>?

    private func performLaunchSync() async {
        if remoteSync.isConfigured {
            if let synced = await remoteSync.pull(
                registry: registry,
                watchState: watchState,
                watchlist: watchlist,
                currentPreferences: { self.preferences }
            ), synced != preferences {
                // Only when they actually differ. Assigning runs `didSet`, which
                // saves and schedules a push — so a pull that changed nothing
                // still uploaded, and on a timer that is a loop.
                preferences = synced
            }
            if remoteSync.state == .idle, remoteSync.lastSync != nil { pushRemoteState() }
        }
        if trakt.isConnected {
            await trakt.pull(into: watchState)
        }
        await flushScreen()
        await refreshTheatricalWindow()
    }

    /// Refreshes the in-cinemas list. Silent without a TMDB key, like every other
    /// enrichment — and an empty window simply hides nothing.
    func refreshTheatricalWindow() async {
        guard !tmdbApiKey.isEmpty else {
            theatrical = TheatricalWindow()
            return
        }
        theatrical = TheatricalWindow(nowPlaying: await tmdb.nowPlaying(apiKey: tmdbApiKey))
    }

    /// A lighter pull, for refreshing while the app is open.
    ///
    /// `syncOnLaunch` also pulls Trakt, which is a third-party API with its own
    /// rate limits and no business being called every minute.
    func refreshRemoteState() async {
        guard remoteSync.isConfigured else {
            #if DEBUG
            PlaybackController.tracePlayback("sync: skipped — no endpoint or token configured")
            #endif
            return
        }
        if let synced = await remoteSync.pull(
            registry: registry,
            watchState: watchState,
            watchlist: watchlist,
            currentPreferences: { self.preferences }
        ), synced != preferences {
            preferences = synced
        }
        if remoteSync.state == .idle, remoteSync.lastSync != nil { pushRemoteState() }
        #if DEBUG
        PlaybackController.tracePlayback("sync: refreshed from the endpoint")
        #endif
    }

    /// Uploads current state. Debounced inside `RemoteSync`.
    func pushRemoteState() {
        remoteSync.schedulePush(
            registry: registry,
            watchState: watchState,
            watchlist: watchlist,
            preferences: preferences
        )
    }

    func installAddon(from urlString: String) async throws {
        let addon = try await client.installAddon(from: urlString)
        registry.install(addon)
    }

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
        cloud.set(data, forKey: Self.preferencesKey)
        pushRemoteState()
    }

    /// Adopts preferences changed on another device. Last writer wins — ranking
    /// settings are a single coherent choice, not a set to merge.
    private func observePreferenceSync() {
        cloud.observe(key: Self.preferencesKey) { [weak self] data in
            guard let self, let data,
                  let incoming = try? JSONDecoder().decode(RankingPreferences.self, from: data),
                  incoming != preferences
            else { return }
            // Assign to the backing store so `didSet` does not echo it back.
            defaults.set(data, forKey: Self.preferencesKey)
            preferences = incoming
        }
    }
}
