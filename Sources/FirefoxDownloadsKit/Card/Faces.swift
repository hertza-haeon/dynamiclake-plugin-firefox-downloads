// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// What DynamicLake draws for a download:
//
//                    compact pill                sneak peek
//                    left        right           left           center                  right
//   downloading      type        blue ring       red stop       294/871MB · 2 min 34 s  18%
//   stalled          type        red ...         red stop       Stalled • name          18%
//   paused           type        orange pause    green play     Paused • name           18%
//   failed           type        red !           blue retry     Failed • name           18%
//   finished         type        green check     blue folder    Complete • name         blue file
//   canceled         type        red X           blue retry     Canceled • name
//   blocked          type        red bar         (none)         Blocked • name
//   browser closed   type        orange pause    (none)         Browser closed • name   18%
//
// (A paused or failed download whose browser was closed keeps its card,
// with no button: Resume and Retry need the browser.) "type" is the file's
// extension in a blue circle ("pdf", "dmg"...). A new download shows the
// blue download arrow for its first seconds; the arrow stays with the
// setting "File-Type Icons" off, and for a file without an extension.
//
// Beside another activity that has the main place, a download is
// DynamicLake's small capsule: it shows "type" alone, in every state (see
// `extra`).
//
// The ring's place holds one of the plugin's pictures, or DynamicLake's own
// nearest "status" symbol where none can be drawn; every button is an SF
// Symbol glyph on a tinted circle, so they all share one size and look.

/// The parts of a download's card.
struct Faces {
    let shared: Shared

    init(_ shared: Shared) {
        self.shared = shared
    }

    static let arrowSymbol = "arrow.down.circle"
    /// The most characters of an extension the circle shows.
    static let badgeChars = 4
    /// "Complete • report.pdf"
    static let bullet = " • "

    private var settings: Settings { shared.settings }

    private static func text(_ text: String, _ style: String) -> JSON {
        .obj(["type": .string("text"), "text": .string(text), "style": .string(style)])
    }

    /// The file's extension as the blue circle shows it ("report.PDF" ->
    /// "pdf"; four characters at most), or "" when it has none that can be
    /// shown (then the arrow stays).
    static func badgeText(_ filename: String) -> String {
        let scalars = Array(filename.unicodeScalars)
        guard let dot = scalars.lastIndex(of: "."), scalars[..<dot].contains(where: { $0 != "." }) else { return "" }
        let ext = scalars[(dot + 1)...]
        guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { return "" }
        return String(FirefoxDownloadsKit.text(ext.prefix(badgeChars))).lowercased()
    }

    /// What the pill's left side shows: "" for the blue arrow (a download's
    /// first seconds, the setting "File-Type Icons" off, or no extension),
    /// else the extension; either one in the same blue circle.
    func pillIconKey(_ download: Download, now: Double) -> String {
        if !settings.flag(.fileTypeIcons) { return "" }
        if download.resolvedAt == nil && now < download.startedAt + shared.t.iconDelaySeconds { return "" }
        return Self.badgeText(download.filename)
    }

    /// The blue circle with the extension `key` in it, or with the download
    /// arrow for "".
    func icon(_ key: String) -> JSON {
        let picture = key.isEmpty ? shared.pictures.image("arrow") : shared.pictures.image("type", key)
        return picture ?? .obj(["type": .string("image"), "source": .string("sfSymbol"), "systemImage": .string(Self.arrowSymbol),
                                "tint": .string("blue")])
    }

    func pillIcon(_ download: Download, now: Double? = nil) -> JSON {
        icon(pillIconKey(download, now: now ?? monotonic()))
    }

    /// What DynamicLake's small capsule beside the notch shows for this
    /// download while another activity has the main place: the file's type
    /// in its blue circle (the arrow with the setting "File-Type Icons"
    /// off, and for a file without an extension). DynamicLake draws the
    /// capsule once, when the card gets there, and not again while it
    /// stays: a ring or a status symbol would go on showing what was true
    /// at that moment. The file's type stays true, so it's there from the
    /// first second, without the arrow's turn.
    func extra(_ download: Download) -> JSON {
        .obj(["leftSlot": icon(settings.flag(.fileTypeIcons) ? Self.badgeText(download.filename) : "")])
    }

    /// The pill's right side for a state, drawn by the plugin (nothing
    /// where it can't be drawn: the caller then uses DynamicLake's nearest
    /// symbol).
    func stateSymbol(_ kind: String) -> JSON? {
        shared.pictures.image(kind)
    }

    /// "Complete • report.pdf": what happened, then the file's name (the
    /// line scrolls when it's long). Never longer than DynamicLake accepts:
    /// a very long name is shortened in the middle.
    func statusText(_ word: String, _ download: Download) -> String {
        var name = Array(download.filename.unicodeScalars)
        let room = shared.t.maxTextChars - word.unicodeScalars.count - Self.bullet.unicodeScalars.count
            - TextRuler.leadBlank.unicodeScalars.count
        if name.count > room {
            let keep = room - 1
            name = Array(name.prefix(max(0, keep - keep / 2))) + ["…"] + Array(name.suffix(from: max(0, name.count - keep / 2)))
        }
        return word + Self.bullet + FirefoxDownloadsKit.text(name)
    }

    /// The status card's line. When it's too long for the sneak peek,
    /// DynamicLake scrolls it, and starts at once: the status would be gone
    /// before it's read. So for `scrollHoldSeconds` it's shown cut short,
    /// which stays still ("Paused • Some.Long.Na…"), and only then whole,
    /// to scroll -- with a blank before it, to keep its first letter clear
    /// of the fade on the left. The time counts from when the status came
    /// up, or from when the plugin opened the sneak peek for it
    /// (`Download.lineFrom`).
    func statusLine(_ word: String, _ download: Download, now: Double? = nil) -> String {
        let now = now ?? monotonic()
        let full = statusText(word, download)
        let short = shared.ruler.fitted(full)
        if download.lineWord != word {
            download.lineWord = word
            download.lineFrom = now
        }
        guard let short else {
            download.linePhase = ""
            return full
        }
        let until = download.lineFrom + shared.t.scrollHoldSeconds
        if now < until {
            download.linePhase = "held"
            if download.textDue == nil || until < download.textDue! {
                download.textDue = until
            }
            return short
        }
        download.linePhase = "scrolling"
        return TextRuler.leadBlank + full
    }

    /// Icon only, a red square in a red circle: no "Stop" text on screen.
    /// `title` is only the VoiceOver label.
    func stopButton(_ download: Download) -> JSON {
        .obj(["type": .string("button"), "title": .string("Stop"), "systemImage": .string("stop.fill"),
              "actionID": .string("stop:\(download.activityID)"), "shape": .string("circle"),
              "tint": .string("red"), "role": .string("destructive")])
    }

    /// Show in Finder: a blue folder in a blue circle, the counterpart of
    /// the Stop button.
    func showButton(_ download: Download) -> JSON {
        .obj(["type": .string("button"), "title": .string("Show in Finder"), "systemImage": .string("folder.fill"),
              "actionID": .string("show:\(download.activityID)"), "shape": .string("circle"), "tint": .string("blue")])
    }

    /// Open File: an arrow in an app's square (macOS's sign for "open in
    /// its app") in a blue circle, across from Show in Finder's folder. It
    /// opens the finished file in the app for its type.
    func openButton(_ download: Download) -> JSON {
        .obj(["type": .string("button"), "title": .string("Open File"), "systemImage": .string("arrow.up.forward.app.fill"),
              "actionID": .string("open:\(download.activityID)"), "shape": .string("circle"), "tint": .string("blue")])
    }

    /// Resume: a green play triangle in a green circle, where Stop was.
    func resumeButton(_ download: Download) -> JSON {
        .obj(["type": .string("button"), "title": .string("Resume"), "systemImage": .string("play.fill"),
              "actionID": .string("resume:\(download.activityID)"), "shape": .string("circle"), "tint": .string("green")])
    }

    /// Retry: a blue circular arrow in a blue circle, where Stop was. The
    /// action is "retry" on a failed card and "restart" on a canceled one
    /// (the browser starts that download over).
    func retryButton(_ download: Download, action: String = "retry") -> JSON {
        .obj(["type": .string("button"), "title": .string("Retry"), "systemImage": .string("arrow.clockwise"),
              "actionID": .string("\(action):\(download.activityID)"), "shape": .string("circle"), "tint": .string("blue")])
    }

    /// The sneak peek's right slot. Side slots widen just enough for
    /// numeric text like "100%"; other text styles show only two characters
    /// there, so without the numeric style (older DynamicLake) the % sign
    /// is dropped and a value that still wouldn't fit is left out.
    func percentSlot(_ text: String, _ numericStyle: String) -> JSON {
        if numericStyle == "numeric" {
            return .obj(["rightSlot": Self.text(text, "numeric")])
        }
        let short = stripTrailing(text.unicodeScalars, ["%"])
        if short.unicodeScalars.count > 2 { return .object([]) }
        return .obj(["rightSlot": Self.text(short, numericStyle)])
    }

    /// "+2 Queuing": the downloads that wait for a card; "" when none does.
    func queueText() -> String {
        shared.queueWaiting > 0 ? "+\(shared.queueWaiting) Queuing" : ""
    }

    /// After the amounts (setting "Download Details"): the speed, the time
    /// left, the downloads that wait ("+2 Queuing"; nothing when none
    /// does), or all of them in turn, `detailsTurnSeconds` each -- each
    /// then as wide as the widest, so that the line stays where it is when
    /// they change places; under a minute the time left counts as its
    /// widest ("88 seconds"), so that the line doesn't move at "9 seconds"
    /// or at "1 second" either. The speed also shows where the time left
    /// can't be told yet. Sets `textDue`: when this text changes by itself
    /// (the next second of the time left, the next turn), for the main loop
    /// to send it on time.
    func rateText(_ download: Download, now: Double) -> String {
        let details = settings.details
        let speed = Formatting.speed(download.speed)
        if details == "speed" { return speed }
        if details == "queue" { return queueText() }
        let left = download.timeLeft(now)
        let timed = left.map { Formatting.time($0) }
        var shown: String
        var shownIsTimed = false
        var turns: [String] = []
        if details == "time" {
            shown = timed ?? speed
            shownIsTimed = timed != nil
        } else {
            // All: the speed first, then the time left, then the downloads
            // that wait -- those that there are.
            var entries: [(text: String, isTimed: Bool)] = []
            for (candidate, isTimed) in [(speed, false), (timed, true), (queueText(), false)] {
                if let candidate, !candidate.isEmpty { entries.append((candidate, isTimed)) }
            }
            turns = entries.map(\.text)
            let (turn, into) = pythonDivmod(max(0.0, now - download.startedAt), shared.t.detailsTurnSeconds)
            download.textDue = now + shared.t.detailsTurnSeconds - into
            let index = Int(turn) % turns.count
            shown = turns[index]
            shownIsTimed = entries[index].isTimed
        }
        if shownIsTimed, let tick = download.timeTickAt, download.textDue == nil || tick < download.textDue! {
            download.textDue = tick
        }
        if turns.count < 2 { return shown }
        let lastMinute = timed != nil && left! < 60 ? [Formatting.lastMinuteWidest] : []
        return shared.ruler.sameWidth(shown, turns + lastMinute)
    }

    /// The downloading line: the amount, then what "Download Details" says
    /// (nothing after it when there's nothing to say).
    static func amountLine(_ amount: String, _ detail: String) -> String {
        detail.isEmpty ? amount : "\(amount) · \(detail)"
    }

    func inProgress(_ download: Download, _ numericStyle: String = "compact", stalled: Bool = false,
                    now: Double? = nil) -> JSON {
        let now = now ?? monotonic()
        let percent = download.percent
        let center: String
        if stalled {
            center = statusLine("Stalled", download, now: now)
        } else if percent != nil {
            center = Self.amountLine(Formatting.pair(download.size, download.totalSize!), rateText(download, now: now))
        } else {
            // (no total size: no time left to tell, so the speed stands in for it)
            let wantsQueue = ["queue", "all"].contains(settings.details)
            center = Self.amountLine(Formatting.amount(download.size),
                                     wantsQueue ? rateText(download, now: now) : Formatting.speed(download.speed))
        }
        var ring = JSON.obj(["type": .string("progress"), "tint": .string("blue")])
        if let percent {
            ring["value"] = .double(Self.rounded4(percent))     // a real, filling ring
        }
        // (without a value DynamicLake draws a spinning ring: the size isn't
        // known yet, or the server never sent one)
        if stalled {
            ring = stateSymbol("stalled") ?? ring
        }
        let pill = JSON.obj(["leftSlot": pillIcon(download, now: now), "rightSlot": ring])
        let peek = JSON.obj(["leftSlot": stopButton(download), "center": Self.text(center, "marquee")])
            .merging(percentSlot(download.percentText, numericStyle))
        return .obj(["compactLiveActivity": pill, "sneakPeek": peek])
    }

    /// Python's `round(value, 4)`: to the nearest ten-thousandth of the
    /// exact value.
    static func rounded4(_ value: Double) -> Double {
        Double(Formatting.fixed(value, 4)) ?? value
    }

    func done(_ download: Download, _ numericStyle: String = "compact", now: Double? = nil) -> JSON {
        let pill = JSON.obj(["leftSlot": pillIcon(download),
                             "rightSlot": stateSymbol("done") ?? .obj(["type": .string("status"), "status": .string("success"),
                                                                      "tint": .string("green")])])
        let peek = JSON.obj(["leftSlot": showButton(download),
                             "center": Self.text(statusLine("Complete", download, now: now), "marquee"),
                             "rightSlot": openButton(download)])
        return .obj(["compactLiveActivity": pill, "sneakPeek": peek])
    }

    /// "Smart Slideshows": one card for several finished downloads ("3
    /// Downloads Completed"). Their number stands where a file's type or
    /// the arrow does, and Show in Finder shows them all.
    func summary(_ download: Download, count: Int) -> JSON {
        let icon = shared.pictures.image("count", String(count)) ?? icon("")
        return .obj([
            "compactLiveActivity": .obj(["leftSlot": icon,
                                         "rightSlot": stateSymbol("done") ?? .obj(["type": .string("status"),
                                                                                  "status": .string("success"),
                                                                                  "tint": .string("green")])]),
            "sneakPeek": .obj(["leftSlot": showButton(download),
                               "center": Self.text("\(count) Downloads Completed", "marquee")]),
            "extraLiveActivity": .obj(["leftSlot": icon]),
        ])
    }

    /// Canceled (in the browser, by Stop, or given up by the browser):
    /// Retry starts it over, like the panel's own Retry. Blocked: nothing
    /// to press here -- only you can decide about it, in the browser.
    func canceled(_ download: Download, reason: String, now: Double? = nil) -> JSON {
        var peek = JSON.obj(["center": Self.text(statusLine(reason, download, now: now), "marquee")])
        // (DynamicLake's red X, where none can be drawn)
        var symbol = JSON.obj(["type": .string("status"), "status": .string("failed"), "tint": .string("red")])
        if reason == "Canceled" {
            peek = JSON.obj(["leftSlot": retryButton(download, action: "restart")]).merging(peek)
            symbol = stateSymbol("canceled") ?? symbol
        } else {
            symbol = stateSymbol("blocked") ?? symbol
        }
        return .obj(["compactLiveActivity": .obj(["leftSlot": pillIcon(download), "rightSlot": symbol]), "sneakPeek": peek])
    }

    /// How far a paused or failed download got (its data is kept, so
    /// Resume or Retry carries on from there); nothing when the size isn't
    /// known.
    func keptPercentSlot(_ download: Download, _ numericStyle: String) -> JSON {
        download.percent != nil ? percentSlot(download.percentText, numericStyle) : .object([])
    }

    func paused(_ download: Download, _ numericStyle: String = "compact", withButton: Bool = true,
                word: String = "Paused", now: Double? = nil) -> JSON {
        var peek = JSON.obj(["center": Self.text(statusLine(word, download, now: now), "marquee")])
            .merging(keptPercentSlot(download, numericStyle))
        if withButton {
            peek = JSON.obj(["leftSlot": resumeButton(download)]).merging(peek)
        }
        let pill = JSON.obj(["leftSlot": pillIcon(download, now: now),
                             "rightSlot": stateSymbol("paused") ?? .obj(["type": .string("status"), "status": .string("paused"),
                                                                        "tint": .string("orange")])])
        return .obj(["compactLiveActivity": pill, "sneakPeek": peek])
    }

    func failed(_ download: Download, _ numericStyle: String = "compact", withButton: Bool = true,
                now: Double? = nil) -> JSON {
        var peek = JSON.obj(["center": Self.text(statusLine("Failed", download, now: now), "marquee")])
            .merging(keptPercentSlot(download, numericStyle))
        if withButton {
            peek = JSON.obj(["leftSlot": retryButton(download)]).merging(peek)
        }
        let pill = JSON.obj(["leftSlot": pillIcon(download, now: now),
                             "rightSlot": stateSymbol("failed") ?? .obj(["type": .string("status"), "status": .string("failed"),
                                                                        "tint": .string("red")])])
        return .obj(["compactLiveActivity": pill, "sneakPeek": peek])
    }
}
