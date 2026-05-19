@echo off
rem Convenience shim — regenerate patches/*.patch from the current working tree
rem and verify each applies cleanly. Run this whenever you've edited an engine
rem file that's tracked in patches/. See Refresh-Patches.ps1 for full doc.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Refresh-Patches.ps1" %*
