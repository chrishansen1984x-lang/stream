import Foundation
import Testing
@testable import StreamCore

private final class SearchStub: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let slow = request.url!.host == "slow.test"
        DispatchQueue.global().asyncAfter(deadline: .now() + (slow ? 2 : 0.02)) { [self] in
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            let path = request.url!.path
            let query = path.components(separatedBy: "search=").last!.replacingOccurrences(of: ".json", with: "")
            let status = query == "fail" ? 503 : 200
            let metas: [[String: String]] = query == "empty" ? [] : [
                ["id": slow ? "exact" : "partial", "type": "movie", "name": slow ? query : query + " sequel"]
            ]
            let body = try! JSONSerialization.data(withJSONObject: ["metas": metas])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

@Suite(.serialized)
@MainActor
struct CatalogSearchTests {
    private func registry() throws -> AddonRegistry {
        let defaults = UserDefaults(suiteName: "search-tests-\(UUID())")!
        let addons = try ["slow", "fast"].map { name in
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data("""
            {"id":"\(name)","name":"\(name)","version":"1","types":["movie"],"resources":["catalog"],"catalogs":[{"id":"top","type":"movie","extra":[{"name":"search"}]}]}
            """.utf8))
            return Addon(manifest: manifest, transportURL: URL(string: "https://\(name).test/manifest.json")!)
        }
        // Read a fixture snapshot without writing to the user's installed addons.
        defaults.set(try JSONEncoder().encode(addons), forKey: "installedAddons")
        return AddonRegistry(defaults: defaults)
    }

    private func client() -> AddonClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchStub.self]
        return AddonClient(session: URLSession(configuration: config))
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test func publishesFastResultsBeforeSlowCatalogAndRanksExactMatch() async throws {
        let model = CatalogSearchModel()
        model.search(query: "Iron Man", registry: try registry(), client: client())
        try await wait { !model.results.isEmpty }
        #expect(model.isSearching)
        #expect(model.results.first?.name == "Iron Man sequel")
        try await wait { !model.isSearching }
        #expect(model.results.map(\.name) == ["Iron Man", "Iron Man sequel"])
    }

    @Test func changedAndClearedQueriesRejectOlderResponses() async throws {
        let model = CatalogSearchModel()
        let registry = try registry()
        let client = client()
        model.search(query: "old", registry: registry, client: client)
        try await wait { !model.results.isEmpty }
        model.search(query: "new", registry: registry, client: client)
        try await wait { !model.isSearching }
        #expect(model.results.allSatisfy { $0.name.hasPrefix("new") })
        model.search(query: "another", registry: registry, client: client)
        try await wait { model.results.first?.name == "another sequel" }
        model.search(query: "", registry: registry, client: client)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(model.results.isEmpty)
        #expect(!model.isSearching)
        #expect(!model.hasSearched)
    }

    @Test func failedRequestsAreDifferentFromEmptyAnswers() async throws {
        let model = CatalogSearchModel()
        let registry = try registry()
        let client = client()
        model.search(query: "fail", registry: registry, client: client)
        try await wait { !model.isSearching }
        #expect(model.failedSources == 2)
        #expect(model.results.isEmpty)
        model.search(query: "empty", registry: registry, client: client)
        try await wait { !model.isSearching }
        #expect(model.failedSources == 0)
        #expect(model.results.isEmpty)
    }
}
