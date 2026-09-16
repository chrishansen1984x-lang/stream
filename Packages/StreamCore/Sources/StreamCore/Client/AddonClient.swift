import Foundation
import os

/// Talks the addon protocol over HTTP.
///
/// Stateless by design — all addon state lives in `AddonRegistry`. This actor only
/// builds URLs, fetches, and decodes.
public actor AddonClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.stream.core", category: "AddonClient")

    /// Per-request ceiling. Addons are third-party and frequently slow or dead;
    /// one hung addon must never stall the whole stream list.
    public var requestTimeout: TimeInterval = 12

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .useProtocolCachePolicy
            // Addons send cacheMaxAge; honoring it keeps home-screen loads cheap.
            configuration.urlCache = URLCache(
                memoryCapacity: 16 * 1024 * 1024,
                diskCapacity: 128 * 1024 * 1024
            )
            self.session = URLSession(configuration: configuration)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: raw) { return date }
            if let date = ISO8601DateFormatter.standard.date(from: raw) { return date }
            // Some addons send bare "2008-01-21".
            if let date = DateFormatter.yearMonthDay.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(raw)")
        }
        self.decoder = decoder
    }

    // MARK: - Installation

    /// Fetches and validates a manifest, accepting the URL forms users actually paste:
    /// `https://host/manifest.json`, `https://host/`, or `stremio://host/manifest.json`.
    public func installAddon(from rawURL: String) async throws -> Addon {
        let normalized = Self.normalizeTransportURL(rawURL)
        guard let url = URL(string: normalized) else { throw AddonError.invalidURL(rawURL) }

        let manifest: Manifest = try await fetch(url)
        return Addon(manifest: manifest, transportURL: url)
    }

    static func normalizeTransportURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Stremio deep links use a custom scheme for the same HTTPS endpoint.
        if value.hasPrefix("stremio://") {
            value = "https://" + value.dropFirst("stremio://".count)
        }
        if !value.contains("://") {
            value = "https://" + value
        }
        if !value.hasSuffix("/manifest.json") {
            value = value.hasSuffix("/") ? value + "manifest.json" : value + "/manifest.json"
        }
        return value
    }

    // MARK: - Resources

    public func catalog(
        from addon: Addon,
        type: MediaType,
        id: String,
        extra: [CatalogQuery] = []
    ) async throws -> CatalogResponse {
        guard addon.supports(.catalog, type: type) else {
            throw AddonError.notSupported(resource: .catalog)
        }
        let url = resourceURL(addon: addon, resource: .catalog, type: type, id: id, extra: extra)
        return try await fetch(url)
    }

    public func meta(from addon: Addon, type: MediaType, id: String) async throws -> MetaDetail {
        guard addon.supports(.meta, type: type, id: id) else {
            throw AddonError.notSupported(resource: .meta)
        }
        let url = resourceURL(addon: addon, resource: .meta, type: type, id: id)
        let response: MetaResponse = try await fetch(url)
        return response.meta
    }

    public func streams(from addon: Addon, type: MediaType, id: String) async throws -> [Stream] {
        guard addon.supports(.stream, type: type, id: id) else {
            throw AddonError.notSupported(resource: .stream)
        }
        let url = resourceURL(addon: addon, resource: .stream, type: type, id: id)
        let response: StreamsResponse = try await fetch(url)

        // Tag provenance so the UI can group and the user can blame the right addon.
        return response.streams.map { stream in
            var tagged = stream
            tagged.addonId = addon.id
            tagged.addonName = addon.name
            return tagged
        }
    }

    /// Fetches a directory of other addons.
    public func addonCatalog(from addon: Addon, type: MediaType, id: String) async throws -> [AddonCatalogEntry] {
        guard addon.supports(.addonCatalog) else {
            throw AddonError.notSupported(resource: .addonCatalog)
        }
        let url = resourceURL(addon: addon, resource: .addonCatalog, type: type, id: id)
        let response: AddonCatalogResponse = try await fetch(url)
        return response.addons
    }

    public func subtitles(
        from addon: Addon,
        type: MediaType,
        id: String,
        extra: [CatalogQuery] = []
    ) async throws -> [Subtitle] {
        guard addon.supports(.subtitles, type: type, id: id) else {
            throw AddonError.notSupported(resource: .subtitles)
        }
        let url = resourceURL(addon: addon, resource: .subtitles, type: type, id: id, extra: extra)
        let response: SubtitlesResponse = try await fetch(url)
        return response.subtitles
    }

    // MARK: - URL building

    /// Builds `/{resource}/{type}/{id}[/{extra}].json`.
    ///
    /// The id must be path-escaped: series episode ids contain colons
    /// (`tt0903747:1:1`) and some addons use ids with slashes.
    nonisolated func resourceURL(
        addon: Addon,
        resource: ResourceKind,
        type: MediaType,
        id: String,
        extra: [CatalogQuery] = []
    ) -> URL {
        var components = URLComponents(url: addon.baseURL, resolvingAgainstBaseURL: false)!
        var path = components.percentEncodedPath
        if !path.hasSuffix("/") { path += "/" }
        path += [resource.rawValue, type.rawValue, id].map(Self.escape).joined(separator: "/")
        if !extra.isEmpty {
            path += "/" + extra.map { "\(Self.escape($0.key))=\(Self.escape($0.value))" }.joined(separator: "&")
        }
        components.percentEncodedPath = path + ".json"
        return components.url!
    }

    private static func escape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Transport

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.debug("Transport failure for \(url.absoluteString): \(error.localizedDescription)")
            throw AddonError.transportFailure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.badResponse(status: http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.debug("Decode failure for \(url.absoluteString): \(String(describing: error))")
            throw AddonError.decodingFailed(error.localizedDescription)
        }
    }
}

/// One `key=value` extra argument on a catalog or subtitles request.
public struct CatalogQuery: Hashable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public static func search(_ term: String) -> Self { .init(key: "search", value: term) }
    public static func skip(_ count: Int) -> Self { .init(key: "skip", value: String(count)) }
    public static func genre(_ name: String) -> Self { .init(key: "genre", value: name) }
}

// MARK: - Date helpers

// Foundation's formatters are documented as thread-safe for concurrent reads once
// configured, but are not marked Sendable. These are configured once here and never
// mutated, so the unchecked annotation is sound.
extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let standard = ISO8601DateFormatter()
}

extension DateFormatter {
    static let yearMonthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
