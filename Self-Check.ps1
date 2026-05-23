#requires -Version 5.1
<#
.SYNOPSIS
    Run the ClaudeSbox spec-corpus self-check (parity + schema validation).
    A fast, editor-less integrity check of the spec yamls + churn manifest.

.DESCRIPTION
    Wraps `dotnet test --filter "TestCategory=SelfCheck"` against the
    ClaudeSbox.Tests assembly. Bypasses the editor — runs in plain
    `dotnet test`, so it's CI-friendly and doesn't need sbox to be open.

    SelfCheck verifies four invariants:
      1. EverySpec_LoadsCleanly — no malformed yaml under specs/.
      2. EveryRegisteredTool_HasASpec — Dispatcher.RegisteredNames ⊆ specs (no
         orphan registrations).
      3. EverySpec_RefersToARegisteredTool — specs ⊆ Dispatcher (no orphan yamls).
      4. EverySampleArgs_ValidatesAgainstInputSchema — each spec's sample_args
         supplies every required field its tool's inputSchema declares.

    Note: tests 2 and 3 require the running addon's Dispatcher to have its
    handlers registered. Standalone dotnet test loads ClaudeSbox.Tests.dll
    which compiles the addon's .cs files in alongside the tests via
    `<Compile Include="../Code/**/*.cs" />`, so [InitializeOnLoad] handlers
    DO fire during test discovery and Dispatcher.RegisteredNames is populated.
    No editor needed.

    For the full Tier-1 spec run (~142 specs) use the in-editor `run_tests`
    MCP tool — that needs the editor and a live scene.

.PARAMETER Build
    Force a `dotnet build` first. Default behavior is to let `dotnet test`
    handle the incremental rebuild itself.

.EXAMPLE
    .\Self-Check.ps1
    Run the self-check suite, print pass/fail summary.

.EXAMPLE
    .\Self-Check.ps1 -Build
    Force a clean build before running.
#>
[CmdletBinding()]
param(
    [switch]$Build
)

$ErrorActionPreference = 'Stop'

$SetupDir = Split-Path -Parent $PSCommandPath
$SboxRoot = (Resolve-Path (Join-Path $SetupDir '..\..\..')).Path
$TestsCsproj = Join-Path $SboxRoot 'game\addons\claude-sbox\Tests\ClaudeSbox.Tests.csproj'

if (-not (Test-Path $TestsCsproj)) {
    Write-Host "ABORT: ClaudeSbox.Tests.csproj not found at $TestsCsproj" -ForegroundColor Red
    Write-Host "       The claude-sbox source addon needs to be at game/addons/claude-sbox/." -ForegroundColor Red
    exit 1
}

if ($Build) {
    Write-Host "Building ClaudeSbox.Tests..." -ForegroundColor Cyan
    & dotnet build $TestsCsproj -nologo -v minimal
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ABORT: build failed (exit $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

Write-Host "Running self-check..." -ForegroundColor Cyan
& dotnet test $TestsCsproj `
    --filter "TestCategory=SelfCheck" `
    --logger "console;verbosity=normal" `
    --nologo

exit $LASTEXITCODE
