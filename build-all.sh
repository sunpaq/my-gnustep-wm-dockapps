#!/bin/sh
# build-all.sh - batch build every dockapp in this repository.
#
# Usage:
#   ./build-all.sh           build all six dockapps
#   ./build-all.sh clean     remove build artifacts first, then build
#
# No root required; each binary is produced next to its sources.
# Install them afterwards with:  sudo ./install-all.sh

set -e

REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO"

# Directories in dock layout order (see place-dockapps.sh)
DIRS="batterydock powerdock wifirescue_dock backlight_dock clockdock mixerdock"

if command -v gmake >/dev/null 2>&1; then
    MAKE=gmake
else
    MAKE=make
fi

CLEAN=0
case "${1:-}" in
    clean) CLEAN=1 ;;
    "")    ;;
    *) echo "usage: $0 [clean]" >&2; exit 1 ;;
esac

fail=0
for d in $DIRS; do
    echo "==> $d"
    if [ "$CLEAN" = 1 ]; then
        (cd "$d" && $MAKE clean >/dev/null 2>&1) || true
    fi
    if (cd "$d" && $MAKE); then
        :
    else
        echo "    FAILED: $d" >&2
        fail=1
    fi
done

echo
echo "==> Summary:"
for d in $DIRS; do
    bin=$(ls "$d" | grep -xE '(battery_dockapp|powerdock|wifirescue_dock|backlight_dockapp|clock_dockapp|mixer_dockapp)' | head -1)
    if [ -n "$bin" ] && [ -x "$d/$bin" ]; then
        echo "    OK      $d/$bin"
    else
        echo "    MISSING $d/?"
        fail=1
    fi
done

[ "$fail" = 0 ] && echo "All dockapps built." || echo "Some dockapps FAILED to build." >&2
exit $fail