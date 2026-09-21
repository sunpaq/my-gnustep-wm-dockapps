# my-gnustep-wm-dockapps

A collection of six 64×64 **Window Maker dockapps** — five written in
Objective-C with GNUstep Foundation + Xlib, one in plain C — that live
together in the top-left icon yard of my desktop.

Licensed under the [BSD 3-Clause License](LICENSE).

![Dockapps running in the top-left of the external display](screenshots/dockapps.png)

Left to right: Workspace clip, **battery**, **power**, **wifi-rescue**,
**backlight**, **mixer**, **clock**.

## The dockapps

| Directory | Dockapp | Language | What it does |
|-----------|---------|----------|--------------|
| `batterydock/` | `battery_dockapp` | Objective-C | Battery charge %, lightning bolt on AC, red alert below 15 % while discharging. Reads ACPI sysctls directly. |
| `powerdock/` | `powerdock` | Objective-C | Sleep / shutdown / reboot with a chooser popup and click-to-confirm arming. Auto-selects `systemctl`, `zzz`/`shutdown`, and a sudo/doas wrapper. ([docs](powerdock/README.md)) |
| `wifirescue_dock/` | `wifirescue_dock` | Objective-C | Wi-Fi status tile (SSID / `RST` / `DOWN`); right-click runs `service netif restart <if>`. ([docs](wifirescue_dock/README.md)) |
| `backlight_dock/` | `backlight_dockapp` | Objective-C | Screen brightness %; left/right click step down/up 10 %, middle click re-reads. Uses `backlight(8)`. |
| `mixerdock/` | `mixerdock` | C | Volume % with speaker symbol and level bar; left/right click step down/up 10 %, middle click toggles mute. Uses `mixer(8)`. |
| `clockdock/` | `clock_dockapp` | Objective-C | Weekday + HH:MM in hand-drawn 7-segment digits, seconds below; left click toggles 12 h/24 h. |

All of the Objective-C apps share the same design (pioneered in
`powerdock`): the 64×64 window registers itself with `WithdrawnState` +
`icon_window` (the classic dockapp handshake), rendering is double
buffered into an offscreen pixmap, and the event loop is a `select()` on
the X connection with computed timeouts — no busy polling, no flicker.

## Building

Requirements: `clang`, GNUstep base (`gnustep-base`), `libobjc2`, X11
dev headers and `gmake`. On FreeBSD:

```
pkg install gnustep-base libobjc2 libX11 gmake
```

Each directory is self-contained; the Makefiles pull the right flags
from `gnustep-config` and pkg-config, so no `GNUstep.sh` sourcing is
needed:

```
cd batterydock && gmake     # likewise for the others
./battery_dockapp &         # then middle-mouse-drag the appicon onto the Dock
```

Or batch-build everything and install it all into `/usr/local/bin`:

```
./build-all.sh              # builds all six dockapps (no root needed)
sudo ./install-all.sh       # installs all six into /usr/local/bin
                             # (wifirescue_dock setuid root, the rest 0755)
```

## Binary naming rule

Dockapp binary names must be **pure ASCII** and must **not contain
hyphens (`-`)** — use underscores instead (`clock_dockapp`, never
`clock-dockapp`). Window Maker stores dock/clip state in `WMState`
using its proplist format, whose parser cannot read unquoted
hyphenated values: a hand-maintained config containing `clock-dockapp`
silently fails to parse, wmaker then starts with an empty dock and
overwrites the file on exit. Underscore names are safe in every config,
hand-written or machine-written.

`mixerdock` is plain C and even builds without GNUstep:

```
cd mixerdock && cc -O2 -o mixer_dockapp mixer_dockapp.c -lX11
```

Most directories also ship an `install-*.sh` / `install.sh` script that
installs the binary (and, for `wifirescue_dock`, sets it setuid root).

## Autostart & placement

- Add the dockapps to `~/GNUstep/Library/WindowMaker/autostart` to
  launch them with your session; Window Maker remembers docked tiles
  across restarts.
- **`place-dockapps.sh`** (repo root) pins every appicon to a canonical
  slot in the icon yard of the head containing `(0,0)`:

  ```
  64,0 battery_dockapp   128,0 powerdock   192,0 wifirescue_dock
  256,0 backlight_dockapp  320,0 mixer_dockapp  384,0 clock_dockapp
  ```

  This exists because dockapps launched at login can end up in the wrong
  display's icon yard when the external monitor appears late (~20 s after
  RandR): Window Maker picks a yard from the position of the app's window
  when the appicon is (re)created, and that placement then sticks across
  WM restarts.

  How it works:

  - It runs after the dockapps are launched — from the Window Maker
    `autostart` file and, after every monitor hotplug/layout change,
    from a display-hotplug hook.
  - It scans `xwininfo -root -tree` for each dockapp's appicon window
    and compares its absolute position against the slot table above.
  - Any appicon that is off its slot is moved with `XMoveWindow` (via a
    small `xmove` helper). Once an appicon sits on the correct display,
    Window Maker keeps it there, so re-asserting the slots after every
    layout change is enough.
  - Because appicons appear asynchronously during a WM (re)start, the
    script re-scans in a retry loop (up to ~12 s) until every running
    dockapp has settled on its slot.
  - Most dockapps' appicon *is* the app's own 64×64 window, so the
    window itself is moved. `wifirescue_dock` is the exception: it owns
    a hidden 5×5 main window that Window Maker wraps in its own 64×64
    appicon frame — the script detects that (via the `5x5` size filter
    in the slot table) and moves the wrapping frame instead.
  - In single-display mode the head containing `(0,0)` is the builtin
    panel, which is the sensible top-left for that layout, so the same
    slots apply there too.

  If you change the slot layout, update this README and the `SLOTS=`
  table at the top of the script together.

## Platform notes

The battery, backlight, mixer and wifi dockapps read FreeBSD interfaces
(ACPI sysctls, `backlight(8)`, `mixer(8)`, `service netif`), so they are
FreeBSD-first. `powerdock` is dual-platform: on Linux/systemd it uses
`systemctl suspend|poweroff|reboot` directly via polkit, with no
privilege setup required.