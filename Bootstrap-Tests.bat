@echo off
setlocal

rem Bootstrap the ClaudeSbox addon's MSTest harness:
rem   1. Build the test assembly.
rem   2. Generate one starter spec yaml per registered MCP tool (idempotent --
rem      the SpecGenerator skips files that already exist, so hand-tuned specs
rem      are preserved on re-run).
rem   3. Run the churn assertions so a missing reflection site fails loudly
rem      with a file:line + blast-radius diagnostic before any spec test runs.
rem
rem Flags:
rem   (none)        run all three stages (build -> generate -> churn)
rem   --build       just build
rem   --generate    just run the spec generator (build must have run already)
rem   --churn       just run churn assertions
rem   --all         explicit form of the default
rem
rem Prereq: sbox must have built the ClaudeSbox addon at least once
rem (game\.vs\output\ClaudeSbox.dll exists -- whatever drive your checkout is on).
rem If you've never run the editor on this checkout, open it once and let the
rem addon compile. The csproj uses $(SboxGame) = MSBuildProjectDirectory/../../..
rem so it resolves regardless of the drive letter.
rem
rem Self-locating: cd into the script's own directory so it runs identically
rem from any cwd, including when invoked by the bootstrap_tests MCP tool.
rem
rem Layout: this script lives in claude-sbox-setup/ next to the addon. Tests/
rem live in the addon proper, one directory over.

cd /d "%~dp0"

set STAGE=all
:argloop
if "%~1"=="" goto argdone
if /i "%~1"=="--build"    set STAGE=build
if /i "%~1"=="-Build"     set STAGE=build
if /i "%~1"=="build"      set STAGE=build
if /i "%~1"=="--generate" set STAGE=generate
if /i "%~1"=="-Generate"  set STAGE=generate
if /i "%~1"=="generate"   set STAGE=generate
if /i "%~1"=="--churn"    set STAGE=churn
if /i "%~1"=="-Churn"     set STAGE=churn
if /i "%~1"=="churn"      set STAGE=churn
if /i "%~1"=="--all"      set STAGE=all
if /i "%~1"=="-All"       set STAGE=all
if /i "%~1"=="all"        set STAGE=all
shift
goto argloop
:argdone

set TESTS_PROJ=..\claude-sbox\Tests\ClaudeSbox.Tests.csproj

if not exist "%TESTS_PROJ%" (
	echo This script needs the claude-sbox addon source at ..\claude-sbox\.
	echo The sbox.game install gives you the compiled package, not the test sources.
	echo If you're a contributor with access to the source, place it at
	echo   game\addons\claude-sbox\
	echo alongside this setup repo. Otherwise this script is not for you.
	exit /b 1
)

if "%STAGE%"=="all" goto do_build
if "%STAGE%"=="build" goto do_build
if "%STAGE%"=="generate" goto do_generate
if "%STAGE%"=="churn" goto do_churn

:do_build
echo.
echo === [1/3] Building ClaudeSbox.Tests ===
dotnet build %TESTS_PROJ% -nologo -v minimal
if errorlevel 1 (
	echo.
	echo Build failed. Common cause: the ClaudeSbox addon's compiled DLL is missing.
	echo Open the editor once so the addon compiles, then re-run this script.
	exit /b 1
)
if "%STAGE%"=="build" goto done

:do_generate
echo.
echo === [2/3] Generating starter spec yamls ===
dotnet test %TESTS_PROJ% --no-build --filter "TestCategory=Generator" --logger "console;verbosity=normal" -nologo
if errorlevel 1 (
	echo.
	echo Spec generation failed. Inspect the test output above.
	exit /b 1
)
if "%STAGE%"=="generate" goto done

:do_churn
echo.
echo === [3/3] Running churn assertions ===
dotnet test %TESTS_PROJ% --no-build --filter "FullyQualifiedName~A_ChurnAssertions" --logger "console;verbosity=normal" -nologo
if errorlevel 1 (
	echo.
	echo Churn assertions failed -- at least one engine reflection site has moved.
	echo The first failing assertion's message names the type/member and which MCP tools depend on it.
	rem Parens inside an if-block confuse CMD's parser even when the block is skipped at
	rem runtime -- the literal `(or` here was triggering ". was unexpected at this time."
	rem after stage 3 succeeded. Escape with ^^( / ^^) so the chars are emitted literally.
	echo Update the handler code ^(or churn-manifest.yaml if the API moved deliberately^).
	exit /b 1
)

:done
echo.
echo === Done ===
echo Specs: ..\claude-sbox\Tests\specs\
echo Next:  hand-tune any TODO_* placeholders, then 'dotnet test %TESTS_PROJ%' for the full run.
endlocal
