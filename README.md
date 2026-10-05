# Firefox Downloads

A DynamicLake plugin that shows Firefox downloads in the notch: progress,
speed or time left, a Stop button, Resume when a download pauses, Retry when it fails
or is canceled, and Show in Finder and Open File when it's done. No browser
extension needed. Also works with LibreWolf, Waterfox, Pale Moon and Tor Browser.

## What it shows

|  | Pill, left | Pill, right | Sneak peek, left | Sneak peek, center | Sneak peek, right |
| --- | --- | --- | --- | --- | --- |
| Downloading | file type | progress ring | Stop (red square) | `294/871MB · 2 min 34 s` | `18%` |
| Stalled | file type | red … | Stop (red square) | `Stalled • report.pdf` | `18%` |
| Paused | file type | orange pause | Resume (green play) | `Paused • report.pdf` | `18%` |
| Failed | file type | red ! | Retry (blue circular arrow) | `Failed • report.pdf` | `18%` |
| Canceled | file type | red ✕ | Retry (blue circular arrow) | `Canceled • report.pdf` | |
| Blocked | file type | red – | | `Blocked • report.pdf` | |
| Finished | file type | green ✓ | Show in Finder (blue folder) | `Complete • report.pdf` | Open File (blue file) |
| Browser closed | file type | orange pause | | `Browser closed • report.pdf` | `18%` |

The pill shows the file's type: its extension in a blue circle (`pdf`,
`dmg`, `zip`; four characters at most). A download starts with the blue
download arrow and shows its type 5 seconds later. A file without an
extension keeps the arrow.

While downloading, the middle shows the amount and the total, in whole
megabytes for a file under 1 GB (`294/871MB`) and in gigabytes with two
decimals from 1 GB (`0.83/2.00GB`), then the speed, the time left, or the
two in turn (see Settings). The time left always has its seconds (`45 s`,
`2 min 34 s`, `1 h 20 min 5 s`) and counts down every second. Until there's
enough data to tell it, the speed shows in its place.

When something happens to a download, the middle says what, then the file's
name; a long name scrolls. While a button works, it reads `Stopping…`,
`Resuming…` or `Retrying…`. The sneak peek opens by itself when a download
pauses, fails, finishes or is canceled, unless you're away (see Settings),
and stays open for 5 seconds. A finished or canceled card then goes, together
with its sneak peek. Both times are settings: how long the sneak peek stays
open, and how long the closed pill stays after it. A paused or failed
download stays in the pill until it carries on or is canceled. A download that gets no data for 15 seconds shows `Stalled`
until data comes again. A download the browser holds back as a potential
security risk shows `Blocked` for a moment: only you can decide about it, in
the browser. Several downloads at once each get their own activity.

## Install

1. In DynamicLake: **Settings → Plugins → Install Local**, then choose the
   `FirefoxDownloads.dynamiclakeplugin` folder (keep that exact name).
2. Give DynamicLake the permissions below.

If DynamicLake says the executable isn't runnable, run
`chmod +x FirefoxDownloads.dynamiclakeplugin/firefox_downloads.py`.

## Permissions

Stop, Resume and Retry need two macOS permissions for DynamicLake:

- **Accessibility:** System Settings → Privacy & Security → Accessibility →
  turn on DynamicLake.
- **Automation:** allow DynamicLake to control System Events when macOS asks
  (later: Privacy & Security → Automation → DynamicLake).

Progress, Show in Finder and Open File need nothing extra.

## Settings

In DynamicLake → Settings → Plugins → Firefox Downloads. Changes apply
within a few seconds, to the downloads on screen too.

- **File-Type Icons** (on): the file's extension in a blue circle in the
  pill. Off, the pill keeps the download arrow.
- **Download Details** (Time): what follows the amount while downloading.
  **Speed**: `294/871MB · 1.2 MB/s`. **Time**: the time left,
  `294/871MB · 2 min 34 s`. **Both**: the speed and the time left take
  turns, 4 seconds each.
- **App Switching After Resume** (on): Resume opens the download's menu in
  the browser, which takes the keyboard, and leaves the browser's Downloads
  panel floating over the app you're using. On, the plugin gives your app
  the keyboard back and makes the browser close its panel: the browser
  comes to the front for an instant, then your app is back (see How it
  works). Off, the plugin leaves all that alone: the panel stays until you
  click in the browser.
- **Focus Mode** (off): does nothing yet. It's there for a later update.
- **Delayed Display** (on): while you're away, a download that finishes,
  pauses, fails or is canceled updates its pill but doesn't open the notch.
  When you're back, the sneak peeks open one by one, oldest first, and
  finished or canceled cards stay their usual time from then on.
- **Away After** (1 min): you count as away when the screen is locked, or
  after this long without keyboard, mouse or trackpad input: 1, 3, 5 or 10
  minutes.
- **Sneak Peek Duration** (5 s): how long the sneak peek stays open when a
  download finishes, pauses, fails or is canceled: 3, 5, 8 or 10 seconds.
- **Remain Visible** (0 s): how long the closed pill of a finished or
  canceled download stays after its sneak peek has closed, from 0 to 30
  seconds. At 0, the card goes away together with its sneak peek.

## How it works

**Progress.** Firefox saves a download as a `.part` file until it
finishes. The plugin watches the download folders set in your browser
profiles. The amount downloaded is that file's size, and the speed is how
fast it grows; the time left comes from the speed, smoothed so that it
counts down steadily instead of jumping around. The total size, and whether
a download is paused or failed, come from `downloads.json`, the file Firefox
keeps in each profile listing downloads in progress. The plugin only reads
it. Firefox updates it about 1.5 s after a change, so the ring starts
filling that long after the download starts.

If there's no total size, the ring keeps spinning and the percentage shows
`—`. That happens when the server doesn't report a size, or for
private-window downloads, which Firefox doesn't save to disk.

**Paused or failed?** A download pauses when you pause it in the browser,
or when Firefox pauses it because the Mac goes to sleep or offline. A
connection that drops mid-download makes it fail instead; Retry then carries
on from where it stopped, or starts over when the server can't resume
downloads.

A pause shows in about a second: the pill first, the sneak peek a moment
later. The browser closes the partial file the moment it stops a download,
and the plugin sees that: it asks macOS whether the browser still has the
file open, and changes nothing. Whether the stop is a pause or a failure,
only `downloads.json` tells, about 1.5 s later; so a failed download shows
as paused for that moment, then as failed.

**Sleep.** When the Mac goes to sleep, Firefox pauses the downloads in
progress and resumes them by itself 10 s after the Mac wakes up. So for 15 s
after a wake, a pause of a download that was in progress isn't shown (it
shows as in progress, with no speed yet); only if Firefox hasn't resumed it
by then does the Paused card appear. A download you'd paused yourself stays
paused, and shows so.

**Browser closed.** When no data comes for a few seconds, the plugin checks
whether the browser the download belongs to is still open, by the lock its
profile holds while it's open (it only looks; it never takes the lock).
Closed, the card shows `Browser closed` with no button, since the buttons
need the browser. Firefox carries on with a download that was in progress
when you open it again, and the card follows. A paused or failed download
keeps its card, without Resume or Retry until the browser is back. This
needs to know which browser profile a download belongs to, from its
`downloads.json`: a private-window download (which the browser deletes when
it quits) or one from a browser the plugin doesn't know shows as stalled
instead.

**Show in Finder and Open File**, on the finished card, don't involve the
browser. Open File opens the file in the app for its type, as a double-click
in the Finder would; macOS asks first about an app or a script that came
from the internet.

**Stop, Resume and Retry** work like the browser's own and keep it in the background.
The plugin presses the toolbar's Downloads button through macOS
Accessibility (a direct action, not a keystroke) and finds the one row for
this file in the panel:

- **Stop** presses the row's Cancel button. Finished entries with the same
  name are ignored.
- **Retry** presses the Retry button of the row showing Failed. On a
  canceled card, it presses the Retry button of the row showing Canceled
  (or Failed, when the browser deleted what it had): the browser starts the
  download over, and the same card follows it. Retry in the browser's own
  panel brings a canceled card back to life too, while it's still up.
- **Resume** has no button in the panel: it's in the row's right-click
  menu. The plugin opens that menu and chooses Resume at once, so the menu
  only flashes. To open the menu, the browser moves the pointer onto the
  row; the plugin puts it straight back. The menu takes the keyboard while
  it's up, and afterwards the browser keeps its Downloads panel floating
  over whatever app you're in. The browser only closes that panel when it
  comes to the front, so the plugin brings it to the front and your app
  straight back, about a tenth of a second later (see Settings to turn this
  off). It does so only when it's sure you're still where you were: the app
  you were in is the one in front, and you haven't clicked or typed since
  you pressed Resume. Otherwise it leaves the panel alone. Nothing is
  clicked, and nothing is typed.

It only ever presses Firefox's own Cancel or Retry button, in the single row
whose title starts with this exact file name, checked again right before
pressing. The panel shows a long name shortened in the middle; such a row
counts only when the full name it keeps for its tooltip is exactly this
file's, read again right before pressing. For Resume, it chooses the item labelled exactly Resume in that row's menu,
once it has checked the menu opened for that row, is the Downloads menu and
has exactly one such item. Otherwise the menu is closed untouched. Labels
are matched in any of Firefox's languages. It never types anything and never
touches web page content. To respond fast, it compiles
its script once (cached in `~/Library/Caches/FirefoxDownloads/`) and warms up
when a download starts, at most every 2 minutes. The warm-up only finds the
button; it presses nothing.

## Limits

- The buttons need the Downloads button on the browser toolbar (it's there
  by default).
- After Stop or Retry, the browser's Downloads panel stays open in the
  browser window until your next click there (closing it would take a
  keystroke). After Resume the plugin makes the browser close it, as
  described above; if you click or type right after pressing Resume, the
  panel is left alone and stays, over your app, until you click in the
  browser.
- The panel lists the 5 most recent downloads, so the buttons can't reach a
  download older than that.
- When a download from a server that can't resume fails again after Retry,
  Firefox deletes its partial file, so it shows as Canceled; its Retry then
  starts it over.
- Resume can't be completely invisible: the panel has no Resume button, so
  the browser's right-click menu flashes for an instant, and the browser
  window comes to the front for an instant to close its panel. Only a
  browser extension could resume a download without them.
- Private-window downloads never show Paused or Failed: a paused one shows
  as stalled.
- A canceled card stays up for the time of Sneak Peek Duration plus Remain
  Visible (5 seconds unless you change them), so its Retry has to be
  pressed within that time; later, retry in the browser.

## Messages

| Message | Meaning |
| --- | --- |
| Didn't stop / resume / restart — … in browser | The press went through, but the download didn't change. |
| Not in the Downloads panel | No row for this file in the panel (for Stop: no active one). |
| Not paused in the browser | The browser doesn't show it as paused. Nothing was chosen. |
| Nothing to retry in the panel | The browser doesn't offer Retry for it. |
| No menu — resume in browser | The row's menu didn't open, or wasn't the Downloads menu. |
| Row hidden — resume in browser | The row isn't fully in view (in the panel, inside the browser window), so its menu wasn't opened. |
| Resume failed — resume in browser | Choosing Resume didn't work; the menu was closed. |
| Menu left open — click elsewhere | The row's menu wouldn't close. Nothing was chosen in it. |
| Several matches — … in browser | More than one row has this name. Nothing was pressed. |
| Panel busy — try again | Downloads changed while it was checking. Nothing was pressed. |
| Downloads panel didn't open | The panel didn't appear. |
| No Downloads button in toolbar | See Limits. |
| Browser isn't running | No Firefox-family browser is open. |
| Couldn't reach the browser | The automation failed or timed out. Use the browser. |
| Needs Accessibility access / Needs Automation access | See Permissions. |

## Log

`~/Library/Logs/FirefoxDownloads/plugin.log` records each button press (the
result, how long it took and each step; after Resume, what was done about
the keyboard and the browser's panel, and why), each file opened with Open File, each warm-up, the settings, each download's total size,
when it pauses, fails, stalls or carries on, when its browser is closed or
opened again, when the Mac wakes up, and which sneak peeks waited for you.
It rolls over at 256 KB. If something goes wrong, check its last few lines
first.

## Customizing

Besides the settings above, a few values are constants at the top of
`firefox_downloads.py`:

- `ACTIVITY_SIZE`: pill width, `"small"` (default), `"normal"` or
  `"large"`.
- `POLL_INTERVAL`: how often the download folders are checked (0.6 s).
- `DETAILS_TURN_SECONDS`: with Download Details on Both, how long the speed
  and the time left each show (4 s).
- `ICON_DELAY_SECONDS`: how long a download shows the arrow before its file
  type (5 s).
- `STALL_SECONDS`: no data this long shows `Stalled` (15 s).
- `WAKE_GRACE_SECONDS`: how long after the Mac wakes up a pause waits
  before it's shown (15 s).
- `REPLAY_GAP_SECONDS`: the time between sneak peeks opening when you're
  back (6 s).
- `WARMUP_MIN_GAP`: minimum time between warm-ups (120 s).
- `FIREFOX_FAMILY`: which browsers' profiles are read.

## Uninstall

In DynamicLake → Settings → Plugins, right-click Firefox Downloads and
choose Uninstall, then delete
`~/Library/Logs/FirefoxDownloads/` and `~/Library/Caches/FirefoxDownloads/`.

---

The icon is Firefox's logo: fine for personal use, but check Mozilla's
trademark guidelines before publishing this plugin anywhere public.
