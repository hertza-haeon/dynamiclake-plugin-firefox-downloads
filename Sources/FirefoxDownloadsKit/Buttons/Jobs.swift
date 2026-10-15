// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// The browser's side of the buttons: one request per button, each run by
/// the button script (Resume also chooses in the row's menu). Tests put
/// stand-ins in their place.
public struct BrowserRequests: Sendable {
    public typealias Request = @Sendable (_ name: String, _ fallback: String?, _ proc: String?, _ button: String?) -> ScriptResult
    /// Stop: press the row's Cancel button.
    public var cancel: Request
    /// Resume: see `resume(...)`. The last argument tells where the browser
    /// put the pointer to open the row's menu, when the pointer guard saw it.
    public var resume: @Sendable (_ name: String, _ fallback: String?, _ proc: String?, _ button: String?,
                                  _ clickedAt: @escaping @Sendable () -> CGPoint?) -> ScriptResult
    /// Retry: press the failed row's Retry button.
    public var retry: Request
    /// Retry on a canceled card: press the Retry button of the row showing
    /// Canceled (or Failed, for a download the browser gave up on and
    /// whose partial file it deleted). The browser starts it over.
    public var restart: Request
    /// Warm-up: find the browser's toolbar Downloads button and press
    /// nothing. This starts System Events and the browser's accessibility
    /// support ahead of time, so the first button press doesn't pay for it.
    public var locate: @Sendable (_ proc: String?, _ button: String?) -> ScriptResult

    /// The file name as stored on disk, plus its composed (NFC) and
    /// decomposed (NFD) Unicode forms when those differ, so an accented
    /// name matches the panel however it was stored.
    static func nameForms(_ filename: String) -> [String] {
        var forms = [filename]
        for variant in [filename.precomposedStringWithCanonicalMapping, filename.decomposedStringWithCanonicalMapping]
            where !forms.contains(where: { Array($0.unicodeScalars) == Array(variant.unicodeScalars) }) {
            forms.append(variant)
        }
        return forms
    }

    static func hintArgs(_ proc: String?, _ button: String?) -> [String] {
        guard let proc, !proc.isEmpty else { return [] }
        var args = ["proc:" + proc]
        if let button, !button.isEmpty { args.append("btn:" + button) }   // only meaningful for that browser
        return args
    }

    /// Run the script for one download: mode "cancel" (Stop), "resume",
    /// "retry" or "restart". `name` is the real name the panel shows;
    /// `fallback` (the name as found on disk) is also tried; `proc` and
    /// `button` are the browser to try first and where its toolbar button
    /// was last time (checked before use). Needs Accessibility permission.
    static func action(_ runner: ScriptRunner, _ mode: String, _ name: String, _ fallback: String?, _ proc: String?,
                       _ button: String?) -> ScriptResult {
        var names = nameForms(name)
        if let fallback, Array(fallback.unicodeScalars) != Array(name.unicodeScalars) {
            for form in nameForms(fallback) where !names.contains(where: { Array($0.unicodeScalars) == Array(form.unicodeScalars) }) {
                names.append(form)
            }
        }
        return runner.runAxScript(["mode:" + mode] + names.map { "name:" + $0 } + hintArgs(proc, button),
                                  fallbackAfterRun: mode != "resume")
    }

    /// Resume: the script shows the paused row's right-click menu (and
    /// checks it opened for that row); the plugin then chooses Resume in it
    /// -- see `RowMenu.choose`. Whenever a menu may have been shown and the
    /// script didn't confirm it's this row's ("menu-changed", "show-error",
    /// or a run cut short), the plugin only looks for it and closes it: a
    /// menu is never left open without saying so.
    static func resume(_ runner: ScriptRunner, _ desk: Desk, _ name: String, _ fallback: String?, _ proc: String?,
                       _ button: String?, clickedAt: @escaping @Sendable () -> CGPoint?) -> ScriptResult {
        guard let ax = desk.accessibility() else {
            return ScriptResult("unavailable", "the macOS Accessibility API couldn't be loaded")
        }
        if !ax.trusted() {
            return ScriptResult("accessibility-not-granted", "not trusted for Accessibility (checked before showing a menu)")
        }
        var result = action(runner, "resume", name, fallback, proc, button)
        let closingOutcome = result.outcome == "show-error" ? "no-menu" : result.outcome   // what's reported after only closing
        guard let frame = parseFrame(result.frame), let pid = Int32(result.pid), result.pid.allSatisfy(\.isNumber) else {
            if result.outcome == "menu-shown" || result.outcome == "show-error" {
                return ScriptResult("no-menu", "\(result.trace) the script didn't say where the menu is;", result.browser,
                                    result.position, result.frame, result.pid)
            }
            result.outcome = closingOutcome
            return result
        }
        let press = result.outcome == "menu-shown"
        var (menuOutcome, menuTrace) = RowMenu.choose(ax, pid: pid, frame: frame, press: press, clickedAt: clickedAt)
        if !press && menuOutcome != "menu-open" {
            menuOutcome = closingOutcome
        }
        return ScriptResult(menuOutcome, "\(result.trace) \(menuTrace)".trimmingCharacters(in: .whitespaces), result.browser,
                            result.position, result.frame, result.pid)
    }

    /// The real requests: the scripts, on the real browser.
    public static func real(runner: ScriptRunner, desk: Desk) -> BrowserRequests {
        BrowserRequests(
            cancel: { action(runner, "cancel", $0, $1, $2, $3) },
            resume: { resume(runner, desk, $0, $1, $2, $3, clickedAt: $4) },
            retry: { action(runner, "retry", $0, $1, $2, $3) },
            restart: { action(runner, "restart", $0, $1, $2, $3) },
            locate: { runner.runAxScript(["mode:locate"] + hintArgs($0, $1), allowFallback: false) })
    }
}

/// One button's work on the browser (kind "stop", "resume", "retry",
/// "restart", or the warm-up, "locate"), on a thread of its own, so that
/// the notch keeps updating while it works.
final class ActionJob: @unchecked Sendable {
    let kind: String
    private let lock = NSLock()
    private var result: ScriptResult?
    private var took = 0.0
    private let started = monotonic()

    init(kind: String) {
        self.kind = kind
    }

    /// Called once, from the job's thread, when it's over.
    func finish(_ result: ScriptResult) {
        var result = result
        if result.outcome.isEmpty { result.outcome = "error" }
        let seconds = monotonic() - started
        lock.withLock {
            took = seconds
            self.result = result      // (set last: `done` means the rest is ready)
        }
    }

    var done: Bool { lock.withLock { result != nil } }
    var outcome: String { lock.withLock { result?.outcome ?? "" } }
    var trace: String { lock.withLock { result?.trace ?? "" } }
    var browser: String { lock.withLock { result?.browser ?? "" } }
    var position: String { lock.withLock { result?.position ?? "" } }
    var seconds: Double { lock.withLock { took } }
}

/// Runs the buttons' work: one browser automation at a time.
public final class ButtonWork: @unchecked Sendable {
    let requests: BrowserRequests
    let desk: Desk
    let progress: BrowserProgress?
    /// One browser automation at a time.
    private let axLock = NSLock()

    public init(requests: BrowserRequests, desk: Desk, progress: BrowserProgress?) {
        self.requests = requests
        self.desk = desk
        self.progress = progress
    }

    /// Runs one button's request. Waits for a warm-up that is still running.
    func startAction(_ kind: String, name: String, fallback: String, finalPaths: [String], proc: String?, button: String?,
                     returnFocus: Bool, tunables: Tunables) -> ActionJob {
        let job = ActionJob(kind: kind)
        Thread.detachNewThread { [self] in
            // Stop: without any permission first (see `BrowserProgress`).
            if kind == "stop", let progress, progress.cancel(finalPaths) {
                job.finish(ScriptResult("cancel-sent", "canceled through the download's announcement to macOS, no permission needed;"))
                return
            }
            axLock.lock()
            defer { axLock.unlock() }
            var result: ScriptResult
            switch kind {
            case "resume":
                let ax = returnFocus ? desk.accessibility() : nil
                let (front, frontNote) = ax != nil && ax!.trusted() ? Focus.frontAppPid(ax, desk: desk) : (nil, "")
                let presses = desk.pressCount()
                let guardian = PointerGuard(desk: desk)
                guardian.start()
                result = requests.resume(name, fallback, proc, button, { guardian.restoredFrom })
                guardian.stop()
                if guardian.restoredFrom != nil {
                    result = result.noting("pointer put back at once")
                } else {
                    result = putPointerBack(result, before: guardian.before, desk: desk)
                }
                if let ax {
                    result.trace = "\(result.trace) \(frontNote)".trimmingCharacters(in: .whitespaces)
                    result = Focus(ax: ax, desk: desk, t: tunables).clearBrowserFromView(result, front: front, pressesBefore: presses)
                }
            case "retry": result = requests.retry(name, fallback, proc, button)
            case "restart": result = requests.restart(name, fallback, proc, button)
            default: result = requests.cancel(name, fallback, proc, button)
            }
            job.finish(result)
        }
        return job
    }

    /// Runs the read-only warm-up. Skips itself if a button's script is running.
    func startWarmup(proc: String?, button: String?) -> ActionJob {
        let job = ActionJob(kind: "locate")
        Thread.detachNewThread { [self] in
            var result = ScriptResult("skipped", "a button's script was already running")
            if axLock.try() {
                result = requests.locate(proc, button)
                axLock.unlock()
            }
            job.finish(result)
        }
        return job
    }
}
