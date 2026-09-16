import Foundation
import os

/// Reports finished playback to Screen.
///
/// Screen keys everything on the same protocol video id Stream already records —
/// `tt0903747` for a film, `tt0903747:1:5` for an episode — so nothing needs
/// translating. Call `record` when a `WatchProgress` crosses its completion
/// threshold; Screen resolves the id, adds the title to the library if it isn't
/// there, and files the watch against the run the viewer is actually in.
///
/// Posting the same id twice is a no-op on Screen's side, so a retry after a
/// dropped connection can't double-count a rewatch.
public actor ScreenScrobbler {

    public struct Configuration: Sendable {
        /// The user-configured HTTPS endpoint for watch events.
        public var endpoint: URL
        /// A device token from Screen → Your year → Connected apps. Starts `scr_`.
        public var token: String

        public init(endpoint: URL, token: String) {
            self.endpoint = endpoint
            self.token = token
        }
    }

    private struct Event: Codable, Sendable, Equatable {
        let id: String
        let watchedAt: String
        let title: String?
        /// Omitted means finished. Below Screen's threshold a film is opened as
        /// in-progress instead, so it appears there while you are partway through.
        let progress: Double?
    }

    private var configuration: Configuration
    private let session: URLSession
    private let defaults: UserDefaults
    /// Watches that haven't reached Screen yet.
    private var pending: [Event]
    private var isFlushing = false

    private static let pendingKey = "screen.scrobbler.pending"
    /// One post carries at most this many; Screen refuses more.
    private static let batchLimit = 100
    /// A TV can be offline for days. Beyond this the oldest are dropped.
    private static let queueLimit = 500

    /// Why the last attempt was refused outright, for Settings. Nil when the last
    /// send succeeded or simply could not be made.
    public private(set) var lastFailure: String?

    /// When Screen last accepted something, and what it was.
    ///
    /// "Waiting to send: 0" answers two completely different questions with the
    /// same number — everything sent, and nothing was ever handed over. For two
    /// days that ambiguity made it impossible to tell whether a missing watch was
    /// Stream failing to report or Screen failing to display. This says which.
    public private(set) var lastSent: Date?
    public private(set) var lastSentTitle: String?

    public init(
        configuration: Configuration,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.configuration = configuration
        self.session = session
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pendingKey),
           let stored = try? JSONDecoder().decode([Event].self, from: data) {
            self.pending = stored
        } else {
            self.pending = []
        }
    }

    /// Points at a different account, or a newly pasted token.
    ///
    /// The queue is deliberately kept: a watch recorded while the token was wrong
    /// is still a watch, and Screen dedupes by id so re-sending costs nothing.
    public func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Whether there is anything to send with. Checked before flushing so an
    /// unconfigured install does not post empty Bearer headers at the endpoint.
    public var isConfigured: Bool {
        !configuration.token.isEmpty
    }

    /// How many watches are waiting. Surfaced in Settings so "did it send?" has an
    /// answer that is not a guess.
    public var queueDepth: Int { pending.count }

    /// Records one finished item, flushing anything queued from earlier.
    ///
    /// Never throws: a tracker failing to record must not surface as a playback
    /// error. Anything that doesn't get through is kept and retried.
    public func record(
        videoId: String,
        title: String? = nil,
        watchedAt: Date = Date(),
        progress: Double? = nil
    ) async {
        let event = Event(
            id: videoId,
            watchedAt: ScreenDate.string(from: watchedAt),
            title: title,
            progress: progress
        )
        enqueue(event)
        await flush()
    }

    /// Sends whatever is queued. Safe to call on launch and on foreground.
    public func flush() async {
        guard !pending.isEmpty, isConfigured, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.batchLimit))
            guard await send(batch) else { return } // keep the queue for next time
            // An enqueue may replace a progress event while the request is in flight.
            pending.removeAll { batch.contains($0) }
            persist()
        }
    }

    private func enqueue(_ event: Event) {
        // Identical ids already waiting are the same watch.
        guard !pending.contains(event) else { return }
        // A queue that never reached Screen can hold several reports for one film
        // as it was watched. Only the latest is worth sending, and a finish
        // supersedes every progress report before it.
        pending.removeAll { $0.id == event.id && ($0.progress != nil) }
        pending.append(event)
        if pending.count > Self.queueLimit {
            pending.removeFirst(pending.count - Self.queueLimit)
        }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingKey)
    }

    private static let logger = Logger(subsystem: "com.stream.core", category: "Screen")

    private func send(_ batch: [Event]) async -> Bool {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["events": batch])

        do {
            let (data, response) = try await session.data(for: request)
            lastFailure = nil
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                lastSent = Date()
                lastSentTitle = batch.last?.title
            }
            Self.logger.info(
                "Screen accepted \(batch.count) event(s), status \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)"
            )
            #if DEBUG
            // The status and Screen's own reply. Debug-only: the response names
            // what was recorded, and that is the user's library, not log material.
            Self.logger.info(
                "POST \(batch.count) event(s) → \((response as? HTTPURLResponse)?.statusCode ?? -1): \(String(decoding: data, as: UTF8.self).prefix(200), privacy: .public)"
            )
            #endif
            guard let http = response as? HTTPURLResponse else { return false }
            if (200..<300).contains(http.statusCode) { return true }
            // Authentication failures and transient client errors retain the queue.
            // Other 4xx responses reject the submitted event data permanently.
            if [401, 403, 408, 425, 429].contains(http.statusCode) {
                lastFailure = "Screen could not accept watches (HTTP \(http.statusCode)); queued for retry."
                return false
            }
            if (400..<500).contains(http.statusCode) {
                lastFailure = http.statusCode == 401
                    ? "Screen rejected the token."
                    : "Screen refused \(batch.count) watch(es) (HTTP \(http.statusCode))."
                return true
            }
            return false // 5xx or anything else: keep and try again later
        } catch {
            // Offline is the normal case on a TV, not an error worth surfacing.
            Self.logger.info("Screen POST failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

private enum ScreenDate {
    /// Screen validates `watchedAt` as a datetime, so fractional seconds are
    /// included. Built per call rather than shared: `ISO8601DateFormatter` is not
    /// `Sendable`, and this runs a handful of times a day, not in a loop.
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
