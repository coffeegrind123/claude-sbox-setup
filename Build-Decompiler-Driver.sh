#!/usr/bin/env bash
# Build + deploy the package decompiler driver (ICSharpCode.Decompiler) used to recover C# source
# from precompiled sbox.game packages (post-#5038 packages ship .bin/package.*.dll, not .cll source
# archives). Source lives HERE in claude-sbox-setup (decompiler-driver/); output is deployed to the
# game's GLOBAL store <game>/.claude-sbox/decompiler-driver/runtime/ — NOT into the claude-sbox
# addon, so the published addon stays source-only. Driven by the decompiler_install MCP tool, or run
# by hand. Requires the .NET SDK.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CSPROJ="$HERE/decompiler-driver/ClaudeSbox.Decompiler.Driver.csproj"
# HERE = <game>/addons/claude-sbox-setup ; the game root is two levels up.
GAME_DIR="$(cd "$HERE/../.." && pwd)"
OUT_DIR="$GAME_DIR/.claude-sbox/decompiler-driver/runtime"

if [ ! -f "$CSPROJ" ]; then
  echo "ERROR: ClaudeSbox.Decompiler.Driver.csproj not found at $CSPROJ" >&2
  exit 1
fi

echo "==> publishing ClaudeSbox.Decompiler.Driver -> $OUT_DIR"
dotnet publish "$CSPROJ" -c Release -o "$OUT_DIR"

echo "==> done. Verify in-editor with decompiler_install (driver_dll_found:true), then"
echo "    package_download a compiled package to recover C# source."
