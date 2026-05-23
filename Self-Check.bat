@echo off
setlocal
rem Convenience shim — runs Self-Check.ps1 with execution policy bypass so you
rem don't have to fight PowerShell's signing complaints. All flags are
rem forwarded verbatim, so:
rem
rem     Self-Check.bat            run the self-check suite
rem     Self-Check.bat -Build     force a dotnet build first
rem
rem SelfCheck validates the spec corpus + churn manifest against the live
rem Dispatcher.RegisteredNames. Doesn't need sbox-dev to be open — the
rem addon's [InitializeOnLoad] handlers fire during MSTest discovery.
rem
rem For the full Tier-1 spec run use `run_tests` from inside the editor —
rem that needs a live scene + asset system.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Self-Check.ps1" %*
exit /b %ERRORLEVEL%
