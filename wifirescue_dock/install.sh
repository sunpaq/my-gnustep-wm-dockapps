#!/bin/sh
# install.sh - install wifirescue_dock as a setuid-root binary in
# /usr/local/bin so it can be launched from the Window Maker menu
# (where there is no terminal to type a sudo password into).
#
# Run as:  sudo ./install.sh

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run me as root:  sudo ./install.sh" >&2
    exit 1
fi

install -o root -g wheel -m 4755 ./wifirescue_dock /usr/local/bin/wifirescue_dock
echo "Installed: /usr/local/bin/wifirescue_dock (setuid root)"

# NOTE: the binary talks to the X server of your user session. Since
# it runs as root, root must be allowed to connect. Add this to
# ~/GNUstep/Library/WindowMaker/autostart (runs when Window Maker
# starts):
#   xhost +SI:localuser:root
echo "Remember to add 'xhost +SI:localuser:root' to your Window Maker"
echo "autostart so the root-owned dockapp can reach your X display."