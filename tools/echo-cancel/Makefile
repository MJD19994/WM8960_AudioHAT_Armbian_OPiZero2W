# Echo Canceller for WM8960 Audio HAT
# Two implementations:
#   wm8960-ec        — SpeexDSP, FIFO-based (works without snd-aloop)
#   wm8960-ec-webrtc — WebRTC AEC3, loopback-based (requires snd-aloop)

CC := gcc
CXX := g++
CFLAGS += -Isrc -Wall -std=gnu99 -O3 -MMD -MP
CXXFLAGS += -Isrc -Wall -std=c++17 -O3 -MMD -MP \
    $(shell pkg-config --cflags webrtc-audio-processing-1)
LDLIBS_SPEEX := -ldl -lm -lrt -lpthread -lasound $(shell pkg-config --libs speexdsp)
LDLIBS_WEBRTC := -lasound \
    $(shell pkg-config --libs webrtc-audio-processing-1)

SRCDIR := src

# SpeexDSP: uses shared audio.c (ring buffer threads + FIFOs)
SPEEX_OBJ := $(SRCDIR)/ec.o $(SRCDIR)/audio.o $(SRCDIR)/fifo.o \
             $(SRCDIR)/pa_ringbuffer.o $(SRCDIR)/util.o

# WebRTC: self-contained, reads from ALSA loopback (no FIFOs/ring buffers)
WEBRTC_OBJ := $(SRCDIR)/ec_webrtc.o

PREFIX ?= /usr/local

all: wm8960-ec wm8960-ec-webrtc

speex: wm8960-ec
webrtc: wm8960-ec-webrtc

wm8960-ec: $(SPEEX_OBJ)
	$(CXX) $(SPEEX_OBJ) $(LDLIBS_SPEEX) -o $@

wm8960-ec-webrtc: $(WEBRTC_OBJ)
	$(CXX) $(WEBRTC_OBJ) $(LDLIBS_WEBRTC) -o $@

$(SRCDIR)/%.o: $(SRCDIR)/%.c
	$(CC) $(CFLAGS) -c $< -o $@

$(SRCDIR)/%.o: $(SRCDIR)/%.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

INSTALL_TARGETS ?= wm8960-ec wm8960-ec-webrtc

install: $(INSTALL_TARGETS)
	for bin in $(INSTALL_TARGETS); do \
		install -D -m 755 $$bin $(PREFIX)/bin/$$bin; \
	done

uninstall:
	for bin in $(INSTALL_TARGETS); do \
		rm -f $(PREFIX)/bin/$$bin; \
	done

clean:
	rm -f $(SRCDIR)/*.o $(SRCDIR)/*.d wm8960-ec wm8960-ec-webrtc

-include $(wildcard $(SRCDIR)/*.d)

.PHONY: all speex webrtc install uninstall clean
