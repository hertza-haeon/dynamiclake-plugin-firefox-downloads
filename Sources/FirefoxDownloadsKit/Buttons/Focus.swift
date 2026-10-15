// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// After Resume: the app you were in, given the keyboard back, and nothing
/// of the browser's left over it.
struct Focus {
    let ax: Accessibility
    let desk: Desk
    let t: Tunables

    /// The app you're in (its process id), and a note for the log when it
    /// had to be asked another way. Accessibility's "focused application"
    /// comes first; a process that has only just started gets no answer to
    /// that (seen on macOS 27). LaunchServices is asked then.
    static func frontAppPid(_ ax: Accessibility?, desk: Desk) -> (Int32?, String) {
        if let pid = ax?.focusedAppPid() { return (pid, "") }
        if let pid = desk.launchServicesFront() { return (pid, "the app in front was asked of LaunchServices; ") }
        return (nil, "")
    }

    /// What that browser has on screen, going by the row the script acted
    /// on: (the Downloads panel floating above other apps, the row's menu,
    /// an ordinary window of the browser's). Nothing where it can't be told.
    ///
    /// After a native menu, the browser keeps its panel floating over every
    /// app until something makes it close it. The panel is the floating
    /// window that holds the whole row; the menu is another floating window
    /// that reaches the row's middle, where the browser opened it. Its other
    /// floating windows (a tooltip, a picture-in-picture video) are neither.
    func browserOverlays(_ pid: Int32, _ row: (x: Double, y: Double, w: Double, h: Double)?) -> (Bool, Bool, Bool)? {
        guard let windows = desk.windowsOnScreen(pid), let row else { return nil }
        let middle = (row.x + row.w / 2.0, row.y + row.h / 2.0)
        var panel = false, menu = false
        for w in windows where w.level > 0 {
            if w.x <= row.x + 2 && w.y <= row.y + 2 && w.x + w.width >= row.x + row.w - 2 && w.y + w.height >= row.y + row.h - 2 {
                panel = true
            } else if w.x - 8 <= middle.0 && middle.0 <= w.x + w.width + 8 && w.y - 8 <= middle.1 && middle.1 <= w.y + w.height + 8 {
                menu = true
            }
        }
        return (panel, menu, windows.contains { $0.level == 0 })
    }

    /// That browser's floating windows that touch the row, for the log:
    /// "level 101 483x114 at 923,101" ("" when there's none, or it can't be
    /// told).
    func floatingOverRow(_ pid: Int32, _ row: (x: Double, y: Double, w: Double, h: Double)) -> String {
        (desk.windowsOnScreen(pid) ?? []).filter { w in
            w.level > 0 && w.x <= row.x + row.w && w.x + w.width >= row.x && w.y <= row.y + row.h && w.y + w.height >= row.y
        }.map { w in
            "level \(w.level) \(Formatting.fixed(w.width, 0))x\(Formatting.fixed(w.height, 0)) at \(Formatting.fixed(w.x, 0)),\(Formatting.fixed(w.y, 0))"
        }.joined(separator: ", ")
    }

    /// Whether `condition()` came true within `seconds` (looked at every 0.03 s).
    static func until(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = monotonic() + seconds
        while !condition() {
            if monotonic() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return true
    }

    /// After Resume. Returns the result with a note for the log, and whether
    /// your app was put in front. Showing the row's menu brings the browser
    /// to the front; if it's still in front once the menu is done, bring
    /// back the app you were in (Firefox then closes its Downloads panel
    /// too, as it does whenever you switch apps). Nothing happens if you
    /// were in the browser, if no menu was shown, if you switched apps
    /// yourself meanwhile, or if you clicked or typed while Resume ran (you
    /// may have gone to the browser on purpose) -- nor if the app in front
    /// was DynamicLake itself (the plugin's parent process), which would say
    /// nothing about the app you were using.
    func handFocusBack(_ result: ScriptResult, front: Int32?, pressesBefore: Int?) -> (ScriptResult, Bool) {
        guard let browser = Int32(result.pid) else { return (result, false) }  // (no menu was shown)
        guard let front, front != getpid() else { return (result.noting("the app in front wasn't known: focus left alone"), false) }
        if front == browser { return (result.noting("you were in the browser: focus left there"), false) }
        if front == getppid() { return (result.noting("DynamicLake was in front: focus left alone"), false) }
        Thread.sleep(forTimeInterval: t.focusSettleSeconds)      // the browser acts on the chosen item first
        var nowFront = ax.focusedAppPid()
        let blind = nowFront == nil
        if blind {
            // Accessibility can't say who has the keyboard (a process that
            // has only just started). LaunchServices says which app is
            // frontmost: yours still, if you haven't gone elsewhere --
            // putting it in front again then changes nothing on screen, and
            // takes the keyboard back from the browser's menu.
            nowFront = desk.launchServicesFront()
            guard let current = nowFront else {
                return (result.noting("the app in front couldn't be read by then: focus left alone"), false)
            }
            if current != browser && current != front {
                return (result.noting("another app was in front by then: focus left alone"), false)
            }
            if pressesBefore == nil || desk.pressCount() != pressesBefore {
                return (result.noting("you clicked or typed meanwhile, or that can't be told: focus left alone"), false)
            }
        } else if nowFront != browser {
            let note = nowFront == front ? "your app was in front again by itself" : "another app was in front by then: focus left alone"
            return (result.noting(note), false)
        }
        if let pressesBefore, let count = desk.pressCount(), count != pressesBefore {
            return (result.noting("you clicked or typed meanwhile: focus left alone"), false)
        }
        let err = ax.setFrontmost(front)
        let who: () -> Int32? = { blind ? desk.launchServicesFront() : ax.focusedAppPid() }
        let deadline = monotonic() + 0.5
        while who() != front && monotonic() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        let note: String
        if who() != front {
            note = "focus could not be handed back (error \(err))"
        } else if blind && nowFront == front {
            // (Nothing visibly changed hands: no reason for the browser to close anything.)
            note = "your app, still the frontmost one for LaunchServices, was given the keyboard again"
        } else {
            note = "focus handed back" + (blind ? " (as far as LaunchServices can tell)" : "")
        }
        return (result.noting(note), !(blind && nowFront == front))
    }

    /// After Resume: leave nothing of the browser over the app you're in.
    ///
    /// The row's menu goes when Resume is chosen in it, but the Downloads
    /// panel stays, floating above every app. Firefox closes its popups
    /// when one of its windows gains or loses the keyboard, one layer each
    /// time: an open menu first, the panel only if no menu is open. (Clicks
    /// in other apps don't reach it; one in the browser brings it to the
    /// front, and lands on something. Hiding the browser and showing it
    /// again leaves the panel where it was.) So:
    ///
    ///   1. wait for the menu to have gone from the screen, then hand focus
    ///      back if the browser still has the keyboard (`handFocusBack`).
    ///      On the Macs seen, your app has it back by itself by then, and
    ///      the panel stays;
    ///   2. if the panel is still there, bring the browser to the front and
    ///      your app back at once: coming forward with no menu open is what
    ///      makes it close the panel. It's in front for about a tenth of a
    ///      second.
    ///
    /// Step 2 touches the browser only when it's certain you're in the app
    /// you were in when Resume was pressed: that app is known, isn't the
    /// browser or DynamicLake, is the one in front right now, and no click
    /// or key press has been counted since, nor any in the last half
    /// second. Every step goes to the log, with whether the panel went.
    func clearBrowserFromView(_ given: ScriptResult, front: Int32?, pressesBefore: Int?) -> ScriptResult {
        var result = given
        guard let browser = Int32(result.pid) else { return result }   // (no menu was shown)
        let row = parseFrame(result.frame)
        let mine = front != nil && front != browser && front != getppid() && front != getpid()
        guard mine, let row, browserOverlays(browser, row) != nil else {
            // Nowhere to go back to (you were in the browser, or it isn't
            // known where you were), or the screen can't be read: no waiting.
            return handFocusBack(result, front: front, pressesBefore: pressesBefore).0
        }
        let front = front!
        let began = monotonic()
        let look = { browserOverlays(browser, row) }

        /// True once nothing of the browser's has floated over the row for
        /// `panelAbsentSeconds`; false if something still does after
        /// `patience`; nothing when the screen can't be read.
        func overlayGone(_ patience: Double) -> Bool? {
            let deadline = monotonic() + patience
            var absentSince: Double?
            while true {
                guard let state = look() else { return nil }
                let now = monotonic()
                if state.0 || state.1 {
                    absentSince = nil
                    if now >= deadline { return false }
                } else {
                    if absentSince == nil { absentSince = now }
                    if now - absentSince! >= t.panelAbsentSeconds { return true }
                }
                Thread.sleep(forTimeInterval: 0.03)
            }
        }

        func verdict(_ gone: Bool?) -> String {
            guard let gone else { return "the screen couldn't be read at that point" }
            if gone { return "the Downloads panel closed" }
            let floating = floatingOverRow(browser, row)
            return "the Downloads panel is still there (\(floating.isEmpty ? "not listed" : floating); row \(result.frame))"
        }

        /// The app with the keyboard, as Accessibility tells it; where it
        /// tells nothing, the frontmost app, as LaunchServices does.
        func who() -> Int32? {
            ax.focusedAppPid() ?? desk.launchServicesFront()
        }

        func untouched() -> Bool {
            pressesBefore != nil && desk.pressCount() == pressesBefore
        }

        /// "" when the browser may be brought forward, else why not.
        func stillYours() -> String {
            if monotonic() - began > t.clearBudgetSeconds { return "it has taken too long" }
            if !untouched() { return "you clicked or typed meanwhile, or that can't be told" }
            guard let quiet = desk.secondsSincePress(), quiet >= t.quietSeconds else {
                return "you clicked or typed a moment ago, or that can't be told"
            }
            if who() != front { return "your app isn't the one in front" }
            if !(look()?.2 ?? false) { return "the browser has no window on this desktop" }
            return ""
        }

        /// Your app in front again, tried up to three times: "" when it is.
        func bringBack() -> String {
            var err: Int32 = 0
            for _ in 0..<3 {
                err = ax.setFrontmost(front)
                if Self.until(0.4, { who() == front }) { return "" }
            }
            return "YOUR APP COULD NOT BE BROUGHT BACK IN FRONT (error \(err))"
        }

        var note = ""
        if !Self.until(t.menuGoneSeconds, { !(look()?.1 ?? false) }) {
            let floating = floatingOverRow(browser, row)
            note = " the menu was slow to go (\(floating.isEmpty ? "not listed" : floating); row \(result.frame));"
        }
        result.trace = (result.trace + note).trimmingCharacters(in: .whitespaces)
        let handed: Bool
        (result, handed) = handFocusBack(result, front: front, pressesBefore: pressesBefore)
        var notes: [String] = []
        // (Handed back: the browser has just lost the keyboard, and may
        // close its panel for that. Not handed back: nothing will make it.)
        let gone = overlayGone(handed ? t.panelGoneSeconds : 0.0)
        if gone != false {
            notes.append(verdict(gone))
        } else {
            let whyNot = stillYours()
            if !whyNot.isEmpty {
                notes.append(verdict(false) + ", and is left there: \(whyNot)")
            } else {
                let err = ax.setFrontmost(browser)
                let came = Self.until(0.3) { who() == browser }
                Thread.sleep(forTimeInterval: t.blinkSeconds)
                var failed = bringBack()
                if failed.isEmpty && !came {
                    // It hadn't come forward when your app was put back in
                    // front: it may still arrive, and mustn't be what's left there.
                    notes.append("the browser was slow to come forward (error \(err))")
                    if Self.until(1.0, { who() == browser }) {
                        failed = bringBack()
                    }
                }
                if !failed.isEmpty {
                    notes.append(failed)
                } else {
                    notes.append("browser brought to the front and your app back: " + verdict(overlayGone(t.panelGoneSeconds)))
                    if !untouched() {
                        notes.append("a click or a key press of yours came meanwhile")
                    } else if who() == browser {          // (a last look: the browser is never what's left in front)
                        let again = bringBack()
                        notes.append(again.isEmpty ? "your app brought back in front once more" : again)
                    }
                }
            }
        }
        result.trace = (result.trace + " " + notes.joined(separator: "; ") + ";").trimmingCharacters(in: .whitespaces)
        return result
    }
}
