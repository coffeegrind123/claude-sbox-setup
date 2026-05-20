#requires -Version 5.1
<#
.SYNOPSIS
    Take a Safe-Pull-shaped snapshot of the current state, on demand.

.DESCRIPTION
    Safe-Pull snapshots before every upstream pull. This script does the
    same snapshot operation independent of any pull, so you can write a
    restore-point before any other risky operation: regenerating patches,
    rewriting an engine file by hand, running a destructive git command,
    starting an experiment you might want to back out of.

    Snapshot is written under <this-repo>/.backups/<yyyyMMdd-HHmmss>[-<reason>]/
    and contains:

        head.txt                    git rev-parse HEAD at snapshot time
        tracked.diff                git diff HEAD (BOTH staged and unstaged
                                    changes to tracked files)
        claude-sbox-addon.zip       full addon tree zipped
        .mcp.json, CLAUDE.md        verbatim copies if present at sbox-public root

    Roll back later with Restore-From-Backup.ps1.

.PARAMETER Reason
    Optional one-word tag appended to the snapshot folder name so you can
    find it later. e.g. -Reason "before-dispatcher-refactor" produces
    .backups/20260518-223000-before-dispatcher-refactor/. Spaces/special
    chars are sanitised to dashes.

.PARAMETER Quiet
    Less console output. Errors still print.

.EXAMPLE
    .\Snapshot-Now.ps1
    Quick snapshot with default folder name.

.EXAMPLE
    .\Snapshot-Now.ps1 -Reason "before-edit-Project.Static"
    Tagged snapshot so you can identify it in Restore-From-Backup's list.
#>
[CmdletBinding()]
param(
    [string]$Reason,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

$SetupDir = Split-Path -Parent $PSCommandPath
$SboxRoot = (Resolve-Path (Join-Path $SetupDir '..\..\..')).Path
$BackupRoot = Join-Path $SetupDir '.backups'

function Step($m) { if (-not $Quiet) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan } }
function Ok($m)   { if (-not $Quiet) { Write-Host "    [OK] $m" -ForegroundColor Green } }
function Warn($m) { Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "    [XX] $m" -ForegroundColor Red }

# Sanity check. engine/ is the stable marker for a sbox-public checkout
# (Bootstrap.bat exists today but Facepunch rewrites their bootstrap tooling
# from time to time; engine/ has been there since the repo's first commit).
if (-not (Test-Path (Join-Path $SboxRoot 'engine') -PathType Container)) {
    Err "$SboxRoot does not look like a sbox-public checkout (no engine/ dir)."
    exit 1
}
if (-not (Test-Path (Join-Path $SboxRoot '.git'))) {
    Err "$SboxRoot is not a git repository. Snapshot needs git diff to work."
    exit 1
}

# Build the snapshot folder name. Reason gets sanitised: anything not
# alphanumeric/dash/underscore becomes a dash.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$slug = ''
if ($Reason) {
    $slug = '-' + (($Reason -replace '[^A-Za-z0-9_-]', '-') -replace '-+', '-').Trim('-')
}
$dirName = "$stamp$slug"
$backupDir = Join-Path $BackupRoot $dirName

# Same-second-collision guard. If Snapshot-Now runs twice in the same wall-
# clock second with the same -Reason (back-to-back Refresh-Patches calls, a
# retry-script smashing Enter), the resulting dir name is identical and the
# earlier version of this script silently merged two snapshots into one
# (overwriting head.txt + tracked.diff with the second run's contents).
# Append a -NN suffix until we land on an unused name.
if (Test-Path $backupDir) {
    $n = 2
    while (Test-Path "$backupDir-$n") { $n++ }
    $dirName = "$dirName-$n"
    $backupDir = "$backupDir-$n"
}
New-Item -ItemType Directory -Path $backupDir | Out-Null

Step "Snapshot to $backupDir"

Push-Location $SboxRoot
try {
    # head.txt + tracked.diff. `git diff HEAD` captures BOTH staged and
    # unstaged changes (versus plain `git diff` which only shows unstaged).
    # We tripped on this gap in a prior session: staged engine patches
    # were silently dropped from the snapshot and recovery had to come
    # from patches/*.patch instead.
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git rev-parse HEAD 2>$null | Set-Content -Path (Join-Path $backupDir 'head.txt')
        & git diff HEAD       2>$null | Set-Content -Path (Join-Path $backupDir 'tracked.diff')
    } finally {
        $ErrorActionPreference = $oldPref
    }
    Ok "head.txt + tracked.diff written"

    # Addon zip.
    $addonSrc = Join-Path $SboxRoot 'game\addons\claude-sbox'
    $addonZip = Join-Path $backupDir 'claude-sbox-addon.zip'
    if (Test-Path $addonSrc) {
        Compress-Archive -Path $addonSrc -DestinationPath $addonZip -Force
        $size = [math]::Round((Get-Item $addonZip).Length / 1MB, 1)
        Ok "claude-sbox-addon.zip ($size MB)"
    } else {
        Warn "$addonSrc not present - skipping addon zip"
    }

    # Optional auxiliary files. Quiet if absent.
    foreach ($aux in @('.mcp.json', 'CLAUDE.md')) {
        $src = Join-Path $SboxRoot $aux
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $backupDir $aux) -Force
            Ok "$aux copied"
        }
    }
} finally {
    Pop-Location
}

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Restore later with:" -ForegroundColor Cyan
    Write-Host "    .\Restore-From-Backup.bat -Snapshot $dirName"
}

# Emit the snapshot dir's absolute path on the success Output stream so
# callers can capture it (e.g. `$snap = & .\Snapshot-Now.ps1 -Quiet`). All
# user-facing Step / Ok / Warn / Err calls go to Write-Host so they don't
# pollute Output; this is the only Write-Output in the script. Previously
# callers had to glob `.backups/` and sort-by-name to find "which dir did
# Snapshot-Now just create" — racy when two snapshots fell in the same
# second.
Write-Output $backupDir
