@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Snapshot-Now.ps1" %*
exit /b %ERRORLEVEL%
