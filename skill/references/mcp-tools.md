# MCP tools exposed by the claude-sbox s&box addon

The in-editor MCP server (the claude-sbox s&box tool addon, `ghage/claude-sbox` on sbox.game) listens on `127.0.0.1:6790`. The `sbox-mcp-bridge` Node package re-exposes everything as stdio MCP. Tools are grouped by subsystem; all calls return JSON.

## Capability map: what the live bridge gives you

This is the narrative overview of every capability bucket (the per-subsystem tables below have the exact tool surfaces). SKILL.md links here for the full map.

When you're in an s&box context, you have access to **four ground-truth pipelines** (live, no snapshots — three docs + one real-world source):

1. **Live API schema**: locally built from the editor's loaded assemblies via `Facepunch.AssemblySchema`. Strictly more accurate than any CDN snapshot because it reflects the exact engine + addon DLLs the user is running. Use the `schema_*` MCP tools to look up exact, doc-commented signatures for every public type/method/property/field/attribute.
2. **Live prose docs**: two sibling pipelines, both cached + BM25-indexed by the MCP server. Use `docs_*` for **first-party Facepunch documentation** (Facepunch/sbox-docs repo, CC-BY-4.0, with `sbox.game/llms.txt` as fallback) — the authoritative usage docs for the engine and editor. Use `learn_*` for **community tutorials** (daily mirror of sbox.game/learn at `coffeegrind123/sbox-learn-docs`) — walkthroughs and how-tos written by other s&box developers, with rich faceted metadata (difficulty, topic, content_type, tags) you can filter on.
3. **Hosted structured docs** (`sdocs_*`): third-party Meilisearch proxy at `sdocs.suiram.dev` exposing 9 tools for symbol resolution, per-method overload details, examples, and related guides. Distinct from `docs_*`: returns structured per-symbol metadata + ranked hits + per-method per-parameter type/doc breakdowns. **Queries leave the machine**: for symbol names lifted from private project source, prefer `schema_*` + `docs_*`. See § Hosted structured docs and gotchas.

And a fourth, **real-world source** pipeline — **`codesearch_*`**: live-scrapes [sbox.game/codesearch](https://sbox.game/codesearch) (the source of *every open-source package*) through a headless-Chromium driver, because that page is a Blazor Server SPA with no JSON API and no prerendered HTML. Where `schema_*`/`sdocs_*` tell you a method's *signature*, codesearch tells you how people *actually call it* in shipped code: `codesearch_search(query)` returns ranked hits (package, file, snippet, source URL), then `codesearch_get_file(...)` pulls the whole file and `codesearch_list_files(...)` walks a package's tree. **Queries leave the machine** (same privacy posture as `sdocs_*`). First use needs a one-time `codesearch_install_driver` (returns `codesearch_driver_unavailable` until then). See § Code search.

**Recommended docs-query layering** (default; deviate when the user already pinned a layer):

1. **Ground first** with `schema_search_members(query)` or `schema_lookup_type(fqn)` — confirms the symbol actually exists in *this* build and pins the canonical FQN. If `connected=false`, skip to step 3 (local prose still works).
2. **Get usage shape** with `sdocs_search_docs(query)` → `sdocs_get_method_details(id)` for per-parameter docs/return types, plus `sdocs_get_examples(id, includeRelated:true)` when the agent needs to see how the call is wired. Skip if the symbol came from private project source (privacy: queries leave the machine).
3. **Get the narrative** with `docs_search(query)` → `docs_get(path)` for first-party prose (lifecycle, RPC semantics, networking visibility rules, etc.). Use `sdocs_get_related_guides(id)` instead when you already have an FQN — it cross-links the symbol back to the prose page.
4. **Fall back to community** with `learn_search(query)` or `learn_search(topic: "...", difficulty: "Beginner")` when official docs don't cover the question. Faceted; use empty query + filter for "highest-rated in this topic".

Shortcut: for a one-line concept ("RPC visibility rules") skip 1 and start at 3. For verifying a method call you're about to write, run 1 alone — schema is ground truth. To see **real call sites** ("how does anyone actually use `ApplyForce` / `Scene.Trace`?"), add `codesearch_search(symbol)` → `codesearch_get_file(hit.source_url)` — the only layer that shows live shipped usage rather than signatures or prose.

You also have **live editor introspection + drive** when the editor is running and the bridge is connected:

4. **Editor mode + state**: `editor_state` is a one-call snapshot of mode (edit/play/paused), scene state, project, multiplayer status, filesystem scopes, dispatcher metrics, and capability flags. **Call this first** when you don't know what state the editor is in; gate any mode-dependent tool on its result.

5. **Scene / inspector / project / console**: `get_active_scene`, `list_gameobjects`, `get_components`, `get_selection`/`set_selection`, `list_properties`/`get_property`/`set_property`, `list_addons`, `tail_log`/`print_log`, `find_asset`/`list_assets`, plus `instantiate_prefab`, `find_game_objects_in_radius`, `frame_selection`, `save_scene`, `batch_transform`, `copy_component`. All edits go through the editor undo scope. For component lifecycle (add/remove/enable/reorder) see `gameobject_*`; for prefab override tracking see `prefab_*`.

6. **UI discovery + drive**: anything user-facing in the editor is reachable. `list_docks`/`list_menus`/`list_shortcuts`/`list_widgets`/`find_widget` discover; `activate_dock`/`set_dock_visible`/`invoke_menu`/`invoke_shortcut`/`click_widget`/`focus_widget`/`send_keys`/`run_console_command` drive. Auto-generated wrappers cover every method tagged `[Menu]`/`[Shortcut]`/`[ConCmd]`/`[Editor.Tool]`: MCP names are `auto_<Type>_<Method>` (underscore form; the canonical identity in `auto_list` output uses `auto:<Type>.<Method>` with dots/colons but the exposed tool name substitutes underscores).

7. **Visual guidance**: `spotlight(target, message)` (single mode) or `spotlight(sequence: [{target, message, dwell_ms}, ...])` (tour mode) draws a glow border + speech bubble around a UI element, dimming everywhere else. Use this for "where is X?" / "show me Y" questions instead of a paragraph of prose; it's faster and the user actually sees what you mean. `editor_highlight` is the older basic single-stop variant: reach for it only when tour mode isn't needed.

8. **Editor preferences**: `list_preferences`/`get_preference`/`set_preference` for every property on `Editor.EditorPreferences`. Plus `export_preferences` / `import_preferences` for full snapshot+restore.

9. **Code reasoning**: `reflection_*` tools go beyond `schema_*` signature lookup into relationships and discovery: `reflection_find_types_with_attribute`, `reflection_find_methods_with_attribute`, `reflection_get_type_hierarchy` (bases + interfaces + subclasses), `reflection_get_enum_values`, `reflection_get_member_metadata` (Title/Icon/Group/Order/Tags), `reflection_parse_attribute_metadata`, `reflection_find_resource_types_with_extension`. Cross-reference via `find_type_usages` / `find_method_overrides` / `find_symbol_definition`.

10. **Compile + hotload introspection**: `compile_check_build_state` (non-blocking), `compile_get_diagnostics` (errors/warnings without re-running), `compile_list_compilers`, `hotload_get_last_result` (TypeTimings, warnings), `hotload_list_queued_assembly_swaps`. Plus an async-job pattern: `start_compile_project_job` → `poll_job` → `cancel_job` / `list_jobs` for non-blocking compiles. Roslyn devtools: `compile_snippet` (diagnostics, no execution), `parse_syntax_tree` (AST dump), and **`execute_csharp`** (REPL-style evaluation in the live editor process via reflective `CSharpScript.EvaluateAsync`: auto-imports `System` / `System.Linq` / `Sandbox` / `Editor` / `Editor.ClaudeSbox.Mcp`, plus a comma-separated `imports` arg for extras). Use `execute_csharp` to answer "what does `Scene.GetAllComponents<X>().Count()` return right now?" in one shot instead of compiling a snippet that doesn't run.

11. **Asset native + cloud library + event bus**: local: `asset_query_state` (compiled? cached? unsaved?), `asset_query_dependencies` (refs/dependants/parents, deep), `asset_compilation_control`, `asset_render_thumbnail` (PNG to disk), `asset_set_in_memory_override` (live-prototype without disk writes). Cloud library: `asset_search(query, take?)` queries sbox.game's public package library, `asset_fetch(ident)` returns full metadata, `asset_mount(ident, pin_to_project?)` mounts via `Package.MountAsync` and (default) appends the ident to the active project's `.sbproj` `PackageReferences` so it auto-mounts on subsequent loads, `asset_unpin(ident)` is the symmetric inverse. Event bus: `wait_for_*` and `last_*` over 28 EditorEvents (`scene.play`, `compile.shader`, `content.changed`, `hotloaded`, `package.changed.*`, `hammer.*`, `asset.contextmenu`, `assetsystem.openpicker`, `folder.contextmenu`, `editor.created`, etc.) plus composites: `wait_for_scene_state`, `wait_for_asset_ready`, `wait_for_editor_ready`, `wait_for_content_change`.

12. **Gizmo + console vars + project + Qt native**: `get_gizmo_state` / `set_gizmo_mode|space|snap_settings|scale`, `list_concmds` / `list_convars` / `get_convar` / `set_convar`, `set_active_project`, `validate_project`, `widget_get_geometry` / `widget_set_visible|opacity|focus_policy`, `widget_capture_to_png` (widget → PNG), `splitter_save_state` / `splitter_restore_state`. Inspector input writes that bypass `set_property` (custom widgets, popup dialogs): `set_input_text` / `set_color` / `set_checkbox` / `set_slider_value` / `select_dropdown_option` / `set_widget_value` (universal); `inspect_widget` to discover an unfamiliar widget's surface first.

13. **Filesystem reads**: `host_*` (8 tools) reads the engine source tree, addon source, project content, editor caches without needing a bind mount. 14 scopes (9 `filesystem_scope` + 5 `absolute_path`), all read-only. Call `host_list_scopes` first to discover what's reachable, then `host_read_file` / `host_grep` / `host_list_directory` / `host_read_text_around` (lines around a target line).

The principle: **anything the user can do in the editor, you can do**. If you can't find a tool for it, try `list_menus`/`list_shortcuts` first (almost everything is registered there), then `run_console_command` as the universal escape hatch.

## Diagnostic / meta

| Tool | What it does |
|---|---|
| `ping` | Basic connectivity probe. Returns `{ok, pong, ts, started_at, tools}`. |
| `list_tools` | Full tool inventory with descriptions and JSON schemas. |
| `server_info` | Editor + MCP host metadata: version, started_at, tool_count, bridge_connections. |
| `doctor` | Unified readiness probe. Rolls up listener / dispatcher / active scene / compile state / playing tabs / unsaved scenes / recent engine errors into one structured pass/warn/fail report with `next_suggested_action`. Call this once at session start instead of probing the others individually. Args: `max_recent_errors`, `max_recent_warnings`. |
| `sbox_status` | (Bridge-side) Connection state + last error. Use this first if other tools fail. |
| `sbox_reconnect` | (Bridge-side) Force re-probe of the editor's MCP host and refresh the tool list. |

## Multi-tool batches (`dispatcher_batch`)

Run up to 50 sequential tool calls in one HTTP roundtrip: each child goes through the normal dispatcher (own LogCapture window, own auto-toast). Later operations can substitute values from earlier ones via `{"$ref": "alias.path.to.value"}`, where `alias` is the operation's `key` and `path` is dotted into the response body. Returns `207 Multi-Status` when any child failed.

| Tool | What it does |
|---|---|
| `dispatcher_batch` | Args: `operations: [{ key, tool, args }]`, `stop_on_error: bool` (default true). Body returns `{ ok, aborted, operations_total, operations_run, results: [{ index, key, tool, ok, status, body }] }`. |

Example: create a GameObject, set its transform, add a ModelRenderer in one call:

```json
{
  "operations": [
    { "key": "obj", "tool": "gameobject_create", "args": { "name": "Crate" } },
    { "tool": "set_property", "args": { "id": { "$ref": "obj.id" }, "path": "WorldPosition", "value": { "x": 0, "y": 0, "z": 100 } } },
    { "tool": "gameobject_add_component", "args": { "id": { "$ref": "obj.id" }, "type": "ModelRenderer" } }
  ]
}
```

## Orientation overrides (`orientation_override_*`)

`.vmdl` assets don't carry a semantic "up" direction in their metadata: the agent or user has to discover the right base rotation by trial. The override store persists that knowledge so subsequent placements pick it up automatically. Storage: `{project assets}/claude-sbox/orientation_overrides.json`, atomic write.

`drop_asset_into_scene` consults the store automatically: when an override exists for the asset path, its `base_rotation` is composed under the caller's `rotation_euler` and `ground_offset_z` is added to `position.z`. Pass `apply_orientation_override:false` to skip lookup.

| Tool | What it does |
|---|---|
| `orientation_override_get` | Read one model's stored override. Args: `model_path`. Returns `{ found, record, storage }`. |
| `orientation_override_set` | Create/replace one model's override. Args: `model_path`, `base_rotation: {pitch, yaw, roll}`, `ground_offset_z`, `forward_axis`, `confidence`, `source`, `notes`. Returns the persisted record. |
| `orientation_override_delete` | Remove one model's stored override. Args: `model_path`. Returns `{ existed }`. |
| `orientation_override_list` | Enumerate every stored override in the active project. Returns `{ count, records, storage }`. |
| `orientation_override_storage` | Where the JSON file lives + whether it exists. Useful for debugging "is the file actually there?". |

## API schema (`schema_*`)

Backed by a **locally-generated schema**: the addon walks the editor's loaded assemblies through `Facepunch.AssemblySchema.Builder` (the same library Facepunch uses to publish `cdn.sbox.game/releases/*.zip.json`) and serializes the result. Strictly more accurate than the CDN dump because it reflects the exact engine version *and* every loaded tool/game addon. Cached on disk under `<sbox-folder>/.claude-sbox/cache/schema/local-<fingerprint>.json`; fingerprint changes on any assembly mtime change so hot-reloads invalidate cleanly.

| Tool | What it does |
|---|---|
| `schema_lookup_type(fullname)` | Full Type entry: methods, properties, fields, base type, attributes, doc summaries. |
| `schema_search_members(query, kind?, limit?)` | Fuzzy search across method/property/field names + doc summaries. `kind` filters by `method`/`property`/`field`/`ctor`. |
| `schema_browse_namespace(prefix?, offset?, limit?)` | List types under a namespace prefix (e.g. `Editor.`, `Sandbox.UI.`). |
| `schema_signature(fullname, member, kind?)` | Formatted signature + XML doc for a single member. Pair with `schema_lookup_type`. |
| `schema_usage(fullname, limit?)` | Find places in the public API that reference a type: return types, parameter types, base types of subclasses. Slow first call (full scan), cached after. |
| `schema_freshness` | Report where the current schema came from, fingerprint, type count. |
| `refresh_schema` | Re-walk the editor's loaded assemblies (call after a hot-reload that brought in new addon DLLs you want introspected). |

**Use these whenever you'd otherwise be tempted to guess at an API name.** That's the entire point of the schema layer. Because the source is the running editor, the answer is always correct for the version of s&box the user is using *right now*: no staging-vs-stable drift, no upstream-CDN-stale-cache problem.

## Prose docs (`docs_*`)

**Primary source: `Facepunch/sbox-docs` repo (CC-BY-4.0).** The addon pulls the tarball at startup (~600KB, single HTTP), unpacks to `<sbox-folder>/.claude-sbox/cache/docs-repo/`, and builds the BM25 index over the entire corpus eagerly. By the time the agent makes its first `docs_search`, the full ~190 pages are already indexed: no `prefetch` flag needed, no per-page latency. Update detection is a single GitHub API call against the master-branch commit SHA.

**Fallback source:** `sbox.game/llms.txt` + per-page lazy fetch: kept underneath in case the GitHub fetch fails (rate-limited, network down, etc.). Search results report `source: "facepunch/sbox-docs"` or `"sbox.game"` so you can tell which path served the answer.

| Tool | What it does |
|---|---|
| `docs_search(query, limit?, prefetch?)` | BM25 over titles + bodies. Returns `[{path, title, score, snippet}]` plus `source` and `repo_commit` fields. Index is fully populated at startup. `prefetch:true` forces every page in the website manifest to be fetched before searching — only useful when the eager repo tarball failed and the lazy website fetcher is in play. |
| `docs_get(path)` | Body of a single page. Reads from the repo cache when available; falls back to the website. Returns `source` and `commit` fields so you can cite. |
| `docs_list` | Every page title + path the manifest knows about. |
| `docs_refresh` | Refresh both sources in parallel: re-fetch the GitHub tarball if the master SHA changed, and revalidate the website cache with ETag/If-None-Match. |

The `path` argument is the suffix after `/docs/` in the repo (or after `/dev/doc/` on the website), with `.md` stripped. So `Facepunch/sbox-docs/blob/master/docs/editor/editor-widgets.md` → `editor/editor-widgets`.

**License**: doc page bodies are CC-BY-4.0. When the agent quotes verbatim, the body itself is the attribution-bearing artifact; the `source` and `commit` fields make the citation precise.

## Community tutorials (`learn_*`)

Daily-scraped mirror of the community-written tutorials at [sbox.game/learn](https://sbox.game/learn), published as a markdown tree at [`coffeegrind123/sbox-learn-docs`](https://github.com/coffeegrind123/sbox-learn-docs). Same fetch + cache + BM25 pattern as `docs_*`, just pointing at a different repo and exposing faceted filters since these pages carry rich metadata (difficulty, topic, content type, tags) that the Facepunch docs don't.

**Why it exists**: sbox.game is a Blazor Server SPA — tutorial bodies are streamed over SignalR after the empty HTML shell loads, so a raw HTTP scraper sees nothing. The mirror is built by a Python+Camoufox script on GitHub Actions (06:00 UTC daily); the addon just downloads the tarball and indexes it, the same way `DocsRepoCache` consumes `Facepunch/sbox-docs`.

**When to reach for `learn_*` vs. `docs_*`:**

- `docs_*` for **first-party Facepunch docs** (API guides, lifecycle, networking semantics). Authoritative.
- `learn_*` for **community walkthroughs** ("how do I set up jigglebones", "porting a Source map", "IDE setup", "displaying a networked variable in UI"). Tagged with difficulty + topic so you can ask for beginner-only or networking-only.

Each tutorial carries YAML frontmatter: `title`, `slug`, `url`, `author`, `author_slug`, `difficulty` (Beginner / Capable / Expert), `topic` (Editor / UI / Networking / Mapping / Coding / Physics / …), `content_type` (Text / Video), `tags[]`, `rating` (1–5 stars from listing card), `views`, `upvotes`, `downvotes`, `updated`, `summary`, `scraped_at`. `learn_get` returns each frontmatter field as a top-level property of the response plus the body markdown.

| Tool | What it does |
|---|---|
| `learn_search(query?, difficulty?, topic?, content_type?, author?, tags?, limit?)` | BM25 over title (×4) + tags (×2) + summary (×2) + body. Returns ranked `[{path, title, score, difficulty, topic, content_type, author, tags, rating, views, url, snippet}]` plus the mirror's commit SHA. **Either `query` OR at least one facet filter is required** — empty-string with no filter is rejected. With facets but no query, falls back to a community-signal score (`rating × 10 + log(views) + upvotes − downvotes`) so "give me a beginner networking tutorial" works without keywords. |
| `learn_get(path)` | Fetch a single tutorial by `<author>/<slug>` path (e.g. `frxxks/beginner-resources`). Returns frontmatter fields + the markdown body. |
| `learn_list` | Every tutorial with its full metadata. Cheap; useful when the agent wants to enumerate by facet without searching. |
| `learn_refresh` | Re-fetch the mirror tarball (single GitHub API call to compare SHA, only re-downloads if changed) and rebuild the BM25 index. Use when you suspect tutorials have changed since editor boot. |

**Calling pattern** for "find me a beginner UI tutorial":

```json
{ "difficulty": "Beginner", "topic": "UI", "limit": 5 }
```

**License**: scraped content is treated as CC-BY-4.0. Each tutorial's `url` field is the canonical attribution target (the original sbox.game/learn page by the named author).

## Hosted structured docs (`sdocs_*`)

A separate **third-party hosted MCP proxy** at `https://sdocs.suiram.dev/api/v1/mcp` (Meilisearch-backed). Distinct from `docs_*` (local prose) and `schema_*` (local signatures): this surface returns structured per-symbol metadata with TOON output, ranked snippets, per-method overload details, and example/related-guide retrieval. URLs in results are sbox.game `/docs/api/...` paths.

**Privacy posture**: queries leave the user's machine. For symbol names lifted out of private project source, prefer local `schema_*` + `docs_*`. `sdocs_*` is best for general concepts ("component update loop", "razor reactivity", "InputAction binding") rather than verbatim project identifiers.

Override the base URL via env var on the editor process (highest priority), `game/data/claude-sbox-config.json` → `claude-sbox.sdocs_base_url`, or the default fallback.

| Tool | What it does |
|---|---|
| `sdocs_status` | Report current base URL + config source. Read-only: does NOT call out. Use first to confirm whether the proxy is configured. |
| `sdocs_search_docs(query, kind?, typeName?, limit?)` | BM25-style hit ranking over the API + Guides corpus. Returns `[{score, id, kind, name, sig, summary, owner, url}]` per hit. `kind` filters by `class`/`method`/`property`/`field`/`enum`. `typeName` narrows to one type's surface. |
| `sdocs_resolve_symbol(name)` | Disambiguate a short name (`Component`, `Scene`, `Transform`) to fully-qualified candidates. Returns ranked FQNs. |
| `sdocs_get_symbol(id)` | One symbol's namespace, kind, signature, summary, inheritance/declaration context. |
| `sdocs_get_method_details(id)` | Single overload: canonical signature, per-parameter names + types + docs, return type + docs, related notes. |
| `sdocs_get_type_members(typeName)` | Constructors / methods / properties of a type. Use after `_resolve_symbol` to enumerate the surface. |
| `sdocs_get_examples(symbolId, includeRelated?)` | Code examples attached to a symbol. `includeRelated:true` falls back to type-level examples when the member has none. |
| `sdocs_get_related_guides(symbolId)` | Guide pages most relevant to a symbol: workflows + editor steps that the API page alone doesn't cover. |
| `sdocs_list_namespaces(prefix?)` | Top-down namespace explorer; per-namespace child + counts (class/enum/interface/struct + member count). |

**When to reach for `sdocs_*` vs. `schema_*` vs. `docs_*`:**

- `schema_*` for the precise signature of a member you can already name. Local; deterministic; cheap.
- `docs_*` for the "I want a paragraph about X" narrative. Local; BM25 over Markdown.
- `sdocs_*` for "I have a concept and want both ranked symbol hits AND example/guide leads in one call". Hosted; richer per-method metadata than `schema_*`; richer ranking than local BM25.

### Layered query recipe

Each surface answers a different question. When researching anything bigger than a single signature lookup, layer them in this order rather than picking one:

| Step | Goal | Tool(s) | When to skip |
|---|---|---|---|
| 1. Ground | Confirm the symbol exists in *this* build; pin the canonical FQN | `schema_search_members(query)` or `schema_lookup_type(fqn)`; `reflection_get_type_hierarchy(fqn)` if you need bases/subclasses | Editor not connected → start at step 3 (local prose). |
| 2. Shape | Per-parameter docs, return type, overload details, example wiring | `sdocs_search_docs(query)` → `sdocs_get_method_details(id)` → `sdocs_get_examples(id, includeRelated:true)` | Symbol came from private project source (privacy: queries leave the machine) → use `schema_signature` + grep the prose docs. |
| 3. Narrative | Workflow / semantics / "why does this behave this way" | `docs_search(query)` → `docs_get(path)`; or `sdocs_get_related_guides(id)` once you have the FQN | Question is just "what does this method return" — step 2 already answered it. |
| 4. Community | Worked end-to-end examples or video walkthroughs | `learn_search(query)` or facet-driven `learn_search(topic: "...", difficulty: "Beginner")` | First-party prose at step 3 covers it. |

**Common single-step shortcuts** (don't run the whole pipeline when the question is narrow):

- *"What's the signature of `Component.OnUpdate`?"* → step 1 alone.
- *"Explain RPC ownership"* → step 3 alone (`docs_search("RPC ownership")`).
- *"What types implement `IScenePhysicsEvents`?"* → step 1 with `reflection_get_type_hierarchy`.
- *"Show me a Razor reactivity example"* → step 2 (`sdocs_search_docs("razor reactivity")` → `_get_examples`).
- *"Beginner UI tutorial"* → step 4 alone with facets.

**Provenance note**: results from step 1 reflect the running editor's loaded assemblies (fingerprint via `schema_freshness`); results from step 2 hit `sdocs.suiram.dev` (hosted, snapshot whatever it was last indexed against); results from steps 3 + 4 read locally-cached repo tarballs (`docs_refresh` / `learn_refresh` to revalidate). When the layers disagree on a signature, trust step 1.

## Code search (`codesearch_*`)

Full-text search over the **source of every open-source package on sbox.game** — the [Code Search](https://sbox.game/codesearch) feature ("search the source of every open source package"). This is the *real-world usage* layer: `schema_*`/`sdocs_*` give you signatures; codesearch shows you how shipped community + Facepunch code actually calls them, and lets you pull whole files for context.

**Why it needs a driver (and isn't just an HTTP call like `sdocs_*`)**: sbox.game is a **Blazor Server** SPA. A raw GET of `/codesearch?q=…` returns only a ~3 KB bootstrap shell — results stream over a SignalR WebSocket circuit and are *never* in the HTML. So the addon drives a headless Chromium (via Microsoft.Playwright) that loads the page, lets the circuit render, and scrapes the result DOM. Because s&box's compiler can't reference Playwright as a NuGet package, the driver is a **prebuilt DLL loaded at runtime** (`Assembly.LoadFrom`) from the game's global store `<game>/.claude-sbox/codesearch-driver/runtime/`; its source + build scripts live in the `claude-sbox-setup` repo, never in the published addon. Everything still runs in one process (only the driver + Playwright DLLs enter the editor's load context; the node driver + Chromium are child processes).

**First-use flow**: a codesearch call with no driver returns `codesearch_driver_unavailable`. Call **`codesearch_install_driver`** once (builds + deploys, ~1–3 min for restore + Chromium download), then retry — it loads lazily on the next call (no restart). **Queries leave the machine** (same privacy posture as `sdocs_*`): for identifiers from private project source, prefer `schema_*` + `docs_*`.

| Tool | What it does |
|---|---|
| `codesearch_search(query, type?, year?, limit?)` | Search package source. Returns `{total_results, hits:[{package, file, kind, source_url, start_line, snippet}]}`. `query` is free-text or a symbol (`"Physics.Trace"` quoted for phrase). `type` filters package kind (`library`/`game`/`code`/`editor`/`unittest`); `year` filters publish year. `source_url` feeds straight into `codesearch_get_file`. |
| `codesearch_get_file(source_url \| org+package+file)` | Fetch the COMPLETE source of one file. Pass a hit's `source_url`, or `org`+`package`+`file` explicitly (e.g. `facepunch` / `sandbox` / `Player/NoclipMoveMode.cs`). Returns full `content` + `line_count`. |
| `codesearch_list_files(org, package)` | Enumerate a package's whole source tree (flat list of file paths) to explore layout before drilling in. |
| `codesearch_status` | Driver diagnostics: `driver_dll_found` / `driver_loaded` / `driver_status` (browser launched? chromium installed?) + `load_error`. Read-only; run first when codesearch fails. |
| `codesearch_restart` | Tear down + relaunch the headless browser (next call relaunches lazily). Use if the circuit wedges or queries start timing out. |
| `codesearch_install_driver(force?, timeout_seconds?)` | Build + deploy the driver (spawns `claude-sbox-setup/Build-CodeSearch-Driver.{bat,sh}`). Idempotent; `force:true` rebuilds (needs an editor restart if the driver's already loaded). Needs the .NET SDK on PATH. |

**When to reach for `codesearch_*`**: "show me how people actually wire up an InputAction / VideoPlayer / Rigidbody force", "find every package that uses `IGameEventHandler`", "what does a real `Component.ITriggerListener` implementation look like". For a method's *contract* use `schema_*`/`sdocs_*`; for *real usage at scale* use codesearch, then `codesearch_get_file` to read the surrounding code.

## Project / addon (`get_active_project`, `list_*`)

| Tool | What it does |
|---|---|
| `get_active_project` | Title, ident, on-disk paths, package metadata for the project hosting the active edit session. |
| `list_projects` | Every `.sbproj` the editor knows about. |
| `list_addons` | Subset of `list_projects` filtered to addon/tool/library types. |

## Scene / GameObject

All scene tools marshal to the editor main thread; safe to call mid-edit. **Hide GameObjects from MCP walks** by including `(MCP IGNORE)` in the Name or adding the `mcp_ignore` tag: useful for editor scaffolding the agent shouldn't see.

| Tool | What it does |
|---|---|
| `get_active_scene` | Active edit session: source path, gameobject count, has unsaved changes. |
| `list_sessions` | Every open edit session, with the active one flagged. |
| `list_gameobjects(depth?, limit?)` | Walk the scene tree. Returns id/name/parent_id/child_count/component_count/depth per GameObject. |
| `get_gameobject(id)` | Full details: name, transform (world+local), components list, children. |
| `get_components(id)` | Components on a GameObject: index, type FullName, enabled state. |
| `get_selection` | Current editor selection (GameObjects + components). |
| `set_selection(ids)` | Replace selection. Empty array = clear. |
| `instantiate_prefab(path, position?, rotation?, parent_id?)` | Clone a `.prefab` into the active scene. Goes through the editor undo scope. |
| `find_game_objects_in_radius(center, radius, limit?, sort_by?)` | Spatial query: GameObjects within radius of center. `sort_by`: "distance" (default) or "name". |
| `frame_selection(id?)` | Center the editor camera on the current selection (or a specific GameObject). |
| `save_scene` / `save_all_scenes` | Persist edits. Returns `had_unsaved_changes`. |
| `batch_transform(ids, translate?, rotate_euler?, scale_multiplier?)` | Translate/rotate/scale-offset many GameObjects at once, single undo entry. |
| `copy_component(source_id, source_index, target_id)` | Copy a component (with all properties) between GameObjects, via SerializedObject so nested data round-trips. |

## Inspector (`*_property`)

Identify a component by `(id, component_index)` or `(id, component_type)`. Edits go through the editor's undo scope so they show up in Undo. `set_property` tries `Sandbox.TypeLibrary.GetSerializedObject(c).GetProperty(name).SetValue(JsonNode)` first (matches inspector copy/paste, handles nested structs); falls back to manual coerce + reflection if that path isn't available.

| Tool | What it does |
|---|---|
| `list_properties(id, component_index|component_type)` | Inspector-visible properties with types and current values. |
| `get_property(...)` | Single property's current value. |
| `set_property(..., value)` | Single property write. JSON value coerced to declared type (Vector3, Color, enum, etc.). Reports which path (`SerializedObject` vs `Reflection`) was used. |

## Assets

| Tool | What it does |
|---|---|
| `find_asset(path)` | Resolve by relative path (e.g. `materials/grass.vmat`). |
| `list_assets(type_filter?, path_prefix?, offset?, limit?)` | Enumerate, optionally filtered by extension token or path prefix. |

## Cloud asset library (`asset_search` / `_fetch` / `_mount` / `_unpin`)

Search the s&box public package library, fetch metadata, and install packages with optional auto-pin to `.sbproj`. Closes the gap where the agent could only reach packages the user had already mounted locally.

| Tool | What it does |
|---|---|
| `asset_search(query, take?)` | Free-text search over sbox.game's package library. Returns up to `take` results (default 20, max 100) with `ident`, `short_ident`, `title`, `description`, `type`, `thumb`, `updated`. Use `asset_fetch` for full details. |
| `asset_fetch(ident)` | Full metadata for a single package by ident. Returns the same fields as `asset_search` plus `primary_asset` (the `PrimaryAsset` meta: useful for direct-to-`drop_asset_into_scene` flows post-mount). Accepts both full ident (`facepunch.tools_pack`) and short ident. |
| `asset_mount(ident, pin_to_project?)` | Calls `Package.MountAsync` so the package's assets become available to the running session. Default `pin_to_project:true` appends the ident to the active project's `.sbproj` `PackageReferences` (idempotent dedupe), so it auto-mounts on subsequent project loads. Pass `false` for one-session-only. |
| `asset_unpin(ident)` | Symmetric inverse: removes every entry matching `ident` from `.sbproj` `PackageReferences`. Does **not** unmount the running session: the package stays usable until next reload. Use to stop a previously-pinned package from auto-mounting. |

**Workflow**: `asset_search("low poly tree")` → pick an interesting `ident` → `asset_fetch(ident)` if you want the description / primary asset before installing → `asset_mount(ident)` to install + pin → `drop_asset_into_scene(primary_asset, ...)` to use it. The pin survives editor restarts; just reopen the project.

## Roslyn devtools (`compile_snippet` / `parse_syntax_tree` / `execute_csharp`)

Inspect / compile / evaluate C# in the live editor process. The first two are static analysis (no execution); `execute_csharp` is the REPL-style evaluator. All three live alongside the ETW profiler tools in `Diagnostics/`.

| Tool | What it does |
|---|---|
| `compile_snippet(source, assembly_name?, reference_engine?)` | Compile a standalone C# snippet via Roslyn and return diagnostics (errors, warnings, info). **Does not execute**: useful for "would this code build against the engine?" without running it. |
| `parse_syntax_tree(source, path?)` | Parse a snippet and return its AST: top-level usings, namespaces, types, methods. Useful for code-reasoning without invoking the compiler. |
| `execute_csharp(code, imports?)` | **REPL-style evaluation in the editor process.** Runs the code via reflective `Microsoft.CodeAnalysis.CSharp.Scripting.CSharpScript.EvaluateAsync` against every loaded assembly. Default imports: `System` / `System.Linq` / `System.Collections.Generic` / `System.Threading.Tasks` / `Sandbox` / `Editor` / `Editor.ClaudeSbox.Mcp`. Pass comma-separated `imports` for extras (e.g. `"Sandbox.UI,Editor.MapEditor"`). Returns `{executed:true, result:"…", type:"…"}` on success; `{executed:false, error:"compile_error", message:"…"}` (HTTP 422) on Roslyn compile failure; `{executed:false, error:"scripting_unavailable"}` if the scripting assembly isn't loaded yet (rare: auto-loads on first engine compile). |

**When to reach for `execute_csharp`** vs the alternatives:

- "Does `Scene.GetAllComponents<X>().Count()` return what I expect?" → `execute_csharp` (one shot)
- "Will this snippet compile against the engine?" → `compile_snippet` (no execution)
- "What does the AST of this expression look like?" → `parse_syntax_tree`
- Need to use a one-off namespace? → `imports: "Sandbox.UI,Editor.MapEditor"`. Default imports already cover most cases.

**Caveats**: `execute_csharp` runs arbitrary C# in the editor: it's the most powerful tool in the bridge. The trust boundary is the localhost-only listener (no remote origin can hit it). Compiled assemblies accumulate in the AppDomain; for batch eval, prefer one call with multiple statements over many round-trips.

## Asset browser navigation

Drive the editor's main Asset Browser dock: folder navigation, view mode, refresh, asset focus, filter pins. Every tool takes an optional `scope` arg (`local` default \| `mounts`); `cloud` is **not supported** because `CloudAssetBrowser` is a separate widget that doesn't share the `AssetBrowser` API surface (no `NavigateTo` / `OpenParentFolder` / `ViewModeType` / `FocusOnAsset`).

| Tool | What it does |
|---|---|
| `asset_browser_get_current_folder(scope?)` | Path of the folder currently shown. Returns `path: null` if nothing loaded. |
| `asset_browser_navigate(path, scope?, add_to_history?)` | Navigate to a project-relative folder. `add_to_history` defaults to true. |
| `asset_browser_open_parent(scope?)` | Navigate one folder up. |
| `asset_browser_set_view_mode(mode, scope?)` | Switch view mode: `List` \| `SmallIcons` \| `MediumIcons` \| `LargeIcons`. |
| `asset_browser_refresh(scope?)` | Force a rescan + repopulate (F5 equivalent). |
| `asset_browser_focus_on_asset(path, scope?)` | Reveal + select an asset; navigates to its folder first. |
| `asset_browser_add_pin(filter, scope?)` | Add a filter pin (search expression like `type:material` or `@vmdl_gibs`). |

## Console (engine log, not the dock widget)

| Tool | What it does |
|---|---|
| `tail_log(n?, min_level?, since_seq?)` | Recent log entries from the addon's ring buffer. `since_seq` lets you poll incrementally. |
| `print_log(message, level?, tag?)` | Push a message into the editor console (so the user sees what you're doing). |
| `clear_log_buffer` | Clear the addon's tail buffer (does not affect the editor's own Console widget). |

## Auto-generated (`auto_*`)

The addon walks the schema for methods carrying `[Editor.MenuItem]`, `[Editor.Tool]`, `[Shortcut]`, `[ConCmd]` and registers one MCP tool per match. **Naming has two forms: see gotcha**: `auto_list` returns the canonical identity `auto:<TypeFullName>.<MethodName>` (with `:` and `.`), but the MCP-exposed tool name uses underscores: `auto_<TypeFullName>_<MethodName>` (because `:` and `.` are illegal in MCP tool names). Both forms are accepted by the bridge dispatcher; the deferred tools list shows the underscore form.

| Tool | What it does |
|---|---|
| `auto_list` | List the auto-generated tools currently registered (returns 19 instances at time of writing: Editor.EditorScene CRUD, Sandbox.Game screenshots, EnvmapProbe/IndirectLightVolume/NavMesh `BakeAll`, CloudAsset.InstallSingle). |
| `auto_register` | Re-scan the schema and register new wrappers (idempotent). |
| `auto_<Type>_<Method>` | Invoke that editor command. Static methods only in v1; instance methods return `not_implemented`. Conceptual identity is `auto:<Type>.<Method>`; pass the underscore form when calling. |

## UI Discovery

Read-only inspection of every user-facing UI element. Use these when you need to know what the user can click before deciding what to do for them.

| Tool | What it does |
|---|---|
| `list_docks` | Every registered dockable panel: name, icon, current visibility/title/type, screen rect. Pair with `activate_dock` and `editor_highlight`. |
| `list_menus(target?)` | Every `[Menu]`-registered menu item under the bar (default target `Editor`): path, icon, priority, shortcut, declaring type. Pair with `invoke_menu`. |
| `list_shortcuts` | Every `[Shortcut]`: identifier, default key binding, group, type, declaring method. Pair with `invoke_shortcut`. |
| `list_widgets(query?, limit?)` | Every named/title-bearing Widget under the editor main window. Filter by Name / WindowTitle / type FullName substring. |
| `find_widget(target)` | Resolve an identifier (`dock:Name | menu:Path | shortcut:id | widget:Name | type:FullName | bare fuzzy text`) to a single Widget; returns kind, type, screen rect, visibility. |
| `get_focused_widget` | Whatever has keyboard focus right now. |

## UI Drive

The agent does what the user would do: clicks tabs, fires menus, types text, runs commands. Always main-threaded.

| Tool | What it does |
|---|---|
| `activate_dock(name)` | Raise a dock tab so it's visible and focused. |
| `set_dock_visible(name, visible)` | Show or hide a dock tab. For `DeleteOnClose` docks (most editor docks) hiding destroys the widget; reopening reconstructs it. Distinct from `activate_dock` (which assumes the dock already exists and just raises it). |
| `invoke_menu(target?, path)` | Fire the action behind a `[Menu]` item by path. Same effect as the user clicking the menu: silent (no cascade animates). |
| `menu_open(path)` | **Visually** open a menu cascade so the user sees it animate (e.g. `'File'` or `'File/Recent Scenes'`). Does NOT trigger the action: pair with `invoke_menu` if you also want the action. Use for "show me where File→New is" style answers. |
| `menu_close` / `menu_list_path(path)` | Programmatic menu-state control. `menu_list_path` resolves a path and reports which submenus / option items exist along the chain: use to validate a path before invoking it. |
| `invoke_shortcut(identifier)` | Fire a `[Shortcut]` by identifier (e.g. `editor.save`). Same effect as pressing the bound keys: and the recommended way to do modified shortcuts (the engine doesn't expose a way to synthesize `KeyEvent`). |
| `click_widget(target)` | Synthetic click. `Button.Clicked` is invoked directly when applicable; other Widgets get `OnMouseClick` via reflection. |
| `focus_widget(target)` | Give a Widget keyboard focus. |
| `send_keys(target?, keys[])` | Send named KeyCodes (`Return`, `Tab`, `Up`, etc.) via `Widget.PostKeyEvent`, or insert literal text via `LineEdit.Insert` / `TextEdit.PlainText`. Single-char inputs are treated as text; multi-char inputs that parse as `KeyCode` are treated as named keys. For modified shortcuts, use `invoke_shortcut`. |
| `run_console_command(command)` | Run anything through s&box's editor console (`ConsoleSystem.Run`). The fallback for things not exposed via `[Menu]`/`[Shortcut]`. |

## Inspector / widget input writes

When `set_property` doesn't apply: custom widgets, transient inspectors, popup dialogs, Hammer side-panels: write through the widget directly. These bypass the SerializedObject undo pipeline so they don't show up in the Undo list; use `set_property` first when the field is inspector-bound to a `[Property]`.

| Tool | What it does |
|---|---|
| `set_input_text(target, value, append?)` | LineEdit / TextEdit / ComboBox edit field. Default REPLACES; `append=true` adds to end. For typing into the currently-focused widget without resolving a target, prefer `send_keys`. |
| `set_color(target, value)` | Any widget exposing `Value`/`Color`/`BackgroundColor`/`Tint`/`BorderColor`. Value is `{r,g,b,a}` 0 to 1 floats OR `'#RRGGBB'`/`'#RRGGBBAA'` hex string. |
| `set_checkbox(target, value)` | Checkbox/toggle Button/anything with bool `Value`/`Checked`/`IsChecked`/`Selected`/`IsActive`. Value is `true`/`false` OR `'On'`/`'Off'`/`'Partial'` for tri-state CheckState. |
| `set_slider_value(target, value)` | FloatSlider native; falls back to reflection on IntegerSlider/FloatSpin/custom controls. Auto-coerces float/int/double/decimal; clamps to widget range when known. |
| `select_dropdown_option(target, by, value)` | ComboBox. `by='text'` (visible string) or `by='index'` (zero-based int). Fires the ComboBox's `ItemChanged` event. |
| `set_widget_value(target, value)` | Universal: figures out the right path based on widget type. Use when you don't know whether the target is a checkbox/dropdown/slider. For inspector-bound `[Property]` fields prefer `set_property` (undo support). |
| `widget_drag(target, from, to, steps?)` | Synthetic mouse drag. Resolves widget; calls `OnMousePress` at `from` (local widget coords), interpolates `steps` `OnMouseMove` events, then `OnMouseRelease` at `to`. **Best-effort**: some widgets reject Qt synthetic events because Qt's `MouseEvent` ctor is internal. For sliders prefer `set_slider_value`; for gizmos prefer `batch_transform`. |
| `inspect_widget(target)` | Deep reflection dump: every property with current value, every Action/event field (wired or not), every declared method signature. Use to discover what an unfamiliar widget can do BEFORE driving it. |
| `get_widget_state(target)` | Current state: value/text/enabled/visible/focused plus type-specific fields (ComboBox `count`/`current_index`, FloatSlider `min`/`max`/`step`, etc.). Use to verify after an interaction. |

## Tree, tabs, file dialogs

Specialized widget drivers for the three Qt collection-widget types that don't fit the generic `set_*` family.

| Tool | What it does |
|---|---|
| `tree_list_items(target)` | Dump a TreeView / BaseItemWidget as nested JSON: per-item name, type, selection state, expansion state, children. Use to discover available paths before driving selection or expansion. |
| `tree_expand_node(target, path)` / `tree_activate_item(target, path)` | Expand a node by name path / fire an item's activation. |
| `tree_select_item(target, path)` / `tree_select_items(target, paths[])` / `tree_unselect_all(target)` | Set selection by path(s). |
| `tab_list_pages(target)` | Names of every page in a `TabWidget` / `VerticalTabWidget` + which is current. Discover names to feed `tab_select`. |
| `tab_select(target, name_or_index)` | Activate a tab page. |
| `pick_file(mode, title?, dir?, filter?)` | Spawn a modal FileDialog asking the user to pick a file or directory. **BLOCKS** until they accept or cancel. Returns selected path or null. `mode`: `open_existing` / `open_any` / `save` / `directory`. |
| `file_dialog_status` | Whether a FileDialog is currently visible + its title / current directory / selected file. |
| `file_dialog_set_path(path)` | Pre-fill the open FileDialog with a path. Combine with `_accept` to submit programmatically. |
| `file_dialog_accept` / `file_dialog_cancel` | Submit / dismiss the active FileDialog. |

## UI Highlight (visual guidance)

Spotlight a UI element with a speech bubble: the answer to "where is X?". The overlay dims everywhere except the target rect, draws a glow border, shows your message, and auto-dismisses (or click anywhere to dismiss). **Lead with `spotlight`** for any "find / locate / point out / show me" request: it's the friendliest answer and supports multi-stop tours.

| Tool | What it does |
|---|---|
| `spotlight(target?, message?, sequence?, pulse?, duration_ms?)` | Visual point-this-out overlay. **Two modes**: (a) **single**: pass `target` + `message`; (b) **tour**: pass a `sequence` array of `{target, message, dwell_ms}` stops and the spotlight steps through them automatically. `pulse:true` makes the glow throb (use sparingly: high-attention variant). |
| `editor_highlight(target, message, duration_ms?)` | Older basic single-stop variant. Same UX, simpler API. Default duration 8000ms. Auto-raises a hidden dock if that's what was targeted. Reach for this only when you don't need tour mode. |
| `editor_dismiss_highlight` | Clear the active highlight now. |
| `highlight_status` | Is one currently active? |

## Editor Preferences

Read + write every property on `Editor.EditorPreferences`: themes, notification settings, hotload behavior, etc. Bypasses the lack of `[Menu]`/`[Shortcut]` attributes on these surfaces.

| Tool | What it does |
|---|---|
| `list_preferences` | Every public static property: name, declared type, current value, `[Description]`/`[Title]` text, enum values when applicable. |
| `get_preference(name)` | Read one. |
| `set_preference(name, value)` | Write one; JSON coerced to declared type. Returns previous + current. |
| `list_changed_preferences` | Per-property: name, type, current value, the resolved cookie key (extracted by IL-walking the getter), backing store (`cookie` \| `convar` \| `unknown`), and whether the cookie key is currently present (i.e. the property has been set away from default). Also returns the full set of cookie keys stored in `EditorCookie`. |
| `reset_preference_to_default(name)` | Remove a cookie-backed property's underlying key so the next get returns the literal default. Errors with `409 not_cookie_backed` for ConVar-backed properties (e.g. `FastHotload`). |
| `export_preferences` | Dump every readable property as `{name: value}`. Suitable as input to `import_preferences`. |
| `import_preferences(values, strict?)` | Apply `{name: value}` to `EditorPreferences`. Each value is JSON-coerced to declared type (incl. enum name/value/object). Returns per-key applied/skipped/failed counts; `strict=true` aborts on first failure. |

## Dock layout presets

Save + restore the editor's full dock layout (every dock's position, size, visibility) as named presets. Persisted to the editor cookie store under `ClaudeSbox.DockPreset.<name>` so they survive editor restarts.

| Tool | What it does |
|---|---|
| `save_dock_layout_as_preset(name)` | Snapshot `DockManager.State` JSON under the given name. Overwrites if it exists; reports `overwrite=true`. |
| `load_dock_layout_preset(name)` | Apply a saved preset; triggers `OnLayoutLoaded`. |
| `list_dock_layout_presets` | Every saved preset (name + state JSON byte length). |
| `delete_dock_layout_preset(name)` | Remove a saved preset. |

## Undo / Redo

Programmatic control over the active edit session's undo stack.

| Tool | What it does |
|---|---|
| `undo(steps?)` | Pop entries off the back stack and apply. Returns the names that were undone. |
| `redo(steps?)` | Same for the forward stack. |
| `list_undo_history(limit?)` | Both stacks: name, timestamp, locked-flag per entry. |
| `undo_to_checkpoint(name, match?, max_steps?, case_insensitive?)` | Pop entries off the back stack until one matching `name` is found and applied (inclusive). `match` is `exact` (default) / `prefix` / `substring`. Pre-checks reachability: errors with the available names if the checkpoint isn't on the stack rather than partially undoing. |

## Asset operations (CRUD)

Beyond `find_asset` / `list_assets`. Complements the auto-generated wrappers: these surfaces don't go through `[Menu]`/`[Shortcut]`.

| Tool | What it does |
|---|---|
| `register_asset_file(absolute_path)` | Make the editor track an existing file as an asset. |
| `create_resource(type, absolute_path)` | Create a new `.scene` / `.prefab` / `.vmat` / etc. |
| `compile_resource(path, text)` | Compile (validate + serialize) source text for a resource. |
| `rename_asset(path, new_name)` | Rename file + tracked references. |
| `move_asset(path, target_directory, overwrite?)` | Move into a different folder. |
| `copy_asset(path, target_directory, overwrite?)` | Duplicate. |
| `delete_asset(path)` | Send to OS recycle bin. |
| `reveal_asset_in_explorer(path)` | Open OS file manager focused on the asset. |
| `open_asset(path)` | Open in the asset's default editor (programmatic double-click). |

## Compile pipeline (drive + introspect)

Drive the C# compile pipeline plus query its state without triggering a fresh build.

| Tool | What it does |
|---|---|
| `compile_project(project_ident?)` | Compile a project end-to-end; awaits completion; returns errors/warnings + log tail. Long-running. Prefer `start_compile_project_job` for non-blocking flows. |
| `wait_for_compiles` | Block until all in-flight compiles finish. |
| `generate_solution` | Regenerate the .sln (for external IDEs to pick up new addons). |
| `compile_check_build_state(project_ident?)` | Non-blocking snapshot: per-compiler IsBuilding/NeedsBuild/BuildSuccess + diagnostic counts. Returns immediately. |
| `compile_get_diagnostics(project_ident?, severity?, limit?)` | Errors + warnings from the most recent compile, structured: severity, file, line, column, code, message. Doesn't trigger a new compile. |
| `compile_list_compilers(project_ident?)` | The two compilers attached to a project (game + editor): name, assembly name, build state, output size + version, generated-code size. |
| `compile_get_assembly_output(project_ident?, compiler?)` | Last `CompilerOutput` summary: success, version, has-XML-doc flag, assembly bytes (count, not the bytes themselves), exception. |
| `compile_mark_for_recompile(project_ident?, compiler?)` | Mark a compiler dirty so the next cycle treats it as needing full rebuild. Doesn't compile by itself. |

### Async job pattern

For long ops where blocking is unworkable, spawn a job and poll:

| Tool | What it does |
|---|---|
| `start_compile_project_job(project_ident?)` | Kick off compile asynchronously; returns `job_id` immediately. |
| `poll_job(job_id, log_tail?)` | State of any started_*_job: status (pending/running/completed/failed/cancelled), progress, log tail, result on completion. |
| `cancel_job(job_id)` | Request cancellation. Honor depends on the underlying op. |
| `list_jobs(filter?, limit?)` | Enumerate jobs by filter (`active` (default) / `running` / `completed` / `failed` / `cancelled` / `all`). Auto-prunes after 30 minutes idle. |

## Hotload pipeline

Introspection of the live `Sandbox.Hotload` instance (reached via `GameInstanceDll.PackageLoader.HotloadManager.Hotload`).

| Tool | What it does |
|---|---|
| `hotload_get_last_result` | TypeTimings (per-type instance counts + ms), ProcessorTimings, errors, warnings from the most recent hotload. |
| `hotload_list_queued_assembly_swaps` | Pairs of (outgoing → incoming) assemblies queued for the next reload. |
| `hotload_get_outgoing_assemblies` | Names of "old" assemblies in pending swaps. |
| `hotload_check_assembly_ignored(assembly)` | Is this assembly in the upgrader's ignore list (its fields skipped during upgrade)? |
| `hotload_get_upgrader_status` | Every registered IInstanceUpgrader + its initialization state. |
| `hotload_get_trace_settings` / `hotload_set_trace_settings(trace_paths?, trace_roots?, include_type_timings?, include_processor_timings?)` | Read/write the four diagnostic flags. |

## Reflection / introspection (`reflection_*`)

Live `EditorTypeLibrary` walks for code-reasoning beyond what `schema_*` exposes. All read-only.

| Tool | What it does |
|---|---|
| `reflection_find_types_with_attribute(attribute, limit?)` | Every type tagged with a given attribute (`GameResource`, `Library`, `Expose`, etc.). Resolves attribute name short or fully-qualified. |
| `reflection_find_methods_with_attribute(attribute, inherit?, limit?)` | Same but for methods (`Menu`, `Shortcut`, `Event`, …). |
| `reflection_find_properties_with_attribute(attribute, limit?)` | Same for properties (`Property`, `Range`, `Group`, …). |
| `reflection_find_types_by_base_type(base_type, limit?)` | Every type assignable to a given base/interface: backed by `EditorTypeLibrary.GetTypes<T>()`. |
| `reflection_get_type_hierarchy(type, include_derived?)` | Bases up to System.Object + interfaces + direct subclasses for a type. |
| `reflection_get_member_metadata(type, member, kind?)` | Full Display metadata: Title, Description, Icon, Group, Order, Tags, Aliases, Attributes, ReadOnly, IsStatic. Different from `schema_signature` (doc-comment view). |
| `reflection_list_members_by_tag(type, tag)` | Members whose `[Tags(...)]` attribute contains a given tag. |
| `reflection_get_enum_values(type)` | All enum values: name, integer value, title, icon, group, description, browsable. |
| `reflection_get_method_signature(type, method)` | Engine-side method signature (parameters, return type, IsStatic, IsPublic, IsAsync) plus Display metadata. |
| `reflection_get_property_descriptor(type, property)` | Property type, CanRead/CanWrite, IsStatic, IsPublic, attributes. |
| `reflection_get_field_descriptor(type, field)` | Field type, IsStatic, IsPublic, ReadOnly, attributes. |
| `reflection_get_intrinsic_types` | The engine's whitelisted intrinsic System types: primitives, collection generics, math types. |
| `reflection_get_type_ident(type)` | Integer ident the engine assigns to a type (caching/serialization key). |
| `reflection_get_member_identity(type?, member?, ident?)` | Forward (type+member → ident) or reverse (ident → type+member) lookup. |
| `reflection_list_attribute_names(filter?, limit?)` | Every Attribute subclass declared in any loaded assembly. Use to discover before `find_types_with_attribute`. |
| `reflection_parse_attribute_metadata(attribute)` | An attribute's shape: constructors, properties, fields, AttributeUsage targets. |
| `reflection_find_resource_types_with_extension(extension)` | `[GameResource]` types whose Extension matches (e.g. `'png'` → `Sandbox.TextureResource`). |

## Asset native operations (`asset_query_*` / `asset_render_*` / `asset_*_in_memory_override`)

Walk the asset dependency graph, query compile state, render thumbnails, override source data in memory.

| Tool | What it does |
|---|---|
| `asset_query_state(path)` | Combined snapshot: IsCompiled, IsCompiledAndUpToDate, IsCompileFailed, HasSourceFile, HasCompiledFile, CanRecompile, IsDeleted, IsTrivialChild, HasUnsavedChanges, HasCachedThumbnail. |
| `asset_query_dependencies(path, deep?, sides?, limit_per_side?)` | Three sets: references (assets I depend on), dependants (assets depending on me), parents (assets owning me). Each side supports deep (transitive) or shallow. |
| `asset_compilation_control(path, mode, full?, timeout_seconds?)` | Trigger compile. `mode`: `compile` (full or incremental) / `compile_if_needed` (no-op if up-to-date, async). |
| `asset_set_in_memory_override(path, data)` / `asset_clear_in_memory_override(path)` | Replace asset's source data with an in-memory string for live-prototyping without disk writes. |
| `asset_render_thumbnail(path, save_to)` | Render the asset's preview thumbnail to disk as PNG. Useful for export/documentation. |
| `asset_rebuild_thumbnail(path, start_build?)` | Invalidate cached thumbnail and re-render asynchronously. |
| `asset_get_additional_files(path)` | Auxiliary files the asset packages with itself (content + game-side). |
| `asset_get_input_dependencies(path)` | Source-file inputs the asset compiler reads. Strong change-detection signal. |
| `asset_get_unrecognized_references(path)` | Paths the asset references that the asset system can't resolve (broken links). |
| `asset_delete_orphans` | Walk every Asset and remove ones whose backing files no longer exist. Returns count. |
| `asset_record_opened(path)` | Mark recently-opened. Updates the LastOpened timestamp without actually opening. |

## Qt widget interop (`widget_*` / `splitter_*`)

Beyond `find_widget` / `click_widget` / `focus_widget`. Drive geometry, visibility, opacity, capture.

| Tool | What it does |
|---|---|
| `widget_get_geometry(target)` | Comprehensive geometry: LocalRect, ScreenRect, position, size, content margins, plus visibility / enabled / focus flags. |
| `widget_set_geometry(target, x?, y?, width?, height?)` | Atomic move + resize. Each param optional. |
| `widget_set_visible(target, visible?, mode?)` | Show / hide; for top-level windows, `mode` accepts `show`/`hide`/`minimize`/`maximize`/`normal`. |
| `widget_set_enabled(target, enabled)` | Enable or disable input on a widget. |
| `widget_set_tooltip(target, text)` / `widget_set_window_title(target, title)` | Mutate hover-text or top-level title. |
| `widget_set_opacity(target, opacity)` | Window opacity 0..1 on a top-level window. |
| `widget_set_focus_policy(target, policy)` | `no` / `tab` / `click` / `strong` / `wheel`. |
| `widget_query_state(target)` | Bundle of common state flags: Enabled, Visible, IsActiveWindow, IsFocused, WindowTitle, ToolTip, runtime type. |
| `widget_capture_to_png(target, save_to)` | Render a widget's current visual state to a PNG on disk. |
| `splitter_save_state(target)` / `splitter_restore_state(target, state)` | Serialize/restore a Splitter's children, sizes, orientation. |

## Modeldoc / Animgraph native

Native introspection of the bundled model + animation editors.

| Tool | What it does |
|---|---|
| `modeldoc_get_session_model` | Path of the model currently open in the ModelDoc editor session. |
| `modeldoc_refresh_game_data` | Reload game data into ModelDoc: equivalent to its 'Refresh Game Data' menu item. |
| `animgraph_get_preview_model` | Path of the model in the AnimGraph preview pane. |
| `animgraph_set_preview_model(path)` | Switch the AnimGraph preview pane to a different model. |

## Event bus (`last_*` / `wait_for_*`)

Subscribe to the engine's `EditorEvent` bus. **28 events** tracked (verified live), each with a `last_*` snapshot tool and a `wait_for_*` blocking tool, plus 6 composite tools that collapse semantically related events.

### Tracked events (each gets `last_<event>` + `wait_for_<event>`)

Scene lifecycle: `scene.play`, `scene.startplay`, `scene.stop`, `scene.beforesave`, `scene.saved`, `scene.session.save`.

Compile / hotload / content: `compile.shader`, `open.shader`, `hotloaded`, `content.changed`, `refresh`, `localaddons.changed`, `tools.gamedata.refresh`.

Editor lifecycle: `app.exit`, `editor.created` (fires once on cold boot, payload = main window type), `editor.preferences`, `keybinds.update`.

Package: `package.changed`, `package.changed.installed`, `package.changed.favourite`, `package.changed.rating`.

Hammer: `hammer.initialized` (Hammer subsystem ready), `hammer.selection.changed` (payload = `selection_size=N`), `hammer.mapview.contextmenu` (right-click in a viewport, payload = `mapview_id=<hash>`).

Asset browser: `asset.contextmenu` (right-click on asset row), `asset.nativecontextmenu` (asset native context menu opened, payload = asset path), `assetsystem.openpicker` (asset-picker dialog requested), `folder.contextmenu` (right-click on folder).

| Tool pattern | What it does |
|---|---|
| `last_<event>()` | Most-recent firing of the event (timestamp + payload + fire count), or `has_fired: false` if it hasn't fired this session. |
| `wait_for_<event>(timeout_ms?)` | Block (default 5000ms, max 60000) until the event fires next. Returns either the fire details or `expired: true`. |
| `list_tracked_events` | Catalog of every tracked event with current snapshot summary. |

Note: `.` in event names is replaced with `_` in tool names: e.g. `wait_for_scene_play`, `last_package_changed_installed`.

### Composite event tools

Higher-level, semantically-grouped:

| Tool | What it does |
|---|---|
| `wait_for_scene_state(target, timeout_ms?)` | Wait for the scene state machine to reach a target state. States: `playing` (scene.play / scene.startplay), `stopped` (scene.stop), `saving` (scene.beforesave), `saved` (scene.saved / scene.session.save). Comma-separated multi-state targets accepted. |
| `wait_for_asset_ready(path, timeout_ms?)` | Wait for an asset's compile pipeline to settle: fires on compile.shader, content.changed for matching path, or hotloaded. |
| `wait_for_content_change(pattern?, timeout_ms?)` | Wait for any `content.changed` event whose filename matches a substring (empty for any). |
| `wait_for_editor_ready(subsystem?, timeout_ms?)` | Wait for an editor subsystem to settle. `subsystem`: `addons` / `typelib` / `hotload` / `all` (default). |
| `wait_for_package_action(action?, timeout_ms?)` | Wait for `install` / `favourite` / `rating` (or `any`) package interaction. |

## Console introspection

Structured access to the engine's console system (the underlying `ConVarSystem` is internal).

| Tool | What it does |
|---|---|
| `list_concmds(filter?, include_hidden?, limit?)` | Every registered ConCmd with name, help, server/admin/cheat/protected/hidden flags. |
| `list_convars(filter?, include_hidden?, limit?)` | Every registered ConVar with current value, default, min/max, replication / save / cheat flags. |
| `get_convar(name)` | Read a ConVar's current value. |
| `set_convar(name, value, force?)` | Write a ConVar's value. `force=true` allows protected vars (use sparingly). |
| `console_help(name)` | Help text registered for a command or convar. |

## Project expansions

Beyond `get_active_project` / `list_projects` / `list_addons`.

| Tool | What it does |
|---|---|
| `set_active_project(ident)` | Switch `Project.Current` programmatically. Triggers UpdateCompiler: may begin a compile. |
| `list_project_dependencies(ident?, recursive?)` | Direct package + editor references + mounts; with `recursive=true`, transitive resolution via `Project.All`. |
| `query_project_metadata(ident?, key?)` | Read keys/values from `ProjectConfig.Metadata`. Single-key lookup or full dict. |
| `validate_project(ident?)` | Sanity-check a project: paths exist on disk, every PackageReference resolves, no `Broken` flag. Read-only. |

## Editor state: Gizmo

`Gizmo.Settings` is a public static accessor returning the active `SceneSettings`.

| Tool | What it does |
|---|---|
| `get_gizmo_state` | Snapshot: edit mode, view mode, space, snap toggles + increments, gizmo scale, enabled state. |
| `set_gizmo_mode(mode)` | Switch edit mode: `position` / `rotation` / `scale`. Equivalent to W/E/R. |
| `set_gizmo_space(space)` | `world` or `local` space. |
| `set_gizmo_view_mode(view_mode)` | `3d` / `2d` / `ui`. |
| `set_gizmo_snap_settings(snap_to_grid?, snap_to_angles?, grid_spacing?, angle_spacing?)` | Configure snapping. Each param optional; omitted ones aren't changed. |
| `set_gizmo_scale(scale)` | Visual size multiplier (0 to 2). |
| `set_gizmos_enabled(enabled)` | Master enable/disable for all gizmos. |
| `set_gizmo_enabled_for_type(type, enabled)` / `is_gizmo_enabled_for_type(type)` | Per-type opt-out. |
| `clear_gizmo_disabled_types` / `list_gizmo_disabled_types` | Reset / inspect the per-type disable list. |

## Persistent cookies (cross-session memory)

Useful as the agent's own memory between sessions, scoped per-user or per-project.

| Tool | What it does |
|---|---|
| `cookie_get(scope, key)` | Read. `scope` is `editor` (per-user) or `project` (per-project). |
| `cookie_set(scope, key, value)` | Write any JSON. |
| `cookie_delete(scope, key)` | Set to null. |
| `cookie_namespace` | Returns the recommended `claude-sbox.` prefix to avoid collisions with engine cookies. |

## Selection refinements

| Tool | What it does |
|---|---|
| `add_to_selection(ids)` | Add without clearing. |
| `remove_from_selection(ids)` | Remove specific ids. |
| `toggle_selection(ids)` | XOR ids in/out. |
| `select_by_component_type(component_type, additive?)` | Replace selection with every GameObject in the scene that has a Component of the given type. Multi-strategy type resolution (short / Sandbox.-prefixed / fuzzy). |
| `select_by_tag(tag, additive?)` | Replace selection with everything tagged. |
| `select_children(id, recursive?, additive?)` | Branch selection. |
| `deselect_all` | Clear the editor's current selection. No-op if empty. |
| `invert_selection` | Replace the selection with every non-ignored GameObject in the active scene that is NOT currently selected. Walks the full hierarchy, skips `(MCP IGNORE)` / `mcp_ignore`. |
| `get_selection_bounds` | World-space AABB enclosing every currently-selected GameObject. Returns `mins`/`maxs`/`center`/`size` as `.x/.y/.z` plus per-object rows. Uses `GameObject.GetBounds()` (`IHasBounds` walk). |
| `get_scene_bounds(include_ignored?)` | World-space AABB over every non-ignored GameObject in the active scene. Slow on large scenes. |
| `find_gameobject_by_path(path, case_insensitive?)` | Resolve a slash-separated name path (e.g. `"World/Player/Camera"`) to a GameObject. Reports ambiguity when multiple GameObjects share a name at any segment. Honors `mcp_ignore`. |

## Hammer / ModelDoc (specialized editors)

Status + control for s&box's bundled level editor (Hammer) and model editor (ModelDoc). Hammer's selection set is **separate** from the scene editor's selection: same engine, different selection manager: so don't confuse `hammer_*` selection tools with `get_selection` / `set_selection`. For richer editing, the auto-generated wrappers expose every `[Menu]` and `[Shortcut]` item registered by these editors.

### Status / map

| Tool | What it does |
|---|---|
| `hammer_status` | Is Hammer open? What map / current material? |
| `hammer_reload_map` | Reload the active map from disk, discarding unsaved changes. |
| `hammer_set_material(path)` | Set Hammer's brush-paint material. |
| `modeldoc_status` | Is ModelDoc open? What model is loaded? |
| `open_model_in_editor(path)` | Open a `.vmdl` in ModelDoc. |

### Hammer selection

| Tool | What it does |
|---|---|
| `hammer_get_selection(include_keyvalues?, limit?)` | Current Hammer selection: SelectMode + every selected MapNode (name, type, position, classname for entities, optional `targetname`/`model` keyvalues). |
| `hammer_clear_selection` | Clear the selection set. |
| `hammer_select_all` | Select every node in the active map. Honors current SelectMode. |
| `hammer_invert_selection` | Invert the current selection. |
| `hammer_set_select_mode(mode)` | Switch SelectMode: `Groups` \| `Objects` \| `Meshes` \| `Verticies` \| `Edges` \| `Faces`. |
| `hammer_get_pivot` | Read `Selection.PivotPosition` (where rotate/scale gizmos centre). |
| `hammer_set_pivot(x, y, z)` | Move the pivot: useful for rotating around a custom point. |
| `hammer_select_objects_using_asset(path)` | Append every map node referencing this asset (model/prefab/etc.) to the selection. |
| `hammer_select_faces_using_material(path)` | Switch SelectMode to Faces and select every face painted with this material. |
| `hammer_assign_asset_to_selection(path)` | Apply an asset (model on entities, material on faces, etc.) to the current Hammer selection. |
| `hammer_show_entity_report(path)` | Open Hammer's Entity Report dialog filtered to entities referencing this asset. |

## Procedural mesh editing (level blockout)

Operates on `Sandbox.MeshComponent` + `Sandbox.PolygonMesh`. Useful when the user says "box me a 256x256 floor here".

| Tool | What it does |
|---|---|
| `mesh_create_block(name?, position?, size?, material?, parent_id?)` | Create a new GameObject with a procedural box MeshComponent. Through editor undo. |
| `mesh_get_info(id)` | Vertex/face count, bounds, collision mode, color. |
| `mesh_set_face_material(id, triangle, material)` | Paint a single triangle. |
| `mesh_rebuild(id)` | Force-rebuild a MeshComponent's renderable mesh. |

## Model inspection (`model_*`)

Query model files (`.vmdl`) for bodygroups, bones, attachments, hitboxes, and LODs.
All take a `path` parameter (e.g. `models/citizen/citizen.vmdl`), not `model`.

| Tool | What it does |
|---|---|
| `model_get_info(path)` | Poly count, bounds, mesh count, material count. |
| `model_list_body_groups(path)` | Bodygroup layout: per-group name, bitmask, and per-choice name + mask. See `references/bodygroups.md` for the citizen model table. |
| `model_list_bones(path)` | Bone hierarchy with parent indices. |
| `model_list_attachments(path)` | Attachment point names and transforms. |
| `model_list_hitboxes(path)` | Per-hitbox bone, min/max bounds. |
| `model_list_lods(path)` | LOD levels with poly counts. |
| `open_model_in_editor(path)` | Open the model in the ModelDoc editor. |

## Code editor (drive the user's IDE)

| Tool | What it does |
|---|---|
| `code_editor_status` | Which IDE is configured, is it installed, current title. |
| `open_file_in_code_editor(path, line?, column?)` | Jump to a specific line/column in the user's IDE. The natural counterpart to "I just edited this file at line 42". |
| `open_solution_in_code_editor` | Open the project `.sln`. |
| `open_addon_in_code_editor(ident)` | Open a specific addon's solution. |

## NodeGraph / ActionGraph / ShaderGraph

Discovery, inspection, and mutation of the user's visual-script graphs. Mutation tools DO ship; use them sparingly and prefer letting the user open the graph editor for substantial changes.

**Scope — ActionGraph & ShaderGraph only.** `nodegraph_*` operates on managed `Editor.NodeEditor.IGraph` + `GameResource` assets. It does **not** work on Animation Graphs (`.vanmgrph`): that editor is native C++ and `AnimationGraph` is a native-handle `Resource`, so it exposes no `IGraph`. For animgraphs use the **Animgraph source** tools below.

**Lazy node-type registration**: `nodegraph_list_node_types` only returns nodes registered by currently-open graph editors. Open an `.action` first to see ActionGraph node types; open a `.shdrgraph` to see ShaderGraph node types. Without an open editor of the matching kind, expect ~1 result (`Common Nodes/No Operation` reroute). See gotchas.

| Tool | What it does |
|---|---|
| `nodegraph_list_node_types(query?, limit?)` | Every `INodeType` currently registered. Lazy: see note above. |
| `nodegraph_inspect(path)` | Open a `.actiongraph` / `.shdrgraph` / etc., return node count + connection count + per-type histogram. Read-only. |
| `nodegraph_serialize(path)` | Dump the graph's nodes as JSON for diffing or analysis. |
| `nodegraph_find_node_by_name(path, query, limit?)` | Substring search on node Identifier or DisplayInfo.Name. |
| `nodegraph_get_pin_types(path, node_identifier)` | Single node's inputs + outputs with name, type, current connection target. |
| `nodegraph_validate_graph(path)` | Reports unreachable nodes, node ErrorMessages, plug ErrorMessages, plus DFS-based cycle detection. |
| `nodegraph_create_node(path, type, position?)` / `_delete_node(path, node_identifier)` | Mutate node set. |
| `nodegraph_connect_pins(path, from_node, from_pin, to_node, to_pin)` / `_disconnect_pin(path, node, pin)` | Mutate connections. |
| `nodegraph_set_node_position(path, node_identifier, position)` / `_set_node_size(path, node_identifier, size)` / `_set_reroute_comment(path, node_identifier, comment)` | Layout / annotation. |
| `nodegraph_save(path)` | Persist mutations to disk. Without this, edits are in-memory only. |
| `shadergraph_list_parameters(path)` | Public material parameters surfaced by a ShaderGraph. |

## Animgraph source (read + edit `.vanmgrph`)

Inspect and edit Animation Graphs by their KV3 source, since the editor is native and `nodegraph_*` can't reach it. Reads go through the engine `KeyValues3ToJson` bridge (with the leading `<!-- kv3 ... format:animgraph2 -->` header stripped, which the parser requires); edits mutate an in-memory JSON DOM and are written back as KV3 by a serializer that preserves the header verbatim and int/float typing, then recompiled via `AssetSystem.CompileResource`. Editing is **session-based**: `_load` once, mutate, then `_verify` / `_save`.

| Tool | What it does |
|---|---|
| `animgraph_source_inspect(path)` | Read-only structure: nodes (id/class/name/position), class histogram, resolved input connections, parameters (name/type/id/default), and state machines — each transition's conditions resolved to **parameter names**. This is how you find which transition or sequence node drives a given animation (e.g. a weapon draw). |
| `animgraph_source_serialize(path, max_length?)` | Raw KV3→JSON of the whole graph. |
| `animgraph_list_node_classes(path?, query?, node_only?, max_files?)` | Catalog of native `C*AnimNode` classes with occurrence counts, an example asset, and the union of property keys — harvested from `.vanmgrph` on disk. Use to discover node types/fields before adding/cloning. |
| `animgraph_edit_load(path)` | Open an editing session (parse source → mutable DOM). |
| `animgraph_edit_verify(path)` | Non-destructive: serialize the session to KV3 and re-parse it; confirms validity (node/param counts) **before** saving. |
| `animgraph_edit_save(path, dry_run?, backup?)` | Serialize → back up to `<file>.bak` → write → recompile. `dry_run:true` reports the KV3 + verifies without writing. |
| `animgraph_edit_discard(path)` | Drop the session, abandoning unsaved edits. |
| `animgraph_set_node_property(path, node_id, property, value)` | Set a node member (JSON value), e.g. `m_sequenceName`, `m_sName`, `m_bLoop`, `m_playbackSpeed`. |
| `animgraph_connect(path, to_node_id, from_node_id, input_field?, from_output?)` / `animgraph_disconnect(path, node_id, input_field?)` | Wire/clear a node input (`m_inputConnection` default; `m_inputConnection1/2`, `m_baseInput`, … via `input_field`). |
| `animgraph_add_node(path, template_node_id? | template_class?+template_from_path?, position?, name?, properties?)` | Add a node by cloning a template (so required fields/defaults are valid) with a fresh unique id. |
| `animgraph_delete_node(path, node_id)` | Remove a node and clear any input connections that referenced it. |
| `animgraph_set_transition_disabled(path, state_machine_id, state_id, dest_state_id, disabled)` | Toggle a state-machine transition's `m_bDisabled`. Disabling the edge into a state stops that state (e.g. a draw) from being entered via it — a permanent fix the per-frame game params can't override. |

## Action graph metadata (read + write)

Targeted CRUD on `.action` assets through the public `Sandbox.ActionGraphs.ActionGraphResource` API: Title / Description / Category / Icon plus the full serialized graph as JSON. Complements the read-only generic NodeGraph tools above. We deliberately don't drive the editor's `ActionGraphView` (it lives in a separate addon claude-sbox doesn't reference); `open_asset(path)` opens the editor through the asset's default-editor pipeline.

| Tool | What it does |
|---|---|
| `actiongraph_list(path_prefix?, limit?)` | Every `.action` asset, with title / description / category / icon. |
| `actiongraph_get_metadata(path)` | Single asset's title / description / category / icon. |
| `actiongraph_set_metadata(path, title?, description?, category?, icon?)` | Write any of the four; persists via `Asset.SaveToDisk(GameResource)`. Errors `graph_uninitialized` if the resource has no `Graph` yet (open it in the editor once first). |
| `actiongraph_export_json(path, indented?)` | Return the asset's `SerializedGraph` as a JSON string: same shape stored on disk, ready for diffing or external tooling. |

## Notifications, clipboard, mounts, sound, camera

Smaller user-facing surfaces.

| Tool | What it does |
|---|---|
| `notify(message, level?, title?)` | Pop an editor toast (the same channel compile/hotload notifications use). Honors NotificationPopups preference. |
| `clipboard_copy(text)` | Put text into the OS clipboard. |
| `clipboard_paste` | Read OS clipboard. |
| `list_mounts` | Mounted game-content sources (CSS, GMod, etc.). |
| `set_mounted(name, mounted)` | Mount/unmount a content source. |
| `refresh_mount(name)` | Reload its asset metadata. |
| `play_asset_sound(path)` | Preview a sound asset. |
| `stop_asset_sound` | Stop preview. |
| `get_editor_camera` | Active session's scene-view camera position/rotation/fov. |
| `set_editor_camera(position?, rotation_euler?, fov?)` | Position the scene-view camera. Omit fields to keep current. |
| `get_editor_window_bounds` | Editor main window's screen-space bounds (`x`, `y`, `width`, `height`), DPI scale, and snapshot of focused + hovered widget identity. Useful for positioning agent overlays. |
| `query_mouse_state` | Snapshot of input state at call time: cursor position (scaled + unscaled), cursor delta, wheel delta, mouse-button mask, keyboard-modifier flags, plus `IsKeyDown` for Shift/Control/Alt/Meta. |

## Calling pattern

A typical "write code" session:

```
sbox_status                                 # confirm connected
get_active_project                          # know where you are
docs_search { query: "razor panels" }       # find usage docs
docs_get { path: "ui/razor-panels" }        # read the page
schema_search_members { query: "BuildHash" }# pin signatures
schema_signature { fullname: "Sandbox.UI.PanelComponent", member: "BuildHash" }
```

A typical "where is X?" session (the user wants visual guidance):

```
docs_search { query: "asset browser" }      # narrative grounding
find_widget { target: "Asset Browser" }     # confirm the target resolves
spotlight {
  target: "dock:Asset Browser",
  message: "It's the panel here at the bottom: drag any .vmat / .vmdl / .scene in to use it."
}
# or for a multi-step tour:
spotlight {
  sequence: [
    { target: "menu:File", message: "Open the File menu", dwell_ms: 2000 },
    { target: "menu:File/New Scene", message: "Click New Scene to start", dwell_ms: 3000 }
  ]
}
```

A typical "do it for me" session:

```
list_menus                                  # what's available
invoke_menu { path: "File/New Scene" }      # do it
# or:
list_shortcuts                              # find the right id
invoke_shortcut { identifier: "editor.save" }
```

If a method you'd reference doesn't appear in `schema_*`, **don't write it**: assume it doesn't exist.

If the user asks "where do I X?" and you can resolve it, **prefer `spotlight` over a wall of text**: the visual answer is faster and clearer. Use tour mode (`sequence: [...]`) when the answer needs more than one stop.

If the user asks "do X for me" and there's a corresponding `[Menu]`/`[Shortcut]`, **prefer `invoke_menu` / `invoke_shortcut`** over composing low-level scene mutations: those are what the user would have hit anyway, and they go through the same undo/notification paths.

## Capability discovery

This file documents the tool families with a UX or correctness story worth elaborating. **For everything else**: the ~597 tools the bridge exposes, including subsystems trimmed from this doc to keep it scannable (`host_*`, `prefab_*`, `gameobject_*` lifecycle, `add_physics`/`_collider`/`_joint`, `create_*` scaffolders, `debug_draw_*`, `scene_trace_*`, `rigidbody_*`, `navmesh_*`, `anim_*`, `sound_*`, `particle_*`, `dispatcher_*`, Roslyn devtools, `find_*` cross-ref, `language_*`, `material_*`, `mapview_*`, `mapentity_*`, `hammer_node_*`, `audio_*`, `shader_*`, `game_*`, `vr_*`, `account_*`, project publishing, and more): see `tool-families.md` for a one-liner discovery index. Grep that file for a topical keyword first; reach for `list_tools` only when neither file mentions the family you need.
