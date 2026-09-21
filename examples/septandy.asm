;==============================================================================
; HAPPY SEPTANDY  --  a first 6809 assembly program for the CoCo Wozmon monitor
;==============================================================================
;
; CREDITS
;   Wozmon, the Apple I monitor this runs under -- Steve Wozniak, 1976
;   6809 / Color Computer 2 port -- Reinaldo Torres (CoCoByte Club)
;                                   and Claude (Anthropic)
;
; WHAT THIS DOES
;   Prints HAPPY SEPTANDY on the screen, then returns to the monitor prompt.
;   Septandy is the CoCo and Tandy community's September celebration.
;
; HOW TO RUN IT
;   Type these lines at the monitor (it echoes "<addr>: 00" before each
;   store -- that is normal, see the note at the bottom of this file):
;
;       1000: 8E 10 0D A6 80 27 05 BD
;       1008: 40 3C 20 F7 39 0D 48 41
;       1010: 50 50 59 20 53 45 50 54
;       1018: 41 4E 44 59 00
;       1000R
;
;------------------------------------------------------------------------------
; BACKGROUND, IF YOU ARE NEW TO ASSEMBLY
;
; Assembly is a human-readable name for each instruction the CPU physically
; executes. One line here becomes one instruction -- a few bytes of memory.
; The 6809 chip inside the CoCo has a handful of internal storage slots
; called REGISTERS. This program uses three of them:
;
;   A   "accumulator"  -- 8 bits, holds one byte. General-purpose scratch;
;                         most arithmetic and character handling goes here.
;   X   "index register" -- 16 bits, holds an ADDRESS. Used as a pointer
;                         that walks through memory.
;   DP  "direct page"  -- 8 bits, supplies the high byte of an address so
;                         common variables can be reached in fewer bytes.
;                         You never touch it here, but see the note below.
;
; Two pieces of notation do most of the work:
;
;   #value    The "#" means IMMEDIATE: use this literal number itself.
;             Without "#", the number is an ADDRESS and the CPU fetches
;             whatever is stored there. This distinction is the single
;             most common source of bugs when learning assembly.
;             LDA #$41  ->  A becomes $41
;             LDA $41   ->  A becomes whatever byte lives at address $41
;
;   $         Marks a hexadecimal (base 16) number. $10 is 16, not ten.
;
; The CPU also keeps CONDITION FLAGS -- one-bit results of the last
; operation. This program uses the Z ("zero") flag: it is set to 1 whenever
; an operation produces zero. Branch instructions test these flags.
;==============================================================================


;------------------------------------------------------------------------------
; EQUATES -- names for fixed numbers. These generate no code at all; the
; assembler just substitutes the value wherever the name appears. Naming
; things costs nothing and makes the program readable.
;------------------------------------------------------------------------------

PUTCHAR     equ $403C   ; Address of the monitor's own "print one character"
                        ; routine. Rather than writing to screen memory
                        ; ourselves, we borrow it -- so we inherit its cursor
                        ; tracking, its ASCII-to-screen translation, and its
                        ; scrolling. Reusing what already works is as good an
                        ; idea in assembly as anywhere else.
                        ;
                        ; NOTE: this address belongs to the .BIN build, which
                        ; loads at $4000. The cartridge build relocates the
                        ; whole monitor to $C000, so PUTCHAR moves with it.

CR          equ $0D     ; ASCII carriage return. $0D = 13 decimal. Printing
                        ; one moves the cursor to the start of the next line.


            org $1000   ; ORG = "origin": assemble as though this code lives
                        ; at address $1000. It fixes where the program expects
                        ; to be, so you must load it there too. $1000 is
                        ; comfortably clear of the screen ($0400-$05FF) and of
                        ; the monitor's own workspace ($3F00-$4214).


;------------------------------------------------------------------------------
; THE PROGRAM
;
; The shape is a classic string-printing loop:
;
;       point X at the text
;   +-> fetch the character X points at, and step X forward
;   |   if that character was zero, we are done
;   |   otherwise print it
;   +-- go back and do it again
;
; A label (a name in the leftmost column) is just a name for the address of
; the line it sits on. The assembler works out the actual numbers.
;------------------------------------------------------------------------------

START       ldx   #MSG  ; LDX = LoaD X. The "#" matters enormously here: we
                        ; want X to hold the ADDRESS of MSG, not the contents
                        ; of that address. X is now a pointer aimed at the
                        ; first byte of our text.

LOOP        lda   ,x+   ; LDA = LoaD A. ",X+" is INDEXED addressing with
                        ; POST-INCREMENT, and it does two things at once:
                        ;   1. load the byte that X currently points at
                        ;   2. THEN add 1 to X, so it points at the next byte
                        ; That is the whole "walk through a string" mechanism
                        ; in a single two-byte instruction. Loading also sets
                        ; the Z flag, which the next line depends on.

            beq   DONE  ; BEQ = Branch if EQual (to zero) -- it branches when
                        ; the Z flag is set. We never compared anything; the
                        ; LDA above already set Z if the byte it loaded was
                        ; zero. Our text ends with a zero byte, so this is how
                        ; the loop knows it has reached the end.
                        ; A zero byte used this way is called a TERMINATOR.

            jsr   PUTCHAR
                        ; JSR = Jump to SubRoutine. It pushes the address of
                        ; the following instruction onto the STACK, then jumps.
                        ; When the routine finishes with RTS, the CPU pops that
                        ; address back and carries on here -- this is how one
                        ; piece of code calls another and gets control back.
                        ; PUTCHAR prints whatever character is in A, which is
                        ; exactly what we loaded two lines ago.

            bra   LOOP  ; BRA = BRanch Always. An unconditional jump back to
                        ; the top. Nothing is tested. This closes the loop.

DONE        rts         ; RTS = ReTurn from Subroutine: pop an address off the
                        ; stack and jump to it.
                        ;
                        ; Why this lands you back at the monitor prompt: the
                        ; monitor's "R" command reaches your code with
                        ; JMP [XAM], from inside a routine the main loop had
                        ; called with JSR. That JSR's return address is still
                        ; sitting on the stack, so our RTS consumes it and
                        ; drops neatly back into the monitor.
                        ;
                        ; Practical rule: end your programs with RTS ($39) and
                        ; you keep the monitor. Fall off the end instead and
                        ; the CPU executes whatever bytes follow -- usually a
                        ; crash and a trip to the RESET button.


;------------------------------------------------------------------------------
; THE DATA
;
; These directives emit bytes rather than instructions. The CPU never
; "executes" them -- our code only ever reads them via X. They sit after the
; RTS precisely so control never reaches them.
;------------------------------------------------------------------------------

MSG         fcb   CR    ; FCB = Form Constant Byte: emit one literal byte.
                        ; Starting the message with a carriage return puts
                        ; our text on a fresh line instead of appending it to
                        ; whatever the monitor last printed.

            fcc   "HAPPY SEPTANDY"
                        ; FCC = Form Constant Characters: emit one byte per
                        ; character, as ASCII. 'H' becomes $48, 'E' $45, and
                        ; so on -- you can see those exact values in the hex
                        ; listing at the top of this file.
                        ;
                        ; UPPERCASE IS REQUIRED. The CoCo's video chip has a
                        ; 64-character set with no lowercase at all, and
                        ; PUTCHAR masks each byte with AND #$3F to fit it.
                        ; Lowercase 'e' ($65) would survive that mask as $25,
                        ; which displays as '%'. "Hello World" would come out
                        ; as garbage, so the message is written "HAPPY SEPTANDY".

            fcb   0     ; The terminator the BEQ above is watching for. Forget
                        ; this byte and the loop runs off the end of the
                        ; message, printing memory as characters until it
                        ; happens to hit a zero.


;==============================================================================
; TWO THINGS THAT SURPRISE PEOPLE
;
; 1. Typing "1000: 8E ..." echoes "1000: 00" first.
;    Not a bug, and not a fault of this program. The monitor walks the line
;    left to right: "1000" on its own is an EXAMINE request, so it prints the
;    byte currently at $1000. Only then does ":" switch it into store mode.
;    The original Apple I monitor behaves identically.
;
; 2. You do not have to set DP.
;    PUTCHAR reaches the monitor's variables through the direct page and
;    needs DP to still be $3F. The monitor never changes it, so it is already
;    correct when your code starts. But if you ever write a program that
;    changes DP itself, set it back before calling any monitor routine --
;    otherwise PUTCHAR reads its cursor from the wrong 256 bytes of memory
;    and writes characters somewhere unpredictable.
;==============================================================================
