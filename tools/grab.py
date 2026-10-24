"""Take a frame from the board and check it against an independent drawing of the same state.

    py -3 tools/grab.py --port COM7 --roms <ROM folder or zip> --out captures/attract.png
    py -3 tools/grab.py --file <dump> --roms <ROM folder or zip> --out <png>   (desktop --dump)

Sends 'p' to the running firmware, which prints the video state of its latest frame (SNAP, the
2084 bytes of rp2040/video.pico's snapshot) and then the 224 x 288 picture it draws from it.
This tool draws the same state the way MAME does - the native 288 x 224 screen from
pacman_scan_rows, the gfx layouts tilelayout/spritelayout, the sprite order, clip and offsets of
pacman_state::draw_sprites, the resistor weights of pacman_palette - then turns it a quarter
turn (ROT90). It shares no code or tables with the firmware. Every pixel must match.

The PNG is of the game's screen: keep it out of the repository (captures/ is ignored).
"""
import argparse
import re
import struct
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pack_roms import SET, candidates  # noqa: E402


def load_set(source):
    files = dict(candidates(source))
    if 'u5' not in files and 'pacman.6e' in files:
        # a plain Pac-Man hardware set (tools/pack_roms.py --plain): the files by name
        return files
    by_crc = {zlib.crc32(d): d for _, d in candidates(source)}
    out = {}
    for role, size, crc in SET:
        if crc not in by_crc:
            raise SystemExit(f'{role} not found in {source}')
        out[role] = by_crc[crc]
    return out


def gfx_pixel(rom, base_bits, xo, yo):
    """MAME gfx decode: planes {0, 4}, bit offsets MSB-first; plane 0 is the high bit."""
    def bit(o):
        return (rom[o >> 3] >> (7 - (o & 7))) & 1
    o = base_bits + xo + yo
    return (bit(o) << 1) | bit(o + 4)


TILE_X = [64, 65, 66, 67, 0, 1, 2, 3]
TILE_Y = [0, 8, 16, 24, 32, 40, 48, 56]
SPR_X = [64, 65, 66, 67, 128, 129, 130, 131, 192, 193, 194, 195, 0, 1, 2, 3]
SPR_Y = [0, 8, 16, 24, 32, 40, 48, 56, 256, 264, 272, 280, 288, 296, 304, 312]


def palette(prom):
    def w(bits, weights):
        return sum(b * x for b, x in zip(bits, weights))
    out = []
    for v in prom[:32]:
        r = w([(v >> 0) & 1, (v >> 1) & 1, (v >> 2) & 1], [0x21, 0x47, 0x97])
        g = w([(v >> 3) & 1, (v >> 4) & 1, (v >> 5) & 1], [0x21, 0x47, 0x97])
        b = w([(v >> 6) & 1, (v >> 7) & 1], [0x51, 0xAE])
        out.append(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
    return out


def reference(roms, snap):
    vram, cram = snap[0:1024], snap[1024:2048]
    spr, pos = snap[2048:2064], snap[2064:2080]
    pal = palette(roms['82s123.7f'])
    lut = roms['82s126.4a']
    tiles, sprites = roms['5e'], roms['5f']
    W, H = 288, 224
    screen = [[0] * W for _ in range(H)]
    # tilemap 36 x 28, pacman_scan_rows
    for col in range(36):
        for row in range(28):
            r, c = row + 2, col - 2
            offs = (r + ((c & 0x1F) << 5)) if (c & 0x20) else (c + (r << 5))
            code, colour = vram[offs], cram[offs] & 0x1F
            for py in range(8):
                for px in range(8):
                    v = gfx_pixel(tiles, code * 128, TILE_X[px], TILE_Y[py])
                    screen[row * 8 + py][col * 8 + px] = pal[lut[colour * 4 + v] & 15]

    def draw(code, colour, fx, fy, sx, sy):
        for py in range(16):
            for px in range(16):
                spx = 15 - px if fx else px
                spy = 15 - py if fy else py
                v = gfx_pixel(sprites, code * 512, SPR_X[spx], SPR_Y[spy])
                k = lut[colour * 4 + v] & 15
                if k == 0:
                    continue                      # transmask: pens whose colour is 0
                x, y = sx + px, sy + py
                if 16 <= x <= 271 and 0 <= y <= 223:   # spriteclip(2*8, 34*8-1, 0, 28*8-1)
                    screen[y][x] = pal[k]

    order = [14, 12, 10, 8, 6]
    for offs in order:
        sx, sy = 272 - pos[offs + 1], pos[offs] - 31
        a = spr[offs]
        draw(a >> 2, spr[offs + 1] & 0x1F, a & 1, a & 2, sx, sy)
        draw(a >> 2, spr[offs + 1] & 0x1F, a & 1, a & 2, sx - 256, sy)
    for offs in (4, 2, 0):
        sx, sy = 272 - pos[offs + 1], pos[offs] - 31
        a = spr[offs]
        draw(a >> 2, spr[offs + 1] & 0x1F, a & 1, a & 2, sx, sy + 1)
        draw(a >> 2, spr[offs + 1] & 0x1F, a & 1, a & 2, sx - 256, sy + 1)
    # ROT90: rotated (x, y) = (H - 1 - y, x)
    return [[screen[223 - X][Y] for X in range(224)] for Y in range(288)]


def write_png(path, pixels):
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for c in row:
            r, g, b = (c >> 11) & 31, (c >> 5) & 63, c & 31
            raw += bytes(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', len(pixels[0]), len(pixels), 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


GRAB_SETTLE = float(__import__('os').environ.get('GRAB_SETTLE', '0'))
ROMS_FOR_CHECK = None                                       # set by main(): to locate a gap
MARKER = bytes([13, 10]) + b'FRAME_END' + bytes([13, 10])   # CR LF FRAME_END CR LF


def parse(stream):
    """SNAP line, FRAME_BEGIN, 224 x 288 RGB565 little-endian, FRAME_END - from a port or a file."""
    snap = None
    while True:
        line = stream.readline()
        if not line:
            raise SystemExit('no frame in the stream')
        line = line.decode(errors='replace').strip()
        if line.startswith('SNAP '):
            snap = bytes.fromhex(line[5:])
        elif line.startswith('FRAME_BEGIN'):
            if 'dtr=' in line:
                print('board: ' + line[len('FRAME_BEGIN 224 288 '):])
            # everything up to FRAME_END, then check its length: a short or long picture is
            # reported with the count, never drawn shifted
            want = 224 * 288 * 2
            buf = b''
            deadline = time.monotonic() + 60
            end = -1
            while end < 0 and time.monotonic() < deadline:
                chunk = stream.read(4096)
                if not chunk and not hasattr(stream, 'in_waiting'):
                    break                                   # a file has ended
                buf += chunk
                # the marker after the picture; the picture itself may hold any bytes, so only
                # a marker on a line of its own after it counts
                end = buf.find(MARKER, max(0, want - 200))
            tail = buf[end:] + stream.readline() + stream.readline()
            dropped = re.search(rb'usb_dropped=(\d+)', tail)
            if dropped:
                print(f'board: usb_dropped={int(dropped.group(1))}')
            if end < 0 or end != want:
                Path('grab-stream.bin').write_bytes(buf)
                if snap is not None:
                    Path('grab-stream.snap').write_bytes(snap)
                if snap is not None and ROMS_FOR_CHECK is not None and end > 0:
                    ref = reference(ROMS_FOR_CHECK, snap)
                    rb = b''.join(struct.pack('<224H', *row) for row in ref)
                    first = next((k for k in range(min(end, want)) if buf[k] != rb[k]), None)
                    print(f'the board bytes first differ from the reference at byte {first} '
                          f'(strip {None if first is None else first // 3584}, offset {None if first is None else first % 3584})')
                raise SystemExit(f'the picture was {end} bytes, not {want} (stream kept in grab-stream.bin)')
            data = buf[:want]
            px = struct.unpack('<%dH' % (224 * 288), data)
            return snap, [list(px[y * 224:(y + 1) * 224]) for y in range(288)]


def grab(port):
    import serial
    link = serial.Serial(port, 115200, timeout=5)
    if GRAB_SETTLE:
        time.sleep(GRAB_SETTLE)        # let the board see the port open before asking
    link.reset_input_buffer()
    link.write(b'p')
    return parse(link)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port')
    p.add_argument('--file', type=Path, help='a dump written by the desktop program (--dump) instead of a board')
    p.add_argument('--roms', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    roms = load_set(a.roms)
    global ROMS_FOR_CHECK
    ROMS_FOR_CHECK = roms
    if a.file:
        with a.file.open('rb') as f:
            snap, board = parse(f)
    elif a.port:
        snap, board = grab(a.port)
    else:
        raise SystemExit('give --port or --file')
    if snap is None or len(snap) != 2084:
        raise SystemExit('no snapshot (SNAP line) before the frame')
    write_png(a.out, board)
    ref = reference(roms, snap)
    write_png(a.out.with_name(a.out.stem + '-reference.png'), ref)
    bad = [(x, y) for y in range(288) for x in range(224) if board[y][x] != ref[y][x]]
    print(f'board frame {a.out}; reference {a.out.stem}-reference.png')
    if bad:
        print(f'MISMATCH: {len(bad)} of {224 * 288} pixels differ; first at x={bad[0][0]} y={bad[0][1]}')
        raise SystemExit(1)
    print(f'MATCH: all {224 * 288} pixels equal the independent drawing')


if __name__ == '__main__':
    main()
