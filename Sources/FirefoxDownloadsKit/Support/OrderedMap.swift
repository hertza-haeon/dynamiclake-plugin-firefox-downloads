// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A dictionary that keeps its keys in the order they were added, as the
/// plugin's rules go through downloads and cards in that order. Setting a
/// key that's there keeps its place; a key removed and added again goes
/// last.
struct OrderedMap<Key: Hashable, Value> {
    private(set) var keys: [Key] = []
    private var storage: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    /// Sets a value (one that may itself be nothing).
    mutating func set(_ key: Key, _ value: Value) {
        self[key] = .some(value)
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let value = storage.removeValue(forKey: key) else { return nil }
        keys.removeAll { $0 == key }
        return value
    }

    func contains(_ key: Key) -> Bool {
        storage[key] != nil
    }

    var values: [Value] { keys.map { storage[$0]! } }
    var items: [(key: Key, value: Value)] { keys.map { ($0, storage[$0]!) } }
    var isEmpty: Bool { keys.isEmpty }
}
