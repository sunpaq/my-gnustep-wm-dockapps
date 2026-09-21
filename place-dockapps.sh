#!/bin/sh
#
# place-dockapps.sh - pin the dockapp appicons onto the top-left icon yard
# of the head that contains screen coordinate (0,0).
#
# Why this exists
# ---------------
# The six dockapps (battery_dockapp, powerdock, backlight/mixer/clock_dockapp,
# wifirescue_dock) are un-docked WindowMaker appicons.  WindowMaker decides
# which display's icon yard an appicon lands in from the position of the
# app's window at the time the appicon is (re)created, and that placement
# is self-reinforcing across WM restarts.  Because the dockapps are
# launched at login *before* the final RandR layout is known (the external
# HDMI monitor can take ~20 s to appear), battery_dockapp (formerly
# wmbsdbatt) and wifirescue_dock ended up stranded in the builtin panel's
# icon yard (top-left of the bottom display) instead of the external
# display's top-left.
#
# Moving the appicon windows with XMoveWindow sticks (verified), and once
# an appicon sits on the correct display it stays there across WM
# restarts - so re-enforcing the canonical slots after every layout change
# and at WM startup is enough.
#
# Canonical slots (head at (0,0); slot 0,0 left free for the Clip):
#   64,0   battery_dockapp     (battery)
#   128,0  powerdock           (power menu)
#   192,0  wifirescue_dock      (wifi)
#   256,0  backlight_dockapp   (brightness)
#   320,0  mixer_dockapp       (volume)
#   384,0  clock_dockapp       (clock)
#
# Appicon window structure (from xwininfo -root -tree):
#  - battery/powerdock/backlight/mixer/clock: the appicon IS the app's own
#    64x64 window (root child) -> move the window itself.
#  - wifirescue_dock: the app has a separate hidden 5x5 main window; WM wraps
#    the icon window in its own 64x64 appicon frame -> move the parent frame.
#    The 5x5 main windows are skipped via the size filter in each slot entry.
#
# In single-display mode the head at (0,0) is the builtin panel, which is
# the sensible top-left for that layout, so the same slots apply.
#
# Called from: ~/GNUstep/Library/WindowMaker/autostart (after the dockapps
# are launched) and ~/bin/display-hotplug.sh (after every layout change).
#

XMOVE="$HOME/bin/xmove"
[ -x "$XMOVE" ] || XMOVE=/usr/local/bin/xmove
[ -x "$XMOVE" ] || exit 0
command -v xwininfo >/dev/null 2>&1 || exit 0

# slot table: "appicon-name:size-filter:target-x:target-y", space separated
SLOTS='battery_dockapp:64x64:64:0 PowerDock:64x64:128:0 wifirescue_dock:64x64:192:0 backlight_dockapp:64x64:256:0 mixer_dockapp:64x64:320:0 clock_dockapp:64x64:384:0'

# Scan a `xwininfo -root -tree` dump.  For each dockapp whose appicon is
# not at its canonical x AND y, print:
#   <window-id-to-move> <tx> <ty> <name>
scan_tree() {
    printf '%s\n' "$1" | awk -v slots="$SLOTS" '
    function sign(c) { return (c == "-") ? -1 : 1 }
    {
        n = match($0, /[^ ]/)
        indent = (n == 0) ? 999 : n - 1
        # last field is the absolute position, e.g. "+64+0" or "-5+30"
        absx = -1; absy = -1
        p = $NF
        if (p ~ /^[+-][0-9]+[+-][0-9]+$/) {
            s1 = sign(substr(p, 1, 1))
            rest = substr(p, 2)
            if (match(rest, /[+-]/)) {
                absx = s1 * (substr(rest, 1, RSTART - 1) + 0)
                absy = sign(substr(rest, RSTART, 1)) * (substr(rest, RSTART + 1) + 0)
            }
        }
        if (indent == 5) { parent_id = $1; parent_absx = absx; parent_absy = absy }
        nslots = split(slots, S, " ")
        for (i = 1; i <= nslots; i++) {
            split(S[i], F, ":")
            if (index($0, "\"" F[1] "\"") > 0 && index($0, F[2]) > 0 &&
                index($0, "5x5") == 0 && !seen[F[1]]) {
                seen[F[1]] = 1
                if (indent == 5) { x = absx; y = absy }
                else             { x = parent_absx; y = parent_absy }
                if (x != F[3] + 0 || y != F[4] + 0)
                    print parent_id, F[3], F[4], F[1]
            }
        }
    }'
}

# A pass is settled when no running dockapp is off its slot.
settled() {
    tree=$(xwininfo -root -tree 2>/dev/null)
    [ -n "$tree" ] && scan_tree "$tree" | grep -q . && return 1
    return 0
}

attempt=0
max=24    # ~12 s worst case: covers WM (re)start races (appicons appear async)
while :; do
    tree=$(xwininfo -root -tree 2>/dev/null)
    [ -n "$tree" ] || { sleep 0.5; continue; }
    moves=$(scan_tree "$tree")
    if [ -z "$moves" ]; then
        break
    fi
    printf '%s\n' "$moves" | while read -r wid tx ty name; do
        if "$XMOVE" "$wid" "$tx" "$ty" 2>/dev/null; then
            echo "place-dockapps: moved $name appicon ($wid) to $tx,$ty"
        fi
    done
    attempt=$((attempt + 1))
    [ $attempt -ge $max ] && break
    sleep 0.5
done
exit 0