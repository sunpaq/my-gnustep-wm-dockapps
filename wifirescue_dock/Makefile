# wifirescue_dock - Window Maker dockapp (Objective-C + Xlib + GNUstep Base)

GNUSTEP_SH := /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh
CC      := clang
OBJCFLAGS := $(shell . $(GNUSTEP_SH) && gnustep-config --objc-flags) \
             -Wall
GSLIBS  := -L/usr/local/GNUstep/System/Library/Libraries \
           -lgnustep-base -lobjc
XLIBS   := -L/usr/local/lib -lX11

OBJS    := main.o WiFiController.o DockView.o

all: wifirescue_dock

wifirescue_dock: $(OBJS)
	$(CC) -o $@ $(OBJS) $(XLIBS) $(GSLIBS) -lpthread

%.o: %.m WiFiRescue.h
	$(CC) $(OBJCFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) wifirescue_dock

.PHONY: all clean