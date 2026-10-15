// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The stand-ins the end-to-end tests drive the plugin with: the same ones
/// the Python plugin's tests use (shorter timings, the browser's answers,
/// you away or not, pictures that are only their names). They exist only
/// in a build made for those tests (`swift build -Xswiftc -DFD_TEST_HOOKS`):
/// the plugin itself has none of this.
public enum TestHooks {
    public static func apply(to shared: Shared) {
        #if FD_TEST_HOOKS
        guard let path = ProcessInfo.processInfo.environment["FIREFOX_DOWNLOADS_TEST_CONTROL"] else { return }
        let control = TestControl(path: path)
        // As in the Python tests: no macOS framework, no libproc.
        shared.ruler = .unmeasured()
        shared.pictures = Pictures { kind, text in Data("\(kind):\(text)".utf8) }
        shared.mac.screenLocked = { nil }
        shared.mac.secondsSinceInput = { nil }
        control.applyTunables(to: shared)
        shared.settings.refreshSeconds = { [unowned shared] in
            control.applyTunables(to: shared)
            return shared.t.settingsRefreshSeconds
        }
        let realPid = shared.mac.profilePid, realInUse = shared.mac.profileInUse, realScan = shared.mac.partFiles
        shared.mac.profilePid = { profile in
            control.applyTunables(to: shared)
            switch control.value("profile_pid") {
            case let number as NSNumber: return number.int32Value
            case is NSNull: return nil
            default: return realPid(profile)
            }
        }
        shared.mac.profileInUse = { profile in
            switch control.value("profile_in_use") {
            case let number as NSNumber: return number.boolValue
            case is NSNull: return nil
            default: return realInUse(profile)
            }
        }
        shared.mac.processHasOpen = { _, path in
            guard Paths.exists(path) else { return nil }
            var answer = control.value("has_open")
            if let files = control.value("has_open_files") as? [String: Any], let own = files[Paths.name(path)] {
                answer = own
            }
            guard let answer, !(answer is NSNull) else { return nil }
            return (answer as? NSNumber)?.boolValue
        }
        shared.mac.wallClock = { wallClock() + ((control.value("wall_offset") as? NSNumber)?.doubleValue ?? 0) }
        shared.mac.away = { (control.value("away") as? NSNumber)?.boolValue ?? false }
        shared.mac.partFiles = { folder in
            control.applyTunables(to: shared)
            if control.takeFailedScan() { return [] }
            return realScan(folder)
        }
        shared.presentSecondsOverride = { kind in
            if let seconds = control.value("present") as? NSNumber { return seconds.intValue }
            return shared.presentSecondsReal(kind)
        }
        shared.keepSecondsOverride = { download in
            if let keep = control.value("keep") as? [String: Any] {
                return ((download.succeeded ? keep["done"] : keep["canceled"]) as? NSNumber)?.doubleValue ?? 0
            }
            return shared.keepSecondsReal(download)
        }
        #endif
    }

    public static func apply(to plugin: Plugin) {
        #if FD_TEST_HOOKS
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["FIREFOX_DOWNLOADS_TEST_CONTROL"] else { return }
        if let tool = TestControl(path: path).value("open_tool") as? String {
            plugin.openTool = tool
        }
        // No compiled script, no pointer, no Accessibility: the browser's
        // side of the buttons is the test's stand-ins, asked through its socket.
        plugin.precompile = nil
        let browser = environment["FIREFOX_DOWNLOADS_TEST_BROWSER"] ?? ""
        plugin.buttons = ButtonWork(requests: .standIns(socket: browser), desk: .none, progress: BrowserProgress())
        #endif
    }
}

#if FD_TEST_HOOKS
extension BrowserRequests {
    /// The test's stand-ins for the browser, asked through its socket: one
    /// line of JSON there (the function and its arguments), one back (the result).
    static func standIns(socket path: String) -> BrowserRequests {
        @Sendable func ask(_ function: String, _ arguments: [String?], resume: Bool = false) -> ScriptResult {
            let request: [String: Any] = ["fn": function, "args": arguments.map { $0 as Any? ?? NSNull() }, "resume": resume]
            guard let data = try? JSONSerialization.data(withJSONObject: request) else { return ScriptResult("error") }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return ScriptResult("unavailable", "no test socket") }
            defer { close(descriptor) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8).prefix($0.count - 1)) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { return ScriptResult("unavailable", "no test socket") }
            let line = data + Data("\n".utf8)
            _ = line.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
            var answer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let got = recv(descriptor, &chunk, chunk.count, 0)
                if got <= 0 { break }
                answer.append(contentsOf: chunk.prefix(got))
                if answer.last == 10 { break }
            }
            guard let reply = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
                  let parts = reply["result"] as? [String], parts.count >= 6 else { return ScriptResult("error", "no answer") }
            return ScriptResult(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
        }
        return BrowserRequests(
            cancel: { ask("request_browser_cancel", [$0, $1, $2, $3]) },
            resume: { name, fallback, proc, button, _ in ask("request_browser_resume", [name, fallback, proc, button], resume: true) },
            retry: { ask("request_browser_retry", [$0, $1, $2, $3]) },
            restart: { ask("request_browser_restart", [$0, $1, $2, $3]) },
            locate: { ask("request_browser_locate", [$0, $1]) })
    }
}
#endif

#if FD_TEST_HOOKS
/// The test's control file, read again whenever it changes.
final class TestControl: @unchecked Sendable {
    private let path: String
    private var stamp: (Int, Int) = (-1, -1)
    private var values: [String: Any] = [:]
    private var failedScansTaken = 0
    private var appliedTunables: [String: Any] = [:]

    init(path: String) {
        self.path = path
    }

    private func reload() {
        var info = stat()
        guard stat(path, &info) == 0 else { return }
        let now = (Int(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int(info.st_mtimespec.tv_nsec), Int(info.st_size))
        guard now != stamp, let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        stamp = now
        values = json
    }

    func value(_ key: String) -> Any? {
        reload()
        return values[key]
    }

    /// Whether this folder listing is one of those that fail.
    func takeFailedScan() -> Bool {
        let failing = (value("failed_scans") as? NSNumber)?.intValue ?? 0
        if failedScansTaken < failing {
            failedScansTaken += 1
            return true
        }
        return false
    }

    /// The Python plugin's names for the timings, and where each goes.
    func applyTunables(to shared: Shared) {
        guard let given = value("tunables") as? [String: Any] else { return }
        if NSDictionary(dictionary: given).isEqual(to: appliedTunables) { return }
        appliedTunables = given
        var t = shared.t
        for (name, raw) in given {
            guard let number = raw as? NSNumber else { continue }
            let d = number.doubleValue, i = number.intValue
            switch name {
            case "POLL_INTERVAL": t.pollInterval = d
            case "ACTION_POLL_INTERVAL": t.actionPollInterval = d
            case "MIN_SAMPLE_GAP": t.minSampleGap = d
            case "SPEED_WINDOW": t.speedWindow = i
            case "VANISH_GRACE_TICKS": t.vanishGraceTicks = i
            case "EMPTY_FILE_TICKS": t.emptyFileTicks = i
            case "NOTICE_SECONDS": t.noticeSeconds = d
            case "PEEK_MARGIN_SECONDS": t.peekMarginSeconds = i
            case "MAX_PRESENT_SECONDS": t.maxPresentSeconds = i
            case "DETAILS_TURN_SECONDS": t.detailsTurnSeconds = d
            case "SCROLL_HOLD_SECONDS": t.scrollHoldSeconds = d
            case "FIT_CHARS": t.fitChars = i
            case "MAX_TEXT_CHARS": t.maxTextChars = i
            case "ICON_DELAY_SECONDS": t.iconDelaySeconds = d
            case "EARLY_STOP_CONFIRM": t.earlyStopConfirm = d
            case "EARLY_STOP_CONFIRM_NO_TOTAL": t.earlyStopConfirmNoTotal = d
            case "EARLY_PEEK_DELAY": t.earlyPeekDelay = d
            case "CANCEL_GIVEUP_SECONDS": t.cancelGiveUpSeconds = d
            case "RESTART_GIVEUP_SECONDS": t.restartGiveUpSeconds = d
            case "STALL_SECONDS": t.stallSeconds = d
            case "CLOSED_CHECK_AFTER": t.closedCheckAfter = d
            case "WAKE_GRACE_SECONDS": t.wakeGraceSeconds = d
            case "SLEEP_GAP_SECONDS": t.sleepGapSeconds = d
            case "WAS_DOWNLOADING_SECONDS": t.wasDownloadingSeconds = d
            case "REPLAY_GAP_SECONDS": t.replayGapSeconds = d
            case "HOLD_MAX_SECONDS": t.holdMaxSeconds = d
            case "NOTCH_PLACES": t.notchPlaces = i
            case "PLACE_GAP_SECONDS": t.placeGapSeconds = d
            case "PEEK_AFTER_CREATE": t.peekAfterCreate = d
            case "SPOT_MARGIN_SECONDS": t.spotMarginSeconds = d
            case "SPOT_GAP_SECONDS": t.spotGapSeconds = d
            case "HAND_BACK_SECONDS": t.handBackSeconds = d
            case "TIME_LEFT_SPAN": t.timeLeftSpan = d
            case "SETTINGS_REFRESH_SECONDS": t.settingsRefreshSeconds = d
            case "STOP_SCRIPT_TIMEOUT": t.stopScriptTimeout = d
            case "TOTAL_WAIT_SECONDS": t.totalWaitSeconds = d
            case "DIR_REFRESH_SECONDS": t.dirRefreshSeconds = d
            case "WARMUP_MIN_GAP": t.warmupMinGap = d
            case "FOCUS_SETTLE_SECONDS": t.focusSettleSeconds = d
            case "MENU_GONE_SECONDS": t.menuGoneSeconds = d
            case "PANEL_GONE_SECONDS": t.panelGoneSeconds = d
            case "PANEL_ABSENT_SECONDS": t.panelAbsentSeconds = d
            case "BLINK_SECONDS": t.blinkSeconds = d
            case "QUIET_SECONDS": t.quietSeconds = d
            case "CLEAR_BUDGET_SECONDS": t.clearBudgetSeconds = d
            default: break
            }
        }
        shared.t = t
        shared.ruler.fitChars = t.fitChars
    }
}
#endif
