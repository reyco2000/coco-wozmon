LWASM ?= lwasm
SRC   := src/wozmon.asm
SRCC  := src/wozmon-cursor.asm

# wozmon.*  = plain, faithful to the original (no cursor)
# wozmonc.* = same monitor with a blinking @ cursor
all: build/wozmon.bin build/wozmon.ccc build/wozmonc.bin build/wozmonc.ccc

build:
	mkdir -p build

build/wozmon.bin: $(SRC) | build
	$(LWASM) --format=decb -DTARGET=0 --output=$@ --map=build/wozmon.bin.map $(SRC)

build/wozmon.ccc: $(SRC) | build
	$(LWASM) --format=raw -DTARGET=1 --output=$@ --map=build/wozmon.ccc.map $(SRC)

build/wozmonc.bin: $(SRCC) | build
	$(LWASM) --format=decb -DTARGET=0 --output=$@ --map=build/wozmonc.bin.map $(SRCC)

build/wozmonc.ccc: $(SRCC) | build
	$(LWASM) --format=raw -DTARGET=1 --output=$@ --map=build/wozmonc.ccc.map $(SRCC)

test:
	.venv/bin/pytest tests/ -v

clean:
	rm -rf build

.PHONY: all test clean
