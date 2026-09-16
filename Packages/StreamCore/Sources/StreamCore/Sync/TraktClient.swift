import Foundation
import os

/// Trakt.tv sync.
///
/// Chosen over iCloud for cross-device progress because it needs no Apple
/// entitlement, authenticates on a TV without a browser, and — unlike a private
/// store — shares progress with Plex, Infuse, and Stremio rather than trapping it
/// in this app.
public actor TraktClient {

    /// Shown to the user while they authorize on another device.
    public struct DeviceCode: Sendable, Hashable {
        public var userCode: String
        public var verificationURL: String
        var deviceCode: String
        var interval: Int
        var expiresIn: Int
    }

    /// A resume point Trakt is holding for us.
    public struct PlaybackItem: Sendable, Hashable {
        /// Protocol video id — `tt123` for a movie, `tt123:1:4` for an episode.
        public var videoId: String
        public var metaId: String
        public var type: MediaType
        /// 0–100, as Trakt reports it.
        public var progress: Double
        /// Total length, derived from Trakt's runtime in minutes.
        public var runtime: Duration?
        public var pausedAt: Date
        public var title: String?
    }

    public enum TraktError: LocalizedError, Sendable {
        case notConfigured
        case authorizationPending
        case slowDown
        case expired
        case denied
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your Trakt client ID and secret in Settings first."
            case .authorizationPending: "Waiting for you to approve the code."
            case .slowDown: "Polling too quickly."
            case .expired: "The code expired. Start again."
            case .denied: "Authorization was declined."
            case .http(let code): "Trakt returned HTTP \(code)."
            }
        }
    }

    private let session: URLSession
    private let logger = Logger(subsystem: "com.stream.core", category: "Trakt")
    private static let base = "https://api.trakt.tv"

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Device authorization

    /// Starts the device flow. The user types the returned code at the returned URL
    /// on any device — which is the whole reason this flow suits a TV.
    public func requestDeviceCode(clientId: String) async throws -> DeviceCode {
        guard !clientId.isEmpty else { throw TraktError.notConfigured }

        let payload = ["client_id": clientId]
        let data = try await post("/oauth/device/code", body: payload, clientId: clientId)
        let decoded = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)

        return DeviceCode(
            userCode: decoded.userCode,
            verificationURL: decoded.verificationUrl,
            deviceCode: decoded.deviceCode,
            interval: decoded.interval,
            expiresIn: decoded.expiresIn
        )
    }

    /// Polls until the user approves. Trakt signals state through HTTP status
    /// codes rather than a body, so they are mapped explicitly.
    public func pollForToken(
        deviceCode: DeviceCode,
        clientId: String,
        clientSecret: String
    ) async throws -> TraktTokens {
        let deadline = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))
        var interval = TimeInterval(deviceCode.interval)

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))

            let body = [
                "code": deviceCode.deviceCode,
                "client_id": clientId,
                "client_secret": clientSecret
            ]

            var request = URLRequest(url: URL(string: Self.base + "/oauth/device/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            switch status {
            case 200:
                return try JSONDecoder().decode(TraktTokens.self, from: data)
            case 400:
                continue                      // still pending
            case 429:
                interval += 1                 // slow down
            case 404:
                throw TraktError.expired
            case 409:
                throw TraktError.expired      // already used
            case 410:
                throw TraktError.expired
            case 418:
                throw TraktError.denied
            default:
                throw TraktError.http(status)
            }
        }

        throw TraktError.expired
    }

    public func refresh(
        refreshToken: String,
        clientId: String,
        clientSecret: String
    ) async throws -> TraktTokens {
        let body = [
            "refresh_token": refreshToken,
            "client_id": clientId,
            "client_secret": clientSecret,
            "grant_type": "refresh_token"
        ]
        let data = try await post("/oauth/token", body: body, clientId: clientId)
        return try JSONDecoder().decode(TraktTokens.self, from: data)
    }

    // MARK: - Playback

    /// Everything Trakt has paused, across every app that reports to it.
    public func playback(clientId: String, accessToken: String) async -> [PlaybackItem] {
        guard let url = URL(string: Self.base + "/sync/playback?extended=full&limit=100") else {
            return []
        }

        var request = URLRequest(url: url)
        applyHeaders(to: &request, clientId: clientId, accessToken: accessToken)

        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status),
              let entries = try? JSONDecoder.trakt.decode([PlaybackEntry].self, from: data)
        else { return [] }

        return entries.compactMap(Self.mapPlayback)
    }

    /// Reports a pause, which is what creates a resume point on Trakt.
    ///
    /// `scrobble/pause` rather than `stop`: stop marks the item watched once past
    /// Trakt's completion threshold, which would wrongly clear the resume point
    /// every time the user exits mid-episode.
    public func reportProgress(
        videoId: String,
        metaId: String,
        type: MediaType,
        progress: Double,
        clientId: String,
        accessToken: String
    ) async {
        guard let url = URL(string: Self.base + "/scrobble/pause") else { return }

        var body: [String: Any] = ["progress": min(99, max(0, progress))]
        if type == .series, let (season, episode) = Self.episodeNumbers(from: videoId) {
            body["show"] = ["ids": ["imdb": metaId]]
            body["episode"] = ["season": season, "number": episode]
        } else {
            body["movie"] = ["ids": ["imdb": metaId]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, clientId: clientId, accessToken: accessToken)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await session.data(for: request)
    }

    // MARK: - Helpers

    /// `tt0903747:1:4` → (1, 4).
    static func episodeNumbers(from videoId: String) -> (season: Int, episode: Int)? {
        let parts = videoId.split(separator: ":")
        guard parts.count >= 3, let season = Int(parts[1]), let episode = Int(parts[2]) else {
            return nil
        }
        return (season, episode)
    }

    private static func mapPlayback(_ entry: PlaybackEntry) -> PlaybackItem? {
        let pausedAt = entry.pausedAt ?? .now

        if let episode = entry.episode, let show = entry.show, let imdb = show.ids.imdb {
            return PlaybackItem(
                videoId: "\(imdb):\(episode.season):\(episode.number)",
                metaId: imdb,
                type: .series,
                progress: entry.progress,
                runtime: episode.runtime.map { .seconds($0 * 60) },
                pausedAt: pausedAt,
                title: show.title
            )
        }

        if let movie = entry.movie, let imdb = movie.ids.imdb {
            return PlaybackItem(
                videoId: imdb,
                metaId: imdb,
                type: .movie,
                progress: entry.progress,
                runtime: movie.runtime.map { .seconds($0 * 60) },
                pausedAt: pausedAt,
                title: movie.title
            )
        }

        return nil
    }

    private func applyHeaders(to request: inout URLRequest, clientId: String, accessToken: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }

    private func post(_ path: String, body: [String: String], clientId: String) async throws -> Data {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw TraktError.http(status) }
        return data
    }
}

/// OAuth tokens. `Codable` so they round-trip through the Keychain as JSON.
public struct TraktTokens: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String
    public var createdAt: Double
    public var expiresIn: Double

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case createdAt = "created_at"
        case expiresIn = "expires_in"
    }

    /// Refreshed a day early, so a long-lived session never fails mid-use.
    public var needsRefresh: Bool {
        let expiry = Date(timeIntervalSince1970: createdAt + expiresIn)
        return Date() > expiry.addingTimeInterval(-86_400)
    }
}

// MARK: - Wire format

private struct DeviceCodeResponse: Decodable {
    var deviceCode: String
    var userCode: String
    var verificationUrl: String
    var expiresIn: Int
    var interval: Int

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUrl = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct PlaybackEntry: Decodable {
    var progress: Double
    var pausedAt: Date?
    var type: String?
    var movie: TraktMovie?
    var episode: TraktEpisode?
    var show: TraktShow?

    private enum CodingKeys: String, CodingKey {
        case progress, type, movie, episode, show
        case pausedAt = "paused_at"
    }
}

private struct TraktIds: Decodable {
    var imdb: String?
}

private struct TraktMovie: Decodable {
    var title: String?
    var runtime: Int?
    var ids: TraktIds
}

private struct TraktShow: Decodable {
    var title: String?
    var ids: TraktIds
}

private struct TraktEpisode: Decodable {
    var season: Int
    var number: Int
    var runtime: Int?
    var ids: TraktIds
}

extension JSONDecoder {
    /// Trakt timestamps are ISO-8601 with fractional seconds.
    static let trakt: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: raw) { return date }
            if let date = ISO8601DateFormatter.standard.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(raw)")
        }
        return decoder
    }()
}
