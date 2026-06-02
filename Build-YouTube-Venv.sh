#!/usr/bin/env bash
# Provision the youtube runtime: a Python venv holding yapsnap + yt-dlp +
# imageio-ffmpeg. Source (youtube.py) lives HERE in claude-sbox-setup; the venv
# (the RUNTIME) is created in the game's GLOBAL store
# <game>/.claude-sbox/youtube/venv — NOT in the claude-sbox addon, so the
# published addon stays source-only (mirrors Build-CodeSearch-Driver). Driven by the
# youtube_install MCP tool, or run by hand. Requires Python 3 on PATH.
#
#   ./Build-YouTube-Venv.sh [force]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# HERE = <game>/addons/claude-sbox-setup ; the game root is two levels up.
GAME_DIR="$(cd "$HERE/../.." && pwd)"
VENV="$GAME_DIR/.claude-sbox/youtube/venv"
SCRIPT="$HERE/youtube/youtube_watch.py"
REPAIR="$HERE/youtube/repair_yapsnap.py"

FORCE="${1:-${YOUTUBE_FORCE:-}}"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY="python"
command -v "$PY" >/dev/null 2>&1 || { echo "ERROR: Python 3 not found on PATH (tried python3, python)." >&2; exit 3; }

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: youtube.py not found at $SCRIPT — pull the claude-sbox-setup repo." >&2
  exit 1
fi

if [ "$FORCE" = "force" ] || [ "$FORCE" = "1" ] || [ "$FORCE" = "true" ]; then
  echo "==> force: removing $VENV"
  rm -rf "$VENV"
fi

echo "==> creating venv -> $VENV"
"$PY" -m venv "$VENV"
VPY="$VENV/bin/python"
"$VPY" -m pip install --upgrade pip
echo "==> installing yapsnap + yt-dlp + imageio-ffmpeg"
"$VPY" -m pip install yapsnap yt-dlp imageio-ffmpeg

# yapsnap 0.1.2.x ships its model checksum manifest to the wrong path; relocate it.
[ -f "$REPAIR" ] && "$VPY" "$REPAIR" || true

echo "==> done. Verify in-editor with youtube_status (venv_ready:true)."
