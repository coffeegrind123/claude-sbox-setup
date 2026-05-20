@echo off
setlocal
rem Convenience shim — runs Safe-Pull.ps1 with execution policy bypass so
rem you don't have to fight PowerShell's signing complaints. All flags are
rem forwarded verbatim, so:
rem
rem     Safe-Pull.bat                run normally (snapshot, stash, pull, pop, verify)
rem     Safe-Pull.bat -DryRun        report what would happen, don't pull
rem     Safe-Pull.bat -Force         skip pre-pull patch-presence check
rem     Safe-Pull.bat -NoBackup      skip the timestamped snapshot
rem
rem Run from this directory (game\addons\claude-sbox-setup\). The script
rem self-locates via %~dp0 so double-clicking from Explorer also works,
rem though you won't see output unless you run it from a console.
rem
rem `setlocal` + the `exit /b %ERRORLEVEL%` at the end propagate the inner
rem PowerShell script's exit code back to the caller. Without these, a CI
rem job invoking Safe-Pull.bat would see 0 even on patch-apply failures.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Safe-Pull.ps1" %*
exit /b %ERRORLEVEL%
