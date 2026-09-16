import SwiftUI
import Observation
import ImageIO

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// In-memory cache of decoded images.
///
/// `AsyncImage` re-fetches and re-decodes on every appearance, which makes a shelf of
/// posters flicker badly while scrolling. Holding decoded images keeps reuse cheap.
/// The cost limit matters on tvOS, where memory is far tighter than on iOS.
actor ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        cache.countLimit = 400
        // Decoded pixels, now that `cost` is measured in them. It used to be the
        // *download* size, and the cache held decoded bitmaps — a 200 KB backdrop
        // is 8 MB decoded — so the old 96 MB limit admitted several hundred
        // megabytes, which on an Apple TV is the memory pressure that gets an app
        // killed. Tighter on the television for the same reason.
        cache.totalCostLimit = (Theme.isTelevision ? 128 : 192) * 1024 * 1024
        return cache
    }()

    /// Longest edge kept, in pixels. Nothing draws larger than a full-width
    /// backdrop, and a 4K poster decoded whole for a 116pt tile is memory spent on
    /// pixels nobody sees.
    private static let maximumPixelSize = 2048

    /// Decodes through ImageIO, downsampling on the way, and reports the real
    /// footprint.
    private static func decode(_ data: Data) -> (image: PlatformImage, cost: Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        #if canImport(UIKit)
        let image = UIImage(cgImage: cgImage)
        #else
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
        return (image, cgImage.width * cgImage.height * 4)
    }

    /// In-flight downloads are keyed by URL and hold `Data` rather than a decoded
    /// image, because `Data` is `Sendable` and the platform image types are not.
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    func image(for url: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }

        // Coalesce concurrent requests — a shelf reload would otherwise fire one
        // download per visible cell for the same artwork.
        let task: Task<Data?, Never>
        if let existing = inFlight[url] {
            task = existing
        } else {
            task = Task { try? await URLSession.shared.data(from: url).0 }
            inFlight[url] = task
        }

        let data = await task.value
        inFlight[url] = nil

        guard let data else { return nil }
        // ImageIO first; the platform decoder as a fallback for anything it
        // refuses, costed generously since its size is not known.
        guard let (image, cost) = Self.decode(data)
            ?? PlatformImage(data: data).map({ ($0, data.count * 8) })
        else { return nil }
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }
}

/// Cached, cross-platform async image with a placeholder and fade-in.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// Renders the image as a solid silhouette in this colour.
    ///
    /// Needed for third-party logos: TMDB's studio and network marks are mostly
    /// *black* on transparent, so on a dark background they are invisible. Template
    /// rendering uses only the alpha channel, so any logo — black, white, or
    /// coloured — comes out legible and consistent.
    var templateTint: Color?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: PlatformImage?
    /// Distinguishes "still fetching" from "there is nothing to fetch".
    ///
    /// Both used to render the same grey card with a film icon, so a shelf that
    /// was working looked identical to a shelf that had given up, and the only way
    /// to tell was to wait and see whether anything changed.
    @State private var isFetching = true

    var body: some View {
        Group {
            if let image {
                if let templateTint {
                    // `renderingMode` must be applied to the Image before `resizable`.
                    imageView(image)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .foregroundStyle(templateTint)
                        .transition(.opacity)
                } else {
                    imageView(image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            } else {
                placeholder()
                    .environment(\.artworkIsLoading, isFetching)
            }
        }
        .animation(.easeOut(duration: 0.20), value: image != nil)
        .task(id: url) {
            // Reloads whenever the URL changes.
            //
            // The guard here used to be `image == nil, !didFail`, which made a
            // change of URL a permanent no-op once anything had loaded: the view
            // kept the first artwork it ever fetched. SwiftUI reuses a view in
            // place rather than rebuilding it, so this hit everywhere a URL
            // changes under a stable view — the Home hero drew one title's
            // backdrop and logo above another title's synopsis and rating, and
            // switching season kept the previous season's episode stills.
            guard let url else {
                image = nil
                isFetching = false
                return
            }
            isFetching = true
            let loaded = await ImageCache.shared.image(for: url)
            // `.task(id:)` cancels the previous run when the URL changes, but the
            // fetch itself is not cancellation-aware; without this a slow load
            // could land after a newer one and put the old artwork back.
            guard !Task.isCancelled else { return }
            image = loaded
            isFetching = false
        }
    }

    private func imageView(_ platformImage: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: platformImage)
        #else
        Image(nsImage: platformImage)
        #endif
    }
}

extension RemoteImage where Placeholder == ArtworkPlaceholder {
    /// `title` is what the placeholder falls back to when no artwork exists. Worth
    /// passing wherever the caller already knows it: a grid of identical grey film
    /// icons tells you nothing, and initials at least keep the row readable.
    init(url: URL?, contentMode: ContentMode = .fill, templateTint: Color? = nil, title: String? = nil) {
        self.init(url: url, contentMode: contentMode, templateTint: templateTint) {
            ArtworkPlaceholder(title: title)
        }
    }

    init(string: String?, contentMode: ContentMode = .fill, templateTint: Color? = nil, title: String? = nil) {
        self.init(
            url: string.flatMap(URL.init(string:)),
            contentMode: contentMode,
            templateTint: templateTint
        ) {
            ArtworkPlaceholder(title: title)
        }
    }
}

extension RemoteImage where Placeholder == Color {
    /// Transparent placeholder, for logos where a grey fill would read as a
    /// broken image while loading.
    init(logo url: URL?, tint: Color) {
        self.init(url: url, contentMode: .fit, templateTint: tint) { Color.clear }
    }
}

/// Neutral fill shown while artwork loads or when an addon supplies none.
///
/// The two are drawn differently on purpose. A shimmer means the tile is still
/// waiting and is worth waiting for; a static card means this is as good as it
/// gets. Showing one card for both left the viewer unable to tell a slow shelf
/// from a broken one.
struct ArtworkPlaceholder: View {
    var title: String?
    @Environment(\.artworkIsLoading) private var isLoading

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Theme.Palette.surfaceRaised, Theme.Palette.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if isLoading {
                    EmptyView()
                } else if let initials = title?.artworkInitials {
                    Text(initials)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                        .padding(8)
                } else {
                    Image(systemName: "film")
                        .font(.title3)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
            }
            .shimmering(isActive: isLoading)
    }
}

extension String {
    /// Up to two initials, the way a person would abbreviate a title:
    /// "Breaking Bad" → "BB", "The Bear" → "B", "The Lord of the Rings" → "LR".
    ///
    /// Case is the signal for which words carry the title. Taking the first two
    /// words outright gave "LO" for *The Lord of the Rings*, because "of" is a word
    /// nobody says when shortening a name; capitalised words are the ones they do.
    var artworkInitials: String? {
        let words = split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var significant = words.filter { $0.first?.isUppercase == true || $0.first?.isNumber == true }
        // An all-lowercase title has no case signal, so every word counts.
        if significant.isEmpty { significant = words }
        if significant.count > 1, ["the", "a", "an"].contains(significant[0].lowercased()) {
            significant.removeFirst()
        }
        let initials = significant.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? nil : initials.uppercased()
    }
}

private struct ArtworkLoadingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the artwork this placeholder stands in for is still being fetched.
    ///
    /// Passed through the environment rather than as a parameter so the placeholder
    /// stays a plain `View` that any caller can substitute.
    var artworkIsLoading: Bool {
        get { self[ArtworkLoadingKey.self] }
        set { self[ArtworkLoadingKey.self] = newValue }
    }
}

/// Sweeping highlight for content that has not arrived yet.
private struct Shimmer: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travel: CGFloat = -1

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content
                .overlay {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.07), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.5)
                        .offset(x: travel * geometry.size.width * 1.5)
                    }
                }
                .clipped()
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        travel = 1
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmering(isActive: Bool) -> some View {
        modifier(Shimmer(isActive: isActive))
    }
}
