@echo off
REM Build + deploy the package decompiler driver (ICSharpCode.Decompiler) used to recover C#
REM source from precompiled sbox.game packages (post-#5038 packages ship .bin/package.*.dll, not
REM .cll source archives). Source lives HERE in claude-sbox-setup (decompiler-driver\); output is
REM deployed to the game's GLOBAL store <game>\.claude-sbox\decompiler-driver\runtime\ -- NOT into
REM the claude-sbox addon, so the published addon stays source-only. Driven by the
REM decompiler_install MCP tool, or run by hand. Requires the .NET SDK.
setlocal
set "HERE=%~dp0"
set "CSPROJ=%HERE%decompiler-driver\ClaudeSbox.Decompiler.Driver.csproj"
REM HERE = <game>\addons\claude-sbox-setup\ ; the game root is two levels up.
for %%I in ("%HERE%..\..") do set "GAME_DIR=%%~fI"
set "OUT_DIR=%GAME_DIR%\.claude-sbox\decompiler-driver\runtime"

if not exist "%CSPROJ%" (
  echo ERROR: ClaudeSbox.Decompiler.Driver.csproj not found at "%CSPROJ%"
  exit /b 1
)

echo ==^> publishing ClaudeSbox.Decompiler.Driver -^> "%OUT_DIR%"
dotnet publish "%CSPROJ%" -c Release -o "%OUT_DIR%"
if errorlevel 1 exit /b 1

echo ==^> done. Verify in-editor with decompiler_install ^(driver_dll_found:true^), then
echo     package_download a compiled package to recover C# source.
