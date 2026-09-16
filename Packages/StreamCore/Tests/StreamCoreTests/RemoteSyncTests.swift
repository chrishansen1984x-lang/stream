import Foundation
import Testing
@testable import StreamCore

private final class SyncProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload = Data("{}".utf8)
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var hold = false
    nonisolated(unsafe) private static var held: SyncProtocol?
    nonisolated(unsafe) private static var bodies: [Data] = []
    static var puts: [Data] { lock.withLock { bodies } }
    static var waiting: Bool { lock.withLock { held != nil } }
    static func configure(_ fields: [String: String] = [:], code: Int = 200, gated: Bool = false) throws {
        let bytes = try JSONEncoder().encode(fields)
        lock.withLock { payload = bytes; status = code; hold = gated; held = nil; bodies = [] }
    }
    static func release() {
        let pending = lock.withLock { defer { held = nil; hold = false }; return held }
        pending?.respond()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "PUT" {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            Self.lock.withLock { Self.bodies.append(data) }
        }
        let gate = Self.lock.withLock {
            if Self.hold { Self.held = self; return true }
            return false
        }
        if !gate { respond() }
    }
    private func respond() {
        let (data, code) = Self.lock.withLock { (Self.payload, Self.status) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class SyncFixture {
    let name = "stream.test.remote." + UUID().uuidString
    let defaults: UserDefaults
    let session: URLSession
    let registry: AddonRegistry
    let watch: WatchStateStore
    let list: WatchlistStore
    var preferences = RankingPreferences(requiredLanguages: ["eng", "spa", "fra"])
    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.set("https://example.test", forKey: "remoteSyncEndpoint")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncProtocol.self]
        session = URLSession(configuration: config)
        registry = AddonRegistry(defaults: defaults)
        watch = WatchStateStore(defaults: defaults)
        list = WatchlistStore(defaults: defaults)
    }
    func close() { session.invalidateAndCancel(); defaults.removePersistentDomain(forName: name) }
    func sync() -> RemoteSync {
        RemoteSync(session: session, defaults: defaults, initialToken: "test-only", debounce: .milliseconds(5), persistToken: { _ in })
    }
    func pull(_ sync: RemoteSync) async -> RankingPreferences? {
        await sync.pull(registry: registry, watchState: watch, watchlist: list, currentPreferences: { self.preferences })
    }
    func push(_ sync: RemoteSync) async throws -> [String: String] {
        let count = SyncProtocol.puts.count
        sync.schedulePush(registry: registry, watchState: watch, watchlist: list, preferences: preferences)
        try await wait { SyncProtocol.puts.count > count }
        // Wait for acknowledgment, not just request arrival.
        for _ in 0..<100 {
            if sync.lastSync != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try await Task.sleep(for: .milliseconds(20))
        return try JSONDecoder().decode([String: String].self, from: SyncProtocol.puts.last!)
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
}

@Suite(.serialized) @MainActor
struct RemoteSyncTests {
    private func addon(_ id: String) throws -> Addon {
        let json = "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"version\":\"1\",\"types\":[\"movie\"],\"resources\":[],\"catalogs\":[]}"
        return Addon(manifest: try JSONDecoder().decode(Manifest.self, from: Data(json.utf8)), transportURL: URL(string: "https://example.test/\(id)/manifest.json")!)
    }
    private func text<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }

    @Test func emptyEndpointReceivesInitialAddonsAndPreferences() async throws {
        try SyncProtocol.configure()
        let f = SyncFixture(); defer { f.close() }
        f.registry.install(try addon("local"))
        let sync = f.sync()
        _ = await f.pull(sync)
        let body = try await f.push(sync)
        #expect(body["addons"] != nil)
        #expect(body["preferences"] != nil)
        #expect(try JSONDecoder().decode([Addon].self, from: Data(body["addons"]!.utf8)).first?.id == "local")
    }

    @Test func unchangedFieldsStayOmittedAfterRestartAndReencoding() async throws {
        try SyncProtocol.configure()
        let f = SyncFixture(); defer { f.close() }
        f.registry.install(try addon("local"))
        _ = try await f.push(f.sync())
        f.preferences.requiredLanguages = Set(["fra", "spa", "eng"])
        let body = try await f.push(f.sync())
        #expect(body["addons"] == nil)
        #expect(body["preferences"] == nil)
        #expect(body["watch"] != nil)
    }

    @Test func offlineEditsSurviveRestartAndPullThenUpload() async throws {
        try SyncProtocol.configure()
        let f = SyncFixture(); defer { f.close() }
        let old = try addon("old")
        f.registry.install(old)
        _ = try await f.push(f.sync())
        f.registry.remove(old)
        f.registry.install(try addon("offline"))
        f.preferences.excludeHDR = true
        try SyncProtocol.configure(["addons": text([old]), "preferences": text(RankingPreferences())])
        let restarted = f.sync()
        #expect(await f.pull(restarted) == nil)
        #expect(f.registry.addons.map(\.id) == ["offline"])
        let body = try await f.push(restarted)
        #expect(body["addons"] != nil)
        #expect(body["preferences"] != nil)
    }

    @Test func unchangedLocalFieldsAdoptRemoteChanges() async throws {
        try SyncProtocol.configure()
        let f = SyncFixture(); defer { f.close() }
        let sync = f.sync()
        _ = try await f.push(sync)
        let incoming = RankingPreferences(excludeHDR: true)
        try SyncProtocol.configure(["addons": text([addon("remote")]), "preferences": text(incoming)])
        f.preferences = await f.pull(sync) ?? f.preferences
        #expect(f.registry.addons.map(\.id) == ["remote"])
        #expect(f.preferences == incoming)
        let body = try await f.push(sync)
        #expect(body["addons"] == nil)
        #expect(body["preferences"] == nil)
    }

    @Test func editsDuringFirstPullArePreserved() async throws {
        let f = SyncFixture(); defer { f.close() }
        try SyncProtocol.configure(["addons": text([addon("remote")]), "preferences": text(RankingPreferences())], gated: true)
        let sync = f.sync()
        let task = Task { await f.pull(sync) }
        try await f.wait { SyncProtocol.waiting }
        f.registry.install(try addon("during-request"))
        f.preferences.excludeHDR = true
        SyncProtocol.release()
        #expect(await task.value == nil)
        #expect(f.registry.addons.map(\.id) == ["during-request"])
    }

    @Test func disconnectRejectsLatePullAndClearsCredentials() async throws {
        let f = SyncFixture(); defer { f.close() }
        try SyncProtocol.configure(["addons": text([addon("remote")])], gated: true)
        var persisted: String?
        let sync = RemoteSync(session: f.session, defaults: f.defaults, initialToken: "fake", persistToken: { persisted = $0 })
        let task = Task { await f.pull(sync) }
        try await f.wait { SyncProtocol.waiting }
        sync.forgetToken()
        SyncProtocol.release()
        _ = await task.value
        #expect(persisted == "")
        #expect(sync.state == .disabled)
        #expect(sync.lastSync == nil)
        #expect(f.registry.addons.isEmpty)
    }

    @Test func invalidRemoteAddonsDoNotAcknowledgeLocalSnapshot() async throws {
        try SyncProtocol.configure(["addons": "{}"])
        let f = SyncFixture(); defer { f.close() }
        let sync = f.sync()
        _ = await f.pull(sync)
        #expect(try await f.push(sync)["addons"] != nil)
    }

    @Test func rejectedUploadRemainsDirtyForRetry() async throws {
        try SyncProtocol.configure(code: 503)
        let f = SyncFixture(); defer { f.close() }
        let sync = f.sync()
        _ = try await f.push(sync)
        #expect(sync.lastSync == nil)
        try SyncProtocol.configure()
        let retried = try await f.push(sync)
        #expect(retried["addons"] != nil)
        #expect(retried["preferences"] != nil)
    }
    @Test func endpointChangeRejectsOldResponseAndResetsAcknowledgments() async throws {
        try SyncProtocol.configure()
        let f = SyncFixture(); defer { f.close() }
        let sync = f.sync()
        _ = try await f.push(sync)
        try SyncProtocol.configure(["addons": text([addon("old-endpoint")])], gated: true)
        let task = Task { await f.pull(sync) }
        try await f.wait { SyncProtocol.waiting }
        sync.endpoint = "https://new.example.test"
        SyncProtocol.release()
        _ = await task.value
        #expect(f.registry.addons.isEmpty)
        #expect(sync.lastSync == nil)
        try SyncProtocol.configure()
        _ = await f.pull(sync)
        let body = try await f.push(sync)
        #expect(body["addons"] != nil)
        #expect(body["preferences"] != nil)
    }

    @Test func successfulPullCancelsQueuedStaleSnapshot() async throws {
        let f = SyncFixture(); defer { f.close() }
        try SyncProtocol.configure(["addons": text([addon("remote")])])
        let sync = RemoteSync(session: f.session, defaults: f.defaults, initialToken: "fake", debounce: .milliseconds(40), persistToken: { _ in })
        sync.schedulePush(registry: f.registry, watchState: f.watch, watchlist: f.list, preferences: f.preferences)
        _ = await f.pull(sync)
        try await Task.sleep(for: .milliseconds(80))
        #expect(SyncProtocol.puts.isEmpty)
        #expect(f.registry.addons.map(\.id) == ["remote"])
        let body = try await f.push(sync)
        #expect(body["addons"] == nil)
    }

}
