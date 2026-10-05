# Citrine PS2SDK Makefile
# Builds the pre-compiled PS2 runner ELF: bin/citrine_runner.elf

EE_BIN = bin/citrine_runner.elf
EE_OBJS = src/citrine_vm.o src/citrine_core.o src/citrine_draw2d.o \
          src/citrine_draw3d.o src/citrine_gl.o src/citrine_input.o src/citrine_audio.o \
          src/citrine_video.o src/citrine_hud.o src/citrine_panic.o src/main.o

EE_INCS := -Iinclude -I$(PS2SDK)/ee/include -I$(PS2SDK)/common/include
EE_CFLAGS := -O3 -fno-strict-aliasing -Wall -Wextra
EE_LDFLAGS := -L$(PS2SDK)/ee/lib
EE_LIBS := -lpad -lgraph -ldma -lpacket2 -ldebug -lc -lm

all: $(EE_BIN)

clean:
	rm -f $(EE_OBJS) $(EE_BIN) bin/test_host.exe tests/test_host.o

# Include standard PS2SDK Makefile rules if PS2SDK is defined
ifneq ($(PS2SDK),)
include $(PS2SDK)/samples/Makefile.pref
include $(PS2SDK)/samples/Makefile.eeglobal
else
# Host build fallback (for syntax and sanity checking)
CC ?= gcc
CFLAGS = -Wall -Wextra -std=c99 -DHOST_TEST_BUILD -Iinclude

$(EE_BIN): $(EE_OBJS)
	mkdir -p bin
	$(CC) $(EE_OBJS) -o $(EE_BIN) -lm

test_host: bin/test_host.exe

bin/test_host.exe: tests/test_host.c src/citrine_vm.c src/citrine_core.c src/citrine_draw2d.c src/citrine_draw3d.c src/citrine_gl.c src/citrine_input.c src/citrine_audio.c src/citrine_video.c src/citrine_hud.c src/citrine_panic.c
	mkdir -p bin
	$(CC) $(CFLAGS) $^ -o $@ -lm

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
endif
