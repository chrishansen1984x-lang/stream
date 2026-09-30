import SwiftUI
import StreamCore

struct PersonView: View {
    let person: TMDBClient.CastMember
    @Environment(AppModel.self) private var model
    @State private var profile: PersonProfile?
    @State private var isLoading = true
    @State private var failed = false
    @State private var biographyExpanded = false
    @State private var role: PersonRole?
    @State private var genreID: Int?
    @State private var sort: FilmographySort = .popular
    @State private var resolving: String?
    @State private var resolved: MetaPreview?
    @State private var resolutionFailed = false
    @State private var loadAttempt = 0
    @State private var openTask: Task<Void, Never>?

    private var credits: [PersonCredit] { profile?.credits ?? [] }
    private var visibleCredits: [PersonCredit] {
        PersonCredit.filtered(credits, role: role, genreID: genreID, sort: sort)
    }
    private var roles: [PersonRole] {
        PersonRole.allCases.filter { candidate in credits.contains { $0.roles.contains(candidate) } }
    }
    private var genres: [Int] {
        Set(credits.flatMap(\.genreIDs)).filter { PersonCredit.genreNames[$0] != nil }
            .sorted { PersonCredit.genreNames[$0]! < PersonCredit.genreNames[$1]! }
    }
    private var portraitWidth: CGFloat { Theme.isTelevision ? 220 : 122 }
    private var posterWidth: CGFloat {
        #if os(macOS)
        150
        #else
        Theme.isTelevision ? 210 : 140
        #endif
    }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterWidth), spacing: Theme.Metrics.posterSpacing, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.isTelevision ? 40 : 30) {
                profileHeader
                filmography
            }
            .padding(Theme.Metrics.screenPadding)
            .padding(.bottom, 40)
        }
        .themedBackground()
        .navigationTitle(person.name)
        .navigationBarTitleDisplayModeInline()
        .navigationDestination(item: $resolved) { DetailView(item: $0) }
        .task(id: loadAttempt) { await load() }
        .onDisappear { openTask?.cancel(); resolving = nil }
        .alert("Not available", isPresented: $resolutionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This title couldn't be matched to an entry your addons can open.")
        }
    }

    private var profileHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.isTelevision ? 36 : 26) {
                portrait
                profileText.frame(minWidth: 240, maxWidth: 760, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 18) {
                portrait
                profileText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var portrait: some View {
        Group {
            if let url = profile?.profileURL ?? person.profileURL {
                RemoteImage(url: url)
            } else {
                ZStack {
                    Theme.Palette.surface
                    Image(systemName: "person.fill")
                        .font(.system(size: Theme.isTelevision ? 70 : 40))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
            }
        }
        .frame(width: portraitWidth, height: portraitWidth * 1.3)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    private var profileText: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !profession.isEmpty {
                Text(profession)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Text(person.name)
                .font(.system(size: Theme.isTelevision ? 48 : 34, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let bio = profile?.biography, !bio.isEmpty {
                Text(bio)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .lineSpacing(4)
                    .lineLimit(biographyExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    biographyExpanded.toggle()
                } label: {
                    Label(biographyExpanded ? "Show less" : "Read biography",
                          systemImage: biographyExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .font(Theme.Typography.meta)
                .accessibilityValue(biographyExpanded ? "Expanded" : "Collapsed")
            }
        }
        .foregroundStyle(Theme.Palette.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profession: String {
        let names = roles.compactMap { role -> String? in
            switch role {
            case .acting: return "Actor"
            case .directing: return "Director"
            case .writing: return "Writer"
            case .other: return nil
            }
        }
        return names.isEmpty ? (profile?.department ?? "") : names.joined(separator: " · ")
    }

    @ViewBuilder
    private var filmography: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Filmography").font(Theme.isTelevision ? .title2.bold() : .title2.weight(.semibold))
                Spacer()
                if !isLoading && !failed {
                    Text("\(visibleCredits.count) \(visibleCredits.count == 1 ? "title" : "titles")")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if failed {
                StateMessage(icon: "wifi.exclamationmark", title: "Couldn’t load filmography",
                             message: "Check your connection and try again.",
                             actionTitle: "Try again", action: { loadAttempt += 1 })
            } else if credits.isEmpty {
                Text("No filmography available.").foregroundStyle(Theme.Palette.secondaryText)
            } else {
                controls
                if visibleCredits.isEmpty {
                    StateMessage(icon: "line.3.horizontal.decrease", title: "No matching titles",
                                 message: "Try another role or genre.", actionTitle: "Clear filters",
                                 action: { role = nil; genreID = nil })
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(visibleCredits) { credit in
                            Button { open(credit) } label: { creditCard(credit) }
                                .posterButtonStyle()
                                .disabled(resolving != nil)
                                .accessibilityLabel("\(credit.title.title), \(credit.title.year ?? ""), \(credit.caption(for: role))")
                                .help(credit.caption(for: role))
                        }
                    }
                }
            }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                roleButtons.fixedSize()
                Spacer(minLength: 10)
                menus.fixedSize()
            }
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal) { roleButtons }.scrollIndicators(.hidden)
                menus
            }
        }
    }

    private var roleButtons: some View {
        HStack(spacing: 6) {
            roleButton(nil)
            ForEach(roles, id: \.self) { roleButton($0) }
        }
    }

    private func roleButton(_ value: PersonRole?) -> some View {
        Button { role = value } label: {
            Text(value?.rawValue ?? "All")
                .font(Theme.Typography.body.weight(.medium))
                .padding(.horizontal, Theme.isTelevision ? 20 : 12)
                .padding(.vertical, Theme.isTelevision ? 14 : 8)
                .background(role == value ? Theme.Palette.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(role == value ? Theme.Palette.primaryText : Theme.Palette.secondaryText)
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
        .accessibilityAddTraits(role == value ? .isSelected : [])
    }

    private var menus: some View {
        HStack(spacing: 14) {
            Menu {
                Button { genreID = nil } label: { menuChoice("All genres", selected: genreID == nil) }
                ForEach(genres, id: \.self) { id in
                    Button { genreID = id } label: { menuChoice(PersonCredit.genreNames[id]!, selected: genreID == id) }
                }
            } label: {
                Label(genreID.flatMap { PersonCredit.genreNames[$0] } ?? "All genres", systemImage: "chevron.down")
            }
            .accessibilityLabel("Genre")
            .accessibilityValue(genreID.flatMap { PersonCredit.genreNames[$0] } ?? "All genres")
            Menu {
                ForEach(FilmographySort.allCases, id: \.self) { value in
                    Button { sort = value } label: { menuChoice(value.rawValue, selected: sort == value) }
                }
            } label: { Label(sort.rawValue, systemImage: "chevron.down") }
            .accessibilityLabel("Sort")
            .accessibilityValue(sort.rawValue)
        }
        .font(Theme.Typography.body)
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder
    private func menuChoice(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func creditCard(_ credit: PersonCredit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RemoteImage(url: credit.title.posterURL)
                    .aspectRatio(Theme.Metrics.posterAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius))
                if resolving == credit.id {
                    Theme.Palette.background.opacity(0.6)
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(Theme.Metrics.posterAspect, contentMode: .fit)
            .clipped()
            Text(credit.title.title)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(2, reservesSpace: true)
            Text([credit.title.year, credit.title.isSeries ? "Series" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Palette.secondaryText)
                .lineLimit(1, reservesSpace: true)
            Text(credit.caption(for: role))
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Palette.secondaryText)
                .lineLimit(2, reservesSpace: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func load() async {
        isLoading = true
        failed = false
        do {
            let result = try await model.tmdb.personProfile(personId: person.id, apiKey: model.tmdbApiKey)
            guard !Task.isCancelled else { return }
            profile = result
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
        isLoading = false
    }

    private func open(_ credit: PersonCredit) {
        openTask?.cancel()
        resolving = credit.id
        openTask = Task {
            let title = credit.title
            let imdbId = await model.tmdb.imdbId(tmdbId: title.id, isSeries: title.isSeries, apiKey: model.tmdbApiKey)
            guard !Task.isCancelled else { return }
            resolving = nil
            guard let imdbId else { resolutionFailed = true; return }
            resolved = MetaPreview(id: imdbId, type: title.isSeries ? .series : .movie,
                                   name: title.title, poster: title.posterURL?.absoluteString, year: title.year)
        }
    }
}
