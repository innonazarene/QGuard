# QGuard

A tiny macOS menu-bar app that swallows ⌘Q and ⌘W so muscle memory can't kill your game.

Built because Dota 2 binds Q and W to item/ability slots, and a slightly early ⌘ press quits
the entire client mid-fight.

## What it does

Installs a `CGEventTap` at the session level and drops ⌘Q / ⌘W keystrokes before any app sees
them. By default it only does this while a protected app is frontmost, so ⌘Q and ⌘W keep
working normally everywhere else.

- **Only in my games** (default) — blocks only while a protected app is frontmost.
- **Everywhere** — blocks system-wide.
- **Off** — passes everything through.

Other details:

- ⌘Q and ⌘W can be toggled independently from the menu.
- `⌥⌘Q` and `⌃⌘Q` always pass through, so you keep an escape hatch.
- Protected apps default to Dota 2 (`com.valvesoftware.dota2`). Add any app via
  *Add frontmost app…*; matching falls back to the app's display name for Steam
  titles that report an odd bundle ID.
- Counts how many accidents it prevented, which gets funny after a week.
- Logs to `~/Library/Logs/QGuard.log`.

## Build

```bash
./build.sh                      # -> ~/Applications/QGuard.app
./build.sh /path/to/Output.app  # custom destination
```

Requires the Swift toolchain (Xcode or Command Line Tools). No Xcode project, no dependencies.
The app icon is generated from `makeicon.swift` at build time.

## Accessibility permission

An event tap needs Accessibility. After the first launch, enable **QGuard** in
System Settings → Privacy & Security → Accessibility. QGuard polls every 1.5s and arms itself
without a relaunch; macOS can take a minute or two to propagate the grant.

Confirm it actually armed:

```bash
grep TAP ~/Library/Logs/QGuard.log
# [...] TAP INSTALLED ok (trusted=true)
```

If that line says `trusted=false`, the tap is not installed and QGuard is doing nothing,
regardless of what the toggle in System Settings shows.

### The stale-grant trap

The app is ad-hoc signed, so its Accessibility grant is bound to the exact binary hash.
Rebuilding invalidates the grant **while the toggle still appears enabled** — a silent
no-op that is miserable to debug. `build.sh` therefore runs
`tccutil reset Accessibility com.tom.qguard` on every build, so you get an honest "off"
to re-enable instead of a switch that lies. Disable with `QGUARD_RESET_TCC=0 ./build.sh`.

A self-signed certificate can make the grant survive rebuilds, but only if its root is
trusted **system-wide**. Trusting it in the login keychain alone satisfies `codesign`
while TCC still refuses the grant. Opt in with `QGUARD_IDENTITY="Your Identity" ./build.sh`.

## Autostart

Menu → *Open Login Items settings* → `+` → add QGuard.

## Caveat

An event tap cannot intercept apps that read the keyboard through raw HID. Confirmed
working with Dota 2; a game that bypasses the Cocoa event queue would need a lower-level
virtual HID driver instead.

## License

MIT
