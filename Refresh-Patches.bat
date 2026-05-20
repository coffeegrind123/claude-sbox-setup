@echo off
setlocal
rem Convenience shim — regenerate patches/*.patch from the current working tree
rem and verify each applies cleanly. Run this whenever you've edited an engine
rem file that's tracked in patches/. See Refresh-Patches.ps1 for full doc.
rem
rem `setlocal` + `exit /b %ERRORLEVEL%` propagate the inner PS exit code so a
rem self-test failure surfaces to CI / chained scripts.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Refresh-Patches.ps1" %*
exit /b %ERRORLEVEL%
