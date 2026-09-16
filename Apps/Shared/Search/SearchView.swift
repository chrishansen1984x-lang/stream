import SwiftUI
import StreamCore

@Observable
@MainActor
final class SearchViewModel {
    private(set) var results: [MetaPreview] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    /// How many catalogs failed to answer the last search.
    ///
    /// Every failure used to collapse into an empty array, and the empty state then
    /// stated as fact something it could not know — "No installed catalog matched
    /// X" is a claim about the catalogs' *answers*, and with the network down there
    /// were no answers. Counting them lets the screen say which of the two it is.
    private(set) var failedSources = 0

    private var currentTask: Task<Void, Never>?

    /// Debounced search across every catalog that advertises `search` support.
    func search(
        query: String,
        registry: AddonRegistry,
        client: AddonClient,
        hiding theatrical: TheatricalWindow = TheatricalWindow()
    ) {
        currentTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }

        currentTask = Task {
            // Debounce: users type faster than addons respond.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            isSearching = true
            let sources = registry.searchableCatalogs

            var collected: [MetaPreview] = []
            var failures = 0
            // `[MetaPreview]?` rather than `[MetaPreview]`: nil is "did not answer",
            // which an empty array cannot express and which the empty state needs.
            await withTaskGroup(of: [MetaPreview]?.self) { group in
                for source in sources {
                    group.addTask {
                        // `try?` on a non-optional return already gives an
                        // optional; nil means the catalog did not answer.
                        try? await client.catalog(
                            from: source.addon,
                            type: source.catalog.type,
                            id: source.catalog.id,
                            extra: [.search(trimmed)]
                        ).metas
                    }
                }
                for await batch in group {
                    if let batch {
                        collected.append(contentsOf: batch)
                    } else {
                        failures += 1
                    }
                }
            }

            guard !Task.isCancelled else { return }

            // The same title often comes from several catalogs; keep first occurrence.
            // Films still in cinemas are dropped first: searching for one and being
            // offered a row that cannot play is worse than not finding it.
            var seen = Set<String>()
            results = collected
                .filter { !theatrical.hides($0) }
                .filter { seen.insert($0.id).inserted }

            failedSources = failures
            isSearching = false
            hasSearched = true
        }
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel = SearchViewModel()
    @State private var query = ""
    @State private var selection: MetaPreview?
    /// macOS: focused on appear so Search means "start typing", not "click the
    /// field, then start typing".
    @FocusState private var isSearchFieldFocused: Bool

    // Generous minimum and spacing: at the tighter values the posters nearly
    // touched and two-line titles ran into the neighbouring column.
    private var columns: [GridItem] {
        #if os(tvOS)
        // Fixed count, not `.adaptive`. Adaptive divides the leftover width into
        // the columns, so a 210pt poster sat in a 331pt column: ragged gutters,
        // and captions wrapping at 210 with 120pt of unused space beside them.
        // A fixed count lets the poster take the whole column instead.
        Array(
            repeating: GridItem(.flexible(), spacing: Theme.Metrics.posterSpacing, alignment: .top),
            count: 6
        )
        #else
        [GridItem(
            .adaptive(minimum: Theme.Metrics.posterWidth + 24),
            spacing: Theme.Metrics.posterSpacing + 10,
            alignment: .top
        )]
        #endif
    }

    /// Width of one grid cell on tvOS, where the column count is fixed.
    private var gridPosterWidth: CGFloat {
        #if os(tvOS)
        let columnCount: CGFloat = 6
        // tvOS lays out in a fixed 1920x1080 point space on every Apple TV; the
        // 1080p/4K difference is scale factor, not points.
        let available = 1920 - (Theme.Metrics.screenPadding * 2)
        return (available - Theme.Metrics.posterSpacing * (columnCount - 1)) / columnCount
        #else
        return Theme.Metrics.posterWidth
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // macOS gets an explicit field: `.searchable` does not surface one
                // in a NavigationSplitView detail pane, which left the screen with
                // no way to type at all.
                #if os(macOS)
                searchField
                    .onAppear { isSearchFieldFocused = true }
                #endif

                content
            }
            .themedBackground()
            #if !os(tvOS)
            // tvOS draws a navigation title as large centred text in the same band
            // the search field and keyboard occupy, so "Search" showed through the
            // middle of the letters. The top bar already names the section.
            .navigationTitle("Search")
            #endif
            .navigationDestination(item: $selection) { item in
                DetailView(item: item)
            }
        }
        #if !os(macOS)
        .searchable(text: $query, prompt: "Movies and series")
        #endif
        .onChange(of: query) { _, newValue in
            viewModel.search(query: newValue, registry: model.registry, client: model.client, hiding: theatricalFilter)
        }
        .onChange(of: model.pendingLink, initial: true) { _, link in
            guard case .search(let incoming) = link else { return }
            if let incoming { query = incoming }
            model.pendingLink = nil
        }
    }

    /// tvOS only — see `HomeView.theatricalFilter`.
    private var theatricalFilter: TheatricalWindow {
        #if os(tvOS)
        model.theatrical
        #else
        TheatricalWindow()
        #endif
    }

    private func retry() {
        viewModel.search(query: query, registry: model.registry, client: model.client, hiding: theatricalFilter)
    }

    /// The results stay mounted while a new search runs.
    ///
    /// Swapping the whole area to a centred spinner on every query tore the grid
    /// down and rebuilt it once per keystroke — a visible flash on a pointer, and
    /// on a TV it also destroyed focus mid-typing, which is what made entering
    /// text from the phone keyboard feel broken. Progress is now an overlay that
    /// changes nothing underneath it.
    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .top) {
            if !viewModel.results.isEmpty {
                grid
            } else if viewModel.hasSearched && !viewModel.isSearching {
                // Two different situations that used to read identically. Naming no
                // addon keeps to the neutral-copy rule; stating a search found
                // nothing when nothing answered does not.
                if viewModel.failedSources > 0 {
                    StateMessage(
                        icon: "exclamationmark.triangle",
                        title: "Couldn’t search everything",
                        message: "Some catalogs didn’t respond. Check your connection and try again.",
                        actionTitle: "Try again",
                        action: { retry() }
                    )
                } else {
                    StateMessage(
                        icon: "magnifyingglass",
                        title: "No results",
                        message: "No installed catalog matched “\(query)”."
                    )
                }
            } else if !viewModel.hasSearched && !viewModel.isSearching {
                StateMessage(
                    icon: "magnifyingglass",
                    title: "Search",
                    message: "Find movies and series across every catalog you have installed."
                )
            }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: viewModel.isSearching)
    }

    #if os(macOS)
    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Palette.tertiaryText)

            TextField("Movies and series", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
                .font(.title3)
                .foregroundStyle(Theme.Palette.primaryText)
                .onSubmit {
                    viewModel.search(query: query, registry: model.registry, client: model.client, hiding: theatricalFilter)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.Palette.surface, in: Capsule())
        .padding(Theme.Metrics.screenPadding)
    }
    #endif

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                ForEach(viewModel.results) { item in
                    PosterButton(
                        width: gridPosterWidth,
                        caption: item.name,
                        artwork: { RemoteImage(string: item.poster, title: item.name) },
                        action: { selection = item }
                    )
                    // Grid rows size to their tallest cell; without this, shorter
                    // cells stretch and their captions drift away from the poster.
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(Theme.Metrics.screenPadding)
            // Clears the floating tab bar so the last row is reachable.
            .padding(.bottom, 60)
        }
        // Without this the grid keeps tvOS's own title-safe inset on top of
        // `screenPadding`, so posters started ~67pt right of the search field
        // above them and the column left edge looked ragged.
        .tvFullBleedHorizontal()
        .scrollIndicators(.never)
    }
}
