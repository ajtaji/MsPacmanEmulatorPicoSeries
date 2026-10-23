"""Generate the Pico 2 W (RP2350, Arm) tree rp2350/*.pico2 from the Pico W sources rp2040/*.pico.

    py -3 tools/port_rp2350.py

The RP2040 files are the source; never edit rp2350/ by hand. What differs:
  - the board libraries (RP2350/Lib/*.pico2) and the Z80 core's Pico 2 build (src/z80.pico2);
  - SPI0's addresses and the DMA request field's position;
  - core 1 starts through RP2350/Lib/multicore_smp.pico2 (McLaunchCore1), not multicore_launch();
  - the system clock (150 MHz, the Pico 2 W's nominal, as the NES port runs) and the speaker's
    link key in the 4 MB chip's last sector ($3FF000).
Every per-file replacement must find its text, or the port stops.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'rp2040'
DST = ROOT / 'rp2350'

COMMON = [
    ('RP2040/Lib/', 'RP2350/Lib/'),
]
PER_FILE = {
    'video.pico': [
        ('#VID_SPI_DR = $4003C008             ; SPI0: data, DMA control, status (RP2040 addresses)',
         '#VID_SPI_DR = $40080008             ; SPI0: data, DMA control, status (RP2350 addresses)'),
        ('#VID_SPI_DMACR = $4003C024', '#VID_SPI_DMACR = $40080024'),
        ('#VID_SPI_SR = $4003C00C', '#VID_SPI_SR = $4008000C'),
        ('#VID_TREQ_SHIFT = 15', '#VID_TREQ_SHIFT = #SPI_DMA_TREQ_SHIFT'),
    ],
    'audio_bt.pico': [
        ('#BTKEY_SECTOR = $1FF000', '#BTKEY_SECTOR = $3FF000'),
        ('the chip\'s last sector ($1FF000,', 'the chip\'s last sector ($3FF000,'),
    ],
    'main.pico': [
        ('XIncludeFile "RP2350/Lib/cyw43_nvram.pico"',
         'XIncludeFile "RP2350/Lib/multicore_smp.pico2"\nXIncludeFile "RP2350/Lib/cyw43_nvram.pico2"'),
        ('; Ms. Pac-Man for the Pico W:', '; Ms. Pac-Man for the Pico 2 W:'),
        ('PrintN("Ms. Pac-Man PureMetal - Pico W")', 'PrintN("Ms. Pac-Man PureMetal - Pico 2 W")'),
        ('''; multicore_launch() works in r4-r7, which the Z80 core holds: its own procedure saves them.
Procedure.i LaunchCore1()
  ProcedureReturn multicore_launch()
EndProcedure''', '''; Core 1 through the RP2350's launch library, in a procedure of its own (it saves r4-r7).
Procedure.i LaunchCore1()
  McCore1ReleaseHold()
  If McLaunchCore1()=6 : ProcedureReturn 1 : EndIf
  ProcedureReturn 0
EndProcedure'''),
    ],
    'mspacman.picow': [
        ('; Ms. Pac-Man for the Pico W (RP2040)', '; Ms. Pac-Man for the Pico 2 W (RP2350)'),
        ('#MSP_CLOCK_KHZ=200000', '#MSP_CLOCK_KHZ=150000'),
    ],
}


def port(name, text):
    for old, new in COMMON:
        text = text.replace(old, new)
    for old, new in PER_FILE.get(name, []):
        if old not in text:
            raise SystemExit(f'{name}: "{old[:60]}" not found; the port is out of date')
        text = text.replace(old, new)
    # local includes and the Z80 core: .pico -> .pico2
    text = text.replace('.pico"', '.pico2"')
    return text


def main():
    DST.mkdir(exist_ok=True)
    names = sorted(p.name for p in SRC.iterdir() if p.suffix in ('.pico', '.picow'))
    for name in names:
        text = (SRC / name).read_text(encoding='utf-8')
        out = name[:-len('.picow')] + '.pico2w' if name.endswith('.picow') else name + '2'
        header = '; Generated from rp2040/%s by tools/port_rp2350.py. Edit the RP2040 source, then regenerate.\n' % name
        (DST / out).write_text(header + port(name, text), encoding='utf-8', newline='\n')
        print(f'rp2350/{out}')


if __name__ == '__main__':
    main()
