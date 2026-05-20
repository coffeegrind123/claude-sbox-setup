@echo off
setlocal
rem Self-locating wrapper. Forwards all args to Setup.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" %*
exit /b %ERRORLEVEL%
