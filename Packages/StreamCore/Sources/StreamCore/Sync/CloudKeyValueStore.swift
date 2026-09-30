import Foundation
import Observation
import os

/// Cross-device storage backed by iCloud's key-value store.
///
/// Chosen over CloudKit deliberately: the whole dataset — installed addons, ranking
/// preferences, and a capped 200 watch records — is a few tens of kilobytes, far
/// inside the 1 MB KVS ceiling. That buys syncing on all three platforms with no
/// schema, no container setup, and no conflict machinery to maintain.
///
/// Every target declares the *same* `ubiquity-kvstore-identifier`, which is what
/// lets the iPhone, Mac, and Apple TV builds share one store despite having
/// different bundle identifiers.
@Observable
@MainActor
public final class CloudKeyValueStore {
    public static let shared = CloudKeyValueStore()

    private let store: NSUbiquitousKeyValueStore
    private let logger = Logger(subsystem: "com.stream.core", category: "CloudSync")
    /// Never removed — this is a process-lifetime singleton, and a `deinit` that
    /// touches main-actor state cannot be expressed safely under strict concurrency.
    private nonisolated(unsafe) static var observerToken: (any NSObjectProtocol)?
    /// Per-key handlers, so each store merges only its own data.
    private var handlers: [String: (Data?) -> Void] = [:]

    /// Registers interest in a key. The handler runs when another device changes it.
    public func observe(key: String, handler: @escaping (Data?) -> Void) {
        handlers[key] = handler
    }

    /// Account availability, not confirmation that a server upload completed.
    public var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil && store.synchronize()
    }

    init(store: NSUbiquitousKeyValueStore = .default, observeChanges: Bool = true) {
        self.store = store
        guard observeChanges else { return }
        // Retained for the process lifetime — this is a singleton, so there is no
        // teardown, and a `deinit` touching main-actor state cannot be expressed
        // safely under strict concurrency.
        Self.observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            // `Notification` is not Sendable, so the values are pulled out here —
            // `Int?` and `[String]` cross the actor boundary safely.
            let info = notification.userInfo
            let reason = info?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = info?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []

            MainActor.assumeIsolated {
                self?.handleExternalChange(reason: reason, keys: keys)
            }
        }
        store.synchronize()
    }

    public func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    /// Supplies an existing local setting without replacing a cloud value.
    public func seedIfMissing(_ data: Data?, forKey key: String) {
        guard let data, store.data(forKey: key) == nil else { return }
        set(data, forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) {
        // The system persists locally and forwards changes when iCloud becomes
        // available. Gating writes on account/network state loses offline edits.
        guard store.data(forKey: key) != data else { return }
        // KVS caps a single value at 1 MB. Silently exceeding it means the write is
        // dropped, so it is checked rather than discovered as missing sync later.
        if let data, data.count > 900_000 {
            logger.error("Refusing to sync \(key): \(data.count) bytes exceeds the KVS limit")
            return
        }
        store.set(data, forKey: key)
        store.synchronize()
    }

    private func handleExternalChange(reason: Int?, keys: [String]) {
        // A quota violation means our own writes are being rejected; log it rather
        // than leaving sync silently broken.
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            logger.error("iCloud key-value quota exceeded; sync is paused")
            return
        }

        for key in keys {
            handlers[key]?(store.data(forKey: key))
        }
    }
}
