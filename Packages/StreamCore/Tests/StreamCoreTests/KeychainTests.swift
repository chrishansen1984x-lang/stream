import Testing
import Foundation
import Security
@testable import StreamCore

/// The keychain service is a hardcoded private constant, so these share a store
/// with the real app. Every account name here is scratch and uniquely suffixed, and
/// each test clears its own — nothing may go near `screenDeviceToken`,
/// `remoteSyncToken` or `traktClientSecret`.
@Suite("Keychain")
struct KeychainTests {

    private func scratchKey() -> String { "test.scratch.\(UUID().uuidString)" }

    @Test("A stored secret comes back exactly")
    func roundTrip() {
        let key = scratchKey()
        defer { Keychain.clear(key) }

        #expect(Keychain.set("a-secret-value", for: key) == errSecSuccess)
        #expect(Keychain.get(key) == "a-secret-value")
    }

    /// The bug that lost the Screen token: an empty string is not nil, so it used to
    /// be written as an empty secret straight over a good one.
    @Test("An empty value is refused and leaves an existing secret intact")
    func emptyIsNeverDestructive() {
        let key = scratchKey()
        defer { Keychain.clear(key) }

        #expect(Keychain.set("keep-me", for: key) == errSecSuccess)
        #expect(Keychain.set("", for: key) == errSecParam)
        #expect(Keychain.set(nil, for: key) == errSecParam)
        #expect(Keychain.get(key) == "keep-me")
    }

    /// Why `Keychain.get(x) != nil` is not a valid "is this configured" test: an
    /// item written empty by an older build reads back as `Optional("")`, which is
    /// truthy for a nil check and empty for everything else.
    @Test("A zero-length item reads back as empty, not as absent")
    func zeroLengthIsNotAbsence() {
        let key = scratchKey()
        defer { Keychain.clear(key) }

        // Written the way the old code did, bypassing the new guard.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.stream.trakt",
            kSecAttrAccount as String: key,
            kSecValueData as String: Data()
        ]
        SecItemDelete(query as CFDictionary)
        #expect(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)

        let read = Keychain.get(key)
        #expect(read != nil)
        #expect(read?.isEmpty == true)
    }

    @Test("A cleared secret is gone")
    func clearRemoves() {
        let key = scratchKey()
        #expect(Keychain.set("temporary", for: key) == errSecSuccess)
        #expect(Keychain.clear(key) == errSecSuccess)
        #expect(Keychain.get(key) == nil)
    }

    @Test("Clearing something that was never there is not an error worth reporting")
    func clearingAbsentIsHarmless() {
        #expect(Keychain.clear(scratchKey()) == errSecItemNotFound)
    }

    @Test("Overwriting replaces rather than appends a second item")
    func overwriteReplaces() {
        let key = scratchKey()
        defer { Keychain.clear(key) }

        #expect(Keychain.set("first", for: key) == errSecSuccess)
        #expect(Keychain.set("second", for: key) == errSecSuccess)
        #expect(Keychain.get(key) == "second")
    }
}
