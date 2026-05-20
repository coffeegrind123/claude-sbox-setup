#!/usr/bin/env bash
# ============================================================================
# Prepare-Bootstrap.sh — Linux equivalent of Prepare-Bootstrap.ps1
#
# Detect processes holding files under game/bin/managed/ that would block
# a Bootstrap rebuild. On Linux this is FAR less common than on Windows
# (Linux doesn't exclusively-lock open files), but `dotnet` build server
# processes can still hold .dll handles in some scenarios.
#
# Usage:
#   ./Prepare-Bootstrap.sh             interactive: list + prompt
#   ./Prepare-Bootstrap.sh --yes       kill detected holders without prompt
#   ./Prepare-Bootstrap.sh --dry-run   list only, don't kill
# ============================================================================

set -uo pipefail

YES=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --yes|-Yes)   YES=1 ;;
        --dry-run|-Dry|-DryRun) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBOX_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANAGED_DIR="$SBOX_ROOT/game/bin/managed"

C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
[ -t 1 ] || { C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; }

step() { echo; echo "${C_CYAN}==> $*${C_RESET}"; }
ok()   { echo "    ${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo "    ${C_YELLOW}[!!]${C_RESET} $*"; }
err()  { echo "    ${C_RED}[XX]${C_RESET} $*" >&2; }

if [ ! -d "$MANAGED_DIR" ]; then
    ok "$MANAGED_DIR doesn't exist yet — nothing could be holding it. Continuing."
    exit 0
fi

if ! command -v lsof >/dev/null 2>&1; then
    warn "lsof not installed — cannot detect file-handle holders."
    warn "Install via your package manager (e.g. 'sudo apt install lsof') to enable detection."
    warn "Proceeding without checks; Bootstrap may fail if anything is holding DLLs."
    exit 0
fi

step "Scanning $MANAGED_DIR for file-handle holders"
HOLDERS="$(lsof +D "$MANAGED_DIR" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)"

if [ -z "$HOLDERS" ]; then
    ok "No processes hold files in $MANAGED_DIR — safe to bootstrap."
    exit 0
fi

# Display holders with their command lines.
echo
warn "The following processes have files open under $MANAGED_DIR:"
while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    cmd="$(ps -p "$pid" -o comm= 2>/dev/null || echo '?')"
    full="$(ps -p "$pid" -o args= 2>/dev/null | head -c 100 || echo '?')"
    echo "    [!!]   pid=$pid  cmd=$cmd"
    echo "    [!!]     args: $full"
done <<< "$HOLDERS"

if [ "$DRY_RUN" -eq 1 ]; then
    ok "Dry run — not killing anything."
    exit 0
fi

if [ "$YES" -ne 1 ]; then
    echo
    read -r -p "    Send SIGTERM to all of the above? [y/N] " reply
    [[ "$reply" =~ ^[yY] ]] || { echo "    aborted."; exit 0; }
fi

# Send SIGTERM first, then SIGKILL after a short grace if still alive.
while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    if kill -TERM "$pid" 2>/dev/null; then
        ok "SIGTERM → pid $pid"
    fi
done <<< "$HOLDERS"

sleep 2

REMAINING="$(lsof +D "$MANAGED_DIR" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)"
if [ -n "$REMAINING" ]; then
    warn "Some holders survived SIGTERM. Escalating to SIGKILL:"
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        kill -KILL "$pid" 2>/dev/null && ok "SIGKILL → pid $pid"
    done <<< "$REMAINING"
fi

# Final check.
FINAL="$(lsof +D "$MANAGED_DIR" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)"
if [ -z "$FINAL" ]; then
    ok "All holders released."
else
    err "Holders still present after SIGKILL — investigate manually with lsof +D $MANAGED_DIR"
    exit 1
fi
