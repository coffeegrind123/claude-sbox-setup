# claude-sbox codesearch driver

A tiny .NET class library that drives a **headless Chromium (via Microsoft.Playwright)** to read
`sbox.game/codesearch` and the per-package source browser. The s&box addon loads this DLL at
**runtime** (`Assembly.LoadFrom`) and calls its single `RunAsync(string)→Task<string>` entrypoint
by reflection — so the addon never needs a compile-time Playwright reference (which s&box's
in-editor compiler can't resolve), yet everything still runs in **one process**.

## Why it lives here (not in the addon)

The `claude-sbox` addon gets **published** to sbox.game, so it must stay **source-only** — no build
scripts, no ~150 MB Playwright + Chromium-launcher payload. Therefore:

- **This source** + the `Build-CodeSearch-Driver.{bat,sh}` scripts live in **`claude-sbox-setup`**
  (the bootstrap/tooling repo), alongside `Bootstrap-Tests.*`.
- The **build output** is deployed to the game's **global store**
  `<game>/.claude-sbox/codesearch-driver/runtime/` (sibling of the docs/learn caches the addon
  already writes) — shared across every project in the install, never inside the addon.
- The addon ships only `Code/` (the reflection bridge + MCP tool handlers).

`sbox.game` is a **Blazor Server** SPA: codesearch results stream over a SignalR WebSocket circuit
and are **absent from the raw HTML**, so reading it requires a real JS-rendering engine.

## Build + deploy

**Preferred — from the editor:** call the **`codesearch_install_driver`** MCP tool. It spawns
`../Build-CodeSearch-Driver.{bat,sh}`, publishes this project into the global store, and installs
Chromium. Idempotent (skips if already built unless `force:true`). The codesearch_* tools point you
at it: when no driver is found they return `codesearch_driver_unavailable` naming this tool.

**By hand** (needs the .NET SDK):

```bash
# from claude-sbox-setup/
./Build-CodeSearch-Driver.sh        # Linux/macOS
Build-CodeSearch-Driver.bat         # Windows
```

It runs `dotnet publish codesearch-driver/CodeSearchDriver.csproj -c Release -o <game>/.claude-sbox/codesearch-driver/runtime`
plus `playwright install chromium`.

The addon finds the DLL automatically at
`<game>/.claude-sbox/codesearch-driver/runtime/ClaudeSbox.CodeSearch.Driver.dll`
(override with the `CODESEARCH_DRIVER_DLL` env var). Verify with `codesearch_status` →
`driver_dll_found: true`.

## Runtime shape

```
s&box editor process
  └─ Assembly.LoadFrom(<game>/.claude-sbox/codesearch-driver/runtime/ClaudeSbox.CodeSearch.Driver.dll)
       └─ Microsoft.Playwright.dll          (loaded into the editor ALC)
            ├─ node playwright driver        (child process)
            └─ headless Chromium             (child process)
                 └─ sbox.game/codesearch Blazor circuit → scraped DOM
```

## Boundary contract (string JSON in / out)

```jsonc
// in
{ "op": "search", "q": "ApplyForce", "type": "library", "year": "2026", "limit": 20, "timeoutMs": 30000 }
{ "op": "get_file", "org": "facepunch", "package": "sandbox", "file": "Player/NoclipMoveMode.cs" }
{ "op": "list_files", "org": "facepunch", "package": "sandbox" }
{ "op": "status" }
{ "op": "restart" }      // closes the browser; next op relaunches lazily

// out (always has "ok"); on failure: { "ok": false, "error": "timeout|browser_unavailable|…", "message": "…" }
{ "ok": true, "total": 4, "hits": [ { "package": "facepunch.sbdm", "file": "Utility/Damage.cs", "kind": "GAME", "url": "/facepunch/sbdm/source?file=Utility%2FDamage.cs", "startLine": 1, "snippet": "…" } ] }
```

## Notes

- **TFM:** `net10.0`, to match the editor runtime that loads it. Change `<TargetFramework>` if the
  editor's runtime differs.
- **Rebuilds:** `Assembly.LoadFrom` caches the DLL for the process lifetime, so rebuilding over an
  already-loaded driver needs an **editor restart** to take effect. A first install loads lazily on
  the next codesearch call (no restart).
- **Auth:** none required — codesearch covers open-source packages and renders without login.
