# wifirescue_dock

A Window Maker dockapp (64x64), written in Objective-C, that shows the
current Wi-Fi connection status and can restart the network interface
on demand.

## What it does

**Status display** (probed every 5 s with `ifconfig <if>`):

| colour | text        | meaning |
|--------|-------------|---------|
| green  | `<ssid>`    | associated with a wireless network |
| yellow | `RST`       | `service netif restart` is running |
| red    | `DOWN`      | interface missing or not associated |
| gray   | `?`         | unknown (ifconfig failed) |

**Right-click on the dock icon** runs `service netif restart <if>`
where `<if>` is the detected wireless interface (auto-detected at
startup: the first interface whose ifconfig output contains
`groups: wlan`, e.g. `wlan0`; can be overridden as the first
command-line argument).

Left-click does nothing. There is no automatic rescue anymore.

## Usage

```
wifirescue_dock [wlan-iface]
```

Needs root privileges for `service netif restart`, so install it
setuid root:

```
sudo ./install.sh
```

Since it runs as root but talks to your X session, allow root to
connect by adding this to `~/GNUstep/Library/WindowMaker/autostart`:

```
xhost +SI:localuser:root
```

Build:  `gmake`