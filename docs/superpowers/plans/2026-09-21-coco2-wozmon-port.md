# CoCo 2 Wozmon Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Apple I monitor (Wozmon) from 6502 to 6809, running on a TRS-80 Color Computer 2, built from one source file into both a DECB loadable binary and an autostart 8K cartridge ROM.

**Architecture:** A single `src/wozmon.asm` with a `TARGET` equate selecting origin, workspace address, and stack setup. Variables live in a page-aligned workspace addressed through the DP register. All hardware access is confined to two routines, `GETKEY` and `PUTCHAR`. Everything is developed test-first against a host-side 6809 emulator that simulates the CoCo's PIA keyboard matrix and VDG text screen.

**Tech Stack:** lwasm 4.22 (lwtools), MC6809 0.9.0 (Python 6809 emulator), pytest 9.1.1, Python 3.13.

**Spec:** `docs/superpowers/specs/2026-09-21-coco2-wozmon-port-design.md`

## Global Constraints

- Command set is **faithful 1:1** to the original: `XXXX`, `XXXX.YYYY`, `XXXX: bb bb`, `R`. Nothing else. No exit path in either build.
- `MODE` byte values are exactly `$00` XAM, `$74` STOR, `$AE` BLOCK.
- Dump format is exactly `XXXX: bb bb bb bb bb bb bb bb`, 8 bytes per line, new line when `XAM AND 7 == 0`.
- Interrupts are masked with `ORCC #$50` in both builds. Never enable them.
- 16-bit workspace values are **6809 big-endian** — high byte at the lower address. The hex shift is `ROL <HEX+1` then `ROL <HEX`.
- Hex parse constants: `EORA #$30` and `CMPA #$FA` are unchanged from the original, but the
  original's `ADC #$88` becomes **`ADDA #$89`**. The 6809 inverts the 6502's carry convention
  on compare (6502 `CMP` sets C=1 when `A >= M`; 6809 `CMPA` sets C=1 on borrow), so the
  carry the original folds in is not set here and must be baked into the constant. With
  `#$88`, `'A'` yields `$F9` instead of `$FA` and every hex letter A-F is silently rejected.
- The cart image must be **exactly 8192 bytes**.
- `setdp WORK/256` in the source and `lda #WORK/256` / `tfr a,dp` at entry must both derive from the single `WORK` equate. If they drift, every variable access silently targets the wrong page with no diagnostic.
- Only `GETKEY` and `PUTCHAR` may touch hardware addresses.

## Workspace layout (referenced by every task)

```
WORK+$00  XAM      2   examine index
WORK+$02  ST       2   store index
WORK+$04  HEX      2   parsed hex value
WORK+$06  YSAV     1   saved text index
WORK+$07  MODE     1   $00 XAM / $74 STOR / $AE BLOCK
WORK+$08  CURSOR   2   screen write pointer
WORK+$0A  KEYLAST  1   debounce state
WORK+$80  IN     128   text buffer
```

## File Structure

| File | Responsibility |
|---|---|
| `src/wozmon.asm` | The entire monitor: target glue, core, I/O layer |
| `tests/harness.py` | `CoCoSim` — assemble, load, execute, simulate PIA + screen |
| `tests/test_harness.py` | Tests for the harness itself |
| `tests/test_putchar.py` | Screen output, CR, scroll |
| `tests/test_getkey.py` | Keyboard matrix scan, debounce |
| `tests/test_hexout.py` | `PRBYTE` / `PRHEX` |
| `tests/test_hexparse.py` | Hex input parsing |
| `tests/test_monitor.py` | Line input, dispatch, examine, store, run |
| `tests/test_build.py` | Both targets assemble; cart is exactly 8192 bytes |
| `Makefile` | Two build targets |
| `requirements.txt` | MC6809, pytest |

---

### Task 1: Test harness and build system

Everything downstream depends on this. Fold in project scaffolding.

**Files:**
- Create: `requirements.txt`, `Makefile`, `tests/harness.py`, `tests/test_harness.py`, `src/wozmon.asm` (skeleton only)

**Interfaces:**
- Produces: `CoCoSim(target=0)` with `.sym{}`, `.cpu`, `.mem`, `.run_sub(label, a=, b=, x=, u=)`, `.screen_text()`, `.press(col,row)`, `.release_all()`, `.peek(addr)`, `.poke(addr, val)`, `.peek_word(addr)`

- [ ] **Step 1: Write `requirements.txt`**

```
MC6809==0.9.0
pytest>=9.0
```

- [ ] **Step 2: Write the skeleton `src/wozmon.asm`**

Only enough to assemble and expose the symbols the harness needs.

```asm
; Wozmon for the TRS-80 Color Computer 2
; Ported from Steve Wozniak's Apple I monitor (1976).

            ifndef TARGET
TARGET      equ 0                   ; 0 = DECB .BIN, 1 = cartridge ROM
            endc

            ifeq TARGET
WORK        equ $3F00
ORIGIN      equ $4000
            else
WORK        equ $0600
ORIGIN      equ $C000
            endc

; --- workspace ---
XAM         equ WORK+$00
ST          equ WORK+$02
HEX         equ WORK+$04
YSAV        equ WORK+$06
MODE        equ WORK+$07
CURSOR      equ WORK+$08
KEYLAST     equ WORK+$0A
IN          equ WORK+$80

; --- hardware ---
SCREEN      equ $0400
SCREND      equ $0600
PIA0DA      equ $FF00
PIA0DB      equ $FF02

            setdp WORK/256
            org ORIGIN

ENTRY       orcc  #$50              ; mask IRQ and FIRQ, both builds
            lda   #WORK/256
            tfr   a,dp
            ifne TARGET
            lds   #$0800
            endc
            rts                     ; replaced in Task 10

            end ENTRY
```

- [ ] **Step 3: Write `tests/harness.py`**

```python
"""Host-side CoCo 2 simulator for testing the Wozmon port."""
import pathlib
import re
import subprocess
import tempfile

from MC6809.components.cpu6809 import CPU
from MC6809.components.memory import Memory
from MC6809.core.configs import BaseConfig

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "wozmon.asm"

SENTINEL = 0x7F00          # RAM the monitor never executes; marks "subroutine returned"
SCREEN = 0x0400
SCREND = 0x0600
PIA0DA = 0xFF00            # keyboard rows, active low
PIA0DB = 0xFF02            # keyboard column strobe, active low


class _Cfg(BaseConfig):
    # MC6809 asserts RAM_SIZE * 2 <= 65536, so RAM caps at 32K.
    RAM_START, RAM_END = 0x0000, 0x7FFF
    ROM_START, ROM_END = 0x8000, 0xFFFF


def assemble(target=0, source=SRC):
    """Assemble the monitor. Returns (blob: bytes, symbols: dict[str, int])."""
    with tempfile.TemporaryDirectory() as td:
        out = pathlib.Path(td) / "o.bin"
        mp = pathlib.Path(td) / "o.map"
        proc = subprocess.run(
            ["lwasm", "--format=raw", f"--output={out}", f"--map={mp}",
             f"-DTARGET={target}", str(source)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise AssertionError(f"lwasm failed:\n{proc.stdout}\n{proc.stderr}")
        syms = {}
        for line in mp.read_text().splitlines():
            m = re.match(r"Symbol:\s+(\S+)\s+\(.*\)\s+=\s+([0-9A-Fa-f]+)", line)
            if m:
                syms[m.group(1)] = int(m.group(2), 16)
        return out.read_bytes(), syms


class CoCoSim:
    """A 6809 running the monitor, with a simulated CoCo keyboard and screen.

    Only TARGET=0 (origin $4000) is used for functional tests, because
    MC6809 caps RAM at 32K and the cart origin $C000 lands in its ROM area.
    The cart build is covered by Task 11's build tests plus hardware checks.
    """

    def __init__(self, target=0):
        blob, self.sym = assemble(target)
        cfg = _Cfg({"verbosity": None, "trace": None})
        self.mem = Memory(cfg)
        self.cpu = CPU(self.mem, cfg)
        self.mem.load(self.sym["ORIGIN"], bytearray(blob))
        self._keys = set()           # {(col, row)} currently held
        self._strobe = 0xFF
        self.mem.add_write_byte_callback(self._pia_write, PIA0DB)
        self.mem.add_read_byte_callback(self._pia_read, PIA0DA)
        self.poke(self.sym["CURSOR"], SCREEN >> 8)
        self.poke(self.sym["CURSOR"] + 1, SCREEN & 0xFF)
        self.clear_screen()

    # --- PIA simulation -------------------------------------------------
    def _pia_write(self, cycles, last_op, address, value):
        self._strobe = value

    def _pia_read(self, cycles, last_op, address):
        rows = 0
        for col, row in self._keys:
            if not (self._strobe >> col) & 1:     # column driven low = selected
                rows |= 1 << row
        return (~rows) & 0xFF                     # rows are active low

    def press(self, col, row):
        self._keys.add((col, row))

    def release_all(self):
        self._keys.clear()

    # --- memory ---------------------------------------------------------
    def peek(self, addr):
        return self.mem.read_byte(addr)

    def poke(self, addr, val):
        self.mem.write_byte(addr, val)

    def peek_word(self, addr):
        return (self.peek(addr) << 8) | self.peek(addr + 1)

    def poke_word(self, addr, val):
        self.poke(addr, (val >> 8) & 0xFF)
        self.poke(addr + 1, val & 0xFF)

    # --- screen ---------------------------------------------------------
    def clear_screen(self):
        for a in range(SCREEN, SCREND):
            self.poke(a, 0x20)

    def screen_text(self):
        """Screen as 16 rows of 32 chars, VDG codes mapped back to ASCII."""
        rows = []
        for r in range(16):
            base = SCREEN + r * 32
            rows.append("".join(
                self._vdg_to_ascii(self.peek(base + c)) for c in range(32)))
        return rows

    @staticmethod
    def _vdg_to_ascii(code):
        code &= 0x3F
        return chr(code + 0x40) if code < 0x20 else chr(code)

    # --- execution ------------------------------------------------------
    def run_sub(self, label, a=0, b=0, x=0, u=0, max_cycles=2_000_000):
        """Call a monitor subroutine and run until it returns.

        Pushes SENTINEL as the return address, so the routine's RTS lands
        there and MC6809's test_run stops.
        """
        self.cpu.accu_a.set(a)
        self.cpu.accu_b.set(b)
        self.cpu.index_x.set(x)
        self.cpu.user_stack_pointer.set(u)      # U, not index_u
        self.cpu.direct_page.set(self.sym["WORK"] >> 8)
        sp = 0x7EFF
        self.mem.write_byte(sp - 1, (SENTINEL >> 8) & 0xFF)
        self.mem.write_byte(sp, SENTINEL & 0xFF)
        self.cpu.system_stack_pointer.set(sp - 1)
        self.cpu.test_run(self.sym[label], SENTINEL, max_ops=max_cycles)
        return self.cpu.accu_a.value
```

- [ ] **Step 4: Write `tests/test_harness.py`**

```python
from harness import CoCoSim, SCREEN, assemble


def test_assembles_and_exports_symbols():
    _, syms = assemble(target=0)
    for name in ("ENTRY", "WORK", "ORIGIN", "XAM", "MODE", "IN"):
        assert name in syms, f"missing symbol {name}"
    assert syms["ORIGIN"] == 0x4000
    assert syms["WORK"] == 0x3F00


def test_both_targets_assemble():
    _, bin_syms = assemble(target=0)
    _, cart_syms = assemble(target=1)
    assert bin_syms["ORIGIN"] == 0x4000
    assert cart_syms["ORIGIN"] == 0xC000
    assert cart_syms["WORK"] == 0x0600


def test_run_sub_returns_at_sentinel():
    """ENTRY is currently just setup + RTS, so it must return cleanly."""
    sim = CoCoSim()
    sim.run_sub("ENTRY")
    assert sim.cpu.direct_page.value == 0x3F


def test_pia_simulation_reports_pressed_key():
    sim = CoCoSim()
    sim.press(col=2, row=5)              # the ':' key
    sim.poke(0xFF02, 0xFF & ~(1 << 2))   # strobe column 2
    assert sim.peek(0xFF00) == (~(1 << 5)) & 0xFF
    sim.poke(0xFF02, 0xFF & ~(1 << 3))   # strobe a different column
    assert sim.peek(0xFF00) == 0xFF      # nothing pressed there


def test_screen_starts_blank():
    sim = CoCoSim()
    assert sim.screen_text()[0] == " " * 32
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `.venv/bin/pytest tests/ -v`
Expected: collection succeeds; failures because `src/wozmon.asm` may not yet assemble cleanly. Fix the skeleton until all five pass.

- [ ] **Step 6: Write the `Makefile`**

```make
LWASM ?= lwasm
SRC   := src/wozmon.asm
PY    := .venv/bin/python

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
```

- [ ] **Step 7: Add `tests/conftest.py` so `harness` imports cleanly**

```python
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
```

- [ ] **Step 8: Run everything**

Run: `make && .venv/bin/pytest tests/ -v`
Expected: both images build; all 5 harness tests PASS.

- [ ] **Step 9: Commit**

```bash
git add requirements.txt Makefile src/wozmon.asm tests/
git commit -m "test: add 6809 host test harness and build system"
```

---

### Task 2: PUTCHAR — screen output

**Files:**
- Modify: `src/wozmon.asm`
- Test: `tests/test_putchar.py`

**Interfaces:**
- Consumes: `CoCoSim` from Task 1
- Produces: `PUTCHAR` (A = ASCII char; preserves A, B, X, U), `SCROLL`, `CLS`. Constant `CR equ $0D`.

- [ ] **Step 1: Write the failing tests**

```python
from harness import CoCoSim, SCREEN, SCREND

CR = 0x0D


def test_writes_one_char_and_advances_cursor():
    sim = CoCoSim()
    sim.run_sub("PUTCHAR", a=ord("A"))
    assert sim.screen_text()[0][0] == "A"
    assert sim.peek_word(sim.sym["CURSOR"]) == SCREEN + 1


def test_preserves_registers():
    sim = CoCoSim()
    sim.run_sub("PUTCHAR", a=ord("Z"), b=0x5A, x=0x1234)
    assert sim.cpu.accu_a.value == ord("Z")
    assert sim.cpu.accu_b.value == 0x5A
    assert sim.cpu.index_x.value == 0x1234


def test_cr_moves_to_start_of_next_line():
    sim = CoCoSim()
    for ch in "ABC":
        sim.run_sub("PUTCHAR", a=ord(ch))
    sim.run_sub("PUTCHAR", a=CR)
    assert sim.peek_word(sim.sym["CURSOR"]) == SCREEN + 32
    sim.run_sub("PUTCHAR", a=ord("X"))
    assert sim.screen_text()[0][:3] == "ABC"
    assert sim.screen_text()[1][0] == "X"


def test_cr_at_column_31_advances_exactly_one_line():
    """Boundary: the round-up must not skip a line when already at col 31."""
    sim = CoCoSim()
    sim.poke_word(sim.sym["CURSOR"], SCREEN + 31)
    sim.run_sub("PUTCHAR", a=CR)
    assert sim.peek_word(sim.sym["CURSOR"]) == SCREEN + 32


def test_scrolls_when_cursor_passes_end_of_screen():
    sim = CoCoSim()
    sim.poke_word(sim.sym["CURSOR"], SCREEN + 15 * 32)   # last row
    for ch in "HELLO":
        sim.run_sub("PUTCHAR", a=ord(ch))
    sim.run_sub("PUTCHAR", a=CR)                         # forces scroll
    assert sim.screen_text()[14][:5] == "HELLO"
    assert sim.screen_text()[15] == " " * 32
    assert sim.peek_word(sim.sym["CURSOR"]) == SCREND - 32


def test_scroll_preserves_earlier_rows_shifted_up():
    sim = CoCoSim()
    for r in range(16):
        sim.poke(SCREEN + r * 32, ord("0") + (r % 10))
    sim.poke_word(sim.sym["CURSOR"], SCREND - 1)
    sim.run_sub("PUTCHAR", a=ord("!"))    # fills last cell, triggers scroll
    text = sim.screen_text()
    assert text[0][0] == "1"              # old row 1 is now row 0
    assert text[14][0] == "5"             # old row 15 is now row 14
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_putchar.py -v`
Expected: FAIL — `KeyError: 'PUTCHAR'` from `run_sub`.

- [ ] **Step 3: Implement PUTCHAR**

Insert before the `end` directive in `src/wozmon.asm`:

```asm
CR          equ $0D
VDGSPC      equ $20                 ; VDG code for space

; --- PUTCHAR: print ASCII char in A. Preserves A, B, X, U. ---
; The AND #$3F maps ASCII to the MC6847's 64-entry set, which begins at
; '@'. Bit 6 is the inverse-video bit; its correct polarity is verification
; item 1 in the spec and is confirmed on hardware in Task 12. If normal
; text needs bit 6 set, change this single instruction to "ora #$40".
PUTCHAR     pshs  a,b,x
            cmpa  #CR
            beq   PUTCR
            ldx   <CURSOR
            anda  #$3F
            sta   ,x+
            stx   <CURSOR
            bra   PUTCHK
PUTCR       ldd   <CURSOR
            subd  #SCREEN
            orb   #31               ; round up to end of this line
            addd  #1                ; then step to the next line's start
            addd  #SCREEN
            std   <CURSOR
PUTCHK      ldx   <CURSOR
            cmpx  #SCREND
            blo   PUTDONE
            bsr   SCROLL
PUTDONE     puls  a,b,x,pc

; --- SCROLL: move rows 1-15 up one, blank the last, home cursor there ---
SCROLL      pshs  a,x,u
            ldx   #SCREEN+32
            ldu   #SCREEN
SCRLP       ldd   ,x++
            std   ,u++
            cmpx  #SCREND
            blo   SCRLP
            ldx   #SCREND-32
            lda   #VDGSPC
SCRBLK      sta   ,x+
            cmpx  #SCREND
            blo   SCRBLK
            ldx   #SCREND-32
            stx   <CURSOR
            puls  a,x,u,pc

; --- CLS: blank the screen and home the cursor ---
CLS         pshs  a,x
            ldx   #SCREEN
            lda   #VDGSPC
CLSLP       sta   ,x+
            cmpx  #SCREND
            blo   CLSLP
            ldx   #SCREEN
            stx   <CURSOR
            puls  a,x,pc
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/pytest tests/test_putchar.py -v`
Expected: all 6 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/wozmon.asm tests/test_putchar.py
git commit -m "feat: add PUTCHAR with CR handling and screen scroll"
```

---

### Task 3: GETKEY — keyboard matrix scan

**Files:**
- Modify: `src/wozmon.asm`
- Test: `tests/test_getkey.py`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `SCANKEY` (returns A = ASCII, or 0 if no key; preserves B, X, U), `GETKEY` (blocks until a key is pressed and released, returns A = ASCII), `KEYTAB` (56 bytes, column-major, 7 rows per column)

The CoCo matrix, column = PIA0_DB bit, row = PIA0_DA bit. Every key the
monitor needs is unshifted.

| | row0 | row1 | row2 | row3 | row4 | row5 | row6 |
|---|---|---|---|---|---|---|---|
|col0|`@`|`H`|`P`|`X`|`0`|`8`|ENTER|
|col1|`A`|`I`|`Q`|`Y`|`1`|`9`|CLEAR|
|col2|`B`|`J`|`R`|`Z`|`2`|`:`|BREAK|
|col3|`C`|`K`|`S`|up|`3`|`;`|—|
|col4|`D`|`L`|`T`|down|`4`|`,`|—|
|col5|`E`|`M`|`U`|left|`5`|`-`|—|
|col6|`F`|`N`|`V`|right|`6`|`.`|—|
|col7|`G`|`O`|`W`|space|`7`|`/`|SHIFT|

- [ ] **Step 1: Write the failing tests**

```python
import pytest
from harness import CoCoSim

CR, ESC, BS = 0x0D, 0x1B, 0x08


@pytest.mark.parametrize("col,row,expected", [
    (0, 4, "0"), (7, 4, "7"), (0, 5, "8"), (1, 5, "9"),
    (1, 0, "A"), (2, 0, "B"), (6, 0, "F"),
    (2, 2, "R"),
    (6, 5, "."), (2, 5, ":"),
])
def test_scankey_maps_matrix_to_ascii(col, row, expected):
    sim = CoCoSim()
    sim.press(col, row)
    assert chr(sim.run_sub("SCANKEY")) == expected


@pytest.mark.parametrize("col,row,expected", [
    (0, 6, CR),    # ENTER
    (2, 6, ESC),   # BREAK
    (5, 3, BS),    # left arrow
])
def test_scankey_maps_control_keys(col, row, expected):
    sim = CoCoSim()
    sim.press(col, row)
    assert sim.run_sub("SCANKEY") == expected


def test_scankey_returns_zero_when_nothing_pressed():
    sim = CoCoSim()
    assert sim.run_sub("SCANKEY") == 0


def test_scankey_returns_zero_for_unused_matrix_positions():
    sim = CoCoSim()
    sim.press(7, 6)          # SHIFT, unused by the monitor
    assert sim.run_sub("SCANKEY") == 0


def test_scankey_preserves_registers():
    sim = CoCoSim()
    sim.press(1, 0)
    sim.run_sub("SCANKEY", b=0x77, x=0x4321)
    assert sim.cpu.accu_b.value == 0x77
    assert sim.cpu.index_x.value == 0x4321
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_getkey.py -v`
Expected: FAIL — `KeyError: 'SCANKEY'`.

- [ ] **Step 3: Implement SCANKEY, GETKEY and KEYTAB**

```asm
ESC         equ $1B
BS          equ $08

; --- SCANKEY: returns A = ASCII of a pressed key, or 0. Preserves B,X,U. ---
; Walks the 8 columns by rotating a single low bit through B. After the
; eighth column the low bit rotates out and carry clears, ending the loop.
SCANKEY     pshs  b,x
            ldx   #KEYTAB
            ldb   #$FE
SKCOL       stb   PIA0DB
            lda   PIA0DA
            coma                    ; active low -> active high
            anda  #$7F              ; 7 valid rows
            bne   SKHIT
            leax  7,x               ; next column's 7 table entries
            orcc  #$01              ; carry in = 1
            rolb
            bcs   SKCOL
            clra                    ; walked all 8 columns, nothing down
            puls  b,x,pc
SKHIT       clrb                    ; find the lowest set row bit
SKBIT       lsra
            bcs   SKGOT
            incb
            bra   SKBIT
SKGOT       abx                     ; X += B
            lda   ,x
            puls  b,x,pc

; --- GETKEY: block until a key is pressed, then released. Returns A. ---
GETKEY      pshs  b,x
GKWAIT      bsr   SCANKEY
            tsta
            beq   GKWAIT
            pshs  a
GKREL       bsr   SCANKEY           ; debounce: wait for all keys up
            tsta
            bne   GKREL
            puls  a
            puls  b,x,pc

; --- KEYTAB: column-major, 7 rows per column. 0 = unused position. ---
KEYTAB      fcb   '@','H','P','X','0','8',CR      ; col 0
            fcb   'A','I','Q','Y','1','9',0       ; col 1 (CLEAR unused)
            fcb   'B','J','R','Z','2',':',ESC     ; col 2 (BREAK = ESC)
            fcb   'C','K','S',0,'3',';',0         ; col 3
            fcb   'D','L','T',0,'4',',',0         ; col 4
            fcb   'E','M','U',BS,'5','-',0        ; col 5 (left = backspace)
            fcb   'F','N','V',0,'6','.',0         ; col 6
            fcb   'G','O','W',' ','7','/',0       ; col 7 (SHIFT unused)
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/pytest tests/test_getkey.py -v`
Expected: all 18 PASS (13 parametrized + 5).

- [ ] **Step 5: Commit**

```bash
git add src/wozmon.asm tests/test_getkey.py
git commit -m "feat: add keyboard matrix scanner with debounce"
```

---

### Task 4: PRBYTE and PRHEX — hex output

**Files:**
- Modify: `src/wozmon.asm`
- Test: `tests/test_hexout.py`

**Interfaces:**
- Consumes: `PUTCHAR` from Task 2
- Produces: `PRBYTE` (A = byte, prints two hex digits), `PRHEX` (A = value, prints low nibble as one hex digit)

- [ ] **Step 1: Write the failing tests**

```python
import pytest
from harness import CoCoSim


def _printed(sim):
    return sim.screen_text()[0].rstrip()


@pytest.mark.parametrize("value,expected", [
    (0x00, "00"), (0x09, "09"), (0x0A, "0A"), (0x0F, "0F"),
    (0xA0, "A0"), (0xFF, "FF"), (0x5A, "5A"), (0x3C, "3C"),
])
def test_prbyte_prints_two_hex_digits(value, expected):
    sim = CoCoSim()
    sim.run_sub("PRBYTE", a=value)
    assert _printed(sim) == expected


@pytest.mark.parametrize("value,expected", [
    (0x00, "0"), (0x09, "9"), (0x0A, "A"), (0x0F, "F"),
    (0xF3, "3"),   # high nibble must be ignored
])
def test_prhex_prints_low_nibble(value, expected):
    sim = CoCoSim()
    sim.run_sub("PRHEX", a=value)
    assert _printed(sim) == expected


def test_nine_to_a_boundary():
    """The ':' between '9' and 'A' in ASCII is where the +7 fixup matters."""
    sim = CoCoSim()
    sim.run_sub("PRBYTE", a=0x9A)
    assert _printed(sim) == "9A"
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_hexout.py -v`
Expected: FAIL — `KeyError: 'PRBYTE'`.

- [ ] **Step 3: Implement**

```asm
; --- PRBYTE: print A as two hex digits. Falls through to PRHEX. ---
PRBYTE      pshs  a
            lsra
            lsra
            lsra
            lsra
            bsr   PRHEX
            puls  a
; --- PRHEX: print A's low nibble as one hex digit. ---
PRHEX       anda  #$0F
            adda  #'0'
            cmpa  #'9'
            bls   PRHOUT
            adda  #7                ; skip ':' through '@' to reach 'A'
PRHOUT      jmp   PUTCHAR           ; tail call; PUTCHAR preserves A
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/pytest tests/test_hexout.py -v`
Expected: all 14 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/wozmon.asm tests/test_hexout.py
git commit -m "feat: add PRBYTE and PRHEX hex output"
```

---

### Task 5: Hex input parsing

**Files:**
- Modify: `src/wozmon.asm`
- Test: `tests/test_hexparse.py`

**Interfaces:**
- Consumes: workspace symbols `HEX`, `IN`, `YSAV`
- Produces: `PARSEHEX` — entered with B = index into `IN`, U = `IN` base. Accumulates hex digits into `HEX`. Returns with B = index of the first non-hex character, and the Z flag set if no digits were consumed.

This is the one task where the spec's byte-order warning bites: `HEX` is
big-endian, so the shift is `ROL <HEX+1` (low byte) then `ROL <HEX` (high).

- [ ] **Step 1: Write the failing tests**

```python
import pytest
from harness import CoCoSim


def _parse(text):
    """Load text into IN, run PARSEHEX, return (HEX value, stop index)."""
    sim = CoCoSim()
    base = sim.sym["IN"]
    for i, ch in enumerate(text):
        sim.poke(base + i, ord(ch))
    sim.poke_word(sim.sym["HEX"], 0)
    sim.run_sub("PARSEHEX", b=0, u=base)
    return sim.peek_word(sim.sym["HEX"]), sim.cpu.accu_b.value


@pytest.mark.parametrize("text,value", [
    ("0", 0x0000), ("F", 0x000F), ("FF", 0x00FF),
    ("1234", 0x1234), ("ABCD", 0xABCD), ("DEAD", 0xDEAD),
    ("00FF", 0x00FF), ("E000", 0xE000),
])
def test_parses_hex_value(text, value):
    assert _parse(text + " ")[0] == value


def test_keeps_only_last_four_digits():
    """The original shifts left without overflow checking."""
    assert _parse("12345 ")[0] == 0x2345


def test_stops_at_first_non_hex():
    value, idx = _parse("1A.")
    assert value == 0x001A
    assert idx == 2


def test_lowercase_is_not_hex():
    """The CoCo 2 keyboard produces uppercase only; 'a' must not parse."""
    value, idx = _parse("a")
    assert idx == 0


def test_g_is_not_hex():
    value, idx = _parse("1G")
    assert value == 0x0001
    assert idx == 1
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_hexparse.py -v`
Expected: FAIL — `KeyError: 'PARSEHEX'`.

- [ ] **Step 3: Implement**

```asm
; --- PARSEHEX: accumulate hex digits from IN into HEX. ---
; In:  B = index into IN, U = IN base.
; Out: B = index of first non-hex char; Z set if no digits were consumed.
; 'A' differs from $C1 only in bit 7, so EOR #$30 maps plain ASCII exactly
; as the original mapped high-bit ASCII. The original's ADC #$88 relies on
; the 6502 setting carry when A >= M; the 6809 sets carry on BORROW, the
; opposite, so the +1 is folded into the constant here: ADDA #$89.
PARSEHEX    stb   <YSAV               ; remember where the digits started
PHNEXT      lda   b,u                 ; the 6809 form of LDA IN,Y
            eora  #$30                ; map '0'-'9' to $00-$09
            cmpa  #$0A
            blo   PHDIG
            adda  #$89                ; map 'A'-'F' to $FA-$FF
            cmpa  #$FA
            blo   PHDONE              ; not a hex character
PHDIG       lsla                      ; digit into the high nibble
            lsla
            lsla
            lsla
            ldy   #4                  ; shift count
PHSHIFT     lsla
            rol   <HEX+1              ; low byte first: 6809 is big-endian
            rol   <HEX
            leay  -1,y
            bne   PHSHIFT
            incb
            bra   PHNEXT
PHDONE      cmpb  <YSAV               ; Z set if no digits consumed
            rts
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/pytest tests/test_hexparse.py -v`
Expected: all 12 PASS. If values come back byte-swapped, the `rol` order is
reversed — see the Global Constraints note.

- [ ] **Step 5: Commit**

```bash
git add src/wozmon.asm tests/test_hexparse.py
git commit -m "feat: add hex input parser"
```

---

### Task 6: Line input

**Files:**
- Modify: `src/wozmon.asm`
- Test: `tests/test_monitor.py`

**Interfaces:**
- Consumes: `GETKEY`, `PUTCHAR`
- Produces: `GETLINE` — reads a line into `IN`, echoing. Returns with the line terminated by CR in the buffer and B = 0. Handles backspace and ESC.

- [ ] **Step 1: Write the failing tests**

```python
from harness import CoCoSim

CR, ESC, BS = 0x0D, 0x1B, 0x08

# (col, row) for the keys the tests type
KEY = {
    "0": (0, 4), "1": (1, 4), "2": (2, 4), "3": (3, 4), "4": (4, 4),
    "5": (5, 4), "6": (6, 4), "7": (7, 4), "8": (0, 5), "9": (1, 5),
    "A": (1, 0), "B": (2, 0), "C": (3, 0), "D": (4, 0), "E": (5, 0),
    "F": (6, 0), "R": (2, 2), ".": (6, 5), ":": (2, 5), " ": (7, 3),
    "\r": (0, 6), "\x1b": (2, 6), "\x08": (5, 3),
}


def type_line(sim, text):
    """Queue keystrokes by patching SCANKEY's source at the PIA level.

    Rather than simulating press/release timing, install a read callback on
    PIA0DA that plays back one key per full column sweep.
    """
    sim.queue_keys([KEY[c] for c in text])


def test_getline_collects_characters_into_buffer():
    sim = CoCoSim()
    type_line(sim, "1234\r")
    sim.run_sub("GETLINE")
    base = sim.sym["IN"]
    assert [chr(sim.peek(base + i)) for i in range(4)] == list("1234")
    assert sim.peek(base + 4) == CR


def test_getline_echoes_to_screen():
    sim = CoCoSim()
    type_line(sim, "AB\r")
    sim.run_sub("GETLINE")
    assert sim.screen_text()[0][:2] == "AB"


def test_backspace_removes_last_character():
    sim = CoCoSim()
    type_line(sim, "12\x083\r")
    sim.run_sub("GETLINE")
    base = sim.sym["IN"]
    assert [chr(sim.peek(base + i)) for i in range(2)] == list("13")
    assert sim.peek(base + 2) == CR


def test_backspace_past_start_restarts_line():
    sim = CoCoSim()
    type_line(sim, "\x08A\r")
    sim.run_sub("GETLINE")
    base = sim.sym["IN"]
    assert chr(sim.peek(base)) == "A"


def test_escape_prints_backslash_and_restarts():
    sim = CoCoSim()
    type_line(sim, "12\x1bA\r")
    sim.run_sub("GETLINE")
    assert "\\" in sim.screen_text()[0]
    base = sim.sym["IN"]
    assert chr(sim.peek(base)) == "A"
```

- [ ] **Step 2: Extend the harness with `queue_keys`**

Add to `CoCoSim` in `tests/harness.py`:

```python
    def queue_keys(self, keys):
        """Play back a list of (col, row) keystrokes, one per column sweep.

        SCANKEY sweeps all 8 columns before reporting; GETKEY then waits for
        release. This callback presents each key for one sweep, then an
        all-up sweep, so GETKEY's debounce advances exactly one key at a time.
        """
        self._queue = list(keys)
        self._sweep = 0
        self._released = True

        def play(cycles, last_op, address):
            col = 0
            for c in range(8):
                if not (self._strobe >> c) & 1:
                    col = c
                    break
            if self._released or not self._queue:
                if col == 7:
                    self._released = False
                return 0xFF
            key_col, key_row = self._queue[0]
            rows = (1 << key_row) if col == key_col else 0
            if col == 7:                 # end of sweep: advance state
                self._queue.pop(0)
                self._released = True
            return (~rows) & 0xFF

        self.mem.add_read_byte_callback(play, PIA0DA)
```

- [ ] **Step 3: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_monitor.py -v`
Expected: FAIL — `KeyError: 'GETLINE'`.

- [ ] **Step 4: Implement**

```asm
; --- GETLINE: read a line into IN, echoing. Returns B = 0. ---
GETLINE     lda   #CR
            jsr   PUTCHAR
GLINIT      ldu   #IN
            clrb
GLNEXT      jsr   GETKEY
            cmpa  #BS
            beq   GLBACK
            cmpa  #ESC
            beq   GLESC
            sta   b,u                 ; store into IN
            jsr   PUTCHAR
            cmpa  #CR
            beq   GLDONE
            incb
            bpl   GLNEXT              ; auto-escape past 127 characters
GLESC       lda   #'\'
            jsr   PUTCHAR
            bra   GETLINE
GLBACK      tstb
            beq   GETLINE             ; backed past the start: restart
            decb
            lda   #BS
            jsr   PUTCHAR
            bra   GLNEXT
GLDONE      clrb
            rts
```

- [ ] **Step 5: Run to verify they pass**

Run: `.venv/bin/pytest tests/test_monitor.py -v`
Expected: all 5 PASS.

- [ ] **Step 6: Commit**

```bash
git add src/wozmon.asm tests/harness.py tests/test_monitor.py
git commit -m "feat: add line input with backspace and escape"
```

---

### Task 7: Command dispatch and MODE

**Files:**
- Modify: `src/wozmon.asm`
- Test: `tests/test_monitor.py` (append)

**Interfaces:**
- Consumes: `GETLINE`, `PARSEHEX`
- Produces: `NEXTITEM` — walks `IN` from index B, dispatching on `.`, `:`, `R`, and hex. Sets `MODE` to `$00`, `$74`, or `$AE`.

- [ ] **Step 1: Write the failing tests**

```python
def _dispatch(text, mode_in=0x00):
    """Load text into IN and run one NEXTITEM pass."""
    sim = CoCoSim()
    base = sim.sym["IN"]
    for i, ch in enumerate(text + "\r"):
        sim.poke(base + i, ord(ch))
    sim.poke(sim.sym["MODE"], mode_in)
    sim.run_sub("NEXTITEM", b=0, u=base)
    return sim


def test_period_sets_block_mode():
    sim = _dispatch("1000.1010")
    assert sim.peek(sim.sym["MODE"]) == 0xAE


def test_colon_sets_store_mode():
    sim = _dispatch("1000: AA")
    assert sim.peek(sim.sym["MODE"]) == 0x74


def test_bare_address_leaves_xam_mode():
    sim = _dispatch("1000")
    assert sim.peek(sim.sym["MODE"]) == 0x00


def test_mode_values_match_original_exactly():
    """$74 is ASL of ':' ($BA); $AE is '.'. The OCR listing had these wrong."""
    assert _dispatch("00:").peek(_dispatch("00:").sym["MODE"]) == 0x74
    assert _dispatch("00.").peek(_dispatch("00.").sym["MODE"]) == 0xAE


def test_spaces_are_skipped_as_delimiters():
    sim = _dispatch("10 20 30")
    assert sim.peek(sim.sym["MODE"]) == 0x00


def test_malformed_input_prints_backslash():
    """No hex digits where hex is expected is the monitor's only error path.

    It prints '\\' and returns, so MAINLOOP reads a fresh line -- matching
    the original, whose ESCAPE prints '\\' then falls into GETLINE.
    """
    sim = _dispatch("G")
    assert "\\" in "".join(sim.screen_text())


def test_hex_letters_all_parse():
    """Regression guard for the 6809 carry inversion.

    With the original's ADC #$88 constant instead of ADDA #$89, every one
    of these is rejected as non-hex and MODE never advances.
    """
    for letter in "ABCDEF":
        sim = _dispatch(letter * 4)
        assert sim.peek_word(sim.sym["XAM"]) != 0, f"{letter} failed to parse"
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_monitor.py -v -k dispatch or mode`
Expected: FAIL — `KeyError: 'NEXTITEM'`.

- [ ] **Step 3: Implement**

```asm
STORMODE    equ $74                 ; ASL of ':'
BLOKMODE    equ $AE                 ; '.'

; --- NEXTITEM: dispatch on the next item in IN. B = index, U = IN base. ---
NEXTITEM    lda   b,u
            cmpa  #CR
            beq   NIDONE             ; end of line
            cmpa  #'.'
            blo   NISKIP             ; below '.' is a delimiter, skip it
            beq   NIBLOK
            cmpa  #':'
            beq   NISTOR
            cmpa  #'R'
            beq   NIRUN
            bra   NIHEX
NISKIP      incb
            bra   NEXTITEM
NIBLOK      lda   #BLOKMODE
            sta   <MODE
            incb
            bra   NEXTITEM
NISTOR      lda   #STORMODE
            sta   <MODE
            incb
            bra   NEXTITEM
NIRUN       jmp   [XAM]              ; the 6809 form of JMP (XAML)
NIHEX       ldx   #0
            stx   <HEX               ; clear the accumulator before parsing
            jsr   PARSEHEX
            beq   NIESC              ; no digits consumed: malformed
            jmp   STOREOREXAM        ; Task 8 / Task 9
; The original's ESCAPE prints '\' then falls into GETLINE, which reads a
; fresh line. Returning to MAINLOOP is exactly equivalent, and avoids
; consuming a line here and then having MAINLOOP consume another.
NIESC       lda   #'\'
            jsr   PUTCHAR
            rts
NIDONE      rts
```

- [ ] **Step 4: Run to verify they pass**

Note `STOREOREXAM` does not exist yet. Add a temporary stub immediately
before `NIESC` so this task's tests can run in isolation:

```asm
STOREOREXAM rts                     ; replaced in Task 8
```

Run: `.venv/bin/pytest tests/test_monitor.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/wozmon.asm tests/test_monitor.py
git commit -m "feat: add command dispatch and MODE handling"
```

---

### Task 8: Examine and block examine

**Files:**
- Modify: `src/wozmon.asm` (replace the `STOREOREXAM` stub)
- Test: `tests/test_monitor.py` (append)

**Interfaces:**
- Consumes: `PRBYTE`, `PUTCHAR`, `NEXTITEM`
- Produces: `STOREOREXAM`, `NXTPRNT`, `PRDATA`, `XAMNEXT` — the examine path, printing `XXXX: bb bb ...` 8 bytes per line

- [ ] **Step 1: Write the failing tests**

```python
def _examine(text, pattern=None):
    sim = CoCoSim()
    if pattern:
        for addr, val in pattern.items():
            sim.poke(addr, val)
    base = sim.sym["IN"]
    for i, ch in enumerate(text + "\r"):
        sim.poke(base + i, ord(ch))
    sim.poke(sim.sym["MODE"], 0x00)
    sim.run_sub("NEXTITEM", b=0, u=base)
    return sim


def test_single_examine_prints_address_and_byte():
    sim = _examine("0500", {0x0500: 0xA9})
    assert "0500: A9" in "".join(sim.screen_text())


def test_block_examine_prints_eight_bytes_per_line():
    pattern = {0x0500 + i: i for i in range(16)}
    sim = _examine("0500.050F", pattern)
    text = "".join(sim.screen_text())
    assert "0500: 00 01 02 03 04 05 06 07" in text
    assert "0508: 08 09 0A 0B 0C 0D 0E 0F" in text


def test_dump_line_fits_32_columns():
    pattern = {0x0500 + i: 0xFF for i in range(8)}
    sim = _examine("0500.0507", pattern)
    for row in sim.screen_text():
        assert len(row.rstrip()) <= 32


def test_block_examine_across_page_boundary():
    """Exercises the INC XAM carry path the OCR listing got wrong."""
    pattern = {0x04FE: 0xAA, 0x04FF: 0xBB, 0x0500: 0xCC, 0x0501: 0xDD}
    sim = _examine("04FE.0501", pattern)
    text = "".join(sim.screen_text())
    assert "AA BB" in text
    assert "CC DD" in text


def test_examine_sets_xam_to_parsed_address():
    sim = _examine("1234")
    assert sim.peek_word(sim.sym["XAM"]) >= 0x1234
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_monitor.py -v`
Expected: FAIL — the stub returns without printing.

- [ ] **Step 3: Implement — replace the `STOREOREXAM` stub**

```asm
; --- STOREOREXAM: MODE decides. Entered after PARSEHEX. ---
; The 6809's BITA clears V rather than loading bit 6, so the original's
; BIT/BVC/BMI dispatch becomes two explicit bit tests.
STOREOREXAM lda   <MODE
            bita  #$40
            bne   DOSTORE            ; MODE $74: store
            bita  #$80
            bne   XAMNEXT            ; MODE $AE: block examine
            ldx   <HEX               ; MODE $00: set both indices
            stx   <ST
            stx   <XAM
            clra                     ; force Z=1: a new address must be printed
NXTPRNT     bne   PRDATA             ; Z clear means mid-line, no address
            lda   #CR
            jsr   PUTCHAR
            lda   <XAM
            jsr   PRBYTE
            lda   <XAM+1
            jsr   PRBYTE
            lda   #':'
            jsr   PUTCHAR
PRDATA      lda   #' '
            jsr   PUTCHAR
            ldx   <XAM
            lda   ,x
            jsr   PRBYTE
XAMNEXT     clr   <MODE              ; back to XAM mode
            ldd   <XAM
            cmpd  <HEX
            bhs   TONEXTITEM         ; reached the end of the range
            ldx   <XAM
            leax  1,x
            stx   <XAM
            lda   <XAM+1
            anda  #$07               ; new line every 8 bytes
            bra   NXTPRNT            ; BRA does not disturb Z
TONEXTITEM  jmp   NEXTITEM
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/pytest tests/test_monitor.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/wozmon.asm tests/test_monitor.py
git commit -m "feat: add examine and block examine"
```

---

### Task 9: Store mode

**Files:**
- Modify: `src/wozmon.asm`
- Test: `tests/test_monitor.py` (append)

**Interfaces:**
- Consumes: `STOREOREXAM`
- Produces: `DOSTORE` — writes `HEX`'s low byte at `ST`, increments `ST`

- [ ] **Step 1: Write the failing tests**

```python
def test_store_writes_byte_at_address():
    sim = _examine("0500: AA")
    assert sim.peek(0x0500) == 0xAA


def test_store_multiple_bytes_advances():
    sim = _examine("0500: 11 22 33")
    assert [sim.peek(0x0500 + i) for i in range(3)] == [0x11, 0x22, 0x33]


def test_store_across_page_boundary():
    sim = _examine("04FE: 11 22 33 44")
    assert [sim.peek(0x04FE + i) for i in range(4)] == [0x11, 0x22, 0x33, 0x44]


def test_store_uses_low_byte_only():
    sim = _examine("0500: 1234")
    assert sim.peek(0x0500) == 0x34


def test_bare_colon_continues_from_last_store_index():
    """ST persists across lines, so ':' with no address resumes storing."""
    sim = CoCoSim()
    base = sim.sym["IN"]

    def feed(text):
        for i, ch in enumerate(text + "\r"):
            sim.poke(base + i, ord(ch))
        sim.poke(sim.sym["MODE"], 0x00)
        sim.run_sub("NEXTITEM", b=0, u=base)

    feed("0500: 11 22")
    feed(": 33 44")
    assert [sim.peek(0x0500 + i) for i in range(4)] == [0x11, 0x22, 0x33, 0x44]
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_monitor.py -v -k store`
Expected: FAIL — `DOSTORE` undefined.

- [ ] **Step 3: Implement**

```asm
; --- DOSTORE: write HEX's low byte at ST, then advance ST. ---
DOSTORE     lda   <HEX+1
            ldx   <ST
            sta   ,x+
            stx   <ST
            jmp   NEXTITEM
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/pytest tests/test_monitor.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/wozmon.asm tests/test_monitor.py
git commit -m "feat: add store mode"
```

---

### Task 10: RUN and the main loop

**Files:**
- Modify: `src/wozmon.asm` (replace `ENTRY`'s placeholder `rts`)
- Test: `tests/test_monitor.py` (append)

**Interfaces:**
- Consumes: everything above
- Produces: a complete `ENTRY` that initializes and loops forever

- [ ] **Step 1: Write the failing tests**

```python
def test_run_jumps_to_examine_address():
    """R transfers control to XAM. Plant an RTS there and check we return."""
    sim = CoCoSim()
    sim.poke(0x0500, 0x39)            # RTS opcode
    base = sim.sym["IN"]
    for i, ch in enumerate("0500R\r"):
        sim.poke(base + i, ord(ch))
    sim.poke(sim.sym["MODE"], 0x00)
    sim.run_sub("NEXTITEM", b=0, u=base)
    # Reaching the sentinel without a crash means the JMP [XAM] worked.


def test_entry_initializes_dp_and_clears_screen():
    sim = CoCoSim()
    sim.poke(0x0400, ord("X"))
    # ENTRY loops forever, so run a bounded number of ops and inspect state.
    sim.run_entry_briefly(ops=5000)
    assert sim.cpu.direct_page.value == 0x3F
```

- [ ] **Step 2: Add `run_entry_briefly` to the harness**

```python
    def run_entry_briefly(self, ops=5000):
        """Run ENTRY for a bounded number of operations (it never returns)."""
        self.cpu.direct_page.set(0)
        self.cpu.system_stack_pointer.set(0x7EFF)
        self.cpu.program_counter.set(self.sym["ENTRY"])
        for _ in range(ops):
            self.cpu.get_and_call_next_op()
```

- [ ] **Step 3: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_monitor.py -v -k run or entry`
Expected: FAIL.

- [ ] **Step 4: Implement — replace `ENTRY`'s `rts`**

```asm
ENTRY       orcc  #$50              ; mask IRQ and FIRQ, both builds
            lda   #WORK/256
            tfr   a,dp
            ifne TARGET
            lds   #$0800
            endc
            jsr   INITHW
            jsr   CLS
            clr   <MODE
            ldx   #0
            stx   <XAM
            stx   <ST
MAINLOOP    jsr   GETLINE
            ldu   #IN
            clrb
            jsr   NEXTITEM
            bra   MAINLOOP

; --- INITHW: PIA direction registers and 32x16 text mode. ---
; Idempotent: BASIC programs these identically, so the same code is
; correct in both builds.
INITHW      clr   $FF01             ; select DDRA
            clr   $FF00             ; keyboard rows are inputs
            lda   #$34
            sta   $FF01             ; select data register A
            clr   $FF03             ; select DDRB
            lda   #$FF
            sta   $FF02             ; keyboard columns are outputs
            lda   #$34
            sta   $FF03             ; select data register B
            rts
```

- [ ] **Step 5: Run the whole suite**

Run: `.venv/bin/pytest tests/ -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/wozmon.asm tests/harness.py tests/test_monitor.py
git commit -m "feat: add RUN command and main monitor loop"
```

---

### Task 11: Cartridge target and build verification

**Files:**
- Modify: `src/wozmon.asm`, `Makefile`
- Test: `tests/test_build.py`

**Interfaces:**
- Consumes: the complete monitor
- Produces: an 8192-byte cart image

- [ ] **Step 1: Write the failing tests**

```python
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _build():
    subprocess.run(["make", "clean", "all"], cwd=ROOT, check=True,
                   capture_output=True)


def test_both_images_build():
    _build()
    assert (ROOT / "build" / "wozmon.bin").exists()
    assert (ROOT / "build" / "wozmon.rom").exists()


def test_cart_image_is_exactly_8k():
    _build()
    assert (ROOT / "build" / "wozmon.rom").stat().st_size == 8192


def test_bin_image_is_decb_format():
    """DECB preamble: $00, 2-byte length, 2-byte load address."""
    _build()
    data = (ROOT / "build" / "wozmon.bin").read_bytes()
    assert data[0] == 0x00
    load_addr = (data[3] << 8) | data[4]
    assert load_addr == 0x4000


def test_bin_postamble_sets_exec_address():
    """Trailer: $FF, $0000, then the exec address from the end directive."""
    _build()
    data = (ROOT / "build" / "wozmon.bin").read_bytes()
    assert data[-5] == 0xFF
    exec_addr = (data[-2] << 8) | data[-1]
    assert exec_addr == 0x4000
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/pytest tests/test_build.py -v`
Expected: FAIL — the cart image is not 8192 bytes.

- [ ] **Step 3: Add the cart padding**

At the very end of `src/wozmon.asm`, before `end ENTRY`:

```asm
            ifne TARGET
            zmb   $E000-*           ; pad the cart image to exactly 8K
            endc
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/pytest tests/ -v`
Expected: all PASS, including the full suite.

- [ ] **Step 5: Commit**

```bash
git add src/wozmon.asm Makefile tests/test_build.py
git commit -m "feat: add cartridge target with 8K padding"
```

---

### Task 12: Hardware verification

**Blocked** on the `coco3-debug` bridge, which timed out during design. Do
not start until it responds to `status`. This task resolves the spec's two
verification items and confirms the keyboard matrix against real hardware.

**Files:**
- Modify: `src/wozmon.asm` (only if a verification result demands it)
- Create: `docs/hardware-verification.md`

- [ ] **Step 1: Confirm the bridge responds**

Call `mcp__coco3-debug__status`. If it times out, stop and report; do not
guess at the results below.

- [ ] **Step 2: Resolve verification item 1 — VDG inverse-video polarity**

Set the machine to CoCo 2. Write an ascending byte ramp to the screen and
screenshot it:

```
write_memory(addr=0x0400, data_hex="".join(f"{i:02x}" for i in range(64)))
screenshot()
```

Read off whether codes `$00-$3F` render as normal (black on green) or
inverse. If normal text requires bit 6 set, change the single `anda #$3F`
in `PUTCHAR` to `anda #$3F` followed by `ora #$40`, and update
`_vdg_to_ascii` in `tests/harness.py` to match. Record the finding.

- [ ] **Step 3: Resolve verification item 2 — cart autostart**

Determine what Color BASIC's reset routine checks at `$C000` before
jumping there. Adjust the cart header if a signature is required. Record
the finding.

- [ ] **Step 4: Verify the keyboard matrix**

The matrix in Task 3 is from documentation, not measurement. For each key
the monitor uses, strobe its column via `write_memory` on `$FF02`, read
`$FF00`, and confirm the row bit matches `KEYTAB`. Correct any mismatches
in both `KEYTAB` and the test's `KEY` map.

- [ ] **Step 5: End-to-end test on hardware**

Load `build/wozmon.bin`, run it, and exercise every command: single
examine, block examine across a page boundary, store, store continuation
with a bare `:`, backspace, ESC, and `R`.

- [ ] **Step 6: Write up and commit**

```bash
git add docs/hardware-verification.md src/wozmon.asm tests/harness.py
git commit -m "docs: record hardware verification results"
```
