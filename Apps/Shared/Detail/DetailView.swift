import SwiftUI
import StreamCore
#if os(tvOS)
import UIKit
#endif

@Observable
@MainActor
final class DetailViewModel {
    private(set) var meta: MetaDetail?
    private(set) var isLoading = true
    /// Why the page has no metadata.
    ///
    /// Two situations that used to share one string and one dead end. Nothing
    /// installed can answer is a settings problem and retrying cannot change it;
    /// everything was asked and nothing answered is almost always the network, and
    /// the page offered no way to ask again short of backing out and re-entering.
    enum Failure {
        case noProvider
        case allFailed
    }

    private(set) var failure: Failure?
    private(set) var similar: [MetaPreview] = []
    /// TMDB's own recommendations, preferred over the genre shelf when available.
    private(set) var recommended: [TMDBClient.TMDBTitle] = []
    private(set) var enrichment: TMDBClient.Enrichment?
    var selectedSeason: Int?

    /// Asks meta-capable addons in registry order and takes the first success.
    ///
    /// Order is the user's stated preference, so the first addon that answers wins
    /// rather than merging conflicting metadata from several sources.
    func load(item: MetaPreview, registry: AddonRegistry, client: AddonClient) async {
        isLoading = true
        failure = nil

        let providers = registry.addons(providing: .meta, type: item.type, id: item.id)
        guard !providers.isEmpty else {
            failure = .noProvider
            isLoading = false
            return
        }

        for addon in providers {
            if let detail = try? await client.meta(from: addon, type: item.type, id: item.id) {
                meta = detail
                selectedSeason = detail.seasons.first { $0.number > 0 }?.number
                    ?? detail.seasons.first?.number
                isLoading = false
                return
            }
        }

        failure = .allFailed
        isLoading = false
    }

    /// The genre least likely to produce a shelf of nothing in particular.
    ///
    /// The broad buckets are demoted so a horror film asks for horror rather than
    /// for drama. Falls back to the first genre when every one of them is broad.
    static func mostSpecificGenre(of genres: [String]) -> String? {
        let broad: Set<String> = [
            "drama", "comedy", "action", "adventure", "thriller", "family", "romance"
        ]
        return genres.first { !broad.contains($0.lowercased()) } ?? genres.first
    }

    /// Networks, studios, and cast photos from TMDB.
    ///
    /// Entirely optional — with no key, or on any failure, the page simply renders
    /// without the extra artwork.
    func loadEnrichment(tmdb: TMDBClient, apiKey: String) async {
        guard let meta, let tmdbId = meta.moviedbId, !apiKey.isEmpty else { return }
        enrichment = await tmdb.enrichment(tmdbId: tmdbId, type: meta.type, apiKey: apiKey)
    }

    /// "More like this", built from the protocol rather than a recommendation API.
    ///
    /// Catalogs accept a `genre` extra, so asking any genre-capable catalog for the
    /// title's own primary genre gives a decent neighbourhood for free. Not true
    /// similarity — it is a genre shelf — but it costs one request and no new addon.
    /// Real recommendations where TMDB can give them, a genre shelf where it cannot.
    ///
    /// The genre shelf was picking `genres.first`, which for anything tagged
    /// "Drama, Horror" meant drama — so The Devil\'s Candy recommended The Shawshank
    /// Redemption and Interstellar. Every serious film is a drama; the tag carries
    /// almost no signal.
    func loadSimilar(
        registry: AddonRegistry,
        client: AddonClient,
        tmdb: TMDBClient,
        apiKey: String
    ) async {
        guard let meta else { return }

        if let tmdbId = meta.moviedbId {
            recommended = await tmdb.recommendations(tmdbId: tmdbId, type: meta.type, apiKey: apiKey)
            if !recommended.isEmpty { return }
        }

        guard let genre = Self.mostSpecificGenre(of: meta.genres) else { return }

        let candidates = registry.homeCatalogs.filter {
            $0.catalog.type == meta.type && $0.catalog.availableGenres.contains(genre)
        }

        for source in candidates {
            guard let response = try? await client.catalog(
                from: source.addon,
                type: source.catalog.type,
                id: source.catalog.id,
                extra: [.genre(genre)]
            ) else { continue }

            let results = response.metas.filter { $0.id != meta.id }
            if !results.isEmpty {
                similar = Array(results.prefix(20))
                return
            }
        }
    }
}

struct DetailView: View {
    let item: MetaPreview
    /// Where the page opens. `episodes` skips the hero for a link that means
    /// "carry on with this show".
    var anchor: DeepLink.Anchor = .top

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = DetailViewModel()
    @State private var launcher = PlaybackLauncher()
    /// Navigating from "More like this" into another title.
    @State private var selection: MetaPreview?
    @State private var opener = TMDBTitleOpener()
    /// Cast member whose filmography is open.
    @State private var selectedPerson: TMDBClient.CastMember?
    /// Set only when the user explicitly asks to browse sources.
    @State private var browsingSources: StreamTarget?
    @State private var playing: RankedStream?
    @State private var pendingContext: PlaybackContext?
    @State private var showsUnavailable = false
    @State private var playingAlternates: [RankedStream] = []

    #if os(tvOS)
    /// Play is the page's default focus.
    ///
    /// Play and Sources are disabled until metadata arrives, and the watchlist
    /// bookmark is not — so on opening a title it was the only enabled control and
    /// the focus engine landed there. The first press of Select silently added the
    /// title to the watchlist, and nothing moved focus to Play once it enabled.
    private enum ActionField: Hashable { case play }
    @FocusState private var actionFocus: ActionField?
    /// One-shot, so this never yanks focus back after the user has moved on.
    @State private var didFocusPlay = false
    #endif

    /// Named so the parallax header can measure its offset within the scroll view.
    fileprivate static let scrollSpace = "detailScroll"

    var body: some View {
        GeometryReader { container in
            scrollBody(containerHeight: container.size.height)
        }
        .themedBackground()
        // Lets the backdrop run to the very top, under the toolbar and title bar.
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        .hiddenNavigationBar()
        .hiddenToolbarBackground()
        .overlay(alignment: .topLeading) { backButton }
        // A resolved TMDB recommendation opens the same way a catalog tile does.
        .onChange(of: opener.resolved) { _, resolved in
            guard let resolved else { return }
            selection = resolved
            opener.resolved = nil
        }
        .alert("Not available", isPresented: $opener.failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No installed addon can open this title.")
        }
        .navigationDestination(item: $selection) { entry in
            DetailView(item: entry)
        }
        .overlay {
            if launcher.phase == .resolving {
                ResolvingOverlay { launcher.cancel() }
            }
        }
        .task {
            await viewModel.load(item: item, registry: model.registry, client: model.client)
            // Open on the season you are actually watching. Defaulting to season 1
            // meant a viewer part-way through a later season landed on episodes
            // they finished months ago.
            if let season = upNext?.episode?.season, season > 0 {
                viewModel.selectedSeason = season
            }
            async let enrichment: Void = viewModel.loadEnrichment(
                tmdb: model.tmdb,
                apiKey: model.tmdbApiKey
            )
            async let similar: Void = viewModel.loadSimilar(
                registry: model.registry,
                client: model.client,
                tmdb: model.tmdb,
                apiKey: model.tmdbApiKey
            )
            _ = await (enrichment, similar)
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
        .sheet(item: $browsingSources) { target in
            StreamPickerView(target: target)
                .presentationDetents([.medium, .large])
                .sheetSize()
        }
        .navigationDestination(item: $selectedPerson) { person in
            PersonView(person: person)
        }
        .presentPlayer(item: $playing, context: pendingContext, alternates: playingAlternates)
        .unavailableAlert(isPresented: $showsUnavailable)
    }

    /// Floating back control for platforms where the navigation bar is hidden.
    ///
    /// Not shown on macOS: hiding the toolbar *background* leaves the real toolbar
    /// back button floating over the artwork already, so adding one here produced
    /// two stacked chevrons. Not shown on tvOS either: the remote's Menu button is
    /// the system back gesture, and an on-screen chevron is both redundant and the
    /// topmost focusable view, so it took first focus away from Play.
    @ViewBuilder
    private var backButton: some View {
        #if os(iOS)
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.top, 12)
        #endif
    }

    @ViewBuilder
    private func failureMessage(_ failure: DetailViewModel.Failure) -> some View {
        switch failure {
        case .noProvider:
            // No retry: asking the same empty set of addons again gives the same
            // answer. What would help is installing one, which lives in Settings.
            StateMessage(
                icon: "puzzlepiece.extension",
                title: "No details available",
                message: "No installed addon provides details for this title."
            )
        case .allFailed:
            StateMessage(
                icon: "exclamationmark.triangle",
                title: "Couldn’t load details",
                message: "Check your connection and try again.",
                actionTitle: "Try again",
                action: {
                    Task {
                        await viewModel.load(item: item, registry: model.registry, client: model.client)
                    }
                }
            )
        }
    }

    fileprivate static let episodesAnchor = "episodes"

    private func scrollBody(containerHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(containerHeight: containerHeight)

                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let failure = viewModel.failure {
                    failureMessage(failure)
                        .frame(maxWidth: .infinity)
                } else if let meta = viewModel.meta {
                    details(meta)
                }

                if !viewModel.recommended.isEmpty || !viewModel.similar.isEmpty {
                    similarSection
                }

                // Reference material, consulted rather than weighed, so it sits
                // after the things that help you decide what to watch.
                if let cast = viewModel.enrichment?.cast, !cast.isEmpty {
                    castRow(cast)
                        .padding(.horizontal, Theme.Metrics.screenPadding)
                        .padding(.top, 6)
                }
            }
            .padding(.bottom, 40)
        }
        .onChange(of: viewModel.meta == nil) { _, isEmpty in
            guard !isEmpty, anchor == .episodes else { return }
            // After load rather than on appear: the season grid does not exist
            // until metadata arrives, so there is nothing to scroll to before then.
            withAnimation { proxy.scrollTo(Self.episodesAnchor, anchor: .top) }
        }
        .coordinateSpace(name: Self.scrollSpace)
        .tvFullBleedHorizontal()
        // Subtle indicators: a bright persistent scrollbar competes with artwork
        // in a browse UI. They still appear while actively scrolling.
        .scrollIndicators(.never)
        }
    }

    /// Genre neighbours, so the page ends with somewhere to go instead of black.
    private var similarSection: some View {
        Shelf(title: "More like this") {
            // TMDB carries a TMDB id and the addons are keyed on IMDb ids, so these
            // tiles resolve on tap rather than eagerly — one request for the title
            // chosen instead of twenty for a shelf that may not be touched.
            ForEach(viewModel.recommended) { title in
                Button {
                    opener.open(title, tmdb: model.tmdb, apiKey: model.tmdbApiKey)
                } label: {
                    TMDBTitleCard(title: title, isResolving: opener.resolving == title.id)
                }
                .buttonStyle(.plain)
            }

            // Only when TMDB gave nothing — no key, no `moviedbId`, or a title it
            // does not know.
            if viewModel.recommended.isEmpty {
                ForEach(viewModel.similar) { entry in
                    PosterButton(
                        width: Theme.Metrics.posterWidth,
                        caption: entry.name,
                        artwork: { RemoteImage(string: entry.poster, title: entry.name) },
                        action: { selection = entry }
                    )
                }
            }
        }
        .padding(.top, 8)
    }

    /// Starts the default path: resolve, rank, play the winner.
    private func autoPlay(videoId: String, title: String, startAt: Duration? = nil) {
        pendingContext = PlaybackContext(
            videoId: videoId,
            metaId: item.id,
            type: item.type,
            title: title,
            startAt: startAt,
            metaName: item.name,
            poster: viewModel.meta?.poster ?? item.poster
        )
        launcher.play(
            target: StreamTarget(type: item.type, videoId: videoId, title: title),
            registry: model.registry,
            resolver: model.resolver,
            preferences: model.preferences
        )
    }

    // MARK: - Header

    /// Hard-capped logo box. Logos range from wide wordmarks to tall stacked marks;
    /// without a fixed box the header height moved per title.
    private static let logoBoxHeight: CGFloat = Theme.isTelevision ? 130 : 66

    /// Proportional to the window so the artwork stays dominant at any size, with
    /// bounds that keep it from swallowing a tall display or vanishing on a short one.
    private func headerHeight(containerHeight: CGFloat) -> CGFloat {
        // The backdrop owns the page. Everything down to the action row sits on
        // it, so it has to be tall enough to hold that block without crowding.
        #if os(iOS)
        // Shorter on a phone: the same block is far taller relative to the screen,
        // and at 0.78 nothing below the hero was reachable without scrolling.
        min(560, max(380, containerHeight * 0.62))
        #else
        Theme.isTelevision
            ? max(760, containerHeight * 0.80)
            : max(560, containerHeight * 0.78)
        #endif
    }

    private func header(containerHeight: CGFloat) -> some View {
        let baseHeight = headerHeight(containerHeight: containerHeight)

        return GeometryReader { geometry in
            let minY = geometry.frame(in: .named(Self.scrollSpace)).minY
            // Stretch on overscroll, hold position on scroll-away — the standard
            // parallax that makes a static banner feel anchored to the content.
            let stretched = max(baseHeight, baseHeight + minY)

            ZStack(alignment: .bottomLeading) {
                RemoteImage(string: viewModel.meta?.background ?? item.background)
                    .frame(width: geometry.size.width, height: stretched)
                    .clipped()

                HeroScrim()

                // A sibling of `heroContent`, not an `HStack` with it. Screen puts
                // its cover on the leading edge, but doing that here would push the
                // title, synopsis and action row inward while the credits grid and
                // season list below stay at `screenPadding` — and Home states the
                // rule for both screens: "two different left insets on one page
                // breaks the strongest alignment cue it has" (HomeView.swift:962).
                HeroPoster(
                    poster: viewModel.meta?.poster ?? item.poster,
                    title: item.name,
                    availableWidth: geometry.size.width
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(Theme.Metrics.screenPadding)

                heroContent
                    .padding(Theme.Metrics.screenPadding)
                    // Only the measure moves, never the left edge.
                    .padding(.trailing, HeroPoster.textInset(for: geometry.size.width))
            }
            .frame(width: geometry.size.width, height: stretched)
            .offset(y: minY > 0 ? -minY : 0)
        }
        .frame(height: baseHeight)
    }

    /// Title, provenance, synopsis, facts, action — in the order a viewer needs
    /// them. The synopsis is what decides whether the button gets pressed, so it
    /// comes before the facts rather than after the action.
    @ViewBuilder
    private var heroContent: some View {
        VStack(alignment: .leading, spacing: Theme.isTelevision ? 24 : 16) {
            // One line on every platform. Stacked on a phone, the studio mark sat
            // on its own row under the title and read as a stray logo rather than
            // as provenance attached to it.
            // Centre-aligned on a phone: bottom alignment hung a small network
            // mark off the baseline of a much larger title logo and read as a
            // stray graphic rather than as provenance.
            VStack(alignment: .leading, spacing: Theme.isTelevision ? 12 : 8) {
                statusChips
                HStack(alignment: Theme.isTelevision ? .bottom : .center,
                       spacing: Theme.isTelevision ? 44 : 18) {
                    titleMark
                        .fixedSize(horizontal: true, vertical: false)
                    if let companies = viewModel.enrichment?.companies, !companies.isEmpty {
                        companyRow(companies)
                    }
                }
            }

            if let description = viewModel.meta?.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.Metrics.readableWidth, alignment: .leading)
            }

            metadataRow
            playControls
        }
    }

    /// What it is, and who it is for.
    ///
    /// Not a reversal of "reference detail reads as text, not pills" below: that
    /// decision is about year, runtime and genre — immutable catalogue facts that
    /// were competing with the rating for emphasis. Nothing moves out of
    /// `metadataRow` here, and an age classification is a badge everywhere it
    /// appears precisely because it is a board's mark rather than prose.
    ///
    /// The chips that were considered and rejected all failed the same test — the
    /// page already says it. "Watched" and "22m left" are inside the Play button,
    /// which carries a progress track and the time remaining. "Continuing"/"Ended"
    /// is a labelled row in `creditsGrid`, and is stated a second time by
    /// `metadataRow`, whose year range closes ("2008–2013") or stays open
    /// ("2022–") to say exactly that. Watchlist membership is the bookmark's fill.
    @ViewBuilder
    private var statusChips: some View {
        HStack(spacing: 6) {
            Chip(text: (viewModel.meta?.type ?? item.type) == .series ? "SERIES" : "FILM")

            // Cinemeta carries no classification at all, so this is TMDB-only and
            // absent without a key or for a title no board has rated. Shown only
            // when it is actually known — a blank badge is worse than none.
            if let certification = viewModel.enrichment?.certification {
                Chip(text: certification.uppercased(), tint: Theme.Palette.secondaryText)
            }

            if isWatchedFilm {
                Chip(text: "WATCHED", tint: Theme.Palette.cached)
            }
        }
    }

    /// Logo when the addon has one, styled text when it doesn't — both occupying
    /// the same fixed box so the header never jumps.
    @ViewBuilder
    private var titleMark: some View {
        Group {
            if let logo = viewModel.meta?.logo ?? item.logo, let url = URL(string: logo) {
                RemoteImage(url: url, contentMode: .fit)
                    .frame(maxWidth: Theme.isTelevision ? 440 : 250, maxHeight: Self.logoBoxHeight, alignment: .bottomLeading)
            } else {
                Text(item.name)
                    .font(Theme.isTelevision ? .largeTitle.bold() : .title2.bold())
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(height: Self.logoBoxHeight, alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reference detail reads as text, not pills.
    ///
    /// Five equal-weight chips gave year, runtime, and genre the same emphasis as the
    /// rating, and a pill shape implies "tappable filter" when none of these are.
    /// The rating is the only element carrying real signal, so it stays highlighted.
    private var metadataRow: some View {
        let meta = viewModel.meta
        let facts = [
            meta?.yearLabel ?? item.yearLabel,
            lengthLabel,
            (meta?.genres ?? item.genres).prefix(2).joined(separator: ", ").nilIfEmpty
        ].compactMap { $0 }

        return HStack(spacing: 8) {
            if let rating = meta?.imdbRating ?? item.imdbRating {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.system(size: Theme.isTelevision ? 20 : 9))
                    Text(rating).font(Theme.Typography.meta.weight(.semibold))
                }
                .foregroundStyle(Theme.Palette.accentWarm)
            }

            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    /// How much there is of it — an episode's runtime for a film, a season count
    /// for a series.
    ///
    /// Cinemeta reports `runtime` on a series as the length of one episode, so the
    /// row read "2008–2013 · 49 min · Drama" for Breaking Bad. Forty-nine minutes
    /// is not the thing anyone weighs before starting a show; five seasons is.
    /// Season 0 is excluded, matching every other count in the app
    /// (`ResumeFeed`, `UpNextResolver`) — specials are not part of the commitment.
    private var lengthLabel: String? {
        let meta = viewModel.meta
        guard (meta?.type ?? item.type) == .series else { return meta?.runtime }
        let seasons = (meta?.seasons ?? []).filter { $0.number > 0 }.count
        guard seasons > 0 else { return meta?.runtime }
        return seasons == 1 ? "1 season" : "\(seasons) seasons"
    }

    /// What Play would start: the resume point, the next unwatched episode, or the
    /// beginning. Nil until metadata loads, since episodes are needed to decide.
    private var upNext: UpNext? {
        guard let meta = viewModel.meta else { return nil }
        return UpNextResolver.resolve(meta: meta, progress: model.watchState.records)
    }

    /// An actual trailer where one exists, otherwise whatever clip is offered —
    /// Cinemeta mixes teasers and featurettes into the same list.
    private var preferredTrailer: Trailer? {
        guard let trailers = viewModel.meta?.trailers, !trailers.isEmpty else { return nil }
        return trailers.first(where: \.isTrailer) ?? trailers.first
    }

    private var isSaved: Bool {
        model.watchlist.contains(item.id)
    }

    private var playLabel: String {
        guard let upNext else { return "Play" }
        guard let episode = upNext.episode else {
            if upNext.isResume { return "Resume" }
            // The one thing a finished *film* never said anywhere on this page.
            // A series says it in the episode grid — every card checked and
            // dimmed — and a part-way title says it inside the Play button's own
            // progress track. A film you finished has neither, because
            // `UpNextResolver` clears the resume point on completion, so the
            // button fell back to a bare "Play" indistinguishable from one you
            // have never opened.
            return hasFinishedUpNext ? "Watch again" : "Play"
        }
        let code = episode.episodeCode ?? episode.displayName
        return upNext.isResume ? "Resume \(code)" : "Play \(code)"
    }

    /// Play is the primary action and picks a source automatically. Choosing one by
    /// hand is deliberately secondary — most people never need it.
    private var playControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.isTelevision ? 20 : 10) {
                ResumePlayButton(
                    label: playLabel,
                    fractionComplete: resumeFraction,
                    remaining: upNext?.remaining,
                    action: startUpNext
                )
                .disabled(viewModel.meta == nil)
                #if os(tvOS)
                .focused($actionFocus, equals: .play)
                #endif

                Button {
                    guard let upNext else { return }
                    browsingSources = StreamTarget(
                        type: item.type,
                        videoId: upNext.videoId,
                        metaId: item.id,
                        title: item.name
                    )
                } label: {
                    Image(systemName: "list.bullet")
                        .frame(width: 20)
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(viewModel.meta == nil)
                .accessibilityLabel("Choose source")

                Button {
                    model.watchlist.toggle(viewModel.meta?.preview ?? item)
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .frame(width: 20)
                }
                .buttonStyle(GlassButtonStyle())
                .accessibilityLabel(isSaved ? "Remove from watchlist" : "Add to watchlist")

                if let trailer = preferredTrailer, let url = trailer.watchURL {
                    // Opens YouTube externally rather than embedding it. In-app
                    // YouTube playback needs either a dedicated addon or libVLC's
                    // YouTube resolver, neither of which is dependable enough to
                    // put behind a button that looks like it always works.
                    #if os(tvOS)
                    // No browser on a television, so the https link opened nothing
                    // and the button was inert. The YouTube app's own scheme works
                    // when the app is installed; when it is not, there is nothing
                    // this button could do, so it is not shown at all.
                    if let appURL = trailer.appURL, UIApplication.shared.canOpenURL(appURL) {
                        Button {
                            UIApplication.shared.open(appURL)
                        } label: {
                            Image(systemName: "play.rectangle")
                                .frame(width: 20)
                        }
                        .buttonStyle(GlassButtonStyle())
                        .accessibilityLabel("Watch trailer in YouTube")
                    }
                    #else
                    Link(destination: url) {
                        Image(systemName: "play.rectangle")
                            .frame(width: 20)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .accessibilityLabel("Watch trailer")
                    #endif
                }
            }

            // No separate "X left" line anywhere: the Play button carries the
            // remaining time inside itself on every platform now, and iOS was
            // stating the same fact twice, once as "42m" and again as "42:24 left".
        }
        #if os(tvOS)
        // Claims focus for Play the moment it stops being disabled.
        .onChange(of: viewModel.meta == nil, initial: true) { _, isLoading in
            guard !isLoading, !didFocusPlay else { return }
            didFocusPlay = true
            actionFocus = .play
        }
        #endif
    }

    /// Whether this *film* has been watched to the end.
    ///
    /// Films only. A series is watched when every episode is, and the episode grid
    /// already says that a card at a time — a chip in the header claiming it for the
    /// whole show would be wrong the week the next episode lands.
    ///
    /// This is the one thing a finished film had nowhere to say. It leaves Continue
    /// watching, it is retired from the Watchlist, and `UpNextResolver` clears its
    /// resume point — so without this the page looks identical to one you have never
    /// opened. The Play button reading "Watch again" says what pressing it does;
    /// this says what already happened.
    private var isWatchedFilm: Bool {
        guard (viewModel.meta?.type ?? item.type) == .movie else { return false }
        return model.watchState.progress(for: item.id)?.isFinished == true
    }

    /// Whether the video Play would start has already been watched to the end.
    private var hasFinishedUpNext: Bool {
        guard let upNext else { return false }
        return model.watchState.progress(for: upNext.videoId)?.isFinished ?? false
    }

    /// How far into the up-next video the viewer already is.
    private var resumeFraction: Double {
        guard let upNext, upNext.resumePosition != nil else { return 0 }
        // Straight off the record: it already computes the fraction, and
        // `Duration.secondsValue` is internal to StreamCore.
        return model.watchState.progress(for: upNext.videoId)?.fractionComplete ?? 0
    }

    private func startUpNext() {
        guard let upNext else { return }
        let title = upNext.episode.map { episode in
            "\(item.name) · \(episode.episodeCode ?? episode.displayName)"
        } ?? item.name

        autoPlay(videoId: upNext.videoId, title: title, startAt: upNext.resumePosition)
    }

    // MARK: - Body

    @ViewBuilder
    private func details(_ meta: MetaDetail) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            // Synopsis and companies now live in the hero; what remains below it
            // is credits, then episodes, with cast further down past `similar`.
            creditsGrid(meta)

            if meta.type == .series && !meta.seasons.isEmpty {
                seasonSection(meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.screenPadding)
    }

    /// Network or studio marks, drawn as white silhouettes.
    ///
    /// TMDB's logos are predominantly *black* on transparent, so drawing them as-is
    /// on a dark background makes them invisible. Template rendering ignores the
    /// source colour entirely and also makes a mixed set look like one system.
    /// Companies with no logo fall back to their name so the row doesn't gap.
    /// Studio marks share the title's line, so they are sized against what is
    /// left of the width rather than to a fixed box.
    private var markSize: (width: CGFloat, height: CGFloat) {
        #if os(tvOS)
        (150, 44)
        #elseif os(iOS)
        // Small: it shares the line with the title and should read as a footnote
        // to it, not a second logo competing for the same rank.
        (46, 16)
        #else
        (88, 24)
        #endif
    }

    private var companyLimit: Int {
        #if os(tvOS)
        3
        #elseif os(iOS)
        1
        #else
        4
        #endif
    }

    private func companyRow(_ companies: [TMDBClient.Company]) -> some View {
        HStack(spacing: Theme.isTelevision ? 36 : 20) {
            // Fewer on the narrower screens: the title logo shares the line, and
            // a phone runs out of room after one mark.
            ForEach(companies.prefix(companyLimit)) { company in
                if let url = company.logoURL {
                    RemoteImage(logo: url, tint: Theme.Palette.secondaryText)
                        .frame(maxWidth: markSize.width, maxHeight: markSize.height)
                        .accessibilityLabel(company.name)
                } else {
                    Text(company.name)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: markSize.height + 2, alignment: .leading)
    }

    /// Cast with faces, which a comma-separated list can never be.
    private func castRow(_ cast: [TMDBClient.CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CAST")
                .font(Theme.Typography.fine.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.tertiaryText)

            ScrollView(.horizontal) {
                // Room for the focused portrait to grow into. A ScrollView clips
                // to its bounds, and with the row sized to the unfocused avatar the
                // 1.08 lift pushed the ring's top arc and the whole drop shadow
                // outside — cutting off the only focus indicator the row has now
                // that the system plate is gone.
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        Button {
                            selectedPerson = member
                        } label: {
                            VStack(spacing: 6) {
                                RemoteImage(url: member.profileURL)
                                    .frame(width: Theme.Metrics.castAvatar, height: Theme.Metrics.castAvatar)
                                    .clipShape(Circle())
                                    .modifier(CastAvatarRing())

                                Text(member.name)
                                    .font(Theme.Typography.fine.weight(.medium))
                                    .foregroundStyle(Theme.Palette.primaryText)
                                    .lineLimit(1)

                                if let character = member.character, !character.isEmpty {
                                    Text(character)
                                        .font(Theme.Typography.fine)
                                        .foregroundStyle(Theme.Palette.tertiaryText)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: Theme.Metrics.castColumn)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CastButtonStyle())
                        #if os(tvOS)
                        // Suppresses the system plate. The custom style draws the
                        // focus itself; leaving both on stacked a rectangle behind
                        // the ring.
                        .focusEffectDisabled()
                        #endif
                    }
                }
                .padding(.vertical, Theme.isTelevision ? 26 : 0)
            }
            .padding(.vertical, Theme.isTelevision ? -26 : 0)
            .scrollIndicators(.never)
        }
    }

    /// Credits as a flowing grid of short columns.
    ///
    /// A vertical stack of labelled blocks wasted the width and read as a form; a
    /// grid fills the row, reflows to the window, and keeps each value short enough
    /// to scan. No poster here — the backdrop already shows the artwork, and a
    /// second copy mid-page is redundant.
    @ViewBuilder
    private func creditsGrid(_ meta: MetaDetail) -> some View {
        // Pared back deliberately. Cast is a clickable portrait row further down
        // and repeating the names here only widened the grid; genre already sits
        // in the hero's metadata line; country and awards earned no space.
        // Status survives on series alone, where "Continuing" or "Ended" changes
        // whether you start the show at all.
        let facts: [(String, String)] = [
            ("Director", meta.director.joined(separator: ", ")),
            ("Writer", meta.writer.prefix(2).joined(separator: ", ")),
            (meta.type == .series ? "Status" : "", meta.type == .series ? (meta.status ?? "") : "")
        ].filter { !$0.0.isEmpty && !$0.1.isEmpty }

        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Divider().overlay(Theme.Palette.separator)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Theme.Metrics.creditColumnWidth), spacing: 32, alignment: .topLeading)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(facts, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(label.uppercased())
                                .font(Theme.Typography.fine.weight(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                            Text(value)
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

            }
            // Shares the synopsis measure. Left unbounded, the grid stretched to
            // the window while the paragraph above it stopped at `readableWidth`,
            // so the same page had two different column edges.
            .frame(maxWidth: Theme.Metrics.readableWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private func seasonSection(_ meta: MetaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The anchor carries the top-bar's height on tvOS rather than being a
            // zero-height marker. `scrollTo(anchor: .top)` puts this view at y=0,
            // which is underneath the bar — padding the section instead leaves the
            // padding above the anchor, where it just scrolls away, and the season
            // chips still landed behind the wordmark.
            #if os(tvOS)
            Color.clear.frame(height: TVTopBar<EmptyView>.height).id(Self.episodesAnchor)
            #else
            Color.clear.frame(height: 0).id(Self.episodesAnchor)
            #endif
            let seasons = meta.seasons

            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(seasons) { season in
                            let isSelected = viewModel.selectedSeason == season.number
                            Button {
                                viewModel.selectedSeason = season.number
                            } label: {
                                // Selection reads white, matching the Play button.
                                // Accent was left over from when Play was tinted;
                                // now it is the only purple element on the page.
                                Text(season.displayName)
                            }
                            .buttonStyle(ChipButtonStyle(isSelected: isSelected))
                            #if os(tvOS)
                            .focusEffectDisabled()
                            #endif
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            let allEpisodes = seasons.first { $0.number == viewModel.selectedSeason }?.episodes ?? []
            // Unaired episodes have no thumbnail and no summary, so a full card is
            // mostly empty placeholder. They get a compact list underneath instead.
            let episodes = allEpisodes.filter { !$0.isUpcoming }
            let upcoming = allEpisodes.filter(\.isUpcoming)
            // A grid of cards rather than a list: episode thumbnails are the most
            // useful thing on the row, and a card gives them real size while using
            // the window width instead of one narrow column.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Theme.Metrics.episodeCardWidth), spacing: 18, alignment: .topLeading)],
                alignment: .leading,
                spacing: 22
            ) {
                ForEach(episodes) { episode in
                    let episodeTitle = "\(item.name) · \(episode.episodeCode ?? episode.displayName)"
                    let record = model.watchState.progress(for: episode.id)
                    EpisodeCard(
                        episode: episode,
                        progress: record,
                        isUpNext: upNext?.videoId == episode.id,
                        // Picking a part-watched episode resumes it. It previously
                        // restarted from zero, which contradicted its own progress bar.
                        action: {
                            autoPlay(
                                videoId: episode.id,
                                title: episodeTitle,
                                startAt: record?.isResumable == true ? record?.position : nil
                            )
                        },
                        chooseSource: {
                            browsingSources = StreamTarget(
                                type: .series,
                                videoId: episode.id,
                                metaId: item.id,
                                title: episodeTitle
                            )
                        },
                        setWatched: { watched in
                            if watched {
                                model.watchState.markFinished(
                                    videoId: episode.id,
                                    metaId: item.id,
                                    type: .series,
                                    metaName: item.name,
                                    poster: viewModel.meta?.poster ?? item.poster
                                )
                            } else {
                                model.watchState.markUnwatched(videoId: episode.id)
                            }
                            model.pushRemoteState()
                        }
                    )
                }
            }

            if !upcoming.isEmpty {
                UpcomingEpisodesList(episodes: upcoming)
            }
        }
    }
}

/// Neutral, cancellable overlay shown while a source is being chosen.
///
/// Says nothing about addons or how many are being queried — the user asked to
/// watch something, not to observe the lookup.
struct ResolvingOverlay: View {
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                // Neutral, and deliberately so — the same rule the source list
                // already follows. Which addon is being queried is internal
                // mechanics, and naming a third party mid-wait reads as the app
                // explaining itself rather than getting on with it.
                Text("Loading…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)
                Button("Cancel", action: cancel)
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .padding(28)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .transition(.opacity)
    }
}

/// Compact list of episodes that haven't aired.
///
/// They carry no artwork or synopsis, so rendering them as cards produced a grid of
/// large empty placeholders that outweighed the real episodes.
struct UpcomingEpisodesList: View {
    let episodes: [Video]

    private static let dateFormat: Date.FormatStyle = .dateTime.day().month(.abbreviated).year()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upcoming")
                .font(Theme.Typography.fine.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.tertiaryText)

            VStack(spacing: 0) {
                ForEach(episodes) { episode in
                    HStack(spacing: 10) {
                        Text(episode.episodeCode ?? "—")
                            .font(Theme.Typography.fine.weight(.medium).monospacedDigit())
                            .foregroundStyle(Theme.Palette.tertiaryText)
                            .frame(width: 54, alignment: .leading)

                        // "TBA" is the addon's placeholder; showing it as a title
                        // implies content that does not exist.
                        Text(episode.displayName == "TBA" ? "Not yet announced" : episode.displayName)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .lineLimit(1)

                        Spacer(minLength: 12)

                        if let date = episode.airDate {
                            Text(date.formatted(Self.dateFormat))
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                        }
                    }
                    .padding(.vertical, 7)

                    if episode.id != episodes.last?.id {
                        Divider().overlay(Theme.Palette.separator)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// One episode as a card: thumbnail, identifier line, title, summary.
///
/// Replaces a dense list row. The thumbnail is the most useful thing about an
/// episode, and a card gives it real size; the grid then uses the window width
/// instead of stacking one narrow column.
struct EpisodeCard: View {
    let episode: Video
    var progress: WatchProgress?
    /// The one Play would start. Marked so the season grid answers "where am I?"
    /// without the viewer having to remember.
    var isUpNext: Bool = false
    let action: () -> Void
    var chooseSource: (() -> Void)?
    var setWatched: ((Bool) -> Void)?

    private static let dateFormat: Date.FormatStyle = .dateTime.day().month(.abbreviated).year()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    // Identifier and air date share a calm meta line, so the
                    // episode title is the only emphasized text on the card.
                    HStack(spacing: 6) {
                        Text(identifierLine)
                            .font(Theme.Typography.fine.weight(.medium))
                            .foregroundStyle(Theme.Palette.tertiaryText)

                        if isUpNext {
                            Text("UP NEXT")
                                .font(Theme.Typography.fine.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(Theme.Palette.background)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.Palette.accent))
                        }
                    }

                    Text(episode.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)

                    if let summary = episode.summary {
                        Text(summary)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let chooseSource {
                Button("Choose source…", systemImage: "list.bullet", action: chooseSource)
            }
            if let setWatched {
                // The escape hatch for a wrong record — an episode started by
                // accident otherwise keeps a resume point with no way to clear it.
                if isFinished {
                    Button("Mark as unwatched", systemImage: "arrow.uturn.backward") {
                        setWatched(false)
                    }
                } else {
                    Button("Mark as watched", systemImage: "checkmark") {
                        setWatched(true)
                    }
                }
            }
        }
    }

    private var thumbnail: some View {
        RemoteImage(string: episode.thumbnail)
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                // A finished episode previously showed nothing at all, so a season
                // grid gave no clue how far through it you were.
                if isFinished {
                    Image(systemName: "checkmark")
                        .font(.system(size: Theme.isTelevision ? 20 : 11, weight: .bold))
                        .foregroundStyle(Theme.Palette.background)
                        .padding(Theme.isTelevision ? 10 : 5)
                        .background(Circle().fill(.white))
                        .padding(Theme.isTelevision ? 12 : 6)
                }
            }
            .overlay {
                // Watched episodes recede so the unwatched ones read first.
                if isFinished {
                    RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                        .fill(Theme.Palette.background.opacity(0.45))
                }
            }
            .overlay(alignment: .bottomLeading) {
                // Resume indicator, so a part-watched episode is obvious without
                // opening it.
                if let fraction = watchedFraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.25))
                            Rectangle()
                                .fill(Theme.Palette.accent)
                                .frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)
            }
    }

    /// Nil when unwatched or finished — a full bar on every watched episode is
    /// noise, and the point is to mark what is part-way through.
    private var watchedFraction: Double? {
        guard let progress, progress.isResumable else { return nil }
        return max(0.02, progress.fractionComplete)
    }

    private var isFinished: Bool {
        progress?.isFinished == true
    }

    private var identifierLine: String {
        var parts: [String] = []
        if let code = episode.episodeCode { parts.append(code) }
        if let date = episode.airDate {
            parts.append(date.formatted(Self.dateFormat))
        }
        return parts.joined(separator: " · ")
    }
}

/// Identifies what the stream picker should resolve.
struct StreamTarget: Identifiable, Hashable {
    let type: MediaType
    /// The playable id — an episode id for series, the movie id otherwise.
    let videoId: String
    /// The parent title, so watch progress groups by show rather than by episode.
    let metaId: String
    let title: String

    var id: String { "\(type.rawValue)|\(videoId)" }

    init(type: MediaType, videoId: String, metaId: String? = nil, title: String) {
        self.type = type
        self.videoId = videoId
        // Episode ids are "tt0903747:1:1"; the parent is the leading component.
        self.metaId = metaId ?? videoId.split(separator: ":").first.map(String.init) ?? videoId
        self.title = title
    }
}

extension View {
    /// `navigationBarTitleDisplayMode` is iOS-only — neither macOS nor tvOS has a
    /// navigation bar with display modes.
    @ViewBuilder
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
