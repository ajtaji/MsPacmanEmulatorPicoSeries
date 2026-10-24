"""Draw the demo's own tiles and sprites (no Namco data) and write its assets description.

    py -3 demo/make_assets.py            -> demo/tiles.png, demo/sprites.png, demo/assets.json

then the compiler's tool makes the five non-program ROMs:

    py -3 <compiler>/tools/pacman_assets.py demo/assets.json --out demo/demo_roms

Pictures are drawn upright, as the player sees the portrait screen (pacman_assets.py turns them).
Pens: 0 black, 1 dark grey, 2 light grey, 3 white.
Tiles: 32 (space) blank, 48-57 digits, 65-90 letters, 33 '!', 45 '-', 46 '.', 58 ':',
       128-131 border pieces (pen 1 frame, pen 2 fill, pen 3 highlight), 132 a solid block.
Sprites: 0 ball, 1 star, 2 diamond, 3 robot face.
"""
import json
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent

# 5 x 7 glyphs, a row a string, '#' = ink
FONT = {
    '0': ['.###.', '#...#', '#..##', '#.#.#', '##..#', '#...#', '.###.'],
    '1': ['..#..', '.##..', '..#..', '..#..', '..#..', '..#..', '.###.'],
    '2': ['.###.', '#...#', '....#', '...#.', '..#..', '.#...', '#####'],
    '3': ['####.', '....#', '....#', '.###.', '....#', '....#', '####.'],
    '4': ['...#.', '..##.', '.#.#.', '#..#.', '#####', '...#.', '...#.'],
    '5': ['#####', '#....', '####.', '....#', '....#', '#...#', '.###.'],
    '6': ['..##.', '.#...', '#....', '####.', '#...#', '#...#', '.###.'],
    '7': ['#####', '....#', '...#.', '..#..', '.#...', '.#...', '.#...'],
    '8': ['.###.', '#...#', '#...#', '.###.', '#...#', '#...#', '.###.'],
    '9': ['.###.', '#...#', '#...#', '.####', '....#', '...#.', '.##..'],
    'A': ['.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
    'B': ['####.', '#...#', '#...#', '####.', '#...#', '#...#', '####.'],
    'C': ['.###.', '#...#', '#....', '#....', '#....', '#...#', '.###.'],
    'D': ['###..', '#..#.', '#...#', '#...#', '#...#', '#..#.', '###..'],
    'E': ['#####', '#....', '#....', '####.', '#....', '#....', '#####'],
    'F': ['#####', '#....', '#....', '####.', '#....', '#....', '#....'],
    'G': ['.###.', '#...#', '#....', '#.###', '#...#', '#...#', '.####'],
    'H': ['#...#', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
    'I': ['.###.', '..#..', '..#..', '..#..', '..#..', '..#..', '.###.'],
    'J': ['..###', '...#.', '...#.', '...#.', '...#.', '#..#.', '.##..'],
    'K': ['#...#', '#..#.', '#.#..', '##...', '#.#..', '#..#.', '#...#'],
    'L': ['#....', '#....', '#....', '#....', '#....', '#....', '#####'],
    'M': ['#...#', '##.##', '#.#.#', '#.#.#', '#...#', '#...#', '#...#'],
    'N': ['#...#', '#...#', '##..#', '#.#.#', '#..##', '#...#', '#...#'],
    'O': ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
    'P': ['####.', '#...#', '#...#', '####.', '#....', '#....', '#....'],
    'Q': ['.###.', '#...#', '#...#', '#...#', '#.#.#', '#..#.', '.##.#'],
    'R': ['####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#'],
    'S': ['.####', '#....', '#....', '.###.', '....#', '....#', '####.'],
    'T': ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'],
    'U': ['#...#', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
    'V': ['#...#', '#...#', '#...#', '#...#', '#...#', '.#.#.', '..#..'],
    'W': ['#...#', '#...#', '#...#', '#.#.#', '#.#.#', '#.#.#', '.#.#.'],
    'X': ['#...#', '#...#', '.#.#.', '..#..', '.#.#.', '#...#', '#...#'],
    'Y': ['#...#', '#...#', '.#.#.', '..#..', '..#..', '..#..', '..#..'],
    'Z': ['#####', '....#', '...#.', '..#..', '.#...', '#....', '#####'],
    '!': ['..#..', '..#..', '..#..', '..#..', '..#..', '.....', '..#..'],
    '-': ['.....', '.....', '.....', '#####', '.....', '.....', '.....'],
    '.': ['.....', '.....', '.....', '.....', '.....', '.##..', '.##..'],
    ':': ['.....', '.##..', '.##..', '.....', '.##..', '.##..', '.....'],
}


def png(path, w, h, pix):
    """pix[y][x] = pen 0-3, written as grey levels 0, 85, 170, 255."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            v = pix[y][x] * 85
            raw += bytes((v, v, v))
    ch = lambda t, c: struct.pack('>I', len(c)) + t + c + struct.pack('>I', zlib.crc32(t + c))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                     + ch(b'IDAT', zlib.compress(bytes(raw), 9)) + ch(b'IEND', b''))


def tiles():
    pix = [[0] * 128 for _ in range(128)]

    def put(n, rows8):
        cx, cy = (n % 16) * 8, (n // 16) * 8
        for v in range(8):
            for u in range(8):
                pix[cy + v][cx + u] = rows8[v][u]

    for ch, rows in FONT.items():
        g = [[0] * 8 for _ in range(8)]
        for v, row in enumerate(rows):
            for u, c in enumerate(row):
                if c == '#':
                    g[v][u + 1] = 3
        put(ord(ch), g)
    # border pieces 128-131: a raised bar (frame pen 1, fill pen 2, highlight pen 3)
    for k in range(4):
        g = [[2] * 8 for _ in range(8)]
        for i in range(8):
            g[0][i] = g[7][i] = g[i][0] = g[i][7] = 1
        g[1][1 + k] = g[1][2 + k] = 3
        put(128 + k, g)
    put(132, [[3] * 8 for _ in range(8)])
    png(HERE / 'tiles.png', 128, 128, pix)


def sprites():
    pix = [[0] * 128 for _ in range(128)]

    def put(n, f):
        cx, cy = (n % 8) * 16, (n // 8) * 16
        for v in range(16):
            for u in range(16):
                pix[cy + v][cx + u] = f(u - 7.5, v - 7.5)

    # 0 ball: a disc with a highlight
    put(0, lambda x, y: 0 if x * x + y * y > 49 else (3 if (x + 2.5) ** 2 + (y + 2.5) ** 2 < 5 else (2 if x + y < 3 else 1)))
    # 1 star: a four-pointed star
    put(1, lambda x, y: 3 if abs(x) * abs(y) < 3 and abs(x) + abs(y) < 9 else 0)
    # 2 diamond
    put(2, lambda x, y: 0 if abs(x) + abs(y) > 7 else (3 if abs(x) + abs(y) < 3 else 2))
    # 3 robot face: a rounded square, two eyes, a mouth
    def robot(x, y):
        if max(abs(x), abs(y)) > 7:
            return 0
        if (abs(x + 3) < 1.5 or abs(x - 3) < 1.5) and abs(y + 2) < 1.5:
            return 3
        if abs(x) < 4 and abs(y - 3.5) < 1:
            return 3
        return 1
    put(3, robot)
    png(HERE / 'sprites.png', 128, 128, pix)


def main():
    tiles()
    sprites()
    desc = {
        'tiles': 'tiles.png',
        'sprites': 'sprites.png',
        'palette': ['#000000', '#FF0000', '#FFB8FF', '#00FFFF', '#47B8FF', '#FFB847', '#FFFF00', '#2121FF',
                    '#00FF00', '#47B8AE', '#FFB8AE', '#DEDEFF', '#FF00FF', '#AE47FF', '#21FF97', '#FFFFFF'],
        # set 0 blank, 1 white text, 2 yellow text, 3 cyan text, 4 the border (blue frame, dark fill,
        # cyan highlight); sprites: 5 red ball, 6 yellow star, 7 green diamond, 8 pink robot
        'sets': [[0, 0, 0, 0], [0, 0, 0, 15], [0, 0, 0, 6], [0, 0, 0, 3], [0, 7, 13, 3],
                 [0, 1, 10, 15], [0, 5, 6, 15], [0, 8, 14, 15], [0, 12, 2, 15]],
    }
    (HERE / 'assets.json').write_text(json.dumps(desc, indent=2) + '\n', encoding='utf-8')
    print('wrote tiles.png, sprites.png, assets.json')


if __name__ == '__main__':
    main()
