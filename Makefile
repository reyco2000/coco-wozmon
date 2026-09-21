LWASM ?= lwasm
SRC   := src/wozmon.asm

all: build/wozmon.bin build/wozmon.rom

build:
	mkdir -p build

build/wozmon.bin: $(SRC) | build
	$(LWASM) --format=decb -DTARGET=0 --output=$@ --map=build/wozmon.bin.map $(SRC)

build/wozmon.rom: $(SRC) | build
	$(LWASM) --format=raw -DTARGET=1 --output=$@ --map=build/wozmon.rom.map $(SRC)

test:
	.venv/bin/pytest tests/ -v

clean:
	rm -rf build

.PHONY: all test clean
