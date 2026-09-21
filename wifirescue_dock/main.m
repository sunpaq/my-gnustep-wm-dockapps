/*
 * main.m - wifirescue_dock: a Window Maker dockapp that displays the
 * Wi-Fi connection status.
 *
 *   - green: associated (shows the SSID)
 *   - red:   not associated
 *   - right-click on the dock icon runs `service netif restart <if>`
 *
 * The wireless interface is auto-detected at startup (first interface
 * with "groups: wlan" in its ifconfig output), overridable on the
 * command line.
 *
 * Usage:  wifirescue_dock [wlan-iface]
 *
 * Needs root privileges to run `service netif restart`, so start it
 * e.g. with sudo, or make the binary setuid root (see install.sh).
 *
 * Build:  gmake
 */

#import "WiFiRescue.h"
#import "DockView.h"

#import <Foundation/Foundation.h>
#include <poll.h>
#include <errno.h>

int main(int argc, const char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *wlanIf = nil;
    if (argc >= 2) {
        wlanIf = [NSString stringWithUTF8String:argv[1]];
    } else {
        wlanIf = [WiFiController detectWlanInterface];
    }
    if (wlanIf == nil) {
        NSLog(@"wifi-rescue: no wireless interface found, "
              @"falling back to wlan0");
        wlanIf = @"wlan0";
    }

    if (geteuid() != 0)
        NSLog(@"wifi-rescue: WARNING - not running as root; "
              @"'service netif restart' will fail");

    NSLog(@"wifi-rescue: starting (wlan=%@)", wlanIf);

    WiFiController *ctrl =
        [[WiFiController alloc] initWithWlanInterface:wlanIf];
    DockView *view = [[DockView alloc] initWithController:ctrl];
    if (view == nil) {
        /* Most common cause: running as root (setuid install) while
         * root has no access to the X server.  Fail loudly instead of
         * becoming a headless zombie looping on poll(). */
        NSLog(@"wifi-rescue: cannot open X display - exiting. "
              @"If running as root, run: xhost +SI:localuser:root");
        [pool drain];
        return 1;
    }

    /* Initial probe so the icon shows something honest. */
    [ctrl probeStatus];
    [view refresh];

    int wakeFD = [view wakeReadFD];
    int xFD    = [view xConnectionNumber];

    for (;;) {
        struct pollfd pfd[2];
        pfd[0].fd = xFD;    pfd[0].events = POLLIN;
        pfd[1].fd = wakeFD; pfd[1].events = POLLIN;

        int rc = poll(pfd, 2, 5000);       /* 5 s heartbeat */
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            break;
        }

        /* X events: expose, right click. */
        if (pfd[0].revents & POLLIN)
            [view processXEvents];

        /* Wakeup pipe: netif restart finished (or status changed). */
        if (pfd[1].revents & POLLIN) {
            char buf[16];
            while (read(wakeFD, buf, sizeof(buf)) > 0)
                ;
            [ctrl probeStatus];
            [view refresh];
        }

        /* Heartbeat: refresh the icon + un-wedge a stuck restart. */
        if (rc == 0) {
            [ctrl checkRestartTimeout];
            [ctrl probeStatus];
            [view refresh];
        }
    }

    NSLog(@"wifi-rescue: event loop exited");
    [pool drain];
    return 0;
}