// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreText
import Foundation

/// Measures text as DynamicLake draws it in the middle of a sneak peek, and
/// shapes lines to fit there. Measured on a notch: the text is the system's
/// semibold at 14 pt; a line up to 196 pt wide is shown whole, a wider one
/// scrolls. Lengths count Unicode characters (code points).
public final class TextRuler {
    /// The sneak peek's font and size.
    static let fontName = ".AppleSystemUIFontDemi"
    static let fontSize = 14.0
    /// An invisible character after padding spaces, which keeps
    /// DynamicLake from trimming them (others, such as U+2060, make it
    /// refuse the whole update).
    static let padEnd = "\u{034F}"
    /// An empty braille cell, put before a line that scrolls: it starts
    /// where the left side fades out, which cut its first letter (spaces
    /// there are trimmed; this isn't one).
    static let leadBlank = "\u{2800}"

    private let measure: (String) -> Double?
    private var widths: [String: Double?] = [:]
    var fitPoints = 196.0
    var fitChars = 28

    /// A ruler that measures with the given function; tests give their own.
    public init(measure: @escaping (String) -> Double?) {
        self.measure = measure
    }

    /// The ruler that measures in the sneak peek's own font.
    public static func system() -> TextRuler {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: font]
        return TextRuler { text in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
    }

    /// A ruler that can't measure (the lengths are counted instead).
    public static func unmeasured() -> TextRuler { TextRuler { _ in nil } }

    /// How wide DynamicLake draws `text` in a sneak peek, in points, or
    /// nothing where it can't be measured.
    func width(_ text: String) -> Double? {
        if let known = widths[text] { return known }
        let width = measure(text)
        if widths.count > 4_000 { widths.removeAll() }
        widths[text] = width
        return width
    }

    private static let trimmed: Set<Unicode.Scalar> = [" ", ".", "•"]

    /// `text` cut to what the sneak peek shows whole, ending with "…";
    /// nothing when all of it fits.
    func fitted(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        func cut(_ count: Int) -> String {
            stripTrailing(scalars.prefix(max(0, count)), Self.trimmed) + "…"
        }
        guard let whole = width(text) else {     // (by the number of characters, then)
            return scalars.count <= fitChars ? nil : cut(fitChars - 1)
        }
        if whole <= fitPoints { return nil }
        var low = 0                             // (the longest beginning that fits with its "…")
        var high = scalars.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if (width(cut(middle)) ?? 0) <= fitPoints {
                low = middle
            } else {
                high = middle
            }
        }
        return cut(low)
    }

    /// Spaces adding up to `points` (to within half a point), followed by
    /// the character that keeps them from being trimmed; "" for less.
    func padding(_ points: Double) -> String {
        var left = points
        var out = ""
        for space in [" ", "\u{2009}", "\u{200A}"] {     // an ordinary one, a thin one, a hair one
            guard let both = width("x" + space + "x"), let none = width("xx"), both - none > 0.1 else { continue }
            let each = both - none
            let count = Int(((left + (space == "\u{200A}" ? each / 2 : 0.0)) / each).rounded(.down))
            if count > 0 { out += String(repeating: space, count: count) }
            left -= Double(count) * each
        }
        return out.isEmpty ? "" : out + Self.padEnd
    }

    /// `shown`, followed by enough space to be as wide as the widest of
    /// them all: where one takes another's place (the speed, the time left,
    /// the downloads that wait, in turn), the line then stays where it is.
    /// Digits count as the widest one, so that it doesn't move every second
    /// either. As it is where widths can't be measured.
    func sameWidth(_ shown: String, _ others: [String]) -> String {
        let wide = ([shown] + others).map { text in
            width(FirefoxDownloadsKit.text(text.unicodeScalars.map { ("0"..."9").contains($0) ? "8" : $0 }))
        }
        guard let actual = width(shown), !wide.contains(where: { $0 == nil }) else { return shown }
        return shown + padding(wide.compactMap { $0 }.max()! - actual)
    }
}
