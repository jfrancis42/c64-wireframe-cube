# c64-wireframe-cube

A rotating 3D wireframe cube on the Commodore 64, computed live in
6502 assembly — no precomputed animation, no lookup of final pixel
positions. Every frame does the rotation, projection, and line drawing
from first principles.

## Requirements

- [64tass](https://sourceforge.net/projects/tass64/) — 6502 cross-assembler
  (Debian/Ubuntu: `apt install 64tass`).
- [VICE](https://vice-emu.sourceforge.io/) — the Commodore emulator,
  supplying `x64` / `x64sc` and `c1541`.

## Build and run

```
make          # assemble cube.prg and pack it into cube.d64
make run      # launch VICE and autostart the disk
make clean
```

In VICE, once the disk is mounted, autostart runs it automatically. To
load it manually:

```
LOAD "CUBE",8,1
RUN
```

`RUN` executes a tiny BASIC stub that `SYS 2064`s into the machine-language
entry point.

## What it does per frame

1. Rotate all 8 canonical cube vertices `(±32, ±32, ±32)` through the
   current `angle_y`, `angle_x`, `angle_z`. Three rotation stages,
   each computing `out = (a·cos + b·sin) / 64`, `out' = (b·cos − a·sin) / 64`
   in signed 8×8 → 16-bit math. 96 signed multiplies per frame.
2. Compute per-face visibility from the sign of each face's rotated
   Z-normal (2 more multiplies).
3. Draw the visible edges as Bresenham lines into the back buffer.
4. Wait for the raster to leave the visible area, then flip the VIC's
   view to the freshly-drawn buffer.

## Techniques of note

- **Quarter-square multiply.** `a·b = ⌊(a+b)²/4⌋ − ⌊(a−b)²/4⌋`. A single
  256-entry table of `⌊n²/4⌋` (split into low and high bytes at `$c000`
  and `$c100`, both page-aligned) reduces a signed 8×8 multiply to two
  indexed loads and a 16-bit subtract — about 40 cycles vs. ~130 for a
  shift-and-add. The table is filled at boot with an incremental adder
  (no multiplies needed).
- **Hidden-line removal on a convex solid.** Six face-visibility flags
  are set from the sign of each face's rotated Z-normal component. Only
  three unique products are needed (`sin_x`, `sin_y·cos_x`, `cos_y·cos_x`)
  because opposite faces have opposite signs. An edge is drawn only if
  at least one of its two adjacent faces is front-facing.
- **Double buffering across VIC banks.** Bitmap A lives in VIC bank 0
  (at `$2000`, with screen RAM at `$0400`); Bitmap B in VIC bank 2
  (`$a000` / `$8400`). The bitmap and screen offsets are the same in
  each bank, so `$d018` never changes — the flip is a single write to
  CIA2 `$dd00`.
- **Writing under the BASIC ROM shadow.** Bitmap B lives at `$a000` —
  where the CPU normally sees BASIC ROM. The VIC always reads RAM, so
  reads-from-VIC are fine. But `EOR (ptr),y` is read-modify-write from
  the CPU's view: with the ROM visible, the read half of that XORs
  pixel bits with BASIC bytecode. Clearing bit 0 of `$01` (LORAM) at
  boot maps the underlying RAM at `$a000-$bfff` so the CPU sees the
  same RAM the VIC does.
- **Inlined pixel plot inside the Bresenham loop.** No JSR/RTS per pixel.
- **Precomputed row-address tables.** 200-entry `BITMAP_ROW_LO` /
  `BITMAP_ROW_HI` map a Y coordinate to the address of pixel `(0, Y)`.
  The row-HI values are baseline for bitmap A; a single per-frame
  `back_bmp_offset` variable (`$00` or `$80`) redirects to bitmap B.

## Performance

On a real PAL C64 (985 kHz): about **4.7 frames per second**, or
~212,000 CPU cycles per rendered frame. Measured under VICE `-warp` by
watching cycle counts between successive `inc angle_y` events.

## Files

- `cube.asm` — the source (64tass syntax).
- `Makefile` — assemble, package, and launch.
- `README.md` — this file.

## References

- Ed Williams' Aviation Formulary and the standard 6502 quarter-square
  multiplication trick — well documented across the 6502.org and
  codebase64.org archives.
- The C64's VIC-II memory-map and banking behavior is worth reading
  through once if you're doing anything nonstandard with `$d018` and
  CIA2: the [VIC-II article on C64 wiki](https://www.c64-wiki.com/wiki/VIC-II)
  covers the essentials.

## License

Public domain / CC0. Do whatever you want.
