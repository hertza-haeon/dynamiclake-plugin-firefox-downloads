# Firefox Downloads

<p align="center">
  <img src="icon.png" alt="Firefox Downloads icon" width="128">
</p>

<p align="center">
  <b>Your Firefox downloads, in the notch.</b><br>
  A plugin for <a href="https://dynamiclake.com">DynamicLake</a>.
</p>

Firefox Downloads shows every download in your MacBook's notch: how far it
is, how fast it goes, how long is left. You can stop, resume or retry a
download and open the finished file without going back to the browser.

- **No browser extension.** Nothing to install in the browser.
- **Works with** Firefox, LibreWolf, Waterfox, Pale Moon and Tor Browser.
- **Stays on your Mac.** The plugin sends nothing over the internet.

## Contents

- [What you need](#what-you-need)
- [Install](#install)
- [Permissions](#permissions)
- [What you see](#what-you-see)
- [The buttons](#the-buttons)
- [Several downloads at once](#several-downloads-at-once)
- [Settings](#settings)
- [Good to know](#good-to-know)
- [If something goes wrong](#if-something-goes-wrong)
- [What the plugin does on your Mac](#what-the-plugin-does-on-your-mac)
- [Uninstall](#uninstall)

## What you need

- A Mac with [DynamicLake](https://dynamiclake.com).
- One of the browsers above. The plugin shows what's saved to the download
  folder set in the browser (your Downloads folder unless you changed it).
- The **Downloads button on the browser's toolbar** (it's there unless you
  removed it). The plugin's buttons work through it.
- **Python 3** (3.9 or later). The plugin is a Python program, and macOS
  doesn't always have Python. To check, open Terminal and type:

  ```bash
  python3 --version
  ```

  If it answers with a number such as `Python 3.9.6`, you're set. If macOS
  offers to install the "command line developer tools" instead, click
  **Install**: Python comes with them. Python from
  [Homebrew](https://brew.sh) or [python.org](https://www.python.org/downloads/)
  works too.

## Install

1. Download `FirefoxDownloads.dynamiclakeplugin.zip` from the
   [latest release](https://github.com/hertza-haeon/dynamiclake-plugin-firefox-downloads/releases/latest)
   and unzip it.
2. Open **DynamicLake → Settings → Plugins**.
3. Click **Install Local** and choose the
   `FirefoxDownloads.dynamiclakeplugin` folder you unzipped. Keep that exact
   name.
4. Give DynamicLake the two [permissions](#permissions) below.

That's all: start a download in your browser and it shows in the notch.

To update, install the newer folder the same way and confirm **Update**.
Your settings are kept.

## Permissions

The plugin runs inside DynamicLake, so the permissions are DynamicLake's.

| Permission | What it's for | Where to turn it on |
| --- | --- | --- |
| **Accessibility** | Stop, Resume and Retry: pressing the browser's own buttons for you | System Settings → Privacy & Security → Accessibility → DynamicLake |
| **Automation** (System Events) | The same three buttons | Click **OK** when macOS asks, or System Settings → Privacy & Security → Automation → DynamicLake |

Without them, everything else still works: progress, Show in Finder and
Open File need no permission. The three buttons then say
`Needs Accessibility access` or `Needs Automation access`.

## What you see

A download shows in two ways:

- **The pill**, in the closed notch: the file's type on the left, a progress
  ring or a status symbol on the right.
- **The sneak peek**, the larger view that opens when you point at the
  notch: a button, a line of text and a percentage. It also opens by itself
  when a download finishes, pauses, fails or is canceled.

The file's type is its extension in a blue circle (`pdf`, `dmg`, `zip`). A
download starts with a blue arrow and shows its type 5 seconds later.

| The download is… | Pill, right side | Sneak peek | Buttons |
| --- | --- | --- | --- |
| Downloading | progress ring | `294/871MB · 2 min 34 s` and `18%` | Stop |
| Stalled (no data for 15 seconds) | red **…** | `Stalled • report.pdf` | Stop |
| Paused | orange pause | `Paused • report.pdf` | Resume |
| Failed | red **!** | `Failed • report.pdf` | Retry |
| Canceled | red **✕** | `Canceled • report.pdf` | Retry |
| Blocked by the browser | red **–** | `Blocked • report.pdf` | none: decide in the browser |
| Finished | green **✓** | `Complete • report.pdf` | Show in Finder, Open File |
| Waiting for its browser, which is closed | orange pause | `Browser closed • report.pdf` | none until the browser is open again |

While downloading, the line reads the amount and the total (`294/871MB`, or
`0.83/2.00GB` from 1 GB), then the time left, the speed, how many downloads
are waiting, or all of these in turn: your choice in
[Settings](#settings).

A finished or canceled card goes away after its sneak peek. A paused or
failed download stays until it carries on or is canceled. A name too long
to fit stays still for 3 seconds, then scrolls.

## The buttons

| Button | What it does |
| --- | --- |
| **Stop** | Cancels the download in the browser. |
| **Resume** | Carries on with a paused download. |
| **Retry** | Carries on with a failed download from where it stopped, when the server allows. On a canceled card, starts the download over. |
| **Show in Finder** | Shows the finished file in the Finder. |
| **Open File** | Opens the finished file, as a double-click would. |

While a button works, the line reads `Stopping…`, `Resuming…` or
`Retrying…`. If it can't do what you asked, it says why: see
[If something goes wrong](#if-something-goes-wrong).

## Several downloads at once

DynamicLake shows two things at a time: one in the notch, one as a small
**capsule** beside it.

- **The first download** is in the notch, **the second** is the capsule.
  The capsule shows the file's type. Click it to bring that download to
  the notch, with its progress and its buttons.
- **The others wait.** Each takes a place, in the order they started, when
  a download before it has finished or been canceled. A paused or failed
  download keeps its place. With Download Details on Queue or All, the
  line says how many are waiting: `+2 Queuing`.
- **You don't miss anything.** When a download that isn't the first one
  finishes, is canceled, pauses or fails, a card says so in the notch, with
  its buttons, for the usual time. Then the notch goes back to what it
  showed. These cards come one at a time.

## Settings

In **DynamicLake → Settings → Plugins**, right-click **Firefox Downloads**
and choose **Settings**. Changes apply within a few seconds.

| Setting | Default | What it does |
| --- | --- | --- |
| **File-Type Icons** | On | Shows the file's extension in a blue circle. Off: the blue arrow. |
| **Download Details** | Time | What follows the amount while downloading. **Speed**: `1.2 MB/s`. **Time**: `2 min 34 s`. **Queue**: how many downloads wait for their turn, `+2 Queuing` (nothing when none does). **All**: each of these in turn, 3 seconds at a time. |
| **App Switching After Resume** | On | Resume makes the browser take the keyboard and leave its Downloads panel open over your app. On: the plugin gives your app the keyboard back and has the browser close its panel; the browser comes to the front for an instant. Off: the panel stays until you click in the browser. |
| **Focus Mode** | Off | When a finished download's card shows. **Off**: as soon as it finishes. **On**: it waits while another download is still running, then the finished cards show one after the other. **Simplified**: the same, but the finished downloads share one card that says how many there are, `3 Downloads Completed`. A pause, a failure or a cancellation always shows at once. |
| **Delayed Display** | On | While you're away, nothing opens the notch. When you're back, the sneak peeks you missed open one by one. |
| **Away After** | 1 min | You count as away when the screen is locked, or after this long without touching the keyboard, mouse or trackpad: 1, 3, 5 or 10 minutes. |
| **Sneak Peek Duration** | 5 s | How long the sneak peek stays open when something happens to a download: 3, 5, 8 or 10 seconds. |
| **Remain Visible** | 0 s | How long the closed pill of a finished or canceled download stays after its sneak peek, from 0 to 30 seconds. |

## Good to know

**Timing**

- A pause or a failure shows about a second and a half after it happens:
  the plugin waits for the browser to say which of the two it is.
- After your Mac wakes up, a pause can take 15 seconds to show. The browser
  pauses downloads when the Mac sleeps and resumes them by itself.
- The ring starts filling a moment after a download starts. If the server
  doesn't give the file's size, the ring keeps spinning and the percentage
  reads `—`.

**The buttons**

- Resume can't be invisible: the browser's menu flashes, the pointer moves
  for an instant and is put back, and with App Switching After Resume on,
  the browser's window comes to the front for an instant.
- After Stop or Retry, the browser's Downloads panel stays open in the
  browser window until your next click there.
- The buttons reach the 5 most recent downloads in the browser's panel.
- Retry on a canceled card has to be pressed while the card is up. Later,
  retry in the browser.
- When a server can't carry on with a download, a failed download can show
  as canceled after Retry. Retry again starts it over.
- If you quit the browser during a download, its card waits. The browser
  carries on with the download when you open it again.
- A download that waits for its turn has no card, so no button: use the
  browser until then.

**The capsule and other apps**

- The capsule shows the file's type only. DynamicLake draws a plugin's
  capsule once, so it can't follow the progress. Click it to see more.
- With Focus Mode on, a finished download leaves the notch at once and its
  card comes later, with Show in Finder and Open File. A download that's
  paused, failed or stalled doesn't keep finished cards waiting.
- With Focus Mode on Simplified, the one card for several finished
  downloads has their number where a file's type is. Its Show in Finder
  shows them all; it has no Open File. A single finished download shows
  its usual card.
- When something else has the notch (music, for example), your download
  is the capsule beside it. When it finishes, is canceled, pauses or
  fails, its card takes the notch for the usual time, with its sneak peek
  and its buttons. Then the other activity is back.
- The plugin can't tell what had the notch. If your download was there
  before the music started, the music has the notch after such a card.
- If you clicked the capsule to swap two downloads, they're swapped back
  after the next card about a download.

**What isn't shown**

- A file you save somewhere other than the browser's download folder.
- For a private-window download: its size (the ring keeps spinning), and a
  pause or a failure (a paused one shows as stalled).

## If something goes wrong

**Nothing shows in the notch when a download starts.** Check that Python 3
is installed (see [What you need](#what-you-need)), then quit DynamicLake
and open it again.

**The buttons don't work.** Check the two [permissions](#permissions), and
that the Downloads button is on the browser's toolbar.

**DynamicLake says the plugin can't be run.** In Terminal:

```bash
chmod +x FirefoxDownloads.dynamiclakeplugin/firefox_downloads.py
```

**A button answers with a message.** Nothing wrong was pressed: when the
plugin isn't sure, it does nothing and tells you.

| Message | What it means |
| --- | --- |
| `Needs Accessibility access`, `Needs Automation access` | See [Permissions](#permissions). |
| `No Downloads button in toolbar` | Put the Downloads button back on the browser's toolbar. |
| `Browser isn't running` | No supported browser is open. |
| `Not in the Downloads panel` | The browser's panel doesn't list this download. |
| `Not paused in the browser` | The browser doesn't show it as paused. |
| `Nothing to retry in the panel` | The browser doesn't offer Retry for it. |
| `Several matches — … in browser` | More than one download has this name. Use the browser. |
| `Panel busy — try again` | Downloads changed while the plugin was looking. Press again. |
| `Downloads panel didn't open` | The browser's panel didn't appear. Press again. |
| `No menu — resume in browser`, `Row hidden — resume in browser`, `Resume failed — resume in browser` | Resume couldn't be chosen. Resume in the browser. |
| `Menu left open — click elsewhere` | The browser's menu stayed open. Click anywhere to close it. |
| `Didn't stop — … in browser` (or resume, restart) | The button was pressed, but the download didn't change. Use the browser. |
| `Couldn't reach the browser` | The browser didn't answer in time. Use the browser. |

**Still stuck?** The plugin keeps a log of what it did and why:

```
~/Library/Logs/FirefoxDownloads/plugin.log
```

Its last lines usually tell what happened.

## What the plugin does on your Mac

- It **watches** your browser's download folder and **reads** the browser's
  own list of downloads. It never changes the browser's files.
- For Stop, Resume and Retry, it **presses the browser's own button** for
  that one download, after checking twice that it's the right one. If
  anything is unclear, it presses nothing.
- It **never types** anything and never touches the pages you browse.
- It **sends nothing** over the internet.

## Uninstall

1. In **DynamicLake → Settings → Plugins**, right-click **Firefox
   Downloads** and choose **Uninstall**.
2. Optionally, delete what it left behind:

```
~/Library/Logs/FirefoxDownloads/
~/Library/Caches/FirefoxDownloads/
```

---

<sub>Firefox and the Firefox logo are trademarks of the Mozilla Foundation.
This plugin is an independent project. It is not affiliated with, or
endorsed by, Mozilla or DynamicLake.</sub>
