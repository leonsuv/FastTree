#!/bin/sh
# Native AppKit render smoke test. Run after ./build-appkit.sh on macOS.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/fasttree-ui.XXXXXX)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1]) / 'Fixture'
for name, kb in [('Projects/archive.bin',64), ('Projects/design.bin',32), ('Documents/notes.txt',8), ('Cache/data.bin',16)]:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(range(256)) * (kb * 4))
PY
./dist/FastTree.app/Contents/Resources/fasttree-scan "$work/Fixture" --threads 2 --index "$work/fixture.ftidx" > "$work/scan.log"
for appearance in light dark; do
    ./dist/FastTree.app/Contents/MacOS/FastTree --snapshot "$work/$appearance.png" \
        --snapshot-root "$work/Fixture" --snapshot-index "$work/fixture.ftidx" \
        --snapshot-appearance "$appearance" --snapshot-width 1080 --snapshot-height 608 > "$work/$appearance.log" 2>&1
 done
./dist/FastTree.app/Contents/MacOS/FastTree --snapshot "$work/empty.png" --snapshot-appearance light \
    --snapshot-width 1080 --snapshot-height 608 > "$work/empty.log" 2>&1
python3 - "$work" <<'PY'
import re, struct, sys
from pathlib import Path
root = Path(sys.argv[1])
for name, expected_rows in [('light',3), ('dark',3), ('empty',0)]:
    log = (root / f'{name}.log').read_text()
    assert 'Unable to simultaneously satisfy constraints' not in log, log
    match = re.search(r'Snapshot: (\d+)×(\d+), panels \[(\d+), (\d+)\], rows (\d+)', log)
    assert match, log
    width, height, left, right, rows = map(int, match.groups())
    assert rows == expected_rows, log
    assert left >= 420 and right >= 280, log
    assert width - left - right <= 265, 'Content no longer fills the window: ' + log
    data = (root / f'{name}.png').read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pixels = struct.unpack('>II', data[16:24])
    assert pixels[0] >= width and pixels[1] >= height
    print(f'{name}: {width}×{height}, explorer {left}, map {right}, {rows} rows — OK')
PY
