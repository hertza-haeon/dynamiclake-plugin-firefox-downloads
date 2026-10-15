// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A downloads.json version the partial file outgrew (see `updateState`).
enum StaleVersion: Equatable {
    case none
    /// Whichever is current first.
    case firstSeen
    case version(ListVersion)
}

/// What decides whether a card is sent again: its first item is the kind
/// of card ("done", "canceled", "paused", "failed", "closed", "active" or
/// "notice"), its last the settings' generation.
struct Signature: Equatable {
    var items: [JSON]
    var generation: Int

    var kind: String { items[0].string ?? "" }

    /// The same apart from the settings (a setting changed: only redrawn).
    func sameApartFromSettings(_ other: Signature) -> Bool {
        items == other.items
    }
}

/// A sneak peek kept for later: of which kind, for how long, since when.
struct Held: Equatable {
    var kind: String
    var seconds: Int
    var since: Double
}

/// Firefox names a partial download `<name up to its first dot>.<8 random
/// base64url characters><rest>.part` (nsExternalHelperAppService.cpp).
/// This undoes the random part; `raw` is that name without ".part".
func realNameFromPart(_ raw: String) -> String {
    let scalars = Array(raw.unicodeScalars)
    guard let dot = scalars.firstIndex(of: ".") else { return raw }
    let chunk = scalars[(dot + 1)..<min(scalars.count, dot + 9)]
    let after = dot + 9 <= scalars.count ? Array(scalars[(dot + 9)...]) : []
    let random = chunk.count == 8 && chunk.allSatisfy { scalar in
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
    }
    if random && (after.isEmpty || after.first == ".") {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars[..<dot])
        kept.append(contentsOf: after)
        return String(kept)
    }
    return raw
}

/// One download: a partial file in a watched folder, and its card.
final class Download {
    let shared: Shared
    var partPath: String
    /// Firefox inserts 8 random characters into the partial file's name
    /// ("report.ab3_Xy9Q.pdf.part" for "report.pdf"); they are taken out to
    /// get the real name. The name with them is kept as a fallback in case
    /// a genuine name just happens to look like that pattern.
    var finalPath: String
    var rawFinalPath: String
    /// The order downloads started in.
    let seq: Int
    let activityID: String
    var samples: [(at: Double, size: Int)] = []
    /// From downloads.json, once known.
    var totalSize: Int?
    /// The process of the browser downloading it.
    var browser = ""
    var startedAt: Double
    var totalLogged = false
    var created = false
    var lastSignature: Signature?
    var missingTicks = 0
    /// Set once done, canceled or blocked.
    var resolvedAt: Double?
    var resolvedReason = "Canceled"
    var succeeded = false
    var notice: String?
    var noticeUntil = 0.0
    /// "active", "paused" or "failed" -- from downloads.json (see
    /// `DownloadsListFile.state(of:)`).
    var state = "active"
    /// The partial file's size when it paused or failed.
    var stateSize = 0
    /// Measurements in a row it has grown since.
    var growthTicks = 0
    /// The last measurement looked at.
    var growthCheckedAt: Double?
    var staleVersion = StaleVersion.none
    /// The state the sneak peek opened for.
    var presentedState: String?
    /// When data last arrived.
    var lastGrowthAt: Double
    var stallLogged = false
    /// The browser profile listing it.
    var profile: String?
    /// Its browser quit (the download waits).
    var browserClosed = false
    /// A pause kept back until then (the Mac woke).
    var holdUntil = 0.0
    /// When the browser was first seen to have closed the partial file (it
    /// stopped the download)...
    var closedSeenAt: Double?
    /// ...and the file's size then.
    var closedSize = 0
    /// Closed looks that found it bigger, since it was last seen open.
    var closedGrowths = 0
    /// The file grew while "closed": the wrong process was asked; not asked
    /// again for this download.
    var noEarlyStop = false
    /// Paused by the closed file alone, so far...
    var earlyPaused = false
    /// ...its sneak peek opens then (`earlyPeekDelay`).
    var peekNotBefore: Double?
    /// A sneak peek kept for when you're back.
    var held: Held?
    /// The smoothed time left, and when it was estimated.
    var eta: Double?
    var etaAt = 0.0
    /// The time left on screen (it counts down), and when it was that much...
    var etaShown: Double?
    var etaShownAt = 0.0
    /// ...and when its next second shows.
    var timeTickAt: Double?
    /// When the card's text changes by itself (see `rateText`).
    var textDue: Double?
    /// The status its line is about ("Paused"...), since when (it stays
    /// still at first: see `statusLine`), whether it's "held" still or
    /// "scrolling" ("": fits), and as it was last sent.
    var lineWord: String?
    var lineFrom = 0.0
    var linePhase = ""
    var linePhaseSent = ""
    /// Until when the sneak peek the plugin opened stays open.
    var peekUntil: Double?
    // Its place among the cards: see "Places".
    /// It has a card of its own (else it waits its turn).
    var place = false
    /// Its status shows in the main place, on a card made for that...
    var spot = false
    /// ...which goes then (a paused or failed download's)...
    var spotUntil: Double?
    /// ...while its own card stays where it is (it has a place).
    var ownCard = false
    /// When the card it has was created.
    var createdAt = 0.0
    /// A sneak peek that card still has to open: (seconds, not before).
    var peekOwed: (seconds: Int, notBefore: Double)?
    /// What `held` waits for: you ("away"), the main place ("turn"), the
    /// other downloads ("focus").
    var heldWhy = ""
    /// What its own card shows, as sent last (for the last word).
    var sentSurfaces: JSON?
    /// "Smart Slideshows": the files of the finished downloads this one's
    /// status card stands for (its own among them).
    var summary: [String] = []
    // Stop, Resume and Retry.
    /// The button's work in flight.
    var job: ActionJob?
    var stopPressedAt: Double?
    /// Cancel was pressed.
    var cancelRequestedAt: Double?
    /// Resume or Retry was pressed...
    var restartRequestedAt: Double?
    /// ...which of them.
    var restartKind = ""
    /// Retry pressed on its canceled card.
    var restartPressedAt: Double?

    init(_ partPath: String, shared: Shared) {
        self.shared = shared
        self.partPath = partPath
        let raw = String(Paths.name(partPath).unicodeScalars.dropLast(5))
        finalPath = Paths.withName(partPath, realNameFromPart(raw))
        rawFinalPath = Paths.withName(partPath, raw)
        seq = shared.nextSeq()
        activityID = "dl-\(seq)"
        startedAt = monotonic()
        lastGrowthAt = startedAt
    }

    var t: Tunables { shared.t }

    var filename: String { Paths.name(finalPath) }

    /// The card its updates go to: its own, or the one that shows its
    /// status in the main place (see "Places").
    var cardID: String { spot ? activityID + Plugin.statusCardSuffix : activityID }

    /// Follow the download to another partial file (Retry after a cancel,
    /// when the browser starts it over under a new name).
    func move(to partPath: String) {
        let raw = String(Paths.name(partPath).unicodeScalars.dropLast(5))
        self.partPath = partPath
        finalPath = Paths.withName(partPath, realNameFromPart(raw))
        rawFinalPath = Paths.withName(partPath, raw)
    }

    /// A Stop is in flight: the script is running, or Cancel was pressed
    /// and the plugin waits for the browser to remove the partial file.
    var stopping: Bool {
        job?.kind == "stop" || cancelRequestedAt != nil
    }

    /// A Stop, Resume or Retry is in flight (script running, or pressed and
    /// waiting for the browser to act on it).
    var busy: Bool {
        job != nil || cancelRequestedAt != nil || restartRequestedAt != nil
    }

    /// The browser was just seen to have closed the partial file: it's
    /// looked at again in a moment (see `earlyStopConfirm`), and again and
    /// again until the sneak peek of that pause is due (is the browser
    /// still there? see `earlyPeekDelay`).
    var settling: Bool {
        if resolvedAt != nil { return false }
        if closedSeenAt != nil && state == "active" { return true }
        if let notBefore = peekNotBefore, state == "paused" { return monotonic() < notBefore + 1.0 }
        return false
    }

    /// Back to downloading after a pause or failure: measure the speed
    /// afresh (the time spent stopped isn't part of it).
    func restarted() {
        if let last = samples.last {
            samples = [last]
        }
        growthTicks = 0
        presentedState = nil
        earlyPaused = false
        peekNotBefore = nil
        lastGrowthAt = monotonic()
        holdUntil = 0
        eta = nil
        etaShown = nil
        if let held, held.kind == "paused" || held.kind == "failed" {
            self.held = nil           // nothing left to show you
        }
    }

    /// Canceled (its partial file went away, and not blocked): the
    /// browser's Retry starts it over.
    var canRestart: Bool {
        resolvedAt != nil && !succeeded && resolvedReason == "Canceled"
    }

    /// Retry was pressed on its canceled card: the script is running, or it
    /// pressed Retry and the browser hasn't started it over yet.
    var restartPending: Bool {
        job?.kind == "restart" || (resolvedAt != nil && restartRequestedAt != nil)
    }

    /// Downloading again after it was canceled: Retry (the plugin's or the
    /// browser's own) started it over, in the same partial file.
    func reopen(_ now: Double) {
        resolvedAt = nil
        succeeded = false
        resolvedReason = "Canceled"
        state = "active"
        samples.removeAll()
        missingTicks = 0
        // What downloads.json says at this moment is from before the
        // restart (Firefox rewrites it about 1.5 s after): not believed.
        staleVersion = .firstSeen
        stateSize = 0
        growthTicks = 0
        growthCheckedAt = nil
        presentedState = nil
        held = nil
        stopPressedAt = nil
        cancelRequestedAt = nil
        restartRequestedAt = nil
        restartPressedAt = nil
        browserClosed = false
        holdUntil = 0
        closedSeenAt = nil
        earlyPaused = false
        peekNotBefore = nil
        lastGrowthAt = now
        stallLogged = false
        eta = nil
        etaShown = nil
        if notice == Notices.working["restart"] {
            notice = nil              // "Retrying…": it has
        }
    }

    /// Measures the partial file (at most every `minSampleGap`).
    @discardableResult
    func sample() -> Int? {
        let now = monotonic()
        if let last = samples.last, now - last.at < t.minSampleGap {
            return last.size
        }
        guard let size = Paths.size(partPath) else { return nil }
        if let last = samples.last, size < last.size {
            // It started over (Retry from a server that can't resume): measure afresh.
            samples.removeAll()
            eta = nil
            etaShown = nil
        }
        if samples.isEmpty || size > samples.last!.size {
            lastGrowthAt = now
        }
        samples.append((now, size))
        if samples.count > t.speedWindow {
            samples.removeFirst(samples.count - t.speedWindow)
        }
        return size
    }

    /// Downloading, but no data for `stallSeconds` (while its browser is
    /// open, and not a pause held back after the Mac woke).
    func stalled(_ now: Double) -> Bool {
        state == "active" && !browserClosed && now - lastGrowthAt >= t.stallSeconds
    }

    /// Still downloading: not over, not paused or failed, its browser open,
    /// and data coming (not stalled). With "Focus Mode" on, finished
    /// downloads' cards wait until no download is.
    func underWay(_ now: Double) -> Bool {
        resolvedAt == nil && shownState(now) == "active" && !browserClosed && !stalled(now)
    }

    /// The state the card shows: a pause held back after the Mac woke
    /// (Firefox resumes those itself) still shows as downloading. So does a
    /// download the browser has just stopped, until its downloads.json says
    /// whether that's a pause or a failure (see `earlyPeekDelay`): the card
    /// then changes once, to the right one.
    func shownState(_ now: Double) -> String {
        if state == "paused" && now < holdUntil { return "active" }
        if state == "paused" && earlyPaused, let notBefore = peekNotBefore, now < notBefore { return "active" }
        return state
    }

    /// Whole seconds left, or nothing until there's enough steady data to
    /// tell. The estimate follows the speed, smoothed; what's shown counts
    /// down by itself, second by second, and is set right when it has
    /// drifted from the estimate (see `Formatting.timeLeftMargin`).
    func timeLeft(_ now: Double) -> Int? {
        timeTickAt = nil
        guard let total = totalSize, total != 0, percent != nil, samples.count >= 2,
              samples.last!.at - samples.first!.at >= t.timeLeftSpan else {
            eta = nil
            etaShown = nil
            return nil
        }
        let speed = self.speed
        if speed < 1024 { return nil }   // (the speed shows "--"; the estimate resumes with the data)
        let raw = max(0.0, Double(total - size) / speed)
        if let eta {
            let predicted = max(0.0, eta - (now - etaAt))   // it counts down by itself
            if raw > 2 * predicted + 30 || raw < 0.5 * predicted - 30 {
                self.eta = raw                              // a real change of pace
            } else {
                let weight = 1 - exp(-max(0.0, now - etaAt) / 3.0)
                self.eta = predicted + weight * (raw - predicted)
            }
        } else {
            self.eta = raw
        }
        etaAt = now
        var shown = etaShown.map { $0 - (now - etaShownAt) }
        if shown == nil || abs(self.eta! - shown!) > Formatting.timeLeftMargin(max(0.0, shown!)) {
            shown = self.eta
        }
        etaShown = shown
        etaShownAt = now
        let whole = max(1, Int(shown!.rounded(.up)))
        timeTickAt = now + max(0.0, shown! - Double(whole - 1))
        return whole
    }

    var size: Int { samples.last?.size ?? 0 }

    var speed: Double {
        guard samples.count >= 2 else { return 0 }
        let (t0, s0) = samples.first!
        let (t1, s1) = samples.last!
        let dt = t1 - t0
        return dt > 0 ? Double(s1 - s0) / dt : 0
    }

    /// Fraction done, or nothing when the total is unknown -- or wrong: a
    /// file already bigger than its "total" (a server reporting the
    /// compressed size, say) gets the spinning ring instead of a stuck 100%.
    var percent: Double? {
        guard let total = totalSize, total != 0, size <= total else { return nil }
        return max(0.0, min(1.0, Double(size) / Double(total)))
    }

    /// Rounded down, so it never reads 100% before the file is complete.
    var percentText: String {
        guard let percent else { return "—" }
        return "\(Int(percent * 100))%"
    }

    /// The card as it is now, and its signature: the plugin sends an update
    /// only when something actually changed.
    func currentSurfaces(_ numericStyle: String = "compact") -> (JSON, Signature) {
        let now = monotonic()
        let gen = shared.settings.generation
        let faces = Faces(shared)
        textDue = nil
        linePhase = ""
        var surfaces: JSON
        var signature: Signature
        if resolvedAt != nil {
            if succeeded && !summary.isEmpty {
                // (the one card for several finished downloads: nothing else goes on it)
                return (faces.summary(self, count: summary.count), Signature(items: [.string("done"), .int(summary.count)], generation: gen))
            }
            if succeeded {
                surfaces = faces.done(self, numericStyle, now: now)
                signature = Signature(items: [.string("done")], generation: gen)
            } else {
                surfaces = faces.canceled(self, reason: resolvedReason, now: now)
                signature = Signature(items: [.string("canceled"), .string(resolvedReason)], generation: gen)
            }
        } else {
            let state = shownState(now)
            let icon = faces.pillIconKey(self, now: now)    // (the arrow, then the file's type)
            if browserClosed {
                // Its browser quit. There's nothing to press until it
                // reopens: then Firefox carries on with a download that was
                // in progress by itself, and a paused or failed one waits
                // for Resume or Retry as before.
                let closedAs = state == "paused" || state == "failed" ? state : "closed"
                if closedAs == "failed" {
                    surfaces = faces.failed(self, numericStyle, withButton: false, now: now)
                } else if closedAs == "paused" {
                    surfaces = faces.paused(self, numericStyle, withButton: false, now: now)
                } else {
                    surfaces = faces.paused(self, numericStyle, withButton: false, word: "Browser closed", now: now)
                }
                signature = Signature(items: [.string("closed"), .string(closedAs), .string(percentText), .string(icon)],
                                      generation: gen)
            } else if state == "paused" {
                surfaces = faces.paused(self, numericStyle, now: now)
                signature = Signature(items: [.string("paused"), .string(percentText), .string(icon)], generation: gen)
            } else if state == "failed" {
                surfaces = faces.failed(self, numericStyle, now: now)
                signature = Signature(items: [.string("failed"), .string(percentText), .string(icon)], generation: gen)
            } else {
                let stalled = self.stalled(now)
                surfaces = faces.inProgress(self, numericStyle, stalled: stalled, now: now)
                signature = Signature(items: [.string("active"), .int(size), totalSize.map { .int($0) } ?? .null,
                                              .int(stalled ? 0 : Int((now / 2).rounded(.down))), .bool(stalled),
                                              surfaces["sneakPeek"]?["center"]?["text"] ?? .null, .string(icon)],
                                      generation: gen)
            }
        }
        surfaces["extraLiveActivity"] = faces.extra(self)
        let centerText = surfaces["sneakPeek"]?["center"]?["text"]?.string ?? ""
        if linePhase.isEmpty && !centerText.contains(Faces.bullet) {
            lineWord = nil           // (not a status line: the next one starts its time afresh)
        }
        if let notice, now < noticeUntil {
            surfaces["sneakPeek"]?["center"] = .obj(["type": .string("text"), "text": .string(notice), "style": .string("marquee")])
            return (surfaces, Signature(items: [.string("notice"), .string(signature.kind), .string(notice), .string(percentText)],
                                        generation: gen))
        }
        if notice != nil {
            notice = nil
        }
        return (surfaces, signature)
    }
}

/// What a vanished partial file means: done (with the file), canceled, or
/// unsure (with the file).
///
/// Firefox reserves the final name with an EMPTY placeholder file for the
/// whole download. On success it renames the partial file over that
/// placeholder; on cancel it deletes the partial file and, a moment later,
/// the placeholder. So a non-empty final file means finished; no final
/// file, or an empty one after data had arrived, means canceled; an empty
/// file for a download that never received data can't be told apart yet.
func classifyVanished(_ download: Download) -> (verdict: String, file: String?) {
    var empty: String?
    var candidates = [download.finalPath]
    if download.rawFinalPath != download.finalPath { candidates.append(download.rawFinalPath) }
    for candidate in candidates {
        guard let size = Paths.size(candidate) else { continue }
        if size > 0 { return ("done", candidate) }
        if empty == nil { empty = candidate }
    }
    if empty == nil || download.size > 0 { return ("canceled", nil) }
    return ("unsure", empty)
}
