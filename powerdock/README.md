# PowerDock

A Window Maker dock applet written in Objective-C (GNUstep Foundation + Xlib)
that controls system sleep, shutdown and reboot.

![usage](https://img.shields.io/badge/Window%20Maker-0.96-blue)

## Usage

| Input              | Action                                        |
|--------------------|-----------------------------------------------|
| **Left click**     | Open a chooser popup: **SLEEP** / **SHUT DOWN** |
| **Middle click**   | Reboot — click again within 5 s to confirm    |
| **Right click**    | Power off — click again within 5 s to confirm |

### The chooser popup

Left-clicking the tile pops up a small dialog **centered on the screen** with
two buttons, **SLEEP** (green) and **SHUT DOWN** (red) — the button under the
pointer is highlighted.  Clicking a button runs that action immediately.  The dialog
closes without doing anything if you:

- press **Escape**,
- click anywhere outside the buttons (the pointer and keyboard are grabbed
  while it is open, so stray clicks can't reach other windows), or
- let it sit for 10 seconds.

If a command exits with a failure (e.g. missing privileges), the tile
flashes an orange **ERR / FAILED** for 3 seconds and the reason is logged.

Destructive actions arm a blinking red **SURE?** tile showing the pending
action (`REBOOT` / `OFF`).  A second click on the same button confirms;
any other click, or waiting 5 seconds, disarms it.

## Build

Requirements: `clang`, GNUstep base (`gnustep-base`), `libobjc2`, X11 dev
headers, `gmake`.  On FreeBSD these come from:

```
pkg install gnustep-base libobjc2 libX11 gmake
```

```
gmake        # builds ./powerdock
gmake run    # build and launch
```

The Makefile is self-contained — it pulls the right flags from
`gnustep-config` and pkg-config, so no GNUstep.sh sourcing is needed.

## Docking it in Window Maker

The app registers its 64×64 window as the icon window in `WithdrawnState`
(the classic dockapp handshake), so:

1. Launch it: `./powerdock &`
2. Window Maker shows its icon; **middle-mouse-drag** the icon onto the Dock.
3. (Optional) right-click the docked tile → *Settings* to rename / set icon.

To have it start automatically with your session, add it to
`~/GNUstep/Library/WindowMaker/autostart`:

```sh
#!/bin/sh
$HOME/powerdock/powerdock &
```

(`chmod +x` the file.)  In the docked tile's Settings you can also enable
"Start when Window Maker is started".

## Permissions

On FreeBSD, `/sbin/shutdown` is not executable by ordinary users and `zzz`
needs root to suspend — running them bare fails with "Permission denied".
The app handles this itself: when it detects a non-root user without
systemd, it prefixes the commands with `sudo` (or `doas` if installed).
What remains is a one-time passwordless rule so `sudo` works unattended.

**sudo (recommended)** — run `sudo visudo` and add:

```
yuli ALL=(root) NOPASSWD: /usr/sbin/zzz, /sbin/shutdown
```

(The confirm-to-arm UI is the safety here; the destructive action only
fires after a deliberate second click.)

**Alternative — operator group for shutdown only:**

```
doas pw groupmod operator -m yuli     # as root
```

then set `POWERDOCK_PRIV=none` and keep `POWERDOCK_OFF="shutdown -p now"`
(`/sbin/shutdown` is setuid root and allows members of group `operator`).
Suspend would still need the sudoers rule above.

**Linux / systemd** — nothing to configure: logind's polkit rules let a
normal user run `systemctl suspend|poweroff|reboot` directly, and the app
detects this and skips the wrapper.

### Privilege wrapper control

`POWERDOCK_PRIV` selects the wrapper used for the commands:

| Value    | Behaviour                                                |
|----------|----------------------------------------------------------|
| `auto`   | default: none for root/systemd, else `sudo`, else `doas` |
| `sudo`   | force `sudo` prefix                                      |
| `doas`   | force `doas` prefix                                      |
| `none`   | run commands bare (you handle privileges yourself)       |

Example: `POWERDOCK_PRIV=none POWERDOCK_SLEEP="doas zzz" ./powerdock &`

## Command selection

At startup the app picks, in order:

1. `POWERDOCK_SLEEP` / `POWERDOCK_OFF` / `POWERDOCK_REBOOT` env vars, if set;
2. otherwise `systemctl suspend|reboot|poweroff` when `systemctl` exists (Linux);
3. otherwise the BSD commands: `zzz`, `shutdown -r now`, `shutdown -p now`.

The commands are then wrapped per `POWERDOCK_PRIV` (see Permissions).

## Files

- `PowerDock.m` — the whole app (~400 lines of ObjC + Xlib)
- `Makefile`    — build rules

## How it works

- The 64×64 window gets `WM_CLASS = Dock.powerdock`, fixed size hints, and
  `WMHints` with `icon_window`/`WithdrawnState` — that's what makes Window
  Maker swallow it into the Dock.
- Rendering is a 64×64 offscreen pixmap redrawn on Expose and on state
  changes, then `XCopyArea`'d onto the window (double-buffered, no flicker).
- The event loop is a `select()` on the X connection with a computed timeout
  while armed or while the chooser popup is open (4 Hz blink, 5 s disarm,
  10 s dialog auto-dismiss).
- The chooser popup is an override-redirect window (with save-under) drawn
  into its own offscreen pixmap like the tile; it grabs the pointer and
  keyboard while open so outside clicks become "cancel" events.
- Commands run through `NSTask` (`/bin/sh -c …`) so the UI never blocks —
  important for `zzz`, which stays alive until the machine resumes.