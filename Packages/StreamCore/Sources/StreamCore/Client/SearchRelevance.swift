import Foundation

public enum SearchRelevance {
    /// Preserve catalog order within each relevance tier.
    public static func sorted<T>(_ results: [T], query: String, title: (T) -> String) -> [T] {
        let query = normalized(query)
        guard !query.isEmpty else { return results }
        let words = Set(query.split(separator: " "))
        let ranks: [Int] = results.map { result in
            rank(normalized(title(result)), query: query, words: words)
        }
        let indices = results.indices.sorted { left, right in
            ranks[left] == ranks[right] ? left < right : ranks[left] < ranks[right]
        }
        return indices.map { results[$0] }
    }

    private static func rank(_ name: String, query: String, words: Set<Substring>) -> Int {
        if name == query { return 0 }
        if name.hasPrefix(query + " ") { return 1 }
        let paddedName = " \(name) "
        let paddedQuery = " \(query) "
        if paddedName.contains(paddedQuery) { return 2 }
        if words.isSubset(of: Set(name.split(separator: " "))) { return 3 }
        return 4
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
