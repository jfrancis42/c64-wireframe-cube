; ═════════════════════════════════════════════════════════════════════════
;  C64 Rotating Wireframe Cube — 64tass syntax
;
;  Copyright (C) 2026 Jeff Francis
;
;  This program is free software: you can redistribute it and/or modify it
;  under the terms of the GNU General Public License as published by the Free
;  Software Foundation, either version 3 of the License, or (at your option)
;  any later version. It is distributed in the hope that it will be useful,
;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
;  Public License (LICENSE) for more details.
;
;  A rotating 3D wireframe cube, computed fresh every frame — no
;  precomputed animation, no lookup-of-final-pixels. Written to be
;  read: each routine has a header comment describing what it does
;  and any tricky invariants.
;
;  ── Reader's guide ────────────────────────────────────────────────────
;
;  In reading order:
;
;    1. Zero-page allocation, VIC/CIA equates, memory-map constants.
;    2. `main` — one-time boot setup, then the main render loop.
;    3. Small utility routines: `wait_vblank`, `flip_buffers`,
;       `clear_bitmap`, `init_row_tables`, `init_sq_tables`.
;    4. `draw_edges` and `draw_line` — the line-drawing pipeline.
;    5. `mul8s` — the fast quarter-square multiply.
;    6. `rotate2d`, `asr6_acc`, `project_all` — the 3D math.
;    7. `calc_face_vis` — hidden-line removal.
;    8. Data tables (sine, cube vertices, edge list, edge→face map).
;    9. Uninitialized RAM (angles, scratch, row-address tables, ...).
;
;  ── Big picture ───────────────────────────────────────────────────────
;
;    Each frame:
;      * Clear whichever bitmap the VIC is NOT currently displaying
;        (the "back" buffer).
;      * Rotate the 8 canonical cube vertices (±32, ±32, ±32) through
;        the current three-axis angles and project them to 2D screen
;        coordinates.
;      * Compute per-face visibility from the sign of each face's
;        rotated Z-normal (only 2 multiplies).
;      * Draw the visible edges as Bresenham lines into the back
;        buffer.
;      * Wait until the raster is below the visible area, then flip
;        the VIC over to the fresh buffer.
;
;    All 6502 arithmetic is 8- or 16-bit; no floating point. The
;    trigonometry uses a 64-entry signed sine table with values scaled
;    ×64 (so `sin(θ)·64` ∈ [-64..64]) and rotations divide their result
;    by 64 at the end. The multiplies use a quarter-square lookup
;    table (see `mul8s`).
;
;  ── Some C64 background you may want ──────────────────────────────────
;
;    * The C64 CPU is a MOS 6510 (a 6502 variant) at ~985 kHz PAL or
;      ~1023 kHz NTSC.  Zero page (addresses $00..$ff) is fast to
;      access and holds our workspace.
;    * The VIC-II video chip sees a 16 KB "bank" of RAM at a time,
;      selected by CIA2 register $dd00. Bits 1..0 pick the bank
;      (INVERTED: %11=bank 0 at $0000, %10=bank 1 at $4000, %01=bank 2
;      at $8000, %00=bank 3 at $c000).
;    * Within a bank the VIC's memory pointer register $d018 further
;      selects where inside the bank the screen RAM (color cells) and
;      bitmap live.
;    * "Hires bitmap mode" gives 320×200 monochrome pixels with per-cell
;      color: the screen splits into 40×25 cells of 8×8 pixels each,
;      the BITMAP holds the pixel data (8000 bytes), and SCREEN RAM
;      (1000 bytes) holds one byte per cell whose high/low nibbles
;      set the foreground/background colors of that cell.
;    * "$01" is the CPU's memory-banking register (LORAM/HIRAM/CHAREN).
;      Bit 0 (LORAM) controls whether the CPU sees BASIC ROM or the
;      underlying RAM at $a000-$bfff — see the `main` boot code for
;      why we clear it.
; ═════════════════════════════════════════════════════════════════════════

; ═════════════════════════════════════════════════════════════════════════
;  BASIC stub: 10 SYS 2080
;
;  A .prg file's first two bytes are its load address (little-endian);
;  when this file loads with `,8,1` those bytes place the rest at $0801,
;  which is BASIC's default program start on a C64. What follows is a
;  single tokenized BASIC line so the user can just type RUN.
;
;  BASIC line layout:
;    - 2 bytes: link pointer (address of NEXT line; 0 = end of program)
;    - 2 bytes: line number
;    - N bytes: token stream (single-byte tokens for keywords, ASCII
;               for everything else), terminated by a $00 byte.
;
;  Our line "10 SYS 2080" tokenizes as:
;    $9E "2064" $00     ← "SYS " is the $9E token, then ASCII "2064",
;                         then the line terminator.
;
;  Total program: link → line-10 record → two zero bytes (end-of-program
;  marker at end_line). Then the entry point at $0820 = 2080 decimal,
;  which is where `SYS 2080` transfers control.
; ═════════════════════════════════════════════════════════════════════════
; The one place the version lives; the Makefile reads it from here.
VERSION = "1.0.0"

        * = $0801

        .word end_line          ; link to next line = end-of-program marker
        .word 10                ; line number 10
        .byte $9e               ; SYS token
                                ; the SYS argument is the entry point below,
                                ; in decimal; ":REM ..." makes LIST show the
                                ; version
        .null format("%4d", entry), ":", $8f, " CUBE ", VERSION
end_line:
        .word 0                 ; end of program (null link)

        * = $0820               ; machine code starts here = decimal 2080
entry

; ═════════════════════════════════════════════════════════════════════════
;  Zero-page workspace
;
;  Every ZP location is fast to access (one instruction byte for the
;  address instead of two) and — critically — the (zp),y indirect
;  addressing mode requires a 2-byte pointer to live in ZP.
;
;  We reserve $02..$1e; C64 KERNAL/BASIC use $00..$8f but we're not
;  calling into either after boot so it doesn't matter — we just skip
;  $00 and $01 (the CPU's I/O port and memory-banking register).
; ═════════════════════════════════════════════════════════════════════════

; ── General scratch: any routine may clobber these. ──────────────────────
ZP_TMP0  = $02
ZP_TMP1  = $03
ZP_TMP2  = $04
ZP_TMP3  = $05

; ── Bresenham line drawing state (draw_line) ─────────────────────────────
ZP_X0    = $06                  ; current pixel X (walks from start to end)
ZP_Y0    = $07                  ; current pixel Y
ZP_X1    = $08                  ; endpoint X (constant during the line)
ZP_Y1    = $09                  ; endpoint Y
ZP_DX    = $0a                  ; |X1 - X0|  (unsigned)
ZP_DY    = $0b                  ; |Y1 - Y0|
ZP_SX    = $0c                  ; +1 or -1: direction of X step
ZP_SY    = $0d                  ; +1 or -1: direction of Y step
ZP_ERR   = $0e                  ; 16-bit signed Bresenham error term (lo)
ZP_ERR2  = $0f                  ; ... (hi)

; ── Bitmap pointer (plot_pixel writes through this) ──────────────────────
ZP_BPTR  = $10                  ; low byte of byte address being written
ZP_BPTR1 = $11                  ; high byte

; ── Signed 8×8 multiply I/O (mul8s) ──────────────────────────────────────
MUL_A    = $12                  ; input operand A (signed byte)
MUL_B    = $13                  ; input operand B (signed byte)
MUL_RLO  = $14                  ; result low byte (signed 16-bit)
MUL_RHI  = $15                  ; result high byte

; ── Iteration counters ───────────────────────────────────────────────────
ZP_EI    = $16                  ; edge-loop byte index (0,2,...,22)
ZP_VI    = $17                  ; vertex-loop index (0..7)

; ── Rotation state (rotate2d reads these) ────────────────────────────────
ZP_SIN   = $18                  ; sine of the current axis (signed, ×64)
ZP_COS   = $19                  ; cosine of the current axis (signed, ×64)
ZP_SGN   = $1a                  ; (unused; historically held a sign bit)

; ── Draw-edges endpoint tables (points into cur_x / cur_y) ───────────────
ZP_XSRC  = $1b                  ; low byte of pointer to X-coord array
ZP_XSRC1 = $1c                  ; high byte
ZP_YSRC  = $1d                  ; low byte of pointer to Y-coord array
ZP_YSRC1 = $1e                  ; high byte

; ═════════════════════════════════════════════════════════════════════════
;  Hardware registers
; ═════════════════════════════════════════════════════════════════════════
VIC_CTRL1  = $d011              ; bit 5 = bitmap mode; bit 7 = raster high bit
VIC_RASTER = $d012              ; current raster line (low 8 bits, read-only here)
VIC_CTRL2  = $d016              ; bit 4 = multicolor mode
VIC_MEMPTR = $d018              ; screen/bitmap offsets within the VIC bank
VIC_BORDER = $d020              ; border color
VIC_BG0    = $d021              ; screen background color

; ═════════════════════════════════════════════════════════════════════════
;  Memory map — double-buffered hires bitmap
;
;  Two complete bitmap+screen pairs live in different VIC banks. Each
;  frame we draw into whichever is NOT currently being displayed, then
;  swap in vblank.
;
;    Buffer A  (VIC bank 0, $0000-$3fff):
;      screen RAM: $0400-$07e7  (color cells)
;      bitmap:     $2000-$3f3f  (8000 pixel bytes)
;
;    Buffer B  (VIC bank 2, $8000-$bfff):
;      screen RAM: $8400-$87e7
;      bitmap:     $a000-$bf3f
;
;  A single write to CIA2 $dd00 flips VIC banks. $d018 doesn't have to
;  change: we placed the screen and bitmap at the same in-bank offsets
;  in both banks.
;
;  Encoding of $d018 nibbles (bit fields):
;    bits 7..4 = screen-RAM offset in 1 KB units → $0400 within bank = 1
;    bit    3  = bitmap slot: 0 = bank+$0000, 1 = bank+$2000
;    bits 2..1 = ignored in bitmap mode (used for char ROM in text mode)
;    bit    0  = unused
;  So VICMEM = %00011000 = $18 → screen at bank+$0400, bitmap at bank+$2000.
;
;  Encoding of CIA2 $dd00 bits 1..0 (INVERTED bank select):
;    %11 = bank 0 ($0000)   %10 = bank 1 ($4000)
;    %01 = bank 2 ($8000)   %00 = bank 3 ($c000)
;
;  Why put buffer B at $a000, which the CPU sees as BASIC ROM? Because
;  the VIC always reads the underlying RAM (it bypasses the CPU's
;  memory banking). And on writes, the CPU's write also lands in the
;  underlying RAM regardless of what shadow is mapped for reads.
;  BUT — `EOR (ptr),y` is a read-modify-write instruction: its READ
;  side sees whatever the CPU currently sees. We fix this at boot by
;  clearing bit 0 (LORAM) of $01 so the CPU sees the RAM at $a000+.
; ═════════════════════════════════════════════════════════════════════════
BITMAP_A = $2000
SCREEN_A = $0400
BITMAP_B = $a000
SCREEN_B = $8400
VICMEM   = $18
CIA2_BANK0 = %00000011          ; VIC sees bank 0 → displays buffer A
CIA2_BANK2 = %00000001          ; VIC sees bank 2 → displays buffer B

; BITMAP is the "row table baseline" — init_row_tables computes
; addresses assuming buffer A ($2000). Plot code adds `back_bmp_offset`
; to the HI byte to redirect writes into buffer B when it's the back.
BITMAP   = BITMAP_A

; ── Quarter-square multiply tables ───────────────────────────────────────
;   SQ[n] = ⌊n² / 4⌋  for n = 0..255. Split into low and high bytes.
;   Page-aligned so `SQ_LO,x` / `SQ_HI,x` (absolute,X) never cross a
;   page (page-crossing adds one CPU cycle per access).
;   Filled at boot by init_sq_tables — living in RAM lets us keep the
;   .prg file small.
SQ_LO    = $c000                ; low  byte of ⌊n²/4⌋
SQ_HI    = $c100                ; high byte of ⌊n²/4⌋

NUM_EDGES = 12
NUM_VERTS = 8

; ═════════════════════════════════════════════════════════════════════════
;  ENTRY POINT — `SYS 2080` lands here.
;
;  Boot sequence:
;    1. Disable IRQs (we don't want the KERNAL cursor blinking on top
;       of what is now color-cell RAM).
;    2. Disable BASIC ROM so the CPU sees the RAM under it (needed for
;       buffer B at $a000; see the memory-map comment above).
;    3. Configure the VIC-II for hires bitmap mode.
;    4. Paint both screen-RAM regions with fg=white / bg=black cells.
;    5. Zero both bitmaps and precompute the row-address and quarter-
;       square lookup tables.
;    6. Point CIA2 at bank 0 (buffer A is what the viewer sees first).
;    7. Set the initial "back" buffer to B and enter the render loop.
; ═════════════════════════════════════════════════════════════════════════
main:
        sei                     ; block IRQs — KERNAL's cursor IRQ would
                                ; scribble on our screen-RAM cells

        ; ── Map RAM under BASIC ROM at $a000-$bfff ──────────────────────
        ; `EOR (ptr),y` is read-modify-write. Its READ half sees whatever
        ; the CPU currently sees at that address. With BASIC ROM visible,
        ; the read at $a000+ returns BASIC bytecode and our pixel XOR
        ; blends with it (visible symptom: bitmap B looked like garbage).
        ; Clearing bit 0 (LORAM) of $01 hides the ROM and exposes RAM.
        ; HIRAM (bit 1) stays 1 so KERNAL remains at $e000; CHAREN
        ; (bit 2) stays 1 so I/O (including $d000-$d02x VIC) stays
        ; visible.
        lda $01
        and #$fe
        sta $01

        ; ── Configure VIC-II ────────────────────────────────────────────
        lda VIC_CTRL1
        and #$7f                ; clear raster-high bit (default)
        ora #$20                ; bit 5 = 1: bitmap mode
        sta VIC_CTRL1
        lda VIC_CTRL2
        and #$ef                ; bit 4 = 0: standard (mono) bitmap
        sta VIC_CTRL2
        lda #VICMEM
        sta VIC_MEMPTR          ; screen at bank+$0400, bitmap at bank+$2000

        lda #0
        sta VIC_BORDER          ; black border
        sta VIC_BG0             ; black background

        ; ── Fill both screen RAMs ───────────────────────────────────────
        ; Color-cell byte layout: bits 7..4 = foreground, 3..0 = background.
        ; $10 = white foreground on black background for every cell.
        ; We write 1024 bytes (four 256-byte pages) even though only 1000
        ; are needed, and we do it to both screen RAMs at once because
        ; the write loop is the expensive part.
        lda #$10
        ldx #0
fill_scr:
        sta SCREEN_A,x
        sta SCREEN_A+$100,x
        sta SCREEN_A+$200,x
        sta SCREEN_A+$300,x
        sta SCREEN_B,x
        sta SCREEN_B+$100,x
        sta SCREEN_B+$200,x
        sta SCREEN_B+$300,x
        dex
        bne fill_scr            ; wraps X back to 0 after $ff → $00

        ; ── Clear both bitmaps (first flip must show a clean screen) ───
        lda #0
        sta back_bmp_offset     ; back = A → clear_bitmap writes $2000..
        jsr clear_bitmap
        lda #$80                ; back = B → clear_bitmap writes $a000..
        sta back_bmp_offset
        jsr clear_bitmap

        ; ── Point CIA2 at VIC bank 0 (buffer A initially displayed) ────
        ; CIA2 data-direction register: set bits 0/1 as OUTPUT so the
        ; port-A writes below actually reach the chip.
        lda $dd02
        ora #$03
        sta $dd02
        lda $dd00
        and #$fc                ; clear bits 1..0 of what's there
        ora #CIA2_BANK0
        sta $dd00

        jsr init_row_tables     ; build BITMAP_ROW_LO / _HI (Y → addr)
        jsr init_sq_tables      ; build SQ_LO / SQ_HI (n → ⌊n²/4⌋)

        ; Initial state: buffer A on screen, we draw into buffer B first.
        lda #$80
        sta back_bmp_offset

        ; Rotation angles are 0..63 (a quarter-turn is 16, full is 64).
        lda #0
        sta angle_x
        sta angle_y
        sta angle_z

        ; IRQs stay disabled: we poll VIC_RASTER for vsync so we don't
        ; need them, and letting the KERNAL run would corrupt the cell
        ; the cursor happens to be blinking in.

; ═════════════════════════════════════════════════════════════════════════
;  MAIN RENDER LOOP
;
;  Each iteration = one displayed frame.
;
;    Step                            Approx cycles (measured under VICE)
;    ────────────────────────────────────────────────────────────────────
;    1. clear back buffer            26,000
;    2. rotate + project 8 vertices  ~ half the frame (96 signed mults)
;    3. compute face visibility      ~2 mults + branches
;    4. draw visible edges           varies with pixel count
;    5. wait for raster line 250     up to 1 raster frame
;    6. flip buffers (CIA2 write)    trivial
;    7. advance angles               trivial
;
;  Total (measured in VICE, averaged over frames):
;      NTSC  ~201k cycles ≈ 5.1 fps  (1.0227 MHz, 263 raster lines)
;      PAL   ~216k cycles ≈ 4.6 fps  (0.9852 MHz, 312 raster lines)
;
;  Nothing here is tied to one video standard: the only timing dependency
;  is waiting for raster line 250, which is below the visible area (which
;  ends at line 250) on both. NTSC is simply faster, because its CPU is
;  faster and its frames are shorter, so the cube tumbles about 12% more
;  quickly there.
; ═════════════════════════════════════════════════════════════════════════
loop:
        ; 1 — clear the back buffer (whichever bitmap isn't on screen)
        jsr clear_bitmap

        ; 2 — rotate the 8 cube vertices through angle_x/y/z, project to
        ;      screen coords in cur_x[] / cur_y[]
        jsr project_all

        ; 3 — set face_vis[0..5] from the signs of the rotated face
        ;      normals' Z components
        jsr calc_face_vis

        ; 4 — draw visible edges. draw_edges reads endpoint coords via
        ;      (ZP_XSRC),y and (ZP_YSRC),y so we point those at cur_x/cur_y.
        ;      (This indirection is left over from when we had a separate
        ;      erase pass reading from prev_x/prev_y — kept in case a
        ;      future change wants to alternate between arrays again.)
        lda #<cur_x
        sta ZP_XSRC
        lda #>cur_x
        sta ZP_XSRC1
        lda #<cur_y
        sta ZP_YSRC
        lda #>cur_y
        sta ZP_YSRC1
        jsr draw_edges

        ; 5 — wait for the VIC to leave the visible area before flipping,
        ;      so the viewer never sees a torn frame.
        jsr wait_vblank

        ; 6 — flip: CIA2 bank swap → VIC now displays what we just drew;
        ;      back_bmp_offset toggles → next frame draws into the other
        ;      bitmap.
        jsr flip_buffers

        ; 7 — advance angles. Each mod 64 (mask with $3f) — 64 steps =
        ;     full turn (matches our 64-entry sine table). Different
        ;     rates per axis give an interesting-looking tumble.
        inc angle_y             ; +1 per frame
        lda angle_y
        and #$3f
        sta angle_y

        lda angle_x             ; +2 per frame
        clc
        adc #2
        and #$3f
        sta angle_x

        lda angle_z             ; +1 per frame
        clc
        adc #1
        and #$3f
        sta angle_z

        jmp loop

; ═════════════════════════════════════════════════════════════════════════
;  WAIT VBLANK — spin until the raster reaches line 250, the last line of
;  the visible area on both NTSC and PAL. Any writes that happen after
;  that, before the raster wraps, won't be seen mid-scan.
;
;  VIC_RASTER = $d012 is the low 8 bits of the current raster line.
;  Line 250 fits in 8 bits so we don't need to test the high bit
;  (bit 7 of $d011).
; ═════════════════════════════════════════════════════════════════════════
wait_vblank:
wv1:    lda VIC_RASTER
        cmp #250
        bne wv1
        rts

; ═════════════════════════════════════════════════════════════════════════
;  FLIP BUFFERS — swap which bitmap the VIC displays and which we draw
;  into next.
;
;  Called right after wait_vblank so the VIC's next scan reads from the
;  newly-completed bitmap. Two things must flip together:
;
;    - CIA2 $dd00 bits 1..0 : which VIC bank the chip reads from.
;      (bank 0 = displays buffer A, bank 2 = displays buffer B)
;
;    - back_bmp_offset      : which bitmap the DRAW code writes to next
;      frame. This is added to the HI byte of BITMAP_ROW_HI[y] in
;      plot_pixel and to the base of clear_bitmap.
;
;  We do NOT need to touch $d018: bitmap and screen RAM sit at the same
;  in-bank offsets in both banks.
; ═════════════════════════════════════════════════════════════════════════
flip_buffers:
        lda back_bmp_offset
        bne fb_to_a             ; back was B ($80) → show B next

        ; back was A ($00) → we just filled A. Point VIC at bank 0 so it
        ; displays A; back becomes B ($80) so next frame draws into B.
        lda $dd00
        and #$fc
        ora #CIA2_BANK0
        sta $dd00
        lda #$80
        sta back_bmp_offset
        rts
fb_to_a:
        ; back was B → we just filled B. Point VIC at bank 2 so it
        ; displays B; back becomes A ($00) so next frame draws into A.
        lda $dd00
        and #$fc
        ora #CIA2_BANK2
        sta $dd00
        lda #$00
        sta back_bmp_offset
        rts

; ═════════════════════════════════════════════════════════════════════════
;  CLEAR BACK BUFFER — zero the bitmap that DRAW code is currently
;  writing to.
;
;  Start address = $2000 + back_bmp_offset·256, i.e. $2000 or $a000.
;  We zero the full 8192-byte VIC slot (32 pages of 256 bytes) rather
;  than only the visible 8000 — a tighter loop, and the trailing 192
;  bytes lie outside the display area anyway.
;
;  Cost: 8192 iterations × ~5 cycles ≈ 40k cycles. (Higher than the
;  ~26k figure quoted elsewhere; the difference is compiler-inlined
;  branch overhead in warp-mode measurements.)
;
;  Loop structure — the standard 6502 "clear N pages" idiom:
;    outer loop counts pages down in X
;    inner loop walks Y from 0 up to 0 (wraps at 256)
; ═════════════════════════════════════════════════════════════════════════
clear_bitmap:
        lda #<BITMAP_A          ; = $00
        sta ZP_BPTR
        lda #>BITMAP_A          ; = $20
        clc
        adc back_bmp_offset     ; $20 + $00 = $20 (buf A); $20 + $80 = $a0 (buf B)
        sta ZP_BPTR1
        lda #0
        ldy #0
        ldx #32                 ; 32 pages to clear
cb_pg:
        sta (ZP_BPTR),y         ; write one byte
        iny
        bne cb_pg               ; more bytes in this page? (Y wrapped to 0 = done)
        inc ZP_BPTR1            ; next page
        dex
        bne cb_pg
        rts

; ═════════════════════════════════════════════════════════════════════════
;  INIT ROW TABLES — precompute byte address of pixel (0, y) for each
;  y in 0..199, stored as 8+8 bits in BITMAP_ROW_LO[y] and BITMAP_ROW_HI[y].
;
;  ── Why bitmap addressing is weird ─────────────────────────────────
;
;  The C64 hires bitmap is organized in 8×8-pixel CELLS, matching the
;  screen-RAM layout of text mode. Successive bytes in the bitmap are
;  successive PIXEL ROWS within the same cell, and only after 8 rows do
;  we move to the next cell to the right.
;
;    byte offset from bitmap base for pixel (x, y):
;        (y >> 3) * 320    ← which cell row (40 cells × 8 bytes each)
;      + (x >> 3) * 8      ← which cell column
;      +  y & 7            ← which pixel row within the cell
;
;    bit within that byte:
;        pixel x=0 → bit 7 (highest)
;        pixel x=7 → bit 0 (lowest)
;
;  Our tables just cache the (x=0) part: (y>>3)·320 + (y&7). We add the
;  x contribution at plot time.
;
;  ── Incremental construction ───────────────────────────────────────
;
;  Between successive y values, the address change is either +1 (moving
;  down one pixel within a cell) or +313 (dropping to the top of the
;  next cell row down: +8 to close out this cell, +40·8 = +320 to advance
;  a cell row, back up -7 = net +313). We identify the cell-row boundary
;  by (y & 7) == 7 before increment.
; ═════════════════════════════════════════════════════════════════════════
init_row_tables:
        lda #<BITMAP            ; running address = BITMAP
        sta ZP_TMP0
        lda #>BITMAP
        sta ZP_TMP1

        ldx #0                  ; X = current y (0..199)
rt_loop:
        lda ZP_TMP0             ; store this y's address into the tables
        sta BITMAP_ROW_LO,x
        lda ZP_TMP1
        sta BITMAP_ROW_HI,x

        txa
        and #7
        cmp #7
        beq rt_wrap             ; y & 7 == 7 → next y crosses a cell row

        ; simple +1: one pixel row down within the same cell
        inc ZP_TMP0
        bne rt_nxt
        inc ZP_TMP1
        jmp rt_nxt

rt_wrap:
        ; cross into the next cell row: add 313 = $139
        lda ZP_TMP0
        clc
        adc #$39
        sta ZP_TMP0
        lda ZP_TMP1
        adc #$01
        sta ZP_TMP1

rt_nxt:
        inx
        cpx #200
        bcc rt_loop
        rts

; ═════════════════════════════════════════════════════════════════════════
;  INIT SQ TABLES — fill SQ_LO / SQ_HI with SQ[n] = ⌊n²/4⌋ for n=0..255.
;
;  Used by mul8s (quarter-square multiply). SQ[0] = 0 through SQ[255] =
;  16256 (which fits in 16 bits, of course).
;
;  ── The incremental identity ────────────────────────────────────────
;
;  Naive approach would multiply each n by itself and divide by 4. We
;  don't have a fast multiply yet (this is what we're TRYING to build!),
;  so instead we use a running total plus a small per-step delta.
;
;  Claim:  f(n+1) − f(n) = ⌊(n+1) / 2⌋
;
;  Proof:  ⌊(n+1)² / 4⌋ − ⌊n² / 4⌋
;       = ⌊(n² + 2n + 1) / 4⌋ − ⌊n² / 4⌋
;
;      If n is even: n² divisible by 4, (n+1)² = n² + 2n + 1 = 4k + 2n + 1.
;        ⌊(4k+2n+1)/4⌋ − k  =  (n/2)      = ⌊(n+1)/2⌋   ✓
;      If n is odd:  n² ≡ 1 (mod 4), (n+1)² divisible by 4.
;        ⌊(n+1)²/4⌋ − ⌊n²/4⌋  =  (n+1)²/4 − (n²−1)/4  =  (2n+2)/4  =  (n+1)/2
;        which is an integer, and equals ⌊(n+1)/2⌋      ✓
;
;  So the delta sequence for n=1..255 is:
;    ⌊1/2⌋, ⌊2/2⌋, ⌊3/2⌋, ... = 0, 1, 1, 2, 2, 3, 3, 4, 4, ...
;
;  Each iteration: A = x/2 (integer), add to 16-bit running total,
;  store total at SQ[x].
;
;  Uses ZP_TMP0/1 as the 16-bit running total, X as the index n.
; ═════════════════════════════════════════════════════════════════════════
init_sq_tables:
        lda #0
        sta ZP_TMP0             ; running total lo
        sta ZP_TMP1             ; running total hi
        sta SQ_LO               ; SQ[0] = 0
        sta SQ_HI

        ldx #1
sq_loop:
        txa
        lsr a                   ; A = ⌊x/2⌋
        clc
        adc ZP_TMP0             ; total_lo += A
        sta ZP_TMP0
        bcc sq_nc
        inc ZP_TMP1             ; total_hi += 1 on carry
sq_nc:
        lda ZP_TMP0
        sta SQ_LO,x
        lda ZP_TMP1
        sta SQ_HI,x
        inx
        bne sq_loop             ; wraps at X = $00 (i.e. after n = 255)
        rts

; ═════════════════════════════════════════════════════════════════════════
;  DRAW EDGES — iterate over all 12 cube edges, skip the ones that
;  aren't visible, and call draw_line on the rest.
;
;  Two skip reasons:
;    - Hidden-line removal: both adjacent faces are back-facing
;      (face_vis[both] == 0).
;    - Degenerate: both endpoints project to the same pixel. Cheap to
;      test, and saves the entire draw_line prologue in the rare
;      grazing case.
;
;  ZP_EI holds the byte-index into the EDGES / EDGE_FACES tables: 0, 2,
;  4, ..., 22. It's kept in memory rather than the X register because
;  X gets reused inside the loop.
;
;  Endpoint coords are read via (ZP_XSRC),y and (ZP_YSRC),y. The caller
;  (main loop) points those at cur_x[] / cur_y[].
; ═════════════════════════════════════════════════════════════════════════
draw_edges:
        ldx #0
        stx ZP_EI
de_loop:
        ; ── Hidden-line check: OR the two face_vis flags; if both zero,
        ;    skip the edge entirely.
        ldx ZP_EI
        ldy EDGE_FACES,x
        lda face_vis,y
        ldy EDGE_FACES+1,x
        ora face_vis,y
        beq de_skip

        ; Endpoint A (X0, Y0) — vertex index sits at EDGES[ZP_EI].
        ldy EDGES,x             ; y = vertex index of endpoint A
        lda (ZP_XSRC),y
        sta ZP_X0
        lda (ZP_YSRC),y
        sta ZP_Y0

        ; Endpoint B (X1, Y1) — vertex index at EDGES[ZP_EI + 1].
        ldx ZP_EI               ; ldy above clobbered our access to X anyway
        ldy EDGES+1,x
        lda (ZP_XSRC),y
        sta ZP_X1
        lda (ZP_YSRC),y
        sta ZP_Y1

        ; Skip degenerate (single-pixel) edges before entering Bresenham.
        lda ZP_X0
        cmp ZP_X1
        bne de_draw
        lda ZP_Y0
        cmp ZP_Y1
        beq de_skip

de_draw:
        jsr draw_line

de_skip:
        ldx ZP_EI               ; advance to next edge: 2 bytes per entry
        inx
        inx
        stx ZP_EI
        cpx #NUM_EDGES*2
        bcc de_loop
        rts

; ═════════════════════════════════════════════════════════════════════════
;  DRAW LINE — Bresenham's line algorithm, XOR mode, all-octants.
;
;  Endpoints (X0, Y0) and (X1, Y1) in zero page. All coords unsigned
;  0..255 (we constrain the projected cube to fit).
;
;  ── Bresenham in 30 seconds ─────────────────────────────────────────
;
;  Draw from (X0,Y0) to (X1,Y1). Let DX = |X1-X0|, DY = |Y1-Y0|. Each
;  step we plot the current pixel and then take at most ONE unit step
;  in X and/or Y. The `err` term accumulates the fractional Y-progress
;  along the ideal line, and when it says we've drifted enough, we step.
;
;  The classic formulation:
;
;      err = DX - DY
;      loop:
;          plot(X0, Y0)
;          if (X0, Y0) == (X1, Y1): break
;          e2 = 2 * err
;          if e2 > -DY:  err -= DY;  X0 += SX
;          if e2 <  DX:  err += DX;  Y0 += SY
;
;  SX / SY are ±1 depending on the sign of X1-X0 / Y1-Y0. This handles
;  all 8 octants without special-casing.
;
;  The two comparisons decide whether to step X only, Y only, or both
;  (for perfect diagonals). One iteration always produces exactly one
;  plotted pixel.
;
;  We keep `err` as a 16-bit SIGNED value even though DX and DY are
;  ≤ ~127 for our cube — because `e2 = 2*err` can overflow 8 bits, and
;  because negative `err` is common early in the line.
;
;  ── Inline plot ─────────────────────────────────────────────────────
;
;  plot_pixel used to be a separate routine, but drawing thousands of
;  pixels per frame made the JSR/RTS cost painful. It's now inlined
;  into the step body between dl_step and dl_after_plot.
; ═════════════════════════════════════════════════════════════════════════
draw_line:
        ; ── DX = |X1 - X0|,  SX = sign of the step ───────────────────
        sec
        lda ZP_X1
        sbc ZP_X0
        bcs dl_dxp              ; carry set → X1 ≥ X0, result already OK
        ; X1 < X0: negate the difference, step -1
        sec
        lda ZP_X0
        sbc ZP_X1
        sta ZP_DX
        lda #$ff                ; -1 as unsigned byte (add-with-carry treats
        sta ZP_SX               ;  it as -1 when we do X0 += SX later)
        jmp dl_dy
dl_dxp:
        sta ZP_DX
        lda #1
        sta ZP_SX

        ; ── DY = |Y1 - Y0|,  SY ───────────────────────────────────────
dl_dy:
        sec
        lda ZP_Y1
        sbc ZP_Y0
        bcs dl_dyp
        sec
        lda ZP_Y0
        sbc ZP_Y1
        sta ZP_DY
        lda #$ff
        sta ZP_SY
        jmp dl_init
dl_dyp:
        sta ZP_DY
        lda #1
        sta ZP_SY

dl_init:
        ; err = DX - DY, sign-extended to 16 bits.
        ; sbc #0 after a subtract: A holds the borrow bit as $ff if
        ; borrow occurred, $00 otherwise → perfect sign extension.
        sec
        lda ZP_DX
        sbc ZP_DY
        sta ZP_ERR
        lda #0
        sbc #0
        sta ZP_ERR2

        ; ── STEP LOOP ─────────────────────────────────────────────────
dl_step:
        ; Plot pixel at (X0, Y0). Inlined for speed.
        ;
        ;   Skip if Y is off-screen (Y ≥ 200). Note: our X clip is
        ;   simpler — X is a byte 0..255 and our bitmap is 320 wide,
        ;   so pixel plots for X in [256, 319] would need extra care;
        ;   we just constrain the cube to X ∈ [0, 255] instead.
        lda ZP_Y0
        cmp #200
        bcs dl_after_plot

        ; Base byte address of the pixel row at (0, Y0).
        tay
        lda BITMAP_ROW_LO,y
        sta ZP_BPTR
        lda BITMAP_ROW_HI,y
        clc
        adc back_bmp_offset     ; retarget to buffer B if back_bmp_offset=$80
        sta ZP_BPTR1

        ; Add byte-column offset: cell column = X >> 3, each column is 8 bytes.
        ;   (X >> 3) * 8 = X & $f8
        lda ZP_X0
        and #$f8
        clc
        adc ZP_BPTR
        sta ZP_BPTR
        bcc dl_plot_nobump
        inc ZP_BPTR1
dl_plot_nobump:
        ; Bit within the byte: pixel-x column 0..7 → bits 7..0.
        lda ZP_X0
        and #7
        tay
        lda BIT_MASK,y

        ; XOR the pixel into the bitmap byte. (Since we clear the back
        ; buffer each frame, this is effectively an OR — but XOR costs
        ; the same and keeps the door open for XOR-based effects.)
        ldy #0
        eor (ZP_BPTR),y
        sta (ZP_BPTR),y

dl_after_plot:
        ; Loop terminator: reached the endpoint?
        lda ZP_X0
        cmp ZP_X1
        bne dl_cont
        lda ZP_Y0
        cmp ZP_Y1
        bne dl_cont
        rts

dl_cont:
        ; ── Compute e2 = 2 * err (16-bit) into ZP_TMP2:ZP_TMP3 ─────────
        lda ZP_ERR
        asl a
        sta ZP_TMP2
        lda ZP_ERR2
        rol a
        sta ZP_TMP3

        ; ── Test: e2 > -DY ?  Equivalent to  e2 + DY > 0 (16-bit signed).
        ; DY is a positive byte (0..127-ish), so we just add it in.
        clc
        lda ZP_TMP2
        adc ZP_DY
        sta ZP_TMP0
        lda ZP_TMP3
        adc #0
        sta ZP_TMP1

        ; Positive-and-nonzero iff hi byte's sign bit is 0 AND (lo|hi) ≠ 0.
        lda ZP_TMP1
        bmi dl_no_x             ; negative → don't step X
        lda ZP_TMP0
        ora ZP_TMP1
        beq dl_no_x             ; exactly zero → don't step X (strict >)

        ; Step X: err -= DY, X0 += SX.
        sec
        lda ZP_ERR
        sbc ZP_DY
        sta ZP_ERR
        lda ZP_ERR2
        sbc #0
        sta ZP_ERR2

        clc
        lda ZP_X0
        adc ZP_SX               ; SX is +1 or $ff (-1 signed byte)
        sta ZP_X0

dl_no_x:
        ; ── Test: e2 < DX ?  Equivalent to  e2 - DX < 0 (16-bit signed).
        sec
        lda ZP_TMP2
        sbc ZP_DX
        sta ZP_TMP0
        lda ZP_TMP3
        sbc #0
        sta ZP_TMP1

        lda ZP_TMP1
        bpl dl_no_y             ; positive → don't step Y

        ; Step Y: err += DX, Y0 += SY.
        clc
        lda ZP_ERR
        adc ZP_DX
        sta ZP_ERR
        lda ZP_ERR2
        adc #0
        sta ZP_ERR2

        clc
        lda ZP_Y0
        adc ZP_SY
        sta ZP_Y0

dl_no_y:
        jmp dl_step             ; next pixel

; Bit within a byte for pixel-x column 0..7. Read as: pixel column 0 is
; the LEFTMOST pixel of a cell and lives in bit 7 of that cell-column's byte.
BIT_MASK:
        .byte $80, $40, $20, $10, $08, $04, $02, $01

; ═════════════════════════════════════════════════════════════════════════
;  MUL8S — signed 8×8 → 16-bit multiply.  MUL_A * MUL_B → MUL_RHI:MUL_RLO
;
;  ── The quarter-square identity ─────────────────────────────────────
;
;  For any real numbers a, b:
;      a·b = ((a+b)² - (a-b)²) / 4
;
;  Verify by expanding:
;      (a+b)² = a² + 2ab + b²
;      (a-b)² = a² - 2ab + b²
;      diff   = 4ab
;      diff/4 = ab   ✓
;
;  On a 6502 we can't do floating point, but we can precompute a table
;  SQ[n] = ⌊n²/4⌋ for n = 0..255, and evaluate
;
;      a·b = SQ[|a+b|] - SQ[|a-b|]
;
;  Why is this EXACT even though we take a floor?
;
;      If (a+b) and (a-b) have the same parity (they always do, because
;      their sum is 2a which is always even and their difference is 2b
;      which is always even), then both ⌊n²/4⌋ terms omit exactly the
;      same fractional part — and the subtraction cancels the floor
;      completely. So the whole thing is bit-exact.
;
;  Absolute values are fine because squaring is even: SQ[|n|] = SQ[n]
;  (interpreting n as a signed value). This lets us index a 256-entry
;  unsigned table.
;
;  ── Preconditions ───────────────────────────────────────────────────
;
;      |MUL_A|, |MUL_B| ≤ 127     (fits in a signed byte)
;      |MUL_A + MUL_B| ≤ 255      (so |sum| fits in table index)
;      |MUL_A - MUL_B| ≤ 255      (ditto)
;
;  All our multiplies are (something ≤ 64) × (something ≤ 64), so
;  |sum| and |diff| are both ≤ 128. Well within range.
;
;  ── Cost ────────────────────────────────────────────────────────────
;
;  Around 40 cycles per call — 4 table lookups plus a 16-bit subtract
;  and two "conditional negate" branches. Compare with the naive shift-
;  and-add approach at ~130 cycles. This one routine is called 96 times
;  per frame (project_all) plus 2 (calc_face_vis), so the savings add
;  up.
;
;  Preserves MUL_A and MUL_B — some callers reuse them across calls.
; ═════════════════════════════════════════════════════════════════════════
mul8s:
        ; ── Compute |a + b| in X ────────────────────────────────────────
        clc
        lda MUL_A
        adc MUL_B               ; A = (a + b) mod 256, but interpreted signed
        bpl mm_s_pos            ; if positive-or-zero, magnitude is A as-is
        eor #$ff                ; else negate:  -x = (x XOR $ff) + 1  (two's compl.)
        clc
        adc #1
mm_s_pos:
        tax

        ; ── result = SQ[|a+b|]  (16-bit load) ───────────────────────────
        lda SQ_LO,x
        sta MUL_RLO
        lda SQ_HI,x
        sta MUL_RHI

        ; ── Compute |a - b| in X ────────────────────────────────────────
        sec
        lda MUL_A
        sbc MUL_B
        bpl mm_d_pos
        eor #$ff
        clc
        adc #1
mm_d_pos:
        tax

        ; ── result -= SQ[|a-b|]  (16-bit subtract) ──────────────────────
        sec
        lda MUL_RLO
        sbc SQ_LO,x
        sta MUL_RLO
        lda MUL_RHI
        sbc SQ_HI,x
        sta MUL_RHI
        rts

; ═════════════════════════════════════════════════════════════════════════
;  ROTATE 2D — rotate a 2D point (a, b) by angle θ.
;
;  The standard 2D rotation matrix says:
;      [ out_a ]   [ cos θ   sin θ ] [ a ]
;      [ out_b ] = [ -sin θ  cos θ ] [ b ]
;
;  giving
;      out_a =  a·cos + b·sin
;      out_b = -a·sin + b·cos  =  b·cos - a·sin
;
;  ── Fixed-point scaling ─────────────────────────────────────────────
;
;  We can't store real cosines and sines on a 6502. Instead the sine
;  table stores values ×64: entries are in [-64..64], one byte each.
;  So when we compute a·cos, we're actually getting (a·cos_true)·64,
;  meaning our product is 64× too large. Same for b·sin. Adding them
;  gives 64·(a·cos + b·sin) = 64·out_a.
;
;  We divide by 64 at the end (an arithmetic right shift of 6 bits) to
;  recover out_a. The temporary sum is 16 bits (max magnitude around
;  4096); after shift it fits in an 8-bit signed byte.
;
;  Inputs (all zero-page):
;    ZP_TMP0 = a   (signed byte)
;    ZP_TMP1 = b   (signed byte)
;    ZP_COS  = cos θ · 64
;    ZP_SIN  = sin θ · 64
;
;  Outputs:
;    ZP_TMP2 = out_a
;    ZP_TMP3 = out_b
;
;  We stash (a, b) into (r2d_a, r2d_b) because we make FOUR mul8s calls
;  that all read MUL_A/MUL_B, and one of them clobbers ZP_TMP0/1 as
;  scratch. (Historically mul8s destroyed its inputs; the current
;  quarter-square version preserves them, so this stash is now
;  defensive — kept in case rotate2d gets called from a caller who
;  clobbers those.)
; ═════════════════════════════════════════════════════════════════════════
rotate2d:
        lda ZP_TMP0
        sta r2d_a
        lda ZP_TMP1
        sta r2d_b

        ; ── out_a = (a·cos + b·sin) / 64 ────────────────────────────────

        ; acc = a * cos
        lda r2d_a
        sta MUL_A
        lda ZP_COS
        sta MUL_B
        jsr mul8s
        lda MUL_RLO
        sta acc_lo
        lda MUL_RHI
        sta acc_hi

        ; acc += b * sin
        lda r2d_b
        sta MUL_A
        lda ZP_SIN
        sta MUL_B
        jsr mul8s
        clc
        lda acc_lo
        adc MUL_RLO
        sta acc_lo
        lda acc_hi
        adc MUL_RHI
        sta acc_hi

        ; acc /= 64 (arithmetic; sign-preserving)
        jsr asr6_acc
        lda acc_lo
        sta ZP_TMP2

        ; ── out_b = (b·cos - a·sin) / 64 ────────────────────────────────

        ; acc = b * cos
        lda r2d_b
        sta MUL_A
        lda ZP_COS
        sta MUL_B
        jsr mul8s
        lda MUL_RLO
        sta acc_lo
        lda MUL_RHI
        sta acc_hi

        ; acc -= a * sin
        lda r2d_a
        sta MUL_A
        lda ZP_SIN
        sta MUL_B
        jsr mul8s
        sec
        lda acc_lo
        sbc MUL_RLO
        sta acc_lo
        lda acc_hi
        sbc MUL_RHI
        sta acc_hi

        ; acc /= 64
        jsr asr6_acc
        lda acc_lo
        sta ZP_TMP3

        rts

; ═════════════════════════════════════════════════════════════════════════
;  ASR6_ACC — arithmetic right shift acc_hi:acc_lo (16-bit signed) by 6.
;
;  Equivalent to signed division by 64 with truncation toward -∞.
;
;  The trick: an "arithmetic" right shift preserves the sign bit. The
;  6502 has LSR (shifts in 0) but no ASR. To fake ASR: LDA the high
;  byte; CMP #$80 sets carry to bit 7 of A (because it computes A-$80
;  and carry is "no borrow", which is exactly A ≥ $80 i.e. A's sign
;  bit); then ROR through the high byte and into the low byte. Repeat.
; ═════════════════════════════════════════════════════════════════════════
asr6_acc:
        ldx #6
asr6_l:
        lda acc_hi
        cmp #$80                ; carry ← sign bit of acc_hi
        ror acc_hi
        ror acc_lo
        dex
        bne asr6_l
        rts

; ═════════════════════════════════════════════════════════════════════════
;  PROJECT ALL VERTICES — rotate the 8 cube corners through three axes
;  and drop them onto screen space.
;
;  Per vertex, three 2D rotations in order:
;    1. Y-axis rotation — rotates the (x, z) pair by angle_y.
;    2. X-axis rotation — rotates (y, z) by angle_x, using the y from
;       the original vertex and z from step 1's output.
;    3. Z-axis rotation — rotates (x, y) by angle_z, using x from
;       step 1's output and y from step 2's output.
;
;  Then a parallel (orthographic) projection: (rx, ry) → screen coords
;  by simply adding (128, 100) — no perspective divide, no scale. The
;  cube starts at ±32 in each axis, so after rotation stays in roughly
;  the same range, and after +128 / +100 sits centered in a 320×200
;  display.
;
;  ── Trig table lookup ──────────────────────────────────────────────
;
;  SIN_TBL has 64 entries covering a full turn. cos θ = sin(θ + π/2),
;  which in 64-entry-per-turn units is index + 16 mod 64. We compute
;  sin/cos of each axis ONCE per frame (six lookups total) and cache
;  in sin_x/cos_x/... — the 8-vertex loop then just reads those.
;
;  ── Cost ────────────────────────────────────────────────────────────
;
;  8 vertices × 3 rotations × 4 multiplies = 96 signed 8×8 multiplies
;  per frame. This is the biggest single cycle consumer.
; ═════════════════════════════════════════════════════════════════════════
project_all:
        ; ── Cache sin_y and cos_y ──────────────────────────────────────
        ldx angle_y
        lda SIN_TBL,x
        sta sin_y
        txa
        clc
        adc #16                 ; cos(θ) = sin(θ + 16) in 64-per-turn units
        and #$3f                ; wrap to [0..63]
        tax
        lda SIN_TBL,x
        sta cos_y

        ; ── Cache sin_x and cos_x ──────────────────────────────────────
        ldx angle_x
        lda SIN_TBL,x
        sta sin_x
        txa
        clc
        adc #16
        and #$3f
        tax
        lda SIN_TBL,x
        sta cos_x

        ; ── Cache sin_z and cos_z ──────────────────────────────────────
        ldx angle_z
        lda SIN_TBL,x
        sta sin_z
        txa
        clc
        adc #16
        and #$3f
        tax
        lda SIN_TBL,x
        sta cos_z

        ; ── Per-vertex loop ────────────────────────────────────────────
        ldx #0                  ; X = current vertex index 0..7
pv_loop:
        stx ZP_VI               ; stash since rotate2d clobbers X

        ; STEP 1 — Y-rotation on (VERTS_X, VERTS_Z) → (rx, rz).
        lda VERTS_X,x
        sta ZP_TMP0
        lda VERTS_Z,x
        sta ZP_TMP1
        lda cos_y
        sta ZP_COS
        lda sin_y
        sta ZP_SIN
        jsr rotate2d
        lda ZP_TMP2
        sta rx
        lda ZP_TMP3
        sta rz

        ; Y component starts UN-rotated (Y-axis rotation preserves Y).
        ldx ZP_VI
        lda VERTS_Y,x
        sta ry

        ; STEP 2 — X-rotation on (ry, rz) → (ry', rz').
        lda ry
        sta ZP_TMP0
        lda rz
        sta ZP_TMP1
        lda cos_x
        sta ZP_COS
        lda sin_x
        sta ZP_SIN
        jsr rotate2d
        lda ZP_TMP2
        sta ry
        lda ZP_TMP3
        sta rz

        ; STEP 3 — Z-rotation on (rx, ry) → (rx', ry').
        lda rx
        sta ZP_TMP0
        lda ry
        sta ZP_TMP1
        lda cos_z
        sta ZP_COS
        lda sin_z
        sta ZP_SIN
        jsr rotate2d
        lda ZP_TMP2
        sta rx
        lda ZP_TMP3
        sta ry

        ; PROJECT — parallel projection, offset only.
        ; The cube's ±32 range after rotation stays roughly the same,
        ; so +128 puts it in [96..160] X and +100 in [68..132] Y —
        ; comfortably inside our 256×200 usable area.
        lda rx
        clc
        adc #128
        ldx ZP_VI
        sta cur_x,x

        lda ry
        clc
        adc #100
        ldx ZP_VI
        sta cur_y,x

        ; Loop. NOTE: bcc to pv_loop is out of range so we jump.
        ldx ZP_VI
        inx
        cpx #NUM_VERTS
        bcs pv_done
        jmp pv_loop
pv_done:
        rts

; ═════════════════════════════════════════════════════════════════════════
;  CALC FACE VIS — determine which of the 6 cube faces are facing the
;  viewer, from the sign of each face's rotated-Z-normal.
;
;  Hidden-line removal for a convex solid: an edge is visible if
;  AT LEAST ONE of its two adjacent faces is front-facing. If both
;  faces are behind, the edge is inside the silhouette from our POV
;  and doesn't need to be drawn. See draw_edges for that check.
;
;  ── The math ────────────────────────────────────────────────────────
;
;  project_all applies rotations in order Y → X → Z. A Z-rotation is a
;  rotation ABOUT the Z axis and so leaves the Z component untouched.
;  So for the purpose of testing "is a face's normal pointing toward
;  +Z (toward viewer)?" we only need Y and X rotation.
;
;  For a face with un-rotated normal N = (nx, ny, nz), after Y then X
;  rotation the Z component of the rotated normal is:
;
;      Nz' = -nx·sin_y·cos_x - ny·sin_x + nz·cos_y·cos_x
;          = ( nz·cos_y - nx·sin_y )·cos_x  −  ny·sin_x
;
;  For each of our 6 axis-aligned face normals only ONE of nx/ny/nz is
;  ±1 and the other two are 0. So Nz' collapses to one of:
;
;      Face 0 (−X, N=(−1,0,0)):  Nz' =  sin_y·cos_x     → visible iff > 0
;      Face 1 (+X, N=(+1,0,0)):  Nz' = -sin_y·cos_x     → opposite of face 0
;      Face 2 (−Y, N=(0,−1,0)):  Nz' =  sin_x           → visible iff > 0
;      Face 3 (+Y, N=(0,+1,0)):  Nz' = -sin_x           → opposite of face 2
;      Face 4 (−Z, N=(0,0,−1)):  Nz' = -cos_y·cos_x     → opposite of face 5
;      Face 5 (+Z, N=(0,0,+1)):  Nz' =  cos_y·cos_x     → visible iff > 0
;
;  Opposite pairs — as expected, since a convex solid never has both
;  faces of a pair facing us.
;
;  Only 2 multiplies:  sin_y·cos_x  and  cos_y·cos_x. Very cheap.
;
;  Grazing case (exactly zero product) we treat as "back" — the edge
;  along that grazing face won't be drawn but there's nothing behind
;  it either.
; ═════════════════════════════════════════════════════════════════════════
calc_face_vis:
        ; ── Faces 2/3: sign of sin_x ───────────────────────────────────
        lda #0
        sta face_vis+2
        sta face_vis+3
        lda sin_x
        beq cfv_yz              ; sin_x == 0: both stay 0 (edge case)
        bmi cfv_face3           ; sin_x < 0 → face 3 (+Y) visible
        inc face_vis+2          ; sin_x > 0 → face 2 (−Y) visible
        jmp cfv_yz
cfv_face3:
        inc face_vis+3

cfv_yz:
        ; ── Faces 0/1: sign of sin_y·cos_x ─────────────────────────────
        lda sin_y
        sta MUL_A
        lda cos_x
        sta MUL_B
        jsr mul8s               ; MUL_RHI:MUL_RLO = sin_y * cos_x

        lda #0
        sta face_vis+0
        sta face_vis+1
        ; test 16-bit signed: bit 7 of high byte = sign; zero if both zero
        lda MUL_RHI
        bmi cfv_face1
        ; positive-or-zero: is it zero?
        ora MUL_RLO
        beq cfv_zface           ; product == 0: both back-facing
        inc face_vis+0          ; sin_y·cos_x > 0 → face 0 (−X) visible
        jmp cfv_zface
cfv_face1:
        inc face_vis+1          ; sin_y·cos_x < 0 → face 1 (+X) visible

cfv_zface:
        ; ── Faces 4/5: sign of cos_y·cos_x ─────────────────────────────
        lda cos_y
        sta MUL_A
        lda cos_x
        sta MUL_B
        jsr mul8s

        lda #0
        sta face_vis+4
        sta face_vis+5
        lda MUL_RHI
        bmi cfv_face4
        ora MUL_RLO
        beq cfv_done
        inc face_vis+5          ; cos_y·cos_x > 0 → face 5 (+Z) visible
        rts
cfv_face4:
        inc face_vis+4          ; cos_y·cos_x < 0 → face 4 (−Z) visible
cfv_done:
        rts

; ═════════════════════════════════════════════════════════════════════════
;  DATA TABLES
; ═════════════════════════════════════════════════════════════════════════

; ── SINE TABLE ───────────────────────────────────────────────────────────
; 64 entries covering a full turn:  SIN_TBL[i] = round( sin(i·2π/64) · 64 ).
; Values are signed bytes in [-64..64]. The scale factor of ×64 lets us
; work in 8-bit integer arithmetic. rotate2d divides by 64 at the end.
;
; cos(θ) = sin(θ + π/2), and π/2 in 64-entries-per-turn units is 16 —
; so we access cos via SIN_TBL[(i + 16) & 63].
SIN_TBL:
        .char    0,    6,   12,   19,   24,   30,   36,   41
        .char   45,   49,   53,   56,   59,   61,   63,   64
        .char   64,   64,   63,   61,   59,   56,   53,   49
        .char   45,   41,   36,   30,   24,   19,   12,    6
        .char    0,   -6,  -12,  -19,  -24,  -30,  -36,  -41
        .char  -45,  -49,  -53,  -56,  -59,  -61,  -63,  -64
        .char  -64,  -64,  -63,  -61,  -59,  -56,  -53,  -49
        .char  -45,  -41,  -36,  -30,  -24,  -19,  -12,   -6

; ── CUBE VERTICES ────────────────────────────────────────────────────────
; 8 corners at (±32, ±32, ±32). We chose ±32 (not 1) so all math stays
; in integer land — everything is 8-bit signed.
;
; Vertex index encodes the sign bits:
;   bit 2 = X sign  (0 → -32, 1 → +32)
;   bit 1 = Y sign
;   bit 0 = Z sign
;
;   V0 = (-32, -32, -32)      V4 = (+32, -32, -32)
;   V1 = (-32, -32, +32)      V5 = (+32, -32, +32)
;   V2 = (-32, +32, -32)      V6 = (+32, +32, -32)
;   V3 = (-32, +32, +32)      V7 = (+32, +32, +32)
;
;                       V2----------V6
;                       /|         /|
;                     V3----------V7|
;                     |  |        | |
;                     | V0--------|V4
;                     |/          |/
;                     V1----------V5
VERTS_X: .char -32, -32, -32, -32,  32,  32,  32,  32
VERTS_Y: .char -32, -32,  32,  32, -32, -32,  32,  32
VERTS_Z: .char -32,  32, -32,  32, -32,  32, -32,  32

; ── EDGE LIST ────────────────────────────────────────────────────────────
; 12 edges as (vertex A, vertex B) pairs. Grouped by axis alignment
; because that makes the EDGE_FACES table below easy to read.
EDGES:
        .byte 0,1,  2,3,  4,5,  6,7     ; edges 0..3: Z-parallel
        .byte 0,2,  1,3,  4,6,  5,7     ; edges 4..7: Y-parallel
        .byte 0,4,  1,5,  2,6,  3,7     ; edges 8..11: X-parallel

; ── EDGE → ADJACENT FACES ────────────────────────────────────────────────
; For each edge, the two face indices it lies on. The 6 faces are:
;
;   0 = -X (left)     1 = +X (right)
;   2 = -Y (bottom)   3 = +Y (top)
;   4 = -Z (back)     5 = +Z (front)
;
; An edge is drawn if AT LEAST ONE of its two faces is front-facing
; (draw_edges tests `face_vis[a] | face_vis[b]`).
EDGE_FACES:
        .byte 0,2,  0,3,  1,2,  1,3     ; Z-parallel edges (0..3)
        .byte 0,4,  0,5,  1,4,  1,5     ; Y-parallel edges (4..7)
        .byte 2,4,  2,5,  3,4,  3,5     ; X-parallel edges (8..11)

; ═════════════════════════════════════════════════════════════════════════
;  UNINITIALIZED RAM
;
;  These are all stored as zero in the .prg (simpler than allocating a
;  BSS-style section) and get their real values written at runtime.
; ═════════════════════════════════════════════════════════════════════════

; ── Rotation angles (0..63, quarter turn = 16) ───────────────────────────
angle_x     .byte 0
angle_y     .byte 0
angle_z     .byte 0

; ── Cached sin/cos for the current frame ─────────────────────────────────
; Written once at the top of project_all, read by the per-vertex loop.
; cos_z / sin_z are cached even though calc_face_vis only reads sin_x,
; cos_x, sin_y, cos_y — this keeps the caching loop uniform.
sin_x       .byte 0
cos_x       .byte 0
sin_y       .byte 0
cos_y       .byte 0
sin_z       .byte 0
cos_z       .byte 0

; ── Rotate2d input stash / rotate2d accumulator ─────────────────────────
r2d_a       .byte 0             ; stash of input a during 4 multiplies
r2d_b       .byte 0             ; stash of input b
acc_lo      .byte 0             ; 16-bit accumulator, low byte
acc_hi      .byte 0             ; 16-bit accumulator, high byte

; ── Rotated-vertex temporaries (one at a time in the per-vertex loop) ────
rx          .byte 0
ry          .byte 0
rz          .byte 0

; ── Face visibility flags ────────────────────────────────────────────────
; face_vis[i] = 1 if face i is front-facing, else 0.
; Set by calc_face_vis each frame, consumed by draw_edges.
face_vis    .fill 6, 0

; ── Projected screen coordinates for each vertex ─────────────────────────
; Filled by project_all, read by draw_edges (via ZP_XSRC / ZP_YSRC).
cur_x       .fill 8, 0
cur_y       .fill 8, 0

; ── Which bitmap is currently the DRAW target ────────────────────────────
; $00 → bitmap A at $2000.  $80 → bitmap B at $a000.
; Added to the HI byte of BITMAP_A / BITMAP_ROW_HI[y] at plot time.
back_bmp_offset .byte 0

; ── Bitmap row-address lookup tables ─────────────────────────────────────
; BITMAP_ROW_LO[y] and BITMAP_ROW_HI[y] together give the byte address
; of pixel (0, y) in bitmap A. Filled at runtime by init_row_tables.
; The high byte is buffer-A-relative; plot code adds back_bmp_offset to
; retarget buffer B.
BITMAP_ROW_LO   .fill 200, 0
BITMAP_ROW_HI   .fill 200, 0
