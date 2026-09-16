import SwiftUI
import StreamCore

/// Poster tile for a TMDB-sourced title.
///
/// TMDB titles carry a TMDB id while the addon protocol is keyed on IMDb ids, so
/// tapping resolves the id first. That resolution is deliberately lazy — one
/// request for the title actually chosen, rather than one per tile on a shelf of
/// twenty.
struct TMDBTitleCard: View {
    let title: TMDBClient.TMDBTitle
    var width: CGFloat = Theme.Metrics.posterWidth
    var showsCharacter = false
    var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RemoteImage(url: title.posterURL)
                    .frame(width: width, height: width / Theme.Metrics.posterAspect)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                            .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)
                    }

                if isResolving {
                    RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                        .fill(.black.opacity(0.55))
                    ProgressView().controlSize(.small).tint(.white)
                }
            }

            Text(title.title)
                .font(Theme.Typography.meta)
                .fontWeight(.medium)
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsCharacter {
                // Space is reserved whether or not a character exists, so grid rows
                // stay uniform.
                Text(title.character?.isEmpty == false ? title.character! : " ")
                    .font(Theme.Typography.fine)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}

/// Resolves a TMDB title to something the addons can open.
@Observable
@MainActor
final class TMDBTitleOpener {
    private(set) var resolving: Int?
    var resolved: MetaPreview?
    var failed = false

    func open(_ title: TMDBClient.TMDBTitle, tmdb: TMDBClient, apiKey: String) {
        resolving = title.id
        Task {
            let imdbId = await tmdb.imdbId(
                tmdbId: title.id,
                isSeries: title.isSeries,
                apiKey: apiKey
            )
            resolving = nil

            guard let imdbId else {
                // Plenty of TMDB entries carry no IMDb id, and the addon protocol
                // cannot address those at all.
                failed = true
                return
            }

            resolved = MetaPreview(
                id: imdbId,
                type: title.isSeries ? .series : .movie,
                name: title.title,
                year: title.year
            )
        }
    }
}
