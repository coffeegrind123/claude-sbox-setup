#!/usr/bin/env bash
# ============================================================================
# Bootstrap-And-Capture.sh — Linux equivalent of Bootstrap-And-Capture.bat
#
# Wraps the joshuascript Linux fork's `bash bootstrap` (which rebuilds managed
# DLLs against the patched engine). Detects + reports lock holders before
# the rebuild via Prepare-Bootstrap.sh, captures the build log to
# bootstrap-out.log, and reports any "file is being used" failures.
#
# On Linux, file-handle locks are much less common than on Windows, so this
# wrapper is more pass-through than the Windows version. The capture+grep
# logic stays in place for the rare case (active dotnet build server etc.).
#
# Usage:
#   ./Bootstrap-And-Capture.sh                normal run
#   ./Bootstrap-And-Capture.sh --kill-locks   non-interactively kill any
#                                             detected lock holders first
# ============================================================================

set -uo pipefail

KILL_LOCKS=0
for arg in "$@"; do
    case "$arg" in
        --kill-locks|-KillLocks) KILL_LOCKS=1 ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"
LOG_PATH="$SETUP_DIR/bootstrap-out.log"

C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
[ -t 1 ] || { C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; }

step() { echo; echo "${C_CYAN}==> $*${C_RESET}"; }
ok()   { echo "    ${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo "    ${C_YELLOW}[!!]${C_RESET} $*"; }
err()  { echo "    ${C_RED}[XX]${C_RESET} $*" >&2; }

# joshuascript fork's bootstrap entry point. It auto-installs Anvil if
# missing, validates Anvil is up-to-date, and (interactively) asks before
# building managed artifacts.
BOOTSTRAP="$SBOX_ROOT/bootstrap"

if [ ! -f "$BOOTSTRAP" ] && [ ! -f "$BOOTSTRAP.sh" ]; then
    err "No 'bootstrap' file at $SBOX_ROOT."
    err "Expected the joshuascript Linux fork (https://github.com/joshuascript/sbox-public)."
    err "Did you clone Facepunch/sbox-public by mistake? That repo has Bootstrap.bat (Windows only)."
    exit 1
fi
[ -f "$BOOTSTRAP.sh" ] && BOOTSTRAP="$BOOTSTRAP.sh"

# Step 1: detect + optionally kill lock holders.
step "[1/3] Checking for file-handle holders"
PB_ARGS=()
[ "$KILL_LOCKS" -eq 1 ] && PB_ARGS+=("--yes")
"$SETUP_DIR/Prepare-Bootstrap.sh" "${PB_ARGS[@]}" || true

# Step 2: run bash bootstrap and capture log.
step "[2/3] Running bash bootstrap (captured to $LOG_PATH)"
cd "$SBOX_ROOT" || { err "cannot cd to $SBOX_ROOT"; exit 1; }

# Run bootstrap with stdin connected so its interactive prompt ("Build
# managed artifacts now? [y/N]") works. tee writes the log alongside.
if [ -t 0 ]; then
    bash bootstrap 2>&1 | tee "$LOG_PATH"
    BOOTSTRAP_EXIT="${PIPESTATUS[0]}"
else
    # Non-interactive — pre-answer 'y' to the build prompt.
    yes y | bash bootstrap 2>&1 | tee "$LOG_PATH"
    BOOTSTRAP_EXIT="${PIPESTATUS[1]}"
fi

if [ "$BOOTSTRAP_EXIT" -ne 0 ]; then
    err "bash bootstrap failed (exit $BOOTSTRAP_EXIT)"
    err "Log captured at $LOG_PATH — inspect for the failure cause."
    exit "$BOOTSTRAP_EXIT"
fi

# Step 3: scan the log for known failure patterns.
step "[3/3] Scanning log for known failure patterns"

# "being used by another process" — the Windows-style lock failure. Possible
# but uncommon on Linux; usually only fires if a dotnet build server held
# things between Prepare-Bootstrap's scan and the actual build.
LOCKED_FILES="$(grep -oE "'[^']+\.(dll|exe)'" "$LOG_PATH" 2>/dev/null | grep -B1 "being used" | sort -u || true)"
if [ -n "$LOCKED_FILES" ]; then
    warn "Detected lock-blocked files in the build log:"
    echo "$LOCKED_FILES" | sed 's/^/    [!!]   /'
    err "Re-run with --kill-locks to forcibly release them before the next build."
    exit 1
fi

# Generic build error scan.
if grep -qE "Build FAILED|error MSB[0-9]|error CS[0-9]" "$LOG_PATH" 2>/dev/null; then
    warn "Build log contains error markers. Inspect $LOG_PATH for details."
    grep -E "Build FAILED|error MSB[0-9]|error CS[0-9]" "$LOG_PATH" | head -10 | sed 's/^/    [!!]   /'
    exit 1
fi

ok "Bootstrap completed successfully."
ok "Next: launch the editor via the Anvil script:"
ok "  bash $SBOX_ROOT/anvil/launch/launch-sbox.sh"
