@echo off
setlocal
rem Convenience shim — runs Uninstall-Cloud-Package.ps1 with execution policy
rem bypass so you don't have to fight PowerShell's signing complaints. All
rem flags are forwarded verbatim, so:
rem
rem     Uninstall-Cloud-Package.bat                remove cloud .cll + .xml
rem     Uninstall-Cloud-Package.bat -DryRun        report what would happen
rem     Uninstall-Cloud-Package.bat -CleanCache    also wipe game/.claude-sbox/cache/ (~900 MB)
rem     Uninstall-Cloud-Package.bat -Force         skip the missing-.sbproj abort
rem
rem CLOSE SBOX before running — the .cll is memory-mapped while the editor
rem is up and the delete fails with a sharing violation.
rem
rem `setlocal` + `exit /b %ERRORLEVEL%` propagate the inner script's exit
rem code (0 ok, 1 missing local addon, 2 sbox still running).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-Cloud-Package.ps1" %*
exit /b %ERRORLEVEL%
