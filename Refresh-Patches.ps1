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
    so they reflect the working-tree state. The sbox-public-root `.gitignore`
    is NOT in this list:
      - Its managed `# >>> claude-sbox >>> ... # <<< claude-sbox <<<` block is
        written idempotently by Setup.ps1 (one-shot at install / re-run).
      - Safe-Pull.ps1 stashes any remaining `.gitignore` mods across pulls.
    So no per-pull regen is needed for it.

    `$patchedFiles` doesn't cover every patch on disk — patch 0011
    (StartupLoadProject.cs second block) is hand-maintained because
    Refresh-Patches can't regen multiple patches against the same
    working-tree file from a single ordered map. 0011 lives under
    `patches/` directly; edit it in place if its content needs to
    change. The self-test at the bottom of this script runs
    `git apply --check` against EVERY .patch in the dir, so hand-
    maintained ones still get verified.

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
    'engine/Sandbox.Engine/Services/Packages/PackageManager/PackageManager.ActivePackage.cs' = '0009-cloud-mount-skip-whitelist-for-tool-packages.patch'
    'engine/Sandbox.Engine/Services/Packages/PackageManager/PackageLoader.cs' = '0010-packageloader-trust-remote-tool-assemblies.patch'
    # Patch 0011 also touches StartupLoadProject.cs (second block, just before
    # patch 0004's InstallAsync of claude-sbox). Hand-maintained alongside 0004
    # because Refresh-Patches can't regen multiple patches against the same
    # working-tree file from a single ordered map.
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
        # Snapshot-Now writes user-facing chatter via Write-Host (suppressed
        # by -Quiet) and emits the snapshot dir's absolute path on the
        # success Output stream. Capture it directly here instead of
        # globbing .backups/ post-hoc — the glob approach was racy when two
        # snapshots fell in the same wall-clock second (the timestamp+slug
        # collided and the wrong dir could be picked).
        $snapPath = & $snapshotScript -Reason 'before-refresh-patches' -Quiet
        if ($snapPath) { $autoSnapshotName = Split-Path $snapPath -Leaf }
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
    #
    # 2>$null discards git's autocrlf warning ("warning: in the working
    # copy of '…', LF will be replaced by CRLF the next time Git touches
    # it") so it doesn't get prepended to the captured patch content.
    # Without this, the warning becomes the first line of the .patch
    # file and downstream `git apply` runs see a malformed leading line.
    $diff = & git diff -- $sourcePath 2>$null
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
# Route through Invoke-Native + capture exit code so a stash-push that
# emitted no changes (or otherwise failed) doesn't lead us into a blind
# `git stash pop` that grabs a UNRELATED prior stash entry. Without this
# check the self-test loop could effectively restore someone's old work
# from a stash they'd intentionally parked aside.
$stashOut = Invoke-Native git stash push -m $tempStash -- @paths
$stashExit = $LASTEXITCODE
# Two acceptable shapes: a real save ("Saved working directory ...") or
# "No local changes to save" — the latter is fine, just means the working
# tree was already clean. Anything else is unexpected.
$stashed = $stashExit -eq 0 -and ($stashOut -match 'Saved working directory')
$noChanges = $stashOut -match 'No local changes to save'
if (-not $stashed -and -not $noChanges) {
    Write-Host "[XX] git stash push failed (exit $stashExit):" -ForegroundColor Red
    $stashOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Show-RestoreHint
    exit 1
}

# Self-test every .patch file on disk, not just the entries in $patchedFiles.
# Patches 0005-0008 + 0011 are hand-maintained against files that ARE in
# $patchedFiles (they multiplex two modifications onto one working-tree file)
# — so the stash above already covers them, but the previous version of this
# loop iterated $patchedFiles directly and silently skipped checking the hand-
# maintained patches. A malformed 0006.patch would slip through every self-test
# until Safe-Pull tried to apply it in production and failed for a user.
$failed = @()
$allPatches = Get-ChildItem $PatchesDir -Filter '*.patch' -ErrorAction SilentlyContinue | Sort-Object Name
foreach ($patchFile in $allPatches) {
    $patchPath = $patchFile.FullName
    $check = Invoke-Native git apply --check $patchPath
    if ($LASTEXITCODE -ne 0) {
        $failed += [pscustomobject]@{ Patch = $patchPath; Error = $check }
        Write-Host "[FAIL]  $patchPath -- $check" -ForegroundColor Red
    } else {
        Write-Host "[OK]    $patchPath applies cleanly to HEAD" -ForegroundColor Green
    }
}

# Restore the original working-tree state — but only if we actually stashed
# something. Otherwise pop would consume an unrelated prior entry.
if ($stashed) {
    Invoke-Native git stash pop | Out-Null
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "==> $($failed.Count) patch(es) failed --check. Inspect the .patch file(s) above." -ForegroundColor Red
    Show-RestoreHint
    exit 1
}

Write-Host ""
Write-Host "==> All patches verified." -ForegroundColor Cyan
