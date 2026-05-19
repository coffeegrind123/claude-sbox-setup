#requires -Version 5.1
<#
.SYNOPSIS
    Find and (with confirmation) stop processes that hold locks on the s&box
    managed-DLL output directory, so the next Bootstrap.bat can replace them.

.DESCRIPTION
    Bootstrap.bat compiles managed projects and writes their DLLs into
    <sbox-public>/game/bin/managed/. If sbox-dev.exe, dotnet's persistent build
    server, MSBuild, csc, VBCSCompiler, or an Explorer window keeps any of
    those DLLs open, the copy step fails with:

        MSB3021: Unable to copy ...Sandbox.Engine.dll... because it is being
        used by another process.

    This script lists every candidate holder it can detect, prints details
    (PID, start time, working set), and asks before killing anything.
    Re-running is safe; if nothing is running it just reports clean.

.PARAMETER Yes
    Skip the confirmation prompt and stop every detected candidate. Useful
    for CI / scripted re-bootstraps. Default behaviour is to ask.

.PARAMETER Dry
    Show what would be killed but don't touch anything.

.EXAMPLE
    .\Prepare-Bootstrap.ps1
    Interactive. Lists holders and prompts before killing.

.EXAMPLE
    .\Prepare-Bootstrap.ps1 -Yes
    Non-interactive. Stops everything matched without prompting.

.NOTES
    Does NOT use Sysinternals handle.exe; only checks well-known holder
    process names (sbox-dev, VBCSCompiler, MSBuild, csc, dotnet build-server).
    If a lock persists after running this, run handle64.exe -nobanner against
    the specific DLL path to find the unusual holder.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Dry
)

# Continue on native-command stderr so PowerShell doesn't terminate on noisy output.
$ErrorActionPreference = 'Continue'

$candidateNames = @(
    'sbox-dev',         # the editor itself
    'VBCSCompiler',     # Roslyn persistent compile server
    'MSBuild',          # MSBuild worker
    'csc'               # standalone C# compiler
)

Write-Host ""
Write-Host "==> Scanning for processes that hold the managed DLLs" -ForegroundColor Cyan

$found = @()
foreach ($name in $candidateNames) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        $found += [pscustomobject]@{
            Name      = $_.ProcessName
            Pid       = $_.Id
            Started   = $_.StartTime
            WSMB      = [math]::Round($_.WorkingSet64 / 1MB, 1)
            Path      = try { $_.MainModule.FileName } catch { '<inaccessible>' }
        }
    }
}

if ($found.Count -eq 0) {
    Write-Host "    No holders detected. Safe to run Bootstrap.bat now." -ForegroundColor Green
    Write-Host ""
    Write-Host "Note: 'dotnet build-server shutdown' is still worth a one-shot call if you"
    Write-Host "      previously hit MSB3021 errors and the holders have already vanished."
    Write-Host "      Run: dotnet build-server shutdown"
    exit 0
}

Write-Host ""
Write-Host "Detected candidate holders:" -ForegroundColor Yellow
$found | Format-Table -AutoSize Name, Pid, Started, WSMB, Path

if ($Dry) {
    Write-Host "==> Dry run; not killing anything." -ForegroundColor Cyan
    exit 0
}

$doKill = $Yes
if (-not $doKill) {
    Write-Host ""
    Write-Host "Stop these processes plus the dotnet build server?" -ForegroundColor Yellow
    Write-Host "Anything currently using sbox-dev, MSBuild, or the build server will be terminated."
    $reply = Read-Host "Type 'y' to stop, anything else to abort"
    $doKill = ($reply -match '^[yY]')
}

if (-not $doKill) {
    Write-Host "==> Aborted, nothing killed." -ForegroundColor Cyan
    exit 0
}

Write-Host ""
foreach ($p in $found) {
    Write-Host "    Stop-Process -Id $($p.Pid) ($($p.Name))..." -NoNewline
    try {
        Stop-Process -Id $p.Pid -Force -ErrorAction Stop
        Write-Host " stopped" -ForegroundColor Green
    } catch {
        Write-Host " FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "    dotnet build-server shutdown..." -NoNewline
$null = & dotnet build-server shutdown 2>&1
if ($LASTEXITCODE -eq 0) { Write-Host " ok" -ForegroundColor Green }
else { Write-Host " returned $LASTEXITCODE (likely no server was running)" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "==> Done. Re-run Bootstrap.bat from the sbox-public root now." -ForegroundColor Cyan
