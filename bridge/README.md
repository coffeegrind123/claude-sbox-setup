# sbox-mcp-bridge

stdio-MCP to HTTP bridge for the s&box editor's in-process MCP server. Lets MCP clients that only speak stdio (Claude Code's stdio transport, Claude Desktop, etc.) talk to the editor's HTTP-only MCP host on `http://127.0.0.1:6790`.

The bridge ships in the [claude-sbox-setup](https://github.com/coffeegrind123/claude-sbox-setup) repo. The claude-sbox addon itself is published at [sbox.game/ghage/claude-sbox](https://sbox.game/ghage/claude-sbox). If you're using the addon's HTTP transport directly (`claude mcp add --transport http -s user sbox http://127.0.0.1:6790/mcp`), you don't need this bridge at all.

## Architecture

```
MCP client  ──stdio MCP──►  sbox-mcp-bridge (this package)
                                    │
                                    ▼ HTTP
                            127.0.0.1:6790
                                    │
                                    ▼
                            s&box editor host (Windows)
                            -> SboxMcpHost (HttpListener)
                            -> editor introspection / control
```

Tools are NOT hardcoded. They're discovered at startup via the editor's `/list_tools` endpoint, so any new tool the editor's MCP host registers (including auto-generated wrappers from `[Editor.MenuItem]` etc.) becomes available without bridge changes.

Two meta-tools (`sbox_status`, `sbox_reconnect`) are always available regardless of editor connection state, so the agent can diagnose missing editor tools without reading stderr.

## Install

The bridge ships pre-built at `dist/bridge.js` (Node 20+, single self-contained file, no `node_modules` needed at runtime). Register it with Claude Code:

```sh
# Linux / Mac / WSL (run from the setup repo root: game/addons/claude-sbox-setup)
claude mcp add --transport stdio -s user sbox node "$(pwd)/bridge/dist/bridge.js"

# Windows PowerShell
claude mcp add --transport stdio -s user sbox node "$PWD\bridge\dist\bridge.js"
```

Other MCP clients (Claude Desktop, Cline, etc.) typically take a similar config: command `node`, arg pointing at `bridge/dist/bridge.js`.

## Configure (Docker-style)

Inside a container with a bind mount of the s&box checkout, place a `.mcp.json` at the project root:

```json
{
  "mcpServers": {
    "sbox": {
      "command": "node",
      "args": ["/workspace/game/addons/claude-sbox-setup/bridge/dist/bridge.js"],
      "env": {
        "SBOX_MCP_HOST": "host.docker.internal:6790"
      }
    }
  }
}
```

Adjust the `/workspace/...` path to your bind mount.

Targeting the editor's MCP host (priority order):

1. `SBOX_MCP_URL`: full base URL with scheme (e.g. `https://my-host:8443`, `http://10.0.0.5:6790`). Use this when the editor runs over HTTPS, on a non-default path, or anywhere the bare `host:port` form can't express.
2. `SBOX_MCP_HOST`: `host:port` (or just `host`, port defaults to 6790). Always assumed `http://`. Backwards compatible.
3. Default: `host.docker.internal:6790`.

`SBOX_MCP_TIMEOUT_MS` defaults to `15000` for normal calls. Known-slow tools (`bootstrap_tests`, `compile_project`, `wait_for_*`, `asset_*`, etc.) carry per-tool overrides up to 10 minutes. Any single call can override with an extra `_timeout_ms: <ms>` arg, which the bridge strips before forwarding.

## Tool-list change notifications

The bridge declares the MCP `tools.listChanged` capability and emits `notifications/tools/list_changed` whenever the editor's tool count changes, in two situations:

1. **After a successful `sbox_reconnect`**: the agent calls `sbox_reconnect`, the bridge re-probes the editor, fetches `/list_tools` cache-bypassed, and if any tools came back fires the notification synchronously. The MCP client (Claude Code, Claude Desktop, etc.) re-fetches the bridge's tool list and the live editor tools land in the agent's deferred-tools index immediately.
2. **Background watcher**: every `SBOX_MCP_WATCH_MS` (default 30000) the bridge polls `/list_tools` and emits the notification when the count differs from the last-announced count. Handles the common case where the bridge starts before the s&box editor is up: the user fires up `sbox-dev.exe`, ~30s later the next tick sees the new tool count, and the notification fires automatically with no manual `sbox_reconnect`.

Tune via env var:

* `SBOX_MCP_WATCH_MS=10000`: poll every 10s instead of 30.
* `SBOX_MCP_WATCH_MS=0`: disable the watcher entirely (you'll need to call `sbox_reconnect` by hand when the editor comes up).

Without `tools.listChanged` declared, MCP clients silently drop the notifications, the watcher fires harmlessly into the void, and the agent keeps its first-connect snapshot (typically just `sbox_status` / `sbox_reconnect` if the editor wasn't running at bridge startup) until the session restarts. If you're seeing that symptom, you're on a pre-0.3.0 bridge: upgrade.

## Networking

`host.docker.internal` is auto-provisioned on Docker Desktop / Windows. On Linux Docker engines, add `--add-host=host.docker.internal:host-gateway` to your `docker run` (or `extra_hosts:` in compose).

## Verifying the connection

With the s&box editor open and the claude-sbox addon loaded:

```bash
curl -s http://127.0.0.1:6790/ping
# -> {"ok":true,"pong":true,...}

curl -s -X POST http://127.0.0.1:6790/list_tools | head -c 500
# -> {"ok":true,"tools":[{"name":"ping",...},{"name":"list_tools",...},{"name":"server_info",...},...]}
```

If those work, the bridge will too. From inside `claude`, run:

```
What tools are exposed by the sbox MCP server?
```

The agent should call `sbox_status` and report `connected=true`, then list the live tools.

## Rebuilding from source

The repo ships a fresh `dist/bridge.js`, so this is only needed if you edit `src/`.

```bash
bun install
bun run build       # bun build, outputs dist/bridge.js
bun run typecheck   # strict TS check, no emit
bun run dev         # bun --watch src/bridge.ts (for iteration)
```

## License

MIT.
