# Citrine PS2SDK Makefile
# Builds the pre-compiled PS2 runner ELF: bin/citrine_runner.elf

EE_BIN = bin/citrine_runner.elf
EE_OBJS = src/citrine_vm.o src/citrine_core.o src/citrine_draw2d.o \
          src/citrine_draw3d.o src/citrine_gl.o src/citrine_input.o src/citrine_audio.o \
          src/citrine_hud.o src/citrine_panic.o src/main.o

EE_INCS := -Iinclude -I$(PS2SDK)/ee/include -I$(PS2SDK)/common/include
EE_CFLAGS := -O3 -fno-strict-aliasing -Wall -Wextra
EE_LDFLAGS := -L$(PS2SDK)/ee/lib
EE_LIBS := -lpad -lgraph -ldma -lpacket2 -ldebug -lc -lm

all: $(EE_BIN)

clean:
	rm -f $(EE_OBJS) $(EE_BIN)

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

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
endif
