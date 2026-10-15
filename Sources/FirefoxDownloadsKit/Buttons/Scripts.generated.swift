// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Generated from the plugin's AppleScript sources and Firefox's labels:
// the scripts exactly as they run, the same as in Firefox Downloads 1.1.3.

enum Scripts {
    /// The script the buttons run ("mode:cancel", "mode:resume",
    /// "mode:retry", "mode:restart", "mode:locate").
    static let fast = #"""
-- Firefox Downloads: act on ONE download in a Firefox-family browser through
-- the toolbar Downloads panel, without bringing the browser to the front.
-- Every step is a direct accessibility read or action; nothing is typed and
-- no window is activated.
--
-- Actions ("mode:" argument):
--   cancel  Stop (the default): press the row's Cancel button.
--   retry   press the Retry button of the row showing Failed.
--   restart press the Retry button of the row showing Canceled (or Failed,
--           when the browser deleted what it had): the browser starts that
--           download over.
--   resume  a paused row has no Resume button, so show the row's
--           right-click menu, where Resume is; the plugin chooses it (System
--           Events can't be relied on to reach a right-click menu).
--           Showing a row's menu makes the browser move the pointer onto
--           the row; the plugin moves it back.
--   locate  only find the toolbar button (a warm-up); press nothing.
--
-- Safety: apart from the toolbar Downloads button, the only things ever
-- pressed here are a row's own Cancel or Retry button, matched by Firefox's
-- exact labels (in any language), in the single row whose title starts with
-- this download's file name (same case), checked again right before
-- pressing; for Resume, that row's menu is shown instead. (The panel shows
-- a long name shortened in the middle: such a row counts only when the
-- whole name on its name label is exactly this file's.) Rows of finished,
-- failed or canceled downloads have no Cancel button, so Stop ignores
-- same-named entries left in the panel's history.
--
-- Speed: elements are addressed by position (window 1 > group 1 > toolbar 2
-- > item 4 ...), spelled out from the browser process in each request, and
-- whole lists of ids, titles and labels are read in one request each,
-- instead of walking the window one element at a time. A slower
-- element-by-element search is only a fallback, and it never enters web
-- page content.
--
-- Arguments: "name:<file name>" (one per Unicode form of the name), and
-- optionally "mode:<action>", "proc:<process>" (the browser to try first)
-- and "btn:<w.g.t.i>" (where the toolbar button was last time; checked
-- before use). Returns "outcome|trace|process|button position|row
-- frame|process id": for Resume, the row whose menu was shown ("x,y,w,h";
-- the browser puts the pointer in its middle and opens the menu there) and
-- the browser's process id, so that the plugin can choose Resume in it --
-- or, for "menu-changed" and "show-error", close it.

-- ------------------------------------------------------------- basics

on attrText(el, attrName)
    -- One accessibility attribute of one element, as text ("" if missing).
    set gotText to ""
    tell application "System Events"
        try
            set rawValue to value of attribute attrName of el
            if rawValue is not missing value then set gotText to rawValue as string
        end try
    end tell
    return gotText
end attrText

on childAttrText(parentRef, childIdx, attrName)
    -- One attribute of the parent's Nth child ("" if missing).
    set gotText to ""
    tell application "System Events"
        try
            set rawValue to value of attribute attrName of UI element childIdx of parentRef
            if rawValue is not missing value then set gotText to rawValue as string
        end try
    end tell
    return gotText
end childAttrText

on childCountOf(el)
    set childNum to 0
    tell application "System Events"
        try
            set childNum to count of UI elements of el
        end try
    end tell
    return childNum
end childCountOf

on asList(maybeList)
    if maybeList is missing value then return missing value
    if (class of maybeList) is list then return maybeList
    return {maybeList}
end asList

on indexOfText(theList, wanted)
    repeat with i from 1 to (count of theList)
        set oneItem to item i of theList
        if oneItem is not missing value then
            try
                if (oneItem as string) is wanted then return i
            end try
        end if
    end repeat
    return 0
end indexOfText

on parseLoc(posText)
    -- "1.1.2.4" -> {1, 1, 2, 4}; anything else -> {}
    set savedDelims to AppleScript's text item delimiters
    set AppleScript's text item delimiters to "."
    set locParts to text items of posText
    set AppleScript's text item delimiters to savedDelims
    if (count of locParts) is not 4 then return {}
    set loc to {}
    try
        repeat with onePart in locParts
            set end of loc to ((contents of onePart) as integer)
        end repeat
    on error
        return {}
    end try
    return loc
end parseLoc

on locText(loc)
    if (count of loc) is not 4 then return ""
    return ((item 1 of loc) as string) & "." & (item 2 of loc) & "." & (item 3 of loc) & "." & (item 4 of loc)
end locText

-- ------------------------------------------------------------- fallback search, element by element

on childrenOf(el)
    set kids to {}
    tell application "System Events"
        try
            set kids to UI elements of el
        end try
    end tell
    return kids
end childrenOf

on isWebArea(el)
    set webArea to false
    tell application "System Events"
        try
            if (value of attribute "AXRole" of el) is "AXWebArea" then set webArea to true
        end try
    end tell
    return webArea
end isWebArea

on firstByDomId(el, wantId, depthLeft)
    -- Web pages can use the same ids, so page content is never entered.
    if depthLeft is 0 then return missing value
    repeat with k in my childrenOf(el)
        set kk to (contents of k)
        if my attrText(kk, "AXDOMIdentifier") is wantId then return kk
        if not (my isWebArea(kk)) then
            set foundEl to my firstByDomId(kk, wantId, depthLeft - 1)
            if foundEl is not missing value then return foundEl
        end if
    end repeat
    return missing value
end firstByDomId

on findInWindows(procName, wantId, depthLimit)
    set wins to {}
    tell application "System Events"
        try
            set wins to windows of process procName
        end try
    end tell
    repeat with w in wins
        set foundEl to my firstByDomId((contents of w), wantId, depthLimit)
        if foundEl is not missing value then return foundEl
    end repeat
    return missing value
end findInWindows

on pressElement(el)
    tell application "System Events"
        try
            perform action "AXPress" of el
            return true
        end try
    end tell
    return false
end pressElement

-- ------------------------------------------------------------- browser and permissions

on isFirefoxFamily(procName)
    repeat with knownName in {"firefox", "firefox-bin", "librewolf", "waterfox", "palemoon", "pale moon", "tor browser", "torbrowser"}
        if procName is (contents of knownName) then return true
    end repeat
    return false
end isFirefoxFamily

on browserProcesses(hintName)
    -- Running Firefox-family browsers, the one that answered last time first.
    set runningNames to {}
    tell application "System Events"
        try
            set runningNames to name of every application process
        on error errText number errNum
            if errNum is -1743 or errText contains "not authorized" then error "automation-denied: " & errText number errNum
        end try
    end tell
    set found to {}
    repeat with rn in runningNames
        set oneName to (contents of rn) as string
        if my isFirefoxFamily(oneName) and found does not contain oneName then
            if oneName is hintName then
                set beginning of found to oneName
            else
                set end of found to oneName
            end if
        end if
    end repeat
    return found
end browserProcesses

on windowCount(procName)
    -- Also the permission check: without Accessibility access this is the
    -- first request that fails, and that error is passed on (marked, so it
    -- is recognised in any language) instead of being mistaken for a
    -- missing toolbar button.
    set winCount to 0
    tell application "System Events"
        try
            set winCount to count of windows of process procName
        on error errText number errNum
            if errNum is -1743 or errText contains "not authorized" then error "automation-denied: " & errText number errNum
            if errNum is -25211 or errNum is -1719 or errText contains "assistive" or errText contains "not allowed" then error "assistive-access-denied: " & errText number errNum
        end try
    end tell
    return winCount
end windowCount

-- ------------------------------------------------------------- the toolbar Downloads button, by position

on toolbarItemId(procName, loc)
    set winIdx to item 1 of loc
    set grpIdx to item 2 of loc
    set barIdx to item 3 of loc
    set itemIdx to item 4 of loc
    set gotId to ""
    tell application "System Events"
        try
            set rawId to value of attribute "AXDOMIdentifier" of UI element itemIdx of toolbar barIdx of group grpIdx of window winIdx of process procName
            if rawId is not missing value then set gotId to rawId as string
        end try
    end tell
    return gotId
end toolbarItemId

on toolbarItemIds(procName, winIdx, grpIdx, barIdx)
    set idList to missing value
    tell application "System Events"
        try
            set idList to value of attribute "AXDOMIdentifier" of every UI element of toolbar barIdx of group grpIdx of window winIdx of process procName
        end try
    end tell
    set idList to my asList(idList)
    if idList is missing value then
        set itemCount to 0
        tell application "System Events"
            try
                set itemCount to count of UI elements of toolbar barIdx of group grpIdx of window winIdx of process procName
            end try
        end tell
        set idList to {}
        repeat with itemIdx from 1 to itemCount
            set end of idList to my toolbarItemId(procName, {winIdx, grpIdx, barIdx, itemIdx})
        end repeat
    end if
    return idList
end toolbarItemIds

on pressToolbarItem(procName, loc)
    set winIdx to item 1 of loc
    set grpIdx to item 2 of loc
    set barIdx to item 3 of loc
    set itemIdx to item 4 of loc
    tell application "System Events"
        try
            perform action "AXPress" of UI element itemIdx of toolbar barIdx of group grpIdx of window winIdx of process procName
            return true
        end try
    end tell
    return false
end pressToolbarItem

on findDownloadsButton(procName, hintLoc, skipWins)
    -- Where Firefox keeps it: a toolbar directly inside a group directly
    -- inside a window. Returns its position {window, group, toolbar, item},
    -- or {}. Windows in skipWins are left out.
    if (count of hintLoc) is 4 then
        if skipWins does not contain (item 1 of hintLoc) then
            if my toolbarItemId(procName, hintLoc) is "downloads-button" then return hintLoc
        end if
    end if
    repeat with winIdx from 1 to my windowCount(procName)
        if skipWins does not contain winIdx then
            set groupCount to 0
            tell application "System Events"
                try
                    set groupCount to count of groups of window winIdx of process procName
                end try
            end tell
            repeat with grpIdx from 1 to groupCount
                set barCount to 0
                tell application "System Events"
                    try
                        set barCount to count of toolbars of group grpIdx of window winIdx of process procName
                    end try
                end tell
                repeat with barIdx from 1 to barCount
                    set itemIdx to my indexOfText(my toolbarItemIds(procName, winIdx, grpIdx, barIdx), "downloads-button")
                    if itemIdx > 0 then
                        set loc to {winIdx, grpIdx, barIdx, itemIdx}
                        -- one more read of just that element, in case the
                        -- one-request list came back out of order
                        if my toolbarItemId(procName, loc) is "downloads-button" then return loc
                    end if
                end repeat
            end repeat
        end if
    end repeat
    return {}
end findDownloadsButton

-- ------------------------------------------------------------- the panel and its list, by position

on groupChildIds(procName, winIdx, grpIdx)
    set idList to missing value
    tell application "System Events"
        try
            set idList to value of attribute "AXDOMIdentifier" of every UI element of group grpIdx of window winIdx of process procName
        end try
    end tell
    set idList to my asList(idList)
    if idList is missing value then
        set childNum to 0
        tell application "System Events"
            try
                set childNum to count of UI elements of group grpIdx of window winIdx of process procName
            end try
        end tell
        set idList to {}
        repeat with childIdx from 1 to childNum
            set oneId to ""
            tell application "System Events"
                try
                    set rawId to value of attribute "AXDOMIdentifier" of UI element childIdx of group grpIdx of window winIdx of process procName
                    if rawId is not missing value then set oneId to rawId as string
                end try
            end tell
            set end of idList to oneId
        end repeat
    end if
    return idList
end groupChildIds

on panelSpot(procName, winIdx, firstGrp, allGroups)
    -- {group, position} of the open panel in this window, or {}. It sits in
    -- the toolbar's own group in LibreWolf, so that group is checked first.
    set panelIdx to my indexOfText(my groupChildIds(procName, winIdx, firstGrp), "downloadsPanel")
    if panelIdx > 0 then return {firstGrp, panelIdx}
    if allGroups then
        set groupCount to 0
        tell application "System Events"
            try
                set groupCount to count of groups of window winIdx of process procName
            end try
        end tell
        repeat with grpIdx from 1 to groupCount
            if grpIdx is not firstGrp then
                set panelIdx to my indexOfText(my groupChildIds(procName, winIdx, grpIdx), "downloadsPanel")
                if panelIdx > 0 then return {grpIdx, panelIdx}
            end if
        end repeat
    end if
    return {}
end panelSpot

on listRefFor(procName, winIdx, spot)
    -- The panel's download list, checked by reading its id through the
    -- reference before it is used.
    set grpIdx to item 1 of spot
    set panelIdx to item 2 of spot
    set idList to missing value
    tell application "System Events"
        try
            set idList to value of attribute "AXDOMIdentifier" of every UI element of UI element panelIdx of group grpIdx of window winIdx of process procName
        end try
    end tell
    set idList to my asList(idList)
    if idList is missing value then set idList to {}
    set listIdx to my indexOfText(idList, "downloadsListBox")
    if listIdx > 0 then
        -- by position from the process (stays valid if the page title changes)
        try
            tell application "System Events"
                set listRef to a reference to UI element listIdx of UI element panelIdx of group grpIdx of window winIdx of process procName
            end tell
            if my attrText(listRef, "AXDOMIdentifier") is "downloadsListBox" then return listRef
        end try
        -- System Events' own reference to it
        try
            tell application "System Events"
                set listRef to UI element listIdx of UI element panelIdx of group grpIdx of window winIdx of process procName
            end tell
            if my attrText(listRef, "AXDOMIdentifier") is "downloadsListBox" then return listRef
        end try
    end if
    -- search inside the panel
    set panelEl to missing value
    tell application "System Events"
        try
            set panelEl to UI element panelIdx of group grpIdx of window winIdx of process procName
        end try
    end tell
    if panelEl is missing value then return missing value
    return my firstByDomId(panelEl, "downloadsListBox", 3)
end listRefFor

-- ------------------------------------------------------------- rows

on rowTitlesOf(listRef, batched)
    -- Titles of the panel rows, in order: in one request when batched is
    -- true, otherwise one request per row.
    set titleList to missing value
    if batched then
        tell application "System Events"
            try
                set titleList to value of attribute "AXTitle" of every UI element of listRef
            end try
        end tell
        set titleList to my asList(titleList)
    end if
    if titleList is missing value then
        set titleList to {}
        repeat with rowIdx from 1 to my childCountOf(listRef)
            set end of titleList to my childAttrText(listRef, rowIdx, "AXTitle")
        end repeat
    end if
    set cleanList to {}
    repeat with oneTitle in titleList
        set rawTitle to contents of oneTitle
        if rawTitle is missing value then
            set end of cleanList to ""
        else
            set end of cleanList to (rawTitle as string)
        end if
    end repeat
    return cleanList
end rowTitlesOf

on rowButtonLabel(listRef, rowIdx, btnIdx)
    set lbl to ""
    tell application "System Events"
        try
            set rawLabel to value of attribute "AXDescription" of button btnIdx of UI element rowIdx of listRef
            if rawLabel is not missing value then set lbl to rawLabel as string
        end try
        if lbl is "" then
            try
                set rawLabel to value of attribute "AXTitle" of button btnIdx of UI element rowIdx of listRef
                if rawLabel is not missing value then set lbl to rawLabel as string
            end try
        end if
    end tell
    return lbl
end rowButtonLabel

on rowButtonLabels(listRef, rowIdx, batched)
    -- Labels of one row's buttons, in order.
    set labelList to missing value
    if batched then
        tell application "System Events"
            try
                set labelList to value of attribute "AXDescription" of every button of UI element rowIdx of listRef
            end try
        end tell
        set labelList to my asList(labelList)
    end if
    if labelList is missing value then
        set btnCount to 0
        tell application "System Events"
            try
                set btnCount to count of buttons of UI element rowIdx of listRef
            end try
        end tell
        set labelList to {}
        repeat with btnIdx from 1 to btnCount
            set end of labelList to ""
        end repeat
    end if
    set cleanList to {}
    repeat with btnIdx from 1 to (count of labelList)
        set rawLabel to item btnIdx of labelList
        if rawLabel is missing value or rawLabel is "" then
            set end of cleanList to my rowButtonLabel(listRef, rowIdx, btnIdx)
        else
            set end of cleanList to (rawLabel as string)
        end if
    end repeat
    return cleanList
end rowButtonLabels

property cachedCancelLabels : missing value

on looksLikeCancel(theText)
    -- True only for the EXACT label of a download row's Cancel button (downloads-cmd-cancel-panel).
    -- No other button a row can have (Retry, Show in Finder, Remove File...)
    -- has one of these labels in any language. A label that merely contains
    -- "cancel" does not count: in Ligurian, "Remove File" is "Scancella schedaio".
    -- Firefox's own translations, in all 115 languages it has. (Letter case
    -- aside: no other label differs from one of these only by case.) The
    -- list is built once per run.
    set lbl to theText as string
    if lbl is "" then return false
    if my cachedCancelLabels is missing value then set my cachedCancelLabels to (my asciiCancelLabels()) & (my otherCancelLabels())
    repeat with oneLabel in my cachedCancelLabels
        if lbl is (contents of oneLabel) then return true
    end repeat
    return false
end looksLikeCancel

on asciiCancelLabels()
    -- The labels written in plain ASCII (English first).
    set labelList to {}
    set labelList to labelList & {"Cancel", "&Haaytu", "Abbrechen", "Annulearje", "Annuler", "Annuleren", "Annulla"}
    set labelList to labelList & {"Annuller", "Anule", "Anulla", "Anullar", "Anuloje", "Anuluj", "Atcelt", "Atsisakyti"}
    set labelList to labelList & {"Avbryt", "Batal", "Batalkan", "Bekor qilish", "Cancelar", "Cancellar", "Cealaigh"}
    set labelList to labelList & {"Diddymu", "Duyichin'", "Encaboxar", "Heja", "Interrumper", "Juki", "Kanselahin"}
    set labelList to labelList & {"Kanselleer", "Katkesta", "Neenal", "Nkuvi-ka", "Nuligi", "Odustani", "Peruuta", "Pociep"}
    set labelList to labelList & {"Rhoxisa", "Sefsex", "Sfai", "Sguir dheth", "Stap", "Tiq'at", "Utzi"}
    return labelList
end asciiCancelLabels

on otherCancelLabels()
    -- The other labels, spelled as Unicode code points so this script
    -- stays plain ASCII.
    set labelList to {}
    set labelList to labelList & {("Anuleaz" & (character id 259)), ("Atce" & (character id 316) & "t")}
    set labelList to labelList & {("Cancel" & (character id 183) & "la")}
    set labelList to labelList & {("H" & (character id 230) & "tta vi" & (character id 240))}
    set labelList to labelList & {("H" & (character id 7911) & "y b" & (character id 7887)), ((character id 304) & "ptal")}
    set labelList to labelList & {("L" & (character id 601) & (character id 287) & "v et")}
    set labelList to labelList & {("M" & (character id 233) & "gse"), ("Na" & (character id 331))}
    set labelList to labelList & {("Nulla" & (character id 241)), ("Otka" & (character id 382) & "i")}
    set labelList to labelList & {("Prekli" & (character id 269) & "i")}
    set labelList to labelList & {("P" & (character id 345) & "etorhny" & (character id 263))}
    set labelList to labelList & {("P" & (character id 347) & "etergnu" & (character id 347))}
    set labelList to labelList & {("Zru" & (character id 353) & "it")}
    set labelList to labelList & {("Zru" & (character id 353) & "i" & (character id 357))}
    set labelList to labelList & {((character id 913) & (character id 954) & (character id 973) & (character id 961) & (character id 969) & (character id 963) & (character id 951))}
    set labelList to labelList & {((character id 1041) & (character id 1072) & (character id 1089) & " " & (character id 1090) & (character id 1072) & (character id 1088) & (character id 1090) & (character id 1091))}
    set labelList to labelList & {((character id 1041) & (character id 1077) & (character id 1082) & (character id 1086) & (character id 1088) & " " & (character id 1082) & (character id 1072) & (character id 1088) & (character id 1076) & (character id 1072) & (character id 1085))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1082) & (character id 1072) & (character id 1078) & (character id 1080))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1084) & (character id 1077) & (character id 1085) & (character id 1080) & (character id 1090) & (character id 1100))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1077) & (character id 1082) & (character id 1098) & (character id 1089) & (character id 1074) & (character id 1072) & (character id 1085) & (character id 1077))}
    set labelList to labelList & {((character id 1057) & (character id 1082) & (character id 1072) & (character id 1089) & (character id 1072) & (character id 1074) & (character id 1072) & (character id 1094) & (character id 1100))}
    set labelList to labelList & {((character id 1057) & (character id 1082) & (character id 1072) & (character id 1089) & (character id 1091) & (character id 1074) & (character id 1072) & (character id 1090) & (character id 1080))}
    set labelList to labelList & {((character id 1353) & (character id 1381) & (character id 1394) & (character id 1377) & (character id 1408) & (character id 1391) & (character id 1381) & (character id 1388))}
    set labelList to labelList & {((character id 1489) & (character id 1497) & (character id 1496) & (character id 1493) & (character id 1500))}
    set labelList to labelList & {((character id 1571) & (character id 1604) & (character id 1594) & (character id 1616))}
    set labelList to labelList & {((character id 1575) & (character id 1606) & (character id 1589) & (character id 1585) & (character id 1575) & (character id 1601))}
    set labelList to labelList & {((character id 1604) & (character id 1602) & (character id 1608))}
    set labelList to labelList & {((character id 1605) & (character id 1606) & (character id 1587) & (character id 1608) & (character id 1582))}
    set labelList to labelList & {((character id 1605) & (character id 1606) & (character id 1587) & (character id 1608) & (character id 1582) & " " & (character id 1705) & (character id 1585) & (character id 1740) & (character id 1722))}
    set labelList to labelList & {((character id 1662) & (character id 1575) & (character id 1588) & (character id 1711) & (character id 1749) & (character id 1586) & (character id 1576) & (character id 1608) & (character id 1608) & (character id 1606) & (character id 1749) & (character id 1608) & (character id 1749))}
    set labelList to labelList & {((character id 2344) & (character id 2375) & (character id 2357) & (character id 2360) & (character id 2367) & (character id 2327) & (character id 2366) & (character id 2352))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2325) & (character id 2352) & (character id 2366))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2325) & (character id 2352) & (character id 2375) & (character id 2306))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2327) & (character id 2352) & (character id 2381) & (character id 2344) & (character id 2369) & (character id 2361) & (character id 2379) & (character id 2360) & (character id 2381))}
    set labelList to labelList & {((character id 2476) & (character id 2494) & (character id 2468) & (character id 2495) & (character id 2482))}
    set labelList to labelList & {((character id 2608) & (character id 2673) & (character id 2598) & " " & (character id 2581) & (character id 2608) & (character id 2635))}
    set labelList to labelList & {((character id 2736) & (character id 2726) & " " & (character id 2709) & (character id 2736) & (character id 2763))}
    set labelList to labelList & {((character id 2992) & (character id 2980) & (character id 3021) & (character id 2980) & (character id 3009))}
    set labelList to labelList & {((character id 3120) & (character id 3110) & (character id 3149) & (character id 3110) & (character id 3137) & (character id 3098) & (character id 3143) & (character id 3119) & (character id 3135))}
    set labelList to labelList & {((character id 3248) & (character id 3238) & (character id 3277) & (character id 3238) & (character id 3265) & " " & (character id 3246) & (character id 3262) & (character id 3233) & (character id 3265))}
    set labelList to labelList & {((character id 3377) & (character id 3366) & (character id 3405) & (character id 3366) & (character id 3390) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3349))}
    set labelList to labelList & {((character id 3461) & (character id 3520) & (character id 3517) & (character id 3458) & (character id 3484) & (character id 3540))}
    set labelList to labelList & {((character id 3618) & (character id 3585) & (character id 3648) & (character id 3621) & (character id 3636) & (character id 3585))}
    set labelList to labelList & {((character id 3725) & (character id 3771) & (character id 3713) & (character id 3776) & (character id 3749) & (character id 3765) & (character id 3713))}
    set labelList to labelList & {((character id 3925) & (character id 4017) & (character id 3954) & (character id 3938) & (character id 3851) & (character id 3936) & (character id 3920) & (character id 3962) & (character id 3923))}
    set labelList to labelList & {((character id 4121) & (character id 4124) & (character id 4143) & (character id 4117) & (character id 4154) & (character id 4102) & (character id 4145) & (character id 4140) & (character id 4100) & (character id 4154) & (character id 4112) & (character id 4145) & (character id 4140) & (character id 4151) & (character id 4117) & (character id 4139))}
    set labelList to labelList & {((character id 4306) & (character id 4304) & (character id 4323) & (character id 4325) & (character id 4315) & (character id 4308) & (character id 4305) & (character id 4304))}
    set labelList to labelList & {((character id 6036) & (character id 6084) & (character id 6087) & (character id 6036) & (character id 6020) & (character id 6091))}
    set labelList to labelList & {((character id 7285) & (character id 7263) & (character id 7289) & (character id 7280) & (character id 7272) & (character id 7263) & (character id 7289))}
    set labelList to labelList & {((character id 12461) & (character id 12515) & (character id 12531) & (character id 12475) & (character id 12523))}
    set labelList to labelList & {((character id 21462) & (character id 28040))}
    set labelList to labelList & {((character id 52712) & (character id 49548))}
    return labelList
end otherCancelLabels

property cachedRetryLabels : missing value

on looksLikeRetry(theText)
    -- True only for the EXACT label of a download row's Retry button (downloads-cmd-retry-panel).
    -- No other button a row can have has one of these labels in any language.
    -- Firefox's own translations, in all 114 languages it has. (Letter case
    -- aside: no other label differs from one of these only by case.) The
    -- list is built once per run.
    set lbl to theText as string
    if lbl is "" then return false
    if my cachedRetryLabels is missing value then set my cachedRetryLabels to (my asciiRetryLabels()) & (my otherRetryLabels())
    repeat with oneLabel in my cachedRetryLabels
        if lbl is (contents of oneLabel) then return true
    end repeat
    return false
end looksLikeRetry

on asciiRetryLabels()
    -- The labels written in plain ASCII (English first).
    set labelList to {}
    set labelList to labelList & {"Retry", "Atkuortuot", "Atriail", "Ceisio eto", "Coba Lagi", "Cuba lagi"}
    set labelList to labelList & {"Empruvar anc ina giada", "Feuch ris a-rithist", "Klask en-dro", "Klopodi denove"}
    set labelList to labelList & {"Nochmals versuchen", "Opakovat", "Opnieuw proberen", "Opnij probearje", "Phinda uzame"}
    set labelList to labelList & {"Poskusi znova", "Preuva torna", "Probeer weer", "Proovi uuesti", "Qayta urinish"}
    set labelList to labelList & {"Reintenta", "Reintentar", "Repetir", "Retentar", "Reyna aftur", "Riprova", "Riprovo"}
    set labelList to labelList & {"Saiatu berriro", "Subukan muli", "Tem odoco", "Tentar de novo", "Tornar a prebar"}
    set labelList to labelList & {"Tornar ensajar", "Torne prove", "Torra a proare", "Try Again", "Voltar a tentar"}
    set labelList to labelList & {"Yeniden dene", "Znova"}
    return labelList
end asciiRetryLabels

on otherRetryLabels()
    -- The other labels, spelled as Unicode code points so this script
    -- stays plain ASCII.
    set labelList to {}
    set labelList to labelList & {("A'ngo " & (character id 241) & "un"), ("Atk" & (character id 257) & "rtot")}
    set labelList to labelList & {("E" & (character id 241) & "eha" & (character id 8217) & (character id 227) & " jey")}
    set labelList to labelList & {("Fu" & (character id 599) & (character id 599) & "ito")}
    set labelList to labelList & {("F" & (character id 246) & "rs" & (character id 246) & "k igen")}
    set labelList to labelList & {("Hi" & (character id 353) & (character id 263) & "e raz spyta" & (character id 263))}
    set labelList to labelList & {("Hy" & (character id 353) & (character id 263) & "i raz wopyta" & (character id 347))}
    set labelList to labelList & {("I" & (character id 353) & " naujo"), ("J" & (character id 233) & "emaat")}
    set labelList to labelList & {("Nas" & (character id 225) & (character id 180) & (character id 225) & " tuku")}
    set labelList to labelList & {("Poku" & (character id 353) & "aj ponovo"), ("Pr" & (character id 248) & "v igen")}
    set labelList to labelList & {("Pr" & (character id 248) & "v igjen")}
    set labelList to labelList & {("Pr" & (character id 248) & "v p" & (character id 229) & " nytt")}
    set labelList to labelList & {("Re" & (character id 238) & "ncearc" & (character id 259))}
    set labelList to labelList & {("R" & (character id 233) & "essayer"), ("Spr" & (character id 243) & "buj ponownie")}
    set labelList to labelList & {("Spr" & (character id 333) & "buj za" & (character id 347))}
    set labelList to labelList & {("Th" & (character id 7917) & " l" & (character id 7841) & "i")}
    set labelList to labelList & {("Titojtob'" & (character id 235) & "x chik"), ("T" & (character id 601) & "krar yoxla")}
    set labelList to labelList & {("Yrit" & (character id 228) & " uudestaan"), ((character id 218) & "jra")}
    set labelList to labelList & {((character id 352) & "ii taaga")}
    set labelList to labelList & {((character id 400) & "re" & (character id 7693) & " i tikelt-nni" & (character id 7693) & "en")}
    set labelList to labelList & {((character id 917) & (character id 960) & (character id 945) & (character id 957) & (character id 940) & (character id 955) & (character id 951) & (character id 968) & (character id 951))}
    set labelList to labelList & {((character id 1055) & (character id 1072) & (character id 1118) & (character id 1090) & (character id 1072) & (character id 1088) & (character id 1099) & (character id 1094) & (character id 1100))}
    set labelList to labelList & {((character id 1055) & (character id 1086) & (character id 1074) & (character id 1090) & (character id 1086) & (character id 1088) & (character id 1077) & (character id 1085) & " " & (character id 1086) & (character id 1087) & (character id 1080) & (character id 1090))}
    set labelList to labelList & {((character id 1055) & (character id 1086) & (character id 1074) & (character id 1090) & (character id 1086) & (character id 1088) & (character id 1080) & (character id 1090) & (character id 1080))}
    set labelList to labelList & {((character id 1055) & (character id 1086) & (character id 1074) & (character id 1090) & (character id 1086) & (character id 1088) & (character id 1080) & (character id 1090) & (character id 1100))}
    set labelList to labelList & {((character id 1055) & (character id 1086) & (character id 1082) & (character id 1091) & (character id 1096) & (character id 1072) & (character id 1112) & " " & (character id 1087) & (character id 1086) & (character id 1085) & (character id 1086) & (character id 1074) & (character id 1086))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1086) & (character id 1073) & (character id 1072) & (character id 1112) & " " & (character id 1087) & (character id 1072) & (character id 1082))}
    set labelList to labelList & {((character id 1058) & (character id 1072) & (character id 1082) & (character id 1088) & (character id 1086) & (character id 1088) & " " & (character id 1082) & (character id 1072) & (character id 1088) & (character id 1076) & (character id 1072) & (character id 1085))}
    set labelList to labelList & {((character id 1178) & (character id 1072) & (character id 1081) & (character id 1090) & (character id 1072) & (character id 1083) & (character id 1072) & (character id 1091))}
    set labelList to labelList & {((character id 1343) & (character id 1408) & (character id 1391) & (character id 1387) & (character id 1398) & " " & (character id 1411) & (character id 1400) & (character id 1408) & (character id 1393) & (character id 1381) & (character id 1388))}
    set labelList to labelList & {((character id 1343) & (character id 1408) & (character id 1391) & (character id 1398) & (character id 1381) & (character id 1388))}
    set labelList to labelList & {((character id 1504) & (character id 1497) & (character id 1505) & (character id 1497) & (character id 1493) & (character id 1503) & " " & (character id 1495) & (character id 1493) & (character id 1494) & (character id 1512))}
    set labelList to labelList & {((character id 1571) & (character id 1593) & (character id 1583) & " " & (character id 1575) & (character id 1604) & (character id 1605) & (character id 1581) & (character id 1575) & (character id 1608) & (character id 1604) & (character id 1577))}
    set labelList to labelList & {((character id 1602) & (character id 1662) & " " & (character id 1585) & (character id 1740) & (character id 1578) & " " & (character id 1583) & (character id 1608) & (character id 1608) & (character id 1575) & (character id 1585) & (character id 1578) & (character id 1607))}
    set labelList to labelList & {((character id 1607) & (character id 1749) & (character id 1608) & (character id 1717) & " " & (character id 1576) & (character id 1583) & (character id 1749) & (character id 1585) & (character id 1749) & (character id 1608) & (character id 1749))}
    set labelList to labelList & {((character id 1608) & (character id 1604) & (character id 1575) & " " & (character id 1705) & (character id 1608) & (character id 1588) & (character id 1588) & " " & (character id 1705) & (character id 1585) & (character id 1608))}
    set labelList to labelList & {((character id 1662) & (character id 1726) & (character id 1585) & " " & (character id 1705) & (character id 1608) & (character id 1588) & (character id 1588) & " " & (character id 1705) & (character id 1585) & (character id 1740) & (character id 1722))}
    set labelList to labelList & {((character id 1705) & (character id 1608) & (character id 1588) & (character id 1588) & " " & (character id 1583) & (character id 1608) & (character id 1576) & (character id 1575) & (character id 1585) & (character id 1607))}
    set labelList to labelList & {((character id 2346) & (character id 2369) & (character id 2344) & (character id 2307) & " " & (character id 2346) & (character id 2381) & (character id 2352) & (character id 2351) & (character id 2366) & (character id 2360) & " " & (character id 2327) & (character id 2352) & (character id 2381) & (character id 2344) & (character id 2369) & (character id 2361) & (character id 2379) & (character id 2360) & (character id 2381))}
    set labelList to labelList & {((character id 2346) & (character id 2369) & (character id 2344) & (character id 2307) & (character id 2346) & (character id 2381) & (character id 2352) & (character id 2351) & (character id 2340) & (character id 2381) & (character id 2344) & " " & (character id 2325) & (character id 2352) & (character id 2366))}
    set labelList to labelList & {((character id 2347) & (character id 2367) & (character id 2344) & " " & (character id 2344) & (character id 2366) & (character id 2332) & (character id 2366))}
    set labelList to labelList & {((character id 2347) & (character id 2367) & (character id 2352) & " " & (character id 2325) & (character id 2379) & (character id 2358) & (character id 2367) & (character id 2358) & (character id 8204) & " " & (character id 2325) & (character id 2352) & (character id 2375) & (character id 2306))}
    set labelList to labelList & {((character id 2474) & (character id 2497) & (character id 2472) & (character id 2480) & (character id 2494) & (character id 2527) & " " & (character id 2458) & (character id 2503) & (character id 2487) & (character id 2509) & (character id 2463) & (character id 2494) & " " & (character id 2453) & (character id 2480) & (character id 2497) & (character id 2472))}
    set labelList to labelList & {((character id 2606) & (character id 2625) & (character id 2652) & "-" & (character id 2581) & (character id 2635) & (character id 2616) & (character id 2620) & (character id 2623) & (character id 2616) & (character id 2620))}
    set labelList to labelList & {((character id 2731) & (character id 2736) & (character id 2752) & " " & (character id 2730) & (character id 2765) & (character id 2736) & (character id 2735) & (character id 2724) & (character id 2765) & (character id 2728) & " " & (character id 2709) & (character id 2736) & (character id 2763))}
    set labelList to labelList & {((character id 2990) & (character id 2993) & (character id 3009) & (character id 2990) & (character id 3009) & (character id 2991) & (character id 2993) & (character id 3021) & (character id 2970) & (character id 3007))}
    set labelList to labelList & {((character id 3118) & (character id 3123) & (character id 3149) & (character id 3123) & (character id 3136) & " " & (character id 3114) & (character id 3149) & (character id 3120) & (character id 3119) & (character id 3108) & (character id 3149) & (character id 3112) & (character id 3135) & (character id 3074) & (character id 3098) & (character id 3137))}
    set labelList to labelList & {((character id 3246) & (character id 3248) & (character id 3251) & (character id 3263) & " " & (character id 3242) & (character id 3277) & (character id 3248) & (character id 3247) & (character id 3236) & (character id 3277) & (character id 3240) & (character id 3263) & (character id 3256) & (character id 3265))}
    set labelList to labelList & {((character id 3381) & (character id 3392) & (character id 3363) & (character id 3405) & (character id 3359) & (character id 3393) & (character id 3330) & " " & (character id 3382) & (character id 3405) & (character id 3376) & (character id 3374) & (character id 3391) & (character id 3375) & (character id 3405) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3349))}
    set labelList to labelList & {((character id 3505) & (character id 3536) & (character id 3520) & (character id 3501))}
    set labelList to labelList & {((character id 3621) & (character id 3629) & (character id 3591) & (character id 3651) & (character id 3627) & (character id 3617) & (character id 3656))}
    set labelList to labelList & {((character id 3749) & (character id 3757) & (character id 3719) & (character id 3779) & (character id 3755) & (character id 3745) & (character id 3784) & (character id 3757) & (character id 3765) & (character id 3713) & (character id 3716) & (character id 3761) & (character id 3785) & (character id 3719))}
    set labelList to labelList & {((character id 3926) & (character id 3942) & (character id 3984) & (character id 4017) & (character id 3938) & (character id 3851) & (character id 3921) & (character id 3956) & (character id 3851) & (character id 3930) & (character id 3964) & (character id 3921) & (character id 3851) & (character id 3939) & (character id 3999))}
    set labelList to labelList & {((character id 4113) & (character id 4117) & (character id 4154) & (character id 4121) & (character id 4150) & (character id 4102) & (character id 4145) & (character id 4140) & (character id 4100) & (character id 4154) & (character id 4123) & (character id 4157) & (character id 4096) & (character id 4154) & (character id 4096) & (character id 4156) & (character id 4106) & (character id 4151) & (character id 4154) & (character id 4117) & (character id 4139))}
    set labelList to labelList & {((character id 4304) & (character id 4334) & (character id 4314) & (character id 4312) & (character id 4307) & (character id 4304) & (character id 4316))}
    set labelList to labelList & {((character id 6038) & (character id 6098) & (character id 6041) & (character id 6070) & (character id 6041) & (character id 6070) & (character id 6040) & (character id 8203) & (character id 6040) & (character id 6098) & (character id 6031) & (character id 6020) & (character id 8203) & (character id 6033) & (character id 6080) & (character id 6031))}
    set labelList to labelList & {((character id 7275) & (character id 7258) & (character id 7282) & (character id 7263) & " " & (character id 7264) & (character id 7273) & (character id 7272) & (character id 7273) & (character id 7266) & (character id 7273) & (character id 7284) & (character id 7273))}
    set labelList to labelList & {((character id 20877) & (character id 35430) & (character id 34892))}
    set labelList to labelList & {((character id 37325) & (character id 35430))}
    set labelList to labelList & {((character id 37325) & (character id 35797))}
    set labelList to labelList & {((character id 45796) & (character id 49884) & " " & (character id 49884) & (character id 46020))}
    return labelList
end otherRetryLabels

property cachedStateWords : missing value

on statusKindOf(statusText)
    -- "paused", "failed" or "canceled" when a row's status text (its title
    -- after the file name) starts with Firefox's word for that state, in any
    -- language; "" otherwise (downloading, finished...). No word of one kind
    -- starts with a word of another kind, in any language.
    -- A row with a progress bar (downloading, paused) has the bar's value
    -- between the file name and the status: that value is passed over.
    set restText to my withoutLeadingBlanks(statusText as string)
    set restText to my withoutLeadingBlanks(my afterBarValue(restText))
    if restText is "" then return ""
    if my cachedStateWords is missing value then set my cachedStateWords to {{"paused", my pausedWords()}, {"failed", my failedWords()}, {"canceled", my canceledWords()}}
    repeat with kindPair in my cachedStateWords
        repeat with oneWord in (item 2 of kindPair)
            if restText starts with (contents of oneWord) then return (item 1 of kindPair)
        end repeat
    end repeat
    return ""
end statusKindOf

on withoutLeadingBlanks(someText)
    -- The text without the spaces and direction marks (right-to-left
    -- languages) it starts with.
    set restText to someText as string
    repeat while (length of restText) > 0
        if (id of (character 1 of restText)) is in {32, 9, 10, 13, 160, 8194, 8195, 8201, 8206, 8207, 8234, 8235, 8236, 8237, 8238, 8239, 8294, 8295, 8296, 8297} then
            if (length of restText) is 1 then
                set restText to ""
            else
                set restText to text 2 thru -1 of restText
            end if
        else
            exit repeat
        end if
    end repeat
    return restText
end withoutLeadingBlanks

on afterBarValue(statusText)
    -- A progress bar's value as the browser writes it in a row's title:
    -- digits, perhaps a point and more digits, then a percent sign and a
    -- space ("42% Paused", "7.5% Paused"). Returns what follows that value;
    -- the text as it is when it doesn't start with exactly that (so a text
    -- that only looks a bit like it is never cut).
    set textLen to length of statusText
    set digitCount to 0
    set markCount to 0
    set pos to 1
    repeat while pos <= textLen and pos <= 20
        set charId to id of (character pos of statusText)
        if charId is in {48, 49, 50, 51, 52, 53, 54, 55, 56, 57} then
            set digitCount to digitCount + 1
        else if charId is 46 and digitCount > 0 and markCount is 0 then
            set markCount to 1
        else
            exit repeat
        end if
        set pos to pos + 1
    end repeat
    if digitCount is 0 or pos > textLen then return statusText
    if (id of (character pos of statusText)) is not 37 then return statusText
    if (id of (character (pos - 1) of statusText)) is 46 then return statusText
    if pos is textLen then return statusText
    if (id of (character (pos + 1) of statusText)) is not in {32, 9, 160, 8194, 8195, 8201, 8239} then return statusText
    return text (pos + 1) thru -1 of statusText
end afterBarValue

on pausedWords()
    -- Firefox's word for a paused download (statePaused), in every language.
    set labelList to {}
    set labelList to labelList & {"'Na stad", ("Aptur" & (character id 257) & "ta"), ("Aptur" & (character id 275) & "ta")}
    set labelList to labelList & {("Aste" & (character id 603) & "fu"), "Curtha ar Sos", "Dijeda"}
    set labelList to labelList & {("Duraklat" & (character id 305) & "ld" & (character id 305)), "Duyichin' akuan'"}
    set labelList to labelList & {"Ehanet", "En pausa", "En pause", "En posa", "Ena sabbii", "Ga hunanzam", "Gepauzeerd"}
    set labelList to labelList & {"I ndalur", "I-pause", "In pausa", "In pause", ("In p" & (character id 224) & "usa")}
    set labelList to labelList & {("In p" & (character id 246) & "sa"), "Inqumamile"}
    set labelList to labelList & {("Misu " & (character id 8217) & "n pausa"), "mombytapyre", "Ocung woko", "Oedi"}
    set labelList to labelList & {"On haud the noo", "Pausad", "Pausada", "Pausado", "Pausate", "Pausatuta", "Pause"}
    set labelList to labelList & {"Paused", "Pausiert", "Paussa", "Pauza qilingan", "Pauzearre", "Pauzirano"}
    set labelList to labelList & {("Pa" & (character id 365) & "zigita"), "Peatatud", "Pobieranie wstrzymane", "Pozastaveno"}
    set labelList to labelList & {("Pozastaven" & (character id 233)), "Pristabdytas", ("Pus pe pauz" & (character id 259))}
    set labelList to labelList & {("Pys" & (character id 228) & "ytetty"), ("Sat p" & (character id 229) & " pause")}
    set labelList to labelList & {("Saxlan" & (character id 305) & "ld" & (character id 305)), "Spauzowane"}
    set labelList to labelList & {("Sz" & (character id 252) & "netel"), "Taxaw", "Wagtend", "Ye pausau", "Zastajeny"}
    set labelList to labelList & {"Zastajony", "Zaustavljeno", ("Za" & (character id 269) & "asno ustavljeno")}
    set labelList to labelList & {((character id 205) & " bi" & (character id 240))}
    set labelList to labelList & {((character id 272) & (character id 227) & " t" & (character id 7841) & "m d" & (character id 7915) & "ng")}
    set labelList to labelList & {((character id 931) & (character id 949) & " " & (character id 960) & (character id 945) & (character id 973) & (character id 963) & (character id 951))}
    set labelList to labelList & {((character id 1040) & (character id 1103) & (character id 1083) & (character id 1076) & (character id 1072) & (character id 1090) & (character id 1099) & (character id 1083) & (character id 1171) & (character id 1072) & (character id 1085))}
    set labelList to labelList & {((character id 1053) & (character id 1072) & " " & (character id 1087) & (character id 1072) & (character id 1091) & (character id 1079) & (character id 1072))}
    set labelList to labelList & {((character id 1055) & (character id 1072) & (character id 1091) & (character id 1079) & (character id 1080) & (character id 1088) & (character id 1072) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1080) & (character id 1079) & (character id 1091) & (character id 1087) & (character id 1080) & (character id 1085) & (character id 1077) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1080) & (character id 1086) & (character id 1089) & (character id 1090) & (character id 1072) & (character id 1085) & (character id 1086) & (character id 1074) & (character id 1083) & (character id 1077) & (character id 1085) & (character id 1072))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1099) & (character id 1087) & (character id 1099) & (character id 1085) & (character id 1077) & (character id 1085) & (character id 1072))}
    set labelList to labelList & {((character id 1058) & (character id 1072) & (character id 1074) & (character id 1072) & (character id 1179) & (character id 1179) & (character id 1091) & (character id 1092) & " " & (character id 1082) & (character id 1072) & (character id 1088) & (character id 1076) & (character id 1072) & " " & (character id 1096) & (character id 1091) & (character id 1076))}
    set labelList to labelList & {((character id 1332) & (character id 1377) & (character id 1380) & (character id 1377) & (character id 1408))}
    set labelList to labelList & {((character id 1332) & (character id 1377) & (character id 1380) & (character id 1377) & (character id 1408) & (character id 1387) & " " & (character id 1396) & (character id 1381) & (character id 1403))}
    set labelList to labelList & {((character id 1502) & (character id 1493) & (character id 1513) & (character id 1492) & (character id 1492))}
    set labelList to labelList & {((character id 1571) & (character id 1615) & (character id 1604) & (character id 1576) & (character id 1616) & (character id 1579))}
    set labelList to labelList & {((character id 1578) & (character id 1608) & (character id 1602) & (character id 1601) & " " & (character id 1705) & (character id 1585) & (character id 1583) & (character id 1729))}
    set labelList to labelList & {((character id 1585) & (character id 1705) & (character id 1740) & (character id 1575))}
    set labelList to labelList & {((character id 1604) & (character id 1749) & " " & (character id 1608) & (character id 1670) & (character id 1575) & (character id 1606) & (character id 1583) & (character id 1575) & (character id 1740) & (character id 1749))}
    set labelList to labelList & {((character id 1605) & (character id 1705) & (character id 1579))}
    set labelList to labelList & {((character id 1608) & (character id 1575) & (character id 1676) & (character id 1575) & (character id 1588) & (character id 1578) & (character id 1606))}
    set labelList to labelList & {((character id 2341) & (character id 2366) & (character id 2306) & (character id 2348) & (character id 2354) & (character id 2375))}
    set labelList to labelList & {((character id 2341) & (character id 2366) & (character id 2342) & "'" & (character id 2361) & (character id 2379) & (character id 2348) & (character id 2366) & (character id 2351))}
    set labelList to labelList & {((character id 2352) & (character id 2369) & (character id 2325) & (character id 2366) & " " & (character id 2361) & (character id 2369) & (character id 2310) & (character id 8204))}
    set labelList to labelList & {((character id 2352) & (character id 2379) & (character id 2325) & (character id 2367) & (character id 2319) & (character id 2325) & (character id 2379))}
    set labelList to labelList & {((character id 2488) & (character id 2509) & (character id 2469) & (character id 2455) & (character id 2495) & (character id 2468) & " " & (character id 2453) & (character id 2480) & (character id 2494) & " " & (character id 2489) & (character id 2527) & (character id 2503) & (character id 2459) & (character id 2503))}
    set labelList to labelList & {((character id 2613) & (character id 2623) & (character id 2608) & (character id 2622) & (character id 2606) & " " & (character id 2617) & (character id 2632))}
    set labelList to labelList & {((character id 2693) & (character id 2719) & (character id 2709) & (character id 2750) & (character id 2741) & (character id 2759) & (character id 2738))}
    set labelList to labelList & {((character id 2951) & (character id 2975) & (character id 3016) & (character id 2984) & (character id 3007) & (character id 2993) & (character id 3009) & (character id 2980) & (character id 3021) & (character id 2980) & (character id 2986) & (character id 3021) & (character id 2986) & (character id 2975) & (character id 3021) & (character id 2975) & (character id 2980) & (character id 3009))}
    set labelList to labelList & {((character id 3112) & (character id 3135) & (character id 3122) & (character id 3137) & (character id 3114) & (character id 3116) & (character id 3105) & (character id 3135) & (character id 3074) & (character id 3110) & (character id 3135))}
    set labelList to labelList & {((character id 3253) & (character id 3263) & (character id 3248) & (character id 3246) & (character id 3263) & (character id 3256) & (character id 3250) & (character id 3262) & (character id 3223) & (character id 3263) & (character id 3238) & (character id 3270))}
    set labelList to labelList & {((character id 3364) & (character id 3378) & (character id 3405) & (character id 8205) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3390) & (character id 3378) & (character id 3364) & (character id 3405) & (character id 3364) & (character id 3399) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3405) & " " & (character id 3368) & (character id 3391) & (character id 3376) & (character id 3405) & (character id 8205) & (character id 3364) & (character id 3405) & (character id 3364) & (character id 3391) & (character id 3375) & (character id 3391) & (character id 3376) & (character id 3391) & (character id 3375) & (character id 3405) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3368) & (character id 3405) & (character id 3368) & (character id 3393))}
    set labelList to labelList & {((character id 3520) & (character id 3538) & (character id 3515) & (character id 3535) & (character id 3512) & (character id 3514) & (character id 3482) & (character id 3538))}
    set labelList to labelList & {((character id 3627) & (character id 3618) & (character id 3640) & (character id 3604) & (character id 3594) & (character id 3633) & (character id 3656) & (character id 3623) & (character id 3588) & (character id 3619) & (character id 3634) & (character id 3623) & (character id 3629) & (character id 3618) & (character id 3641) & (character id 3656))}
    set labelList to labelList & {((character id 3746) & (character id 3768) & (character id 3732) & (character id 3722) & (character id 3771) & (character id 3784) & (character id 3751) & (character id 3716) & (character id 3762) & (character id 3751))}
    set labelList to labelList & {((character id 3926) & (character id 3904) & (character id 3906) & (character id 3851) & (character id 3930) & (character id 3938))}
    set labelList to labelList & {((character id 4097) & (character id 4145) & (character id 4112) & (character id 4153) & (character id 4112) & (character id 4123) & (character id 4117) & (character id 4154) & (character id 4113) & (character id 4140) & (character id 4152) & (character id 4126) & (character id 4106) & (character id 4154))}
    set labelList to labelList & {((character id 4328) & (character id 4308) & (character id 4329) & (character id 4308) & (character id 4320) & (character id 4308) & (character id 4305) & (character id 4323) & (character id 4314) & (character id 4312))}
    set labelList to labelList & {((character id 6036) & (character id 6070) & (character id 6035) & (character id 8203) & (character id 6037) & (character id 6098) & (character id 6050) & (character id 6070) & (character id 6016))}
    set labelList to labelList & {((character id 7259) & (character id 7268) & (character id 7261) & (character id 7260) & (character id 7273) & " " & (character id 7262) & (character id 7278) & (character id 7281) & (character id 7263))}
    set labelList to labelList & {((character id 20013) & (character id 26029) & (character id 12375) & (character id 12390) & (character id 12356) & (character id 12414) & (character id 12377))}
    set labelList to labelList & {((character id 24050) & (character id 26242) & (character id 20572))}
    set labelList to labelList & {((character id 24050) & (character id 26283) & (character id 20572))}
    set labelList to labelList & {((character id 51068) & (character id 49884) & " " & (character id 51473) & (character id 51648) & (character id 46120))}
    return labelList
end pausedWords

on failedWords()
    -- Firefox's word for a failed download (stateFailed), in every language.
    set labelList to {}
    set labelList to labelList & {("A ka" & (character id 331)), "Ayiphumelelanga"}
    set labelList to labelList & {("Ba" & (character id 351) & "ar" & (character id 305) & "s" & (character id 305) & "z oldu")}
    set labelList to labelList & {("Betg reuss" & (character id 236)), "C'hwitet warni"}
    set labelList to labelList & {("Dh'fh" & (character id 224) & "illig e"), "Didnae wirk"}
    set labelList to labelList & {("D" & (character id 235) & "shtoi"), ("Eba" & (character id 245) & "nnestus")}
    set labelList to labelList & {("Ep" & (character id 228) & "onnistui"), ("E" & (character id 537) & "uat"), "Faddina"}
    set labelList to labelList & {"Failed", "Falhou", "Falio", "Fallido", "Fallite", "Fallou", "Fallutu"}
    set labelList to labelList & {("Fall" & (character id 243)), ("Fal" & (character id 238) & "t"), "Fehlgeschlagen"}
    set labelList to labelList & {("Frac" & (character id 224) & "s"), "Gagal", "Gire'ej", "Ha fallat", "Ha fallau"}
    set labelList to labelList & {"Het misluk", "Huts egin du", "Javypyre", "Lajj na", "Malsukcesa"}
    set labelList to labelList & {("Man " & (character id 252) & "tz ta xub'" & (character id 228) & "n"), "Methiant"}
    set labelList to labelList & {"Mislearre", "Mislukt", "Mislykka", "Mislykket", "Misslyckad"}
    set labelList to labelList & {("Mist" & (character id 243) & "kst"), "Muvaffaqiyatsiz yakunlandi", "Nabigo", "Naizadeve"}
    set labelList to labelList & {("Neizdev" & (character id 257) & "s"), "Nepavyko", ("Neuspe" & (character id 353) & "no")}
    set labelList to labelList & {("Neuspje" & (character id 353) & "no")}
    set labelList to labelList & {("Ne" & (character id 250) & "spe" & (character id 353) & "n" & (character id 233))}
    set labelList to labelList & {"Nije uspjelo", ("Niy podarzi" & (character id 322) & "o sie")}
    set labelList to labelList & {("Njeporad" & (character id 378) & "i" & (character id 322) & "o")}
    set labelList to labelList & {("Njera" & (character id 378) & "ony"), "Non riuscito", "Opoto"}
    set labelList to labelList & {("Pobranie si" & (character id 281) & " nie powiod" & (character id 322) & "o"), "Selhalo"}
    set labelList to labelList & {"Sikertelen", "Teipthe", ("Th" & (character id 7845) & "t b" & (character id 7841) & "i")}
    set labelList to labelList & {"Ur yeddi ara", ("U" & (character id 287) & "ursuz oldu"), "Woorii"}
    set labelList to labelList & {((character id 201) & "chec")}
    set labelList to labelList & {((character id 913) & (character id 960) & (character id 941) & (character id 964) & (character id 965) & (character id 967) & (character id 949))}
    set labelList to labelList & {((character id 1048) & (character id 1207) & (character id 1088) & (character id 1086) & " " & (character id 1085) & (character id 1072) & (character id 1096) & (character id 1091) & (character id 1076))}
    set labelList to labelList & {((character id 1053) & (character id 1077) & " " & (character id 1091) & (character id 1076) & (character id 1072) & (character id 1083) & (character id 1072) & (character id 1089) & (character id 1100))}
    set labelList to labelList & {((character id 1053) & (character id 1077) & (character id 1074) & (character id 1076) & (character id 1072) & (character id 1095) & (character id 1072))}
    set labelList to labelList & {((character id 1053) & (character id 1077) & (character id 1091) & (character id 1089) & (character id 1087) & (character id 1077) & (character id 1083) & (character id 1086))}
    set labelList to labelList & {((character id 1053) & (character id 1077) & (character id 1091) & (character id 1089) & (character id 1087) & (character id 1077) & (character id 1096) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1053) & (character id 1103) & (character id 1118) & (character id 1076) & (character id 1072) & (character id 1095) & (character id 1072))}
    set labelList to labelList & {((character id 1178) & (character id 1072) & (character id 1090) & (character id 1077))}
    set labelList to labelList & {((character id 1345) & (character id 1377) & (character id 1389) & (character id 1400) & (character id 1394) & (character id 1400) & (character id 1410) & (character id 1396))}
    set labelList to labelList & {((character id 1353) & (character id 1387) & " " & (character id 1397) & (character id 1377) & (character id 1403) & (character id 1400) & (character id 1394) & (character id 1400) & (character id 1410) & (character id 1381) & (character id 1388))}
    set labelList to labelList & {((character id 1499) & (character id 1513) & (character id 1500) & (character id 1493) & (character id 1503))}
    set labelList to labelList & {((character id 1587) & (character id 1749) & (character id 1585) & (character id 1705) & (character id 1749) & (character id 1608) & (character id 1578) & (character id 1608) & (character id 1608) & " " & (character id 1606) & (character id 1749) & (character id 1576) & (character id 1608) & (character id 1608))}
    set labelList to labelList & {((character id 1588) & (character id 1705) & (character id 1587) & (character id 1578) & " " & (character id 1582) & (character id 1585) & (character id 1583))}
    set labelList to labelList & {((character id 1588) & (character id 1705) & (character id 1587) & (character id 1578) & " " & (character id 1582) & (character id 1608) & (character id 1585) & (character id 1583))}
    set labelList to labelList & {((character id 1601) & (character id 1588) & (character id 1604))}
    set labelList to labelList & {((character id 1606) & (character id 1575) & (character id 1705) & (character id 1575) & (character id 1605))}
    set labelList to labelList & {((character id 2309) & (character id 2346) & (character id 2351) & (character id 2358) & (character id 2368))}
    set labelList to labelList & {((character id 2309) & (character id 2360) & (character id 2347) & (character id 2354) & " " & (character id 2349) & (character id 2351) & (character id 2379))}
    set labelList to labelList & {((character id 2347) & (character id 2375) & (character id 2354) & (character id 2375) & (character id 2306) & " " & (character id 2332) & (character id 2366) & (character id 2348) & (character id 2366) & (character id 2351))}
    set labelList to labelList & {((character id 2357) & (character id 2367) & (character id 2347) & (character id 2354) & (character id 8204))}
    set labelList to labelList & {((character id 2476) & (character id 2509) & (character id 2479) & (character id 2480) & (character id 2509) & (character id 2469))}
    set labelList to labelList & {((character id 2603) & (character id 2631) & (character id 2610) & (character id 2637) & (character id 2617) & " " & (character id 2617) & (character id 2632))}
    set labelList to labelList & {((character id 2728) & (character id 2751) & (character id 2743) & (character id 2765) & (character id 2731) & (character id 2739))}
    set labelList to labelList & {((character id 2980) & (character id 3019) & (character id 2994) & (character id 3021) & (character id 2997) & (character id 3007) & (character id 2991) & (character id 3009) & (character id 2993) & (character id 3021) & (character id 2993) & (character id 2980) & (character id 3009))}
    set labelList to labelList & {((character id 3125) & (character id 3135) & (character id 3115) & (character id 3122) & (character id 3118) & (character id 3144) & (character id 3074) & (character id 3110) & (character id 3135))}
    set labelList to labelList & {((character id 3253) & (character id 3263) & (character id 3243) & (character id 3250) & (character id 3223) & (character id 3274) & (character id 3202) & (character id 3233) & (character id 3263) & (character id 3238) & (character id 3270))}
    set labelList to labelList & {((character id 3370) & (character id 3376) & (character id 3390) & (character id 3356) & (character id 3375) & (character id 3370) & (character id 3405) & (character id 3370) & (character id 3398) & (character id 3359) & (character id 3405) & (character id 3359) & (character id 3393))}
    set labelList to labelList & {((character id 3461) & (character id 3523) & (character id 3512) & (character id 3501) & (character id 3530) & " " & (character id 3520) & (character id 3538) & (character id 3514))}
    set labelList to labelList & {((character id 3621) & (character id 3657) & (character id 3617) & (character id 3648) & (character id 3627) & (character id 3621) & (character id 3623))}
    set labelList to labelList & {((character id 3749) & (character id 3771) & (character id 3785) & (character id 3745) & (character id 3776) & (character id 3755) & (character id 3749) & (character id 3751))}
    set labelList to labelList & {((character id 3939) & (character id 3962) & (character id 3923) & (character id 3851) & (character id 3928) & (character id 3851) & (character id 3920) & (character id 3956) & (character id 3926) & (character id 3851) & (character id 3924))}
    set labelList to labelList & {((character id 4121) & (character id 4129) & (character id 4145) & (character id 4140) & (character id 4100) & (character id 4154) & (character id 4121) & (character id 4156) & (character id 4100) & (character id 4154) & (character id 4117) & (character id 4139))}
    set labelList to labelList & {((character id 4329) & (character id 4304) & (character id 4328) & (character id 4314) & (character id 4312) & (character id 4314) & (character id 4312))}
    set labelList to labelList & {((character id 6036) & (character id 6070) & (character id 6035) & (character id 8203) & (character id 6036) & (character id 6042) & (character id 6070) & (character id 6023) & (character id 6096) & (character id 6041))}
    set labelList to labelList & {((character id 7280) & (character id 7268) & (character id 7260) & (character id 7263) & (character id 7289) & (character id 7267) & (character id 7278) & (character id 7281) & (character id 7263))}
    set labelList to labelList & {((character id 22833) & (character id 25943))}
    set labelList to labelList & {((character id 22833) & (character id 25943) & (character id 12375) & (character id 12414) & (character id 12375) & (character id 12383))}
    set labelList to labelList & {((character id 22833) & (character id 36133))}
    set labelList to labelList & {((character id 49892) & (character id 54056) & (character id 54632))}
    return labelList
end failedWords

on canceledWords()
    -- Firefox's word for a canceled download (stateCanceled), in every language.
    set labelList to {}
    set labelList to labelList & {("A na" & (character id 331) & "andi"), "Abgebrochen", "Air a sgur dheth", "Annulearre"}
    set labelList to labelList & {"Annulladu", "Annullato", "Annulleret", ("Annul" & (character id 233)), "Anulat"}
    set labelList to labelList & {"Anullat", ("Anul" & (character id 226) & "t"), "Atcalta", "Atcelta", "Atsisakyta"}
    set labelList to labelList & {"Avbrote", "Avbruten", "Avbrutt", "Bekor qilingan", "Cancelada", "Cancelado", "Canceled"}
    set labelList to labelList & {"Cancellate", "Cancelled", "Cealaithe", "Dibatalkan", "Diddymwyd"}
    set labelList to labelList & {("Encabox" & (character id 243) & "se"), "Geannuleerd", "Gekanselleer", "Haaytinaama"}
    set labelList to labelList & {"Hejapyre", ("H" & (character id 230) & "tt vi" & (character id 240)), "Ifsex", "Interrut"}
    set labelList to labelList & {"Irhoxisiwe", ((character id 304) & "ptal edildi"), "Katkestatud", "Kijuko woko"}
    set labelList to labelList & {"Kinansela", ("L" & (character id 601) & (character id 287) & "v Edildi")}
    set labelList to labelList & {("Megszak" & (character id 237) & "tva"), "Neenalu na", "Nga dure'", "Ntu nkuvi-ka"}
    set labelList to labelList & {"Nuligita", "Nullet", "Obustavljeno", "Peruutettu", "Pobieranie anulowane", "Pociepane"}
    set labelList to labelList & {"Prekinuto", "Preklicano", ("P" & (character id 345) & "etorhnjeny")}
    set labelList to labelList & {("P" & (character id 347) & "etergnjony"), "S'ha cancelau"}
    set labelList to labelList & {("S'ha cancel" & (character id 183) & "lat"), "Scancelou", "Sfallutu", "Stappit"}
    set labelList to labelList & {"U anulua", "Utzita", ("Zru" & (character id 353) & "eno")}
    set labelList to labelList & {("Zru" & (character id 353) & "en" & (character id 233))}
    set labelList to labelList & {((character id 272) & (character id 227) & " h" & (character id 7911) & "y")}
    set labelList to labelList & {((character id 913) & (character id 954) & (character id 965) & (character id 961) & (character id 974) & (character id 952) & (character id 951) & (character id 954) & (character id 949))}
    set labelList to labelList & {((character id 1041) & (character id 1077) & (character id 1082) & (character id 1086) & (character id 1088) & " " & (character id 1082) & (character id 1072) & (character id 1088) & (character id 1076) & (character id 1072) & " " & (character id 1096) & (character id 1091) & (character id 1076))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1082) & (character id 1072) & (character id 1078) & (character id 1072) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1082) & (character id 1072) & (character id 1079) & (character id 1072) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1084) & (character id 1077) & (character id 1085) & (character id 1077) & (character id 1085) & (character id 1072))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1077) & (character id 1082) & (character id 1098) & (character id 1089) & (character id 1085) & (character id 1072) & (character id 1090) & (character id 1086))}
    set labelList to labelList & {((character id 1057) & (character id 1082) & (character id 1072) & (character id 1089) & (character id 1072) & (character id 1074) & (character id 1072) & (character id 1085) & (character id 1072))}
    set labelList to labelList & {((character id 1057) & (character id 1082) & (character id 1072) & (character id 1089) & (character id 1086) & (character id 1074) & (character id 1072) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1058) & (character id 1086) & (character id 1179) & (character id 1090) & (character id 1072) & (character id 1090) & (character id 1099) & (character id 1083) & (character id 1076) & (character id 1099))}
    set labelList to labelList & {((character id 1353) & (character id 1381) & (character id 1394) & (character id 1377) & (character id 1408) & (character id 1391) & (character id 1377) & (character id 1390))}
    set labelList to labelList & {((character id 1353) & (character id 1381) & (character id 1394) & (character id 1377) & (character id 1408) & (character id 1391) & (character id 1406) & (character id 1377) & (character id 1390))}
    set labelList to labelList & {((character id 1489) & (character id 1493) & (character id 1496) & (character id 1500))}
    set labelList to labelList & {((character id 1571) & (character id 1615) & (character id 1604) & (character id 1594) & (character id 1616) & (character id 1610) & (character id 1614))}
    set labelList to labelList & {((character id 1604) & (character id 1594) & (character id 1608) & " " & (character id 1588) & (character id 1583) & (character id 1607))}
    set labelList to labelList & {((character id 1604) & (character id 1602) & (character id 1608) & " " & (character id 1608) & (character id 1575) & (character id 1576) & (character id 1740) & (character id 1676) & (character id 1607))}
    set labelList to labelList & {((character id 1605) & (character id 1606) & (character id 1587) & (character id 1608) & (character id 1582) & " " & (character id 1578) & (character id 1726) & (character id 1740) & (character id 1575))}
    set labelList to labelList & {((character id 1605) & (character id 1606) & (character id 1587) & (character id 1608) & (character id 1582) & " " & (character id 1588) & (character id 1583) & (character id 1729))}
    set labelList to labelList & {((character id 1607) & (character id 1749) & (character id 1717) & (character id 1608) & (character id 1749) & (character id 1588) & (character id 1742) & (character id 1606) & (character id 1585) & (character id 1575) & (character id 1740) & (character id 1749) & (character id 1608) & (character id 1749))}
    set labelList to labelList & {((character id 2348) & (character id 2366) & (character id 2340) & (character id 2367) & (character id 2354) & " " & (character id 2326) & (character id 2366) & (character id 2354) & (character id 2366) & (character id 2350) & (character id 2348) & (character id 2366) & (character id 2351))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2325) & (character id 2375) & (character id 2354) & (character id 2375))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2327) & (character id 2352) & (character id 2367) & (character id 2351) & (character id 2379))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & (character id 8204))}
    set labelList to labelList & {((character id 2476) & (character id 2494) & (character id 2468) & (character id 2495) & (character id 2482) & " " & (character id 2453) & (character id 2480) & (character id 2494) & " " & (character id 2489) & (character id 2527) & (character id 2503) & (character id 2459) & (character id 2503))}
    set labelList to labelList & {((character id 2608) & (character id 2673) & (character id 2598) & " " & (character id 2581) & (character id 2624) & (character id 2596) & (character id 2622))}
    set labelList to labelList & {((character id 2736) & (character id 2726) & " " & (character id 2725) & (character id 2735) & (character id 2759) & (character id 2738) & " " & (character id 2715) & (character id 2759))}
    set labelList to labelList & {((character id 2992) & (character id 2980) & (character id 3021) & (character id 2980) & (character id 3009) & " " & (character id 2970) & (character id 3014) & (character id 2991) & (character id 3021) & (character id 2991) & (character id 2986) & (character id 3021) & (character id 2986) & (character id 2975) & (character id 3021) & (character id 2975) & (character id 2980) & (character id 3009))}
    set labelList to labelList & {((character id 3120) & (character id 3110) & (character id 3149) & (character id 3110) & (character id 3137) & " " & (character id 3098) & (character id 3143) & (character id 3119) & (character id 3116) & (character id 3105) & (character id 3135) & (character id 3112) & (character id 3110) & (character id 3135))}
    set labelList to labelList & {((character id 3248) & (character id 3238) & (character id 3277) & (character id 3238) & (character id 3265) & (character id 3223) & (character id 3274) & (character id 3251) & (character id 3263) & (character id 3256) & (character id 3250) & (character id 3262) & (character id 3223) & (character id 3263) & (character id 3238) & (character id 3270))}
    set labelList to labelList & {((character id 3377) & (character id 3366) & (character id 3405) & (character id 3366) & (character id 3390) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3391) & (character id 3375) & (character id 3391) & (character id 3376) & (character id 3391) & (character id 3375) & (character id 3405) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3368) & (character id 3405) & (character id 3368) & (character id 3393))}
    set labelList to labelList & {((character id 3461) & (character id 3520) & (character id 3517) & (character id 3458) & (character id 3484) & (character id 3540) & " " & (character id 3482) & (character id 3545) & (character id 3515) & (character id 3538) & (character id 3499) & (character id 3538))}
    set labelList to labelList & {((character id 3618) & (character id 3585) & (character id 3648) & (character id 3621) & (character id 3636) & (character id 3585) & (character id 3649) & (character id 3621) & (character id 3657) & (character id 3623))}
    set labelList to labelList & {((character id 3725) & (character id 3771) & (character id 3713) & (character id 3776) & (character id 3749) & (character id 3765) & (character id 3713) & (character id 3777) & (character id 3749) & (character id 3785) & (character id 3751))}
    set labelList to labelList & {((character id 3925) & (character id 4017) & (character id 3954) & (character id 3938) & (character id 3851) & (character id 3936) & (character id 3920) & (character id 3962) & (character id 3923) & (character id 3851) & (character id 3926) & (character id 4017) & (character id 3942) & (character id 3851) & (character id 3935) & (character id 3954) & (character id 3923))}
    set labelList to labelList & {((character id 4118) & (character id 4155) & (character id 4096) & (character id 4154) & (character id 4126) & (character id 4141) & (character id 4121) & (character id 4154) & (character id 4152) & (character id 4113) & (character id 4140) & (character id 4152) & (character id 4126) & (character id 4106) & (character id 4154))}
    set labelList to labelList & {((character id 4306) & (character id 4304) & (character id 4323) & (character id 4325) & (character id 4315) & (character id 4308) & (character id 4305) & (character id 4323) & (character id 4314) & (character id 4312))}
    set labelList to labelList & {((character id 6036) & (character id 6070) & (character id 6035) & (character id 8203) & (character id 6036) & (character id 6084) & (character id 6087) & (character id 6036) & (character id 6020) & (character id 6091))}
    set labelList to labelList & {((character id 7285) & (character id 7263) & (character id 7289) & (character id 7280) & (character id 7272) & (character id 7263) & (character id 7289) & " " & (character id 7278) & (character id 7281) & (character id 7263))}
    set labelList to labelList & {((character id 12461) & (character id 12515) & (character id 12531) & (character id 12475) & (character id 12523) & (character id 12373) & (character id 12428) & (character id 12414) & (character id 12375) & (character id 12383))}
    set labelList to labelList & {((character id 24050) & (character id 21462) & (character id 28040))}
    set labelList to labelList & {((character id 52712) & (character id 49548) & (character id 46120))}
    return labelList
end canceledWords

-- ------------------------------------------------------------- shared: which row

on nameEnd(rowTitle, nameVariants)
    -- Length of the file name this row title starts with, or 0. A title
    -- reads "<file name> <status> <button label>", so the name must be
    -- there character for character (see sameText) and be followed by a
    -- space (or end the title): a row for "report.pdf.zip" is not a row for
    -- "report.pdf".
    set titleLen to length of rowTitle
    repeat with v in nameVariants
        set oneName to (contents of v) as string
        set nameLen to length of oneName
        if nameLen > 0 and not (titleLen < nameLen) then
            set samePrefix to my sameText(text 1 thru nameLen of rowTitle, oneName)
            if samePrefix then
                if titleLen is nameLen then return nameLen
                if (id of (character (nameLen + 1) of rowTitle)) is in {32, 9, 10, 13, 160, 8194, 8195, 8201, 8239} then return nameLen
            end if
        end if
    end repeat
    return 0
end nameEnd

on rowIsForName(rowTitle, nameVariants)
    return (my nameEnd(rowTitle, nameVariants)) > 0
end rowIsForName

-- ------------------------------------------------------------- shared: a name the panel shows shortened

-- Where the whole name was found on the row namesForRow last looked at:
-- {child} or {child, grandchild} of the row; {} when its title has the full
-- name (nothing more to read).
property wholeNameSpot : {}
-- ...and the file's own names it was compared with.
property wholeNameList : {}
-- A note for the log when a row looked like this name shortened but its
-- whole name wasn't found ("" otherwise).
property shortNote : ""

on sameText(textA, textB)
    -- The same characters, one for one. (AppleScript's own "is" takes some
    -- different texts for equal: it skips invisible characters, and sees a
    -- fullwidth letter as the plain one.)
    if (length of textA) is not (length of textB) then return false
    if (length of textA) is 0 then return true
    return (id of textA) is (id of textB)
end sameText

on shortenedEnd(rowTitle, wholeName)
    -- The panel shortens a long file name in the middle: the beginning of
    -- the name, one ellipsis character, the end of the name. Returns where
    -- such a shortened name ends in the title, or 0: the title must start
    -- with the beginning of wholeName (the same characters), then the
    -- ellipsis, then the end of wholeName, followed by a space (or by
    -- nothing).
    set titleLen to length of rowTitle
    set nameLen to length of wholeName
    set cutPos to offset of (character id 8230) in rowTitle
    if cutPos < 2 then return 0
    set headLen to cutPos - 1
    if not (headLen < nameLen) then return 0
    if not (my sameText(text 1 thru headLen of rowTitle, text 1 thru headLen of wholeName)) then return 0
    set tailMax to nameLen - headLen - 1
    if tailMax > (titleLen - cutPos) then set tailMax to (titleLen - cutPos)
    repeat with tailLen from tailMax to 1 by -1
        set lastPos to cutPos + tailLen
        if my sameText(text (cutPos + 1) thru lastPos of rowTitle, text (nameLen - tailLen + 1) thru nameLen of wholeName) then
            if lastPos is titleLen then return lastPos
            if (id of (character (lastPos + 1) of rowTitle)) is in {32, 9, 10, 13, 160, 8194, 8195, 8201, 8239} then return lastPos
        end if
    end repeat
    return 0
end shortenedEnd

on helpsOf(listRef, rowIdx, childIdx)
    -- The help texts (the tooltips) of a row's elements (childIdx 0), or of
    -- the elements inside its childIdx-th element, in order, as texts ("" for
    -- an element without one). One request, or one per element if that
    -- fails. Only read, nothing is pressed.
    set rawList to missing value
    set elemCount to 0
    tell application "System Events"
        try
            if childIdx is 0 then
                set elemCount to count of UI elements of UI element rowIdx of listRef
                if elemCount > 0 then set rawList to value of attribute "AXHelp" of every UI element of UI element rowIdx of listRef
            else
                set elemCount to count of UI elements of UI element childIdx of UI element rowIdx of listRef
                if elemCount > 0 then set rawList to value of attribute "AXHelp" of every UI element of UI element childIdx of UI element rowIdx of listRef
            end if
        end try
    end tell
    if rawList is not missing value then
        if (class of rawList) is not list then set rawList to {rawList}
        if (count of rawList) is not elemCount then set rawList to missing value
    end if
    set cleanList to {}
    repeat with elemIdx from 1 to elemCount
        set oneText to ""
        if rawList is missing value then
            if childIdx is 0 then
                set oneText to my helpTextAt(listRef, rowIdx, {elemIdx})
            else
                set oneText to my helpTextAt(listRef, rowIdx, {childIdx, elemIdx})
            end if
        else
            try
                set rawHelp to item elemIdx of rawList
                if rawHelp is not missing value then set oneText to rawHelp as string
            end try
        end if
        set end of cleanList to oneText
    end repeat
    return cleanList
end helpsOf

on helpTextAt(listRef, rowIdx, spot)
    -- The help text of one element of a row: its spot-th element ({child}),
    -- or an element inside that one ({child, grandchild}). "" when it has
    -- none. One request. Only read.
    set oneText to ""
    tell application "System Events"
        try
            if (count of spot) is 1 then
                set rawHelp to value of attribute "AXHelp" of UI element (item 1 of spot) of UI element rowIdx of listRef
            else
                set rawHelp to value of attribute "AXHelp" of UI element (item 2 of spot) of UI element (item 1 of spot) of UI element rowIdx of listRef
            end if
            if rawHelp is not missing value then set oneText to rawHelp as string
        end try
    end tell
    return oneText
end helpTextAt

on rowHelpTexts(listRef, rowIdx)
    -- {help texts, where each is}: every help text on a row's elements and
    -- on the elements inside those (the name label may sit one level down),
    -- with its spot (see helpTextAt). Only read.
    set foundTexts to {}
    set foundSpots to {}
    set childHelps to my helpsOf(listRef, rowIdx, 0)
    repeat with i from 1 to (count of childHelps)
        if (item i of childHelps) is not "" then
            set end of foundTexts to (item i of childHelps)
            set end of foundSpots to {i}
        end if
    end repeat
    repeat with i from 1 to (count of childHelps)
        set innerHelps to my helpsOf(listRef, rowIdx, i)
        repeat with j from 1 to (count of innerHelps)
            if (item j of innerHelps) is not "" then
                set end of foundTexts to (item j of innerHelps)
                set end of foundSpots to {i, j}
            end if
        end repeat
    end repeat
    return {foundTexts, foundSpots}
end rowHelpTexts

on shortNameFor(listRef, rowIdx, rowTitle, nameVariants)
    -- "" unless the row shows this file's name shortened. A name too long
    -- for the panel is shown shortened in the middle, and the row's title
    -- then has the shortened name; the whole name stays on the row's name
    -- label, as its help text (its tooltip). The row is this file's only
    -- when the title starts with the two ends of this file's name (see
    -- shortenedEnd) AND that whole name is exactly this file's, character
    -- for character. Returns the shortened name as the title has it, and
    -- remembers where the whole name was (wholeNameSpot).
    if rowTitle does not contain (character id 8230) then return ""
    set couldBe to false
    repeat with v in nameVariants
        if (my shortenedEnd(rowTitle, (contents of v) as string)) > 0 then set couldBe to true
    end repeat
    if not couldBe then return ""
    set helps to my rowHelpTexts(listRef, rowIdx)
    set helpTexts to item 1 of helps
    set helpSpots to item 2 of helps
    repeat with h from 1 to (count of helpTexts)
        set wholeName to item h of helpTexts
        repeat with v in nameVariants
            set oneName to (contents of v) as string
            if my sameText(wholeName, oneName) then
                set endPos to my shortenedEnd(rowTitle, oneName)
                if endPos > 0 then
                    set my wholeNameSpot to item h of helpSpots
                    return (text 1 thru endPos of rowTitle)
                end if
            end if
        end repeat
    end repeat
    set my shortNote to "row " & rowIdx & " looks like this name shortened, but its whole name isn't on it (help texts read: " & (count of helpTexts) & "); "
    return ""
end shortNameFor

on namesForRow(listRef, rowIdx, rowTitle, fileNames)
    -- What this row's title may start with: this file's name -- and, when
    -- the title has it shortened, that shortened name too, but only after
    -- the whole name on the row's name label was read, now, and is exactly
    -- this file's (see shortNameFor). A title that starts with the full
    -- name needs no extra read.
    set my wholeNameSpot to {}
    set my wholeNameList to fileNames
    set my shortNote to ""
    if my rowIsForName(rowTitle, fileNames) then return fileNames
    set shortName to my shortNameFor(listRef, rowIdx, rowTitle, fileNames)
    if shortName is "" then return fileNames
    return fileNames & {shortName}
end namesForRow

on wholeNameStill(listRef, rowIdx, nameList)
    -- For the row namesForRow just matched by its whole name: that name,
    -- read once more from the same label, must still be this file's,
    -- character for character. (True at once for a row whose title has the
    -- full name: there's nothing more to read.) Called last before a press
    -- or a menu, so that two files that look the same shortened can't be
    -- taken for one another when rows shift.
    if (count of (my wholeNameSpot)) is 0 then return true
    set wholeName to my helpTextAt(listRef, rowIdx, my wholeNameSpot)
    if wholeName is "" then return false
    repeat with v in nameList
        if my sameText(wholeName, (contents of v) as string) then return true
    end repeat
    return false
end wholeNameStill

on rowKind(rowTitle, nameVariants)
    -- "paused", "failed", "canceled" or "": the state the row shows right
    -- after the file name (Firefox's own word for it, in any language).
    set nameLen to my nameEnd(rowTitle, nameVariants)
    if nameLen is 0 then return ""
    if (length of rowTitle) < (nameLen + 2) then return ""
    return my statusKindOf(text (nameLen + 2) thru -1 of rowTitle)
end rowKind

on statusShape(rowTitle, nameVariants)
    -- For the log, when a row's state isn't recognised: how its status text
    -- (the title after the file name) begins, with every digit written 9
    -- and every letter a, so that neither a name nor a site shows
    -- ("99% aaaaaa - 9.9 aa"). "" when there's nothing to tell. Only read.
    set shapeText to ""
    try
        set nameLen to my nameEnd(rowTitle, nameVariants)
        if nameLen is 0 or (length of rowTitle) < (nameLen + 2) then return ""
        set statusText to text (nameLen + 2) thru -1 of rowTitle
        set lastPos to length of statusText
        if lastPos > 20 then set lastPos to 20
        repeat with pos from 1 to lastPos
            set charId to id of (character pos of statusText)
            if charId is in {48, 49, 50, 51, 52, 53, 54, 55, 56, 57} then
                set shapeText to shapeText & "9"
            else if charId is in {32, 160, 8194, 8195, 8201, 8239} then
                set shapeText to shapeText & " "
            else if charId is in {37, 44, 46, 58, 40, 41, 47} then
                set shapeText to shapeText & (character id charId)
            else if charId is in {45, 8211, 8212} then
                set shapeText to shapeText & "-"
            else
                set shapeText to shapeText & "a"
            end if
        end repeat
    on error
        return ""
    end try
    return shapeText
end statusShape

on wantsButton(actionMode, btnLabel)
    -- The row button an action goes by: Retry for retry and restart, Cancel
    -- otherwise. Downloading and paused rows have a Cancel button; a paused
    -- row's Resume is in its right-click menu, not on a button.
    if actionMode is "retry" or actionMode is "restart" then return my looksLikeRetry(btnLabel)
    return my looksLikeCancel(btnLabel)
end wantsButton

on pickRow(nameRows, candKinds, actionMode)
    -- Which candidate to act on: {"pick", n}, or {outcome, 0} when none.
    -- Candidates are the rows for this file that have the button the action
    -- goes by. Stop needs exactly one. Retry, Resume and restart take the
    -- one row showing the state they need (Failed; Paused; Canceled, or
    -- Failed when the browser deleted what it had). If Firefox's word for
    -- the state isn't recognised, a single candidate is used and the browser
    -- has the last word: only a failed or canceled row has a Retry button,
    -- and only a paused row has a Resume item in its menu.
    set candCount to count of candKinds
    if actionMode is "cancel" then
        if candCount is 1 then return {"pick", 1}
        if candCount > 1 then return {"ambiguous", 0}
    else
        set wantKinds to {"paused"}
        if actionMode is "retry" then set wantKinds to {"failed"}
        if actionMode is "restart" then set wantKinds to {"canceled", "failed"}
        set preferred to {}
        set unknownRows to {}
        repeat with i from 1 to candCount
            set oneKind to item i of candKinds
            if oneKind is not "" and wantKinds contains oneKind then set end of preferred to i
            if oneKind is "" then set end of unknownRows to i
        end repeat
        if (count of preferred) is 1 then return {"pick", item 1 of preferred}
        if (count of preferred) > 1 then return {"ambiguous", 0}
        if candCount is 1 and (count of unknownRows) is 1 then return {"pick", 1}
        if (count of unknownRows) > 1 then return {"ambiguous", 0}
    end if
    if nameRows > 0 then return {"not-active", 0}
    return {"no-match", 0}
end pickRow

on joinedTexts(textList)
    set joined to ""
    repeat with oneText in textList
        if joined is not "" then set joined to joined & ","
        set joined to joined & (contents of oneText)
    end repeat
    return joined
end joinedTexts

-- ------------------------------------------------------------- shared: Resume, from a row's right-click menu

-- The browser's process id, read before a row's menu is shown (reset at the
-- start of every run): the plugin needs it to find that menu.
property shownPid : ""

on rowFrame(listRef, rowIdx)
    -- "x,y,w,h": where the row is on screen, in points, or "" when its
    -- middle (where the browser clicks to open its menu) isn't inside the
    -- visible list (a click there could land outside the panel, in the
    -- page) or isn't inside the browser window (the browser sends that
    -- click to its window, and outside it no menu would open).
    set rowPos to missing value
    set rowDims to missing value
    set listPos to missing value
    set listDims to missing value
    tell application "System Events"
        try
            set rowPos to position of UI element rowIdx of listRef
            set rowDims to size of UI element rowIdx of listRef
            set listPos to position of listRef
            set listDims to size of listRef
        end try
    end tell
    if rowPos is missing value or rowDims is missing value or listPos is missing value or listDims is missing value then return ""
    try
        set rowX to (item 1 of rowPos) div 1
        set rowY to (item 2 of rowPos) div 1
        set rowW to (item 1 of rowDims) div 1
        set rowH to (item 2 of rowDims) div 1
        if rowW < 4 or rowH < 4 then return ""
        set midX to rowX + (rowW div 2)
        set midY to rowY + (rowH div 2)
        if midX < ((item 1 of listPos) + 2) or midY < ((item 2 of listPos) + 2) then return ""
        if midX > ((item 1 of listPos) + (item 1 of listDims) - 2) then return ""
        if midY > ((item 2 of listPos) + (item 2 of listDims) - 2) then return ""
        if not (my insideWindow(listRef, midX, midY)) then return ""
        return (rowX as string) & "," & (rowY as string) & "," & (rowW as string) & "," & (rowH as string)
    end try
    return ""
end rowFrame

on insideWindow(listRef, midX, midY)
    -- False only when the window the list belongs to can be read and the
    -- point is outside it.
    set winPos to missing value
    set winDims to missing value
    tell application "System Events"
        try
            set winEl to value of attribute "AXWindow" of listRef
            set winPos to position of winEl
            set winDims to size of winEl
        end try
    end tell
    if winPos is missing value or winDims is missing value then return true
    try
        if midX < ((item 1 of winPos) + 1) or midY < ((item 2 of winPos) + 1) then return false
        if midX > ((item 1 of winPos) + (item 1 of winDims) - 1) then return false
        if midY > ((item 2 of winPos) + (item 2 of winDims) - 1) then return false
    end try
    return true
end insideWindow

on notePid(procName)
    -- Read the browser's process id before its menu is shown (the plugin
    -- finds the menu by it). False if it can't be read: then no menu.
    set my shownPid to my pidText(procName)
    return (my shownPid) is not ""
end notePid

on showRowMenu(listRef, rowIdx, nameVariants, scanKind, frameText)
    -- Show the row's right-click menu, then make sure it is this row's: the
    -- browser selects the row it opens a menu for, and that row must still
    -- be this file's, in the same state. Choosing Resume in the menu is the
    -- plugin's job: it finds the menu where it opened (System Events can't
    -- be relied on to reach it), checks it and closes
    -- it untouched unless everything matches. Returns {outcome, trace, row
    -- frame}: "menu-shown", "menu-changed" or "show-error" (for these two the
    -- plugin only closes the menu, if there is one). notePid comes first.
    -- In case this run is cut short, where the menu opens goes to the log
    -- (stderr) first, so the plugin can still close it.
    log "menu-at|" & frameText & "|" & (my shownPid)
    set shownOk to false
    tell application "System Events"
        try
            perform action "AXShowMenu" of UI element rowIdx of listRef
            set shownOk to true
        end try
    end tell
    if not shownOk then return {"show-error", "showing the row's menu reported an error; ", frameText}
    set rowSelected to missing value
    set nowTitle to ""
    set readNote to ""
    tell application "System Events"
        try
            set rowSelected to value of attribute "AXSelected" of UI element rowIdx of listRef
        end try
        try
            set rawTitle to value of attribute "AXTitle" of UI element rowIdx of listRef
            if rawTitle is not missing value then set nowTitle to rawTitle as string
        end try
    end tell
    -- (A read that fails proves nothing either way: the row was checked
    -- just before, and the plugin checks the menu itself.)
    if rowSelected is false then return {"menu-changed", "the menu opened for another row; ", frameText}
    if nowTitle is not "" then
        if not (my rowIsForName(nowTitle, nameVariants)) then return {"menu-changed", "the row moved; ", frameText}
        if scanKind is not "" then
            set nowKind to my rowKind(nowTitle, nameVariants)
            if nowKind is "" then
                -- No state word in the title. The pointer came onto the row
                -- when its menu opened, and the browser then swaps the row's
                -- status label for another: the title may have been read
                -- between the two. It is read once more, a moment later;
                -- the row must still be the selected one, this file's, and
                -- show its state then. (The log says when this happened.)
                delay 0.1
                set laterSelected to missing value
                set laterTitle to ""
                tell application "System Events"
                    try
                        set laterSelected to value of attribute "AXSelected" of UI element rowIdx of listRef
                    end try
                    try
                        set rawLater to value of attribute "AXTitle" of UI element rowIdx of listRef
                        if rawLater is not missing value then set laterTitle to rawLater as string
                    end try
                end tell
                if laterSelected is false then return {"menu-changed", "the row's title had no state word after the menu, and at a second read the menu was another row's; ", frameText}
                if not (my rowIsForName(laterTitle, nameVariants)) then return {"menu-changed", "the row's title had no state word after the menu, and at a second read the row had moved; ", frameText}
                set nowKind to my rowKind(laterTitle, nameVariants)
                if nowKind is "" then return {"menu-changed", "the row's title had no state word after the menu, read twice; ", frameText}
                set readNote to "the row's title had no state word right after the menu, and had one at a second read; "
            end if
            if nowKind is not scanKind then return {"menu-changed", "the row changed; ", frameText}
        end if
    end if
    if not (my wholeNameStill(listRef, rowIdx, my wholeNameList)) then return {"menu-changed", "the row's file changed; ", frameText}
    return {"menu-shown", readNote & "row menu shown (selected=" & (rowSelected as string) & "); ", frameText}
end showRowMenu

on pidText(procName)
    -- The browser's process id, so the plugin can tell its menu apart.
    set pidValue to ""
    tell application "System Events"
        try
            set pidValue to (unix id of process procName) as string
        end try
    end tell
    return pidValue
end pidText

on buttonIndexFor(labelList, actionMode)
    repeat with btnIdx from 1 to (count of labelList)
        if my wantsButton(actionMode, item btnIdx of labelList) then return btnIdx
    end repeat
    return 0
end buttonIndexFor

on scanRows(listRef, nameVariants, batched, actionMode)
    -- Returns {rows for this file name, candidate row positions, the
    -- position of the wanted button in each, total rows, labels seen, the
    -- candidates' titles, the state each shows}. A candidate is a row for
    -- this file with the button the action goes by (see wantsButton). A
    -- row whose title has the name shortened counts only when its name
    -- label carries this file's whole name (see namesForRow).
    set titleList to my rowTitlesOf(listRef, batched)
    set nameRows to 0
    set candRows to {}
    set candButtons to {}
    set candTitles to {}
    set candKinds to {}
    set seenText to ""
    set otherShort to 0
    repeat with rowIdx from 1 to (count of titleList)
        set oneTitle to item rowIdx of titleList
        set rowNames to my namesForRow(listRef, rowIdx, oneTitle, nameVariants)
        set seenText to seenText & (my shortNote)
        if my rowIsForName(oneTitle, rowNames) then
            set nameRows to nameRows + 1
            set labelList to my rowButtonLabels(listRef, rowIdx, batched)
            -- (Stop goes by the Cancel button alone, so it skips this.)
            set oneKind to ""
            if actionMode is not "cancel" then set oneKind to my rowKind(oneTitle, rowNames)
            set seenText to seenText & "row " & rowIdx & "=[" & my joinedTexts(labelList) & "]" & oneKind & " "
            if actionMode is not "cancel" and oneKind is "" then set seenText to seenText & "(state not recognised; its status begins: " & my statusShape(oneTitle, rowNames) & ") "
            if (count of rowNames) > (count of nameVariants) then set seenText to seenText & "(name shortened in the panel) "
            set btnIdx to my buttonIndexFor(labelList, actionMode)
            if btnIdx > 0 then
                set end of candRows to rowIdx
                set end of candButtons to btnIdx
                set end of candTitles to oneTitle
                set end of candKinds to oneKind
            end if
        else
            if oneTitle contains (character id 8230) then set otherShort to otherShort + 1
        end if
    end repeat
    if otherShort > 0 then set seenText to seenText & "shortened names of other files=" & otherShort & " "
    return {nameRows, candRows, candButtons, (count of titleList), seenText, candTitles, candKinds}
end scanRows

on pressRowButton(listRef, rowIdx, btnIdx, fileNames, scanTitle, scanKind, actionMode)
    -- Re-check right before pressing, because rows shift when a download
    -- starts or is removed: the button first, then the row's title, then
    -- press at once. A row's title ends with its button's label ("<name>
    -- <status> Cancel"); when the scan saw it that way, the last read must
    -- too, and it must still show the same state, so that one read proves
    -- the row is this file's AND unchanged. For a name the panel shows
    -- shortened, the whole name on the row's label is read too: before the
    -- title, and once more after it, last of all (two files can look the
    -- same shortened).
    set btnLabel to my rowButtonLabel(listRef, rowIdx, btnIdx)
    if not (my wantsButton(actionMode, btnLabel)) then return {"changed", "button changed before the press; "}
    set strictEnd to (scanTitle ends with btnLabel)
    set nameVariants to my namesForRow(listRef, rowIdx, scanTitle, fileNames)
    set nowTitle to my childAttrText(listRef, rowIdx, "AXTitle")
    if not (my rowIsForName(nowTitle, nameVariants)) then return {"changed", "row moved before the press; "}
    if strictEnd and not (nowTitle ends with btnLabel) then return {"changed", "row changed before the press; "}
    if scanKind is not "" and (my rowKind(nowTitle, nameVariants)) is not scanKind then return {"changed", "row state changed before the press; "}
    if not (my wholeNameStill(listRef, rowIdx, fileNames)) then return {"changed", "row's file changed before the press; "}
    set pressedOk to false
    tell application "System Events"
        try
            perform action "AXPress" of button btnIdx of UI element rowIdx of listRef
            set pressedOk to true
        end try
    end tell
    if pressedOk then return {actionMode & "-sent", "pressed [" & btnLabel & "] in row " & rowIdx & "; "}
    return {"press-failed", "pressing [" & btnLabel & "] reported an error; "}
end pressRowButton

on resumeRow(procName, listRef, rowIdx, btnIdx, fileNames, scanTitle, scanKind)
    -- The same re-checks as for a press (a paused row keeps its Cancel
    -- button), then the row's right-click menu, where Resume is. Where the
    -- row is comes first, so that the last check of the row comes right
    -- before its menu is shown.
    set frameText to my rowFrame(listRef, rowIdx)
    if frameText is "" then return {"row-hidden", "the row's middle isn't in view (panel list and browser window), no menu shown; ", ""}
    if not (my notePid(procName)) then return {"no-menu", "the browser's process id couldn't be read, no menu shown; ", ""}
    set btnLabel to my rowButtonLabel(listRef, rowIdx, btnIdx)
    if not (my looksLikeCancel(btnLabel)) then return {"changed", "button changed before the menu; ", ""}
    set strictEnd to (scanTitle ends with btnLabel)
    set nameVariants to my namesForRow(listRef, rowIdx, scanTitle, fileNames)
    set nowTitle to my childAttrText(listRef, rowIdx, "AXTitle")
    if not (my rowIsForName(nowTitle, nameVariants)) then return {"changed", "row moved before the menu; ", ""}
    if strictEnd and not (nowTitle ends with btnLabel) then return {"changed", "row changed before the menu; ", ""}
    if scanKind is not "" and (my rowKind(nowTitle, nameVariants)) is not scanKind then return {"changed", "row state changed before the menu; ", ""}
    if not (my wholeNameStill(listRef, rowIdx, fileNames)) then return {"changed", "row's file changed before the menu; ", ""}
    return my showRowMenu(listRef, rowIdx, nameVariants, scanKind, frameText)
end resumeRow

on actInList(procName, listRef, nameVariants, openedPanel, actionMode)
    -- Act on the one row for this file. Returns {outcome, trace, row frame}.
    set traceText to ""
    set outcome to "no-match"
    set frameText to ""
    repeat with attempt from 1 to 4
        -- Only the first read is batched; later ones go row by row.
        set scan to my scanRows(listRef, nameVariants, (attempt is 1), actionMode)
        set traceText to traceText & "rows=" & (item 4 of scan) & "; rows for this file=" & (item 1 of scan) & "; with the button=" & (count of (item 2 of scan)) & "; " & (item 5 of scan)
        set picked to my pickRow(item 1 of scan, item 7 of scan, actionMode)
        set outcome to item 1 of picked
        if outcome is "ambiguous" then exit repeat
        if outcome is "pick" then
            set n to item 2 of picked
            set rowIdx to item n of (item 2 of scan)
            set btnIdx to item n of (item 3 of scan)
            if actionMode is "resume" then
                set res to my resumeRow(procName, listRef, rowIdx, btnIdx, nameVariants, item n of (item 6 of scan), item n of (item 7 of scan))
                set frameText to item 3 of res
            else
                set res to my pressRowButton(listRef, rowIdx, btnIdx, nameVariants, item n of (item 6 of scan), item n of (item 7 of scan), actionMode)
            end if
            set outcome to item 1 of res
            set traceText to traceText & (item 2 of res)
            if outcome is not "changed" then exit repeat
        else
            -- After the batched read, confirm row by row. A panel that has
            -- only just opened may still be filling in, so it gets a little
            -- longer.
            if attempt > 1 then
                if (not openedPanel) or attempt is 4 then exit repeat
                delay 0.15
            end if
        end if
    end repeat
    return {outcome, traceText, frameText}
end actInList

-- ------------------------------------------------------------- one browser

on actInWindow(procName, loc, nameVariants, actionMode)
    set winIdx to item 1 of loc
    set grpIdx to item 2 of loc
    set traceText to "button at " & my locText(loc) & "; "
    -- Open the panel unless it is open already. Pressing the button while
    -- the panel is open only focuses it, so it is pressed at most once.
    set openedPanel to false
    set spot to my panelSpot(procName, winIdx, grpIdx, true)
    if (count of spot) is 0 then
        if my toolbarItemId(procName, loc) is not "downloads-button" then return {"no-button", traceText & "toolbar changed before the press; ", ""}
        if not (my pressToolbarItem(procName, loc)) then return {"no-panel", traceText & "pressing the Downloads button failed; ", ""}
        set openedPanel to true
        repeat 40 times
            delay 0.05
            set spot to my panelSpot(procName, winIdx, grpIdx, false)
            if (count of spot) is 2 then exit repeat
        end repeat
        if (count of spot) is 0 then set spot to my panelSpot(procName, winIdx, grpIdx, true)
    end if
    set traceText to traceText & "panel opened by script=" & openedPanel & "; "
    if (count of spot) is 2 then
        set listRef to my listRefFor(procName, winIdx, spot)
    else
        set panelEl to my findInWindows(procName, "downloadsPanel", 4)
        if panelEl is missing value then return {"no-panel", traceText & "panel did not appear; ", ""}
        set traceText to traceText & "panel found by full search; "
        set listRef to my firstByDomId(panelEl, "downloadsListBox", 3)
    end if
    if listRef is missing value then return {"no-panel", traceText & "list not found in panel; ", ""}
    set res to my actInList(procName, listRef, nameVariants, openedPanel, actionMode)
    return {item 1 of res, traceText & (item 2 of res), item 3 of res}
end actInWindow

on actBySearch(procName, nameVariants, actionMode)
    -- For layouts where the button is not where Firefox keeps it.
    set btnEl to my findInWindows(procName, "downloads-button", 5)
    if btnEl is missing value then return {"no-button", "toolbar Downloads button not found; ", ""}
    set traceText to "button found by full search; "
    set openedPanel to false
    set panelEl to my findInWindows(procName, "downloadsPanel", 4)
    if panelEl is missing value then
        if my attrText(btnEl, "AXDOMIdentifier") is not "downloads-button" then return {"no-button", traceText & "toolbar changed before the press; ", ""}
        if not (my pressElement(btnEl)) then return {"no-panel", traceText & "pressing the Downloads button failed; ", ""}
        set openedPanel to true
        repeat 10 times
            delay 0.2
            set panelEl to my findInWindows(procName, "downloadsPanel", 4)
            if panelEl is not missing value then exit repeat
        end repeat
    end if
    if panelEl is missing value then return {"no-panel", traceText & "panel did not appear; ", ""}
    set traceText to traceText & "panel opened by script=" & openedPanel & "; "
    set listRef to my firstByDomId(panelEl, "downloadsListBox", 3)
    if listRef is missing value then return {"no-panel", traceText & "list not found in panel; ", ""}
    set res to my actInList(procName, listRef, nameVariants, openedPanel, actionMode)
    return {item 1 of res, traceText & (item 2 of res), item 3 of res}
end actBySearch

on outcomeRank(oneOutcome)
    if oneOutcome is "not-active" then return 3
    if oneOutcome is "no-match" then return 2
    if oneOutcome is "no-panel" then return 1
    return 0
end outcomeRank

on actInBrowser(procName, nameVariants, actionMode, hintLoc)
    -- Returns {outcome, trace, button position, row frame}. Each browser
    -- window has its own panel, and private windows list only private
    -- downloads, so if the first window's panel doesn't have it, one more
    -- window is tried.
    set traceText to ""
    set triedWins to {}
    set bestOutcome to ""
    set bestLoc to {}
    repeat 2 times
        set loc to my findDownloadsButton(procName, hintLoc, triedWins)
        if (count of loc) is not 4 then exit repeat
        if actionMode is "locate" then return {"located", "button at " & my locText(loc) & "; ", loc, ""}
        set end of triedWins to (item 1 of loc)
        set res to my actInWindow(procName, loc, nameVariants, actionMode)
        set traceText to traceText & (item 2 of res)
        if (item 1 of res) is not in {"no-match", "not-active"} then return {item 1 of res, traceText, loc, item 3 of res}
        if bestOutcome is "" or (my outcomeRank(item 1 of res)) > (my outcomeRank(bestOutcome)) then
            set bestOutcome to item 1 of res
            set bestLoc to loc
        end if
    end repeat
    if bestOutcome is not "" then return {bestOutcome, traceText, bestLoc, ""}
    if actionMode is "locate" then return {"no-button", "toolbar Downloads button not at its usual place; ", {}, ""}
    set res to my actBySearch(procName, nameVariants, actionMode)
    return {item 1 of res, traceText & (item 2 of res), {}, item 3 of res}
end actInBrowser

on run argv
    set nameVariants to {}
    set hintName to ""
    set hintLoc to {}
    set actionMode to "cancel"
    repeat with oneArg in argv
        set rawArg to (contents of oneArg) as string
        if rawArg is in {"mode:locate", "mode:cancel", "mode:retry", "mode:resume", "mode:restart"} then set actionMode to (text 6 thru -1 of rawArg)
        if (length of rawArg) > 5 then
            if (text 1 thru 5 of rawArg) is "name:" then set end of nameVariants to (text 6 thru -1 of rawArg)
            if (text 1 thru 5 of rawArg) is "proc:" then set hintName to (text 6 thru -1 of rawArg)
        end if
        if (length of rawArg) > 4 then
            if (text 1 thru 4 of rawArg) is "btn:" then set hintLoc to my parseLoc(text 5 thru -1 of rawArg)
        end if
    end repeat
    if (count of nameVariants) is 0 and actionMode is not "locate" then return "no-name|no file name was passed||||"
    set my shownPid to ""
    try
        set procNames to my browserProcesses(hintName)
        if (count of procNames) is 0 then return "no-browser|no Firefox-family browser process found||||"
        set bestOutcome to ""
        set bestTrace to ""
        set bestProc to ""
        set bestLoc to {}
        repeat with procItem in procNames
            set procName to (contents of procItem) as string
            set procHint to {}
            if procName is hintName then set procHint to hintLoc
            set res to my actInBrowser(procName, nameVariants, actionMode, procHint)
            set oneOutcome to item 1 of res
            set oneTrace to "browser=" & procName & "; " & (item 2 of res)
            if oneOutcome is not in {"no-match", "not-active", "no-panel", "no-button"} then
                set pidValue to ""
                if oneOutcome is in {"menu-shown", "menu-changed", "show-error"} then set pidValue to my shownPid
                return oneOutcome & "|" & oneTrace & "|" & procName & "|" & my locText(item 3 of res) & "|" & (item 4 of res) & "|" & pidValue
            end if
            if bestOutcome is "" or (my outcomeRank(oneOutcome)) > (my outcomeRank(bestOutcome)) then
                set bestOutcome to oneOutcome
                set bestTrace to oneTrace
                set bestProc to procName
                set bestLoc to item 3 of res
            end if
        end repeat
        return bestOutcome & "|" & bestTrace & "|" & bestProc & "|" & my locText(bestLoc) & "||"
    on error errText number errNum
        return "script-error|" & errText & " (" & errNum & ")||||"
    end try
end run
"""#

    /// A slower, element-by-element version of the same search, with the
    /// same safety rules. Used only if the script above cannot run.
    static let legacy = #"""
-- Firefox Downloads: FALLBACK script. A slower, element-by-element version
-- of the main script's search, which the plugin only runs when the main
-- script cannot run. The same actions (cancel, retry, restart, resume) and
-- the same safety rules: no keystrokes, the browser stays in the
-- background, web page content is never searched, and the only things
-- pressed are a Cancel or Retry button of the single row whose title starts
-- with this file's name (for Resume, that row's menu is shown; the plugin
-- chooses Resume).
-- Returns "outcome|trace|process||row frame|process id" (for Resume: the
-- row whose menu was shown, and the browser's process id; for
-- "menu-changed" and "show-error" the plugin only closes that menu).

on childrenOf(el)
    set kids to {}
    tell application "System Events"
        try
            set kids to UI elements of el
        end try
    end tell
    return kids
end childrenOf

on domIdOf(el)
    set gotId to ""
    tell application "System Events"
        try
            set rawId to value of attribute "AXDOMIdentifier" of el
            if rawId is not missing value then set gotId to rawId as string
        end try
    end tell
    return gotId
end domIdOf

on isWebArea(el)
    set webArea to false
    tell application "System Events"
        try
            if (value of attribute "AXRole" of el) is "AXWebArea" then set webArea to true
        end try
    end tell
    return webArea
end isWebArea

on firstByDomId(el, wantId, depthLeft)
    -- Web pages can use the same ids, so page content is never entered.
    if depthLeft is 0 then return missing value
    repeat with k in my childrenOf(el)
        set kk to (contents of k)
        if my domIdOf(kk) is wantId then return kk
        if not (my isWebArea(kk)) then
            set foundEl to my firstByDomId(kk, wantId, depthLeft - 1)
            if foundEl is not missing value then return foundEl
        end if
    end repeat
    return missing value
end firstByDomId

on findInWindows(procName, wantId, depthLimit)
    set wins to {}
    tell application "System Events"
        try
            set wins to windows of process procName
        end try
    end tell
    repeat with w in wins
        set foundEl to my firstByDomId((contents of w), wantId, depthLimit)
        if foundEl is not missing value then return foundEl
    end repeat
    return missing value
end findInWindows

on pressElement(el)
    tell application "System Events"
        try
            perform action "AXPress" of el
            return true
        end try
    end tell
    return false
end pressElement

property cachedCancelLabels : missing value

on looksLikeCancel(theText)
    -- True only for the EXACT label of a download row's Cancel button (downloads-cmd-cancel-panel).
    -- No other button a row can have (Retry, Show in Finder, Remove File...)
    -- has one of these labels in any language. A label that merely contains
    -- "cancel" does not count: in Ligurian, "Remove File" is "Scancella schedaio".
    -- Firefox's own translations, in all 115 languages it has. (Letter case
    -- aside: no other label differs from one of these only by case.) The
    -- list is built once per run.
    set lbl to theText as string
    if lbl is "" then return false
    if my cachedCancelLabels is missing value then set my cachedCancelLabels to (my asciiCancelLabels()) & (my otherCancelLabels())
    repeat with oneLabel in my cachedCancelLabels
        if lbl is (contents of oneLabel) then return true
    end repeat
    return false
end looksLikeCancel

on asciiCancelLabels()
    -- The labels written in plain ASCII (English first).
    set labelList to {}
    set labelList to labelList & {"Cancel", "&Haaytu", "Abbrechen", "Annulearje", "Annuler", "Annuleren", "Annulla"}
    set labelList to labelList & {"Annuller", "Anule", "Anulla", "Anullar", "Anuloje", "Anuluj", "Atcelt", "Atsisakyti"}
    set labelList to labelList & {"Avbryt", "Batal", "Batalkan", "Bekor qilish", "Cancelar", "Cancellar", "Cealaigh"}
    set labelList to labelList & {"Diddymu", "Duyichin'", "Encaboxar", "Heja", "Interrumper", "Juki", "Kanselahin"}
    set labelList to labelList & {"Kanselleer", "Katkesta", "Neenal", "Nkuvi-ka", "Nuligi", "Odustani", "Peruuta", "Pociep"}
    set labelList to labelList & {"Rhoxisa", "Sefsex", "Sfai", "Sguir dheth", "Stap", "Tiq'at", "Utzi"}
    return labelList
end asciiCancelLabels

on otherCancelLabels()
    -- The other labels, spelled as Unicode code points so this script
    -- stays plain ASCII.
    set labelList to {}
    set labelList to labelList & {("Anuleaz" & (character id 259)), ("Atce" & (character id 316) & "t")}
    set labelList to labelList & {("Cancel" & (character id 183) & "la")}
    set labelList to labelList & {("H" & (character id 230) & "tta vi" & (character id 240))}
    set labelList to labelList & {("H" & (character id 7911) & "y b" & (character id 7887)), ((character id 304) & "ptal")}
    set labelList to labelList & {("L" & (character id 601) & (character id 287) & "v et")}
    set labelList to labelList & {("M" & (character id 233) & "gse"), ("Na" & (character id 331))}
    set labelList to labelList & {("Nulla" & (character id 241)), ("Otka" & (character id 382) & "i")}
    set labelList to labelList & {("Prekli" & (character id 269) & "i")}
    set labelList to labelList & {("P" & (character id 345) & "etorhny" & (character id 263))}
    set labelList to labelList & {("P" & (character id 347) & "etergnu" & (character id 347))}
    set labelList to labelList & {("Zru" & (character id 353) & "it")}
    set labelList to labelList & {("Zru" & (character id 353) & "i" & (character id 357))}
    set labelList to labelList & {((character id 913) & (character id 954) & (character id 973) & (character id 961) & (character id 969) & (character id 963) & (character id 951))}
    set labelList to labelList & {((character id 1041) & (character id 1072) & (character id 1089) & " " & (character id 1090) & (character id 1072) & (character id 1088) & (character id 1090) & (character id 1091))}
    set labelList to labelList & {((character id 1041) & (character id 1077) & (character id 1082) & (character id 1086) & (character id 1088) & " " & (character id 1082) & (character id 1072) & (character id 1088) & (character id 1076) & (character id 1072) & (character id 1085))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1082) & (character id 1072) & (character id 1078) & (character id 1080))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1084) & (character id 1077) & (character id 1085) & (character id 1080) & (character id 1090) & (character id 1100))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1077) & (character id 1082) & (character id 1098) & (character id 1089) & (character id 1074) & (character id 1072) & (character id 1085) & (character id 1077))}
    set labelList to labelList & {((character id 1057) & (character id 1082) & (character id 1072) & (character id 1089) & (character id 1072) & (character id 1074) & (character id 1072) & (character id 1094) & (character id 1100))}
    set labelList to labelList & {((character id 1057) & (character id 1082) & (character id 1072) & (character id 1089) & (character id 1091) & (character id 1074) & (character id 1072) & (character id 1090) & (character id 1080))}
    set labelList to labelList & {((character id 1353) & (character id 1381) & (character id 1394) & (character id 1377) & (character id 1408) & (character id 1391) & (character id 1381) & (character id 1388))}
    set labelList to labelList & {((character id 1489) & (character id 1497) & (character id 1496) & (character id 1493) & (character id 1500))}
    set labelList to labelList & {((character id 1571) & (character id 1604) & (character id 1594) & (character id 1616))}
    set labelList to labelList & {((character id 1575) & (character id 1606) & (character id 1589) & (character id 1585) & (character id 1575) & (character id 1601))}
    set labelList to labelList & {((character id 1604) & (character id 1602) & (character id 1608))}
    set labelList to labelList & {((character id 1605) & (character id 1606) & (character id 1587) & (character id 1608) & (character id 1582))}
    set labelList to labelList & {((character id 1605) & (character id 1606) & (character id 1587) & (character id 1608) & (character id 1582) & " " & (character id 1705) & (character id 1585) & (character id 1740) & (character id 1722))}
    set labelList to labelList & {((character id 1662) & (character id 1575) & (character id 1588) & (character id 1711) & (character id 1749) & (character id 1586) & (character id 1576) & (character id 1608) & (character id 1608) & (character id 1606) & (character id 1749) & (character id 1608) & (character id 1749))}
    set labelList to labelList & {((character id 2344) & (character id 2375) & (character id 2357) & (character id 2360) & (character id 2367) & (character id 2327) & (character id 2366) & (character id 2352))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2325) & (character id 2352) & (character id 2366))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2325) & (character id 2352) & (character id 2375) & (character id 2306))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2327) & (character id 2352) & (character id 2381) & (character id 2344) & (character id 2369) & (character id 2361) & (character id 2379) & (character id 2360) & (character id 2381))}
    set labelList to labelList & {((character id 2476) & (character id 2494) & (character id 2468) & (character id 2495) & (character id 2482))}
    set labelList to labelList & {((character id 2608) & (character id 2673) & (character id 2598) & " " & (character id 2581) & (character id 2608) & (character id 2635))}
    set labelList to labelList & {((character id 2736) & (character id 2726) & " " & (character id 2709) & (character id 2736) & (character id 2763))}
    set labelList to labelList & {((character id 2992) & (character id 2980) & (character id 3021) & (character id 2980) & (character id 3009))}
    set labelList to labelList & {((character id 3120) & (character id 3110) & (character id 3149) & (character id 3110) & (character id 3137) & (character id 3098) & (character id 3143) & (character id 3119) & (character id 3135))}
    set labelList to labelList & {((character id 3248) & (character id 3238) & (character id 3277) & (character id 3238) & (character id 3265) & " " & (character id 3246) & (character id 3262) & (character id 3233) & (character id 3265))}
    set labelList to labelList & {((character id 3377) & (character id 3366) & (character id 3405) & (character id 3366) & (character id 3390) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3349))}
    set labelList to labelList & {((character id 3461) & (character id 3520) & (character id 3517) & (character id 3458) & (character id 3484) & (character id 3540))}
    set labelList to labelList & {((character id 3618) & (character id 3585) & (character id 3648) & (character id 3621) & (character id 3636) & (character id 3585))}
    set labelList to labelList & {((character id 3725) & (character id 3771) & (character id 3713) & (character id 3776) & (character id 3749) & (character id 3765) & (character id 3713))}
    set labelList to labelList & {((character id 3925) & (character id 4017) & (character id 3954) & (character id 3938) & (character id 3851) & (character id 3936) & (character id 3920) & (character id 3962) & (character id 3923))}
    set labelList to labelList & {((character id 4121) & (character id 4124) & (character id 4143) & (character id 4117) & (character id 4154) & (character id 4102) & (character id 4145) & (character id 4140) & (character id 4100) & (character id 4154) & (character id 4112) & (character id 4145) & (character id 4140) & (character id 4151) & (character id 4117) & (character id 4139))}
    set labelList to labelList & {((character id 4306) & (character id 4304) & (character id 4323) & (character id 4325) & (character id 4315) & (character id 4308) & (character id 4305) & (character id 4304))}
    set labelList to labelList & {((character id 6036) & (character id 6084) & (character id 6087) & (character id 6036) & (character id 6020) & (character id 6091))}
    set labelList to labelList & {((character id 7285) & (character id 7263) & (character id 7289) & (character id 7280) & (character id 7272) & (character id 7263) & (character id 7289))}
    set labelList to labelList & {((character id 12461) & (character id 12515) & (character id 12531) & (character id 12475) & (character id 12523))}
    set labelList to labelList & {((character id 21462) & (character id 28040))}
    set labelList to labelList & {((character id 52712) & (character id 49548))}
    return labelList
end otherCancelLabels

property cachedRetryLabels : missing value

on looksLikeRetry(theText)
    -- True only for the EXACT label of a download row's Retry button (downloads-cmd-retry-panel).
    -- No other button a row can have has one of these labels in any language.
    -- Firefox's own translations, in all 114 languages it has. (Letter case
    -- aside: no other label differs from one of these only by case.) The
    -- list is built once per run.
    set lbl to theText as string
    if lbl is "" then return false
    if my cachedRetryLabels is missing value then set my cachedRetryLabels to (my asciiRetryLabels()) & (my otherRetryLabels())
    repeat with oneLabel in my cachedRetryLabels
        if lbl is (contents of oneLabel) then return true
    end repeat
    return false
end looksLikeRetry

on asciiRetryLabels()
    -- The labels written in plain ASCII (English first).
    set labelList to {}
    set labelList to labelList & {"Retry", "Atkuortuot", "Atriail", "Ceisio eto", "Coba Lagi", "Cuba lagi"}
    set labelList to labelList & {"Empruvar anc ina giada", "Feuch ris a-rithist", "Klask en-dro", "Klopodi denove"}
    set labelList to labelList & {"Nochmals versuchen", "Opakovat", "Opnieuw proberen", "Opnij probearje", "Phinda uzame"}
    set labelList to labelList & {"Poskusi znova", "Preuva torna", "Probeer weer", "Proovi uuesti", "Qayta urinish"}
    set labelList to labelList & {"Reintenta", "Reintentar", "Repetir", "Retentar", "Reyna aftur", "Riprova", "Riprovo"}
    set labelList to labelList & {"Saiatu berriro", "Subukan muli", "Tem odoco", "Tentar de novo", "Tornar a prebar"}
    set labelList to labelList & {"Tornar ensajar", "Torne prove", "Torra a proare", "Try Again", "Voltar a tentar"}
    set labelList to labelList & {"Yeniden dene", "Znova"}
    return labelList
end asciiRetryLabels

on otherRetryLabels()
    -- The other labels, spelled as Unicode code points so this script
    -- stays plain ASCII.
    set labelList to {}
    set labelList to labelList & {("A'ngo " & (character id 241) & "un"), ("Atk" & (character id 257) & "rtot")}
    set labelList to labelList & {("E" & (character id 241) & "eha" & (character id 8217) & (character id 227) & " jey")}
    set labelList to labelList & {("Fu" & (character id 599) & (character id 599) & "ito")}
    set labelList to labelList & {("F" & (character id 246) & "rs" & (character id 246) & "k igen")}
    set labelList to labelList & {("Hi" & (character id 353) & (character id 263) & "e raz spyta" & (character id 263))}
    set labelList to labelList & {("Hy" & (character id 353) & (character id 263) & "i raz wopyta" & (character id 347))}
    set labelList to labelList & {("I" & (character id 353) & " naujo"), ("J" & (character id 233) & "emaat")}
    set labelList to labelList & {("Nas" & (character id 225) & (character id 180) & (character id 225) & " tuku")}
    set labelList to labelList & {("Poku" & (character id 353) & "aj ponovo"), ("Pr" & (character id 248) & "v igen")}
    set labelList to labelList & {("Pr" & (character id 248) & "v igjen")}
    set labelList to labelList & {("Pr" & (character id 248) & "v p" & (character id 229) & " nytt")}
    set labelList to labelList & {("Re" & (character id 238) & "ncearc" & (character id 259))}
    set labelList to labelList & {("R" & (character id 233) & "essayer"), ("Spr" & (character id 243) & "buj ponownie")}
    set labelList to labelList & {("Spr" & (character id 333) & "buj za" & (character id 347))}
    set labelList to labelList & {("Th" & (character id 7917) & " l" & (character id 7841) & "i")}
    set labelList to labelList & {("Titojtob'" & (character id 235) & "x chik"), ("T" & (character id 601) & "krar yoxla")}
    set labelList to labelList & {("Yrit" & (character id 228) & " uudestaan"), ((character id 218) & "jra")}
    set labelList to labelList & {((character id 352) & "ii taaga")}
    set labelList to labelList & {((character id 400) & "re" & (character id 7693) & " i tikelt-nni" & (character id 7693) & "en")}
    set labelList to labelList & {((character id 917) & (character id 960) & (character id 945) & (character id 957) & (character id 940) & (character id 955) & (character id 951) & (character id 968) & (character id 951))}
    set labelList to labelList & {((character id 1055) & (character id 1072) & (character id 1118) & (character id 1090) & (character id 1072) & (character id 1088) & (character id 1099) & (character id 1094) & (character id 1100))}
    set labelList to labelList & {((character id 1055) & (character id 1086) & (character id 1074) & (character id 1090) & (character id 1086) & (character id 1088) & (character id 1077) & (character id 1085) & " " & (character id 1086) & (character id 1087) & (character id 1080) & (character id 1090))}
    set labelList to labelList & {((character id 1055) & (character id 1086) & (character id 1074) & (character id 1090) & (character id 1086) & (character id 1088) & (character id 1080) & (character id 1090) & (character id 1080))}
    set labelList to labelList & {((character id 1055) & (character id 1086) & (character id 1074) & (character id 1090) & (character id 1086) & (character id 1088) & (character id 1080) & (character id 1090) & (character id 1100))}
    set labelList to labelList & {((character id 1055) & (character id 1086) & (character id 1082) & (character id 1091) & (character id 1096) & (character id 1072) & (character id 1112) & " " & (character id 1087) & (character id 1086) & (character id 1085) & (character id 1086) & (character id 1074) & (character id 1086))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1086) & (character id 1073) & (character id 1072) & (character id 1112) & " " & (character id 1087) & (character id 1072) & (character id 1082))}
    set labelList to labelList & {((character id 1058) & (character id 1072) & (character id 1082) & (character id 1088) & (character id 1086) & (character id 1088) & " " & (character id 1082) & (character id 1072) & (character id 1088) & (character id 1076) & (character id 1072) & (character id 1085))}
    set labelList to labelList & {((character id 1178) & (character id 1072) & (character id 1081) & (character id 1090) & (character id 1072) & (character id 1083) & (character id 1072) & (character id 1091))}
    set labelList to labelList & {((character id 1343) & (character id 1408) & (character id 1391) & (character id 1387) & (character id 1398) & " " & (character id 1411) & (character id 1400) & (character id 1408) & (character id 1393) & (character id 1381) & (character id 1388))}
    set labelList to labelList & {((character id 1343) & (character id 1408) & (character id 1391) & (character id 1398) & (character id 1381) & (character id 1388))}
    set labelList to labelList & {((character id 1504) & (character id 1497) & (character id 1505) & (character id 1497) & (character id 1493) & (character id 1503) & " " & (character id 1495) & (character id 1493) & (character id 1494) & (character id 1512))}
    set labelList to labelList & {((character id 1571) & (character id 1593) & (character id 1583) & " " & (character id 1575) & (character id 1604) & (character id 1605) & (character id 1581) & (character id 1575) & (character id 1608) & (character id 1604) & (character id 1577))}
    set labelList to labelList & {((character id 1602) & (character id 1662) & " " & (character id 1585) & (character id 1740) & (character id 1578) & " " & (character id 1583) & (character id 1608) & (character id 1608) & (character id 1575) & (character id 1585) & (character id 1578) & (character id 1607))}
    set labelList to labelList & {((character id 1607) & (character id 1749) & (character id 1608) & (character id 1717) & " " & (character id 1576) & (character id 1583) & (character id 1749) & (character id 1585) & (character id 1749) & (character id 1608) & (character id 1749))}
    set labelList to labelList & {((character id 1608) & (character id 1604) & (character id 1575) & " " & (character id 1705) & (character id 1608) & (character id 1588) & (character id 1588) & " " & (character id 1705) & (character id 1585) & (character id 1608))}
    set labelList to labelList & {((character id 1662) & (character id 1726) & (character id 1585) & " " & (character id 1705) & (character id 1608) & (character id 1588) & (character id 1588) & " " & (character id 1705) & (character id 1585) & (character id 1740) & (character id 1722))}
    set labelList to labelList & {((character id 1705) & (character id 1608) & (character id 1588) & (character id 1588) & " " & (character id 1583) & (character id 1608) & (character id 1576) & (character id 1575) & (character id 1585) & (character id 1607))}
    set labelList to labelList & {((character id 2346) & (character id 2369) & (character id 2344) & (character id 2307) & " " & (character id 2346) & (character id 2381) & (character id 2352) & (character id 2351) & (character id 2366) & (character id 2360) & " " & (character id 2327) & (character id 2352) & (character id 2381) & (character id 2344) & (character id 2369) & (character id 2361) & (character id 2379) & (character id 2360) & (character id 2381))}
    set labelList to labelList & {((character id 2346) & (character id 2369) & (character id 2344) & (character id 2307) & (character id 2346) & (character id 2381) & (character id 2352) & (character id 2351) & (character id 2340) & (character id 2381) & (character id 2344) & " " & (character id 2325) & (character id 2352) & (character id 2366))}
    set labelList to labelList & {((character id 2347) & (character id 2367) & (character id 2344) & " " & (character id 2344) & (character id 2366) & (character id 2332) & (character id 2366))}
    set labelList to labelList & {((character id 2347) & (character id 2367) & (character id 2352) & " " & (character id 2325) & (character id 2379) & (character id 2358) & (character id 2367) & (character id 2358) & (character id 8204) & " " & (character id 2325) & (character id 2352) & (character id 2375) & (character id 2306))}
    set labelList to labelList & {((character id 2474) & (character id 2497) & (character id 2472) & (character id 2480) & (character id 2494) & (character id 2527) & " " & (character id 2458) & (character id 2503) & (character id 2487) & (character id 2509) & (character id 2463) & (character id 2494) & " " & (character id 2453) & (character id 2480) & (character id 2497) & (character id 2472))}
    set labelList to labelList & {((character id 2606) & (character id 2625) & (character id 2652) & "-" & (character id 2581) & (character id 2635) & (character id 2616) & (character id 2620) & (character id 2623) & (character id 2616) & (character id 2620))}
    set labelList to labelList & {((character id 2731) & (character id 2736) & (character id 2752) & " " & (character id 2730) & (character id 2765) & (character id 2736) & (character id 2735) & (character id 2724) & (character id 2765) & (character id 2728) & " " & (character id 2709) & (character id 2736) & (character id 2763))}
    set labelList to labelList & {((character id 2990) & (character id 2993) & (character id 3009) & (character id 2990) & (character id 3009) & (character id 2991) & (character id 2993) & (character id 3021) & (character id 2970) & (character id 3007))}
    set labelList to labelList & {((character id 3118) & (character id 3123) & (character id 3149) & (character id 3123) & (character id 3136) & " " & (character id 3114) & (character id 3149) & (character id 3120) & (character id 3119) & (character id 3108) & (character id 3149) & (character id 3112) & (character id 3135) & (character id 3074) & (character id 3098) & (character id 3137))}
    set labelList to labelList & {((character id 3246) & (character id 3248) & (character id 3251) & (character id 3263) & " " & (character id 3242) & (character id 3277) & (character id 3248) & (character id 3247) & (character id 3236) & (character id 3277) & (character id 3240) & (character id 3263) & (character id 3256) & (character id 3265))}
    set labelList to labelList & {((character id 3381) & (character id 3392) & (character id 3363) & (character id 3405) & (character id 3359) & (character id 3393) & (character id 3330) & " " & (character id 3382) & (character id 3405) & (character id 3376) & (character id 3374) & (character id 3391) & (character id 3375) & (character id 3405) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3349))}
    set labelList to labelList & {((character id 3505) & (character id 3536) & (character id 3520) & (character id 3501))}
    set labelList to labelList & {((character id 3621) & (character id 3629) & (character id 3591) & (character id 3651) & (character id 3627) & (character id 3617) & (character id 3656))}
    set labelList to labelList & {((character id 3749) & (character id 3757) & (character id 3719) & (character id 3779) & (character id 3755) & (character id 3745) & (character id 3784) & (character id 3757) & (character id 3765) & (character id 3713) & (character id 3716) & (character id 3761) & (character id 3785) & (character id 3719))}
    set labelList to labelList & {((character id 3926) & (character id 3942) & (character id 3984) & (character id 4017) & (character id 3938) & (character id 3851) & (character id 3921) & (character id 3956) & (character id 3851) & (character id 3930) & (character id 3964) & (character id 3921) & (character id 3851) & (character id 3939) & (character id 3999))}
    set labelList to labelList & {((character id 4113) & (character id 4117) & (character id 4154) & (character id 4121) & (character id 4150) & (character id 4102) & (character id 4145) & (character id 4140) & (character id 4100) & (character id 4154) & (character id 4123) & (character id 4157) & (character id 4096) & (character id 4154) & (character id 4096) & (character id 4156) & (character id 4106) & (character id 4151) & (character id 4154) & (character id 4117) & (character id 4139))}
    set labelList to labelList & {((character id 4304) & (character id 4334) & (character id 4314) & (character id 4312) & (character id 4307) & (character id 4304) & (character id 4316))}
    set labelList to labelList & {((character id 6038) & (character id 6098) & (character id 6041) & (character id 6070) & (character id 6041) & (character id 6070) & (character id 6040) & (character id 8203) & (character id 6040) & (character id 6098) & (character id 6031) & (character id 6020) & (character id 8203) & (character id 6033) & (character id 6080) & (character id 6031))}
    set labelList to labelList & {((character id 7275) & (character id 7258) & (character id 7282) & (character id 7263) & " " & (character id 7264) & (character id 7273) & (character id 7272) & (character id 7273) & (character id 7266) & (character id 7273) & (character id 7284) & (character id 7273))}
    set labelList to labelList & {((character id 20877) & (character id 35430) & (character id 34892))}
    set labelList to labelList & {((character id 37325) & (character id 35430))}
    set labelList to labelList & {((character id 37325) & (character id 35797))}
    set labelList to labelList & {((character id 45796) & (character id 49884) & " " & (character id 49884) & (character id 46020))}
    return labelList
end otherRetryLabels

property cachedStateWords : missing value

on statusKindOf(statusText)
    -- "paused", "failed" or "canceled" when a row's status text (its title
    -- after the file name) starts with Firefox's word for that state, in any
    -- language; "" otherwise (downloading, finished...). No word of one kind
    -- starts with a word of another kind, in any language.
    -- A row with a progress bar (downloading, paused) has the bar's value
    -- between the file name and the status: that value is passed over.
    set restText to my withoutLeadingBlanks(statusText as string)
    set restText to my withoutLeadingBlanks(my afterBarValue(restText))
    if restText is "" then return ""
    if my cachedStateWords is missing value then set my cachedStateWords to {{"paused", my pausedWords()}, {"failed", my failedWords()}, {"canceled", my canceledWords()}}
    repeat with kindPair in my cachedStateWords
        repeat with oneWord in (item 2 of kindPair)
            if restText starts with (contents of oneWord) then return (item 1 of kindPair)
        end repeat
    end repeat
    return ""
end statusKindOf

on withoutLeadingBlanks(someText)
    -- The text without the spaces and direction marks (right-to-left
    -- languages) it starts with.
    set restText to someText as string
    repeat while (length of restText) > 0
        if (id of (character 1 of restText)) is in {32, 9, 10, 13, 160, 8194, 8195, 8201, 8206, 8207, 8234, 8235, 8236, 8237, 8238, 8239, 8294, 8295, 8296, 8297} then
            if (length of restText) is 1 then
                set restText to ""
            else
                set restText to text 2 thru -1 of restText
            end if
        else
            exit repeat
        end if
    end repeat
    return restText
end withoutLeadingBlanks

on afterBarValue(statusText)
    -- A progress bar's value as the browser writes it in a row's title:
    -- digits, perhaps a point and more digits, then a percent sign and a
    -- space ("42% Paused", "7.5% Paused"). Returns what follows that value;
    -- the text as it is when it doesn't start with exactly that (so a text
    -- that only looks a bit like it is never cut).
    set textLen to length of statusText
    set digitCount to 0
    set markCount to 0
    set pos to 1
    repeat while pos <= textLen and pos <= 20
        set charId to id of (character pos of statusText)
        if charId is in {48, 49, 50, 51, 52, 53, 54, 55, 56, 57} then
            set digitCount to digitCount + 1
        else if charId is 46 and digitCount > 0 and markCount is 0 then
            set markCount to 1
        else
            exit repeat
        end if
        set pos to pos + 1
    end repeat
    if digitCount is 0 or pos > textLen then return statusText
    if (id of (character pos of statusText)) is not 37 then return statusText
    if (id of (character (pos - 1) of statusText)) is 46 then return statusText
    if pos is textLen then return statusText
    if (id of (character (pos + 1) of statusText)) is not in {32, 9, 160, 8194, 8195, 8201, 8239} then return statusText
    return text (pos + 1) thru -1 of statusText
end afterBarValue

on pausedWords()
    -- Firefox's word for a paused download (statePaused), in every language.
    set labelList to {}
    set labelList to labelList & {"'Na stad", ("Aptur" & (character id 257) & "ta"), ("Aptur" & (character id 275) & "ta")}
    set labelList to labelList & {("Aste" & (character id 603) & "fu"), "Curtha ar Sos", "Dijeda"}
    set labelList to labelList & {("Duraklat" & (character id 305) & "ld" & (character id 305)), "Duyichin' akuan'"}
    set labelList to labelList & {"Ehanet", "En pausa", "En pause", "En posa", "Ena sabbii", "Ga hunanzam", "Gepauzeerd"}
    set labelList to labelList & {"I ndalur", "I-pause", "In pausa", "In pause", ("In p" & (character id 224) & "usa")}
    set labelList to labelList & {("In p" & (character id 246) & "sa"), "Inqumamile"}
    set labelList to labelList & {("Misu " & (character id 8217) & "n pausa"), "mombytapyre", "Ocung woko", "Oedi"}
    set labelList to labelList & {"On haud the noo", "Pausad", "Pausada", "Pausado", "Pausate", "Pausatuta", "Pause"}
    set labelList to labelList & {"Paused", "Pausiert", "Paussa", "Pauza qilingan", "Pauzearre", "Pauzirano"}
    set labelList to labelList & {("Pa" & (character id 365) & "zigita"), "Peatatud", "Pobieranie wstrzymane", "Pozastaveno"}
    set labelList to labelList & {("Pozastaven" & (character id 233)), "Pristabdytas", ("Pus pe pauz" & (character id 259))}
    set labelList to labelList & {("Pys" & (character id 228) & "ytetty"), ("Sat p" & (character id 229) & " pause")}
    set labelList to labelList & {("Saxlan" & (character id 305) & "ld" & (character id 305)), "Spauzowane"}
    set labelList to labelList & {("Sz" & (character id 252) & "netel"), "Taxaw", "Wagtend", "Ye pausau", "Zastajeny"}
    set labelList to labelList & {"Zastajony", "Zaustavljeno", ("Za" & (character id 269) & "asno ustavljeno")}
    set labelList to labelList & {((character id 205) & " bi" & (character id 240))}
    set labelList to labelList & {((character id 272) & (character id 227) & " t" & (character id 7841) & "m d" & (character id 7915) & "ng")}
    set labelList to labelList & {((character id 931) & (character id 949) & " " & (character id 960) & (character id 945) & (character id 973) & (character id 963) & (character id 951))}
    set labelList to labelList & {((character id 1040) & (character id 1103) & (character id 1083) & (character id 1076) & (character id 1072) & (character id 1090) & (character id 1099) & (character id 1083) & (character id 1171) & (character id 1072) & (character id 1085))}
    set labelList to labelList & {((character id 1053) & (character id 1072) & " " & (character id 1087) & (character id 1072) & (character id 1091) & (character id 1079) & (character id 1072))}
    set labelList to labelList & {((character id 1055) & (character id 1072) & (character id 1091) & (character id 1079) & (character id 1080) & (character id 1088) & (character id 1072) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1080) & (character id 1079) & (character id 1091) & (character id 1087) & (character id 1080) & (character id 1085) & (character id 1077) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1080) & (character id 1086) & (character id 1089) & (character id 1090) & (character id 1072) & (character id 1085) & (character id 1086) & (character id 1074) & (character id 1083) & (character id 1077) & (character id 1085) & (character id 1072))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1099) & (character id 1087) & (character id 1099) & (character id 1085) & (character id 1077) & (character id 1085) & (character id 1072))}
    set labelList to labelList & {((character id 1058) & (character id 1072) & (character id 1074) & (character id 1072) & (character id 1179) & (character id 1179) & (character id 1091) & (character id 1092) & " " & (character id 1082) & (character id 1072) & (character id 1088) & (character id 1076) & (character id 1072) & " " & (character id 1096) & (character id 1091) & (character id 1076))}
    set labelList to labelList & {((character id 1332) & (character id 1377) & (character id 1380) & (character id 1377) & (character id 1408))}
    set labelList to labelList & {((character id 1332) & (character id 1377) & (character id 1380) & (character id 1377) & (character id 1408) & (character id 1387) & " " & (character id 1396) & (character id 1381) & (character id 1403))}
    set labelList to labelList & {((character id 1502) & (character id 1493) & (character id 1513) & (character id 1492) & (character id 1492))}
    set labelList to labelList & {((character id 1571) & (character id 1615) & (character id 1604) & (character id 1576) & (character id 1616) & (character id 1579))}
    set labelList to labelList & {((character id 1578) & (character id 1608) & (character id 1602) & (character id 1601) & " " & (character id 1705) & (character id 1585) & (character id 1583) & (character id 1729))}
    set labelList to labelList & {((character id 1585) & (character id 1705) & (character id 1740) & (character id 1575))}
    set labelList to labelList & {((character id 1604) & (character id 1749) & " " & (character id 1608) & (character id 1670) & (character id 1575) & (character id 1606) & (character id 1583) & (character id 1575) & (character id 1740) & (character id 1749))}
    set labelList to labelList & {((character id 1605) & (character id 1705) & (character id 1579))}
    set labelList to labelList & {((character id 1608) & (character id 1575) & (character id 1676) & (character id 1575) & (character id 1588) & (character id 1578) & (character id 1606))}
    set labelList to labelList & {((character id 2341) & (character id 2366) & (character id 2306) & (character id 2348) & (character id 2354) & (character id 2375))}
    set labelList to labelList & {((character id 2341) & (character id 2366) & (character id 2342) & "'" & (character id 2361) & (character id 2379) & (character id 2348) & (character id 2366) & (character id 2351))}
    set labelList to labelList & {((character id 2352) & (character id 2369) & (character id 2325) & (character id 2366) & " " & (character id 2361) & (character id 2369) & (character id 2310) & (character id 8204))}
    set labelList to labelList & {((character id 2352) & (character id 2379) & (character id 2325) & (character id 2367) & (character id 2319) & (character id 2325) & (character id 2379))}
    set labelList to labelList & {((character id 2488) & (character id 2509) & (character id 2469) & (character id 2455) & (character id 2495) & (character id 2468) & " " & (character id 2453) & (character id 2480) & (character id 2494) & " " & (character id 2489) & (character id 2527) & (character id 2503) & (character id 2459) & (character id 2503))}
    set labelList to labelList & {((character id 2613) & (character id 2623) & (character id 2608) & (character id 2622) & (character id 2606) & " " & (character id 2617) & (character id 2632))}
    set labelList to labelList & {((character id 2693) & (character id 2719) & (character id 2709) & (character id 2750) & (character id 2741) & (character id 2759) & (character id 2738))}
    set labelList to labelList & {((character id 2951) & (character id 2975) & (character id 3016) & (character id 2984) & (character id 3007) & (character id 2993) & (character id 3009) & (character id 2980) & (character id 3021) & (character id 2980) & (character id 2986) & (character id 3021) & (character id 2986) & (character id 2975) & (character id 3021) & (character id 2975) & (character id 2980) & (character id 3009))}
    set labelList to labelList & {((character id 3112) & (character id 3135) & (character id 3122) & (character id 3137) & (character id 3114) & (character id 3116) & (character id 3105) & (character id 3135) & (character id 3074) & (character id 3110) & (character id 3135))}
    set labelList to labelList & {((character id 3253) & (character id 3263) & (character id 3248) & (character id 3246) & (character id 3263) & (character id 3256) & (character id 3250) & (character id 3262) & (character id 3223) & (character id 3263) & (character id 3238) & (character id 3270))}
    set labelList to labelList & {((character id 3364) & (character id 3378) & (character id 3405) & (character id 8205) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3390) & (character id 3378) & (character id 3364) & (character id 3405) & (character id 3364) & (character id 3399) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3405) & " " & (character id 3368) & (character id 3391) & (character id 3376) & (character id 3405) & (character id 8205) & (character id 3364) & (character id 3405) & (character id 3364) & (character id 3391) & (character id 3375) & (character id 3391) & (character id 3376) & (character id 3391) & (character id 3375) & (character id 3405) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3368) & (character id 3405) & (character id 3368) & (character id 3393))}
    set labelList to labelList & {((character id 3520) & (character id 3538) & (character id 3515) & (character id 3535) & (character id 3512) & (character id 3514) & (character id 3482) & (character id 3538))}
    set labelList to labelList & {((character id 3627) & (character id 3618) & (character id 3640) & (character id 3604) & (character id 3594) & (character id 3633) & (character id 3656) & (character id 3623) & (character id 3588) & (character id 3619) & (character id 3634) & (character id 3623) & (character id 3629) & (character id 3618) & (character id 3641) & (character id 3656))}
    set labelList to labelList & {((character id 3746) & (character id 3768) & (character id 3732) & (character id 3722) & (character id 3771) & (character id 3784) & (character id 3751) & (character id 3716) & (character id 3762) & (character id 3751))}
    set labelList to labelList & {((character id 3926) & (character id 3904) & (character id 3906) & (character id 3851) & (character id 3930) & (character id 3938))}
    set labelList to labelList & {((character id 4097) & (character id 4145) & (character id 4112) & (character id 4153) & (character id 4112) & (character id 4123) & (character id 4117) & (character id 4154) & (character id 4113) & (character id 4140) & (character id 4152) & (character id 4126) & (character id 4106) & (character id 4154))}
    set labelList to labelList & {((character id 4328) & (character id 4308) & (character id 4329) & (character id 4308) & (character id 4320) & (character id 4308) & (character id 4305) & (character id 4323) & (character id 4314) & (character id 4312))}
    set labelList to labelList & {((character id 6036) & (character id 6070) & (character id 6035) & (character id 8203) & (character id 6037) & (character id 6098) & (character id 6050) & (character id 6070) & (character id 6016))}
    set labelList to labelList & {((character id 7259) & (character id 7268) & (character id 7261) & (character id 7260) & (character id 7273) & " " & (character id 7262) & (character id 7278) & (character id 7281) & (character id 7263))}
    set labelList to labelList & {((character id 20013) & (character id 26029) & (character id 12375) & (character id 12390) & (character id 12356) & (character id 12414) & (character id 12377))}
    set labelList to labelList & {((character id 24050) & (character id 26242) & (character id 20572))}
    set labelList to labelList & {((character id 24050) & (character id 26283) & (character id 20572))}
    set labelList to labelList & {((character id 51068) & (character id 49884) & " " & (character id 51473) & (character id 51648) & (character id 46120))}
    return labelList
end pausedWords

on failedWords()
    -- Firefox's word for a failed download (stateFailed), in every language.
    set labelList to {}
    set labelList to labelList & {("A ka" & (character id 331)), "Ayiphumelelanga"}
    set labelList to labelList & {("Ba" & (character id 351) & "ar" & (character id 305) & "s" & (character id 305) & "z oldu")}
    set labelList to labelList & {("Betg reuss" & (character id 236)), "C'hwitet warni"}
    set labelList to labelList & {("Dh'fh" & (character id 224) & "illig e"), "Didnae wirk"}
    set labelList to labelList & {("D" & (character id 235) & "shtoi"), ("Eba" & (character id 245) & "nnestus")}
    set labelList to labelList & {("Ep" & (character id 228) & "onnistui"), ("E" & (character id 537) & "uat"), "Faddina"}
    set labelList to labelList & {"Failed", "Falhou", "Falio", "Fallido", "Fallite", "Fallou", "Fallutu"}
    set labelList to labelList & {("Fall" & (character id 243)), ("Fal" & (character id 238) & "t"), "Fehlgeschlagen"}
    set labelList to labelList & {("Frac" & (character id 224) & "s"), "Gagal", "Gire'ej", "Ha fallat", "Ha fallau"}
    set labelList to labelList & {"Het misluk", "Huts egin du", "Javypyre", "Lajj na", "Malsukcesa"}
    set labelList to labelList & {("Man " & (character id 252) & "tz ta xub'" & (character id 228) & "n"), "Methiant"}
    set labelList to labelList & {"Mislearre", "Mislukt", "Mislykka", "Mislykket", "Misslyckad"}
    set labelList to labelList & {("Mist" & (character id 243) & "kst"), "Muvaffaqiyatsiz yakunlandi", "Nabigo", "Naizadeve"}
    set labelList to labelList & {("Neizdev" & (character id 257) & "s"), "Nepavyko", ("Neuspe" & (character id 353) & "no")}
    set labelList to labelList & {("Neuspje" & (character id 353) & "no")}
    set labelList to labelList & {("Ne" & (character id 250) & "spe" & (character id 353) & "n" & (character id 233))}
    set labelList to labelList & {"Nije uspjelo", ("Niy podarzi" & (character id 322) & "o sie")}
    set labelList to labelList & {("Njeporad" & (character id 378) & "i" & (character id 322) & "o")}
    set labelList to labelList & {("Njera" & (character id 378) & "ony"), "Non riuscito", "Opoto"}
    set labelList to labelList & {("Pobranie si" & (character id 281) & " nie powiod" & (character id 322) & "o"), "Selhalo"}
    set labelList to labelList & {"Sikertelen", "Teipthe", ("Th" & (character id 7845) & "t b" & (character id 7841) & "i")}
    set labelList to labelList & {"Ur yeddi ara", ("U" & (character id 287) & "ursuz oldu"), "Woorii"}
    set labelList to labelList & {((character id 201) & "chec")}
    set labelList to labelList & {((character id 913) & (character id 960) & (character id 941) & (character id 964) & (character id 965) & (character id 967) & (character id 949))}
    set labelList to labelList & {((character id 1048) & (character id 1207) & (character id 1088) & (character id 1086) & " " & (character id 1085) & (character id 1072) & (character id 1096) & (character id 1091) & (character id 1076))}
    set labelList to labelList & {((character id 1053) & (character id 1077) & " " & (character id 1091) & (character id 1076) & (character id 1072) & (character id 1083) & (character id 1072) & (character id 1089) & (character id 1100))}
    set labelList to labelList & {((character id 1053) & (character id 1077) & (character id 1074) & (character id 1076) & (character id 1072) & (character id 1095) & (character id 1072))}
    set labelList to labelList & {((character id 1053) & (character id 1077) & (character id 1091) & (character id 1089) & (character id 1087) & (character id 1077) & (character id 1083) & (character id 1086))}
    set labelList to labelList & {((character id 1053) & (character id 1077) & (character id 1091) & (character id 1089) & (character id 1087) & (character id 1077) & (character id 1096) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1053) & (character id 1103) & (character id 1118) & (character id 1076) & (character id 1072) & (character id 1095) & (character id 1072))}
    set labelList to labelList & {((character id 1178) & (character id 1072) & (character id 1090) & (character id 1077))}
    set labelList to labelList & {((character id 1345) & (character id 1377) & (character id 1389) & (character id 1400) & (character id 1394) & (character id 1400) & (character id 1410) & (character id 1396))}
    set labelList to labelList & {((character id 1353) & (character id 1387) & " " & (character id 1397) & (character id 1377) & (character id 1403) & (character id 1400) & (character id 1394) & (character id 1400) & (character id 1410) & (character id 1381) & (character id 1388))}
    set labelList to labelList & {((character id 1499) & (character id 1513) & (character id 1500) & (character id 1493) & (character id 1503))}
    set labelList to labelList & {((character id 1587) & (character id 1749) & (character id 1585) & (character id 1705) & (character id 1749) & (character id 1608) & (character id 1578) & (character id 1608) & (character id 1608) & " " & (character id 1606) & (character id 1749) & (character id 1576) & (character id 1608) & (character id 1608))}
    set labelList to labelList & {((character id 1588) & (character id 1705) & (character id 1587) & (character id 1578) & " " & (character id 1582) & (character id 1585) & (character id 1583))}
    set labelList to labelList & {((character id 1588) & (character id 1705) & (character id 1587) & (character id 1578) & " " & (character id 1582) & (character id 1608) & (character id 1585) & (character id 1583))}
    set labelList to labelList & {((character id 1601) & (character id 1588) & (character id 1604))}
    set labelList to labelList & {((character id 1606) & (character id 1575) & (character id 1705) & (character id 1575) & (character id 1605))}
    set labelList to labelList & {((character id 2309) & (character id 2346) & (character id 2351) & (character id 2358) & (character id 2368))}
    set labelList to labelList & {((character id 2309) & (character id 2360) & (character id 2347) & (character id 2354) & " " & (character id 2349) & (character id 2351) & (character id 2379))}
    set labelList to labelList & {((character id 2347) & (character id 2375) & (character id 2354) & (character id 2375) & (character id 2306) & " " & (character id 2332) & (character id 2366) & (character id 2348) & (character id 2366) & (character id 2351))}
    set labelList to labelList & {((character id 2357) & (character id 2367) & (character id 2347) & (character id 2354) & (character id 8204))}
    set labelList to labelList & {((character id 2476) & (character id 2509) & (character id 2479) & (character id 2480) & (character id 2509) & (character id 2469))}
    set labelList to labelList & {((character id 2603) & (character id 2631) & (character id 2610) & (character id 2637) & (character id 2617) & " " & (character id 2617) & (character id 2632))}
    set labelList to labelList & {((character id 2728) & (character id 2751) & (character id 2743) & (character id 2765) & (character id 2731) & (character id 2739))}
    set labelList to labelList & {((character id 2980) & (character id 3019) & (character id 2994) & (character id 3021) & (character id 2997) & (character id 3007) & (character id 2991) & (character id 3009) & (character id 2993) & (character id 3021) & (character id 2993) & (character id 2980) & (character id 3009))}
    set labelList to labelList & {((character id 3125) & (character id 3135) & (character id 3115) & (character id 3122) & (character id 3118) & (character id 3144) & (character id 3074) & (character id 3110) & (character id 3135))}
    set labelList to labelList & {((character id 3253) & (character id 3263) & (character id 3243) & (character id 3250) & (character id 3223) & (character id 3274) & (character id 3202) & (character id 3233) & (character id 3263) & (character id 3238) & (character id 3270))}
    set labelList to labelList & {((character id 3370) & (character id 3376) & (character id 3390) & (character id 3356) & (character id 3375) & (character id 3370) & (character id 3405) & (character id 3370) & (character id 3398) & (character id 3359) & (character id 3405) & (character id 3359) & (character id 3393))}
    set labelList to labelList & {((character id 3461) & (character id 3523) & (character id 3512) & (character id 3501) & (character id 3530) & " " & (character id 3520) & (character id 3538) & (character id 3514))}
    set labelList to labelList & {((character id 3621) & (character id 3657) & (character id 3617) & (character id 3648) & (character id 3627) & (character id 3621) & (character id 3623))}
    set labelList to labelList & {((character id 3749) & (character id 3771) & (character id 3785) & (character id 3745) & (character id 3776) & (character id 3755) & (character id 3749) & (character id 3751))}
    set labelList to labelList & {((character id 3939) & (character id 3962) & (character id 3923) & (character id 3851) & (character id 3928) & (character id 3851) & (character id 3920) & (character id 3956) & (character id 3926) & (character id 3851) & (character id 3924))}
    set labelList to labelList & {((character id 4121) & (character id 4129) & (character id 4145) & (character id 4140) & (character id 4100) & (character id 4154) & (character id 4121) & (character id 4156) & (character id 4100) & (character id 4154) & (character id 4117) & (character id 4139))}
    set labelList to labelList & {((character id 4329) & (character id 4304) & (character id 4328) & (character id 4314) & (character id 4312) & (character id 4314) & (character id 4312))}
    set labelList to labelList & {((character id 6036) & (character id 6070) & (character id 6035) & (character id 8203) & (character id 6036) & (character id 6042) & (character id 6070) & (character id 6023) & (character id 6096) & (character id 6041))}
    set labelList to labelList & {((character id 7280) & (character id 7268) & (character id 7260) & (character id 7263) & (character id 7289) & (character id 7267) & (character id 7278) & (character id 7281) & (character id 7263))}
    set labelList to labelList & {((character id 22833) & (character id 25943))}
    set labelList to labelList & {((character id 22833) & (character id 25943) & (character id 12375) & (character id 12414) & (character id 12375) & (character id 12383))}
    set labelList to labelList & {((character id 22833) & (character id 36133))}
    set labelList to labelList & {((character id 49892) & (character id 54056) & (character id 54632))}
    return labelList
end failedWords

on canceledWords()
    -- Firefox's word for a canceled download (stateCanceled), in every language.
    set labelList to {}
    set labelList to labelList & {("A na" & (character id 331) & "andi"), "Abgebrochen", "Air a sgur dheth", "Annulearre"}
    set labelList to labelList & {"Annulladu", "Annullato", "Annulleret", ("Annul" & (character id 233)), "Anulat"}
    set labelList to labelList & {"Anullat", ("Anul" & (character id 226) & "t"), "Atcalta", "Atcelta", "Atsisakyta"}
    set labelList to labelList & {"Avbrote", "Avbruten", "Avbrutt", "Bekor qilingan", "Cancelada", "Cancelado", "Canceled"}
    set labelList to labelList & {"Cancellate", "Cancelled", "Cealaithe", "Dibatalkan", "Diddymwyd"}
    set labelList to labelList & {("Encabox" & (character id 243) & "se"), "Geannuleerd", "Gekanselleer", "Haaytinaama"}
    set labelList to labelList & {"Hejapyre", ("H" & (character id 230) & "tt vi" & (character id 240)), "Ifsex", "Interrut"}
    set labelList to labelList & {"Irhoxisiwe", ((character id 304) & "ptal edildi"), "Katkestatud", "Kijuko woko"}
    set labelList to labelList & {"Kinansela", ("L" & (character id 601) & (character id 287) & "v Edildi")}
    set labelList to labelList & {("Megszak" & (character id 237) & "tva"), "Neenalu na", "Nga dure'", "Ntu nkuvi-ka"}
    set labelList to labelList & {"Nuligita", "Nullet", "Obustavljeno", "Peruutettu", "Pobieranie anulowane", "Pociepane"}
    set labelList to labelList & {"Prekinuto", "Preklicano", ("P" & (character id 345) & "etorhnjeny")}
    set labelList to labelList & {("P" & (character id 347) & "etergnjony"), "S'ha cancelau"}
    set labelList to labelList & {("S'ha cancel" & (character id 183) & "lat"), "Scancelou", "Sfallutu", "Stappit"}
    set labelList to labelList & {"U anulua", "Utzita", ("Zru" & (character id 353) & "eno")}
    set labelList to labelList & {("Zru" & (character id 353) & "en" & (character id 233))}
    set labelList to labelList & {((character id 272) & (character id 227) & " h" & (character id 7911) & "y")}
    set labelList to labelList & {((character id 913) & (character id 954) & (character id 965) & (character id 961) & (character id 974) & (character id 952) & (character id 951) & (character id 954) & (character id 949))}
    set labelList to labelList & {((character id 1041) & (character id 1077) & (character id 1082) & (character id 1086) & (character id 1088) & " " & (character id 1082) & (character id 1072) & (character id 1088) & (character id 1076) & (character id 1072) & " " & (character id 1096) & (character id 1091) & (character id 1076))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1082) & (character id 1072) & (character id 1078) & (character id 1072) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1082) & (character id 1072) & (character id 1079) & (character id 1072) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1054) & (character id 1090) & (character id 1084) & (character id 1077) & (character id 1085) & (character id 1077) & (character id 1085) & (character id 1072))}
    set labelList to labelList & {((character id 1055) & (character id 1088) & (character id 1077) & (character id 1082) & (character id 1098) & (character id 1089) & (character id 1085) & (character id 1072) & (character id 1090) & (character id 1086))}
    set labelList to labelList & {((character id 1057) & (character id 1082) & (character id 1072) & (character id 1089) & (character id 1072) & (character id 1074) & (character id 1072) & (character id 1085) & (character id 1072))}
    set labelList to labelList & {((character id 1057) & (character id 1082) & (character id 1072) & (character id 1089) & (character id 1086) & (character id 1074) & (character id 1072) & (character id 1085) & (character id 1086))}
    set labelList to labelList & {((character id 1058) & (character id 1086) & (character id 1179) & (character id 1090) & (character id 1072) & (character id 1090) & (character id 1099) & (character id 1083) & (character id 1076) & (character id 1099))}
    set labelList to labelList & {((character id 1353) & (character id 1381) & (character id 1394) & (character id 1377) & (character id 1408) & (character id 1391) & (character id 1377) & (character id 1390))}
    set labelList to labelList & {((character id 1353) & (character id 1381) & (character id 1394) & (character id 1377) & (character id 1408) & (character id 1391) & (character id 1406) & (character id 1377) & (character id 1390))}
    set labelList to labelList & {((character id 1489) & (character id 1493) & (character id 1496) & (character id 1500))}
    set labelList to labelList & {((character id 1571) & (character id 1615) & (character id 1604) & (character id 1594) & (character id 1616) & (character id 1610) & (character id 1614))}
    set labelList to labelList & {((character id 1604) & (character id 1594) & (character id 1608) & " " & (character id 1588) & (character id 1583) & (character id 1607))}
    set labelList to labelList & {((character id 1604) & (character id 1602) & (character id 1608) & " " & (character id 1608) & (character id 1575) & (character id 1576) & (character id 1740) & (character id 1676) & (character id 1607))}
    set labelList to labelList & {((character id 1605) & (character id 1606) & (character id 1587) & (character id 1608) & (character id 1582) & " " & (character id 1578) & (character id 1726) & (character id 1740) & (character id 1575))}
    set labelList to labelList & {((character id 1605) & (character id 1606) & (character id 1587) & (character id 1608) & (character id 1582) & " " & (character id 1588) & (character id 1583) & (character id 1729))}
    set labelList to labelList & {((character id 1607) & (character id 1749) & (character id 1717) & (character id 1608) & (character id 1749) & (character id 1588) & (character id 1742) & (character id 1606) & (character id 1585) & (character id 1575) & (character id 1740) & (character id 1749) & (character id 1608) & (character id 1749))}
    set labelList to labelList & {((character id 2348) & (character id 2366) & (character id 2340) & (character id 2367) & (character id 2354) & " " & (character id 2326) & (character id 2366) & (character id 2354) & (character id 2366) & (character id 2350) & (character id 2348) & (character id 2366) & (character id 2351))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2325) & (character id 2375) & (character id 2354) & (character id 2375))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & " " & (character id 2327) & (character id 2352) & (character id 2367) & (character id 2351) & (character id 2379))}
    set labelList to labelList & {((character id 2352) & (character id 2342) & (character id 2381) & (character id 2342) & (character id 8204))}
    set labelList to labelList & {((character id 2476) & (character id 2494) & (character id 2468) & (character id 2495) & (character id 2482) & " " & (character id 2453) & (character id 2480) & (character id 2494) & " " & (character id 2489) & (character id 2527) & (character id 2503) & (character id 2459) & (character id 2503))}
    set labelList to labelList & {((character id 2608) & (character id 2673) & (character id 2598) & " " & (character id 2581) & (character id 2624) & (character id 2596) & (character id 2622))}
    set labelList to labelList & {((character id 2736) & (character id 2726) & " " & (character id 2725) & (character id 2735) & (character id 2759) & (character id 2738) & " " & (character id 2715) & (character id 2759))}
    set labelList to labelList & {((character id 2992) & (character id 2980) & (character id 3021) & (character id 2980) & (character id 3009) & " " & (character id 2970) & (character id 3014) & (character id 2991) & (character id 3021) & (character id 2991) & (character id 2986) & (character id 3021) & (character id 2986) & (character id 2975) & (character id 3021) & (character id 2975) & (character id 2980) & (character id 3009))}
    set labelList to labelList & {((character id 3120) & (character id 3110) & (character id 3149) & (character id 3110) & (character id 3137) & " " & (character id 3098) & (character id 3143) & (character id 3119) & (character id 3116) & (character id 3105) & (character id 3135) & (character id 3112) & (character id 3110) & (character id 3135))}
    set labelList to labelList & {((character id 3248) & (character id 3238) & (character id 3277) & (character id 3238) & (character id 3265) & (character id 3223) & (character id 3274) & (character id 3251) & (character id 3263) & (character id 3256) & (character id 3250) & (character id 3262) & (character id 3223) & (character id 3263) & (character id 3238) & (character id 3270))}
    set labelList to labelList & {((character id 3377) & (character id 3366) & (character id 3405) & (character id 3366) & (character id 3390) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3391) & (character id 3375) & (character id 3391) & (character id 3376) & (character id 3391) & (character id 3375) & (character id 3405) & (character id 3349) & (character id 3405) & (character id 3349) & (character id 3393) & (character id 3368) & (character id 3405) & (character id 3368) & (character id 3393))}
    set labelList to labelList & {((character id 3461) & (character id 3520) & (character id 3517) & (character id 3458) & (character id 3484) & (character id 3540) & " " & (character id 3482) & (character id 3545) & (character id 3515) & (character id 3538) & (character id 3499) & (character id 3538))}
    set labelList to labelList & {((character id 3618) & (character id 3585) & (character id 3648) & (character id 3621) & (character id 3636) & (character id 3585) & (character id 3649) & (character id 3621) & (character id 3657) & (character id 3623))}
    set labelList to labelList & {((character id 3725) & (character id 3771) & (character id 3713) & (character id 3776) & (character id 3749) & (character id 3765) & (character id 3713) & (character id 3777) & (character id 3749) & (character id 3785) & (character id 3751))}
    set labelList to labelList & {((character id 3925) & (character id 4017) & (character id 3954) & (character id 3938) & (character id 3851) & (character id 3936) & (character id 3920) & (character id 3962) & (character id 3923) & (character id 3851) & (character id 3926) & (character id 4017) & (character id 3942) & (character id 3851) & (character id 3935) & (character id 3954) & (character id 3923))}
    set labelList to labelList & {((character id 4118) & (character id 4155) & (character id 4096) & (character id 4154) & (character id 4126) & (character id 4141) & (character id 4121) & (character id 4154) & (character id 4152) & (character id 4113) & (character id 4140) & (character id 4152) & (character id 4126) & (character id 4106) & (character id 4154))}
    set labelList to labelList & {((character id 4306) & (character id 4304) & (character id 4323) & (character id 4325) & (character id 4315) & (character id 4308) & (character id 4305) & (character id 4323) & (character id 4314) & (character id 4312))}
    set labelList to labelList & {((character id 6036) & (character id 6070) & (character id 6035) & (character id 8203) & (character id 6036) & (character id 6084) & (character id 6087) & (character id 6036) & (character id 6020) & (character id 6091))}
    set labelList to labelList & {((character id 7285) & (character id 7263) & (character id 7289) & (character id 7280) & (character id 7272) & (character id 7263) & (character id 7289) & " " & (character id 7278) & (character id 7281) & (character id 7263))}
    set labelList to labelList & {((character id 12461) & (character id 12515) & (character id 12531) & (character id 12475) & (character id 12523) & (character id 12373) & (character id 12428) & (character id 12414) & (character id 12375) & (character id 12383))}
    set labelList to labelList & {((character id 24050) & (character id 21462) & (character id 28040))}
    set labelList to labelList & {((character id 52712) & (character id 49548) & (character id 46120))}
    return labelList
end canceledWords

-- ------------------------------------------------------------- shared: which row

on nameEnd(rowTitle, nameVariants)
    -- Length of the file name this row title starts with, or 0. A title
    -- reads "<file name> <status> <button label>", so the name must be
    -- there character for character (see sameText) and be followed by a
    -- space (or end the title): a row for "report.pdf.zip" is not a row for
    -- "report.pdf".
    set titleLen to length of rowTitle
    repeat with v in nameVariants
        set oneName to (contents of v) as string
        set nameLen to length of oneName
        if nameLen > 0 and not (titleLen < nameLen) then
            set samePrefix to my sameText(text 1 thru nameLen of rowTitle, oneName)
            if samePrefix then
                if titleLen is nameLen then return nameLen
                if (id of (character (nameLen + 1) of rowTitle)) is in {32, 9, 10, 13, 160, 8194, 8195, 8201, 8239} then return nameLen
            end if
        end if
    end repeat
    return 0
end nameEnd

on rowIsForName(rowTitle, nameVariants)
    return (my nameEnd(rowTitle, nameVariants)) > 0
end rowIsForName

-- ------------------------------------------------------------- shared: a name the panel shows shortened

-- Where the whole name was found on the row namesForRow last looked at:
-- {child} or {child, grandchild} of the row; {} when its title has the full
-- name (nothing more to read).
property wholeNameSpot : {}
-- ...and the file's own names it was compared with.
property wholeNameList : {}
-- A note for the log when a row looked like this name shortened but its
-- whole name wasn't found ("" otherwise).
property shortNote : ""

on sameText(textA, textB)
    -- The same characters, one for one. (AppleScript's own "is" takes some
    -- different texts for equal: it skips invisible characters, and sees a
    -- fullwidth letter as the plain one.)
    if (length of textA) is not (length of textB) then return false
    if (length of textA) is 0 then return true
    return (id of textA) is (id of textB)
end sameText

on shortenedEnd(rowTitle, wholeName)
    -- The panel shortens a long file name in the middle: the beginning of
    -- the name, one ellipsis character, the end of the name. Returns where
    -- such a shortened name ends in the title, or 0: the title must start
    -- with the beginning of wholeName (the same characters), then the
    -- ellipsis, then the end of wholeName, followed by a space (or by
    -- nothing).
    set titleLen to length of rowTitle
    set nameLen to length of wholeName
    set cutPos to offset of (character id 8230) in rowTitle
    if cutPos < 2 then return 0
    set headLen to cutPos - 1
    if not (headLen < nameLen) then return 0
    if not (my sameText(text 1 thru headLen of rowTitle, text 1 thru headLen of wholeName)) then return 0
    set tailMax to nameLen - headLen - 1
    if tailMax > (titleLen - cutPos) then set tailMax to (titleLen - cutPos)
    repeat with tailLen from tailMax to 1 by -1
        set lastPos to cutPos + tailLen
        if my sameText(text (cutPos + 1) thru lastPos of rowTitle, text (nameLen - tailLen + 1) thru nameLen of wholeName) then
            if lastPos is titleLen then return lastPos
            if (id of (character (lastPos + 1) of rowTitle)) is in {32, 9, 10, 13, 160, 8194, 8195, 8201, 8239} then return lastPos
        end if
    end repeat
    return 0
end shortenedEnd

on helpsOf(listRef, rowIdx, childIdx)
    -- The help texts (the tooltips) of a row's elements (childIdx 0), or of
    -- the elements inside its childIdx-th element, in order, as texts ("" for
    -- an element without one). One request, or one per element if that
    -- fails. Only read, nothing is pressed.
    set rawList to missing value
    set elemCount to 0
    tell application "System Events"
        try
            if childIdx is 0 then
                set elemCount to count of UI elements of UI element rowIdx of listRef
                if elemCount > 0 then set rawList to value of attribute "AXHelp" of every UI element of UI element rowIdx of listRef
            else
                set elemCount to count of UI elements of UI element childIdx of UI element rowIdx of listRef
                if elemCount > 0 then set rawList to value of attribute "AXHelp" of every UI element of UI element childIdx of UI element rowIdx of listRef
            end if
        end try
    end tell
    if rawList is not missing value then
        if (class of rawList) is not list then set rawList to {rawList}
        if (count of rawList) is not elemCount then set rawList to missing value
    end if
    set cleanList to {}
    repeat with elemIdx from 1 to elemCount
        set oneText to ""
        if rawList is missing value then
            if childIdx is 0 then
                set oneText to my helpTextAt(listRef, rowIdx, {elemIdx})
            else
                set oneText to my helpTextAt(listRef, rowIdx, {childIdx, elemIdx})
            end if
        else
            try
                set rawHelp to item elemIdx of rawList
                if rawHelp is not missing value then set oneText to rawHelp as string
            end try
        end if
        set end of cleanList to oneText
    end repeat
    return cleanList
end helpsOf

on helpTextAt(listRef, rowIdx, spot)
    -- The help text of one element of a row: its spot-th element ({child}),
    -- or an element inside that one ({child, grandchild}). "" when it has
    -- none. One request. Only read.
    set oneText to ""
    tell application "System Events"
        try
            if (count of spot) is 1 then
                set rawHelp to value of attribute "AXHelp" of UI element (item 1 of spot) of UI element rowIdx of listRef
            else
                set rawHelp to value of attribute "AXHelp" of UI element (item 2 of spot) of UI element (item 1 of spot) of UI element rowIdx of listRef
            end if
            if rawHelp is not missing value then set oneText to rawHelp as string
        end try
    end tell
    return oneText
end helpTextAt

on rowHelpTexts(listRef, rowIdx)
    -- {help texts, where each is}: every help text on a row's elements and
    -- on the elements inside those (the name label may sit one level down),
    -- with its spot (see helpTextAt). Only read.
    set foundTexts to {}
    set foundSpots to {}
    set childHelps to my helpsOf(listRef, rowIdx, 0)
    repeat with i from 1 to (count of childHelps)
        if (item i of childHelps) is not "" then
            set end of foundTexts to (item i of childHelps)
            set end of foundSpots to {i}
        end if
    end repeat
    repeat with i from 1 to (count of childHelps)
        set innerHelps to my helpsOf(listRef, rowIdx, i)
        repeat with j from 1 to (count of innerHelps)
            if (item j of innerHelps) is not "" then
                set end of foundTexts to (item j of innerHelps)
                set end of foundSpots to {i, j}
            end if
        end repeat
    end repeat
    return {foundTexts, foundSpots}
end rowHelpTexts

on shortNameFor(listRef, rowIdx, rowTitle, nameVariants)
    -- "" unless the row shows this file's name shortened. A name too long
    -- for the panel is shown shortened in the middle, and the row's title
    -- then has the shortened name; the whole name stays on the row's name
    -- label, as its help text (its tooltip). The row is this file's only
    -- when the title starts with the two ends of this file's name (see
    -- shortenedEnd) AND that whole name is exactly this file's, character
    -- for character. Returns the shortened name as the title has it, and
    -- remembers where the whole name was (wholeNameSpot).
    if rowTitle does not contain (character id 8230) then return ""
    set couldBe to false
    repeat with v in nameVariants
        if (my shortenedEnd(rowTitle, (contents of v) as string)) > 0 then set couldBe to true
    end repeat
    if not couldBe then return ""
    set helps to my rowHelpTexts(listRef, rowIdx)
    set helpTexts to item 1 of helps
    set helpSpots to item 2 of helps
    repeat with h from 1 to (count of helpTexts)
        set wholeName to item h of helpTexts
        repeat with v in nameVariants
            set oneName to (contents of v) as string
            if my sameText(wholeName, oneName) then
                set endPos to my shortenedEnd(rowTitle, oneName)
                if endPos > 0 then
                    set my wholeNameSpot to item h of helpSpots
                    return (text 1 thru endPos of rowTitle)
                end if
            end if
        end repeat
    end repeat
    set my shortNote to "row " & rowIdx & " looks like this name shortened, but its whole name isn't on it (help texts read: " & (count of helpTexts) & "); "
    return ""
end shortNameFor

on namesForRow(listRef, rowIdx, rowTitle, fileNames)
    -- What this row's title may start with: this file's name -- and, when
    -- the title has it shortened, that shortened name too, but only after
    -- the whole name on the row's name label was read, now, and is exactly
    -- this file's (see shortNameFor). A title that starts with the full
    -- name needs no extra read.
    set my wholeNameSpot to {}
    set my wholeNameList to fileNames
    set my shortNote to ""
    if my rowIsForName(rowTitle, fileNames) then return fileNames
    set shortName to my shortNameFor(listRef, rowIdx, rowTitle, fileNames)
    if shortName is "" then return fileNames
    return fileNames & {shortName}
end namesForRow

on wholeNameStill(listRef, rowIdx, nameList)
    -- For the row namesForRow just matched by its whole name: that name,
    -- read once more from the same label, must still be this file's,
    -- character for character. (True at once for a row whose title has the
    -- full name: there's nothing more to read.) Called last before a press
    -- or a menu, so that two files that look the same shortened can't be
    -- taken for one another when rows shift.
    if (count of (my wholeNameSpot)) is 0 then return true
    set wholeName to my helpTextAt(listRef, rowIdx, my wholeNameSpot)
    if wholeName is "" then return false
    repeat with v in nameList
        if my sameText(wholeName, (contents of v) as string) then return true
    end repeat
    return false
end wholeNameStill

on rowKind(rowTitle, nameVariants)
    -- "paused", "failed", "canceled" or "": the state the row shows right
    -- after the file name (Firefox's own word for it, in any language).
    set nameLen to my nameEnd(rowTitle, nameVariants)
    if nameLen is 0 then return ""
    if (length of rowTitle) < (nameLen + 2) then return ""
    return my statusKindOf(text (nameLen + 2) thru -1 of rowTitle)
end rowKind

on statusShape(rowTitle, nameVariants)
    -- For the log, when a row's state isn't recognised: how its status text
    -- (the title after the file name) begins, with every digit written 9
    -- and every letter a, so that neither a name nor a site shows
    -- ("99% aaaaaa - 9.9 aa"). "" when there's nothing to tell. Only read.
    set shapeText to ""
    try
        set nameLen to my nameEnd(rowTitle, nameVariants)
        if nameLen is 0 or (length of rowTitle) < (nameLen + 2) then return ""
        set statusText to text (nameLen + 2) thru -1 of rowTitle
        set lastPos to length of statusText
        if lastPos > 20 then set lastPos to 20
        repeat with pos from 1 to lastPos
            set charId to id of (character pos of statusText)
            if charId is in {48, 49, 50, 51, 52, 53, 54, 55, 56, 57} then
                set shapeText to shapeText & "9"
            else if charId is in {32, 160, 8194, 8195, 8201, 8239} then
                set shapeText to shapeText & " "
            else if charId is in {37, 44, 46, 58, 40, 41, 47} then
                set shapeText to shapeText & (character id charId)
            else if charId is in {45, 8211, 8212} then
                set shapeText to shapeText & "-"
            else
                set shapeText to shapeText & "a"
            end if
        end repeat
    on error
        return ""
    end try
    return shapeText
end statusShape

on wantsButton(actionMode, btnLabel)
    -- The row button an action goes by: Retry for retry and restart, Cancel
    -- otherwise. Downloading and paused rows have a Cancel button; a paused
    -- row's Resume is in its right-click menu, not on a button.
    if actionMode is "retry" or actionMode is "restart" then return my looksLikeRetry(btnLabel)
    return my looksLikeCancel(btnLabel)
end wantsButton

on pickRow(nameRows, candKinds, actionMode)
    -- Which candidate to act on: {"pick", n}, or {outcome, 0} when none.
    -- Candidates are the rows for this file that have the button the action
    -- goes by. Stop needs exactly one. Retry, Resume and restart take the
    -- one row showing the state they need (Failed; Paused; Canceled, or
    -- Failed when the browser deleted what it had). If Firefox's word for
    -- the state isn't recognised, a single candidate is used and the browser
    -- has the last word: only a failed or canceled row has a Retry button,
    -- and only a paused row has a Resume item in its menu.
    set candCount to count of candKinds
    if actionMode is "cancel" then
        if candCount is 1 then return {"pick", 1}
        if candCount > 1 then return {"ambiguous", 0}
    else
        set wantKinds to {"paused"}
        if actionMode is "retry" then set wantKinds to {"failed"}
        if actionMode is "restart" then set wantKinds to {"canceled", "failed"}
        set preferred to {}
        set unknownRows to {}
        repeat with i from 1 to candCount
            set oneKind to item i of candKinds
            if oneKind is not "" and wantKinds contains oneKind then set end of preferred to i
            if oneKind is "" then set end of unknownRows to i
        end repeat
        if (count of preferred) is 1 then return {"pick", item 1 of preferred}
        if (count of preferred) > 1 then return {"ambiguous", 0}
        if candCount is 1 and (count of unknownRows) is 1 then return {"pick", 1}
        if (count of unknownRows) > 1 then return {"ambiguous", 0}
    end if
    if nameRows > 0 then return {"not-active", 0}
    return {"no-match", 0}
end pickRow

on joinedTexts(textList)
    set joined to ""
    repeat with oneText in textList
        if joined is not "" then set joined to joined & ","
        set joined to joined & (contents of oneText)
    end repeat
    return joined
end joinedTexts

-- ------------------------------------------------------------- shared: Resume, from a row's right-click menu

-- The browser's process id, read before a row's menu is shown (reset at the
-- start of every run): the plugin needs it to find that menu.
property shownPid : ""

on rowFrame(listRef, rowIdx)
    -- "x,y,w,h": where the row is on screen, in points, or "" when its
    -- middle (where the browser clicks to open its menu) isn't inside the
    -- visible list (a click there could land outside the panel, in the
    -- page) or isn't inside the browser window (the browser sends that
    -- click to its window, and outside it no menu would open).
    set rowPos to missing value
    set rowDims to missing value
    set listPos to missing value
    set listDims to missing value
    tell application "System Events"
        try
            set rowPos to position of UI element rowIdx of listRef
            set rowDims to size of UI element rowIdx of listRef
            set listPos to position of listRef
            set listDims to size of listRef
        end try
    end tell
    if rowPos is missing value or rowDims is missing value or listPos is missing value or listDims is missing value then return ""
    try
        set rowX to (item 1 of rowPos) div 1
        set rowY to (item 2 of rowPos) div 1
        set rowW to (item 1 of rowDims) div 1
        set rowH to (item 2 of rowDims) div 1
        if rowW < 4 or rowH < 4 then return ""
        set midX to rowX + (rowW div 2)
        set midY to rowY + (rowH div 2)
        if midX < ((item 1 of listPos) + 2) or midY < ((item 2 of listPos) + 2) then return ""
        if midX > ((item 1 of listPos) + (item 1 of listDims) - 2) then return ""
        if midY > ((item 2 of listPos) + (item 2 of listDims) - 2) then return ""
        if not (my insideWindow(listRef, midX, midY)) then return ""
        return (rowX as string) & "," & (rowY as string) & "," & (rowW as string) & "," & (rowH as string)
    end try
    return ""
end rowFrame

on insideWindow(listRef, midX, midY)
    -- False only when the window the list belongs to can be read and the
    -- point is outside it.
    set winPos to missing value
    set winDims to missing value
    tell application "System Events"
        try
            set winEl to value of attribute "AXWindow" of listRef
            set winPos to position of winEl
            set winDims to size of winEl
        end try
    end tell
    if winPos is missing value or winDims is missing value then return true
    try
        if midX < ((item 1 of winPos) + 1) or midY < ((item 2 of winPos) + 1) then return false
        if midX > ((item 1 of winPos) + (item 1 of winDims) - 1) then return false
        if midY > ((item 2 of winPos) + (item 2 of winDims) - 1) then return false
    end try
    return true
end insideWindow

on notePid(procName)
    -- Read the browser's process id before its menu is shown (the plugin
    -- finds the menu by it). False if it can't be read: then no menu.
    set my shownPid to my pidText(procName)
    return (my shownPid) is not ""
end notePid

on showRowMenu(listRef, rowIdx, nameVariants, scanKind, frameText)
    -- Show the row's right-click menu, then make sure it is this row's: the
    -- browser selects the row it opens a menu for, and that row must still
    -- be this file's, in the same state. Choosing Resume in the menu is the
    -- plugin's job: it finds the menu where it opened (System Events can't
    -- be relied on to reach it), checks it and closes
    -- it untouched unless everything matches. Returns {outcome, trace, row
    -- frame}: "menu-shown", "menu-changed" or "show-error" (for these two the
    -- plugin only closes the menu, if there is one). notePid comes first.
    -- In case this run is cut short, where the menu opens goes to the log
    -- (stderr) first, so the plugin can still close it.
    log "menu-at|" & frameText & "|" & (my shownPid)
    set shownOk to false
    tell application "System Events"
        try
            perform action "AXShowMenu" of UI element rowIdx of listRef
            set shownOk to true
        end try
    end tell
    if not shownOk then return {"show-error", "showing the row's menu reported an error; ", frameText}
    set rowSelected to missing value
    set nowTitle to ""
    set readNote to ""
    tell application "System Events"
        try
            set rowSelected to value of attribute "AXSelected" of UI element rowIdx of listRef
        end try
        try
            set rawTitle to value of attribute "AXTitle" of UI element rowIdx of listRef
            if rawTitle is not missing value then set nowTitle to rawTitle as string
        end try
    end tell
    -- (A read that fails proves nothing either way: the row was checked
    -- just before, and the plugin checks the menu itself.)
    if rowSelected is false then return {"menu-changed", "the menu opened for another row; ", frameText}
    if nowTitle is not "" then
        if not (my rowIsForName(nowTitle, nameVariants)) then return {"menu-changed", "the row moved; ", frameText}
        if scanKind is not "" then
            set nowKind to my rowKind(nowTitle, nameVariants)
            if nowKind is "" then
                -- No state word in the title. The pointer came onto the row
                -- when its menu opened, and the browser then swaps the row's
                -- status label for another: the title may have been read
                -- between the two. It is read once more, a moment later;
                -- the row must still be the selected one, this file's, and
                -- show its state then. (The log says when this happened.)
                delay 0.1
                set laterSelected to missing value
                set laterTitle to ""
                tell application "System Events"
                    try
                        set laterSelected to value of attribute "AXSelected" of UI element rowIdx of listRef
                    end try
                    try
                        set rawLater to value of attribute "AXTitle" of UI element rowIdx of listRef
                        if rawLater is not missing value then set laterTitle to rawLater as string
                    end try
                end tell
                if laterSelected is false then return {"menu-changed", "the row's title had no state word after the menu, and at a second read the menu was another row's; ", frameText}
                if not (my rowIsForName(laterTitle, nameVariants)) then return {"menu-changed", "the row's title had no state word after the menu, and at a second read the row had moved; ", frameText}
                set nowKind to my rowKind(laterTitle, nameVariants)
                if nowKind is "" then return {"menu-changed", "the row's title had no state word after the menu, read twice; ", frameText}
                set readNote to "the row's title had no state word right after the menu, and had one at a second read; "
            end if
            if nowKind is not scanKind then return {"menu-changed", "the row changed; ", frameText}
        end if
    end if
    if not (my wholeNameStill(listRef, rowIdx, my wholeNameList)) then return {"menu-changed", "the row's file changed; ", frameText}
    return {"menu-shown", readNote & "row menu shown (selected=" & (rowSelected as string) & "); ", frameText}
end showRowMenu

on pidText(procName)
    -- The browser's process id, so the plugin can tell its menu apart.
    set pidValue to ""
    tell application "System Events"
        try
            set pidValue to (unix id of process procName) as string
        end try
    end tell
    return pidValue
end pidText

on rowTitleAt(panelList, rowIndex)
    set rowTitle to ""
    tell application "System Events"
        try
            set rawTitle to value of attribute "AXTitle" of UI element rowIndex of panelList
            if rawTitle is not missing value then set rowTitle to rawTitle as string
        end try
    end tell
    return rowTitle
end rowTitleAt

on rowButtonLabel(panelList, rowIndex, j)
    set btnLabel to ""
    tell application "System Events"
        try
            set rawLabel to value of attribute "AXDescription" of button j of UI element rowIndex of panelList
            if rawLabel is not missing value then set btnLabel to rawLabel as string
        end try
        if btnLabel is "" then
            try
                set rawLabel to value of attribute "AXTitle" of button j of UI element rowIndex of panelList
                if rawLabel is not missing value then set btnLabel to rawLabel as string
            end try
        end if
    end tell
    return btnLabel
end rowButtonLabel

on rowWantedButton(panelList, rowIndex, actionMode)
    -- Position of the row's button the action goes by (Cancel, or Retry
    -- for retry and restart), or 0 when it has none.
    set btnCount to 0
    tell application "System Events"
        try
            set btnCount to count of buttons of UI element rowIndex of panelList
        end try
    end tell
    repeat with j from 1 to btnCount
        if my wantsButton(actionMode, my rowButtonLabel(panelList, rowIndex, j)) then return j
    end repeat
    return 0
end rowWantedButton

on run argv
    -- The warm-up must never reach the code below.
    repeat with oneArg in argv
        if ((contents of oneArg) as string) is "mode:locate" then return "located|the fallback script does not warm up||||"
    end repeat
    set actionMode to "cancel"
    set fileNames to {}
    repeat with oneArg in argv
        set rawArg to (contents of oneArg) as string
        if rawArg is in {"mode:cancel", "mode:retry", "mode:resume", "mode:restart"} then set actionMode to (text 6 thru -1 of rawArg)
        if (length of rawArg) > 5 then
            if (text 1 thru 5 of rawArg) is "name:" then set end of fileNames to (text 6 thru -1 of rawArg)
        end if
    end repeat
    if (count of fileNames) is 0 then return "no-name|no file name was passed||||"
    set traceText to ""
    set my shownPid to ""

    set browserNames to {"firefox", "Firefox", "librewolf", "LibreWolf", "waterfox", "Waterfox", "Tor Browser", "palemoon", "Pale Moon"}
    set foundProcess to ""
    tell application "System Events"
        try
            repeat with pName in browserNames
                if exists (process pName) then
                    set foundProcess to (pName as string)
                    exit repeat
                end if
            end repeat
        on error errText number errNum
            if errNum is -1743 or errText contains "not authorized" then error "automation-denied: " & errText number errNum
            error errText number errNum
        end try
    end tell
    if foundProcess is "" then return "no-browser|no Firefox-family browser process found||||"
    set traceText to "browser=" & foundProcess & "; mode=" & actionMode & "; "

    -- Permission check: a missing Accessibility permission would otherwise
    -- look like a missing toolbar button. The marked error reaches the plugin.
    tell application "System Events"
        try
            set winCount to count of windows of process foundProcess
        on error errText number errNum
            if errNum is -1743 or errText contains "not authorized" then error "automation-denied: " & errText number errNum
            if errNum is -25211 or errNum is -1719 or errText contains "assistive" or errText contains "not allowed" then error "assistive-access-denied: " & errText number errNum
        end try
    end tell

    set dlButton to my findInWindows(foundProcess, "downloads-button", 5)
    if dlButton is missing value then return "no-button|" & traceText & "toolbar Downloads button not found|" & foundProcess & "|||"

    -- Open the panel unless it is already open.
    set openedPanel to false
    set panelEl to my findInWindows(foundProcess, "downloadsPanel", 4)
    if panelEl is missing value then
        if my domIdOf(dlButton) is not "downloads-button" then return "no-button|" & traceText & "toolbar changed before the press|" & foundProcess & "|||"
        if not (my pressElement(dlButton)) then return "no-panel|" & traceText & "pressing the Downloads button failed|" & foundProcess & "|||"
        set openedPanel to true
        repeat 10 times
            delay 0.2
            set panelEl to my findInWindows(foundProcess, "downloadsPanel", 4)
            if panelEl is not missing value then exit repeat
        end repeat
    end if
    if panelEl is missing value then return "no-panel|" & traceText & "panel did not appear|" & foundProcess & "|||"
    set traceText to traceText & "panel opened by script=" & openedPanel & "; "
    set panelList to my firstByDomId(panelEl, "downloadsListBox", 3)
    if panelList is missing value then return "no-panel|" & traceText & "list not found in panel|" & foundProcess & "|||"

    -- Rows are addressed by position: their titles change every second.
    set rowCount to 0
    tell application "System Events"
        try
            set rowCount to count of UI elements of panelList
        end try
    end tell
    set nameRows to 0
    set candRows to {}
    set candButtons to {}
    set candTitles to {}
    set candKinds to {}
    repeat with i from 1 to rowCount
        set scanTitle to my rowTitleAt(panelList, i)
        -- (a name the panel shows shortened counts only when the row's
        -- name label carries this file's whole name: see namesForRow)
        set rowNames to my namesForRow(panelList, i, scanTitle, fileNames)
        set traceText to traceText & (my shortNote)
        if my rowIsForName(scanTitle, rowNames) then
            set nameRows to nameRows + 1
            set j to my rowWantedButton(panelList, i, actionMode)
            if j > 0 then
                set end of candRows to i
                set end of candButtons to j
                set end of candTitles to scanTitle
                if actionMode is "cancel" then
                    set end of candKinds to ""
                else
                    set end of candKinds to my rowKind(scanTitle, rowNames)
                end if
            end if
        end if
    end repeat
    set traceText to traceText & "rows=" & rowCount & "; rows for this file=" & nameRows & "; with the button=" & (count of candRows) & "; "

    set picked to my pickRow(nameRows, candKinds, actionMode)
    set outcome to item 1 of picked
    set frameText to ""
    if outcome is "pick" then
        set n to item 2 of picked
        set rowIndex to item n of candRows
        set j to item n of candButtons
        set scanKind to item n of candKinds
        set outcome to "changed"
        -- For Resume, where the row is comes first, so that the last check
        -- of the row comes right before its menu is shown.
        set rowPlace to "-"
        if actionMode is "resume" then set rowPlace to my rowFrame(panelList, rowIndex)
        if rowPlace is "" then
            set outcome to "row-hidden"
            set traceText to traceText & "the row's middle isn't in view (panel list and browser window), no menu shown; "
        else if actionMode is "resume" and not (my notePid(foundProcess)) then
            set outcome to "no-menu"
            set traceText to traceText & "the browser's process id couldn't be read, no menu shown; "
        else
            -- Re-check right before acting: the button first, then the
            -- title (which ends with the button's label when the scan saw it
            -- that way, and still shows the same state).
            set btnLabel to my rowButtonLabel(panelList, rowIndex, j)
            if my wantsButton(actionMode, btnLabel) then
                set strictEnd to ((item n of candTitles) ends with btnLabel)
                -- (for a shortened name: the whole name on the row's label, read again now)
                set nameVariants to my namesForRow(panelList, rowIndex, item n of candTitles, fileNames)
                set nowTitle to my rowTitleAt(panelList, rowIndex)
                set rowOk to my rowIsForName(nowTitle, nameVariants)
                if rowOk and strictEnd then set rowOk to (nowTitle ends with btnLabel)
                if rowOk and scanKind is not "" then set rowOk to ((my rowKind(nowTitle, nameVariants)) is scanKind)
                if rowOk then set rowOk to my wholeNameStill(panelList, rowIndex, fileNames)
                if rowOk then
                    if actionMode is "resume" then
                        set res to my showRowMenu(panelList, rowIndex, nameVariants, scanKind, rowPlace)
                        set outcome to item 1 of res
                        set traceText to traceText & (item 2 of res)
                        set frameText to item 3 of res
                    else
                        set pressedOk to false
                        tell application "System Events"
                            try
                                perform action "AXPress" of button j of UI element rowIndex of panelList
                                set pressedOk to true
                            end try
                        end tell
                        if pressedOk then
                            set outcome to actionMode & "-sent"
                            set traceText to traceText & "pressed [" & btnLabel & "] in row " & rowIndex & "; "
                        else
                            set outcome to "press-failed"
                            set traceText to traceText & "pressing [" & btnLabel & "] reported an error; "
                        end if
                    end if
                end if
            end if
        end if
    end if
    set pidValue to ""
    if outcome is in {"menu-shown", "menu-changed", "show-error"} then set pidValue to my shownPid
    return outcome & "|" & traceText & "|" & foundProcess & "||" & frameText & "|" & pidValue
end run
"""#

    /// Firefox's own labels, in every language it's translated into: the
    /// menu's Resume item, and items that menu always has for a paused
    /// download (Show in Finder, Clear Preview Panel), which prove a menu
    /// is that menu.
    static let resumeLabels: [String] = ["Adkregiñ", "Ailgychwyn", "Atkuortuot", "Atkārtot", "Berrekin", "Buyela kwakhona", "Continar", "Continuar", "Continuă", "Cuntinuar", "Davam et", "Davom etish", "Daŭrigi", "Devam et", "Dooraat", "Ehorei hese", "Ferfetsje", "Folytatás", "Fortset", "Fortsett", "Fortsetzen", "Genoptag", "Halda áfram", "Hervat", "Hervatten", "Ipagpatuloy", "Jatka", "Jokku", "Jätka", "Kajie´e tuku", "Kemmel", "Lanjutkan", "Lean", "Lean air", "Mede", "Nadaljuj", "Nastavi", "Nayi'i ñun", "Pokračovat", "Pokračovať", "Pokročować", "Pókšacowaś", "Reanudar", "Repiggio", "Reprender", "Reprendre", "Reprèn", "Reprén", "Resume", "Retomar", "Rimerre", "Ripie", "Riprendi", "Rōb zaś", "Sambung", "Sighi", "Siguir", "Titikïr chik el", "Tiếp tục", "Tęsti", "Wznów", "Återuppta", "Šintin taaga", "Συνέχεια", "Возобновить", "Давом додан", "Жалғастыру", "Настави", "Працягнуць", "Продовжити", "Продолжи", "Продължаване", "Շարունակել", "Վերադառնալ", "המשך", "ازسرگیری", "استأنف", "ز سر گرؽڌن", "هێنانەوە", "ولا جاری کرو", "پھر جاری کریں", "पुनः निरन्तरता दिनुहोस्", "पुन्हा सुरू करा", "फिन जागाय", "फिर बहाल करें", "পুনরায় শুরু করা", "ਮੁੜ-ਪ੍ਰਾਪਤ", "ફરી શરૂ કરો", "தொடரவும்", "కొనసాగించు", "ಮರಳಿ ಆರಂಭಿಸು", "വീണ്ടും ആരംഭിയ്ക്കുക", "නැවතත්", "ทำต่อ", "ດຳເນີນການຕໍ່", "མུ་མཐུད", "ဆက်လက်ဆောင်ရွက်ပါ", "განაგრძეთ", "បន្ត", "ᱫᱩᱦᱲᱟᱹ ᱮᱦᱚᱵ", "再開", "繼續", "继续", "계속"]
    static let menuMarkers: [String] = ["Afficher dans le Finder", "Afișează în Finder", "Ammustra in Finder", "Bersihkan Panel Pratinjau", "Buang Panel Previu", "Buida la subfinestra de previsualització", "Cima iPhanele yamaVandlakanya", "Clear Preview Panel", "Clirio'r Panel Rhagolwg", "Curăță panoul de previzualizări", "Dangos yn Finder", "Dicht Preview Panel", "Diskouez e Finder", "Dọn bảng xem trước", "Ehechauka Hekahápe", "Előnézeti panel törlése", "Embogue jeike hague ra’ãngarupa", "Erakutsi Finder-en", "Esborra la subfinestra de previsualització", "Escafar lo panèl d'apercebut", "Escoscar panel de previsualización", "Falamhaich panail an ro-sheallaidh", "Finder ਵਿੱਚ ਵੇਖਾਓ", "Finder に表示", "Finder’da göster", "Finder에서 보기", "Foarbyldpaniel wiskje", "Garbitu aurrebista-panela", "Glan Painéal an Réamhamhairc", "Hawiin ang Preview Panel", "Hiển thị trong thư mục", "Hreinsa forskoðunarspjald", "Im Finder anzeigen", "Ipakita sa Finder", "Izbriši ploču pregleda", "Išvalyti peržiūros skydelį", "Jwa dirica me neno", "Kuva Finderis", "Limpa o panel de previsualización", "Limpar o painel de pré-visualização", "Limpar painel de exibição", "Limpiar panel de previsualización", "Limpiar panel de vista previa", "Liste leeren", "Llimpiar el panel de previsualización", "Lìmpia su pannellu de previsualizatzione", "Maak voorskoupaneel skoon", "Megjelenítés mappában", "Momtu Alluwal Ɓennungal", "Monstrar in Finder", "Montri en Finder", "Moofur feddiyoo kaa", "Mostra en el Finder", "Mostra nel Finder", "Mostra-ho en el Finder", "Mostrar dins lo Finder", "Mostrar en Finder", "Mostrar no Finder", "Mostre in Finder", "Mussar en il Finder", "Nagi'iaj nìñu' riña ni'io'", "Nete il panel de anteprime", "Notīrīt priekšskatījuma paneli", "Näytä Finderissa", "Nūteireit prīkšskatejuma paneli", "Oldindan koʻrish panelini tozalash", "Očisti panel za pregled", "Pokaż w Finderze", "Pokoż we Finderze", "Počisti ploščo predogleda", "Prikaži u Finderu", "Prikaži u folderu", "Prikaži v Finderju", "Puhasta eelvaate paneel", "Přehladowe wokno wuprózdnić", "Pśeglědowe wokno wuprozniś", "Rens forhåndsvisningspanel", "Rensa förhandsgranskningspanelen", "Rodyti per „Finder“", "Ryd liste", "Rādīt mapē", "Scancella Panello Anteprimma", "Seall san lorgaire", "Sfeḍ agalis n teskant", "Shfaqe në Finder", "Show in Finder", "Skarzhañ ar penel alberz", "Sken deg ukaram", "Spastroje Panelin e Paraparjeve", "Svidar la panela da prevista", "Svuota pannello anteprima", "Sá´áno panel vista previa", "Sýna í Finder", "Taispeáin san Aimsitheoir", "Tampilkan di Finder", "Tik'ut pa Finder", "Tiyuj nab'ey tz'ub'al pas", "Toane yn Finder", "Tonen in Finder", "Tyhjennä esikatselupaneeli", "Tøm førehandsvisingsruta", "Vacuar le pannello de vista preliminar", "Vider le panneau d’aperçu", "Vis i Finder", "Visa i Finder", "Viŝi antaŭvidan panelon", "Voorbeeldpaneel wissen", "Vymazat tento seznam", "Vymazať panel náhľadu", "W Finder pokazać", "W Finder pokazaś", "Wyczyść listę", "Wypucuj lista z podglōndym", "Xituvi nu Finder", "Zobrazit ve Finderu", "Zobraziť vo Finderi", "Ön baxış panelini təmizlə", "Ön izleme panelini temizle", "Απαλοιφή περιοχής προεπισκόπησης", "Εμφάνιση στο Finder", "Алдын-ала қарау панелін тазарту", "Ачысціць панэль перадпаказу", "Бумада көрсету", "Изчистване на списъка", "Исчисти го панелот за преглед", "Намоиш додан дар ҷӯянда", "Обриши панел за преглед", "Очистити панель перегляду", "Очистить панель предпросмотра", "Паказаць у Finder", "Пок кардани лавҳаи пешнамоиш", "Показати у Finder", "Показать в Finder", "Показване в папката", "Прикажи у фасцикли", "Մաքրել նախադիտման վահանակը", "Ցուցադրել որոնիչում", "Ցուցադրել պանակում", "הצגה ב־Finder", "ניקוי חלונית תצוגה מקדימה", "اعرض في فايندر", "امسح لوحة المعاينة", "روفتن تابلو پؽش نشووݩ", "صاف پیش نظارہ پینل", "فولڈر اِچ ݙکھاؤ", "فولڈر میں دکھائیں", "نشووݩ داڌن من Finder", "نمایش در Finder", "پاک کردن تابلو پیش‌نمایش", "پاککردنەوەی بەشی پێشبینین", "پیش نظارہ پینل صاف کرو", "पूर्वावलोकन पटल मिटाए", "पूर्वावलोकन प्यानल खाली गर्नुहोस्", "पूर्वावलोकन फलक साफ करा", "फाइंडर में दिखाएं", "फोल्डरमा देखाउनुहोस्", "প্রাকপদর্শন প্যানেল পরিষ্কার করুন", "ফোল্ডারে দেখান", "ਝਲਕ ਪੈਨਲ ਨੂੰ ਸਾਫ਼ ਕਰੋ", "પૂર્વદર્શન પેનલ સાફ કરો", "முன்பார்வை பலகத்தை துடை", "ఫైండర్‌లో చూపించు", "మునుజూపు ప్యానెలుని తుడిచివేయి", "അറയിൽ കാണിക്കുക", "പ്രിവ്യൂ പാനൽ വൃത്തിയാക്കുക", "පෙරදසුන මඬල මකන්න", "බහාලුමෙහි පෙන්වන්න", "ล้างแผงแสดงตัวอย่าง", "แสดงในโฟลเดอร์", "ລ້າງ Panel ການສະແດງຕົວຢ່າງ", "ສະແດງໃນ Finder", "སྔོན་ལྟའི་ངོས་ནས་མེད་པ་བཟོ་བ", "အစမ်းကြည့်ပန်နယ်ကို ရှင်းလင်းပါ", "დასრულებული ჩამოტვირთვების მოცილება", "ჩვენება საქაღალდეში", "ផ្ទាំង​សម្អាត​ការ​មើល​ជា​មុន", "ᱢᱟᱲᱟᱝ ᱛᱮᱭᱟᱜ ᱧᱮᱞ ᱯᱮᱱᱟᱞ ᱯᱷᱟᱨᱪᱟᱭ ᱢᱮ", "ᱧᱟᱢᱤᱡ ᱨᱮ ᱫᱮᱠᱷᱟᱣ ᱢᱮ", "プレビューパネルを消去", "在访达中显示", "於 Finder 顯示", "清空预览面板", "清除預覽窗格", "미리보기 패널 정리"]
}
