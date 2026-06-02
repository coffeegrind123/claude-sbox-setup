#!/usr/bin/env bash
# Explicit installer for youtube's venv (yapsnap + yt-dlp). The launcher does this
# lazily on first run too; use this to pre-warm or to force a clean reinstall.
#
#   ./install.sh            create/refresh the venv
#   ./install.sh --force    delete and recreate it
set -euo pipefail

venv="${YOUTUBE_VENV:-$HOME/.claude-sbox/youtube/venv}"
PY="${PYTHON:-python3}"

if [ "${1:-}" = "--force" ]; then
  echo "[install] removing $venv" >&2
  rm -rf "$venv"
fi

command -v "$PY" >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 3; }
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[install] WARNING: ffmpeg not found on PATH. youtube needs it for frame" >&2
  echo "          extraction and audio decode. Install via apt/brew/winget." >&2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[install] creating venv at $venv" >&2
"$PY" -m venv "$venv"
"$venv/bin/python" -m pip install --upgrade pip
"$venv/bin/python" -m pip install yapsnap yt-dlp imageio-ffmpeg

# yapsnap 0.1.2.x ships its model_checksums.sha256 to the wrong path (venv root
# instead of next to yapsnap.py), so the model downloader aborts. Put it where
# yapsnap looks. Harmless on versions that package it correctly.
"$venv/bin/python" "$here/repair_yapsnap.py" || true

echo "[install] done. yapsnap + yt-dlp installed in $venv" >&2
"$venv/bin/yapsnap" --help >/dev/null 2>&1 && echo "[install] yapsnap OK" >&2 || true
