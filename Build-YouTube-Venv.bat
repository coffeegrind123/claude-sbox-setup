@echo off
setlocal enabledelayedexpansion
rem Provision the youtube runtime (Python venv: yapsnap + yt-dlp + imageio-ffmpeg)
rem into the game's global store <game>\.claude-sbox\youtube\venv. Source stays in
rem claude-sbox-setup; the addon stays source-only. Driven by youtube_install, or
rem run by hand. Requires Python 3 on PATH. Usage: Build-YouTube-Venv.bat [force]

set "HERE=%~dp0"
rem HERE ends with a backslash and = <game>\addons\claude-sbox-setup\ ; game root is two up.
pushd "%HERE%..\.." || (echo ERROR: cannot locate game root & exit /b 1)
set "GAME_DIR=%CD%"
popd
set "VENV=%GAME_DIR%\.claude-sbox\youtube\venv"
set "SCRIPT=%HERE%youtube\youtube_watch.py"
set "REPAIR=%HERE%youtube\repair_yapsnap.py"

if not exist "%SCRIPT%" (
  echo ERROR: youtube.py not found at "%SCRIPT%" - pull the claude-sbox-setup repo.
  exit /b 1
)

rem Locate a Python launcher: prefer the 'py' launcher, then python.
set "PY="
where py >nul 2>&1 && set "PY=py -3"
if not defined PY ( where python >nul 2>&1 && set "PY=python" )
if not defined PY (
  echo ERROR: Python 3 not found on PATH ^(tried 'py -3', 'python'^). Install Python 3.
  exit /b 3
)

if /I "%~1"=="force"  rmdir /s /q "%VENV%" 2>nul
if /I "%~1"=="1"      rmdir /s /q "%VENV%" 2>nul
if /I "%~1"=="true"   rmdir /s /q "%VENV%" 2>nul

echo ==^> creating venv -^> "%VENV%"
%PY% -m venv "%VENV%" || (echo ERROR: venv creation failed & exit /b 4)
set "VPY=%VENV%\Scripts\python.exe"

"%VPY%" -m pip install --upgrade pip || (echo ERROR: pip upgrade failed & exit /b 5)
echo ==^> installing yapsnap + yt-dlp + imageio-ffmpeg
"%VPY%" -m pip install yapsnap yt-dlp imageio-ffmpeg || (echo ERROR: pip install failed & exit /b 6)

if exist "%REPAIR%" "%VPY%" "%REPAIR%"

echo ==^> done. Verify in-editor with youtube_status ^(venv_ready:true^).
exit /b 0
