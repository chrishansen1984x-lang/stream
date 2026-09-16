import Foundation

/// One request made before the player sees a source, for two unrelated reasons
/// that happen to want the same request.
///
/// **Redirects.** Every debrid playback link is a `307` to a CDN host, and
/// libVLC's HTTP/2 client sometimes fails to follow it: when the server's
/// END_STREAM arrives before libVLC cancels the stream, it errors with
/// `Stream closed (0x5)`, sends a second RST_STREAM, tears the connection down
/// and never issues the redirected request. No error, no event, no log — the
/// player sits in `opening` until the 45s watchdog gives up. Measured 2026-08-21:
/// 18 stalls in 52 attempts across macOS, iOS and tvOS; 0 in 28 when the redirect
/// was resolved first. Following it here, with URLSession, means libVLC only ever
/// sees a direct URL. It is not free — the probe adds roughly 350ms to the median
/// time to first frame, because the app now pays for the redirect libVLC used to
/// follow itself. Trading a third of a second for a hang that happened on more
/// than a quarter of plays, and produced no error until a 45s timeout, is worth it.
///
/// **Placeholders.** When the provider cannot produce the file it advertised, it
/// answers with a small, valid, playable MP4 instead of an error. Stream played
/// one for 120 seconds and wrote it to the library as a 106-minute film watched
/// to completion. The same response that resolves the redirect also says how many
/// bytes are really there and where they came from.
public struct SourcePreflight: Sendable {

    /// A source that has been checked and is safe to hand to a player.
    public struct Resolved: Sendable, Equatable {
        /// The URL after redirects — what the player should actually open.
        public var url: URL
        /// Total size of the media, from `Content-Range`, when the server says.
        public var servedBytes: Int64?
        public var contentType: String?
    }

    public enum Problem: Error, Sendable, Equatable {
        /// The provider served something other than the media it advertised.
        case placeholder(reason: String)

        public var message: String {
            switch self {
            case .placeholder(let reason): reason
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // A source that cannot even answer a one-byte range request in this
            // long is not going to stream. Well inside the player's own 45s
            // watchdog, so a slow probe still leaves time to open.
            configuration.timeoutIntervalForRequest = 12
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Resolves `url` and judges what it points at.
    ///
    /// `advertisedBytes` must be the addon's `videoSize` — the size of the *file*.
    /// Never `folderSize`: that is the whole torrent folder, and a healthy episode
    /// measured at 15% of it, which a size check would call a placeholder.
    ///
    /// Anything that is not an HTTP(S) URL is returned unchanged; `file://` needs
    /// none of this and answers none of it.
    public func resolve(_ url: URL, advertisedBytes: Int64? = nil) async -> Result<Resolved, Problem> {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .success(Resolved(url: url, servedBytes: nil, contentType: nil))
        }

        var request = URLRequest(url: url)
        // A ranged GET, not HEAD. AIOStreams answers `405` to HEAD, and the
        // total size arrives in `Content-Range` either way.
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.httpMethod = "GET"

        // `bytes(for:)`, never `data(for:)`. The latter returns only once the
        // whole body has arrived and sits in memory, and a server that ignores
        // `Range` answers this one-byte request with the entire file: gigabytes
        // into RAM on an Apple TV, which is a jetsam kill. Headers are all this
        // needs, so the body is cancelled unread the moment they are in.
        guard let (body, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse
        else {
            // The probe is an optimisation and a safety net, not a gate. If it
            // cannot be made — offline, a server that refuses ranges — the player
            // still gets the source it would have got before this existed.
            return .success(Resolved(url: url, servedBytes: nil, contentType: nil))
        }

        body.task.cancel()

        let finalURL = http.url ?? url
        let served = Self.totalBytes(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
            ?? (http.expectedContentLength > 1 ? http.expectedContentLength : nil)

        switch Self.verdict(finalURL: finalURL, servedBytes: served, advertisedBytes: advertisedBytes, contentType: http.value(forHTTPHeaderField: "Content-Type")) {
        case .placeholder(let reason):
            return .failure(.placeholder(reason: reason))
        case .playable:
            return .success(
                Resolved(
                    url: finalURL,
                    servedBytes: served,
                    contentType: http.value(forHTTPHeaderField: "Content-Type")
                )
            )
        }
    }

    // MARK: - The decision, separated from the request so it can be tested

    public enum Verdict: Equatable, Sendable {
        case playable
        case placeholder(reason: String)
    }

    /// Below this fraction of the advertised size, it is not the film.
    ///
    /// Deliberately far from the boundary. Across six healthy sources the served
    /// total matched `videoSize` *exactly* — ratio 1.000 on files from 2.7 GB to
    /// 59.8 GB — while the placeholder came in at 1/264th of what was advertised.
    /// There is nothing in between to be careful about.
    private static let minimumServedFraction = 0.5

    public static func verdict(
        finalURL: URL,
        servedBytes: Int64?,
        advertisedBytes: Int64?,
        contentType: String? = nil
    ) -> Verdict {
        // The provider names its own failure. `slate.elfhosted.com/…/slate.mp4`
        // is served with the reason in the redirect's query string, which is a
        // better thing to put on screen than two minutes of someone else's error
        // card — and it catches the case where nothing was advertised to compare
        // a byte count against, which is exactly the case that bit us.
        if isProviderSlate(finalURL) {
            return .placeholder(reason: slateReason(from: finalURL))
        }

        // A manifest describes segments; its own size is unrelated to the video.
        let mime = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        if ["m3u8", "m3u", "mpd"].contains(finalURL.pathExtension.lowercased())
            || ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl", "application/dash+xml"].contains(mime ?? "") {
            return .playable
        }

        if let advertisedBytes, advertisedBytes > 0,
           let servedBytes, servedBytes > 0,
           Double(servedBytes) < Double(advertisedBytes) * minimumServedFraction {
            return .placeholder(
                reason: "This source returned \(byteLabel(servedBytes)) where the addon "
                    + "advertised \(byteLabel(advertisedBytes)). It is a placeholder, not the "
                    + "film — try another source."
            )
        }

        return .playable
    }

    /// ElfHosted's error-card service, which answers with a real playable MP4.
    ///
    /// Host only. Matching on the filename as well looked harmless and was not:
    /// it refused a perfectly good file that happened to be called `slate.mp4`
    /// on an unrelated server. A false negative here plays an error card, which
    /// the size check may still catch and the viewer can recover from; a false
    /// positive refuses to play a film that works. So this stays narrow, and
    /// widens only against evidence of the slate being served from somewhere
    /// else.
    static func isProviderSlate(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host == "slate.elfhosted.com"
    }

    /// The provider's own words, out of the redirect it sent us to.
    static func slateReason(from url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // The reason arrives form-encoded — spaces as `+`, which `queryItems`
        // does not decode; it only undoes percent-escapes. Rewriting `+` as
        // `%20` in the raw query first is what makes the message read as a
        // sentence instead of "No+matching+file". Done before decoding, so a
        // literal plus sent as `%2B` still survives as a plus.
        if let query = components?.percentEncodedQuery {
            components?.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%20")
        }
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces).nilIfBlank
        }
        let title = value("title")
        let body = value("body")

        switch (title, body) {
        case let (title?, body?): return "\(title) — \(body)"
        case let (title?, nil): return title
        case let (nil, body?): return body
        case (nil, nil):
            return "The provider returned a placeholder clip instead of this title. "
                + "Try another source."
        }
    }

    /// `bytes 0-0/4375418` → `4375418`.
    static func totalBytes(fromContentRange header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let total = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        // A server that does not know the length sends `*`.
        return Int64(total)
    }

    private static func byteLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
