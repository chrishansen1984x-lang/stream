import Foundation

/// A playable source returned by a stream addon.
///
/// Exactly one of `url` / `ytId` / `infoHash` / `externalUrl` identifies the media.
/// Everything a user sees about quality lives in unstructured `name`/`title` text,
/// which is why `ReleaseParser` exists.
public struct Stream: Codable, Hashable, Sendable, Identifiable {
    public var url: String?
    public var ytId: String?
    public var infoHash: String?
    @LenientInt public var fileIdx: Int?
    public var externalUrl: String?

    public var name: String?
    public var title: String?
    public var description: String?
    public var behaviorHints: StreamBehaviorHints?
    public var subtitles: [Subtitle]?

    /// Set by the client, not the addon — which addon produced this stream.
    public var addonId: String?
    public var addonName: String?

    private enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, fileIdx, externalUrl
        case name, title, description, behaviorHints, subtitles
    }

    public var id: String {
        [url, ytId, infoHash, externalUrl, name, title]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    /// The descriptive line for a source.
    ///
    /// `behaviorHints.filename` comes first because it is the one structured field
    /// that reliably holds the release name. Aggregators like AIOStreams omit `title`
    /// entirely and put a decorated multi-line summary in `description`, which reads
    /// badly as a row label.
    public var displayTitle: String {
        if let filename = behaviorHints?.filename, !filename.isEmpty {
            return filename
        }
        if let title, !title.isEmpty {
            return title
        }
        if let description, !description.isEmpty {
            // Decorated summaries are multi-line; the first line is the useful part.
            return description
                .split(separator: "\n")
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) }
                ?? description
        }
        return name ?? "Unknown source"
    }

    /// Short source label — the streaming service ("Disney Plus") or a quality tag.
    ///
    /// Addons put this in `name`, and several prefix it with their own name on a
    /// first line ("Torrentio\n1080p"). That prefix is dropped when it just repeats
    /// the addon name, which the UI already shows.
    public func sourceLabel(addonName: String?) -> String? {
        guard let name else { return nil }
        let firstLine = name
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)

        guard let firstLine, !firstLine.isEmpty else { return nil }

        if let addonName, firstLine.caseInsensitiveCompare(addonName) == .orderedSame {
            return nil
        }

        // Aggregators reuse `name` for the full release string plus a tag list
        // ("<filename>.mkv, TrueHD,4K,HDR,DV,..."). That is content for the title
        // line, not a short label, and it is already shown there.
        if let filename = behaviorHints?.filename, firstLine.hasPrefix(filename) {
            return nil
        }

        // Backstop for addons with no filename hint: a real label is short.
        guard firstLine.count <= 24 else { return nil }

        return firstLine
    }

    /// Direct HTTP(S) playback is the only kind an App Store build resolves itself.
    public var isDirectlyPlayable: Bool {
        guard let url, let parsed = URL(string: url) else { return false }
        return parsed.scheme == "https" || parsed.scheme == "http"
    }

    public var isTorrent: Bool { infoHash != nil }

    public var playbackURL: URL? {
        if let url, let parsed = URL(string: url) { return parsed }
        if let externalUrl, let parsed = URL(string: externalUrl) { return parsed }
        return nil
    }
}

public struct StreamBehaviorHints: Codable, Hashable, Sendable {
    public var notWebReady: Bool?
    public var bingeGroup: String?
    public var countryWhitelist: [String]?
    @LenientInt public var videoSize: Int?
    /// Size of the whole torrent folder, when the source is one the debrid
    /// provider already holds.
    ///
    /// **Not the size of the file.** A healthy Alien: Earth episode measured at
    /// 15% of its folder, so comparing served bytes against this would call a
    /// working source a placeholder — `videoSize` is the only size that means
    /// "this file". What it is good for is that its *presence* means the folder
    /// is in the library, which is the cached signal AIOStreams never sets
    /// `cached` for.
    @LenientInt public var folderSize: Int?
    public var filename: String?
    /// Debrid aggregators signal instant availability structurally here, rather than
    /// with the ⚡ marker other addons embed in the title text.
    public var cached: Bool?

    private enum CodingKeys: String, CodingKey {
        case notWebReady, bingeGroup, countryWhitelist, videoSize, folderSize, filename, cached
    }

    /// Container extension from the release filename.
    ///
    /// Read from `filename` rather than the URL: debrid playback links are opaque
    /// tokens with no extension, so the URL says nothing about the container.
    public var containerExtension: String? {
        guard let filename, let dot = filename.lastIndex(of: ".") else { return nil }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        return ext.isEmpty ? nil : ext
    }
}

public struct Subtitle: Codable, Hashable, Sendable, Identifiable {
    public var id: String?
    public var url: String
    public var lang: String

    public var resolvedId: String { id ?? url }
}

// MARK: - Response envelopes

public struct CatalogResponse: Codable, Sendable {
    public var metas: [MetaPreview]
    public var hasMore: Bool?
    @LenientInt public var cacheMaxAge: Int?

    private enum CodingKeys: String, CodingKey { case metas, hasMore, cacheMaxAge }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Skip individual malformed items rather than losing the page.
        metas = try container.decodeLossy([MetaPreview].self, forKey: .metas)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
        _cacheMaxAge = try container.decode(LenientInt.self, forKey: .cacheMaxAge)
    }
}

public struct MetaResponse: Codable, Sendable {
    public var meta: MetaDetail
}

public struct StreamsResponse: Codable, Sendable {
    public var streams: [Stream]

    private enum CodingKeys: String, CodingKey { case streams }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = try container.decodeLossy([Stream].self, forKey: .streams)
    }
}

public struct SubtitlesResponse: Codable, Sendable {
    public var subtitles: [Subtitle]

    private enum CodingKeys: String, CodingKey { case subtitles }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = try container.decodeLossy([Subtitle].self, forKey: .subtitles)
    }
}

// MARK: - Lossy array decoding

/// Wrapper that turns a failed element decode into `nil` instead of aborting the array.
private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: any Decoder) throws {
        value = try? Element(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array, dropping elements that fail to decode.
    ///
    /// One malformed item in a 50-item catalog should cost one poster, not the shelf.
    func decodeLossy<Element: Decodable>(
        _ type: [Element].Type,
        forKey key: Key
    ) throws -> [Element] {
        guard let wrapped = try decodeIfPresent([Lossy<Element>].self, forKey: key) else { return [] }
        return wrapped.compactMap(\.value)
    }
}
