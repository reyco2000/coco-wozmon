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

            end ENTRY
