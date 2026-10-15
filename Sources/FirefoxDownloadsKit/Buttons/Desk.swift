// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// A window of the browser's on screen: its level and its place (only
/// these are read, which needs no permission, never what's in it).
public struct ScreenWindow: Sendable {
    public var level: Int
    public var x: Double, y: Double, width: Double, height: Double
}

/// What the buttons ask of the Mac about the pointer, the keyboard, the
/// windows and the app in front, gathered so that tests can answer
/// instead (and never move the real pointer).
public struct Desk: Sendable {
    /// Where the pointer is, in screen points (top-left origin).
    public var pointerLocation: @Sendable () -> CGPoint? = Desk.realPointerLocation
    /// How many mouse, trackpad and keyboard events macOS has seen so far
    /// (the browser moving the pointer adds none).
    public var inputEventCount: @Sendable () -> Int? = Desk.realInputEventCount
    /// How long since your last mouse, trackpad or keyboard input (from devices).
    public var secondsSinceInput: @Sendable () -> Double? = Desk.realSecondsSinceInput
    /// How long since your last click, key press (modifier keys too) or
    /// scroll (moving the pointer doesn't count).
    public var secondsSincePress: @Sendable () -> Double? = Desk.realSecondsSincePress
    /// How many clicks and key presses macOS has seen so far (from devices:
    /// the browser opening a menu adds none).
    public var pressCount: @Sendable () -> Int? = Desk.realPressCount
    public var movePointer: @Sendable (CGPoint) -> Bool = Desk.realMovePointer
    /// The process id of the frontmost app, asked of LaunchServices.
    public var launchServicesFront: @Sendable () -> Int32? = Desk.realLaunchServicesFront
    /// That process's windows on screen now.
    public var windowsOnScreen: @Sendable (Int32) -> [ScreenWindow]? = Desk.realWindowsOnScreen
    /// The Accessibility API.
    public var accessibility: @Sendable () -> Accessibility? = { Accessibility.shared }

    public init() {}

    /// A desk with nothing on it: every answer "can't be told" (tests).
    public static var none: Desk {
        var desk = Desk()
        desk.pointerLocation = { nil }
        desk.inputEventCount = { nil }
        desk.secondsSinceInput = { nil }
        desk.secondsSincePress = { nil }
        desk.pressCount = { nil }
        desk.movePointer = { _ in false }
        desk.launchServicesFront = { nil }
        desk.windowsOnScreen = { _ in nil }
        desk.accessibility = { nil }
        return desk
    }

    private static let anyInput = CGEventType(rawValue: ~0)!
    /// kCGEventLeftMouseDown, RightMouseDown, OtherMouseDown, KeyDown.
    private static let presses: [UInt32] = [1, 3, 25, 10]
    /// kCGEventFlagsChanged (a modifier key), ScrollWheel.
    private static let touches: [UInt32] = [12, 22]

    static func realPointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    static func realInputEventCount() -> Int? {
        Int(CGEventSource.counterForEventType(.hidSystemState, eventType: anyInput))
    }

    static func realSecondsSinceInput() -> Double? {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    static func realSecondsSincePress() -> Double? {
        (presses + touches).compactMap(CGEventType.init(rawValue:))
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min()
    }

    static func realPressCount() -> Int? {
        presses.compactMap(CGEventType.init(rawValue:))
            .map { Int(CGEventSource.counterForEventType(.hidSystemState, eventType: $0)) }.reduce(0, +)
    }

    static func realMovePointer(_ point: CGPoint) -> Bool {
        let moved = CGWarpMouseCursorPosition(point) == .success
        CGAssociateMouseAndMouseCursorPosition(1)
        return moved
    }

    /// While a browser's menu has the keyboard, this is still the app you
    /// were in: macOS keeps it in front.
    static func realLaunchServicesFront() -> Int32? {
        let asn = ScriptRunner.run(["/usr/bin/lsappinfo", "front"], timeout: 2).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asn.isEmpty else { return nil }
        let info = ScriptRunner.run(["/usr/bin/lsappinfo", "info", "-only", "pid", asn], timeout: 2).stdout
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z])pid"?\s*=\s*(\d+)"#)
        guard let found = pattern.firstMatch(in: info, range: NSRange(info.startIndex..., in: info)),
              let digits = Range(found.range(at: 1), in: info), let pid = Int32(info[digits]) else { return nil }
        return pid > 0 && pid != getpid() ? pid : nil
    }

    static func realWindowsOnScreen(_ pid: Int32) -> [ScreenWindow]? {
        guard let listing = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var found: [ScreenWindow] = []
        for window in listing {
            guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid,
                  let level = (window[kCGWindowLayer as String] as? NSNumber)?.intValue else { continue }
            var rect = CGRect.zero
            if let bounds = window[kCGWindowBounds as String] as? NSDictionary,
               CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect) {
                found.append(ScreenWindow(level: level, x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height))
            }
        }
        return found
    }
}

/// "x,y,w,h" -> the frame.
func parseFrame(_ frame: String) -> (x: Double, y: Double, w: Double, h: Double)? {
    guard let match = frame.wholeMatch(of: #/(-?\d+),(-?\d+),(\d+),(\d+)/#),
          let x = Double(match.1), let y = Double(match.2), let w = Double(match.3), let h = Double(match.4) else { return nil }
    return (x, y, w, h)
}

/// While Resume's steps run, put the pointer back the moment the browser
/// moves it: that's the browser moving it onto the row to open its menu
/// (the menu opens there either way). A jump counts as the browser's when
/// macOS saw no input from you meanwhile, or when it's too far, too fast
/// and too sudden for a hand: over 150 points within one 5 ms look, at
/// least 4 times faster than the look before (a hand speeds up gradually).
/// Where the browser put the pointer (`restoredFrom`) is where it clicked:
/// the corner of the menu.
final class PointerGuard: @unchecked Sendable {
    static let poll = 0.005
    /// Seconds without input before a small jump counts as the browser's.
    static let quiet = 0.05
    /// Points.
    static let far = 150.0
    /// Points per second.
    static let fast = 20000.0
    /// Times the speed of the look before.
    static let sudden = 4.0

    let before: CGPoint?
    private let lock = NSLock()
    private var _restoredFrom: CGPoint?
    private(set) var restores = 0
    private var stopped = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private let desk: Desk

    /// Where the browser last put the pointer.
    var restoredFrom: CGPoint? { lock.withLock { _restoredFrom } }

    init(desk: Desk) {
        self.desk = desk
        before = desk.pointerLocation()
    }

    func start() {
        guard before != nil else { return }
        let thread = Thread { [self] in
            watch()
            finished.signal()
        }
        self.thread = thread
        thread.start()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func watch() {
        var last = before
        var count = desk.inputEventCount()
        var at = monotonic()
        var speed = 0.0
        while true {
            Thread.sleep(forTimeInterval: Self.poll)
            if isStopped { return }
            let now = desk.pointerLocation(), nowCount = desk.inputEventCount(), idle = desk.secondsSinceInput()
            let nowAt = monotonic()
            guard let now, let lastPoint = last else { return }
            let dist = max(abs(now.x - lastPoint.x), abs(now.y - lastPoint.y))
            let nowSpeed = dist / max(nowAt - at, 1e-3)
            let quiet = count != nil && nowCount == count && idle != nil && idle! >= Self.quiet
            let flung = dist > Self.far && nowSpeed > Self.fast && nowSpeed > Self.sudden * speed
            if dist > 2 && (quiet || flung) {
                // (It keeps watching: the fallback script may show the menu again.)
                if desk.movePointer(lastPoint) {
                    lock.withLock {
                        _restoredFrom = now
                        restores += 1
                    }
                    count = desk.inputEventCount()
                    at = monotonic()
                    speed = 0
                    continue
                }
                return
            }
            last = now
            count = nowCount
            at = nowAt
            speed = nowSpeed
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        if thread != nil {
            _ = finished.wait(timeout: .now() + 0.5)
        }
    }
}

/// After Resume, when the guard didn't catch it: if the pointer is still on
/// the row whose menu was shown (the script reports its frame), move it back
/// to where it was before. If you've moved it since, leave it alone.
func putPointerBack(_ result: ScriptResult, before: CGPoint?, desk: Desk) -> ScriptResult {
    guard let frame = parseFrame(result.frame), let before, let now = desk.pointerLocation() else { return result }
    func inside(_ p: CGPoint) -> Bool {
        frame.x - 2 <= p.x && p.x <= frame.x + frame.w + 2 && frame.y - 2 <= p.y && p.y <= frame.y + frame.h + 2
    }
    if !inside(now) || inside(before) { return result }
    return result.noting(desk.movePointer(before) ? "pointer put back" : "pointer could not be put back")
}
