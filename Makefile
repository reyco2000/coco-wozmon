LWASM ?= lwasm
SRC   := src/wozmon.asm
SRCC  := src/wozmon-cursor.asm

# wozmon.*  = plain, faithful to the original (no cursor)
# wozmonc.* = same monitor with a blinking @ cursor
all: build/wozmon.bin build/wozmon.rom build/wozmonc.bin build/wozmonc.rom

build:
	mkdir -p build

build/wozmon.bin: $(SRC) | build
	$(LWASM) --format=decb -DTARGET=0 --output=$@ --map=build/wozmon.bin.map $(SRC)

build/wozmon.rom: $(SRC) | build
	$(LWASM) --format=raw -DTARGET=1 --output=$@ --map=build/wozmon.rom.map $(SRC)

build/wozmonc.bin: $(SRCC) | build
	$(LWASM) --format=decb -DTARGET=0 --output=$@ --map=build/wozmonc.bin.map $(SRCC)

build/wozmonc.rom: $(SRCC) | build
	$(LWASM) --format=raw -DTARGET=1 --output=$@ --map=build/wozmonc.rom.map $(SRCC)

test:
	.venv/bin/pytest tests/ -v

clean:
	rm -rf build

.PHONY: all test clean
