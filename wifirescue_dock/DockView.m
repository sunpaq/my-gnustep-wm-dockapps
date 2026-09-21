/*
 * DockView.m - Xlib implementation of a classic 64x64 Window Maker
 * dockapp. The window is created with WMHints initial_state =
 * WithdrawnState + IconWindowHint, which makes Window Maker (and other
 * WM dock-protocol window managers) swallow it into the dock.
 *
 * Appearance: a WiFi fan (three arcs + dot) that changes colour with
 * the link state, plus a one-line status text:
 *   green  <ssid> - online (associated)
 *   yellow "RST"  - `service netif restart` is running
 *   red    "DOWN" - offline (not associated)
 *   gray   "?"    - unknown
 * Right-clicking the docklet runs `service netif restart <if>`.
 */

#import "DockView.h"
#import "WiFiRescue.h"
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

@implementation DockView

- (instancetype)initWithController:(WiFiController *)controller
{
    self = [super init];
    if (!self)
        return nil;

    _ctrl = controller;
    _lastDrawn = WifiUnknown;

    _dpy = XOpenDisplay(NULL);
    if (_dpy == NULL) {
        NSLog(@"wifi-rescue: cannot open X display");
        [self release];
        return nil;
    }
    int scr = DefaultScreen(_dpy);

    /* Wake pipe: any thread can poke the main loop. */
    if (pipe(_wakePipe) != 0) {
        NSLog(@"wifi-rescue: pipe() failed");
        [self release];
        return nil;
    }
    fcntl(_wakePipe[0], F_SETFL, O_NONBLOCK);
    fcntl(_wakePipe[1], F_SETFL, O_NONBLOCK);

    Window root = RootWindow(_dpy, scr);
    _iconWin = XCreateSimpleWindow(_dpy, root, 0, 0, 64, 64, 0,
                BlackPixel(_dpy, scr), WhitePixel(_dpy, scr));
    _win = XCreateSimpleWindow(_dpy, root, 0, 0, 1, 1, 0,
                BlackPixel(_dpy, scr), WhitePixel(_dpy, scr));

    /* Dockapp magic: WM swallows iconWin because the main window
     * is born withdrawn with IconWindowHint set. */
    XWMHints hints;
    memset(&hints, 0, sizeof(hints));
    hints.flags         = StateHint | IconWindowHint | WindowGroupHint;
    hints.initial_state = WithdrawnState;
    hints.icon_window   = _iconWin;
    hints.window_group  = _win;
    XSetWMHints(_dpy, _win, &hints);

    XClassHint classHint;
    classHint.res_name  = (char *)"wifirescue_dock";
    classHint.res_class = (char *)"WMWiFiRescue";
    /* Class hint on BOTH windows: Window Maker matches docked tiles
     * (wDockTrackWindowLaunch) by the WM_CLASS of the *main* window,
     * so without this the withdrawn window identifies itself only
     * as "default.default" and can never be adopted by a dock tile. */
    XSetClassHint(_dpy, _win, &classHint);
    XSetClassHint(_dpy, _iconWin, &classHint);

    /* WM_COMMAND on the main window: lets WM also match by command. */
    char *cmdArgv[2];
    cmdArgv[0] = (char *)"wifirescue_dock";
    cmdArgv[1] = NULL;
    XSetCommand(_dpy, _win, cmdArgv, 1);

    XStoreName(_dpy, _win, "wifirescue_dock");
    XSetIconName(_dpy, _iconWin, "wifi");

    XSelectInput(_dpy, _iconWin,
                 ExposureMask | ButtonPressMask | ButtonReleaseMask);

    _gc = XCreateGC(_dpy, _iconWin, 0, NULL);

    Colormap cmap = DefaultColormap(_dpy, scr);
    XColor col, dummy;
    _colBg = WhitePixel(_dpy, scr);
    #define COLOR(spec, dst) \
        if (XAllocNamedColor(_dpy, cmap, spec, &col, &dummy)) dst = col.pixel
    COLOR("#202028", _colBg);
    COLOR("#3ddc5a", _colGreen);
    COLOR("#e5342f", _colRed);
    COLOR("#e8c33a", _colYellow);
    COLOR("#9a9aa5", _colGray);
    #undef COLOR

    /* Small bitmap font; fall back to "6x10"/"fixed".  NOTE: the
     * XFontStruct must stay alive for the whole app - XFreeFont() unloads
     * the font on the server, which would make the later
     * XQueryFont()/XDrawString calls fail and silently kill all status
     * text. */
    _fontStruct = XLoadQueryFont(_dpy, "7x13");
    if (_fontStruct == NULL)
        _fontStruct = XLoadQueryFont(_dpy, "6x10");
    if (_fontStruct == NULL)
        _fontStruct = XLoadQueryFont(_dpy, "fixed");

    XMapWindow(_dpy, _win);          /* WM withdraws it, keeps icon */
    /* XMapWindow does not flush Xlib's output buffer; without an
     * explicit XFlush() the MapWindow request can sit in our local
     * buffer for minutes (only the 5 s heartbeat draw requests slowly
     * fill it) and Window Maker never sees the window - i.e. no icon
     * appears in the dock. */
    XFlush(_dpy);
    return self;
}

- (int)xConnectionNumber
{
    return ConnectionNumber(_dpy);
}

- (int)wakeReadFD
{
    return _wakePipe[0];
}

- (void)sendWake
{
    char c = 'w';
    write(_wakePipe[1], &c, 1);
}

/* ------------------------------------------------------------------ */
/* Drawing                                                             */
/* ------------------------------------------------------------------ */
- (void)draw
{
    Pixmap pm = XCreatePixmap(_dpy, _iconWin, 64, 64,
                              DefaultDepth(_dpy, DefaultScreen(_dpy)));
    XGCValues gcv;
    gcv.foreground = _colBg;
    XChangeGC(_dpy, _gc, GCForeground, &gcv);
    XFillRectangle(_dpy, pm, _gc, 0, 0, 64, 64);

    /* Thin border around the tile, like PowerDock. */
    gcv.foreground = _colGray;
    XChangeGC(_dpy, _gc, GCForeground, &gcv);
    XDrawRectangle(_dpy, pm, _gc, 1, 1, 61, 61);

    WifiStatus st = [_ctrl status];

    unsigned long col = _colGray;
    const char *text = "?";
    NSString *label = nil;
    switch (st) {
    case WifiAssociated:
        col = _colGreen;
        label = [_ctrl lastSSID];
        if (label == nil || [label length] == 0)
            label = @"OK";
        break;
    case WifiDown:       col = _colRed;    text = "DOWN"; break;
    case WifiRestarting: col = _colYellow; text = "RST";  break;
    default:             col = _colGray;   text = "?";    break;
    }
    if (label != nil) {
        /* 7x13 font: at most 9 characters fit into 64 px. */
        if ([label length] > 9)
            label = [label substringToIndex:9];
        text = [label UTF8String];
    }

    /* WiFi fan: three arcs centred on (32, 42), 45..135 degrees.
     * Raised so the SSID text has clear room at the bottom and the
     * icon+text block sits centered in the tile. */
    static const int radii[3] = { 11, 21, 30 };
    const int fanY = 42;
    gcv.foreground = col;
    gcv.line_width = 3;
    XChangeGC(_dpy, _gc, GCForeground | GCLineWidth, &gcv);
    for (int i = 0; i < 3; i++) {
        int r = radii[i];
        XDrawArc(_dpy, pm, _gc, 32 - r, fanY - r, r * 2, r * 2,
                 45 * 64, 90 * 64);
    }
    /* Dot in the middle. */
    XFillArc(_dpy, pm, _gc, 32 - 4, fanY - 4, 8, 8, 0, 360 * 64);

    /* Status text at the bottom, horizontally centered. */
    gcv.line_width = 1;
    if (_fontStruct != NULL) {
        gcv.font = _fontStruct->fid;
        XChangeGC(_dpy, _gc, GCLineWidth | GCFont, &gcv);
        int tw = XTextWidth(_fontStruct, text, (int)strlen(text));
        XDrawString(_dpy, pm, _gc, (64 - tw) / 2, 62,
                    text, (int)strlen(text));
    } else {
        XChangeGC(_dpy, _gc, GCLineWidth, &gcv);
    }

    XCopyArea(_dpy, pm, _iconWin, _gc, 0, 0, 64, 64, 0, 0);
    XFreePixmap(_dpy, pm);
    /* Make sure the repaint actually reaches the server; the main loop
     * only ever polls for input, so nothing else would flush. */
    XFlush(_dpy);
    if (_lastDrawn != st)
        NSLog(@"wifi-rescue: drew state=%d color=0x%lx text=%s",
              (int)st, (unsigned long)col, text);
    _lastDrawn = st;
}

- (void)refresh
{
    /* Always repaint, even when the status is unchanged: Window Maker
     * caches dockapp icons and can paste a stale image over our window
     * WITHOUT sending an Expose, which used to leave the icon stuck on
     * an old colour (e.g. yellow "RST") after the network had already
     * recovered. The event loop calls this every 5 s heartbeat, so a
     * clobbered icon now heals within one beat. */
    [self draw];
}

/* ------------------------------------------------------------------ */
/* X event pump                                                        */
/* ------------------------------------------------------------------ */
- (void)processXEvents
{
    while (XPending(_dpy) > 0) {
        XEvent ev;
        XNextEvent(_dpy, &ev);
        switch (ev.type) {
        case Expose:
            if (ev.xexpose.count == 0)
                [self draw];
            break;
        case ButtonPress:
            if (ev.xbutton.button == 3)      /* right click */
                [self spawnNetifRestart];
            break;
        default:
            break;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Right-click: run `service netif restart <if>` in the background.    */
/* ------------------------------------------------------------------ */
- (void)spawnNetifRestart
{
    if ([_ctrl isRestarting])
        return;
    NSLog(@"wifi-rescue: right click - restarting netif on %@",
          [_ctrl wlanIf]);
    [_ctrl beginNetifRestart];
    [self sendWake];                      /* turn yellow immediately */
    [NSThread detachNewThreadSelector:@selector(restartThread)
                             toTarget:self
                           withObject:nil];
}

- (void)restartThread
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [_ctrl finishNetifRestart];
    [self sendWake];                  /* redraw promptly */
    [pool drain];
}

- (void)dealloc
{
    if (_dpy) {
        if (_fontStruct)
            XFreeFont(_dpy, _fontStruct);
        XFreeGC(_dpy, _gc);
        XCloseDisplay(_dpy);
    }
    [super dealloc];
}

@end