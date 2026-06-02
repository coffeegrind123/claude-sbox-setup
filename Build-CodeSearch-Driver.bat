@echo off
REM Build + deploy the forum site-scrape Playwright driver (formerly the codesearch driver --
REM codesearch + release_notes are plain REST now; this driver only backs forum_*). Source lives HERE in claude-sbox-setup
REM (codesearch-driver\); output is deployed to the game's GLOBAL store
REM <game>\.claude-sbox\codesearch-driver\runtime\ -- NOT into the claude-sbox addon, so the
REM published addon stays source-only. Driven by the codesearch_install_driver MCP tool, or
REM run by hand. Requires the .NET SDK.
setlocal
set "HERE=%~dp0"
set "CSPROJ=%HERE%codesearch-driver\CodeSearchDriver.csproj"
REM HERE = <game>\addons\claude-sbox-setup\ ; the game root is two levels up.
for %%I in ("%HERE%..\..") do set "GAME_DIR=%%~fI"
set "OUT_DIR=%GAME_DIR%\.claude-sbox\codesearch-driver\runtime"

if not exist "%CSPROJ%" (
  echo ERROR: CodeSearchDriver.csproj not found at "%CSPROJ%"
  exit /b 1
)

echo ==^> publishing CodeSearchDriver -^> "%OUT_DIR%"
dotnet publish "%CSPROJ%" -c Release -o "%OUT_DIR%"
if errorlevel 1 exit /b 1

echo ==^> installing Chromium for Playwright
if exist "%OUT_DIR%\playwright.ps1" (
  pwsh "%OUT_DIR%\playwright.ps1" install chromium
) else (
  echo    ^(no playwright launcher found; driver self-installs Chromium on first use^)
)

echo ==^> done. Verify in-editor with codesearch_status ^(driver_dll_found:true^).
