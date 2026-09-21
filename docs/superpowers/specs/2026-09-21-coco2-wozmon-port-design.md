# Porting Wozmon to the Color Computer 2

**Date:** 2026-09-21
**Status:** Approved, ready for implementation planning

## 1. Goal

Port the Apple I monitor (Wozmon, Steve Wozniak, 1976) from 6502 to the
MC6809, running on a TRS-80 Color Computer 2. The result is a memory
monitor with the original's exact command set, built from one source file
into two images: a Disk BASIC loadable binary and an autostarting 8K
cartridge ROM.

## 2. Source material

The input listing, `wozmon.asm`, is an OCR transcription of the original
printed listing and contains transcription errors. The port follows the
*canonical* Wozmon semantics, not the transcription.

Errors that would produce a functionally wrong monitor if ported literally:

| Listing | Correct | Effect if ported as written |
|---|---|---|
| `CMP #$A3` ("." test) | `CMP #$AE` | `$A3` is `#`, not `.` — block examine never triggers |
| `ASC #$88` | `ADC #$88` | `ASC` is not a 6502 mnemonic; hex letters A-F unparseable |
| `BND MOD8CHK` | `BNE MOD8CHK` | `BND` is not a 6502 mnemonic |
| `36 24` / `36 25` for `INC XAML/XAMH` | `E6 24` / `E6 25` | `$36` is `ROL zp,X`; examine index never advances |
| `A5 25` for both `LDA XAMH` and `LDA XAML` | `A5 25` / `A5 24` | address high byte printed twice; 16-bit compare wrong |
| `MODE` comment `$7B` STOR, `$A3` BLOCK | `$74` STOR, `$AE` BLOCK | `ASL` of `":"` (`$BA`) is `$74`; BLOCK is `"."` = `$AE` |
| `LDA #$BD` commented "CR" | `LDA #$8D` | wrong character emitted |
| `CMP #$8B` commented "CR?" | `CMP #$8D` | end-of-line never detected |
| `67 PLA` | `68 PLA` | wrong opcode |
| `8B 13 D0 STY DSPCR` | `8C 13 D0` | `$8B` is not a valid `STY` |
| `8D 1D D0 STA DSP` | `8D 12 D0` | DSP is `$D012` |

The listing also has non-semantic artifacts: several addresses out of
sequence (`$FF63` for `$FF6E`, `$FFBD` for `$FF8D`, `$FF70` for `$FF79`,
and off-by-one addresses around `$FFA8`, `$FFC7`, `$FFD7`), the label
spelled both `NOTHEX` and `NOHEX`, `BACKSAPCE` for `BACKSPACE`, and
`KBD CR` / `DSP CR` for `KBDCR` / `DSPCR`. These need no decision; they
simply do not survive into the port.

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Deployment | Both a DECB `.BIN` and an autostart cart `.ROM`, from one source | Covers development convenience and standalone use without maintaining two programs |
| I/O | Bare metal: direct PIA0 keyboard scan, direct VDG screen writes | ROM-independent; the monitor stays usable when BASIC is not initialized, which is the point of a monitor |
| Scope | Faithful 1:1 command set | Original commands and nothing more |
| Exit | None, in either build | Faithful to the original, which has no exit; the two builds differ only in origin and workspace address |

**Faithful means behavior, not transliteration.** The command set, output
format, and error behavior match the original exactly. The implementation
uses 6809 idiom where it is exactly equivalent — a literal
instruction-for-instruction transliteration would be larger and slower on
this CPU for no behavioral gain.

## 4. Architecture

### 4.1 Build structure

One `src/wozmon.asm`, one `TARGET` equate, two assembler invocations.

```
src/wozmon.asm
├── TARGET equate (ifndef-guarded, default 0 = BIN)
├── per-target equates: ORG, WORK, stack     <- the only differing addresses
├── entry glue         (ifeq TARGET ... else ... endc)
├── monitor core       <- target-agnostic
├── I/O layer          <- target-agnostic
└── (cart only) 8K pad
```

Verified against lwasm 4.22: `ifeq` / `else` / `endc`, the `ifndef`
default guard, and `-DTARGET=1` overriding it all behave as required, with
the unselected branch emitting no bytes.

### 4.2 Memory maps

**Cart (`TARGET=1`)**

```
$0400-$05FF   VDG text screen, 32x16
$0600-$06FF   WORK    (DP = $06)
$0700-$07FF   stack   (LDS #$0800)
$C000-$DFFF   monitor ROM, padded to exactly 8192 bytes
```

Workspace and stack sit immediately above the text screen, so the cart
build runs even on a 4K machine.

**BIN (`TARGET=0`)**

```
$0400-$05FF   VDG text screen (BASIC already owns it)
$3F00-$3FFF   WORK    (DP = $3F)
$4000-....    monitor code
              stack: BASIC's, inherited
```

Placing `WORK` below the code makes the workspace page-aligned by
construction, with no `rmb` padding. Because the monitor never returns, it
inherits BASIC's stack rather than switching.

### 4.3 Workspace layout

Replaces Wozmon's zero page `$24-$2B`. Accessed via the DP register, which
makes every variable reference a 2-byte direct-page instruction — the
6809's equivalent of the 6502's architectural zero page.

| Offset | Name | Size | Original |
|---|---|---|---|
| `+$00` | `XAM` | 2 | `XAML`/`XAMH` `$24/$25` |
| `+$02` | `ST` | 2 | `STL`/`STH` `$26/$27` |
| `+$04` | `HEX` | 2 | `L`/`H` `$28/$29` |
| `+$06` | `YSAV` | 1 | `$2A` |
| `+$07` | `MODE` | 1 | `$2B` |
| `+$08` | `CURSOR` | 2 | new, bare-metal `PUTCHAR` |
| `+$0A` | `KEYLAST` | 1 | new, debounce state |
| `+$80` | `IN` | 128 | `$0200` |

The 16-bit values are native 6809 big-endian, the opposite of the 6502.

**Assembler/runtime agreement.** `setdp` is a promise to the assembler,
not a runtime action; the code must separately load DP at entry. If the
two disagree, every variable access silently reads the wrong page with no
diagnostic. Both are derived from the single `WORK` equate — `setdp
WORK/256` in the source, `lda #WORK/256` / `tfr a,dp` at entry — so they
cannot drift when `TARGET` changes. This is the reason the design is one
file rather than a core plus two glue files.

## 5. The port

The core keeps the original's structure: four states (`NOTCR`, `GETLINE`,
`NEXTITEM`, `NEXTHEX`) dispatched through the `MODE` byte, whose values
are unchanged at `$00` XAM, `$74` STOR, `$AE` BLOCK.

**`MODE` resets to `$00` at the start of every line.** The original does
this after each CR by falling through `LDA #$00` / `TAX` / `ASL` into
`SETMODE`. Omitting it leaves a store line's `$74` in place, so the next
line's address item takes the store path instead of printing and silently
writes to the store index. Only an end-to-end test catches this: any test
that sets `MODE` itself before dispatching hides it.

### 5.1 Translations that collapse

| Wozmon (6502) | CoCo (6809) |
|---|---|
| `LDA IN,Y`, 8-bit `Y` index | `LDA B,U` with `U` = `IN` base — B-accumulator-offset indexing is an exact match |
| `SETADR` 2-byte copy loop | `LDX <HEX` / `STX <ST` / `STX <XAM` |
| `LDA XAML`/`CMP L`/`LDA XAMH`/`SBC H`/`BCS` | `LDX <XAM` / `CMPX <HEX` / `BHS` (**not** `LDD`/`CMPD` -- see below) |
| `JMP (XAML)` | `JMP [XAM]` — extended indirect |
| `(XAML,X)` with `X`=0 | `LDX <XAM` / `LDA ,X` |

`TSTB` / `BMI` / `BPL` on `B` preserve the sign tests that drive backspace
(`BMI GETLINE` past start of line) and the 127-character auto-ESC.

**Register conflict: the 16-bit compare must not use D.** `D` is `A:B`, and
`B` holds the text index, so `LDD <XAM` silently overwrites the parser's
position with `XAM`'s low byte. The 6502 original had no such conflict --
its compare used `A` alone and the index lived in `Y`, a separate register.
Collapsing the compare to 16 bits reintroduces it. `X` is free at that
point, so the port uses `CMPX`. The same caution applies anywhere `B` is
live: `SCROLL` uses `LDD` for its block move and therefore saves `B`.
Caught in testing -- the symptom was the text index jumping to `$34`, the
low byte of the examined address, and the dispatcher then walking off the
end of the line buffer.

### 5.2 Translations that change

| Concern | Resolution |
|---|---|
| `BIT` / `BVC` MODE dispatch | explicit `BITA #$40` then `BITA #$80` — the 6809's `BITA` clears V rather than loading bit 6 |
| `ROL L` / `ROL H` | `ROL <HEX+1` / `ROL <HEX` — order flips, 6809 is big-endian |
| `MOD8CHK` always-taken `BPL` | `BRA` — it does not affect CC, so Z from `ANDA #$07` still reaches `NXTPRNT`'s `BNE` |
| `CLD` | deleted, no decimal mode on 6809 |
| `CLI` | **inverts** to `ORCC #$50`, in *both* builds. In the cart build BASIC never initializes, so no IRQ handler is installed and enabling interrupts would crash on the first VSYNC. In the BIN build BASIC's handler does exist, but masking is safe because the monitor never returns and so never has to restore it |
| High-bit-set ASCII | plain ASCII. `EORA #$30` and `CMPA #$FA` carry over unchanged, because `'A'` differs from `$C1` only in bit 7 |
| **Carry convention on compare** | **The 6809 inverts the 6502's.** The 6502's `CMP` sets C=1 when `A >= M`; the 6809's `CMPA` sets C=1 on *borrow*, i.e. when `A < M`. The original's `ADC #$88` relies on the 6502 carry being set by the preceding failed compare, so it becomes `ADDA #$89` here, with the `+1` folded into the constant. Verified on the emulator: with `ADDA #$88`, `'A'` yields `$F9` rather than `$FA` and every hex letter A-F is rejected. Everywhere else the port uses semantic mnemonics (`BLO`, `BHS`, `BLS`) instead of transliterating `BCC`/`BCS`, and those are correct on the 6809 unchanged |

### 5.3 Output format

`XXXX: bb bb bb bb bb bb bb bb` is 29 characters, so the original's
8-bytes-per-line dump fits the CoCo's 32-column screen exactly. Faithful
and CoCo-appropriate coincide; no adaptation is needed.

## 6. I/O layer

Two entry points, `GETKEY` and `PUTCHAR`. The only code that touches
hardware.

### 6.1 GETKEY

Strobe each of 8 columns on PIA0 `$FF02`, read 7 rows from `$FF00` (active
low), index a 56-byte ASCII table. Blocks until a key is down, then waits
for all-keys-up to debounce.

Every key the monitor needs is unshifted: `.` and `:` are their own keys,
left-arrow is the natural backspace (matching the Apple I's `_`), and
BREAK serves as ESC. The scanner therefore needs no shift handling.

### 6.2 PUTCHAR

Translate ASCII to VDG screen code, store at `CURSOR`, advance. Handle CR.
Scroll by moving `$0420-$05FF` down to `$0400` and blanking the last row.

### 6.3 Screen and PIA initialization

Setting the PIA direction registers and the 32x16 text mode is idempotent
— BASIC already programs them identically — so the same init code is
correct in both builds and needs no conditional.

## 7. Error handling

Faithful: the only error path is the original's. A non-hex character where
hex is expected, or a line yielding no hex digits, prints `\` and restarts
the line. No address bounds checking; `R` into nothing is the user's
problem, exactly as on the Apple I.

## 8. Build

```
lwasm --format=decb -DTARGET=0 -o build/wozmon.bin src/wozmon.asm
lwasm --format=raw  -DTARGET=1 -o build/wozmon.rom src/wozmon.asm
```

Driven by a two-target Makefile. The cart image must be exactly 8192
bytes.

The DECB format records both a load address and an execution address. The
load address follows from `ORG $4000`; the execution address is set by the
`end <entry>` directive, so `LOADM"WOZMON"` followed by `EXEC` enters at
the glue rather than requiring the user to type an address.

## 9. Testing

1. **Assembly** — both targets assemble clean; the cart image is exactly
   8192 bytes.
2. **Semantic diff** — disassemble the output with the project's
   `dasm6809.py` and walk it against the 6502 original state by state,
   confirming each translation in section 5.
3. **On-device**, via the `coco3-debug` MCP bridge: write a known pattern
   to RAM, drive the monitor, and check the dump. Cases: single examine,
   block examine across a `$xxFF` page boundary (the `INC XAM` carry
   path), `XXXX:` store, store continuation with a bare `:`, backspace,
   ESC, and `R`.

## 10. Verification items

Two facts are unresolved and are to be settled empirically as the first
implementation step, not assumed. The debug bridge was unreachable at
design time (two timeouts), so neither could be checked.

1. **ASCII to VDG screen code.** The MC6847 uses a 64-entry character set
   beginning at `@`, so the code is `ASCII AND $3F`. Bit 6 is the
   inverse-video bit, and the polarity the CoCo's normal black-on-green
   text uses is not confirmed. The mapping is isolated in a single routine
   and is either `ANDA #$3F` or `ANDA #$3F` / `ORA #$40`. Resolve by
   writing a byte ramp to `$0400` and screenshotting. The design is
   unaffected either way.
2. **Cart autostart.** Exactly what Color BASIC's reset routine checks at
   `$C000` before jumping there. Affects the cart build's header only.

**Risk.** If the bridge stays unreachable, test step 3 has no substitute.
A host-side 6809 simulator would need to be sourced before much code is
written; this should be raised rather than worked around.

## 11. Out of scope

No `G`/fill/move/search commands, no cassette or disk save-load, no
lowercase, no 40- or 80-column modes, no CoCo 3 support, and no exit to
BASIC. Any of these would be a separate change with its own design.
