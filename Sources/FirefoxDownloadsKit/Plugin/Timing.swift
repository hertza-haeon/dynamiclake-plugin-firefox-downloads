// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Notices the Mac waking up. The monotonic clock stands still while the
/// Mac sleeps (it counts only time awake) and the wall clock doesn't, so
/// across a sleep the wall clock moves on much further between two looks.
/// A look that's merely late moves both clocks alike.
final class SleepWatch {
    private var last: (now: Double, wall: Double)?
    /// (monotonic) the look before the last gap.
    var before = 0.0
    private let shared: Shared

    init(_ shared: Shared) {
        self.shared = shared
    }

    /// About how long the Mac slept since the last call, or 0.
    func asleepFor(_ now: Double) -> Double {
        let wall = shared.mac.wallClock()
        let previous = last
        last = (now, wall)
        guard let previous else { return 0 }
        let gap = (wall - previous.wall) - (now - previous.now)
        if gap < shared.t.sleepGapSeconds { return 0 }
        before = previous.now
        return gap
    }
}

/// How long sneak peeks open and cards stay, and whether you're there.
extension Shared {
    /// Sneak peeks kept for when you're back.
    static let holdable: Set<String> = ["done", "canceled", "paused", "failed"]

    /// You're away from the Mac: the screen is locked, or there's been no
    /// input for the "Away After" time (keyboard, mouse or trackpad -- or
    /// input that apps post for you, such as Voice Control's or a remote
    /// session's).
    func userAway() -> Bool {
        if let away = mac.away { return away() }
        if mac.screenLocked() == true { return true }
        guard let idle = mac.secondsSinceInput() else { return false }
        return idle >= Double(settings.seconds(.awayAfter))
    }

    /// A finished or canceled card goes away with its sneak peek still open
    /// ("Remain Visible" at 0), not after a while as the closed pill.
    func goesWithPeek() -> Bool {
        settings.seconds(.remainVisible) <= 0
    }

    /// How long the sneak peek opens, in whole seconds within what
    /// DynamicLake accepts: the setting "Sneak Peek Duration" (a button's
    /// message: its own short time). A card that goes with its sneak peek
    /// open asks for a little more than it stays (see `peekMarginSeconds`).
    func presentSeconds(_ kind: String) -> Int {
        if let override = presentSecondsOverride { return override(kind) }
        return presentSecondsReal(kind)
    }

    func presentSecondsReal(_ kind: String) -> Int {
        var seconds: Double
        if kind == "notice" {
            seconds = t.noticeSeconds
        } else {
            seconds = Double(settings.seconds(.sneakPeekDuration))
            if (kind == "done" || kind == "canceled") && goesWithPeek() {
                seconds += Double(t.peekMarginSeconds)
            }
        }
        return max(1, min(t.maxPresentSeconds, Int(seconds)))
    }

    /// How long a finished or canceled card stays: its sneak peek, then the
    /// closed pill for the time of "Remain Visible".
    func keepSeconds(_ download: Download) -> Double {
        if let override = keepSecondsOverride { return override(download) }
        return keepSecondsReal(download)
    }

    func keepSecondsReal(_ download: Download) -> Double {
        let peek = Double(settings.seconds(.sneakPeekDuration))
        if !goesWithPeek() {
            return peek + Double(settings.seconds(.remainVisible))
        }
        if peek + Double(t.peekMarginSeconds) > Double(t.maxPresentSeconds) {
            return peek - 0.25    // (the longest sneak peek there is: gone just before it would close)
        }
        return peek
    }
}
