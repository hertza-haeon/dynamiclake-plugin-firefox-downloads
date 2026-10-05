#!/usr/bin/env python3
"""
Firefox Downloads -- a DynamicLake plugin

Shows download progress for Firefox and the browsers built on it
(LibreWolf, Waterfox, Pale Moon, Tor Browser, ...) in the DynamicLake
notch, with working Stop, Resume and Retry buttons, without installing any
browser extension.

HOW IT WORKS
------------
Firefox writes an in-progress download to a ".part" file inside the
download folder, then renames it to the final name the moment the
transfer finishes. This script watches the relevant folder(s) for that
pattern:

  * bytes downloaded so far -> the live size of the .part file
  * speed, time left        -> the size delta between polls
  * total size, percentage, -> downloads.json, the small file each Firefox
    paused or failed           profile keeps listing the downloads in
                                progress (so the browser can resume them
                                after a restart), matched by the .part
                                file's exact path. Read-only.
  * completion + filename   -> the .part file disappearing while the
                                finished file appears
  * browser closed          -> the lock its profile holds while it's open
                                (only looked at, never taken)
  * "Show in Finder"        -> `open -R <file>`

While downloading, the sneak peek shows numbers ("294/871MB · 2 min 34 s");
when something happens it says what, and to which file ("Complete • report.pdf",
"Paused • report.pdf"...), scrolling when the name is long. The pill shows the
file's extension in a blue circle, and how it's going: a ring, or a symbol.

Stop, Resume and Retry: nothing on disk can control a transfer the browser
owns, so the plugin uses macOS Accessibility. It presses the toolbar's
Downloads button (a direct accessibility action, so the browser stays in
the background) and finds the one panel row whose title starts with this
file's name. Stop presses that row's own Cancel button (a true cancel;
finished entries with the same name have none and are ignored); Retry
presses the Retry button of the row showing Failed (or, on a canceled
card, Canceled); Resume, which has no button in the panel, is chosen from
the paused row's right-click menu.
"""

from __future__ import annotations

import base64
import ctypes
import fcntl
import hashlib
import itertools
import json
import math
import os
import re
import select
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback
import unicodedata
import zlib
from collections import deque
from pathlib import Path

# --------------------------------------------------------------------------
# Tunables
# --------------------------------------------------------------------------

POLL_INTERVAL = 0.6           # seconds between filesystem scans
ACTION_POLL_INTERVAL = 0.1    # ...while a Stop, Resume or Retry is in flight,
                              # so the card follows the browser within 0.1 s
MIN_SAMPLE_GAP = 0.45         # speed samples are taken at most this often
SPEED_WINDOW = 8              # samples kept for the rolling speed estimate
VANISH_GRACE_TICKS = 1        # extra scans before a .part that vanished with
                              # no finished file (and no Stop pending) counts
                              # as canceled in the browser
EMPTY_FILE_TICKS = 3          # extra scans an EMPTY final file must survive
                              # before it counts as a finished (empty) download
PEEK_SECONDS = 5              # how long the sneak peek opens when a download finishes,
                              # pauses, fails or is canceled (the default of the
                              # setting "Sneak Peek Duration")
REMAIN_SECONDS = 0            # ...and how long a finished or canceled card's pill
                              # stays after that (the default of "Remain Visible").
                              # At 0 the card goes with its sneak peek still open
REMAIN_MAX_SECONDS = 30       # ...the most that setting goes to
NOTICE_SECONDS = 3            # how long a transient button-result message shows
PEEK_MARGIN_SECONDS = 2       # a card that goes with its sneak peek open asks for the
                              # sneak peek this much longer than it stays, so that the
                              # two go together (no moment with only the pill left)
MAX_PRESENT_SECONDS = 10      # the longest sneak peek DynamicLake accepts (a longer one
                              # makes it refuse the whole update)
DETAILS_TURN_SECONDS = 4      # "Download Details" on Both: the speed and the time left
                              # take turns, this long each
SCROLL_HOLD_SECONDS = 3       # a status line too long for the sneak peek stays still this
                              # long, cut short, before it starts to scroll
FIT_POINTS = 196.0            # the widest text DynamicLake shows whole in the middle of a
                              # sneak peek (a wider one scrolls). Measured on a notch, in
                              # the font below: 202 pt with "100%" on its right, up to 220
FIT_CHARS = 28                # ...in characters, where widths can't be measured
PEEK_FONT = ".AppleSystemUIFontDemi"    # the sneak peek's text, as measured on a notch: the
PEEK_FONT_SIZE = 14.0                   # system's semibold, at 14 pt
LEAD_BLANK = "\u2800"         # an empty braille cell, put before a line that scrolls: it
                              # starts where the left side fades out, which cut its first
                              # letter (spaces there are trimmed; this isn't one)
PAD_END = "\u034f"            # an invisible character after padding spaces, which keeps
                              # DynamicLake from trimming them (others, such as U+2060,
                              # make it refuse the whole update)
MAX_TEXT_CHARS = 240          # ...and the longest text
ICON_DELAY_SECONDS = 5        # a new download shows the blue arrow this long, then
                              # its file type
EARLY_STOP_CONFIRM = 0.09     # the browser closed the partial file: looked at again
                              # this much later before the download counts as paused
                              # (it also closes it for an instant when it finishes)
EARLY_STOP_CONFIRM_NO_TOTAL = 0.5   # ...longer when the size isn't known: "it's all
                              # there, so it's finishing" can't be told then
EARLY_PEEK_DELAY = 3.0        # a download stopped that way is a paused one or a failed
                              # one: the card (pill and sneak peek) waits until the
                              # browser's downloads.json says which, about 1.5 s later
                              # -- this long at most, then it's shown as paused. (If
                              # the browser was in fact quitting, it closes its files
                              # first: the card says so instead.)
CANCEL_GIVEUP_SECONDS = 8.0   # after Stop: file still there this long => report it
RESTART_GIVEUP_SECONDS = 10.0 # after Resume/Retry: no data this long => report it
STALL_SECONDS = 15            # downloading, but no data this long => "Stalled"
CLOSED_CHECK_AFTER = 3        # no data this long => check whether the browser is still open
WAKE_GRACE_SECONDS = 15       # after the Mac wakes, a pause waits this long before it's
                              # shown: Firefox pauses downloads when the Mac sleeps and
                              # resumes them itself 10 s after it wakes
SLEEP_GAP_SECONDS = 8         # this long between two scans means the Mac was asleep
WAS_DOWNLOADING_SECONDS = 5   # data this recently before the Mac slept: it was downloading
                              # (Firefox resumes those; a download you'd paused, it doesn't)
AWAY_SECONDS = 60             # no keyboard, mouse or trackpad input this long: you're
                              # away (the default of the "Away After" setting; see
                              # "Delayed Display")
REPLAY_GAP_SECONDS = 6        # between two sneak peeks shown when you're back
HOLD_MAX_SECONDS = 12 * 3600  # a sneak peek waits for you at most this long
NOTCH_PLACES = 2              # downloads that have a card at the same time (DynamicLake
                              # shows two: the main place and the capsule beside it).
                              # The others wait their turn, oldest first: see "Places".
                              # 0: no limit, every download has its card from the start
                              # and shows its own status on it
PLACE_GAP_SECONDS = 0.5       # after a card left, the next download's card comes no
                              # sooner than this (created in the same breath, it would
                              # take the main place from the card that moves up)
PEEK_AFTER_CREATE = 0.2       # a sneak peek is asked for this long after its card was
                              # created: DynamicLake ignores one that comes with it
SPOT_MARGIN_SECONDS = 0.5     # a paused or failed download's status card in the main
                              # place stays this long past its sneak peek...
SPOT_GAP_SECONDS = 1.5        # ...and the next status card comes this long after it left
HAND_BACK_SECONDS = 0.8       # cards lowered to give the main place back keep the low
                              # priority this long (DynamicLake decides who moves up a
                              # moment after a card is dismissed or lowered, by the
                              # priorities of that moment; between equals, another
                              # app's activity first, then the card updated last)
FOCUS_SETTLE_SECONDS = 0.25   # after Resume: time for the browser to act on the
                              # command before focus goes back to your app
MENU_GONE_SECONDS = 1.0       # ...which waits, this long at most, for the row's menu
                              # to have gone from the screen (see clear_browser_from_view)
PANEL_GONE_SECONDS = 0.5      # how long the Downloads panel may take to go after that
PANEL_ABSENT_SECONDS = 0.2    # ...and how long it must have been off the screen to count
                              # as gone (it's out of sight for an instant when the menu goes)
BLINK_SECONDS = 0.03          # how long the browser then stays in front before your app
                              # is brought back (it closes its panel as it comes forward)
QUIET_SECONDS = 0.5           # ...which isn't done within this long of a click or a key
                              # press of yours (one under way would land in the browser)
CLEAR_BUDGET_SECONDS = 3.0    # ...nor once the clearing has taken this long
TIME_LEFT_SPAN = 3.0          # seconds of data before time left is estimated
SETTINGS_REFRESH_SECONDS = 5  # how often DynamicLake's plugin settings are re-read
STOP_SCRIPT_TIMEOUT = 20      # seconds before an osascript run is abandoned
WARMUP_MIN_GAP = 120          # seconds between warm-ups of the Stop automation
TOTAL_WAIT_SECONDS = 10       # log it if no total size shows up in this time
LOG_MAX_BYTES = 256 * 1024    # ~/Library/Logs/FirefoxDownloads/plugin.log rolls over
DIR_REFRESH_SECONDS = 300     # how often to re-read the browsers' profile folders

PLUGIN_FOLDER_NAME = "FirefoxDownloads"  # for ~/Library/Logs and ~/Library/Caches
ACTIVITY_SIZE = "small"       # compact pill width: "small" (icon + ring, the same
                              # geometry as DynamicLake's built-in activities),
                              # "normal" or "large"

# Firefox-family browsers: their folder in ~/Library/Application Support,
# and the name of their process (used to try the right browser first).
FIREFOX_FAMILY = {
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
}

_activity_counter = itertools.count(1)


# --------------------------------------------------------------------------
# DynamicLake JSON socket protocol (see JSONPluginAPI)
# --------------------------------------------------------------------------

class DynamicLake:
    """Thin wrapper around the framed JSON protocol: a 4-byte big-endian
    length prefix followed by UTF-8 JSON, in both directions. The socket is
    non-blocking; the main loop sleeps in select() on it, so a button press
    is handled the moment it arrives instead of at the next scan."""

    def __init__(self, sock_path: str):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(sock_path)
        self.sock.setblocking(False)
        self._buf = b""

    def send(self, payload: dict) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        left = memoryview(struct.pack(">I", len(data)) + data)
        # The socket doesn't block, and a frame with a picture in it is
        # bigger than the socket always takes at once: each piece is sent
        # once, in order, waiting for room while DynamicLake reads. (Never
        # the whole frame again after a part of it went out: that would
        # break every message after it.)
        while left:
            try:
                left = left[self.sock.send(left):]
            except (BlockingIOError, InterruptedError):
                try:
                    select.select([], [self.sock], [], 1.0)
                except (OSError, ValueError):
                    time.sleep(0.01)

    def wait_readable(self, timeout: float) -> None:
        """Sleep up to `timeout` seconds, waking early as soon as DynamicLake
        sends something (a button press)."""
        try:
            select.select([self.sock], [], [], max(0.0, timeout))
        except (OSError, ValueError):
            time.sleep(max(0.0, timeout))

    def poll_incoming(self) -> list[dict]:
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError("DynamicLake closed the plugin socket")
                self._buf += chunk
        except BlockingIOError:
            pass
        msgs = []
        while len(self._buf) >= 4:
            (length,) = struct.unpack(">I", self._buf[:4])
            if len(self._buf) < 4 + length:
                break
            frame, self._buf = self._buf[4:4 + length], self._buf[4 + length:]
            try:
                msgs.append(json.loads(frame))
            except ValueError:
                pass
        return msgs


def feature_set() -> set[str]:
    raw = os.environ.get("DYNAMICLAKE_PLUGIN_FEATURES", "")
    return {f for f in raw.split(",") if f}


# --------------------------------------------------------------------------
# Settings: the switches in DynamicLake's plugin settings (plugin.json)
# --------------------------------------------------------------------------

SETTING_DEFAULTS = {
    "fileTypeIcons": True,       # "File-Type Icons": the kind of file in the pill instead of the arrow
    "downloadDetails": "time",   # "Download Details": after the amounts, the "speed", the "time" left, or "both" in turn
    "returnFocus": True,         # "App Switching After Resume": after Resume, bring back the app you were in
    "focusMode": False,          # "Focus Mode": a finished download's card waits until no download is under way
    "waitWhenAway": True,        # "Delayed Display": hold sneak peeks while you're away; show them when you're back
    "awayAfter": AWAY_SECONDS,   # "Away After": ...away after this long without input ("1 min", "5 min"...)
    "sneakPeekDuration": PEEK_SECONDS,   # "Sneak Peek Duration": how long a sneak peek opens ("3 s", "5 s"...)
    "remainVisible": REMAIN_SECONDS,     # "Remain Visible": how long a finished or canceled card's pill stays after it
}


def _setting_env_names(setting_id: str) -> list[str]:
    snake = re.sub(r"(?<!^)(?=[A-Z])", "_", setting_id).upper()
    return [f"DYNAMICLAKE_SETTING_{snake}", f"DYNAMICLAKE_SETTING_{setting_id.upper()}",
            f"DYNAMICLAKE_SETTING_{setting_id}"]


def _as_bool(raw) -> bool | None:
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, (int, float)):
        return raw != 0
    if isinstance(raw, str):
        text = raw.strip().lower()
        if text in ("1", "true", "yes", "on"):
            return True
        if text in ("0", "false", "no", "off"):
            return False
    return None


_DURATION = re.compile(r"\s*(\d+(?:[.,]\d+)?)\s*([A-Za-z]*)\.?\s*")
_MINUTES_PER = {"": 1.0, "m": 1.0, "min": 1.0, "mins": 1.0, "minute": 1.0, "minutes": 1.0,
                "s": 1 / 60, "sec": 1 / 60, "secs": 1 / 60, "second": 1 / 60, "seconds": 1 / 60,
                "h": 60.0, "hr": 60.0, "hrs": 60.0, "hour": 60.0, "hours": 60.0}


def _as_seconds(raw) -> int | None:
    """A duration setting -- the title of the choice ("1 minute", "5
    minutes"), or a number of minutes -- in seconds, from 10 s to an hour."""
    try:
        if isinstance(raw, bool):
            return None
        if isinstance(raw, (int, float)):
            minutes = float(raw)
        elif isinstance(raw, str) and len(raw) <= 40:
            m = _DURATION.fullmatch(raw)
            per = _MINUTES_PER.get(m.group(2).lower()) if m else None
            if per is None:
                return None
            minutes = float(m.group(1).replace(",", ".")) * per
        else:
            return None
    except (OverflowError, ValueError):
        return None
    if not math.isfinite(minutes):
        return None
    return int(min(3600.0, max(10.0, minutes * 60.0)) + 0.5)


def _as_details(raw) -> str | None:
    """The choice of "Download Details", by its title."""
    text = raw.strip().lower() if isinstance(raw, str) else None
    return text if text in ("speed", "time", "both") else None


def _as_whole_seconds(raw, lowest: int, highest: int) -> int | None:
    """A number of seconds -- a number, or the title of a choice ("5 s",
    "5 seconds") -- when it's from `lowest` to `highest`."""
    try:
        if isinstance(raw, bool):
            return None
        if isinstance(raw, (int, float)):
            seconds = float(raw)
        elif isinstance(raw, str) and len(raw) <= 40:
            m = _DURATION.fullmatch(raw)
            if not m or m.group(2).lower() not in ("", "s", "sec", "secs", "second", "seconds"):
                return None
            seconds = float(m.group(1).replace(",", "."))
        else:
            return None
    except (OverflowError, ValueError):
        return None
    if not math.isfinite(seconds) or not lowest <= seconds <= highest:
        return None
    return int(seconds + 0.5)


def _as_peek_seconds(raw) -> int | None:
    return _as_whole_seconds(raw, 1, MAX_PRESENT_SECONDS)


def _as_remain_seconds(raw) -> int | None:
    return _as_whole_seconds(raw, 0, REMAIN_MAX_SECONDS)


_SETTING_PARSERS = {"downloadDetails": _as_details, "awayAfter": _as_seconds,
                    "sneakPeekDuration": _as_peek_seconds, "remainVisible": _as_remain_seconds}


def _setting_parser(key: str):
    return _SETTING_PARSERS.get(key, _as_bool)


def _setting_text(value) -> str:
    if isinstance(value, bool):
        return "on" if value else "off"
    return value if isinstance(value, str) else f"{value} s"


class Settings:
    """DynamicLake passes the plugin's settings at launch (environment
    variables DYNAMICLAKE_SETTING_...) and keeps them in a file it names
    (DYNAMICLAKE_PLUGIN_SETTINGS_PATH), which is re-read every few seconds
    so that a change applies at once. Anything unreadable keeps its default."""

    def __init__(self):
        self.values = dict(SETTING_DEFAULTS)
        self.generation = 0          # goes up on every change (part of each card's signature)
        self._next_read = 0.0

    def __getitem__(self, key: str):
        return self.values[key]

    def refresh(self, now: float | None = None, force: bool = False) -> str | None:
        """Re-read them (at most every SETTINGS_REFRESH_SECONDS); returns a
        line for the log when something changed (or, with `force`, always).
        A settings file caught mid-write keeps the settings as they were."""
        now = time.monotonic() if now is None else now
        if not force and now < self._next_read:
            return None
        self._next_read = now + SETTINGS_REFRESH_SECONDS
        try:
            values = self._read()
        except Exception:            # (a file that can't be read now: try again soon)
            self._next_read = now + 1.0
            if not force:
                return None
            values = dict(SETTING_DEFAULTS)
        if values == self.values and not force:
            return None
        changed = [f"{k} {_setting_text(v)}" for k, v in values.items() if force or v != self.values[k]]
        if values != self.values:
            self.generation += 1
        self.values = values
        return "settings: " + ", ".join(changed)

    def _read(self) -> dict:
        values = dict(SETTING_DEFAULTS)
        for key in values:
            parse = _setting_parser(key)
            for name in _setting_env_names(key):
                value = parse(os.environ.get(name))
                if value is not None:
                    values[key] = value
                    break
        path = os.environ.get("DYNAMICLAKE_PLUGIN_SETTINGS_PATH")
        if path:
            try:
                data = json.loads(Path(path).read_text(encoding="utf-8"))
            except FileNotFoundError:
                data = None              # none yet: the defaults
            stored = data.get("values", data) if isinstance(data, dict) else None
            if isinstance(stored, dict):
                for key in values:
                    value = _setting_parser(key)(stored.get(key))
                    if value is not None:
                        values[key] = value
        return values


SETTINGS = Settings()


# --------------------------------------------------------------------------
# Formatting helpers
# --------------------------------------------------------------------------

_UNITS = ("B", "KB", "MB", "GB", "TB")


def _unit_for(n: float) -> int:
    """Like Firefox's own download sizes, move to the next unit before a
    number would need four digits (so "1.0 MB", never "1000 KB")."""
    n = float(max(n, 0))
    i = 0
    while n >= 999.5 and i < len(_UNITS) - 1:
        n /= 1024
        i += 1
    return i


def _in_unit(n: float, i: int) -> str:
    """One decimal below 100, whole numbers from 100 up ("5.9", "13.8",
    "512"), as Firefox shows them."""
    value = float(max(n, 0)) / (1024 ** i)
    return f"{value:.0f}" if i == 0 or value >= 99.95 else f"{value:.1f}"


def human_bytes(n: float) -> str:
    i = _unit_for(n)
    return f"{_in_unit(n, i)} {_UNITS[i]}"


_KB, _MB, _GB = 1024, 1024 ** 2, 1024 ** 3


def _amount_unit(reference: float) -> tuple[int, str, int]:
    """(bytes per unit, unit, decimals) for the amounts in the sneak peek:
    whole megabytes below 1 GB, gigabytes with two decimals from there
    (and whole kilobytes for something smaller than a megabyte)."""
    if reference >= _GB:
        return _GB, "GB", 2
    if reference >= _MB:
        return _MB, "MB", 0
    return _KB, "KB", 0


def _floored(n: float, per: int, decimals: int) -> str:
    """Rounded down, so the amount downloaded never reads as the total
    before the file is complete."""
    scale = 10 ** decimals
    return f"{math.floor(max(n, 0) / per * scale) / scale:.{decimals}f}"


def human_pair(done: float, total: float) -> str:
    """"294/871MB", "0.83/2.00GB": amount downloaded/total, in the total's
    unit."""
    per, unit, decimals = _amount_unit(total)
    shown_total = f"{max(total, 0) / per:.{decimals}f}"
    return f"{_floored(min(done, total), per, decimals)}/{shown_total}{unit}"


def human_amount(done: float) -> str:
    """"294MB", "0.83GB": the amount downloaded when there's no total."""
    per, unit, decimals = _amount_unit(done)
    return f"{_floored(done, per, decimals)}{unit}"


def human_speed(bytes_per_sec: float) -> str:
    if bytes_per_sec < 1:
        return "-- KB/s"
    return f"{human_bytes(bytes_per_sec)}/s"


def time_left_margin(shown: float) -> float:
    """What's shown counts down by itself, second by second. This is how far
    the estimate must drift from it before it's set right, so that it
    doesn't jump at every reading of the speed."""
    return max(2.0, 0.06 * shown)


def human_time(seconds: int) -> str:
    """"45 s", "2 min 34 s", "1 h 20 min 5 s": the time left, always with
    its seconds."""
    minutes, secs = divmod(max(0, int(seconds)), 60)
    if minutes == 0:
        return f"{secs} s"
    hours, minutes = divmod(minutes, 60)
    if hours == 0:
        return f"{minutes} min {secs} s"
    return f"{hours} h {minutes} min {secs} s"


# --------------------------------------------------------------------------
# Browser profiles, download folders, and downloads.json
# --------------------------------------------------------------------------

_PREF_LINE = re.compile(r'user_pref\("([^"]+)",\s*(.*?)\);')


def parse_prefs_js(path: Path) -> dict:
    """Small, forgiving parser for Firefox-style prefs.js user_pref() lines.
    We only need three keys (folderList / dir / useDownloadDir), so this
    does not attempt to be a full JS parser -- just enough regex to pull
    out string/bool/int literals from that one call pattern."""
    values: dict = {}
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return values
    for m in _PREF_LINE.finditer(text):
        key, raw = m.group(1), m.group(2).strip()
        if raw == "true":
            values[key] = True
        elif raw == "false":
            values[key] = False
        elif raw[:1] == '"' and raw[-1:] == '"':
            values[key] = raw[1:-1]
        else:
            try:
                values[key] = int(raw)
            except ValueError:
                values[key] = raw
    return values


def resolve_download_dir(prefs: dict, home: Path) -> Path:
    folder_list = prefs.get("browser.download.folderList", 1)
    custom_dir = prefs.get("browser.download.dir")
    if folder_list == 2 and custom_dir:
        return Path(custom_dir).expanduser()
    if folder_list == 0:
        return home / "Desktop"
    return home / "Downloads"


def _profiles_ini_paths(app_root: Path) -> list[Path]:
    """Profile folders listed in profiles.ini, including ones stored outside
    the usual Profiles folder."""
    found: list[Path] = []
    try:
        text = (app_root / "profiles.ini").read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return found
    for section in re.split(r"^\[", text, flags=re.M):
        fields = dict(re.findall(r"^(\w+)=(.*)$", section, flags=re.M))
        raw = fields.get("Path", "").strip()
        if not raw:
            continue
        found.append(app_root / raw if fields.get("IsRelative", "1").strip() == "1" else Path(raw))
    return found


def discover_profiles() -> list[tuple[Path, str]]:
    """Every Firefox-family profile folder on this Mac, with the name of the
    browser process that owns it ("" when unknown). Folder names are matched
    without regard to case (LibreWolf's is "librewolf" on some Macs)."""
    home = Path.home()
    support = home / "Library" / "Application Support"
    wanted = {name.lower(): process for name, process in FIREFOX_FAMILY.items()}
    app_roots: list[tuple[Path, str]] = []
    try:
        for entry in support.iterdir():
            if entry.name.lower() in wanted and entry.is_dir():
                app_roots.append((entry, wanted[entry.name.lower()]))
    except OSError:
        pass
    found: list[tuple[Path, str]] = []
    seen: set = set()

    def add(profile: Path, process: str) -> None:
        try:
            st = profile.stat()
        except OSError:
            return
        key = (st.st_dev, st.st_ino)
        if profile.is_dir() and key not in seen:
            seen.add(key)
            found.append((profile, process))

    for app_root, process in app_roots:
        for profile in _profiles_ini_paths(app_root):
            add(profile, process)
        try:
            for profile in (app_root / "Profiles").iterdir():
                add(profile, process)
        except OSError:
            pass
    # Tor Browser ships a self-contained profile inside the .app bundle.
    for base in (Path("/Applications"), home / "Applications"):
        add(base / "Tor Browser.app" / "Contents" / "Resources" / "TorBrowser" / "Data" / "Browser" / "profile.default", "")
    return found


# Firefox locks a profile while it has it open (toolkit/profile/
# nsProfileLock.cpp). On macOS that's an fcntl() write lock on the profile's
# ".parentlock" file -- or, on a disk that can't do those (a network volume),
# ".parentlock" made a symbolic link naming its process ("<ip>:+<pid>"),
# removed when it quits. (On Linux the link is called "lock".) The plugin
# only asks: it never locks anything, and writes nothing there.
if sys.platform == "darwin":
    _FLOCK_FORMAT, _FLOCK_FIELDS = "qqihh", ("start", "len", "pid", "type", "whence")
else:                        # Linux, where the tests run
    _FLOCK_FORMAT, _FLOCK_FIELDS = "hhqqi", ("type", "whence", "start", "len", "pid")


def _lock_query(path: Path) -> dict | None:
    """What the system says about a write lock on `path` (its "type", and
    the "pid" of the process holding it), or None if it can't be asked."""
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return None
    try:
        query = dict.fromkeys(_FLOCK_FIELDS, 0)
        query.update(type=fcntl.F_WRLCK, whence=os.SEEK_SET)
        packed = struct.pack(_FLOCK_FORMAT, *(query[f] for f in _FLOCK_FIELDS))
        try:
            answer = fcntl.fcntl(fd, fcntl.F_GETLK, packed)
        except OSError:
            return None
        return dict(zip(_FLOCK_FIELDS, struct.unpack(_FLOCK_FORMAT, answer)))
    finally:
        os.close(fd)


def _lock_held(path: Path) -> bool | None:
    """Whether some process holds a write lock on `path` (None if it can't
    be asked)."""
    answer = _lock_query(path)
    return None if answer is None else answer["type"] != fcntl.F_UNLCK


def _link_alive(link: Path) -> bool | None:
    """Whether the process a lock link names ("<ip>:+<pid>") is running;
    None when `link` isn't such a link."""
    try:
        target = os.readlink(str(link))
    except OSError:
        return None
    m = re.search(r":\+?(\d+)$", target)
    if not m:
        return None
    try:
        os.kill(int(m.group(1)), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (OSError, OverflowError):
        return None
    return True


def profile_pid(profile: Path) -> int | None:
    """The browser process that has this profile open: the one its lock
    names (see above). None when the profile isn't open, or that can't be
    told."""
    parentlock = profile / ".parentlock"
    try:
        m = re.search(r":\+?(\d+)$", os.readlink(str(parentlock)))
    except OSError:
        m = None
    if m:
        return int(m.group(1)) if _link_alive(parentlock) else None
    answer = _lock_query(parentlock)
    if answer is None or answer["type"] == fcntl.F_UNLCK or answer["pid"] <= 0:
        return None
    return int(answer["pid"])


# Whether a process has a file open, asked of macOS (libproc: the list of
# the process's open files). Nothing is opened, locked or changed.
_proc: dict = {}


def _libproc():
    if "lib" not in _proc:
        lib = None
        try:
            lib = ctypes.CDLL("/usr/lib/libproc.dylib")
            lib.proc_pidinfo.restype = ctypes.c_int
            lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
            lib.proc_pidfdinfo.restype = ctypes.c_int
            lib.proc_pidfdinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        except (OSError, AttributeError):
            lib = None
        _proc["lib"] = lib
    return _proc["lib"]


def process_has_open(pid: int, path: Path) -> bool | None:
    """Whether process `pid` has this file open right now; None when that
    can't be told (the file is gone, the process is, or this isn't a Mac)."""
    lib = _libproc()
    if lib is None:
        return None
    try:
        st = os.stat(path)
    except OSError:
        return None
    try:
        room = lib.proc_pidinfo(pid, 1, 0, None, 0)            # PROC_PIDLISTFDS: the room it needs
        if room <= 0:
            return None
        table = ctypes.create_string_buffer(room + 8 * 64)     # (and some, for files opened meanwhile)
        got = lib.proc_pidinfo(pid, 1, 0, table, len(table))
        if got <= 0:
            return None
        info = ctypes.create_string_buffer(176)                # struct vnode_fdinfo
        for offset in range(0, got - 7, 8):                    # struct proc_fdinfo: descriptor, kind
            fd, kind = struct.unpack_from("iI", table, offset)
            if kind != 1:                                      # (PROX_FDTYPE_VNODE: a file)
                continue
            if lib.proc_pidfdinfo(pid, fd, 1, info, 176) != 176:   # PROC_PIDFDVNODEINFO
                continue
            device, = struct.unpack_from("I", info, 24)        # vinfo_stat: vst_dev...
            inode, = struct.unpack_from("Q", info, 32)         # ...and vst_ino
            if inode == st.st_ino and device == (st.st_dev & 0xFFFFFFFF):
                return True
        return False
    except Exception:
        return None


def profile_in_use(profile: Path) -> bool | None:
    """Whether a browser has this profile open right now; None when that
    can't be told."""
    parentlock = profile / ".parentlock"
    linked = _link_alive(parentlock)
    if linked is not None:
        return linked
    held = _lock_held(parentlock)
    other = _link_alive(profile / "lock")
    if held or other:
        return True
    if held is False or other is False:
        return False
    return None


class BrowserPresence:
    """Is the browser a download belongs to still open? Asked only about
    downloads that stopped receiving data; each answer is kept a second."""

    def __init__(self):
        self._cache: dict = {}
        self._pids: dict = {}

    def pid_of(self, profile: Path, now: float) -> int | None:
        """The browser process that has this profile open, or None."""
        hit = self._pids.get(profile)
        if hit is None or now - hit[0] >= 1.0:
            hit = (now, profile_pid(profile))
            self._pids[profile] = hit
        return hit[1]

    def profile_open(self, profile: Path, now: float) -> bool | None:
        hit = self._cache.get(profile)
        if hit is None or now - hit[0] >= 1.0:
            hit = (now, profile_in_use(profile))
            self._cache[profile] = hit
        return hit[1]

    def note(self, profile: Path, now: float, in_use: bool | None) -> None:
        """An answer just asked for (not from the cache): kept like any other."""
        self._cache[profile] = (now, in_use)
        if not in_use:
            self._pids.pop(profile, None)

    def closed_for(self, profile: Path | None, now: float) -> bool:
        """Closed when its profile (the one whose downloads.json lists it)
        isn't open. A download no downloads.json lists (a private window's,
        or a browser whose profile the plugin doesn't know) is never taken
        for closed: which browser it belongs to can't be told."""
        return profile is not None and self.profile_open(profile, now) is False


def partial_file_state(dl: "Download", presence: BrowserPresence, now: float) -> str:
    """"open": the browser has this download's partial file open (it's
    downloading, or waiting for data). "closed": the browser is running and
    doesn't have it open -- it closes it the moment it stops a download (a
    pause, a failure), about 1.5 s before its downloads.json says so.
    "unknown": can't be told (which browser it is isn't known, the browser
    isn't running, the file is gone, or this isn't a Mac)."""
    if dl.profile is None:
        return "unknown"
    pid = presence.pid_of(dl.profile, now)
    if pid is None:
        return "unknown"
    has_it = process_has_open(pid, dl.part_path)
    if has_it is None:
        return "unknown"
    return "open" if has_it else "closed"


def discover_watch_dirs(profiles: list[tuple[Path, str]]) -> set[Path]:
    home = Path.home()
    dirs = {home / "Downloads"}
    for profile, _ in profiles:
        prefs_js = profile / "prefs.js"
        if prefs_js.is_file():
            dirs.add(resolve_download_dir(parse_prefs_js(prefs_js), home))
    return {d for d in dirs if d.is_dir()}


def scan_part_files(directory: Path) -> set[Path]:
    try:
        with os.scandir(directory) as it:
            return {
                Path(e.path) for e in it
                if e.name.endswith(".part") and e.is_file(follow_symlinks=False)
            }
    except OSError:
        return set()


def _path_key(path: str) -> str:
    return unicodedata.normalize("NFC", os.path.normpath(path))


def _name_key(path: str) -> str:
    return unicodedata.normalize("NFC", os.path.basename(path))


_BLOCKED_FLAGS = ("becauseBlocked", "becauseBlockedByParentalControls",
                  "becauseBlockedByReputationCheck", "becauseBlockedByContentAnalysis")


def entry_state(item: dict) -> str:
    """What one downloads.json entry says about its download:
      "failed"  -- it stopped with an error and kept its partial data (Firefox
                   lists it with an "errorObj"; Retry continues it)
      "paused"  -- stopped by a pause (in the browser, or by Firefox itself
                   when the Mac sleeps or goes offline): "canceled" while
                   keeping its partial data
      "blocked" -- held back as a potential security risk, until you decide
                   in the browser
      "active"  -- downloading
      ""        -- in between (being canceled, just finished)"""
    error = item.get("errorObj")
    if item.get("hasBlockedData") is True:
        return "blocked"
    if isinstance(error, dict):
        if any(error.get(flag) is True for flag in _BLOCKED_FLAGS):
            return "blocked"
        return "failed"
    if error:
        return "failed"
    if item.get("succeeded") is True:
        return ""
    if item.get("canceled") is True:
        return "paused" if item.get("hasPartialData") is True else ""
    return "active"


def read_downloads_json(path: Path) -> dict:
    """{("path"|"name", key): (total bytes or None, state)} for the downloads
    listed in one downloads.json -- keyed by the .part file's full path and
    by its name (and by the final file's, as a fallback). Firefox serializes
    each download's target as {"path": ..., "partFilePath": ...}, includes
    "totalBytes" once the server has sent the size, and the fields that tell
    a paused or failed download apart (see entry_state)."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    entries: dict = {}
    items = data.get("list") if isinstance(data, dict) else None
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        total = item.get("totalBytes")
        if isinstance(total, bool) or not isinstance(total, (int, float)) or total <= 0:
            total = None
        else:
            total = int(total)
        state = entry_state(item)
        target = item.get("target")
        paths = []
        if isinstance(target, str):
            paths.append(target)
        elif isinstance(target, dict):
            paths += [target[k] for k in ("partFilePath", "path") if isinstance(target.get(k), str)]
        for p in paths:
            entries[("path", _path_key(p))] = (total, state)
            entries[("name", _name_key(p))] = (total, state)
    return entries


class DownloadsJson:
    """Every profile's downloads.json. Firefox rewrites that file
    (atomically) about 1.5 s after a download starts, gets its size, pauses,
    resumes, fails or stops; it's only re-read here when it changes."""

    def __init__(self):
        self._cache: dict[Path, tuple] = {}   # file -> ((mtime, size), entries, process)

    def refresh(self, profiles: list[tuple[Path, str]]) -> None:
        live = set()
        for profile, process in profiles:
            f = profile / "downloads.json"
            live.add(f)
            try:
                st = f.stat()
            except OSError:
                self._cache.pop(f, None)
                continue
            stamp = (st.st_mtime_ns, st.st_size)
            cached = self._cache.get(f)
            if cached is None or cached[0] != stamp:
                self._cache[f] = (stamp, read_downloads_json(f), process)
        for f in list(self._cache):
            if f not in live:
                del self._cache[f]

    def lookup(self, dl: "Download") -> tuple:
        """(total bytes or None, state, browser process, version of the file)
        for one download, or (None, "", "", None) when no downloads.json
        lists it. The version tells a rewritten file from the same one.
        A match on the final file's name alone (another folder's download
        may have the same name) gives the size but not the state."""
        keys = [("path", _path_key(str(dl.part_path))), ("name", _name_key(str(dl.part_path))),
                ("path", _path_key(str(dl.final_path))), ("name", _name_key(str(dl.final_path)))]
        for i, key in enumerate(keys):
            for f, (stamp, entries, process) in self._cache.items():
                if key in entries:
                    total, state = entries[key]
                    return total, (state if i < 3 else ""), process, (str(f),) + stamp
        return None, "", "", None

    def lists_partial_file(self, dl: "Download") -> bool:
        """Whether the downloads.json of the download's profile lists this
        very partial file (by its path or its name) -- not merely a download
        with the same final name."""
        if dl.profile is None:
            return False
        hit = self._cache.get(dl.profile / "downloads.json")
        return hit is not None and (("path", _path_key(str(dl.part_path))) in hit[1]
                                    or ("name", _name_key(str(dl.part_path))) in hit[1])

    def profile_of(self, dl: "Download") -> Path | None:
        """The browser profile whose downloads.json lists this download (by
        its partial file, or its final file's full path), or None."""
        keys = [("path", _path_key(str(dl.part_path))), ("name", _name_key(str(dl.part_path))),
                ("path", _path_key(str(dl.final_path)))]
        for key in keys:
            for f, (_, entries, _) in self._cache.items():
                if key in entries:
                    return f.parent
        return None


# --------------------------------------------------------------------------
# Per-download state
# --------------------------------------------------------------------------

_RANDOM_CHUNK = re.compile(r"[A-Za-z0-9_-]{8}")


def real_name_from_part(raw_name: str) -> str:
    """Undo Firefox's random infix. Firefox names a partial download
    <name up to its first dot>.<8 random base64url chars><rest>.part
    (nsExternalHelperAppService.cpp); raw_name is that without ".part"."""
    dot = raw_name.find(".")
    if dot < 0:
        return raw_name
    chunk = raw_name[dot + 1: dot + 9]
    after = raw_name[dot + 9:]
    if _RANDOM_CHUNK.fullmatch(chunk) and (after == "" or after.startswith(".")):
        return raw_name[:dot] + after
    return raw_name


class Download:
    def __init__(self, part_path: Path):
        self.part_path = part_path
        # Firefox inserts 8 random characters into the partial file's name
        # ("report.ab3_Xy9Q.pdf.part" for "report.pdf"); strip them to get the
        # real name. The name without them is kept as a fallback in case a
        # genuine name just happens to look like that pattern.
        raw_name = part_path.name[: -len(".part")]
        self.final_path = part_path.with_name(real_name_from_part(raw_name))
        self.raw_final_path = part_path.with_name(raw_name)
        self.seq = next(_activity_counter)   # the order downloads started in
        self.activity_id = f"dl-{self.seq}"
        self.samples: deque = deque(maxlen=SPEED_WINDOW)
        self.total_size: int | None = None   # from downloads.json, once known
        self.browser = ""                    # process of the browser downloading it
        self.started_at = time.monotonic()
        self.total_logged = False
        self.created = False
        self.last_signature = None
        self.missing_ticks = 0
        self.resolved_at: float | None = None   # set once done, canceled or blocked
        self.resolved_reason = "Canceled"
        self.succeeded = False
        self.notice: str | None = None
        self.notice_until = 0.0
        # "active", "paused" or "failed" -- from downloads.json, see entry_state
        self.state = "active"
        self.state_size = 0                  # the .part's size when it paused or failed
        self.growth_ticks = 0                # measurements in a row it has grown since
        self.growth_checked_at: float | None = None  # the last measurement looked at
        self.stale_version = None            # a downloads.json version the .part outgrew
                                             # (FIRST_SEEN: whichever is current first)
        self.presented_state: str | None = None  # the state the sneak peek opened for
        self.last_growth_at = self.started_at    # when data last arrived
        self.stall_logged = False
        self.profile: Path | None = None         # the browser profile listing it
        self.browser_closed = False              # its browser quit (the download waits)
        self.hold_until = 0.0                    # a pause kept back until then (the Mac woke)
        self.closed_seen_at: float | None = None # when the browser was first seen to have closed
                                                 # the partial file (it stopped the download)
        self.closed_size = 0                     # ...and the file's size then
        self.closed_growths = 0                  # closed looks that found it bigger, since it was last seen open
        self.no_early_stop = False               # (the file grew while "closed": the wrong process
                                                 # was asked; not asked again for this download)
        self.early_paused = False                # paused by the closed file alone, so far
        self.peek_not_before: float | None = None    # ...its sneak peek opens then (EARLY_PEEK_DELAY)
        self.held: tuple | None = None           # (kind, seconds, since): a sneak peek kept for when you're back
        self.eta: float | None = None            # smoothed time left, and when it was estimated
        self.eta_at = 0.0
        self.eta_shown: float | None = None      # the time left on screen (it counts down), and
        self.eta_shown_at = 0.0                  # ...when it was that much
        self.time_tick_at: float | None = None   # ...and when its next second shows
        self.text_due: float | None = None       # when the card's text changes by itself (see rate_text)
        self.line_word: str | None = None        # the status its line is about ("Paused"...), since
        self.line_from = 0.0                     # ...when (it stays still at first: see status_line),
        self.line_phase = ""                     # ...whether it's "held" still or "scrolling" ("": fits),
        self.line_phase_sent = ""                # ...and as it was last sent
        self.peek_until: float | None = None     # until when the sneak peek the plugin opened stays open
        # Its place among the cards -- see "Places", above the main loop
        self.place = False                       # it has a card of its own (else it waits its turn)
        self.spot = False                        # its status shows in the main place, on a card made for that...
        self.spot_until: float | None = None     # ...which goes then (a paused or failed download's)
        self.own_card = False                    # ...while its own card stays where it is (it has a place)
        self.created_at = 0.0                    # when the card it has was created
        self.peek_owed: tuple | None = None      # (seconds, not before): a sneak peek that card still has to open
        self.held_why = ""                       # what `held` waits for: you ("away") or the main place ("turn")
        # Stop / Resume / Retry bookkeeping -- see README.md
        self.job: ActionJob | None = None           # browser automation running
        self.stop_pressed_at: float | None = None   # when Stop was pressed
        self.cancel_requested_at: float | None = None   # Cancel was pressed
        self.restart_requested_at: float | None = None  # Resume/Retry was pressed
        self.restart_kind = ""                          # ...which of them
        self.restart_pressed_at: float | None = None    # Retry pressed on its canceled card

    @property
    def filename(self) -> str:
        return self.final_path.name

    @property
    def card_id(self) -> str:
        """The card its updates go to: its own, or the one that shows its
        status in the main place (see "Places")."""
        return self.activity_id + "-s" if self.spot else self.activity_id

    def move_to(self, part_path: Path) -> None:
        """Follow the download to another partial file (Retry after a
        cancel, when the browser starts it over under a new name)."""
        raw_name = part_path.name[: -len(".part")]
        self.part_path = part_path
        self.final_path = part_path.with_name(real_name_from_part(raw_name))
        self.raw_final_path = part_path.with_name(raw_name)

    @property
    def stopping(self) -> bool:
        """A Stop is in flight: the script is running, or Cancel was pressed
        and we are waiting for the browser to remove the partial file."""
        return (self.job is not None and self.job.kind == "stop") or self.cancel_requested_at is not None

    @property
    def busy(self) -> bool:
        """A Stop, Resume or Retry is in flight (script running, or pressed and
        waiting for the browser to act on it)."""
        return self.job is not None or self.cancel_requested_at is not None \
            or self.restart_requested_at is not None

    @property
    def settling(self) -> bool:
        """The browser was just seen to have closed the partial file: it's
        looked at again in a moment (see EARLY_STOP_CONFIRM), and again and
        again until the sneak peek of that pause is due (is the browser
        still there? see EARLY_PEEK_DELAY)."""
        if self.resolved_at is not None:
            return False
        return (self.closed_seen_at is not None and self.state == "active") \
            or (self.peek_not_before is not None and self.state == "paused"
                and time.monotonic() < self.peek_not_before + 1.0)

    def restarted(self) -> None:
        """Back to downloading after a pause or failure: measure the speed
        afresh (the time spent stopped isn't part of it)."""
        if self.samples:
            last = self.samples[-1]
            self.samples.clear()
            self.samples.append(last)
        self.growth_ticks = 0
        self.presented_state = None
        self.early_paused, self.peek_not_before = False, None
        self.last_growth_at = time.monotonic()
        self.hold_until = 0.0
        self.eta = self.eta_shown = None
        if self.held is not None and self.held[0] in ("paused", "failed"):
            self.held = None          # nothing left to show you

    @property
    def can_restart(self) -> bool:
        """Canceled (its partial file went away, and not blocked): the
        browser's Retry starts it over."""
        return self.resolved_at is not None and not self.succeeded and self.resolved_reason == "Canceled"

    @property
    def restart_pending(self) -> bool:
        """Retry was pressed on its canceled card: the script is running, or
        it pressed Retry and the browser hasn't started it over yet."""
        return (self.job is not None and self.job.kind == "restart") or \
            (self.resolved_at is not None and self.restart_requested_at is not None)

    def reopen(self, now: float) -> None:
        """Downloading again after it was canceled: Retry (the plugin's or the
        browser's own) started it over, in the same partial file."""
        self.resolved_at = None
        self.succeeded = False
        self.resolved_reason = "Canceled"
        self.state = "active"
        self.samples.clear()
        self.missing_ticks = 0
        # What downloads.json says at this moment is from before the restart
        # (Firefox rewrites it about 1.5 s after): not believed.
        self.stale_version = FIRST_SEEN
        self.state_size = 0
        self.growth_ticks = 0
        self.growth_checked_at = None
        self.presented_state = None
        self.held = None
        self.stop_pressed_at = None
        self.cancel_requested_at = None
        self.restart_requested_at = None
        self.restart_pressed_at = None
        self.browser_closed = False
        self.hold_until = 0.0
        self.closed_seen_at = None
        self.early_paused, self.peek_not_before = False, None
        self.last_growth_at = now
        self.stall_logged = False
        self.eta = self.eta_shown = None
        if self.notice == WORKING_NOTICES["restart"]:
            self.notice = None        # "Retrying…": it has

    def sample(self) -> int | None:
        now = time.monotonic()
        if self.samples and now - self.samples[-1][0] < MIN_SAMPLE_GAP:
            return self.samples[-1][1]
        try:
            size = self.part_path.stat().st_size
        except OSError:
            return None
        if self.samples and size < self.samples[-1][1]:
            self.samples.clear()     # it started over (Retry from a server that can't resume): measure afresh
            self.eta = self.eta_shown = None
        if not self.samples or size > self.samples[-1][1]:
            self.last_growth_at = now
        self.samples.append((now, size))
        return size

    def stalled(self, now: float) -> bool:
        """Downloading, but no data for STALL_SECONDS (while its browser is
        open, and not a pause held back after the Mac woke)."""
        return self.state == "active" and not self.browser_closed \
            and now - self.last_growth_at >= STALL_SECONDS

    def under_way(self, now: float) -> bool:
        """Still downloading: not over, not paused or failed, its browser
        open, and data coming (not stalled). With "Focus Mode" on, finished
        downloads' cards wait until no download is."""
        return self.resolved_at is None and self.shown_state(now) == "active" \
            and not self.browser_closed and not self.stalled(now)

    def shown_state(self, now: float) -> str:
        """The state the card shows: a pause held back after the Mac woke
        (Firefox resumes those itself) still shows as downloading. So does
        a download the browser has just stopped, until its downloads.json
        says whether that's a pause or a failure (see EARLY_PEEK_DELAY): the
        card then changes once, to the right one."""
        if self.state == "paused" and now < self.hold_until:
            return "active"
        if self.state == "paused" and self.early_paused and self.peek_not_before is not None \
                and now < self.peek_not_before:
            return "active"
        return self.state

    def time_left(self, now: float) -> int | None:
        """Whole seconds left, or None until there's enough steady data to
        tell. The estimate follows the speed, smoothed; what's shown counts
        down by itself, second by second, and is set right when it has
        drifted from the estimate (see time_left_margin)."""
        self.time_tick_at = None
        if not self.total_size or self.percent is None or len(self.samples) < 2 \
                or self.samples[-1][0] - self.samples[0][0] < TIME_LEFT_SPAN:
            self.eta = self.eta_shown = None
            return None
        speed = self.speed
        if speed < 1024:
            return None               # (the speed shows "--"; the estimate resumes with the data)
        raw = max(0.0, (self.total_size - self.size) / speed)
        if self.eta is None:
            self.eta = raw
        else:
            predicted = max(0.0, self.eta - (now - self.eta_at))   # it counts down by itself
            if raw > 2 * predicted + 30 or raw < 0.5 * predicted - 30:
                self.eta = raw                                       # a real change of pace
            else:
                weight = 1 - math.exp(-max(0.0, now - self.eta_at) / 3.0)
                self.eta = predicted + weight * (raw - predicted)
        self.eta_at = now
        shown = None if self.eta_shown is None else self.eta_shown - (now - self.eta_shown_at)
        if shown is None or abs(self.eta - shown) > time_left_margin(max(0.0, shown)):
            shown = self.eta
        self.eta_shown, self.eta_shown_at = shown, now
        whole = max(1, int(math.ceil(shown)))
        self.time_tick_at = now + max(0.0, shown - (whole - 1))
        return whole

    @property
    def size(self) -> int:
        return self.samples[-1][1] if self.samples else 0

    @property
    def speed(self) -> float:
        if len(self.samples) < 2:
            return 0.0
        t0, s0 = self.samples[0]
        t1, s1 = self.samples[-1]
        dt = t1 - t0
        return (s1 - s0) / dt if dt > 0 else 0.0

    @property
    def percent(self) -> float | None:
        """Fraction done, or None when the total is unknown -- or wrong: a
        file already bigger than its "total" (a server reporting the
        compressed size, say) gets the spinning ring instead of a stuck
        100%."""
        if not self.total_size or self.size > self.total_size:
            return None
        return max(0.0, min(1.0, self.size / self.total_size))

    def current_surfaces(self, numeric_style: str = "compact"):
        """Return (surfaces_dict, signature). The signature lets the main
        loop send an update only when something actually changed; its first
        item is the kind of card ("done", "canceled", "paused", "failed",
        "closed", "active" or "notice")."""
        now = time.monotonic()
        gen = SETTINGS.generation
        self.text_due = None
        self.line_phase = ""
        if self.resolved_at is not None:
            if self.succeeded:
                surfaces, signature = done_surfaces(self, numeric_style, now), ("done", gen)
            else:
                surfaces = canceled_surfaces(self, self.resolved_reason, now)
                signature = ("canceled", self.resolved_reason, gen)
        else:
            state = self.shown_state(now)
            icon = pill_icon_key(self, now)        # (the arrow, then the file's type: see _pill_icon)
            if self.browser_closed:
                # Its browser quit. There's nothing to press until it
                # reopens: then Firefox carries on with a download that was
                # in progress by itself, and a paused or failed one waits for
                # Resume or Retry as before.
                closed_as = state if state in ("paused", "failed") else "closed"
                if closed_as == "failed":
                    surfaces = failed_surfaces(self, numeric_style, with_button=False, now=now)
                elif closed_as == "paused":
                    surfaces = paused_surfaces(self, numeric_style, with_button=False, now=now)
                else:
                    surfaces = paused_surfaces(self, numeric_style, with_button=False, word="Browser closed", now=now)
                signature = ("closed", closed_as, self.percent_text, icon, gen)
            elif state == "paused":
                surfaces = paused_surfaces(self, numeric_style, now=now)
                signature = ("paused", self.percent_text, icon, gen)
            elif state == "failed":
                surfaces = failed_surfaces(self, numeric_style, now=now)
                signature = ("failed", self.percent_text, icon, gen)
            else:
                stalled = self.stalled(now)
                surfaces = in_progress_surfaces(self, numeric_style, stalled=stalled, now=now)
                signature = ("active", self.size, self.total_size, 0 if stalled else int(now // 2), stalled,
                             surfaces["sneakPeek"]["center"]["text"], icon, gen)
        surfaces["extraLiveActivity"] = extra_surface(self)
        if not self.line_phase and surfaces["sneakPeek"].get("center", {}).get("text", "").find(BULLET) < 0:
            self.line_word = None          # (not a status line: the next one starts its time afresh)
        if self.notice and now < self.notice_until:
            surfaces["sneakPeek"]["center"] = {
                "type": "text", "text": self.notice, "style": "marquee"
            }
            return surfaces, ("notice", signature[0], self.notice, self.percent_text, gen)
        if self.notice:
            self.notice = None
        return surfaces, signature

    @property
    def percent_text(self) -> str:
        pct = self.percent
        # Rounded down, so it never reads 100% before the file is complete.
        return f"{int(pct * 100)}%" if pct is not None else "—"


def classify_vanished(dl: "Download") -> tuple[str, Path | None]:
    """What a vanished .part file means: ("done", file), ("canceled", None)
    or ("unsure", file).

    Firefox reserves the final name with an EMPTY placeholder file for the
    whole download. On success it renames the .part over that placeholder;
    on cancel it deletes the .part and, a moment later, the placeholder. So
    a non-empty final file means finished; no final file, or an empty one
    after data had arrived, means canceled; an empty file for a download
    that never received data can't be told apart yet."""
    empty: Path | None = None
    for candidate in dict.fromkeys((dl.final_path, dl.raw_final_path)):
        try:
            size = candidate.stat().st_size
        except OSError:
            continue
        if size > 0:
            return "done", candidate
        if empty is None:
            empty = candidate
    if empty is None or dl.size > 0:
        return "canceled", None
    return "unsure", empty


# --------------------------------------------------------------------------
# The pill's own pictures: the file's extension in a blue circle, and the
# symbols for "failed", "stalled" and "blocked" -- in the look of
# DynamicLake's own status symbols (a dim disc of the colour, the glyph in
# the colour). Drawn off screen with CoreGraphics and CoreText (ctypes, both
# part of macOS), kept as small PNG pictures, each drawn once.
# --------------------------------------------------------------------------

class _CGRect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double),
                ("width", ctypes.c_double), ("height", ctypes.c_double)]


BADGE_PIXELS = 96             # the pictures' size (DynamicLake scales them to the slot)
BADGE_FONT = ".AppleSystemUIFontRounded-Bold"   # the system's rounded bold (else: its bold)
_BADGE_BLUE = (10 / 255, 132 / 255, 1.0)        # the blue and red of DynamicLake's symbols
_BADGE_RED = (1.0, 69 / 255, 58 / 255)
_draw: dict = {}
_badges: dict = {}


def _draw_libs():
    """(CoreFoundation, CoreGraphics, CoreText, constants) set up for
    drawing, or None where they can't be loaded (not a Mac)."""
    if "libs" not in _draw:
        found = None
        try:
            cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            ct = ctypes.CDLL("/System/Library/Frameworks/CoreText.framework/CoreText")
            ref, num = ctypes.c_void_p, ctypes.c_double
            for lib, name, restype, argtypes in (
                    (cf, "CFRelease", None, [ref]),
                    (cf, "CFStringCreateWithCString", ref, [ref, ctypes.c_char_p, ctypes.c_uint32]),
                    (cf, "CFDictionaryCreate", ref, [ref, ctypes.POINTER(ref), ctypes.POINTER(ref), ctypes.c_long, ref, ref]),
                    (cf, "CFAttributedStringCreate", ref, [ref, ref, ref]),
                    (cg, "CGColorSpaceCreateDeviceRGB", ref, []),
                    (cg, "CGColorSpaceRelease", None, [ref]),
                    (cg, "CGBitmapContextCreate", ref, [ref, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t,
                                                         ctypes.c_size_t, ref, ctypes.c_uint32]),
                    (cg, "CGContextRelease", None, [ref]),
                    (cg, "CGContextSetRGBFillColor", None, [ref, num, num, num, num]),
                    (cg, "CGContextSetRGBStrokeColor", None, [ref, num, num, num, num]),
                    (cg, "CGContextSetLineWidth", None, [ref, num]),
                    (cg, "CGContextSetLineCap", None, [ref, ctypes.c_int32]),
                    (cg, "CGContextFillEllipseInRect", None, [ref, _CGRect]),
                    (cg, "CGContextMoveToPoint", None, [ref, num, num]),
                    (cg, "CGContextAddLineToPoint", None, [ref, num, num]),
                    (cg, "CGContextStrokePath", None, [ref]),
                    (cg, "CGContextSetTextPosition", None, [ref, num, num]),
                    (ct, "CTFontCreateUIFontForLanguage", ref, [ctypes.c_uint32, num, ref]),
                    (ct, "CTFontCreateWithName", ref, [ref, num, ref]),
                    (ct, "CTFontGetXHeight", num, [ref]),
                    (ct, "CTLineCreateWithAttributedString", ref, [ref]),
                    (ct, "CTLineGetTypographicBounds", num, [ref, ctypes.POINTER(num), ctypes.POINTER(num), ctypes.POINTER(num)]),
                    (ct, "CTLineDraw", None, [ref, ref])):
                fn = getattr(lib, name)
                fn.restype, fn.argtypes = restype, argtypes
            constants = {
                "font": ref.in_dll(ct, "kCTFontAttributeName").value,
                "context colour": ref.in_dll(ct, "kCTForegroundColorFromContextAttributeName").value,
                "true": ref.in_dll(cf, "kCFBooleanTrue").value,
                "key callbacks": ctypes.addressof(ctypes.c_char.in_dll(cf, "kCFTypeDictionaryKeyCallBacks")),
                "value callbacks": ctypes.addressof(ctypes.c_char.in_dll(cf, "kCFTypeDictionaryValueCallBacks")),
            }
            found = (cf, cg, ct, constants) if all(constants.values()) else None
        except (OSError, AttributeError, ValueError):
            found = None
        _draw["libs"] = found
    return _draw["libs"]


def png_bytes(width: int, height: int, rgba: bytes) -> bytes:
    """A PNG file's bytes from RGBA pixels (alpha not premultiplied)."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def _text_line(libs, text: str, size: float):
    """(a CoreText line of `text` in the badge font at `size`, its width,
    the font's x-height). The line must be released."""
    cf, _, ct, constants = libs
    font = None
    name = cf.CFStringCreateWithCString(None, BADGE_FONT.encode("utf-8"), 0x08000100)
    if name:
        font = ct.CTFontCreateWithName(name, size, None)             # (another font if that one isn't there)
        cf.CFRelease(name)
    if not font:
        font = ct.CTFontCreateUIFontForLanguage(3, size, None)      # (the bold system font)
    string = cf.CFStringCreateWithCString(None, text.encode("utf-8"), 0x08000100)
    attributes = None
    if font and string:                                             # (a dictionary can't hold "nothing")
        keys = (ctypes.c_void_p * 2)(constants["font"], constants["context colour"])
        values = (ctypes.c_void_p * 2)(font, constants["true"])
        attributes = cf.CFDictionaryCreate(None, keys, values, 2, constants["key callbacks"], constants["value callbacks"])
    styled = cf.CFAttributedStringCreate(None, string, attributes) if attributes else None
    line = ct.CTLineCreateWithAttributedString(styled) if styled else None
    width, x_height = 0.0, 0.0
    if line:
        ascent, descent, leading = ctypes.c_double(), ctypes.c_double(), ctypes.c_double()
        width = float(ct.CTLineGetTypographicBounds(line, ctypes.byref(ascent), ctypes.byref(descent), ctypes.byref(leading)))
        x_height = float(ct.CTFontGetXHeight(font))
    for made in (styled, attributes, string, font):
        if made:
            cf.CFRelease(made)
    return line, width, x_height


_widths: dict = {}


def text_width(text: str) -> float | None:
    """How wide DynamicLake draws `text` in a sneak peek, in points (see
    PEEK_FONT), or None where it can't be measured (not a Mac)."""
    if text in _widths:
        return _widths[text]
    libs = _draw_libs()
    if libs is None:
        return None
    cf, _, ct, constants = libs
    width = None
    try:
        if "peek font" not in _draw:          # (kept for good)
            name = cf.CFStringCreateWithCString(None, PEEK_FONT.encode("utf-8"), 0x08000100)
            font = ct.CTFontCreateWithName(name, PEEK_FONT_SIZE, None) if name else None
            if name:
                cf.CFRelease(name)
            _draw["peek font"] = font or ct.CTFontCreateUIFontForLanguage(3, PEEK_FONT_SIZE, None)
        font = _draw["peek font"]
        string = cf.CFStringCreateWithCString(None, text.encode("utf-8"), 0x08000100)
        attributes = None
        if font and string:
            keys = (ctypes.c_void_p * 1)(constants["font"])
            values = (ctypes.c_void_p * 1)(font)
            attributes = cf.CFDictionaryCreate(None, keys, values, 1, constants["key callbacks"], constants["value callbacks"])
        styled = cf.CFAttributedStringCreate(None, string, attributes) if attributes else None
        line = ct.CTLineCreateWithAttributedString(styled) if styled else None
        if line:
            width = float(ct.CTLineGetTypographicBounds(line, None, None, None))
        for made in (line, styled, attributes, string):
            if made:
                cf.CFRelease(made)
    except Exception:
        width = None
    if len(_widths) > 4000:
        _widths.clear()
    _widths[text] = width
    return width


def fitted_text(text: str) -> str | None:
    """`text` cut to what the sneak peek shows whole, ending with "…"; None
    when all of it fits."""
    whole = text_width(text)
    if whole is None:                         # (by the number of characters, then)
        return None if len(text) <= FIT_CHARS else text[:FIT_CHARS - 1].rstrip(" .•") + "…"
    if whole <= FIT_POINTS:
        return None
    low, high = 0, len(text)                  # (the longest beginning that fits with its "…")
    while high - low > 1:
        middle = (low + high) // 2
        if (text_width(text[:middle].rstrip(" .•") + "…") or 0.0) <= FIT_POINTS:
            low = middle
        else:
            high = middle
    return text[:low].rstrip(" .•") + "…"


def _padding(points: float) -> str:
    """Spaces adding up to `points` (to within half a point), followed by
    the character that keeps them from being trimmed; "" for less."""
    out = ""
    for space in (" ", "\u2009", "\u200a"):            # an ordinary one, a thin one, a hair one
        both, none = text_width("x" + space + "x"), text_width("xx")
        if both is None or none is None or both - none <= 0.1:
            continue
        each = both - none
        count = int((points + (each / 2 if space == "\u200a" else 0.0)) // each)
        out += space * count
        points -= count * each
    return out + PAD_END if out else ""


_DIGIT = re.compile(r"[0-9]")


def same_width(shown: str, other: str) -> str:
    """`shown`, followed by enough space to be as wide as the wider of the
    two: where one takes the other's place (the speed and the time left, in
    turn), the line then stays where it is. Digits count as the widest one,
    so that it doesn't move every second either. As it is where widths
    can't be measured."""
    wide = [text_width(_DIGIT.sub("8", text)) for text in (shown, other)]
    actual = text_width(shown)
    if actual is None or None in wide:
        return shown
    return shown + _padding(max(wide) - actual)


def draw_badge(kind: str, text: str = "") -> bytes | None:
    """One picture, as PNG: kind "type" (`text`, a file's extension) or
    "arrow" (the download arrow), in a blue circle; "failed" (!), "stalled"
    (...) or "blocked" (a bar), in a red circle. None where it can't be
    drawn."""
    libs = _draw_libs()
    if libs is None:
        return None
    cf, cg, ct, _ = libs
    size = BADGE_PIXELS
    colour, dim = (_BADGE_BLUE, 0.24) if kind in ("type", "arrow") else (_BADGE_RED, 0.22)
    pixels = ctypes.create_string_buffer(size * size * 4)
    space = cg.CGColorSpaceCreateDeviceRGB()
    # (8 bits a colour, premultiplied alpha last, bytes in R G B A order)
    context = cg.CGBitmapContextCreate(pixels, size, size, 8, size * 4, space, 1 | (4 << 12)) if space else None
    if space:
        cg.CGColorSpaceRelease(space)
    if not context:
        return None
    try:
        cg.CGContextSetRGBFillColor(context, colour[0], colour[1], colour[2], dim)
        cg.CGContextFillEllipseInRect(context, _CGRect(0.0, 0.0, float(size), float(size)))
        cg.CGContextSetRGBFillColor(context, colour[0], colour[1], colour[2], 1.0)
        cg.CGContextSetRGBStrokeColor(context, colour[0], colour[1], colour[2], 1.0)
        cg.CGContextSetLineCap(context, 1)                          # (round ends)

        def stroke(width: float, x0: float, y0: float, x1: float, y1: float) -> None:
            cg.CGContextSetLineWidth(context, size * width)
            cg.CGContextMoveToPoint(context, size * x0, size * y0)
            cg.CGContextAddLineToPoint(context, size * x1, size * y1)
            cg.CGContextStrokePath(context)

        if kind == "type":
            # As large as fits: 80 % of the circle's width at most.
            biggest = size * (0.50 if len(text) <= 2 else 0.44)
            line, width, x_height = _text_line(libs, text, biggest)
            if line and width > size * 0.80:
                cf.CFRelease(line)
                line, width, x_height = _text_line(libs, text, biggest * size * 0.80 / width)
            if not line:
                return None
            cg.CGContextSetTextPosition(context, (size - width) / 2.0, (size - x_height) / 2.0)
            ct.CTLineDraw(line, context)
            cf.CFRelease(line)
        elif kind == "arrow":                                       # pointing down: a shaft and its two-armed head
            stroke(0.085, 0.5, 0.71, 0.5, 0.30)
            stroke(0.085, 0.5, 0.29, 0.33, 0.46)
            stroke(0.085, 0.5, 0.29, 0.67, 0.46)
        elif kind == "failed":                                      # an exclamation mark: a bar and a dot
            stroke(0.085, 0.5, 0.70, 0.5, 0.46)
            stroke(0.094, 0.5, 0.31, 0.5, 0.31)
        elif kind == "stalled":                                     # three dots
            for x in (0.33, 0.5, 0.67):
                stroke(0.098, x, 0.5, x, 0.5)
        elif kind == "blocked":                                     # a horizontal bar
            stroke(0.085, 0.33, 0.5, 0.67, 0.5)
        else:
            return None
    finally:
        cg.CGContextRelease(context)
    raw, straight = pixels.raw, bytearray(size * size * 4)
    for i in range(0, len(raw), 4):
        alpha = raw[i + 3]
        if alpha:
            straight[i] = min(255, (raw[i] * 255 + alpha // 2) // alpha)
            straight[i + 1] = min(255, (raw[i + 1] * 255 + alpha // 2) // alpha)
            straight[i + 2] = min(255, (raw[i + 2] * 255 + alpha // 2) // alpha)
            straight[i + 3] = alpha
    return png_bytes(size, size, bytes(straight))


def badge_image(kind: str, text: str = "") -> dict | None:
    """The image component for one of the plugin's pictures (see draw_badge),
    or None where it can't be drawn. Each is drawn once."""
    key = (kind, text)
    if key not in _badges:
        picture = None
        try:
            data = draw_badge(kind, text)
            if data:
                picture = {"type": "image", "source": "inlineData", "mimeType": "image/png",
                           "base64Data": base64.b64encode(data).decode("ascii")}
        except Exception:
            picture = None
        _badges[key] = picture
    return _badges[key]


# --------------------------------------------------------------------------
# Surfaces (what DynamicLake actually renders)
#
#                    compact pill                sneak peek
#                    left        right           left           center                  right
#   downloading      type        blue ring       red stop       294/871MB · 2 min 34 s  18%
#   stalled          type        red ...         red stop       Stalled • name          18%
#   paused           type        orange pause    green play     Paused • name           18%
#   failed           type        red !           blue retry     Failed • name           18%
#   finished         type        green check     blue folder    Complete • name         blue file
#   canceled         type        red X           blue retry     Canceled • name
#   blocked          type        red bar         (none)         Blocked • name
#   browser closed   type        orange pause    (none)         Browser closed • name   18%
#
# (A paused or failed download whose browser was closed keeps its card, with
# no button: Resume and Retry need the browser.)
# "type" is the file's extension in a blue circle ("pdf", "dmg"...). A new
# download shows the blue download arrow for its first seconds; the arrow
# stays with the setting "File-Type Icons" off, and for a file without an
# extension.
#
# Beside another activity that has the main place, a download is DynamicLake's
# small capsule: it shows "type" alone, in every state (see extra_surface).
#
# The ring's place holds one of DynamicLake's own "status" symbols, or one of
# the plugin's pictures in the same look, and every button is an SF Symbol
# glyph on a tinted circle, so they all share one size and look.
# --------------------------------------------------------------------------

ARROW_SYMBOL = "arrow.down.circle"
BADGE_CHARS = 4               # the most characters of an extension the circle shows
BULLET = " • "           # "Complete • report.pdf"


def badge_text(filename: str) -> str:
    """The file's extension as the blue circle shows it ("report.PDF" ->
    "pdf"; four characters at most), or "" when it has none that can be
    shown (then the arrow stays)."""
    ext = os.path.splitext(filename)[1][1:].lower()
    if not ext or not ext.isascii() or not ext.isalnum():
        return ""
    return ext[:BADGE_CHARS]


def pill_icon_key(dl: "Download", now: float) -> str:
    """What the pill's left side shows: "" for the blue arrow (a download's
    first seconds, the setting "File-Type Icons" off, or no extension),
    else the extension; either one in the same blue circle."""
    if not SETTINGS["fileTypeIcons"]:
        return ""
    if dl.resolved_at is None and now < dl.started_at + ICON_DELAY_SECONDS:
        return ""
    return badge_text(dl.filename)


def _icon(key: str) -> dict:
    """The blue circle with the extension `key` in it, or with the download
    arrow for ""."""
    picture = badge_image("type", key) if key else badge_image("arrow")
    return picture or {"type": "image", "source": "sfSymbol", "systemImage": ARROW_SYMBOL, "tint": "blue"}


def _pill_icon(dl: "Download", now: float | None = None) -> dict:
    return _icon(pill_icon_key(dl, time.monotonic() if now is None else now))


def extra_surface(dl: "Download") -> dict:
    """What DynamicLake's small capsule beside the notch shows for this
    download while another activity has the main place: the file's type in
    its blue circle (the arrow with the setting "File-Type Icons" off, and
    for a file without an extension). DynamicLake draws the capsule once,
    when the card gets there, and not again while it stays: a ring or a
    status symbol would go on showing what was true at that moment. The
    file's type stays true, so it's there from the first second, without
    the arrow's turn."""
    return {"leftSlot": _icon(badge_text(dl.filename) if SETTINGS["fileTypeIcons"] else "")}


def _state_symbol(kind: str) -> dict | None:
    """The pill's right side for a state DynamicLake has no symbol of its
    own for: "failed" (!), "stalled" (...) or "blocked" (a bar), each in a
    red circle. None where it can't be drawn (the caller then uses
    DynamicLake's nearest symbol)."""
    return badge_image(kind)


def status_text(word: str, dl: "Download") -> str:
    """"Complete • report.pdf": what happened, then the file's name
    (the line scrolls when it's long). Never longer than DynamicLake
    accepts: a very long name is shortened in the middle."""
    name = dl.filename
    room = MAX_TEXT_CHARS - len(word) - len(BULLET) - len(LEAD_BLANK)
    if len(name) > room:
        keep = room - 1
        name = name[: keep - keep // 2] + "…" + name[len(name) - keep // 2:]
    return f"{word}{BULLET}{name}"


def status_line(word: str, dl: "Download", now: float | None = None) -> str:
    """The status card's line. When it's too long for the sneak peek,
    DynamicLake scrolls it, and starts at once: the status would be gone
    before it's read. So for SCROLL_HOLD_SECONDS it's shown cut short, which
    stays still ("Paused • Some.Long.Na…"), and only then whole, to scroll --
    with a blank before it, to keep its first letter clear of the fade on
    the left. The time counts from when the status came up, or from when
    the plugin opened the sneak peek for it (Download.line_from)."""
    now = time.monotonic() if now is None else now
    full = status_text(word, dl)
    short = fitted_text(full)
    if dl.line_word != word:
        dl.line_word, dl.line_from = word, now
    if short is None:
        dl.line_phase = ""
        return full
    until = dl.line_from + SCROLL_HOLD_SECONDS
    if now < until:
        dl.line_phase = "held"
        if dl.text_due is None or until < dl.text_due:
            dl.text_due = until
        return short
    dl.line_phase = "scrolling"
    return LEAD_BLANK + full


def _stop_button(dl: "Download") -> dict:
    """Icon-only red square in a red circle -- no "Stop" text on screen. The
    glyph is systemImage "stop.fill", a filled square; shape "circle" is the
    tappable background. `title` is only the VoiceOver label."""
    return {
        "type": "button", "title": "Stop", "systemImage": "stop.fill",
        "actionID": f"stop:{dl.activity_id}", "shape": "circle",
        "tint": "red", "role": "destructive",
    }


def _show_button(dl: "Download") -> dict:
    """Show in Finder: a blue folder in a blue circle, the counterpart of the
    Stop button. `title` is only the VoiceOver label."""
    return {
        "type": "button", "title": "Show in Finder", "systemImage": "folder.fill",
        "actionID": f"show:{dl.activity_id}", "shape": "circle", "tint": "blue",
    }


def _open_button(dl: "Download") -> dict:
    """Open File: the file itself in a blue circle, across from Show in
    Finder's folder. It opens the finished file in the app for its type.
    `title` is only the VoiceOver label."""
    return {
        "type": "button", "title": "Open File", "systemImage": "doc.fill",
        "actionID": f"open:{dl.activity_id}", "shape": "circle", "tint": "blue",
    }


def _resume_button(dl: "Download") -> dict:
    """Resume: a green play triangle in a green circle, where Stop was."""
    return {
        "type": "button", "title": "Resume", "systemImage": "play.fill",
        "actionID": f"resume:{dl.activity_id}", "shape": "circle", "tint": "green",
    }


def _retry_button(dl: "Download", action: str = "retry") -> dict:
    """Retry: a blue circular arrow in a blue circle, where Stop was. The
    action is "retry" on a failed card and "restart" on a canceled one (the
    browser starts that download over)."""
    return {
        "type": "button", "title": "Retry", "systemImage": "arrow.clockwise",
        "actionID": f"{action}:{dl.activity_id}", "shape": "circle", "tint": "blue",
    }


def _percent_slot(text: str, numeric_style: str) -> dict:
    """The sneak peek's right slot. Side slots widen just enough for numeric
    text like "100%"; other text styles show only two characters there, so
    without the numeric style (older DynamicLake) the % sign is dropped and
    a value that still wouldn't fit is left out."""
    if numeric_style == "numeric":
        return {"rightSlot": {"type": "text", "text": text, "style": "numeric"}}
    short = text.rstrip("%")
    if len(short) > 2:
        return {}
    return {"rightSlot": {"type": "text", "text": short, "style": numeric_style}}


def rate_text(dl: "Download", now: float) -> str:
    """After the amounts (setting "Download Details"): the speed, the time
    left, or the two in turn, DETAILS_TURN_SECONDS each -- each then as wide
    as the wider of the two (same_width), so that the line stays where it
    is when they change places. The speed also shows where the time left
    can't be told yet. Sets `dl.text_due`: when this text changes by itself
    (the next second of the time left, the next turn), for the main loop to
    send it on time."""
    details = SETTINGS["downloadDetails"]
    speed = human_speed(dl.speed)
    if details == "speed":
        return speed
    turn, into = divmod(max(0.0, now - dl.started_at), DETAILS_TURN_SECONDS)
    if details == "both":
        dl.text_due = now + DETAILS_TURN_SECONDS - into
    left = dl.time_left(now)
    if left is None:
        return speed
    timed = human_time(left)
    if details == "both" and int(turn) % 2 == 0:       # (the speed first)
        return same_width(speed, timed)
    tick = dl.time_tick_at
    if tick is not None and (dl.text_due is None or tick < dl.text_due):
        dl.text_due = tick
    return same_width(timed, speed) if details == "both" else timed


def in_progress_surfaces(dl: "Download", numeric_style: str = "compact",
                         stalled: bool = False, now: float | None = None) -> dict:
    now = time.monotonic() if now is None else now
    pct = dl.percent
    if stalled:
        center = status_line("Stalled", dl, now)
    elif pct is not None:
        center = f"{human_pair(dl.size, dl.total_size)} · {rate_text(dl, now)}"
    else:
        center = f"{human_amount(dl.size)} · {human_speed(dl.speed)}"
    ring: dict = {"type": "progress", "tint": "blue"}
    if pct is not None:
        ring["value"] = round(pct, 4)   # a real, filling ring
    # (without a value DynamicLake draws a spinning ring: the size isn't
    # known yet, or the server never sent one)
    if stalled:
        ring = _state_symbol("stalled") or ring
    return {
        "compactLiveActivity": {"leftSlot": _pill_icon(dl, now), "rightSlot": ring},
        "sneakPeek": {
            "leftSlot": _stop_button(dl),
            "center": {"type": "text", "text": center, "style": "marquee"},
            **_percent_slot(dl.percent_text, numeric_style),
        },
    }


def done_surfaces(dl: "Download", numeric_style: str = "compact", now: float | None = None) -> dict:
    return {
        "compactLiveActivity": {
            "leftSlot": _pill_icon(dl),
            "rightSlot": {"type": "status", "status": "success", "tint": "green"},
        },
        "sneakPeek": {
            "leftSlot": _show_button(dl),
            "center": {"type": "text", "text": status_line("Complete", dl, now), "style": "marquee"},
            "rightSlot": _open_button(dl),
        },
    }


def canceled_surfaces(dl: "Download", reason: str, now: float | None = None) -> dict:
    """Canceled (in the browser, by Stop, or given up by the browser): Retry
    starts it over, like the panel's own Retry. Blocked: nothing to press
    here -- only you can decide about it, in the browser."""
    sneak_peek: dict = {"center": {"type": "text", "text": status_line(reason, dl, now), "style": "marquee"}}
    symbol = {"type": "status", "status": "failed", "tint": "red"}     # (DynamicLake's red X)
    if reason == "Canceled":
        sneak_peek = {"leftSlot": _retry_button(dl, "restart"), **sneak_peek}
    else:
        symbol = _state_symbol("blocked") or symbol
    return {
        "compactLiveActivity": {"leftSlot": _pill_icon(dl), "rightSlot": symbol},
        "sneakPeek": sneak_peek,
    }


def _kept_percent_slot(dl: "Download", numeric_style: str) -> dict:
    """How far a paused or failed download got (its data is kept, so Resume
    or Retry carries on from there); nothing when the size isn't known."""
    return _percent_slot(dl.percent_text, numeric_style) if dl.percent is not None else {}


def paused_surfaces(dl: "Download", numeric_style: str = "compact", with_button: bool = True,
                    word: str = "Paused", now: float | None = None) -> dict:
    sneak_peek: dict = {"center": {"type": "text", "text": status_line(word, dl, now), "style": "marquee"},
                        **_kept_percent_slot(dl, numeric_style)}
    if with_button:
        sneak_peek = {"leftSlot": _resume_button(dl), **sneak_peek}
    return {
        "compactLiveActivity": {
            "leftSlot": _pill_icon(dl, now),
            "rightSlot": {"type": "status", "status": "paused", "tint": "orange"},
        },
        "sneakPeek": sneak_peek,
    }


def failed_surfaces(dl: "Download", numeric_style: str = "compact", with_button: bool = True,
                    now: float | None = None) -> dict:
    sneak_peek: dict = {"center": {"type": "text", "text": status_line("Failed", dl, now), "style": "marquee"},
                        **_kept_percent_slot(dl, numeric_style)}
    if with_button:
        sneak_peek = {"leftSlot": _retry_button(dl), **sneak_peek}
    return {
        "compactLiveActivity": {
            "leftSlot": _pill_icon(dl, now),
            "rightSlot": _state_symbol("failed") or {"type": "status", "status": "failed", "tint": "red"},
        },
        "sneakPeek": sneak_peek,
    }


# --------------------------------------------------------------------------
# Stop, Resume, Retry -- through the browser's Downloads panel (macOS
# Accessibility)
# --------------------------------------------------------------------------

# The script the buttons run ("mode:cancel", "mode:resume", "mode:retry").
# It is compiled once (osacompile) into ~/Library/Caches/FirefoxDownloads, so
# later runs skip the compile step.
_AX_CANCEL_SCRIPT = r'''
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
    set restText to statusText as string
    -- leading spaces and direction marks (right-to-left languages)
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
    if restText is "" then return ""
    if my cachedStateWords is missing value then set my cachedStateWords to {{"paused", my pausedWords()}, {"failed", my failedWords()}, {"canceled", my canceledWords()}}
    repeat with kindPair in my cachedStateWords
        repeat with oneWord in (item 2 of kindPair)
            if restText starts with (contents of oneWord) then return (item 1 of kindPair)
        end repeat
    end repeat
    return ""
end statusKindOf

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
    -- reads "<file name> <status> <button label>", so the name must match
    -- with the same case and be followed by a space (or end the title): a
    -- row for "report.pdf.zip" is not a row for "report.pdf".
    set titleLen to length of rowTitle
    repeat with v in nameVariants
        set oneName to (contents of v) as string
        set nameLen to length of oneName
        if nameLen > 0 and not (titleLen < nameLen) then
            set samePrefix to false
            considering case
                if (text 1 thru nameLen of rowTitle) is oneName then set samePrefix to true
            end considering
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
        if scanKind is not "" and (my rowKind(nowTitle, nameVariants)) is not scanKind then return {"menu-changed", "the row changed; ", frameText}
    end if
    if not (my wholeNameStill(listRef, rowIdx, my wholeNameList)) then return {"menu-changed", "the row's file changed; ", frameText}
    return {"menu-shown", "row menu shown (selected=" & (rowSelected as string) & "); ", frameText}
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
'''

# A slower, element-by-element version of the same search, with the same
# safety rules. Used only if the script above cannot run.
_AX_FALLBACK_SCRIPT = r'''
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
    set restText to statusText as string
    -- leading spaces and direction marks (right-to-left languages)
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
    if restText is "" then return ""
    if my cachedStateWords is missing value then set my cachedStateWords to {{"paused", my pausedWords()}, {"failed", my failedWords()}, {"canceled", my canceledWords()}}
    repeat with kindPair in my cachedStateWords
        repeat with oneWord in (item 2 of kindPair)
            if restText starts with (contents of oneWord) then return (item 1 of kindPair)
        end repeat
    end repeat
    return ""
end statusKindOf

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
    -- reads "<file name> <status> <button label>", so the name must match
    -- with the same case and be followed by a space (or end the title): a
    -- row for "report.pdf.zip" is not a row for "report.pdf".
    set titleLen to length of rowTitle
    repeat with v in nameVariants
        set oneName to (contents of v) as string
        set nameLen to length of oneName
        if nameLen > 0 and not (titleLen < nameLen) then
            set samePrefix to false
            considering case
                if (text 1 thru nameLen of rowTitle) is oneName then set samePrefix to true
            end considering
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
        if scanKind is not "" and (my rowKind(nowTitle, nameVariants)) is not scanKind then return {"menu-changed", "the row changed; ", frameText}
    end if
    if not (my wholeNameStill(listRef, rowIdx, my wholeNameList)) then return {"menu-changed", "the row's file changed; ", frameText}
    return {"menu-shown", "row menu shown (selected=" & (rowSelected as string) & "); ", frameText}
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
'''

# What the plugin shows for each outcome the scripts can return, per button.
# The "-sent" outcomes are not in here: the plugin then waits for the
# browser (the .part file disappearing, or growing again).
_COMMON_NOTICES = {
    "accessibility-not-granted": "Needs Accessibility access",
    "automation-not-granted": "Needs Automation access",
    "no-match": "Not in the Downloads panel",
    "changed": "Panel busy — try again",
    "no-panel": "Downloads panel didn't open",
    "no-button": "No Downloads button in toolbar",
    "no-browser": "Browser isn't running",
}
ACTION_NOTICES = {
    "stop": {**_COMMON_NOTICES,
             "ambiguous": "Several matches — cancel in browser",
             "not-active": "Not in the Downloads panel"},
    "resume": {**_COMMON_NOTICES,
               "ambiguous": "Several matches — resume in browser",
               "not-active": "Not paused in the browser",
               "not-paused": "Not paused in the browser",
               "no-menu": "No menu — resume in browser",
               "show-error": "No menu — resume in browser",
               "wrong-menu": "No menu — resume in browser",
               "row-hidden": "Row hidden — resume in browser",
               "menu-changed": "Panel busy — try again",
               "not-pressed": "Resume failed — resume in browser",
               "menu-open": "Menu left open — click elsewhere"},
    "retry": {**_COMMON_NOTICES,
              "ambiguous": "Several matches — retry in browser",
              "not-active": "Nothing to retry in the panel"},
}
# "restart": the Retry button of a canceled card (the panel's Retry of a
# canceled download, which starts it over).
ACTION_NOTICES["restart"] = ACTION_NOTICES["retry"]
WORKING_NOTICES = {"stop": "Stopping…", "resume": "Resuming…", "retry": "Retrying…", "restart": "Retrying…"}
GAVE_UP_NOTICES = {"stop": "Didn't stop — cancel in browser",
                   "resume": "Didn't resume — resume in browser",
                   "retry": "Didn't restart — retry in browser",
                   "restart": "Didn't restart — retry in browser"}
# Pressed (or the press reported an error but may have gone through): wait
# for the browser.
SENT_OUTCOMES = {"stop": ("cancel-sent", "press-failed"),
                 "resume": ("resume-sent", "press-failed"),
                 "retry": ("retry-sent", "press-failed"),
                 "restart": ("restart-sent", "press-failed")}
FALLBACK_NOTICE = "Couldn't reach the browser"
STOP_OUTCOME_NOTICES = ACTION_NOTICES["stop"]
STOP_FALLBACK_NOTICE = FALLBACK_NOTICE
STOP_GAVE_UP_NOTICE = GAVE_UP_NOTICES["stop"]

# Outcomes that mean "the script itself broke", so the fallback script runs.
_SCRIPT_FAILURES = {"script-error", "syntax-error", "error"}

_AX_LOCK = threading.Lock()       # one browser automation at a time
_COMPILE_LOCK = threading.Lock()  # guards _script_state
_script_state: dict = {
    "compiled": None,          # Path of the compiled script, once built
    "compile_failed": False,   # osacompile could not build it
    "fast_broken": False,      # the main script failed: use the fallback
    "fast_failures": 0,
}


def name_forms(filename: str) -> list[str]:
    """The file name as stored on disk, plus its composed (NFC) and
    decomposed (NFD) Unicode forms when those differ, so an accented name
    matches the panel however it was stored."""
    forms = [filename]
    for form in ("NFC", "NFD"):
        variant = unicodedata.normalize(form, filename)
        if variant not in forms:
            forms.append(variant)
    return forms


def script_cache_dir() -> Path:
    return Path.home() / "Library" / "Caches" / PLUGIN_FOLDER_NAME


def compiled_fast_script() -> Path | None:
    """Compile the Stop script once and reuse it: running a compiled script
    skips parsing it and loading System Events' dictionary on every press.
    Returns None when it can't be compiled (the script then runs as text)."""
    with _COMPILE_LOCK:
        cached = _script_state["compiled"]
        if cached is not None and cached.exists():
            return cached
        if _script_state["compile_failed"] or _script_state["fast_broken"]:
            return None
        digest = hashlib.sha1(_AX_CANCEL_SCRIPT.encode("utf-8")).hexdigest()[:12]
        cache_dir = script_cache_dir()
        target = cache_dir / f"stop-{digest}.scpt"
        if target.exists():
            _script_state["compiled"] = target
            return target
        source = cache_dir / f"stop-{digest}.applescript"
        scratch = cache_dir / f"stop-{digest}-{os.getpid()}.scpt"
        try:
            cache_dir.mkdir(parents=True, exist_ok=True)
            source.write_text(_AX_CANCEL_SCRIPT, encoding="utf-8")
            result = subprocess.run(["osacompile", "-o", str(scratch), str(source)],
                                    capture_output=True, text=True, timeout=60)
            if result.returncode != 0 or not scratch.exists():
                err = " ".join((result.stderr or "").split())
                _script_state["compile_failed"] = True
                if "syntax error" in err.lower():
                    _script_state["fast_broken"] = True
                log_event(f"compiling the Stop script failed ({err or result.returncode}); "
                          + ("using the fallback script" if _script_state["fast_broken"]
                             else "running it uncompiled"))
                return None
            os.replace(scratch, target)
        except (OSError, subprocess.SubprocessError) as exc:
            _script_state["compile_failed"] = True
            log_event(f"compiling the Stop script failed ({exc!r}); running it uncompiled")
            return None
        finally:
            for leftover in (source, scratch):
                try:
                    leftover.unlink()
                except OSError:
                    pass
        for old in cache_dir.glob("stop-*.scpt"):
            if old != target:
                try:
                    old.unlink()
                except OSError:
                    pass
        _script_state["compiled"] = target
        return target


def start_precompile() -> None:
    """Compile the Stop script in the background, so the first Stop doesn't
    wait for it."""
    threading.Thread(target=lambda: compiled_fast_script(), daemon=True).start()


def permission_outcome(text: str) -> str | None:
    """Recognise a missing permission. The scripts mark these errors
    ("assistive-access-denied:", "automation-denied:") so they are
    recognised whatever language macOS is set to."""
    low = text.lower()
    if "automation-denied" in low or "not authorized" in low or "-1743" in low:
        return "automation-not-granted"
    if "assistive-access-denied" in low or "assistive" in low or "not allowed" in low or "-25211" in low:
        return "accessibility-not-granted"
    return None


ScriptResult = tuple  # (outcome, trace, browser process, button position, row frame, process id)


def parse_script_output(output: str) -> ScriptResult:
    """"outcome|trace|process|position|frame|pid" -> (outcome, trace,
    process, position, frame, pid). For Resume, the frame ("x,y,w,h") is the
    row whose right-click menu was shown (the browser opens the menu, and
    puts the pointer, in its middle) and pid is the browser's process id.
    Shorter forms are accepted too."""
    parts = output.strip().split("|")
    outcome = parts[0].strip() or "error"
    browser = position = spot = pid = ""
    if len(parts) >= 6:
        trace, browser = "|".join(parts[1:-4]), parts[-4].strip()
        position, spot, pid = parts[-3].strip(), parts[-2].strip(), parts[-1].strip()
    elif len(parts) == 5:
        trace, browser = parts[1], parts[2].strip()
        position, spot = parts[3].strip(), parts[4].strip()
    elif len(parts) == 4:
        trace, browser, position = parts[1], parts[2].strip(), parts[3].strip()
    elif len(parts) == 3:
        trace, browser = parts[1], parts[2].strip()
    else:
        trace = "|".join(parts[1:])
    trace = " ".join(trace.split())
    if outcome == "script-error":
        outcome = permission_outcome(trace) or outcome
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", position):
        position = ""
    if not re.fullmatch(r"-?\d+,-?\d+,\d+,\d+", spot):
        spot = ""
    if not re.fullmatch(r"\d+", pid):
        pid = ""
    return outcome, trace, browser, position, spot, pid


_MENU_AT = re.compile(r"^menu-at\|(-?\d+,-?\d+,\d+,\d+)\|(\d+)[ \t]*\r?$", re.M)


def menu_breadcrumb(stderr) -> tuple[str, str, str]:
    """(stderr without it, frame, pid). Right before showing a row's menu,
    the scripts log "menu-at|x,y,w,h|pid" (to stderr), so that a run that
    is cut short or breaks still tells where a menu may be open."""
    if isinstance(stderr, bytes):
        stderr = stderr.decode("utf-8", "replace")
    text = stderr or ""
    frame = pid = ""
    for m in _MENU_AT.finditer(text):
        frame, pid = m.group(1), m.group(2)
    return _MENU_AT.sub("", text), frame, pid


def _run_script(cmd: list[str]) -> ScriptResult:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=STOP_SCRIPT_TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        _, frame, pid = menu_breadcrumb(exc.stderr)
        return "timeout", f"no answer within {STOP_SCRIPT_TIMEOUT} s", "", "", frame, pid
    except OSError as exc:
        return "unavailable", str(exc), "", "", "", ""
    output = (result.stdout or "").strip()
    stderr, frame, pid = menu_breadcrumb(result.stderr)
    if result.returncode == 0 and output:
        parsed = parse_script_output(output)
        if not parsed[4] and frame:        # it broke after showing a menu
            parsed = parsed[:4] + (frame, pid)
        return parsed
    err = " ".join(stderr.split())
    mapped = permission_outcome(err)
    if mapped:
        return mapped, err, "", "", frame, pid
    if "syntax error" in err.lower():
        return "syntax-error", err, "", "", "", ""
    return "error", err or f"osascript exited with code {result.returncode}", "", "", frame, pid


def run_ax_script(script_args: list[str], allow_fallback: bool = True,
                  fallback_after_run: bool = True) -> ScriptResult:
    """Run the main script (compiled when possible). If the script itself
    breaks, run the slower fallback script instead -- unless allow_fallback
    is False (the warm-up, which the fallback doesn't do), or the main script
    broke while running and fallback_after_run is False (Resume: it may have
    shown a menu already, and must not show another)."""
    notes = ""
    if not _script_state["fast_broken"]:
        compiled = compiled_fast_script()
        if compiled is not None:
            cmd = ["osascript", str(compiled)]
        else:
            cmd = ["osascript", "-e", _AX_CANCEL_SCRIPT]
        result = _run_script(cmd + script_args)
        if result[0] not in _SCRIPT_FAILURES:
            return result
        with _COMPILE_LOCK:
            _script_state["fast_failures"] += 1
            if result[0] == "syntax-error" or _script_state["fast_failures"] >= 2:
                _script_state["fast_broken"] = True
        notes = f"main script failed ({result[0]}: {result[1]}); "
        if not allow_fallback or (result[0] != "syntax-error" and not fallback_after_run):
            return result[0], notes.strip(), result[2], "", result[4], result[5]
    elif not allow_fallback:
        return "unavailable", "the main script can't run in this session", "", "", "", ""
    outcome, trace, browser, _, spot, pid = _run_script(["osascript", "-e", _AX_FALLBACK_SCRIPT] + script_args)
    return outcome, f"{notes}fallback script: {trace}", browser, "", spot, pid


def hint_args(proc_hint: str | None, button_hint: str | None) -> list[str]:
    args = []
    if proc_hint:
        args.append("proc:" + proc_hint)
        if button_hint:
            args.append("btn:" + button_hint)  # only meaningful for that browser
    return args


def request_browser_action(mode: str, filename: str, fallback_name: str | None = None,
                           proc_hint: str | None = None, button_hint: str | None = None) -> ScriptResult:
    """Run the script for one download: mode "cancel" (Stop), "resume" or
    "retry". Returns (outcome, trace, browser process, button position, row
    frame, process id). `filename` is the real name the panel shows;
    `fallback_name` (the name as found on disk) is also tried;
    `proc_hint`/`button_hint` are the browser to try first and where its
    toolbar button was last time (checked before use). Needs Accessibility
    permission."""
    names = name_forms(filename)
    if fallback_name and fallback_name != filename:
        names += [n for n in name_forms(fallback_name) if n not in names]
    return run_ax_script(["mode:" + mode] + ["name:" + n for n in names] + hint_args(proc_hint, button_hint),
                         fallback_after_run=(mode != "resume"))


def request_browser_cancel(filename: str, fallback_name: str | None = None,
                           proc_hint: str | None = None, button_hint: str | None = None) -> ScriptResult:
    """Stop: press the row's Cancel button."""
    return request_browser_action("cancel", filename, fallback_name, proc_hint, button_hint)


def request_browser_resume(filename: str, fallback_name: str | None = None,
                           proc_hint: str | None = None, button_hint: str | None = None,
                           clicked_at=None) -> ScriptResult:
    """Resume: the script shows the paused row's right-click menu (and
    checks it opened for that row); the plugin then chooses Resume in it --
    see choose_in_row_menu. Whenever a menu may have been shown and the
    script didn't confirm it's this row's ("menu-changed", "show-error", or
    a run cut short), the plugin only looks for it and closes it: a menu is
    never left open without saying so. clicked_at() is where the browser
    put the pointer to open the menu, when the pointer guard saw it."""
    ax = accessibility()
    if ax is None:
        return "unavailable", "the macOS Accessibility API couldn't be loaded", "", "", "", ""
    if not ax.trusted():
        return "accessibility-not-granted", "not trusted for Accessibility (checked before showing a menu)", "", "", "", ""
    result = tuple(request_browser_action("resume", filename, fallback_name, proc_hint, button_hint))
    result += ("",) * max(0, 6 - len(result))
    outcome, trace, browser, position, frame, pid = result[:6]
    closing_outcome = {"show-error": "no-menu"}.get(outcome, outcome)   # what's reported after only closing
    where = _parse_frame(frame)
    if where is None or not pid.isdigit():
        if outcome in ("menu-shown", "show-error"):
            return "no-menu", f"{trace} the script didn't say where the menu is;", browser, position, frame, pid
        return (closing_outcome,) + result[1:6]
    press = outcome == "menu-shown"
    menu_outcome, menu_trace = choose_in_row_menu(ax, int(pid), where, press=press, clicked_at=clicked_at)
    if not press and menu_outcome != "menu-open":
        menu_outcome = closing_outcome
    return menu_outcome, f"{trace} {menu_trace}".strip(), browser, position, frame, pid


def request_browser_retry(filename: str, fallback_name: str | None = None,
                          proc_hint: str | None = None, button_hint: str | None = None) -> ScriptResult:
    """Retry: press the failed row's Retry button."""
    return request_browser_action("retry", filename, fallback_name, proc_hint, button_hint)


def request_browser_restart(filename: str, fallback_name: str | None = None,
                            proc_hint: str | None = None, button_hint: str | None = None) -> ScriptResult:
    """Retry on a canceled card: press the Retry button of the row showing
    Canceled (or Failed, for a download the browser gave up on and whose
    partial file it deleted). The browser starts it over."""
    return request_browser_action("restart", filename, fallback_name, proc_hint, button_hint)


def request_browser_locate(proc_hint: str | None = None, button_hint: str | None = None) -> ScriptResult:
    """Warm-up: find the browser's toolbar Downloads button and press
    nothing. This starts System Events and the browser's accessibility
    support ahead of time, so the first button press doesn't pay for it."""
    return run_ax_script(["mode:locate"] + hint_args(proc_hint, button_hint), allow_fallback=False)


# --------------------------------------------------------------------------
# The pointer: to open a row's right-click menu (for Resume), the browser
# moves the pointer onto the row. It is put straight back: the moment it
# jumps without any mouse or trackpad input, which is the browser, not you.
# CoreGraphics through ctypes, both part of macOS and Python.
# --------------------------------------------------------------------------

class _CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_quartz: dict = {}
_HID_STATE = 1                 # kCGEventSourceStateHIDSystemState: input from devices
_SESSION_STATE = 0             # kCGEventSourceStateCombinedSessionState: that, and input
                               # apps post for you (remote sessions, Voice Control...)
_ANY_INPUT = 0xFFFFFFFF        # kCGAnyInputEventType
_PRESSES = (1, 3, 25, 10)      # kCGEventLeftMouseDown, RightMouseDown, OtherMouseDown, KeyDown
_TOUCHES = (12, 22)            # kCGEventFlagsChanged (a modifier key), ScrollWheel


def _quartz_libs():
    """(CoreGraphics, CoreFoundation), or None where they can't be loaded."""
    if "libs" not in _quartz:
        libs = None
        try:
            cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            cg.CGEventCreate.restype = ctypes.c_void_p
            cg.CGEventCreate.argtypes = [ctypes.c_void_p]
            cg.CGEventGetLocation.restype = _CGPoint
            cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
            cg.CGWarpMouseCursorPosition.restype = ctypes.c_int32
            cg.CGWarpMouseCursorPosition.argtypes = [_CGPoint]
            cg.CGAssociateMouseAndMouseCursorPosition.restype = ctypes.c_int32
            cg.CGAssociateMouseAndMouseCursorPosition.argtypes = [ctypes.c_int]
            cg.CGEventSourceCounterForEventType.restype = ctypes.c_uint32
            cg.CGEventSourceCounterForEventType.argtypes = [ctypes.c_int32, ctypes.c_uint32]
            cg.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
            cg.CGEventSourceSecondsSinceLastEventType.argtypes = [ctypes.c_int32, ctypes.c_uint32]
            cf.CFRelease.restype = None
            cf.CFRelease.argtypes = [ctypes.c_void_p]
            libs = (cg, cf)
        except (OSError, AttributeError):
            libs = None
        _quartz["libs"] = libs
    return _quartz["libs"]


def pointer_location() -> tuple[float, float] | None:
    """Where the pointer is, in screen points (top-left origin), or None."""
    libs = _quartz_libs()
    if libs is None:
        return None
    cg, cf = libs
    try:
        event = cg.CGEventCreate(None)
        if not event:
            return None
        try:
            point = cg.CGEventGetLocation(event)
            return float(point.x), float(point.y)
        finally:
            cf.CFRelease(event)
    except Exception:
        return None


def input_event_count() -> int | None:
    """How many mouse, trackpad and keyboard events macOS has seen so far.
    The browser moving the pointer adds none."""
    libs = _quartz_libs()
    if libs is None:
        return None
    try:
        return int(libs[0].CGEventSourceCounterForEventType(_HID_STATE, _ANY_INPUT))
    except Exception:
        return None


def _session_libs():
    """(CoreGraphics, CoreFoundation, {key: CFString}) set up for reading the
    login session's record, or None. Kept apart from _quartz_libs, so that a
    missing function here can't disable the pointer handling."""
    if "session" not in _quartz:
        found = None
        try:
            cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
            cg.CGSessionCopyCurrentDictionary.argtypes = []
            cf.CFDictionaryGetValue.restype = ctypes.c_void_p
            cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
            cf.CFStringCreateWithCString.restype = ctypes.c_void_p
            cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
            cf.CFGetTypeID.restype = ctypes.c_ulong
            cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
            cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
            cf.CFBooleanGetTypeID.argtypes = []
            cf.CFBooleanGetValue.restype = ctypes.c_bool
            cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
            cf.CFRelease.restype = None
            cf.CFRelease.argtypes = [ctypes.c_void_p]
            keys = {k: cf.CFStringCreateWithCString(None, k.encode(), 0x08000100)   # kept for good
                    for k in ("CGSSessionScreenIsLocked", "kCGSSessionOnConsoleKey")}
            found = (cg, cf, keys) if all(keys.values()) else None
        except (OSError, AttributeError):
            found = None
        _quartz["session"] = found
    return _quartz["session"]


def screen_locked() -> bool | None:
    """Whether the screen is locked (or this login isn't the one on screen),
    from the login session's own record; None when unknown."""
    libs = _session_libs()
    if libs is None:
        return None
    cg, cf, keys = libs

    def flag(info, key):
        value = cf.CFDictionaryGetValue(info, keys[key])
        if not value or cf.CFGetTypeID(value) != cf.CFBooleanGetTypeID():
            return None
        return bool(cf.CFBooleanGetValue(value))

    try:
        info = cg.CGSessionCopyCurrentDictionary()
        if not info:
            return None
        try:
            return flag(info, "CGSSessionScreenIsLocked") is True or flag(info, "kCGSSessionOnConsoleKey") is False
        finally:
            cf.CFRelease(info)
    except Exception:
        return None


def seconds_since_input(state: int = _HID_STATE) -> float | None:
    """How long since your last mouse, trackpad or keyboard input."""
    libs = _quartz_libs()
    if libs is None:
        return None
    try:
        return float(libs[0].CGEventSourceSecondsSinceLastEventType(state, _ANY_INPUT))
    except Exception:
        return None


def seconds_since_press() -> float | None:
    """How long since your last click, key press (modifier keys too) or
    scroll (from devices; moving the pointer doesn't count)."""
    libs = _quartz_libs()
    if libs is None:
        return None
    try:
        return min(float(libs[0].CGEventSourceSecondsSinceLastEventType(_HID_STATE, t)) for t in _PRESSES + _TOUCHES)
    except Exception:
        return None


def press_count() -> int | None:
    """How many clicks and key presses macOS has seen so far (from devices:
    the browser opening a menu adds none)."""
    libs = _quartz_libs()
    if libs is None:
        return None
    try:
        return sum(int(libs[0].CGEventSourceCounterForEventType(_HID_STATE, t)) for t in _PRESSES)
    except Exception:
        return None


def move_pointer(x: float, y: float) -> bool:
    libs = _quartz_libs()
    if libs is None:
        return False
    cg, _ = libs
    try:
        moved = cg.CGWarpMouseCursorPosition(_CGPoint(x, y)) == 0
        cg.CGAssociateMouseAndMouseCursorPosition(1)
        return moved
    except Exception:
        return False


class PointerGuard:
    """While Resume's steps run, put the pointer back the moment the browser
    moves it: that's the browser moving it onto the row to open its menu
    (the menu opens there either way). A jump counts as the browser's when
    macOS saw no input from you meanwhile, or when it's too far, too fast
    and too sudden for a hand: over 150 points within one 5 ms look, at
    least 4 times faster than the look before (a hand speeds up gradually).
    Where the browser put the pointer (restored_from) is where it clicked:
    the corner of the menu."""

    POLL = 0.005
    QUIET = 0.05          # seconds without input before a small jump counts as the browser's
    FAR = 150.0           # points
    FAST = 20000.0        # points per second
    SUDDEN = 4.0          # times the speed of the look before

    def __init__(self):
        self.before = pointer_location()
        self.restored_from: tuple[float, float] | None = None   # where the browser last put it
        self.restores = 0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "PointerGuard":
        if self.before is not None:
            self._thread = threading.Thread(target=self._watch, daemon=True)
            self._thread.start()
        return self

    def _watch(self) -> None:
        last, count, at, speed = self.before, input_event_count(), time.monotonic(), 0.0
        while not self._stop.wait(self.POLL):
            now, now_count, idle, now_at = pointer_location(), input_event_count(), seconds_since_input(), time.monotonic()
            if now is None or last is None:
                return
            dist = max(abs(now[0] - last[0]), abs(now[1] - last[1]))
            now_speed = dist / max(now_at - at, 1e-3)
            quiet = count is not None and now_count == count and idle is not None and idle >= self.QUIET
            flung = dist > self.FAR and now_speed > self.FAST and now_speed > self.SUDDEN * speed
            if dist > 2 and (quiet or flung):
                # (It keeps watching: the fallback script may show the menu again.)
                if move_pointer(*last):
                    self.restored_from = now
                    self.restores += 1
                    count, at, speed = input_event_count(), time.monotonic(), 0.0
                    continue
                return
            last, count, at, speed = now, now_count, now_at, now_speed

    def __exit__(self, *exc) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(0.5)


def _parse_frame(frame: str) -> tuple[float, float, float, float] | None:
    m = re.fullmatch(r"(-?\d+),(-?\d+),(\d+),(\d+)", frame or "")
    return tuple(float(g) for g in m.groups()) if m else None


def put_pointer_back(result: ScriptResult, before: tuple[float, float] | None) -> ScriptResult:
    """After Resume, when the guard didn't catch it: if the pointer is still
    on the row whose menu was shown (the script reports its frame), move it
    back to where it was before. If you've moved it since, leave it alone."""
    result = tuple(result) + ("",) * max(0, 6 - len(result))
    frame = _parse_frame(result[4])
    if frame is None or before is None:
        return result
    now = pointer_location()
    if now is None:
        return result
    x, y, w, h = frame
    inside = lambda p: x - 2 <= p[0] <= x + w + 2 and y - 2 <= p[1] <= y + h + 2
    if not inside(now) or inside(before):
        return result
    note = "pointer put back" if move_pointer(*before) else "pointer could not be put back"
    return (result[0], f"{result[1]} {note};".strip()) + result[2:6]


def stay_out_of_the_dock() -> str:
    """Python's executable lives in an app bundle (Python.app, in Homebrew's
    Python as in the Mac's own). The first time the plugin brings an app to
    the front (hand_focus_back), macOS registers the plugin's process as an
    app -- an ordinary one, going by that bundle: an icon appears in the
    Dock and bounces for ever, since Python never finishes "launching", and
    Force Quit on it stops the plugin. Marking the process as a helper
    without a Dock icon beforehand makes macOS register it as that instead.
    The mark is made in memory only (the process's own copy of the bundle's
    Info.plist); nothing on disk changes. Returns a note for the log."""
    try:
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        cf.CFBundleGetMainBundle.restype = ctypes.c_void_p
        cf.CFBundleGetMainBundle.argtypes = []
        cf.CFBundleGetInfoDictionary.restype = ctypes.c_void_p
        cf.CFBundleGetInfoDictionary.argtypes = [ctypes.c_void_p]
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFDictionarySetValue.restype = None
        cf.CFDictionarySetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        cf.CFRelease.restype = None
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        bundle = cf.CFBundleGetMainBundle()
        info = cf.CFBundleGetInfoDictionary(bundle) if bundle else None
        if not info:
            return "no Dock icon to keep away (Python isn't in an app bundle here)"
        # (LSAppNapIsDisabled: an app that shows nothing may have its timers
        # slowed down by macOS; this one counts seconds.)
        for name in (b"LSUIElement", b"LSAppNapIsDisabled"):
            key = cf.CFStringCreateWithCString(None, name, 0x08000100)      # (UTF-8)
            if not key:
                return "couldn't mark the process as a helper without a Dock icon"
            try:
                cf.CFDictionarySetValue(info, key, ctypes.c_void_p.in_dll(cf, "kCFBooleanTrue"))
            finally:
                cf.CFRelease(key)
        return "marked as a helper without a Dock icon"
    except (OSError, AttributeError, ValueError) as exc:
        return f"couldn't mark the process as a helper without a Dock icon ({exc!r})"


def launch_services_front() -> int | None:
    """The process id of the frontmost app, asked of LaunchServices with
    lsappinfo (a part of macOS), or None. While a browser's menu has the
    keyboard, this is still the app you were in: macOS keeps it in front."""
    try:
        asn = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True, timeout=2).stdout.strip()
        info = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "pid", asn],
                              capture_output=True, text=True, timeout=2).stdout if asn else ""
    except (OSError, subprocess.SubprocessError):
        return None
    found = re.search(r'(?<![A-Za-z])pid"?\s*=\s*(\d+)', info)
    pid = int(found.group(1)) if found else 0
    return pid if pid > 0 and pid != os.getpid() else None


def front_app_pid(ax) -> tuple[int | None, str]:
    """The app you're in (its process id), and a note for the log when it
    had to be asked another way. Accessibility's "focused application" comes
    first; a process that has only just started gets no answer to that (seen
    on macOS 27: the first Resume after the plugin started never handed
    focus back, and nothing harmless asked beforehand changes it).
    LaunchServices is asked then."""
    pid = ax.focused_app_pid() if ax is not None else None
    if pid is not None:
        return pid, ""
    pid = launch_services_front()
    return (pid, "the app in front was asked of LaunchServices; ") if pid is not None else (None, "")


def _window_libs():
    """(CoreGraphics, CoreFoundation, {key: CFString}) set up for listing the
    windows on screen, or None. Kept apart from _quartz_libs, so that a
    missing function here can't disable the pointer handling."""
    if "windows" not in _quartz:
        found = None
        try:
            cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            ref = ctypes.c_void_p
            cg.CGWindowListCopyWindowInfo.restype = ref
            cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
            cg.CGRectMakeWithDictionaryRepresentation.restype = ctypes.c_bool
            cg.CGRectMakeWithDictionaryRepresentation.argtypes = [ref, ctypes.POINTER(_CGRect)]
            cf.CFArrayGetCount.restype = ctypes.c_long
            cf.CFArrayGetCount.argtypes = [ref]
            cf.CFArrayGetValueAtIndex.restype = ref
            cf.CFArrayGetValueAtIndex.argtypes = [ref, ctypes.c_long]
            cf.CFDictionaryGetValue.restype = ref
            cf.CFDictionaryGetValue.argtypes = [ref, ref]
            cf.CFNumberGetValue.restype = ctypes.c_bool
            cf.CFNumberGetValue.argtypes = [ref, ctypes.c_long, ctypes.POINTER(ctypes.c_int64)]
            cf.CFStringCreateWithCString.restype = ref
            cf.CFStringCreateWithCString.argtypes = [ref, ctypes.c_char_p, ctypes.c_uint32]
            cf.CFRelease.restype = None
            cf.CFRelease.argtypes = [ref]
            keys = {name: cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)      # (kept for good)
                    for name in ("kCGWindowOwnerPID", "kCGWindowLayer", "kCGWindowBounds")}
            if all(keys.values()):
                found = (cg, cf, keys)
        except (OSError, AttributeError):
            found = None
        _quartz["windows"] = found
    return _quartz["windows"]


def windows_on_screen(pid: int) -> list[tuple[int, float, float, float, float]] | None:
    """That process's windows on screen now, as (level, x, y, width, height),
    or None where macOS can't be asked. Only their place and level are read
    (which needs no permission), never what's in them."""
    libs = _window_libs()
    if libs is None:
        return None
    cg, cf, keys = libs
    try:
        listing = cg.CGWindowListCopyWindowInfo(1, 0)      # (on screen only; no window to start from)
        if not listing:
            return None
        try:
            found = []
            number = ctypes.c_int64()
            for i in range(cf.CFArrayGetCount(listing)):
                window = cf.CFArrayGetValueAtIndex(listing, i)
                values = {}
                for name in ("kCGWindowOwnerPID", "kCGWindowLayer"):
                    value = cf.CFDictionaryGetValue(window, keys[name])
                    if value and cf.CFNumberGetValue(value, 4, ctypes.byref(number)):      # (4: a 64-bit integer)
                        values[name] = number.value
                if values.get("kCGWindowOwnerPID") != pid or "kCGWindowLayer" not in values:
                    continue
                rect = _CGRect()
                bounds = cf.CFDictionaryGetValue(window, keys["kCGWindowBounds"])
                if bounds and cg.CGRectMakeWithDictionaryRepresentation(bounds, ctypes.byref(rect)):
                    found.append((int(values["kCGWindowLayer"]), rect.x, rect.y, rect.width, rect.height))
            return found
        finally:
            cf.CFRelease(listing)
    except Exception:
        return None


def browser_overlays(pid: int, row: tuple[float, float, float, float] | None) -> tuple[bool, bool, bool] | None:
    """What that browser has on screen, going by the row the script acted on
    (`row`: its frame): (the Downloads panel floating above other apps, the
    row's menu, an ordinary window of the browser's). None where it can't be
    told.

    After a native menu, the browser keeps its panel floating over every
    app until something makes it close it. The panel is the floating window
    that holds the whole row; the menu is another floating window that
    reaches the row's middle, where the browser opened it. Its other
    floating windows (a tooltip, a picture-in-picture video) are neither."""
    windows = windows_on_screen(pid)
    if windows is None or row is None:
        return None
    x, y, width, height = row
    middle = (x + width / 2.0, y + height / 2.0)
    panel = menu = False
    for level, wx, wy, ww, wh in windows:
        if level <= 0:
            continue
        if wx <= x + 2 and wy <= y + 2 and wx + ww >= x + width - 2 and wy + wh >= y + height - 2:
            panel = True
        elif wx - 8 <= middle[0] <= wx + ww + 8 and wy - 8 <= middle[1] <= wy + wh + 8:
            menu = True
    return panel, menu, any(w[0] == 0 for w in windows)


def floating_over_row(pid: int, row: tuple[float, float, float, float]) -> str:
    """That browser's floating windows that touch the row, for the log:
    "level 101 483x114 at 923,101" ("" when there's none, or it can't be
    told)."""
    x, y, width, height = row
    return ", ".join(f"level {level} {ww:.0f}x{wh:.0f} at {wx:.0f},{wy:.0f}"
                     for level, wx, wy, ww, wh in (windows_on_screen(pid) or [])
                     if level > 0 and wx <= x + width and wx + ww >= x and wy <= y + height and wy + wh >= y)


def _until(condition, seconds: float) -> bool:
    """Whether condition() came true within `seconds` (looked at every 0.03 s)."""
    deadline = time.monotonic() + seconds
    while not condition():
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.03)
    return True


def hand_focus_back(ax, result: ScriptResult, front_pid: int | None, presses_before: int | None = None) -> ScriptResult:
    """After Resume: see _hand_focus_back, whose result this is."""
    return _hand_focus_back(ax, result, front_pid, presses_before)[0]


def _hand_focus_back(ax, result: ScriptResult, front_pid: int | None,
                     presses_before: int | None = None) -> tuple[ScriptResult, bool]:
    """After Resume. Returns the result with a note for the log, and whether
    your app was put in front. Showing the row's menu brings the browser to the front;
    if it's still in front once the menu is done, bring back the app you
    were in (Firefox then closes its Downloads panel too, as it does whenever
    you switch apps). Nothing happens if you were in the browser, if no menu
    was shown, if you switched apps yourself meanwhile, or if you clicked or
    typed while Resume ran (you may have gone to the browser on purpose) --
    nor if the app in front was DynamicLake itself (the plugin's parent
    process), which would say nothing about the app you were using."""
    result = tuple(result) + ("",) * max(0, 6 - len(result))
    noted = lambda note: ((result[0], f"{result[1]} {note};".strip()) + result[2:6], False)
    browser_pid = int(result[5]) if str(result[5]).isdigit() else None
    if browser_pid is None:
        return result, False               # (no menu was shown: the browser didn't come to the front)
    if front_pid is None or front_pid == os.getpid():
        return noted("the app in front wasn't known: focus left alone")
    if front_pid == browser_pid:
        return noted("you were in the browser: focus left there")
    if front_pid == os.getppid():
        return noted("DynamicLake was in front: focus left alone")
    time.sleep(FOCUS_SETTLE_SECONDS)       # the browser acts on the chosen item first
    now_front = ax.focused_app_pid()
    blind = now_front is None
    if blind:
        # Accessibility can't say who has the keyboard (a process that has
        # only just started). LaunchServices says which app is frontmost:
        # yours still, if you haven't gone elsewhere -- putting it in front
        # again then changes nothing on screen, and takes the keyboard back
        # from the browser's menu.
        now_front = launch_services_front()
        if now_front is None:
            return noted("the app in front couldn't be read by then: focus left alone")
        if now_front not in (browser_pid, front_pid):
            return noted("another app was in front by then: focus left alone")
        if presses_before is None or press_count() != presses_before:
            return noted("you clicked or typed meanwhile, or that can't be told: focus left alone")
    elif now_front != browser_pid:
        return noted("your app was in front again by itself" if now_front == front_pid
                     else "another app was in front by then: focus left alone")
    if presses_before is not None and press_count() not in (None, presses_before):
        return noted("you clicked or typed meanwhile: focus left alone")
    err = ax.set_frontmost(front_pid)
    who = launch_services_front if blind else ax.focused_app_pid
    deadline = time.monotonic() + 0.5
    while who() != front_pid and time.monotonic() < deadline:
        time.sleep(0.03)
    if who() != front_pid:
        note = f"focus could not be handed back (error {err})"
    elif blind and now_front == front_pid:
        # (Nothing visibly changed hands: no reason for the browser to close anything.)
        note = "your app, still the frontmost one for LaunchServices, was given the keyboard again"
    else:
        note = "focus handed back" + (" (as far as LaunchServices can tell)" if blind else "")
    return (result[0], f"{result[1]} {note};".strip()) + result[2:6], not (blind and now_front == front_pid)


def clear_browser_from_view(ax, result: ScriptResult, front_pid: int | None,
                            presses_before: int | None = None) -> ScriptResult:
    """After Resume: leave nothing of the browser over the app you're in.

    The row's menu goes when Resume is chosen in it, but the Downloads panel
    stays, floating above every app. Firefox closes its popups when one of
    its windows gains or loses the keyboard, one layer each time: an open
    menu first, the panel only if no menu is open. (Clicks in other apps
    don't reach it; one in the browser brings it to the front, and lands on
    something. Hiding the browser and showing it again leaves the panel
    where it was.) So:

      1. wait for the menu to have gone from the screen, then hand focus
         back if the browser still has the keyboard (_hand_focus_back). On
         the Macs seen, your app has it back by itself by then, and the
         panel stays;
      2. if the panel is still there, bring the browser to the front and
         your app back at once: coming forward with no menu open is what
         makes it close the panel. It's in front for about a tenth of a
         second.

    Step 2 touches the browser only when it's certain you're in the app you
    were in when Resume was pressed: that app is known, isn't the browser or
    DynamicLake, is the one in front right now, and no click or key press
    has been counted since, nor any in the last half second. Every step goes
    to the log, with whether the panel went."""
    result = tuple(result) + ("",) * max(0, 6 - len(result))
    browser_pid = int(result[5]) if str(result[5]).isdigit() else None
    if browser_pid is None:
        return result                      # (no menu was shown: nothing of the browser came up)
    row = _parse_frame(result[4])
    mine = front_pid is not None and front_pid not in (browser_pid, os.getppid(), os.getpid())
    if not mine or row is None or browser_overlays(browser_pid, row) is None:
        # Nowhere to go back to (you were in the browser, or it isn't known
        # where you were), or the screen can't be read: no waiting.
        return hand_focus_back(ax, result, front_pid, presses_before)
    began = time.monotonic()

    def look():
        """(panel, menu, a window of the browser's own), or None."""
        return browser_overlays(browser_pid, row)

    def overlay_gone(patience: float):
        """True once nothing of the browser's has floated over the row for
        PANEL_ABSENT_SECONDS; False if something still does after
        `patience`; None when the screen can't be read."""
        deadline = time.monotonic() + patience
        absent_since = None
        while True:
            state = look()
            if state is None:
                return None
            now = time.monotonic()
            if state[0] or state[1]:
                absent_since = None
                if now >= deadline:
                    return False
            else:
                absent_since = now if absent_since is None else absent_since
                if now - absent_since >= PANEL_ABSENT_SECONDS:
                    return True
            time.sleep(0.03)

    def verdict(gone) -> str:
        if gone is None:
            return "the screen couldn't be read at that point"
        return "the Downloads panel closed" if gone else \
            f"the Downloads panel is still there ({floating_over_row(browser_pid, row) or 'not listed'}; row {result[4]})"

    def who():
        """The app with the keyboard, as Accessibility tells it; where it
        tells nothing, the frontmost app, as LaunchServices does."""
        pid = ax.focused_app_pid()
        return pid if pid is not None else launch_services_front()

    def untouched() -> bool:
        return presses_before is not None and press_count() == presses_before

    def still_yours() -> str:
        """"" when the browser may be brought forward, else why not."""
        if time.monotonic() - began > CLEAR_BUDGET_SECONDS:
            return "it has taken too long"
        if not untouched():
            return "you clicked or typed meanwhile, or that can't be told"
        quiet = seconds_since_press()
        if quiet is None or quiet < QUIET_SECONDS:
            return "you clicked or typed a moment ago, or that can't be told"
        if who() != front_pid:
            return "your app isn't the one in front"
        if not (look() or (False, False, False))[2]:
            return "the browser has no window on this desktop"
        return ""

    def bring_back() -> str:
        """Your app in front again, tried up to three times: "" when it is."""
        err = 0
        for _ in range(3):
            err = ax.set_frontmost(front_pid)
            if _until(lambda: who() == front_pid, 0.4):
                return ""
        return f"YOUR APP COULD NOT BE BROUGHT BACK IN FRONT (error {err})"

    note = ""
    if not _until(lambda: not (look() or (False, False))[1], MENU_GONE_SECONDS):
        note = f" the menu was slow to go ({floating_over_row(browser_pid, row) or 'not listed'}; row {result[4]});"
    result, handed = _hand_focus_back(ax, (result[0], (result[1] + note).strip()) + result[2:6], front_pid, presses_before)
    notes: list[str] = []
    # (Handed back: the browser has just lost the keyboard, and may close
    # its panel for that. Not handed back: nothing will make it.)
    gone = overlay_gone(PANEL_GONE_SECONDS if handed else 0.0)
    if gone is not False:
        notes.append(verdict(gone))
    else:
        why_not = still_yours()
        if why_not:
            notes.append(verdict(False) + f", and is left there: {why_not}")
        else:
            err = ax.set_frontmost(browser_pid)
            came = _until(lambda: who() == browser_pid, 0.3)
            time.sleep(BLINK_SECONDS)
            failed = bring_back()
            if not failed and not came:
                # It hadn't come forward when your app was put back in front:
                # it may still arrive, and mustn't be what's left there.
                notes.append(f"the browser was slow to come forward (error {err})")
                if _until(lambda: who() == browser_pid, 1.0):
                    failed = bring_back()
            if failed:
                notes.append(failed)
            else:
                notes.append("browser brought to the front and your app back: " + verdict(overlay_gone(PANEL_GONE_SECONDS)))
                if not untouched():
                    notes.append("a click or a key press of yours came meanwhile")
                elif who() == browser_pid:        # (a last look: the browser is never what's left in front)
                    notes.append(bring_back() or "your app brought back in front once more")
    return (result[0], (result[1] + " " + "; ".join(notes) + ";").strip()) + result[2:6]


# --------------------------------------------------------------------------
# Resume, second half: choosing Resume in the row's right-click menu.
# System Events can't be relied on to reach a right-click menu, so the
# plugin finds it itself with the macOS Accessibility API (the same
# permission as the scripts): the browser's menu, at the spot it opened.
# --------------------------------------------------------------------------

# Firefox's own labels, in every language it's translated into: the menu's
# Resume item, and items that menu always has for a paused download (Show in
# Finder, Clear Preview Panel), which prove a menu is that menu. None of the
# Resume labels is the label of any other item of that menu, in any language.
MENU_LABELS = {
    "resume": ["Adkregi\u00f1", "Ailgychwyn", "Atkuortuot", "Atk\u0101rtot", "Berrekin", "Buyela kwakhona", "Continar", "Continuar", "Continu\u0103", "Cuntinuar", "Davam et", "Davom etish", "Da\u016drigi", "Devam et", "Dooraat", "Ehorei hese", "Ferfetsje", "Folytat\u00e1s", "Fortset", "Fortsett", "Fortsetzen", "Genoptag", "Halda \u00e1fram", "Hervat", "Hervatten", "Ipagpatuloy", "Jatka", "Jokku", "J\u00e4tka", "Kajie\u00b4e tuku", "Kemmel", "Lanjutkan", "Lean", "Lean air", "Mede", "Nadaljuj", "Nastavi", "Nayi'i \u00f1un", "Pokra\u010dovat", "Pokra\u010dova\u0165", "Pokro\u010dowa\u0107", "P\u00f3k\u0161acowa\u015b", "Reanudar", "Repiggio", "Reprender", "Reprendre", "Repr\u00e8n", "Repr\u00e9n", "Resume", "Retomar", "Rimerre", "Ripie", "Riprendi", "R\u014db za\u015b", "Sambung", "Sighi", "Siguir", "Titik\u00efr chik el", "Ti\u1ebfp t\u1ee5c", "T\u0119sti", "Wzn\u00f3w", "\u00c5teruppta", "\u0160intin taaga", "\u03a3\u03c5\u03bd\u03ad\u03c7\u03b5\u03b9\u03b1", "\u0412\u043e\u0437\u043e\u0431\u043d\u043e\u0432\u0438\u0442\u044c", "\u0414\u0430\u0432\u043e\u043c \u0434\u043e\u0434\u0430\u043d", "\u0416\u0430\u043b\u0493\u0430\u0441\u0442\u044b\u0440\u0443", "\u041d\u0430\u0441\u0442\u0430\u0432\u0438", "\u041f\u0440\u0430\u0446\u044f\u0433\u043d\u0443\u0446\u044c", "\u041f\u0440\u043e\u0434\u043e\u0432\u0436\u0438\u0442\u0438", "\u041f\u0440\u043e\u0434\u043e\u043b\u0436\u0438", "\u041f\u0440\u043e\u0434\u044a\u043b\u0436\u0430\u0432\u0430\u043d\u0435", "\u0547\u0561\u0580\u0578\u0582\u0576\u0561\u056f\u0565\u056c", "\u054e\u0565\u0580\u0561\u0564\u0561\u057c\u0576\u0561\u056c", "\u05d4\u05de\u05e9\u05da", "\u0627\u0632\u0633\u0631\u06af\u06cc\u0631\u06cc", "\u0627\u0633\u062a\u0623\u0646\u0641", "\u0632 \u0633\u0631 \u06af\u0631\u063d\u068c\u0646", "\u0647\u06ce\u0646\u0627\u0646\u06d5\u0648\u06d5", "\u0648\u0644\u0627 \u062c\u0627\u0631\u06cc \u06a9\u0631\u0648", "\u067e\u06be\u0631 \u062c\u0627\u0631\u06cc \u06a9\u0631\u06cc\u06ba", "\u092a\u0941\u0928\u0903 \u0928\u093f\u0930\u0928\u094d\u0924\u0930\u0924\u093e \u0926\u093f\u0928\u0941\u0939\u094b\u0938\u094d", "\u092a\u0941\u0928\u094d\u0939\u093e \u0938\u0941\u0930\u0942 \u0915\u0930\u093e", "\u092b\u093f\u0928 \u091c\u093e\u0917\u093e\u092f", "\u092b\u093f\u0930 \u092c\u0939\u093e\u0932 \u0915\u0930\u0947\u0902", "\u09aa\u09c1\u09a8\u09b0\u09be\u09df \u09b6\u09c1\u09b0\u09c1 \u0995\u09b0\u09be", "\u0a2e\u0a41\u0a5c-\u0a2a\u0a4d\u0a30\u0a3e\u0a2a\u0a24", "\u0aab\u0ab0\u0ac0 \u0ab6\u0ab0\u0ac2 \u0a95\u0ab0\u0acb", "\u0ba4\u0bca\u0b9f\u0bb0\u0bb5\u0bc1\u0bae\u0bcd", "\u0c15\u0c4a\u0c28\u0c38\u0c3e\u0c17\u0c3f\u0c02\u0c1a\u0c41", "\u0cae\u0cb0\u0cb3\u0cbf \u0c86\u0cb0\u0c82\u0cad\u0cbf\u0cb8\u0cc1", "\u0d35\u0d40\u0d23\u0d4d\u0d1f\u0d41\u0d02 \u0d06\u0d30\u0d02\u0d2d\u0d3f\u0d2f\u0d4d\u0d15\u0d4d\u0d15\u0d41\u0d15", "\u0db1\u0dd0\u0dc0\u0dad\u0dad\u0dca", "\u0e17\u0e33\u0e15\u0e48\u0e2d", "\u0e94\u0eb3\u0ec0\u0e99\u0eb5\u0e99\u0e81\u0eb2\u0e99\u0e95\u0ecd\u0ec8", "\u0f58\u0f74\u0f0b\u0f58\u0f50\u0f74\u0f51", "\u1006\u1000\u103a\u101c\u1000\u103a\u1006\u1031\u102c\u1004\u103a\u101b\u103d\u1000\u103a\u1015\u102b", "\u10d2\u10d0\u10dc\u10d0\u10d2\u10e0\u10eb\u10d4\u10d7", "\u1794\u1793\u17d2\u178f", "\u1c6b\u1c69\u1c66\u1c72\u1c5f\u1c79 \u1c6e\u1c66\u1c5a\u1c75", "\u518d\u958b", "\u7e7c\u7e8c", "\u7ee7\u7eed", "\uacc4\uc18d"],
    "markers": ["Afficher dans le Finder", "Afi\u0219eaz\u0103 \u00een Finder", "Ammustra in Finder", "Bersihkan Panel Pratinjau", "Buang Panel Previu", "Buida la subfinestra de previsualitzaci\u00f3", "Cima iPhanele yamaVandlakanya", "Clear Preview Panel", "Clirio'r Panel Rhagolwg", "Cur\u0103\u021b\u0103 panoul de previzualiz\u0103ri", "Dangos yn Finder", "Dicht Preview Panel", "Diskouez e Finder", "D\u1ecdn b\u1ea3ng xem tr\u01b0\u1edbc", "Ehechauka Hekah\u00e1pe", "El\u0151n\u00e9zeti panel t\u00f6rl\u00e9se", "Embogue jeike hague ra\u2019\u00e3ngarupa", "Erakutsi Finder-en", "Esborra la subfinestra de previsualitzaci\u00f3", "Escafar lo pan\u00e8l d'apercebut", "Escoscar panel de previsualizaci\u00f3n", "Falamhaich panail an ro-sheallaidh", "Finder \u0a35\u0a3f\u0a71\u0a1a \u0a35\u0a47\u0a16\u0a3e\u0a13", "Finder \u306b\u8868\u793a", "Finder\u2019da g\u00f6ster", "Finder\uc5d0\uc11c \ubcf4\uae30", "Foarbyldpaniel wiskje", "Garbitu aurrebista-panela", "Glan Pain\u00e9al an R\u00e9amhamhairc", "Hawiin ang Preview Panel", "Hi\u1ec3n th\u1ecb trong th\u01b0 m\u1ee5c", "Hreinsa forsko\u00f0unarspjald", "Im Finder anzeigen", "Ipakita sa Finder", "Izbri\u0161i plo\u010du pregleda", "I\u0161valyti per\u017ei\u016bros skydel\u012f", "Jwa dirica me neno", "Kuva Finderis", "Limpa o panel de previsualizaci\u00f3n", "Limpar o painel de pr\u00e9-visualiza\u00e7\u00e3o", "Limpar painel de exibi\u00e7\u00e3o", "Limpiar panel de previsualizaci\u00f3n", "Limpiar panel de vista previa", "Liste leeren", "Llimpiar el panel de previsualizaci\u00f3n", "L\u00ecmpia su pannellu de previsualizatzione", "Maak voorskoupaneel skoon", "Megjelen\u00edt\u00e9s mapp\u00e1ban", "Momtu Alluwal \u0181ennungal", "Monstrar in Finder", "Montri en Finder", "Moofur feddiyoo kaa", "Mostra en el Finder", "Mostra nel Finder", "Mostra-ho en el Finder", "Mostrar dins lo Finder", "Mostrar en Finder", "Mostrar no Finder", "Mostre in Finder", "Mussar en il Finder", "Nagi'iaj n\u00ec\u00f1u' ri\u00f1a ni'io'", "Nete il panel de anteprime", "Not\u012br\u012bt priek\u0161skat\u012bjuma paneli", "N\u00e4yt\u00e4 Finderissa", "N\u016bteireit pr\u012bk\u0161skatejuma paneli", "Oldindan ko\u02bbrish panelini tozalash", "O\u010disti panel za pregled", "Poka\u017c w Finderze", "Poko\u017c we Finderze", "Po\u010disti plo\u0161\u010do predogleda", "Prika\u017ei u Finderu", "Prika\u017ei u folderu", "Prika\u017ei v Finderju", "Puhasta eelvaate paneel", "P\u0159ehladowe wokno wupr\u00f3zdni\u0107", "P\u015begl\u011bdowe wokno wuprozni\u015b", "Rens forh\u00e5ndsvisningspanel", "Rensa f\u00f6rhandsgranskningspanelen", "Rodyti per \u201eFinder\u201c", "Ryd liste", "R\u0101d\u012bt map\u0113", "Scancella Panello Anteprimma", "Seall san lorgaire", "Sfe\u1e0d agalis n teskant", "Shfaqe n\u00eb Finder", "Show in Finder", "Skarzha\u00f1 ar penel alberz", "Sken deg ukaram", "Spastroje Panelin e Paraparjeve", "Svidar la panela da prevista", "Svuota pannello anteprima", "S\u00e1\u00b4\u00e1no panel vista previa", "S\u00fdna \u00ed Finder", "Taispe\u00e1in san Aimsitheoir", "Tampilkan di Finder", "Tik'ut pa Finder", "Tiyuj nab'ey tz'ub'al pas", "Toane yn Finder", "Tonen in Finder", "Tyhjenn\u00e4 esikatselupaneeli", "T\u00f8m f\u00f8rehandsvisingsruta", "Vacuar le pannello de vista preliminar", "Vider le panneau d\u2019aper\u00e7u", "Vis i Finder", "Visa i Finder", "Vi\u015di anta\u016dvidan panelon", "Voorbeeldpaneel wissen", "Vymazat tento seznam", "Vymaza\u0165 panel n\u00e1h\u013eadu", "W Finder pokaza\u0107", "W Finder pokaza\u015b", "Wyczy\u015b\u0107 list\u0119", "Wypucuj lista z podgl\u014dndym", "Xituvi nu Finder", "Zobrazit ve Finderu", "Zobrazi\u0165 vo Finderi", "\u00d6n bax\u0131\u015f panelini t\u0259mizl\u0259", "\u00d6n izleme panelini temizle", "\u0391\u03c0\u03b1\u03bb\u03bf\u03b9\u03c6\u03ae \u03c0\u03b5\u03c1\u03b9\u03bf\u03c7\u03ae\u03c2 \u03c0\u03c1\u03bf\u03b5\u03c0\u03b9\u03c3\u03ba\u03cc\u03c0\u03b7\u03c3\u03b7\u03c2", "\u0395\u03bc\u03c6\u03ac\u03bd\u03b9\u03c3\u03b7 \u03c3\u03c4\u03bf Finder", "\u0410\u043b\u0434\u044b\u043d-\u0430\u043b\u0430 \u049b\u0430\u0440\u0430\u0443 \u043f\u0430\u043d\u0435\u043b\u0456\u043d \u0442\u0430\u0437\u0430\u0440\u0442\u0443", "\u0410\u0447\u044b\u0441\u0446\u0456\u0446\u044c \u043f\u0430\u043d\u044d\u043b\u044c \u043f\u0435\u0440\u0430\u0434\u043f\u0430\u043a\u0430\u0437\u0443", "\u0411\u0443\u043c\u0430\u0434\u0430 \u043a\u04e9\u0440\u0441\u0435\u0442\u0443", "\u0418\u0437\u0447\u0438\u0441\u0442\u0432\u0430\u043d\u0435 \u043d\u0430 \u0441\u043f\u0438\u0441\u044a\u043a\u0430", "\u0418\u0441\u0447\u0438\u0441\u0442\u0438 \u0433\u043e \u043f\u0430\u043d\u0435\u043b\u043e\u0442 \u0437\u0430 \u043f\u0440\u0435\u0433\u043b\u0435\u0434", "\u041d\u0430\u043c\u043e\u0438\u0448 \u0434\u043e\u0434\u0430\u043d \u0434\u0430\u0440 \u04b7\u04ef\u044f\u043d\u0434\u0430", "\u041e\u0431\u0440\u0438\u0448\u0438 \u043f\u0430\u043d\u0435\u043b \u0437\u0430 \u043f\u0440\u0435\u0433\u043b\u0435\u0434", "\u041e\u0447\u0438\u0441\u0442\u0438\u0442\u0438 \u043f\u0430\u043d\u0435\u043b\u044c \u043f\u0435\u0440\u0435\u0433\u043b\u044f\u0434\u0443", "\u041e\u0447\u0438\u0441\u0442\u0438\u0442\u044c \u043f\u0430\u043d\u0435\u043b\u044c \u043f\u0440\u0435\u0434\u043f\u0440\u043e\u0441\u043c\u043e\u0442\u0440\u0430", "\u041f\u0430\u043a\u0430\u0437\u0430\u0446\u044c \u0443 Finder", "\u041f\u043e\u043a \u043a\u0430\u0440\u0434\u0430\u043d\u0438 \u043b\u0430\u0432\u04b3\u0430\u0438 \u043f\u0435\u0448\u043d\u0430\u043c\u043e\u0438\u0448", "\u041f\u043e\u043a\u0430\u0437\u0430\u0442\u0438 \u0443 Finder", "\u041f\u043e\u043a\u0430\u0437\u0430\u0442\u044c \u0432 Finder", "\u041f\u043e\u043a\u0430\u0437\u0432\u0430\u043d\u0435 \u0432 \u043f\u0430\u043f\u043a\u0430\u0442\u0430", "\u041f\u0440\u0438\u043a\u0430\u0436\u0438 \u0443 \u0444\u0430\u0441\u0446\u0438\u043a\u043b\u0438", "\u0544\u0561\u0584\u0580\u0565\u056c \u0576\u0561\u056d\u0561\u0564\u056b\u057f\u0574\u0561\u0576 \u057e\u0561\u0570\u0561\u0576\u0561\u056f\u0568", "\u0551\u0578\u0582\u0581\u0561\u0564\u0580\u0565\u056c \u0578\u0580\u0578\u0576\u056b\u0579\u0578\u0582\u0574", "\u0551\u0578\u0582\u0581\u0561\u0564\u0580\u0565\u056c \u057a\u0561\u0576\u0561\u056f\u0578\u0582\u0574", "\u05d4\u05e6\u05d2\u05d4 \u05d1\u05beFinder", "\u05e0\u05d9\u05e7\u05d5\u05d9 \u05d7\u05dc\u05d5\u05e0\u05d9\u05ea \u05ea\u05e6\u05d5\u05d2\u05d4 \u05de\u05e7\u05d3\u05d9\u05de\u05d4", "\u0627\u0639\u0631\u0636 \u0641\u064a \u0641\u0627\u064a\u0646\u062f\u0631", "\u0627\u0645\u0633\u062d \u0644\u0648\u062d\u0629 \u0627\u0644\u0645\u0639\u0627\u064a\u0646\u0629", "\u0631\u0648\u0641\u062a\u0646 \u062a\u0627\u0628\u0644\u0648 \u067e\u063d\u0634 \u0646\u0634\u0648\u0648\u0769", "\u0635\u0627\u0641 \u067e\u06cc\u0634 \u0646\u0638\u0627\u0631\u06c1 \u067e\u06cc\u0646\u0644", "\u0641\u0648\u0644\u0688\u0631 \u0627\u0650\u0686 \u0759\u06a9\u06be\u0627\u0624", "\u0641\u0648\u0644\u0688\u0631 \u0645\u06cc\u06ba \u062f\u06a9\u06be\u0627\u0626\u06cc\u06ba", "\u0646\u0634\u0648\u0648\u0769 \u062f\u0627\u068c\u0646 \u0645\u0646 Finder", "\u0646\u0645\u0627\u06cc\u0634 \u062f\u0631 Finder", "\u067e\u0627\u06a9 \u06a9\u0631\u062f\u0646 \u062a\u0627\u0628\u0644\u0648 \u067e\u06cc\u0634\u200c\u0646\u0645\u0627\u06cc\u0634", "\u067e\u0627\u06a9\u06a9\u0631\u062f\u0646\u06d5\u0648\u06d5\u06cc \u0628\u06d5\u0634\u06cc \u067e\u06ce\u0634\u0628\u06cc\u0646\u06cc\u0646", "\u067e\u06cc\u0634 \u0646\u0638\u0627\u0631\u06c1 \u067e\u06cc\u0646\u0644 \u0635\u0627\u0641 \u06a9\u0631\u0648", "\u092a\u0942\u0930\u094d\u0935\u093e\u0935\u0932\u094b\u0915\u0928 \u092a\u091f\u0932 \u092e\u093f\u091f\u093e\u090f", "\u092a\u0942\u0930\u094d\u0935\u093e\u0935\u0932\u094b\u0915\u0928 \u092a\u094d\u092f\u093e\u0928\u0932 \u0916\u093e\u0932\u0940 \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d", "\u092a\u0942\u0930\u094d\u0935\u093e\u0935\u0932\u094b\u0915\u0928 \u092b\u0932\u0915 \u0938\u093e\u092b \u0915\u0930\u093e", "\u092b\u093e\u0907\u0902\u0921\u0930 \u092e\u0947\u0902 \u0926\u093f\u0916\u093e\u090f\u0902", "\u092b\u094b\u0932\u094d\u0921\u0930\u092e\u093e \u0926\u0947\u0916\u093e\u0909\u0928\u0941\u0939\u094b\u0938\u094d", "\u09aa\u09cd\u09b0\u09be\u0995\u09aa\u09a6\u09b0\u09cd\u09b6\u09a8 \u09aa\u09cd\u09af\u09be\u09a8\u09c7\u09b2 \u09aa\u09b0\u09bf\u09b7\u09cd\u0995\u09be\u09b0 \u0995\u09b0\u09c1\u09a8", "\u09ab\u09cb\u09b2\u09cd\u09a1\u09be\u09b0\u09c7 \u09a6\u09c7\u0996\u09be\u09a8", "\u0a1d\u0a32\u0a15 \u0a2a\u0a48\u0a28\u0a32 \u0a28\u0a42\u0a70 \u0a38\u0a3e\u0a2b\u0a3c \u0a15\u0a30\u0a4b", "\u0aaa\u0ac2\u0ab0\u0acd\u0ab5\u0aa6\u0ab0\u0acd\u0ab6\u0aa8 \u0aaa\u0ac7\u0aa8\u0ab2 \u0ab8\u0abe\u0aab \u0a95\u0ab0\u0acb", "\u0bae\u0bc1\u0ba9\u0bcd\u0baa\u0bbe\u0bb0\u0bcd\u0bb5\u0bc8 \u0baa\u0bb2\u0b95\u0ba4\u0bcd\u0ba4\u0bc8 \u0ba4\u0bc1\u0b9f\u0bc8", "\u0c2b\u0c48\u0c02\u0c21\u0c30\u0c4d\u200c\u0c32\u0c4b \u0c1a\u0c42\u0c2a\u0c3f\u0c02\u0c1a\u0c41", "\u0c2e\u0c41\u0c28\u0c41\u0c1c\u0c42\u0c2a\u0c41 \u0c2a\u0c4d\u0c2f\u0c3e\u0c28\u0c46\u0c32\u0c41\u0c28\u0c3f \u0c24\u0c41\u0c21\u0c3f\u0c1a\u0c3f\u0c35\u0c47\u0c2f\u0c3f", "\u0d05\u0d31\u0d2f\u0d3f\u0d7d \u0d15\u0d3e\u0d23\u0d3f\u0d15\u0d4d\u0d15\u0d41\u0d15", "\u0d2a\u0d4d\u0d30\u0d3f\u0d35\u0d4d\u0d2f\u0d42 \u0d2a\u0d3e\u0d28\u0d7d \u0d35\u0d43\u0d24\u0d4d\u0d24\u0d3f\u0d2f\u0d3e\u0d15\u0d4d\u0d15\u0d41\u0d15", "\u0db4\u0dd9\u0dbb\u0daf\u0dc3\u0dd4\u0db1 \u0db8\u0dac\u0dbd \u0db8\u0d9a\u0db1\u0dca\u0db1", "\u0db6\u0dc4\u0dcf\u0dbd\u0dd4\u0db8\u0dd9\u0dc4\u0dd2 \u0db4\u0dd9\u0db1\u0dca\u0dc0\u0db1\u0dca\u0db1", "\u0e25\u0e49\u0e32\u0e07\u0e41\u0e1c\u0e07\u0e41\u0e2a\u0e14\u0e07\u0e15\u0e31\u0e27\u0e2d\u0e22\u0e48\u0e32\u0e07", "\u0e41\u0e2a\u0e14\u0e07\u0e43\u0e19\u0e42\u0e1f\u0e25\u0e40\u0e14\u0e2d\u0e23\u0e4c", "\u0ea5\u0ec9\u0eb2\u0e87 Panel \u0e81\u0eb2\u0e99\u0eaa\u0eb0\u0ec1\u0e94\u0e87\u0e95\u0ebb\u0ea7\u0ea2\u0ec8\u0eb2\u0e87", "\u0eaa\u0eb0\u0ec1\u0e94\u0e87\u0ec3\u0e99 Finder", "\u0f66\u0f94\u0f7c\u0f53\u0f0b\u0f63\u0f9f\u0f60\u0f72\u0f0b\u0f44\u0f7c\u0f66\u0f0b\u0f53\u0f66\u0f0b\u0f58\u0f7a\u0f51\u0f0b\u0f54\u0f0b\u0f56\u0f5f\u0f7c\u0f0b\u0f56", "\u1021\u1005\u1019\u103a\u1038\u1000\u103c\u100a\u1037\u103a\u1015\u1014\u103a\u1014\u101a\u103a\u1000\u102d\u102f \u101b\u103e\u1004\u103a\u1038\u101c\u1004\u103a\u1038\u1015\u102b", "\u10d3\u10d0\u10e1\u10e0\u10e3\u10da\u10d4\u10d1\u10e3\u10da\u10d8 \u10e9\u10d0\u10db\u10dd\u10e2\u10d5\u10d8\u10e0\u10d7\u10d5\u10d4\u10d1\u10d8\u10e1 \u10db\u10dd\u10ea\u10d8\u10da\u10d4\u10d1\u10d0", "\u10e9\u10d5\u10d4\u10dc\u10d4\u10d1\u10d0 \u10e1\u10d0\u10e5\u10d0\u10e6\u10d0\u10da\u10d3\u10d4\u10e8\u10d8", "\u1795\u17d2\u1791\u17b6\u17c6\u1784\u200b\u179f\u1798\u17d2\u17a2\u17b6\u178f\u200b\u1780\u17b6\u179a\u200b\u1798\u17be\u179b\u200b\u1787\u17b6\u200b\u1798\u17bb\u1793", "\u1c62\u1c5f\u1c72\u1c5f\u1c5d \u1c5b\u1c6e\u1c6d\u1c5f\u1c5c \u1c67\u1c6e\u1c5e \u1c6f\u1c6e\u1c71\u1c5f\u1c5e \u1c6f\u1c77\u1c5f\u1c68\u1c6a\u1c5f\u1c6d \u1c62\u1c6e", "\u1c67\u1c5f\u1c62\u1c64\u1c61 \u1c68\u1c6e \u1c6b\u1c6e\u1c60\u1c77\u1c5f\u1c63 \u1c62\u1c6e", "\u30d7\u30ec\u30d3\u30e5\u30fc\u30d1\u30cd\u30eb\u3092\u6d88\u53bb", "\u5728\u8bbf\u8fbe\u4e2d\u663e\u793a", "\u65bc Finder \u986f\u793a", "\u6e05\u7a7a\u9884\u89c8\u9762\u677f", "\u6e05\u9664\u9810\u89bd\u7a97\u683c", "\ubbf8\ub9ac\ubcf4\uae30 \ud328\ub110 \uc815\ub9ac"],
}

MENU_WAIT_SECONDS = 3.0       # how long to look for the menu once it's been shown
MENU_FADE_SECONDS = 0.8       # a closing menu fades out, and can still be found meanwhile


def _label_key(text: str) -> str:
    return unicodedata.normalize("NFC", text).casefold()


_RESUME_KEYS = frozenset(_label_key(x) for x in MENU_LABELS["resume"])
_MARKER_KEYS = frozenset(_label_key(x) for x in MENU_LABELS["markers"])


def is_resume_label(text: str | None) -> bool:
    return bool(text) and _label_key(text) in _RESUME_KEYS


def is_menu_marker(text: str | None) -> bool:
    return bool(text) and _label_key(text) in _MARKER_KEYS


class Accessibility:
    """The few calls of the macOS Accessibility API (ApplicationServices) the
    plugin makes itself, through ctypes. Elements are CoreFoundation
    references (ints); every one this returns must be passed to release()."""

    UTF8 = 0x08000100         # kCFStringEncodingUTF8
    TIMEOUT = 1.0             # seconds an unanswered request waits

    def __init__(self):
        ax = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        ref, err = ctypes.c_void_p, ctypes.c_int32
        for name, restype, argtypes in (
                ("AXIsProcessTrusted", ctypes.c_bool, []),
                ("AXUIElementCreateSystemWide", ref, []),
                ("AXUIElementCreateApplication", ref, [ctypes.c_int]),
                ("AXUIElementCopyElementAtPosition", err, [ref, ctypes.c_float, ctypes.c_float, ctypes.POINTER(ref)]),
                ("AXUIElementCopyAttributeValue", err, [ref, ref, ctypes.POINTER(ref)]),
                ("AXUIElementPerformAction", err, [ref, ref]),
                ("AXUIElementGetPid", err, [ref, ctypes.POINTER(ctypes.c_int)]),
                ("AXUIElementSetMessagingTimeout", err, [ref, ctypes.c_float]),
                ("AXUIElementSetAttributeValue", err, [ref, ref, ref])):
            fn = getattr(ax, name)
            fn.restype, fn.argtypes = restype, argtypes
        for name, restype, argtypes in (
                ("CFStringCreateWithCString", ref, [ref, ctypes.c_char_p, ctypes.c_uint32]),
                ("CFStringGetLength", ctypes.c_long, [ref]),
                ("CFStringGetMaximumSizeForEncoding", ctypes.c_long, [ctypes.c_long, ctypes.c_uint32]),
                ("CFStringGetCString", ctypes.c_bool, [ref, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]),
                ("CFGetTypeID", ctypes.c_ulong, [ref]),
                ("CFStringGetTypeID", ctypes.c_ulong, []),
                ("CFBooleanGetTypeID", ctypes.c_ulong, []),
                ("CFArrayGetTypeID", ctypes.c_ulong, []),
                ("CFArrayGetCount", ctypes.c_long, [ref]),
                ("CFArrayGetValueAtIndex", ref, [ref, ctypes.c_long]),
                ("CFBooleanGetValue", ctypes.c_bool, [ref]),
                ("CFRetain", ref, [ref]),
                ("CFRelease", None, [ref])):
            fn = getattr(cf, name)
            fn.restype, fn.argtypes = restype, argtypes
        self.ax, self.cf = ax, cf
        self._names: dict = {}
        self._string_type = cf.CFStringGetTypeID()
        self._boolean_type = cf.CFBooleanGetTypeID()
        self._array_type = cf.CFArrayGetTypeID()
        self._true = ctypes.c_void_p.in_dll(cf, "kCFBooleanTrue").value
        self.system = ax.AXUIElementCreateSystemWide()
        ax.AXUIElementSetMessagingTimeout(self.system, self.TIMEOUT)

    def _name(self, text: str):
        if text not in self._names:     # kept for the life of the plugin
            self._names[text] = self.cf.CFStringCreateWithCString(None, text.encode("utf-8"), self.UTF8)
        return self._names[text]

    def trusted(self) -> bool:
        return bool(self.ax.AXIsProcessTrusted())

    def release(self, ref) -> None:
        if ref:
            self.cf.CFRelease(ref)

    def retain(self, ref):
        return self.cf.CFRetain(ref) if ref else None

    def app(self, pid: int, timeout: float | None = None):
        el = self.ax.AXUIElementCreateApplication(pid)
        if el:
            self.ax.AXUIElementSetMessagingTimeout(el, self.TIMEOUT if timeout is None else timeout)
        return el

    def hit(self, x: float, y: float, scope=None):
        """The element at (x, y): among one app's windows when `scope` is that
        app's element, else whatever is on screen there, whichever app it
        belongs to."""
        out = ctypes.c_void_p()
        if self.ax.AXUIElementCopyElementAtPosition(scope or self.system, x, y, ctypes.byref(out)) != 0:
            return None
        return out.value

    def pid(self, el) -> int | None:
        out = ctypes.c_int(0)
        return out.value if self.ax.AXUIElementGetPid(el, ctypes.byref(out)) == 0 else None

    def _copy(self, el, attr: str):
        out = ctypes.c_void_p()
        if self.ax.AXUIElementCopyAttributeValue(el, self._name(attr), ctypes.byref(out)) != 0:
            return None
        return out.value

    def string(self, el, attr: str) -> str | None:
        value = self._copy(el, attr)
        if not value:
            return None
        try:
            if self.cf.CFGetTypeID(value) != self._string_type:
                return None
            size = self.cf.CFStringGetMaximumSizeForEncoding(self.cf.CFStringGetLength(value), self.UTF8) + 1
            buf = ctypes.create_string_buffer(size)
            if not self.cf.CFStringGetCString(value, buf, size, self.UTF8):
                return None
            return buf.value.decode("utf-8", "replace")
        finally:
            self.release(value)

    def boolean(self, el, attr: str) -> bool | None:
        value = self._copy(el, attr)
        if not value:
            return None
        try:
            if self.cf.CFGetTypeID(value) != self._boolean_type:
                return None
            return bool(self.cf.CFBooleanGetValue(value))
        finally:
            self.release(value)

    def element(self, el, attr: str):
        """An element-valued attribute (AXParent...), or None."""
        return self._copy(el, attr)

    def children(self, el) -> list:
        value = self._copy(el, "AXChildren")
        if not value:
            return []
        try:
            if self.cf.CFGetTypeID(value) != self._array_type:
                return []
            return [self.retain(self.cf.CFArrayGetValueAtIndex(value, i))
                    for i in range(self.cf.CFArrayGetCount(value))]
        finally:
            self.release(value)

    def perform(self, el, action: str) -> int:
        return int(self.ax.AXUIElementPerformAction(el, self._name(action)))

    def focused_app_pid(self) -> int | None:
        """The process id of the app in front (the one you're using), or None."""
        app = self._copy(self.system, "AXFocusedApplication")
        if not app:
            return None
        try:
            return self.pid(app)
        finally:
            self.release(app)

    def set_frontmost(self, pid: int) -> int:
        """Bring that app to the front (what System Events' "set frontmost"
        does). Returns the AXError, 0 if it was accepted."""
        app = self.app(pid)
        if not app:
            return -1
        try:
            return int(self.ax.AXUIElementSetAttributeValue(app, self._name("AXFrontmost"), self._true))
        finally:
            self.release(app)


_ax_state: dict = {}


def accessibility() -> Accessibility | None:
    """The Accessibility API, or None where it can't be loaded (not a Mac)."""
    if "ax" not in _ax_state:
        try:
            _ax_state["ax"] = Accessibility()
        except (OSError, AttributeError, ValueError):
            _ax_state["ax"] = None
    return _ax_state["ax"]


def _count(seen: dict, what: str) -> None:
    seen[what] = seen.get(what, 0) + 1


def _menu_hit(ax: Accessibility, scope, pid: int, x: float, y: float, seen: dict, label: str):
    """The browser's menu at (x, y) (retained), hit-testing within `scope`
    (the browser's element, or None: the whole screen), or None."""
    el = ax.hit(x, y, scope)
    if not el:
        _count(seen, label + "nothing")
        return None
    try:
        if ax.pid(el) != pid:
            _count(seen, label + "another app")
            return None
        role = ax.string(el, "AXRole") or "?"
        if role == "AXMenu":
            return ax.retain(el)
        if role == "AXMenuItem":
            parent = ax.element(el, "AXParent")
            if parent and ax.string(parent, "AXRole") == "AXMenu":
                return parent
            ax.release(parent)
        _count(seen, label + role)
        return None
    finally:
        ax.release(el)


def _menu_at(ax: Accessibility, app, pid: int, x: float, y: float, seen: dict):
    """The browser's menu at (x, y) (retained), or None: looked for among
    the browser's own windows first (another app's window on top, such as
    the notch's, doesn't get in the way), then on screen. `seen` collects
    what was there instead, for the log."""
    menu = _menu_hit(ax, app, pid, x, y, seen, "") if app else None
    return menu if menu is not None else _menu_hit(ax, None, pid, x, y, seen, "screen: ")


def _menu_among_children(ax: Accessibility, app):
    """A menu among the browser's own top-level elements (retained), or None."""
    if not app:
        return None
    found = None
    for child in ax.children(app):
        if found is None and ax.string(child, "AXRole") == "AXMenu":
            found = child
        else:
            ax.release(child)
    return found


def _probe_points(frame: tuple[float, float, float, float], clicked=None) -> list:
    """Where to look for the menu: it opens with a corner where the browser
    clicked -- where it put the pointer (`clicked`, when the pointer guard
    saw it), which is the middle of the row -- to the right and down unless
    the screen edge flips it."""
    x, y, w, h = frame
    centres = [(x + w / 2, y + h / 2)]
    if clicked is not None and max(abs(clicked[0] - centres[0][0]), abs(clicked[1] - centres[0][1])) > 3:
        centres.insert(0, (float(clicked[0]), float(clicked[1])))
    return [(cx + dx, cy + dy) for cx, cy in centres for dx, dy in ((14, 9), (-14, 9), (14, -9), (-14, -9))]


def _menu_open_at(ax: Accessibility, app, pid: int, point) -> bool:
    menu = _menu_at(ax, app, pid, point[0], point[1], {})
    ax.release(menu)
    return menu is not None


def _menu_open_among_children(ax: Accessibility, app) -> bool:
    menu = _menu_among_children(ax, app)
    ax.release(menu)
    return menu is not None


def _gone(still_open, seconds: float) -> bool:
    """Whether the menu is gone within `seconds`."""
    deadline = time.monotonic() + seconds
    while still_open():
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
    return True


def _close_menu(ax: Accessibility, menu, first_item, still_open, outcome: str, trace: str) -> tuple[str, str]:
    """Close the menu without choosing anything."""
    for target in (menu, first_item, menu):
        if target:
            ax.perform(target, "AXCancel")
        if _gone(still_open, MENU_FADE_SECONDS):
            return outcome, trace + "menu closed; "
    return "menu-open", trace + "the menu did not close; "


def choose_in_row_menu(ax: Accessibility, pid: int, frame: tuple[float, float, float, float],
                       press: bool, clicked_at=None) -> tuple[str, str]:
    """The script has just shown a row's right-click menu. Find it (the
    browser's menu, where it opened) and, if `press`, choose Resume: only if
    it's the downloads menu (it has one of that menu's other items) with
    exactly one item labelled Resume, read again right before the press.
    Anything else, or `press` False, closes it untouched; nothing else in it
    is ever pressed. clicked_at() is where the browser put the pointer to
    open it, if known. Returns (outcome, trace)."""
    app = ax.app(pid, timeout=0.5)       # the browser, for hit-tests among its windows
    try:
        return _choose_in_row_menu(ax, app, pid, frame, press, clicked_at)
    finally:
        ax.release(app)


def _choose_in_row_menu(ax, app, pid, frame, press, clicked_at) -> tuple[str, str]:
    deadline = time.monotonic() + MENU_WAIT_SECONDS
    menu, where, seen, looks, still_open = None, "", {}, 0, None
    while menu is None and time.monotonic() < deadline:
        looks += 1
        for point in _probe_points(frame, clicked_at() if clicked_at else None):
            if time.monotonic() >= deadline:
                break
            menu = _menu_at(ax, app, pid, point[0], point[1], seen)
            if menu is not None:
                where = "at %.0f,%.0f" % point
                still_open = (lambda p=point: _menu_open_at(ax, app, pid, p))
                break
        if menu is None and looks % 10 == 0 and time.monotonic() < deadline:
            menu = _menu_among_children(ax, app)
            if menu is not None:
                where = "among the browser's elements"
                still_open = (lambda: _menu_open_among_children(ax, app))
        if menu is None:
            time.sleep(0.005)
    if menu is None:
        found = ", ".join(f"{k} x{v}" for k, v in sorted(seen.items())) or "nothing"
        return "no-menu", f"the menu wasn't found in {MENU_WAIT_SECONDS:.1f} s (seen: {found}); "
    items: list = []
    try:
        items = ax.children(menu)
        roles = [ax.string(el, "AXRole") for el in items]
        titles = [ax.string(el, "AXTitle") or "" for el in items]
        trace = f"menu {where} after {looks} looks: [{','.join(t for t in titles if t)}]; "
        first = items[0] if items else None
        if not press:
            return _close_menu(ax, menu, first, still_open, "menu-changed", trace)
        resume = [i for i, (r, t) in enumerate(zip(roles, titles)) if r == "AXMenuItem" and is_resume_label(t)]
        marked = any(is_menu_marker(t) for i, t in enumerate(titles) if i not in resume)
        if not marked:
            return _close_menu(ax, menu, first, still_open, "wrong-menu", trace + "not the downloads menu; ")
        if len(resume) != 1:
            return _close_menu(ax, menu, first, still_open, "not-paused", trace + "no Resume item; ")
        item = items[resume[0]]
        title = ax.string(item, "AXTitle")
        if not is_resume_label(title):
            return _close_menu(ax, menu, first, still_open, "menu-changed", trace + "the menu changed; ")
        if ax.boolean(item, "AXEnabled") is False:
            return _close_menu(ax, menu, first, still_open, "not-paused", trace + "Resume is disabled; ")
        err = ax.perform(item, "AXPress")
        if err == 0:
            return "resume-sent", trace + f"pressed [{title}]; "
        # An error. If the menu goes (it fades out first), the press may
        # still have gone through; if it stays open, it didn't.
        trace += f"pressing Resume reported error {err}; "
        if _gone(still_open, MENU_FADE_SECONDS):
            return "press-failed", trace
        return _close_menu(ax, menu, first, still_open, "not-pressed", trace)
    finally:
        for el in items:
            ax.release(el)
        ax.release(menu)


def log_path() -> Path:
    return Path.home() / "Library" / "Logs" / PLUGIN_FOLDER_NAME / "plugin.log"


def log_event(message: str) -> None:
    """Append one line to the plugin's log (outside the plugin package, as
    DynamicLake requires); never allowed to break the plugin."""
    path = log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.stat().st_size > LOG_MAX_BYTES:
            path.replace(path.with_name(path.name + ".1"))
        with path.open("a", encoding="utf-8") as fh:
            fh.write(time.strftime("%Y-%m-%d %H:%M:%S  ") + message + "\n")
    except OSError:
        pass


class AxJob:
    """Browser automation on a background thread, so the notch keeps
    updating while it works."""

    def __init__(self, *args):
        self.outcome: str | None = None
        self.trace = ""
        self.browser = ""
        self.position = ""
        self.spot = ""
        self.pid = ""
        self.seconds = 0.0
        self._started = time.monotonic()
        self._thread = threading.Thread(target=self._run, args=args, daemon=True)
        self._thread.start()

    def _finish(self, result) -> None:
        result = tuple(result) + ("", "", "", "", "", "")
        self.seconds = time.monotonic() - self._started
        self.trace, self.browser, self.position, self.spot = result[1], result[2], result[3], result[4]
        self.pid = result[5]
        self.outcome = result[0] or "error"  # set last: `done` implies the rest is ready

    @property
    def done(self) -> bool:
        return self.outcome is not None


class ActionJob(AxJob):
    """Runs one button's script: kind "stop", "resume" or "retry". Waits for
    a warm-up that is still running."""

    def __init__(self, kind: str, *args):
        self.kind = kind          # set before the thread starts
        super().__init__(*args)

    def _run(self, filename, fallback_name=None, proc_hint=None, button_hint=None) -> None:
        with _AX_LOCK:
            try:
                request = {"stop": request_browser_cancel, "resume": request_browser_resume,
                           "retry": request_browser_retry, "restart": request_browser_restart}[self.kind]
                if self.kind == "resume":
                    ax = accessibility() if SETTINGS["returnFocus"] else None
                    front, front_note = front_app_pid(ax) if ax is not None and ax.trusted() else (None, "")
                    presses = press_count()
                    with PointerGuard() as guard:
                        result = request(filename, fallback_name, proc_hint, button_hint,
                                         clicked_at=lambda: guard.restored_from)
                    result = tuple(result) + ("",) * max(0, 6 - len(result))
                    if guard.restored_from is not None:
                        result = (result[0], f"{result[1]} pointer put back at once;".strip()) + result[2:]
                    else:
                        result = put_pointer_back(result, guard.before)
                    if ax is not None:
                        result = (result[0], f"{result[1]} {front_note}".strip()) + tuple(result[2:])
                        try:
                            result = clear_browser_from_view(ax, result, front, presses)
                        except Exception as exc:      # (the download was resumed all the same)
                            result = (result[0], f"{result[1]} clearing the browser from view failed: {exc!r};") \
                                + tuple(result[2:])
                else:
                    result = request(filename, fallback_name, proc_hint, button_hint)
            except Exception as exc:  # never let a worker crash silently mid-job
                result = ("error", f"plugin error: {exc!r}")
        self._finish(result)


class WarmupJob(AxJob):
    """Runs the read-only warm-up. Skips itself if a button's script is running."""

    def _run(self, proc_hint=None, button_hint=None) -> None:
        result = ("skipped", "a button's script was already running")
        if _AX_LOCK.acquire(blocking=False):
            try:
                result = request_browser_locate(proc_hint, button_hint)
            except Exception as exc:
                result = ("error", f"plugin error: {exc!r}")
            finally:
                _AX_LOCK.release()
        self._finish(result)


# --------------------------------------------------------------------------
# Sleep, and whether you're at the Mac
# --------------------------------------------------------------------------

def wall_clock() -> float:
    return time.time()


class SleepWatch:
    """Notices the Mac waking up. The monotonic clock stands still while the
    Mac sleeps (on macOS it counts only time awake) and the wall clock
    doesn't, so across a sleep the wall clock moves on much further between
    two scans. A scan that's merely late moves both clocks alike."""

    def __init__(self):
        self._last: tuple[float, float] | None = None
        self.before = 0.0            # (monotonic) the scan before the last gap

    def asleep_for(self, now: float) -> float:
        """About how long the Mac slept since the last call, or 0.0."""
        wall = wall_clock()
        last, self._last = self._last, (now, wall)
        if last is None:
            return 0.0
        gap = (wall - last[1]) - (now - last[0])
        if gap < SLEEP_GAP_SECONDS:
            return 0.0
        self.before = last[0]
        return gap


def user_away() -> bool:
    """You're away from the Mac: the screen is locked, or there's been no
    input for the "Away After" time (keyboard, mouse or trackpad -- or input
    that apps post for you, such as Voice Control's or a remote session's)."""
    if screen_locked():
        return True
    idle = seconds_since_input(_SESSION_STATE)
    return idle is not None and idle >= SETTINGS["awayAfter"]


HOLDABLE = ("done", "canceled", "paused", "failed")          # sneak peeks kept for when you're back


def goes_with_peek() -> bool:
    """A finished or canceled card goes away with its sneak peek still open
    ("Remain Visible" at 0), not after a while as the closed pill."""
    return SETTINGS["remainVisible"] <= 0


def present_seconds(kind: str) -> int:
    """How long the sneak peek opens, in whole seconds within what DynamicLake
    accepts: the setting "Sneak Peek Duration" (a button's message: its own
    short time). A card that goes with its sneak peek open asks for a little
    more than it stays (see PEEK_MARGIN_SECONDS)."""
    if kind == "notice":
        seconds = NOTICE_SECONDS
    else:
        seconds = SETTINGS["sneakPeekDuration"]
        if kind in ("done", "canceled") and goes_with_peek():
            seconds += PEEK_MARGIN_SECONDS
    return max(1, min(MAX_PRESENT_SECONDS, int(seconds)))


def keep_seconds(dl: Download) -> float:
    """How long a finished or canceled card stays: its sneak peek, then the
    closed pill for the time of "Remain Visible"."""
    peek = SETTINGS["sneakPeekDuration"]
    if not goes_with_peek():
        return peek + SETTINGS["remainVisible"]
    if peek + PEEK_MARGIN_SECONDS > MAX_PRESENT_SECONDS:
        return peek - 0.25            # (the longest sneak peek there is: gone just before it would close)
    return peek


# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------

ACTION_STATES = {"stop": "active", "resume": "paused", "retry": "failed"}  # where each button shows
FIRST_SEEN = ("first seen",)   # see Download.stale_version
ACTION_NAMES = {"stop": "Stop", "resume": "Resume", "retry": "Retry", "restart": "Retry"}


# --------------------------------------------------------------------------
# Places
#
# DynamicLake shows two cards at a time: one in the main place, one as the
# small capsule beside it. Left to itself with three or more, it keeps the
# oldest in the main place, shows the newest in the capsule and, when the
# main one leaves, moves that newest one up: the second download would come
# last. So the plugin gives a card to NOTCH_PLACES downloads only, in the
# order they started. The others wait without one, and each gets its card
# when a place is free: when the card of a finished, canceled or blocked
# download has gone (a paused or failed download keeps its place).
#
# The oldest download with a card is "first": by DynamicLake's rule it has
# the main place, and it shows its status on its own card, as a single
# download does. Any other download's status (finished, canceled, paused,
# failed) shows in the main place on a card made for that, which takes the
# place for its time and gives it back (start_spot and end_spot, in main).
# One at a time, oldest first (step 4b). A download that's over and isn't
# first gives up its own card and its place at once.
#
# Another app's activity (music, say) may have the main place, with the
# first download as the capsule: DynamicLake opens no sneak peek there. So
# a status always takes the main place, with the high priority: a status
# card is created with it, and the first download's own card gets it with
# its status (its sneak peek is asked for again a moment later: asked for
# a card that isn't in the main place yet, it's dropped). Afterwards the
# place is given back with the low priority, never with the high one: a
# card that leaves, or the plugin's cards lowered for a moment (the first
# download's the least), let another app's activity move up when there's
# one, and the first download when there's none (end_spot, steps 4c, 4e).
#
# With the setting "Focus Mode" on, a finished download's card waits while
# any other download is still under way (Download.under_way): its own card
# and its place go at once, whichever download it is, so that the next ones
# move up; when none is under way, the finished cards that waited show in
# the main place one after the other, in the order the downloads finished,
# each on a status card. Only finished cards wait: a pause, a failure or a
# cancellation shows at once, as with the setting off.
#
# DynamicLake never says where a card is: all this goes by the order above.
# After a click on the capsule (which swaps the two cards), or beside
# another app's activity, the cards may be elsewhere than the plugin thinks;
# and a download that had the main place before another app's activity came
# is behind it after a status has shown.
# --------------------------------------------------------------------------

def first_in_place(downloads) -> Download | None:
    """The oldest download that has a card of its own."""
    holders = [d for d in downloads if d.place]
    return min(holders, key=lambda d: d.seq) if holders else None


def assign_places(downloads, free_from: float, now: float) -> list:
    """Give the free places to the downloads that wait, oldest first, and
    return those. Only a download still under way gets one (a waiting one
    that's over only has its status to show), and none right after a card
    left (PLACE_GAP_SECONDS)."""
    downloads = list(downloads)
    if NOTCH_PLACES <= 0:
        waiting = [d for d in downloads if not d.place]
    else:
        free = NOTCH_PLACES - sum(1 for d in downloads if d.place)
        if free <= 0 or now < free_from:
            return []
        waiting = sorted((d for d in downloads if not d.place and d.resolved_at is None),
                         key=lambda d: d.seq)[:free]
    for d in waiting:
        d.place = True
    return waiting


def adopt_restarted(tracked: dict, part_path: Path) -> Download | None:
    """A canceled download whose Retry was pressed here, started over in a
    new partial file (same folder, same file name): it keeps its card.
    (Firefox normally reuses the partial file's name; this is the fallback.
    Only a partial file that's new since the last scan is offered here, and
    only once the press went through.)"""
    name = real_name_from_part(part_path.name[: -len(".part")])
    for key, dl in list(tracked.items()):
        if dl.can_restart and dl.restart_requested_at is not None and key.parent == part_path.parent \
                and dl.filename == name:
            del tracked[key]
            dl.move_to(part_path)
            tracked[part_path] = dl
            return dl
    return None


def update_state(dl: Download, listed: str, version, stopped_early: bool = False) -> str | None:
    """Move a download between "active", "paused" and "failed": what its
    downloads.json entry says (see entry_state), unless its .part file keeps
    growing -- then the browser has resumed it, and the file will say so
    about 1.5 s later; until it's rewritten, that version of the file is
    ignored. The other way round, `stopped_early`: the browser has closed
    the partial file (see partial_file_state), so it stopped the download,
    and downloads.json will say so about 1.5 s later; until then it shows
    as paused (a failure shows as failed once the file says so). Returns a
    line for the log when the state changed. ("blocked" is handled by the
    caller; "" or unlisted is no news.)"""
    if dl.stale_version is FIRST_SEEN and version is not None:
        dl.stale_version = version
    target = dl.state
    if listed in ("paused", "failed"):
        target = "active" if version is not None and version == dl.stale_version else listed
    elif listed == "active":
        target = "active"
    if stopped_early and target == "active":
        target = "paused"
    if dl.state in ("paused", "failed") and target == dl.state and dl.samples:
        sampled_at, size = dl.samples[-1]
        if sampled_at != dl.growth_checked_at:        # a new measurement
            dl.growth_checked_at = sampled_at
            if size > dl.state_size:
                dl.growth_ticks += 1
                dl.state_size = size
            else:
                dl.growth_ticks = 0
            # Two measurements in a row, or one right after our own Resume or
            # Retry, so a last write the browser flushed late isn't mistaken
            # for a restart.
            if dl.growth_ticks >= (1 if dl.restart_requested_at is not None else 2):
                dl.stale_version = version
                target = "active"
    if target == dl.state:
        return None
    old, dl.state = dl.state, target
    if target in ("paused", "failed"):
        dl.state_size = dl.size
        dl.growth_ticks = 0
        dl.growth_checked_at = dl.samples[-1][0] if dl.samples else None
        return f"{target} at {human_bytes(dl.size)}" + (f" of {human_bytes(dl.total_size)}" if dl.total_size else "")
    dl.restarted()
    return f"downloading again (was {old})"


def main() -> None:
    sock_path = os.environ.get("DYNAMICLAKE_JSON_SOCKET")
    if not sock_path:
        print("DYNAMICLAKE_JSON_SOCKET is missing -- launch this from DynamicLake.",
              file=sys.stderr)
        sys.exit(1)

    features = feature_set()
    supports_present_sneak_peek = "presentSneakPeek" in features
    # Digits that change in place (no jitter) for the percentage, where supported.
    numeric_style = "numeric" if "numericText" in features else "compact"

    dlk = DynamicLake(sock_path)
    log_event("started: " + stay_out_of_the_dock())
    log_event(SETTINGS.refresh(force=True))
    profiles = discover_profiles()
    watch_dirs = discover_watch_dirs(profiles)
    next_dir_refresh = time.monotonic() + DIR_REFRESH_SECONDS
    lists = DownloadsJson()
    presence = BrowserPresence()
    sleep_watch = SleepWatch()
    next_replay_at = 0.0
    places_free_from = 0.0     # no card is given before then (see PLACE_GAP_SECONDS)
    spot_pinned = ""           # the card kept behind the capsule's while a status card has the main place
    raised: dict = {}          # a download's own card, at the high priority for its status: card -> when
                               # the main place is given back (None: when the card goes, or at once)
    settling: dict = {}        # cards at the low priority to give the main place back: card -> when
                               # each gets its usual priority again (see end_spot, steps 4c and 4e)

    # Baseline pass: note .part files that already exist when we start so a
    # stale/abandoned one does not immediately show up as "downloading".
    baseline_sizes: dict[Path, int] = {}
    for d in watch_dirs:
        for p in scan_part_files(d):
            try:
                baseline_sizes[p] = p.stat().st_size
            except OSError:
                pass

    tracked: dict[Path, Download] = {}
    last_browser = ""          # browser process that answered last; tried first
    last_button = ""           # where its toolbar Downloads button was ("1.1.2.4")
    last_ax_activity = -WARMUP_MIN_GAP
    warmup: WarmupJob | None = None
    start_precompile()

    def browser_hints(dl: Download) -> tuple[str | None, str | None]:
        """The browser to try first (the one whose downloads.json lists this
        download, else the one that answered last) and, when that's the same
        browser, where its toolbar button was."""
        proc = dl.browser or last_browser
        return (proc or None), (last_button if proc and proc == last_browser and last_button else None)

    def waiting_for_you(cache: dict) -> bool:
        """Whether sneak peeks wait until you're back (asked at most once a pass)."""
        if "away" not in cache:
            cache["away"] = bool(SETTINGS["waitWhenAway"]) and user_away()
        return cache["away"]

    def send_priority(activity_id: str, priority: str) -> None:
        dlk.send({"schemaVersion": 1, "type": "update", "activityID": activity_id, "priority": priority})

    def own_cards(but: str = "") -> list:
        """The downloads' own cards that are up (no status card), oldest download first."""
        return [d.activity_id for d in sorted(tracked.values(), key=lambda d: d.seq)
                if (d.own_card if d.spot else d.created) and d.activity_id != but]

    def lower(cards, now: float) -> None:
        """The low priority for these cards, in this order, for a moment (step 4c)."""
        for card in cards:
            send_priority(card, "low")
            settling[card] = now + HAND_BACK_SECONDS

    def start_spot(dl: Download, kind: str, now: float) -> None:
        """Show this download's status in the main place, on a card made for
        that (its own card, if it has one, stays where it is). The card is
        created with the high priority, which takes the main place at once.
        The first download's card gets the low one meanwhile: behind the
        capsule's, so that the capsule goes on showing what it showed. The
        sneak peek is asked for a moment later (PEEK_AFTER_CREATE)."""
        nonlocal spot_pinned
        first = first_in_place(tracked.values())
        dl.own_card, dl.created = dl.created, False
        dl.spot = True
        dl.line_from = now                    # (its line stays still at first, from now)
        surfaces, signature = dl.current_surfaces(numeric_style)
        dlk.send({"schemaVersion": 1, "type": "create", "activityID": dl.card_id, "title": "Download",
                  "priority": "high", "size": ACTIVITY_SIZE, "surfaces": surfaces})
        if first is not None and first is not dl and first.created:
            send_priority(first.activity_id, "low")
            spot_pinned = first.activity_id
            settling.pop(spot_pinned, None)
        for card in list(raised):                 # (a card that had the main place for its own status)
            if card != spot_pinned:
                send_priority(card, "normal")
            del raised[card]
        dl.created, dl.created_at = True, now
        dl.last_signature, dl.line_phase_sent = signature, dl.line_phase
        seconds = present_seconds(kind)
        dl.peek_owed = (seconds, now + PEEK_AFTER_CREATE)
        if dl.resolved_at is not None:
            dl.resolved_at = now              # (it stays its usual time, from now)
            dl.spot_until = None
        else:
            dl.spot_until = now + PEEK_AFTER_CREATE + seconds + SPOT_MARGIN_SECONDS

    def end_spot(dl: Download, now: float) -> None:
        """The status card leaves the main place. DynamicLake then moves up
        another app's activity when there's one, else the plugin's card with
        the highest priority (between equals, whichever was updated last):
        so, just before the status card is dismissed, the first download's
        card gets its usual priority and the plugin's other cards the low
        one, which they keep for a moment (HAND_BACK_SECONDS; step 4c)."""
        nonlocal spot_pinned, next_replay_at
        first = first_in_place(tracked.values())
        if first is dl:
            back = dl.activity_id if dl.own_card else ""
        else:
            back = first.activity_id if first is not None and first.created and not first.spot else ""
        if back:
            send_priority(back, "normal")
            raised.pop(back, None)
            settling.pop(back, None)
        lower([card for card in own_cards(but=back) if card not in raised], now)
        dlk.send({"schemaVersion": 1, "type": "dismiss", "activityID": dl.card_id})
        spot_pinned = ""
        log_event(f"{dl.filename}: its status card left the main place" + (
            f" ({first.filename} is first in line for it)" if back else " (no other card)"))
        dl.spot, dl.spot_until, dl.peek_owed = False, None, None
        dl.created, dl.own_card = dl.own_card, False
        dl.last_signature = None              # (its own card, if it has one, is brought up to date)
        next_replay_at = max(next_replay_at, now + SPOT_GAP_SECONDS)

    last_tick = -POLL_INTERVAL
    last_error = ("", 0.0)
    while True:
        try:
            # Sleep until the next scan, but wake the instant DynamicLake sends
            # a button press. Scans run every 0.1 s while a button's action is
            # in flight.
            interval = ACTION_POLL_INTERVAL if any(dl.busy or dl.settling for dl in tracked.values()) \
                else POLL_INTERVAL
            remaining = last_tick + interval - time.monotonic()
            # ...and on time for a card that's due to go (with its sneak peek
            # still open), or a new download's arrow to become its file type.
            waking = time.monotonic()
            dues = [places_free_from]                 # (a card for the next download in line)
            dues.extend(settling.values())
            dues.extend(until for until in raised.values() if until is not None)
            for dl in tracked.values():
                if dl.peek_owed is not None:
                    dues.append(dl.peek_owed[1])
                if dl.spot_until is not None:
                    dues.append(dl.spot_until)
                if dl.held is not None and dl.held_why == "turn":
                    dues.append(max(next_replay_at, dl.created_at + PEEK_AFTER_CREATE if dl.created else 0.0))
            for due in dues:
                if due > waking:
                    remaining = min(remaining, due - waking + 0.01)
            for dl in tracked.values():
                if dl.resolved_at is None:
                    due = dl.started_at + ICON_DELAY_SECONDS
                elif dl.job is None and not dl.restart_pending and dl.held is None:
                    due = dl.resolved_at + keep_seconds(dl)
                else:
                    continue
                if due > waking:
                    remaining = min(remaining, due - waking + 0.01)
                if dl.peek_not_before is not None and dl.peek_not_before > waking:
                    remaining = min(remaining, dl.peek_not_before - waking + 0.01)
                if dl.text_due is not None and dl.text_due > waking:      # (the time left, second by second)
                    remaining = min(remaining, dl.text_due - waking + 0.01)
            if remaining > 0:
                dlk.wait_readable(remaining)
            now = time.monotonic()
            away_cache: dict = {}

            changed = SETTINGS.refresh(now)
            if changed:
                log_event(changed)

            if now >= next_dir_refresh:
                profiles = discover_profiles()
                watch_dirs = discover_watch_dirs(profiles)
                next_dir_refresh = now + DIR_REFRESH_SECONDS

            # 1. Button presses, handled as soon as they arrive. Stop, Resume and
            # Retry only act on the card their button is shown on, one at a time.
            for msg in dlk.poll_incoming():
                if msg.get("type") != "action":
                    continue
                action_id = msg.get("actionID", "")
                kind, _, activity_id = action_id.partition(":")
                dl = next((d for d in tracked.values() if d.activity_id == activity_id), None)
                if dl is None:
                    continue
                if kind == "show":
                    if dl.final_path.exists():
                        subprocess.run(["open", "-R", str(dl.final_path)])
                    continue
                if kind == "open":
                    # Open File, on the finished card: the file, in the app for
                    # its type (macOS asks first about an app or a script that
                    # came from the internet, as it does in the Finder).
                    if dl.resolved_at is not None and dl.succeeded and dl.final_path.exists():
                        try:
                            opened = subprocess.run(["open", str(dl.final_path)], capture_output=True, timeout=15).returncode
                        except (OSError, subprocess.SubprocessError) as exc:
                            opened = repr(exc)
                        log_event(f"{dl.filename}: Open File" + ("" if opened == 0 else f": couldn't be opened ({opened})"))
                    continue
                shown = kind in ACTION_STATES and dl.resolved_at is None and not dl.browser_closed \
                    and dl.shown_state(now) == ACTION_STATES[kind]
                if kind == "restart":
                    shown = dl.can_restart
                if not shown or dl.busy:
                    continue
                proc_hint, button_hint = browser_hints(dl)
                if kind == "stop":
                    dl.stop_pressed_at = now
                if kind == "restart":
                    dl.restart_pressed_at = now
                dl.job = ActionJob(kind, dl.filename, dl.raw_final_path.name, proc_hint, button_hint)
                last_ax_activity = now
                dl.held = None                    # (you're here)
                dl.notice = WORKING_NOTICES[kind]
                dl.notice_until = now + STOP_SCRIPT_TIMEOUT + (
                    CANCEL_GIVEUP_SECONDS if kind == "stop" else RESTART_GIVEUP_SECONDS)

            # 1b. Pick up finished button actions (they run on a background thread).
            for dl in tracked.values():
                job = dl.job
                if job is None or not job.done:
                    continue
                dl.job = None
                log_event(f"{dl.filename}: {ACTION_NAMES[job.kind]}: {job.outcome} after {job.seconds:.2f} s | {job.trace}")
                if job.browser:
                    last_browser, last_button = job.browser, job.position
                if dl.resolved_at is not None and (job.kind != "restart" or not dl.can_restart):
                    continue  # the partial file already went away (or, restarted, it finished already)
                done_at = time.monotonic()
                # "press-failed": the press reported an error, but it may still
                # have gone through -- so wait for the browser, like after a press.
                if job.outcome in SENT_OUTCOMES[job.kind]:
                    if job.kind == "stop":
                        dl.cancel_requested_at = done_at  # step 3 sees the .part disappear
                        dl.notice = WORKING_NOTICES["stop"]
                        dl.notice_until = done_at + CANCEL_GIVEUP_SECONDS + 1
                    elif dl.resolved_at is None and dl.state == "active":
                        dl.notice = None                  # it's downloading again already
                    else:
                        # step 2 sees it restart (a canceled download: its
                        # partial file coming back)
                        dl.restart_requested_at, dl.restart_kind = done_at, job.kind
                        dl.notice = WORKING_NOTICES[job.kind]
                        dl.notice_until = done_at + RESTART_GIVEUP_SECONDS + 1
                else:
                    dl.notice = ACTION_NOTICES[job.kind].get(job.outcome, FALLBACK_NOTICE)
                    dl.notice_until = done_at + NOTICE_SECONDS
                    if dl.resolved_at is not None:
                        dl.resolved_at = done_at          # the card stays up while it says so

            # 1c. The warm-up finished.
            if warmup is not None and warmup.done:
                log_event(f"warm-up: {warmup.outcome} after {warmup.seconds:.2f} s | {warmup.trace}")
                if warmup.browser:
                    last_browser, last_button = warmup.browser, warmup.position
                warmup = None

            if now >= last_tick + interval - 0.005:
                last_tick = now

                # 1d. The Mac just woke up. Firefox paused the downloads in
                # progress when it went to sleep, and resumes them by itself 10 s
                # after it wakes: until then, a pause isn't shown (nor a partial
                # file that went away, which Firefox starts over).
                # Only what was downloading when the Mac went to sleep: a
                # download you'd paused stays paused, and shows so.
                asleep = sleep_watch.asleep_for(now)
                if asleep:
                    waiting = [dl for dl in tracked.values() if dl.resolved_at is None and (
                        dl.state == "active" or sleep_watch.before - dl.last_growth_at <= WAS_DOWNLOADING_SECONDS)]
                    for dl in waiting:
                        dl.hold_until = now + WAKE_GRACE_SECONDS
                        dl.presented_state = None     # (its pause may have been seen before the Mac slept)
                    if waiting:
                        log_event(f"the Mac woke up (asleep about {asleep:.0f} s): for {WAKE_GRACE_SECONDS} s, "
                                  f"pauses aren't shown while Firefox resumes downloads by itself "
                                  f"({', '.join(dl.filename for dl in waiting)})")

                # 2. Rescan watched directories for .part files.
                seen_now: set[Path] = set()
                for d in list(watch_dirs):
                    for part_path in scan_part_files(d):
                        seen_now.add(part_path)
                        dl = tracked.get(part_path)
                        if dl is None and part_path not in baseline_sizes:
                            dl = adopt_restarted(tracked, part_path)
                        if dl is None:
                            baseline_size = baseline_sizes.get(part_path)
                            if baseline_size is not None:
                                try:
                                    current_size = part_path.stat().st_size
                                except OSError:
                                    current_size = baseline_size
                                if current_size <= baseline_size:
                                    continue  # stale leftover, not actively growing
                            dl = tracked[part_path] = Download(part_path)
                            if baseline_size is not None:
                                # A download from before the plugin started, now
                                # growing: resumed, while downloads.json may still
                                # say paused or failed for a moment.
                                dl.stale_version = FIRST_SEEN
                            # A new download: get the browser automation ready now,
                            # so a button press doesn't have to wait for start-up.
                            if warmup is None and not any(t.busy for t in tracked.values()) \
                                    and now - last_ax_activity >= WARMUP_MIN_GAP:
                                warmup = WarmupJob(last_browser or None, last_button or None)
                                last_ax_activity = now
                        elif dl.can_restart:
                            # Its partial file is back: Retry (the notch's, or the
                            # browser's own) started the canceled download over.
                            pressed_at = dl.restart_pressed_at if dl.restart_pending else None
                            dl.reopen(now)
                            log_event(f"{dl.filename}: downloading again after it was canceled" + (
                                f" (Retry worked, {now - pressed_at:.2f} s after the press)" if pressed_at is not None else ""))
                        if dl.resolved_at is None:
                            dl.sample()

                # 2a. Total size and state (paused, failed...), from the browsers'
                # downloads.json.
                if any(dl.resolved_at is None for dl in tracked.values()):
                    lists.refresh(profiles)
                for dl in tracked.values():
                    if dl.resolved_at is not None:
                        continue
                    total, listed, process, version = lists.lookup(dl)
                    if process:
                        dl.browser = process
                    dl.profile = lists.profile_of(dl) or dl.profile
                    if total:
                        if dl.total_size is None:
                            log_event(f"{dl.filename}: total size {human_bytes(total)} (from the browser's downloads.json)")
                        dl.total_size, dl.total_logged = total, True
                    elif not dl.total_logged and now - dl.started_at >= TOTAL_WAIT_SECONDS:
                        dl.total_logged = True
                        log_event(f"{dl.filename}: no total size in any downloads.json after "
                                  f"{TOTAL_WAIT_SECONDS} s -- the ring stays spinning (the server may not "
                                  f"send a size, or it's a private-window download)")
                    if listed == "blocked":
                        # Held back as a potential security risk: only you can
                        # decide, in the browser.
                        dl.resolved_at, dl.succeeded, dl.resolved_reason = now, False, "Blocked"
                        dl.cancel_requested_at = dl.restart_requested_at = None
                        dl.notice = None
                        log_event(f"{dl.filename}: blocked by the browser as a potential security risk")
                        continue
                    # The browser closes the partial file the moment it stops a
                    # download (a pause, a failure), about 1.5 s before its
                    # downloads.json says so: seen closed twice, a moment
                    # apart (it's also closed for an instant when the download
                    # finishes or is canceled), it counts as stopped at once.
                    # Not during a Stop, nor for a download its browser's
                    # downloads.json doesn't list by its partial file.
                    stopped_early = False
                    look = "unknown"
                    if not dl.no_early_stop and not dl.stopping and lists.lists_partial_file(dl):
                        look = partial_file_state(dl, presence, now)
                    if look == "closed":
                        try:
                            fresh = dl.part_path.stat().st_size
                        except OSError:
                            fresh = None
                        if fresh is None or (dl.total_size is not None and fresh >= dl.total_size):
                            dl.closed_seen_at = None               # gone, or all there: it's finishing
                        elif dl.closed_seen_at is None:
                            dl.closed_seen_at, dl.closed_size, dl.closed_growths = now, fresh, 0
                        elif fresh > dl.closed_size:
                            # Bigger than at the last look, yet that process
                            # doesn't have it open. Once, it may have been
                            # reopened and closed in between (a Retry that
                            # failed again at once): seen afresh. Twice since
                            # it was last seen open (however slowly it grows),
                            # it isn't the process downloading it.
                            dl.closed_growths += 1
                            dl.closed_seen_at, dl.closed_size = now, fresh
                            if dl.closed_growths >= 2:
                                dl.no_early_stop, dl.closed_seen_at = True, None
                                log_event(f"{dl.filename}: its partial file grows although the browser that lists it doesn't "
                                          f"have it open: another process is downloading it (pauses show when downloads.json says so)")
                        else:
                            confirm = EARLY_STOP_CONFIRM if dl.total_size is not None else EARLY_STOP_CONFIRM_NO_TOTAL
                            stopped_early = now - dl.closed_seen_at >= confirm
                    else:
                        dl.closed_seen_at = None
                        if look == "unknown" and dl.early_paused and dl.state == "paused" and dl.profile is not None:
                            in_use = profile_in_use(dl.profile)    # (asked afresh, not from the cache)
                            presence.note(dl.profile, now, in_use)
                            if in_use is False:
                                # It wasn't a pause: the browser was quitting (it
                                # closes its files a moment before it's gone).
                                dl.state = "active"
                                dl.early_paused, dl.peek_not_before, dl.presented_state = False, None, None
                                dl.browser_closed = True
                                # (as after CLOSED_CHECK_AFTER without data: it stays
                                # "browser closed" until data comes again)
                                dl.last_growth_at = min(dl.last_growth_at, now - CLOSED_CHECK_AFTER - 1.0)
                                log_event(f"{dl.filename}: not paused: its browser was closing, at {human_bytes(dl.size)}; "
                                          f"Firefox carries on with the download when it reopens")
                                continue
                    was_active = dl.state == "active"
                    change = update_state(dl, listed, version, stopped_early)
                    if dl.state != "paused":
                        dl.early_paused, dl.peek_not_before = False, None
                    elif stopped_early and was_active and listed not in ("paused", "failed"):
                        # Stopped, by the closed file alone so far. A pause or
                        # a failure? The card waits for downloads.json to tell
                        # (shown_state), so that it changes once, to the right
                        # one; the loop looks often meanwhile (settling).
                        dl.early_paused, dl.peek_not_before = True, now + EARLY_PEEK_DELAY
                    elif dl.early_paused and listed == "paused":
                        dl.early_paused = False                    # downloads.json says so too:
                        if dl.peek_not_before is not None:
                            dl.peek_not_before = now               # no need to wait any longer
                    if change:
                        if stopped_early and was_active and dl.state == "paused" and listed != "paused":
                            change += " (the browser closed the partial file; its downloads.json hasn't said so yet)"
                        if dl.state == "paused" and now < dl.hold_until:
                            change += (f" -- the Mac just woke up: shown only if Firefox hasn't resumed it "
                                       f"within {dl.hold_until - now:.0f} s")
                        log_event(f"{dl.filename}: {change}")
                        if dl.state == "active":
                            if dl.restart_requested_at is not None:
                                log_event(f"{dl.filename}: {ACTION_NAMES[dl.restart_kind]} worked, data again "
                                          f"{now - dl.restart_requested_at:.2f} s after the press")
                                dl.restart_requested_at = None
                            if dl.notice in (WORKING_NOTICES["resume"], WORKING_NOTICES["retry"]):
                                dl.notice = None

                # 2b. A button press that didn't take.
                for dl in tracked.values():
                    if dl.restart_requested_at is not None and now - dl.restart_requested_at >= RESTART_GIVEUP_SECONDS:
                        was = "canceled" if dl.resolved_at is not None else dl.state
                        log_event(f"{dl.filename}: still {was} {RESTART_GIVEUP_SECONDS:.0f} s after "
                                  f"{ACTION_NAMES[dl.restart_kind]} was pressed")
                        dl.restart_requested_at = None
                        dl.notice = GAVE_UP_NOTICES[dl.restart_kind]
                        dl.notice_until = now + NOTICE_SECONDS
                        if dl.resolved_at is not None:
                            dl.resolved_at = now          # the card stays up while it says so
                    if dl.resolved_at is not None:
                        continue
                    if dl.cancel_requested_at is not None and now - dl.cancel_requested_at >= CANCEL_GIVEUP_SECONDS:
                        log_event(f"{dl.filename}: still downloading {CANCEL_GIVEUP_SECONDS:.0f} s after Cancel was pressed")
                        dl.cancel_requested_at = None
                        dl.notice = GAVE_UP_NOTICES["stop"]
                        dl.notice_until = now + NOTICE_SECONDS

                # 2c. No data for a while: is its browser still open? Or is the
                # download stalled?
                for dl in tracked.values():
                    if dl.resolved_at is not None or dl.busy:
                        continue
                    quiet = now - dl.last_growth_at
                    closed = quiet >= CLOSED_CHECK_AFTER and presence.closed_for(dl.profile, now)
                    if closed != dl.browser_closed:
                        dl.browser_closed = closed
                        if not closed:
                            log_event(f"{dl.filename}: its browser is open again")
                        elif dl.state == "active":
                            log_event(f"{dl.filename}: its browser was closed at {human_bytes(dl.size)}; "
                                      f"Firefox carries on with the download when it reopens")
                        else:
                            log_event(f"{dl.filename}: its browser was closed (the download stays {dl.state})")
                    stalled = dl.stalled(now)
                    if stalled and not dl.stall_logged:
                        dl.stall_logged = True
                        log_event(f"{dl.filename}: stalled: no data for {STALL_SECONDS} s at {human_bytes(dl.size)}")
                    elif dl.stall_logged and not stalled:
                        dl.stall_logged = False
                        if quiet < STALL_SECONDS:
                            log_event(f"{dl.filename}: data again after stalling")

                # 3. Detect completion / cancellation: the .part file vanished.
                for part_path, dl in tracked.items():
                    if dl.resolved_at is not None:
                        continue
                    if part_path in seen_now or os.path.exists(part_path):
                        dl.missing_ticks = 0  # (a failed folder listing is not a vanish)
                        continue
                    dl.missing_ticks += 1
                    verdict, final = classify_vanished(dl)
                    if verdict == "unsure" and dl.missing_ticks <= EMPTY_FILE_TICKS:
                        continue
                    if verdict == "canceled" and not dl.stopping and (
                            dl.missing_ticks <= VANISH_GRACE_TICKS or now < dl.hold_until):
                        continue
                    if final is not None:
                        dl.final_path = final
                    dl.succeeded = verdict != "canceled"
                    dl.resolved_at = now
                    dl.notice = None                  # ("Stopping…" and the like: that's settled)
                    if dl.stopping and dl.stop_pressed_at is not None:
                        took = now - dl.stop_pressed_at
                        log_event(f"{dl.filename}: " + (
                            f"finished before the cancel landed ({took:.2f} s after Stop)" if dl.succeeded
                            else f"canceled, partial file removed {took:.2f} s after Stop was pressed"))
                    dl.cancel_requested_at = dl.restart_requested_at = None

                # 3b. Retry pressed on a canceled card, and the download finished
                # before a scan saw its partial file: done, all the same.
                for dl in tracked.values():
                    if dl.can_restart and dl.restart_requested_at is not None:
                        verdict, final = classify_vanished(dl)
                        if verdict == "done" and final is not None:
                            log_event(f"{dl.filename}: finished right after Retry "
                                      f"({now - dl.restart_requested_at:.2f} s after the press)")
                            dl.final_path, dl.succeeded, dl.resolved_at = final, True, now
                            dl.restart_requested_at, dl.notice = None, None

            # 4. Send whatever changed. The sneak peek opens by itself when a
            # download finishes, pauses, fails or is canceled, and for messages --
            # unless you're away: then it waits until you're back (step 4b).
            # Only NOTCH_PLACES downloads have a card of their own, and only the
            # first of them shows its status on it: see "Places".
            for dl in assign_places(tracked.values(), places_free_from, now):
                if NOTCH_PLACES > 0 and dl.last_signature is not None:        # (it waited)
                    log_event(f"{dl.filename}: its turn, it has a card ({now - dl.started_at:.0f} s after it started)")
            first = first_in_place(tracked.values())
            in_spot = any(d.spot for d in tracked.values())
            for dl in tracked.values():
                surfaces, signature = dl.current_surfaces(numeric_style)
                kind = signature[0]
                if dl.resolved_at is not None and dl.place and NOTCH_PLACES > 0 and dl is not first and not dl.spot:
                    # Another download than the first is over: its card goes and
                    # its place is the next one's. Its status shows in the main place.
                    if dl.created:
                        dlk.send({"schemaVersion": 1, "type": "dismiss", "activityID": dl.activity_id})
                        dl.created = False
                    dl.place = False
                    places_free_from = now + PLACE_GAP_SECONDS
                on_card = dl.place or dl.spot             # (else it waits: nothing to send)
                # A pause known only from the closed partial file changes the
                # pill at once and opens its sneak peek a moment later (see
                # EARLY_PEEK_DELAY).
                peek_waits = kind == "paused" and dl.peek_not_before is not None and now < dl.peek_not_before
                peek_due = kind == "paused" and dl.peek_not_before is not None and not peek_waits \
                    and dl.presented_state != kind
                owed = dl.created and dl.peek_owed is not None and now >= dl.peek_owed[1]
                if signature == dl.last_signature and not peek_due and dl.line_phase == dl.line_phase_sent \
                        and not owed and (dl.created or not on_card):
                    continue                              # (the same card, and its line where it was)
                msg_type = "create" if not dl.created else "update"
                payload = {
                    "schemaVersion": 1, "type": msg_type,
                    "activityID": dl.card_id, "surfaces": surfaces,
                }
                if msg_type == "create":
                    payload.update(title="Download", priority="normal", size=ACTIVITY_SIZE)
                present = None
                if dl.last_signature is not None and signature[:-1] == dl.last_signature[:-1] and not peek_due:
                    pass                                  # only redrawn (a setting changed): no sneak peek
                elif kind in ("done", "canceled", "notice"):
                    present = present_seconds(kind)
                elif kind in ("paused", "failed") and dl.presented_state != kind and not peek_waits:
                    present = present_seconds(kind)       # once per pause or failure
                if kind in ("paused", "failed") and not peek_waits:
                    dl.presented_state = kind
                    dl.peek_not_before = None
                if present and kind in HOLDABLE:
                    # It waits until you're back -- or for its turn in the main
                    # place, when it isn't this download's own card that's there,
                    # or when other cards wait for theirs. With "Focus Mode" on, a
                    # finished one also waits while another download is under way,
                    # and behind the finished ones that wait already.
                    away = waiting_for_you(away_cache)
                    others = [d for d in tracked.values() if d is not dl]
                    queued = bool(SETTINGS["focusMode"]) and kind == "done" and not dl.spot and any(
                        d.under_way(now) or (d.held is not None and d.held_why == "focus") for d in others)
                    behind = not dl.spot and any(d.held is not None and d.held_why == "turn" for d in others)
                    if away or queued or behind or not (NOTCH_PLACES <= 0 or dl.spot or (dl is first and not in_spot)):
                        if dl.held is None and queued:
                            log_event(f"{dl.filename}: done; shown when the other downloads are done too (Focus Mode)")
                        elif dl.held is None and away:
                            log_event(f"{dl.filename}: {kind} while you're away; shown when you're back")
                        dl.held = (kind, present, dl.held[2] if dl.held else now)
                        dl.held_why = "focus" if queued else ("away" if away else "turn")
                        present = None
                        if queued and dl.place and NOTCH_PLACES > 0:
                            # Its card and its place go at once: the next ones move up.
                            if dl.created:
                                dlk.send({"schemaVersion": 1, "type": "dismiss", "activityID": dl.activity_id})
                                dl.created = False
                            dl.place = False
                            places_free_from = now + PLACE_GAP_SECONDS
                            on_card = False
                again = False
                if owed:
                    if present is None and dl.held is None and (kind in HOLDABLE or kind == "notice"):
                        present, again = dl.peek_owed[0], True
                        if dl.resolved_at is not None:
                            dl.resolved_at = now          # (it stays its usual time from the sneak peek)
                    dl.peek_owed = None
                if not on_card:
                    dl.last_signature, dl.line_phase_sent = signature, dl.line_phase
                    continue
                # Its own card says its status: the card takes the main place for
                # that (another app's activity may have it; the plugin can't tell),
                # with the high priority. Asked for a card that isn't in the main
                # place yet, a sneak peek is dropped: it's asked for again a moment
                # later (on a card that was there already, that changes nothing).
                rise = bool(present) and supports_present_sneak_peek and kind in HOLDABLE and not dl.spot \
                    and not again and NOTCH_PLACES > 0
                if rise:
                    payload["priority"] = "high"
                    raised[dl.activity_id] = None
                    settling.pop(dl.activity_id, None)
                if msg_type == "create":
                    dl.created_at = now
                    if present:                           # (asked for with the card, it's ignored: a moment later)
                        dl.peek_owed, present = (present, now + PEEK_AFTER_CREATE), None
                elif rise:
                    dl.peek_owed = (present, now + PEEK_AFTER_CREATE)
                if supports_present_sneak_peek and present:
                    payload["presentSneakPeek"] = present
                    dl.peek_until = now + present
                    if kind in HOLDABLE:                  # (its line stays still at first, from now)
                        dl.line_from = now
                        payload["surfaces"], signature = dl.current_surfaces(numeric_style)
                        if dl.spot and dl.resolved_at is None:
                            dl.spot_until = now + present + SPOT_MARGIN_SECONDS
                        elif NOTCH_PLACES > 0:            # (a status card waits until this one has been seen)
                            next_replay_at = max(next_replay_at, now + (
                                keep_seconds(dl) if dl.resolved_at is not None else present) + 0.3)
                        if dl.activity_id in raised and not dl.spot and dl.resolved_at is None:
                            raised[dl.activity_id] = now + present + SPOT_MARGIN_SECONDS      # (step 4e)
                elif supports_present_sneak_peek and (dl.line_phase_sent, dl.line_phase) == ("held", "scrolling") \
                        and dl.peek_until is not None and dl.peek_until - now >= 0.5:
                    # The line starts to scroll while the sneak peek the plugin
                    # opened is still open. DynamicLake only shows a new text
                    # in it when it's asked for again: for the time that's left.
                    payload["presentSneakPeek"] = max(1, min(MAX_PRESENT_SECONDS, int(round(dl.peek_until - now))))
                dlk.send(payload)
                dl.created = True
                dl.last_signature = signature
                dl.line_phase_sent = dl.line_phase

            # 4b. You're back: open the sneak peeks that waited, one at a time,
            # oldest first. A finished or canceled card then stays its usual time.
            for dl in tracked.values():
                if dl.held is not None and now - dl.held[2] > HOLD_MAX_SECONDS:
                    dl.held = None                        # waited long enough
                    if dl.resolved_at is not None:
                        dl.resolved_at = now
            # The same goes for the sneak peeks that waited for their turn in the
            # main place: a download that isn't the first shows there on a card
            # made for that (see "Places").
            # Finished cards that wait because of "Focus Mode" join the line
            # when no download is under way (or the setting is turned off).
            if not SETTINGS["focusMode"] or not any(d.under_way(now) for d in tracked.values()):
                for dl in tracked.values():
                    if dl.held is not None and dl.held_why == "focus":
                        dl.held_why = "turn"
            in_line = [d for d in tracked.values() if d.held is not None and d.held_why != "focus"]
            if now >= next_replay_at and in_line \
                    and not any(dl.spot for dl in tracked.values()) and not waiting_for_you(away_cache):
                first = first_in_place(tracked.values())
                for dl in sorted(in_line, key=lambda d: (d.held[2], d.seq)):
                    surfaces, signature = dl.current_surfaces(numeric_style)
                    if signature[0] == "active":
                        dl.held = None                    # it carries on: nothing to show
                        continue
                    if signature[0] not in HOLDABLE:
                        continue                          # a message on it for now, or its browser closed: later
                    since, why = dl.held[2], dl.held_why
                    if NOTCH_PLACES > 0 and dl is not first:
                        dl.held = None
                        start_spot(dl, signature[0], now)
                        log_event(f"{dl.filename}: {signature[0]}, shown in the main place" + (
                            f" now that you're back ({now - since:.0f} s later)" if why == "away" else ""))
                        break
                    if not dl.created or now - dl.created_at < PEEK_AFTER_CREATE:
                        break                             # (its card is only just there: in a moment)
                    dl.held = None
                    dl.line_from = now                    # (its line stays still at first, from now)
                    surfaces, signature = dl.current_surfaces(numeric_style)
                    payload = {"schemaVersion": 1, "type": "update", "activityID": dl.activity_id,
                               "surfaces": surfaces}
                    if supports_present_sneak_peek:
                        payload["presentSneakPeek"] = present_seconds(signature[0])
                        dl.peek_until = now + payload["presentSneakPeek"]
                        if NOTCH_PLACES > 0:
                            # (as in step 4: its card takes the main place for it,
                            # and the sneak peek is asked for again a moment later)
                            payload["priority"] = "high"
                            settling.pop(dl.activity_id, None)
                            raised[dl.activity_id] = None if dl.resolved_at is not None \
                                else now + payload["presentSneakPeek"] + SPOT_MARGIN_SECONDS
                            dl.peek_owed = (payload["presentSneakPeek"], now + PEEK_AFTER_CREATE)
                    dlk.send(payload)
                    dl.last_signature = signature
                    dl.line_phase_sent = dl.line_phase
                    gap = REPLAY_GAP_SECONDS
                    if dl.resolved_at is not None:
                        dl.resolved_at = now
                        gap = max(gap, keep_seconds(dl) + 0.3)    # (after this card has gone)
                    next_replay_at = now + gap
                    if why == "away":
                        log_event(f"{dl.filename}: {signature[0]}, shown now that you're back "
                                  f"({now - since:.0f} s later)")
                    break

            # 4c. The cards lowered to give the main place back: whatever moves
            # up is there by now. Their usual priority again, the oldest
            # download's first (those that are still there).
            due = [card for card, when in settling.items() if now >= when]
            if due:
                for card in own_cards():
                    if card in due and card not in raised and card != spot_pinned:
                        send_priority(card, "normal")
                for card in due:
                    del settling[card]

            # 4d. A paused or failed download's status card has had its time in
            # the main place (not while a button works on it, or says something),
            # or the download carries on.
            for dl in tracked.values():
                if not dl.spot or dl.resolved_at is not None or dl.peek_owed is not None:
                    continue
                if dl.job is not None or dl.restart_pending or (dl.notice and now < dl.notice_until):
                    continue
                if dl.spot_until is None or now >= dl.spot_until or (
                        dl.shown_state(now) == "active" and not dl.browser_closed):
                    end_spot(dl, now)

            # 4e. A download's own card has had the main place for its pause or
            # its failure (not while a button works on it, or says something),
            # or the download carries on: the place is given back. All the
            # plugin's cards get the low priority for a moment, this one last:
            # another app's activity moves up if there's one; if not, this card
            # stays where it is (between equals, the card that's there stays).
            # A finished or canceled download's card just goes at its time.
            for card, until in list(raised.items()):
                dl = next((d for d in tracked.values() if d.activity_id == card and d.created and not d.spot), None)
                if dl is None:
                    del raised[card]                      # (the card has gone)
                    continue
                if dl.resolved_at is not None or dl.peek_owed is not None:
                    continue
                if dl.job is not None or dl.restart_pending or (dl.notice and now < dl.notice_until):
                    continue
                if until is None or now >= until or (dl.shown_state(now) == "active" and not dl.browser_closed):
                    del raised[card]
                    lower([c for c in own_cards(but=card) if c not in raised and c != spot_pinned] + [card], now)
                    log_event(f"{dl.filename}: its card has had the main place for its status; the place is given back")

            # 5. Dismiss cards whose grace period has elapsed (not while a button
            # works on them, nor while they wait for you).
            now = time.monotonic()
            for part_path in list(tracked.keys()):
                dl = tracked[part_path]
                if dl.resolved_at is None or dl.job is not None or dl.restart_pending or dl.held is not None:
                    continue
                if now - dl.resolved_at > keep_seconds(dl):
                    if dl.spot:
                        end_spot(dl, now)
                    if dl.created:
                        dlk.send({"schemaVersion": 1, "type": "dismiss",
                                  "activityID": dl.activity_id})
                    if dl.place:
                        places_free_from = now + PLACE_GAP_SECONDS
                    del tracked[part_path]
                    baseline_sizes.pop(part_path, None)
                    if dl.resolved_reason == "Blocked":
                        # The held-back file stays until you decide in the
                        # browser; don't show it again unless it grows.
                        try:
                            baseline_sizes[part_path] = part_path.stat().st_size
                        except OSError:
                            pass
        except (ConnectionError, OSError):
            raise                    # DynamicLake went away: the plugin ends (see __main__)
        except Exception as exc:     # a bug must not end the plugin: log it and carry on
            where = "".join(traceback.format_exception_only(type(exc), exc)).strip()
            if where != last_error[0] or time.monotonic() - last_error[1] > 60:
                last_error = (where, time.monotonic())
                log_event("error in the main loop (carrying on): " + " | ".join(
                    ln.strip() for ln in traceback.format_exc().strip().splitlines()[-6:]))
            time.sleep(0.5)


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, OSError) as exc:
        print(f"Firefox Downloads exiting: {exc}", file=sys.stderr)
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(0)
