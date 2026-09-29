#!/usr/bin/env python3
"""Small independent correctness fixture for built scanner binaries."""
import json, os, pathlib, subprocess, tempfile, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
def main():
    with tempfile.TemporaryDirectory(prefix="fasttree-safety-fixture-") as td:
        root = pathlib.Path(td) / "tree"
        (root / "nested").mkdir(parents=True)
        (root / "regular.bin").write_bytes(b"F" * 4096)
        os.link(root / "regular.bin", root / "nested" / "hardlink.bin")
        with (root / "sparse.bin").open("wb") as f: f.truncate(10 * 1024 * 1024)
        (root / "nested" / "note.txt").write_bytes(b"fixture")
        os.symlink("/etc/passwd", root / "symlink")
        unique = [root / "regular.bin", root / "sparse.bin", root / "nested" / "note.txt"]
        expected = {"files": len(unique), "dirs": 1,
                    "logical_bytes": sum(p.stat().st_size for p in unique),
                    "allocated_bytes": sum(p.stat().st_blocks * 512 for p in unique), "hardlinks": 1}
        print("reference:", json.dumps(expected, sort_keys=True))
        failed = False
        for name in sorted(p.name for p in (ROOT / "scanners").glob("agent-*")):
            binary = ROOT / "scanners" / name / "fasttree-scan"
            if not binary.exists():
                print(f"{name}: not built; skipped"); continue
            out = pathlib.Path(td) / f"{name}.json"
            run = subprocess.run([str(binary), str(root), "--json", str(out), "--threads", "4"], capture_output=True, text=True)
            if run.returncode or not out.exists():
                print(f"{name}: failed to run: {run.stderr or run.stdout}"); failed = True; continue
            got = json.loads(out.read_text())
            actual = {k: got.get(k) for k in expected}
            ok = actual == expected and got.get("skipped", 0) >= 1
            print(f"{name}: {'PASS' if ok else 'FAIL'} {json.dumps(actual, sort_keys=True)} skipped={got.get('skipped')}")
            failed |= not ok
        return 1 if failed else 0
if __name__ == "__main__": sys.exit(main())
