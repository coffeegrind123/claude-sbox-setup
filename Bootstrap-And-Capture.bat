@echo off
rem ==========================================================================
rem Bootstrap-And-Capture.bat
rem
rem End-to-end bootstrap helper for the sbox-public root Bootstrap.bat:
rem
rem   [1/4] Prepare    -- Prepare-Bootstrap.ps1 stops processes holding the
rem                       engine/managed DLLs open (sbox-dev, VBCSCompiler,
rem                       MSBuild, csc) and shuts down the dotnet build server.
rem   [2/4] Bootstrap  -- run <sbox-root>\Bootstrap.bat with full output
rem                       captured to bootstrap-out.log.
rem   [3/4] Extract    -- post-process the log to pull every path reported as
rem                       "being used by another process" into locked-files.txt.
rem   [4/4] Cleanup    -- if any locked files were captured, prompt to delete
rem                       them. With -DeleteLocked, deletes without asking.
rem
rem Flags (any order):
rem   -Yes            Skip Prepare-Bootstrap's "stop these processes?" prompt.
rem   -DeleteLocked   After capture, delete every path in locked-files.txt
rem                   without prompting. Implies -Yes for the prepare stage.
rem   -NoPrepare      Skip [1/4] entirely; original cold-bootstrap behaviour.
rem   --help, /?, -h  Print this usage block and exit 0.
rem
rem Self-locating: lives at <sbox-public-root>\game\addons\claude-sbox-setup\.
rem Walks up three directories to find Bootstrap.bat at the sbox-public root.
rem ==========================================================================
setlocal enabledelayedexpansion

set ARG_YES=0
set ARG_DELLOCK=0
set ARG_NOPREP=0

:argloop
if "%~1"=="" goto argdone
if /i "%~1"=="-Yes"           set ARG_YES=1
if /i "%~1"=="-DeleteLocked"  set ARG_DELLOCK=1
if /i "%~1"=="-NoPrepare"     set ARG_NOPREP=1
if /i "%~1"=="--help"         goto showhelp
if /i "%~1"=="/?"             goto showhelp
if /i "%~1"=="-h"             goto showhelp
shift
goto argloop
:argdone

rem -DeleteLocked implies -Yes: if you're auto-deleting locked files you
rem definitely also want prepare to auto-kill holders.
if "%ARG_DELLOCK%"=="1" set ARG_YES=1

set ADDON_DIR=%~dp0
rem Strip trailing backslash
if "%ADDON_DIR:~-1%"=="\" set ADDON_DIR=%ADDON_DIR:~0,-1%
for %%I in ("%ADDON_DIR%\..\..\..") do set SBOX_ROOT=%%~fI

if not exist "%SBOX_ROOT%\Bootstrap.bat" (
    echo [ERROR] Bootstrap.bat not found at %SBOX_ROOT%.
    echo         This script must live at ^<sbox-public-root^>^\game^\addons^\claude-sbox-setup^\.
    exit /b 1
)
if not exist "%ADDON_DIR%\Prepare-Bootstrap.ps1" (
    echo [ERROR] Prepare-Bootstrap.ps1 not found next to this script.
    echo         Expected at %ADDON_DIR%\Prepare-Bootstrap.ps1.
    exit /b 1
)

rem ----- [1/4] Prepare ------------------------------------------------------
if "%ARG_NOPREP%"=="1" (
    echo.
    echo === [1/4] Prepare-Bootstrap SKIPPED ^(-NoPrepare^)
) else (
    echo.
    if "%ARG_YES%"=="1" (
        echo === [1/4] Stopping holders ^(Prepare-Bootstrap.ps1 -Yes^)
    ) else (
        echo === [1/4] Stopping holders ^(Prepare-Bootstrap.ps1, interactive^)
    )
    if "%ARG_YES%"=="1" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ADDON_DIR%\Prepare-Bootstrap.ps1" -Yes
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ADDON_DIR%\Prepare-Bootstrap.ps1"
    )
    set PREP_EXIT=!ERRORLEVEL!
    if not "!PREP_EXIT!"=="0" (
        echo [ERROR] Prepare-Bootstrap.ps1 exited with !PREP_EXIT!. Aborting.
        exit /b !PREP_EXIT!
    )
)

rem ----- [2/4] Bootstrap ----------------------------------------------------
pushd "%SBOX_ROOT%"

echo.
echo === [2/4] Running Bootstrap.bat ^(full output -^> bootstrap-out.log^)
echo === sbox-public root: %SBOX_ROOT%
echo === This takes ~2 minutes and may print artifact-download errors. That's expected.
echo.
call Bootstrap.bat > "%ADDON_DIR%\bootstrap-out.log" 2>&1
set BOOT_EXIT=%ERRORLEVEL%

rem ----- [3/4] Extract ------------------------------------------------------
echo.
echo === [3/4] Extracting locked file paths -^> locked-files.txt
echo.

rem Inline PowerShell does the regex extraction. PS single-quoted strings let
rem us embed single quotes via doubling ('') without cmd escape issues; the
rem outer cmd "..." protects the pipes from being interpreted by cmd.
rem
rem Two-stage: capture matches to a variable, then write the file
rem unconditionally via Set-Content -- including with zero matches. Tee-Object
rem only writes when the pipeline has input, so the previous fix used to
rem leave a stale locked-files.txt from an earlier run when the current
rem bootstrap succeeded cleanly. That led to "delete 22 files" prompts on
rem runs that should have reported 0 locked files, deleting freshly-restored
rem native DLLs and re-breaking the install.
rem -EA Stop turns any silent PS error (missing log file, regex glitch, etc.)
rem into a non-zero exit so the cmd shell sees a real failure instead of
rem proceeding with a stale locked-files.txt from a previous run.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $paths = Select-String -Path '%ADDON_DIR%\bootstrap-out.log' -Pattern 'being used by another process' | ForEach-Object { if ($_.Line -match '''([^'']+\.(?:dll|exe))''') { $Matches[1] } } | Sort-Object -Unique; if ($paths) { $paths | ForEach-Object { Write-Host $_ } }; Set-Content -Path '%ADDON_DIR%\locked-files.txt' -Value $paths -Encoding UTF8"
if errorlevel 1 (
    echo [WARN] Could not extract locked files from bootstrap-out.log
    echo [WARN]   ^(Bootstrap.bat may have failed before producing the log.^)
    echo [WARN]   Continuing with an empty locked-files.txt.
    rem Ensure the file exists + is empty so the count step downstream gets 0.
    type nul > "%ADDON_DIR%\locked-files.txt"
)

popd

rem ----- [4/4] Cleanup ------------------------------------------------------
rem Count entries in locked-files.txt. Get-Content auto-detects the UTF-16
rem BOM that Tee-Object wrote, so the count is correct regardless of encoding.
set LOCKED_COUNT=0
set DELETED_FILES=0
for /f "usebackq" %%C in (`powershell -NoProfile -Command "(Get-Content '%ADDON_DIR%\locked-files.txt' -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count"`) do set LOCKED_COUNT=%%C

echo.
if "%LOCKED_COUNT%"=="0" (
    echo === [4/4] No locked files captured. Nothing to clean up.
) else (
    if "%ARG_DELLOCK%"=="1" (
        echo === [4/4] Deleting %LOCKED_COUNT% locked file^(s^) ^(-DeleteLocked^)
        call :doDelete
        set DELETED_FILES=1
    ) else (
        echo === [4/4] %LOCKED_COUNT% locked file^(s^) captured.
        echo.
        set /p REPLY=Delete them now? [y/N]
        if /i "!REPLY!"=="y" (
            call :doDelete
            set DELETED_FILES=1
        ) else (
            echo Skipped. You can delete later with:
            echo.
            echo     powershell -NoProfile -Command "Get-Content '%ADDON_DIR%\locked-files.txt' ^| ForEach-Object { Remove-Item $_ -Force -EA Continue; 'deleted ' + $_ }"
        )
    )
)

echo.
echo --------------------------------------------------------------------------
echo Bootstrap exit code:  %BOOT_EXIT%
echo Full log:             %ADDON_DIR%\bootstrap-out.log
echo Locked-file list:     %ADDON_DIR%\locked-files.txt
echo --------------------------------------------------------------------------
echo.

rem When we just deleted native DLLs, the install is missing critical engine
rem binaries (tier0, engine2, Qt5Core, etc.) and the editor will not launch
rem until a second bootstrap restores them. Tell the user explicitly --
rem otherwise they hit a confusing "sbox-dev.exe failed to start" later.
if "!DELETED_FILES!"=="1" (
    echo **************************************************************************
    echo *                                                                        *
    echo *  ACTION REQUIRED -- Bootstrap must be re-run.                          *
    echo *                                                                        *
    echo *  You just deleted !LOCKED_COUNT! locked file^(s^) from game\bin\win64.    *
    echo *  The editor cannot launch until those native DLLs are restored.        *
    echo *                                                                        *
    echo *  Re-run this script ^(or the unattended form^):                          *
    echo *                                                                        *
    echo *      .\Bootstrap-And-Capture.bat                                       *
    echo *      .\Bootstrap-And-Capture.bat -Yes -DeleteLocked   ^(unattended^)     *
    echo *                                                                        *
    echo *  The freshly-deleted paths are not held by anything, so the next run   *
    echo *  should report "0 locked file^(s^) captured".                           *
    echo *                                                                        *
    echo **************************************************************************
    echo.
)

endlocal & exit /b %BOOT_EXIT%

rem ==========================================================================
:doDelete
rem Runs in the same setlocal scope. PS handles the UTF-16 read transparently;
rem Test-Path guards against entries that vanished between capture and now;
rem -ErrorAction Continue keeps the loop going if one file is still locked.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$n=0; Get-Content '%ADDON_DIR%\locked-files.txt' | ForEach-Object { $p = $_.Trim(); if ($p -and (Test-Path -LiteralPath $p)) { try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; Write-Host ('deleted ' + $p); $n++ } catch { Write-Host ('FAILED  ' + $p + ' :: ' + $_.Exception.Message) -ForegroundColor Red } } }; Write-Host ('--- ' + $n + ' file(s) deleted')"
goto :eof

rem ==========================================================================
:showhelp
echo Bootstrap-And-Capture.bat -- run sbox-public Bootstrap with prepare + capture.
echo.
echo Usage:  Bootstrap-And-Capture.bat [-Yes] [-DeleteLocked] [-NoPrepare]
echo.
echo   -Yes            Auto-confirm Prepare-Bootstrap.ps1's stop-processes prompt.
echo   -DeleteLocked   After capture, delete every locked-files.txt entry
echo                   without prompting. Implies -Yes.
echo   -NoPrepare      Skip the prepare stage; same as the pre-enhancement
echo                   cold-bootstrap behaviour.
echo   --help, /?, -h  Show this help.
echo.
echo Typical interactive run:
echo     Bootstrap-And-Capture.bat
echo.
echo Typical unattended / CI run:
echo     Bootstrap-And-Capture.bat -Yes -DeleteLocked
echo.
endlocal & exit /b 0
