// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Sizes, speeds and times as the card and the log write them. Sizes count
/// 1024 bytes to the kilobyte, as Firefox's own downloads do. Always with a
/// full stop for the decimals, whatever the Mac's language and region.
enum Formatting {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    /// `value` with `decimals` decimals, rounded as printf rounds (the
    /// exact value, halfway to even).
    static func fixed(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: nil, value)
    }

    /// Like Firefox's own download sizes, move to the next unit before a
    /// number would need four digits (so "1.0 MB", never "1000 KB").
    private static func unit(for n: Double) -> Int {
        var value = max(n, 0)
        var index = 0
        while value >= 999.5 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index
    }

    /// One decimal below 100, whole numbers from 100 up ("5.9", "13.8",
    /// "512"), as Firefox shows them.
    private static func inUnit(_ n: Double, _ index: Int) -> String {
        let value = max(n, 0) / pow(1024.0, Double(index))
        return index == 0 || value >= 99.95 ? fixed(value, 0) : fixed(value, 1)
    }

    /// `5.9 MB`, `512 KB`, `0 B`.
    static func bytes(_ n: Double) -> String {
        let index = unit(for: n)
        return "\(inUnit(n, index)) \(units[index])"
    }

    static func bytes(_ n: Int) -> String {
        bytes(Double(n))
    }

    private static let kilo = 1024, mega = 1024 * 1024, giga = 1024 * 1024 * 1024

    /// (bytes per unit, unit, decimals) for the amounts in the sneak peek:
    /// whole megabytes below 1 GB, gigabytes with two decimals from there
    /// (and whole kilobytes for something smaller than a megabyte).
    private static func amountUnit(_ reference: Int) -> (per: Int, unit: String, decimals: Int) {
        if reference >= giga { return (giga, "GB", 2) }
        if reference >= mega { return (mega, "MB", 0) }
        return (kilo, "KB", 0)
    }

    /// Rounded down, so the amount downloaded never reads as the total
    /// before the file is complete.
    private static func floored(_ n: Int, _ per: Int, _ decimals: Int) -> String {
        let scale = pow(10.0, Double(decimals))
        return fixed((Double(max(n, 0)) / Double(per) * scale).rounded(.down) / scale, decimals)
    }

    /// `294/871MB`, `0.83/2.00GB`: amount downloaded/total, in the total's unit.
    static func pair(_ done: Int, _ total: Int) -> String {
        let (per, unit, decimals) = amountUnit(total)
        let shownTotal = fixed(Double(max(total, 0)) / Double(per), decimals)
        return "\(floored(min(done, total), per, decimals))/\(shownTotal)\(unit)"
    }

    /// `294MB`, `0.83GB`: the amount downloaded when there's no total.
    static func amount(_ done: Int) -> String {
        let (per, unit, decimals) = amountUnit(done)
        return "\(floored(done, per, decimals))\(unit)"
    }

    /// `13.8 MB/s`; `-- KB/s` when nothing comes.
    static func speed(_ bytesPerSecond: Double) -> String {
        if !(bytesPerSecond >= 1) { return "-- KB/s" }
        return "\(bytes(bytesPerSecond))/s"
    }

    /// What's shown counts down by itself, second by second. This is how
    /// far the estimate must drift from it before it's set right, so that
    /// it doesn't jump at every reading of the speed.
    static func timeLeftMargin(_ shown: Double) -> Double {
        max(2.0, 0.06 * shown)
    }

    /// The widest the time left gets under a minute (see `rateText`).
    static let lastMinuteWidest = "88 seconds"

    /// `45 seconds`, `2 min 34 s`, `1 h 20 min 5 s`: the time left, always
    /// with its seconds. Under a minute the word is written out, so that
    /// the line takes about the room it took with the minutes.
    static func time(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let (minutes, secs) = (total / 60, total % 60)
        if minutes == 0 {
            return secs == 1 ? "1 second" : "\(secs) seconds"
        }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return hours == 0 ? "\(rest) min \(secs) s" : "\(hours) h \(rest) min \(secs) s"
    }
}
