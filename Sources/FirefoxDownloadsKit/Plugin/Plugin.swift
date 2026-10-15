// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Places
//
// DynamicLake shows two cards at a time: one in the main place, one as the
// small capsule beside it. Left to itself with three or more, it keeps the
// oldest in the main place, shows the newest in the capsule and, when the
// main one leaves, moves that newest one up: the second download would come
// last. So the plugin gives a card to `notchPlaces` downloads only, in the
// order they started. The others wait without one, and each gets its card
// when a place is free: when the card of a finished, canceled or blocked
// download has gone (a paused or failed download keeps its place).
//
// The oldest download with a card is "first": by DynamicLake's rule it has
// the main place, and it shows its status on its own card, as a single
// download does. Any other download's status (finished, canceled, paused,
// failed) shows in the main place on a card made for that, which takes the
// place for its time and gives it back (`startSpot` and `endSpot`). One at
// a time, oldest first (step 4b). A download that's over and isn't first
// gives up its own card and its place at once.
//
// Another app's activity (music, say) may have the main place, with the
// first download as the capsule: DynamicLake opens no sneak peek there. So
// a status always takes the main place, with the high priority: a status
// card is created with it, and the first download's own card gets it with
// its status (its sneak peek is asked for again a moment later: asked for a
// card that isn't in the main place yet, it's dropped). Afterwards the
// place is given back with the low priority, never with the high one: a
// card that leaves, or the plugin's cards lowered for a moment (the first
// download's the least), let another app's activity move up when there's
// one, and the first download when there's none (`endSpot`, steps 4c, 4e).
//
// With the setting "Focus Mode" on, a finished download's card waits while
// any other download is still under way (`Download.underWay`): its own card
// and its place go at once, whichever download it is, so that the next ones
// move up; when none is under way, the finished cards that waited show in
// the main place one after the other, in the order the downloads finished,
// each on a status card. Only finished cards wait: a pause, a failure or a
// cancellation shows at once, as with the setting off.
//
// With the setting "Smart Slideshows" on, finished cards that wait in line
// together -- for the other downloads (Focus Mode), for you (Delayed
// Display) -- show as one: a status card that says how many there are ("3
// Downloads Completed"; one alone shows as it is).
//
// Beside another app's activity, the capsule is the plugin's card that was
// updated last, and DynamicLake goes by that all the time, not only when a
// card comes or goes. Two downloads' cards aren't updated in step (each has
// updates of its own: its time left counting down, its details taking
// turns), so they would keep taking the capsule from each other, which
// blinks out for a second at every change. So the first download's card
// always has the last word: in a pass it is sent after the others', and
// when only another card had something to send, it is sent once more as it
// is, right behind (`lastWord`; `DynamicLake.keepLast`).
//
// DynamicLake never says where a card is: all this goes by the order above.
// After a click on the capsule (which swaps the two cards), or beside
// another app's activity, the cards may be elsewhere than the plugin
// thinks; and a download that had the main place before another app's
// activity came is behind it after a status has shown.

/// The plugin: it watches the download folders and keeps DynamicLake's
/// cards up to date, one look at a time.
public final class Plugin {
    /// A status card's name: its download's card's, and this (see "Places").
    static let statusCardSuffix = "-s"

    let shared: Shared
    private let lake: DynamicLake
    private let supportsPresentSneakPeek: Bool
    /// Digits that change in place (no jitter) for the percentage, where supported.
    private let numericStyle: String
    /// The program that shows a file in the Finder and opens it.
    var openTool = "/usr/bin/open"
    /// Stop, Resume and Retry's work on the browser, and the warm-up.
    public var buttons: ButtonWork?
    /// Compiles the button script ahead of the first press.
    public var precompile: (() -> Void)?

    private var t: Tunables { shared.t }
    private var settings: Settings { shared.settings }

    private var profiles: [(path: String, process: String)] = []
    private var watchDirs: [String] = []
    private var nextDirRefresh = 0.0
    private let lists = DownloadsList()
    private let presence: BrowserPresence
    private let sleepWatch: SleepWatch
    private var nextReplayAt = 0.0
    /// No card is given before then (see `placeGapSeconds`).
    private var placesFreeFrom = 0.0
    /// The card kept behind the capsule's while a status card has the main place.
    private var spotPinned = ""
    /// A download's own card, at the high priority for its status: card ->
    /// when the main place is given back (nothing: when the card goes, or at once).
    private var raised = OrderedMap<String, Double?>()
    /// Cards at the low priority to give the main place back: card -> when
    /// each gets its usual priority again (see `endSpot`, steps 4c and 4e).
    private var settling = OrderedMap<String, Double>()
    private var baselineSizes: [String: Int] = [:]
    private var tracked = OrderedMap<String, Download>()
    /// The browser process that answered last (tried first), and where its
    /// toolbar Downloads button was ("1.1.2.4").
    var lastBrowser = ""
    var lastButton = ""
    private var lastAxActivity: Double
    private var warmup: ActionJob?
    private var lastTick: Double
    private var lastError = ("", 0.0)

    public init(shared: Shared, lake: DynamicLake, features: Set<String>) {
        self.shared = shared
        self.lake = lake
        supportsPresentSneakPeek = features.contains("presentSneakPeek")
        numericStyle = features.contains("numericText") ? "numeric" : "compact"
        presence = BrowserPresence(mac: shared.mac)
        sleepWatch = SleepWatch(shared)
        lastTick = -shared.t.pollInterval
        lastAxActivity = -shared.t.warmupMinGap
    }

    /// The features DynamicLake names in the environment.
    public static func features(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        Set((environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private func log(_ message: String) {
        shared.logEvent(message)
    }

    // MARK: Running

    /// Runs until DynamicLake closes the connection.
    public func run() {
        log("started: no Dock icon to keep away (not in an app bundle)")
        if let line = settings.refresh(now: monotonic(), force: true) { log(line) }
        profiles = Profiles.discover()
        watchDirs = Profiles.watchFolders(profiles)
        buttons?.progress?.watch(watchDirs)
        nextDirRefresh = monotonic() + t.dirRefreshSeconds
        // Baseline: the partial files already there when the plugin starts,
        // so that a stale or abandoned one does not show up as "downloading".
        for folder in watchDirs {
            for part in shared.mac.partFiles(folder) {
                if let size = Paths.size(part) { baselineSizes[part] = size }
            }
        }
        precompile?()
        while true {
            do {
                try pass()
            } catch is LakeClosed {
                return                       // DynamicLake went away: the plugin ends
            } catch {
                let where_ = "\(error)"
                if where_ != lastError.0 || monotonic() - lastError.1 > 60 {
                    lastError = (where_, monotonic())
                    log("error in the main loop (carrying on): \(where_)")
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func send(_ payload: JSON) throws {
        try lake.send(payload)
    }

    private func sendPriority(_ activityID: String, _ priority: String) throws {
        try send(.obj(["schemaVersion": .int(1), "type": .string("update"), "activityID": .string(activityID),
                       "priority": .string(priority)]))
    }

    private func dismiss(_ activityID: String) throws {
        try send(.obj(["schemaVersion": .int(1), "type": .string("dismiss"), "activityID": .string(activityID)]))
    }

    /// The oldest download that has a card of its own.
    private func firstInPlace() -> Download? {
        tracked.values.filter(\.place).min { $0.seq < $1.seq }
    }

    /// Give the free places to the downloads that wait, oldest first, and
    /// return those. Only a download still under way gets one (a waiting
    /// one that's over only has its status to show), and none right after
    /// a card left (`placeGapSeconds`).
    private func assignPlaces(_ now: Double) -> [Download] {
        let downloads = tracked.values
        var waiting: [Download]
        if t.notchPlaces <= 0 {
            waiting = downloads.filter { !$0.place }
        } else {
            let free = t.notchPlaces - downloads.filter(\.place).count
            if free <= 0 || now < placesFreeFrom { return [] }
            waiting = Array(downloads.filter { !$0.place && $0.resolvedAt == nil }.sorted { $0.seq < $1.seq }.prefix(free))
        }
        for download in waiting { download.place = true }
        return waiting
    }

    /// A canceled download whose Retry was pressed here, started over in a
    /// new partial file (same folder, same file name): it keeps its card.
    /// (Firefox normally reuses the partial file's name; this is the
    /// fallback. Only a partial file that's new since the last look is
    /// offered here, and only once the press went through.)
    private func adoptRestarted(_ partPath: String) -> Download? {
        let name = realNameFromPart(text(Paths.name(partPath).unicodeScalars.dropLast(5)))
        for (key, download) in tracked.items {
            if download.canRestart && download.restartRequestedAt != nil && Paths.parent(key) == Paths.parent(partPath)
                && download.filename == name {
                tracked.removeValue(forKey: key)
                download.move(to: partPath)
                tracked[partPath] = download
                return download
            }
        }
        return nil
    }

    /// Move a download between "active", "paused" and "failed": what its
    /// downloads.json entry says, unless its partial file keeps growing --
    /// then the browser has resumed it, and the file will say so about
    /// 1.5 s later; until it's rewritten, that version of the file is
    /// ignored. The other way round, `stoppedEarly`: the browser has closed
    /// the partial file, so it stopped the download, and downloads.json will
    /// say so about 1.5 s later; until then it shows as paused (a failure
    /// shows as failed once the file says so). Returns a line for the log
    /// when the state changed. ("blocked" is handled by the caller; "" or
    /// unlisted is no news.)
    static func updateState(_ download: Download, listed: String, version: ListVersion?, stoppedEarly: Bool = false) -> String? {
        if download.staleVersion == .firstSeen, let version {
            download.staleVersion = .version(version)
        }
        var target = download.state
        if listed == "paused" || listed == "failed" {
            target = version != nil && download.staleVersion == .version(version!) ? "active" : listed
        } else if listed == "active" {
            target = "active"
        }
        if stoppedEarly && target == "active" {
            target = "paused"
        }
        if (download.state == "paused" || download.state == "failed") && target == download.state, let last = download.samples.last {
            if last.at != download.growthCheckedAt {          // a new measurement
                download.growthCheckedAt = last.at
                if last.size > download.stateSize {
                    download.growthTicks += 1
                    download.stateSize = last.size
                } else {
                    download.growthTicks = 0
                }
                // Two measurements in a row, or one right after the
                // plugin's own Resume or Retry, so a last write the browser
                // flushed late isn't mistaken for a restart.
                if download.growthTicks >= (download.restartRequestedAt != nil ? 1 : 2) {
                    download.staleVersion = version.map { .version($0) } ?? .none
                    target = "active"
                }
            }
        }
        if target == download.state { return nil }
        let old = download.state
        download.state = target
        if target == "paused" || target == "failed" {
            download.stateSize = download.size
            download.growthTicks = 0
            download.growthCheckedAt = download.samples.last?.at
            return "\(target) at \(Formatting.bytes(download.size))"
                + (download.totalSize.map { $0 != 0 ? " of \(Formatting.bytes($0))" : "" } ?? "")
        }
        download.restarted()
        return "downloading again (was \(old))"
    }

    /// "Paused", "failed"...: does the browser have this download's partial
    /// file open? "open": it's downloading, or waiting for data. "closed":
    /// the browser is running and doesn't have it open -- it closes it the
    /// moment it stops a download (a pause, a failure), about 1.5 s before
    /// its downloads.json says so. "unknown": can't be told (which browser
    /// it is isn't known, the browser isn't running, or the file is gone).
    private func partialFileState(_ download: Download, now: Double) -> String {
        guard let profile = download.profile, let pid = presence.pid(of: profile, now: now) else { return "unknown" }
        guard let hasIt = shared.mac.processHasOpen(pid, download.partPath) else { return "unknown" }
        return hasIt ? "open" : "closed"
    }

    /// The browser to try first (the one whose downloads.json lists this
    /// download, else the one that answered last) and, when that's the same
    /// browser, where its toolbar button was.
    private func browserHints(_ download: Download) -> (String?, String?) {
        let proc = download.browser.isEmpty ? lastBrowser : download.browser
        let button = !proc.isEmpty && proc == lastBrowser && !lastButton.isEmpty ? lastButton : nil
        return (proc.isEmpty ? nil : proc, button)
    }

    /// Whether sneak peeks wait until you're back (asked at most once a pass).
    private func waitingForYou(_ cache: inout Bool?) -> Bool {
        if cache == nil {
            cache = settings.flag(.waitWhenAway) && shared.userAway()
        }
        return cache!
    }

    /// The first download's card is the one updated last: if another
    /// download's own card got a message after it, it is sent once more,
    /// as it is (see "Places"). Nothing while it has no card of its own up,
    /// and nothing with `notchPlaces` at 0.
    private func lastWord() throws {
        let first = firstInPlace()
        var card = ""
        if t.notchPlaces > 0, let first, first.created, !first.spot { card = first.activityID }
        if card != lake.keepLast {
            lake.keepLast = card
            lake.overtaken = !card.isEmpty && tracked.values.contains { d in
                d !== first && (d.spot ? d.ownCard : d.created)
            }
        }
        if !card.isEmpty && lake.overtaken, let surfaces = first?.sentSurfaces {
            try send(.obj(["schemaVersion": .int(1), "type": .string("update"), "activityID": .string(card),
                           "surfaces": surfaces]))
        }
    }

    /// The downloads' own cards that are up (no status card), oldest download first.
    private func ownCards(but: String = "") -> [String] {
        tracked.values.sorted { $0.seq < $1.seq }
            .filter { ($0.spot ? $0.ownCard : $0.created) && $0.activityID != but }
            .map(\.activityID)
    }

    /// The low priority for these cards, in this order, for a moment (step 4c).
    private func lower(_ cards: [String], _ now: Double) throws {
        for card in cards {
            try sendPriority(card, "low")
            settling[card] = now + t.handBackSeconds
        }
    }

    /// Show this download's status in the main place, on a card made for
    /// that (its own card, if it has one, stays where it is). The card is
    /// created with the high priority, which takes the main place at once.
    /// The first download's card gets the low one meanwhile: behind the
    /// capsule's, so that the capsule goes on showing what it showed. The
    /// sneak peek is asked for a moment later (`peekAfterCreate`).
    private func startSpot(_ download: Download, kind: String, now: Double) throws {
        let first = firstInPlace()
        download.ownCard = download.created
        download.created = false
        download.spot = true
        download.lineFrom = now                  // (its line stays still at first, from now)
        let (surfaces, signature) = download.currentSurfaces(numericStyle)
        try send(.obj(["schemaVersion": .int(1), "type": .string("create"), "activityID": .string(download.cardID),
                       "title": .string("Download"), "priority": .string("high"), "size": .string(activitySize),
                       "surfaces": surfaces]))
        if let first, first !== download, first.created {
            try sendPriority(first.activityID, "low")
            spotPinned = first.activityID
            settling.removeValue(forKey: spotPinned)
        }
        for card in raised.keys {                 // (a card that had the main place for its own status)
            if card != spotPinned {
                try sendPriority(card, "normal")
            }
            raised.removeValue(forKey: card)
        }
        download.created = true
        download.createdAt = now
        download.lastSignature = signature
        download.linePhaseSent = download.linePhase
        let seconds = shared.presentSeconds(kind)
        download.peekOwed = (seconds, now + t.peekAfterCreate)
        if download.resolvedAt != nil {
            download.resolvedAt = now                // (it stays its usual time, from now)
            download.spotUntil = nil
        } else {
            download.spotUntil = now + t.peekAfterCreate + Double(seconds) + t.spotMarginSeconds
        }
    }

    /// The status card leaves the main place. DynamicLake then moves up
    /// another app's activity when there's one, else the plugin's card with
    /// the highest priority (between equals, whichever was updated last):
    /// so, just before the status card is dismissed, the first download's
    /// card gets its usual priority and the plugin's other cards the low
    /// one, which they keep for a moment (`handBackSeconds`; step 4c).
    private func endSpot(_ download: Download, now: Double) throws {
        let first = firstInPlace()
        var back = ""
        if first === download {
            back = download.ownCard ? download.activityID : ""
        } else if let first, first.created, !first.spot {
            back = first.activityID
        }
        if !back.isEmpty {
            try sendPriority(back, "normal")
            raised.removeValue(forKey: back)
            settling.removeValue(forKey: back)
        }
        try lower(ownCards(but: back).filter { !raised.contains($0) }, now)
        try dismiss(download.cardID)
        spotPinned = ""
        log("\(download.filename): its status card left the main place"
            + (!back.isEmpty ? " (\(first!.filename) is first in line for it)" : " (no other card)"))
        download.spot = false
        download.spotUntil = nil
        download.peekOwed = nil
        download.created = download.ownCard
        download.ownCard = false
        download.lastSignature = nil             // (its own card, if it has one, is brought up to date)
        nextReplayAt = max(nextReplayAt, now + t.spotGapSeconds)
    }

    /// Runs `open` with these arguments, without holding up the loop (a
    /// card due meanwhile goes on time), one after the other, in the order
    /// they were asked for; `finished` gets "" when it went well, else why
    /// not.
    private func launchTool(_ arguments: [String], timeout: Double = 3_600, finished: (@Sendable (String) -> Void)? = nil) {
        let tool = openTool
        Self.toolQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                finished?(": couldn't be opened (\(error.localizedDescription))")
                return
            }
            let deadline = monotonic() + timeout
            while process.isRunning && monotonic() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                process.terminate()
                finished?(": couldn't be opened (no answer after \(Int(timeout)) s)")
                return
            }
            process.waitUntilExit()
            finished?(process.terminationStatus == 0 ? "" : ": couldn't be opened (\(process.terminationStatus))")
        }
    }

    private static let toolQueue = DispatchQueue(label: "Firefox Downloads: open")

    // MARK: One pass

    private func pass() throws {
        // Sleep until the next look, but wake the instant DynamicLake sends
        // a button press. Looks come every 0.1 s while a button's action is
        // in flight.
        let interval = tracked.values.contains { $0.busy || $0.settling } ? t.actionPollInterval : t.pollInterval
        var remaining = lastTick + interval - monotonic()
        // ...and on time for a card that's due to go (with its sneak peek
        // still open), or a new download's arrow to become its file type.
        let waking = monotonic()
        var dues = [placesFreeFrom]               // (a card for the next download in line)
        dues += settling.values
        dues += raised.values.compactMap { $0 }
        for download in tracked.values {
            if let owed = download.peekOwed { dues.append(owed.notBefore) }
            if let until = download.spotUntil { dues.append(until) }
            if download.held != nil && download.heldWhy == "turn" {
                dues.append(max(nextReplayAt, download.created ? download.createdAt + t.peekAfterCreate : 0.0))
            }
        }
        for due in dues where due > waking {
            remaining = min(remaining, due - waking + 0.01)
        }
        for download in tracked.values {
            var due: Double
            if download.resolvedAt == nil {
                due = download.startedAt + t.iconDelaySeconds
            } else if download.job == nil && !download.restartPending && download.held == nil {
                due = download.resolvedAt! + shared.keepSeconds(download)
            } else {
                continue
            }
            if due > waking { remaining = min(remaining, due - waking + 0.01) }
            if let notBefore = download.peekNotBefore, notBefore > waking {
                remaining = min(remaining, notBefore - waking + 0.01)
            }
            if let textDue = download.textDue, textDue > waking {     // (the time left, second by second)
                remaining = min(remaining, textDue - waking + 0.01)
            }
        }
        if remaining > 0 {
            lake.waitReadable(remaining)
        }
        var now = monotonic()
        var awayCache: Bool?

        if let changed = settings.refresh(now: now) { log(changed) }

        if now >= nextDirRefresh {
            profiles = Profiles.discover()
            watchDirs = Profiles.watchFolders(profiles)
            buttons?.progress?.watch(watchDirs)
            nextDirRefresh = now + t.dirRefreshSeconds
        }

        // 1. Button presses, handled as soon as they arrive. Stop, Resume and
        // Retry only act on the card their button is shown on, one at a time.
        for message in try lake.pollIncoming() {
            guard message["type"] as? String == "action" else { continue }
            let actionID = message["actionID"] as? String ?? ""
            let (kind, activityID) = Self.partition(actionID)
            guard let download = tracked.values.first(where: { $0.activityID == activityID }) else { continue }
            if kind == "show" {
                // (the one card for several finished downloads shows them all)
                let found = (download.summary.isEmpty ? [download.finalPath] : download.summary).filter(Paths.exists)
                if !found.isEmpty {
                    launchTool(["-R"] + found)
                }
                continue
            }
            if kind == "open" {
                // Open File, on the finished card: the file, in the app for
                // its type (macOS asks first about an app or a script that
                // came from the internet, as it does in the Finder).
                if download.resolvedAt != nil && download.succeeded && Paths.exists(download.finalPath) {
                    let log = shared.log, name = download.filename
                    launchTool([download.finalPath], timeout: 15) { outcome in
                        log.write("\(name): Open File" + outcome)
                    }
                }
                continue
            }
            var shown = Notices.actionStates[kind] != nil && download.resolvedAt == nil && !download.browserClosed
                && download.shownState(now) == Notices.actionStates[kind]
            if kind == "restart" {
                shown = download.canRestart
            }
            if !shown || download.busy { continue }
            guard let buttons else { continue }
            let (proc, button) = browserHints(download)
            if kind == "stop" { download.stopPressedAt = now }
            if kind == "restart" { download.restartPressedAt = now }
            download.job = buttons.startAction(kind, name: download.filename, fallback: Paths.name(download.rawFinalPath),
                                               finalPaths: [download.finalPath, download.rawFinalPath], proc: proc,
                                               button: button, returnFocus: settings.flag(.returnFocus), tunables: t)
            lastAxActivity = now
            download.held = nil                  // (you're here)
            download.notice = Notices.working[kind]
            download.noticeUntil = now + t.stopScriptTimeout + (kind == "stop" ? t.cancelGiveUpSeconds : t.restartGiveUpSeconds)
        }

        // 1b. Pick up finished button actions (they run on a thread of their own).
        for download in tracked.values {
            guard let job = download.job, job.done else { continue }
            download.job = nil
            log("\(download.filename): \(Notices.actionNames[job.kind] ?? job.kind): \(job.outcome) after "
                + "\(Formatting.fixed(job.seconds, 2)) s | \(job.trace)")
            if !job.browser.isEmpty {
                lastBrowser = job.browser
                lastButton = job.position
            }
            if download.resolvedAt != nil && (job.kind != "restart" || !download.canRestart) {
                continue  // the partial file already went away (or, restarted, it finished already)
            }
            let doneAt = monotonic()
            // "press-failed": the press reported an error, but it may still
            // have gone through -- so wait for the browser, like after a press.
            if Notices.sent[job.kind]?.contains(job.outcome) == true {
                if job.kind == "stop" {
                    download.cancelRequestedAt = doneAt   // step 3 sees the partial file disappear
                    download.notice = Notices.working["stop"]
                    download.noticeUntil = doneAt + t.cancelGiveUpSeconds + 1
                } else if download.resolvedAt == nil && download.state == "active" {
                    download.notice = nil                 // it's downloading again already
                } else {
                    // step 2 sees it restart (a canceled download: its
                    // partial file coming back)
                    download.restartRequestedAt = doneAt
                    download.restartKind = job.kind
                    download.notice = Notices.working[job.kind]
                    download.noticeUntil = doneAt + t.restartGiveUpSeconds + 1
                }
            } else {
                download.notice = Notices.action[job.kind]?[job.outcome] ?? Notices.fallback
                download.noticeUntil = doneAt + t.noticeSeconds
                if download.resolvedAt != nil {
                    download.resolvedAt = doneAt          // the card stays up while it says so
                }
            }
        }

        // 1c. The warm-up finished.
        if let done = warmup, done.done {
            log("warm-up: \(done.outcome) after \(Formatting.fixed(done.seconds, 2)) s | \(done.trace)")
            if !done.browser.isEmpty {
                lastBrowser = done.browser
                lastButton = done.position
            }
            warmup = nil
        }

        if now >= lastTick + interval - 0.005 {
            lastTick = now
            try look(now)
        }

        try sendChanges(now: now, awayCache: &awayCache)

        // 5. Dismiss cards whose grace period has elapsed (not while a button
        // works on them, nor while they wait for you).
        now = monotonic()
        for partPath in tracked.keys {
            guard let download = tracked[partPath] else { continue }
            if download.resolvedAt == nil || download.job != nil || download.restartPending || download.held != nil { continue }
            if now - download.resolvedAt! > shared.keepSeconds(download) {
                if download.spot {
                    try endSpot(download, now: now)
                }
                if download.created {
                    try dismiss(download.activityID)
                }
                if download.place {
                    placesFreeFrom = now + t.placeGapSeconds
                }
                tracked.removeValue(forKey: partPath)
                baselineSizes.removeValue(forKey: partPath)
                if download.resolvedReason == "Blocked" {
                    // The held-back file stays until you decide in the
                    // browser; don't show it again unless it grows.
                    if let size = Paths.size(partPath) { baselineSizes[partPath] = size }
                }
            }
        }

        // 6. The first download's card has the last word (see "Places").
        try lastWord()
    }

    static func partition(_ actionID: String) -> (String, String) {
        guard let colon = actionID.firstIndex(of: ":") else { return (actionID, "") }
        return (String(actionID[..<colon]), String(actionID[actionID.index(after: colon)...]))
    }

    /// Steps 1d to 3b: the folders, downloads.json and the browsers.
    private func look(_ now: Double) throws {
        // 1d. The Mac just woke up. Firefox paused the downloads in
        // progress when it went to sleep, and resumes them by itself 10 s
        // after it wakes: until then, a pause isn't shown (nor a partial
        // file that went away, which Firefox starts over). Only what was
        // downloading when the Mac went to sleep: a download you'd paused
        // stays paused, and shows so.
        let asleep = sleepWatch.asleepFor(now)
        if asleep != 0 {
            let waiting = tracked.values.filter { download in
                download.resolvedAt == nil
                    && (download.state == "active" || sleepWatch.before - download.lastGrowthAt <= t.wasDownloadingSeconds)
            }
            for download in waiting {
                download.holdUntil = now + t.wakeGraceSeconds
                download.presentedState = nil     // (its pause may have been seen before the Mac slept)
            }
            if !waiting.isEmpty {
                log("the Mac woke up (asleep about \(Formatting.fixed(asleep, 0)) s): for \(Self.pythonNumber(t.wakeGraceSeconds)) s, "
                    + "pauses aren't shown while Firefox resumes downloads by itself "
                    + "(\(waiting.map(\.filename).joined(separator: ", ")))")
            }
        }

        // 2. Look in the watched folders for partial files.
        var seenNow = Set<String>()
        for folder in watchDirs {
            for partPath in shared.mac.partFiles(folder).sorted() {
                seenNow.insert(partPath)
                var download = tracked[partPath]
                if download == nil && baselineSizes[partPath] == nil {
                    download = adoptRestarted(partPath)
                }
                if download == nil {
                    let baselineSize = baselineSizes[partPath]
                    if let baselineSize {
                        let currentSize = Paths.size(partPath) ?? baselineSize
                        if currentSize <= baselineSize { continue }   // stale leftover, not actively growing
                    }
                    let new = Download(partPath, shared: shared)
                    tracked[partPath] = new
                    download = new
                    if baselineSize != nil {
                        // A download from before the plugin started, now
                        // growing: resumed, while downloads.json may still
                        // say paused or failed for a moment.
                        new.staleVersion = .firstSeen
                    }
                    // A new download: get the browser automation ready now,
                    // so a button press doesn't have to wait for start-up.
                    if let buttons, warmup == nil, !tracked.values.contains(where: \.busy),
                       now - lastAxActivity >= t.warmupMinGap {
                        warmup = buttons.startWarmup(proc: lastBrowser.isEmpty ? nil : lastBrowser,
                                                     button: lastButton.isEmpty ? nil : lastButton)
                        lastAxActivity = now
                    }
                } else if download!.canRestart {
                    // Its partial file is back: Retry (the notch's, or the
                    // browser's own) started the canceled download over.
                    let pressedAt = download!.restartPending ? download!.restartPressedAt : nil
                    download!.reopen(now)
                    log("\(download!.filename): downloading again after it was canceled"
                        + (pressedAt.map { " (Retry worked, \(Formatting.fixed(now - $0, 2)) s after the press)" } ?? ""))
                }
                if download!.resolvedAt == nil {
                    download!.sample()
                }
            }
        }

        // 2a. Total size and state (paused, failed...), from the browsers'
        // downloads.json.
        if tracked.values.contains(where: { $0.resolvedAt == nil }) {
            lists.refresh(profiles)
        }
        for download in tracked.values {
            if download.resolvedAt != nil { continue }
            let (total, listed, process, version) = lists.lookup(download)
            if !process.isEmpty {
                download.browser = process
            }
            download.profile = lists.profile(of: download) ?? download.profile
            if let total, total != 0 {
                if download.totalSize == nil {
                    log("\(download.filename): total size \(Formatting.bytes(total)) (from the browser's downloads.json)")
                }
                download.totalSize = total
                download.totalLogged = true
            } else if !download.totalLogged && now - download.startedAt >= t.totalWaitSeconds {
                download.totalLogged = true
                log("\(download.filename): no total size in any downloads.json after "
                    + "\(Self.pythonNumber(t.totalWaitSeconds)) s -- the ring stays spinning (the server may not "
                    + "send a size, or it's a private-window download)")
            }
            if listed == "blocked" {
                // Held back as a potential security risk: only you can
                // decide, in the browser.
                download.resolvedAt = now
                download.succeeded = false
                download.resolvedReason = "Blocked"
                download.cancelRequestedAt = nil
                download.restartRequestedAt = nil
                download.notice = nil
                log("\(download.filename): blocked by the browser as a potential security risk")
                continue
            }
            // The browser closes the partial file the moment it stops a
            // download (a pause, a failure), about 1.5 s before its
            // downloads.json says so: seen closed twice, a moment apart
            // (it's also closed for an instant when the download finishes
            // or is canceled), it counts as stopped at once. Not during a
            // Stop, nor for a download its browser's downloads.json doesn't
            // list by its partial file.
            var stoppedEarly = false
            var look = "unknown"
            if !download.noEarlyStop && !download.stopping && lists.listsPartialFile(download) {
                look = partialFileState(download, now: now)
            }
            if look == "closed" {
                let fresh = Paths.size(download.partPath)
                if fresh == nil || (download.totalSize != nil && fresh! >= download.totalSize!) {
                    download.closedSeenAt = nil               // gone, or all there: it's finishing
                } else if download.closedSeenAt == nil {
                    download.closedSeenAt = now
                    download.closedSize = fresh!
                    download.closedGrowths = 0
                } else if fresh! > download.closedSize {
                    // Bigger than at the last look, yet that process doesn't
                    // have it open. Once, it may have been reopened and
                    // closed in between (a Retry that failed again at once):
                    // seen afresh. Twice since it was last seen open
                    // (however slowly it grows), it isn't the process
                    // downloading it.
                    download.closedGrowths += 1
                    download.closedSeenAt = now
                    download.closedSize = fresh!
                    if download.closedGrowths >= 2 {
                        download.noEarlyStop = true
                        download.closedSeenAt = nil
                        log("\(download.filename): its partial file grows although the browser that lists it doesn't "
                            + "have it open: another process is downloading it (pauses show when downloads.json says so)")
                    }
                } else {
                    let confirm = download.totalSize != nil ? t.earlyStopConfirm : t.earlyStopConfirmNoTotal
                    stoppedEarly = now - download.closedSeenAt! >= confirm
                }
            } else {
                download.closedSeenAt = nil
                if look == "unknown" && download.earlyPaused && download.state == "paused", let profile = download.profile {
                    let inUse = shared.mac.profileInUse(profile)    // (asked afresh, not from the cache)
                    presence.note(profile, now: now, inUse: inUse)
                    if inUse == false {
                        // It wasn't a pause: the browser was quitting (it
                        // closes its files a moment before it's gone).
                        download.state = "active"
                        download.earlyPaused = false
                        download.peekNotBefore = nil
                        download.presentedState = nil
                        download.browserClosed = true
                        // (as after `closedCheckAfter` without data: it stays
                        // "browser closed" until data comes again)
                        download.lastGrowthAt = min(download.lastGrowthAt, now - t.closedCheckAfter - 1.0)
                        log("\(download.filename): not paused: its browser was closing, at \(Formatting.bytes(download.size)); "
                            + "Firefox carries on with the download when it reopens")
                        continue
                    }
                }
            }
            let wasActive = download.state == "active"
            var change = Self.updateState(download, listed: listed, version: version, stoppedEarly: stoppedEarly)
            if download.state != "paused" {
                download.earlyPaused = false
                download.peekNotBefore = nil
            } else if stoppedEarly && wasActive && listed != "paused" && listed != "failed" {
                // Stopped, by the closed file alone so far. A pause or a
                // failure? The card waits for downloads.json to tell
                // (`shownState`), so that it changes once, to the right
                // one; the loop looks often meanwhile (`settling`).
                download.earlyPaused = true
                download.peekNotBefore = now + t.earlyPeekDelay
            } else if download.earlyPaused && listed == "paused" {
                download.earlyPaused = false              // downloads.json says so too:
                if download.peekNotBefore != nil {
                    download.peekNotBefore = now          // no need to wait any longer
                }
            }
            if change != nil {
                if stoppedEarly && wasActive && download.state == "paused" && listed != "paused" {
                    change! += " (the browser closed the partial file; its downloads.json hasn't said so yet)"
                }
                if download.state == "paused" && now < download.holdUntil {
                    change! += " -- the Mac just woke up: shown only if Firefox hasn't resumed it "
                        + "within \(Formatting.fixed(download.holdUntil - now, 0)) s"
                }
                log("\(download.filename): \(change!)")
                if download.state == "active" {
                    if let requested = download.restartRequestedAt {
                        log("\(download.filename): \(Notices.actionNames[download.restartKind] ?? download.restartKind) worked, "
                            + "data again \(Formatting.fixed(now - requested, 2)) s after the press")
                        download.restartRequestedAt = nil
                    }
                    if download.notice == Notices.working["resume"] || download.notice == Notices.working["retry"] {
                        download.notice = nil
                    }
                }
            }
        }

        // 2b. A button press that didn't take.
        for download in tracked.values {
            if let requested = download.restartRequestedAt, now - requested >= t.restartGiveUpSeconds {
                let was = download.resolvedAt != nil ? "canceled" : download.state
                log("\(download.filename): still \(was) \(Formatting.fixed(t.restartGiveUpSeconds, 0)) s after "
                    + "\(Notices.actionNames[download.restartKind] ?? download.restartKind) was pressed")
                download.restartRequestedAt = nil
                download.notice = Notices.gaveUp[download.restartKind]
                download.noticeUntil = now + t.noticeSeconds
                if download.resolvedAt != nil {
                    download.resolvedAt = now          // the card stays up while it says so
                }
            }
            if download.resolvedAt != nil { continue }
            if let requested = download.cancelRequestedAt, now - requested >= t.cancelGiveUpSeconds {
                log("\(download.filename): still downloading \(Formatting.fixed(t.cancelGiveUpSeconds, 0)) s after Cancel was pressed")
                download.cancelRequestedAt = nil
                download.notice = Notices.gaveUp["stop"]
                download.noticeUntil = now + t.noticeSeconds
            }
        }

        // 2c. No data for a while: is its browser still open? Or is the
        // download stalled?
        for download in tracked.values {
            if download.resolvedAt != nil || download.busy { continue }
            let quiet = now - download.lastGrowthAt
            let closed = quiet >= t.closedCheckAfter && presence.closed(for: download.profile, now: now)
            if closed != download.browserClosed {
                download.browserClosed = closed
                if !closed {
                    log("\(download.filename): its browser is open again")
                } else if download.state == "active" {
                    log("\(download.filename): its browser was closed at \(Formatting.bytes(download.size)); "
                        + "Firefox carries on with the download when it reopens")
                } else {
                    log("\(download.filename): its browser was closed (the download stays \(download.state))")
                }
            }
            let stalled = download.stalled(now)
            if stalled && !download.stallLogged {
                download.stallLogged = true
                log("\(download.filename): stalled: no data for \(Self.pythonNumber(t.stallSeconds)) s at \(Formatting.bytes(download.size))")
            } else if download.stallLogged && !stalled {
                download.stallLogged = false
                if quiet < t.stallSeconds {
                    log("\(download.filename): data again after stalling")
                }
            }
        }

        // 3. Completion or cancellation: the partial file vanished.
        for (partPath, download) in tracked.items {
            if download.resolvedAt != nil { continue }
            if seenNow.contains(partPath) || Paths.exists(partPath) {
                download.missingTicks = 0     // (a failed folder listing is not a vanish)
                continue
            }
            download.missingTicks += 1
            let (verdict, final) = classifyVanished(download)
            if verdict == "unsure" && download.missingTicks <= t.emptyFileTicks { continue }
            if verdict == "canceled" && !download.stopping
                && (download.missingTicks <= t.vanishGraceTicks || now < download.holdUntil) {
                continue
            }
            if let final {
                download.finalPath = final
            }
            download.succeeded = verdict != "canceled"
            download.resolvedAt = now
            download.notice = nil                   // ("Stopping…" and the like: that's settled)
            if download.stopping, let pressed = download.stopPressedAt {
                let took = Formatting.fixed(now - pressed, 2)
                log("\(download.filename): " + (download.succeeded
                    ? "finished before the cancel landed (\(took) s after Stop)"
                    : "canceled, partial file removed \(took) s after Stop was pressed"))
            }
            download.cancelRequestedAt = nil
            download.restartRequestedAt = nil
        }

        // 3b. Retry pressed on a canceled card, and the download finished
        // before a look saw its partial file: done, all the same.
        for download in tracked.values where download.canRestart {
            guard let requested = download.restartRequestedAt else { continue }
            let (verdict, final) = classifyVanished(download)
            if verdict == "done", let final {
                log("\(download.filename): finished right after Retry (\(Formatting.fixed(now - requested, 2)) s after the press)")
                download.finalPath = final
                download.succeeded = true
                download.resolvedAt = now
                download.restartRequestedAt = nil
                download.notice = nil
            }
        }
    }

    /// A number of seconds as Python writes it in a sentence: `10` for a
    /// whole number given as one, `0.6` otherwise.
    public static func pythonNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : JSON.python(value)
    }

    /// Steps 4 to 4e: whatever changed is sent.
    private func sendChanges(now: Double, awayCache: inout Bool?) throws {
        // 4. Send whatever changed. The sneak peek opens by itself when a
        // download finishes, pauses, fails or is canceled, and for messages
        // -- unless you're away: then it waits until you're back (step 4b).
        // Only `notchPlaces` downloads have a card of their own, and only
        // the first of them shows its status on it: see "Places".
        for download in assignPlaces(now) {
            if t.notchPlaces > 0 && download.lastSignature != nil {        // (it waited)
                log("\(download.filename): its turn, it has a card (\(Formatting.fixed(now - download.startedAt, 0)) s after it started)")
            }
        }
        var first = firstInPlace()
        let inSpot = tracked.values.contains(where: \.spot)
        shared.queueWaiting = t.notchPlaces > 0
            ? tracked.values.filter { !$0.place && !$0.spot && $0.resolvedAt == nil }.count : 0
        var inTurn = tracked.values
        if t.notchPlaces > 0, let first, first.created, !first.spot {
            // (its card's update goes after the others': the last word)
            inTurn = inTurn.filter { $0 !== first } + inTurn.filter { $0 === first }
        }
        for download in inTurn {
            var (surfaces, signature) = download.currentSurfaces(numericStyle)
            let kind = signature.kind
            if download.resolvedAt != nil && download.place && t.notchPlaces > 0 && download !== first && !download.spot {
                // Another download than the first is over: its card goes and
                // its place is the next one's. Its status shows in the main place.
                if download.created {
                    try dismiss(download.activityID)
                    download.created = false
                }
                download.place = false
                placesFreeFrom = now + t.placeGapSeconds
            }
            var onCard = download.place || download.spot      // (else it waits: nothing to send)
            // A pause known only from the closed partial file changes the
            // pill at once and opens its sneak peek a moment later (see
            // `earlyPeekDelay`).
            let peekWaits = kind == "paused" && download.peekNotBefore != nil && now < download.peekNotBefore!
            let peekDue = kind == "paused" && download.peekNotBefore != nil && !peekWaits && download.presentedState != kind
            let owed = download.created && download.peekOwed != nil && now >= download.peekOwed!.notBefore
            if signature == download.lastSignature && !peekDue && download.linePhase == download.linePhaseSent
                && !owed && (download.created || !onCard) {
                continue                                    // (the same card, and its line where it was)
            }
            let messageType = download.created ? "update" : "create"
            var payload = JSON.obj(["schemaVersion": .int(1), "type": .string(messageType),
                                    "activityID": .string(download.cardID), "surfaces": surfaces])
            if messageType == "create" {
                payload["title"] = .string("Download")
                payload["priority"] = .string("normal")
                payload["size"] = .string(activitySize)
            }
            var present: Int?
            if let last = download.lastSignature, signature.sameApartFromSettings(last), !peekDue {
                // only redrawn (a setting changed): no sneak peek
            } else if kind == "done" || kind == "canceled" || kind == "notice" {
                present = shared.presentSeconds(kind)
            } else if (kind == "paused" || kind == "failed") && download.presentedState != kind && !peekWaits {
                present = shared.presentSeconds(kind)         // once per pause or failure
            }
            if (kind == "paused" || kind == "failed") && !peekWaits {
                download.presentedState = kind
                download.peekNotBefore = nil
            }
            if let seconds = present, seconds != 0, Shared.holdable.contains(kind) {
                // It waits until you're back -- or for its turn in the main
                // place, when it isn't this download's own card that's
                // there, or when other cards wait for theirs. With "Focus
                // Mode" on, a finished one also waits while another download
                // is under way, and behind the finished ones that wait already.
                let away = waitingForYou(&awayCache)
                let others = tracked.values.filter { $0 !== download }
                let queued = settings.flag(.focusMode) && kind == "done" && !download.spot && others.contains { d in
                    d.underWay(now) || (d.held != nil && d.heldWhy == "focus")
                }
                let behind = !download.spot && others.contains { $0.held != nil && $0.heldWhy == "turn" }
                if away || queued || behind || !(t.notchPlaces <= 0 || download.spot || (download === first && !inSpot)) {
                    if download.held == nil && queued {
                        log("\(download.filename): done; shown when the other downloads are done too (Focus Mode)")
                    } else if download.held == nil && away {
                        log("\(download.filename): \(kind) while you're away; shown when you're back")
                    }
                    download.held = Held(kind: kind, seconds: seconds, since: download.held?.since ?? now)
                    download.heldWhy = queued ? "focus" : (away ? "away" : "turn")
                    present = nil
                    if queued && download.place && t.notchPlaces > 0 {
                        // Its card and its place go at once: the next ones move up.
                        if download.created {
                            try dismiss(download.activityID)
                            download.created = false
                        }
                        download.place = false
                        placesFreeFrom = now + t.placeGapSeconds
                        onCard = false
                    }
                }
            }
            var again = false
            if owed {
                if (present == nil || present == 0) && download.held == nil && (Shared.holdable.contains(kind) || kind == "notice") {
                    present = download.peekOwed!.seconds
                    again = true
                    if download.resolvedAt != nil {
                        download.resolvedAt = now           // (it stays its usual time from the sneak peek)
                    }
                }
                download.peekOwed = nil
            }
            if !onCard {
                download.lastSignature = signature
                download.linePhaseSent = download.linePhase
                continue
            }
            // Its own card says its status: the card takes the main place
            // for that (another app's activity may have it; the plugin
            // can't tell), with the high priority. Asked for a card that
            // isn't in the main place yet, a sneak peek is dropped: it's
            // asked for again a moment later (on a card that was there
            // already, that changes nothing).
            let rise = (present ?? 0) != 0 && supportsPresentSneakPeek && Shared.holdable.contains(kind) && !download.spot
                && !again && t.notchPlaces > 0
            if rise {
                payload["priority"] = .string("high")
                raised.set(download.activityID, nil)
                settling.removeValue(forKey: download.activityID)
            }
            if messageType == "create" {
                download.createdAt = now
                if let seconds = present, seconds != 0 {     // (asked for with the card, it's ignored: a moment later)
                    download.peekOwed = (seconds, now + t.peekAfterCreate)
                    present = nil
                }
            } else if rise {
                download.peekOwed = (present!, now + t.peekAfterCreate)
            }
            if supportsPresentSneakPeek, let seconds = present, seconds != 0 {
                payload["presentSneakPeek"] = .int(seconds)
                download.peekUntil = now + Double(seconds)
                if Shared.holdable.contains(kind) {           // (its line stays still at first, from now)
                    download.lineFrom = now
                    (surfaces, signature) = download.currentSurfaces(numericStyle)
                    payload["surfaces"] = surfaces
                    if download.spot && download.resolvedAt == nil {
                        download.spotUntil = now + Double(seconds) + t.spotMarginSeconds
                    } else if t.notchPlaces > 0 {            // (a status card waits until this one has been seen)
                        nextReplayAt = max(nextReplayAt, now + (download.resolvedAt != nil
                            ? shared.keepSeconds(download) : Double(seconds)) + 0.3)
                    }
                    if raised.contains(download.activityID) && !download.spot && download.resolvedAt == nil {
                        raised.set(download.activityID, now + Double(seconds) + t.spotMarginSeconds)     // (step 4e)
                    }
                }
            } else if supportsPresentSneakPeek && download.linePhaseSent == "held" && download.linePhase == "scrolling",
                      let until = download.peekUntil, until - now >= 0.5 {
                // The line starts to scroll while the sneak peek the plugin
                // opened is still open. DynamicLake only shows a new text in
                // it when it's asked for again: for the time that's left.
                payload["presentSneakPeek"] = .int(max(1, min(t.maxPresentSeconds, Int((until - now).rounded(.toNearestOrEven)))))
            }
            try send(payload)
            if !download.spot {
                download.sentSurfaces = payload["surfaces"]
            }
            download.created = true
            download.lastSignature = signature
            download.linePhaseSent = download.linePhase
        }

        // 4b. You're back: open the sneak peeks that waited, one at a time,
        // oldest first. A finished or canceled card then stays its usual time.
        for download in tracked.values {
            if let held = download.held, now - held.since > t.holdMaxSeconds {
                download.held = nil                     // waited long enough
                if download.resolvedAt != nil {
                    download.resolvedAt = now
                }
            }
        }
        // The same goes for the sneak peeks that waited for their turn in the
        // main place: a download that isn't the first shows there on a card
        // made for that (see "Places"). Finished cards that wait because of
        // "Focus Mode" join the line when no download is under way (or the
        // setting is turned off).
        if !settings.flag(.focusMode) || !tracked.values.contains(where: { $0.underWay(now) }) {
            for download in tracked.values where download.held != nil && download.heldWhy == "focus" {
                download.heldWhy = "turn"
            }
        }
        let inLine = tracked.values.filter { $0.held != nil && $0.heldWhy != "focus" }
        let byWaiting: (Download, Download) -> Bool = { a, b in
            (a.held!.since, a.seq) < (b.held!.since, b.seq)
        }
        var together: [Download] = []
        if now >= nextReplayAt && !inLine.isEmpty && settings.flag(.smartSlideshows) && t.notchPlaces > 0
            && !tracked.values.contains(where: \.spot) && !waitingForYou(&awayCache) {
            // "Smart Slideshows": the finished downloads that wait for their
            // card (for the other downloads, with "Focus Mode"; for you,
            // with "Delayed Display"; or for their turn) get one card
            // between them, with their number. Their own cards and places go
            // (if they still had them), and all but the first of them are
            // done with here.
            together = inLine.sorted(by: byWaiting).filter { d in
                d.resolvedAt != nil && d.succeeded && !d.spot && d.currentSurfaces(numericStyle).1.kind == "done"
            }
        }
        if together.count >= 2 {
            for download in together {
                if download.created {
                    try dismiss(download.activityID)
                    download.created = false
                }
                if download.place {
                    download.place = false
                    placesFreeFrom = now + t.placeGapSeconds
                }
                download.held = nil
            }
            let one = together[0]
            one.summary = together.map(\.finalPath)
            for download in together.dropFirst() {
                download.resolvedAt = now - shared.keepSeconds(download) - 1.0     // (step 5 lets it go at once)
            }
            try startSpot(one, kind: "done", now: now)
            log("\(together.count) downloads done, shown on one card (Smart Slideshows): "
                + together.map(\.filename).joined(separator: ", "))
        } else if now >= nextReplayAt && !inLine.isEmpty && !tracked.values.contains(where: \.spot) && !waitingForYou(&awayCache) {
            first = firstInPlace()
            for download in inLine.sorted(by: byWaiting) {
                var (surfaces, signature) = download.currentSurfaces(numericStyle)
                if signature.kind == "active" {
                    download.held = nil                 // it carries on: nothing to show
                    continue
                }
                if !Shared.holdable.contains(signature.kind) {
                    continue                            // a message on it for now, or its browser closed: later
                }
                let since = download.held!.since
                let why = download.heldWhy
                if t.notchPlaces > 0 && download !== first {
                    download.held = nil
                    try startSpot(download, kind: signature.kind, now: now)
                    log("\(download.filename): \(signature.kind), shown in the main place"
                        + (why == "away" ? " now that you're back (\(Formatting.fixed(now - since, 0)) s later)" : ""))
                    break
                }
                if !download.created || now - download.createdAt < t.peekAfterCreate {
                    break                               // (its card is only just there: in a moment)
                }
                download.held = nil
                download.lineFrom = now                 // (its line stays still at first, from now)
                (surfaces, signature) = download.currentSurfaces(numericStyle)
                var payload = JSON.obj(["schemaVersion": .int(1), "type": .string("update"),
                                        "activityID": .string(download.activityID), "surfaces": surfaces])
                if supportsPresentSneakPeek {
                    let seconds = shared.presentSeconds(signature.kind)
                    payload["presentSneakPeek"] = .int(seconds)
                    download.peekUntil = now + Double(seconds)
                    if t.notchPlaces > 0 {
                        // (as in step 4: its card takes the main place for it,
                        // and the sneak peek is asked for again a moment later)
                        payload["priority"] = .string("high")
                        settling.removeValue(forKey: download.activityID)
                        raised.set(download.activityID, download.resolvedAt != nil ? nil
                            : now + Double(seconds) + t.spotMarginSeconds)
                        download.peekOwed = (seconds, now + t.peekAfterCreate)
                    }
                }
                try send(payload)
                download.sentSurfaces = payload["surfaces"]
                download.lastSignature = signature
                download.linePhaseSent = download.linePhase
                var gap = t.replayGapSeconds
                if download.resolvedAt != nil {
                    download.resolvedAt = now
                    gap = max(gap, shared.keepSeconds(download) + 0.3)    // (after this card has gone)
                }
                nextReplayAt = now + gap
                if why == "away" {
                    log("\(download.filename): \(signature.kind), shown now that you're back (\(Formatting.fixed(now - since, 0)) s later)")
                }
                break
            }
        }

        // 4c. The cards lowered to give the main place back: whatever moves
        // up is there by now. Their usual priority again, the oldest
        // download's first (those that are still there).
        let due = settling.items.filter { now >= $0.value }.map(\.key)
        if !due.isEmpty {
            for card in ownCards() where due.contains(card) && !raised.contains(card) && card != spotPinned {
                try sendPriority(card, "normal")
            }
            for card in due {
                settling.removeValue(forKey: card)
            }
        }

        // 4d. A paused or failed download's status card has had its time in
        // the main place (not while a button works on it, or says
        // something), or the download carries on.
        for download in tracked.values {
            if !download.spot || download.resolvedAt != nil || download.peekOwed != nil { continue }
            if download.job != nil || download.restartPending || (download.notice != nil && now < download.noticeUntil) { continue }
            if download.spotUntil == nil || now >= download.spotUntil!
                || (download.shownState(now) == "active" && !download.browserClosed) {
                try endSpot(download, now: now)
            }
        }

        // 4e. A download's own card has had the main place for its pause or
        // its failure (not while a button works on it, or says something),
        // or the download carries on: the place is given back. All the
        // plugin's cards get the low priority for a moment, this one last:
        // another app's activity moves up if there's one; if not, this card
        // stays where it is (between equals, the card that's there stays).
        // A finished or canceled download's card just goes at its time.
        for (card, until) in raised.items {
            guard let download = tracked.values.first(where: { $0.activityID == card && $0.created && !$0.spot }) else {
                raised.removeValue(forKey: card)        // (the card has gone)
                continue
            }
            if download.resolvedAt != nil || download.peekOwed != nil { continue }
            if download.job != nil || download.restartPending || (download.notice != nil && now < download.noticeUntil) { continue }
            if until == nil || now >= until! || (download.shownState(now) == "active" && !download.browserClosed) {
                raised.removeValue(forKey: card)
                try lower(ownCards(but: card).filter { !raised.contains($0) && $0 != spotPinned } + [card], now)
                log("\(download.filename): its card has had the main place for its status; the place is given back")
            }
        }
    }
}
