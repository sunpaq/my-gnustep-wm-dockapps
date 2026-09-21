#!/bin/sh
# install.sh - install backlight_dockapp into /usr/local/bin
# Run as:  sudo ./install_backlight_dockapp.sh

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run me as root:  sudo $(pwd)/install_backlight_dockapp.sh" >&2
    exit 1
fi

# Resolve the real user's home from the script's location
# ($HOME is /root under sudo, so we can't use it)
SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC="$SRC_DIR/backlight_dockapp"

if [ ! -x "$SRC" ]; then
    echo "error: binary not found: $SRC" >&2
    exit 1
fi

install -o root -g wheel -m 755 "$SRC" /usr/local/bin/backlight_dockapp
echo "Installed: /usr/local/bin/backlight_dockapp (from $SRC)"