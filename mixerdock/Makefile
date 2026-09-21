# MixerDock — Window Maker dock app (C + Xlib)
#
# Self-contained Makefile, same style as the other dev/*dock projects.
# Works with GNU make and BSD make.

X11_CFLAGS = -I/usr/local/include
X11_LIBS   = -L/usr/local/lib -lX11

CC   ?= cc
CFLAGS ?= -O2 -Wall
SRC  = mixer_dockapp.c
BIN  = mixer_dockapp

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) $(X11_CFLAGS) -o $(BIN) $(SRC) $(X11_LIBS)

clean:
	rm -f $(BIN)

run: $(BIN)
	./$(BIN) &

.PHONY: all clean run