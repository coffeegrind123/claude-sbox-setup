---
name: sbox-live
description: Use when working in an s&box (Facepunch's Source 2 game engine) project: writing or editing C# components/Razor panels/scenes, debugging editor behavior, or interacting with the live editor through the claude-sbox in-editor MCP server. Trigger on `using Sandbox;`, `: Component`, `[Property]`, `[Sync]`, `[Rpc.Broadcast]`, `PanelComponent`, `*.razor`, `*.scene`, `*.prefab`, `*.sbproj`. Also trigger when editing files under `~/sbox-public/` or any folder named `addons/`. Replaces and supersedes the third-party `sbox` skill.
---

# sbox-live: live s&box integration skill

This skill is one half of the **ClaudeSbox ↔ s&box deep integration**. The other half is the in-editor tool addon (`ghage/claude-sbox` on sbox.game) that hosts an MCP server on port 6790 and exposes editor introspection / control to you.

When you're in an s&box context, you have access to **three ground-truth pipelines** (live, no snapshots):

1. **Live API schema**: locally built from the editor's loaded assemblies via `Facepunch.AssemblySchema`. Strictly more accurate than any CDN snapshot because it reflects the exact engine + addon DLLs the user is running. Use the `schema_*` MCP tools to look up exact, doc-commented signatures for every public type/method/property/field/attribute.
2. **Live prose docs**: Facepunch/sbox-docs repo (CC-BY-4.0) + `sbox.game/llms.txt` fallback, cached and BM25-indexed by the MCP server. Use the `docs_*` MCP tools for narrative usage docs.
3. **Hosted structured docs** (`sdocs_*`): third-party Meilisearch proxy at `sdocs.suiram.dev` exposing 9 tools for symbol resolution, per-method overload details, examples, and related guides. Distinct from `docs_*`: returns structured per-symbol metadata + ranked hits + per-method per-parameter type/doc breakdowns. **Queries leave the machine**: for symbol names lifted from private project source, prefer `schema_*` + `docs_*`. See `references/mcp-tools.md` § Hosted structured docs and gotchas.

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

If `sbox_status` reports `connected=false`, the editor isn't running or the bridge can't reach `host.docker.internal:6790`. Fall back to the schema/docs pipelines (which still work without the editor) and the references below.

## How to respond to common asks

- **"where is X?"** → don't lecture. Resolve via `find_widget` or `list_docks`/`list_menus`, then call `spotlight` with a one-sentence message. The user sees the highlight; you confirm in chat with one line. For multi-step answers ("how do I find the Asset Browser AND open a vmat from there"), use `spotlight`'s tour mode (`sequence: [...]`).
- **"do X for me"** → if X has a `[Menu]` entry, prefer `invoke_menu`. If `[Shortcut]`, prefer `invoke_shortcut`. They go through the same code path the user's manual click would, so notifications/undo behave naturally. Reach for low-level scene mutations only when there's no menu/shortcut.
- **"how do I X?"** → `docs_search` for the prose explanation, `spotlight` for the visual answer (tour mode if multi-step), then offer to do it for them.
- **"set my editor to X"** → `list_preferences` to find the property, `set_preference` to apply.
- **"is there a tool for Y?"** → grep `references/tool-families.md` first (curated one-liner index over ~593 bridge tools). Reach for `list_tools` only if the family isn't there.
- **session opener** → call `doctor` once. It returns a structured pass/warn/fail roll-up plus a single `next_suggested_action` so you don't have to ping/sbox_status/compile_check_build_state/list_unsaved_scenes individually.
- **"do four things in a row"** → use `dispatcher_batch`. Each op runs through the normal dispatcher (own LogCapture window); refer to earlier results via `{"$ref": "alias.path"}`. Saves agent turns and roundtrips.

## Routing: when to read which file

| If the user is asking about… | Open this reference file |
|---|---|
| Translating a Unity pattern to s&box | `references/unity-translation.md` |
| The Ten Rules of s&box (lifecycle, networking, async) | `references/ten-rules.md` |
| Common gotchas (namespace surprises, signature traps, silent set_property failures, sdocs privacy, auto_* naming, widget_drag rejections) | `references/gotchas.md` |
| Bodygroups: hiding/showing body parts on models (e.g. citizen) | `references/bodygroups.md` |
| Live MCP tools you can call (curated, with usage stories) | `references/mcp-tools.md` |
| "Is there a tool for X?": discovery index across all ~593 bridge tools | `references/tool-families.md` |
| Driving an open file dialog or spawning a modal file picker | Call `pick_file` (modal blocking) or `file_dialog_*` (drive an already-open dialog) |
| Driving a tree widget (asset browser tree, scene hierarchy, etc.) | Call `tree_list_items` to discover paths, then `tree_select_item` / `_expand_node` / `_activate_item` |
| Driving a tab page widget | Call `tab_list_pages` then `tab_select` |
| Filling an inspector input that doesn't have a `[Property]` (custom widget, popup dialog) | Call `set_input_text` / `set_color` / `set_checkbox` / `set_slider_value` / `select_dropdown_option`; `set_widget_value` for universal "I don't know the type"; `inspect_widget` to discover surface first |
| The exact signature of a method, property, field | Don't read a file: call `schema_signature` |
| How to use a system (RPC, Razor, Editor Tools, Hammer) | Don't read a file: call `docs_search` then `docs_get`; or `sdocs_search_docs` for ranked structured hits + `sdocs_get_related_guides` for workflow pages |
| Disambiguating a short type name to a fully-qualified one | Don't read a file: call `sdocs_resolve_symbol` (hosted) or `schema_search_members` (local) |
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
3. `set_property(id, component_index, name, value)`: runs through the editor's undo scope, so the user sees a normal undoable change. **Always verify**: the response includes `previous` and `current` values. If they're equal, the change didn't take: follow up with `get_property` to confirm.

When the user asks you to *write* code, prefer `Read`/`Edit`/`Write` against the bind-mounted source tree (your cwd is the s&box project root), then call `recompile` (when implemented) or tell the user to trigger a hot-reload.

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
