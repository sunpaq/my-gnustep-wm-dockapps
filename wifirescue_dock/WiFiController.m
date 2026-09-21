/*
 * WiFiController.m - Wi-Fi status probing for the dockapp.
 *
 * Pure status display: probes `ifconfig <wlan>` and reports whether
 * the interface exists, is associated and holds an IPv4 address.
 * The only action it performs is the (right-click triggered)
 * `service netif restart <if>`.
 */

#import "WiFiRescue.h"
#import <sys/wait.h>
#import <time.h>

@implementation WiFiController

@synthesize wlanIf = _wlanIf;

/* ------------------------------------------------------------------ */
/* Auto-detect the wireless interface: the first interface whose       */
/* ifconfig output contains "groups: wlan" (a wlan(4) vap).            */
/* ------------------------------------------------------------------ */
+ (NSString *)detectWlanInterface
{
    FILE *fp = popen("ifconfig -l 2>&1", "r");
    if (fp == NULL)
        return nil;

    char line[1024];
    NSString *found = nil;
    if (fgets(line, sizeof(line), fp) != NULL) {
        char *save = NULL;
        for (char *tok = strtok_r(line, " \t\r\n", &save);
             tok != NULL && found == nil;
             tok = strtok_r(NULL, " \t\r\n", &save)) {
            NSString *cmd = [NSString stringWithFormat:
                        @"ifconfig %s 2>&1", tok];
            FILE *ifp = popen([cmd fileSystemRepresentation], "r");
            if (ifp == NULL)
                continue;
            char iline[1024];
            while (fgets(iline, sizeof(iline), ifp) != NULL) {
                /* matches both "groups: wlan" and "wlan ..." */
                if (strstr(iline, "groups:") != NULL &&
                    strstr(iline, "wlan") != NULL) {
                    found = [NSString stringWithUTF8String:tok];
                    break;
                }
            }
            pclose(ifp);
        }
    }
    pclose(fp);
    return found;
}

/* ------------------------------------------------------------------ */
/* Run a shell command, log its output. Returns YES on exit status 0. */
/* ------------------------------------------------------------------ */
- (BOOL)runCommand:(NSString *)cmd
{
    NSString *full = [cmd stringByAppendingString:@" 2>&1"];
    FILE *fp = popen([full fileSystemRepresentation], "r");
    if (fp == NULL) {
        NSLog(@"wifi-rescue: popen failed for: %@", cmd);
        return NO;
    }
    char line[512];
    while (fgets(line, sizeof(line), fp) != NULL) {
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n')
            line[len - 1] = '\0';
        NSLog(@"wifi-rescue:   | %s", line);
    }
    int rc = pclose(fp);
    if (WIFEXITED(rc) && WEXITSTATUS(rc) == 0)
        return YES;
    NSLog(@"wifi-rescue: command failed (%@) rc=%d",
          cmd, WIFEXITED(rc) ? WEXITSTATUS(rc) : -1);
    return NO;
}

/* -------------------------------------------------------------- */
/* Init                                                            */
/* -------------------------------------------------------------- */
- (instancetype)initWithWlanInterface:(NSString *)wlan
{
    self = [super init];
    if (self) {
        _wlanIf    = [wlan copy];
        _stateLock    = [[NSLock alloc] init];
        _status       = WifiUnknown;
        _restartStart = 0;
    }
    return self;
}

/* -------------------------------------------------------------- */
/* Probe: parse `ifconfig <wlan>` output for status, IPv4 and SSID. */
/* -------------------------------------------------------------- */
- (WifiStatus)probeStatus
{
    NSString *ip   = nil;
    NSString *ssid = nil;

    NSString *cmd = [NSString stringWithFormat:@"ifconfig %@",
                               _wlanIf];
    FILE *fp = popen([cmd fileSystemRepresentation], "r");
    if (fp == NULL) {
        [self setState:WifiUnknown ip:nil ssid:nil];
        return WifiUnknown;
    }

    char line[1024];
    BOOL sawInterface = NO;
    WifiStatus parsed = WifiDown;
    while (fgets(line, sizeof(line), fp) != NULL) {
        sawInterface = YES;              /* ifconfig produced output */
        if (strstr(line, "status:") != NULL) {
            if (strstr(line, "associated") != NULL)
                parsed = WifiAssociated;
            else
                parsed = WifiDown;       /* no carrier, scanning... */
        }
        char *p = strstr(line, "inet ");
        if (p != NULL) {
            p += 5;
            while (*p == ' ') p++;
            char *end = p;
            while (*end && *end != ' ') end++;
            char buf[64];
            size_t n = (size_t)(end - p);
            if (n < sizeof(buf)) {
                memcpy(buf, p, n);
                buf[n] = '\0';
                ip = [NSString stringWithUTF8String:buf];
            }
        }
        /* SSID line:  "ssid <name> channel ..." */
        char *s = strstr(line, "ssid ");
        if (s != NULL && ssid == nil) {
            s += 5;
            char *end = s;
            while (*end && *end != ' ' && *end != '\n') end++;
            char buf[64];
            size_t n = (size_t)(end - s);
            if (n > 0 && n < sizeof(buf)) {
                memcpy(buf, s, n);
                buf[n] = '\0';
                ssid = [NSString stringWithUTF8String:buf];
            }
        }
    }
    pclose(fp);

    if (!sawInterface)
        parsed = WifiDown;               /* vap does not exist */

    [self setState:parsed ip:ip ssid:ssid];
    return parsed;
}

- (WifiStatus)status
{
    WifiStatus st;
    [_stateLock lock];
    st = _status;
    [_stateLock unlock];
    return st;
}

- (NSString *)lastIP
{
    NSString *ip;
    [_stateLock lock];
    ip = [_lastIP copy];
    [_stateLock unlock];
    return ip;
}

- (NSString *)lastSSID
{
    NSString *ssid;
    [_stateLock lock];
    ssid = [_lastSSID copy];
    [_stateLock unlock];
    return ssid;
}

- (BOOL)isRestarting
{
    BOOL r;
    [_stateLock lock];
    r = _restarting;
    [_stateLock unlock];
    return r;
}

- (void)setState:(WifiStatus)st ip:(NSString *)ip ssid:(NSString *)ssid
{
    [_stateLock lock];
    WifiStatus old = _status;
    if (!_restarting)                    /* stay "restarting" until done */
        _status = st;
    _lastIP   = [ip copy];
    _lastSSID = [ssid copy];
    [_stateLock unlock];
    if (old != _status)
        NSLog(@"wifi-rescue: state %d -> %d (ip=%@ ssid=%@)",
              (int)old, (int)_status, _lastIP, _lastSSID);
}

- (void)setStatusFlag:(WifiStatus)st
{
    [_stateLock lock];
    _status = st;
    [_stateLock unlock];
}

/* -------------------------------------------------------------- */
/* Right-click action: `service netif restart <if>` (synchronous;  */
/* run from a background thread).                                  */
/* -------------------------------------------------------------- */
/* NOTE: do NOT run the restart through popen()+fgets(): the        */
/* netif script daemonizes wpa_supplicant (-B), which inherits the  */
/* popen pipe and never exits, so fgets() never sees EOF and the    */
/* restart thread blocks forever, leaving the icon stuck on "RST".  */
/* Instead redirect output to a log file and wait only for the      */
/* direct child with system().                                      */
- (void)beginNetifRestart
{
    [_stateLock lock];
    _restarting   = YES;
    _restartStart = time(NULL);
    [_stateLock unlock];
    [self setStatusFlag:WifiRestarting];
}

- (void)finishNetifRestart
{
    NSString *cmd = [NSString stringWithFormat:
                @"service netif restart %@ >>/tmp/wifirescue_dock.log 2>&1",
                _wlanIf];
    NSLog(@"wifi-rescue: running '%@'", cmd);
    int rc = system([cmd fileSystemRepresentation]);
    if (rc == -1 || (WIFEXITED(rc) && WEXITSTATUS(rc) != 0))
        NSLog(@"wifi-rescue: restart command failed rc=%d", rc);

    /* Re-association + DHCP can take 10-20 s. Keep showing RST until
     * the link is associated with an IPv4 address (or give up after
     * ~30 s and show the honest state). */
    BOOL ok = NO;
    for (int i = 0; i < 15; i++) {
        [NSThread sleepForTimeInterval:2.0];
        WifiStatus st = [self probeStatus];
        if (st == WifiAssociated && [self lastIP] != nil) {
            ok = YES;
            break;
        }
    }

    [_stateLock lock];
    _restarting = NO;
    [_stateLock unlock];
    [self probeStatus];

    if (ok)
        NSLog(@"wifi-rescue: restart OK - %@ associated with IP %@",
              _wlanIf, [self lastIP]);
    else
        NSLog(@"wifi-rescue: restart finished but link is still down "
              @"on %@", _wlanIf);
}

- (void)checkRestartTimeout
{
    [_stateLock lock];
    BOOL stuck = _restarting && _restartStart != 0 &&
                 time(NULL) - _restartStart > 120;
    if (stuck)
        _restarting = NO;
    [_stateLock unlock];
    if (stuck) {
        NSLog(@"wifi-rescue: restarting state stuck >120 s - forcing "
              @"status refresh");
        [self probeStatus];
    }
}

@end