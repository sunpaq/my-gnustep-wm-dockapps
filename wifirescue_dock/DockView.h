/*
 * DockView.h - 64x64 Window Maker dockapp window (Xlib).
 */

#import <Foundation/Foundation.h>
#import <X11/Xlib.h>
#import "WiFiRescue.h"
#import <X11/Xutil.h>

@class WiFiController;

@interface DockView : NSObject {
    Display       *_dpy;
    Window         _win;          /* withdrawn top-level window  */
    Window         _iconWin;      /* the actual 64x64 dockapp    */
    GC             _gc;
    unsigned long  _colGreen, _colRed, _colYellow, _colGray, _colBg;
    XFontStruct   *_fontStruct;    /* kept alive for the whole app */
    WiFiController *_ctrl;
    WifiStatus     _lastDrawn;    /* avoid needless redraws      */
    int            _wakePipe[2];  /* nudge the event loop        */
}

- (instancetype)initWithController:(WiFiController *)controller;
- (int)xConnectionNumber;
- (int)wakeReadFD;                /* fd to poll() for wakeups   */
- (void)processXEvents;           /* drain pending X events     */
- (void)refresh;                  /* redraw if status changed   */
- (void)sendWake;                 /* thread-safe loop nudge     */

@end