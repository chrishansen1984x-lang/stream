import Foundation
import os

/// A stream plus its parsed attributes and the addon it came from.
public struct RankedStream: Identifiable, Hashable, Sendable {
    public var stream: Stream
    public var attributes: StreamAttributes

    public var id: String { stream.id }

    public var addonName: String { stream.addonName ?? "Unknown" }
}

/// Fans a stream request out across every capable addon.
///
/// Addons are independent third-party servers with wildly varying latency. Awaiting
/// them serially, or awaiting the slowest one, is the single biggest cause of a
/// sluggish stream list — so results are yielded as they land and the whole group is
/// abandoned at a hard deadline.
public struct StreamResolver: Sendable {
    private let client: AddonClient
    private let logger = Logger(subsystem: "com.stream.core", category: "StreamResolver")

    /// Hard ceiling for the whole fan-out. Anything slower is not worth the wait.
    public var deadline: Duration = .seconds(15)

    public init(client: AddonClient) {
        self.client = client
    }

    /// Yields batches as each addon responds, so the UI fills in progressively.
    public func resolve(
        type: MediaType,
        id: String,
        from addons: [Addon]
    ) -> AsyncStream<Result<[RankedStream], AddonFailure>> {
        let capable = addons.filter { $0.supports(.stream, type: type, id: id) }
        let client = self.client
        let deadline = self.deadline

        // Nothing to ask: finish immediately rather than letting the caller sit on a
        // spinner until the deadline elapses.
        guard !capable.isEmpty else {
            return AsyncStream { $0.finish() }
        }

        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: FanOutResult.self) { group in
                    for addon in capable {
                        group.addTask {
                            do {
                                let streams = try await client.streams(from: addon, type: type, id: id)
                                let ranked = streams.map {
                                    RankedStream(stream: $0, attributes: ReleaseParser.parse($0))
                                }
                                return .batch(ranked)
                            } catch {
                                return .failed(AddonFailure(addonName: addon.name, error: error))
                            }
                        }
                    }

                    // Racing a sleeper against the group abandons stragglers rather than
                    // letting one dead addon hang the whole list.
                    group.addTask {
                        try? await Task.sleep(for: deadline)
                        return .deadlineReached
                    }

                    // The sleeper never completes on its own once every addon has
                    // answered, so completions are counted and the group is torn down
                    // as soon as the last real task reports. Without this the caller
                    // waits out the full deadline on every single lookup.
                    var completed = 0
                    for await result in group {
                        switch result {
                        case .batch(let streams):
                            continuation.yield(.success(streams))
                            completed += 1
                        case .failed(let failure):
                            continuation.yield(.failure(failure))
                            completed += 1
                        case .deadlineReached:
                            completed = capable.count
                        }
                        if completed >= capable.count { break }
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum FanOutResult: Sendable {
        case batch([RankedStream])
        case failed(AddonFailure)
        case deadlineReached
    }

    /// Convenience for callers that just want the finished, sorted list.
    public func resolveAll(
        type: MediaType,
        id: String,
        from addons: [Addon],
        preferences: RankingPreferences = .init()
    ) async -> (streams: [RankedStream], failures: [AddonFailure]) {
        var collected: [RankedStream] = []
        var failures: [AddonFailure] = []

        for await result in resolve(type: type, id: id, from: addons) {
            switch result {
            case .success(let batch): collected.append(contentsOf: batch)
            case .failure(let failure): failures.append(failure)
            }
        }

        return (StreamRanker.rank(collected, preferences: preferences), failures)
    }
}

public struct AddonFailure: Error, Hashable, Sendable {
    public var addonName: String
    public var message: String

    init(addonName: String, error: any Error) {
        self.addonName = addonName
        self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
