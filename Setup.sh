#!/usr/bin/env bash
# ============================================================================
# Setup.sh — Linux equivalent of Setup.ps1
#
# Apply the claude-sbox engine patches to a sbox-public checkout (the
# joshuascript Linux fork or a Linux-native build of sbox-public). Idempotent:
# re-running after a `git pull` on sbox-public re-applies only what's missing.
#
# Logic parity with Setup.ps1 but minus the Windows-specific tiers:
#   - No CRLF normalization step (Linux is LF-native; the .patch files in
#     patches/ are already LF).
#   - No patch.exe fallback distinct from `patch` (patch IS the native tool).
#
# Idempotency probe: strict `git apply --check --reverse`. We deliberately do
# NOT use `--3way` for the probe — same false-positive trap as the Windows
# version: --3way consults git's blob database, and every patch in patches/
# has been committed to setup-repo history, so --3way reports "already
# applied" for a clean working tree at HEAD. Strict --reverse correctly
# tests the working-tree file's context lines.
#
# Forward apply tiers:
#   1. git apply (strict context)
#   2. git apply --3way (uses indexed blobs; recovers from line-number drift)
#   3. patch -p1 --fuzz=5 (last resort, accepts some context misalignment)
#
# Writes a managed `# >>> claude-sbox >>> ... # <<< claude-sbox <<<` block to
# the sbox-public-root .gitignore that excludes the addon's cache dirs +
# Snapshot-Now's .backups/ dir. Block is idempotent — re-writing it on
# subsequent runs replaces the existing block in-place.
#
# Usage:
#   ./Setup.sh                 consumer mode — print install instructions, exit
#   ./Setup.sh --dev           developer install — apply every engine patch
#   ./Setup.sh --dev --dry-run check what would happen, no mutations
#   ./Setup.sh --dev --force   skip the "already applied" idempotency probe
#
# Default (no flags) = consumer mode: tells the user to run
# `package_install ghage.claude-sbox tools` in the editor console. No engine
# touches, no clone. The contributor / source-tree workflow is opt-in via
# --dev. --dry-run and --force imply --dev (only meaningful when applying
# patches).
#
# Known limitation: re-running Setup.sh on a tree where patches are already
# applied AND have stacked context shifts may end up fuzzy-applying some
# patches at incorrect offsets (the GNU patch fuzzy matcher can find a
# different chunk that fuzzy-matches the patch's context, even with -N).
# The fresh-install path (clean engine tree → 7 strict applies) and the
# Safe-Pull-driven update flow (reset → pull → re-apply) both avoid this.
# Recovery if you suspect a double-apply: `git checkout HEAD -- engine/`
# from the sbox-public root, then re-run ./Setup.sh.
# ============================================================================

set -uo pipefail

# ───────────────────────── Argument parsing ─────────────────────────

DRY_RUN=0
FORCE=0
DEV=0
for arg in "$@"; do
    case "$arg" in
        --dev|-Dev)        DEV=1 ;;
        --dry-run|-DryRun) DRY_RUN=1 ;;
        --force|-Force)    FORCE=1 ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "[XX] unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

# --dry-run / --force are only meaningful when applying patches, so they
# imply --dev. Without this a user passing only --dry-run would silently
# fall into consumer mode and see the "exit immediately" path, which is
# confusing — they clearly intended to preview the patch apply.
if [ "$DRY_RUN" -eq 1 ] || [ "$FORCE" -eq 1 ]; then DEV=1; fi

# ───────────────────────── Consumer-mode short-circuit ─────────────────────────
# Default path. No engine touches, no clone, no managed .gitignore writes —
# just print the one-line `package_install` flow that cloud installers use.
# Exits 0 before any state is mutated.
#
# Why this is the default: most people running Setup.sh are end-users
# looking for the install command, not contributors planning to edit addon
# source. The contributor path is the explicit --dev opt-in; everyone else
# gets a fast no-op + the editor-console command.
#
# Note: the consumer path assumes the engine has already been patched
# (otherwise `package_install` will fail at compile/load time with
# whitelist errors from patches 9/10). For a fresh sbox-public checkout
# the user MUST run with --dev at least once to apply the patches, then
# they can choose source-clone (continue with --dev) or cloud-install
# (skip the source clone and use `package_install` in the editor).
# Called out in the consumer banner below so users aren't surprised.
if [ "$DEV" -eq 0 ]; then
    # Reuse the color helpers defined later in the script. They're inline
    # here so the consumer banner doesn't have to wait for sanity-check
    # logic to run before printing.
    if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        _C_RESET=$'\e[0m'; _C_CYAN=$'\e[36m'; _C_YELLOW=$'\e[33m'; _C_GRAY=$'\e[90m'
    else
        _C_RESET=""; _C_CYAN=""; _C_YELLOW=""; _C_GRAY=""
    fi
    echo
    echo "${_C_CYAN}==> claude-sbox setup (consumer mode)${_C_RESET}"
    echo
    echo "${_C_YELLOW}Install claude-sbox as a cloud package:${_C_RESET}"
    echo "  1. Launch  <sbox-public>/game/sbox-dev  (any project)"
    echo "  2. Open the developer console (~ key)"
    echo "  3. Run:    package_install ghage.claude-sbox tools"
    echo "  4. Restart the editor"
    echo
    echo "The in-editor MCP host comes up on  http://127.0.0.1:6790"
    echo "Connect Claude Code:"
    echo "  claude mcp add --transport http -s user sbox http://127.0.0.1:6790/mcp"
    echo "  (or http://host.docker.internal:6790/mcp from a devcontainer)"
    echo
    echo "${_C_GRAY}Note: cloud install requires the claude-sbox engine patches to be${_C_RESET}"
    echo "${_C_GRAY}applied on this sbox-public checkout. If your editor logs whitelist${_C_RESET}"
    echo "${_C_GRAY}errors at compile/mount time, re-run with --dev to apply them:${_C_RESET}"
    echo "${_C_GRAY}    ./Setup.sh --dev${_C_RESET}"
    echo
    echo "${_C_CYAN}For source-clone developer setup (edit addon code, contribute back),${_C_RESET}"
    echo "${_C_CYAN}use:  ./Setup.sh --dev${_C_RESET}"
    echo
    exit 0
fi

# ───────────────────────── Locate sbox-public root ─────────────────────────
# Script lives at <sbox-public-root>/game/addons/claude-sbox-setup/Setup.sh,
# so walk up three directories to find the root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"
PATCHES_DIR="$SETUP_DIR/patches"

# Pretty-print helpers. Match the .ps1's [OK]/[!!]/[XX] vocabulary so the
# Linux + Windows outputs read identically.
_supports_color() { [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; }
if _supports_color; then
    C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_GRAY=$'\e[90m'
else
    C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""
fi

step() { echo; echo "${C_CYAN}==> $*${C_RESET}"; }
ok()   { echo "    ${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo "    ${C_YELLOW}[!!]${C_RESET} $*"; }
err()  { echo "    ${C_RED}[XX]${C_RESET} $*" >&2; }
dim()  { echo "    ${C_GRAY}$*${C_RESET}"; }

echo
echo "${C_CYAN}==> claude-sbox setup (Linux)${C_RESET}"
echo "    setup:       $SETUP_DIR"
echo "    sbox-public: $SBOX_ROOT"
echo

# ───────────────────────── Sanity checks ─────────────────────────

if [ ! -d "$SBOX_ROOT/engine" ] || [ ! -d "$SBOX_ROOT/game" ]; then
    err "$SBOX_ROOT does not look like a sbox-public checkout (missing engine/ or game/)."
    err "Expected layout: <sbox-public>/game/addons/claude-sbox-setup/"
    exit 1
fi

# Sanity-check the engine source files the patches target are present —
# Facepunch occasionally moves things, and we want a friendlier error than
# "git apply: file not found" if the schema changed upstream.
for marker in \
    "$SBOX_ROOT/engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs" \
    "$SBOX_ROOT/engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs"
do
    if [ ! -f "$marker" ]; then
        err "Engine source file the patches target is missing:"
        err "  $marker"
        err "Has Facepunch moved it? Open an issue with your sbox-public commit SHA."
        exit 1
    fi
done

if [ ! -d "$PATCHES_DIR" ]; then
    err "No patches/ directory under $SETUP_DIR"
    exit 1
fi

# Collect patches in numeric-prefix order. The order matters — patch 0011
# stacks on the same StartupLoadProject.cs file that patch 0004 modifies,
# so 0004 must land first. (Earlier history had patches 0005-0008 stacked
# on 0003's file too; those were consolidated into 0003.)
mapfile -t PATCHES < <(find "$PATCHES_DIR" -maxdepth 1 -name "*.patch" -type f | sort)
if [ "${#PATCHES[@]}" -eq 0 ]; then
    err "No .patch files found under $PATCHES_DIR"
    exit 1
fi

# ───────────────────────── Apply each patch ─────────────────────────

cd "$SBOX_ROOT" || { err "cannot cd to $SBOX_ROOT"; exit 1; }
APPLIED=0
SKIPPED=0
FAILED_PATCHES=()

# --ignore-whitespace lets git apply tolerate whitespace drift in surrounding
# context lines. Especially important on a tree where multiple patches stack
# on the same file: a later patch in the chain might whitespace-shift the
# context that earlier patches' reverse-check tries to anchor against.
APPLY_FLAGS=(--ignore-whitespace)

for patch_path in "${PATCHES[@]}"; do
    patch_name="$(basename "$patch_path")"
    printf "    %s... " "$patch_name"

    # Build a CRLF-converted variant of the patch up front. Most Linux trees
    # are LF and this is unused, but a user who carries a Windows checkout
    # onto Linux (or has core.autocrlf=true inherited from their global
    # gitconfig) ends up with CRLF working-tree files. The LF patch in
    # patches/ then can't context-match, both for forward apply and for
    # the --check --reverse probe.
    crlf_patch=""
    if command -v awk >/dev/null 2>&1; then
        crlf_patch="$(mktemp -t "claude-sbox-${patch_name}.crlf.XXXXXX")"
        # Normalize any pre-existing CRLF back to LF, then convert wholesale.
        awk 'BEGIN { ORS = "\r\n" } { sub(/\r$/, ""); print }' "$patch_path" > "$crlf_patch"
    fi

    # Idempotency probe — tiered, mirroring the forward apply tiers.
    #
    # Tier R1: strict `git apply --check --reverse` on the LF patch. Fast
    # and definitive when patches stand alone.
    # Tier R2: same probe against the CRLF-converted patch. Covers Windows-
    # checkout trees on Linux.
    # Tier R3: GNU patch's `-R --dry-run`. More permissive than git apply
    # about context matching, so it can detect "already applied" even on
    # stacked patches where later patches in the chain have shifted
    # earlier patches' surrounding context. Crucially this is NOT the
    # --3way false-positive trap: --3way consults git's object database
    # which can satisfy reverse-checks against blobs that aren't actually
    # in the working tree. `patch -R` only looks at the working tree.
    if [ "$FORCE" -ne 1 ]; then
        if git apply --check --reverse "${APPLY_FLAGS[@]}" "$patch_path" >/dev/null 2>&1; then
            echo "${C_YELLOW}already applied${C_RESET}"
            SKIPPED=$((SKIPPED + 1))
            [ -n "$crlf_patch" ] && rm -f "$crlf_patch"
            continue
        fi
        if [ -n "$crlf_patch" ] && git apply --check --reverse "${APPLY_FLAGS[@]}" "$crlf_patch" >/dev/null 2>&1; then
            echo "${C_YELLOW}already applied${C_RESET} ${C_GRAY}(crlf)${C_RESET}"
            SKIPPED=$((SKIPPED + 1))
            rm -f "$crlf_patch"
            continue
        fi
        if command -v patch >/dev/null 2>&1; then
            if patch -R --dry-run -p1 --silent --input "$patch_path" >/dev/null 2>&1; then
                echo "${C_YELLOW}already applied${C_RESET} ${C_GRAY}(patch -R)${C_RESET}"
                SKIPPED=$((SKIPPED + 1))
                [ -n "$crlf_patch" ] && rm -f "$crlf_patch"
                continue
            fi
        fi
    fi

    # Dry-run: only check, don't apply.
    if [ "$DRY_RUN" -eq 1 ]; then
        if git apply --check "${APPLY_FLAGS[@]}" "$patch_path" >/dev/null 2>&1; then
            echo "${C_YELLOW}would apply (dry-run)${C_RESET}"
        else
            echo "${C_RED}WOULD FAIL (dry-run)${C_RESET}"
            git apply --check "${APPLY_FLAGS[@]}" "$patch_path" 2>&1 | sed 's/^/      /' >&2 || true
        fi
        continue
    fi

    # Tier 1: strict git apply (LF patch).
    if git apply "${APPLY_FLAGS[@]}" "$patch_path" >/dev/null 2>&1; then
        echo "${C_GREEN}applied${C_RESET}"
        APPLIED=$((APPLIED + 1))
        [ -n "$crlf_patch" ] && rm -f "$crlf_patch"
        continue
    fi
    tier1_err="$(git apply "${APPLY_FLAGS[@]}" "$patch_path" 2>&1)"

    # Tier 2: git apply --3way (3-way merge using indexed blob hashes).
    if git apply --3way "${APPLY_FLAGS[@]}" "$patch_path" >/dev/null 2>&1; then
        echo "${C_GREEN}applied (3way)${C_RESET}"
        APPLIED=$((APPLIED + 1))
        [ -n "$crlf_patch" ] && rm -f "$crlf_patch"
        continue
    fi
    tier2_err="$(git apply --3way "${APPLY_FLAGS[@]}" "$patch_path" 2>&1)"

    # Tier 3: strict git apply against the CRLF variant. Covers the
    # Windows-tree-on-Linux case where the LF patch can't context-match.
    if [ -n "$crlf_patch" ]; then
        if git apply "${APPLY_FLAGS[@]}" "$crlf_patch" >/dev/null 2>&1; then
            echo "${C_GREEN}applied (crlf)${C_RESET}"
            APPLIED=$((APPLIED + 1))
            rm -f "$crlf_patch"
            continue
        fi
        tier3_err="$(git apply "${APPLY_FLAGS[@]}" "$crlf_patch" 2>&1)"
        if git apply --3way "${APPLY_FLAGS[@]}" "$crlf_patch" >/dev/null 2>&1; then
            echo "${C_GREEN}applied (crlf-3way)${C_RESET}"
            APPLIED=$((APPLIED + 1))
            rm -f "$crlf_patch"
            continue
        fi
        tier3b_err="$(git apply --3way "${APPLY_FLAGS[@]}" "$crlf_patch" 2>&1)"
    else
        tier3_err="(awk not available, CRLF tier skipped)"
        tier3b_err=""
    fi

    # Tier 4: patch -p1 -N --fuzz=5 — last-resort fuzzy matcher.
    #
    # The `-N` flag is critical here: without it, patch will silently
    # double-apply patches whose reverse-check failed but whose forward
    # context still fuzzy-matches (the Windows version's bug). With `-N`,
    # patch refuses to apply if it detects a "Reversed or previously
    # applied" state, exiting 1 with a recognizable message. We parse
    # that to distinguish "patch genuinely failed" from "patch was
    # already applied, our probe just couldn't tell" — the latter is
    # treated as a skip, not a failure.
    if patch_exe="$(command -v patch 2>/dev/null)"; then
        # Try LF first.
        patch_out="$("$patch_exe" -p1 -N --fuzz=5 --no-backup-if-mismatch --input "$patch_path" 2>&1)"
        patch_exit=$?
        if [ "$patch_exit" -eq 0 ]; then
            echo "${C_GREEN}applied (fuzzy)${C_RESET}"
            APPLIED=$((APPLIED + 1))
            [ -n "$crlf_patch" ] && rm -f "$crlf_patch"
            continue
        fi
        if echo "$patch_out" | grep -qiE "previously applied|reversed.*patch detected"; then
            echo "${C_YELLOW}already applied${C_RESET} ${C_GRAY}(patch -N)${C_RESET}"
            SKIPPED=$((SKIPPED + 1))
            [ -n "$crlf_patch" ] && rm -f "$crlf_patch"
            continue
        fi

        # Try CRLF variant.
        if [ -n "$crlf_patch" ]; then
            patch_out="$("$patch_exe" -p1 -N --fuzz=5 --no-backup-if-mismatch --input "$crlf_patch" 2>&1)"
            patch_exit=$?
            if [ "$patch_exit" -eq 0 ]; then
                echo "${C_GREEN}applied (crlf-fuzzy)${C_RESET}"
                APPLIED=$((APPLIED + 1))
                rm -f "$crlf_patch"
                continue
            fi
            if echo "$patch_out" | grep -qiE "previously applied|reversed.*patch detected"; then
                echo "${C_YELLOW}already applied${C_RESET} ${C_GRAY}(crlf patch -N)${C_RESET}"
                SKIPPED=$((SKIPPED + 1))
                rm -f "$crlf_patch"
                continue
            fi
        fi
        tier4_err="$patch_out"
    else
        tier4_err="(patch command not found; install GNU patch)"
    fi
    [ -n "$crlf_patch" ] && rm -f "$crlf_patch"

    # All tiers failed. Surface diagnostics + recovery path.
    echo "${C_RED}FAILED${C_RESET}"
    echo
    dim "git apply (strict, LF):"
    dim "  $tier1_err"
    dim "git apply --3way (LF):"
    dim "  $tier2_err"
    if [ -n "$crlf_patch" ]; then
        dim "git apply (strict, CRLF):"
        dim "  ${tier3_err:-(not run)}"
        dim "git apply --3way (CRLF):"
        dim "  ${tier3b_err:-(not run)}"
    fi
    dim "patch --fuzz=5:"
    dim "  ${tier4_err:-(not run)}"
    echo
    err "Patch did not apply via any tier. Likely upstream sbox-public has"
    err "rewritten the lines this patch targets beyond what fuzzy matching"
    err "can handle. Inspect the patch and the target by hand:"
    err "  patch:  $patch_path"
    target="$(grep -m1 '^+++ b/' "$patch_path" | sed 's|^+++ b/||')"
    err "  target: $SBOX_ROOT/$target"
    echo
    warn "To roll back to a known-good state, list available snapshots:"
    warn "  ./Restore-From-Backup.sh --list"
    warn "then restore one with --snapshot <name> --yes."
    FAILED_PATCHES+=("$patch_name")
    exit 1
done

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "${C_CYAN}==> Dry run complete. No files changed.${C_RESET}"
    exit 0
fi
echo "${C_CYAN}==> Done. $APPLIED applied, $SKIPPED already in place.${C_RESET}"

# ───────────────────────── .gitignore managed block ─────────────────────────
# Writes a bracketed block to the sbox-public-root .gitignore. The block:
#   - Excludes .claude-sbox/ (addon's BM25/cache/learn/schema dirs).
#   - Excludes game/addons/claude-sbox-setup/.backups/ (Snapshot-Now output).
#   - Contains a literal `claude-sbox` substring, which Safe-Pull.sh's
#     marker check uses as proof that Setup ran.
# Idempotent in three ways: (a) creates .gitignore if missing, (b) regex-
# replaces the existing managed block in place if present, (c) appends if
# the markers aren't there yet.

GI_PATH="$SBOX_ROOT/.gitignore"
BEGIN_MARKER='# >>> claude-sbox (managed block -- do not edit between markers) >>>'
END_MARKER='# <<< claude-sbox <<<'
BLOCK="$(cat <<EOF
$BEGIN_MARKER
# Local addon cache (BM25 indexes, docs tarball, learn-mirror tarball, schema dumps).
.claude-sbox/

# Snapshot output from Snapshot-Now.sh / Safe-Pull.sh auto-snapshots.
game/addons/claude-sbox-setup/.backups/
$END_MARKER
EOF
)"

if [ ! -f "$GI_PATH" ]; then
    # Fresh checkout with no .gitignore — create it with just the block.
    printf '%s\n' "$BLOCK" > "$GI_PATH"
    echo
    echo "${C_CYAN}==> Wrote managed block to a new .gitignore at $GI_PATH${C_RESET}"
else
    # If the markers exist, regex-replace the block in place. If not, append.
    if grep -qF "$BEGIN_MARKER" "$GI_PATH" && grep -qF "$END_MARKER" "$GI_PATH"; then
        tmp="$(mktemp)"
        awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v block="$BLOCK" '
            $0 == begin { skipping = 1; print block; next }
            skipping && $0 == end { skipping = 0; next }
            !skipping { print }
        ' "$GI_PATH" > "$tmp"
        if ! cmp -s "$tmp" "$GI_PATH"; then
            mv "$tmp" "$GI_PATH"
            echo
            dim "==> Refreshed managed claude-sbox block in $GI_PATH"
        else
            rm -f "$tmp"
        fi
    else
        # First-time append. Ensure trailing newline before our block.
        if [ -s "$GI_PATH" ] && [ "$(tail -c1 "$GI_PATH")" != "" ]; then
            printf '\n' >> "$GI_PATH"
        fi
        printf '\n%s\n' "$BLOCK" >> "$GI_PATH"
        echo
        echo "${C_CYAN}==> Appended managed claude-sbox block to $GI_PATH${C_RESET}"
    fi
fi

# ───────────────────────── Next steps ─────────────────────────

echo
echo "Next steps:"
echo "  1. From this directory, run: ./Bootstrap-And-Capture.sh"
echo "     (wraps the joshuascript fork's 'bash bootstrap' to rebuild managed"
echo "      artifacts against the patched engine)"
echo "  2. Launch the editor via the Anvil launch script:"
echo "       bash $SBOX_ROOT/anvil/launch/launch-sbox.sh"
echo "  3. Open any project, then in the developer console run, ONCE EVER:"
echo "       package_install ghage.claude-sbox tools"
echo "     (downloads the addon to a global cache; subsequent project loads"
echo "      reuse it instantly with no redownload)"
echo "  4. The in-editor MCP host comes up on http://127.0.0.1:6790."
echo "  5. Connect Claude Code:"
echo "       claude mcp add --transport http -s user sbox http://127.0.0.1:6790/mcp"
echo "  6. For future sbox-public updates, prefer ./Safe-Pull.sh (from this directory)."
echo "     It snapshots state, reverts patches, pulls, and re-applies in one step."
