; HELLO WORLD for CoCo Wozmon
; Assembles to $1000. Type it in with the monitor's store command, then
; run it with "1000R".
;
; Calls the monitor's own PUTCHAR, so it inherits the cursor and scrolling.
; DP is still $3F when the monitor jumps here, which PUTCHAR requires.
;
; The monitor reaches user code via JMP [XAM] from inside NEXTITEM, which
; MAINLOOP called with JSR -- so MAINLOOP's return address is still on the
; stack and a plain RTS drops back into the monitor.

PUTCHAR     equ $403C               ; monitor entry, .BIN build at $4000
CR          equ $0D

            org $1000

START       ldx   #MSG
LOOP        lda   ,x+
            beq   DONE
            jsr   PUTCHAR
            bra   LOOP
DONE        rts                     ; back to the monitor prompt

MSG         fcb   CR
            fcc   "HELLO WORLD"
            fcb   0
