import Foundation
import CryptoKit
import Observation
import os

/// Syncs app state through a personal HTTP endpoint.
///
/// Fills the gap the other two backends leave: iCloud key-value storage requires a
/// paid Apple Developer membership, and Trakt understands watch progress but has no
/// concept of installed addons or ranking preferences. This carries all three, so a
/// fresh install needs no manual reconfiguration.
@Observable
@MainActor
public final class RemoteSync {

    public enum State: Equatable {
        case disabled
        case idle
        case syncing
        case failed(String)
    }

    public private(set) var state: State = .disabled
    public private(set) var lastSync: Date?

    public var endpoint: String {
        didSet {
            defaults.set(endpoint, forKey: Self.endpointKey)
            if endpoint != oldValue { configurationChanged() }
        }
    }

    /// Bearer token for the endpoint. Keychain rather than defaults — it grants
    /// full read/write on the user's synced state.
    public var token: String {
        didSet {
            persistToken(token)
            if token != oldValue { configurationChanged() }
        }
    }

    public var isConfigured: Bool {
        !endpoint.isEmpty && !token.isEmpty && URL(string: endpoint) != nil
    }

    /// Disconnects on purpose.
    ///
    /// `Keychain.set` refuses an empty value, so clearing the field in Settings
    /// only emptied this session's copy: the next launch read the old token back
    /// and sync quietly resumed. The endpoint is kept — it is not a secret, and
    /// re-pasting the token is the whole of reconnecting.
    public func forgetToken() {
        token = ""
        configurationChanged()
    }

    private let session: URLSession
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.stream.core", category: "RemoteSync")
    private var pushTask: Task<Void, Never>?
    private let persistToken: (String) -> Void
    private let debounce: Duration
    private var generation = UUID()
    private var activePull: UUID?

    private func configurationChanged() {
        generation = UUID()
        activePull = nil
        pushTask?.cancel()
        lastSyncedAddons = nil
        lastSyncedPreferences = nil
        lastSync = nil
        state = isConfigured ? .idle : .disabled
    }

    /// What the endpoint last agreed with us on, for the two fields it replaces
    /// wholesale.
    ///
    /// Watch progress and the watchlist merge by union, so re-sending them is
    /// always safe. Addons and preferences are last-writer-wins on the Worker,
    /// and every push used to carry both — so a device recording fifteen seconds
    /// of playback uploaded its stale addon list over one another device had just
    /// changed. These two go up only when they differ from what was last synced.
    // Persist only fingerprints, not another copy of credential-bearing addon URLs.
    private var lastSyncedAddons: Data? {
        didSet { defaults.set(lastSyncedAddons, forKey: Self.addonBaselineKey) }
    }
    private var lastSyncedPreferences: Data? {
        didSet { defaults.set(lastSyncedPreferences, forKey: Self.preferenceBaselineKey) }
    }
    private static let addonBaselineKey = "remoteSyncAddonBaseline.v1"
    private static let preferenceBaselineKey = "remoteSyncPreferenceBaseline.v1"

    private static func fingerprint(_ data: Data?) -> Data? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return Data(SHA256.hash(data: canonical))
    }

    private static func encoded(_ preferences: RankingPreferences) -> Data? {
        guard let data = try? JSONEncoder().encode(preferences),
              var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // Set<String> encodes as an array whose iteration order varies by process.
        value["requiredLanguages"] = preferences.requiredLanguages.sorted()
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static let endpointKey = "remoteSyncEndpoint"
    private static let tokenKey = "remoteSyncToken"

    /// Payload keys, matching the Worker's top-level fields.
    private enum Field {
        static let addons = "addons"
        static let watch = "watch"
        static let watchlist = "watchlist"
        static let preferences = "preferences"
    }

    public convenience init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.init(session: session, defaults: defaults, initialToken: Keychain.get(Self.tokenKey) ?? "") {
            if $0.isEmpty { Keychain.clear(Self.tokenKey) }
            else { Keychain.set($0, for: Self.tokenKey) }
        }
    }

    // Injectable credentials keep regression tests out of the user's Keychain.
    init(session: URLSession, defaults: UserDefaults, initialToken: String,
         debounce: Duration = .seconds(3), persistToken: @escaping (String) -> Void) {
        self.session = session
        self.defaults = defaults
        self.persistToken = persistToken
        self.debounce = debounce
        self.endpoint = defaults.string(forKey: Self.endpointKey) ?? ""
        self.token = initialToken
        self.lastSyncedAddons = defaults.data(forKey: Self.addonBaselineKey)
        self.lastSyncedPreferences = defaults.data(forKey: Self.preferenceBaselineKey)
        self.state = isConfigured ? .idle : .disabled
    }

    // MARK: - Pull

    /// Fetches remote state and merges it locally.
    ///
    /// Each store applies its own reconciliation: watch records merge per-video by
    /// timestamp, addons replace wholesale because their order is meaningful.
    /// Returns preferences rather than taking them `inout`: an actor-isolated
    /// property cannot cross an async boundary by reference.
    @discardableResult
    public func pull(
        registry: AddonRegistry,
        watchState: WatchStateStore,
        watchlist: WatchlistStore,
        currentPreferences: () -> RankingPreferences
    ) async -> RankingPreferences? {
        guard isConfigured, let url = stateURL, activePull == nil else { return nil }
        let requestGeneration = generation
        let pullID = UUID()
        activePull = pullID
        defer { if activePull == pullID { activePull = nil } }
        let startingAddons = Self.fingerprint(registry.exportData())
        let startingPreferences = Self.fingerprint(Self.encoded(currentPreferences()))
        // A successful push during this request must not turn a previously dirty
        // local field into a candidate for replacement by this older GET response.
        let addonsWereDirty = lastSyncedAddons.map { $0 != startingAddons } ?? false
        let preferencesWereDirty = lastSyncedPreferences.map { $0 != startingPreferences } ?? false
        state = .syncing

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard generation == requestGeneration else { return nil }
            if Task.isCancelled { state = .idle; return nil }
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                throw URLError(.badServerResponse)
            }
            guard status != 401 else {
                state = .failed("Sync token rejected.")
                return nil
            }
            guard (200..<300).contains(status) else {
                state = .failed("Sync endpoint returned HTTP \(status).")
                return nil
            }

            let payload = try JSONDecoder().decode([String: RawJSON].self, from: data)
            // The caller schedules a fresh snapshot after applying this pull.
            // Do not let a queued pre-pull snapshot overwrite adopted values.
            pushTask?.cancel()

            if let addons = payload[Field.addons]?.data,
               (try? JSONDecoder().decode([Addon].self, from: addons)) != nil,
               !addonsWereDirty,
               Self.fingerprint(registry.exportData()) == startingAddons {
                registry.adoptRemote(addons)
                lastSyncedAddons = Self.fingerprint(registry.exportData())
            }
            // Missing or invalid fields are not acknowledgements. In particular,
            // an empty endpoint must still receive the first local addon snapshot.
            if let watch = payload[Field.watch]?.data {
                watchState.mergeRemote(watch)
            }
            if let saved = payload[Field.watchlist]?.data {
                watchlist.mergeRemote(saved)
            }
            var incomingPreferences = payload[Field.preferences]?.data.flatMap {
                try? JSONDecoder().decode(RankingPreferences.self, from: $0)
            }
            if preferencesWereDirty || Self.fingerprint(Self.encoded(currentPreferences())) != startingPreferences {
                incomingPreferences = nil
            }
            if let incomingPreferences {
                lastSyncedPreferences = Self.fingerprint(Self.encoded(incomingPreferences))
            }

            lastSync = .now
            state = .idle
            return incomingPreferences
        } catch {
            guard generation == requestGeneration else { return nil }
            if Task.isCancelled { state = .idle; return nil }
            logger.error("Remote pull failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Push

    /// Uploads current state, coalescing rapid changes.
    ///
    /// Debounced because progress is recorded every 15 seconds during playback and
    /// each write would otherwise be its own request.
    public func schedulePush(
        registry: AddonRegistry,
        watchState: WatchStateStore,
        watchlist: WatchlistStore,
        preferences: RankingPreferences
    ) {
        guard isConfigured else { return }

        let currentAddons = registry.exportData()
        let currentPreferences = Self.encoded(preferences)
        // Only what changed here since the endpoint last saw it. See
        // `lastSyncedAddons`.
        let addons = Self.fingerprint(currentAddons) == lastSyncedAddons ? nil : currentAddons
        let preferenceData = Self.fingerprint(currentPreferences) == lastSyncedPreferences ? nil : currentPreferences
        let watch = watchState.exportData()
        let saved = watchlist.exportData()

        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await push(addons: addons, watch: watch, watchlist: saved, preferences: preferenceData)
        }
    }

    private func push(addons: Data?, watch: Data?, watchlist: Data?, preferences: Data?) async {
        guard isConfigured, let url = stateURL else { return }
        let requestGeneration = generation

        var body: [String: Any] = [:]
        // Preserve the endpoint's embedded JSON-string wire format.
        if let addons, let text = String(data: addons, encoding: .utf8) { body[Field.addons] = text }
        if let watch, let text = String(data: watch, encoding: .utf8) { body[Field.watch] = text }
        if let watchlist, let text = String(data: watchlist, encoding: .utf8) {
            body[Field.watchlist] = text
        }
        if let preferences, let text = String(data: preferences, encoding: .utf8) {
            body[Field.preferences] = text
        }
        guard !body.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await session.data(for: request)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            // The status used to be discarded, so a rejected token or a broken
            // Worker read as "synced" in Settings.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status != 401 else {
                state = .failed("Sync token rejected.")
                return
            }
            guard (200..<300).contains(status) else {
                state = .failed("Sync endpoint returned HTTP \(status).")
                return
            }
            // Agreed with the endpoint, so the next push can skip them unless
            // they change again.
            if let addons { lastSyncedAddons = Self.fingerprint(addons) }
            if let preferences { lastSyncedPreferences = Self.fingerprint(preferences) }
            lastSync = .now
            state = .idle
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            logger.error("Remote push failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    private var stateURL: URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        if !components.path.hasSuffix("/state") {
            components.path = components.path.hasSuffix("/")
                ? components.path + "state"
                : components.path + "/state"
        }
        return components.url
    }
}

/// Holds a field whose value is itself JSON encoded as a string.
///
/// The Worker merges histories and replaces explicitly supplied configuration fields.
private struct RawJSON: Decodable {
    let data: Data?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            data = text.data(using: .utf8)
        } else {
            data = nil
        }
    }
}
