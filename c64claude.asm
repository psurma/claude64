; Claude Code Client for Commodore 64 Ultimate
; Chat with Claude AI via memory-mapped bridge
;
; Memory protocol:
;   $C000 OUT_FLAG  (0=idle, 1=msg ready)
;   $C001 OUT_LEN
;   $C002-$C0FF OUT_BUF (user message, PETSCII)
;   $C100 IN_FLAG   (0=idle, 1=response ready)
;   $C101 IN_LEN_LO
;   $C102 IN_LEN_HI
;   $C103-$C4FF IN_BUF (response text)
;   $C500 STATUS    (0=disconnected, 1=connected, 2=thinking)

; ---- Constants ----
CHROUT      = $ffd2
GETIN       = $ffe4
PLOT        = $fff0
SCNKEY      = $ff9f

SCREEN      = $0400
COLRAM      = $d800
BORDER      = $d020
BGCOL       = $d021
RASTER      = $d012

; Mailbox addresses
OUT_FLAG    = $c000
OUT_LEN     = $c001
OUT_BUF     = $c002
IN_FLAG     = $c100
IN_LEN_LO   = $c101
IN_LEN_HI   = $c102
IN_BUF      = $c103
STATUS      = $c500

; Screen layout
CHAT_TOP    = 3         ; first chat row
CHAT_BOT    = 21        ; last chat row
INPUT_ROW   = 23        ; input line row
STATUS_ROW  = 24        ; status bar row
SEP_ROW     = 22        ; separator row
CHAT_COLS   = 38        ; usable columns (1 margin each side)

; Colors
COL_BORDER  = 6         ; blue
COL_BG      = 0         ; black
COL_CHROME  = 14        ; light blue
COL_USER    = 13        ; light green
COL_CLAUDE  = 14        ; light blue
COL_STATUS  = 1         ; white
COL_INPUT   = 1         ; white

; Zero page variables
zp_ptr      = $fb       ; general purpose pointer (2 bytes)
zp_ptr2     = $fd       ; second pointer (2 bytes)

*= $0801

; BASIC stub: 10 SYS 2064
!byte $0b, $08
!byte $0a, $00
!byte $9e
!byte $32, $30, $36, $34
!byte $00
!byte $00, $00

*= $0810

; ============================================================
; INIT
; ============================================================
init:
            ; Set colors
            lda #COL_BORDER
            sta BORDER
            lda #COL_BG
            sta BGCOL

            ; Force uppercase+graphics charset
            lda #$8e        ; PETSCII: switch to uppercase
            jsr CHROUT

            ; Clear screen
            lda #$93
            jsr CHROUT

            ; Set text color to light blue
            lda #$9a        ; PETSCII: light blue text
            jsr CHROUT

            ; Clear mailbox flags
            lda #0
            sta OUT_FLAG
            sta IN_FLAG
            sta STATUS
            sta input_len
            sta waiting_flag
            sta chat_row

            ; Set initial chat row
            lda #CHAT_TOP
            sta chat_row

            ; Draw the UI chrome
            jsr draw_chrome

            ; Draw initial status
            jsr draw_status

            ; Show input prompt
            jsr draw_input_prompt

; ============================================================
; MAIN LOOP
; ============================================================
main_loop:
            ; Wait for raster (simple vsync)
-           lda RASTER
            cmp #251
            bne -

            ; Check keyboard
            jsr check_keyboard

            ; Check for incoming response
            jsr check_response

            ; Update status display periodically
            jsr draw_status

            jmp main_loop

; ============================================================
; DRAW CHROME - Title bar, separator
; ============================================================
draw_chrome:
            ; Use CHROUT for all chrome drawing (correct PETSCII rendering)

            ; -- Row 0: top border --
            clc
            ldx #0
            ldy #0
            jsr PLOT

            lda #$b0        ; PETSCII top-left corner
            jsr CHROUT
            ldx #38
.topline:   lda #$c0        ; PETSCII horizontal line
            jsr CHROUT
            dex
            bne .topline
            lda #$ae        ; PETSCII top-right corner
            jsr CHROUT

            ; -- Row 1: title --
            clc
            ldx #1
            ldy #0
            jsr PLOT

            lda #$dd        ; PETSCII left vertical bar
            jsr CHROUT

            ldx #0
.titleloop: lda title_pet,x
            beq .titlepad
            jsr CHROUT
            inx
            bne .titleloop
.titlepad:
            ; Pad with spaces to col 39
            clc
            ldx #1
            ldy #39
            jsr PLOT
            lda #$dd        ; PETSCII right vertical bar
            jsr CHROUT

            ; -- Row 2: bottom border --
            clc
            ldx #2
            ldy #0
            jsr PLOT

            lda #$ad        ; PETSCII bottom-left corner
            jsr CHROUT
            ldx #38
.botline:   lda #$c0        ; PETSCII horizontal line
            jsr CHROUT
            dex
            bne .botline
            lda #$bd        ; PETSCII bottom-right corner
            jsr CHROUT

            ; -- Row 22: separator --
            clc
            ldx #SEP_ROW
            ldy #0
            jsr PLOT

            ldx #40
.sepline:   lda #$c0        ; PETSCII horizontal line
            jsr CHROUT
            dex
            bne .sepline

            ; Set chrome color on relevant rows
            ldx #0
            lda #COL_CHROME
.colloop:   sta COLRAM,x        ; row 0
            sta COLRAM+40,x     ; row 1
            sta COLRAM+80,x     ; row 2
            sta COLRAM+880,x    ; row 22
            inx
            cpx #40
            bne .colloop

            rts

; Title text in PETSCII
title_pet:
            !raw "  CLAUDE CODE FOR C64   "
            !byte 0

; ============================================================
; DRAW STATUS BAR
; ============================================================
draw_status:
            ; Row 24, calculate offset: 24*40 = 960
            lda STATUS
            cmp #2
            beq .thinking
            cmp #1
            beq .connected
            ; Default: waiting for bridge
            ldx #0
-           lda status_waiting,x
            beq .pad_status
            sta SCREEN+960,x
            lda #7          ; yellow
            sta COLRAM+960,x
            inx
            cpx #40
            bne -
            jmp .pad_status

.connected:
            lda waiting_flag
            bne .show_thinking
            ldx #0
-           lda status_ready,x
            beq .pad_status
            sta SCREEN+960,x
            lda #5          ; green
            sta COLRAM+960,x
            inx
            cpx #40
            bne -
            jmp .pad_status

.show_thinking:
.thinking:
            ldx #0
-           lda status_think,x
            beq .pad_status
            sta SCREEN+960,x
            lda #10         ; light red
            sta COLRAM+960,x
            inx
            cpx #40
            bne -

.pad_status:
            ; Clear rest of status line
            cpx #40
            bcs .status_done
            lda #32         ; space
            sta SCREEN+960,x
            lda #COL_STATUS
            sta COLRAM+960,x
            inx
            jmp .pad_status
.status_done:
            rts

; Status strings in screen codes
status_waiting:
            ;  W  A  I  T  I  N  G     F  O  R     B  R  I  D  G  E  .  .  .
            !byte 32,23,1,9,20,9,14,7,32,6,15,18,32,2,18,9,4,7,5,46,46,46
            !byte 0
status_ready:
            ;  R  E  A  D  Y
            !byte 32,18,5,1,4,25,32,32,32,32,32
            !byte 0
status_think:
            ;  T  H  I  N  K  I  N  G  .  .  .
            !byte 32,20,8,9,14,11,9,14,7,46,46,46
            !byte 0

; ============================================================
; DRAW INPUT PROMPT
; ============================================================
draw_input_prompt:
            ; Row 23, offset = 23*40 = 920
            ; Draw "> " prompt
            lda #30         ; screen code for '>'... actually let's use PETSCII via plot
            ; Use direct screen writes
            lda #62-64+128  ; '>' = PETSCII $3E... screen code = 62
            ; Actually: '>' PETSCII $3E -> screen code $3E (62) in uppercase mode
            lda #62         ; screen code for '>'
            sta SCREEN+920
            lda #32         ; space
            sta SCREEN+921
            lda #COL_INPUT
            sta COLRAM+920
            sta COLRAM+921

            ; Clear rest of input line
            ldx #2
-           lda #32
            sta SCREEN+920,x
            lda #COL_INPUT
            sta COLRAM+920,x
            inx
            cpx #40
            bne -
            rts

; ============================================================
; CHECK KEYBOARD
; ============================================================
check_keyboard:
            ; Don't accept input while waiting for response
            lda waiting_flag
            bne .kb_done

            jsr GETIN
            cmp #0
            beq .kb_done        ; no key pressed

            cmp #13             ; RETURN?
            beq .do_send

            cmp #20             ; DEL (backspace)?
            beq .do_backspace

            ; Printable character - add to buffer if room
            ldx input_len
            cpx #76             ; max ~2 lines (38*2)
            bcs .kb_done        ; buffer full

            sta input_buf,x     ; store PETSCII char
            inc input_len

            ; Echo to screen
            jsr echo_input
.kb_done:
            rts

.do_send:
            lda input_len
            beq .kb_done        ; don't send empty

            jsr send_message
            rts

.do_backspace:
            lda input_len
            beq .kb_done        ; nothing to delete

            dec input_len
            jsr echo_input
            rts

; ============================================================
; ECHO INPUT - Redraw input line from buffer
; ============================================================
echo_input:
            ; Clear input line (after prompt)
            ldx #2
-           lda #32
            sta SCREEN+920,x
            lda #COL_INPUT
            sta COLRAM+920,x
            inx
            cpx #40
            bne -

            ; Draw buffer contents
            ldx #0
            ldy input_len
            beq .echo_done
-           lda input_buf,x
            ; Convert PETSCII to screen code
            jsr petscii_to_screen
            sta SCREEN+922,x   ; offset 2 for "> "
            lda #COL_INPUT
            sta COLRAM+922,x
            inx
            dey
            bne -
.echo_done:
            rts

; ============================================================
; PETSCII TO SCREEN CODE conversion
; ============================================================
petscii_to_screen:
            ; Input: A = PETSCII code
            ; Output: A = screen code
            ; Uppercase mode mapping:
            cmp #$40
            bcc .pts_below40     ; $00-$3F: screen code = PETSCII
            cmp #$60
            bcc .pts_alpha       ; $40-$5F: letters -> subtract $40
            cmp #$80
            bcc .pts_60_7f       ; $60-$7F: screen code = PETSCII
            cmp #$a0
            bcc .pts_80_9f       ; $80-$9F: screen code = PETSCII - $80 (not common)
            ; $A0-$BF: graphics chars -> subtract $40
            sec
            sbc #$40
            rts
.pts_below40:
            rts                  ; return as-is ($20=space, digits, punctuation)
.pts_alpha:
            sec
            sbc #$40             ; A=$41 -> screen code $01, etc
            rts
.pts_60_7f:
            rts                  ; return as-is
.pts_80_9f:
            sec
            sbc #$80
            rts

; ============================================================
; SEND MESSAGE - Copy input to mailbox and signal bridge
; ============================================================
send_message:
            ; First, display user's message in chat area
            lda #COL_USER
            sta print_color

            ; Print "> " prefix
            lda #62             ; '>' screen code
            jsr print_chat_char
            lda #32             ; space
            jsr print_chat_char

            ; Print user's input
            ldx #0
            stx print_idx
.print_user:
            ldx print_idx
            cpx input_len
            beq .print_user_done
            lda input_buf,x
            jsr petscii_to_screen
            jsr print_chat_char
            inc print_idx
            jmp .print_user
.print_user_done:
            ; New line after user message
            jsr chat_newline

            ; Copy to mailbox
            ldx #0
-           cpx input_len
            beq +
            lda input_buf,x
            sta OUT_BUF,x
            inx
            bne -
+           lda input_len
            sta OUT_LEN

            ; Signal message ready
            lda #1
            sta OUT_FLAG

            ; Set waiting state
            lda #1
            sta waiting_flag

            ; Clear input
            lda #0
            sta input_len
            jsr draw_input_prompt

            rts

; ============================================================
; CHECK RESPONSE - Poll IN_FLAG for incoming message
; ============================================================
check_response:
            lda IN_FLAG
            cmp #1
            bne .cr_done

            ; Response is ready! Display it
            lda #COL_CLAUDE
            sta print_color

            ; Get length
            lda IN_LEN_LO
            sta resp_len
            lda IN_LEN_HI
            sta resp_len+1

            ; Print response with word wrap
            ; Use resp_ptr (dedicated variable) so scroll_chat can't corrupt it
            lda #<IN_BUF
            sta resp_ptr
            lda #>IN_BUF
            sta resp_ptr+1

.resp_loop:
            ; Check if we've printed all bytes
            lda resp_len
            bne .resp_cont
            lda resp_len+1
            beq .resp_done
.resp_cont:
            ; Load byte from response buffer using zp_ptr temporarily
            lda resp_ptr
            sta zp_ptr
            lda resp_ptr+1
            sta zp_ptr+1
            ldy #0
            lda (zp_ptr),y
            beq .resp_done      ; null terminator

            sta resp_char       ; save the character

            ; Advance our saved pointer
            inc resp_ptr
            bne +
            inc resp_ptr+1
+
            ; Decrement length
            lda resp_len
            sec
            sbc #1
            sta resp_len
            lda resp_len+1
            sbc #0
            sta resp_len+1

            ; Now process the character (zp_ptr may be clobbered by scroll)
            lda resp_char

            ; Check for newline (PETSCII $0D)
            cmp #$0d
            bne .resp_not_nl
            jsr chat_newline
            jmp .resp_loop

.resp_not_nl:
            jsr petscii_to_screen
            jsr print_chat_char

            jmp .resp_loop

.resp_done:
            ; Add blank line after response
            jsr chat_newline

            ; Clear flags
            lda #0
            sta IN_FLAG
            sta waiting_flag

            ; Redraw status and input
            jsr draw_status
            jsr draw_input_prompt

.cr_done:
            rts

; ============================================================
; PRINT CHAT CHAR - Print one screen code char at current chat position
; ============================================================
print_chat_char:
            ; A = screen code to print
            pha

            ; Calculate screen address: chat_row * 40 + chat_col
            ; Use zp_ptr2 for screen address
            lda chat_row
            jsr calc_row_offset  ; sets zp_ptr2 to SCREEN + row*40

            lda chat_col
            clc
            adc #1              ; 1 char left margin
            tay

            pla
            sta (zp_ptr2),y

            ; Set color
            lda zp_ptr2
            clc
            adc #<(COLRAM-SCREEN)
            sta zp_ptr2
            lda zp_ptr2+1
            adc #>(COLRAM-SCREEN)
            sta zp_ptr2+1

            lda print_color
            sta (zp_ptr2),y

            ; Advance column
            inc chat_col
            lda chat_col
            cmp #CHAT_COLS
            bcc .pcc_done

            ; Wrap to next line
            jsr chat_newline

.pcc_done:
            rts

; ============================================================
; CHAT NEWLINE - Move to next line in chat area, scroll if needed
; ============================================================
chat_newline:
            lda #0
            sta chat_col

            inc chat_row
            lda chat_row
            cmp #(CHAT_BOT+1)
            bcc .cn_done

            ; Need to scroll
            jsr scroll_chat
            lda #CHAT_BOT
            sta chat_row

.cn_done:
            rts

; ============================================================
; CALC ROW OFFSET - Calculate screen address for a row
; Input: A = row number
; Output: zp_ptr2 = SCREEN + row*40
; ============================================================
calc_row_offset:
            ; row * 40 = row * 32 + row * 8
            tax
            lda #0
            sta zp_ptr2
            sta zp_ptr2+1

            ; row * 8
            txa
            asl
            asl
            asl
            sta zp_ptr2
            lda #0
            adc #0              ; carry from shifts
            sta zp_ptr2+1

            ; Save row*8
            lda zp_ptr2
            pha
            lda zp_ptr2+1
            pha

            ; row * 32 = (row * 8) * 4
            asl zp_ptr2
            rol zp_ptr2+1
            asl zp_ptr2
            rol zp_ptr2+1

            ; Add row*8
            pla
            clc
            adc zp_ptr2+1
            sta zp_ptr2+1
            pla
            clc
            adc zp_ptr2
            sta zp_ptr2
            bcc +
            inc zp_ptr2+1
+
            ; Add SCREEN base
            lda zp_ptr2
            clc
            adc #<SCREEN
            sta zp_ptr2
            lda zp_ptr2+1
            adc #>SCREEN
            sta zp_ptr2+1

            rts

; ============================================================
; SCROLL CHAT - Scroll chat area up one line
; ============================================================
scroll_chat:
            ; Copy rows CHAT_TOP+1 through CHAT_BOT up by one row
            ; Each row = 40 bytes in screen RAM and color RAM

            lda #(CHAT_TOP+1)
            sta scroll_src_row

.scroll_loop:
            lda scroll_src_row
            cmp #(CHAT_BOT+1)
            bcs .scroll_clear

            ; Calculate source address (scroll_src_row)
            lda scroll_src_row
            jsr calc_row_offset
            ; zp_ptr2 now has source screen address

            ; Copy source to zp_ptr (will be our source)
            lda zp_ptr2
            sta zp_ptr
            lda zp_ptr2+1
            sta zp_ptr+1

            ; Calculate dest address (scroll_src_row - 1)
            lda scroll_src_row
            sec
            sbc #1
            jsr calc_row_offset
            ; zp_ptr2 now has dest screen address

            ; Copy 40 bytes of screen RAM
            ldy #0
-           lda (zp_ptr),y
            sta (zp_ptr2),y
            iny
            cpy #40
            bne -

            ; Now copy color RAM: add offset COLRAM-SCREEN to both pointers
            lda zp_ptr
            clc
            adc #<(COLRAM-SCREEN)
            sta zp_ptr
            lda zp_ptr+1
            adc #>(COLRAM-SCREEN)
            sta zp_ptr+1

            lda zp_ptr2
            clc
            adc #<(COLRAM-SCREEN)
            sta zp_ptr2
            lda zp_ptr2+1
            adc #>(COLRAM-SCREEN)
            sta zp_ptr2+1

            ldy #0
-           lda (zp_ptr),y
            sta (zp_ptr2),y
            iny
            cpy #40
            bne -

            inc scroll_src_row
            jmp .scroll_loop

.scroll_clear:
            ; Clear the bottom chat row
            lda #CHAT_BOT
            jsr calc_row_offset
            ldy #0
            lda #32         ; space
-           sta (zp_ptr2),y
            iny
            cpy #40
            bne -

            ; Clear color on bottom row too
            lda zp_ptr2
            clc
            adc #<(COLRAM-SCREEN)
            sta zp_ptr2
            lda zp_ptr2+1
            adc #>(COLRAM-SCREEN)
            sta zp_ptr2+1

            ldy #0
            lda #COL_CLAUDE
-           sta (zp_ptr2),y
            iny
            cpy #40
            bne -

            rts

; ============================================================
; VARIABLES
; ============================================================
input_buf:      !fill 80, 0     ; user input buffer (PETSCII)
input_len:      !byte 0         ; current input length
waiting_flag:   !byte 0         ; 1 = waiting for response
chat_row:       !byte 3         ; current chat output row
chat_col:       !byte 0         ; current chat output column
print_color:    !byte COL_CLAUDE ; current text color
resp_len:       !word 0         ; response length counter
scroll_src_row: !byte 0         ; temp for scroll routine
print_idx:      !byte 0         ; temp index for printing
resp_ptr:       !word 0         ; response buffer pointer (safe from scroll)
resp_char:      !byte 0         ; temp char during response display
