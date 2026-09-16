import Foundation

/// Addons are written by hundreds of independent authors and are inconsistent about
/// primitive types: Cinemeta returns `imdbRating` as `"9.5"` while other addons return
/// `9.5`, and `year` may be `2008`, `"2008"`, or `"2008–2013"`.
///
/// These wrappers decode either representation rather than failing the whole payload.
/// A single strict field would otherwise drop an entire catalog page.
@propertyWrapper
public struct LenientString: Codable, Hashable, Sendable {
    public var wrappedValue: String?

    public init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let string = try? container.decode(String.self) {
            // Addons send "" as readily as they omit a field. Collapsing both to nil
            // means every call site can use `if let` instead of also testing emptiness.
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            wrappedValue = trimmed.isEmpty ? nil : trimmed
        } else if let int = try? container.decode(Int.self) {
            wrappedValue = String(int)
        } else if let double = try? container.decode(Double.self) {
            // Avoid "6.0" for whole numbers that arrived as 6
            wrappedValue = Int(exactly: double).map(String.init) ?? String(double)
        } else if let bool = try? container.decode(Bool.self) {
            wrappedValue = String(bool)
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// Decodes a number that may arrive as a JSON string (`"1080"`, `"42"`).
@propertyWrapper
public struct LenientInt: Codable, Hashable, Sendable {
    public var wrappedValue: Int?

    public init(wrappedValue: Int?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let int = try? container.decode(Int.self) {
            wrappedValue = int
        } else if let double = try? container.decode(Double.self) {
            wrappedValue = Int(exactly: double.rounded(.towardZero))
        } else if let string = try? container.decode(String.self) {
            wrappedValue = Int(string) ?? Double(string).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// Decodes a list that may arrive as a single bare value (`"Action"` vs `["Action"]`),
/// which several community addons do for `genre`, `director`, and `cast`.
@propertyWrapper
public struct LenientStringArray: Codable, Hashable, Sendable {
    public var wrappedValue: [String]

    public init(wrappedValue: [String]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = []
        } else if let array = try? container.decode([String].self) {
            wrappedValue = array
        } else if let single = try? container.decode(String.self) {
            wrappedValue = [single]
        } else if let numbers = try? container.decode([Int].self) {
            wrappedValue = numbers.map(String.init)
        } else {
            wrappedValue = []
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    // Absent keys must produce empty/nil rather than throwing, so these wrappers
    // behave like optionals when the addon omits the field entirely.
    public func decode(_ type: LenientString.Type, forKey key: Key) throws -> LenientString {
        try decodeIfPresent(type, forKey: key) ?? LenientString(wrappedValue: nil)
    }

    public func decode(_ type: LenientInt.Type, forKey key: Key) throws -> LenientInt {
        try decodeIfPresent(type, forKey: key) ?? LenientInt(wrappedValue: nil)
    }

    public func decode(_ type: LenientStringArray.Type, forKey key: Key) throws -> LenientStringArray {
        try decodeIfPresent(type, forKey: key) ?? LenientStringArray(wrappedValue: [])
    }
}
