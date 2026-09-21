/*
 * WiFiRescue.h - Shared declarations for the WMWiFiRescue dockapp.
 *
 * This is now a pure Wi-Fi connection status display:
 *   - periodically probes the wireless interface with ifconfig(8)
 *   - right-click on the dock icon runs `service netif restart <if>`
 *
 * The wireless interface is auto-detected at startup (the first
 * interface whose ifconfig output contains "groups: wlan", i.e. a
 * wlan(4) vap).
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(int, WifiStatus) {
    WifiUnknown    = 0,   /* cannot tell (e.g. ifconfig failed) */
    WifiDown       = 1,   /* interface missing or not associated */
    WifiAssociated = 2,   /* associated (link OK) */
    WifiRestarting = 3    /* `service netif restart` is running */
};

@class DockView;

@interface WiFiController : NSObject {
    NSString  *_wlanIf;
    NSLock    *_stateLock;
    WifiStatus _status;
    NSString  *_lastIP;
    NSString  *_lastSSID;
    BOOL       _restarting;
time_t     _restartStart;
}

@property (readonly) NSString *wlanIf;

/* Return the first wireless interface found (wlan(4) vap), e.g.
 * "wlan0". Returns nil if none is present. */
+ (NSString *)detectWlanInterface;

- (instancetype)initWithWlanInterface:(NSString *)wlan;

/* Probe current state with ifconfig(8); updates internal status and
 * returns it. Also captures the IPv4 address and SSID if any. */
- (WifiStatus)probeStatus;

/* Current (possibly cached) status. */
- (WifiStatus)status;

/* Cached IPv4 address or nil. */
- (NSString *)lastIP;

/* Cached SSID or nil. */
- (NSString *)lastSSID;

/* Mark the controller as "restarting" (icon shows RST). Must be
 * called before finishNetifRestart. */
- (void)beginNetifRestart;

/* Run `service netif restart <wlanIf>` synchronously and wait for
 * re-association (call from a background thread, after
 * beginNetifRestart). */
- (void)finishNetifRestart;

/* YES while a netif restart is in flight. */
- (BOOL)isRestarting;

/* Call periodically (from the heartbeat). If the restarting state
 * has been stuck for more than 120 s (e.g. a wedged restart thread),
 * force-clear it so the icon shows the real link state again. */
- (void)checkRestartTimeout;

@end