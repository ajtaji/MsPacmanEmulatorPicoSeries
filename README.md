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

The auxiliary board's decode latch is modelled (the start-up ROM test needs it). Not modelled:
the cocktail cabinet's flip, coin lockout and lamps.

On the Pico 2 the strip renderer (tiles and each sprite row) and the WSG voice are Thumb-2
inline assembly (`#MSP_THUMB2=1`, set by `tools/port_rp2350.py`); the Pico W keeps the
BASIC versions of the same code. `rp2040/Diagnostics/wsg_check.pico2w` checks the Thumb-2 voice
against the BASIC loop on the board (300 random trials: 0 differ).

## Measured (silent build, a played game, USB coin/start at 14/16 s, 2026-10-25)

Ms. Pac-Man is a Midway US machine: 60.606 frames a second, and the panel shows every one.
Per second of each core (ms):

| Board | fps shown | Core 0: Z80 / WSG / idle | Core 1: drawing / SPI wait / idle | Frame |
|---|---|---|---|---|
| Pico W, 200 MHz (BASIC) | 60.6, 0 dropped | 122 / 45 / 822 | 273 / 420 / 118 | — |
| Pico 2 W, 150 MHz, BASIC | 60.6, 0 dropped | 116-119 / 30-53 / 820-841 | 257-269 / 653-666 / 25 | MATCH |
| Pico 2 W, 150 MHz, Thumb-2 | 60.6, 0 dropped | 106 / 14-20 / 860-867 | **91** / 827 / 26 | MATCH |

Thumb-2 draws a frame about 2.9 times faster and makes the sound chip about 2.5 times faster
(3.6 times in the board check). Core 1's idle time does not grow: the panel link (SPI at
75 MHz on the Pico 2 W) is what core 1 waits on, and the time saved moves into that wait.

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

A compiler without `--storage-write` sends the pack with the firmware instead, as a sparse asset
(`--flash-assets`, the manifest `pack_roms.py` writes beside the pack). That UF2 then holds the
ROMs, so `build.py` writes it only outside the repository:

```
py -3 tools/build.py --compiler <exe> --assets <outside>\assets-rp2040.json --output <outside>\mspacman-with-roms.uf2 --port COM7
```

The firmware prints the CRC-32 of the address space it decoded; `pack_roms.py` prints the
same numbers from its own decryption, and the two must match.

## The desktop program (`desktop/`)

The same machine as a Windows program in PureBasic, drawn with the Neon Arcade Display Engine:
the game's screen scaled in the window, its sound on the PC's speakers (waveOut, paced by the
sound card's clock: 48,000 samples = 60.606 frames a second), the keyboard, and debug panes -
registers and flags, the disassembly at PC, a memory view, run / step / frame / breakpoint.

```
& "C:\Program Files\PureBasic\Compilers\pbcompilerc.exe" desktop\MsPacman.pb /EXE build\MsPacman.exe /THREAD /DPIAWARE /CONSTANT MSP_Z80_CORE$=<desktop Z80 core>
build\MsPacman.exe <ROM folder>
```

Keys: arrows, 5 or C coin, 1 / 2 start, F5 run/pause, F10 step, F11 frame, F3 reset, M mute.
`--log N` runs N frames without a window and prints a line a second (build with `/CONSOLE`);
`--dump <file>` writes the last frame in the board's format for `tools/grab.py --file`.
Without `MSP_Z80_CORE$` the build carries a stand-in CPU that runs nothing, and says so in its
title bar and log.

## Checking the picture

`py -3 tools/grab.py --port COM7 --roms <set> --out captures/frame.png` takes a frame from the
board and the state it was drawn from, draws that state independently the way MAME does, and
compares every pixel.
