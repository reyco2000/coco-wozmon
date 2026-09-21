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
            jsr   INITHW
            jsr   CLS
            clr   <MODE
            ldx   #0
            stx   <XAM
            stx   <ST
MAINLOOP    jsr   GETLINE
            ldu   #IN
            clrb
            clr   <MODE             ; every line starts in XAM mode, as the
            jsr   NEXTITEM          ; original does via LDA #0 / TAX / ASL /
                                    ; STA MODE after each CR
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
SCROLL      pshs  a,b,x,u
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
            puls  a,b,x,u,pc

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
            lda   #'_'                ; the Apple I's backspace key was '_',
            jsr   PUTCHAR             ; and it echoed one; match that display
            bra   GLNEXT
GLDONE      clrb
            rts

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
; The 16-bit compare must NOT use D: B holds the text index, and D is A:B,
; so LDD <XAM would overwrite it with XAM's low byte. The 6502 original had
; no such conflict -- its compare used A alone and the index lived in Y.
; X is free here, so CMPX does the same job without touching B.
            ldx   <XAM
            cmpx  <HEX
            bhs   TONEXTITEM         ; reached the end of the range
            leax  1,x
            stx   <XAM
            lda   <XAM+1
            anda  #$07               ; new line every 8 bytes
            bra   NXTPRNT            ; BRA does not disturb Z
TONEXTITEM  jmp   NEXTITEM

; --- DOSTORE: write HEX's low byte at ST, then advance ST. ---
DOSTORE     lda   <HEX+1
            ldx   <ST
            sta   ,x+
            stx   <ST
            jmp   NEXTITEM

            ifne TARGET
            zmb   $E000-*           ; pad the cart image to exactly 8K
            endc

            end ENTRY
