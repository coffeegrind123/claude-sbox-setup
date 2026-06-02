#!/usr/bin/env python3
"""Put yapsnap's model_checksums.sha256 where yapsnap actually looks for it.

yapsnap 0.1.2.x has a packaging bug: the wheel installs model_checksums.sha256 to
the venv root, but yapsnap.py resolves it as `Path(__file__).parent /
"model_checksums.sha256"` (i.e. next to the module). The mismatch makes the model
downloader refuse to proceed ("checksum manifest ... is missing"). This copies the
manifest into place. No-op on versions that package it correctly.

Run with the venv's python:  $venv/bin/python repair_yapsnap.py
"""
import pathlib
import shutil
import sys

try:
    import yapsnap
except Exception as e:  # not installed / import error — nothing to repair
    print(f"[repair] yapsnap not importable ({e}); skipping", file=sys.stderr)
    sys.exit(0)

mod_dir = pathlib.Path(yapsnap.__file__).resolve().parent
target = mod_dir / "model_checksums.sha256"

if target.exists():
    print(f"[repair] manifest already present: {target}", file=sys.stderr)
    sys.exit(0)

# The wheel drops it a few levels up (venv root). Check the obvious parents first,
# then fall back to a bounded search under the environment prefix.
candidates = [p / "model_checksums.sha256" for p in (
    mod_dir.parent,            # site-packages
    mod_dir.parent.parent,     # lib/pythonX.Y
    mod_dir.parent.parent.parent,
    mod_dir.parent.parent.parent.parent,  # venv root
    pathlib.Path(sys.prefix),
)]
found = next((c for c in candidates if c.exists()), None)

if found is None:
    hits = list(pathlib.Path(sys.prefix).rglob("model_checksums.sha256"))
    found = hits[0] if hits else None

if found is None:
    print("[repair] could not locate model_checksums.sha256 anywhere under "
          f"{sys.prefix}; yapsnap may fail to download its model", file=sys.stderr)
    sys.exit(1)

shutil.copy2(found, target)
print(f"[repair] copied {found} -> {target}", file=sys.stderr)
