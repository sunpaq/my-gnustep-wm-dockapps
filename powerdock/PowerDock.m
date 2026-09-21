/*
 * PowerDock.m — a Window Maker dock app written in Objective-C
 *
 * A 64x64 dock applet that controls system power:
 *
 *   Button1 (left)   : open a chooser dialog  (Sleep / Shut down)
 *   Button2 (middle) : reboot                   (click twice to confirm)
 *   Button3 (right)  : power off                (click twice to confirm)
 *
 * The chooser dialog is an override-redirect popup that appears next to
 * the dock tile: click SLEEP or SHUT DOWN to run the action right away;
 * dismiss it with Escape, a click outside it, or by letting it time out
 * (10 s).  While it is open the pointer and keyboard are grabbed so stray
 * clicks cannot leak to other windows.
 *
 * The destructive actions arm a red "SURE?" state for 5 seconds;
 * a second click on the same button confirms, any other click or
 * an expiry disarms it.
 *
 * Commands are chosen at startup: if systemctl exists (Linux/systemd)
 * it is used, otherwise the BSD commands (zzz / shutdown -p / -r).
 * Override with environment variables if you like:
 *
 *   POWERDOCK_SLEEP="zzz" POWERDOCK_OFF="shutdown -p now" \
 *   POWERDOCK_REBOOT="shutdown -r now" ./powerdock
 *
 * Build:  gmake        Run:  ./powerdock &
 */

#import <Foundation/Foundation.h>

#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/extensions/Xinerama.h>
#import <X11/keysym.h>

#import <errno.h>
#import <signal.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/select.h>
#import <time.h>
#import <unistd.h>

#define WIN_SIZE     64
#define ARM_TIMEOUT  5.0   /* seconds the confirm state stays armed */

/* chooser popup geometry */
#define DLG_W        220
#define DLG_H        70
#define DLG_BTN_W    90
#define DLG_BTN_H    32
#define DLG_BTN_Y    30
#define DLG_BTN1_X   12   /* SLEEP button */
#define DLG_BTN2_X   (DLG_W - DLG_BTN_W - 12)  /* SHUT DOWN button */
#define DLG_TIMEOUT  10.0 /* auto-dismiss seconds */

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
/* CommandRunner — runs shell commands without blocking the dock app   */
/* ------------------------------------------------------------------ */

@interface CommandRunner : NSObject
{
    NSMutableArray *tasks;   /* keep references so children get reaped */
    NSTask         *lastTask; /* most recently launched, for status check */
}
- (void)run:(NSString *)command;
- (NSTask *)lastTask;
@end

@implementation CommandRunner

- (NSTask *)lastTask
{
    return [[lastTask retain] autorelease];
}

- (id)init
{
    self = [super init];
    if (self != nil) {
        tasks = [[NSMutableArray alloc] init];
        lastTask = nil;
    }
    return self;
}

- (void)dealloc
{
    [lastTask release];
    [tasks release];
    [super dealloc];
}

- (void)run:(NSString *)command
{
    NSTask *task = [[NSTask alloc] init];

    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:@"-c", command, nil]];

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @try {
        [task launch];
        NSLog(@"PowerDock: launched: %@", command);
        [tasks addObject:task];           /* retained until reaped */
        [lastTask release];
        lastTask = [task retain];
    } @catch (NSException *exception) {
        NSLog(@"PowerDock: failed to run '%@': %@", command, exception);
    }
    [pool release];

    [task release];

    /* prune finished tasks (cap the array as a safety net) */
    NSUInteger i = 0;
    while (i < [tasks count]) {
        NSTask *t = [tasks objectAtIndex:i];
        if ([t isRunning]) {
            i++;
        } else {
            [tasks removeObjectAtIndex:i];
        }
    }
    while ([tasks count] > 16) {
        [tasks removeObjectAtIndex:0];
    }
}

@end

/* ------------------------------------------------------------------ */
/* DockApp — the X11 dock applet itself                                */
/* ------------------------------------------------------------------ */

typedef enum {
    ARM_NONE = 0,
    ARM_SLEEP,
    ARM_REBOOT,
    ARM_OFF
} ArmedAction;

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
    unsigned long   colArmedBg;
    unsigned long   colArmedFg;
    unsigned long   colErrBg;
    unsigned long   colErrFg;

    Window          dlgWin;        /* chooser popup (created in init) */
    Pixmap          dlgBuf;
    BOOL            dlgOpen;
    int             dlgHover;      /* 0 none, 1 sleep, 2 off */
    double          dlgDeadline;

    ArmedAction     armed;
    double          armedDeadline;
    BOOL            blink;

    CommandRunner  *runner;
    NSString       *sleepCmd;
    NSString       *offCmd;
    NSString       *rebootCmd;
    NSString       *privPrefix;   /* "sudo"/"doas", or nil for none */
    NSTask         *checkedTask;  /* most recent task whose exit we judged */
    double          failUntil;    /* ERR flash deadline; 0 = not flashing */
}
- (id)initWithDisplay:(Display *)aDpy;
- (Window)window;
- (void)draw;
- (void)handleButton:(XButtonEvent *)ev;
- (void)handleEvent:(XEvent *)ev;     /* full event dispatch */
- (void)openDialog;                   /* show the chooser popup */
- (void)closeDialog;
- (void)drawDialog;
- (void)tick;                       /* blink / disarm housekeeping */
- (double)suggestedTimeout;         /* for select(); 0 = block */
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
    wmh->flags         = IconWindowHint | StateHint | WindowGroupHint;
    wmh->icon_window   = win;
    wmh->initial_state = WithdrawnState;
    wmh->window_group  = win;
    XSetWMHints(dpy, win, wmh);
    XFree(wmh);

    XClassHint *ch = XAllocClassHint();
    ch->res_name  = "powerdock";
    ch->res_class = "Dock";
    XSetClassHint(dpy, win, ch);
    XFree(ch);

    XStoreName(dpy, win, "PowerDock");

    /* --- graphics resources --- */
    cmap = DefaultColormap(dpy, scr);
    XGCValues gcv;
    gcv.graphics_exposures = False;
    gc = XCreateGC(dpy, win, GCGraphicsExposures, &gcv);

    buf  = XCreatePixmap(dpy, win, WIN_SIZE, WIN_SIZE,
                         DefaultDepth(dpy, scr));
    font = XLoadQueryFont(dpy, "fixed");
    if (font != NULL) {
        XSetFont(dpy, gc, font->fid);
    }

    colBg      = [self colorNamed:"#1c2024" fallback:"#202020"];
    colBorder  = [self colorNamed:"#5c6370" fallback:"#808080"];
    colGlyph   = [self colorNamed:"#3fbf5f" fallback:"#00aa00"];
    colArmedBg = [self colorNamed:"#b03030" fallback:"#aa0000"];
    colArmedFg = [self colorNamed:"#ffffff" fallback:"#ffffff"];
    colErrBg   = [self colorNamed:"#d07820" fallback:"#aa5500"];
    colErrFg   = [self colorNamed:"#101010" fallback:"#000000"];

    XSelectInput(dpy, win, ExposureMask | ButtonPressMask
                 | StructureNotifyMask);

    /* --- the chooser popup (created up front, mapped on demand) --- */
    XSetWindowAttributes dsa;
    dsa.override_redirect = True;   /* no WM interference */
    dsa.save_under         = True;  /* restore under us on unmap */
    dsa.background_pixel   = colBg;
    dsa.event_mask         = ExposureMask | ButtonPressMask
                             | PointerMotionMask | KeyPressMask;
    dlgWin = XCreateWindow(dpy, RootWindow(dpy, scr),
                           0, 0, DLG_W, DLG_H, 1,
                           CopyFromParent, InputOutput, CopyFromParent,
                           CWOverrideRedirect | CWSaveUnder
                           | CWBackPixel | CWEventMask,
                           &dsa);
    dlgBuf  = XCreatePixmap(dpy, dlgWin, DLG_W, DLG_H,
                            DefaultDepth(dpy, scr));
    dlgOpen     = NO;
    dlgHover    = 0;
    dlgDeadline = 0.0;

    armed     = ARM_NONE;
    blink     = YES;
    runner    = [[CommandRunner alloc] init];

    /* --- pick the right commands for this OS --- */
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    NSString *override;

    override = [env objectForKey:@"POWERDOCK_SLEEP"];
    if (override != nil) sleepCmd = [override copy]; else sleepCmd = nil;
    override = [env objectForKey:@"POWERDOCK_OFF"];
    if (override != nil) offCmd = [override copy]; else offCmd = nil;
    override = [env objectForKey:@"POWERDOCK_REBOOT"];
    if (override != nil) rebootCmd = [override copy]; else rebootCmd = nil;

    if (sleepCmd == nil || offCmd == nil || rebootCmd == nil) {
        BOOL hasSystemd =
            access("/usr/bin/systemctl", X_OK) == 0
            || access("/bin/systemctl", X_OK) == 0;

        if (hasSystemd) {                       /* Linux / systemd */
            if (sleepCmd   == nil) sleepCmd   = @"systemctl suspend";
            if (rebootCmd  == nil) rebootCmd  = @"systemctl reboot";
            if (offCmd     == nil) offCmd     = @"systemctl poweroff";
        } else {                                /* BSD family */
            if (sleepCmd   == nil) sleepCmd   = @"zzz";
            if (rebootCmd  == nil) rebootCmd  = @"shutdown -r now";
            if (offCmd     == nil) offCmd     = @"shutdown -p now";
        }
    }

    /* --- privilege wrapper for root-only commands ---
     *
     * On BSD, zzz/shutdown need root; on Linux/systemd, logind's polkit
     * rules let a normal user suspend/power off, so no prefix there.
     * Override with POWERDOCK_PRIV=none|sudo|doas|auto (default auto).
     */
    NSString *priv = [env objectForKey:@"POWERDOCK_PRIV"];
    if (priv == nil || [priv isEqualToString:@"auto"]) {
        BOOL isRoot     = (geteuid() == 0);
        BOOL hasSystemd = access("/usr/bin/systemctl", X_OK) == 0
                       || access("/bin/systemctl", X_OK) == 0;
        BOOL hasSudo    = access("/usr/local/bin/sudo", X_OK) == 0
                       || access("/usr/bin/sudo", X_OK) == 0;
        BOOL hasDoas    = access("/usr/local/bin/doas", X_OK) == 0
                       || access("/usr/bin/doas", X_OK) == 0;

        if (isRoot || hasSystemd) priv = @"none";
        else if (hasSudo)         priv = @"sudo";
        else if (hasDoas)         priv = @"doas";
        else                      priv = @"none";
    }
    if ([priv isEqualToString:@"none"]) {
        privPrefix = nil;
        NSLog(@"PowerDock: no privilege wrapper in use "
              "(POWERDOCK_PRIV=none|sudo|doas|auto)");
    } else {
        privPrefix = [priv copy];
        NSLog(@"PowerDock: prefixing commands with '%@'", privPrefix);
    }

    XMapWindow(dpy, win);
    [self draw];
    return self;
}

- (void)dealloc
{
    if (buf    != None) XFreePixmap(dpy, buf);
    if (dlgBuf != None) XFreePixmap(dpy, dlgBuf);
    if (dlgWin != None) XDestroyWindow(dpy, dlgWin);
    if (gc   != None) XFreeGC(dpy, gc);
    if (font != NULL) XFreeFont(dpy, font);
    XDestroyWindow(dpy, win);
    [runner release];
    [sleepCmd release];
    [offCmd release];
    [rebootCmd release];
    [privPrefix release];
    [checkedTask release];
    [super dealloc];
}

- (Window)window
{
    return win;
}

/* ---------- drawing ---------- */

/*
 * Idle:      dark tile, green power glyph (circle with a vertical stem).
 * Armed:     red tile, blinking "SURE?" plus the pending action name.
 */
- (void)draw
{
    double t      = nowSeconds();
    BOOL   isErr  = (failUntil > t);
    BOOL   isArmed = (armed != ARM_NONE) && !isErr;

    unsigned long bg  = isArmed ? colArmedBg : (isErr ? colErrBg : colBg);
    unsigned long fg  = isArmed ? colArmedFg : (isErr ? colErrFg : colGlyph);
    unsigned long brd = isArmed ? colArmedFg : colBorder;

    /* blink phase for armed/error state: inverted every other tick */
    if ((isArmed || isErr) && blink) {
        unsigned long tmp = bg;
        bg = fg;
        fg = tmp;
    }

    XSetForeground(dpy, gc, bg);
    XFillRectangle(dpy, buf, gc, 0, 0, WIN_SIZE, WIN_SIZE);

    XSetForeground(dpy, gc, brd);
    XDrawRectangle(dpy, buf, gc, 1, 1, WIN_SIZE - 3, WIN_SIZE - 3);

    XSetLineAttributes(dpy, gc, 3, LineSolid, CapButt, JoinMiter);
    XSetForeground(dpy, gc, fg);

    if (isErr) {
        [self drawCenteredString:"ERR!" atY:30];
        [self drawCenteredString:"FAILED" atY:46];
        XDrawRectangle(dpy, buf, gc, 4, 4, WIN_SIZE - 9, WIN_SIZE - 9);
    } else if (isArmed) {
        [self drawCenteredString:"SURE?" atY:28];
        const char *what = (armed == ARM_SLEEP)  ? "SLEEP"
                         : (armed == ARM_REBOOT) ? "REBOOT"
                         : "OFF";
        [self drawCenteredString:what atY:46];
        XDrawRectangle(dpy, buf, gc, 4, 4, WIN_SIZE - 9, WIN_SIZE - 9);
    } else {
        /* power glyph: circle with a gap at the top + vertical stem */
        XDrawArc(dpy, buf, gc, 20, 21, 24, 24, 135 * 64, 270 * 64);
        XDrawLine(dpy, buf, gc, 32, 13, 32, 32);
        [self drawCenteredString:"PWR" atY:58];
    }

    XSetLineAttributes(dpy, gc, 0, LineSolid, CapButt, JoinMiter);
    XCopyArea(dpy, buf, win, gc, 0, 0, WIN_SIZE, WIN_SIZE, 0, 0);
    XFlush(dpy);
}

/* ---------- actions ---------- */

- (NSString *)commandForAction:(ArmedAction)action
{
    switch (action) {
    case ARM_SLEEP:  return sleepCmd;
    case ARM_REBOOT: return rebootCmd;
    case ARM_OFF:    return offCmd;
    default:         return nil;
    }
}

- (void)arm:(ArmedAction)action
{
    armed         = action;
    armedDeadline = nowSeconds() + ARM_TIMEOUT;
    blink         = YES;
    [self draw];
}

- (void)disarm
{
    armed = ARM_NONE;
    [self draw];
}

- (void)execute:(ArmedAction)action
{
    NSString *cmd = [self commandForAction:action];
    if (cmd == nil) return;

    NSString *full = cmd;
    if (privPrefix != nil) {
        full = [NSString stringWithFormat:@"%@ %@", privPrefix, cmd];
    }
    NSLog(@"PowerDock: %@", full);
    [runner run:full];
    armed = ARM_NONE;
    [self draw];
}

- (void)handleButton:(XButtonEvent *)ev
{
    ArmedAction clicked = ARM_NONE;
    switch (ev->button) {
    case Button1:                          /* left: chooser dialog */
        if (armed != ARM_NONE) [self disarm];
        [self openDialog];
        return;
    case Button2: clicked = ARM_REBOOT; break;   /* middle */
    case Button3: clicked = ARM_OFF;    break;   /* right  */
    default:      return;                        /* wheel etc. */
    }

    if (armed == clicked) {
        [self execute:clicked];          /* confirmed */
    } else {
        [self arm:clicked];
    }
}

/* ---------- chooser dialog ---------- */

/* which button is at popup-local (x, y)?  0 = none, 1 = sleep, 2 = off */
- (int)dialogHitAtX:(int)x y:(int)y
{
    if (y < DLG_BTN_Y || y >= DLG_BTN_Y + DLG_BTN_H) return 0;
    if (x >= DLG_BTN1_X && x < DLG_BTN1_X + DLG_BTN_W) return 1;
    if (x >= DLG_BTN2_X && x < DLG_BTN2_X + DLG_BTN_W) return 2;
    return 0;
}

- (void)openDialog
{
    if (dlgWin == None || dlgOpen) return;

    /* position it centered on the monitor the pointer is on.
     * DisplayWidth/Height span all monitors in a multi-head setup, so
     * centering on them would put the popup across/in the wrong display. */
    int scr = DefaultScreen(dpy);
    int dx = (DisplayWidth(dpy, scr)  - DLG_W) / 2;
    int dy = (DisplayHeight(dpy, scr) - DLG_H) / 2;

    Window root = RootWindow(dpy, scr), child;
    int px, py, wx, wy;
    unsigned int mask;
    if (XQueryPointer(dpy, root, &root, &child,
                      &px, &py, &wx, &wy, &mask)) {
        int heads = 1;
        XineramaScreenInfo *xi = XineramaQueryScreens(dpy, &heads);
        if (xi != NULL && heads > 0) {
            int i;
            for (i = 0; i < heads; i++) {
                if (px >= xi[i].x_org && px <  xi[i].x_org + xi[i].width &&
                    py >= xi[i].y_org && py <  xi[i].y_org + xi[i].height) {
                    dx = xi[i].x_org + (xi[i].width  - DLG_W) / 2;
                    dy = xi[i].y_org + (xi[i].height - DLG_H) / 2;
                    break;
                }
            }
            XFree(xi);
        } else {
            /* no Xinerama: just center on the pointer and clamp */
            dx = px - DLG_W / 2;
            dy = py - DLG_H / 2;
        }
        if (dx < 0) dx = 0;
        if (dy < 0) dy = 0;
    }

    XMoveWindow(dpy, dlgWin, dx, dy);
    XMapRaised(dpy, dlgWin);

    dlgOpen     = YES;
    dlgHover    = 0;
    dlgDeadline = nowSeconds() + DLG_TIMEOUT;

    /* grab so stray clicks cannot reach other apps, and so a click
     * outside the popup (delivered here with out-of-bounds coords)
     * or an Escape keypress dismisses the dialog */
    XGrabPointer(dpy, dlgWin, False,
                 ButtonPressMask | PointerMotionMask,
                 GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
    XGrabKeyboard(dpy, dlgWin, False,
                  GrabModeAsync, GrabModeAsync, CurrentTime);
    [self drawDialog];
}

- (void)closeDialog
{
    if (!dlgOpen) return;
    dlgOpen = NO;
    XUngrabKeyboard(dpy, CurrentTime);
    XUngrabPointer(dpy, CurrentTime);
    XUnmapWindow(dpy, dlgWin);
    XFlush(dpy);
}

- (void)drawString:(const char *)s centeredInX:(int)cx width:(int)cw y:(int)y
{
    if (font == NULL) return;
    int len = strlen(s);
    int w = XTextWidth(font, s, len);
    XDrawString(dpy, dlgBuf, gc, cx + (cw - w) / 2, y, s, len);
}

- (void)drawDialogButton:(int)which label:(const char *)label accent:(unsigned long)accent
{
    int x = (which == 1) ? DLG_BTN1_X : DLG_BTN2_X;
    int y = DLG_BTN_Y;
    BOOL hovered = (dlgHover == which);

    unsigned long bg = hovered ? accent : colBg;
    unsigned long fg = hovered ? colBg  : accent;

    XSetForeground(dpy, gc, bg);
    XFillRectangle(dpy, dlgBuf, gc, x, y, DLG_BTN_W, DLG_BTN_H);
    XSetForeground(dpy, gc, fg);
    XDrawRectangle(dpy, dlgBuf, gc, x + 1, y + 1,
                   DLG_BTN_W - 3, DLG_BTN_H - 3);
    [self drawString:label centeredInX:x width:DLG_BTN_W
                  y:y + (DLG_BTN_H + (font ? font->ascent : 0)) / 2 - 1];
}

- (void)drawDialog
{
    if (dlgWin == None) return;

    XSetForeground(dpy, gc, colBg);
    XFillRectangle(dpy, dlgBuf, gc, 0, 0, DLG_W, DLG_H);
    XSetForeground(dpy, gc, colBorder);
    XDrawRectangle(dpy, dlgBuf, gc, 1, 1, DLG_W - 3, DLG_H - 3);

    XSetForeground(dpy, gc, colGlyph);
    [self drawString:"Choose action:" centeredInX:0 width:DLG_W y:17];

    [self drawDialogButton:1 label:"SLEEP"      accent:colGlyph];
    [self drawDialogButton:2 label:"SHUT DOWN"  accent:colArmedBg];

    XCopyArea(dpy, dlgBuf, dlgWin, gc, 0, 0, DLG_W, DLG_H, 0, 0);
    XFlush(dpy);
}

- (void)handleDialogPress:(XButtonEvent *)ev
{
    int hit = [self dialogHitAtX:ev->x y:ev->y];
    [self closeDialog];                 /* any click ends the dialog */

    if (ev->button != Button1) return;  /* non-left click = cancel */
    if (hit == 1) [self execute:ARM_SLEEP];
    if (hit == 2) [self execute:ARM_OFF];
    /* hit == 0 (outside the buttons, but inside the grab): just cancel */
}

- (void)handleEvent:(XEvent *)ev
{
    switch (ev->type) {
    case Expose:
        if (ev->xexpose.window == dlgWin) {
            if (ev->xexpose.count == 0) [self drawDialog];
        } else if (ev->xexpose.count == 0) {
            [self draw];
        }
        break;
    case ButtonPress:
        if (dlgOpen && ev->xbutton.window == dlgWin) {
            [self handleDialogPress:&ev->xbutton];
        } else {
            [self handleButton:&ev->xbutton];
        }
        break;
    case KeyPress:
        if (dlgOpen
            && ev->xkey.keycode == XKeysymToKeycode(dpy, XK_Escape)) {
            [self closeDialog];
        }
        break;
    case MotionNotify:
        if (dlgOpen && ev->xmotion.window == dlgWin) {
            int h = [self dialogHitAtX:ev->xmotion.x y:ev->xmotion.y];
            if (h != dlgHover) {
                dlgHover = h;
                [self drawDialog];
            }
        }
        break;
    default:
        break;
    }
}

- (void)tick
{
    /* chooser dialog auto-dismiss */
    if (dlgOpen && nowSeconds() >= dlgDeadline) {
        [self closeDialog];
    }

    /* error flash expiry */
    if (failUntil > 0 && nowSeconds() >= failUntil) {
        failUntil = 0;
        [self draw];
    }

    /* did the last launched command exit with a failure? */
    NSTask *t = [runner lastTask];
    if (t != nil && t != checkedTask && ![t isRunning]) {
        [checkedTask release];
        checkedTask = [t retain];
        if ([t terminationStatus] != 0) {
            failUntil = nowSeconds() + 3.0;
            blink = YES;
            NSLog(@"PowerDock: command failed (exit status %d)",
                  (int)[t terminationStatus]);
            [self draw];
        }
    }

    if (armed == ARM_NONE) return;

    double now = nowSeconds();
    if (now >= armedDeadline) {
        [self disarm];
        return;
    }
    blink = !blink;                      /* ~4 Hz via suggestedTimeout */
    [self draw];
}

- (double)suggestedTimeout
{
    double t = 0.0;

    if (dlgOpen) {
        double remain = dlgDeadline - nowSeconds();
        t = (remain < 0.0) ? 0.01 : remain;
    }

    if (armed == ARM_NONE && failUntil == 0) return t;  /* block, or dlg */

    double blinkT = 0.25;
    if (armed == ARM_NONE) {
        /* error flash blinking */
        return (t > 0.0 && t < blinkT) ? t : blinkT;
    }

    double remain = armedDeadline - nowSeconds();
    if (remain < blinkT) blinkT = remain;
    return (t > 0.0 && t < blinkT) ? t : blinkT;
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
        fprintf(stderr, "powerdock: cannot open display "
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
        struct timeval tv, *tvp = NULL;
        if (t > 0.0) {
            tv.tv_sec  = (time_t)t;
            tv.tv_usec = (suseconds_t)((t - tv.tv_sec) * 1e6);
            tvp = &tv;
        }

        int r = select(xfd + 1, &fds, NULL, NULL, tvp);
        if (r < 0 && errno != EINTR) {
            perror("powerdock: select");
            break;
        }

        if (r == 0 || t == 0.0) {
            /* timeout fired, or nothing pending: housekeeping */
            [app tick];
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
        }

        [loopPool release];
    }

    XCloseDisplay(dpy);
    [app release];
    [pool release];
    return 0;
}