// Sources/ArtAdk/Util/ArtSupport.swift
//
// Small internal helpers shared across the SDK: locking, opt-in logging,
// and encoders for the exact wire encoding the server expects
// (URI components, form-encoded queries, compact JSON).

import Foundation

// MARK: - Locking

/// Recursive lock guarding mutable SDK state that is touched from several
/// tasks. The closure API keeps `lock()`/`unlock()` out of `async`
/// contexts and guarantees balanced unlocks. Never call user callbacks
/// while holding it.
final class ArtLock {
    private let lock = NSRecursiveLock()

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Logging

/// Severity of an SDK diagnostic message.
public enum ArtLogLevel: String {
    case debug, info, warning, error
}

/// Opt-in sink for SDK diagnostics (unknown agent events, superseded
/// runs, interceptor misuse, missing configuration). Silent by default.
///
/// ```swift
/// ArtLog.handler = { level, message in print("[ART][\(level)] \(message)") }
/// ```
public enum ArtLog {
    public static var handler: ((ArtLogLevel, String) -> Void)?

    static func debug(_ message: @autoclosure () -> String) { handler?(.debug, message()) }
    static func info(_ message: @autoclosure () -> String) { handler?(.info, message()) }
    static func warn(_ message: @autoclosure () -> String) { handler?(.warning, message()) }
    static func error(_ message: @autoclosure () -> String) { handler?(.error, message()) }
}

// MARK: - Wire encoding

enum ArtEncoding {
    private static let asciiAlphanumerics =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    /// Characters left unescaped in a URI component.
    private static let uriComponentAllowed =
        CharacterSet(charactersIn: asciiAlphanumerics + "-_.!~*'()")

    /// Characters left unescaped in a form-encoded query (space is
    /// handled separately and becomes `+`).
    private static let formAllowed =
        CharacterSet(charactersIn: asciiAlphanumerics + "*-._ ")

    /// Percent-encodes everything except letters, digits and `-_.!~*'()`.
    static func uriComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? value
    }

    /// Form-encodes a single query key or value.
    static func formComponent(_ value: String) -> String {
        let encoded = value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
        return encoded.replacingOccurrences(of: " ", with: "+")
    }

    /// Form-encoded query string (`a=1&b=2`). Pairs are emitted in the
    /// order given.
    static func formQuery(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(formComponent($0.0))=\(formComponent($0.1))" }.joined(separator: "&")
    }

    /// Dictionary variant; keys are sorted so URLs are deterministic
    /// (dictionaries have no stable order).
    static func formQuery(_ params: [String: String]) -> String {
        formQuery(params.keys.sorted().map { ($0, params[$0] ?? "") })
    }

    /// ISO 8601 timestamp with milliseconds, e.g. `2026-09-24T10:02:31.220Z`.
    static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - JSON

/// Thrown when a value handed to the SDK can't be encoded as JSON.
/// (`JSONSerialization` raises an uncatchable Objective-C exception for
/// invalid input, so values are validated first.)
public struct ArtJSONError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

enum ArtJSON {
    /// Compact JSON text for JSON-compatible values, including top-level
    /// strings, numbers, booleans and `NSNull`.
    static func stringify(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject([value]) else {
            throw ArtJSONError(message: "Value is not JSON-serializable: \(type(of: value))")
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Decodes JSON text (fragments allowed); `nil` when it isn't JSON.
    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Truthiness for decoded JSON values: `nil`, `NSNull`, empty strings
    /// and zero are false; everything else is true.
    static func isTruthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let string = value as? String { return !string.isEmpty }
        if let number = value as? NSNumber { return number != 0 }
        return true
    }

    /// Decoded JSON number → `Int` (accepts `NSNumber`, `Int`, `Double`).
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let number as NSNumber: return number.intValue
        case let double as Double: return Int(double)
        case let string as String: return Int(string)
        default: return nil
        }
    }

    /// Decoded JSON value → `String` when it is a non-empty scalar.
    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}
