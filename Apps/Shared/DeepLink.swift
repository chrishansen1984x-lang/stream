import Foundation
import StreamCore

/// A `stream://` URL the app can be driven to.
///
/// Genuinely useful — it is how other apps and the Stremio ecosystem hand a title
/// off — and it is also the only practical way to reach a specific screen on a TV
/// from a script, which makes tvOS layouts testable without a remote.
enum DeepLink: Hashable {
    case home
    case search(query: String?)
    case settings
    case detail(MetaPreview, anchor: Anchor)

    /// Where a detail link should land. `episodes` is how another app hands off
    /// "continue this show" rather than "here is this show".
    enum Anchor: String, Hashable {
        case top
        case episodes
    }
    #if DEBUG
    /// `stream://play?url=…&title=…` — opens the player on a URL directly,
    /// bypassing addon resolution. The only way to inspect the player's own
    /// chrome on a TV without a remote to press Play with.
    case play(url: URL, title: String, software: Bool, startAt: Int?)
    /// `stream://fullscreen` — toggles the player window, for testing the path
    /// the enlarge button uses without needing to synthesise a click.
    case fullScreen
    /// `stream://seek?to=90` — drives the on-screen player's scrubber path.
    /// Dragging a slider cannot be synthesised here, so this is the only way to
    /// exercise a seek end to end.
    case seek(to: Int, fast: Bool)
    /// `stream://snapshot?path=/tmp/x.png` — writes the window to disk.
    case snapshot(path: String, window: String?)
    #endif

    static let scheme = "stream"

    /// Parses `stream://detail/tt0903747?type=series&name=Breaking%20Bad`,
    /// `stream://search?q=dune`, `stream://settings`, `stream://home`.
    init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }

        switch url.host() {
        case "home":
            self = .home

        case "search":
            self = .search(query: value("q"))

        case "settings":
            self = .settings

        #if DEBUG
        case "fullscreen":
            self = .fullScreen

        case "seek":
            guard let to = value("to").flatMap(Int.init) else { return nil }
            self = .seek(to: to, fast: value("fast") == "1")

        case "snapshot":
            guard let path = value("path") else { return nil }
            self = .snapshot(path: path, window: value("window"))

        case "play":
            guard let raw = value("url"), let target = URL(string: raw) else { return nil }
            self = .play(
                url: target,
                title: value("title") ?? "Preview",
                software: value("software") == "1",
                startAt: value("at").flatMap(Int.init)
            )
        #endif

        case "detail":
            // The id is the first path component: stream://detail/tt0903747
            let id = url.pathComponents.first { $0 != "/" }
            guard let id, !id.isEmpty else { return nil }
            let type = MediaType(rawValue: value("type") ?? MediaType.movie.rawValue)
            self = .detail(
                MetaPreview(id: id, type: type, name: value("name") ?? id),
                anchor: Anchor(rawValue: value("at") ?? "") ?? .top
            )

        default:
            return nil
        }
    }

    #if DEBUG
    /// A link passed at launch: `simctl launch <id> <bundle> -streamLink stream://settings`.
    ///
    /// tvOS puts a system confirmation in front of `openurl`, which needs a remote
    /// to dismiss, so a launch argument is the only way to drive the app to a
    /// screen from a script. Debug-only; it is a test hook, not a feature.
    static var fromLaunchArguments: DeepLink? {
        guard let raw = UserDefaults.standard.string(forKey: "streamLink"),
              let url = URL(string: raw)
        else { return nil }
        return DeepLink(url: url)
    }
    #endif
}
