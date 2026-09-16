import Foundation

/// One addon listed in an `addon_catalog` directory.
///
/// The directory carries each addon's full manifest, so capabilities can be shown
/// before installing — no extra round trip per entry.
public struct AddonCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public var transportUrl: String
    public var transportName: String?
    public var manifest: Manifest
    public var flags: AddonFlags?

    public var id: String { transportUrl }

    public var name: String { manifest.name }

    /// What the addon provides, minus `addon_catalog` — a directory listing is not
    /// a capability a user is choosing between.
    public var capabilities: [String] {
        manifest.resources
            .map(\.name.rawValue)
            .filter { $0 != ResourceKind.addonCatalog.rawValue }
    }

    /// Addons needing setup hand back a configuration page rather than working
    /// immediately, so the UI has to say so before install.
    public var requiresConfiguration: Bool {
        manifest.behaviorHints?.configurationRequired == true
    }

    public var isAdult: Bool {
        manifest.behaviorHints?.adult == true || flags?.adult == true
    }
}

public struct AddonFlags: Codable, Hashable, Sendable {
    public var official: Bool?
    public var protected: Bool?
    public var adult: Bool?
}

public struct AddonCatalogResponse: Codable, Sendable {
    public var addons: [AddonCatalogEntry]

    private enum CodingKeys: String, CodingKey { case addons }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Community directories run to ~100 entries written by as many authors;
        // one malformed manifest must not empty the whole list.
        addons = try container.decodeLossy([AddonCatalogEntry].self, forKey: .addons)
    }
}
