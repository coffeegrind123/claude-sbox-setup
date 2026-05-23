#!/usr/bin/env bash
# ============================================================================
# Uninstall-Cloud-Package.sh — Linux equivalent of Uninstall-Cloud-Package.ps1
#
# Remove the cloud-installed ghage.claude-sbox package binaries plus
# (optionally) the runtime cache. Use when switching from the cloud
# package to the local source addon at game/addons/claude-sbox/.
#
# The engine patches auto-install the published ghage.claude-sbox package on
# first editor start (patch 0004). Patch 0012 skips that install when
# game/addons/claude-sbox/.sbproj is present at startup — but if the cloud
# package was installed BEFORE the local source was cloned, the cloud .cll
# wins the load race and your local edits are invisible.
#
# Usage:
#   ./Uninstall-Cloud-Package.sh                  remove cloud .cll + .xml
#   ./Uninstall-Cloud-Package.sh --dry-run        report what would happen
#   ./Uninstall-Cloud-Package.sh --clean-cache    also wipe game/.claude-sbox/cache/ (~900 MB)
#   ./Uninstall-Cloud-Package.sh --force          skip the missing-.sbproj abort
#
# CLOSE SBOX before running — the .cll is memory-mapped while the editor
# is up and the delete fails with a sharing violation.
#
# Exit codes:
#   0  success (or nothing to do)
#   1  local addon .sbproj missing (re-download would happen on next start)
#   2  sbox is currently running
# ============================================================================

set -uo pipefail

DRY_RUN=0
CLEAN_CACHE=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-DryRun)         DRY_RUN=1 ;;
        --clean-cache|-CleanCache) CLEAN_CACHE=1 ;;
        --force|-Force)            FORCE=1 ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 64
            ;;
    esac
done

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"
BIN_DIR="$SBOX_ROOT/game/download/assets/_bin"
CACHE_DIR="$SBOX_ROOT/game/.claude-sbox/cache"
LOCAL_SBPROJ="$SBOX_ROOT/game/addons/claude-sbox/.sbproj"

echo "Uninstall-Cloud-Package"
echo "  setup dir : $SETUP_DIR"
echo "  sbox root : $SBOX_ROOT"
[[ $DRY_RUN -eq 1 ]] && echo "  mode      : DRY-RUN (no files will be touched)"
echo ""

# Refuse to run while sbox is up.
if pgrep -x sbox-dev >/dev/null 2>&1 || pgrep -x sbox >/dev/null 2>&1; then
    echo "ABORT: sbox is currently running. Close it first." >&2
    exit 2
fi

# Warn / abort if the local source addon isn't present.
if [[ ! -f "$LOCAL_SBPROJ" ]]; then
    if [[ $FORCE -eq 1 ]]; then
        echo "WARNING: $LOCAL_SBPROJ not found — next editor start WILL re-download the cloud package."
        echo "         Continuing because --force was given."
    else
        echo "ABORT: $LOCAL_SBPROJ not found." >&2
        echo "       Without the local addon .sbproj, StartupLoadProject would just re-download the cloud package on the next editor start." >&2
        echo "       Clone https://github.com/coffeegrind123/claude-sbox into game/addons/claude-sbox/ first, then re-run." >&2
        echo "       (Or pass --force to bypass this check.)" >&2
        exit 1
    fi
else
    echo "OK: local source addon present at game/addons/claude-sbox/.sbproj"
fi
echo ""

# 1. Cloud package binaries.
shopt -s nullglob
pkg_files=( "$BIN_DIR"/package_ghage_claude_sbox.* )
shopt -u nullglob

if [[ ${#pkg_files[@]} -eq 0 ]]; then
    echo "No cloud package files found in $BIN_DIR — already uninstalled."
else
    pkg_bytes=$(du -bc "${pkg_files[@]}" 2>/dev/null | tail -1 | awk '{print $1}')
    pkg_kb=$(( pkg_bytes / 1024 ))
    echo "Cloud package files to remove (${#pkg_files[@]} files, ${pkg_kb} KB):"
    for f in "${pkg_files[@]}"; do
        printf "  - %8d B  %s\n" "$(stat -c%s "$f")" "$f"
    done
    if [[ $DRY_RUN -eq 0 ]]; then
        rm -f "${pkg_files[@]}"
        echo "Deleted ${#pkg_files[@]} package file(s)."
    fi
fi
echo ""

# 2. Runtime cache (optional).
if [[ $CLEAN_CACHE -eq 1 ]]; then
    if [[ -d "$CACHE_DIR" ]]; then
        cache_mb=$(du -sm "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
        echo "Runtime cache to remove (${cache_mb} MB): $CACHE_DIR"
        if [[ $DRY_RUN -eq 0 ]]; then
            rm -rf "$CACHE_DIR"
            echo "Deleted runtime cache."
        fi
    else
        echo "No runtime cache found at $CACHE_DIR — nothing to clean."
    fi
else
    if [[ -d "$CACHE_DIR" ]]; then
        cache_mb=$(du -sm "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
        echo "Runtime cache preserved (${cache_mb} MB at game/.claude-sbox/cache/). Pass --clean-cache to wipe it."
    fi
fi
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run complete — no files were touched."
else
    echo "Done. Start sbox; you should see this in the log:"
    echo "  [claude-sbox] local addon at game/addons/claude-sbox/ detected — skipping cloud install, local source will be used"
fi
