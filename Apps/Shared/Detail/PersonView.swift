import SwiftUI
import StreamCore

/// A cast member's filmography.
///
/// TMDB credits are keyed on TMDB ids while the addon protocol is keyed on IMDb
/// ids, so opening a title resolves the id first. That resolution is done lazily —
/// only for the title actually tapped — rather than for all forty up front.
struct PersonView: View {
    let person: TMDBClient.CastMember

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var credits: [TMDBClient.TMDBTitle] = []
    @State private var isLoading = true
    @State private var resolving: Int?
    @State private var resolved: MetaPreview?
    @State private var resolutionFailed = false

    private let columns = [GridItem(.adaptive(minimum: Theme.Metrics.creditPosterWidth), spacing: 14, alignment: .top)]

    var body: some View {
        // Pushed into the existing navigation stack rather than presented as a
        // sheet: a filmography is a place you browse to and come back from, and a
        // sheet on macOS reads as a separate window.
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if credits.isEmpty {
                StateMessage(
                    icon: "person.crop.circle",
                    title: person.name,
                    message: "No filmography available."
                )
            } else {
                grid
            }
        }
        .themedBackground()
        .navigationTitle(person.name)
        .navigationBarTitleDisplayModeInline()
        .navigationDestination(item: $resolved) { item in
            DetailView(item: item)
        }
        .task {
            credits = await model.tmdb.credits(personId: person.id, apiKey: model.tmdbApiKey)
            isLoading = false
        }
        .alert("Not available", isPresented: $resolutionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This title couldn't be matched to an entry your addons can open.")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(credits) { credit in
                    Button {
                        open(credit)
                    } label: {
                        creditCard(credit)
                    }
                    .posterButtonStyle()
                }
            }
            .padding(Theme.Metrics.screenPadding)
        }
        .scrollIndicators(.never)
    }

    private func creditCard(_ credit: TMDBClient.TMDBTitle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RemoteImage(url: credit.posterURL)
                    .frame(width: Theme.Metrics.creditPosterWidth, height: Theme.Metrics.creditPosterWidth / Theme.Metrics.posterAspect)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous))

                if resolving == credit.id {
                    RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                        .fill(.black.opacity(0.55))
                    ProgressView().controlSize(.small).tint(.white)
                }
            }

            Text(credit.title)
                .font(Theme.Typography.meta)
                .fontWeight(.medium)
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)

            // Space is reserved whether or not a character name exists. Without
            // this, cells differ in height and the grid rows stagger.
            Text(credit.character?.isEmpty == false ? credit.character! : " ")
                .font(Theme.Typography.fine)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Theme.Metrics.creditPosterWidth, alignment: .topLeading)
    }

    private func open(_ credit: TMDBClient.TMDBTitle) {
        resolving = credit.id
        Task {
            let imdbId = await model.tmdb.imdbId(
                tmdbId: credit.id,
                isSeries: credit.isSeries,
                apiKey: model.tmdbApiKey
            )
            resolving = nil

            guard let imdbId else {
                // Plenty of TMDB entries have no IMDb id, and the addon protocol
                // cannot address those at all.
                resolutionFailed = true
                return
            }

            resolved = MetaPreview(
                id: imdbId,
                type: credit.isSeries ? .series : .movie,
                name: credit.title,
                year: credit.year
            )
        }
    }
}
