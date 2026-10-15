// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Every timing and limit the plugin works by, in seconds unless said
/// otherwise. Tests shorten some of them.
public struct Tunables: Sendable {
    /// Between two looks at the download folders.
    public var pollInterval = 0.6
    /// ...while a Stop, Resume or Retry is in flight, so the card follows
    /// the browser within 0.1 s.
    public var actionPollInterval = 0.1
    /// Speed readings are taken at most this often.
    public var minSampleGap = 0.45
    /// Readings kept for the rolling speed estimate.
    public var speedWindow = 8
    /// Extra looks before a partial file that vanished with no finished
    /// file (and no Stop pending) counts as canceled in the browser.
    public var vanishGraceTicks = 1
    /// Extra looks an EMPTY final file must survive before it counts as a
    /// finished (empty) download.
    public var emptyFileTicks = 3
    /// How long the sneak peek opens when a download finishes, pauses,
    /// fails or is canceled (the default of "Sneak Peek Duration").
    public var peekSeconds = 5
    /// ...and how long a finished or canceled card's pill stays after that
    /// (the default of "Remain Visible"). At 0 the card goes with its sneak
    /// peek still open.
    public var remainSeconds = 0
    /// ...the most that setting goes to.
    public var remainMaxSeconds = 30
    /// How long a button's message shows.
    public var noticeSeconds = 3.0
    /// A card that goes with its sneak peek open asks for the sneak peek
    /// this much longer than it stays, so that the two go together (no
    /// moment with only the pill left).
    public var peekMarginSeconds = 2
    /// The longest sneak peek DynamicLake accepts (a longer one makes it
    /// refuse the whole update).
    public var maxPresentSeconds = 10
    /// "Download Details" on All: the speed, the time left and the
    /// downloads that wait take turns, this long each.
    public var detailsTurnSeconds = 3.0
    /// A status line too long for the sneak peek stays still this long,
    /// cut short, before it starts to scroll.
    public var scrollHoldSeconds = 3.0
    /// The widest text DynamicLake shows whole in the middle of a sneak
    /// peek (a wider one scrolls). Measured on a notch, in the sneak peek's
    /// font: 202 pt with "100%" on its right, up to 220.
    public var fitPoints = 196.0
    /// ...in characters, where widths can't be measured.
    public var fitChars = 28
    /// The longest text DynamicLake accepts, in characters.
    public var maxTextChars = 240
    /// A new download shows the blue arrow this long, then its file type.
    public var iconDelaySeconds = 4.0
    /// The browser closed the partial file: looked at again this much later
    /// before the download counts as paused (it also closes it for an
    /// instant when it finishes).
    public var earlyStopConfirm = 0.09
    /// ...longer when the size isn't known: "it's all there, so it's
    /// finishing" can't be told then.
    public var earlyStopConfirmNoTotal = 0.5
    /// A download stopped that way is a paused one or a failed one: the
    /// card (pill and sneak peek) waits until the browser's downloads.json
    /// says which, about 1.5 s later -- this long at most, then it's shown
    /// as paused. (If the browser was in fact quitting, it closes its
    /// files first: the card says so instead.)
    public var earlyPeekDelay = 3.0
    /// After Stop: the file still there this long, and it is reported.
    public var cancelGiveUpSeconds = 8.0
    /// After Resume or Retry: no data this long, and it is reported.
    public var restartGiveUpSeconds = 10.0
    /// Downloading, but no data this long: "Stalled".
    public var stallSeconds = 15.0
    /// No data this long: is the browser still open?
    public var closedCheckAfter = 3.0
    /// After the Mac wakes, a pause waits this long before it's shown:
    /// Firefox pauses downloads when the Mac sleeps and resumes them itself
    /// 10 s after it wakes.
    public var wakeGraceSeconds = 15.0
    /// This long between two looks means the Mac was asleep.
    public var sleepGapSeconds = 8.0
    /// Data this recently before the Mac slept: it was downloading (Firefox
    /// resumes those; a download you'd paused, it doesn't).
    public var wasDownloadingSeconds = 5.0
    /// No keyboard, mouse or trackpad input this long: you're away (the
    /// default of "Away After"; see "Delayed Display").
    public var awaySeconds = 60
    /// Between two sneak peeks shown when you're back.
    public var replayGapSeconds = 6.0
    /// A sneak peek waits for you at most this long.
    public var holdMaxSeconds = 12.0 * 3600
    /// Downloads that have a card at the same time (DynamicLake shows two:
    /// the main place and the capsule beside it). The others wait their
    /// turn, oldest first: see `Plugin`, "Places". 0: no limit, every
    /// download has its card from the start and shows its own status on it.
    public var notchPlaces = 2
    /// After a card left, the next download's card comes no sooner than
    /// this (created in the same breath, it would take the main place from
    /// the card that moves up).
    public var placeGapSeconds = 0.5
    /// A sneak peek is asked for this long after its card was created:
    /// DynamicLake ignores one that comes with it.
    public var peekAfterCreate = 0.2
    /// A paused or failed download's status card in the main place stays
    /// this long past its sneak peek...
    public var spotMarginSeconds = 0.5
    /// ...and the next status card comes this long after it left.
    public var spotGapSeconds = 1.5
    /// Cards lowered to give the main place back keep the low priority
    /// this long (DynamicLake decides who moves up a moment after a card is
    /// dismissed or lowered, by the priorities of that moment; between
    /// equals, another app's activity first, then the card updated last).
    public var handBackSeconds = 0.8
    /// After Resume: time for the browser to act on the command before
    /// focus goes back to your app...
    public var focusSettleSeconds = 0.25
    /// ...which waits, this long at most, for the row's menu to have gone
    /// from the screen (see `clearBrowserFromView`).
    public var menuGoneSeconds = 1.0
    /// How long the Downloads panel may take to go after that...
    public var panelGoneSeconds = 0.5
    /// ...and how long it must have been off the screen to count as gone
    /// (it's out of sight for an instant when the menu goes).
    public var panelAbsentSeconds = 0.2
    /// How long the browser then stays in front before your app is brought
    /// back (it closes its panel as it comes forward)...
    public var blinkSeconds = 0.03
    /// ...which isn't done within this long of a click or a key press of
    /// yours (one under way would land in the browser)...
    public var quietSeconds = 0.5
    /// ...nor once the clearing has taken this long.
    public var clearBudgetSeconds = 3.0
    /// Between two warm-ups of the browser automation.
    public var warmupMinGap = 120.0
    /// Seconds of data before the time left is estimated.
    public var timeLeftSpan = 3.0
    /// How often DynamicLake's plugin settings are read again.
    public var settingsRefreshSeconds = 5.0
    /// Seconds before a button's script is abandoned.
    public var stopScriptTimeout = 20.0
    /// Log it if no total size shows up in this time.
    public var totalWaitSeconds = 10.0
    /// The log is set aside and begun anew past this size, in bytes.
    public var logMaxBytes = 256 * 1024
    /// How often the browsers' profile folders are read again.
    public var dirRefreshSeconds = 300.0

    public init() {}
}

/// The pill's width: "small" (an icon and a ring, the same geometry as
/// DynamicLake's built-in activities), "normal" or "large".
let activitySize = "small"

/// Firefox-family browsers: their folder in ~/Library/Application Support,
/// and the name of their process (used to try the right browser first).
let firefoxFamily: KeyValuePairs<String, String> = [
    "Firefox": "firefox",
    "Firefox Developer Edition": "firefox",
    "Firefox Nightly": "firefox",
    "Firefox Beta": "firefox",
    "LibreWolf": "librewolf",
    "Waterfox": "waterfox",
    "Waterfox Classic": "waterfox",
    "Pale Moon": "palemoon",
    "Basilisk": "",
    "SeaMonkey": "",
    "IceCat": "",
]
