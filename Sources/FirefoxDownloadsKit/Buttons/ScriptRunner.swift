// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation

/// What a button's script came back with: (outcome, trace, browser
/// process, toolbar button position, row frame, process id).
public struct ScriptResult: Equatable, Sendable {
    public var outcome: String
    public var trace = ""
    public var browser = ""
    public var position = ""
    public var frame = ""
    public var pid = ""

    public init(_ outcome: String, _ trace: String = "", _ browser: String = "", _ position: String = "",
                _ frame: String = "", _ pid: String = "") {
        self.outcome = outcome
        self.trace = trace
        self.browser = browser
        self.position = position
        self.frame = frame
        self.pid = pid
    }

    /// The same, with a note added to its trace ("... note;").
    func noting(_ note: String) -> ScriptResult {
        var result = self
        result.trace = "\(trace) \(note);".trimmingCharacters(in: .whitespaces)
        return result
    }
}

/// Runs the button scripts. The main one is compiled (osacompile) at each
/// start, into a temporary folder of its own, so that a press skips the
/// compile step; the compiled file is checked against its fingerprint
/// before every use (`checkedFastScript`).
public final class ScriptRunner: @unchecked Sendable {
    /// The system's own programs, by their full path: never whatever carries
    /// the same name in a folder that comes earlier in PATH.
    static let osascript = "/usr/bin/osascript"
    static let osacompile = "/usr/bin/osacompile"
    /// Outcomes that mean "the script itself broke", so the fallback script runs.
    static let failures: Set<String> = ["script-error", "syntax-error", "error"]

    private let lock = NSLock()
    private var compiled: String?          // the compiled script, built by this process
    private var fingerprint: String?       // its SHA-256, as this process built it
    private var untrusted = false          // it was found changed: the script runs from its text
    private var compileFailed = false      // osacompile could not build it
    private(set) var fastBroken = false    // the main script failed: use the fallback
    private var fastFailures = 0
    private var cacheCleared = false
    private let log: PluginLog
    /// Seconds before a script run is abandoned.
    var timeout: () -> Double

    public init(log: PluginLog, timeout: @escaping () -> Double) {
        self.log = log
        self.timeout = timeout
    }

    /// The folder where a compiled script was kept before 1.1.3.
    var cacheFolder = Paths.join(homeFolder(), "Library/Caches/FirefoxDownloads")

    /// A compiled script lying in ~/Library/Caches/FirefoxDownloads is not
    /// this process's own: it is never run, and it is removed (the files
    /// named like one, then the folder if that leaves it empty). A folder
    /// that is a link to another place is left alone.
    static func clearScriptCache(_ folder: String) {
        var info = stat()
        if lstat(folder, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasPrefix("stop-")
            && (name.hasSuffix(".scpt") || name.hasSuffix(".applescript")) {
            unlink(Paths.join(folder, name))
        }
        rmdir(folder)
    }

    /// The SHA-256 of a file's bytes; nothing when it can't be read.
    static func fingerprint(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Remove a compiled script and the folder made for it (nothing through
    /// a folder that has become a link to another place).
    static func removeCompiled(_ path: String) {
        let folder = Paths.parent(path)
        var info = stat()
        if lstat(folder, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK { return }
        unlink(path)
        rmdir(folder)
    }

    /// (compiled script, its fingerprint), or nothing: see `compiledFastScript`.
    /// Both are read in one go, under the lock.
    private func compiledFastScriptAndFingerprint() -> (String, String)? {
        lock.lock()
        defer { lock.unlock() }
        if compileFailed || fastBroken || untrusted { return nil }
        if let compiled, let fingerprint { return (compiled, fingerprint) }
        if !cacheCleared {
            cacheCleared = true
            Self.clearScriptCache(cacheFolder)
        }
        var template = Array((NSTemporaryDirectory() + "FirefoxDownloads-XXXXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else {
            compileFailed = true
            log.write("compiling the Stop script failed (no temporary folder: errno \(errno)); running it uncompiled")
            return nil
        }
        let target = Paths.join(String(cString: made), "stop.scpt")
        // (the text goes in on standard input: no copy of it on disk)
        let run = Self.run([Self.osacompile, "-o", target], input: Scripts.fast, timeout: 60)
        var found: String?
        // Read-only before its fingerprint is taken: osascript writes a
        // script's properties back into a compiled file it can write to,
        // which would make every run change the file. (A file that can't be
        // made read-only isn't used: the script then runs from its text.)
        if run.status == 0 && chmod(target, 0o400) == 0 {
            found = Self.fingerprint(target)
        }
        guard let found else {
            let err = run.stderr.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            compileFailed = true
            if err.lowercased().contains("syntax error") { fastBroken = true }
            log.write("compiling the Stop script failed (\(err.isEmpty ? String(run.status) : err)); "
                + (fastBroken ? "using the fallback script" : "running it uncompiled"))
            Self.removeCompiled(target)
            return nil
        }
        compiled = target
        fingerprint = found
        compiledAtExit = target
        atexit {
            if let path = compiledAtExit { ScriptRunner.removeCompiled(path) }
        }
        log.write("the button script is compiled for this run; the compiled file is checked before every use")
        return (target, found)
    }

    /// Compile the button script, once for this run, and remember the
    /// compiled file's fingerprint: running a compiled script skips parsing
    /// it and loading System Events' dictionary on every press. It goes into
    /// a temporary folder made for this run alone (a name of its own each
    /// time, open to this user only), read-only: a compiled script from
    /// another run, or put there by another program, is never picked up.
    /// Nothing when it can't be compiled, or isn't to be trusted (the script
    /// then runs as text). Callers that run it use `checkedFastScript`.
    @discardableResult
    func compiledFastScript() -> String? {
        compiledFastScriptAndFingerprint()?.0
    }

    /// The compiled script, when it is still, byte for byte, the file this
    /// process built: its fingerprint is taken again right before every
    /// use. A file that has gone (the system clears temporary folders) is
    /// built again, once, in a new folder. A file that is there but
    /// different is never run: from then on the script runs from the
    /// plugin's own text, and the log says so. Nothing: run the text.
    func checkedFastScript() -> String? {
        for attempt in 1...2 {
            guard let (path, expected) = compiledFastScriptAndFingerprint() else { return nil }
            let found = Self.fingerprint(path)
            if found == expected { return path }
            let gone = found == nil && !Paths.lexists(path)
            lock.lock()
            if compiled != path {
                lock.unlock()
                continue                      // (another thread dealt with it meanwhile)
            }
            compiled = nil
            fingerprint = nil
            if gone { Self.removeCompiled(path) }    // (the folder it was in)
            if gone && attempt == 1 {
                lock.unlock()
                continue                      // gone: built again
            }
            if gone { compileFailed = true } else { untrusted = true }
            lock.unlock()
            if gone {
                log.write("the compiled button script keeps disappearing: the script runs from the plugin's own text from here on")
            } else {
                log.write("the compiled button script isn't the file this plugin built (changed since): it isn't run; "
                    + "the script runs from the plugin's own text from here on")
            }
            return nil
        }
        return nil
    }

    /// Compile the script on a thread of its own, so the first press
    /// doesn't wait for it.
    public func startPrecompile() {
        Thread.detachNewThread { [self] in
            compiledFastScript()
        }
    }

    // MARK: Running

    /// Recognise a missing permission. The scripts mark these errors
    /// ("assistive-access-denied:", "automation-denied:") so they are
    /// recognised whatever language macOS is set to.
    static func permissionOutcome(_ text: String) -> String? {
        let low = text.lowercased()
        if low.contains("automation-denied") || low.contains("not authorized") || low.contains("-1743") {
            return "automation-not-granted"
        }
        if low.contains("assistive-access-denied") || low.contains("assistive") || low.contains("not allowed")
            || low.contains("-25211") {
            return "accessibility-not-granted"
        }
        return nil
    }

    private static func words(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "outcome|trace|process|position|frame|pid" -> the result. For
    /// Resume, the frame ("x,y,w,h") is the row whose right-click menu was
    /// shown (the browser opens the menu, and puts the pointer, in its
    /// middle) and pid is the browser's process id. Shorter forms are
    /// accepted too.
    static func parseOutput(_ output: String) -> ScriptResult {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        var outcome = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if outcome.isEmpty { outcome = "error" }
        var trace = "", browser = "", position = "", spot = "", pid = ""
        let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 6 {
            trace = parts[1..<(parts.count - 4)].joined(separator: "|")
            browser = trimmed(parts[parts.count - 4])
            position = trimmed(parts[parts.count - 3])
            spot = trimmed(parts[parts.count - 2])
            pid = trimmed(parts[parts.count - 1])
        } else if parts.count == 5 {
            (trace, browser, position, spot) = (parts[1], trimmed(parts[2]), trimmed(parts[3]), trimmed(parts[4]))
        } else if parts.count == 4 {
            (trace, browser, position) = (parts[1], trimmed(parts[2]), trimmed(parts[3]))
        } else if parts.count == 3 {
            (trace, browser) = (parts[1], trimmed(parts[2]))
        } else {
            trace = parts.dropFirst().joined(separator: "|")
        }
        trace = words(trace)
        if outcome == "script-error" {
            outcome = permissionOutcome(trace) ?? outcome
        }
        if position.wholeMatch(of: #/\d+\.\d+\.\d+\.\d+/#) == nil { position = "" }
        if spot.wholeMatch(of: #/-?\d+,-?\d+,\d+,\d+/#) == nil { spot = "" }
        if pid.wholeMatch(of: #/\d+/#) == nil { pid = "" }
        return ScriptResult(outcome, trace, browser, position, spot, pid)
    }

    /// (stderr without it, frame, pid). Right before showing a row's menu,
    /// the scripts log "menu-at|x,y,w,h|pid" (to stderr), so that a run
    /// that is cut short or breaks still tells where a menu may be open.
    /// (osascript also says "couldn't save changes to script" at every run
    /// of the read-only compiled script: it is no part of what went wrong.)
    static func menuBreadcrumb(_ stderr: String) -> (String, String, String) {
        var frame = "", pid = "", kept: [String] = []
        for line in stderr.components(separatedBy: "\n") {
            let bare = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if let match = bare.wholeMatch(of: #/menu-at\|(-?\d+,-?\d+,\d+,\d+)\|(\d+)[ \t]*/#) {
                frame = String(match.1)
                pid = String(match.2)
                kept.append("")
                continue
            }
            if line.firstMatch(of: #/^\S*osascript: couldn't save changes to script .*$/#) != nil {
                continue                          // (the line and its line break)
            }
            kept.append(line)
        }
        return (kept.joined(separator: "\n"), frame, pid)
    }

    /// A program's run: exit status (-1: it couldn't start, -2: no answer
    /// in time), standard output and error.
    struct Run {
        var status: Int32
        var stdout: String
        var stderr: String
        var error: String = ""
    }

    /// Runs a program, its input on standard input, and waits for it (at
    /// most `timeout` seconds, then it is killed).
    static func run(_ command: [String], input: String? = nil, timeout: Double) -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let feed = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : feed
        do {
            try process.run()
        } catch {
            return Run(status: -1, stdout: "", stderr: "", error: error.localizedDescription)
        }
        // (read on threads of their own, so that a full pipe never stalls it)
        let collected = Collected()
        let group = DispatchGroup()
        for (pipe, isError) in [(out, false), (err, true)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.set(String(decoding: data, as: UTF8.self), error: isError)
                group.leave()
            }
        }
        let deadline = monotonic() + timeout
        if let input {
            // Written on the side, within the time allowed: a program that
            // stops reading can neither hold this up nor end the plugin
            // (writing to a closed pipe is an error here, not a signal).
            let writer = feed.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            group.enter()
            DispatchQueue.global().async {
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
                group.leave()
            }
        }
        while process.isRunning && monotonic() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        group.wait()
        return Run(status: timedOut ? -2 : process.terminationStatus, stdout: collected.stdout, stderr: collected.stderr)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var stdout = ""
        private(set) var stderr = ""

        func set(_ text: String, error: Bool) {
            lock.withLock {
                if error { stderr = text } else { stdout = text }
            }
        }
    }

    func runScript(_ command: [String]) -> ScriptResult {
        let seconds = timeout()
        let run = Self.run(command, timeout: seconds)
        if run.status == -2 {
            let (_, frame, pid) = Self.menuBreadcrumb(run.stderr)
            return ScriptResult("timeout", "no answer within \(Plugin.pythonNumber(seconds)) s", "", "", frame, pid)
        }
        if run.status == -1 {
            return ScriptResult("unavailable", run.error)
        }
        let output = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let (stderr, frame, pid) = Self.menuBreadcrumb(run.stderr)
        if run.status == 0 && !output.isEmpty {
            var parsed = Self.parseOutput(output)
            if parsed.frame.isEmpty && !frame.isEmpty {    // it broke after showing a menu
                parsed.frame = frame
                parsed.pid = pid
            }
            return parsed
        }
        let err = Self.words(stderr)
        if let mapped = Self.permissionOutcome(err) {
            return ScriptResult(mapped, err, "", "", frame, pid)
        }
        if err.lowercased().contains("syntax error") {
            return ScriptResult("syntax-error", err)
        }
        return ScriptResult("error", err.isEmpty ? "osascript exited with code \(run.status)" : err, "", "", frame, pid)
    }

    /// Run the main script (compiled when possible, the compiled file
    /// checked first: `checkedFastScript`). If the script itself breaks,
    /// run the slower fallback script instead -- unless `allowFallback` is
    /// false (the warm-up, which the fallback doesn't do), or the main
    /// script broke while running and `fallbackAfterRun` is false (Resume:
    /// it may have shown a menu already, and must not show another).
    func runAxScript(_ arguments: [String], allowFallback: Bool = true, fallbackAfterRun: Bool = true) -> ScriptResult {
        var notes = ""
        lock.lock()
        let broken = fastBroken
        lock.unlock()
        if !broken {
            let command: [String]
            if let compiled = checkedFastScript() {
                command = [Self.osascript, compiled]
            } else {
                command = [Self.osascript, "-e", Scripts.fast]
            }
            let result = runScript(command + arguments)
            if !Self.failures.contains(result.outcome) { return result }
            lock.lock()
            fastFailures += 1
            if result.outcome == "syntax-error" || fastFailures >= 2 { fastBroken = true }
            lock.unlock()
            notes = "main script failed (\(result.outcome): \(result.trace)); "
            if !allowFallback || (result.outcome != "syntax-error" && !fallbackAfterRun) {
                return ScriptResult(result.outcome, notes.trimmingCharacters(in: .whitespaces), result.browser, "",
                                    result.frame, result.pid)
            }
        } else if !allowFallback {
            return ScriptResult("unavailable", "the main script can't run in this session")
        }
        let result = runScript([Self.osascript, "-e", Scripts.legacy] + arguments)
        return ScriptResult(result.outcome, "\(notes)fallback script: \(result.trace)", result.browser, "", result.frame, result.pid)
    }
}

/// The compiled script to remove when the plugin ends.
nonisolated(unsafe) private var compiledAtExit: String?
