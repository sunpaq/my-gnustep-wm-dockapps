/*
 * ClockDock.m — a Window Maker dock app written in Objective-C
 *
 * Objective-C refactor of clock_dockapp.c, modeled on the PowerDock
 * project (same DockApp structure, event loop and drawing style).
 *
 * Shows the time in digit format in a 64x64 dockapp:
 *   top    : weekday + day of month   (small, dim gray)
 *   middle : HH:MM                    (large 7-segment digits, green)
 *   bottom : seconds (+ AM/PM)        (small, dim gray)
 *
 * The HH:MM digits are drawn by hand as 7-segment digits (no font),
 * so they are as large as the tile allows and exactly centered.
 *
 *   Left click (button 1): toggle 24h / 12h format
 *
 * Build:  gmake        Run:  ./clock_dockapp &
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
#import <time.h>
#import <unistd.h>

#define WIN_SIZE   64
#define POLL_SEC   1.0   /* tick every second */

/* Palette matching the other dockapps */
#define COL_BG     "#202028"   /* dark charcoal */
#define COL_GREEN  "#3ddc5a"   /* green         */
#define COL_GRAY   "#9a9aa5"   /* gray border   */
#define COL_DIM    "#5a5a64"   /* dim gray text */

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
/* Clock — builds the three display strings from localtime(3)          */
/* ------------------------------------------------------------------ */

@interface Clock : NSObject
+ (void)stringsFor12h:(BOOL)use12h
               toDate:(char *)date dateSize:(size_t)dateSize
               toBig:(char *)big bigSize:(size_t)bigSize
               toSecs:(char *)secs secsSize:(size_t)secsSize;
@end

@implementation Clock

/*
 * Fills:
 *   date : "Mon 21"
 *   big  : "13:37"          (12h mode: "01:37")
 *   secs : "45 P"           (24h mode: "45  ")
 */
+ (void)stringsFor12h:(BOOL)use12h
               toDate:(char *)date dateSize:(size_t)dateSize
               toBig:(char *)big bigSize:(size_t)bigSize
               toSecs:(char *)secs secsSize:(size_t)secsSize
{
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);

    int hour = use12h ? tm.tm_hour % 12 : tm.tm_hour;
    if (hour == 0) hour = 12;
    char ampm = (tm.tm_hour < 12) ? 'A' : 'P';

    strftime(date, dateSize, "%a %d", &tm);
    snprintf(big, bigSize, "%02d:%02d", hour, tm.tm_min);
    if (use12h)
        snprintf(secs, secsSize, "%02d %c", tm.tm_sec, ampm);
    else
        snprintf(secs, secsSize, "%02d", tm.tm_sec);
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
    XFontStruct    *fontSmall;

    unsigned long   colBg;
    unsigned long   colBorder;
    unsigned long   colGlyph;
    unsigned long   colDim;

    BOOL            use12h;
    char            curDate[16];
    char            curBig[16];
    char            curSecs[16];
    double          nextPoll;      /* monotonic seconds of next tick */
    BOOL            quitRequested; /* WM_DELETE_WINDOW received */
}
- (id)initWithDisplay:(Display *)aDpy;
- (Window)window;
- (void)draw;
- (void)drawIfChanged;
- (void)drawDigit:(int)digit atX:(int)x y:(int)y color:(unsigned long)c;
- (void)drawTime:(const char *)s color:(unsigned long)c;
- (void)handleEvent:(XEvent *)ev;   /* full event dispatch */
- (void)tick;                       /* re-read the clock, redraw on change */
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

/* draw a string centered horizontally at the given baseline */
- (void)drawCentered:(XFontStruct *)f string:(const char *)s
           baseline:(int)baseline color:(unsigned long)color
{
    if (f == NULL) return;
    int len = strlen(s);
    /* exact integer centering: (WIN_SIZE - textwidth) / 2 */
    int tw = XTextWidth(f, s, len);
    XSetForeground(dpy, gc, color);
    XDrawString(dpy, buf, gc, (WIN_SIZE - tw) / 2, baseline, s, len);
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
    ch->res_name  = "clock_dockapp";
    ch->res_class = "DockApp";
    XSetClassHint(dpy, win, ch);
    XFree(ch);

    XStoreName(dpy, win, "clock_dockapp");

    /* WM_DELETE_WINDOW so a WM delete notice quits cleanly */
    XSetWMProtocols(dpy, win,
        &(Atom){ XInternAtom(dpy, "WM_DELETE_WINDOW", False) }, 1);

    /* --- graphics resources --- */
    cmap = DefaultColormap(dpy, scr);
    XGCValues gcv;
    gcv.graphics_exposures = False;
    gc = XCreateGC(dpy, win, GCGraphicsExposures, &gcv);

    buf = XCreatePixmap(dpy, win, WIN_SIZE, WIN_SIZE,
                        DefaultDepth(dpy, scr));

    /* classic X11 bitmap fonts -- always present on FreeBSD */
    fontSmall = XLoadQueryFont(dpy, "7x13");
    if (fontSmall == NULL)
        fontSmall = XLoadQueryFont(dpy,
            "-*-fixed-*-*-*-*-13-*-*-*-*-*-*-*");
    if (fontSmall == NULL) fontSmall = XLoadQueryFont(dpy, "fixed");

    colBg     = [self colorNamed:COL_BG    fallback:"#202020"];
    colBorder = [self colorNamed:COL_GRAY  fallback:"#808080"];
    colGlyph  = [self colorNamed:COL_GREEN fallback:"#00aa00"];
    colDim    = [self colorNamed:COL_DIM   fallback:"#505050"];

    XSetWindowBackground(dpy, win, colBg);
    XSetWindowBorder(dpy, win, colBorder);

    XSelectInput(dpy, win, ExposureMask | ButtonPressMask
                 | StructureNotifyMask);

    use12h        = NO;
    quitRequested = NO;

    XMapWindow(dpy, win);
    return self;
}

- (void)dealloc
{
    if (buf != None) XFreePixmap(dpy, buf);
    if (gc  != None) XFreeGC(dpy, gc);
    if (fontSmall != NULL) XFreeFont(dpy, fontSmall);
    XDestroyWindow(dpy, win);
    [super dealloc];
}

- (Window)window
{
    return win;
}

/* ---------- 7-segment digits ---------- */

/* segments: a b c d e f g (top, upper-right, lower-right, bottom,
 * lower-left, upper-left, middle); 1 = lit */
static const int segTable[10][7] = {
    { 1,1,1,1,1,1,0 },    /* 0 */
    { 0,1,1,0,0,0,0 },    /* 1 */
    { 1,1,0,1,1,0,1 },    /* 2 */
    { 1,1,1,1,0,0,1 },    /* 3 */
    { 0,1,1,0,0,1,1 },    /* 4 */
    { 1,0,1,1,0,1,1 },    /* 5 */
    { 1,0,1,1,1,1,1 },    /* 6 */
    { 1,1,1,0,0,0,0 },    /* 7 */
    { 1,1,1,1,1,1,1 },    /* 8 */
    { 1,1,1,1,0,1,1 },    /* 9 */
};

/*
 * Draw one 7-segment digit in a 13x22 box at (x, y).
 */
- (void)drawDigit:(int)digit atX:(int)x y:(int)y color:(unsigned long)c
{
    const int Wd = 13, H = 22, t = 3;
    const int vLen = (H - 2) / 2;         /* vertical segment length */
    const int *s = segTable[digit];

    XSetForeground(dpy, gc, c);

    /* horizontal segments */
    if (s[0]) XFillRectangle(dpy, buf, gc, x + 1, y, Wd - 2, t);        /* a */
    if (s[6]) XFillRectangle(dpy, buf, gc, x + 1, y + (H - t) / 2,
                                 Wd - 2, t);                           /* g */
    if (s[3]) XFillRectangle(dpy, buf, gc, x + 1, y + H - t, Wd - 2, t);/* d */

    /* vertical segments */
    if (s[5]) XFillRectangle(dpy, buf, gc, x, y + 1, t, vLen);        /* f */
    if (s[1]) XFillRectangle(dpy, buf, gc, x + Wd - t, y + 1, t, vLen);/* b */
    if (s[4]) XFillRectangle(dpy, buf, gc, x, y + H - 1 - vLen,
                                 t, vLen);                             /* e */
    if (s[2]) XFillRectangle(dpy, buf, gc, x + Wd - t, y + H - 1 - vLen,
                                 t, vLen);                             /* c */
}

/*
 * Draw "HH:MM" as large 7-segment digits, horizontally centered.
 * The total width is computed first, so the block sits exactly in
 * the middle of the tile -- no font metrics involved at all.
 */
- (void)drawTime:(const char *)s color:(unsigned long)c
{
    const int Wd = 13, gap = 2, colonW = 3, H = 22;
    const int y = 16;                     /* top of the digits */

    int total = 0;
    for (const char *p = s; *p; p++) {
        total += (*p == ':') ? colonW : Wd;
        total += gap;
    }
    total -= gap;                         /* no gap after the last glyph */

    int x = (WIN_SIZE - total) / 2;       /* exact center */

    for (const char *p = s; *p; p++) {
        if (*p == ':') {
            /* two dots around the vertical middle */
            XSetForeground(dpy, gc, c);
            XFillRectangle(dpy, buf, gc, x, y + H / 2 - 6, 3, 3);
            XFillRectangle(dpy, buf, gc, x, y + H / 2 + 3, 3, 3);
            x += colonW + gap;
        } else {
            [self drawDigit:(*p - '0') atX:x y:y color:c];
            x += Wd + gap;
        }
    }
}

/* ---------- drawing ---------- */

/*
 * Dark charcoal tile with three lines:
 *   top    : weekday + day of month (small, dim)
 *   middle : HH:MM                  (large 7-segment digits, green)
 *   bottom : seconds                (small, dim)
 */
- (void)draw
{
    XSetForeground(dpy, gc, colBg);
    XFillRectangle(dpy, buf, gc, 0, 0, WIN_SIZE, WIN_SIZE);

    /* thin border around the tile, like PowerDock */
    XSetForeground(dpy, gc, colBorder);
    XDrawRectangle(dpy, buf, gc, 1, 1, WIN_SIZE - 3, WIN_SIZE - 3);

    [self drawCentered:fontSmall string:curDate baseline:12
                 color:colDim];
    [self drawTime:curBig color:colGlyph];
    [self drawCentered:fontSmall string:curSecs baseline:56
                 color:colDim];

    XCopyArea(dpy, buf, win, gc, 0, 0, WIN_SIZE, WIN_SIZE, 0, 0);
    XFlush(dpy);
}

/* redraw only when one of the three strings changed */
- (void)drawIfChanged
{
    char date[16], big[8], secs[8];
    [Clock stringsFor12h:use12h ? YES : NO
                 toDate:date dateSize:sizeof(date)
                 toBig:big bigSize:sizeof(big)
                 toSecs:secs secsSize:sizeof(secs)];

    if (strcmp(big, curBig) == 0 && strcmp(secs, curSecs) == 0
        && strcmp(date, curDate) == 0) {
        return;                          /* nothing changed */
    }

    strlcpy(curDate, date, sizeof(curDate));
    strlcpy(curBig, big, sizeof(curBig));
    strlcpy(curSecs, secs, sizeof(curSecs));
    [self draw];
}

/* ---------- actions / events ---------- */

- (void)handleEvent:(XEvent *)ev
{
    switch (ev->type) {
    case Expose:
        if (ev->xexpose.count == 0) {
            curBig[0] = '\0';            /* force redraw */
            [self drawIfChanged];
        }
        break;
    case ButtonPress:
        if (ev->xbutton.button == Button1) {
            use12h = !use12h;
            curBig[0] = '\0';            /* force redraw */
            [self drawIfChanged];
        }
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
    [self drawIfChanged];
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
        fprintf(stderr, "clock_dockapp: cannot open display "
                "(is $DISPLAY set?)\n");
        [pool release];
        return 1;
    }

    DockApp *app = [[DockApp alloc] initWithDisplay:dpy];
    [app tick];    /* sets first poll deadline, draws the first face */

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
            perror("clock_dockapp: select");
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