// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A JSON value whose objects keep their keys in the order they were set:
/// what the plugin sends DynamicLake is built piece by piece, and written
/// out the way the Python plugin wrote it (`json.dumps` with no spaces and
/// every character beyond ASCII escaped), so that the two can be compared
/// byte for byte.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (lhs: JSON, rhs: JSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.double(a), .double(b)): a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): Double(a) == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)):
            // (Python's dicts compare without regard to their order, too.)
            a.count == b.count && a.allSatisfy { key, value in b.first { $0.0 == key }?.1 == value }
        default: false
        }
    }

    /// An object from pairs, in that order.
    public static func obj(_ pairs: KeyValuePairs<String, JSON>) -> JSON {
        .object(pairs.map { ($0.key, $0.value) })
    }

    /// The value at `key` of an object (nothing for anything else). Setting
    /// it replaces the value where it was, or adds it at the end; setting
    /// nothing removes it.
    public subscript(key: String) -> JSON? {
        get {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first { $0.0 == key }?.1
        }
        set {
            guard case .object(var pairs) = self else { return }
            let index = pairs.firstIndex { $0.0 == key }
            switch (index, newValue) {
            case let (index?, value?): pairs[index].1 = value
            case let (nil, value?): pairs.append((key, value))
            case let (index?, nil): pairs.remove(at: index)
            case (nil, nil): break
            }
            self = .object(pairs)
        }
    }

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var keys: [String] {
        if case .object(let pairs) = self { return pairs.map(\.0) }
        return []
    }

    /// This object with the pairs of `other` set on it, in their order
    /// (Python's `{**a, **b}`).
    public func merging(_ other: JSON) -> JSON {
        var result = self
        if case .object(let pairs) = other {
            for (key, value) in pairs { result[key] = value }
        }
        return result
    }

    // MARK: Writing

    /// The compact text: `{"a":1,"b":[true,null]}`.
    public var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .int(let number): out += String(number)
        case .double(let number): out += Self.python(number)
        case .string(let text): Self.quote(text, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (index, (key, value)) in pairs.enumerated() {
                if index > 0 { out += "," }
                Self.quote(key, into: &out)
                out += ":"
                value.write(into: &out)
            }
            out += "}"
        }
    }

    /// A number as Python writes a float: the shortest form that reads back
    /// the same, `1.0` for a whole one, `1e-05` below 0.0001.
    static func python(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number > 0 ? "Infinity" : "-Infinity" }
        var text = "\(number)"
        // Swift writes 1e-05 and 1e+16 as Python does, but not every
        // exponent: Python always gives it two digits at least.
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mantissa = text[..<e]
            var exponent = String(text[text.index(after: e)...])
            var sign = "+"
            if exponent.hasPrefix("-") { sign = "-"; exponent.removeFirst() } else if exponent.hasPrefix("+") { exponent.removeFirst() }
            if exponent.count < 2 { exponent = "0" + exponent }
            text = mantissa + "e" + sign + exponent
        }
        return text
    }

    private static func quote(_ text: String, into out: inout String) {
        out += "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default:
                let hex = String(unit, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            }
        }
        out += "\""
    }

    // MARK: Reading

    /// A value read from JSON text (keys in the order they were written).
    public static func parse(_ data: Data) -> JSON? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return from(object, ordered: data)
    }

    /// From what `JSONSerialization` gives (which loses the keys' order:
    /// they are put back in the order they appear in `ordered`, when known).
    static func from(_ object: Any, ordered: Data? = nil) -> JSON? {
        switch object {
        case is NSNull: return .null
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let items as [Any]:
            return .array(items.compactMap { from($0) })
        case let pairs as [String: Any]:
            return .object(pairs.keys.sorted().compactMap { key in from(pairs[key]!).map { (key, $0) } })
        default:
            return nil
        }
    }
}
