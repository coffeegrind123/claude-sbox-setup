---
name: sbox-live
description: Use when working in an s&box (Facepunch's Source 2 game engine) project: writing or editing C# components/Razor panels/scenes, debugging editor behavior, or interacting with the live editor through the claude-sbox in-editor MCP server. Trigger on `using Sandbox;`, `: Component`, `[Property]`, `[Sync]`, `[Rpc.Broadcast]`, `PanelComponent`, `*.razor`, `*.scene`, `*.prefab`, `*.sbproj`. Also trigger when editing files under `~/sbox-public/` or any folder named `addons/`. Replaces and supersedes the third-party `sbox` skill.
---

# sbox-live: live s&box integration skill

This skill is one half of the **ClaudeSbox ↔ s&box deep integration**. The other half is the in-editor tool addon (`ghage/claude-sbox` on sbox.game) that hosts an MCP server on port 6790 and exposes editor introspection / control to you.

When you're in an s&box context you have **ground-truth docs pipelines** (live, no snapshots) plus **live editor introspection + drive**. The full capability map — all 13 buckets with their exact tool surfaces (schema, first-party + community + hosted docs, scene/inspector, UI drive, spotlight, preferences, reflection, compile/hotload + `execute_csharp` REPL, asset/cloud/event-bus, gizmo/convars/Qt, filesystem reads) — lives in `references/mcp-tools.md` § *Capability map*. The essentials you should keep in mind on every prompt:

**Docs ground-truth, in layering order** (default; deviate only when the user pinned a layer):

1. **Ground first** with `schema_search_members(query)` / `schema_lookup_type(fqn)` — confirms the symbol exists in *this* build and pins the canonical FQN, per-parameter types, and return type. The local schema (`Facepunch.AssemblySchema` over the editor's loaded DLLs) is stricter than any CDN snapshot. If `connected=false`, skip to step 2 (local prose still works).
2. **Narrative** with `docs_search(query)` → `docs_get(path)` for first-party Facepunch prose (lifecycle, RPC semantics, networking visibility).
3. **Community fallback** with `learn_search(query)` / `learn_search(topic:"…", difficulty:"Beginner")` when official docs don't cover it — faceted (difficulty/topic/tags/rating).
4. **Real-world usage** with `codesearch_search(symbol)` → `codesearch_get_file(hit.source_url)` — searches the source of *every open-source package* on sbox.game for actual call sites (not signatures/prose). Plain REST (`public.facepunch.com/sbox/code/search/1/`) — no driver/install. **Queries leave the machine** — skip for private-source identifiers. See `references/mcp-tools.md` § Code search.

Shortcut: a one-line concept ("RPC visibility rules") → start at 2; verifying a call you're about to write → run 1 alone (schema is ground truth); "how does anyone actually *use* this?" → 4.

**Live editor drive** (editor running + bridge connected): start with **`editor_state`** (one-call mode/scene/project/capability snapshot) and gate mode-dependent tools on its result; **`doctor`** is the session-opener readiness roll-up. Everything user-facing is reachable. The principle: **anything the user can do in the editor, you can do** — if you can't find a tool, try `list_menus`/`list_shortcuts` (almost everything is registered there), then `run_console_command` as the universal escape hatch. Reach for `references/tool-families.md` to answer "is there a tool for X?" across ~730 tools, and `references/mcp-tools.md` for per-subsystem detail.

If `sbox_status` reports `connected=false`, the editor isn't running or the bridge can't reach `host.docker.internal:6790`. Fall back to the schema/docs pipelines (which still work without the editor) and the references below.

## How to respond to common asks

- **"where is X?"** → don't lecture. Resolve via `find_widget` or `list_docks`/`list_menus`, then call `spotlight` with a one-sentence message. The user sees the highlight; you confirm in chat with one line. For multi-step answers ("how do I find the Asset Browser AND open a vmat from there"), use `spotlight`'s tour mode (`sequence: [...]`).
- **"do X for me"** → if X has a `[Menu]` entry, prefer `invoke_menu`. If `[Shortcut]`, prefer `invoke_shortcut`. They go through the same code path the user's manual click would, so notifications/undo behave naturally. Reach for low-level scene mutations only when there's no menu/shortcut.
- **"how do I X?"** → `docs_search` for the prose explanation, `spotlight` for the visual answer (tour mode if multi-step), then offer to do it for them.
- **"set my editor to X"** → `list_preferences` to find the property, `set_preference` to apply.
- **"is there a tool for Y?"** → grep `references/tool-families.md` first (curated one-liner index over ~730 bridge tools). Reach for `list_tools` only if the family isn't there.
- **session opener** → call `doctor` once. It returns a structured pass/warn/fail roll-up plus a single `next_suggested_action` so you don't have to ping/sbox_status/compile_check_build_state/list_unsaved_scenes individually.
- **"do four things in a row"** → use `dispatcher_batch`. Each op runs through the normal dispatcher (own LogCapture window); refer to earlier results via `{"$ref": "alias.path"}`. Saves agent turns and roundtrips.
- **runtime bug you can't reproduce** (no WASD/mouse injection) → have the user reproduce and freeze in the bad state, then read component fields with `get_property` (ground truth beats guessing). Read a per-tick value like `Velocity` **twice** — if it's byte-identical, that component isn't ticking (disabled / inactive / proxy / paused); `get_components` shows the `enabled` flags. See `references/gotchas.md` "Live runtime debugging".

## Routing: when to read which file

| If the user is asking about… | Open this reference file |
|---|---|
| Translating a Unity pattern to s&box | `references/unity-translation.md` |
| The Ten Rules of s&box (lifecycle, networking, async) | `references/ten-rules.md` |
| Common gotchas (namespace surprises, signature traps, set_property coercion — bool/Vector3/float/asset-handles now work, runtime-only props no-op in edit mode, bone GET=world vs SET=model space, Components.Get skips disabled, live runtime debugging, screenshot location, codesearch/news REST + privacy (queries leave the machine) and the forum-only Chromium driver lifecycle, auto_* naming, widget_drag rejections) | `references/gotchas.md` |
| Bodygroups: hiding/showing body parts on models (e.g. citizen) | `references/bodygroups.md` |
| Find &/or "watch" a tutorial **video** (a YouTube link, or "find a video on X") | `references/watch-video.md`. `youtube_search(query)` to discover (keyless), then `youtube_watch(input)` (MCP): transcribe + frame-per-caption → a viewing package in the game folder. First time → `youtube_install`. Then Read `watch.md` + `frames/` from the game folder (use the returned `output_dir_game_relative`). |
| Inspecting/editing an **animation graph** (`.vanmgrph`): find what drives an animation, disable a state-machine transition, change a node's sequence, add/connect nodes | Don't read a file: `animgraph_source_inspect(path)` to map nodes/connections/parameters/state-machines, then the `animgraph_edit_*` session tools (`_load` → mutate → `_verify` → `_save`) + `animgraph_set_node_property` / `animgraph_set_transition_disabled` / `animgraph_connect` / `animgraph_add_node`. Operates on the KV3 source — **not** `nodegraph_*` (that's ActionGraph/ShaderGraph only). See `references/tool-families.md` § Animation. |
| Live MCP tools you can call (curated, with usage stories) | `references/mcp-tools.md` |
| "Is there a tool for X?": discovery index across all ~730 bridge tools | `references/tool-families.md` |
| Which s&box doc area + which tool families cover a domain (Scene/Code/Editor/Assets/Graphics/UI/Gameplay/Networking/Services), and the non-negotiable engineering rules / quality gates | `references/nine-categories.md` |
| Driving an open file dialog or spawning a modal file picker | Call `pick_file` (modal blocking) or `file_dialog_*` (drive an already-open dialog) |
| Driving a tree widget (asset browser tree, scene hierarchy, etc.) | Call `tree_list_items` to discover paths, then `tree_select_item` / `_expand_node` / `_activate_item` |
| Driving a tab page widget | Call `tab_list_pages` then `tab_select` |
| Filling an inspector input that doesn't have a `[Property]` (custom widget, popup dialog) | Call `set_input_text` / `set_color` / `set_checkbox` / `set_slider_value` / `select_dropdown_option`; `set_widget_value` for universal "I don't know the type"; `inspect_widget` to discover surface first |
| The exact signature of a method, property, field | Don't read a file: call `schema_signature` |
| Researching a symbol or API you're about to call (full pipeline) | Layer the queries: `schema_search_members` / `schema_signature` → `docs_search` → `learn_search` as a fallback → `codesearch_search` for real call sites. See top-of-file recipe. |
| How to use a system (RPC, Razor, Editor Tools, Hammer) | Don't read a file: call `docs_search` then `docs_get`; fall back to `learn_search` for community walkthroughs |
| "Show me how someone built X" / a beginner walkthrough / a community tutorial | Don't read a file: call `learn_search(query)` or `learn_search(difficulty: "Beginner", topic: "UI")`. Faceted; tutorials carry difficulty / topic / tags / rating. Pair with `learn_get(path)` for the body. |
| Find a tutorial **video** by topic, or "watch" a **YouTube link** | Don't read a file (until details needed): `youtube_search(query: "<topic>")` (keyless discovery → ranked videos), then `youtube_watch(input: "<url>")` — transcribes (yapsnap) + a frame per caption → a viewing package in the game folder; first use → `youtube_install`, diagnose with `youtube_status`. Then Read `watch.md` + `frames/*.jpg` from the game folder (the result's `output_dir_game_relative`). Full detail: `references/watch-video.md`. |
| "How does anyone actually *use* this API?" / find real call sites across published code | Don't read a file: call `codesearch_search(symbol)` (every open-source package's source), then `codesearch_get_file(hit.source_url)` for full context. Plain REST — no install. Queries leave the machine. See `references/mcp-tools.md` § Code search. |
| Browse / read a specific open-source package's source tree | Don't read a file: `codesearch_list_files(org, package)` to enumerate, then `codesearch_get_file(org, package, file)` for any file. |
| "What's the community saying about X" / find a forum thread / read a bug report or announcement | Don't read a file: `forum_search(query)` for the site's own index (older/specific threads), or `forum_list_categories` → `forum_browse_category(slug)` for recent threads, then `forum_read_thread(url)` for the posts. Forum is the only Chromium-driver family — first use → `codesearch_install_driver` (`forum_driver_outdated` → `force:true` + restart). Queries leave the machine. See `references/mcp-tools.md` § Community forum. |
| "What changed in the last update" / when did an API land or change / is this a known issue | Don't read a file: call `release_notes(limit?)` for recent update posts (each with titled `sections`), or `release_notes(version: "26.05")` to filter. Plain REST (`/news/platform`) — no driver. See `references/mcp-tools.md` § Release notes. |
| Disambiguating a short type name to a fully-qualified one | Don't read a file: call `schema_search_members` (local) |
| Discovery: "which types implement X", "every method tagged Y" | Don't read a file: call `reflection_find_types_with_attribute` / `reflection_find_methods_with_attribute` / `reflection_get_type_hierarchy` |
| Synchronizing with editor lifecycle (compile finished? scene saved? hotload happened?) | Don't read a file: call `wait_for_<event>` (or composites: `wait_for_scene_state`, `wait_for_asset_ready`, `wait_for_editor_ready`) |
| "Is the editor ready? What should I do first?": single-call readiness probe | Don't read a file: call `doctor`. It rolls up listener / dispatcher / active scene / compile state / playing tabs / unsaved scenes / recent engine errors and returns `next_suggested_action`. |
| Chaining multiple tool calls in one turn (create → reparent → add component → set property, etc.) | Don't read a file: call `dispatcher_batch` with `operations: [{ key, tool, args }]` and `{"$ref": "alias.path"}` substitutions. Up to 50 ops, sequential. |
| Placing a `.vmdl` upright (the model's "up" axis is wrong) | Set the orientation once with `orientation_override_set`; subsequent `drop_asset_into_scene` calls auto-apply it. `orientation_override_get`/`_list` to inspect. |
| "What does `<expression>` evaluate to in the editor right now?": live C# REPL | Don't read a file: call `execute_csharp(code)`. `System` / `System.Linq` / `Sandbox` / `Editor` are auto-imported; pass `imports` for extras. Useful for "what's the active scene's GameObject count", "does this LINQ query return what I expect", "what's the current value of `EditorPreferences.<X>`". |
| "Find me a model/material/sound from the s&box library": cloud asset workflow | `asset_search(query)` → pick an ident → `asset_fetch(ident)` for full metadata → `asset_mount(ident)` to install. The default `pin_to_project:true` appends the ident to `.sbproj` `PackageReferences` so it auto-mounts on next session; pass `false` for one-session-only. `asset_unpin(ident)` removes the pin without unmounting the running session. |

## Anti-hallucination rule

Before you write a method call, attribute, or component lifecycle method that you haven't seen verified in *this* session, **call `schema_signature` or `schema_lookup_type` to confirm it exists**. Hallucinated APIs is the #1 failure mode in s&box code generation; the live schema fixes it for free.

For attribute-driven discovery (e.g. "which types are `[GameResource]`s?", "every method tagged `[Menu]`", "what does `[Range]` actually store?"), reach for `reflection_find_types_with_attribute` / `reflection_find_methods_with_attribute` / `reflection_parse_attribute_metadata`: these are richer than `schema_*` because they walk relationships, not just signatures.

If `sbox_status` reports `connected=false` and you can't call `schema_*` / `reflection_*`, fall back to `references/unity-translation.md` and `references/ten-rules.md` for the highest-frequency anti-patterns.

## Editing live state

When the user asks you to change a value in the inspector ("set the player speed to 250", "disable the second component"), prefer the MCP tools over editing the `.scene` JSON by hand:

1. `get_selection` to see what's selected.
2. `get_components(id)` to enumerate.
3. `set_property(id, component_index, name, value)`: runs through the editor's undo scope, so the user sees a normal undoable change. Handles every common type — `bool` (`true`/`false`), numbers, `Vector3`/`Color` (`{x,y,z}`/`{r,g,b,a}`), enum-by-name, and **asset handles** (pass a content-path string for a `Model`/`Material`, e.g. `"models/dev/box.vmdl"`). **Always verify**: the response includes `previous` and `current`. If they're equal, either the write missed or the property is **runtime-only** (e.g. `Rigidbody.Velocity` no-ops in edit mode) — confirm with `get_property` and, for runtime props, test in Play.

When the user asks you to *write* code, prefer `Read`/`Edit`/`Write` against the bind-mounted source tree (your cwd is the s&box project root), then call `recompile` (when implemented) or tell the user to trigger a hot-reload.

## Believe the user about what's on screen

When the user tells you what they observe in the running game — "there is no HUD",
"the font isn't showing", "the digits are cut off", "it works now" — **treat it as ground
truth and act on it directly.** Do NOT take screenshots to verify or contradict them. The
bridge generally **cannot** capture the in-game UI reliably (`screenshot_scene_to_file`
excludes screen-space panels; widget capture of the 3D viewport returns blank), so a
screenshot is more likely to mislead than confirm — and re-checking what the user just told
you wastes their time and erodes trust. Reason about the cause from their description, make
the fix, and ask them to confirm. Use screenshots only when the user hasn't said what they
see and you have no other signal — never to second-guess an explicit statement.

## What you should NOT do

- Don't suggest `MonoBehaviour`, `Awake`, `Start`, `Update`, `[SerializeField]`. See `references/unity-translation.md` for the s&box equivalents.
- Don't use `System.IO.File`, `System.Console`, `System.Net.Http.HttpClient`, raw sockets: they're sandbox-blocked. Use `FileSystem.Data`, `Log`, `Http`.
- Don't write `Physics.Raycast(...)`. Use `Scene.Trace.Ray(...)` builder. (Rule 6.)
- Don't write coroutines (`IEnumerator`, `yield return`). Use `async Task` + `await Task.DelaySeconds(n)`. (Rule 8.)
- Don't `using` a namespace you haven't verified exists. The sandbox blocks unknown namespaces at compile time.

## What you absolutely should do

- Mark gameplay classes `sealed`. (Rule 1.)
- Use `protected override void On*()` for all lifecycle. (Rule 2.)
- Tag inspector fields `[Property]`. (Rule 3.)
- Tag networked state `[Sync]`, guard with `if ( IsProxy ) return;`. (Rules 4 to 5.)
- Run a `schema_search_members` whenever you're tempted to guess. The schema *is* ground truth.
