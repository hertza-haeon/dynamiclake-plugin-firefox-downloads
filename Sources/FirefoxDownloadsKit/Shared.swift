// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// What the plugin asks of the Mac about the browsers and about you,
/// gathered in one place so that tests can answer instead.
public struct MacAnswers {
    /// The browser process that has a profile open (see `ProfileLock`).
    public var profilePid: (String) -> Int32? = ProfileLock.profilePid
    /// Whether a browser has a profile open.
    public var profileInUse: (String) -> Bool? = ProfileLock.profileInUse
    /// Whether a process has a file open.
    public var processHasOpen: (Int32, String) -> Bool? = ProfileLock.processHasOpen
    /// Seconds since 1970 (see `SleepWatch`).
    public var wallClock: () -> Double = FirefoxDownloadsKit.wallClock
    /// The partial files in a folder.
    public var partFiles: (String) -> Set<String> = Profiles.partFiles
    /// Whether the screen is locked (or this login isn't the one on
    /// screen); nothing when unknown.
    public var screenLocked: () -> Bool? = MacAnswers.isScreenLocked
    /// How long since the last input of any kind (keyboard, mouse,
    /// trackpad, or input that apps post for you, such as Voice Control's
    /// or a remote session's); nothing when unknown.
    public var secondsSinceInput: () -> Double? = MacAnswers.idleSeconds
    /// Stands in for "you're away" altogether, in tests.
    public var away: (() -> Bool)?

    public init() {}

    static func isScreenLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        func flag(_ key: String) -> Bool? {
            guard let value = session[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        return flag("CGSSessionScreenIsLocked") == true || flag("kCGSSessionOnConsoleKey") == false
    }

    static func idleSeconds() -> Double? {
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// What every part of the plugin shares: the timings, the settings, the
/// log, the pictures and the measuring of text, the Mac's answers, and the
/// downloads waiting for a card.
public final class Shared {
    public var t: Tunables
    public let settings: Settings
    public let log: PluginLog
    var pictures: Pictures
    var ruler: TextRuler
    public var mac: MacAnswers
    /// How many downloads wait for a card (see "Places"): counted at every
    /// pass, for the line of the downloads that have one.
    var queueWaiting = 0
    /// The order downloads started in.
    private var lastSeq = 0
    /// Stand-ins for two of the rules, in tests.
    var presentSecondsOverride: ((String) -> Int)?
    var keepSecondsOverride: ((Download) -> Double)?

    public init(tunables: Tunables = Tunables(), settings: Settings = Settings(), log: PluginLog = .inLibrary(),
                pictures: Pictures = Pictures(), ruler: TextRuler = .system(), mac: MacAnswers = MacAnswers()) {
        self.t = tunables
        self.settings = settings
        self.log = log
        self.pictures = pictures
        self.ruler = ruler
        self.mac = mac
        settings.refreshSeconds = { [unowned self] in self.t.settingsRefreshSeconds }
        log.maxBytes = tunables.logMaxBytes
    }

    func nextSeq() -> Int {
        lastSeq += 1
        return lastSeq
    }

    func logEvent(_ message: String) {
        log.write(message)
    }
}
