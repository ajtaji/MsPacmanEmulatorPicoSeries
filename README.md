# Ms. Pac-Man for the Raspberry Pi Pico series — PureMetal

An emulator of the Ms. Pac-Man arcade machine (Midway / General Computer, 1981) for the
Raspberry Pi Pico W (RP2040) and Pico 2 W (RP2350), written in PureMetal and compiled with
PureMetal Forge to bare-metal code: no SDK, no RTOS.

**No ROMs are included.** The game's ROMs are commercial; you load your own set onto the
board's flash (below). Nothing in this repository is derived from them.

> Status: the machine is written and builds for both boards; it waits for the Z80 core
> (`Z80EmulatorPicoSeries`) to fit the Pico W's SRAM and has not yet run on a board. Nothing
> below is claimed as measured until it has.

## Hardware

- Raspberry Pi Pico W (Pico 2 W builds too) on the **LAFVIN ST7796 kit** — the display and
  controls the NES emulator uses: LCD SCK/MOSI GP2/GP3 (SPI0), CS/DC/RST GP5/GP6/GP7, buttons
  GP15 (A) and GP14 (B), joystick GP26/GP27.
- The 224 × 288 picture is shown unscaled, upright, centred on the 320 × 480 panel.
- Sound: a Bluetooth speaker (A2DP), through PureMetal's `Shared/Bluetooth/bt_audio.pmi`.

Controls: stick = joystick, **B** = coin, **A** = 1 player start, **A + B** = 2 player start.

## How it is built

| Part | File | What it does |
|---|---|---|
| Machine | `rp2040/machine.pico` | MAME's `mspacman_map` with its mirrors: ROM write-protect, the $5000 latch, sound registers, sprite positions, IN0/IN1/DSW1/DSW2, watchdog (16 frames), vertical-blank interrupt with the IM 2 vector from `OUT (0),A` |
| ROMs | `rp2040/romstore.pico`, `tools/pack_roms.py` | the ROM pack in flash at $40000, every file checked by CRC-32; the auxiliary board's decryption of u5/u6/u7 and its forty patches done on the board |
| Video | `rp2040/video.pico` | tiles and sprites predecoded at boot in portrait orientation; 36 strips of 224 × 8 drawn on core 1 and sent by DMA while the next is drawn |
| Sound | `rp2040/wsg.pico` | the Namco WSG's three voices at 96 kHz, two steps per 48 kHz sample, at vertical blank |
| Bluetooth | `rp2040/audio_bt.pico` | streams the WSG ring from core 1; keeps the speaker's link key in the last flash sector |
| Controls | `rp2040/input.pico` | the carrier's stick and buttons, plus USB serial keys |
| CPU | `../Z80EmulatorPicoSeries/src/z80.pico` | the computed-goto Z80 core, built with `#Z80_MEM_HOOKS=1` |

Timing: the Z80 at 3.072 MHz, 50,688 T-states a frame, 60.606 frames a second (16.5 ms),
paced by the microsecond timer. Core 0 runs the Z80, the machine and the sound; core 1 the
display and the Bluetooth stream.

Not modelled: the auxiliary board's decode latch (the decoded bank is always in, as on the
decrypted-ROM bootlegs that run the same program), the cocktail cabinet's flip, coin lockout
and lamps.

## Build and run

```
py -3 tools/build.py --compiler <PureMetal Forge folder>\PureMetalForge.exe
py -3 tools/build.py --compiler <...>\PureMetalForge.exe --port COM7 --seconds 30
py -3 tools/port_rp2350.py      # regenerate rp2350/ from rp2040/, then build rp2350/mspacman.pico2w
```

The build refuses an image that would reach the ROM pack at flash offset $40000.
For sound, copy `rp2040/mspacman.picow` outside the repository, put your speaker's address in
its `Speaker` data, and build the copy with `--source`.

## Loading the ROMs

The files of MAME's `mspacman` set, found by CRC-32 in a folder or zip:
`pacman.6e 6f 6h 6j`, `u5 u6 u7`, `5e 5f`, `82s123.7f`, `82s126.4a`, `82s126.1m`.

```
py -3 tools/pack_roms.py <folder-or-zip> -o <outside the repo>\mspacman.pack
PureMetalForge.exe --storage-write <...>\mspacman.pack --offset $40000 --port COM7 -t rp2040
```

The firmware prints the CRC-32 of the address space it decoded; `pack_roms.py` prints the
same numbers from its own decryption, and the two must match.

## Checking the picture

`py -3 tools/grab.py --port COM7 --roms <set> --out captures/frame.png` takes a frame from the
board and the state it was drawn from, draws that state independently the way MAME does, and
compares every pixel.
