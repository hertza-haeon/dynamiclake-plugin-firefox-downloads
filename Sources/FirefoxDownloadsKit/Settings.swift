// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One setting's value: a switch, a choice, or a number of seconds.
public enum SettingValue: Equatable, Sendable {
    case flag(Bool)
    case choice(String)
    case seconds(Int)

    /// How it reads in the log: `on`, `time`, `60 s`.
    var logText: String {
        switch self {
        case .flag(let on): on ? "on" : "off"
        case .choice(let text): text
        case .seconds(let seconds): "\(seconds) s"
        }
    }
}

/// The switches in DynamicLake's plugin settings (plugin.json), in the order
/// the log lists them.
public enum SettingKey: String, CaseIterable, Sendable {
    /// "File-Type Icons": the kind of file in the pill instead of the arrow.
    case fileTypeIcons
    /// "Download Details": after the amounts, the "speed", the "time" left,
    /// the "queue" (how many downloads wait for a card), or "all" of them
    /// in turn.
    case downloadDetails
    /// "App Switching After Resume": after Resume, bring back the app you
    /// were in.
    case returnFocus
    /// "Focus Mode": a finished download's card waits until no download is
    /// under way.
    case focusMode
    /// "Delayed Display": hold sneak peeks while you're away; show them
    /// when you're back.
    case waitWhenAway
    /// "Away After": ...away after this long without input ("1 min",
    /// "5 min"...).
    case awayAfter
    /// "Smart Slideshows": finished cards that waited (for the others with
    /// "Focus Mode", for you with "Delayed Display") show as one card, with
    /// their number.
    case smartSlideshows
    /// "Sneak Peek Duration": how long a sneak peek opens ("3 s", "5 s"...).
    case sneakPeekDuration
    /// "Remain Visible": how long a finished or canceled card's pill stays
    /// after it.
    case remainVisible

    var defaultValue: SettingValue {
        switch self {
        case .fileTypeIcons: .flag(true)
        case .downloadDetails: .choice("time")
        case .returnFocus: .flag(true)
        case .focusMode: .flag(false)
        case .waitWhenAway: .flag(true)
        case .awayAfter: .seconds(60)
        case .smartSlideshows: .flag(false)
        case .sneakPeekDuration: .seconds(5)
        case .remainVisible: .seconds(0)
        }
    }

    /// Reads a value as it may arrive (`true`, `1`, `"on"`, `"5 s"`...);
    /// nothing when it can't be read.
    func parse(_ raw: Any?) -> SettingValue? {
        switch self {
        case .downloadDetails: SettingParsers.details(raw).map { .choice($0) }
        case .focusMode: SettingParsers.focus(raw).map { .flag($0) }
        case .awayAfter: SettingParsers.seconds(raw).map { .seconds($0) }
        case .sneakPeekDuration: SettingParsers.wholeSeconds(raw, 1, 10).map { .seconds($0) }
        case .remainVisible: SettingParsers.wholeSeconds(raw, 0, 30).map { .seconds($0) }
        default: SettingParsers.bool(raw).map { .flag($0) }
        }
    }

    /// The names DynamicLake gives it in the environment:
    /// `DYNAMICLAKE_SETTING_FILE_TYPE_ICONS` (and two other spellings).
    var environmentNames: [String] {
        var snake = ""
        for (index, character) in rawValue.enumerated() {
            if index > 0 && character.isASCII && character.isUppercase { snake += "_" }
            snake += String(character)
        }
        return ["DYNAMICLAKE_SETTING_\(snake.uppercased())", "DYNAMICLAKE_SETTING_\(rawValue.uppercased())",
                "DYNAMICLAKE_SETTING_\(rawValue)"]
    }
}

/// Values as they may arrive: `true`, `1`, `"1"`, `"on"`, `"5 s"`, `"5 minutes"`.
enum SettingParsers {
    private static func isBoolean(_ raw: Any) -> Bool {
        (raw as AnyObject) is NSNumber && CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// A number, not a switch (JSON's `true` arrives as a number too).
    private static func number(_ raw: Any) -> Double? {
        guard !isBoolean(raw), !(raw is String), let number = raw as? NSNumber else { return nil }
        return number.doubleValue
    }

    static func bool(_ raw: Any?) -> Bool? {
        guard let raw else { return nil }
        if isBoolean(raw) { return (raw as? NSNumber)?.boolValue }
        if let value = number(raw) { return value != 0 }
        guard let text = raw as? String else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    /// The choice of "Download Details", by its title ("Both" is what
    /// "All" was called while there were two things to show in turn).
    static func details(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        let choice = text == "both" ? "all" : text
        return ["speed", "time", "queue", "all"].contains(choice) ? choice : nil
    }

    /// The switch "Focus Mode" (for a while it was a choice of Off, On or
    /// Simplified: a setting still stored that way reads as on, or off).
    static func focus(_ raw: Any?) -> Bool? {
        if let text = raw as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "simplified" {
            return true
        }
        return bool(raw)
    }

    private static var durationPattern: Regex<(Substring, Substring, Substring)> { #/\s*(\d+(?:[.,]\d+)?)\s*([A-Za-z]*)\.?\s*/# }
    private static let minutesPer: [String: Double] = [
        "": 1, "m": 1, "min": 1, "mins": 1, "minute": 1, "minutes": 1,
        "s": 1.0 / 60, "sec": 1.0 / 60, "secs": 1.0 / 60, "second": 1.0 / 60, "seconds": 1.0 / 60,
        "h": 60, "hr": 60, "hrs": 60, "hour": 60, "hours": 60,
    ]

    /// A duration setting -- the title of the choice ("1 minute", "5
    /// minutes"), or a number of minutes -- in seconds, from 10 s to an hour.
    static func seconds(_ raw: Any?) -> Int? {
        guard let raw, !isBoolean(raw) else { return nil }
        var minutes: Double
        if let value = number(raw) {
            minutes = value
        } else if let text = raw as? String, text.unicodeScalars.count <= 40,
                  let match = text.wholeMatch(of: durationPattern),
                  let per = minutesPer[match.2.lowercased()],
                  let value = Double(match.1.replacingOccurrences(of: ",", with: ".")) {
            minutes = value * per
        } else {
            return nil
        }
        guard minutes.isFinite else { return nil }
        return Int(min(3600.0, max(10.0, minutes * 60.0)) + 0.5)
    }

    /// A number of seconds -- a number, or the title of a choice ("5 s",
    /// "5 seconds") -- when it's from `lowest` to `highest`.
    static func wholeSeconds(_ raw: Any?, _ lowest: Int, _ highest: Int) -> Int? {
        guard let raw, !isBoolean(raw) else { return nil }
        var seconds: Double
        if let value = number(raw) {
            seconds = value
        } else if let text = raw as? String, text.unicodeScalars.count <= 40,
                  let match = text.wholeMatch(of: durationPattern),
                  ["", "s", "sec", "secs", "second", "seconds"].contains(match.2.lowercased()),
                  let value = Double(match.1.replacingOccurrences(of: ",", with: ".")) {
            seconds = value
        } else {
            return nil
        }
        guard seconds.isFinite, seconds >= Double(lowest), seconds <= Double(highest) else { return nil }
        return Int(seconds + 0.5)
    }
}

/// DynamicLake passes the plugin's settings at launch (environment variables
/// DYNAMICLAKE_SETTING_...) and keeps them in a file it names
/// (DYNAMICLAKE_PLUGIN_SETTINGS_PATH), which is read again every few seconds
/// so that a change applies at once. Anything unreadable keeps its default.
public final class Settings {
    public private(set) var values: [SettingKey: SettingValue]
    /// Goes up on every change (part of each card's signature).
    public private(set) var generation = 0
    private var nextRead = 0.0
    private let environment: [String: String]
    var refreshSeconds: () -> Double

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                refreshSeconds: @escaping () -> Double = { 5.0 }) {
        self.environment = environment
        self.refreshSeconds = refreshSeconds
        values = Self.defaults
    }

    static var defaults: [SettingKey: SettingValue] {
        Dictionary(uniqueKeysWithValues: SettingKey.allCases.map { ($0, $0.defaultValue) })
    }

    public subscript(key: SettingKey) -> SettingValue { values[key]! }

    func flag(_ key: SettingKey) -> Bool {
        if case .flag(let on) = self[key] { return on }
        return false
    }

    func seconds(_ key: SettingKey) -> Int {
        if case .seconds(let seconds) = self[key] { return seconds }
        return 0
    }

    var details: String {
        if case .choice(let choice) = self[.downloadDetails] { return choice }
        return "time"
    }

    /// For tests: settings as given.
    func set(_ key: SettingKey, _ value: SettingValue) {
        if values[key] != value {
            values[key] = value
            generation += 1
        }
    }

    /// Reads them again (at most every few seconds); returns a line for the
    /// log when something changed (or, with `force`, always). A settings
    /// file caught mid-write keeps the settings as they were.
    public func refresh(now: Double, force: Bool = false) -> String? {
        if !force && now < nextRead { return nil }
        nextRead = now + refreshSeconds()
        var read: [SettingKey: SettingValue]
        do {
            read = try self.read()
        } catch {
            // (a file that can't be read now: try again soon)
            nextRead = now + 1.0
            if !force { return nil }
            read = Self.defaults
        }
        if read == values && !force { return nil }
        let changed = SettingKey.allCases.filter { force || read[$0] != values[$0] }
            .map { "\($0.rawValue) \(read[$0]!.logText)" }
        if read != values { generation += 1 }
        values = read
        return "settings: " + changed.joined(separator: ", ")
    }

    private struct Unreadable: Error {}

    private func read() throws -> [SettingKey: SettingValue] {
        var read = Self.defaults
        for key in SettingKey.allCases {
            for name in key.environmentNames {
                if let value = key.parse(environment[name]) {
                    read[key] = value
                    break
                }
            }
        }
        guard let path = environment["DYNAMICLAKE_PLUGIN_SETTINGS_PATH"], !path.isEmpty else { return read }
        guard let data = FileManager.default.contents(atPath: path) else {
            if Paths.exists(path) { throw Unreadable() }
            return read                               // none yet: the defaults
        }
        guard String(data: data, encoding: .utf8) != nil,
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw Unreadable()
        }
        var stored: [String: Any]?
        if let object = json as? [String: Any] {
            stored = object.keys.contains("values") ? object["values"] as? [String: Any] : object
        }
        if let stored {
            for key in SettingKey.allCases {
                if let value = key.parse(stored[key.rawValue]) {
                    read[key] = value
                }
            }
        }
        return read
    }
}
