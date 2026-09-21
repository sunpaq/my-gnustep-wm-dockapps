#!/bin/sh
# install.sh — build (if needed) and install powerdock into /usr/local/bin
#
# Usage:
#   ./install.sh               # build if missing, install, enable autostart
#   ./install.sh --force       # rebuild even if the binary already exists
#   ./install.sh --no-autostart  # skip the Window Maker autostart hook
#   PREFIX=/opt/bin ./install.sh   # install somewhere else

set -e

PREFIX="${PREFIX:-/usr/local/bin}"
BIN=powerdock
FORCE=0
AUTOSTART=1
for arg in "$@"; do
    case "$arg" in
        --force)        FORCE=1 ;;
        --no-autostart) AUTOSTART=0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")"

# Build only if the binary is missing/stale or --force was given
if [ ! -x "$BIN" ] || [ "PowerDock.m" -nt "$BIN" ] || [ "$FORCE" = 1 ]; then
    echo "==> Building $BIN ..."
    if command -v gmake >/dev/null 2>&1; then
        gmake clean >/dev/null 2>&1 || true
        gmake
    else
        make clean >/dev/null 2>&1 || true
        make
    fi
else
    echo "==> $BIN is up to date, skipping build"
fi

echo "==> Installing $BIN to $PREFIX ..."
if [ -w "$PREFIX" ] 2>/dev/null; then
    install -m 0755 "$BIN" "$PREFIX/$BIN"
else
    # Not writable as the current user — elevate with sudo or doas
    if command -v sudo >/dev/null 2>&1; then
        sudo install -m 0755 "$BIN" "$PREFIX/$BIN"
    elif command -v doas >/dev/null 2>&1; then
        doas install -m 0755 "$BIN" "$PREFIX/$BIN"
    else
        echo "error: $PREFIX is not writable and neither sudo nor doas is available." >&2
        exit 1
    fi
fi

# Hook into Window Maker's session autostart (idempotent)
if [ "$AUTOSTART" = 1 ]; then
    WMSTART="$HOME/GNUstep/Library/WindowMaker/autostart"
    echo "==> Configuring autostart ($WMSTART) ..."
    mkdir -p "$(dirname "$WMSTART")"
    if [ -f "$WMSTART" ] && grep -qs "powerdock" "$WMSTART"; then
        echo "    already present, skipping"
    elif [ -f "$WMSTART" ]; then
        printf '\n# PowerDock dockapp\n%s &\n' "$PREFIX/$BIN" >> "$WMSTART"
        chmod +x "$WMSTART"
        echo "    appended"
    else
        {   echo '#!/bin/sh'
            echo ''
            echo '# PowerDock dockapp'
            printf '%s &\n' "$PREFIX/$BIN"
        } > "$WMSTART"
        chmod +x "$WMSTART"
        echo "    created"
    fi
fi

echo "==> Done: $PREFIX/$BIN"
echo "    It will launch automatically the next time Window Maker starts."