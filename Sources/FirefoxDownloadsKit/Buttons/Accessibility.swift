// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ApplicationServices
import Foundation

/// The few calls of the macOS Accessibility API the plugin makes itself
/// (the scripts do the rest, through System Events). Used by one button's
/// work at a time.
public final class Accessibility: @unchecked Sendable {
    /// Seconds an unanswered request waits.
    static let timeout: Float = 1.0
    static let shared = Accessibility()

    let system = AXUIElementCreateSystemWide()

    private init() {
        AXUIElementSetMessagingTimeout(system, Self.timeout)
    }

    func trusted() -> Bool {
        AXIsProcessTrusted()
    }

    func app(_ pid: Int32, timeout: Float? = nil) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout ?? Self.timeout)
        return element
    }

    /// The element at (x, y): among one app's windows when `scope` is that
    /// app's element, else whatever is on screen there, whichever app it
    /// belongs to.
    func hit(_ x: Double, _ y: Double, scope: AXUIElement? = nil) -> AXUIElement? {
        var out: AXUIElement?
        guard AXUIElementCopyElementAtPosition(scope ?? system, Float(x), Float(y), &out) == .success else { return nil }
        return out
    }

    func pid(_ element: AXUIElement) -> Int32? {
        var out: pid_t = 0
        return AXUIElementGetPid(element, &out) == .success ? out : nil
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out
    }

    func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// An element-valued attribute (AXParent...), or nothing.
    func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copy(element, "AXChildren"), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return ((value as! CFArray) as [AnyObject]).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    func perform(_ element: AXUIElement, _ action: String) -> Int32 {
        AXUIElementPerformAction(element, action as CFString).rawValue
    }

    /// The process id of the app in front (the one you're using), or nothing.
    func focusedAppPid() -> Int32? {
        guard let app = element(system, "AXFocusedApplication") else { return nil }
        return pid(app)
    }

    /// Bring that app to the front (what System Events' "set frontmost"
    /// does). Returns the AXError, 0 if it was accepted.
    func setFrontmost(_ pid: Int32) -> Int32 {
        AXUIElementSetAttributeValue(app(pid), "AXFrontmost" as CFString, kCFBooleanTrue).rawValue
    }
}

// Resume, second half: choosing Resume in the row's right-click menu.
// System Events can't be relied on to reach a right-click menu, so the
// plugin finds it itself with the macOS Accessibility API (the same
// permission as the scripts): the browser's menu, at the spot it opened.
enum RowMenu {
    /// How long to look for the menu once it's been shown.
    static let waitSeconds = 3.0
    /// A closing menu fades out, and can still be found meanwhile.
    static let fadeSeconds = 0.8

    private static func labelKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    private static let resumeKeys = Set(Scripts.resumeLabels.map(labelKey))
    private static let markerKeys = Set(Scripts.menuMarkers.map(labelKey))

    static func isResumeLabel(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return resumeKeys.contains(labelKey(text))
    }

    static func isMenuMarker(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return markerKeys.contains(labelKey(text))
    }

    /// The browser's menu at (x, y), hit-testing within `scope` (the
    /// browser's element, or nothing: the whole screen).
    private static func menuHit(_ ax: Accessibility, _ scope: AXUIElement?, _ pid: Int32, _ x: Double, _ y: Double,
                                _ seen: inout [String: Int], _ label: String) -> AXUIElement? {
        guard let element = ax.hit(x, y, scope: scope) else {
            seen[label + "nothing", default: 0] += 1
            return nil
        }
        if ax.pid(element) != pid {
            seen[label + "another app", default: 0] += 1
            return nil
        }
        let role = ax.string(element, "AXRole") ?? "?"
        if role == "AXMenu" { return element }
        if role == "AXMenuItem", let parent = ax.element(element, "AXParent"), ax.string(parent, "AXRole") == "AXMenu" {
            return parent
        }
        seen[label + role, default: 0] += 1
        return nil
    }

    /// The browser's menu at (x, y): looked for among the browser's own
    /// windows first (another app's window on top, such as the notch's,
    /// doesn't get in the way), then on screen. `seen` collects what was
    /// there instead, for the log.
    private static func menuAt(_ ax: Accessibility, _ app: AXUIElement?, _ pid: Int32, _ x: Double, _ y: Double,
                               _ seen: inout [String: Int]) -> AXUIElement? {
        if let app, let menu = menuHit(ax, app, pid, x, y, &seen, "") { return menu }
        return menuHit(ax, nil, pid, x, y, &seen, "screen: ")
    }

    /// A menu among the browser's own top-level elements, or nothing.
    private static func menuAmongChildren(_ ax: Accessibility, _ app: AXUIElement?) -> AXUIElement? {
        guard let app else { return nil }
        return ax.children(app).first { ax.string($0, "AXRole") == "AXMenu" }
    }

    /// Where to look for the menu: it opens with a corner where the browser
    /// clicked -- where it put the pointer (`clicked`, when the pointer
    /// guard saw it), which is the middle of the row -- to the right and
    /// down unless the screen edge flips it.
    static func probePoints(_ frame: (x: Double, y: Double, w: Double, h: Double), clicked: CGPoint?) -> [(Double, Double)] {
        var centres = [(frame.x + frame.w / 2, frame.y + frame.h / 2)]
        if let clicked, max(abs(clicked.x - centres[0].0), abs(clicked.y - centres[0].1)) > 3 {
            centres.insert((Double(clicked.x), Double(clicked.y)), at: 0)
        }
        return centres.flatMap { cx, cy in [(14.0, 9.0), (-14, 9), (14, -9), (-14, -9)].map { (cx + $0.0, cy + $0.1) } }
    }

    /// Whether the menu is gone within `seconds`.
    private static func gone(_ stillOpen: () -> Bool, _ seconds: Double) -> Bool {
        let deadline = monotonic() + seconds
        while stillOpen() {
            if monotonic() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    /// Close the menu without choosing anything.
    private static func close(_ ax: Accessibility, _ menu: AXUIElement, _ firstItem: AXUIElement?, _ stillOpen: () -> Bool,
                              _ outcome: String, _ trace: String) -> (String, String) {
        for target in [menu, firstItem, menu] {
            if let target { _ = ax.perform(target, "AXCancel") }
            if gone(stillOpen, fadeSeconds) { return (outcome, trace + "menu closed; ") }
        }
        return ("menu-open", trace + "the menu did not close; ")
    }

    /// The script has just shown a row's right-click menu. Find it (the
    /// browser's menu, where it opened) and, if `press`, choose Resume: only
    /// if it's the downloads menu (it has one of that menu's other items)
    /// with exactly one item labelled Resume, read again right before the
    /// press. Anything else, or `press` false, closes it untouched; nothing
    /// else in it is ever pressed. `clickedAt()` is where the browser put
    /// the pointer to open it, if known. Returns (outcome, trace).
    static func choose(_ ax: Accessibility, pid: Int32, frame: (x: Double, y: Double, w: Double, h: Double), press: Bool,
                       clickedAt: (() -> CGPoint?)?) -> (String, String) {
        let app = ax.app(pid, timeout: 0.5)        // the browser, for hit-tests among its windows
        let deadline = monotonic() + waitSeconds
        var menu: AXUIElement?
        var whereFound = ""
        var seen: [String: Int] = [:]
        var looks = 0
        var stillOpen: () -> Bool = { false }
        while menu == nil && monotonic() < deadline {
            looks += 1
            for point in probePoints(frame, clicked: clickedAt?()) {
                if monotonic() >= deadline { break }
                menu = menuAt(ax, app, pid, point.0, point.1, &seen)
                if menu != nil {
                    whereFound = "at \(Formatting.fixed(point.0, 0)),\(Formatting.fixed(point.1, 0))"
                    stillOpen = {
                        var unused: [String: Int] = [:]
                        return menuAt(ax, app, pid, point.0, point.1, &unused) != nil
                    }
                    break
                }
            }
            if menu == nil && looks % 10 == 0 && monotonic() < deadline {
                menu = menuAmongChildren(ax, app)
                if menu != nil {
                    whereFound = "among the browser's elements"
                    stillOpen = { menuAmongChildren(ax, app) != nil }
                }
            }
            if menu == nil { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard let menu else {
            let found = seen.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
            return ("no-menu", "the menu wasn't found in \(Formatting.fixed(waitSeconds, 1)) s (seen: \(found.isEmpty ? "nothing" : found)); ")
        }
        let items = ax.children(menu)
        let roles = items.map { ax.string($0, "AXRole") }
        let titles = items.map { ax.string($0, "AXTitle") ?? "" }
        var trace = "menu \(whereFound) after \(looks) looks: [\(titles.filter { !$0.isEmpty }.joined(separator: ","))]; "
        let first = items.first
        if !press {
            return close(ax, menu, first, stillOpen, "menu-changed", trace)
        }
        let resume = items.indices.filter { roles[$0] == "AXMenuItem" && isResumeLabel(titles[$0]) }
        let marked = titles.indices.contains { !resume.contains($0) && isMenuMarker(titles[$0]) }
        if !marked {
            return close(ax, menu, first, stillOpen, "wrong-menu", trace + "not the downloads menu; ")
        }
        if resume.count != 1 {
            return close(ax, menu, first, stillOpen, "not-paused", trace + "no Resume item; ")
        }
        let item = items[resume[0]]
        let title = ax.string(item, "AXTitle")
        if !isResumeLabel(title) {
            return close(ax, menu, first, stillOpen, "menu-changed", trace + "the menu changed; ")
        }
        if ax.boolean(item, "AXEnabled") == false {
            return close(ax, menu, first, stillOpen, "not-paused", trace + "Resume is disabled; ")
        }
        let err = ax.perform(item, "AXPress")
        if err == 0 {
            return ("resume-sent", trace + "pressed [\(title!)]; ")
        }
        // An error. If the menu goes (it fades out first), the press may
        // still have gone through; if it stays open, it didn't.
        trace += "pressing Resume reported error \(err); "
        if gone(stillOpen, fadeSeconds) {
            return ("press-failed", trace)
        }
        return close(ax, menu, first, stillOpen, "not-pressed", trace)
    }
}
