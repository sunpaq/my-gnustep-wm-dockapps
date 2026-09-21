/*
 * mixer_dockapp.c - WindowMaker dock app for mixer(8)
 *
 * Shows the current volume (vol control) as a percentage in a 64x64
 * dockapp, with a speaker symbol and a level bar.
 *   Left click  (button 1): decrease volume by 10%
 *   Right click (button 3): increase volume by 10%
 *   Middle click (button 2): toggle mute (bar turns gray while muted)
 *
 * Build:  cc -O2 -o mixer_dockapp mixer_dockapp.c \
 *             -I/usr/local/include -L/usr/local/lib -lX11
 * Run:    ./mixer_dockapp &     (then drag it onto the WindowMaker dock)
 */

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/select.h>

#define WIN_SIZE   64
#define STEP       10
#define POLL_SEC   10   /* periodic refresh so external changes show up */

/* Palette matching wm-wifi-rescue (same as backlight_dockapp) */
#define COL_BG     "#202028"   /* dark charcoal */
#define COL_GREEN  "#3ddc5a"   /* green         */
#define COL_GRAY   "#9a9aa5"   /* gray border / muted bar */

/* ---------- mixer(8) interface ---------- */

/* Read current volume of the "vol" control; returns 0..100, or -1. */
static int volume_get(void)
{
	FILE *fp = popen("mixer vol.volume 2>/dev/null", "r");
	char buf[256];
	int val = -1;

	if (!fp)
		return -1;
	while (fgets(buf, sizeof(buf), fp)) {
		/* new mixer: "vol.volume=0.50:0.50" (left:right) */
		char *p = strstr(buf, "vol.volume=");
		if (p)
			val = (int)(atof(p + strlen("vol.volume="))
			    * 100.0 + 0.5);
	}
	pclose(fp);
	if (val < 0)
		val = 0;
	if (val > 100)
		val = 100;
	return val;
}

/* Is the "vol" control muted?  Returns 1 muted, 0 not, -1 unknown. */
static int muted_get(void)
{
	FILE *fp = popen("mixer vol.mute 2>/dev/null", "r");
	char buf[256];
	int state = -1;

	if (!fp)
		return -1;
	while (fgets(buf, sizeof(buf), fp)) {
		char *p = strstr(buf, "vol.mute=");
		if (p) {
			p += strlen("vol.mute=");
			if (strncmp(p, "on", 2) == 0)
				state = 1;
			else if (strncmp(p, "off", 3) == 0)
				state = 0;
		}
	}
	pclose(fp);
	return state;
}

/* Set volume of the "vol" control to an absolute 0..100 value. */
static void volume_set(int val)
{
	char cmd[64];
	if (val < 0)
		val = 0;
	if (val > 100)
		val = 100;
	snprintf(cmd, sizeof(cmd),
	    "mixer vol.volume=%d.%02d >/dev/null 2>&1", val / 100,
	    val % 100);
	if (system(cmd) == -1)
		return; /* ignore */
}

/* Set mute state of the "vol" control. */
static void mute_set(int on)
{
	char cmd[64];
	snprintf(cmd, sizeof(cmd),
	    "mixer vol.mute=%s >/dev/null 2>&1", on ? "on" : "off");
	if (system(cmd) == -1)
		return; /* ignore */
}

/* ---------- dockapp ---------- */

int main(void)
{
	Display *dpy = XOpenDisplay(NULL);
	if (!dpy) {
		fprintf(stderr, "mixer_dockapp: cannot open display\n");
		return 1;
	}

	int screen = DefaultScreen(dpy);
	Window root = RootWindow(dpy, screen);
	unsigned long bg = WhitePixel(dpy, screen);

	Window win = XCreateSimpleWindow(dpy, root, 0, 0, WIN_SIZE, WIN_SIZE,
	    1, BlackPixel(dpy, screen), bg);

	/* Look like a proper dockapp so WindowMaker can dock it */
	XClassHint ch = { "mixer_dockapp", "DockApp" };
	XSetClassHint(dpy, win, &ch);

	XWMHints hints;
	memset(&hints, 0, sizeof(hints));
	hints.flags = InputHint | StateHint | IconWindowHint | WindowGroupHint;
	hints.input = True;
	hints.initial_state = WithdrawnState;
	hints.icon_window = win;
	hints.window_group = win;
	XSetWMHints(dpy, win, &hints);

	/* WM_NAME for identification */
	XStoreName(dpy, win, "mixer_dockapp");
	XSetWMProtocols(dpy, win,
	    &(Atom){ XInternAtom(dpy, "WM_DELETE_WINDOW", False) }, 1);

	XSelectInput(dpy, win, ExposureMask | ButtonPressMask);

	XFontStruct *font_big = XLoadQueryFont(dpy,
	    "-*-helvetica-bold-r-*-*-20-*-*-*-*-*-*-*");
	if (!font_big)
		font_big = XLoadQueryFont(dpy, "fixed");
	XFontStruct *font_small = XLoadQueryFont(dpy,
	    "-*-helvetica-medium-r-*-*-10-*-*-*-*-*-*-*");
	if (!font_small)
		font_small = font_big;

	XGCValues gcv;
	GC gc = XCreateGC(dpy, win, 0, &gcv);

	/* Load the wm-wifi-rescue palette (fall back to black/white) */
	Colormap cmap = DefaultColormap(dpy, screen);
	XColor col, dummy;
	unsigned long fg, border, gray;
	fg = border = BlackPixel(dpy, screen);
	gray = border;
#define COLOR(spec, dst) \
	if (XAllocNamedColor(dpy, cmap, spec, &col, &dummy)) dst = col.pixel
	COLOR(COL_BG, bg);
	COLOR(COL_GREEN, fg);
	COLOR(COL_GRAY, gray);
	COLOR(COL_GRAY, border);
#undef COLOR
	XSetWindowBackground(dpy, win, bg);
	XSetWindowBorder(dpy, win, border);

	Window w2;
	int x, y;
	unsigned int w, h, bw, depth;
	XGetGeometry(dpy, win, &w2, &x, &y, &w, &h, &bw, &depth);
	Pixmap pm = XCreatePixmap(dpy, win, w, h, depth);

	int volume = volume_get();
	int muted = muted_get();
	int last_volume = -1;
	int last_muted = -1;

	XMapWindow(dpy, win);

	for (;;) {
		fd_set fds;
		struct timeval tv;
		FD_ZERO(&fds);
		FD_SET(ConnectionNumber(dpy), &fds);
		tv.tv_sec = POLL_SEC;
		tv.tv_usec = 0;

		if (select(ConnectionNumber(dpy) + 1, &fds, NULL, NULL,
		    &tv) < 0)
			break;

		if (FD_ISSET(ConnectionNumber(dpy), &fds)) {
			while (XPending(dpy)) {
				XEvent ev;
				XNextEvent(dpy, &ev);

				switch (ev.type) {
				case Expose:
					if (ev.xexpose.count == 0)
						last_volume = -1;
					break;
				case ButtonPress:
					if (ev.xbutton.button == Button1) {
						/* mixer has no relative
						 * ops: read, adjust, set */
						int cur = volume_get();
						if (cur >= 0)
							volume = cur;
						if (muted) {
							/* unmuting: restore
							 * audible level */
							mute_set(0);
							if (volume == 0)
								volume = STEP;
							volume_set(volume);
						} else
							volume_set(volume -
							    STEP);
						volume = volume_get();
						muted = muted_get();
					} else if (ev.xbutton.button ==
					    Button3) {
						int cur = volume_get();
						if (cur >= 0)
							volume = cur;
						if (muted)
							mute_set(0);
						volume_set(volume + STEP);
						volume = volume_get();
						muted = muted_get();
					} else if (ev.xbutton.button ==
					    Button2) {
						int m = muted_get();
						if (m == 0)
							mute_set(1);
						else if (m == 1)
							mute_set(0);
						muted = muted_get();
					}
					break;
				case ClientMessage:
					/* WM_DELETE_WINDOW */
					goto out;
				}
			}
		} else {
			/* timer: poll for external changes */
			int cur = volume_get();
			if (cur >= 0)
				volume = cur;
			int m = muted_get();
			if (m >= 0)
				muted = m;
		}

		if (volume != last_volume || muted != last_muted) {
			char pct[8];
			snprintf(pct, sizeof(pct), "%d%%", volume);

			/* background */
			XSetForeground(dpy, gc, bg);
			XFillRectangle(dpy, pm, gc, 0, 0, w, h);

			/* thin border around the tile, like PowerDock */
			XSetForeground(dpy, gc, border);
			XDrawRectangle(dpy, pm, gc, 1, 1, w - 3, h - 3);

			/* speaker symbol: nub + symmetric cone, top center */
			unsigned long barcol = muted ? gray : fg;
			XSetForeground(dpy, gc, barcol);
			XFillRectangle(dpy, pm, gc, w / 2 - 8, 10, 4, 8);
			XPoint cone[4];
			cone[0].x = w / 2 - 4; cone[0].y = 10;
			cone[1].x = w / 2 - 4; cone[1].y = 18;
			cone[2].x = w / 2 + 4; cone[2].y = 23;
			cone[3].x = w / 2 + 4; cone[3].y = 5;
			XFillPolygon(dpy, pm, gc, cone, 4, Convex,
			    CoordModeOrigin);
			if (!muted) {
				/* two sound arcs */
				XDrawArc(dpy, pm, gc, w / 2 + 4, 9, 8, 10,
				    -50 * 64, 100 * 64);
				XDrawArc(dpy, pm, gc, w / 2 + 7, 7, 8, 14,
				    -50 * 64, 100 * 64);
			}

			/* percentage, centered */
			XSetForeground(dpy, gc, fg);
			int tw = XTextWidth(font_big, pct,
			    (int)strlen(pct));
			XDrawString(dpy, pm, gc,
			    (w - tw) / 2, 24 + font_big->ascent, pct,
			    (int)strlen(pct));

			/* level bar */
			int bx = 8, by = h - 20, bwd = w - 16, bht = 8;
			XDrawRectangle(dpy, pm, gc, bx - 1, by - 1,
			    bwd + 1, bht + 1);
			XSetForeground(dpy, gc, barcol);
			XFillRectangle(dpy, pm, gc, bx, by,
			    muted ? 0 : bwd * volume / 100, bht);

			XCopyArea(dpy, pm, win, gc, 0, 0, w, h, 0, 0);
			XFlush(dpy);
			last_volume = volume;
			last_muted = muted;
		}
	}

out:
	XFreePixmap(dpy, pm);
	XFreeGC(dpy, gc);
	if (font_big)
		XUnloadFont(dpy, font_big->fid);
	if (font_small)
		XUnloadFont(dpy, font_small->fid);
	XDestroyWindow(dpy, win);
	XCloseDisplay(dpy);
	return 0;
}