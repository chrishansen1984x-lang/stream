import Foundation
import Observation
import os

/// The installed-addon list, its ordering, and resource routing.
///
/// Order is meaningful: it decides shelf order on the home screen and the priority
/// in which stream results are merged.
///
/// Persistence deliberately uses `UserDefaults` and stays small. tvOS caps app-local
/// persistent storage at roughly 500 KB, so this must never grow unbounded — see
/// `AUDIT.md` §4.3. Manifests are a few KB each; a sane addon count fits comfortably.
@Observable
@MainActor
public final class AddonRegistry {
    public private(set) var addons: [Addon] = []

    /// Fired after any local change — install, removal, reorder, enable/disable.
    ///
    /// Without this, addon changes were only pushed to the sync endpoint when
    /// something *else* triggered a push, so installing an addon on one device
    /// could sit unsynced indefinitely.
    public var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let storageKey: String
    private let cloud: CloudKeyValueStore?
    private let logger = Logger(subsystem: "com.stream.core", category: "AddonRegistry")

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "installedAddons",
        cloud: CloudKeyValueStore? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.cloud = cloud
        load()

        if let cloud {
            adopt(remote: cloud.data(forKey: storageKey))
            cloud.observe(key: storageKey) { [weak self] data in
                self?.adopt(remote: data)
            }
        }
    }

    /// Replaces the local list with the remote one.
    ///
    /// Whole-list rather than per-addon, unlike watch progress: order is meaningful
    /// here (it drives shelf order and lookup priority), and merging two orderings
    /// has no correct answer. Last writer wins is the honest behaviour.
    /// Snapshot for pushing to a remote backend.
    public func exportData() -> Data? {
        try? JSONEncoder().encode(addons)
    }

    /// Adopts a snapshot from any remote backend — iCloud or the sync Worker.
    public func adoptRemote(_ data: Data?) {
        adopt(remote: data)
    }

    private func adopt(remote data: Data?) {
        guard let data,
              let incoming = try? JSONDecoder().decode([Addon].self, from: data),
              incoming != addons
        else { return }

        addons = incoming
        persistLocally()
    }

    // MARK: - Mutation

    public func install(_ addon: Addon) {
        if let index = addons.firstIndex(where: { $0.id == addon.id }) {
            // Re-installing preserves position but refreshes the manifest and config.
            var updated = addon
            updated.isEnabled = addons[index].isEnabled
            addons[index] = updated
        } else {
            addons.append(addon)
        }
        save()
    }

    public func remove(_ addon: Addon) {
        addons.removeAll { $0.id == addon.id }
        save()
    }

    public func setEnabled(_ isEnabled: Bool, for addon: Addon) {
        guard let index = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        addons[index].isEnabled = isEnabled
        save()
    }

    /// Reorders addons. Implemented here rather than using SwiftUI's
    /// `move(fromOffsets:toOffset:)` so StreamCore stays UI-framework independent.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { addons[$0] }
        // Count removals before the insertion point to correct the target index.
        let removedBefore = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) {
            addons.remove(at: index)
        }
        addons.insert(contentsOf: moving, at: destination - removedBefore)
        save()
    }

    public func contains(_ addonId: String) -> Bool {
        addons.contains { $0.id == addonId }
    }

    // MARK: - Routing

    public var enabledAddons: [Addon] { addons.filter(\.isEnabled) }

    public func addons(providing resource: ResourceKind, type: MediaType? = nil, id: String? = nil) -> [Addon] {
        addons.filter { $0.supports(resource, type: type, id: id) }
    }

    /// Every catalog across installed addons, in addon order, excluding those that
    /// require a search term (they have nothing to show on a home screen).
    public var homeCatalogs: [CatalogSource] {
        enabledAddons.flatMap { addon in
            addon.manifest.catalogs
                .filter(\.isBrowsable)
                .map { CatalogSource(addon: addon, catalog: $0) }
        }
    }

    /// Every addon directory published by installed addons, in addon order.
    public var addonDirectories: [CatalogSource] {
        enabledAddons.flatMap { addon in
            addon.manifest.addonCatalogs.map { CatalogSource(addon: addon, catalog: $0) }
        }
    }

    public var searchableCatalogs: [CatalogSource] {
        enabledAddons.flatMap { addon in
            addon.manifest.catalogs
                .filter(\.supportsSearch)
                .map { CatalogSource(addon: addon, catalog: $0) }
        }
    }

    // MARK: - Persistence

    private func save() {
        persistLocally()
        if let data = try? JSONEncoder().encode(addons) {
            cloud?.set(data, forKey: storageKey)
        }
        onChange?()
    }

    private func persistLocally() {
        do {
            defaults.set(try JSONEncoder().encode(addons), forKey: storageKey)
        } catch {
            logger.error("Failed to persist addons: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            addons = try JSONDecoder().decode([Addon].self, from: data)
        } catch {
            logger.error("Failed to load addons, starting empty: \(error.localizedDescription)")
            addons = []
        }
    }
}

/// A catalog paired with the addon that serves it.
public struct CatalogSource: Hashable, Sendable, Identifiable {
    public var addon: Addon
    public var catalog: CatalogDefinition

    public var id: String { "\(addon.id)|\(catalog.slug)" }

    /// Shelf title. Addons name catalogs generically ("Popular"), so the addon name
    /// disambiguates when several are installed.
    public var shelfTitle: String {
        "\(catalog.displayName) \(catalog.type.displayName)"
    }
}
