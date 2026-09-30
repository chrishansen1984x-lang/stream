import SwiftUI
import StreamCore
#if os(macOS)
import AppKit
#endif

/// Selects a playback engine from source metadata.
enum PlaybackRouter {

    /// Containers eligible for AVPlayer. Unknown containers use libVLC.
    private static let avPlayerContainers: Set<String> = ["mp4", "m4v", "mov"]

    /// Uses the addon filename, falling back to the playback URL extension.
    /// Container and audio metadata are hints; PlaybackController handles runtime fallback.
    static func engine(for item: RankedStream) -> PlaybackController.Engine {
        let container = item.stream.behaviorHints?.containerExtension
            ?? item.stream.playbackURL.flatMap { $0.pathExtension.isEmpty ? nil : $0.pathExtension.lowercased() }

        guard let container, avPlayerContainers.contains(container) else {
            return .software
        }
        if item.attributes.audioCodec?.requiresSoftwareDecode == true {
            return .software
        }
        return .avPlayer
    }
}

/// A resolved source, reduced to what playback actually needs.
///
/// `Codable`/`Hashable` because macOS opens the player as a separate window scene,
/// and SwiftUI requires window values to round-trip through state restoration.
struct PlaybackRequest: Codable, Hashable, Identifiable {
    var url: URL
    var title: String
    var preferSoftware: Bool
    /// Identity for watch tracking, carried through so the player can record
    /// progress without needing to reach back into the detail screen.
    var videoId: String
    var metaId: String
    var type: MediaType
    var startAt: Duration?
    var metaName: String?
    var poster: String?
    /// Advertised source size, used by preflight to detect placeholder clips.
    var expectedBytes: Int64?
    /// Remaining sources in ranked order for automatic fallback, including
    /// when preflight detects a playable provider error clip.
    var alternates: [Alternate] = []

    struct Alternate: Codable, Hashable, Sendable {
        var url: URL
        var expectedBytes: Int64?
        var preferSoftware: Bool
    }

    var id: String { url.absoluteString }

    #if DEBUG
    /// Creates a request with placeholder tracking fields for the `stream://play` debug link.
    init(previewing url: URL, title: String, software: Bool = false, startAt: Duration? = nil) {
        self.url = url
        self.title = title
        self.preferSoftware = software
        self.startAt = startAt
        self.videoId = "preview"
        self.metaId = "preview"
        self.type = .movie
    }
    #endif

    init?(stream: RankedStream, context: PlaybackContext, alternates: [RankedStream] = []) {
        guard let url = stream.stream.playbackURL else { return nil }
        self.url = url
        self.title = context.title
        self.preferSoftware = PlaybackRouter.engine(for: stream) == .software
        // `videoSize` only. `folderSize` is the whole torrent folder — a healthy
        // episode measured at 15% of it, which a size check would reject.
        self.expectedBytes = stream.stream.behaviorHints?.videoSize.map(Int64.init)
        self.videoId = context.videoId
        self.metaId = context.metaId
        self.type = context.type
        self.startAt = context.startAt
        self.metaName = context.metaName
        self.poster = context.poster
        // Deduplicate the selected source and alternates so fallback does not
        // probe the same URL twice when multiple addons return it.
        var seen: Set<URL> = [url]
        self.alternates = alternates.compactMap { candidate in
            guard let alternateURL = candidate.stream.playbackURL,
                  seen.insert(alternateURL).inserted else { return nil }
            return Alternate(
                url: alternateURL,
                expectedBytes: candidate.stream.behaviorHints?.videoSize.map(Int64.init),
                preferSoftware: PlaybackRouter.engine(for: candidate) == .software
            )
        }
    }
}

/// Everything the player needs that isn't the stream itself.
struct PlaybackContext: Hashable {
    var videoId: String
    var metaId: String
    var type: MediaType
    var title: String
    var startAt: Duration?
    /// Snapshot for the continue-watching shelf, so it needs no metadata lookup.
    var metaName: String?
    var poster: String?
}
