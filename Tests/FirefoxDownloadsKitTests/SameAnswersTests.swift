// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import FirefoxDownloadsKit

/// The Python plugin's answers (Firefox Downloads 1.1.3), taken from its
/// own code: the Swift plugin must give the same ones.
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func list(_ name: String) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed]) as? [[String: Any]])
    }

    static func object(_ name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed]) as? [String: Any])
    }
}

/// A JSON value from a fixture, as `SettingParsers` would get it from a file
/// (nothing for null).
private func raw(_ value: Any?) -> Any? {
    value is NSNull ? nil : value
}

private func describe(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "null" }
    if let number = value as? NSNumber {
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : "\(number)"
    }
    return "\(value)"
}

/// Whether a Swift value and a fixture's value are the same (numbers
/// compared as numbers, exactly).
private func same(_ a: Any?, _ b: Any?) -> Bool {
    let a = a is NSNull ? nil : a, b = b is NSNull ? nil : b
    if a == nil || b == nil { return a == nil && b == nil }
    if let x = a as? NSNumber, let y = b as? NSNumber { return x.doubleValue == y.doubleValue }
    return "\(a!)" == "\(b!)"
}

struct FormattingTests {
    @Test func sizesSpeedsAndTimesAreWrittenAsThePythonPluginWritesThem() throws {
        for case let item in try Fixtures.list("formatting.json") {
            let fn = item["fn"] as! String
            let args = item["args"] as! [NSNumber]
            switch fn {
            case "bytes": #expect(Formatting.bytes(args[0].intValue) == item["out"] as? String, "bytes(\(args[0]))")
            case "amount": #expect(Formatting.amount(args[0].intValue) == item["out"] as? String, "amount(\(args[0]))")
            case "pair": #expect(Formatting.pair(args[0].intValue, args[1].intValue) == item["out"] as? String, "pair(\(args))")
            case "speed": #expect(Formatting.speed(args[0].doubleValue) == item["out"] as? String, "speed(\(args[0]))")
            case "time": #expect(Formatting.time(args[0].intValue) == item["out"] as? String, "time(\(args[0]))")
            case "margin": #expect(Formatting.timeLeftMargin(args[0].doubleValue) == (item["out"] as! NSNumber).doubleValue)
            default: Issue.record("unknown \(fn)")
            }
        }
    }
}

struct SettingsTests {
    @Test func settingsAreReadAsThePythonPluginReadsThem() throws {
        for item in try Fixtures.list("settings.json") {
            let parser = item["parser"] as! String
            let value = raw(item["raw"])
            let expected = describe(item["out"])
            let got: Any?
            switch parser {
            case "bool": got = SettingParsers.bool(value)
            case "seconds": got = SettingParsers.seconds(value)
            case "details": got = SettingParsers.details(value)
            case "focus": got = SettingParsers.focus(value)
            case "peek": got = SettingParsers.wholeSeconds(value, 1, 10)
            case "remain": got = SettingParsers.wholeSeconds(value, 0, 30)
            default: got = nil
            }
            #expect(describe(got.map { $0 as Any }) == expected, "\(parser)(\(describe(value)))")
        }
    }

    @Test func theLogLineListsEverySettingAtStartThenTheChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fd-settings-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("settings.json")
        try Data(#"{"values": {"fileTypeIcons": false, "awayAfter": "5 min"}}"#.utf8).write(to: file)
        let settings = Settings(environment: ["DYNAMICLAKE_PLUGIN_SETTINGS_PATH": file.path, "DYNAMICLAKE_SETTING_FOCUS_MODE": "1"])
        #expect(settings.refresh(now: 0, force: true) == "settings: fileTypeIcons off, downloadDetails time, returnFocus on, "
            + "focusMode on, waitWhenAway on, awayAfter 300 s, smartSlideshows off, sneakPeekDuration 5 s, remainVisible 0 s")
        #expect(settings.generation == 1)
        try Data(#"{"values": {"fileTypeIcons": true, "awayAfter": "5 min"}}"#.utf8).write(to: file)
        #expect(settings.refresh(now: 1) == nil)              // (not before 5 s)
        #expect(settings.refresh(now: 5) == "settings: fileTypeIcons on")
        #expect(settings.generation == 2)
        try Data("{\"values\": {".utf8).write(to: file)        // caught mid-write: as they were
        #expect(settings.refresh(now: 10) == nil)
        #expect(settings.flag(.fileTypeIcons))
    }
}

struct NamesTests {
    @Test func namesAreTakenApartAsThePythonPluginTakesThem() throws {
        for item in try Fixtures.list("names.json") {
            let args = item["args"] as! [String]
            let expected = item["out"] as! String
            switch item["fn"] as! String {
            case "realName": #expect(realNameFromPart(args[0]) == expected, "realName(\(args[0]))")
            case "badgeText": #expect(Faces.badgeText(args[0]) == expected, "badgeText(\(args[0]))")
            case "statusText":
                let shared = Shared(log: PluginLog(path: "/dev/null"), ruler: .unmeasured())
                let download = Download("/D/\(args[1]).part", shared: shared)
                download.finalPath = "/D/" + args[1]
                #expect(Faces(shared).statusText(args[0], download) == expected, "statusText(\(args[0]), \(args[1].prefix(30)))")
            default: Issue.record("unknown")
            }
        }
    }
}

struct BrowserTests {
    @Test func downloadsJsonIsReadAsThePythonPluginReadsIt() throws {
        let fixture = try Fixtures.object("lists.json")
        for item in fixture["entries"] as! [[String: Any]] {
            #expect(DownloadsListFile.state(of: item["item"] as! [String: Any]) == item["out"] as! String, "\(item["item"]!)")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fd-lists-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for item in fixture["files"] as! [[String: Any]] {
            let file = folder.appendingPathComponent("downloads.json")
            try JSONSerialization.data(withJSONObject: item["content"]!).write(to: file)
            let got = DownloadsListFile.read(file.path).map { key, entry in
                "\(key.kind == .path ? "path" : "name")|\(key.key)|\(entry.total.map(String.init) ?? "null")|\(entry.state)"
            }.sorted()
            let expected = (item["out"] as! [[Any]]).map { row in
                "\(row[0])|\(row[1])|\(describe(row[2]))|\(row[3])"
            }.sorted()
            #expect(got == expected, "\(item["content"]!)")
        }
    }

    @Test func downloadFoldersAndProfilesAreFoundAsThePythonPluginFindsThem() throws {
        let fixture = try Fixtures.object("browser.json")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fd-browser-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        setenv("HOME", "/Users/someone", 1)
        for item in fixture["prefs"] as! [[String: Any]] {
            let file = folder.appendingPathComponent("prefs.js")
            try Data((item["text"] as! String).utf8).write(to: file)
            let got = Profiles.downloadFolder(Profiles.parsePrefs(file.path), home: "/Users/someone")
            #expect(got == item["folder"] as! String, "\(item["text"]!)")
        }
        for item in fixture["ini"] as! [[String: Any]] {
            try Data((item["text"] as! String).utf8).write(to: folder.appendingPathComponent("profiles.ini"))
            let got = Profiles.iniPaths(folder.path).map { path in
                path.hasPrefix(folder.path + "/") ? String(path.dropFirst(folder.path.count + 1)) : path
            }
            #expect(got == item["paths"] as! [String], "\(item["text"]!)")
        }
    }
}

struct PictureTests {
    @Test func everyPictureIsTheSameByteForByte() throws {
        for item in try Fixtures.list("pictures.json") {
            let expected = try Fixtures.data("pictures/" + (item["file"] as! String))
            let got = try #require(Pictures.png(item["kind"] as! String, item["text"] as! String))
            #expect(got == expected, "\(item["kind"]!) \(item["text"]!)")
        }
    }
}

struct RulerTests {
    @Test func textIsMeasuredAndShapedAsThePythonPluginDoesIt() throws {
        let ruler = TextRuler.system()
        for item in try Fixtures.list("ruler.json") {
            let args = item["args"] as! [Any]
            switch item["fn"] as! String {
            case "width":
                #expect(ruler.width(args[0] as! String) == (item["out"] as? NSNumber)?.doubleValue, "width(\(args[0]))")
            case "fitted":
                #expect(ruler.fitted(args[0] as! String) == item["out"] as? String, "fitted(\(args[0]))")
            case "padding":
                #expect(ruler.padding((args[0] as! NSNumber).doubleValue) == item["out"] as? String, "padding(\(args[0]))")
            case "sameWidth":
                #expect(ruler.sameWidth(args[0] as! String, args[1] as! [String]) == item["out"] as? String, "sameWidth(\(args[0]))")
            default: Issue.record("unknown")
            }
        }
    }
}

struct FacesTests {
    @Test func everyCardFaceIsTheSameAsThePythonPlugins() throws {
        for item in try Fixtures.list("faces.json") {
            let label = item["label"] as! String
            let shared = Shared(log: PluginLog(path: "/dev/null"),
                                pictures: Pictures { kind, text in Data("\(kind):\(text)".utf8) })
            for (key, value) in item["settings"] as! [String: Any] {
                let setting = try #require(SettingKey(rawValue: key))
                shared.settings.set(setting, try #require(setting.parse(value)))
            }
            shared.queueWaiting = (item["queue"] as! NSNumber).intValue
            let name = item["name"] as! String
            let download = Download("/Users/someone/Downloads/\(name).part", shared: shared)
            download.startedAt = 1000
            let fields = item["fields"] as! [String: Any]
            for (key, value) in fields {
                switch key {
                case "samples": download.samples = (value as! [[NSNumber]]).map { ($0[0].doubleValue, $0[1].intValue) }
                case "total_size": download.totalSize = (value as! NSNumber).intValue
                case "line_word": download.lineWord = value as? String
                case "line_from": download.lineFrom = (value as! NSNumber).doubleValue
                case "resolved_at": download.resolvedAt = (value as! NSNumber).doubleValue
                case "succeeded": download.succeeded = (value as! NSNumber).boolValue
                case "resolved_reason": download.resolvedReason = value as! String
                default: Issue.record("\(label): unknown field \(key)")
                }
            }
            let args = item["args"] as! [String: Any]
            let now = (item["now"] as! NSNumber).doubleValue
            let numeric = item["numeric"] as! String
            let faces = Faces(shared)
            let got: JSON
            switch item["call"] as! String {
            case "in_progress": got = faces.inProgress(download, numeric, stalled: args["stalled"] as? Bool ?? false, now: now)
            case "done": got = faces.done(download, numeric, now: now)
            case "summary": got = faces.summary(download, count: (args["count"] as! NSNumber).intValue)
            case "canceled": got = faces.canceled(download, reason: args["reason"] as! String, now: now)
            case "paused":
                got = faces.paused(download, numeric, withButton: args["button"] as? Bool ?? true,
                                   word: args["word"] as? String ?? "Paused", now: now)
            case "failed": got = faces.failed(download, numeric, withButton: args["button"] as? Bool ?? true, now: now)
            default: Issue.record("unknown"); continue
            }
            #expect(got.text == item["out"] as! String, "\(label)")
            let after = item["after"] as! [String: Any]
            #expect(same(download.textDue, after["text_due"]), "\(label): when its text changes")
            #expect(download.linePhase == after["line_phase"] as! String, "\(label): its line")
            #expect(describe(download.lineWord) == describe(after["line_word"]), "\(label): its line's word")
            #expect(same(download.eta, after["eta"]), "\(label): the time left estimated")
            #expect(same(download.timeTickAt, after["time_tick_at"]), "\(label): the next second")
        }
    }
}

struct TimeLeftTests {
    @Test func theTimeLeftFollowsTheReadingsAsThePythonPluginsDoes() throws {
        for item in try Fixtures.list("timeleft.json") {
            let shared = Shared(log: PluginLog(path: "/dev/null"))
            let download = Download("/D/run.Ab3_Xy9Q.bin.part", shared: shared)
            download.totalSize = (item["total"] as! NSNumber).intValue
            let window = (item["window"] as! NSNumber).intValue
            let readings = item["readings"] as! [[NSNumber]]
            let out = item["out"] as! [[Any]]
            for (index, reading) in readings.enumerated() {
                download.samples.append((reading[0].doubleValue, reading[1].intValue))
                if download.samples.count > window { download.samples.removeFirst() }
                let left = download.timeLeft(reading[0].doubleValue + 0.1)
                #expect(same(left, out[index][0]), "\(item["label"]!), reading \(index)")
                #expect(same(download.timeTickAt, out[index][1]), "\(item["label"]!), reading \(index): next second")
            }
        }
    }
}
