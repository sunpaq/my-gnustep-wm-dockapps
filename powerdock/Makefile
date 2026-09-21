# PowerDock — Window Maker dock app in Objective-C
#
# Self-contained Makefile: pulls the GNUstep Foundation flags from
# gnustep-config and links against X11.  Works with GNU make and BSD make.

GNUSTEP_SH = /usr/local/GNUstep/System/Library/Makefiles/GNUstep.sh

OBJC_FLAGS := $(shell . $(GNUSTEP_SH) && gnustep-config --objc-flags)
BASE_LIBS  := $(shell . $(GNUSTEP_SH) && gnustep-config --base-libs)
X11_CFLAGS := $(shell pkg-config --cflags x11 2>/dev/null || echo -I/usr/local/include)
X11_LIBS   := $(shell pkg-config --libs x11 2>/dev/null || echo -L/usr/local/lib -lX11) -lXinerama

CC  = clang
SRC = PowerDock.m
BIN = powerdock

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(OBJC_FLAGS) $(X11_CFLAGS) -o $(BIN) $(SRC) $(BASE_LIBS) $(X11_LIBS)

clean:
	rm -f $(BIN) *.d

run: $(BIN)
	./$(BIN) &

.PHONY: all clean run