#!/usr/bin/env bash
# ============================================================================
# Refresh-Patches.sh — Linux equivalent of Refresh-Patches.ps1
#
# Regenerate patches/*.patch from the current working-tree diffs of engine
# files we maintain local modifications for. Auto-snapshots before
# regenerating so a careless run doesn't lose hand-tuned patch content.
#
# Same parity as the .ps1: patch 0011 (StartupLoadProject.cs second block)
# is hand-maintained because we can't regen multiple patches against the
# same working-tree file from a single ordered map. (The historical
# 0005-0008 stack on Utility.Projects.Compile.cs was consolidated into
# 0003, so only 0011 remains in the hand-maintained set today.)
#
# Self-test at the end runs `git apply --check` against EVERY .patch in
# patches/ — covers both regenerated AND hand-maintained patches.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"
PATCHES_DIR="$SETUP_DIR/patches"

C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_GRAY=$'\e[90m'
[ -t 1 ] || { C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""; }

cd "$SBOX_ROOT" || { echo "cannot cd to $SBOX_ROOT" >&2; exit 1; }

# Regenerable patches — file path → patch filename. Hand-maintained patch
# 0011 doesn't appear here; its file is still stashed by the self-test
# loop below (via union with $PATCHES) but never regenerated.
declare -a PATCHED_FILES_KEYS=(
    "engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs"
    "engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs"
    "engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs"
    "engine/Sandbox.Tools/StartupLoadProject.cs"
    "engine/Sandbox.Engine/Services/Packages/PackageManager/PackageManager.ActivePackage.cs"
    "engine/Sandbox.Engine/Services/Packages/PackageManager/PackageLoader.cs"
)
declare -A PATCHED_FILES=(
    ["engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs"]="0001-engine-add-claude-sbox-to-builtin-addons.patch"
    ["engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs"]="0002-sboxbuild-dedupe-manifest-paths.patch"
    ["engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs"]="0003-publish-compile-tool-type-projects.patch"
    ["engine/Sandbox.Tools/StartupLoadProject.cs"]="0004-startuploadproject-claude-sbox-global-install.patch"
    ["engine/Sandbox.Engine/Services/Packages/PackageManager/PackageManager.ActivePackage.cs"]="0009-cloud-mount-skip-whitelist-for-tool-packages.patch"
    ["engine/Sandbox.Engine/Services/Packages/PackageManager/PackageLoader.cs"]="0010-packageloader-trust-remote-tool-assemblies.patch"
)

# Auto-snapshot before regenerating. Refresh-Patches overwrites patches/*.patch
# in place; if you'd hand-tuned a patch and call this carelessly, the old
# content is gone. Skip via SKIP_REFRESH_SNAPSHOT=1.
AUTO_SNAPSHOT_NAME=""
if [ -z "${SKIP_REFRESH_SNAPSHOT:-}" ]; then
    if [ -x "$SETUP_DIR/Snapshot-Now.sh" ]; then
        SNAP_PATH="$("$SETUP_DIR/Snapshot-Now.sh" --reason "before-refresh-patches" --quiet)"
        if [ -n "$SNAP_PATH" ]; then
            AUTO_SNAPSHOT_NAME="$(basename "$SNAP_PATH")"
            echo "${C_GREEN}[OK]${C_RESET} auto-snapshot taken: $AUTO_SNAPSHOT_NAME"
            echo "${C_GRAY}    (set SKIP_REFRESH_SNAPSHOT=1 to skip)${C_RESET}"
        fi
    fi
fi

show_restore_hint() {
    echo
    if [ -n "$AUTO_SNAPSHOT_NAME" ]; then
        echo "${C_YELLOW}[!!] To roll back to the pre-refresh state, run:${C_RESET}"
        echo "${C_YELLOW}[!!]   ./Restore-From-Backup.sh --snapshot $AUTO_SNAPSHOT_NAME --yes${C_RESET}"
    else
        echo "${C_YELLOW}[!!] No auto-snapshot was taken (SKIP_REFRESH_SNAPSHOT was set). List existing:${C_RESET}"
        echo "${C_YELLOW}[!!]   ./Restore-From-Backup.sh --list${C_RESET}"
    fi
}

mkdir -p "$PATCHES_DIR"

generated=0
skipped=0
for source_path in "${PATCHED_FILES_KEYS[@]}"; do
    patch_name="${PATCHED_FILES[$source_path]}"
    patch_path="$PATCHES_DIR/$patch_name"

    if [ ! -f "$source_path" ]; then
        echo "${C_YELLOW}[SKIP]${C_RESET}  $source_path — file doesn't exist; remove from PATCHED_FILES or restore"
        skipped=$((skipped + 1))
        continue
    fi

    diff_out="$(git diff -- "$source_path" 2>/dev/null)"
    if [ -z "$(echo "$diff_out" | tr -d '[:space:]')" ]; then
        if [ -f "$patch_path" ]; then
            rm -f "$patch_path"
            echo "${C_YELLOW}[CLEAN]${C_RESET} $source_path has no local mods — removed stale $patch_path"
        else
            echo "${C_YELLOW}[SKIP]${C_RESET}  $source_path has no local mods — nothing to write"
        fi
        skipped=$((skipped + 1))
        continue
    fi

    # Write the diff as the patch file. UTF-8 no-BOM is the default for
    # printf on Linux; matches what git apply expects.
    printf '%s\n' "$diff_out" > "$patch_path"
    bytes="$(stat -c%s "$patch_path" 2>/dev/null || wc -c < "$patch_path")"
    echo "${C_GREEN}[WROTE]${C_RESET} $source_path -> $patch_path ($bytes bytes)"
    generated=$((generated + 1))
done

echo
echo "${C_CYAN}==> $generated patch(es) regenerated, $skipped skipped.${C_RESET}"

# ───────────────────────── Self-test ─────────────────────────

echo
echo "${C_CYAN}==> Self-test: revert files to HEAD, apply patches, restore${C_RESET}"
TEMP_STASH="Refresh-Patches self-test $(date -u +'%H:%M:%S')"
paths_to_stash=()
for p in "${PATCHED_FILES_KEYS[@]}"; do
    [ -f "$p" ] && paths_to_stash+=("$p")
done

if [ "${#paths_to_stash[@]}" -eq 0 ]; then
    echo "${C_GREEN}[OK]${C_RESET} no patched files exist on disk; nothing to verify"
    exit 0
fi

STASH_OUT="$(git stash push -m "$TEMP_STASH" -- "${paths_to_stash[@]}" 2>&1)"
STASH_EXIT=$?
STASHED=0
echo "$STASH_OUT" | grep -q "Saved working directory" && STASHED=1
NO_CHANGES=0
echo "$STASH_OUT" | grep -q "No local changes to save" && NO_CHANGES=1

if [ "$STASHED" -eq 0 ] && [ "$NO_CHANGES" -eq 0 ]; then
    echo "${C_RED}[XX]${C_RESET} git stash push failed (exit $STASH_EXIT):"
    echo "$STASH_OUT" | sed 's/^/    /'
    show_restore_hint
    exit 1
fi

failed=()
mapfile -t ALL_PATCHES < <(find "$PATCHES_DIR" -maxdepth 1 -name "*.patch" -type f | sort)
for patch_file in "${ALL_PATCHES[@]}"; do
    if check_out="$(git apply --check "$patch_file" 2>&1)"; then
        echo "${C_GREEN}[OK]${C_RESET}    $patch_file applies cleanly to HEAD"
    else
        failed+=("$patch_file")
        echo "${C_RED}[FAIL]${C_RESET}  $patch_file -- $check_out"
    fi
done

if [ "$STASHED" -eq 1 ]; then
    git stash pop 2>&1 | sed 's/^/    /'
fi

if [ "${#failed[@]}" -gt 0 ]; then
    echo
    echo "${C_RED}==> ${#failed[@]} patch(es) failed --check. Inspect the .patch file(s) above.${C_RESET}"
    show_restore_hint
    exit 1
fi

echo
echo "${C_CYAN}==> All patches verified.${C_RESET}"
