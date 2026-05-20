#requires -Version 5.1
<#
.SYNOPSIS
    List Safe-Pull snapshots and (with confirmation) restore from one.

.DESCRIPTION
    Safe-Pull writes a snapshot to .backups/<yyyyMMdd-HHmmss>/ before every
    upstream pull. Each snapshot contains:

        head.txt                    git rev-parse HEAD before the pull
        tracked.diff                git diff of every tracked-file mod
                                    (engine patches, .gitignore, etc.)
        claude-sbox-addon.zip       full addon tree zipped
        .mcp.json, CLAUDE.md        verbatim copies, if present at pull time

    This script lists what's available, lets you pick one, and restores some
    or all of it. Re-running is safe; nothing happens until you confirm
    (unless -Yes is passed).

.PARAMETER List
    Just list available snapshots and exit. Default when no other action is
    requested.

.PARAMETER Snapshot
    Snapshot timestamp directory name (e.g. "20260518-181309"). Defaults to
    the newest snapshot when omitted.

.PARAMETER PatchesOnly
    Only re-apply `tracked.diff` (engine patches + .gitignore). Leaves the
    addon source untouched.

.PARAMETER AddonOnly
    Only extract the addon zip. Leaves engine patches alone.

.PARAMETER DryRun
    Show what would be restored without writing anything.

.PARAMETER Yes
    Skip the confirmation prompt. Useful for scripts; risky interactively.

.EXAMPLE
    .\Restore-From-Backup.ps1
    Lists available snapshots and exits.

.EXAMPLE
    .\Restore-From-Backup.ps1 -Snapshot 20260518-181309
    Restores everything (patches + addon) from that specific snapshot,
    prompting before writing.

.EXAMPLE
    .\Restore-From-Backup.ps1 -PatchesOnly -DryRun
    Shows what the latest snapshot's tracked.diff would do, without applying.
#>
[CmdletBinding(DefaultParameterSetName='Default')]
param(
    [switch]$List,
    [string]$Snapshot,
    [switch]$PatchesOnly,
    [switch]$AddonOnly,
    [switch]$DryRun,
    [switch]$Yes,
    # Allow the zip-extract step to overwrite existing files in the target
    # tree. Without this, a collision aborts the addon-restore step with a
    # clear recovery hint. Use when you know the existing tree is the one
    # you're trying to replace (i.e. addon dev iteration on the same clone).
    [switch]$Force,
    # Explicitly opt in to "restore the newest snapshot" without naming it.
    # Required when no -Snapshot is given and -Yes is set — otherwise -Yes
    # alone would silently kick off a full restore against whatever happens
    # to be the most recent backup, which is a surprising amount of mutation
    # for a single-letter flag to imply.
    [switch]$Newest
)

$ErrorActionPreference = 'Continue'

# Locate sbox-public root from the addon dir.
$SetupDir = Split-Path -Parent $PSCommandPath
$SboxRoot = (Resolve-Path (Join-Path $SetupDir '..\..\..')).Path
$BackupRoot = Join-Path $SetupDir '.backups'

function Ok($m)   { Write-Host "    [OK] $m"   -ForegroundColor Green }
function Warn($m) { Write-Host "    [!!] $m"   -ForegroundColor Yellow }
function Err($m)  { Write-Host "    [XX] $m"   -ForegroundColor Red }
function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }

if (-not (Test-Path $BackupRoot)) {
    Err "No snapshots found. Expected $BackupRoot to exist."
    Err "Run Safe-Pull at least once to generate one, or check this is the right install."
    exit 1
}

# Enumerate snapshots, newest first. Each subdirectory whose name matches the
# Safe-Pull timestamp pattern counts.
$snapshots = Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
    Sort-Object Name -Descending

if ($snapshots.Count -eq 0) {
    Err "No snapshots under $BackupRoot match the yyyyMMdd-HHmmss pattern."
    exit 1
}

# Print summary table when -List was passed or when no action flag was given.
# -Newest is treated as "give me an action without naming a snapshot"; without
# it (or -Snapshot), -Yes alone falls into the list branch instead of silently
# restoring the most recent snapshot.
if ($List -or (-not $Snapshot -and -not $Newest -and -not $PatchesOnly -and -not $AddonOnly -and -not $DryRun -and -not $Yes)) {
    Step "Available snapshots"
    $rows = foreach ($s in $snapshots) {
        $headFile = Join-Path $s.FullName 'head.txt'
        $head = if (Test-Path $headFile) { (Get-Content $headFile -ErrorAction SilentlyContinue).Trim() } else { '<unknown>' }
        $zip = (Get-ChildItem $s.FullName -Filter '*addon.zip' -ErrorAction SilentlyContinue | Select-Object -First 1)
        $zipMB = if ($zip) { [math]::Round($zip.Length / 1MB, 1) } else { 0 }
        $hasDiff = Test-Path (Join-Path $s.FullName 'tracked.diff')
        $hasMcp = Test-Path (Join-Path $s.FullName '.mcp.json')
        $hasClaude = Test-Path (Join-Path $s.FullName 'CLAUDE.md')
        [pscustomobject]@{
            Snapshot  = $s.Name
            HeadSha   = $head.Substring(0, [math]::Min(10, $head.Length))
            ZipMB     = $zipMB
            HasDiff   = if ($hasDiff)   { 'yes' } else { '-' }
            HasMcp    = if ($hasMcp)    { 'yes' } else { '-' }
            CLAUDE    = if ($hasClaude) { 'yes' } else { '-' }
            Mtime     = $s.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        }
    }
    $rows | Format-Table -AutoSize
    Write-Host ""
    Write-Host "To restore everything from the newest: .\Restore-From-Backup.ps1 -Newest -Yes"
    Write-Host "To restore a specific snapshot:       .\Restore-From-Backup.ps1 -Snapshot $($snapshots[0].Name) -Yes"
    Write-Host "Other flags: -PatchesOnly, -AddonOnly, -DryRun, -Force (overwrite addon zip)"
    exit 0
}

# Pick the target snapshot. -Yes alone (no -Snapshot, no -Newest) is rejected
# above; if we got here without a -Snapshot, the user must have passed -Newest
# or one of the granular flags that defaults to newest.
if ($Snapshot) {
    $target = $snapshots | Where-Object { $_.Name -eq $Snapshot } | Select-Object -First 1
    if (-not $target) {
        Err "Snapshot '$Snapshot' not found under $BackupRoot."
        Err "Available: $(($snapshots | Select-Object -First 5).Name -join ', ')..."
        exit 1
    }
} else {
    $target = $snapshots[0]
    if ($Newest) {
        Ok "no -Snapshot supplied; -Newest selects $($target.Name)"
    }
}

Step "Restore plan"
Write-Host "    snapshot:    $($target.Name)"
Write-Host "    snapshot @:  $($target.FullName)"
$headFile = Join-Path $target.FullName 'head.txt'
if (Test-Path $headFile) {
    Write-Host "    head SHA:    $((Get-Content $headFile).Trim())"
}

$doDiff = -not $AddonOnly
$doZip  = -not $PatchesOnly

if ($doDiff) {
    $diffPath = Join-Path $target.FullName 'tracked.diff'
    if (-not (Test-Path $diffPath)) {
        Warn "tracked.diff missing in this snapshot - patches will not be restored."
        $doDiff = $false
    } else {
        Write-Host "    will apply:  $diffPath (engine patches + .gitignore mods)"
    }
}

if ($doZip) {
    $zipPath = (Get-ChildItem $target.FullName -Filter '*addon.zip' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $zipPath) {
        Warn "No *addon.zip in this snapshot - addon tree will not be restored."
        $doZip = $false
    } else {
        Write-Host "    will extract: $($zipPath.FullName) -> game\addons\<top-level-in-zip>\"
    }
}

if (-not $doDiff -and -not $doZip) {
    Err "Nothing to do - both -PatchesOnly and -AddonOnly excluded each other, or the snapshot has neither."
    exit 1
}

if ($DryRun) {
    Step "Dry run; no files changed."
    if ($doDiff) {
        Write-Host "    would: git apply --3way --ignore-whitespace $diffPath" -ForegroundColor DarkGray
    }
    if ($doZip) {
        Write-Host "    would: extract $($zipPath.FullName) -> $(Join-Path $SboxRoot 'game\addons')\" -ForegroundColor DarkGray
    }
    foreach ($aux in @('.mcp.json', 'CLAUDE.md')) {
        $src = Join-Path $target.FullName $aux
        if (Test-Path $src) {
            Write-Host "    would: prompt + copy $src -> $(Join-Path $SboxRoot $aux)" -ForegroundColor DarkGray
        }
    }
    exit 0
}

if (-not $Yes) {
    Write-Host ""
    Write-Host "This will OVERWRITE the matching files on disk. Anything you've changed" -ForegroundColor Yellow
    Write-Host "in the engine files / addon source since the snapshot will be lost." -ForegroundColor Yellow
    $reply = Read-Host "Type 'y' to proceed, anything else to abort"
    if ($reply -notmatch '^[yY]') { Err "Aborted."; exit 1 }
}

# Apply tracked.diff from sbox-public root.
if ($doDiff) {
    Step "Apply tracked.diff from sbox-public root"
    Push-Location $SboxRoot
    try {
        $out = & git apply --3way --ignore-whitespace $diffPath 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Ok "tracked.diff applied cleanly"
        } else {
            # Abort on failure rather than press on into the addon-zip
            # step. Continuing would leave the engine in a half-restored
            # state (conflict markers in some files, others unchanged)
            # while the script tells the user "Done" — a worse failure
            # mode than a clean abort with a recovery hint. Matches the
            # .sh behavior on Linux.
            Err "git apply returned $LASTEXITCODE; output below:"
            Write-Host $out -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "[!!] Aborted before addon extraction. Manual recovery options:" -ForegroundColor Yellow
            Write-Host "[!!]   - Conflict markers in the affected files: resolve by hand, then 'git add' them" -ForegroundColor Yellow
            Write-Host "[!!]   - Or discard your local mods first:" -ForegroundColor Yellow
            Write-Host "[!!]       git restore engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs" -ForegroundColor Yellow
            Write-Host "[!!]       git restore engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs" -ForegroundColor Yellow
            Write-Host "[!!]     then re-run this script." -ForegroundColor Yellow
            Write-Host "[!!]   - Or try a different snapshot: .\Restore-From-Backup.bat -List" -ForegroundColor Yellow
            Pop-Location
            exit 1
        }
    } finally {
        Pop-Location
    }
}

# Extract the addon zip into game/addons/. The zip contains a top-level
# 'claude-sbox\' folder matching where the addon lives. We extract
# preserving structure so it lands at the expected path.
if ($doZip) {
    Step "Extract addon zip"
    $gameAddons = Join-Path $SboxRoot 'game\addons'
    $topLevel = $null
    # Peek at the zip's first entry to learn the top-level dir.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zipPath.FullName)
    try {
        $first = $z.Entries | Select-Object -First 1
        if ($first) {
            $topLevel = ($first.FullName -split '[\\/]')[0]
        }
    } finally { $z.Dispose() }

    if (-not $topLevel) {
        Err "Couldn't determine top-level folder in $($zipPath.Name)."
        exit 1
    }

    $extractTarget = Join-Path $gameAddons $topLevel
    Write-Host "    extracting -> $extractTarget"

    # Expand-Archive doesn't auto-overwrite in PS 5.1; use the raw .NET API
    # which has an explicit `overwriteFiles` bool. The earlier version of
    # this block passed `$false` and relied on the post-call `$?` check,
    # but ExtractToDirectory THROWS IOException on the first existing
    # file rather than emitting a non-terminating error — so $? never
    # fired and the script aborted with a confusing stack trace mid-
    # restore, leaving a half-extracted tree.
    #
    # Now we always pass $true when -Force is set (explicit user opt-in)
    # and otherwise wrap in try/catch so a collision surfaces as a
    # readable error with a clear recovery path. Either way the call is
    # idempotent: if the target tree is clean, both modes succeed; if it
    # has files, -Force overwrites and no-Force errors clearly.
    $overwrite = [bool]$Force
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory(
            $zipPath.FullName,
            $gameAddons,
            $overwrite
        )
        Ok "addon tree restored to $extractTarget"
    } catch [System.IO.IOException] {
        Warn "Zip extract collided with existing files under $extractTarget."
        Warn "Either:"
        Warn "  - Re-run with -Force to overwrite in place, OR"
        Warn "  - Delete the target tree and re-run (manual: Remove-Item '$extractTarget' -Recurse -Force)"
        Warn "Snapshot zip remains at $($zipPath.FullName) for manual inspection."
        Warn "First conflict: $($_.Exception.Message)"
    } catch {
        Err "Zip extract failed: $($_.Exception.Message)"
        Err "Snapshot zip remains at $($zipPath.FullName); inspect manually."
    }
}

# Optional auxiliary files - environment-specific (.mcp.json, your
# container's MCP config) or user-specific (CLAUDE.md, your Claude Code
# working-doc at sbox-public root). Under -Yes we auto-restore them; the
# user opted in to non-interactive mode and presumably wants the full
# snapshot back. Without -Yes we prompt per file.
foreach ($aux in @('.mcp.json', 'CLAUDE.md')) {
    $src = Join-Path $target.FullName $aux
    if (-not (Test-Path $src)) { continue }
    Write-Host ""
    if ($Yes) {
        $reply = 'y'
    } else {
        $reply = Read-Host "Restore '$aux' from snapshot to sbox-public root? [y/N]"
    }
    if ($reply -match '^[yY]') {
        Copy-Item $src (Join-Path $SboxRoot $aux) -Force
        Ok "$aux restored"
    }
}

Step "Done"
Write-Host "Next: relaunch sbox-dev. If the engine patches changed, also run Bootstrap.bat."
