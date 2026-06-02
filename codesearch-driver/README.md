# claude-sbox site-scrape driver (forum)

A tiny .NET class library that drives a **headless Chromium (via Microsoft.Playwright)** to read
the `sbox.game` **community forum**. The s&box addon loads this DLL at **runtime**
(`Assembly.LoadFrom`) and calls its single `RunAsync(string)→Task<string>` entrypoint by reflection
— so the addon never needs a compile-time Playwright reference (which s&box's in-editor compiler
can't resolve), yet everything still runs in **one process**.

> **History / naming:** this driver was originally built for `codesearch_*` (hence the
> `codesearch-driver` folder, `ClaudeSbox.CodeSearch.Driver.dll`, and `codesearch_install_driver`
> tool names — all kept for back-compat). **codesearch + release_notes have since moved to plain
> REST** (`public.facepunch.com/sbox/code/search/1/` and `/news/platform` — no browser), so the
> **only live consumer of this driver is now `forum_*`.** The driver still contains the old
> `search` / `get_file` / `list_files` / `release_notes` ops, but the addon no longer calls them.

## Why it lives here (not in the addon)

The `claude-sbox` addon gets **published** to sbox.game, so it must stay **source-only** — no build
scripts, no ~150 MB Playwright + Chromium-launcher payload. Therefore:

- **This source** + the `Build-CodeSearch-Driver.{bat,sh}` scripts live in **`claude-sbox-setup`**
  (the bootstrap/tooling repo), alongside `Bootstrap-Tests.*`.
- The **build output** is deployed to the game's **global store**
  `<game>/.claude-sbox/codesearch-driver/runtime/` (sibling of the docs/learn caches the addon
  already writes) — shared across every project in the install, never inside the addon.
- The addon ships only `Code/` (the reflection bridge + MCP tool handlers).

`sbox.game/f` (the forum) is a **Blazor Server** SPA: thread + post content streams over a SignalR
WebSocket circuit and is **absent from the raw HTML**, so reading it requires a real JS-rendering
engine. (codesearch + the changelog, by contrast, have plain JSON REST endpoints, which is why
they no longer need this driver.)

## Build + deploy

**Preferred — from the editor:** call the **`codesearch_install_driver`** MCP tool (name kept for
back-compat). It spawns `../Build-CodeSearch-Driver.{bat,sh}`, publishes this project into the
global store, and installs Chromium. Idempotent (skips if already built unless `force:true`). The
`forum_*` tools point you at it: when no driver is found they return `forum_driver_unavailable`
naming this tool.

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
                 └─ sbox.game/f Blazor circuit → scraped DOM
```

## Boundary contract (string JSON in / out)

The **live** ops are the forum ops; the codesearch/release-notes ops below are legacy (the addon
now serves those over REST and no longer invokes them):

```jsonc
// in — live (forum_*)
{ "op": "forum_index", "timeoutMs": 30000 }
{ "op": "forum_category", "category": "general", "timeoutMs": 30000 }
{ "op": "forum_thread", "path": "/f/general/2749/1/", "timeoutMs": 30000 }
{ "op": "forum_search", "q": "ragdoll", "timeoutMs": 30000 }

// in — legacy (no longer called by the addon; codesearch + release_notes are REST now)
{ "op": "search", "q": "ApplyForce", "type": "library", "year": "2026", "limit": 20, "timeoutMs": 30000 }
{ "op": "get_file", "org": "facepunch", "package": "sandbox", "file": "Player/NoclipMoveMode.cs" }
{ "op": "list_files", "org": "facepunch", "package": "sandbox" }
{ "op": "release_notes", "limit": 10, "timeoutMs": 30000 }
{ "op": "status" }
{ "op": "restart" }      // closes the browser; next op relaunches lazily

// out (always has "ok"); on failure: { "ok": false, "error": "timeout|browser_unavailable|bad_op|…", "message": "…" }
```

## Notes

- **TFM:** `net10.0`, to match the editor runtime that loads it. Change `<TargetFramework>` if the
  editor's runtime differs.
- **Rebuilds:** `Assembly.LoadFrom` caches the DLL for the process lifetime, so rebuilding over an
  already-loaded driver needs an **editor restart** to take effect. A first install loads lazily on
  the next forum call (no restart).
- **Auth:** none required — the forum (and the open-source packages the legacy ops covered) render
  without login.
