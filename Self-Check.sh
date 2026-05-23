#!/usr/bin/env bash
# ============================================================================
# Self-Check.sh — Linux equivalent of Self-Check.ps1
#
# Run the ClaudeSbox spec-corpus self-check (parity + schema validation).
# Wraps `dotnet test --filter "TestCategory=SelfCheck"`. Bypasses the editor
# — runs in plain dotnet test, so it's CI-friendly and doesn't need sbox
# to be open.
#
# SelfCheck verifies four invariants:
#   1. EverySpec_LoadsCleanly — no malformed yaml under specs/.
#   2. EveryRegisteredTool_HasASpec — Dispatcher ⊆ specs (no orphan registrations).
#   3. EverySpec_RefersToARegisteredTool — specs ⊆ Dispatcher (no orphan yamls).
#   4. EverySampleArgs_ValidatesAgainstInputSchema — each spec's sample_args
#      supplies every required field its tool's inputSchema declares.
#
# The addon's [InitializeOnLoad] handlers fire during MSTest discovery
# (ClaudeSbox.Tests.dll compiles the addon's .cs files in alongside the
# tests via `<Compile Include="../Code/**/*.cs" />`), so Dispatcher.
# RegisteredNames is populated even without a running editor.
#
# Usage:
#   ./Self-Check.sh              run the suite
#   ./Self-Check.sh --build      force a dotnet build first
#
# Exit code is dotnet test's: 0 = all pass, 1 = at least one failure.
# ============================================================================

set -uo pipefail

BUILD=0
for arg in "$@"; do
    case "$arg" in
        --build|-Build) BUILD=1 ;;
        -h|--help)
            sed -n '2,26p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 64
            ;;
    esac
done

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBOX_ROOT="$(cd "$SETUP_DIR/../../.." && pwd)"
TESTS_CSPROJ="$SBOX_ROOT/game/addons/claude-sbox/Tests/ClaudeSbox.Tests.csproj"

if [[ ! -f "$TESTS_CSPROJ" ]]; then
    echo "ABORT: ClaudeSbox.Tests.csproj not found at $TESTS_CSPROJ" >&2
    echo "       The claude-sbox source addon needs to be at game/addons/claude-sbox/." >&2
    exit 1
fi

if [[ $BUILD -eq 1 ]]; then
    echo "Building ClaudeSbox.Tests..."
    dotnet build "$TESTS_CSPROJ" -nologo -v minimal || exit $?
fi

echo "Running self-check..."
dotnet test "$TESTS_CSPROJ" \
    --filter "TestCategory=SelfCheck" \
    --logger "console;verbosity=normal" \
    --nologo
