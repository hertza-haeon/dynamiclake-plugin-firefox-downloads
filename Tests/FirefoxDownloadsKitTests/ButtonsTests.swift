// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import Testing
@testable import FirefoxDownloadsKit

private func results(_ value: Any?) -> [String] {
    (value as? [Any] ?? []).map { "\($0)" }
}

private func tuple(_ result: ScriptResult) -> [String] {
    [result.outcome, result.trace, result.browser, result.position, result.frame, result.pid]
}

struct ButtonFixtureTests {
    let fixture: [String: Any]

    init() throws {
        fixture = try Fixtures.object("buttons.json")
    }

    @Test func theScriptsAreTheVerySameAsThePythonPlugins() {
        #expect(Scripts.fast == fixture["fast_script"] as? String)
        #expect(Scripts.legacy == fixture["legacy_script"] as? String)
        #expect(Scripts.resumeLabels == fixture["resume_labels"] as? [String])
        #expect(Scripts.menuMarkers == fixture["menu_markers"] as? [String])
    }

    @Test func whatTheScriptsSayIsReadAsThePythonPluginReadsIt() {
        for item in fixture["parse"] as! [[String: Any]] {
            #expect(tuple(ScriptRunner.parseOutput(item["in"] as! String)) == results(item["out"]), "\(item["in"]!)")
        }
        for item in fixture["breadcrumbs"] as! [[String: Any]] {
            let (rest, frame, pid) = ScriptRunner.menuBreadcrumb(item["in"] as! String)
            #expect([rest, frame, pid] == results(item["out"]), "\(item["in"]!)")
        }
        for item in fixture["permission"] as! [[String: Any]] {
            #expect(ScriptRunner.permissionOutcome(item["in"] as! String) == item["out"] as? String, "\(item["in"]!)")
        }
    }

    @Test func namesAndHintsAreGivenToTheScriptAsThePythonPluginGivesThem() {
        for item in fixture["name_forms"] as! [[String: Any]] {
            let got = BrowserRequests.nameForms(item["in"] as! String).map { Array($0.unicodeScalars) }
            let expected = (item["out"] as! [String]).map { Array($0.unicodeScalars) }
            #expect(got == expected, "\(item["in"]!)")
        }
        for item in fixture["hints"] as! [[String: Any]] {
            let given = item["in"] as! [Any]
            #expect(BrowserRequests.hintArgs(given[0] as? String, given[1] as? String) == item["out"] as! [String])
        }
    }

    @Test func theMenuIsLookedForWhereThePythonPluginLooks() {
        for item in fixture["probes"] as! [[String: Any]] {
            let f = (item["frame"] as! [NSNumber]).map(\.doubleValue)
            let clicked = (item["clicked"] as? [NSNumber]).map { CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue) }
            let got = RowMenu.probePoints((f[0], f[1], f[2], f[3]), clicked: clicked).map { [$0.0, $0.1] }
            #expect(got == (item["out"] as! [[NSNumber]]).map { $0.map(\.doubleValue) })
        }
        for item in fixture["labels"] as! [[String: Any]] {
            let text = item["in"] as! String
            #expect(RowMenu.isResumeLabel(text) == (item["resume"] as! Bool), "Resume? \(text)")
            #expect(RowMenu.isMenuMarker(text) == (item["marker"] as! Bool), "marker? \(text)")
        }
    }

    @Test func theBrowsersWindowsAreToldApartAsThePythonPluginTellsThem() {
        for item in fixture["overlays"] as! [[String: Any]] {
            let windows = (item["windows"] as! [[NSNumber]]).map {
                ScreenWindow(level: $0[0].intValue, x: $0[1].doubleValue, y: $0[2].doubleValue, width: $0[3].doubleValue,
                             height: $0[4].doubleValue)
            }
            var desk = Desk.none
            desk.windowsOnScreen = { _ in windows }
            let focus = Focus(ax: Accessibility.shared, desk: desk, t: Tunables())
            let row = (x: 900.0, y: 120.0, w: 380.0, h: 52.0)
            let got = focus.browserOverlays(4242, row)
            #expect(got.map { [$0.0, $0.1, $0.2] } == (item["out"] as! [Bool]), "\(windows)")
            #expect(focus.floatingOverRow(4242, row) == item["floating"] as! String)
        }
    }
}

/// On the Mac itself: what the buttons ask of macOS, without any browser.
struct ButtonsOnTheMacTests {
    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fd-buttons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func theScriptIsCompiledOnceCheckedBeforeEachUseAndNeverRunWhenChanged() throws {
        let logFolder = try folder()
        defer { try? FileManager.default.removeItem(atPath: logFolder) }
        let log = PluginLog(path: logFolder + "/plugin.log")
        let runner = ScriptRunner(log: log, timeout: { 20 })
        runner.cacheFolder = logFolder + "/Caches/FirefoxDownloads"
        // A compiled script left by an older version is removed, never run.
        try FileManager.default.createDirectory(atPath: runner.cacheFolder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: runner.cacheFolder + "/stop-abc.scpt"))
        let compiled = try #require(runner.checkedFastScript())
        #expect(!FileManager.default.fileExists(atPath: runner.cacheFolder))
        #expect(compiled.hasPrefix(NSTemporaryDirectory()) && compiled.hasSuffix("/stop.scpt"))
        let attributes = try FileManager.default.attributesOfItem(atPath: compiled)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
        #expect(runner.checkedFastScript() == compiled)                  // the same file, checked again
        // Gone (the system clears temporary folders): built again, once.
        ScriptRunner.removeCompiled(compiled)
        let again = try #require(runner.checkedFastScript())
        #expect(again != compiled && FileManager.default.fileExists(atPath: again))
        // Changed: never run; the script runs from its text from then on.
        chmod(again, 0o600)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: again))
        #expect(runner.checkedFastScript() == nil)
        #expect(runner.checkedFastScript() == nil)
        let text = try String(contentsOfFile: logFolder + "/plugin.log", encoding: .utf8)
        #expect(text.contains("the button script is compiled for this run; the compiled file is checked before every use"))
        #expect(text.contains("isn't the file this plugin built (changed since): it isn't run"))
        ScriptRunner.removeCompiled(again)
    }

    @Test func aScriptsAnswerAndItsBreadcrumbsAreReadFromOsascript() {
        let runner = ScriptRunner(log: PluginLog(path: "/dev/null"), timeout: { 5 })
        let answered = runner.runScript(["/usr/bin/osascript", "-e", #"log "menu-at|900,120,380,52|4242""#,
                                         "-e", #"return "show-error|the menu went|librewolf|1.1.2.4""#])
        #expect(tuple(answered) == ["show-error", "the menu went", "librewolf", "1.1.2.4", "900,120,380,52", "4242"])
        let broken = runner.runScript(["/usr/bin/osascript", "-e", "error \"assistive-access-denied: no\""])
        #expect(broken.outcome == "accessibility-not-granted")
        let slow = ScriptRunner(log: PluginLog(path: "/dev/null"), timeout: { 0.5 })
            .runScript(["/usr/bin/osascript", "-e", "delay 3"])
        #expect(slow.outcome == "timeout" && slow.trace == "no answer within 0.5 s")
    }

    @Test func aFileAnotherProcessHasOpenIsToldApart() throws {
        let place = try folder()
        defer { try? FileManager.default.removeItem(atPath: place) }
        let held = place + "/held.part", other = place + "/other.part"
        try Data("x".utf8).write(to: URL(fileURLWithPath: held))
        try Data("y".utf8).write(to: URL(fileURLWithPath: other))
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", held]
        tail.standardOutput = FileHandle.nullDevice
        try tail.run()
        defer { tail.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(ProfileLock.processHasOpen(tail.processIdentifier, held) == true)
        #expect(ProfileLock.processHasOpen(tail.processIdentifier, other) == false)
        #expect(ProfileLock.processHasOpen(tail.processIdentifier, place + "/gone.part") == nil)
    }

    @Test func bigMessagesReachASlowReaderWhole() throws {
        var ends: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        let lake = DynamicLake(descriptor: ends[0])
        let reader = ends[1]
        let picture = String(repeating: "A", count: 60_000)
        final class Received: @unchecked Sendable { var count = 0; var whole = true }
        let received = Received()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 7_000)
            while received.count < 40 {
                Thread.sleep(forTimeInterval: 0.002)          // a slow reader
                let got = recv(reader, &chunk, chunk.count, 0)
                if got <= 0 { break }
                buffer += chunk.prefix(got)
                while buffer.count >= 4 {
                    let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                    guard buffer.count >= 4 + length else { break }
                    let frame = Data(buffer[4..<(4 + length)])
                    buffer.removeFirst(4 + length)
                    let message = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
                    if message?["activityID"] as? String != "dl-\(received.count)" { received.whole = false }
                    received.count += 1
                }
            }
            done.signal()
        }
        for index in 0..<40 {
            try lake.send(.obj(["schemaVersion": .int(1), "type": .string("update"), "activityID": .string("dl-\(index)"),
                                "surfaces": .obj(["picture": .string(picture)])]))
        }
        #expect(done.wait(timeout: .now() + 20) == .success)
        #expect(received.count == 40 && received.whole)
        close(reader)
    }
}
