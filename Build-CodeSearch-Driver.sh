#!/usr/bin/env bash
# Build + deploy the forum site-scrape Playwright driver (formerly the codesearch driver —
# codesearch + release_notes are plain REST now; this driver only backs forum_*). Source lives HERE in claude-sbox-setup
# (codesearch-driver/); output is deployed to the game's GLOBAL store
# <game>/.claude-sbox/codesearch-driver/runtime/ — NOT into the claude-sbox addon, so the
# published addon stays source-only. Driven by the codesearch_install_driver MCP tool, or
# run by hand. Requires the .NET SDK.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CSPROJ="$HERE/codesearch-driver/CodeSearchDriver.csproj"
# HERE = <game>/addons/claude-sbox-setup ; the game root is two levels up.
GAME_DIR="$(cd "$HERE/../.." && pwd)"
OUT_DIR="$GAME_DIR/.claude-sbox/codesearch-driver/runtime"

if [ ! -f "$CSPROJ" ]; then
  echo "ERROR: CodeSearchDriver.csproj not found at $CSPROJ" >&2
  exit 1
fi

echo "==> publishing CodeSearchDriver -> $OUT_DIR"
dotnet publish "$CSPROJ" -c Release -o "$OUT_DIR"

echo "==> installing Chromium for Playwright"
if [ -f "$OUT_DIR/playwright.sh" ]; then
  "$OUT_DIR/playwright.sh" install chromium || echo "   (chromium install skipped; driver self-installs on first use)"
elif command -v pwsh >/dev/null 2>&1 && [ -f "$OUT_DIR/playwright.ps1" ]; then
  pwsh "$OUT_DIR/playwright.ps1" install chromium || echo "   (chromium install skipped; driver self-installs on first use)"
else
  echo "   (no playwright launcher found; driver self-installs Chromium on first use)"
fi

echo "==> done. Verify in-editor with codesearch_status (driver_dll_found:true)."
