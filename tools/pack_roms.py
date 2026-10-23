"""Pack a Ms. Pac-Man ROM set into the flash image the firmware reads.

    py -3 tools/pack_roms.py <folder-or-zip> -o <private folder>/mspacman.pack

The files are found by CRC-32, not by name, so a MAME set under any file
names works. Every file of the set must be present and whole; a missing or
damaged file stops the pack with its name, never a pack the board would run
wrongly. The pack holds the original files unchanged: the board does the
auxiliary-board decryption and patching itself (rp2040/romstore.pico).

The printed "decoded" CRC-32 is of the 64 KB address space the firmware
builds from the pack (decrypted u5/u6/u7 and the forty patches, MAME's
init_mspacman). The board prints the CRC of what it built; the two must match.

Write the pack to the board with the compiler's own uploader (never a
third-party tool):

    PureMetalForge.exe --storage-write <pack> --offset $40000 --port COM7 -t rp2040

THE ROMS ARE COMMERCIAL. Keep the pack outside the repository.
"""
import argparse
import struct
import sys
import zipfile
import zlib
from pathlib import Path

# Offset of the pack in flash (rp2040/romstore.pico #ROMPACK_FLASH). The NES
# ROM store starts at $50000; this store ends below it.
PACK_OFFSET = 0x40000
PACK_LIMIT = 0x10000

# role, size, CRC-32 - MAME's "mspacman" set (src/mame/pacman/pacman.cpp)
SET = [
    ('pacman.6e', 0x1000, 0xC1E6AB10),
    ('pacman.6f', 0x1000, 0x1A6FB2D4),
    ('pacman.6h', 0x1000, 0xBCDD1BEB),
    ('pacman.6j', 0x1000, 0x817D94E3),
    ('u5', 0x0800, 0xF45FBBCD),
    ('u6', 0x1000, 0xA90E7000),
    ('u7', 0x1000, 0xC82CD714),
    ('5e', 0x1000, 0x5C281D01),
    ('5f', 0x1000, 0x615AF909),
    ('82s123.7f', 0x0020, 0x2FC650BD),
    ('82s126.4a', 0x0100, 0x3EB3A8E4),
    ('82s126.1m', 0x0100, 0xA9CC86BF),
]
MAGIC = b'MSPK'
VERSION = 1
ENTRY = 32
HEADER = 16


def candidates(source):
    """Every file in a folder (not its subfolders) or a zip, as (name, bytes)."""
    if source.is_dir():
        for path in sorted(source.iterdir()):
            if path.is_file() and path.stat().st_size <= 0x10000:
                yield path.name, path.read_bytes()
    elif zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            for info in archive.infolist():
                if not info.is_dir() and info.file_size <= 0x10000:
                    yield info.filename, archive.read(info)
    else:
        raise SystemExit(f'{source} is neither a folder nor a zip file')


def bitswap(value, *bits):
    """MAME's bitswap<n>(value, b(n-1), ..., b0): output bit k comes from input bit bits[-1-k]."""
    out = 0
    for position, bit in enumerate(reversed(bits)):
        out |= ((value >> bit) & 1) << position
    return out


def decoded_space(files):
    """The Ms. Pac-Man (decoded) bank, MAME init_mspacman + mspacman_install_patches."""
    rom = bytearray(0x10000)
    rom[0x0000:0x4000] = files['pacman.6e'] + files['pacman.6f'] + files['pacman.6h'] + files['pacman.6j']
    rom[0x8000:0x8800] = files['u5']
    rom[0x9000:0xA000] = files['u6']
    rom[0xB000:0xC000] = files['u7']
    d = bytearray(0x10000)
    data = lambda b: bitswap(b, 0, 4, 5, 7, 6, 3, 2, 1)
    for i in range(0x1000):
        d[0x0000 + i] = rom[0x0000 + i]
        d[0x1000 + i] = rom[0x1000 + i]
        d[0x2000 + i] = rom[0x2000 + i]
        d[0x3000 + i] = data(rom[0xB000 + bitswap(i, 11, 3, 7, 9, 10, 8, 6, 5, 4, 2, 1, 0)])
    for i in range(0x800):
        d[0x8000 + i] = data(rom[0x8000 + bitswap(i, 8, 7, 5, 9, 10, 6, 3, 4, 2, 1, 0)])
        d[0x8800 + i] = data(rom[0x9800 + bitswap(i, 3, 7, 9, 10, 8, 6, 5, 4, 2, 1, 0)])
        d[0x9000 + i] = data(rom[0x9000 + bitswap(i, 3, 7, 9, 10, 8, 6, 5, 4, 2, 1, 0)])
        d[0x9800 + i] = rom[0x1800 + i]
    for i in range(0x1000):
        d[0xA000 + i] = rom[0x2000 + i]
        d[0xB000 + i] = rom[0x3000 + i]
    patches = [
        (0x0410, 0x8008), (0x08E0, 0x81D8), (0x0A30, 0x8118), (0x0BD0, 0x80D8),
        (0x0C20, 0x8120), (0x0E58, 0x8168), (0x0EA8, 0x8198), (0x1000, 0x8020),
        (0x1008, 0x8010), (0x1288, 0x8098), (0x1348, 0x8048), (0x1688, 0x8088),
        (0x16B0, 0x8188), (0x16D8, 0x80C8), (0x16F8, 0x81C8), (0x19A8, 0x80A8),
        (0x19B8, 0x81A8), (0x2060, 0x8148), (0x2108, 0x8018), (0x21A0, 0x81A0),
        (0x2298, 0x80A0), (0x23E0, 0x80E8), (0x2418, 0x8000), (0x2448, 0x8058),
        (0x2470, 0x8140), (0x2488, 0x8080), (0x24B0, 0x8180), (0x24D8, 0x80C0),
        (0x24F8, 0x81C0), (0x2748, 0x8050), (0x2780, 0x8090), (0x27B8, 0x8190),
        (0x2800, 0x8028), (0x2B20, 0x8100), (0x2B30, 0x8110), (0x2BF0, 0x81D0),
        (0x2CC0, 0x80D0), (0x2CD8, 0x80E0), (0x2CF0, 0x81E0), (0x2D60, 0x8160),
    ]
    for i in range(8):
        for dst, src in patches:
            d[dst + i] = d[src + i]
    return d


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('source', type=Path, help='folder or zip holding the Ms. Pac-Man ROM set')
    parser.add_argument('-o', '--output', type=Path, required=True, help='pack file to write (keep it out of git)')
    args = parser.parse_args()

    by_crc = {}
    for name, data in candidates(args.source):
        by_crc.setdefault(zlib.crc32(data), (name, data))
    files, missing = {}, []
    for role, size, crc in SET:
        found = by_crc.get(crc)
        if found is None or len(found[1]) != size:
            missing.append(f'{role} ({size} bytes, CRC-32 {crc:08X})')
            continue
        files[role] = found[1]
        print(f'  {role:<10} <- {found[0]}')
    if missing:
        print('Not packed: these files of the Ms. Pac-Man set were not found (or not whole) in '
              f'{args.source}:', file=sys.stderr)
        for line in missing:
            print('  ' + line, file=sys.stderr)
        raise SystemExit(1)

    table = bytearray()
    body = bytearray()
    first = HEADER + ENTRY * len(SET)
    for role, size, crc in SET:
        table += struct.pack('<16sIIII', role.encode(), first + len(body), size, crc, 0)
        body += files[role]
    payload = bytes(table + body)
    pack = MAGIC + struct.pack('<HHII', VERSION, len(SET), HEADER + len(payload), zlib.crc32(payload)) + payload
    if len(pack) > PACK_LIMIT:
        raise SystemExit(f'Pack is {len(pack)} bytes; the store holds {PACK_LIMIT}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(pack)
    space = decoded_space(files)
    print(f'Wrote {args.output} ({len(pack)} bytes, pack CRC-32 {zlib.crc32(pack):08X})')
    print(f'decoded 0000-3FFF CRC-32 {zlib.crc32(bytes(space[0x0000:0x4000])):08X}  '
          f'8000-BFFF CRC-32 {zlib.crc32(bytes(space[0x8000:0xC000])):08X}')
    print(f'Write it: PureMetalForge.exe --storage-write "{args.output}" --offset ${PACK_OFFSET:X} --port COMx -t rp2040')


if __name__ == '__main__':
    main()
