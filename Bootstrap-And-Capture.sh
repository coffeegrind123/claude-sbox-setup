#!/usr/bin/env bash
# ============================================================================
# Bootstrap-And-Capture.sh — Linux equivalent of Bootstrap-And-Capture.bat
#
# Wraps the joshuascript Linux fork's `bash bootstrap` (which rebuilds managed
# DLLs against the patched engine). 4-stage flow mirroring
# Bootstrap-And-Capture.bat:
#   [1/4] Prepare   — Prepare-Bootstrap.sh stops processes holding the
#                     engine/managed DLLs open (sbox-dev, dotnet build server,
#                     etc.) before the rebuild. Optional via --no-prepare.
#   [2/4] Bootstrap — run `bash bootstrap` with full output captured to
#                     bootstrap-out.log.
#   [3/4] Extract   — post-process the log to pull every path reported as
#                     "being used by another process" into locked-files.txt.
#   [4/4] Cleanup   — if any locked files were captured, prompt to delete
#                     them. With --delete-locked, deletes without asking.
#
# On Linux, file-handle locks are much less common than on Windows, so the
# locked-file stages are usually no-ops. Kept in place for the rare case
# (active dotnet build server holding .dll handles).
#
# Usage:
#   ./Bootstrap-And-Capture.sh                  normal interactive run
#   ./Bootstrap-And-Capture.sh --yes            auto-confirm Prepare-Bootstrap
#   ./Bootstrap-And-Capture.sh --delete-locked  auto-delete captured holders
#                                               (implies --yes for prepare)
#   ./Bootstrap-And-Capture.sh --no-prepare     skip [1/4] entirely
#   ./Bootstrap-And-Capture.sh --kill-locks     deprecated alias for --yes
# ============================================================================

set -uo pipefail

YES=0
DELETE_LOCKED=0
NO_PREPARE=0
for arg in "$@"; do
    case "$arg" in
        --yes|-Yes)                  YES=1 ;;
        --delete-locked|-DeleteLocked) DELETE_LOCKED=1 ;;
        --no-prepare|-NoPrepare)     NO_PREPARE=1 ;;
        # --kill-locks is the legacy name; same semantics as --yes (auto-
        # confirm Prepare-Bootstrap's stop-processes prompt). Keep it
        # working so existing scripts / muscle memory don't break.
        --kill-locks|-KillLocks)     YES=1 ;;
        -h|--help)
            sed -n '2,27p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

# --delete-locked implies --yes: if you're auto-deleting locked files you
# definitely also want prepare to auto-kill holders. Matches .bat behavior.
[ "$DELETE_LOCKED" -eq 1 ] && YES=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"
LOG_PATH="$SETUP_DIR/bootstrap-out.log"
LOCKED_PATH="$SETUP_DIR/locked-files.txt"

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

# ----- [1/4] Prepare ----------------------------------------------------------
if [ "$NO_PREPARE" -eq 1 ]; then
    step "[1/4] Prepare-Bootstrap SKIPPED (--no-prepare)"
else
    if [ "$YES" -eq 1 ]; then
        step "[1/4] Stopping holders (Prepare-Bootstrap.sh --yes)"
        "$SETUP_DIR/Prepare-Bootstrap.sh" --yes || PREP_EXIT=$?
    else
        step "[1/4] Stopping holders (Prepare-Bootstrap.sh, interactive)"
        "$SETUP_DIR/Prepare-Bootstrap.sh" || PREP_EXIT=$?
    fi
    if [ "${PREP_EXIT:-0}" -ne 0 ]; then
        err "Prepare-Bootstrap.sh exited with $PREP_EXIT. Aborting."
        exit "$PREP_EXIT"
    fi
fi

# ----- [2/4] Bootstrap --------------------------------------------------------
step "[2/4] Running bash bootstrap (captured to $LOG_PATH)"
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

cd "$SETUP_DIR" || true

# ----- [3/4] Extract locked file paths ---------------------------------------
step "[3/4] Extracting locked file paths -> locked-files.txt"

# "being used by another process" — the Windows-style lock failure. Possible
# but uncommon on Linux; usually only fires if a dotnet build server held
# things between Prepare-Bootstrap's scan and the actual build. Write the
# file unconditionally (even with zero matches) so the count step downstream
# gets 0 and a stale list from a previous run can't trigger a false-positive
# "delete N files" prompt.
if grep -E "being used by another process|file lock" "$LOG_PATH" >/dev/null 2>&1; then
    grep -oE "'[^']+\.(dll|exe|so)'" "$LOG_PATH" 2>/dev/null \
        | tr -d "'" \
        | sort -u > "$LOCKED_PATH" || true
else
    : > "$LOCKED_PATH"
fi
LOCKED_COUNT="$(grep -cve '^[[:space:]]*$' "$LOCKED_PATH" 2>/dev/null || echo 0)"
if [ "$LOCKED_COUNT" -gt 0 ]; then
    warn "Captured $LOCKED_COUNT lock-blocked file(s):"
    sed 's/^/    [!!]   /' "$LOCKED_PATH"
fi

# ----- [4/4] Cleanup ----------------------------------------------------------
DELETED_FILES=0
if [ "$LOCKED_COUNT" -eq 0 ]; then
    step "[4/4] No locked files captured. Nothing to clean up."
else
    if [ "$DELETE_LOCKED" -eq 1 ]; then
        step "[4/4] Deleting $LOCKED_COUNT locked file(s) (--delete-locked)"
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if [ -e "$f" ]; then
                rm -f "$f" && ok "deleted $f"
            fi
        done < "$LOCKED_PATH"
        DELETED_FILES=1
    else
        step "[4/4] $LOCKED_COUNT locked file(s) captured"
        echo
        read -r -p "    Delete them now? [y/N] " reply
        if [[ "$reply" =~ ^[yY] ]]; then
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                if [ -e "$f" ]; then
                    rm -f "$f" && ok "deleted $f"
                fi
            done < "$LOCKED_PATH"
            DELETED_FILES=1
        else
            echo "    Skipped. Delete manually later with:"
            echo "        xargs -a $LOCKED_PATH rm -f"
        fi
    fi
fi

# Generic build error scan — catches failures the bootstrap exit code might
# not propagate (e.g. tee-pipe success even when the upstream process
# errored, late MSBuild warnings escalated to errors, etc.).
if grep -qE "Build FAILED|error MSB[0-9]|error CS[0-9]" "$LOG_PATH" 2>/dev/null; then
    warn "Build log contains error markers:"
    grep -E "Build FAILED|error MSB[0-9]|error CS[0-9]" "$LOG_PATH" | head -10 | sed 's/^/    [!!]   /'
    err "Inspect $LOG_PATH for the full failure context."
    [ "$BOOTSTRAP_EXIT" -eq 0 ] && BOOTSTRAP_EXIT=1
fi

echo
echo "--------------------------------------------------------------------------"
echo "Bootstrap exit code:  $BOOTSTRAP_EXIT"
echo "Full log:             $LOG_PATH"
echo "Locked-file list:     $LOCKED_PATH"
echo "--------------------------------------------------------------------------"
echo

# When we just deleted native .dll/.so files, the install is missing critical
# engine binaries and the editor won't launch until a second bootstrap restores
# them. Tell the user explicitly so they don't hit a confusing "sbox-dev failed
# to start" later.
if [ "$DELETED_FILES" -eq 1 ]; then
    cat <<EOF
**************************************************************************
*                                                                        *
*  ACTION REQUIRED -- Bootstrap must be re-run.                          *
*                                                                        *
*  You just deleted $LOCKED_COUNT locked file(s). The editor cannot
*  launch until the missing binaries are restored.                       *
*                                                                        *
*  Re-run this script (or the unattended form):                          *
*                                                                        *
*      ./Bootstrap-And-Capture.sh                                        *
*      ./Bootstrap-And-Capture.sh --yes --delete-locked   (unattended)   *
*                                                                        *
*  The freshly-deleted paths are not held by anything, so the next run   *
*  should report "0 locked file(s) captured".                            *
*                                                                        *
**************************************************************************

EOF
fi

if [ "$BOOTSTRAP_EXIT" -eq 0 ] && [ "$DELETED_FILES" -eq 0 ]; then
    ok "Bootstrap completed successfully."
    ok "Next: launch the editor via the Anvil script:"
    ok "  bash $SBOX_ROOT/anvil/launch/launch-sbox.sh"
fi

exit "$BOOTSTRAP_EXIT"
