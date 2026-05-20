#!/usr/bin/env bash
# ============================================================================
# Restore-From-Backup.sh — Linux equivalent of Restore-From-Backup.ps1
#
# Usage:
#   ./Restore-From-Backup.sh                      list available snapshots
#   ./Restore-From-Backup.sh --list               same
#   ./Restore-From-Backup.sh --snapshot <name>    restore that snapshot (asks)
#   ./Restore-From-Backup.sh --newest --yes       restore newest, no prompt
#   ./Restore-From-Backup.sh --patches-only       restore only tracked.diff
#   ./Restore-From-Backup.sh --addon-only         restore only addon tarball
#   ./Restore-From-Backup.sh --force              allow addon-tar overwrite
# ============================================================================

set -uo pipefail

LIST=0
SNAPSHOT=""
PATCHES_ONLY=0
ADDON_ONLY=0
DRY_RUN=0
YES=0
NEWEST=0
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list|-List)              LIST=1 ;;
        --snapshot|-Snapshot)      shift; SNAPSHOT="${1:-}" ;;
        --snapshot=*)              SNAPSHOT="${1#*=}" ;;
        --patches-only|-PatchesOnly) PATCHES_ONLY=1 ;;
        --addon-only|-AddonOnly)   ADDON_ONLY=1 ;;
        --dry-run|-DryRun)         DRY_RUN=1 ;;
        --yes|-Yes)                YES=1 ;;
        --newest|-Newest)          NEWEST=1 ;;
        --force|-Force)            FORCE=1 ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"
BACKUP_ROOT="$SETUP_DIR/.backups"

C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
[ -t 1 ] || { C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; }

step() { echo; echo "${C_CYAN}==> $*${C_RESET}"; }
ok()   { echo "    ${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo "    ${C_YELLOW}[!!]${C_RESET} $*"; }
err()  { echo "    ${C_RED}[XX]${C_RESET} $*" >&2; }

if [ ! -d "$BACKUP_ROOT" ]; then
    err "No snapshots found. Expected $BACKUP_ROOT to exist."
    err "Run ./Snapshot-Now.sh or ./Safe-Pull.sh first."
    exit 1
fi

mapfile -t SNAPSHOTS < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort -r)
if [ "${#SNAPSHOTS[@]}" -eq 0 ]; then
    err "No snapshots in $BACKUP_ROOT."
    exit 1
fi

# Listing branch — when --list, OR when no action flag was given.
if [ "$LIST" -eq 1 ] || { [ -z "$SNAPSHOT" ] && [ "$NEWEST" -eq 0 ] && [ "$PATCHES_ONLY" -eq 0 ] && [ "$ADDON_ONLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$YES" -eq 0 ]; }; then
    step "Available snapshots"
    printf "    %-30s %-12s %s\n" "Snapshot" "Mtime" "Has"
    for s in "${SNAPSHOTS[@]}"; do
        name="$(basename "$s")"
        mtime="$(date -r "$s" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
        has=""
        [ -f "$s/tracked.diff" ]              && has="${has}diff "
        [ -f "$s/claude-sbox-addon.tar.gz" ]  && has="${has}tar "
        [ -f "$s/.mcp.json" ]                 && has="${has}mcp "
        [ -f "$s/CLAUDE.md" ]                 && has="${has}claude "
        printf "    %-30s %-12s %s\n" "$name" "$mtime" "$has"
    done
    echo
    echo "To restore everything from the newest: ./Restore-From-Backup.sh --newest --yes"
    echo "To restore a specific snapshot:        ./Restore-From-Backup.sh --snapshot $(basename "${SNAPSHOTS[0]}") --yes"
    echo "Other flags: --patches-only, --addon-only, --dry-run, --force"
    exit 0
fi

# Pick target snapshot.
if [ -n "$SNAPSHOT" ]; then
    TARGET="$BACKUP_ROOT/$SNAPSHOT"
    if [ ! -d "$TARGET" ]; then
        err "Snapshot '$SNAPSHOT' not found under $BACKUP_ROOT."
        err "Available:"
        for s in "${SNAPSHOTS[@]:0:5}"; do err "  $(basename "$s")"; done
        exit 1
    fi
else
    TARGET="${SNAPSHOTS[0]}"
    if [ "$NEWEST" -eq 1 ]; then
        ok "no --snapshot supplied; --newest selects $(basename "$TARGET")"
    fi
fi

step "Restore plan"
echo "    snapshot:    $(basename "$TARGET")"
echo "    snapshot @:  $TARGET"
if [ -f "$TARGET/head.txt" ]; then
    echo "    head SHA:    $(cat "$TARGET/head.txt")"
fi

DIFF_PATH="$TARGET/tracked.diff"
TAR_PATH="$TARGET/claude-sbox-addon.tar.gz"
ZIP_PATH="$TARGET/claude-sbox-addon.zip"
DO_DIFF=1
DO_TAR=1
[ "$ADDON_ONLY" -eq 1 ] && DO_DIFF=0
[ "$PATCHES_ONLY" -eq 1 ] && DO_TAR=0
if [ "$DO_DIFF" -eq 1 ] && [ ! -f "$DIFF_PATH" ]; then
    warn "no tracked.diff in this snapshot — skipping engine restore"
    DO_DIFF=0
fi
if [ "$DO_TAR" -eq 1 ] && [ ! -f "$TAR_PATH" ] && [ ! -f "$ZIP_PATH" ]; then
    warn "no addon tar/zip in this snapshot — skipping addon restore"
    DO_TAR=0
fi
if [ "$DO_DIFF" -eq 0 ] && [ "$DO_TAR" -eq 0 ]; then
    err "Nothing to do — both engine and addon pieces unavailable."
    exit 1
fi

if [ "$YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    read -r -p "    proceed with restore? [y/N] " reply
    [[ "$reply" =~ ^[yY] ]] || { echo "    aborted."; exit 0; }
fi

cd "$SBOX_ROOT" || { err "cannot cd to $SBOX_ROOT"; exit 1; }

# Engine restore via git apply --3way.
if [ "$DO_DIFF" -eq 1 ]; then
    step "Apply engine diff ($(basename "$DIFF_PATH"))"
    if [ "$DRY_RUN" -eq 1 ]; then
        ok "would: git apply --3way --ignore-whitespace $DIFF_PATH"
    else
        if git apply --3way --ignore-whitespace "$DIFF_PATH" 2>&1 | sed 's/^/    /'; then
            ok "engine diff restored"
        else
            err "git apply failed — inspect $DIFF_PATH manually"
            exit 1
        fi
    fi
fi

# Addon tarball/zip extraction.
if [ "$DO_TAR" -eq 1 ]; then
    step "Extract addon archive"
    ADDON_DST="$SBOX_ROOT/game/addons"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -f "$TAR_PATH" ]; then ok "would: tar -xzf $TAR_PATH -C $ADDON_DST"
        else                        ok "would: unzip $ZIP_PATH -d $ADDON_DST"
        fi
    else
        TARGET_DIR="$ADDON_DST/claude-sbox"
        if [ -e "$TARGET_DIR" ] && [ "$FORCE" -ne 1 ]; then
            warn "Target $TARGET_DIR already exists. Re-run with --force to overwrite,"
            warn "or remove the dir manually: rm -rf '$TARGET_DIR'"
            warn "Snapshot archive remains at $TAR_PATH$ZIP_PATH for manual inspection."
        else
            if [ -f "$TAR_PATH" ]; then
                # tar overwrites by default; same as --force behavior in spirit
                tar -xzf "$TAR_PATH" -C "$ADDON_DST"
                ok "addon tree restored to $TARGET_DIR"
            elif [ -f "$ZIP_PATH" ]; then
                # Legacy zip from Windows snapshots
                unzip -o -q "$ZIP_PATH" -d "$ADDON_DST"
                ok "addon tree restored to $TARGET_DIR (from .zip)"
            fi
        fi
    fi
fi

# Optional auxiliary files. Prompt before restoring (environment-specific).
for aux in ".mcp.json" "CLAUDE.md"; do
    src="$TARGET/$aux"
    if [ ! -f "$src" ]; then continue; fi
    echo
    if [ "$YES" -eq 1 ]; then
        reply="y"
    else
        read -r -p "    Restore '$aux' from snapshot to sbox-public root? [y/N] " reply
    fi
    if [[ "$reply" =~ ^[yY] ]]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            ok "would: cp $src $SBOX_ROOT/$aux"
        else
            cp -f "$src" "$SBOX_ROOT/$aux"
            ok "$aux restored"
        fi
    fi
done

step "Done"
ok "Restored from $(basename "$TARGET")"
