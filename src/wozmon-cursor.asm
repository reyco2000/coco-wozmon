;==============================================================================
; WOZMON for the TRS-80 Color Computer 2  --  BLINKING CURSOR VERSION
;==============================================================================
;------------------------------------------------------------------------------
; CREDITS
;
;   Original Apple I monitor ("Wozmon"), 1976
;       Steve Wozniak
;       256 bytes of ROM, and the entire software an Apple I shipped with.
;
;   6809 / TRS-80 Color Computer 2 port
;       Reinaldo Torres  --  CoCoByte Club
;       Claude (Anthropic)
;------------------------------------------------------------------------------
;
; A memory monitor: a tiny program that lets you look at memory, change it,
; and run code -- with no operating system underneath. Ported from Steve
; Wozniak's Apple I monitor of 1976, which fitted in 256 bytes of ROM and was
; the entire software the Apple I shipped with.
;
; COMMANDS
;   1000            examine the byte at $1000
;   1000.100F       dump a range, 8 bytes per line
;   1000: DE AD     store bytes starting at $1000
;   :BE EF          keep storing where the last store left off
;   1000R           run the machine code at $1000
;   left-arrow      backspace        BREAK  cancel the line
;
; There is deliberately no way to exit, exactly as on the Apple I. Press the
; RESET button to leave.
;
; THIS VERSION differs from src/wozmon.asm in exactly one routine, GETKEY,
; which blinks a '@' cursor at the typing position while it waits for a key.
; Everything else is identical. See the long comment above GETKEY for why
; the cursor lives there and not in PUTCHAR.
;
;==============================================================================
; A SHORT ASSEMBLY PRIMER, IF YOU NEED ONE
;==============================================================================
;
; Assembly is a readable name for each instruction the processor actually
; executes; one line here becomes a few bytes of memory. The 6809 keeps its
; working values in REGISTERS:
;
;   A, B   Two 8-bit accumulators -- one byte each. General scratch.
;   D      A and B glued together as one 16-bit register. D IS A:B, the same
;          physical storage seen two ways. Writing D destroys both A and B.
;          That overlap causes a real bug later in this file; see XAMNEXT.
;   X, Y   16-bit index registers. These hold ADDRESSES and act as pointers.
;   U      A 16-bit register this program uses as a second pointer.
;   S      The stack pointer (see PSHS/PULS below).
;   DP     "Direct page" -- 8 bits. Explained under setdp, below.
;   PC     Program counter: the address of the next instruction.
;   CC     Condition codes: single-bit flags describing the last result.
;
; FLAGS. Most instructions set flags as a side effect. This program uses:
;   Z  "zero"     set when a result was zero
;   N  "negative" set when bit 7 of a result was 1
;   C  "carry"    set when an operation carried or borrowed out
; Branch instructions do nothing but test these flags.
;
; ADDRESSING MODES -- how an instruction says WHERE its operand is. Getting
; these confused is the classic beginner's bug, so they are named throughout:
;
;   lda #$41     IMMEDIATE. The "#" means the literal value. A becomes $41.
;   lda $041     EXTENDED. A full 16-bit address. A becomes the byte at $0041.
;   lda <MODE    DIRECT. One byte of address; DP supplies the high byte.
;   lda ,x       INDEXED. A becomes the byte that X points at.
;   lda ,x+      INDEXED, POST-INCREMENT. Load, then advance X by one.
;   lda ,x++     Same, advancing by two (used for 16-bit loads).
;   lda b,u      ACCUMULATOR-OFFSET INDEXED. Address is U plus B. This is an
;                array lookup in one instruction, and it is how this port
;                replaces the 6502 original's "LDA IN,Y".
;   jmp [XAM]    INDIRECT. Read a 16-bit address FROM $XAM, then jump there.
;
; $ marks hexadecimal. $10 is sixteen, not ten.
;
;==============================================================================
; HOW THE PROGRAM IS ORGANISED
;==============================================================================
;
;   ENTRY  -> sets up the machine, then loops forever:
;               GETLINE    collect a line of typed characters into a buffer
;               NEXTITEM   walk that line left to right, acting on each item
;
; NEXTITEM keeps a single byte called MODE that says what a number means
; right now: examine it, store to it, or dump up to it. Punctuation changes
; MODE. That one byte is the whole "parser", and it is why the original fit
; in 256 bytes.
;
; Underneath sit the building blocks: PUTCHAR and GETKEY talk to the
; hardware, PRBYTE prints hex, PARSEHEX reads hex.
;==============================================================================


;------------------------------------------------------------------------------
; BUILD CONFIGURATION
;
; This one file builds two different programs. Everything below is identical
; in both; only the addresses change. "ifndef/ifeq/else/endc" are directives
; to the ASSEMBLER, not instructions -- the unselected branch emits no bytes
; at all. Choose with: lwasm -DTARGET=1
;------------------------------------------------------------------------------

            ifndef TARGET           ; if the caller did not pick a target,
TARGET      equ 0                   ;   default to the disk-loadable build
            endc

            ifeq TARGET
; --- Build 0: a DECB binary, loaded into RAM from disk or tape ---
WORK        equ $3F00               ; our variables live here
ORIGIN      equ $4000               ; our code is loaded here
            else
; --- Build 1: an 8K cartridge ROM ---
; With a cartridge, BASIC never starts, so all of low RAM is ours.
WORK        equ $0600               ; just above the screen
ORIGIN      equ $C000               ; the CoCo's cartridge address
            endc


;------------------------------------------------------------------------------
; THE WORKSPACE -- our variables
;
; "equ" just gives a number a name; it generates no code. These are offsets
; into one 256-byte page of RAM. Keeping them in a single page is what makes
; the DIRECT addressing mode (below) usable, which keeps the program small.
;------------------------------------------------------------------------------

XAM         equ WORK+$00    ; 2 bytes: the "examine" address -- where we are
                            ;   currently reading from
ST          equ WORK+$02    ; 2 bytes: the "store" address -- where the next
                            ;   typed byte will be written
HEX         equ WORK+$04    ; 2 bytes: the number most recently typed in hex
YSAV        equ WORK+$06    ; 1 byte: saves a buffer position, so we can tell
                            ;   whether any hex digits were actually typed
MODE        equ WORK+$07    ; 1 byte: examine / store / dump. See NEXTITEM.
CURSOR      equ WORK+$08    ; 2 bytes: where the next character will be drawn
CURSAVE     equ WORK+$0A    ; 1 byte: the screen code hidden under the cursor
BLINK       equ WORK+$0B    ; 2 bytes: free-running counter that times the blink
IN          equ WORK+$80    ; 128 bytes: the line you are typing


;------------------------------------------------------------------------------
; HARDWARE ADDRESSES
;
; On the CoCo there are no I/O instructions. Hardware appears as memory: you
; talk to the keyboard and screen by reading and writing particular addresses.
;------------------------------------------------------------------------------

SCREEN      equ $0400       ; text screen: 32 columns x 16 rows = 512 bytes
SCREND      equ $0600       ; first address PAST the screen
PIA0DA      equ $FF00       ; keyboard: read which rows are pressed
PIA0DB      equ $FF02       ; keyboard: write which column to test


;------------------------------------------------------------------------------
; setdp -- a PROMISE to the assembler, not an instruction.
;
; DIRECT addressing gives an instruction one byte of address; the DP register
; supplies the missing high byte. So "lda <MODE" is 2 bytes instead of 3, and
; that saving repeated across the whole program is substantial.
;
; setdp tells the assembler "DP will hold this value at run time, so you may
; use the short form". It emits nothing. The code must ALSO load DP itself,
; at ENTRY below. If those two ever disagree, every variable access silently
; reads the wrong 256 bytes of memory with no error message -- which is why
; both are derived from the single WORK symbol and cannot drift apart.
;------------------------------------------------------------------------------

            setdp WORK/256
            org ORIGIN      ; assemble as though loaded at this address


;==============================================================================
; ENTRY -- where execution begins
;==============================================================================

ENTRY       orcc  #$50      ; ORCC sets bits in the condition-code register.
                            ; Bits $40 and $10 are the FIRQ and IRQ masks, so
                            ; this switches interrupts OFF.
                            ; NOTE: the 6502 original does the opposite here
                            ; (CLI enables them). On the cartridge build BASIC
                            ; never initialises, so no interrupt handler is
                            ; installed and allowing an interrupt would jump
                            ; through an uninitialised vector and crash.

            lda   #WORK/256 ; the high byte of our workspace address...
            tfr   a,dp      ; TFR = TransFeR between registers. DP now matches
                            ; the setdp promise above, making every "<name>"
                            ; reference correct.

            ifne TARGET
            lds   #$0800    ; Cartridge build only: BASIC never ran, so no
                            ; stack exists yet. Point S at $0800 and let it
                            ; grow downward through $07FF-$0700.
            endc            ; The disk build inherits BASIC's stack, which is
                            ; already valid.

            jsr   INITHW    ; set up the keyboard hardware
            jsr   CLS       ; clear the screen

            clr   <MODE     ; CLR writes zero. Start in "examine" mode.
            ldx   #0
            stx   <XAM      ; STX stores all 16 bits of X, so this clears
            stx   <ST       ; both bytes of XAM and of ST in one instruction.
            stx   <BLINK    ; start the cursor blink counter from a known value

; --- the main loop: read a line, act on it, repeat forever ---
MAINLOOP    jsr   GETLINE   ; collect keystrokes until Enter
            ldu   #IN       ; U points at the line buffer...
            clrb            ; ...and B is our position within it, starting 0.
                            ; Together they give "lda b,u" = read IN[B].
            clr   <MODE     ; Every line starts in examine mode. Without this,
                            ; a line that ended in store mode would leave the
                            ; NEXT line's address silently storing instead of
                            ; printing. The original resets it the same way
                            ; after each carriage return.
            jsr   NEXTITEM  ; interpret the line
            bra   MAINLOOP  ; BRA = branch always. Forever.


;==============================================================================
; INITHW -- prepare the keyboard hardware
;
; The keyboard hangs off a PIA (Peripheral Interface Adapter), a chip whose
; pins can each be an input or an output. Each half has two registers sharing
; one address; bit 2 of the control register picks which one you see. So the
; sequence is always: clear bit 2, write the directions, set bit 2 again.
;
; Harmless to run twice -- BASIC programs these identically -- so the same
; code is correct in both builds.
;==============================================================================

INITHW      clr   $FF01     ; control A bit 2 = 0: expose the DIRECTION register
            clr   $FF00     ; all 8 row pins are INPUTS (we read these)
            lda   #$34
            sta   $FF01     ; bit 2 = 1: expose the DATA register again
            clr   $FF03     ; same dance for the B side
            lda   #$FF
            sta   $FF02     ; all 8 column pins are OUTPUTS (we drive these)
            lda   #$34
            sta   $FF03
            rts             ; RTS = return to whoever called us


CR          equ $0D         ; ASCII carriage return
VDGSPC      equ $20         ; the screen code for a blank space


;==============================================================================
; PUTCHAR -- draw one character. Input: A = ASCII. Preserves A, B, X, U.
;
; The video chip does not use ASCII. It has a 64-character set that begins at
; '@', so the screen code is simply the low 6 bits of the ASCII value:
;   'A' $41 -> $01      '0' $30 -> $30      ' ' $20 -> $20
; Bit 6 selects inverse video. Masking it off with AND #$3F gives normal
; text, which hardware testing confirmed.
;
; A consequence: there is NO LOWERCASE. 'e' ($65) masks down to $25, which is
; '%'. Anything printed through here must be uppercase.
;==============================================================================

PUTCHAR     pshs  a,b,x     ; PSHS = PuSH onto the S stack. This saves the
                            ; caller's registers so we can use them freely and
                            ; hand them back untouched. A routine that does
                            ; this is safe to call from anywhere -- and this
                            ; one is called from nearly everywhere.

            cmpa  #CR       ; CMPA compares A against a value by subtracting
                            ; and setting flags, WITHOUT changing A.
            beq   PUTCR     ; BEQ branches if they were equal (Z flag set).

; --- an ordinary printable character ---
            ldx   <CURSOR   ; X = where to draw
            anda  #$3F      ; ASCII -> screen code (see the note above)
            sta   ,x+       ; store it at X, THEN advance X by one
            stx   <CURSOR   ; remember the new position
            bra   PUTCHK

; --- a carriage return: move to the start of the next row ---
PUTCR       ldd   <CURSOR   ; LDD loads 16 bits into D (= A and B together)
            subd  #SCREEN   ; convert the address into an offset 0..511
            orb   #31       ; ORB sets bits. Setting the low 5 bits rounds the
                            ; offset up to the last column of this row...
            addd  #1        ; ...and adding one steps into the next row.
            addd  #SCREEN   ; back to a real address
            std   <CURSOR

; --- did we run off the bottom of the screen? ---
PUTCHK      ldx   <CURSOR
            cmpx  #SCREND
            blo   PUTDONE   ; BLO = branch if LOwer (unsigned). Still on
                            ; screen, so nothing more to do.
            bsr   SCROLL    ; BSR = Branch to SubRoutine; like JSR but with a
                            ; shorter, relative address.

PUTDONE     puls  a,b,x,pc  ; PULS restores what PSHS saved. Naming PC as one
                            ; of the registers pulls the return address
                            ; straight into the program counter -- so this
                            ; single instruction both restores and returns.
                            ; A very common 6809 idiom.


;==============================================================================
; SCROLL -- shift rows 1-15 up by one, blank the bottom row.
;
; Note it saves B. It uses LDD for speed, and D includes B -- which callers
; may be relying on. See the warning in the primer at the top.
;==============================================================================

SCROLL      pshs  a,b,x,u
            ldx   #SCREEN+32    ; source: the second row
            ldu   #SCREEN       ; destination: the first row
SCRLP       ldd   ,x++          ; copy TWO bytes at a time and advance both
            std   ,u++          ; pointers by two -- half as many loops
            cmpx  #SCREND
            blo   SCRLP         ; keep going until the source runs off the end

            ldx   #SCREND-32    ; now blank the last row
            lda   #VDGSPC
SCRBLK      sta   ,x+
            cmpx  #SCREND
            blo   SCRBLK

            ldx   #SCREND-32
            stx   <CURSOR       ; park the cursor at the start of that row
            puls  a,b,x,u,pc


;==============================================================================
; CLS -- fill the whole screen with spaces and home the cursor.
;==============================================================================

CLS         pshs  a,x
            ldx   #SCREEN
            lda   #VDGSPC
CLSLP       sta   ,x+           ; write a space, step forward
            cmpx  #SCREND
            blo   CLSLP
            ldx   #SCREEN
            stx   <CURSOR
            puls  a,x,pc


ESC         equ $1B             ; we use the BREAK key for this
BS          equ $08             ; we use the left-arrow key for this


;==============================================================================
; SCANKEY -- is any key down? Returns A = its ASCII code, or 0. Preserves B,X,U.
;
; The keyboard is not 53 separate wires. The keys sit at the crossing points
; of a grid: 8 columns driven by us, 7 rows read back. To find a key you
; drive ONE column low and see which row wires go low in response. Do that
; for all 8 columns and you have scanned the whole keyboard.
;
; "Low" means pressed, because the electronics are active-low -- a 0 bit is
; a pressed key. That is why COMA appears below.
;
; The column walk uses a neat trick: B starts as %11111110, a single 0 in the
; low position. Rotating it left moves that 0 along, selecting each column in
; turn. After the eighth rotation the 0 falls out into the carry flag, which
; ends the loop -- no separate counter needed.
;==============================================================================

SCANKEY     pshs  b,x
            ldx   #KEYTAB       ; X walks through the table of key meanings
            ldb   #$FE          ; %11111110 -- column 0 selected

SKCOL       stb   PIA0DB        ; drive this column low
            lda   PIA0DA        ; read all 7 row wires back
            coma                ; COMA flips every bit, so "pressed" becomes 1
            anda  #$7F          ; keep only the 7 real rows
            bne   SKHIT         ; BNE = branch if not zero: something is down

            leax  7,x           ; LEAX = Load Effective Address. Computes an
                                ; address without loading memory -- here just
                                ; X = X + 7, stepping over this column's 7
                                ; table entries.
            orcc  #$01          ; force the carry flag to 1, so the rotate
                                ; feeds a 1 into the bottom of B
            rolb                ; ROLB rotates B left through carry: the 0
                                ; moves up one column, and the bit shifted out
                                ; of the top lands in carry.
            bcs   SKCOL         ; BCS = branch if carry set. Carry stays 1
                                ; until the 0 finally rotates out, after all
                                ; 8 columns -- then it clears and we fall out.

            clra                ; nothing pressed anywhere: return 0
            puls  b,x,pc

; --- a key is down; A holds the row bits. Which row is it? ---
SKHIT       clrb                ; B will count how many rows up it is
SKBIT       lsra                ; LSRA shifts A right; the bit that falls off
                                ; the bottom lands in carry.
            bcs   SKGOT         ; carry set means this row was the pressed one
            incb                ; not yet: try the next row up
            bra   SKBIT

SKGOT       abx                 ; ABX adds B to X. X was already at the start
                                ; of this column's entries, so this selects
                                ; the right row within it.
            lda   ,x            ; fetch the character from the table
            puls  b,x,pc


;==============================================================================
; GETKEY -- wait for a keypress and return it in A, blinking a cursor.
;
; THIS IS THE ONLY ROUTINE THAT DIFFERS from the plain monitor.
;
; A piece of history worth knowing: the original Wozmon contains no cursor
; code whatsoever. The Apple I did show a blinking '@' at the typing
; position, but it was produced by the terminal HARDWARE -- the shift
; register video section -- with no help from the software at all. Wozmon
; simply handed characters to the display and the terminal did the rest.
;
; The CoCo's video chip has no hardware cursor either. Color BASIC's
; familiar blinking block is software, drawn during BASIC's own keyboard
; poll. So to reproduce what an Apple I user actually saw, we have to draw
; one ourselves -- and the natural place is here, in the one routine that
; spends its time waiting.
;
; The method: remember the screen code already sitting at the cursor
; position, then alternate between that and a '@' on a free-running counter.
; Whichever happens to be showing when a key arrives, the original is put
; back before we return, so the cursor never leaves a mark behind.
;
; Two waits as before -- one for a key to go down, one for it to come back
; up (debouncing). Only the first one blinks.
;==============================================================================

CURGLYPH    equ '@'&$3F         ; the screen code for '@'. PUTCHAR masks ASCII
                                ; with $3F and '@' is $40, so this works out
                                ; to $00 -- the first character in the video
                                ; chip's 64-character set.

GETKEY      pshs  b,x
            ldx   <CURSOR       ; whatever is on screen where we are about to
            lda   ,x            ; type, save it so it can be put back later
            sta   <CURSAVE

GKWAIT      bsr   SCANKEY
            tsta                ; TSTA sets the flags from A without altering it
            bne   GKGOT         ; a key is down: stop blinking and take it

            ldx   <BLINK        ; no key yet, so tick the blink counter
            leax  1,x
            stx   <BLINK
            lda   <BLINK        ; the HIGH byte, which changes 256 times more
                                ; slowly than the low one
            bita  #$04          ; watch a single bit of it. It flips roughly
                                ; once a second at the CoCo's clock speed;
                                ; pick a higher bit to blink slower.
            beq   GKSHOW        ; bit clear: show what was underneath
            lda   #CURGLYPH     ; bit set:   show the cursor
            bra   GKDRAW
GKSHOW      lda   <CURSAVE
GKDRAW      ldx   <CURSOR
            sta   ,x            ; write straight to screen memory, NOT through
                                ; PUTCHAR -- PUTCHAR would advance the cursor,
                                ; and the cursor must stay where it is.
            bra   GKWAIT

GKGOT       pshs  a             ; save the key; SCANKEY is about to overwrite A
            lda   <CURSAVE      ; leave the screen exactly as we found it,
            ldx   <CURSOR       ; whichever half of the blink we stopped on
            sta   ,x
GKREL       bsr   SCANKEY       ; debounce: wait for every key to come up
            tsta
            bne   GKREL
            puls  a             ; recover the key we found
            puls  b,x,pc


;==============================================================================
; KEYTAB -- what each grid position means.
;
; 8 columns x 7 rows, stored column by column, matching the order SCANKEY
; walks them. A 0 marks a position whose key this monitor does not use.
;
; Every key the monitor needs happens to be unshifted -- '.' and ':' have
; their own keys on a CoCo -- so there is no shift handling anywhere.
;==============================================================================

KEYTAB      fcb   '@','H','P','X','0','8',CR      ; col 0  (ENTER)
            fcb   'A','I','Q','Y','1','9',0       ; col 1  (CLEAR unused)
            fcb   'B','J','R','Z','2',':',ESC     ; col 2  (BREAK = cancel)
            fcb   'C','K','S',0,'3',';',0         ; col 3
            fcb   'D','L','T',0,'4',',',0         ; col 4
            fcb   'E','M','U',BS,'5','-',0        ; col 5  (left = backspace)
            fcb   'F','N','V',0,'6','.',0         ; col 6
            fcb   'G','O','W',' ','7','/',0       ; col 7  (SHIFT unused)


;==============================================================================
; PRBYTE -- print A as two hex digits, e.g. $AF prints "AF".
;
; Note there is no RTS here: PRBYTE runs off its last line straight into
; PRHEX. That is deliberate and is called FALLING THROUGH -- it saves the
; bytes a jump would cost, and PRHEX is exactly what we wanted next anyway.
;==============================================================================

PRBYTE      pshs  a             ; keep the original byte for the second digit
            lsra                ; shift right four times, moving the high
            lsra                ; nibble down into the low position
            lsra
            lsra
            bsr   PRHEX         ; print it as the first digit
            puls  a             ; restore the byte, low nibble still intact
                                ; ...and fall through to print it:

;------------------------------------------------------------------------------
; PRHEX -- print the low 4 bits of A as one hex digit.
;
; Digits 0-9 and letters A-F are not adjacent in ASCII: '9' is $39 but 'A' is
; $41, with ':;<=>?@' in between. So add '0' to get a digit, and if the
; result landed past '9', skip those seven punctuation characters.
;------------------------------------------------------------------------------

PRHEX       anda  #$0F          ; isolate the low 4 bits (a value 0-15)
            adda  #'0'          ; 0-9 now read as the characters '0'-'9'
            cmpa  #'9'
            bls   PRHOUT        ; BLS = branch if lower or same: it was a digit
            adda  #7            ; it was 10-15: jump the gap to 'A'-'F'
PRHOUT      jmp   PUTCHAR       ; A TAIL CALL: jump rather than call, so
                                ; PUTCHAR's own return goes straight back to
                                ; OUR caller. Saves a return instruction.


;==============================================================================
; PARSEHEX -- read hex digits from the typed line into HEX.
;
;   In:  B = position in the line, U = start of the line buffer
;   Out: B = position of the first character that was not hex
;        Z flag set if no digits were found at all (i.e. bad input)
;
; The clever part is the conversion test, inherited from the original. EOR
; #$30 turns '0'-'9' into $00-$09; anything 10 or more was not a digit. Then
; ADDA #$89 maps 'A'-'F' onto $FA-$FF, so a single unsigned compare against
; $FA accepts exactly the six hex letters and rejects everything else.
;
; WHY $89 AND NOT THE ORIGINAL'S $88: the 6502 sets carry when a compare
; finds "greater or equal", and the original folds that carry into an ADC.
; The 6809 sets carry on BORROW -- the opposite convention -- so that carry
; is not there, and the +1 must be built into the constant instead. With $88,
; 'A' produces $F9 rather than $FA and every hex letter is rejected.
;==============================================================================

PARSEHEX    stb   <YSAV         ; remember where the digits began, so we can
                                ; tell at the end whether we consumed any

PHNEXT      lda   b,u           ; read IN[B] -- one instruction, thanks to
                                ; accumulator-offset indexing
            eora  #$30          ; EORA = exclusive-OR. Maps '0'-'9' to $00-$09.
            cmpa  #$0A
            blo   PHDIG         ; below 10: a decimal digit, go use it
            adda  #$89          ; maps 'A'-'F' to $FA-$FF (see above)
            cmpa  #$FA
            blo   PHDONE        ; below $FA: not a hex character. Stop.

; --- we have a digit worth 0-15 in A; fold it into HEX ---
PHDIG       lsla                ; move it into the TOP 4 bits of A, so that
            lsla                ; shifting left pushes it out one bit at a
            lsla                ; time into the carry flag
            lsla
            ldy   #4            ; four bits to transfer
PHSHIFT     lsla                ; next bit of the digit falls into carry
            rol   <HEX+1        ; rotate carry into the low byte of HEX...
            rol   <HEX          ; ...and the low byte's top bit into the high.
                                ; LOW BYTE FIRST: the 6809 stores 16-bit values
                                ; high byte first, the opposite of the 6502, so
                                ; this order is reversed from the original.
            leay  -1,y          ; count down
            bne   PHSHIFT
            incb                ; advance past this character
            bra   PHNEXT        ; and look for another digit

PHDONE      cmpb  <YSAV         ; equal means B never moved: no digits at all.
                                ; The caller reads the Z flag to detect that.
            rts


;==============================================================================
; GETLINE -- collect typed characters into IN until Enter. Returns B = 0.
;==============================================================================

GETLINE     lda   #CR           ; start on a fresh line
            jsr   PUTCHAR
GLINIT      ldu   #IN           ; U = buffer, B = position in it
            clrb

GLNEXT      jsr   GETKEY        ; wait for a keystroke
            cmpa  #BS
            beq   GLBACK
            cmpa  #ESC
            beq   GLESC

            sta   b,u           ; store the character as IN[B]
            jsr   PUTCHAR       ; and show it
            cmpa  #CR
            beq   GLDONE        ; Enter: the line is complete
            incb
            bpl   GLNEXT        ; BPL = branch if plus, i.e. bit 7 still clear.
                                ; B is 8 bits, so it goes "negative" at 128 --
                                ; a free buffer-overflow check. Past 127
                                ; characters we fall into GLESC and start over.

; --- BREAK, or an over-long line: abandon it ---
GLESC       lda   #'\'          ; the monitor's universal "that was rejected"
            jsr   PUTCHAR
            bra   GETLINE       ; throw the line away and begin again

; --- backspace ---
GLBACK      tstb
            beq   GETLINE       ; already at the start: just restart the line
            decb                ; step the position back one
            lda   #'_'          ; The Apple I's backspace key WAS the '_' key
            jsr   PUTCHAR       ; and it echoed one, so this reproduces what
            bra   GLNEXT        ; the original displayed.

GLDONE      clrb                ; hand back a position of 0 for the parser
            rts


STORMODE    equ $74             ; ':' ($3A) shifted left once
BLOKMODE    equ $AE             ; '.' in the Apple I's high-bit ASCII


;==============================================================================
; NEXTITEM -- interpret the line. B = position, U = buffer.
;
; This is the heart of the monitor. It walks the line one item at a time,
; and MODE remembers what a number currently means:
;
;   MODE $00  examine: print the byte at this address
;   MODE $74  store:   write this byte to memory     (set by ':')
;   MODE $AE  dump:    print everything up to here   (set by '.')
;
; So "1000: DE AD" reads as: address 1000 (examine it), then ':' switches to
; store mode, then DE and AD are written. That is also why typing it echoes
; "1000: 00" first -- the address really is examined before the ':' is seen.
;==============================================================================

NEXTITEM    lda   b,u           ; the character at the current position
            cmpa  #CR
            beq   NIDONE        ; end of the line

            cmpa  #'.'
            blo   NISKIP        ; anything below '.' -- notably space -- is
                                ; just a separator, so skip it
            beq   NIBLOK
            cmpa  #':'
            beq   NISTOR
            cmpa  #'R'
            beq   NIRUN
            bra   NIHEX         ; none of the above: it must be a number

NISKIP      incb                ; step over the separator
            bra   NEXTITEM

NIBLOK      lda   #BLOKMODE     ; '.' seen: switch to dump mode
            sta   <MODE
            incb
            bra   NEXTITEM

NISTOR      lda   #STORMODE     ; ':' seen: switch to store mode
            sta   <MODE
            incb
            bra   NEXTITEM

NIRUN       jmp   [XAM]         ; 'R' seen: run the user's code.
                                ; The brackets mean INDIRECT -- read the
                                ; 16-bit address stored at XAM, and jump
                                ; THERE. We arrived inside a JSR from
                                ; MAINLOOP, so its return address is still on
                                ; the stack: a program that ends in RTS comes
                                ; straight back to the monitor prompt.

NIHEX       ldx   #0
            stx   <HEX          ; clear the accumulator before reading digits
            jsr   PARSEHEX
            beq   NIESC         ; Z set: no digits found, so this was garbage
            jmp   STOREOREXAM   ; act on the number according to MODE

; The original prints '\' and then reads a fresh line. Returning to MAINLOOP
; is exactly equivalent, and avoids consuming a line here and then having
; MAINLOOP consume another one on top.
NIESC       lda   #'\'
            jsr   PUTCHAR
            rts

NIDONE      rts


;==============================================================================
; STOREOREXAM -- a number was just parsed; MODE decides what to do with it.
;
; The 6502 original tests MODE with a single BIT instruction, which loads
; bits 6 and 7 straight into flags. The 6809's BITA does not do that, so the
; same decision takes two explicit tests here.
;==============================================================================

STOREOREXAM lda   <MODE
            bita  #$40          ; BITA = AND for the flags only; A is unchanged
            bne   DOSTORE       ; bit 6 set ($74): store mode
            bita  #$80
            bne   XAMNEXT       ; bit 7 set ($AE): dump mode

; --- examine mode: this number is a new address to look at ---
            ldx   <HEX
            stx   <ST           ; future stores will start here too
            stx   <XAM
            clra                ; forces the Z flag set, which tells the code
                                ; just below to print the address -- see the
                                ; note at NXTPRNT.

;------------------------------------------------------------------------------
; NXTPRNT -- print one byte, starting a new line with its address when needed.
;
; This is entered with the Z flag carrying a message: Z set means "begin a
; new line, print the address first", Z clear means "we are mid-line, just
; add another byte". Using a flag as an argument is very much of its era --
; compact, and the reason the original fitted in 256 bytes.
;------------------------------------------------------------------------------

NXTPRNT     bne   PRDATA        ; mid-line: skip the address
            lda   #CR
            jsr   PUTCHAR
            lda   <XAM          ; high byte of the address
            jsr   PRBYTE
            lda   <XAM+1        ; low byte
            jsr   PRBYTE
            lda   #':'
            jsr   PUTCHAR

PRDATA      lda   #' '
            jsr   PUTCHAR
            ldx   <XAM
            lda   ,x            ; read the byte that XAM points at
            jsr   PRBYTE

; --- step to the next address, and decide whether we are finished ---
XAMNEXT     clr   <MODE         ; after any dump we revert to examine mode

; The 16-bit compare must NOT use D. D is A:B, and B is holding our position
; in the typed line -- so "ldd <XAM" would quietly overwrite that position
; with the low byte of the address, and the parser would wander off into
; unwritten memory. The 6502 original had no such clash: its compare used A
; alone, with the position kept in Y. X is free here, so CMPX does the job
; without touching B. (This was a real bug, found by tracing.)
            ldx   <XAM
            cmpx  <HEX
            bhs   TONEXTITEM    ; BHS = branch if higher or same: we have
                                ; reached the end of the requested range
            leax  1,x           ; advance the examine address
            stx   <XAM
            lda   <XAM+1
            anda  #$07          ; every 8th address has zero in its low 3 bits,
                                ; which sets Z -- and Z set means "start a new
                                ; line". That is how the dump breaks into rows
                                ; of 8 without needing a counter.
            bra   NXTPRNT       ; BRA does not alter flags, so the Z we just
                                ; computed survives the jump.

TONEXTITEM  jmp   NEXTITEM      ; back to the line, to read the next item


;==============================================================================
; DOSTORE -- store mode: write the typed byte into memory.
;==============================================================================

DOSTORE     lda   <HEX+1        ; only the low byte: "1234" stores $34
            ldx   <ST
            sta   ,x+           ; write it, and advance the store address
            stx   <ST
            jmp   NEXTITEM


;------------------------------------------------------------------------------
; Cartridge builds must be exactly 8192 bytes. ZMB = Zero Memory Bytes; "*"
; means "the current address", so this pads out whatever is left.
;------------------------------------------------------------------------------

            ifne TARGET
            zmb   $E000-*
            endc

            end ENTRY           ; END marks the source finished, and names the
                                ; address execution should begin at.
