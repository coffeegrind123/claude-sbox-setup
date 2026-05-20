@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-From-Backup.ps1" %*
exit /b %ERRORLEVEL%
