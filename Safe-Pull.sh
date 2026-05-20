#!/usr/bin/env bash
# ============================================================================
# Safe-Pull.sh — Linux equivalent of Safe-Pull.ps1
#
# Snapshot → fetch → diff → reset engine → stash → pull → reapply → pop.
# Same contract as Safe-Pull.ps1 minus the Windows-specific tiers.
#
# Usage:
#   ./Safe-Pull.sh               normal run
#   ./Safe-Pull.sh --dry-run     report what would happen, don't pull
#   ./Safe-Pull.sh --force       skip pre-pull patch-presence check
#   ./Safe-Pull.sh --no-backup   skip the timestamped snapshot
# ============================================================================

set -uo pipefail

DRY_RUN=0
FORCE=0
NO_BACKUP=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-DryRun)    DRY_RUN=1 ;;
        --force|-Force)       FORCE=1 ;;
        --no-backup|-NoBackup) NO_BACKUP=1 ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"

C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
[ -t 1 ] || { C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; }

step() { echo; echo "${C_CYAN}==> $*${C_RESET}"; }
ok()   { echo "    ${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo "    ${C_YELLOW}[!!]${C_RESET} $*"; }
err()  { echo "    ${C_RED}[XX]${C_RESET} $*" >&2; }

BACKUP_DIR=""
show_restore_hint() {
    echo
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        local snap_name; snap_name="$(basename "$BACKUP_DIR")"
        echo "${C_YELLOW}[!!] To roll back to the pre-pull state, run:${C_RESET}"
        echo "${C_YELLOW}[!!]   ./Restore-From-Backup.sh --snapshot $snap_name --yes${C_RESET}"
    else
        echo "${C_YELLOW}[!!] No snapshot was taken this run. Older snapshots may help:${C_RESET}"
        echo "${C_YELLOW}[!!]   ./Restore-From-Backup.sh --list${C_RESET}"
    fi
}

cd "$SBOX_ROOT" || { err "cannot cd to $SBOX_ROOT"; exit 1; }

# ───────────────────────── Sanity check ─────────────────────────

step "Sanity check"
if [ ! -d ".git" ]; then
    err "Not a git repository (no .git/ at cwd)."; exit 1
fi
if [ ! -d "engine" ]; then
    err "engine/ directory not found in cwd. cd to sbox-public root first."; exit 1
fi
ADDON_SRC_PRESENT=0
if [ -d "game/addons/claude-sbox" ]; then
    ADDON_SRC_PRESENT=1
    ok "cwd is sbox-public root, claude-sbox addon source present"
else
    ok "cwd is sbox-public root (addon source clone not present — fine if installed from sbox.game)"
fi

# Tracked patches — same markers as Safe-Pull.ps1's $expectedPatches.
declare -A EXPECTED_PATCHES=(
    [".gitignore"]="claude-sbox"
    ["engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs"]="Manifest contains duplicate path"
    ["engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs"]='AddFromFileBuiltIn( "addons/claude-sbox/.sbproj" )'
    ["engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs"]='project.Config.Type == "tool"'
    ["engine/Sandbox.Tools/StartupLoadProject.cs"]=".sbox-global"
    ["engine/Sandbox.Engine/Services/Packages/PackageManager/PackageManager.ActivePackage.cs"]='Package.TypeName == "tool"'
    ["engine/Sandbox.Engine/Services/Packages/PackageManager/PackageLoader.cs"]='Extend the "tool assemblies'
)

# ───────────────────────── Pre-pull verification ─────────────────────────

step "Verify pre-pull patch state"
MISSING=()
for file in "${!EXPECTED_PATCHES[@]}"; do
    marker="${EXPECTED_PATCHES[$file]}"
    if [ ! -f "$file" ]; then
        MISSING+=("$file (FILE MISSING)")
        continue
    fi
    if ! grep -qF -- "$marker" "$file" 2>/dev/null; then
        MISSING+=("$file (marker not found)")
    fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    warn "Tracked patches missing or modified:"
    for m in "${MISSING[@]}"; do warn "  - $m"; done
    if [ "$FORCE" -ne 1 ]; then
        err "Aborting — engine is not in a known-patched state."
        err ""
        err "Most likely cause: you've never run Setup, OR you ran"
        err "  git checkout HEAD -- engine/  somewhere along the way and"
        err "wiped the applied patches. Fix:"
        err ""
        err "    ./Setup.sh"
        err ""
        err "Setup is idempotent — already-applied patches are skipped, and"
        err "missing ones are re-applied. Once it finishes, Safe-Pull will"
        err "pass this check."
        err ""
        err "If you genuinely want to pull anyway (you removed a patch on"
        err "purpose and the marker is stale), re-run Safe-Pull with --force."
        exit 1
    fi
    warn "Proceeding with --force despite missing patches."
else
    ok "${#EXPECTED_PATCHES[@]}/${#EXPECTED_PATCHES[@]} tracked patches present"
fi

# Existing stash entries from a prior failed run would confuse the pop step.
STASH_LIST="$(git stash list 2>/dev/null)"
if [ -n "$STASH_LIST" ] && [ "$FORCE" -ne 1 ]; then
    warn "Existing stash entries found:"
    echo "$STASH_LIST" | sed 's/^/    [!!]   /'
    err "Aborting to avoid stash confusion. Resolve existing stashes first"
    err "('git stash list', 'git stash pop' or 'git stash drop'), or rerun"
    err "with --force."
    exit 1
fi

# ───────────────────────── Snapshot backup ─────────────────────────

if [ "$NO_BACKUP" -ne 1 ]; then
    step "Snapshot backup"
    SNAP_PATH="$("$SETUP_DIR/Snapshot-Now.sh" --reason "before-safe-pull" --quiet)"
    if [ -n "$SNAP_PATH" ] && [ -d "$SNAP_PATH" ]; then
        BACKUP_DIR="$SNAP_PATH"
        ok "Backup complete at $BACKUP_DIR"
    else
        warn "Snapshot-Now.sh returned no path — continuing without backup"
    fi
else
    warn "Skipping backup (per --no-backup). No safety net if pull goes wrong."
fi

# ───────────────────────── Fetch + diff ─────────────────────────

step "Fetching upstream"
git fetch origin master 2>&1 | sed 's/^/    /'
AHEAD="$(git rev-list HEAD..origin/master --count 2>/dev/null || echo 0)"
ok "$AHEAD upstream commits incoming"
if [ "$AHEAD" -eq 0 ]; then
    ok "Already up-to-date. Nothing to pull."
    exit 0
fi

step "Check overlap with our patches"
INCOMING="$(git diff --name-only HEAD origin/master 2>/dev/null)"
OVERLAP=()
for file in "${!EXPECTED_PATCHES[@]}"; do
    if echo "$INCOMING" | grep -qxF "$file"; then
        OVERLAP+=("$file")
    fi
done
if [ "${#OVERLAP[@]}" -gt 0 ]; then
    warn "Upstream modifies files we patch — apply MAY conflict:"
    for f in "${OVERLAP[@]}"; do warn "  - $f"; done
else
    ok "No overlap with our patched files; pull should be conflict-free"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    ok "Dry run complete. Re-run without --dry-run to actually pull."
    exit 0
fi

# ───────────────────────── Pull flow ─────────────────────────

# Engine files that any patch touches. Derived from $EXPECTED_PATCHES minus
# the .gitignore key. We reset all of these to HEAD so the pull has a clean
# tree for those paths, then re-apply every patch in patches/ in numeric
# order (0005-0008 stack on 0003's file; 0011 stacks on 0004's file).
PATCHED_ENGINE_FILES=()
for f in "${!EXPECTED_PATCHES[@]}"; do
    [ "$f" != ".gitignore" ] && PATCHED_ENGINE_FILES+=("$f")
done

step "Reverting patched engine files to HEAD (clean state for pull)"
for f in "${PATCHED_ENGINE_FILES[@]}"; do
    if [ -f "$f" ]; then
        git checkout HEAD -- "$f" || { err "git checkout HEAD -- $f failed"; exit 1; }
        ok "$f restored to HEAD"
    fi
done

step "Stashing remaining tracked changes (.gitignore etc.)"
STASH_MSG="Safe-Pull auto-stash $(date -u +'%Y-%m-%d %H:%M:%S')"
STASH_OUT="$(git stash push -m "$STASH_MSG" 2>&1)"
echo "$STASH_OUT" | sed 's/^/    /'
STASHED=0
echo "$STASH_OUT" | grep -q "Saved working directory" && STASHED=1

step "Pulling"
if ! git pull --ff-only origin master 2>&1 | sed 's/^/    /'; then
    PULL_EXIT=$?
    err "git pull failed (exit $PULL_EXIT)."
    if [ "$STASHED" -eq 1 ]; then
        err "Restoring stash..."
        git stash pop 2>&1 | sed 's/^/    /'
    fi
    err "Engine files are at HEAD-before-pull. Re-apply manually with:"
    err "  git apply --3way game/addons/claude-sbox-setup/patches/*.patch"
    show_restore_hint
    exit "$PULL_EXIT"
fi

# Apply every patch on disk in numeric-prefix order. The order matters —
# patch 0011 stacks on the file 0004 modifies, so 0004 must land first.
#
# Apply strategy: strict first, --3way only as fallback. The earlier version
# used --3way unconditionally, which fails for stacked patches (0005-0008):
# their "before" blob hash refers to an intermediate (post-prior-patch) state
# that isn't a git-tracked blob, so --3way can't find it and produces conflict markers on
# what would be a clean strict apply against the already-0003-patched
# working tree.
step "Re-applying engine patches from patches/ on disk"
PATCHES_DIR="$SETUP_DIR/patches"
mapfile -t ALL_PATCHES < <(find "$PATCHES_DIR" -maxdepth 1 -name "*.patch" -type f | sort)
if [ "${#ALL_PATCHES[@]}" -eq 0 ]; then
    err "No .patch files under $PATCHES_DIR — nothing to re-apply. Engine files are at HEAD-before-pull."
    show_restore_hint
    exit 1
fi
FAILED_PATCHES=()
for patch_path in "${ALL_PATCHES[@]}"; do
    patch_name="$(basename "$patch_path")"

    # Tier 1: strict git apply against the current working tree. Works for
    # the entire chain when patches are applied in numeric order and the
    # working tree carries the cumulative effect of all prior patches.
    if git apply --ignore-whitespace "$patch_path" >/dev/null 2>&1; then
        ok "$patch_name applied"
        continue
    fi
    strict_err="$(git apply --ignore-whitespace "$patch_path" 2>&1)"

    # Tier 2: --3way. Useful when upstream rewrote the lines a patch
    # targets — git uses blob hashes in the patch header to 3-way merge.
    if git apply --3way --ignore-whitespace "$patch_path" >/dev/null 2>&1; then
        ok "$patch_name applied (3way)"
        continue
    fi
    threeway_err="$(git apply --3way --ignore-whitespace "$patch_path" 2>&1)"

    warn "$patch_name failed both strict and --3way:"
    echo "$strict_err" | sed 's/^/    [!!]   strict: /'
    echo "$threeway_err" | sed 's/^/    [!!]   3way:   /'
    FAILED_PATCHES+=("$patch_path")
done

if [ "${#FAILED_PATCHES[@]}" -gt 0 ]; then
    err "${#FAILED_PATCHES[@]} patch(es) failed to apply cleanly:"
    for p in "${FAILED_PATCHES[@]}"; do err "  - $p"; done
    err ""
    err "Recovery:"
    err "  1. Inspect the failing .patch file and the current state of the target."
    err "  2. Resolve any 3-way merge markers in the file by hand."
    err "  3. Run ./Refresh-Patches.sh to re-capture the resolved state."
    err "  4. Restart the editor + ./Bootstrap-And-Capture.sh."
    if [ "$STASHED" -eq 1 ]; then
        err ""
        err "  .gitignore is still in stash. After fixing, run: git stash pop"
    fi
    show_restore_hint
    exit 1
fi

if [ "$STASHED" -eq 1 ]; then
    step "Restoring .gitignore (git stash pop)"
    if ! git stash pop 2>&1 | sed 's/^/    /'; then
        err "git stash pop conflicts!"
        err "  - .gitignore has merge markers on disk"
        err "  - stash entry preserved (visible via 'git stash list')"
        err "  - resolve manually, 'git add .gitignore', then 'git stash drop'"
        show_restore_hint
        exit 1
    fi
fi

# ───────────────────────── Post-pull verification ─────────────────────────

step "Verify post-pull patch state"
POST_MISSING=()
for file in "${!EXPECTED_PATCHES[@]}"; do
    marker="${EXPECTED_PATCHES[$file]}"
    if [ ! -f "$file" ]; then POST_MISSING+=("$file (FILE MISSING)"); continue; fi
    if ! grep -qF -- "$marker" "$file" 2>/dev/null; then
        POST_MISSING+=("$file (marker not found)")
    fi
done
if [ "${#POST_MISSING[@]}" -gt 0 ]; then
    err "Patches missing AFTER pull — something went wrong:"
    for m in "${POST_MISSING[@]}"; do err "  - $m"; done
    show_restore_hint
    exit 1
fi
ok "${#EXPECTED_PATCHES[@]}/${#EXPECTED_PATCHES[@]} tracked patches still present"

# Spot-check addon tree if the source clone is present.
if [ "$ADDON_SRC_PRESENT" -eq 1 ]; then
    if [ ! -f "game/addons/claude-sbox/Code/Editor/ClaudeSboxBootstrap.cs" ]; then
        err "ClaudeSboxBootstrap.cs missing! Addon tree damaged."
        show_restore_hint
        exit 1
    fi
    CS_COUNT="$(find game/addons/claude-sbox -name '*.cs' -type f | wc -l)"
    if [ "$CS_COUNT" -lt 50 ]; then
        warn "claude-sbox addon has only $CS_COUNT .cs files — expected 100+. Possibly damaged."
    else
        ok "claude-sbox addon tree intact ($CS_COUNT .cs files)"
    fi
fi

step "Done"
NEW_HEAD="$(git rev-parse HEAD 2>/dev/null)"
ok "HEAD is now $NEW_HEAD"
ok "Next step: ./Bootstrap-And-Capture.sh to rebuild managed artifacts"
if [ -n "$BACKUP_DIR" ]; then
    ok "Snapshot retained at $BACKUP_DIR (safe to delete once you've verified the pull)"
fi
