import Foundation
import Observation
import os

/// Owns Trakt credentials, authorization state, and reconciliation with local
/// watch progress.
@Observable
@MainActor
public final class TraktSync {

    public enum State: Equatable {
        case disconnected
        case awaitingAuthorization(userCode: String, url: String)
        case connected
        case failed(String)
    }

    public private(set) var state: State = .disconnected
    public private(set) var lastSync: Date?

    /// App credentials from the user's own Trakt application. Not secret in the
    /// usual sense — Trakt expects each app to register its own — but stored with
    /// the tokens rather than compiled in, so they never land in source control.
    public var clientId: String {
        didSet { defaults.set(clientId, forKey: Self.clientIdKey) }
    }
    public var clientSecret: String {
        didSet { Keychain.set(clientSecret, for: Self.clientSecretKey) }
    }

    public var isConfigured: Bool { !clientId.isEmpty && !clientSecret.isEmpty }
    public var isConnected: Bool { tokens != nil }

    private var tokens: TraktTokens? {
        didSet { persistTokens() }
    }

    private let client: TraktClient
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.stream.core", category: "TraktSync")
    private var authTask: Task<Void, Never>?

    private static let clientIdKey = "traktClientId"
    private static let clientSecretKey = "traktClientSecret"
    private static let tokensKey = "traktTokens"

    public init(client: TraktClient = TraktClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.clientId = defaults.string(forKey: Self.clientIdKey) ?? ""
        self.clientSecret = Keychain.get(Self.clientSecretKey) ?? ""

        if let raw = Keychain.get(Self.tokensKey),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TraktTokens.self, from: data) {
            self.tokens = decoded
            self.state = .connected
        }
    }

    // MARK: - Authorization

    /// Runs the device flow end to end: shows a code, polls until approved.
    public func connect() {
        guard isConfigured else {
            state = .failed("Add your Trakt client ID and secret first.")
            return
        }

        authTask?.cancel()
        authTask = Task {
            do {
                let code = try await client.requestDeviceCode(clientId: clientId)
                state = .awaitingAuthorization(userCode: code.userCode, url: code.verificationURL)

                let issued = try await client.pollForToken(
                    deviceCode: code,
                    clientId: clientId,
                    clientSecret: clientSecret
                )
                tokens = issued
                state = .connected
            } catch is CancellationError {
                state = .disconnected
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    public func cancelConnect() {
        authTask?.cancel()
        authTask = nil
        state = isConnected ? .connected : .disconnected
    }

    public func disconnect() {
        authTask?.cancel()
        tokens = nil
        state = .disconnected
    }

    /// Forgets the app credentials as well as the tokens.
    ///
    /// `Keychain.set` refuses an empty value, so clearing the secret field only
    /// emptied this session's copy and the next launch read it back.
    public func forgetCredentials() {
        disconnect()
        Keychain.clear(Self.clientSecretKey)
        clientSecret = ""
        clientId = ""
    }

    // MARK: - Sync

    /// Pulls Trakt's resume points into the local store.
    ///
    /// Trakt reports progress as a percentage plus a runtime in whole minutes, so
    /// the reconstructed position is approximate — good to within about half a
    /// minute. Local records win when they are newer, which keeps a just-watched
    /// episode from being rewound by a stale remote entry.
    public func pull(into store: WatchStateStore) async {
        guard let token = await validAccessToken() else { return }

        let items = await client.playback(clientId: clientId, accessToken: token)
        for item in items {
            guard let runtime = item.runtime, runtime > .zero else { continue }

            let position = Duration.seconds(runtime.secondsValue * item.progress / 100)
            guard position >= WatchProgress.minimumMeaningfulPosition else { continue }

            if let existing = store.progress(for: item.videoId), existing.updatedAt >= item.pausedAt {
                continue
            }

            store.record(
                videoId: item.videoId,
                metaId: item.metaId,
                type: item.type,
                position: position,
                duration: runtime,
                metaName: item.title,
                updatedAt: item.pausedAt
            )
        }

        lastSync = .now
    }

    /// Reports one local resume point to Trakt.
    public func push(_ progress: WatchProgress) async {
        guard let token = await validAccessToken(),
              let duration = progress.duration, duration > .zero
        else { return }

        await client.reportProgress(
            videoId: progress.videoId,
            metaId: progress.metaId,
            type: progress.type,
            progress: progress.fractionComplete * 100,
            clientId: clientId,
            accessToken: token
        )
    }

    /// Refreshes shortly before expiry rather than after a failure, so a long
    /// session never has to recover from a 401 mid-playback.
    private func validAccessToken() async -> String? {
        guard var current = tokens, isConfigured else { return nil }

        if current.needsRefresh {
            do {
                current = try await client.refresh(
                    refreshToken: current.refreshToken,
                    clientId: clientId,
                    clientSecret: clientSecret
                )
                tokens = current
            } catch TraktClient.TraktError.http(let status) where (400..<500).contains(status) {
                // Trakt itself refused the refresh token: it is dead, and the
                // user must re-authorize.
                logger.error("Trakt refresh refused with HTTP \(status)")
                tokens = nil
                state = .failed("Trakt sign-in expired. Connect again.")
                return nil
            } catch {
                // Offline, or Trakt is down. Any failure here used to be treated
                // as a dead token, which signed a television out for having no
                // network at the moment the token crossed its refresh line.
                // The tokens are kept and this sync is skipped; the refresh is
                // retried on the next call, with a day of slack before expiry.
                logger.error("Trakt refresh could not be made: \(error.localizedDescription)")
                return nil
            }
        }

        return current.accessToken
    }

    private func persistTokens() {
        guard let tokens,
              let data = try? JSONEncoder().encode(tokens),
              let raw = String(data: data, encoding: .utf8)
        else {
            Keychain.remove(Self.tokensKey)
            return
        }
        Keychain.set(raw, for: Self.tokensKey)
    }
}
