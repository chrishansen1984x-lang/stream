import SwiftUI
import StreamCore

@Observable
@MainActor
final class HomeViewModel {
    struct ShelfState: Identifiable {
        let source: CatalogSource
        /// What the catalog returned, before the in-cinemas filter. Kept so the
        /// filter can be re-applied when the list arrives without refetching every
        /// shelf — the list is fetched by `syncOnLaunch`, which races this load.
        var allItems: [MetaPreview] = []
        var items: [MetaPreview] = []
        var isLoading = true
        /// The technical reason this shelf is empty — "Addon returned HTTP 502",
        /// a decoder complaint. Held so diagnostics can show it, never shown to a
        /// viewer who has not asked for it.
        var failureDetail: String?

        var id: String { source.id }
    }

    private(set) var shelves: [ShelfState] = []
    private(set) var featuredItems: [MetaPreview] = []

    /// The hero currently shown, for callers that only need one.
    var featured: MetaPreview? { featuredItems.first }
    private(set) var hasLoadedOnce = false
    private(set) var genre: String?
    private(set) var inTheatres: [TMDBClient.TMDBTitle] = []
    /// tvOS treats In theatres as a filter selection rather than a standing shelf.
    ///
    /// On a TV the home page is a long scroll driven by a remote, and a row you
    /// pass on the way to the catalogs every single time costs more than it gives.
    /// It is still one press away, in the same menu as the genres.
    private(set) var showsInTheatres = false
    /// Applied to every catalog result. Empty off tvOS, so nothing is hidden there.
    private var theatrical = TheatricalWindow()
    private(set) var resumeFeed: [ResumeEntry] = []
    /// Full metadata for hero titles, keyed by id.
    ///
    /// Catalog entries frequently carry no synopsis — Cinemeta's shelves omit it
    /// — so the banner had nothing to show where the detail page shows a
    /// paragraph. Fetched per hero as it is paged to, and kept, so paging back
    /// does not re-request.
    private(set) var featuredDetails: [String: MetaDetail] = [:]
    /// Age classification for hero titles, keyed by id.
    ///
    /// Cinemeta carries no certification, so it comes from TMDB — the same request
    /// the detail page makes, and `TMDBClient` caches per id, so opening the title
    /// afterwards costs nothing.
    private(set) var featuredCertifications: [String: String] = [:]

    func loadFeaturedDetail(
        for item: MetaPreview?,
        registry: AddonRegistry,
        client: AddonClient,
        tmdb: TMDBClient,
        apiKey: String
    ) async {
        guard let item, featuredDetails[item.id] == nil else { return }
        for addon in registry.addons(providing: .meta, type: item.type, id: item.id) {
            guard let detail = try? await client.meta(from: addon, type: item.type, id: item.id) else {
                continue
            }
            featuredDetails[item.id] = detail
            // Needs the TMDB id, which only arrives with the metadata above.
            if let tmdbId = detail.moviedbId,
               let certification = await tmdb.enrichment(
                   tmdbId: tmdbId, type: detail.type, apiKey: apiKey
               )?.certification {
                featuredCertifications[item.id] = certification
            }
            return
        }
    }

    /// Films currently in cinemas.
    ///
    /// The only shelf not backed by an addon — no addon publishes a theatrical
    /// window. Silently absent without a TMDB key, like every other enrichment.
    func loadInTheatres(tmdb: TMDBClient, apiKey: String) async {
        guard !apiKey.isEmpty else {
            inTheatres = []
            return
        }
        inTheatres = await tmdb.nowPlaying(apiKey: apiKey)
    }

    /// Re-applies the in-cinemas filter to shelves already on screen.
    ///
    /// The list is fetched by `syncOnLaunch` and the shelves by this view model, and
    /// neither waits for the other — so on a cold launch the first shelves land
    /// unfiltered. Re-filtering what is already held costs nothing; refetching every
    /// catalog to hide two rows would be absurd.
    func applyTheatrical(_ window: TheatricalWindow) {
        guard window != theatrical else { return }
        theatrical = window
        for index in shelves.indices {
            shelves[index].items = shelves[index].allItems.filter { !window.hides($0) }
        }
        updateFeatured()
    }

    /// Shows only what is in cinemas, as a filter rather than a shelf.
    ///
    /// Catalogs are dropped rather than filtered: no addon publishes a theatrical
    /// window, so there is nothing to intersect them with.
    func showInTheatres(tmdb: TMDBClient, apiKey: String) async {
        showsInTheatres = true
        genre = nil
        shelves = []
        featuredItems = []
        await loadInTheatres(tmdb: tmdb, apiKey: apiKey)
        hasLoadedOnce = true
    }

    /// Every genre any installed catalog advertises, deduplicated.
    static func availableGenres(registry: AddonRegistry) -> [String] {
        var seen = Set<String>()
        return registry.homeCatalogs
            .flatMap(\.catalog.availableGenres)
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    /// Loads every home catalog concurrently.
    ///
    /// Each shelf updates independently — one slow or dead addon must not hold up
    /// the rest of the screen.
    func load(
        registry: AddonRegistry,
        client: AddonClient,
        genre: String? = nil,
        hiding theatrical: TheatricalWindow = TheatricalWindow()
    ) async {
        self.genre = genre
        showsInTheatres = false
        self.theatrical = theatrical
        // A genre filter only applies to catalogs that advertise it; the rest are
        // dropped rather than shown unfiltered, which would be misleading.
        let sources = genre.map { wanted in
            registry.homeCatalogs.filter { $0.catalog.availableGenres.contains(wanted) }
        } ?? registry.homeCatalogs

        shelves = sources.map { ShelfState(source: $0) }
        featuredItems = []

        guard !sources.isEmpty else {
            hasLoadedOnce = true
            return
        }

        await withTaskGroup(of: (String, Result<[MetaPreview], any Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let response = try await client.catalog(
                            from: source.addon,
                            type: source.catalog.type,
                            id: source.catalog.id,
                            extra: genre.map { [.genre($0)] } ?? []
                        )
                        return (source.id, .success(response.metas))
                    } catch {
                        return (source.id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                guard let index = shelves.firstIndex(where: { $0.id == id }) else { continue }
                shelves[index].isLoading = false
                switch result {
                case .success(let metas):
                    // A film still in cinemas has no stream behind it, so a shelf
                    // that lists it is offering something that cannot play.
                    shelves[index].allItems = metas
                    shelves[index].items = metas.filter { !theatrical.hides($0) }
                case .failure(let error):
                    shelves[index].failureDetail = Self.describe(error)
                }
                updateFeatured()
            }
        }

        hasLoadedOnce = true
    }

    /// Reloads one shelf after a failure.
    ///
    /// A flaky addon used to leave a permanent hole on Home that only relaunching
    /// the app would fill: the row stated its error and offered nothing to do about
    /// it. Catalogs fail transiently far more often than permanently, so the row
    /// retries itself rather than making the viewer reload the whole screen and
    /// re-fetch the shelves that did work.
    func reload(shelf id: String, client: AddonClient) async {
        guard let start = shelves.firstIndex(where: { $0.id == id }) else { return }
        let source = shelves[start].source
        shelves[start].failureDetail = nil
        shelves[start].isLoading = true

        let result: Result<[MetaPreview], any Error>
        do {
            let response = try await client.catalog(
                from: source.addon,
                type: source.catalog.type,
                id: source.catalog.id,
                extra: genre.map { [.genre($0)] } ?? []
            )
            result = .success(response.metas)
        } catch {
            result = .failure(error)
        }

        // Re-find the row: `load` may have rebuilt `shelves` while this was in
        // flight, in which case the old index points at a different catalog.
        guard let index = shelves.firstIndex(where: { $0.id == id }) else { return }
        shelves[index].isLoading = false
        switch result {
        case .success(let metas):
            shelves[index].allItems = metas
            shelves[index].items = metas.filter { !theatrical.hides($0) }
        case .failure(let error): shelves[index].failureDetail = Self.describe(error)
        }
        updateFeatured()
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Fetches titles and artwork for watch records that have none.
    ///
    /// Progress is recorded from the player, which may not know the parent title —
    /// and any record written before snapshots existed has neither. Without this
    /// they render as blank tiles labelled "Continue".
    /// Builds the continue-watching shelf.
    ///
    /// Needs metadata, not just progress records: after finishing S02E03 the row
    /// should offer S02E04, and no record for S02E04 exists yet. One lookup per
    /// title, not per record.
    func buildResumeFeed(
        watchState: WatchStateStore,
        registry: AddonRegistry,
        client: AddonClient
    ) async {
        let progress = watchState.records
        let candidates = ResumeFeed.candidates(in: progress)
        guard !candidates.isEmpty else {
            resumeFeed = []
            return
        }

        // Providers are resolved on the main actor up front: the registry is
        // main-actor isolated, so looking them up inside the task group would
        // hop back for every candidate.
        let work = candidates.map { candidate in
            (
                candidate: candidate,
                providers: registry.addons(
                    providing: .meta,
                    type: candidate.type,
                    id: candidate.metaId
                )
            )
        }

        let metas = await withTaskGroup(of: MetaDetail?.self) { group in
            for item in work {
                group.addTask {
                    for addon in item.providers {
                        if let detail = try? await client.meta(
                            from: addon,
                            type: item.candidate.type,
                            id: item.candidate.metaId
                        ) {
                            return detail
                        }
                    }
                    return nil
                }
            }
            var collected: [MetaDetail] = []
            for await meta in group {
                if let meta { collected.append(meta) }
            }
            return collected
        }

        let rebuilt = metas
            .compactMap { ResumeFeed.entry(meta: $0, progress: progress) }

        // Rows whose metadata did not come back are kept, not dropped.
        //
        // `try? await client.meta` swallows every failure, so a flaky addon simply
        // produced fewer entries — and assigning the result wholesale deleted those
        // titles from a shelf already on screen. With the refresh running every 45
        // seconds, one bad moment emptied Continue watching and the next rebuilt it,
        // silently, over and over. The progress records are local and were never in
        // doubt; only the artwork lookup failed, and a stale row is better than a
        // vanished one.
        let recovered = resumeFeed.filter { existing in
            !rebuilt.contains { $0.metaId == existing.metaId }
                && progress.values.contains { $0.metaId == existing.metaId }
                && watchState.records[existing.videoId]?.isFinished != true
        }
        resumeFeed = (rebuilt + recovered)
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Candidates for the hero, in shelf order.
    ///
    /// Backdrop art is required — the hero is a wide banner and a poster-only item
    /// looks broken in it. One per title, and capped: this is a shortlist to page
    /// through, not a second catalogue.
    ///
    /// Previously this picked the single first match and never changed, so the
    /// hero was whatever the first addon happened to return first.
    private func updateFeatured() {
        var seen = Set<String>()
        let candidates = shelves
            .flatMap(\.items)
            .filter { $0.background != nil }
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.featuredCount)

        guard !candidates.isEmpty else { return }
        let updated = Array(candidates)
        guard updated.map(\.id) != featuredItems.map(\.id) else { return }
        featuredItems = updated
    }

    static let featuredCount = 5
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel = HomeViewModel()
    /// An explicit path rather than a bound optional item.
    ///
    /// `navigationDestination(item:)` pushed reliably from a click but ignored
    /// programmatic assignment here, which left both deep links and "go Home"
    /// setting state that the stack never acted on. A path is directly
    /// manipulable: append to push, empty it to return to the top.
    ///
    /// It lives on the model rather than in `@State` because things outside this
    /// view need to empty it. On macOS the detail column is swapped when the
    /// section changes, and swapping it out from under a `NavigationStack` whose
    /// bound path is non-empty makes SwiftUI assert inside
    /// `NavigationColumnState.boundPathChange` — clicking Search from a movie page
    /// killed the app every time. The toolbar has to be able to pop this first.
    @State private var detailAnchor: DeepLink.Anchor = .top
    @State private var heroIndex = 0
    #if os(iOS)
    @State private var isShowingSettings = false
    #endif
    @State private var opener = TMDBTitleOpener()
    @State private var launcher = PlaybackLauncher()
    @State private var playing: RankedStream?
    @State private var pendingContext: PlaybackContext?
    @State private var showsUnavailable = false
    @State private var playingAlternates: [RankedStream] = []

    /// How often Home re-pulls while it is the visible screen.
    private static let refreshInterval: Int = 45

    /// Rebuilds the resume shelf from whatever watch state now holds.
    private func refreshResumeShelf() async {
        await viewModel.buildResumeFeed(
            watchState: model.watchState,
            registry: model.registry,
            client: model.client
        )
    }

    var body: some View {
        // Named, not shadowing `model`. Rebinding the environment value as
        // `@Bindable var model = model` changed its isolation for the `.task`
        // closures below and they stopped compiling.
        @Bindable var bindable = model

        return NavigationStack(path: $bindable.homePath) {
            Group {
                if model.registry.enabledAddons.isEmpty && viewModel.hasLoadedOnce {
                    StateMessage(
                        icon: "puzzlepiece.extension",
                        title: "No addons installed",
                        message: "Add a catalog addon to start browsing."
                    )
                } else {
                    content
                }
            }
            .themedBackground()
            // Inline so the hero owns the top of the screen. A large title repeating
            // the app name pushed content down by ~150pt for no information.
            // Empty on macOS: the toolbar carries the wordmark, and a window
            // title of the same name rendered "Stream" twice side by side.
            .homeNavigationTitle()
            .navigationBarTitleDisplayModeInline()
            // Same treatment as Detail: the hero runs under the window chrome
            // rather than starting below an opaque strip. On iOS the navigation
            // bar is hidden outright — hiding only its background still reserves
            // the space, so the hero stayed pinned below a black strip.
            .ignoresSafeArea(edges: .top)
            .hiddenNavigationBar()
            .hiddenToolbarBackground()
            .overlay(alignment: .top) { iOSTopBar }
            .hiddenNavigationBar()
            .macToolbarGenreMenu(genreMenu)
            .navigationDestination(for: MetaPreview.self) { item in
                DetailView(item: item, anchor: detailAnchor)
            }
        }
        .task(id: model.registry.addons.count) {
            await viewModel.load(registry: model.registry, client: model.client, hiding: theatricalFilter)
            // Independent of watch state, so it can run alongside.
            async let theatres: Void = viewModel.loadInTheatres(
                tmdb: model.tmdb,
                apiKey: model.tmdbApiKey
            )
            // The pull, *then* the shelf. These used to run concurrently, which
            // meant Continue watching was usually built from local records the
            // remote merge had not landed in yet — progress finished on another
            // device showed up one launch late, if at all.
            await model.syncOnLaunch()
            await refreshResumeShelf()
            await theatres
        }
        // Keeps Continue watching current while Home is on screen.
        //
        // A pull only happened at launch and when the scene became active, so a
        // device already sitting on Home never learned that another one had
        // finished an episode — an Apple TV can stay on this screen for hours.
        // The task is tied to the view, so nothing polls once Home goes away.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                // No `scenePhase` gate. It was one, and it never let a single
                // refresh through: on macOS the phase read `background` from
                // inside this view even with the app running and on screen. The
                // task's own lifetime is the right gate — SwiftUI cancels it when
                // Home goes away, and a suspended app does not run tasks at all.
                guard !Task.isCancelled else { return }
                await model.refreshRemoteState()
                await refreshResumeShelf()
            }
        }
        // Keyed on the hero itself, not run alongside `load`. Shelves fill in
        // independently and the hero is only chosen once one of them lands, so a
        // fetch started next to `load` found no hero yet and quietly did nothing.
        .onChange(of: model.theatrical) { _, window in
            viewModel.applyTheatrical(window)
        }
        .onChange(of: model.homeFilter) { _, filter in
            applyFilter(filter)
        }
        .task(id: currentHero?.id) {
            await viewModel.loadFeaturedDetail(
                for: currentHero,
                registry: model.registry,
                client: model.client,
                tmdb: model.tmdb,
                apiKey: model.tmdbApiKey
            )
        }
        // `initial`, because on macOS and tvOS this view can be mounted *by* a
        // link — the section switches to Home to deliver it — and a handler that
        // only fires on change never saw the value that was already set.
        .onChange(of: model.pendingLink, initial: true) { _, link in
            switch link {
            case .detail(let item, let anchor):
                detailAnchor = anchor
                model.homePath = [item]
                model.pendingLink = nil
            case .home:
                // Pops whatever is pushed. Selecting the Home *section* is not
                // enough on its own — you are already in it, so the pushed detail
                // page simply stayed put and the menu item looked broken.
                model.homePath.removeAll()
                detailAnchor = .top
                model.pendingLink = nil
            #if os(iOS)
            case .settings:
                // Settings is no longer a tab, so the link opens the sheet rather
                // than quietly doing nothing.
                isShowingSettings = true
                model.pendingLink = nil
            #endif
            default:
                break
            }
        }
        .onChange(of: opener.resolved) { _, resolved in
            if let resolved {
                model.homePath.append(resolved)
                opener.resolved = nil
            }
        }
        .alert("Not available", isPresented: $opener.failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This title couldn't be matched to an entry your addons can open.")
        }
        .overlay {
            if launcher.phase == .resolving {
                ResolvingOverlay { launcher.cancel() }
            }
        }
        .onChange(of: launcher.phase) { _, phase in
            switch phase {
            case .ready(let stream):
                // Snapshotted here: `finish()` resets the launcher, and the player
                // needs the rest of the ranked list to step past a placeholder.
                playingAlternates = launcher.alternates
                playing = stream
                launcher.finish()
            case .unavailable:
                showsUnavailable = true
                launcher.finish()
            default:
                break
            }
        }
        .presentPlayer(item: $playing, context: pendingContext, alternates: playingAlternates)
        #if os(iOS)
        // A sheet, not a tab: settings is somewhere you visit and leave, not a
        // third place to browse.
        .sheet(isPresented: $isShowingSettings) {
            AddonsView(isModal: true)
        }
        #endif
        .unavailableAlert(isPresented: $showsUnavailable)
    }

    /// Filters every genre-capable catalog at once.
    ///
    /// Catalogs accept a `genre` extra, so this is a real server-side filter rather
    /// than a client-side pass over already-fetched pages.
    @ToolbarContentBuilder
    private var genreMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // No custom menu style here: the overrides that suit the iOS floating
            // button made this render at a different weight from the neighbouring
            // Search button, and the two merged into one lopsided capsule.
            Menu {
                genreOptions
            } label: {
                // Named when active. A bare funnel tells you a filter exists but
                // not which one is on, so a filtered Home looked like an empty one.
                if let genre = viewModel.genre {
                    Label(genre, systemImage: genreIcon)
                } else {
                    Image(systemName: genreIcon)
                }
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(isFiltered ? Theme.Palette.accent : Theme.Palette.primaryText)
            .foregroundStyle(isFiltered ? Theme.Palette.accent : Theme.Palette.primaryText)
            .help("Filter by genre")
        }
    }

    /// Writes the choice to the model; `applyFilter` does the loading. The TV's
    /// top bar has its own copy of this menu and writes the same value.
    @ViewBuilder
    private var genreOptions: some View {
        Button {
            model.homeFilter = nil
        } label: {
            Label("All genres", systemImage: model.homeFilter == nil ? "checkmark" : "")
        }

        Divider()

        ForEach(HomeViewModel.availableGenres(registry: model.registry), id: \.self) { genre in
            Button {
                model.homeFilter = .genre(genre)
            } label: {
                Label(genre, systemImage: model.homeFilter == .genre(genre) ? "checkmark" : "")
            }
        }
    }

    /// One path for every platform's menu.
    private func applyFilter(_ filter: AppModel.HomeFilter?) {
        switch filter {
        case .inTheatres: showInTheatres()
        case .genre(let genre): setGenre(genre)
        case nil: setGenre(nil)
        }
    }

    /// iOS/tvOS render this over the artwork, since their navigation bar is hidden.
    ///
    /// Styled to match the player's floating controls rather than the tinted
    /// capsule iOS gives a bare toolbar button — that read as a stray blue blob
    /// over the hero.
    /// Wordmark and filter over the hero, mirroring the Mac's toolbar and the TV's
    /// top bar. iOS hides its navigation bar here so the artwork can run to the
    /// top edge, which left the app with no name on screen at all.
    @ViewBuilder
    private var iOSTopBar: some View {
        #if os(iOS)
        HStack {
            Text("Stream")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.Palette.primaryText)
                .shadow(color: .black.opacity(0.55), radius: 6, y: 1)

            Spacer()

            floatingGenreButton
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, 4)
        #endif
    }

    @ViewBuilder
    private var floatingGenreButton: some View {
        // iOS only. On tvOS an overlay is outside the focus path, so the control
        // rendered but could never be reached — it lives inline instead.
        #if os(iOS)
        Menu {
            genreOptions

            Divider()

            Button("Settings", systemImage: "gearshape") {
                isShowingSettings = true
            }
        } label: {
            Image(systemName: genreIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.45), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }

    @ViewBuilder
    private var inTheatresShelf: some View {
        if !viewModel.inTheatres.isEmpty {
            Shelf(title: "In theatres") {
                ForEach(viewModel.inTheatres) { title in
                    PosterButton(
                        width: Theme.Metrics.posterWidth,
                        caption: title.title,
                        artwork: { RemoteImage(url: title.posterURL, title: title.title) },
                        action: { opener.open(title, tmdb: model.tmdb, apiKey: model.tmdbApiKey) }
                    )
                }
            }
        }
    }

    /// Anything narrowing the page hides the personal rows — Continue watching and
    /// Watchlist answer "what am I in the middle of", which a filtered view is not.
    private var isFiltered: Bool { viewModel.genre != nil || viewModel.showsInTheatres }

    private var genreIcon: String {
        #if os(macOS)
        // Bare, to match the magnifier and house beside it. Active state is
        // carried by tint and the genre name rather than a filled circle.
        "line.3.horizontal.decrease"
        #else
        viewModel.genre == nil
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
        #endif
    }

    /// Hero Play starts playback rather than opening the detail page.
    ///
    /// A series needs its episode list before "Play" means anything, so metadata
    /// is fetched first and run through the same `UpNextResolver` the detail page
    /// uses — otherwise the hero would resume a different episode than the show's
    /// own Play button, which is worse than having no hero Play at all.
    private func playFeatured(_ item: MetaPreview) {
        Task {
            let detail = await loadMeta(for: item)

            var videoId = item.id
            var startAt: Duration?
            var title = item.name

            if let detail {
                let upNext = UpNextResolver.resolve(meta: detail, progress: model.watchState.records)
                videoId = upNext.videoId
                startAt = upNext.resumePosition
                if let episode = upNext.episode {
                    title = "\(item.name) · \(episode.episodeCode ?? episode.displayName)"
                }
            }

            pendingContext = PlaybackContext(
                videoId: videoId,
                metaId: item.id,
                type: item.type,
                title: title,
                startAt: startAt,
                metaName: item.name,
                poster: detail?.poster ?? item.poster
            )
            launcher.play(
                target: StreamTarget(type: item.type, videoId: videoId, title: title),
                registry: model.registry,
                resolver: model.resolver,
                preferences: model.preferences
            )
        }
    }

    /// Plays a Continue watching row straight away.
    ///
    /// The entry already carries the video this row would play and where to resume
    /// it — `ResumeFeed` ran the whole `UpNextResolver` to work that out. Pushing
    /// the detail page instead discarded it and made the viewer wait while the same
    /// metadata was fetched and the same resolver re-run, only to offer a Play
    /// button that computes the identical answer. A shelf called Continue watching
    /// should continue watching. The detail page is still one long-press away.
    private func playResume(_ entry: ResumeEntry) {
        let title = entry.episodeCode.map { "\(entry.title) · \($0)" } ?? entry.title
        pendingContext = PlaybackContext(
            videoId: entry.videoId,
            metaId: entry.metaId,
            type: entry.type,
            title: title,
            startAt: entry.resumePosition,
            metaName: entry.title,
            poster: entry.poster
        )
        launcher.play(
            target: StreamTarget(type: entry.type, videoId: entry.videoId, title: title),
            registry: model.registry,
            resolver: model.resolver,
            preferences: model.preferences
        )
    }

    private func loadMeta(for item: MetaPreview) async -> MetaDetail? {
        for addon in model.registry.addons(providing: .meta, type: item.type, id: item.id) {
            if let detail = try? await model.client.meta(from: addon, type: item.type, id: item.id) {
                return detail
            }
        }
        return nil
    }

    private func showInTheatres() {
        Task { await viewModel.showInTheatres(tmdb: model.tmdb, apiKey: model.tmdbApiKey) }
    }

    private func setGenre(_ genre: String?) {
        Task {
            await viewModel.load(
                registry: model.registry, client: model.client,
                genre: genre, hiding: theatricalFilter
            )
        }
    }

    /// Only the TV hides them. On a Mac or a phone the row costs a glance and the
    /// pointer moves on; with a remote it is a wall of things that will not play.
    private var theatricalFilter: TheatricalWindow {
        #if os(tvOS)
        model.theatrical
        #else
        TheatricalWindow()
        #endif
    }

    /// The hero currently on screen.
    private var currentHero: MetaPreview? {
        let items = viewModel.featuredItems
        guard !items.isEmpty else { return nil }
        return items[min(heroIndex, items.count - 1)]
    }

    /// A paged hero.
    ///
    /// It used to be a single title — whichever the first addon happened to
    /// return first — chosen once and never revisited. It is now a short,
    /// swipeable shortlist so the top of Home is not the same artwork forever.
    @ViewBuilder
    private func heroSection(viewportHeight: CGFloat, viewportWidth: CGFloat) -> some View {
        let items = viewModel.featuredItems
        if !items.isEmpty {
            #if os(tvOS)
            // A remote cannot swipe a banner without the focus engine fighting
            // for it, so the TV shows the first and leaves paging to the shelves.
            heroBanner(items[0], viewportHeight: viewportHeight, viewportWidth: viewportWidth)
            #elseif os(macOS)
            // `.page` is iOS-only, so the Mac gets a paging scroll — the same
            // swipe on a trackpad, snapping one hero at a time.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        heroBanner(item, viewportHeight: viewportHeight, viewportWidth: viewportWidth)
                            .containerRelativeFrame(.horizontal)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.never)
            .frame(height: heroHeight(viewportHeight: viewportHeight))
            #else
            TabView(selection: $heroIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    heroBanner(item, viewportHeight: viewportHeight, viewportWidth: viewportWidth).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
            .frame(height: heroHeight(viewportHeight: viewportHeight))
            #endif
        }
    }

    private func heroHeight(viewportHeight: CGFloat) -> CGFloat {
        #if os(macOS)
        max(440, viewportHeight * 0.66)
        #else
        max(360, viewportHeight * 0.52)
        #endif
    }

    @ViewBuilder
    private func heroBanner(_ item: MetaPreview, viewportHeight: CGFloat, viewportWidth: CGFloat) -> some View {
        FeaturedBanner(
            item: item,
            synopsis: viewModel.featuredDetails[item.id]?.description ?? item.description,
            certification: viewModel.featuredCertifications[item.id],
            isWatched: item.type == .movie
                && model.watchState.progress(for: item.id)?.isFinished == true,
            isSaved: model.watchlist.contains(item.id),
            resumeFraction: featuredResume(item)?.fractionComplete ?? 0,
            remaining: featuredResume(item)?.remaining,
            containerHeight: viewportHeight,
            containerWidth: viewportWidth,
            onPlay: { playFeatured(item) },
            onToggleWatchlist: { model.watchlist.toggle(item) },
            action: { model.homePath.append(item) }
        )
    }

    private func markWatched(_ entry: ResumeEntry) {
        model.watchState.markFinished(
            videoId: entry.videoId,
            metaId: entry.metaId,
            type: entry.type,
            metaName: entry.title,
            poster: entry.poster
        )
        model.pushRemoteState()
        Task {
            await viewModel.buildResumeFeed(
                watchState: model.watchState,
                registry: model.registry,
                client: model.client
            )
        }
    }

    /// Drops a title from the continue-watching shelf.
    ///
    /// Forgets the title's progress entirely rather than hiding the row, so the
    /// choice syncs to the other devices like any other watch state.
    private func removeFromContinueWatching(_ entry: ResumeEntry) {
        model.watchState.clearTitle(metaId: entry.metaId)
        model.pushRemoteState()
        Task {
            await viewModel.buildResumeFeed(
                watchState: model.watchState,
                registry: model.registry,
                client: model.client
            )
        }
    }

    /// Latest progress for the featured title, if any.
    private func featuredResume(_ item: MetaPreview) -> WatchProgress? {
        model.watchState.progress(forMeta: item.id).first { $0.isResumable }
    }

    private var content: some View {
        GeometryReader { viewport in
            scrollBody(viewportHeight: viewport.size.height, viewportWidth: viewport.size.width)
        }
    }

    private func scrollBody(viewportHeight: CGFloat, viewportWidth: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                heroSection(viewportHeight: viewportHeight, viewportWidth: viewportWidth)

                // Above the catalogs: what you were already watching outranks
                // anything an addon wants to promote.
                //
                // Hidden while a genre filter is active: continue-watching,
                // watchlist, and in-theatres have no genre dimension, and showing
                // them unfiltered under a "Horror" view misrepresents the screen.
                let resumable = isFiltered ? [] : viewModel.resumeFeed
                if !resumable.isEmpty {
                    Shelf(title: "Continue watching") {
                        ForEach(resumable) { entry in
                            let destination = MetaPreview(
                                id: entry.metaId,
                                type: entry.type,
                                name: entry.title,
                                poster: entry.poster
                            )
                            ResumeCard(
                                entry: entry,
                                onRemove: { removeFromContinueWatching(entry) },
                                onMarkWatched: { markWatched(entry) },
                                onShowDetails: { model.homePath.append(destination) }
                            ) { playResume(entry) }
                        }
                    }
                }

                let saved = isFiltered ? [] : model.watchlist.sorted
                if !saved.isEmpty {
                    Shelf(title: "Watchlist") {
                        ForEach(saved) { entry in
                            PosterButton(
                                width: Theme.Metrics.posterWidth,
                                caption: entry.meta.name,
                                artwork: { RemoteImage(string: entry.meta.poster, title: entry.meta.name) },
                                action: { model.homePath.append(entry.meta) }
                            )
                            .contextMenu {
                                Button("Remove from Watchlist", systemImage: "bookmark.slash", role: .destructive) {
                                    model.watchlist.remove(entry.id)
                                }
                            }
                        }
                    }
                }

                #if os(tvOS)
                // Only when it is the thing you asked for. See
                // `HomeViewModel.showsInTheatres`.
                if viewModel.showsInTheatres { inTheatresShelf }
                #else
                if !isFiltered { inTheatresShelf }
                #endif

                ForEach(viewModel.shelves) { shelf in
                    shelfView(shelf)
                }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .tvFullBleedHorizontal()
        .refreshable {
            await viewModel.load(registry: model.registry, client: model.client, hiding: theatricalFilter)
        }
    }

    /// The addon name, but only when another shelf shares this shelf's title.
    private func attribution(for shelf: HomeViewModel.ShelfState) -> String? {
        let duplicates = viewModel.shelves.filter { $0.source.shelfTitle == shelf.source.shelfTitle }
        return duplicates.count > 1 ? shelf.source.addon.name : nil
    }

    @ViewBuilder
    private func shelfView(_ shelf: HomeViewModel.ShelfState) -> some View {
        // A shelf that loaded successfully but is empty is noise — drop it entirely.
        if !shelf.isLoading && shelf.items.isEmpty && shelf.failureDetail == nil {
            EmptyView()
        } else {
            // Addons name catalogs generically ("Popular"), so the content type is
            // needed to tell two shelves apart. The addon name is only shown when
            // even that is ambiguous — otherwise it repeats down the whole page.
            Shelf(title: shelf.source.shelfTitle, subtitle: attribution(for: shelf)) {
                if shelf.isLoading {
                    ShelfSkeleton()
                } else if let detail = shelf.failureDetail {
                    ShelfFailure(detail: model.showsDiagnostics ? detail : nil) {
                        Task { await viewModel.reload(shelf: shelf.id, client: model.client) }
                    }
                } else {
                    ForEach(shelf.items) { item in
                        PosterButton(
                            width: Theme.Metrics.posterWidth,
                            caption: item.name,
                            artwork: { RemoteImage(string: item.poster, title: item.name) },
                            action: { model.homePath.append(item) }
                        )
                    }
                }
            }
        }
    }
}

/// Full-bleed hero at the top of the home screen.
///
/// macOS carries an action row — Play, More Info, and the watchlist toggle — so
/// the hero is a surface rather than one large button. iOS and tvOS keep the
/// single-button form until their own redesigns land.
struct FeaturedBanner: View {
    let item: MetaPreview
    var synopsis: String?
    /// Age classification, when TMDB has one. Absent rather than guessed.
    var certification: String?
    /// Films only — see `DetailView.isWatchedFilm`.
    var isWatched: Bool = false
    var isSaved: Bool = false
    /// Resume state for the featured title, so the button matches the one on the
    /// detail page rather than always reading a bare "Play".
    var resumeFraction: Double = 0
    var remaining: Duration?
    /// Viewport height. The hero is proportional to the window, as on the detail
    /// page — a fixed 340pt looked squat at any size above the default.
    var containerHeight: CGFloat = 0
    /// Viewport width, for the cover on the trailing edge. Same rule as the detail
    /// page: below `HeroPoster`'s threshold there is no cover and nothing moves.
    var containerWidth: CGFloat = 0
    var onPlay: (() -> Void)?
    var onToggleWatchlist: (() -> Void)?
    let action: () -> Void

    var body: some View {
        #if os(macOS)
        surface
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            // The hero is no longer one big button, but clicking the artwork was
            // how you opened a title before and should keep working. Buttons
            // inside consume their own clicks.
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
        #elseif os(tvOS)
        // Deliberately *not* a button, and deliberately no tap gesture.
        //
        // As one large focusable card the hero swallowed the remote: focus landed
        // on it and, being taller than everything around it, was awkward to leave.
        // The artwork is now inert and the action row inside it carries the focus.
        surface
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
        #else
        surface
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
        #endif
    }

    private var surface: some View {
        ZStack(alignment: .bottomLeading) {
            // The artwork is an overlay on a clear box, so it contributes nothing
            // to layout. Sized directly, an aspect-fill backdrop is wider than the
            // screen; the ZStack took that width and the synopsis laid out against
            // it, running off the right edge of a phone.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                .overlay {
                    RemoteImage(string: item.background)
                        .frame(height: heroHeight)
                }
                .clipped()

            // The same treatment the detail page uses, from one definition. Two
            // hand-matched ramps is what made the two screens look like different
            // apps.
            HeroScrim()

            // Short dark band at the very top: the toolbar has no background of
            // its own, so the wordmark and its icons would otherwise sit directly
            // on whatever the backdrop shows there.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            HeroPoster(poster: item.poster, title: item.name, availableWidth: containerWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(Theme.Metrics.screenPadding)
                .padding(.bottom, pagingInset)

            VStack(alignment: .leading, spacing: Theme.isTelevision ? 16 : 14) {
                statusChips
                titleMark
                // The same block the detail page leads with, in the same order:
                // what it is, then the facts, then the action.
                if let synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.Metrics.readableWidth, alignment: .leading)
                }
                metadataRow
                actionRow
            }
            // The same margin the shelves below use. Two different left insets on
            // one page breaks the strongest alignment cue it has.
            .padding(Theme.Metrics.screenPadding)
            // Only the measure moves, never the left edge — the shelves below start
            // at `screenPadding` and the hero has to line up with them.
            .padding(.trailing, HeroPoster.textInset(for: containerWidth))
            // Room for the paging dots, which sit at the bottom of the TabView and
            // were drawn straight through the More Info button.
            .padding(.bottom, pagingInset)
        }
    }

    /// Space the page indicator needs beneath the content.
    private var pagingInset: CGFloat {
        #if os(iOS)
        26
        #else
        0
        #endif
    }

    /// The same pair the detail page leads with — what it is, and who it is for.
    ///
    /// These sit inside the banner\'s own tap target, so pressing one opens the
    /// title. That is what pressing anywhere else on the banner does, so the chip
    /// is not making a promise the rest of the surface does not already make.
    @ViewBuilder
    private var statusChips: some View {
        HStack(spacing: 6) {
            Chip(text: item.type == .series ? "SERIES" : "FILM")
            if let certification {
                Chip(text: certification.uppercased(), tint: Theme.Palette.secondaryText)
            }
            if isWatched {
                Chip(text: "WATCHED", tint: Theme.Palette.cached)
            }
        }
    }

    private var heroHeight: CGFloat {
        #if os(macOS)
        // Short of the detail page's 0.78 on purpose: the first shelf has to peek
        // above the fold so the page reads as browsable rather than as one poster.
        max(440, containerHeight * 0.66)
        #else
        // Both now carry an action row, so both need room for it.
        Theme.isTelevision ? 700 : max(360, containerHeight * 0.52)
        #endif
    }

    @ViewBuilder
    private var titleMark: some View {
        if let logo = item.logo, let url = URL(string: logo) {
            RemoteImage(url: url, contentMode: .fit)
                .frame(maxWidth: logoBox.width, maxHeight: logoBox.height, alignment: .leading)
        } else {
            Text(item.name)
                .font(Theme.isTelevision ? .largeTitle.bold() : .title.bold())
                .foregroundStyle(Theme.Palette.primaryText)
        }
    }

    private var logoBox: (width: CGFloat, height: CGFloat) {
        #if os(macOS)
        (280, 84)
        #else
        Theme.isTelevision ? (440, 130) : (200, 56)
        #endif
    }

    /// Same treatment as Detail: rating highlighted, everything else plain
    /// interpuncted text rather than a row of pills.
    private var metadataRow: some View {
        HStack(spacing: 8) {
            if let rating = item.imdbRating {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.system(size: Theme.isTelevision ? 20 : 9))
                    Text(rating).font(Theme.Typography.meta.weight(.semibold))
                }
                .foregroundStyle(Theme.Palette.accentWarm)
            }

            let facts = [item.yearLabel, item.genres.prefix(2).joined(separator: ", ").nilIfEmpty]
                .compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

    /// Three targets, not five. The comp put sources and trailer here too, but
    /// they sit at the same rank as More Info while carrying less, and both are
    /// one click away on the detail page this button opens.
    private var actionRow: some View {
        HStack(spacing: Theme.isTelevision ? 20 : 10) {
            ResumePlayButton(
                label: "Play",
                fractionComplete: resumeFraction,
                remaining: remaining
            ) {
                onPlay?()
            }

            Button("More Info", action: action)
                .buttonStyle(OutlineButtonStyle())

            Button {
                onToggleWatchlist?()
            } label: {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .frame(width: 20)
            }
            .buttonStyle(GlassButtonStyle())
            .help(isSaved ? "Remove from watchlist" : "Add to watchlist")
        }
        .padding(.top, 4)
    }
}
