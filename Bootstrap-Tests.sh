#!/usr/bin/env bash
# ============================================================================
# Bootstrap-Tests.sh — Linux equivalent of Bootstrap-Tests.bat
#
# Build the ClaudeSbox.Tests assembly, generate starter spec yamls for every
# registered tool, and run churn assertions. Linux-native — no PowerShell.
#
# Usage:
#   ./Bootstrap-Tests.sh             all stages (build → generate → churn)
#   ./Bootstrap-Tests.sh --build     just build
#   ./Bootstrap-Tests.sh --generate  just run the spec generator
#   ./Bootstrap-Tests.sh --churn     just run churn assertions
# ============================================================================

set -uo pipefail

STAGE="all"
for arg in "$@"; do
    case "$arg" in
        --build|build)       STAGE="build" ;;
        --generate|generate) STAGE="generate" ;;
        --churn|churn)       STAGE="churn" ;;
        --all|all)           STAGE="all" ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBOX_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TESTS_CSPROJ="$SBOX_ROOT/game/addons/claude-sbox/Tests/ClaudeSbox.Tests.csproj"

C_RESET=$'\e[0m'; C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_RED=$'\e[31m'
[ -t 1 ] || { C_RESET=""; C_CYAN=""; C_GREEN=""; C_RED=""; }

if [ ! -f "$TESTS_CSPROJ" ]; then
    echo "${C_RED}[XX]${C_RESET} ClaudeSbox.Tests.csproj not found at $TESTS_CSPROJ" >&2
    echo "${C_RED}[XX]${C_RESET} The addon must be cloned at game/addons/claude-sbox/" >&2
    exit 1
fi

if ! command -v dotnet >/dev/null 2>&1; then
    echo "${C_RED}[XX]${C_RESET} dotnet CLI not found. Install the .NET 10 SDK." >&2
    exit 1
fi

cd "$(dirname "$TESTS_CSPROJ")" || exit 1

if [ "$STAGE" = "all" ] || [ "$STAGE" = "build" ]; then
    echo "${C_CYAN}=== [1/3] Building ClaudeSbox.Tests ===${C_RESET}"
    dotnet build "$TESTS_CSPROJ" || exit 1
fi
if [ "$STAGE" = "build" ]; then exit 0; fi

if [ "$STAGE" = "all" ] || [ "$STAGE" = "generate" ]; then
    echo
    echo "${C_CYAN}=== [2/3] Generating starter spec yamls ===${C_RESET}"
    dotnet test "$TESTS_CSPROJ" --filter "FullyQualifiedName~GenerateSpecs" --no-build || exit 1
fi
if [ "$STAGE" = "generate" ]; then exit 0; fi

if [ "$STAGE" = "all" ] || [ "$STAGE" = "churn" ]; then
    echo
    echo "${C_CYAN}=== [3/3] Running churn assertions ===${C_RESET}"
    dotnet test "$TESTS_CSPROJ" --filter "Category=Churn" --no-build || exit 1
fi

echo
echo "${C_CYAN}=== Done ===${C_RESET}"
echo "Specs: $SBOX_ROOT/game/addons/claude-sbox/Tests/specs/"
echo "Next:  hand-tune any TODO_* placeholders, then run the full test suite:"
echo "       dotnet test $TESTS_CSPROJ"
