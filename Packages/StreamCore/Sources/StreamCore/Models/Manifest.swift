import Foundation

/// Content type. Kept open-ended: the protocol reserves `movie`/`series`/`channel`/`tv`
/// but addons freely invent their own (`anime`, `Podcasts`, `other`).
public struct MediaType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let movie = MediaType(rawValue: "movie")
    public static let series = MediaType(rawValue: "series")
    public static let channel = MediaType(rawValue: "channel")
    public static let tv = MediaType(rawValue: "tv")

    public var displayName: String {
        switch self {
        case .movie: "Movies"
        case .series: "Series"
        case .channel: "Channels"
        case .tv: "TV"
        default: rawValue.capitalized
        }
    }
}

/// Resources an addon can serve.
public struct ResourceKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let catalog = ResourceKind(rawValue: "catalog")
    public static let meta = ResourceKind(rawValue: "meta")
    public static let stream = ResourceKind(rawValue: "stream")
    public static let subtitles = ResourceKind(rawValue: "subtitles")
    public static let addonCatalog = ResourceKind(rawValue: "addon_catalog")
}

/// A `resources` entry, which the protocol allows in two shapes:
/// the short form `"stream"`, or the long form
/// `{ "name": "stream", "types": ["movie"], "idPrefixes": ["tt"] }`.
public struct ResourceDescriptor: Codable, Hashable, Sendable {
    public var name: ResourceKind
    public var types: [MediaType]?
    public var idPrefixes: [String]?

    private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

    public init(name: ResourceKind, types: [MediaType]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    public init(from decoder: any Decoder) throws {
        // Short form: a bare string such as "stream".
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            name = ResourceKind(rawValue: raw)
            types = nil
            idPrefixes = nil
            return
        }
        // Long form: an object with its own type and id-prefix filters.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(ResourceKind.self, forKey: .name)
        types = try container.decodeIfPresent([MediaType].self, forKey: .types)
        idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(types, forKey: .types)
        try container.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
    }
}

/// Declares one extra query parameter a catalog accepts (`search`, `skip`, `genre`).
public struct CatalogExtra: Codable, Hashable, Sendable {
    public var name: String
    public var isRequired: Bool
    public var options: [String]?
    @LenientInt public var optionsLimit: Int?

    private enum CodingKeys: String, CodingKey {
        case name, options, optionsLimit
        case isRequired = "isRequired"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isRequired = (try? container.decode(Bool.self, forKey: .isRequired)) ?? false
        options = try container.decodeIfPresent([String].self, forKey: .options)
        _optionsLimit = try container.decode(LenientInt.self, forKey: .optionsLimit)
    }
}

/// A catalog an addon publishes — becomes one shelf on the home screen.
public struct CatalogDefinition: Codable, Hashable, Sendable, Identifiable {
    public var type: MediaType
    public var id: String
    public var name: String?
    public var extra: [CatalogExtra]?
    public var extraSupported: [String]?
    public var extraRequired: [String]?
    public var genres: [String]?

    /// Stable identity for a catalog across addons.
    public var slug: String { "\(type.rawValue)/\(id)" }

    public var displayName: String { name ?? id.capitalized }

    /// Extras this catalog cannot be fetched without.
    public var requiredExtras: [String] {
        if let extraRequired, !extraRequired.isEmpty { return extraRequired }
        return extra?.filter(\.isRequired).map(\.name) ?? []
    }

    /// Catalogs that *require* a search term must not be fetched for the home screen —
    /// they return empty or error without one.
    public var requiresSearch: Bool {
        requiredExtras.contains("search")
    }

    /// Whether this catalog can be shown on a home screen unattended.
    ///
    /// Any required extra disqualifies it, not just `search`. Cinemeta's
    /// "Last videos" and "Calendar videos" require `lastVideosIds` and
    /// `calendarVideosIds` — ids that only exist for a signed-in Stremio library —
    /// so without this they appear as shelves of unrelated, duplicated content.
    public var isBrowsable: Bool {
        requiredExtras.isEmpty
    }

    public var supportsSearch: Bool {
        if let extraSupported, extraSupported.contains("search") { return true }
        if let extra, extra.contains(where: { $0.name == "search" }) { return true }
        return false
    }

    public var supportsSkip: Bool {
        if let extraSupported, extraSupported.contains("skip") { return true }
        if let extra, extra.contains(where: { $0.name == "skip" }) { return true }
        return false
    }

    public var availableGenres: [String] {
        if let genres, !genres.isEmpty { return genres }
        return extra?.first(where: { $0.name == "genre" })?.options ?? []
    }
}

/// The addon manifest — the client's routing table.
public struct Manifest: Codable, Hashable, Sendable {
    public var id: String
    public var version: String?
    public var name: String
    public var description: String?
    public var logo: String?
    public var background: String?
    public var types: [MediaType]
    public var catalogs: [CatalogDefinition]
    /// Directories of *other* addons this addon publishes, browsable via the
    /// `addon_catalog` resource. Cinemeta serves the Official and Community lists.
    public var addonCatalogs: [CatalogDefinition]
    public var resources: [ResourceDescriptor]
    public var idPrefixes: [String]?
    public var behaviorHints: ManifestBehaviorHints?

    private enum CodingKeys: String, CodingKey {
        case id, version, name, description, logo, background
        case types, catalogs, addonCatalogs, resources, idPrefixes, behaviorHints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        background = try container.decodeIfPresent(String.self, forKey: .background)
        types = (try? container.decode([MediaType].self, forKey: .types)) ?? []
        catalogs = (try? container.decode([CatalogDefinition].self, forKey: .catalogs)) ?? []
        addonCatalogs = (try? container.decode([CatalogDefinition].self, forKey: .addonCatalogs)) ?? []
        resources = (try? container.decode([ResourceDescriptor].self, forKey: .resources)) ?? []
        idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
        behaviorHints = try container.decodeIfPresent(ManifestBehaviorHints.self, forKey: .behaviorHints)
    }

    /// Whether this addon should be asked for `resource` given a content type and item id.
    /// This is the core routing decision — asking every addon for everything is the
    /// most common cause of slow stream resolution.
    public func supports(_ resource: ResourceKind, type: MediaType? = nil, id: String? = nil) -> Bool {
        guard let descriptor = resources.first(where: { $0.name == resource }) else { return false }

        if let type {
            // A long-form descriptor's own `types` wins; otherwise fall back to the manifest's.
            let allowed = descriptor.types ?? types
            guard allowed.isEmpty || allowed.contains(type) else { return false }
        }

        if let id {
            let prefixes = descriptor.idPrefixes ?? idPrefixes
            if let prefixes, !prefixes.isEmpty {
                guard prefixes.contains(where: { id.hasPrefix($0) }) else { return false }
            }
        }

        return true
    }
}

public struct ManifestBehaviorHints: Codable, Hashable, Sendable {
    public var configurable: Bool?
    public var configurationRequired: Bool?
    public var adult: Bool?
    public var p2p: Bool?
}
