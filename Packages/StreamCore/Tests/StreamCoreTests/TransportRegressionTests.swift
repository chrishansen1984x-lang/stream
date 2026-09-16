import Foundation
import Testing
@testable import StreamCore

struct TransportRegressionTests {
    @Test(arguments: ["\"N/A\"", "\"\"", "\"nan\"", "\"inf\"", "1e100", "-1e100"])
    func invalidNumbersDoNotTrap(json: String) throws {
        #expect(try JSONDecoder().decode(LenientInt.self, from: Data(json.utf8)).wrappedValue == nil)
    }
    @Test func numbersPreserveSafeValues() throws {
        #expect(try JSONDecoder().decode(LenientInt.self, from: Data("\"42.8\"".utf8)).wrappedValue == 42)
        #expect(try JSONDecoder().decode(LenientString.self, from: Data("1e100".utf8)).wrappedValue != nil)
        #expect(try JSONDecoder().decode(LenientString.self, from: Data("6.0".utf8)).wrappedValue == "6")
    }
    @Test func resourceURLHasOneEncodingLayer() throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(#"{"id":"test","name":"Test","version":"1","types":["movie"],"resources":["catalog"],"catalogs":[]}"#.utf8))
        let addon = Addon(manifest: manifest, transportURL: URL(string: "https://example.test/config%2Fkeep/manifest.json")!)
        let url = AddonClient().resourceURL(addon: addon, resource: .catalog, type: .movie, id: "custom/id", extra: [.search("hello world & 東京")])
        #expect(url.absoluteString == "https://example.test/config%2Fkeep/catalog/movie/custom%2Fid/search=hello%20world%20%26%20%E6%9D%B1%E4%BA%AC.json")
    }
}
