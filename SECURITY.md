# Security policy

MagicTrackpoint runs in the background with two sensitive macOS permissions
(*Input Monitoring* and *Accessibility*). Security reports are welcome and
taken seriously.

## Supported versions

Only the latest release receives fixes. Update before reporting.

| Version | Supported |
|---|---|
| 1.0.x (latest release) | Yes |
| Older, or unreleased builds | No |

## Reporting a vulnerability

**Please do not open a public issue.** Report privately through GitHub:

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe:
   - the version (`magictrackpointctl status` shows it) and your macOS version;
   - what an attacker can do, and under which conditions (local user, another
     app, a modified file…);
   - the steps to reproduce, or a proof of concept.

What happens next:

- You get an acknowledgement, usually within a week. This is a one-person
  project, so please be patient.
- The issue is confirmed or explained, then fixed in a new release.
- The fix is published with a GitHub security advisory. You are credited,
  unless you prefer not to be.

Please give a reasonable time to fix the issue before disclosing it publicly.

## Scope

In scope:

- the helper (`magictrackpointd`) and the control command
  (`magictrackpointctl`);
- the install and uninstall scripts, and the disk image's installer apps;
- the release chain: signing, notarization, the installer's signature check.

Out of scope: macOS itself, the keyboard's firmware, third-party tools, and
attacks that require administrator rights or full control of the user's
account (such an attacker can already do more than this tool allows).

## What the tool promises

These are the security properties a report can show to be broken:

- **No network access**, no telemetry, no update checks, no data collection.
- **Never runs as root**; installs for the current user only, without an
  administrator password.
- **Keystrokes are never recorded**: keyboard reports are discarded on their
  first byte, never copied, stored or logged. With scrolling disabled, the
  helper does not receive them at all.
- **The three special keys** (F4, F10, Print Screen) reach the helper on
  their own, never with typing. F10 never uses Control Center's Bluetooth
  switch (it only opens or closes the device list); F4 reads no audio, it only
  changes the microphone's mute setting. No program is ever started.
- **Only the middle button and the wheel are filtered**, and only during a
  TrackPoint gesture (plus at most 250 ms after it). Trackpad scrolling is
  never touched.
- **Fails closed**: if the settings file cannot be read, scrolling, the only
  feature that needs keyboard reports, stays off.
- **Only public, documented Apple APIs**; no kernel or system extension.
- **The disk-image installer refuses** any helper that is not signed by the
  release team's Developer ID certificate, or that was modified after signing.

Known limitations that are documented choices, not vulnerabilities, are listed
in the [README](README.md#11-known-limitations).

## Verifying a release

Each release is signed with a Developer ID certificate (team `26N2RN6N67`),
notarized by Apple, and published with its SHA-256 checksum. Git commits and
tags are signed with an SSH key registered on the maintainer's GitHub account
(fingerprint `SHA256:WOf0wdC9u8pRnz0yN8ChPYUA6ttnKWN3SDJwpyD+rWA`); GitHub
shows them as *Verified*.

Check the download:

```bash
shasum -a 256 -c MagicTrackpoint-<version>.dmg.sha256
```

```bash
spctl --assess --type open --context context:primary-signature -v MagicTrackpoint-<version>.dmg
```

The second command must print `source=Notarized Developer ID`.

Check the installed helper:

```bash
codesign -dv ~/.local/bin/magictrackpointd 2>&1 | grep -E 'Identifier|TeamIdentifier'
```

It must show `com.jcbaptiste.magictrackpoint` and `26N2RN6N67`.

Independent code audits: [docs/audits/](docs/audits/).
