ASM = 64tass
C1541 = c1541
X64 = x64

all: cube.d64

cube.prg: cube.asm
	$(ASM) --cbm-prg -o cube.prg cube.asm

cube.d64: cube.prg
	$(C1541) -format "cube,00" d64 cube.d64 -write cube.prg "cube,p"

run: cube.d64
	$(X64) -autostart cube.d64

clean:
	rm -f cube.prg cube.d64

.PHONY: all run clean
