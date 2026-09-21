#!/bin/sh
# install-all.sh - batch install every dockapp binary into /usr/local/bin.
#
# Run as:  sudo ./install-all.sh        (after ./build-all.sh)
# Or:      PREFIX=/some/dir sudo -E ./install-all.sh   (non-default prefix)
#
# wifirescue_dock is installed setuid root (it needs root to run
# `service netif restart`); everything else is a plain 0755 root:wheel
# binary.  Retired hyphenated names (battery-dockapp etc.) are removed
# so nothing stale is left in the prefix.

set -e

PREFIX="${PREFIX:-/usr/local/bin}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run me as root:  sudo ./install-all.sh" >&2
    exit 1
fi

REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO"

# dir:binary:mode — dock layout order (see place-dockapps.sh)
APPS="
batterydock:battery_dockapp:755
powerdock:powerdock:755
wifirescue_dock:wifirescue_dock:4755
backlight_dock:backlight_dockapp:755
clockdock:clock_dockapp:755
mixerdock:mixer_dockapp:755
"

for entry in $APPS; do
    dir=${entry%%:*}
    rest=${entry#*:}
    bin=${rest%%:*}
    mode=${rest#*:}
    src="$dir/$bin"

    if [ ! -x "$src" ]; then
        echo "error: binary not found: $src (run ./build-all.sh first)" >&2
        exit 1
    fi

    install -o root -g wheel -m "$mode" "$src" "$PREFIX/$bin"
    echo "Installed: $PREFIX/$bin (mode $mode)"
done

# Retire the old hyphenated names for good.
rm -f "$PREFIX/battery-dockapp" "$PREFIX/backlight-dockapp" \
      "$PREFIX/clock-dockapp" "$PREFIX/mixer-dockapp" 2>/dev/null || true
echo "Removed retired hyphenated binaries (if any were present)."

echo "All dockapps installed into $PREFIX."