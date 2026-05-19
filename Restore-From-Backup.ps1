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
        openclaude-addon.zip        legacy name for snapshots from before
                                    the openclaude -> claude-sbox rename
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
    [switch]$Yes
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
if ($List -or (-not $Snapshot -and -not $PatchesOnly -and -not $AddonOnly -and -not $DryRun -and -not $Yes)) {
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
    Write-Host "To restore everything from the newest: .\Restore-From-Backup.ps1 -Yes"
    Write-Host "To restore a specific snapshot:       .\Restore-From-Backup.ps1 -Snapshot $($snapshots[0].Name) -Yes"
    Write-Host "Other flags: -PatchesOnly, -AddonOnly, -DryRun"
    exit 0
}

# Pick the target snapshot.
if ($Snapshot) {
    $target = $snapshots | Where-Object { $_.Name -eq $Snapshot } | Select-Object -First 1
    if (-not $target) {
        Err "Snapshot '$Snapshot' not found under $BackupRoot."
        Err "Available: $(($snapshots | Select-Object -First 5).Name -join ', ')..."
        exit 1
    }
} else {
    $target = $snapshots[0]
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
        Write-Host "    (top-level folder in older snapshots is 'openclaude\'; newer ones are 'claude-sbox\')"
    }
}

if (-not $doDiff -and -not $doZip) {
    Err "Nothing to do - both -PatchesOnly and -AddonOnly excluded each other, or the snapshot has neither."
    exit 1
}

if ($DryRun) {
    Step "Dry run; no files changed."
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
            Warn "git apply returned $LASTEXITCODE; output below:"
            Write-Host $out -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "[!!] Manual recovery options:" -ForegroundColor Yellow
            Write-Host "[!!]   - Conflict markers in the affected files: resolve by hand, then 'git add' them" -ForegroundColor Yellow
            Write-Host "[!!]   - Or discard your local mods first:" -ForegroundColor Yellow
            Write-Host "[!!]       git restore engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs" -ForegroundColor Yellow
            Write-Host "[!!]       git restore engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs" -ForegroundColor Yellow
            Write-Host "[!!]     then re-run this script." -ForegroundColor Yellow
            Write-Host "[!!]   - Or try a different snapshot: .\Restore-From-Backup.bat -List" -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
    }
}

# Extract the addon zip into game/addons/. Each zip contains a top-level
# folder ('openclaude\' or 'claude-sbox\') matching where the addon lived
# at the time of the snapshot. We extract preserving structure so the user
# can decide whether to use the historical name or rename to current.
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

    # Expand-Archive doesn't auto-overwrite in PS 5.1; use raw API.
    [System.IO.Compression.ZipFile]::ExtractToDirectory(
        $zipPath.FullName,
        $gameAddons,
        $false  # don't overwrite by default
    ) 2>&1 | ForEach-Object {
        # ExtractToDirectory throws on conflict; catch shown below.
    }
    if ($?) {
        Ok "addon tree restored to $extractTarget"
    } else {
        Warn "Extract reported errors. If files already existed, delete the target folder"
        Warn "and re-run, or extract by hand with: Expand-Archive '$($zipPath.FullName)' '$gameAddons' -Force"
    }
}

# Optional auxiliary files - prompt before restoring since these are
# environment-specific (.mcp.json, your container's MCP config) or
# user-specific (CLAUDE.md, your Claude Code working-doc at sbox-public root).
foreach ($aux in @('.mcp.json', 'CLAUDE.md')) {
    $src = Join-Path $target.FullName $aux
    if (-not (Test-Path $src)) { continue }
    Write-Host ""
    $reply = Read-Host "Restore '$aux' from snapshot to sbox-public root? [y/N]"
    if ($reply -match '^[yY]') {
        Copy-Item $src (Join-Path $SboxRoot $aux) -Force
        Ok "$aux restored"
    }
}

Step "Done"
Write-Host "Next: relaunch sbox-dev. If the engine patches changed, also run Bootstrap.bat."
