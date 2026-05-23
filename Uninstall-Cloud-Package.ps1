#requires -Version 5.1
<#
.SYNOPSIS
    Remove the cloud-installed ghage.claude-sbox package binaries plus
    (optionally) the runtime cache. Use when switching from the cloud
    package to the local source addon at game/addons/claude-sbox/.

.DESCRIPTION
    The engine patches auto-install the published ghage.claude-sbox package
    on first editor start (patch 0004 — StartupLoadProject). Patch 0012
    skips that install when game/addons/claude-sbox/.sbproj is present at
    startup — but if the cloud package was installed BEFORE the local
    source was cloned, the cloud .cll wins the load race and your local
    edits are invisible.

    This script removes the cloud install so the next editor start mounts
    the local source instead. It deletes:

        game/download/assets/_bin/package_ghage_claude_sbox.*
            The .cll (compiled assembly) + .xml (metadata) — ~640 KB.

    With -CleanCache it also deletes:

        game/.claude-sbox/cache/
            Runtime cache for sbox-docs, sbox-learn-docs, schema fingerprint,
            etc. (~900 MB). Safe to wipe — repopulates from GitHub tarballs
            on first use. Most useful when an addon update changes cache
            schemas; otherwise keep it to save the re-fetch.

    Sbox MUST be closed before running — the .cll is memory-mapped while
    the editor is up and the delete will fail with a sharing violation.

.PARAMETER DryRun
    Report what would be deleted, don't actually delete.

.PARAMETER CleanCache
    Also delete the runtime cache at game/.claude-sbox/cache/. Default
    leaves it in place.

.PARAMETER Force
    Skip the warning when game/addons/claude-sbox/.sbproj is missing.
    Without -Force, the script aborts in that case because the next
    editor start would just re-download the cloud package.

.EXAMPLE
    .\Uninstall-Cloud-Package.ps1 -DryRun
    See what would be removed.

.EXAMPLE
    .\Uninstall-Cloud-Package.ps1 -CleanCache
    Remove the package binaries AND the ~900 MB runtime cache.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$CleanCache,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$SetupDir   = Split-Path -Parent $PSCommandPath
$SboxRoot   = (Resolve-Path (Join-Path $SetupDir '..\..\..')).Path
$BinDir     = Join-Path $SboxRoot 'game\download\assets\_bin'
$CacheDir   = Join-Path $SboxRoot 'game\.claude-sbox\cache'
$LocalSbproj = Join-Path $SboxRoot 'game\addons\claude-sbox\.sbproj'

Write-Host "Uninstall-Cloud-Package"
Write-Host "  setup dir : $SetupDir"
Write-Host "  sbox root : $SboxRoot"
if ($DryRun) { Write-Host "  mode      : DRY-RUN (no files will be touched)" -ForegroundColor Yellow }
Write-Host ""

# Refuse to run while sbox is up — the .cll is locked.
$sboxProc = Get-Process -Name 'sbox-dev','sbox' -ErrorAction SilentlyContinue
if ($sboxProc) {
    Write-Host "ABORT: sbox is currently running (pid $($sboxProc[0].Id)). Close it first." -ForegroundColor Red
    exit 2
}

# Warn if the local source addon isn't present — without it, the next
# startup will re-download the cloud package via StartupLoadProject.
if (-not (Test-Path $LocalSbproj)) {
    if ($Force) {
        Write-Host "WARNING: $LocalSbproj not found — next editor start WILL re-download the cloud package." -ForegroundColor Yellow
        Write-Host "         Continuing because -Force was given." -ForegroundColor Yellow
    } else {
        Write-Host "ABORT: $LocalSbproj not found." -ForegroundColor Red
        Write-Host "       Without the local addon .sbproj, StartupLoadProject would just re-download the cloud package on the next editor start." -ForegroundColor Red
        Write-Host "       Clone https://github.com/coffeegrind123/claude-sbox into game/addons/claude-sbox/ first, then re-run." -ForegroundColor Red
        Write-Host "       (Or pass -Force to bypass this check.)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "OK: local source addon present at game/addons/claude-sbox/.sbproj"
}
Write-Host ""

# 1. Find cloud package binaries.
$pkgFiles = @()
if (Test-Path $BinDir) {
    $pkgFiles = Get-ChildItem -Path $BinDir -File -Filter 'package_ghage_claude_sbox.*' -ErrorAction SilentlyContinue
}

if ($pkgFiles.Count -eq 0) {
    Write-Host "No cloud package files found in $BinDir — already uninstalled."
} else {
    $pkgBytes = ($pkgFiles | Measure-Object -Property Length -Sum).Sum
    Write-Host "Cloud package files to remove ($($pkgFiles.Count) files, $([Math]::Round($pkgBytes/1KB)) KB):"
    foreach ($f in $pkgFiles) {
        Write-Host ("  - {0,8:N0} B  {1}" -f $f.Length, $f.FullName)
    }
    if (-not $DryRun) {
        foreach ($f in $pkgFiles) {
            Remove-Item -Path $f.FullName -Force
        }
        Write-Host "Deleted $($pkgFiles.Count) package file(s)." -ForegroundColor Green
    }
}
Write-Host ""

# 2. Runtime cache (optional, large).
if ($CleanCache) {
    if (Test-Path $CacheDir) {
        $cacheBytes = (Get-ChildItem -Path $CacheDir -Recurse -File -ErrorAction SilentlyContinue |
                       Measure-Object -Property Length -Sum).Sum
        Write-Host "Runtime cache to remove ($([Math]::Round($cacheBytes/1MB)) MB): $CacheDir"
        if (-not $DryRun) {
            Remove-Item -Path $CacheDir -Recurse -Force
            Write-Host "Deleted runtime cache." -ForegroundColor Green
        }
    } else {
        Write-Host "No runtime cache found at $CacheDir — nothing to clean."
    }
} else {
    if (Test-Path $CacheDir) {
        $cacheBytes = (Get-ChildItem -Path $CacheDir -Recurse -File -ErrorAction SilentlyContinue |
                       Measure-Object -Property Length -Sum).Sum
        Write-Host "Runtime cache preserved ($([Math]::Round($cacheBytes/1MB)) MB at game/.claude-sbox/cache/). Pass -CleanCache to wipe it."
    }
}
Write-Host ""

if ($DryRun) {
    Write-Host "Dry run complete — no files were touched." -ForegroundColor Yellow
} else {
    Write-Host "Done. Start sbox; you should see this in the log:"
    Write-Host "  [claude-sbox] local addon at game/addons/claude-sbox/ detected — skipping cloud install, local source will be used"
}
