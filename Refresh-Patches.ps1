<#
.SYNOPSIS
    Regenerate the patch files in `patches/` from the current working-tree
    diffs of engine files we maintain local modifications for.

.DESCRIPTION
    Each tracked engine modification is stored as a `git diff` output in
    `patches/<NN>-<short-name>.patch`. Safe-Pull.ps1 re-applies these via
    `git apply --3way` after `git pull`, which gets cleaner merges than
    `git stash pop` because it knows the patch's parent commit and can use
    full file context to resolve hunks.

    Run this script whenever you've made or changed a local edit to one of
    the engine files in `$patchedFiles` below — it regenerates all patches
    so they reflect the working-tree state. The `.gitignore` is NOT in this
    list (it's small + append-only, kept in stash by Safe-Pull instead).

    Adding a new engine modification:
      1. Edit the engine file as usual.
      2. Add an entry to `$patchedFiles` mapping the file path to a stable
         patch filename (e.g. "engine/Sandbox.Foo/Bar.cs" → "0003-bar-fix.patch").
      3. Run this script — the new .patch file appears in patches/.
      4. Add the file + a marker substring to `Safe-Pull.ps1`'s
         `$expectedPatches` hashtable so post-pull verification picks it up.
      5. Update the README's patch list so users know what gets applied.

    Removing an engine modification:
      1. Revert the file via `git restore <path>`.
      2. Delete the entry from `$patchedFiles` here + the file from
         `$expectedPatches` in Safe-Pull.
      3. Delete the corresponding `patches/<NN>-*.patch` file.

.NOTES
    Patches are gitignored — they live alongside the working tree but never
    get committed to upstream sbox-public (which would defeat the point).
    They survive `git pull`, `git stash`, and any other normal git op.
    They do NOT survive `rm -rf patches/` or a fresh clone — in those cases,
    pull the patches anew from this repo's `patches/` directory (the
    canonical source on disk) or re-derive them from a working sbox-public
    checkout that still has the modifications in place.
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Locate sbox-public root and switch cwd. This script lives at
# <sbox-public-root>/game/addons/claude-sbox-setup/Refresh-Patches.ps1.
# The body operates on cwd = sbox-public root for `git diff <engine-file>`,
# so we shift cwd here and write outputs into this repo's patches/ folder.
$SetupDir = Split-Path -Parent $PSCommandPath
$SboxRoot = (Resolve-Path (Join-Path $SetupDir '..\..\..')).Path
Set-Location $SboxRoot

# Run a native command (typically git) with ErrorActionPreference temporarily
# flipped to 'Continue' and stderr merged into stdout. Without this, git's
# informational stderr lines get converted to PowerShell ErrorRecord objects
# under script-wide 'Stop' preference, terminating execution. Returns merged
# output as a string array; check $LASTEXITCODE for failure.
function Invoke-Native {
    param([string]$Cmd, [Parameter(ValueFromRemainingArguments)]$ArgList)
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Cmd @ArgList 2>&1
    }
    finally {
        $ErrorActionPreference = $oldPref
    }
}

# Map: working-tree file path → stable patch filename. Order matches the
# numeric prefix; renumber if you remove an entry to keep the sequence dense.
$patchedFiles = [ordered]@{
    'engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs' = '0001-engine-add-claude-sbox-to-builtin-addons.patch'
    'engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs'         = '0002-sboxbuild-dedupe-manifest-paths.patch'
    'engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs'        = '0003-publish-compile-tool-type-projects.patch'
    'engine/Sandbox.Tools/StartupLoadProject.cs'                      = '0004-startuploadproject-claude-sbox-global-install.patch'
    # Patches 0005, 0006, 0007, and 0008 also touch Utility.Projects.Compile.cs (in
    # different blocks from patch 0003). Refresh-Patches can't regen multiple patches
    # against the same working-tree file from a single map, so 0005-0008 are hand-
    # maintained: edit them directly under patches/ if their content needs to change.
}

if (-not (Test-Path .\Bootstrap.bat)) {
    Write-Host "[ERROR] $SboxRoot does not look like a sbox-public checkout (missing Bootstrap.bat)." -ForegroundColor Red
    exit 1
}

# Auto-snapshot before regenerating. Refresh-Patches overwrites patches/*.patch
# in place; if you'd hand-tuned a patch and call this carelessly, the old
# content is gone. Skip-able via the SKIP_REFRESH_SNAPSHOT env var (useful in
# tight self-testing loops where the snapshot churn isn't worth it).
$autoSnapshotName = $null
if (-not $env:SKIP_REFRESH_SNAPSHOT) {
    $snapshotScript = Join-Path $SetupDir 'Snapshot-Now.ps1'
    if (Test-Path $snapshotScript) {
        & $snapshotScript -Reason 'before-refresh-patches' -Quiet
        # Capture the name of the just-created snapshot so we can quote it
        # in the recovery hint if Refresh-Patches' self-test fails.
        $latest = Get-ChildItem (Join-Path $SetupDir '.backups') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) { $autoSnapshotName = $latest.Name }
        Write-Host "[OK] auto-snapshot taken: $autoSnapshotName" -ForegroundColor DarkGray
        Write-Host "     (set `$env:SKIP_REFRESH_SNAPSHOT='1' to skip)" -ForegroundColor DarkGray
    }
}

function Show-RestoreHint {
    Write-Host ""
    if ($autoSnapshotName) {
        Write-Host "[!!] To roll back to the pre-refresh state, run:" -ForegroundColor Yellow
        Write-Host "[!!]   .\Restore-From-Backup.bat -Snapshot $autoSnapshotName -Yes" -ForegroundColor Yellow
    } else {
        Write-Host "[!!] No auto-snapshot was taken (SKIP_REFRESH_SNAPSHOT was set). List existing:" -ForegroundColor Yellow
        Write-Host "[!!]   .\Restore-From-Backup.bat -List" -ForegroundColor Yellow
    }
}

$PatchesDir = Join-Path $SetupDir 'patches'
New-Item -ItemType Directory -Force -Path $PatchesDir | Out-Null

$generated = 0
$skipped = 0
foreach ($entry in $patchedFiles.GetEnumerator()) {
    $sourcePath = $entry.Key
    $patchPath = Join-Path $PatchesDir $entry.Value

    if (-not (Test-Path $sourcePath)) {
        Write-Host "[SKIP]  $sourcePath — file doesn't exist; remove from `$patchedFiles or restore the file" -ForegroundColor Yellow
        $skipped++
        continue
    }

    # `git diff <path>` outputs the working-tree-vs-HEAD diff for just that
    # file. Empty output means the file matches HEAD = no modification = no
    # patch to write (and we delete a stale .patch if it exists).
    $diff = & git diff -- $sourcePath
    if ([string]::IsNullOrWhiteSpace($diff)) {
        if (Test-Path $patchPath) {
            Remove-Item $patchPath -Force
            Write-Host "[CLEAN] $sourcePath has no local mods — removed stale $patchPath" -ForegroundColor Yellow
        } else {
            Write-Host "[SKIP]  $sourcePath has no local mods — nothing to write" -ForegroundColor Yellow
        }
        $skipped++
        continue
    }

    # `git diff` output is already in the format `git apply` accepts. Write
    # it verbatim to the patch file. UTF8-no-BOM keeps it diff-clean for
    # downstream readers (some Windows editors add a BOM that confuses git
    # apply's offset calculations on the first hunk).
    #
    # $patchPath is already absolute (built from $PatchesDir above); pass
    # straight to WriteAllText.
    [System.IO.File]::WriteAllText(
        $patchPath,
        ($diff -join "`n") + "`n",
        (New-Object System.Text.UTF8Encoding $false)
    )
    $bytes = (Get-Item $patchPath).Length
    Write-Host "[WROTE] $sourcePath -> $patchPath ($bytes bytes)" -ForegroundColor Green
    $generated++
}

Write-Host ""
Write-Host "==> $generated patch(es) regenerated, $skipped skipped." -ForegroundColor Cyan

# Validate every regenerated patch applies cleanly when the file is at HEAD.
# This catches the case where a regen produced a malformed patch (e.g. mixed
# line endings) that would silently break Safe-Pull's post-pull apply step.
Write-Host ""
Write-Host "==> Self-test: revert files to HEAD, apply patches, restore" -ForegroundColor Cyan
$tempStash = "Refresh-Patches self-test $(Get-Date -Format 'HH:mm:ss')"
$paths = $patchedFiles.Keys | Where-Object { Test-Path $_ }

if ($paths.Count -eq 0) {
    Write-Host "[OK] no patched files exist on disk; nothing to verify"
    exit 0
}

# Stash just the patched files so the rest of the working tree is untouched.
& git stash push -m $tempStash -- @paths | Out-Null

$failed = @()
foreach ($entry in $patchedFiles.GetEnumerator()) {
    $patchPath = Join-Path $PatchesDir $entry.Value
    if (-not (Test-Path $patchPath)) { continue }
    $check = Invoke-Native git apply --check $patchPath
    if ($LASTEXITCODE -ne 0) {
        $failed += [pscustomobject]@{ Patch = $patchPath; Error = $check }
        Write-Host "[FAIL]  $patchPath -- $check" -ForegroundColor Red
    } else {
        Write-Host "[OK]    $patchPath applies cleanly to HEAD" -ForegroundColor Green
    }
}

# Restore the original working-tree state.
& git stash pop | Out-Null

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "==> $($failed.Count) patch(es) failed --check. Inspect the .patch file(s) above." -ForegroundColor Red
    Show-RestoreHint
    exit 1
}

Write-Host ""
Write-Host "==> All patches verified." -ForegroundColor Cyan
