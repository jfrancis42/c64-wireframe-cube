ASM = 64tass
C1541 = c1541
X64 = x64sc

# the emulator model used by `make run`; the program runs on either standard
VICE_MODEL = ntsc

VERSION := $(shell sed -n 's/^VERSION *= *"\(.*\)".*/\1/p' cube.asm)

all: cube.d64

cube.prg: cube.asm
	$(ASM) --cbm-prg -o cube.prg cube.asm

cube.d64: cube.prg
	$(C1541) -format "cube,00" d64 cube.d64 -write cube.prg "cube,p"

run: cube.d64
	$(X64) -model $(VICE_MODEL) -autostart cube.d64

dist: cube.d64
	rm -f cube-$(VERSION).zip
	zip -q cube-$(VERSION).zip cube.prg cube.d64 README.md

clean:
	rm -f cube.prg cube.d64 cube-*.zip

.PHONY: all run dist clean
