#!/usr/bin/env bash
# ============================================================================
# Snapshot-Now.sh — Linux equivalent of Snapshot-Now.ps1
#
# Capture the current state of in-progress work to .backups/<timestamp>/:
#   head.txt              — git rev-parse HEAD before the snapshot
#   tracked.diff          — git diff HEAD output (staged + unstaged)
#   claude-sbox-addon.tar.gz — full addon tree archived (zip on Windows,
#                           tar.gz on Linux for smaller + native handling)
#   .mcp.json, CLAUDE.md  — verbatim copies if present at sbox-public root
#
# Usage:
#   ./Snapshot-Now.sh                 timestamp-only dir name
#   ./Snapshot-Now.sh --reason TAG    appends -tag to the dir name
#   ./Snapshot-Now.sh --quiet         suppress Step/Ok output (Write-Output
#                                     of the path still happens for callers)
#
# Emits the snapshot dir's absolute path on stdout. Callers (Refresh-Patches.sh)
# can capture it with $(./Snapshot-Now.sh --reason foo --quiet).
# ============================================================================

set -uo pipefail

REASON=""
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --reason=*) REASON="${arg#*=}" ;;
        --reason)   shift; REASON="${1:-}" ;;
        -Reason)    shift; REASON="${1:-}" ;;
        --quiet|-Quiet) QUIET=1 ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"
BACKUP_ROOT="$SETUP_DIR/.backups"

C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
[ -t 1 ] || { C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; }

step() { [ "$QUIET" -eq 1 ] || { echo; echo "${C_CYAN}==> $*${C_RESET}"; }; }
ok()   { [ "$QUIET" -eq 1 ] || echo "    ${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo "    ${C_YELLOW}[!!]${C_RESET} $*"; }
err()  { echo "    ${C_RED}[XX]${C_RESET} $*" >&2; }

# Sanity check — engine/ is the stable sbox-public marker.
if [ ! -d "$SBOX_ROOT/engine" ]; then
    err "$SBOX_ROOT does not look like a sbox-public checkout (no engine/ dir)."
    exit 1
fi
if [ ! -d "$SBOX_ROOT/.git" ]; then
    err "$SBOX_ROOT is not a git repository. Snapshot needs git diff to work."
    exit 1
fi

# Build snapshot folder name. Reason gets sanitised: anything not
# alphanumeric/dash/underscore becomes a dash.
# Local time (not UTC) — matches Snapshot-Now.ps1's Get-Date and how users
# mentally tag their snapshots ("the one from this morning"). Cross-platform
# snapshots taken in the same hour sort identically when they share a TZ.
STAMP="$(date +'%Y%m%d-%H%M%S')"
SLUG=""
if [ -n "$REASON" ]; then
    # tr-based sanitization to mirror the .ps1's regex replace.
    SLUG="-$(echo "$REASON" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')"
fi
DIR_NAME="$STAMP$SLUG"
BACKUP_DIR="$BACKUP_ROOT/$DIR_NAME"

# Same-second collision guard. If two snapshots fall in the same wall-clock
# second with the same -Reason, append a -NN suffix so we don't merge two
# snapshots into one dir (overwriting head.txt + tracked.diff).
if [ -e "$BACKUP_DIR" ]; then
    n=2
    while [ -e "$BACKUP_ROOT/$DIR_NAME-$n" ]; do n=$((n+1)); done
    DIR_NAME="$DIR_NAME-$n"
    BACKUP_DIR="$BACKUP_ROOT/$DIR_NAME"
fi
mkdir -p "$BACKUP_DIR"

step "Snapshot to $BACKUP_DIR"

cd "$SBOX_ROOT" || { err "cannot cd to $SBOX_ROOT"; exit 1; }

# git rev-parse HEAD + git diff HEAD. Use HEAD (not bare `git diff`) to
# capture BOTH staged and unstaged changes — staged tracked-file edits
# would otherwise drop out of the snapshot.
git rev-parse HEAD 2>/dev/null > "$BACKUP_DIR/head.txt" || echo "unknown" > "$BACKUP_DIR/head.txt"
git diff HEAD 2>/dev/null > "$BACKUP_DIR/tracked.diff" || true
ok "head.txt + tracked.diff written"

# Addon source tarball. tar.gz instead of zip — smaller + native tooling.
ADDON_SRC="$SBOX_ROOT/game/addons/claude-sbox"
if [ -d "$ADDON_SRC" ]; then
    ADDON_TAR="$BACKUP_DIR/claude-sbox-addon.tar.gz"
    tar -czf "$ADDON_TAR" -C "$SBOX_ROOT/game/addons" claude-sbox 2>/dev/null
    SIZE_MB="$(du -sm "$ADDON_TAR" 2>/dev/null | awk '{print $1}')"
    ok "claude-sbox-addon.tar.gz (${SIZE_MB}MB)"
else
    warn "$ADDON_SRC not present — skipping addon tarball"
fi

# Auxiliary files. Quiet if absent.
for aux in ".mcp.json" "CLAUDE.md"; do
    src="$SBOX_ROOT/$aux"
    if [ -f "$src" ]; then
        cp "$src" "$BACKUP_DIR/$aux"
        ok "$aux copied"
    fi
done

if [ "$QUIET" -ne 1 ]; then
    echo
    echo "Restore later with:"
    echo "    ./Restore-From-Backup.sh --snapshot $DIR_NAME"
fi

# Emit the snapshot dir's absolute path on the Output stream so callers
# can capture it (`snap=$(./Snapshot-Now.sh --reason foo --quiet)`). All
# user-facing chatter goes via step/ok/warn/err to stderr or via Write-Host
# equivalent. This is the only stdout line.
echo "$BACKUP_DIR"
