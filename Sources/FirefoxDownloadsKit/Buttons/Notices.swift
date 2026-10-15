// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What the card says for each outcome of Stop, Resume and Retry. The
/// "-sent" outcomes are not in here: the plugin then waits for the browser
/// (the partial file disappearing, or growing again).
enum Notices {
    private static let common = [
        "accessibility-not-granted": "Needs Accessibility access",
        "automation-not-granted": "Needs Automation access",
        "no-match": "Not in the Downloads panel",
        "changed": "Panel busy — try again",
        "no-panel": "Downloads panel didn't open",
        "no-button": "No Downloads button in toolbar",
        "no-browser": "Browser isn't running",
    ]

    static let action: [String: [String: String]] = {
        let retry = common.merging([
            "ambiguous": "Several matches — retry in browser",
            "not-active": "Nothing to retry in the panel",
        ]) { $1 }
        return [
            "stop": common.merging([
                "ambiguous": "Several matches — cancel in browser",
                "not-active": "Not in the Downloads panel",
            ]) { $1 },
            "resume": common.merging([
                "ambiguous": "Several matches — resume in browser",
                "not-active": "Not paused in the browser",
                "not-paused": "Not paused in the browser",
                "no-menu": "No menu — resume in browser",
                "show-error": "No menu — resume in browser",
                "wrong-menu": "No menu — resume in browser",
                "row-hidden": "Row hidden — resume in browser",
                "menu-changed": "Panel busy — try again",
                "not-pressed": "Resume failed — resume in browser",
                "menu-open": "Menu left open — click elsewhere",
            ]) { $1 },
            // "restart": the Retry button of a canceled card (the panel's
            // Retry of a canceled download, which starts it over).
            "retry": retry,
            "restart": retry,
        ]
    }()

    static let working = ["stop": "Stopping…", "resume": "Resuming…", "retry": "Retrying…", "restart": "Retrying…"]
    static let gaveUp = [
        "stop": "Didn't stop — cancel in browser",
        "resume": "Didn't resume — resume in browser",
        "retry": "Didn't restart — retry in browser",
        "restart": "Didn't restart — retry in browser",
    ]
    /// Pressed (or the press reported an error but may have gone through):
    /// wait for the browser.
    static let sent = [
        "stop": ["cancel-sent", "press-failed"],
        "resume": ["resume-sent", "press-failed"],
        "retry": ["retry-sent", "press-failed"],
        "restart": ["restart-sent", "press-failed"],
    ]
    static let fallback = "Couldn't reach the browser"

    /// Where each button shows.
    static let actionStates = ["stop": "active", "resume": "paused", "retry": "failed"]
    static let actionNames = ["stop": "Stop", "resume": "Resume", "retry": "Retry", "restart": "Retry"]
}
