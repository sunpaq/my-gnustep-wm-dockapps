# AGENTS.md — my-gnustep-wm-dockapps

Guidance for coding agents working in this repository.

## Project overview

A collection of six 64×64 **Window Maker dockapps**. Five are written in
**Objective-C with the GNUstep Foundation framework + Xlib**, one
(`mixerdock/`) is plain C. They live in the icon yard of a Window Maker
desktop and are **FreeBSD-first** (ACPI sysctls, `backlight(8)`,
`mixer(8)`, `service netif`); only `powerdock` is dual-platform
(systemd/polkit on Linux).

| Directory | Binary | Language |
|-----------|--------|----------|
| `batterydock/` | `battery_dockapp` | Objective-C |
| `powerdock/`   | `powerdock`       | Objective-C |
| `wifirescue_dock/` | `wifirescue_dock` | Objective-C (multi-file: `main.m`, `DockView`, `WiFiController`) |
| `backlight_dock/` | `backlight_dockapp` | Objective-C |
| `clockdock/`   | `clock_dockapp`   | Objective-C |
| `mixerdock/`   | `mixer_dockapp`   | plain C (no GNUstep) |

## Language & framework policy (important)

- **Always write new code in Objective-C using the GNUstep Foundation
  framework.** Do not rewrite dockapps in Swift, C++, or shell. Plain C
  is only acceptable for a tiny, Xlib-only utility like `mixerdock`, and
  only if there is a strong reason.
- Use GNUstep Foundation types (`NSString`, `NSArray`, `NSDictionary`,
  `NSTimer`, …) instead of C++/GLib/other framework equivalents. C
  stdlib (`stdio`, `stdlib`, `string`, `sysctl`, `select`) and POSIX
  calls are fine for the system-facing parts (reading sysctls, running
  commands, talking to X11).
- Use `#import` (not `#include`) for Objective-C and C headers, matching
  existing files.
- Manual reference counting: `[[NSAutoreleasePool alloc] init]` in
  `main()`, `autorelease` where appropriate. No ARC — the Makefiles do
  not enable it and libobjc2/GNUstep-base setup here is MRC.
- Prefer `NSLog(@"...")` for diagnostics, never bare `printf` in
  Objective-C code.
- String formatting with Foundation types: use `%@`, and box scalars
  when interpolating (e.g. `[NSString stringWithFormat:@"%ld", (long)v]`).

## Architecture conventions (shared "DockApp" design)

All Objective-C dockapps follow the same pattern (pioneered in
`powerdock`). Keep new dockapps consistent with it:

- 64×64 window registered as a dockapp: `WithdrawnState` +
  `icon_window` via `XChangeProperty` — the classic Window Maker
  handshake. Do not use other toolkits (no GTK, no NSApplication GUI).
- Rendering is **double-buffered**: draw into an offscreen `Pixmap`,
  then blit to the window in one operation. Never draw directly to the
  visible window (it flickers).
- Event loop is a `select()` on the X connection fd with a **computed
  timeout** for periodic refresh. **No busy polling**, no `sleep()` in
  the render path, no threads for the UI.
- Colors are defined as `#define COL_*` hex string constants at the top
  of the file, resolved with `XParseColor`; keep the shared palette
  (`#202028` bg, `#3ddc5a` green, `#9a9aa5` gray, `#ff4d4d` red) when
  it fits.
- Mouse handling: left/right click typically step a value down/up,
  middle click re-reads or toggles; destructive or multi-step actions
  use a chooser/confirm-arming pattern (see `powerdock`).
- One self-contained directory per dockapp: `Name.m` (+ `.h` when
  split), a standalone `Makefile`, and an `install*.sh` script.
- **Dockapp binary names must be pure ASCII and must not contain
  hyphens (`-`); use underscores** (`clock_dockapp`, never
  `clock-dockapp`). Window Maker's proplist parser cannot read
  unquoted hyphenated values in `WMState`, so hyphenated names
  silently break hand-maintained dock configs — wmaker fails to parse
  the file, starts with an empty dock, and overwrites it on exit.

## Building

Requirements: `clang`, `gnustep-base`, `libobjc2`, X11 dev headers,
`gmake`. On FreeBSD: `pkg install gnustep-base libobjc2 libX11 gmake`.

- Each directory is **self-contained**. Build from inside it:
  `cd batterydock && gmake` (and likewise for the others).
- Batch helpers at the repo root: `./build-all.sh` builds all six
  dockapps (no root needed); `sudo ./install-all.sh` installs all six
  into `/usr/local/bin` — `wifirescue_dock` setuid root, the rest 0755
  root:wheel. Dockapp binaries live in `/usr/local/bin` **only**; the
  Window Maker `autostart` launches them from there and there is no
  per-user copy in `~/bin`.
- Makefiles pull Objective-C flags from `gnustep-config --objc-flags`
  and `--base-libs` (sourcing `GNUstep.sh` first) and X11 flags from
  `pkg-config x11`. **Do not hard-code GNUstep include/lib paths** and
  do not require the user to source `GNUstep.sh` themselves.
- `mixerdock/` is the exception: `cc -O2 -o mixer_dockapp
  mixer_dockapp.c -lX11` — no GNUstep.
- Test build with `gmake -C <dir>` after any change. There is no test
  suite; verify by compiling cleanly (no new warnings) and, when
  possible, running the binary (`./<binary> &`, then dock it by
  middle-mouse-dragging the appicon).

## Platform notes

- Target platform is **FreeBSD** first: `sysctlbyname()` for ACPI
  battery data, `backlight(8)`, `mixer(8)`, `ifconfig` / `service
  netif`. Read kernel state via sysctls directly where possible (see
  `batterydock`) rather than `popen()`-ing tools.
- `powerdock` auto-detects the platform: `systemctl` on Linux, `zzz` /
  `shutdown` on FreeBSD, with a sudo/doas wrapper where privileges are
  needed.
- `wifirescue_dock` needs root for `service netif restart`; its
  `install.sh` sets the binary setuid root. Be careful and explicit
  when touching privilege-related code.
- FreeBSD-isms are expected in code (`#include <sys/sysctl.h>`, etc.).
  Keep Linux compatibility only where it already exists (`powerdock`).

## Housekeeping

- Repo-root helpers: `place-dockapps.sh` pins appicons to canonical
  slots in the icon yard; it is called from the Window Maker
  `autostart` file and display-hotplug hooks. Don't change the slot
  layout (64·n,0) without updating the README.
- Every dockapp directory may have its own `README.md` — keep it in
  sync when behavior changes.
- License is BSD 3-Clause; new files should carry a short header
  comment like the existing `*.m` files (purpose, data sources, build
  & run instructions).
- Don't commit build artifacts (`.o`, `.d`, binaries) for new work;
  some are currently tracked, but avoid adding more.