# MagicTrackpoint

**Make the Lenovo ThinkPad TrackPoint Keyboard II feel at home on a Mac.**

MagicTrackpoint is a tiny background helper for macOS. It has no window and no
menu-bar icon: you install it once, and from then on it does this.

| | What you do | What happens |
|---|---|---|
| **Sensitivity** | nothing | The TrackPoint speed you chose (1–9) is set in the keyboard itself, and set again when the keyboard reconnects or the Mac wakes up. |
| **Scrolling** | hold the middle button and push the TrackPoint | The page scrolls, up/down and left/right. Push harder to scroll faster. The cursor stays where it is. |
| **Middle click** | press and release the middle button without pushing | A normal middle click (open a link in a new tab, close a tab, …). |
| **Microphone key** (F4) | press it | Mutes or unmutes your microphone, with a short sound (*Pop* = muted, *Tink* = on). |
| **Bluetooth key** (F10) | press it | Opens Control Center on the Bluetooth device list; press again to close it. |
| **Print Screen** | press it | Sends ⇧⌘5, the screenshot shortcut (macOS or a tool such as CleanShot), like on the Mac's own keyboard. |

That's the whole tool. No other keyboard remapping, no accounts, no network,
no telemetry, no automatic updates. The other Lenovo keys (F8, F9, F11, F12)
send codes macOS ignores; MagicTrackpoint leaves them alone.

> Français : [docs/README.fr.md](docs/README.fr.md)

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Install](#2-install)
3. [Grant the two permissions](#3-grant-the-two-permissions)
4. [Check that it works](#4-check-that-it-works)
5. [Everyday use](#5-everyday-use)
6. [Settings](#6-settings)
7. [Troubleshooting](#7-troubleshooting)
8. [Uninstall](#8-uninstall)
9. [How it works](#9-how-it-works)
10. [Privacy and security](#10-privacy-and-security)
11. [Known limitations](#11-known-limitations)
12. [For developers](#12-for-developers)
13. [Credits and license](#13-credits-and-license)

---

## 1. Before you start

**Keyboard.**

| Model | Connection | USB ID | Status |
|---|---|---|---|
| ThinkPad TrackPoint Keyboard II | Bluetooth | `17EF:60E1` | Tested daily |
| ThinkPad TrackPoint Keyboard II | 2.4 GHz USB receiver | `17EF:60EE` | Expected to work (same protocol), **not tested** |

No other device is ever opened or reconfigured. Your trackpad and Apple
keyboard behave exactly as before; so does an external mouse, except while you
hold the TrackPoint's middle button (see [Known limitations](#11-known-limitations)).

**Mac.** macOS 12 Monterey or later, Apple Silicon or Intel (one universal
program for both).

**Another TrackPoint tool already installed?** Quit it first (for example the
TrackPointD app, and remove it from *System Settings → General → Login Items*).
Two tools driving the same keyboard fight each other. If you use
**Karabiner-Elements**, turn off *Modify events* for this keyboard.

---

## 2. Install

Pick **one** of the two ways. Both install the same files, for your user
account only. You never need an administrator password.

### Option A: the ready-made disk image (easiest)

1. Download `MagicTrackpoint-<version>.dmg` from the
   [Releases page](https://github.com/phocean/MagicTrackpoint/releases).
2. Open it, then double-click **Install MagicTrackpoint**. macOS first asks
   whether you really want to open an app downloaded from the Internet, and
   says Apple checked it for malicious software and found none: click
   **Open**. The installer then asks for confirmation, installs the helper and
   starts it.
3. Click **Continue** to grant the two permissions (next section explains
   them): System Settings opens on the right page, you turn on
   `magictrackpointd`, come back and click **Continue** again until it says
   *All permissions granted*. Then eject the disk image.

Everything on the disk image is signed with a Developer ID certificate and
notarized by Apple, so macOS opens it without warnings. *Install
MagicTrackpoint* is a tiny AppleScript application: it runs the same install
script as option B (without building anything). You can read it, and the
files it installs, with right-click → **Show Package Contents** →
`Contents/Resources`.

### Option B: build it yourself

You need the free Xcode Command Line Tools. If you have never installed them:

```bash
xcode-select --install
```

Then download the source and install:

```bash
git clone https://github.com/phocean/MagicTrackpoint.git
```

```bash
cd MagicTrackpoint
```

```bash
make install
```

`make install` compiles the program, runs the automated tests, signs the
program, installs it and starts it. It takes about a minute.

**About signing when you build it yourself.** macOS remembers the permissions
of step 3 per program signature:

- If your keychain has a **Developer ID Application** or **Apple Development**
  certificate, `make install` uses it, and the permissions survive every
  future rebuild.
- Otherwise the program is signed "ad hoc": it works, but macOS forgets the
  permissions each time you rebuild. You will have to grant them again after
  every `make install` (remove the old entry first).

`make help` lists every command.

### What gets installed

| File | Role |
|---|---|
| `~/.local/bin/magictrackpointd` | the helper itself |
| `~/.local/bin/magictrackpointctl` | the control command (status, reload, …) |
| `~/Library/LaunchAgents/com.jcbaptiste.magictrackpoint.plist` | tells macOS to start the helper when you log in |
| `~/.config/magictrackpoint/config.plist` | your settings (created once, never overwritten) |

Tip: to type `magictrackpointctl` without its full path, add this line to
`~/.zshrc`, then open a new Terminal window:

```bash
export PATH="$PATH:$HOME/.local/bin"
```

The rest of this guide assumes you did. Otherwise, type
`~/.local/bin/magictrackpointctl` instead of `magictrackpointctl`.

---

## 3. Grant the two permissions

macOS protects keyboards and mice: no program may read them or act on them
without your consent. MagicTrackpoint needs two permissions, both in
*System Settings → Privacy & Security*:

| Permission | Why it is needed |
|---|---|
| **Input Monitoring** | to read the middle button, the scroll movements and the three special keys from the keyboard, and to send it the sensitivity |
| **Accessibility** | to produce the scrolling and the middle click, to hold back the keyboard's own middle click while you scroll, and for the Bluetooth and Print Screen keys (they open Control Center and send ⇧⌘5) |

Neither is optional: without the first, the keyboard cannot be read at all;
without the second, nothing can be scrolled or clicked. (Reasoning and proof in
[docs/architecture.md §6](docs/architecture.md), in French.)

If you installed from the disk image and clicked **Continue** until *All
permissions granted*, this is already done. Otherwise, or to check again
later, use the command below (the disk image's installer runs it for you).

**The easy way.** Run:

```bash
magictrackpointctl permissions
```

It restarts the helper so that it asks macOS again, then opens System Settings
on the first missing permission. Turn on **magictrackpointd** in that list.
Run the same command again for the second one. You are done when it prints:

```
All permissions granted.
```

Why run it again instead of just waiting? macOS applies *Input Monitoring*
only when the program restarts, and this command does that for you.
*Accessibility* is picked up within 5 seconds.

**If magictrackpointd is not in the list:** click **+**, press
`Cmd+Shift+G`, type `~/.local/bin/magictrackpointd`, press Return, then
**Open**.

---

## 4. Check that it works

```bash
magictrackpointctl status
```

You should see, among other lines:

```
state=running
input_monitoring=granted
accessibility=granted
hid=open
event_taps=ready
devices=1
device.0=bluetooth sensitivity:applied preferred_scrolling:applied
```

Then try it:

1. Hold the middle button and push the TrackPoint up and down: the page
   scrolls and the cursor does not move.
2. Push gently, then harder: it scrolls faster.
3. Click a link with a short middle press: it opens in a new tab.
4. Scroll with the middle button, release it over a link: no tab opens.

`devices=0`? The keyboard is off, asleep or connected to another computer:
press a key, then check again.

---

## 5. Everyday use

Nothing to do: the helper starts when you log in, follows the keyboard when it
connects, disconnects or wakes up, and uses no CPU while you are not touching
the keyboard: it waits for events. Its only timer runs while a permission is
missing (a check every 5 seconds) and stops once both are granted.

The control command:

| Command | What it does |
|---|---|
| `magictrackpointctl status` | Is it running? Permissions, connected keyboards, current settings |
| `magictrackpointctl permissions` | Ask for the permissions again and open the right settings page |
| `magictrackpointctl reload` | Apply a changed settings file, without restarting |
| `magictrackpointctl restart` | Restart the helper |
| `magictrackpointctl stop` | Stop it until your next login (or `start`) |
| `magictrackpointctl start` | Start it again |
| `magictrackpointctl log` | Watch its messages live (`Ctrl+C` to quit) |
| `magictrackpointctl check` | Check the settings file for mistakes |

---

## 6. Settings

The settings live in `~/.config/magictrackpoint/config.plist`. Every setting
is optional: a missing one takes its default value. The file is a standard
macOS property list; [config/config.example.plist](config/config.example.plist)
shows every key with its explanation.

| Setting | Values | Default | What it changes |
|---|---|---|---|
| `trackpoint.sensitivity` | 1 to 9 | `7` | Cursor speed of the TrackPoint, set in the keyboard itself |
| `scroll.enabled` | `true` / `false` | `true` | Middle button + TrackPoint scrolls. `false` gives the keyboard back its own behaviour |
| `scroll.speed` | 0.1 to 10 | `1.0` | Overall scroll speed multiplier |
| `scroll.acceleration` | 0 to 2 | `1.0` | How much harder pushes scroll faster. `0` = constant speed |
| `scroll.horizontal` | `true` / `false` | `true` | Allow left/right scrolling |
| `scroll.threshold` | 0 to 50 | `3` | How much movement turns a middle press into a scroll (see below) |
| `middle_button.click_if_no_scroll` | `true` / `false` | `true` | Send a middle click when you press without scrolling |
| `keys.microphone` | `true` / `false` | `true` | F4 mutes or unmutes the default microphone |
| `keys.bluetooth` | `true` / `false` | `true` | F10 opens Control Center on Bluetooth (falls back to *System Settings → Bluetooth*) |
| `keys.screenshot` | `true` / `false` | `true` | Print Screen sends ⇧⌘5 |
| `logging.level` | `error`, `info`, `debug` | `error` | How much the helper writes to the system log |

### Changing a setting

The simplest way is the `plutil` command that comes with macOS. Example,
scroll 50% faster:

```bash
plutil -replace scroll.speed -float 1.5 ~/.config/magictrackpoint/config.plist
```

```bash
magictrackpointctl check
```

```bash
magictrackpointctl reload
```

The type must match the setting: `-integer` for sensitivity and threshold,
`-float` for speed and acceleration, `-bool` for true/false settings,
`-string` for the log level. You can also edit the file in any text editor.

If a value is wrong (say, sensitivity 12), `check` and `status` tell you, the
helper uses the default for that one setting and applies the others.

### How the middle button decides: click or scroll

While you hold the middle button, the keyboard itself turns the TrackPoint
movement into small scroll steps. MagicTrackpoint adds up those steps from the
moment you press:

- if the total stays **below the threshold** until you release, you get a
  **middle click** and nothing scrolls;
- as soon as it **reaches the threshold**, scrolling starts, and releasing the
  button will **not** click.

So the click is only sent on release, once it is certain you did not scroll.
Raise the threshold if a slight unintended push sometimes scrolls instead of
clicking; lower it if scrolling feels slow to start. Measured on the
keyboard: a plain click moves 0 steps, the smallest real scroll about 10, so
the default of 3 leaves room on both sides.

One consequence: with the TrackPoint's middle button you can no longer
*hold* a middle click or drag with it (used by some 3D or CAD programs). An
external mouse is not affected. `scroll.enabled = false` restores the
keyboard's native middle button.

### How acceleration works

The keyboard measures how hard you push: about 70 times per second it reports
1 step for a gentle push, up to 3 or 4 for a hard one. Each report scrolls
`steps^(1 + acceleration) × 10 pixels × speed`:

| Push | `acceleration = 0` | `1` (default) | `2` |
|---|---|---|---|
| gentle (1 step) | 10 px | 10 px | 10 px |
| medium (2 steps) | 20 px | 40 px | 80 px |
| hard (3 steps) | 30 px | 90 px | 270 px |

Gentle pushes always stay precise; only harder pushes speed up. Speed depends
on pressure only, never on timing, so it feels the same on a busy or an idle
Mac.

The scroll direction follows your macOS *Natural scrolling* setting, like the
trackpad.

---

## 7. Troubleshooting

| What you see | What to do |
|---|---|
| Nothing happens at all | `magictrackpointctl status`. Look for `MISSING` and fix that line first. |
| `input_monitoring=MISSING` or `accessibility=MISSING` | `magictrackpointctl permissions`, as many times as it asks. |
| `MISSING` although the switch is on | The program was rebuilt with an ad hoc signature: in System Settings, select magictrackpointd, click **−**, then run `magictrackpointctl permissions`. |
| `scroll=configured, inactive` | Accessibility is missing. Until it is granted, the keyboard is left in its normal mode on purpose. |
| `devices=0` | The keyboard is off, asleep, or connected elsewhere. Press a key. |
| `sensitivity:FAILED` | The keyboard refused the command: turn it off and on again. |
| A middle click sometimes comes with a scroll, or a scroll clicks | Adjust `scroll.threshold`. |
| Too slow, too fast | `scroll.speed`, then `scroll.acceleration`. |
| Something else odd | Set `logging.level` to `debug`, `magictrackpointctl reload`, then `magictrackpointctl log` and reproduce. Each gesture is summarized (movement, scroll, click). The log never contains what you type. Set the level back to `error` afterwards. |

Resource use, if you are curious:

```bash
ps -o pid,%cpu,rss,command -p "$(pgrep -x magictrackpointd)"
```

Observed on a MacBook Pro M4 over 20 seconds: 0.0–0.1% CPU with the keyboard
connected and idle. Longer measurements (memory over an hour, after many
reconnections) are not done yet.

---

## 8. Uninstall

From the disk image: double-click **Uninstall MagicTrackpoint**.
From the source folder:

```bash
make uninstall
```

This stops the helper, puts the keyboard back in its native mode, and removes
the program, the control command and the login item. Your settings file is
kept; to delete it too:

```bash
bash scripts/uninstall.sh --purge
```

The two permissions stay listed in System Settings until you remove them:
select magictrackpointd and click **−** (the uninstaller also prints the
`tccutil` commands that do it).

---

## 9. How it works

```
 TrackPoint Keyboard II ──Bluetooth/USB──▶ macOS
        ▲   │ middle button, scroll steps                     │
        │   ▼                                                 ▼
  sensitivity  magictrackpointd ── scroll + click events ──▶ your apps
  (HID command)   (one small process, started at login by launchd)
```

- **The keyboard does the hard part.** In its "preferred scrolling" mode, the
  firmware itself turns stick movement into scroll steps while the middle
  button is held, so the cursor stays put. MagicTrackpoint switches that mode
  on, turns the steps into smooth, pixel-precise scrolling, and switches the
  mode off again when it stops.
- **Event-driven.** It reacts to the keyboard's messages, to connections and
  to wake-ups. No periodic timer runs once the permissions are granted.
- **Careful with other devices.** It only filters the middle button and the
  wheel, and only *during* a TrackPoint gesture (plus at most 250 ms after it,
  for the keyboard's own last wheel events); trackpad scrolling is never
  touched.
- **Only public, documented Apple APIs** (IOKit HID, Quartz event taps). No
  kernel extension, no system extension, never root.

The detailed design, the decisions and their reasons, and the hardware test
results are in [docs/architecture.md](docs/architecture.md) (in French).

---

## 10. Privacy and security

- **No network access, no telemetry, no update checks, no data collection.**
- **Never runs as administrator (root)**: it refuses to.
- **Keystrokes are never recorded.** On Bluetooth, the keyboard's typing
  reports reach the helper because they share one connection with the
  TrackPoint; they are discarded on their first byte, never copied, stored or
  logged. When scrolling is disabled, the helper does not even receive them.
  The three special keys are delivered to it on their own, by macOS, never
  together with typing.
- **Never turns Bluetooth off.** The Bluetooth key only ever opens or closes
  the device list; it never uses the switch that would disconnect the
  keyboard. It starts no program and the microphone key reads no sound: it
  only changes the microphone's mute setting.
- **Minimal logging**: errors only by default, kept on your Mac by the system
  log, never anything you type.
- **Exactly two permissions**, both justified above.
- **Signed and notarized releases**; the disk-image installer refuses a
  program that is not signed with the MagicTrackpoint release team's
  Developer ID certificate, or that was modified after signing.
- **Fails closed**: if the settings file cannot be read, scrolling (the only
  feature that needs keyboard reports) stays off.

Found a security problem? Please report it privately, as explained in
[SECURITY.md](SECURITY.md), not in a public issue. It also explains how to
verify a release.

---

## 11. Known limitations

- The USB receiver has not been tested by us.
- Not yet verified on the keyboard: sensitivity levels 1 and 9, reconnection,
  wake from sleep, long-run memory use. The manual test plan and its dated
  results are in [docs/tests-manuels.md](docs/tests-manuels.md).
- While the TrackPoint's middle button is held, the middle button and the
  wheel of an external mouse used *at the same moment* are ignored (macOS does
  not tell which device sent an event).
- One TrackPoint keyboard at a time: with two connected, a gesture on one also
  holds back the other's wheel and middle click.
- If you revoke *Input Monitoring* while the helper runs, it does not notice:
  run `magictrackpointctl restart`. If you revoke *Accessibility*, it notices at
  the next middle-button press and puts the keyboard back in its native mode.
- If the helper crashes, macOS restarts it within 30 seconds; in between, a
  middle click may follow a scroll.
- The Bluetooth key relies on how Control Center is built (checked on macOS
  27). If a macOS update changes it, the key opens *System Settings →
  Bluetooth* instead.
- The microphone key needs a microphone with a mute control (the Mac's own
  has one). macOS shows nothing on screen: the sound and
  `magictrackpointctl status` (`microphone=muted`) tell you the state.
- The special keys were measured on the Bluetooth keyboard; on the USB
  receiver they are untested.

---

## 12. For developers

```bash
make help
```

| Path | Content |
|---|---|
| `src/mtp_core.h` | pure logic: configuration, HID report decoding, click/scroll state machine, acceleration, event filtering decisions |
| `src/magictrackpointd.m` | system side: IOKit HID, event taps, launchd, sleep/wake, signals |
| `tools/magictrackpointctl` | control command (shell) |
| `scripts/` | install, uninstall, disk image build |
| `tests/` | unit tests (with sanitizers), build checks, install/uninstall tests in a sandbox |
| `docs/` | design notes, manual hardware test plan, code audits (French) |

`make test` runs the automated tests: unit tests of the pure logic (about
260,000 checks, most of them from exhaustive sweeps of values), build checks,
and install/uninstall tests in a sandbox. The system side of the helper (HID,
event taps, sleep) is only tested by hand: see
[docs/tests-manuels.md](docs/tests-manuels.md), with dated results.

Code reviews: [docs/audits/](docs/audits/) (three independent audits of 1.0.0
and their consolidated summary, in French).

**Release.** `make release` builds the disk image, signs it with your
Developer ID Application certificate, has Apple notarize it and staples the
ticket. Once, store your notary credentials in the keychain (it asks for an
[app-specific password](https://support.apple.com/102654)):

```bash
xcrun notarytool store-credentials magictrackpoint --apple-id <your Apple ID> --team-id <your Team ID>
```

---

## 13. Credits and license

Copyright (C) 2026 Jean-Christophe Baptiste.

MagicTrackpoint is free software: you can redistribute it and/or modify it
under the terms of the **GNU General Public License, version 3 or (at your
option) any later version**. It comes without any warranty. The full text is
in [LICENSE](LICENSE).

Thanks to hoyaaaa, whose
[trackpoint-daemon-macos](https://github.com/hoyaaaa/trackpoint-daemon-macos)
first documented how this keyboard talks over HID (device IDs, report formats,
configuration commands). MagicTrackpoint contains none of its code.
