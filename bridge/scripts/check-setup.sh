#!/usr/bin/env bash
# check-setup.sh: run inside the MCP-client container (or any host that has the bridge)
# to verify it can talk to the in-editor MCP host on the Windows host. Prints PASS/FAIL
# per check.
set -uo pipefail

HOST="${SBOX_MCP_HOST:-host.docker.internal:6790}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

ok=0; fail=0
pass() { green "PASS  $1"; ok=$((ok+1)); }
fail() { red "FAIL  $1"; fail=$((fail+1)); }

echo "Checking sbox-mcp-bridge connectivity"
echo "Target editor host: $HOST"
echo

# 1) Bridge package present
if [ -f "$(dirname "$0")/../dist/bridge.js" ]; then
  pass "dist/bridge.js exists"
elif [ -f "/opt/sbox-mcp-bridge/bridge.js" ]; then
  pass "/opt/sbox-mcp-bridge/bridge.js exists"
else
  fail "bridge.js not found (run 'npm run build' or copy to /opt/sbox-mcp-bridge/)"
fi

# 2) host.docker.internal resolves
if getent hosts "${HOST%%:*}" >/dev/null 2>&1; then
  pass "${HOST%%:*} resolves"
else
  fail "${HOST%%:*} does not resolve — add --add-host=host.docker.internal:host-gateway on Linux Docker"
fi

# 3) /ping reaches the editor
if pong=$(curl -fsS --max-time 5 "http://$HOST/ping" 2>/dev/null); then
  pass "GET /ping → $pong"
else
  fail "GET /ping failed: is the s&box editor running with the claude-sbox addon loaded?"
fi

# 4) /list_tools returns a sensible tool list
if tools=$(curl -fsS --max-time 5 -X POST -H 'content-type: application/json' -d '{}' "http://$HOST/list_tools" 2>/dev/null); then
  count=$(echo "$tools" | grep -o '"name"' | wc -l)
  pass "POST /list_tools → $count tools registered"
else
  fail "POST /list_tools failed"
fi

# 5) /schema_lookup_type sanity check
if probe=$(curl -fsS --max-time 10 -X POST -H 'content-type: application/json' \
    -d '{"fullname":"Sandbox.GameObject"}' \
    "http://$HOST/schema_lookup_type" 2>/dev/null); then
  if echo "$probe" | grep -q '"FullName"'; then
    pass "POST /schema_lookup_type Sandbox.GameObject → resolved"
  else
    yellow "WARN  /schema_lookup_type returned but no FullName field — schema may not be loaded yet"
  fi
fi

# 6) /docs_list to confirm llms.txt manifest loaded
if docs=$(curl -fsS --max-time 10 -X POST -H 'content-type: application/json' -d '{}' "http://$HOST/docs_list" 2>/dev/null); then
  count=$(echo "$docs" | grep -o '"path"' | wc -l)
  if [ "$count" -gt 50 ]; then
    pass "POST /docs_list → $count doc pages indexed"
  else
    yellow "WARN  /docs_list returned but only $count entries — manifest may be loading"
  fi
fi

# 7) Bridge loads without crashing
node -e "import('$(realpath "$(dirname "$0")/..")/dist/bridge.js').catch(e => { console.error(e.message); process.exit(1); })" </dev/null >/dev/null 2>/tmp/bridge-load.log &
sleep 1
kill %1 2>/dev/null
wait 2>/dev/null
if grep -q "fatal" /tmp/bridge-load.log 2>/dev/null; then
  fail "bridge.js threw on startup: $(cat /tmp/bridge-load.log)"
else
  pass "bridge.js loads cleanly"
fi

echo
echo "Summary: $ok passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
