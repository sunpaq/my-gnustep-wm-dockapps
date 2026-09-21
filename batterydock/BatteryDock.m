/*
 * BatteryDock.m — a Window Maker dock app written in Objective-C
 *
 * Objective-C refactor of battery-dockapp.c, modeled on the PowerDock
 * project (same DockApp structure, event loop and drawing style).
 *
 * Shows the current battery charge as a percentage in a 64x64 dockapp.
 * A lightning bolt is drawn when the laptop is on AC power, otherwise a
 * slim battery symbol with a fill level.  The percentage turns red when
 * the battery is low (< LOW_PCT) and discharging.
 *   Any click: re-read the battery state immediately.
 *
 * Data comes straight from the ACPI sysctls (no /dev/apm, no popen):
 *   hw.acpi.battery.life   0..100  percent
 *   hw.acpi.battery.rate   0..n    mW being drawn/charged
 *   hw.acpi.acline         1 = on AC power
 *
 * Build:  gmake        Run:  ./battery-dockapp &
 *                             (then drag it onto the Window Maker dock)
 */

#import <Foundation/Foundation.h>

#import <X11/Xlib.h>
#import <X11/Xatom.h>
#import <X11/Xutil.h>

#import <errno.h>
#import <signal.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/select.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

#define WIN_SIZE   64
#define LOW_PCT    15    /* red alert threshold when discharging */
#define POLL_SEC   10.0  /* periodic refresh */

/* Palette matching wm-wifi-rescue / backlight-dockapp */
#define COL_BG     "#202028"   /* dark charcoal */
#define COL_GREEN  "#3ddc5a"   /* green         */
#define COL_GRAY   "#9a9aa5"   /* gray border   */
#define COL_RED    "#ff4d4d"   /* low battery   */

/* ------------------------------------------------------------------ */
/* Timing helper                                                       */
/* ------------------------------------------------------------------ */

static double
nowSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------------ */
/* Battery — reads the ACPI battery state through sysctl(3)            */
/* ------------------------------------------------------------------ */

@interface Battery : NSObject
+ (int)life;                    /* 0..100 percent, or -1 unknown */
+ (BOOL)onAC;                   /* YES when on AC power */
@end

@implementation Battery

/* Read an integer sysctl; returns -1 on failure. */
+ (int)sysctlInt:(const char *)name
{
    int v = -1;
    size_t len = sizeof(v);

    if (sysctlbyname(name, &v, &len, NULL, 0) == -1)
        return -1;
    return v;
}

+ (int)life
{
    int v = [self sysctlInt:"hw.acpi.battery.life"];
    if (v < 0) return -1;
    if (v > 100) v = 100;
    return v;
}

+ (BOOL)onAC
{
    return [self sysctlInt:"hw.acpi.acline"] > 0;
}

@end

/* ------------------------------------------------------------------ */
/* DockApp — the X11 dock applet itself                                */
/* ------------------------------------------------------------------ */

@interface DockApp : NSObject
{
    Display        *dpy;
    Window          win;
    Pixmap          buf;
    GC              gc;
    Colormap        cmap;
    XFontStruct    *font;

    unsigned long   colBg;
    unsigned long   colBorder;
    unsigned long   colGlyph;
    unsigned long   colRed;

    int             life;          /* 0..100, or -1 unknown */
    BOOL            onAC;
    int             lastDrawn;     /* last (life<<1|ac) painted */
    double          nextPoll;      /* monotonic seconds of next poll */
    BOOL            quitRequested; /* WM_DELETE_WINDOW received */
}
- (id)initWithDisplay:(Display *)aDpy;
- (Window)window;
- (void)draw;
- (void)handleEvent:(XEvent *)ev;   /* full event dispatch */
- (void)tick;                       /* poll battery, redraw on change */
- (double)suggestedTimeout;         /* for select(); 0 = block */
- (double)nextPollTime;
- (BOOL)shouldQuit;
@end

@implementation DockApp

/* ---------- helpers ---------- */

- (unsigned long)colorNamed:(const char *)name
                   fallback:(const char *)fb
{
    XColor exact;
    if (XParseColor(dpy, cmap, name, &exact)
        && XAllocColor(dpy, cmap, &exact) != 0) {
        return exact.pixel;
    }
    if (XParseColor(dpy, cmap, fb, &exact)
        && XAllocColor(dpy, cmap, &exact) != 0) {
        return exact.pixel;
    }
    return BlackPixel(dpy, DefaultScreen(dpy));
}

- (void)drawCenteredString:(const char *)s atY:(int)y
{
    if (font == NULL) return;
    int len = strlen(s);
    int w = XTextWidth(font, s, len);
    XDrawString(dpy, buf, gc, (WIN_SIZE - w) / 2, y, s, len);
}

/* ---------- setup ---------- */

- (id)initWithDisplay:(Display *)aDpy
{
    self = [super init];
    if (self == nil) return nil;

    dpy    = aDpy;
    int scr = DefaultScreen(dpy);

    /* --- the 64x64 window Window Maker will swallow --- */
    win = XCreateSimpleWindow(dpy, RootWindow(dpy, scr),
                              0, 0, WIN_SIZE, WIN_SIZE, 0,
                              BlackPixel(dpy, scr),
                              BlackPixel(dpy, scr));

    /* size is fixed at 64x64 */
    XSizeHints *sh = XAllocSizeHints();
    sh->flags      = PMinSize | PMaxSize | PBaseSize;
    sh->min_width  = sh->max_width  = sh->base_width  = WIN_SIZE;
    sh->min_height = sh->max_height = sh->base_height = WIN_SIZE;
    XSetWMNormalHints(dpy, win, sh);
    XFree(sh);

    /*
     * The dockapp handshake: hand the window to the window manager as
     * the icon window in WithdrawnState.  Window Maker then swallows
     * it into the Dock / Wharf instead of mapping a normal window.
     */
    XWMHints *wmh = XAllocWMHints();
    wmh->flags         = InputHint | IconWindowHint | StateHint
                       | WindowGroupHint;
    wmh->input         = True;
    wmh->icon_window   = win;
    wmh->initial_state = WithdrawnState;
    wmh->window_group  = win;
    XSetWMHints(dpy, win, wmh);
    XFree(wmh);

    XClassHint *ch = XAllocClassHint();
    ch->res_name  = "battery-dockapp";
    ch->res_class = "DockApp";
    XSetClassHint(dpy, win, ch);
    XFree(ch);

    XStoreName(dpy, win, "battery-dockapp");

    /* WM_DELETE_WINDOW so a WM delete notice quits cleanly */
    XSetWMProtocols(dpy, win,
        &(Atom){ XInternAtom(dpy, "WM_DELETE_WINDOW", False) }, 1);

    /* --- graphics resources --- */
    cmap = DefaultColormap(dpy, scr);
    XGCValues gcv;
    gcv.graphics_exposures = False;
    gc = XCreateGC(dpy, win, GCGraphicsExposures, &gcv);

    buf  = XCreatePixmap(dpy, win, WIN_SIZE, WIN_SIZE,
                         DefaultDepth(dpy, scr));
    font = XLoadQueryFont(dpy,
        "-*-helvetica-bold-r-*-*-20-*-*-*-*-*-*-*");
    if (font == NULL) font = XLoadQueryFont(dpy, "fixed");

    colBg     = [self colorNamed:COL_BG    fallback:"#202020"];
    colBorder = [self colorNamed:COL_GRAY  fallback:"#808080"];
    colGlyph  = [self colorNamed:COL_GREEN fallback:"#00aa00"];
    colRed    = [self colorNamed:COL_RED   fallback:"#aa0000"];

    XSetWindowBackground(dpy, win, colBg);
    XSetWindowBorder(dpy, win, colBorder);

    XSelectInput(dpy, win, ExposureMask | ButtonPressMask
                 | StructureNotifyMask);

    life          = [Battery life];
    onAC          = [Battery onAC];
    lastDrawn     = -1;
    quitRequested = NO;

    XMapWindow(dpy, win);
    XFlush(dpy);   /* map immediately - the loop only flushes on draw */
    return self;
}

- (void)dealloc
{
    if (buf  != None) XFreePixmap(dpy, buf);
    if (gc   != None) XFreeGC(dpy, gc);
    if (font != NULL) XFreeFont(dpy, font);
    XDestroyWindow(dpy, win);
    [super dealloc];
}

- (Window)window
{
    return win;
}

/* ---------- drawing ---------- */

/*
 * Dark charcoal tile.  On AC: green lightning bolt.  Discharging:
 * slim battery symbol with a fill level.  Ink turns red when the
 * battery is low and discharging.
 */
- (void)draw
{
    char pct[8];
    if (life < 0)
        snprintf(pct, sizeof(pct), "n/a");
    else
        snprintf(pct, sizeof(pct), "%d%%", life);

    /* discharging + low -> red, otherwise green */
    unsigned long ink = colGlyph;
    if (!onAC && life >= 0 && life < LOW_PCT)
        ink = colRed;

    /* background */
    XSetForeground(dpy, gc, colBg);
    XFillRectangle(dpy, buf, gc, 0, 0, WIN_SIZE, WIN_SIZE);

    /* thin border around the tile, like PowerDock */
    XSetForeground(dpy, gc, colBorder);
    XDrawRectangle(dpy, buf, gc, 1, 1, WIN_SIZE - 3, WIN_SIZE - 3);

    if (onAC) {
        /* lightning bolt symbol (AC power) */
        XPoint bolt[7] = {
            { WIN_SIZE / 2 + 2, 2 },
            { WIN_SIZE / 2 - 8, 20 },
            { WIN_SIZE / 2 - 1, 20 },
            { WIN_SIZE / 2 - 3, 30 },
            { WIN_SIZE / 2 + 8, 10 },
            { WIN_SIZE / 2 + 1, 10 },
            { WIN_SIZE / 2 + 2, 2 },
        };
        XSetForeground(dpy, gc, ink);
        XFillPolygon(dpy, buf, gc, bolt, 7, Convex,
            CoordModeOrigin);
    } else {
        /* battery symbol with fill level (slim) */
        int bx = WIN_SIZE / 2 - 7, by = 4;
        int bwd = 14, bht = 24;
        XSetForeground(dpy, gc, colBorder);
        XDrawRectangle(dpy, buf, gc, bx, by, bwd, bht);
        /* terminal nub on top */
        XFillRectangle(dpy, buf, gc, WIN_SIZE / 2 - 3,
            by - 4, 6, 4);
        XSetForeground(dpy, gc, ink);
        if (life > 0) {
            XFillRectangle(dpy, buf, gc, bx + 2,
                by + bht - 2 - (bht - 4) * life / 100,
                bwd - 4, (bht - 4) * life / 100);
        }
    }

    /* percentage, centered */
    XSetForeground(dpy, gc, ink);
    [self drawCenteredString:pct atY:28 + (font ? font->ascent : 0)];

    /* level bar */
    int bx = 8, by = WIN_SIZE - 16, bwd = WIN_SIZE - 16, bht = 8;
    XSetForeground(dpy, gc, colBorder);
    XDrawRectangle(dpy, buf, gc, bx - 1, by - 1, bwd + 1, bht + 1);
    XSetForeground(dpy, gc, ink);
    if (life > 0) {
        XFillRectangle(dpy, buf, gc, bx, by,
                       bwd * life / 100, bht);
    }

    XCopyArea(dpy, buf, win, gc, 0, 0, WIN_SIZE, WIN_SIZE, 0, 0);
    XFlush(dpy);
}

/* ---------- actions / events ---------- */

- (void)handleEvent:(XEvent *)ev
{
    switch (ev->type) {
    case Expose:
        if (ev->xexpose.count == 0) [self draw];
        break;
    case ButtonPress:
        /* any button: re-read immediately */
        life = [Battery life];
        onAC = [Battery onAC];
        [self draw];
        break;
    case ClientMessage:
        /* WM_DELETE_WINDOW */
        quitRequested = YES;
        break;
    default:
        break;
    }
}

- (BOOL)shouldQuit
{
    return quitRequested;
}

- (void)tick
{
    /* timer: poll for external changes */
    int curlife = [Battery life];
    BOOL curac  = [Battery onAC];
    if (curlife >= 0) life = curlife;
    onAC = curac;

    int state = ((life < 0 ? -1 : life) << 1) | (onAC ? 1 : 0);
    if (state != lastDrawn) {
        [self draw];
        lastDrawn = state;
    }
    nextPoll = nowSeconds() + POLL_SEC;
}

- (double)suggestedTimeout
{
    double remain = nextPoll - nowSeconds();
    return (remain > 0.0) ? remain : 0.01;
}

- (double)nextPollTime
{
    return nextPoll;
}

@end

/* ------------------------------------------------------------------ */
/* main — event loop                                                   */
/* ------------------------------------------------------------------ */

int
main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    Display *dpy = XOpenDisplay(NULL);   /* honors $DISPLAY */
    if (dpy == NULL) {
        fprintf(stderr, "battery-dockapp: cannot open display "
                "(is $DISPLAY set?)\n");
        [pool release];
        return 1;
    }

    DockApp *app = [[DockApp alloc] initWithDisplay:dpy];
    [app tick];    /* sets first poll deadline */

    int xfd = ConnectionNumber(dpy);
    for (;;) {
        NSAutoreleasePool *loopPool = [[NSAutoreleasePool alloc] init];

        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(xfd, &fds);

        double t = [app suggestedTimeout];
        struct timeval tv;
        tv.tv_sec  = (time_t)t;
        tv.tv_usec = (suseconds_t)((t - tv.tv_sec) * 1e6);

        int r = select(xfd + 1, &fds, NULL, NULL, &tv);
        if (r < 0 && errno != EINTR) {
            perror("battery-dockapp: select");
            break;
        }

        while (XPending(dpy) > 0) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (ev.type == DestroyNotify) {
                XCloseDisplay(dpy);
                [app release];
                [pool release];
                return 0;
            }
            [app handleEvent:&ev];
            if ([app shouldQuit]) {
                XCloseDisplay(dpy);
                [app release];
                [pool release];
                return 0;
            }
        }

        if (nowSeconds() >= [app nextPollTime]) {
            [app tick];
        }

        [loopPool release];
    }

    XCloseDisplay(dpy);
    [app release];
    [pool release];
    return 0;
}