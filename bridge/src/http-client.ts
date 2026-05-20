/**
 * Thin HTTP client to the in-editor SboxMcpHost on host.docker.internal:6790.
 * Every MCP tool call routes through here as a POST with a JSON body, gets a JSON body back.
 *
 * Connection-state tracking so the bridge can degrade gracefully when the editor isn't
 * running (or the user closed it mid-session) instead of throwing on every tool call.
 */

export interface HostConfig {
  /** Full base URL with scheme + host + port, no trailing slash (e.g. http://host.docker.internal:6790). */
  base: string;
  timeoutMs: number;
}

export interface ToolDescriptor {
  name: string;
  description?: string;
  inputSchema?: unknown;
}

export class SboxHttpClient {
  private readonly base: string;
  private connected = false;
  private lastError: string | null = null;
  private cachedTools: ToolDescriptor[] | null = null;
  private toolsCachedAt = 0;
  private readonly toolsCacheMs = 30_000;

  constructor(private readonly config: HostConfig) {
    this.base = config.base.replace(/\/+$/, "");
  }

  /** Lightweight health probe. Returns true when the editor responds within timeout. */
  async ping(): Promise<boolean> {
    try {
      const r = await this.fetchJson("ping", null, this.config.timeoutMs);
      this.connected = r.ok === true || (r as { pong?: boolean }).pong === true;
      this.lastError = null;
      return this.connected;
    } catch (e) {
      this.connected = false;
      this.lastError = e instanceof Error ? e.message : String(e);
      return false;
    }
  }

  /** Fetch the live tool inventory. Cached for `toolsCacheMs` to avoid hammering /list_tools. */
  async listTools(force = false): Promise<ToolDescriptor[]> {
    const now = Date.now();
    if (!force && this.cachedTools && now - this.toolsCachedAt < this.toolsCacheMs) {
      return this.cachedTools;
    }
    const r = await this.fetchJson("list_tools", {}, this.config.timeoutMs);
    if (r.ok !== true || !Array.isArray((r as { tools?: ToolDescriptor[] }).tools)) {
      throw new Error(`/list_tools returned unexpected payload: ${JSON.stringify(r).slice(0, 200)}`);
    }
    this.cachedTools = (r as { tools: ToolDescriptor[] }).tools;
    this.toolsCachedAt = now;
    return this.cachedTools;
  }

  /**
   * Invoke a named tool with arbitrary JSON args. Errors are surfaced as thrown Error.
   *
   * `timeoutMs` overrides `config.timeoutMs` for this single call — used by the bridge to
   * give known-slow tools (bootstrap_tests, compile_project, wait_for_*, …) the headroom
   * they need without raising the default for snappy calls. Pass `undefined` to use the
   * configured default.
   */
  async callTool(name: string, args: unknown, timeoutMs?: number): Promise<unknown> {
    return this.fetchJson(name, args ?? {}, timeoutMs ?? this.config.timeoutMs);
  }

  /** Connection state for /server_info-style introspection. */
  getStatus(): { connected: boolean; lastError: string | null; base: string } {
    return { connected: this.connected, lastError: this.lastError, base: this.base };
  }

  private async fetchJson(path: string, body: unknown, timeoutMs: number): Promise<Record<string, unknown>> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const init: RequestInit = body === null
        ? { method: "GET", signal: ctrl.signal }
        : {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(body),
            signal: ctrl.signal,
          };
      const resp = await fetch(`${this.base}/${path}`, init);
      const text = await resp.text();
      if (!resp.ok) {
        throw new Error(`HTTP ${resp.status} from /${path}: ${text.slice(0, 300)}`);
      }
      try {
        return JSON.parse(text) as Record<string, unknown>;
      } catch {
        throw new Error(`Non-JSON response from /${path}: ${text.slice(0, 300)}`);
      }
    } finally {
      clearTimeout(timer);
    }
  }
}
