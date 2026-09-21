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
