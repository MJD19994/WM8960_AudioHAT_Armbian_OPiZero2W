# Echo Canceller for WM8960 Audio HAT
# Based on voice-engine/ec (GPLv3)

CC := gcc
CXX := g++
CFLAGS += -Isrc -Wall -std=gnu99 -O3 -MMD -MP
LDLIBS += -ldl -lm -lrt -lpthread -lasound $(shell pkg-config --libs speexdsp)

SRCDIR := src
OBJ := $(SRCDIR)/ec.o $(SRCDIR)/audio.o $(SRCDIR)/fifo.o \
       $(SRCDIR)/pa_ringbuffer.o $(SRCDIR)/util.o
DEPS := $(OBJ:.o=.d)

PREFIX ?= /usr/local

all: wm8960-ec

wm8960-ec: $(OBJ)
	$(CXX) $(OBJ) $(LDLIBS) -o $@

$(SRCDIR)/%.o: $(SRCDIR)/%.c
	$(CC) $(CFLAGS) -c $< -o $@

install: wm8960-ec
	install -D -m 755 wm8960-ec $(PREFIX)/bin/wm8960-ec

uninstall:
	rm -f $(PREFIX)/bin/wm8960-ec

clean:
	rm -f $(SRCDIR)/*.o $(SRCDIR)/*.d wm8960-ec

-include $(DEPS)

.PHONY: all install uninstall clean
