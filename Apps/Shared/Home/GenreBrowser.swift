import SwiftUI
import StreamCore

struct GenreBrowser: View {
    let genre: String
    @Binding var selection: String
    let open: (TMDBClient.TMDBTitle) -> Void
    @Environment(AppModel.self) private var model
    @State private var options = TMDBClient.BrowseOptions()
    @State private var hideWatched = false
    @State private var titles: [TMDBClient.TMDBTitle] = []
    @State private var imdbIDs: [Int: String] = [:]
    @State private var page = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var failed = false
    @State private var generation = UUID()
    @State private var loadedRequestKey: String?
    @State private var moreTask: Task<Void, Never>?

    private var themes: [GenreTheme] { GenreTheme.themes(for: genre) }
    private var selected: GenreTheme? { themes.first { $0.id == selection } }
    private var requestKey: String { "\(selection)|\(options)|\(hideWatched)|\(model.tmdbApiKey)" }
    private var visibleTitles: [TMDBClient.TMDBTitle] {
        titles.filter { title in
            guard hideWatched, let id = imdbIDs[title.id] else { return true }
            return model.watchState.progress(for: id)?.isFinished != true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Explore \(genre.lowercased()) movies")
                .font(.title2.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) { controls }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 12) { controls }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let theme = selected {
                if model.tmdbApiKey.isEmpty {
                    Text("Add your TMDB key in Settings to browse these collections.")
                } else {
                    Text(theme.title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.primaryText)
                    if hideWatched {
                        Text("Movies without a watch-history match stay visible.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Metrics.posterWidth), spacing: 18)], alignment: .leading, spacing: 24) {
                        ForEach(visibleTitles) { title in
                            Button { open(title) } label: { TMDBTitleCard(title: title) }
                                .posterButtonStyle()
                        }
                    }
                    if isLoading { ProgressView("Loading movies…") }
                    else if failed {
                        Text("Couldn't load this collection.")
                        Button("Try again") { loadMore() }
                    } else {
                        if visibleTitles.isEmpty {
                            Text("No movies match these filters on the loaded pages.")
                                .foregroundStyle(.secondary)
                        }
                        if hasMore { Button("Load more") { loadMore() }.buttonStyle(.bordered) }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .task(id: requestKey) {
            if loadedRequestKey == requestKey, page > 0 { return }
            moreTask?.cancel()
            let id = UUID()
            generation = id
            titles = []; imdbIDs = [:]; page = 0; hasMore = false; failed = false; isLoading = false
            await load(generation: id)
        }
        .onDisappear { moreTask?.cancel() }
    }

    private var sortTitle: String {
        switch options.sort {
        case "primary_release_date.desc": "Newest releases"
        case "vote_average.desc": "Highest rated"
        default: "Popular"
        }
    }

    @ViewBuilder private var controls: some View {
        browseMenu(title: "Category", value: selected?.title ?? "All \(genre.lowercased())", width: 230) {
            Picker("Category", selection: $selection) {
                Text("All \(genre.lowercased())").tag("")
                ForEach(themes) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        if selected != nil {
            browseMenu(title: "Sort", value: sortTitle, width: 190) {
                Picker("Sort", selection: $options.sort) {
                    Text("Popular").tag("popularity.desc")
                    Text("Newest releases").tag("primary_release_date.desc")
                    Text("Highest rated").tag("vote_average.desc")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            browseMenu(title: "Filters", value: "Filters", width: 120) {
                Picker("Decade", selection: $options.decade) {
                    Text("Any decade").tag(0)
                    ForEach(Array(stride(from: (Calendar.current.component(.year, from: Date()) / 10) * 10, through: 1920, by: -10)), id: \.self) {
                        Text("\(String($0))s").tag($0)
                    }
                }
                Picker("Runtime", selection: $options.runtime) {
                    Text("Any runtime").tag(0)
                    Text("Up to 90 minutes").tag(90)
                    Text("Up to 2 hours").tag(120)
                    Text("Up to 3 hours").tag(180)
                }
                Picker("Minimum rating", selection: $options.rating) {
                    Text("Any rating").tag(0)
                    ForEach(6...9, id: \.self) { Text("\($0)+").tag($0) }
                }
                Toggle("Hide watched", isOn: $hideWatched)
                Divider()
                Button("Reset filters") { options = .init(); hideWatched = false }
            }
        }
    }

    private func browseMenu<Content: View>(title: String, value: String, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack(spacing: 12) {
                Text(value).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(Theme.Typography.body)
            .padding(.horizontal, 12)
            .frame(width: width, height: 38)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func loadMore() {
        guard !isLoading else { return }
        let id = generation
        moreTask = Task { await load(generation: id) }
    }

    @MainActor private func load(generation id: UUID) async {
        guard let theme = selected, !model.tmdbApiKey.isEmpty else { return }
        isLoading = true; failed = false
        defer { if generation == id { isLoading = false } }
        do {
            let result = try await model.tmdb.browse(theme: theme, options: options, page: page + 1, apiKey: model.tmdbApiKey)
            var resolved: [Int: String] = [:]
            if hideWatched {
                // Bound lookups to five at a time; never request IDs for the whole catalog.
                for start in stride(from: 0, to: result.titles.count, by: 5) {
                    try Task.checkCancellation()
                    let batch = Array(result.titles[start..<min(start + 5, result.titles.count)])
                    let tmdb = model.tmdb
                    let key = model.tmdbApiKey
                    await withTaskGroup(of: (Int, String?).self) { group in
                        for title in batch {
                            group.addTask { (title.id, await tmdb.imdbId(tmdbId: title.id, isSeries: false, apiKey: key)) }
                        }
                        for await (movieID, imdbID) in group { resolved[movieID] = imdbID }
                    }
                }
            }
            guard !Task.isCancelled, generation == id else { return }
            var seen = Set(titles.map(\.id))
            titles += result.titles.filter { seen.insert($0.id).inserted }
            imdbIDs.merge(resolved) { _, new in new }
            page += 1; hasMore = result.hasMore
            loadedRequestKey = requestKey
        } catch {
            guard !Task.isCancelled, generation == id else { return }
            failed = true
        }
    }
}
