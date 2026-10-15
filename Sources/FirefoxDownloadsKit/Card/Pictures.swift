// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import CoreText
import Foundation
import zlib

/// The pill's own pictures: the file's extension in a blue circle, and the
/// symbols for "done", "paused", "canceled", "failed", "stalled" and
/// "blocked" -- in the look of DynamicLake's own status symbols (a dim disc
/// of the colour, the glyph in the colour). Drawn off screen with
/// CoreGraphics and CoreText, kept as small PNG pictures, each drawn once.
public final class Pictures {
    /// The pictures' size (DynamicLake scales them to the slot).
    static let pixels = 96
    /// The system's rounded bold (else: its bold).
    static let fontName = ".AppleSystemUIFontRounded-Bold"
    private static let blue = (10.0 / 255, 132.0 / 255, 1.0)
    private static let red = (1.0, 69.0 / 255, 58.0 / 255)
    private static let green = (48.0 / 255, 209.0 / 255, 88.0 / 255)
    private static let orange = (1.0, 159.0 / 255, 10.0 / 255)
    /// Every picture follows one rule: a full circle in its colour, dark,
    /// and the symbol in the same colour, bright, inside it. (colour, how
    /// dark the circle)
    private static let looks: [String: ((Double, Double, Double), Double)] = [
        "type": (blue, 0.24), "arrow": (blue, 0.24), "count": (blue, 0.24),
        "done": (green, 0.22), "paused": (orange, 0.22),
        "canceled": (red, 0.22), "failed": (red, 0.22),
        "stalled": (red, 0.22), "blocked": (red, 0.22),
    ]

    private struct Key: Hashable {
        var kind: String
        var text: String
    }

    private var drawn: [Key: JSON?] = [:]
    private let draw: (String, String) -> Data?

    /// Tests may give their own way of drawing.
    public init(draw: @escaping (String, String) -> Data? = Pictures.png) {
        self.draw = draw
    }

    /// The image component for one of the plugin's pictures (see `png`),
    /// or nothing where it can't be drawn. Each is drawn once.
    func image(_ kind: String, _ text: String = "") -> JSON? {
        let key = Key(kind: kind, text: text)
        if let known = drawn[key] { return known }
        var picture: JSON?
        if let data = draw(kind, text), !data.isEmpty {
            picture = .obj(["type": .string("image"), "source": .string("inlineData"), "mimeType": .string("image/png"),
                            "base64Data": .string(data.base64EncodedString())])
        }
        drawn[key] = picture
        return picture
    }

    /// One picture, as PNG: kind "type" (`text`, a file's extension),
    /// "count" (`text`, a number) or "arrow" (the download arrow), in a
    /// blue circle; "done" (a check mark) in a green one; "paused" (two
    /// bars) in an orange one; "canceled" (a cross), "failed" (!),
    /// "stalled" (...) or "blocked" (a bar) in a red one. Each the same
    /// way: the circle full and dark, the symbol bright. Nothing where it
    /// can't be drawn.
    public static func png(_ kind: String, _ text: String) -> Data? {
        guard let (colour, dim) = looks[kind] else { return nil }
        let size = pixels
        let side = Double(size)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        // (8 bits a colour, premultiplied alpha last, bytes in R G B A order)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: dim)
            context.fillEllipse(in: CGRect(x: 0.0, y: 0.0, width: side, height: side))
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1.0)
            context.setStrokeColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1.0)
            context.setLineCap(.round)

            func stroke(_ width: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
                context.setLineWidth(side * width)
                context.move(to: CGPoint(x: side * x0, y: side * y0))
                context.addLine(to: CGPoint(x: side * x1, y: side * y1))
                context.strokePath()
            }

            switch kind {
            case "type", "count":
                // As large as fits: 80 % of the circle's width at most.
                let biggest = side * (text.unicodeScalars.count <= 2 ? 0.50 : 0.44)
                var (line, width, xHeight) = textLine(text, size: biggest)
                if width > side * 0.80 {
                    (line, width, xHeight) = textLine(text, size: biggest * side * 0.80 / width)
                }
                if kind == "count" {
                    // A number sits in the middle of the circle by its own
                    // shape: the box around what is drawn of its digits,
                    // not the room the font gives them (digits are taller
                    // than the small letters an extension is centred by,
                    // and would sit too high).
                    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                    context.textPosition = CGPoint(x: (side - ink.width) / 2.0 - ink.origin.x,
                                                   y: (side - ink.height) / 2.0 - ink.origin.y)
                } else {
                    context.textPosition = CGPoint(x: (side - width) / 2.0, y: (side - xHeight) / 2.0)
                }
                CTLineDraw(line, context)
            case "arrow":                       // pointing down: a shaft and its two-armed head
                stroke(0.085, 0.5, 0.71, 0.5, 0.30)
                stroke(0.085, 0.5, 0.29, 0.33, 0.46)
                stroke(0.085, 0.5, 0.29, 0.67, 0.46)
            case "done":                        // a check mark: the short arm, then the long one
                stroke(0.085, 0.347, 0.467, 0.458, 0.32)
                stroke(0.085, 0.458, 0.32, 0.68, 0.667)
            case "canceled":                    // a cross
                stroke(0.085, 0.345, 0.345, 0.655, 0.655)
                stroke(0.085, 0.345, 0.655, 0.655, 0.345)
            case "paused":                      // two upright bars
                stroke(0.095, 0.41, 0.36, 0.41, 0.64)
                stroke(0.095, 0.59, 0.36, 0.59, 0.64)
            case "failed":                      // an exclamation mark: a bar and a dot
                stroke(0.085, 0.5, 0.70, 0.5, 0.46)
                stroke(0.094, 0.5, 0.31, 0.5, 0.31)
            case "stalled":                     // three dots
                for x in [0.33, 0.5, 0.67] {
                    stroke(0.098, x, 0.5, x, 0.5)
                }
            case "blocked":                     // a horizontal bar
                stroke(0.085, 0.33, 0.5, 0.67, 0.5)
            default:
                return false
            }
            return true
        }
        guard drew else { return nil }
        // The PNG wants the colours without the alpha multiplied in.
        var straight = [UInt8](repeating: 0, count: pixels.count)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            guard alpha > 0 else { continue }
            for c in 0..<3 {
                straight[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + alpha / 2) / alpha))
            }
            straight[i + 3] = UInt8(alpha)
        }
        return pngBytes(width: size, height: size, rgba: straight)
    }

    /// A line of `text` in the pictures' font at `size`, its width, and the
    /// font's x-height.
    private static func textLine(_ text: String, size: Double) -> (CTLine, Double, Double) {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: kCFBooleanTrue as Any,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (line, width, CTFontGetXHeight(font))
    }

    /// A PNG file's bytes from RGBA pixels (alpha not premultiplied), made
    /// the way the Python plugin made them (zlib at its strongest).
    static func pngBytes(width: Int, height: Int, rgba: [UInt8]) -> Data {
        func be32(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func chunk(_ kind: String, _ data: [UInt8]) -> [UInt8] {
            let typed = Array(kind.utf8) + data
            let crc = typed.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
            return be32(UInt32(data.count)) + typed + be32(crc)
        }
        var rows: [UInt8] = []
        rows.reserveCapacity(height * (width * 4 + 1))
        for y in 0..<height {
            rows.append(0)
            rows += rgba[(y * width * 4)..<((y + 1) * width * 4)]
        }
        var length = compressBound(uLong(rows.count))
        var compressed = [UInt8](repeating: 0, count: Int(length))
        _ = compress2(&compressed, &length, rows, uLong(rows.count), 9)
        let header = be32(UInt32(width)) + be32(UInt32(height)) + [8, 6, 0, 0, 0]
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            + chunk("IHDR", header) + chunk("IDAT", Array(compressed.prefix(Int(length)))) + chunk("IEND", [])
        return Data(bytes)
    }
}
