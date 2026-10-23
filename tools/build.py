"""Build the Ms. Pac-Man firmware with PureMetal Forge; optionally upload it and read the board.

    py -3 tools/build.py --compiler <PureMetalForge.exe>                       # rp2040/mspacman.picow
    py -3 tools/build.py --compiler <exe> --source <wrapper> --port COM7 --seconds 30

The compiler is the uploader (it sends the finished UF2 itself); nothing else touches the board.
An image that reaches the ROM pack at flash offset $40000 is refused before any upload, because
writing it would overwrite the ROMs (rp2040/romstore.pico).
"""
import argparse
import os
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMAGE_LIMIT = 0x10040000          # the ROM pack's first byte (romstore.pico #ROMPACK_FLASH)
PACK_END = 0x10050000             # ... and the end of its region
FAMILY = {'rp2040': 0xE48BFF56, 'rp2350': 0xE48BFF59}


def image_end(uf2, family, assets=False):
    """End of the code blocks. With assets, blocks inside the ROM pack's region are the pack's."""
    data = uf2.read_bytes()
    if not data or len(data) % 512:
        raise SystemExit(f'{uf2} is not a whole UF2')
    end = 0
    for offset in range(0, len(data), 512):
        m0, m1, flags, target, size, number, count, fam = struct.unpack_from('<8I', data, offset)
        if (m0, m1) != (0x0A324655, 0x9E5D5157) or fam != family:
            raise SystemExit(f'{uf2}: block {offset // 512} is not a {family:08X} UF2 block')
        if assets and IMAGE_LIMIT <= target and target + size <= PACK_END:
            continue
        end = max(end, target + size)
    return end


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--compiler', required=True, type=Path)
    p.add_argument('--source', type=Path, default=ROOT / 'rp2040' / 'mspacman.picow')
    p.add_argument('--output', type=Path)
    p.add_argument('--port')
    p.add_argument('--assets', type=Path, help='a --flash-assets manifest (tools/pack_roms.py): the ROM pack goes up with the image; the UF2 then holds the ROMs, so --output must be outside the repository')
    p.add_argument('--seconds', type=float, default=20)
    p.add_argument('--capture', type=Path, help='serial log (default: <output>.board.log)')
    p.add_argument('--keys', default='', help='keys to send after the board starts, "@<seconds>:<keys>" items separated by ","')
    a = p.parse_args()

    target = 'rp2350' if a.source.suffix.startswith('.pico2') else 'rp2040'
    out = a.output or (ROOT / 'build' / ('mspacman-pico2-w.uf2' if target == 'rp2350' else 'mspacman-pico-w.uf2'))
    if a.assets and (a.output is None or ROOT in a.output.resolve().parents):
        raise SystemExit('--assets puts the ROMs in the UF2: give --output outside the repository')
    out.parent.mkdir(parents=True, exist_ok=True)
    compiler = a.compiler.resolve()
    env = dict(os.environ, PMF_ROOT=str(compiler.parent))
    log = out.with_name(out.name + '.build.log')
    with log.open('w', encoding='utf-8', errors='replace') as f:
        extra = ['--flash-assets', str(a.assets.resolve())] if a.assets else []
        r = subprocess.run([str(compiler), '--compile', str(a.source.resolve()), '-S', '-o', str(out.resolve())] + extra,
                           cwd=compiler.parent, env=env, stdout=f, stderr=subprocess.STDOUT)
    text = log.read_text(encoding='utf-8', errors='replace')
    for line in text.splitlines():
        if not line.startswith('[DEBUG]') and not line.startswith('> Loaded'):
            print(line)
    if r.returncode != 0:
        raise SystemExit(f'compiler exit {r.returncode}; log {log}')
    end = image_end(out, FAMILY[target], bool(a.assets))
    if end > IMAGE_LIMIT:
        raise SystemExit(f'image ends at {end:08X}, past the ROM pack at {IMAGE_LIMIT:08X}: not uploaded')
    print(f'image ends at {end:08X}, {IMAGE_LIMIT - end} bytes below the ROM pack')
    if not a.port:
        return
    r = subprocess.run([str(compiler), '--radio-firmware', str(out.resolve()), '--port', a.port],
                       cwd=compiler.parent, env=env, capture_output=True, text=True)
    print(r.stdout.strip())
    print(r.stderr.strip())
    if r.returncode != 0:
        raise SystemExit(f'upload failed (exit {r.returncode})')
    capture(a.port, a.seconds, a.capture or out.with_name(out.name + '.board.log'), a.keys)


def capture(port, seconds, path, keys):
    import serial
    plan = []
    for item in filter(None, keys.split(',')):
        at, _, k = item.partition(':')
        plan.append((float(at.lstrip('@')), k))
    start = time.monotonic()
    link = None
    with path.open('w', encoding='utf-8', newline='\n') as f:
        while time.monotonic() - start < seconds:
            if link is None:
                try:
                    link = serial.Serial(port, 115200, timeout=0.2)
                except serial.SerialException:
                    if time.monotonic() - start > 15:
                        raise SystemExit(f'{port} did not come back after the upload')
                    time.sleep(0.25)
                    continue
            now = time.monotonic() - start
            while plan and plan[0][0] <= now:
                link.write(plan.pop(0)[1].encode())
            try:
                line = link.readline().decode(errors='replace').rstrip('\r\n')
            except (serial.SerialException, OSError):
                link = None
                continue
            if line:
                stamp = f'{time.monotonic() - start:7.2f} {line}'
                print(stamp, flush=True)
                f.write(stamp + '\n')
    print(f'capture: {path}')


if __name__ == '__main__':
    main()
