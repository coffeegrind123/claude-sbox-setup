@echo off
setlocal

rem === Set .sbproj file-association default to THIS checkout's sbox-dev.exe ===
rem
rem Why: Windows stores file associations in the registry. If sbox-dev.exe was
rem ever registered from a different drive/path (e.g., a D: install you've since
rem deleted), double-clicking .sbproj files keeps trying to launch the dead path
rem and pops the "How do you want to open this file?" dialog.
rem
rem This bat rewrites the association to the sbox-dev.exe sitting at the
rem appropriate location relative to this script.
rem
rem Self-locating: the bat lives at <sbox>/game/addons/claude-sbox-setup/,
rem two parents up = <sbox>/game/. Works regardless of drive letter.
rem
rem Per-user (HKCU) registration only — no admin needed. HKCU wins over HKLM
rem via the HKCR merge order, so this overrides any system-wide stale registration.

pushd "%~dp0..\.."
set "EXE=%CD%\sbox-dev.exe"
popd

if not exist "%EXE%" (
	echo ERROR: sbox-dev.exe not found at "%EXE%"
	echo.
	echo Either the engine hasn't been built (run Bootstrap.bat in the sbox-public root)
	echo or this script has been moved out of game\addons\claude-sbox-setup\.
	exit /b 1
)

echo Registering .sbproj default to: %EXE%
echo.

rem 1. Map .sbproj extension to the Sandbox.ProjectFile ProgID.
reg add "HKCU\Software\Classes\.sbproj" /ve /d "Sandbox.ProjectFile" /f >nul

rem 2. Map the ProgID to the actual launch command.
reg add "HKCU\Software\Classes\Sandbox.ProjectFile\shell\open\command" /ve /d "\"%EXE%\" -project \"%%1\"" /f >nul

rem 3. Wipe any "Always use this app" UserChoice override the user may have set
rem    via the file-open dialog. UserChoice trumps class registration; clearing
rem    it lets steps 1 and 2 take effect. Silently ignore if it doesn't exist.
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.sbproj\UserChoice" /f >nul 2>&1

echo Done. Current registration:
reg query "HKCU\Software\Classes\Sandbox.ProjectFile\shell\open\command" /ve

echo.
echo Test: double-click any .sbproj file. It should launch the sbox-dev.exe above
echo (the C: copy if you're consolidated to C:, etc.) instead of any stale path.

endlocal
