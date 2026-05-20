#!/usr/bin/env node
/**
 * sbox-mcp-bridge: stdio MCP server that forwards to the in-editor SboxMcpHost on the
 * Windows host. The MCP client (Claude Code, Claude Desktop, etc.) spawns this as a
 * subprocess and speaks MCP over stdio; the bridge re-issues each call as HTTP to
 * host.docker.internal:6790, where the claude-sbox addon's HttpListener is running.
 *
 * Tools are NOT hardcoded. At startup we hit /list_tools to discover whatever the editor
 * exposes (built-ins + auto-generated wrappers from schema attributes) and re-expose
 * each one as a real MCP tool. New editor versions get new tools for free.
 *
 * If the editor isn't running we still register a small set of meta-tools (`sbox_status`,
 * `sbox_reconnect`) so the agent can introspect the connection without having to read
 * stderr logs. Live tools become available the moment /list_tools succeeds.
 *
 * Tool-list change notifications: this bridge declares `tools.listChanged` and emits
 * `notifications/tools/list_changed` whenever the live tool count changes (via
 * sbox_reconnect or the background watcher). MCP clients that respect that capability
 * (Claude Code etc.) re-fetch /list_tools and the freshly-available editor tools land in
 * the agent's deferred-tools index without a manual refresh.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type Tool,
} from "@modelcontextprotocol/sdk/types.js";

import { SboxHttpClient, type HostConfig, type ToolDescriptor } from "./http-client.js";

// ----------------------------------------------------------------------------
// Per-tool HTTP timeouts
// ----------------------------------------------------------------------------
// The bridge's default timeout (config.timeoutMs, 15s unless SBOX_MCP_TIMEOUT_MS
// is set) is tuned for snappy editor introspection calls so a hung editor surfaces
// fast. But some tools legitimately do real work — building the test assembly,
// recompiling the project, waiting on an event, hitting sbox.game's cloud library
// — and 15s aborts them mid-flight every single call.
//
// SLOW_TOOL_TIMEOUTS lists the explicit cases. SLOW_TOOL_PREFIXES handles
// patterns like `wait_for_*` (these literally wait — the editor-side timeout_ms
// arg is authoritative; the bridge just needs to stay open longer) and
// `start_*_job` (job kickoff can be slow for large projects).
//
// Callers can override either with `{ _timeout_ms: <ms> }` in args. The bridge
// strips that key before forwarding so the editor's schema validation isn't
// confused by an unknown parameter.
const SLOW_TOOL_TIMEOUTS: Record<string, number> = {
  bootstrap_tests: 300_000, // ~30s typical, up to a few minutes on a freshly-pulled engine
  bootstrap_engine: 600_000, // engine artifact download + native + managed compile
  compile_project: 600_000, // large addons routinely run minutes
  compile_resource: 120_000,
  compile_snippet: 60_000,
  shader_compile_and_check: 120_000,
  wait_for_compiles: 300_000,
  asset_search: 60_000, // sbox.game cloud library
  asset_fetch: 60_000,
  asset_mount: 300_000, // download + extract
  asset_render_thumbnail: 60_000,
  asset_rebuild_thumbnail: 60_000,
  asset_batch_reimport: 300_000,
  screenshot_scene_to_file: 60_000,
  widget_capture_to_png: 60_000,
  pick_file: 600_000, // modal, blocks until the user picks a file
  refresh_schema: 120_000,
  start_standalone_export_job: 60_000, // job kickoff; the export itself is async
  start_compile_project_job: 60_000,
  project_publish_finalize: 300_000,
  project_publish_query_upload_plan: 60_000,
  project_publish_upload_files_job: 60_000,
  dispatcher_batch: 300_000, // up to 50 ops; cumulative can be long
  set_active_project: 120_000, // can trigger a content recompile sweep
  load_project: 120_000,
  hammer_reload_map: 60_000,
  navmesh_calculate_path: 60_000,
};

const SLOW_TOOL_PREFIXES: Array<{ prefix: string; timeoutMs: number }> = [
  { prefix: "wait_for_", timeoutMs: 600_000 }, // literally waits; editor-side arg is authoritative
  { prefix: "start_", timeoutMs: 60_000 }, // job kickoff
  { prefix: "project_publish_", timeoutMs: 120_000 },
];

function resolveTimeoutMs(toolName: string, defaultMs: number): number {
  const explicit = SLOW_TOOL_TIMEOUTS[toolName];
  if (explicit !== undefined) return explicit;
  for (const { prefix, timeoutMs } of SLOW_TOOL_PREFIXES) {
    if (toolName.startsWith(prefix)) return timeoutMs;
  }
  return defaultMs;
}

/**
 * Strip the bridge-local `_timeout_ms` knob from args before forwarding to the editor.
 * Returns the cleaned args and the override (in ms) if one was present and valid.
 */
function extractTimeoutOverride(args: unknown): { args: unknown; overrideMs: number | undefined } {
  if (args === null || typeof args !== "object" || Array.isArray(args)) {
    return { args, overrideMs: undefined };
  }
  const obj = args as Record<string, unknown>;
  if (!("_timeout_ms" in obj)) return { args, overrideMs: undefined };
  const raw = obj._timeout_ms;
  const ms = typeof raw === "number" && Number.isFinite(raw) && raw > 0 ? raw : undefined;
  const { _timeout_ms: _drop, ...rest } = obj;
  return { args: rest, overrideMs: ms };
}

function parseHostFromEnv(): HostConfig {
  // Resolution priority:
  //   1. SBOX_MCP_URL  — full base URL with scheme (e.g. https://my-host:8443).
  //                      Use when the editor's MCP host runs over HTTPS, on a
  //                      non-default path, or anywhere the host:port form
  //                      can't express.
  //   2. SBOX_MCP_HOST — host:port (or just host, port defaults to 6790).
  //                      Always assumed http://. Backwards compatible.
  //   3. Default: host.docker.internal:6790.
  const fullUrl = process.env.SBOX_MCP_URL?.trim();
  if (fullUrl) {
    try {
      const parsed = new URL(fullUrl);
      return {
        base: parsed.origin + parsed.pathname.replace(/\/+$/, ""),
        timeoutMs: Number(process.env.SBOX_MCP_TIMEOUT_MS ?? 15_000),
      };
    } catch {
      throw new Error(`bad SBOX_MCP_URL: ${fullUrl}`);
    }
  }
  const raw = process.env.SBOX_MCP_HOST?.trim() || "host.docker.internal:6790";
  const m = /^([^:]+)(?::(\d+))?$/.exec(raw);
  if (!m) throw new Error(`bad SBOX_MCP_HOST: ${raw}`);
  const host = m[1]!;
  const port = m[2] ? Number(m[2]) : 6790;
  return {
    base: `http://${host}:${port}`,
    timeoutMs: Number(process.env.SBOX_MCP_TIMEOUT_MS ?? 15_000),
  };
}

function descriptorToMcpTool(d: ToolDescriptor): Tool {
  return {
    name: d.name,
    description: d.description ?? `s&box editor tool '${d.name}'.`,
    inputSchema:
      // Default to a permissive object schema if the editor didn't supply one. This is the
      // shape MCP requires; the editor will validate properly server-side anyway.
      (d.inputSchema as Tool["inputSchema"]) ?? {
        type: "object",
        properties: {},
        additionalProperties: true,
      },
  };
}

/** Always-available meta tools regardless of editor connection state. */
function metaTools(client: SboxHttpClient): Tool[] {
  return [
    {
      name: "sbox_status",
      description:
        "Report whether the bridge is currently connected to the s&box editor's MCP host, " +
        "what URL it's targeting, and the last error if any. Use this to diagnose missing " +
        "editor tools.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
    {
      name: "sbox_reconnect",
      description:
        "Force a re-probe of the editor's MCP host and refresh the tool list. Use after " +
        "starting/restarting the s&box editor while the bridge is already running.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
  ];
}

async function main() {
  const config = parseHostFromEnv();
  const client = new SboxHttpClient(config);

  // Best-effort connect at startup. Failure is fine — we surface meta-tools regardless.
  await client.ping();
  if (client.getStatus().connected) {
    try {
      await client.listTools();
    } catch (e) {
      process.stderr.write(`[sbox-mcp-bridge] /list_tools failed at startup: ${String(e)}\n`);
    }
  }

  // listChanged: true is REQUIRED for the notifications/tools/list_changed flow to work.
  // Without it, MCP clients (Claude Code, Claude Desktop, etc.) skip registering a
  // ToolListChangedNotificationSchema listener, and any
  // server.sendToolListChanged() we emit later silently goes to the floor. With it
  // enabled, the client re-fetches /list_tools whenever we notify — exactly what we need
  // when the s&box editor comes up after the bridge has already been spawned (the bridge
  // typically starts first and only sees the 2 meta-tools until /list_tools succeeds).
  const server = new Server(
    { name: "sbox-mcp-bridge", version: "0.3.0" },
    { capabilities: { tools: { listChanged: true } } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    const meta = metaTools(client);
    let live: Tool[] = [];
    try {
      const descriptors = await client.listTools();
      live = descriptors.map(descriptorToMcpTool);
    } catch {
      // Connection lost between startup and now. The agent gets the meta tools and a
      // friendly note via sbox_status; no need to throw and abort the whole listing.
    }
    return { tools: [...meta, ...live] };
  });

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args } = req.params;

    if (name === "sbox_status") {
      const status = client.getStatus();
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                connected: status.connected,
                base: status.base,
                last_error: status.lastError,
                config,
              },
              null,
              2,
            ),
          },
        ],
      };
    }

    if (name === "sbox_reconnect") {
      const ok = await client.ping();
      let toolCount = 0;
      let probeError: string | null = null;
      if (ok) {
        try {
          toolCount = (await client.listTools(true)).length;
        } catch (e) {
          probeError = e instanceof Error ? e.message : String(e);
        }
      }
      // Tell the MCP client to re-fetch /list_tools. Without this notification the client
      // keeps its first-connect snapshot (which was just the 2 meta-tools because the
      // editor wasn't running at bridge startup), and the agent's deferred-tools index
      // never picks up the live editor tools (~570 in a typical session) even though the
      // bridge can call them on demand. Best-effort — swallow errors so a notify hiccup
      // doesn't fail the reconnect call itself.
      if (toolCount > 0) {
        server.sendToolListChanged().catch((e) => {
          process.stderr.write(`[sbox-mcp-bridge] sendToolListChanged failed: ${String(e)}\n`);
        });
      }
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ connected: ok, tool_count: toolCount, probe_error: probeError }, null, 2),
          },
        ],
      };
    }

    // Forward to editor. Errors become text content so the agent can read what went wrong
    // rather than getting an opaque MCP transport error.
    //
    // Timeout resolution order: explicit `_timeout_ms` arg from the caller > curated
    // per-tool override > config default (15s). The escape hatch is stripped from args
    // before forwarding so the editor doesn't see it as an unknown parameter.
    const { args: cleanedArgs, overrideMs } = extractTimeoutOverride(args);
    const effectiveTimeoutMs = overrideMs ?? resolveTimeoutMs(name, config.timeoutMs);
    try {
      const result = await client.callTool(name, cleanedArgs ?? {}, effectiveTimeoutMs);
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      };
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      return {
        content: [{ type: "text", text: JSON.stringify({ ok: false, error: "bridge_failure", message }, null, 2) }],
        isError: true,
      };
    }
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(
    `[sbox-mcp-bridge] connected to ${config.base} (editor reachable=${client.getStatus().connected})\n`,
  );

  // Background tool-list watcher.
  //
  // The bridge is typically spawned before the s&box editor is running, so the very first
  // /list_tools at startup fails and the MCP client caches just the 2 meta-tools. Without
  // this watcher the user has to call sbox_reconnect by hand to surface the live tools
  // once they fire up the editor.
  //
  // Cheap solution: every WATCH_INTERVAL_MS poll /list_tools (cache-bypassed) and emit
  // notifications/tools/list_changed when the live count differs from the last-announced
  // count. The MCP client's listChanged handler responds by re-fetching /list_tools,
  // picking up all editor tools (~570 in a typical session) within one poll interval of
  // the editor coming up.
  //
  // Cost: one HTTP round-trip every 30s to a localhost:6790 endpoint. The editor's
  // /list_tools handler is in-process and trivially fast. Tune via SBOX_MCP_WATCH_MS env
  // var (any milliseconds value); set to 0 to disable.
  const WATCH_INTERVAL_MS = Number(process.env.SBOX_MCP_WATCH_MS ?? 30_000);
  const WATCH_DISABLED = Number(process.env.SBOX_MCP_WATCH_MS) === 0;
  if (!WATCH_DISABLED) {
    let lastAnnouncedCount = -1;
    setInterval(async () => {
      try {
        const ok = await client.ping();
        if (!ok) return; // editor still down — silent, will retry next tick
        const tools = await client.listTools(true);
        if (tools.length !== lastAnnouncedCount) {
          lastAnnouncedCount = tools.length;
          await server.sendToolListChanged();
          process.stderr.write(
            `[sbox-mcp-bridge] tool count changed -> ${tools.length}; notified MCP client\n`,
          );
        }
      } catch (e) {
        // Best-effort; never throw from the timer.
        process.stderr.write(
          `[sbox-mcp-bridge] watcher tick failed: ${e instanceof Error ? e.message : String(e)}\n`,
        );
      }
    }, WATCH_INTERVAL_MS).unref(); // .unref() so the timer doesn't pin the bridge alive after stdio closes
  }
}

main().catch((e: unknown) => {
  process.stderr.write(`[sbox-mcp-bridge] fatal: ${e instanceof Error ? e.stack ?? e.message : String(e)}\n`);
  process.exit(1);
});
