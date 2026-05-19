<#
.SYNOPSIS
    Safe wrapper around `git pull` for the sbox-public repo. Snapshots all
    in-progress work first, then runs the stash/pull/pop dance, verifies
    every tracked patch and the addon tree survived, and surfaces a clear
    recovery path on failure.

.DESCRIPTION
    The repo holds two kinds of in-progress work that a careless `git pull`
    or destructive command could nuke:
        1. Engine files modified by the claude-sbox patches — currently
           `engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs`,
           `engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs`, and
           `engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs`.
        2. Untracked work that lives outside any tracked file — the
           claude-sbox addon source if you have it under
           `game/addons/claude-sbox/`, plus any local `.mcp.json` or
           `CLAUDE.md` at the sbox-public root.

    `git pull` on its own does NOT touch untracked content, but a typo like
    `git clean -fdx` or `git checkout .` will obliterate it without a
    confirmation prompt. This script's pre-pull snapshot is the safety net.

.PARAMETER DryRun
    Do everything except the actual stash/pull/pop. Reports what WOULD
    happen so you can review the incoming commit list and any overlap with
    our patched files before committing to the merge.

.PARAMETER NoBackup
    Skip the timestamped snapshot. Faster but loses the safety net — use
    only if you've already snapshotted by other means.

.PARAMETER Force
    Bypass the pre-pull "patches present?" check. Useful only if you've
    deliberately removed a patch and want to pull anyway.

.EXAMPLE
    .\Safe-Pull.ps1
    Standard safe pull: snapshot -> stash -> pull -> pop -> verify.

.EXAMPLE
    .\Safe-Pull.ps1 -DryRun
    Show what would happen. No mutation of working tree, stash, or remote.

.NOTES
    Snapshots land at `.backups/<yyyyMMdd-HHmmss>/` containing:
        head.txt              — git rev-parse HEAD before the pull
        tracked.diff          — `git diff` output (every tracked-file edit)
        claude-sbox-addon.zip — full snapshot of game/addons/claude-sbox/
                                 (only if you have the source clone there;
                                 skipped on sbox.game-only installs)
        .mcp.json, CLAUDE.md  — verbatim copies if present

    `.backups/` is in .gitignore so snapshots don't pollute git status.
    Disk-cheap (the addon zip is ~2 MB compressed) — let them accumulate
    until you're confident the workflow is solid, then prune by hand.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoBackup,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Locate sbox-public root and switch cwd. After the move-into-addon, this
# script lives at <sbox-public-root>/game/addons/claude-sbox-setup/Safe-Pull.ps1.
# The body still operates on cwd = sbox-public root for git operations, so
# we shift cwd here and keep all the original relative paths working.
$SetupDir = Split-Path -Parent $PSCommandPath
$SboxRoot = (Resolve-Path (Join-Path $SetupDir '..\..\..')).Path
Set-Location $SboxRoot

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [OK] $msg"   -ForegroundColor Green }

# Emit a "to roll back, run X" hint pointing at the snapshot we took at
# Step 3. Safe to call when $backupDir is null (e.g. before the snapshot
# step has run or with -NoBackup) -- prints a generic hint instead.
function Show-RestoreHint {
    Write-Host ""
    if ($backupDir -and (Test-Path $backupDir)) {
        $snapName = Split-Path $backupDir -Leaf
        Write-Host "[!!] To roll back to the pre-pull state, run:" -ForegroundColor Yellow
        Write-Host "[!!]   .\game\addons\claude-sbox-setup\Restore-From-Backup.bat -Snapshot $snapName -Yes" -ForegroundColor Yellow
    } else {
        Write-Host "[!!] No snapshot was taken this run. Older snapshots may help:" -ForegroundColor Yellow
        Write-Host "[!!]   .\game\addons\claude-sbox-setup\Restore-From-Backup.bat -List" -ForegroundColor Yellow
    }
}
function Warn($msg) { Write-Host "    [!!] $msg"   -ForegroundColor Yellow }
function Err($msg)  { Write-Host "    [XX] $msg"   -ForegroundColor Red }

# Run a native command (typically git) with ErrorActionPreference temporarily
# flipped to 'Continue' and stderr merged into stdout. Without this, git's
# informational stderr lines (e.g. "From https://github.com/...", "fast-forward
# to origin/master") get converted to PowerShell ErrorRecord objects, which
# the script-wide 'Stop' preference treats as terminating.
#
# The trailing `ForEach-Object { "$_" }` coerces ErrorRecord objects back to
# plain strings, so when the caller pipes the result to Out-Host the lines
# render as normal text instead of red-formatted "git.exe : ..." error blocks
# (which look like the script failed when it didn't). Strings stay strings;
# only error records get re-stringified.
#
# Returns the merged output as a string array; check $LASTEXITCODE for failure.
function Invoke-Native {
    param([string]$Cmd, [Parameter(ValueFromRemainingArguments)]$ArgList)
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Cmd @ArgList 2>&1 | ForEach-Object { "$_" }
    }
    finally {
        $ErrorActionPreference = $oldPref
    }
}

# ──────────────────────────────────────────────────────────────────────────
# 1. Sanity — are we at the sbox-public root with the addon present?
# ──────────────────────────────────────────────────────────────────────────
Step "Sanity check"
if (-not (Test-Path .\Bootstrap.bat)) {
    Err "Bootstrap.bat not found in cwd. cd to sbox-public root first."; exit 1
}
if (-not (Test-Path .\.git)) {
    Err "Not a git repository."; exit 1
}
$addonSrcPresent = Test-Path .\game\addons\claude-sbox
if ($addonSrcPresent) {
    Ok "cwd is sbox-public root, claude-sbox addon source present"
} else {
    Ok "cwd is sbox-public root (addon source clone not present — fine if you installed claude-sbox from sbox.game)"
}

# Tracked patches we expect to find. Keyed by file path; value is a
# unique substring proving the patch is applied. Update this when adding
# a new tracked patch.
$expectedPatches = @{
    # ASCII-only markers — PS 5.1's Select-String default encoding behavior on
    # files without a BOM differs from how the script itself is read (we added
    # a BOM to the .ps1 to keep em-dashes), so any non-ASCII char in the
    # marker can mismatch the file's bytes despite both being conceptually
    # the "same" character. Keep markers in the printable-ASCII range.
    '.gitignore' = 'claude-sbox'
    'engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs' = 'Manifest contains duplicate path'
    'engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs' = 'AddFromFileBuiltIn( "addons/claude-sbox/.sbproj" )'
    'engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs' = 'project.Config.Type == "tool"'
    'engine/Sandbox.Tools/StartupLoadProject.cs' = '.sbox-global'
}

# Map: tracked engine file → patches/<file>.patch. The .gitignore is NOT here
# (it's small + append-only, no risk of upstream conflict — kept in stash
# below). Engine files use git-format patches because:
#   - `git apply --3way` is better at merging than `git stash pop` when
#     upstream rewrites surrounding code: the patch knows its parent commit
#     and uses full file context to resolve hunks.
#   - Patches are inspectable in patches/ — open one in any editor to see
#     exactly what we modified.
#   - On apply failure we get clear conflict markers + the original .patch
#     file as a reference for manual merge.
# Source-of-truth for these is the working tree; Refresh-Patches.ps1
# regenerates the .patch files when you edit the engine source.
$enginePatches = [ordered]@{
    'engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs' = "$SetupDir\patches\0001-engine-add-claude-sbox-to-builtin-addons.patch"
    'engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs'         = "$SetupDir\patches\0002-sboxbuild-dedupe-manifest-paths.patch"
    'engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs'        = "$SetupDir\patches\0003-publish-compile-tool-type-projects.patch"
}

# ──────────────────────────────────────────────────────────────────────────
# 2. Verify pre-pull state — every patch present, no leftover stash
# ──────────────────────────────────────────────────────────────────────────
Step "Verify pre-pull patch state"
$missing = @()
foreach ($file in $expectedPatches.Keys) {
    $marker = $expectedPatches[$file]
    if (-not (Test-Path $file)) { $missing += "$file (FILE MISSING)"; continue }
    if (-not (Select-String -Path $file -Pattern $marker -SimpleMatch -Quiet)) {
        $missing += "$file (marker not found)"
    }
}
if ($missing.Count -gt 0) {
    Warn "Tracked patches missing or modified:"
    $missing | ForEach-Object { Warn "  - $_" }
    if (-not $Force) {
        Err "Aborting. Run with -Force to proceed anyway, or restore the patches first."
        exit 1
    }
    Warn "Proceeding with -Force despite missing patches."
} else {
    Ok "$($expectedPatches.Count)/$($expectedPatches.Count) tracked patches present"
}

# Existing stash entries from a prior failed run would confuse the pop step.
$stashList = git stash list
if ($stashList -and -not $Force) {
    Warn "Existing stash entries found:"
    $stashList | ForEach-Object { Warn "  $_" }
    Err "Aborting to avoid stash confusion. Resolve existing stashes first ('git stash list', 'git stash pop' or 'git stash drop'), or rerun with -Force."
    exit 1
}

# ──────────────────────────────────────────────────────────────────────────
# 3. Snapshot backup — the actual safety net
# ──────────────────────────────────────────────────────────────────────────
$backupDir = $null
if (-not $NoBackup) {
    Step "Snapshot backup"
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $SetupDir ".backups\$stamp"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

    # Discard stderr (e.g. CRLF/LF auto-conversion warnings from git diff) —
    # we only want the clean stdout in the snapshot files.
    #
    # Quirk: `2>$null` ALONE doesn't actually suppress the issue under
    # ErrorActionPreference='Stop'. PS still creates an ErrorRecord from the
    # native command's stderr line BEFORE the redirect resolves, and Stop
    # terminates on it. The redirect target only affects where the record
    # would have ended up. So we have to flip EAP to 'Continue' for the
    # duration of the call, just like Invoke-Native does internally — except
    # here we want stdout pure (no merged stderr) so the saved diff is clean.
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # `git diff HEAD` captures BOTH staged and unstaged changes. Plain
        # `git diff` only shows unstaged -- if a tracked file is `git add`ed
        # but not committed (which staged engine patches were, in one
        # session), its diff silently drops out of the snapshot. Use HEAD.
        & git rev-parse HEAD 2>$null | Set-Content -Path "$backupDir\head.txt"
        & git diff HEAD       2>$null | Set-Content -Path "$backupDir\tracked.diff"
    }
    finally {
        $ErrorActionPreference = $oldPref
    }
    Ok "tracked diff + HEAD -> $backupDir\"

    if ($addonSrcPresent) {
        Compress-Archive -Path .\game\addons\claude-sbox -DestinationPath "$backupDir\claude-sbox-addon.zip" -Force
        Ok "addon tree -> $backupDir\claude-sbox-addon.zip"
    } else {
        Ok "addon source not present at game\addons\claude-sbox\ — skipping addon-zip step"
    }

    foreach ($f in @('.mcp.json', 'CLAUDE.md')) {
        if (Test-Path $f) { Copy-Item $f "$backupDir\$f" -Force }
    }
    Ok "untracked-but-precious files copied"

    Ok "Backup complete at $backupDir"
} else {
    Warn "Skipping backup (per -NoBackup). No safety net if pull goes wrong."
}

# ──────────────────────────────────────────────────────────────────────────
# 4. Fetch + diff — show what's coming and whether it overlaps our patches
# ──────────────────────────────────────────────────────────────────────────
Step "Fetching upstream"
Invoke-Native git fetch origin master | Out-Host
$ahead = [int](Invoke-Native git rev-list HEAD..origin/master --count)
Ok "$ahead upstream commits incoming"

if ($ahead -eq 0) {
    Ok "Already up-to-date. Nothing to pull."
    exit 0
}

Step "Check overlap with our patches"
$incoming = git diff --name-only HEAD origin/master
$overlap = @()
foreach ($file in $expectedPatches.Keys) {
    if ($incoming -contains $file) { $overlap += $file }
}
if ($overlap.Count -gt 0) {
    Warn "Upstream modifies files we patch — stash pop MAY conflict:"
    $overlap | ForEach-Object { Warn "  - $_" }
    Warn "If pop conflicts, resolve manually then 'git add <file>; git stash drop'."
} else {
    Ok "No overlap with our patched files; pull should be conflict-free"
}

if ($DryRun) {
    Ok "Dry run complete. Re-run without -DryRun to actually pull."
    exit 0
}

# ──────────────────────────────────────────────────────────────────────────
# 5. Pull flow — patches/* for engine files, stash for the rest
#
# Strategy:
#   - Refresh patches/*.patch from the working tree (captures any incremental
#     edits the user made since the last refresh) so we don't lose work.
#   - Restore the patched engine files to HEAD via `git checkout HEAD --`
#     so they're at upstream-pristine state for the pull.
#   - Stash whatever's left modified (in practice, just .gitignore — small,
#     append-only, low conflict risk).
#   - git pull --ff-only.
#   - git apply --3way patches/*.patch to re-introduce engine modifications.
#   - git stash pop to re-introduce .gitignore.
#
# `git apply --3way` is the win here: it knows each patch's original parent
# commit and uses full file context to merge against the new upstream state.
# When stash pop conflicts, you get markers in unfamiliar territory; when
# `git apply --3way` conflicts, the patch file itself is the reference for
# what we wanted, side by side with the file's current state.
# ──────────────────────────────────────────────────────────────────────────

Step "Refreshing patches/* from current working-tree state"
$patchesToApply = @()
foreach ($entry in $enginePatches.GetEnumerator()) {
    $sourcePath = $entry.Key
    $patchPath = $entry.Value
    if (-not (Test-Path $sourcePath)) {
        Warn "$sourcePath doesn't exist — skipping"
        continue
    }
    $diff = & git diff -- $sourcePath
    if ([string]::IsNullOrWhiteSpace($diff)) {
        # File matches HEAD; no patch needed. If a stale patch exists, leave
        # it alone — the user may have intentionally reverted but kept the
        # patch for reference. Better to be conservative here.
        Ok "$sourcePath has no local mods (no patch needed for this pull)"
        continue
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $patchPath) | Out-Null
    # $patchPath is now absolute ($SetupDir\patches\...). Earlier it was
    # relative and we Join-Path'd with cwd; doing that on an absolute path
    # produces a mangled "C:\sbox\C:\sbox\..." string that WriteAllText
    # rejects with "given path's format is not supported." Use the path
    # directly.
    [System.IO.File]::WriteAllText(
        $patchPath,
        ($diff -join "`n") + "`n",
        (New-Object System.Text.UTF8Encoding $false)
    )
    $patchesToApply += $patchPath
    Ok "wrote $patchPath ($([int]((Get-Item $patchPath).Length / 1)) bytes)"
}

Step "Reverting patched engine files to HEAD (clean state for pull)"
foreach ($sourcePath in $enginePatches.Keys) {
    if (-not (Test-Path $sourcePath)) { continue }
    Invoke-Native git checkout HEAD -- $sourcePath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Err "git checkout HEAD -- $sourcePath failed (exit $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
    Ok "$sourcePath restored to HEAD"
}

Step "Stashing remaining tracked changes (.gitignore etc.)"
$stashMsg = "Safe-Pull auto-stash $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$stashOutput = Invoke-Native git stash push -m $stashMsg
$stashOutput | Out-Host
$stashed = $LASTEXITCODE -eq 0 -and ($stashOutput -notmatch 'No local changes to save')

Step "Pulling"
Invoke-Native git pull --ff-only origin master | Out-Host
$pullExit = $LASTEXITCODE
if ($pullExit -ne 0) {
    Err "git pull failed (exit $pullExit)."
    if ($stashed) {
        Err "Restoring stash..."
        Invoke-Native git stash pop | Out-Host
    }
    Err "Engine files are at HEAD-before-pull. Re-apply manually with: git apply --3way game\addons\claude-sbox-setup\patches\*.patch"
    Show-RestoreHint
    exit $pullExit
}

Step "Re-applying engine patches (git apply --3way)"
$failedPatches = @()
foreach ($patchPath in $patchesToApply) {
    if (-not (Test-Path $patchPath)) {
        Warn "$patchPath disappeared — skipping"
        continue
    }
    $applyOutput = Invoke-Native git apply --3way $patchPath
    $applyOutput | Out-Host
    if ($LASTEXITCODE -ne 0) {
        $failedPatches += $patchPath
    } else {
        Ok "$patchPath applied"
    }
}
if ($failedPatches.Count -gt 0) {
    Err "$($failedPatches.Count) patch(es) failed to apply cleanly:"
    $failedPatches | ForEach-Object { Err "  - $_" }
    Err ""
    Err "Recovery:"
    Err "  1. Inspect the failing .patch file and the current state of the target file."
    Err "  2. Resolve any 3-way merge markers in the file by hand."
    Err "  3. Run Refresh-Patches.bat to re-capture the resolved state into the patch file."
    Err "  4. Restart the editor + Bootstrap.bat as usual."
    if ($stashed) {
        Err ""
        Err "  .gitignore is still in stash. After fixing the patches, run: git stash pop"
    }
    Show-RestoreHint
    exit 1
}

if ($stashed) {
    Step "Restoring .gitignore (git stash pop)"
    $popOutput = Invoke-Native git stash pop
    $popOutput | Out-Host
    $popExit = $LASTEXITCODE
    $hasConflict = ($popOutput -match 'CONFLICT')
    if ($popExit -ne 0 -or $hasConflict) {
        Err "git stash pop conflicts!"
        Err "  - .gitignore has merge markers on disk"
        Err "  - stash entry preserved (visible via 'git stash list')"
        Err "  - resolve manually, 'git add .gitignore', then 'git stash drop'"
        Show-RestoreHint
        exit 1
    }
}

# ──────────────────────────────────────────────────────────────────────────
# 6. Post-pull verification — every patch present, addon tree intact
# ──────────────────────────────────────────────────────────────────────────
Step "Verify post-pull patch state"
$postMissing = @()
foreach ($file in $expectedPatches.Keys) {
    $marker = $expectedPatches[$file]
    if (-not (Test-Path $file)) { $postMissing += "$file (FILE MISSING)"; continue }
    if (-not (Select-String -Path $file -Pattern $marker -SimpleMatch -Quiet)) {
        $postMissing += "$file (marker not found)"
    }
}
if ($postMissing.Count -gt 0) {
    Err "Patches missing AFTER pull — something went wrong:"
    $postMissing | ForEach-Object { Err "  - $_" }
    Show-RestoreHint
    exit 1
}
Ok "$($expectedPatches.Count)/$($expectedPatches.Count) tracked patches still present"

# Spot-check addon tree — bootstrap file plus at least 50 source files.
# Only runs when the source clone is present; sbox.game-install users skip this.
if ($addonSrcPresent) {
if (-not (Test-Path .\game\addons\claude-sbox\Code\Editor\ClaudeSboxBootstrap.cs)) {
    Err "ClaudeSboxBootstrap.cs missing! Addon tree damaged."
    Show-RestoreHint
    exit 1
}
$csCount = (Get-ChildItem .\game\addons\claude-sbox -Recurse -Filter *.cs -File).Count
if ($csCount -lt 50) {
    Warn ("claude-sbox addon has only {0} .cs files — expected 100+. Possibly damaged." -f $csCount)
} else {
    Ok ("claude-sbox addon tree intact ({0} .cs files)" -f $csCount)
}
} else {
    Ok "addon source clone not present — skipped post-pull spot-check (irrelevant for sbox.game installs)"
}

Step "Done"
$newHead = git rev-parse HEAD
Ok "HEAD is now $newHead"
Ok "Next step: .\Bootstrap.bat to download fresh artifacts + rebuild managed projects"
if ($backupDir) {
    Ok "Snapshot retained at $backupDir (safe to delete once you've verified the pull)"
}
