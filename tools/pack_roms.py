"""Pack a Ms. Pac-Man ROM set into the flash image the firmware reads.

    py -3 tools/pack_roms.py <folder-or-zip> -o <private folder>/mspacman.pack
    py -3 tools/pack_roms.py --plain <folder> -o <folder>/demo.pack

--plain packs a set for PLAIN Pac-Man hardware - a program built for the compiler's Pac-Man
board (.pacman: pacman.6e .. pacman.6j, and 5e, 5f, 82s123.7f, 82s126.4a, 82s126.1m from
tools/pacman_assets.py) - taken by FILE NAME, with no auxiliary board: the firmware then maps
the four program ROMs at $0000 and $8000 and does no decryption or patching (pack version 2).

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
import hashlib
import json
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
VERSION_PLAIN = 2
# version 2: these, in this order, by name (rp2040/romstore.pico reads them by position)
PLAIN = [('pacman.6e', 0x1000), ('pacman.6f', 0x1000), ('pacman.6h', 0x1000), ('pacman.6j', 0x1000),
         ('5e', 0x1000), ('5f', 0x1000), ('82s123.7f', 0x0020), ('82s126.4a', 0x0100), ('82s126.1m', 0x0100)]
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


def write_pack(args, version, roles):
    """roles: (name, bytes) in pack order. Writes the pack and its --flash-assets manifests."""
    table, body = bytearray(), bytearray()
    first = HEADER + ENTRY * len(roles)
    for name, data in roles:
        table += struct.pack('<16sIIII', name.encode(), first + len(body), len(data), zlib.crc32(data), 0)
        body += data
    payload = bytes(table + body)
    pack = MAGIC + struct.pack('<HHII', version, len(roles), HEADER + len(payload), zlib.crc32(payload)) + payload
    if len(pack) > PACK_LIMIT:
        raise SystemExit(f'Pack is {len(pack)} bytes; the store holds {PACK_LIMIT}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(pack)
    padded = pack + bytes(-len(pack) % 256)
    for chip, capacity, name in (('rp2040', 2 * 1024 * 1024, 'assets-rp2040.json'),
                                 ('rp2350', 4 * 1024 * 1024, 'assets-rp2350.json')):
        manifest = {'version': 1, 'flashCapacity': capacity, 'chip': chip, 'assets': [{
            'path': args.output.name, 'offset': PACK_OFFSET, 'length': len(pack),
            'sha256': hashlib.sha256(pack).hexdigest(), 'paddedLength': len(padded),
            'paddedSha256': hashlib.sha256(padded).hexdigest()}]}
        (args.output.parent / name).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Wrote {args.output} ({len(pack)} bytes, version {version}, pack CRC-32 {zlib.crc32(pack):08X}); '
          f'manifests {args.output.parent / "assets-rp2040.json"}, assets-rp2350.json')
    return pack


def pack_plain(args):
    files = {name: data for name, data in candidates(args.source)}
    roles, problems = [], []
    for name, size in PLAIN:
        data = files.get(name)
        if data is None:
            problems.append(f'{name} is missing')
        elif len(data) != size:
            problems.append(f'{name} is {len(data)} bytes, not {size}')
        else:
            roles.append((name, data))
    if problems:
        print('Not packed: ' + '; '.join(problems), file=sys.stderr)
        raise SystemExit(1)
    write_pack(args, VERSION_PLAIN, roles)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('source', type=Path, help='folder or zip holding the Ms. Pac-Man ROM set')
    parser.add_argument('-o', '--output', type=Path, required=True, help='pack file to write (keep it out of git)')
    parser.add_argument('--plain', action='store_true', help='plain Pac-Man hardware set, files by name (see above)')
    args = parser.parse_args()
    if args.plain:
        return pack_plain(args)

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

    pack = write_pack(args, VERSION, [(role, files[role]) for role, size, crc in SET])
    space = decoded_space(files)
    print(f'decoded 0000-3FFF CRC-32 {zlib.crc32(bytes(space[0x0000:0x4000])):08X}  '
          f'8000-BFFF CRC-32 {zlib.crc32(bytes(space[0x8000:0xC000])):08X}')
    # The same pack as a sparse asset of an upload (--flash-assets): the route for a compiler that
    # has no --storage-write. The UF2 such a build makes holds the ROMs: keep it private too.
    padded = pack + bytes(-len(pack) % 256)
    for chip, capacity, name in (('rp2040', 2 * 1024 * 1024, 'assets-rp2040.json'),
                                 ('rp2350', 4 * 1024 * 1024, 'assets-rp2350.json')):
        manifest = {'version': 1, 'flashCapacity': capacity, 'chip': chip, 'assets': [{
            'path': args.output.name, 'offset': PACK_OFFSET, 'length': len(pack),
            'sha256': hashlib.sha256(pack).hexdigest(), 'paddedLength': len(padded),
            'paddedSha256': hashlib.sha256(padded).hexdigest()}]}
        (args.output.parent / name).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Write it: PureMetalForge.exe --storage-write "{args.output}" --offset ${PACK_OFFSET:X} --port COMx -t rp2040')
    print(f'      or: py -3 tools/build.py --compiler <exe> --assets {args.output.parent / "assets-rp2040.json"} '
          f'--output <private folder>/mspacman-with-roms.uf2 --port COMx')


if __name__ == '__main__':
    main()
