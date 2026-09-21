/*
 * BacklightDock.m — a Window Maker dock app written in Objective-C
 *
 * Objective-C refactor of backlight-dockapp.c, modeled on the PowerDock
 * project (same DockApp structure, event loop and drawing style).
 *
 * Shows the current screen brightness as a percentage in a 64x64 dockapp.
 *   Left click  (button 1): decrease brightness by STEP %
 *   Right click (button 3): increase brightness by STEP %
 *   Middle click (button 2): re-read the current brightness
 *
 * The brightness level is read from backlight(8); external changes are
 * picked up by a periodic poll (POLL_SEC) so the tile stays in sync.
 *
 * Build:  gmake        Run:  ./backlight-dockapp &
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
#define STEP       10
#define POLL_SEC   10.0   /* periodic refresh so external changes show up */

/* Palette matching wm-wifi-rescue */
#define COL_BG     "#202028"   /* dark charcoal */
#define COL_GREEN  "#3ddc5a"   /* green         */
#define COL_GRAY   "#9a9aa5"   /* gray border   */

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
/* Backlight — talks to backlight(8) through NSTask                    */
/* ------------------------------------------------------------------ */

@interface Backlight : NSObject
+ (int)level;                       /* 0..100, or -1 on failure */
+ (void)adjust:(NSString *)sign;    /* @"-" or @"+" by STEP */
@end

@implementation Backlight

/* Read current brightness; returns 0..100, or -1 on failure. */
+ (int)level
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:
        @"-c", @"backlight 2>/dev/null", nil]];

    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSPipe pipe]];

    int val = -1;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @try {
        [task launch];

        /* backlight(8) prints a few short lines and exits; reading to
         * EOF is effectively instant, same as the popen() it replaces */
        NSData *data = [[outPipe fileHandleForReading]
            readDataToEndOfFile];
        [task waitUntilExit];

        NSString *text = [[NSString alloc]
            initWithData:data encoding:NSUTF8StringEncoding];
        if (text != nil) {
            NSRange r = [text rangeOfString:@"brightness:"];
            if (r.location != NSNotFound) {
                NSString *rest = [text substringFromIndex:
                    NSMaxRange(r)];
                NSScanner *sc = [NSScanner scannerWithString:rest];
                int v = 0;
                if ([sc scanInt:&v]) {
                    val = v;
                }
            }
            [text release];
        }
    } @catch (NSException *exception) {
        NSLog(@"BacklightDock: failed to run backlight: %@", exception);
    }
    [pool release];

    [task release];

    if (val < 0)   return -1;
    if (val > 100) val = 100;
    return val;
}

/* Run "backlight <sign> <STEP>"; ignores errors like the C version. */
+ (void)adjust:(NSString *)sign
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:@"-c",
        [NSString stringWithFormat:@"backlight %@ %d >/dev/null 2>&1",
            sign, STEP], nil]];

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        NSLog(@"BacklightDock: failed to adjust brightness: %@",
              exception);
    }
    [pool release];

    [task release];
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

    int             brightness;    /* 0..100, or -1 unknown */
    int             lastDrawn;     /* last level actually painted */
    double          nextPoll;      /* monotonic seconds of next poll */
    BOOL            quitRequested; /* WM_DELETE_WINDOW received */
}
- (id)initWithDisplay:(Display *)aDpy;
- (Window)window;
- (void)draw;
- (void)handleEvent:(XEvent *)ev;   /* full event dispatch */
- (void)tick;                       /* poll brightness, redraw on change */
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
    ch->res_name  = "backlight-dockapp";
    ch->res_class = "DockApp";
    XSetClassHint(dpy, win, ch);
    XFree(ch);

    XStoreName(dpy, win, "backlight-dockapp");

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

    XSetWindowBackground(dpy, win, colBg);
    XSetWindowBorder(dpy, win, colBorder);

    XSelectInput(dpy, win, ExposureMask | ButtonPressMask
                 | StructureNotifyMask);

    brightness     = [Backlight level];
    lastDrawn      = -1;
    quitRequested  = NO;

    XMapWindow(dpy, win);
    [self draw];
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
 * Dark charcoal tile, green sun glyph (filled circle, top center),
 * the brightness percentage in the middle and a level bar at the
 * bottom -- same layout as the C version.
 */
- (void)draw
{
    XSetForeground(dpy, gc, colBg);
    XFillRectangle(dpy, buf, gc, 0, 0, WIN_SIZE, WIN_SIZE);

    /* thin border around the tile, like PowerDock */
    XSetForeground(dpy, gc, colBorder);
    XDrawRectangle(dpy, buf, gc, 1, 1, WIN_SIZE - 3, WIN_SIZE - 3);

    /* sun symbol (filled circle top center) */
    XSetForeground(dpy, gc, colGlyph);
    XFillArc(dpy, buf, gc, WIN_SIZE / 2 - 6, 4, 12, 12, 0, 360 * 64);

    /* percentage, centered */
    char pct[8];
    if (brightness < 0)
        snprintf(pct, sizeof(pct), "n/a");
    else
        snprintf(pct, sizeof(pct), "%d%%", brightness);
    [self drawCenteredString:pct
        atY:14 + (font ? font->ascent : 0) + 4];

    /* level bar */
    int bx = 8, by = WIN_SIZE - 20, bwd = WIN_SIZE - 16, bht = 8;
    XSetForeground(dpy, gc, colBorder);
    XDrawRectangle(dpy, buf, gc, bx - 1, by - 1, bwd + 1, bht + 1);
    XSetForeground(dpy, gc, colGlyph);
    if (brightness > 0) {
        XFillRectangle(dpy, buf, gc, bx, by,
                       bwd * brightness / 100, bht);
    }

    XCopyArea(dpy, buf, win, gc, 0, 0, WIN_SIZE, WIN_SIZE, 0, 0);
    XFlush(dpy);
}

/* ---------- actions ---------- */

- (void)handleButton:(XButtonEvent *)ev
{
    switch (ev->button) {
    case Button1:                        /* left: decrease */
        [Backlight adjust:@"-"];
        brightness = [Backlight level];
        [self draw];
        break;
    case Button3:                        /* right: increase */
        [Backlight adjust:@"+"];
        brightness = [Backlight level];
        [self draw];
        break;
    case Button2:                        /* middle: re-read only */
        brightness = [Backlight level];
        [self draw];
        break;
    default:
        break;                           /* wheel etc. */
    }
}

- (void)handleEvent:(XEvent *)ev
{
    switch (ev->type) {
    case Expose:
        if (ev->xexpose.count == 0) [self draw];
        break;
    case ButtonPress:
        [self handleButton:&ev->xbutton];
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
    int cur = [Backlight level];
    if (cur >= 0) {
        brightness = cur;
        if (brightness != lastDrawn) [self draw];
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
        fprintf(stderr, "backlight-dockapp: cannot open display "
                "(is $DISPLAY set?)\n");
        [pool release];
        return 1;
    }

    DockApp *app = [[DockApp alloc] initWithDisplay:dpy];

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
            perror("backlight-dockapp: select");
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