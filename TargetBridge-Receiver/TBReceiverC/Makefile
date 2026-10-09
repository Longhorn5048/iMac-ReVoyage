# TBReceiver pure-C build (macOS target).
#
# Prerequisites on the iMac (Intel) running OCLP macOS 14:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#   brew install ffmpeg sdl2 pkgconf
#
# Build:
#   make
#
# Run:
#   ./tbreceiver              # fullscreen
#   ./tbreceiver --windowed   # debug windowed
#
# Linux target (later): identical sources, swap LDFLAGS to pkgconf on
#   libavcodec libavutil sdl2 ; drop -framework lines.

CC       ?= clang
PKG      ?= pkgconf
APP_VERSION ?= 3.2.0
APP_BUILD   ?= dev

MACOSX_DEPLOYMENT_TARGET ?= 11.0
export MACOSX_DEPLOYMENT_TARGET

CFLAGS   += -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
CFLAGS   += $(shell $(PKG) --cflags libavcodec libavutil sdl2)
CFLAGS   += -DTB_RECEIVER_VERSION=\"$(APP_VERSION)\" -DTB_RECEIVER_BUILD=\"$(APP_BUILD)\"
CFLAGS   += '-DTB_LANGUAGE_SOURCE_DIR="$(abspath ../../TargetBridge-Shared/Languages)"'

LDFLAGS  += $(shell $(PKG) --libs libavcodec libavutil sdl2)

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS  += -framework ApplicationServices -framework AppKit -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework IOKit
endif

C_SRC = src/main.c src/net.c src/decoder.c src/display.c src/tb_i18n.c ../../RescueReceiver/DisplaySignalState.c
OBJC_SRC = src/tb_gesture_bridge.m
OBJ = $(C_SRC:.c=.o) $(OBJC_SRC:.m=.o)
BIN = tbreceiver

all: $(BIN)

../../RescueReceiver/DisplaySignalState.o: ../../RescueReceiver/DisplaySignalState.h

src/display.o: src/display.h src/tb_gesture_bridge.h ../../TargetBridge-Shared/ReceiverDebug.h

src/main.o: src/display.h src/decoder.h src/tb_gesture_bridge.h ../../RescueReceiver/DisplaySignalState.h src/control_send.h src/audio_ring.h src/session_auth.h src/receiver_identity.h src/input_permissions.h src/proto.h ../../TargetBridge-Shared/DisplayPower.h
src/main.o: ../../TargetBridge-Shared/LocalConnection.h ../../TargetBridge-Shared/ReceiverDebug.h src/stream_stats.h

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.m
	$(CC) $(CFLAGS) -fobjc-arc -c -o $@ $<

clean:
	rm -f $(OBJ) $(BIN) $(TEST_BIN) test_decoder_failures test_session_gate test_display_profile

# Unit tests for the packet parser. net.c is pure POSIX, so this needs no
# ffmpeg/SDL/pkgconf — it runs anywhere, including CI, with no hardware.
TEST_CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
TEST_BIN = test_net_parser test_audio_ring test_session_auth test_control_send test_receiver_identity test_input_permissions test_receiver_debug

test_receiver_debug: tests/test_receiver_debug.c src/stream_stats.h ../../TargetBridge-Shared/ReceiverDebug.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_debug.c -o $@

test_input_permissions: tests/test_input_permissions.c src/input_permissions.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_input_permissions.c -o $@

test_net_parser: tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c -o $@

test_receiver_identity: tests/test_receiver_identity.c src/receiver_identity.h src/session_auth.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_identity.c -o $@

test_control_send: tests/test_control_send.c src/control_send.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_control_send.c -o $@

test_audio_ring: tests/test_audio_ring.c src/audio_ring.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_audio_ring.c -o $@

test_session_auth: tests/test_session_auth.c src/session_auth.h src/receiver_identity.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_session_auth.c -o $@

# Optional decoder failure-path tests need the normal FFmpeg build dependencies.
test_decoder_failures: tests/test_decoder_failures.c src/decoder.c src/decoder.h
	$(CC) $(CFLAGS) tests/test_decoder_failures.c -o $@ $(LDFLAGS)

test-decoder: test_decoder_failures
	./test_decoder_failures

test_session_gate: ../../TargetBridge-Shared/LocalConnection.h ../../TargetBridge-Shared/ReceiverDebug.h src/stream_stats.h tests/test_session_gate.c ../../RescueReceiver/DisplaySignalState.h src/main.c src/session_auth.h src/input_permissions.h ../../TargetBridge-Shared/DisplayPower.h $(filter-out src/main.o,$(OBJ))
	$(CC) $(CFLAGS) tests/test_session_gate.c $(filter-out src/main.o,$(OBJ)) -o $@ $(LDFLAGS)

test-session-gate: test_session_gate
	./test_session_gate

test: $(TEST_BIN)
	./test_net_parser
	./test_audio_ring
	./test_session_auth
	./test_control_send
	./test_receiver_identity
	./test_input_permissions
	./test_receiver_debug

.PHONY: all clean test test-decoder test-session-gate

test_display_profile: tests/test_display_profile.c src/display.c $(filter-out src/main.o src/display.o,$(OBJ))
	$(CC) $(CFLAGS) tests/test_display_profile.c $(filter-out src/main.o src/display.o,$(OBJ)) -o $@ $(LDFLAGS)

test-display-profile: test_display_profile
	./test_display_profile
