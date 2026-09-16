import Foundation

/// An installed addon: its manifest plus the transport URL it was installed from.
///
/// The transport URL matters — many addons carry user configuration in a path
/// segment (`https://host/{configBlob}/manifest.json`), so it cannot be
/// reconstructed from the manifest `id` alone.
public struct Addon: Codable, Hashable, Sendable, Identifiable {
    public var manifest: Manifest
    public var transportURL: URL
    public var isEnabled: Bool
    public var installedAt: Date

    public var id: String { manifest.id }
    public var name: String { manifest.name }

    public init(manifest: Manifest, transportURL: URL, isEnabled: Bool = true, installedAt: Date = .now) {
        self.manifest = manifest
        self.transportURL = transportURL
        self.isEnabled = isEnabled
        self.installedAt = installedAt
    }

    /// Base URL for resource requests — the transport URL minus `/manifest.json`,
    /// preserving any configuration path segment.
    public var baseURL: URL {
        transportURL.deletingLastPathComponent()
    }

    public func supports(_ resource: ResourceKind, type: MediaType? = nil, id: String? = nil) -> Bool {
        isEnabled && manifest.supports(resource, type: type, id: id)
    }
}

/// Errors surfaced to the UI. Addon failures are routine (addons go offline
/// constantly), so these must be non-fatal and individually recoverable.
public enum AddonError: LocalizedError, Sendable {
    case invalidURL(String)
    case badResponse(status: Int)
    case decodingFailed(String)
    case notSupported(resource: ResourceKind)
    case transportFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "Not a valid addon URL: \(url)"
        case .badResponse(let status):
            "Addon returned HTTP \(status)"
        case .decodingFailed(let detail):
            "Could not read the addon's response: \(detail)"
        case .notSupported(let resource):
            "This addon does not provide \(resource.rawValue)"
        case .transportFailure(let detail):
            "Could not reach the addon: \(detail)"
        }
    }
}
