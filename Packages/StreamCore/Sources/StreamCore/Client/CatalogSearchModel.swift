import Foundation
import Observation

@Observable
@MainActor
public final class CatalogSearchModel {
    public private(set) var results: [MetaPreview] = []
    public private(set) var isSearching = false
    public private(set) var hasSearched = false
    /// How many catalogs failed to answer the last search.
    ///
    /// Every failure used to collapse into an empty array, and the empty state then
    /// stated as fact something it could not know — "No installed catalog matched
    /// X" is a claim about the catalogs' *answers*, and with the network down there
    /// were no answers. Counting them lets the screen say which of the two it is.
    public private(set) var failedSources = 0

    private var currentTask: Task<Void, Never>?
    public private(set) var sourceCount = 0

    public init() {}

    /// Debounced search across every catalog that advertises `search` support.
    public func search(
        query: String,
        registry: AddonRegistry,
        client: AddonClient
    ) {
        currentTask?.cancel()
        failedSources = 0
        sourceCount = registry.searchableCatalogs.count

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }

        isSearching = true
        currentTask = Task {
            // Debounce: users type faster than addons respond.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            isSearching = true
            let sources = registry.searchableCatalogs

            var batches: [Int: [MetaPreview]] = [:]
            var failures = 0
            // `[MetaPreview]?` rather than `[MetaPreview]`: nil is "did not answer",
            // which an empty array cannot express and which the empty state needs.
            await withTaskGroup(of: (Int, [MetaPreview]?).self) { group in
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        // `try?` on a non-optional return already gives an
                        // optional; nil means the catalog did not answer.
                        let result = try? await client.catalog(
                            from: source.addon,
                            type: source.catalog.type,
                            id: source.catalog.id,
                            extra: [.search(trimmed)]
                        ).metas
                        return (index, result)
                    }
                }
                for await (index, batch) in group {
                    guard !Task.isCancelled else { return }
                    if let batch {
                        batches[index] = batch
                    } else {
                        failures += 1
                    }
                    // Publish each response; a slow addon must not hide fast results.
                    var seen = Set<String>()
                    let collected = sources.indices.flatMap { batches[$0] ?? [] }
                        .filter { seen.insert($0.id).inserted }
                    results = SearchRelevance.sorted(collected, query: trimmed, title: \.name)
                    failedSources = failures
                }
            }

            guard !Task.isCancelled else { return }

            if batches.isEmpty { results = [] }
            failedSources = failures
            isSearching = false
            hasSearched = true
        }
    }
}
