# claude-sbox-setup

Setup scripts, engine patches, Claude Code companion skill, MCP bridge, and reference docs for the **claude-sbox** s&box editor addon ([sbox.game/ghage/claude-sbox](https://sbox.game/ghage/claude-sbox)).

The addon itself is a compiled tool package published to sbox.game. This repo holds everything around it: the engine patches that have to be applied to the sbox-public tree, the `.bat` / `.ps1` helpers, the companion `sbox-live` Claude Code skill, the Node MCP bridge, and the package marketing assets.

---

## Quick start

You need a working [sbox-public](https://github.com/Facepunch/sbox-public) checkout (`git clone --recursive https://github.com/Facepunch/sbox-public`).

**1. Clone this setup repo into `game/addons/`** of your sbox-public checkout:

```sh
cd <sbox-public>/game/addons/
git clone https://github.com/coffeegrind123/claude-sbox-setup.git
```

**2. From the new `claude-sbox-setup/` directory, apply the engine patches and rebuild:**

```powershell
.\Setup.bat
.\Bootstrap-And-Capture.bat
```

`Setup.bat` applies the engine patches to the parent sbox-public tree and verifies them; idempotent — re-run after any `git pull` on sbox-public. `Bootstrap-And-Capture.bat` is a wrapper around upstream's `Bootstrap.bat` that detects and stops any process holding `game/bin/managed/*.dll` open (lingering sbox-dev, VBCSCompiler, MSBuild, the dotnet build server, etc.) before the managed-DLL rebuild starts, so you don't hit the `MSB3021: ...being used by another process` cascade.

**3. Launch the editor and seed the addon:**

```powershell
..\..\sbox-dev.exe
```

Open any project (a fresh `my_project` is fine), open the developer console, and run **once, ever**:

```
package_install ghage.claude-sbox tools
```

That's the one-time install step. Patch 0004 (the cloud auto-mount) snapshots the downloaded package files into `<sbox-public>/game/.sbox-global/cloud/.bin/`. From here on, every editor restart on every project automatically copies that global snapshot back into the per-project cache before mounting — no redownload, works offline.

The in-editor MCP host comes up automatically on `http://127.0.0.1:6790`.

### Connecting Claude Code

Two transports work. Pick whichever your client supports.

**HTTP (easiest, no bridge needed):**

```sh
claude mcp add --transport http -s user sbox http://127.0.0.1:6790/mcp
```

(or `http://host.docker.internal:6790/mcp` if you run Claude Code inside a devcontainer)

**Stdio bridge** (for clients that don't speak the HTTP transport, or that prefer subprocess MCP servers):

The bridge ships pre-built at `bridge/dist/bridge.js`. It's a single self-contained file (Node 20+, no `node_modules` at runtime).

```sh
# Linux / Mac / WSL (run from this repo's root)
claude mcp add --transport stdio -s user sbox node "$(pwd)/bridge/dist/bridge.js"

# Windows PowerShell
claude mcp add --transport stdio -s user sbox node "$PWD\bridge\dist\bridge.js"
```

To rebuild the bridge from source: `cd bridge && bun install && bun run build` (or use the equivalent npm + tsc flow).

Other MCP clients (Claude Desktop, Cline, etc.) can connect via the HTTP/SSE transports on port 6790, or via the stdio bridge above. See [Two channels](#two-channels) for the full surface.

### Installing the companion skill

The `skill/` directory holds the `sbox-live` workflow skill — routing guidance for the MCP tools, common gotchas, anti-hallucination rules, and Unity-to-s&box translation tables. Copy it into your user-scope Claude skill directory so it auto-loads on s&box prompts:

```sh
# Linux / Mac / WSL
mkdir -p ~/.claude/skills && cp -r skill ~/.claude/skills/sbox-live

# Windows PowerShell
New-Item -ItemType Directory -Force "$HOME/.claude/skills" | Out-Null
Copy-Item -Recurse skill "$HOME/.claude/skills/sbox-live"
```

### Engine patches: what gets applied

Setup applies ten patches to your sbox-public tree (all reversible, all shipped in `patches/` for inspection):

1. **`Project.Static.cs`**: adds the addon to the engine's built-in addon list **if** a source clone is present at `game/addons/claude-sbox/`. Source-clone branch only; the sbox.game-install flow (the common case) gets auto-load from patch 4 instead.
2. **`DownloadPublicArtifacts.cs`**: dedupes manifest entries by destination path. Fixes an upstream race where parallel artifact downloads fight over the same file when a manifest contains duplicate-path entries (causes confusing "being used by another process" failures during `Bootstrap.bat`).
3. **`Utility.Projects.Compile.cs`**: enables publish-compile support for tool-type projects so the addon can be packaged through the editor's publish pipeline.
4. **`StartupLoadProject.cs`**: auto-mounts `ghage.claude-sbox` on every project load from a global cache at `<sbox-public>/game/.sbox-global/cloud/.bin/`, so one-time `package_install ghage.claude-sbox tools` makes the addon available for every project, every editor restart, with no redownload (size-matched pre-stage skips the `.cll` download). Also adds `ghage.claude-sbox` to the `required` set inside `RefreshCloudAssets` so cross-project eviction can't wipe the addon's per-project cache. Scoped to `ghage.claude-sbox` only; all other cloud packages keep the engine's default per-project cache behaviour.
5. **`Utility.Projects.Compile.cs`** (second block — patch 3 hits the same file in a different spot): skips the unconditional `"editor"` `IgnoreFolders` entry at publish-compile time when the project type is `"tool"`. Facepunch's publish path strips the `editor` folder from compile input — correct for game/library addons (where `Code/Editor/` holds editor-only inspectors that shouldn't ship to players) but actively wrong for tool addons, which are ENTIRELY editor code and almost always namespaced under `Editor.<X>` with all source under `Code/Editor/`. Without this patch the publisher silently strips the whole codebase, packs only `Code/Imports.cs` into the `.cll`, and produces an empty (~1 KB) package that mounts with no `[Event]` handlers. Maintainers-only — only matters if you're republishing the addon, not for installing it.
6. **`Utility.Projects.Compile.cs`** (third block in the same file, inside patch 3's `if Type == "tool"` branch): adds the explicit assembly references the in-editor compile already provides for tool projects — `Sandbox.Tools`, `Sandbox.Compiling`, Roslyn (`Microsoft.CodeAnalysis(.CSharp)`), `Facepunch.ActionGraphs`, `SkiaSharp`, plus net / process / registry / memory bits, and `AddToolBaseReference()` so `Editor.TreeView` / `AssetBrowser` / `ToastWidget` resolve. The publish-compile was missing all of these, so tool publishes failed with hundreds of "type or namespace not found" errors. `Project.Compiling.cs:109-122` is the in-editor mirror this restores. Maintainers-only.
7. **`Utility.Projects.Compile.cs`** (fourth block, immediately after the CompileGroup is constructed): sets the publish CompileGroup's `ReferenceProvider` so cross-package references like `package.toolbase` (from patch 6's `AddToolBaseReference`) can resolve via `PackageManager.ActivePackages.Lookup`. In-editor compile groups get a provider from their owning `ActivePackage`; the publish CompileGroup is fresh and doesn't, so `AddToolBaseReference` throws `"Couldn't find reference package.toolbase"` without this. Maintainers-only.
8. **`Utility.Projects.Compile.cs`** (fifth block, same area): nulls out `compileGroup.AccessControl` for tool-type publishes. The whitelist restricts game/library publishes to a curated API surface (no `Process`, `File`, `HttpClient`, raw `Editor.*` types) — correct for sandboxed runtime content where users may install untrusted code, but actively wrong for tool addons, which by design need full editor + .NET access. The in-editor compile never applies the whitelist; the publish path was the only place enforcing it. Without this patch tool publishes fail with ~700 "is not allowed when whitelist is enabled" errors. Game/library publishes still enforce the whitelist normally. Maintainers-only.
9. **`PackageManager.ActivePackage.cs`** (cloud-mount counterpart to patch 8): nulls out `group.AccessControl` inside `CompileCodeArchive` when `Package.TypeName == "tool"`. This is the path users without a local source clone hit — `package_install ghage.claude-sbox tools` (or the engine auto-mount from patch 4) downloads the `.cll`, then `CompileCodeArchive` compiles it on the user's machine to load the addon. Without this patch, the user's compile hits the same whitelist wall as patch 8 fixes for the publisher, and the addon fails to load with "Whitelist violation(s), build unsuccessful". `Project.Compiling.cs:56` already sets `Whitelist=false` for source-clone-loaded tool projects; this patch mirrors that behaviour into the cloud-mount path. End-user-facing — every cloud-install user needs this patch applied.
10. **`PackageLoader.cs`** (the second consumer-side whitelist gate, after patch 9): extends the "skip access control for tool assemblies" exemption to remote (cloud-mounted) tool packages. Patch 9 fixed the COMPILE-time whitelist; patch 10 fixes the DLL-LOAD-time whitelist that runs immediately after compile in `LoadAssemblyFromPackage`. Facepunch's original code gates the skip behind `ap.Package is LocalPackage` with a comment saying "This is used for tool packages which are ALWAYS local" — so cloud tool addons trip the check. Without this patch, the consumer's mount fails with hundreds of "Whitelist Error: X is not allowed when whitelist is enabled" PLUS "Couldn't resolve 'Microsoft.CodeAnalysis.CSharp / Facepunch.ActionGraphs / ...'" errors from `AccessControl.VerifyAssembly`'s metadata walker. Bypassing the whitelist via `TrustUnsafe` skips both. End-user-facing — pairs with patch 9 to make cloud-installed tool addons actually load.

### Updating sbox-public

When you pull upstream sbox-public, the engine files revert to their pristine state. The easiest path is `.\Safe-Pull.bat` (also from this directory):

```powershell
cd game\addons\claude-sbox-setup
.\Safe-Pull.bat
```

That snapshots your tracked-file edits and addon source (if you have one) to `.backups/<timestamp>/`, runs `git pull` on sbox-public, then re-applies the ten engine patches in one pass and verifies their post-pull markers. If you'd rather do it by hand:

```powershell
cd <sbox-public>
git pull
cd game\addons\claude-sbox-setup
git pull       # update setup repo itself
.\Setup.bat    # re-apply engine patches (idempotent)
```

Power users with their own multi-patch workflows can refer to `patches/*.patch` directly and integrate them into their own `git apply` flow.

### Bootstrap fails with "file is being used by another process"

The recommended path is `.\Bootstrap-And-Capture.bat` (shown in Quick start) — it integrates the lock-detect/kill step before the managed-DLL rebuild so this failure mode is handled automatically.

If you ran the plain upstream `Bootstrap.bat` and it bailed with `MSB3021: Unable to copy ...Sandbox.Engine.dll`, run `Prepare-Bootstrap.bat` from this repo manually to detect and kill the lock holders, then retry:

```powershell
cd game\addons\claude-sbox-setup
.\Prepare-Bootstrap.bat        # interactive: lists holders, prompts before stopping
.\Prepare-Bootstrap.bat -Yes   # non-interactive variant for scripts
```

Pass `-Dry` to see what would be killed without touching anything. The script only stops well-known holder process names (sbox-dev, VBCSCompiler, MSBuild, csc, dotnet build-server); if a lock persists after running it, use Sysinternals `handle64.exe -nobanner <path>` against the specific DLL to find an unusual holder (Explorer window with `game\bin\managed` focused, an antivirus mid-scan, etc.).

---

## Two channels

### 1. Dock widget

A docked terminal panel next to the Console / Asset Browser, hosting a real interactive PTY session via Win32 ConPTY. Defaults to spawning `cmd.exe`: you type whatever lands you in your environment (typically `docker exec -it <your-container> bash`, then `claude`). Minimal ANSI→HTML stripping is applied so Claude Code's TUI renders readable; full xterm.js-grade rendering is the v1.5 polish target.

### 2. In-editor MCP server on `127.0.0.1:6790`

Exposes editor introspection + control as ~593 MCP tools. Localhost-only `HttpListener` hosting **three transports concurrently on the same port**:

- `POST /<toolname>`: bespoke wire shape that the external Node `sbox-mcp-bridge` translates stdio-MCP into. Original transport; lower-friction when the bridge is in use.
- `POST /mcp`: MCP JSON-RPC 2.0 Streamable HTTP. Lets clients connect directly without the bridge: `claude mcp add --transport http -s user sbox http://localhost:6790/mcp`.
- `GET /sse` + `POST /sse/message?session=…`: MCP SSE legacy flow. Some clients still default to it.

All three funnel into the same dispatcher: per-call telemetry (LogCapture `engine_log`, AutoToast, `dispatcher_metrics`) is transport-agnostic.

Tools are registered two ways:
- Hand-authored `Dispatcher.Register(name, handler, description, inputSchema)` from `[InitializeOnLoad]`: the established path; the bulk of the surface uses this.
- `[McpTool("name", Description = "…")]` on a public static method, with parameters described via `[McpParam]`: JSON Schema auto-built from the C# signature. New code prefers this path.

The bridge **discovers tools dynamically** at startup via `/list_tools`: both registration paths auto-appear in the agent's tool list without bridge changes.

---

## How to use it (BYO container)

This setup ships **no** Docker infrastructure. You bring your own container with Claude Code (or another MCP client) inside it.

1. Bind-mount your s&box folder into your existing container (anywhere: `/workspace` is conventional).
2. Make sure `host.docker.internal` is reachable from inside your container. On Docker Desktop / Windows it works out of the box; on Linux Docker engines add `--add-host=host.docker.internal:host-gateway` to your `docker run` (or `extra_hosts:` in compose).
3. The bridge is already in this repo at `bridge/dist/bridge.js`. Either expose that path inside the container via the bind mount, or build it once on the host (`cd bridge && bun install && bun run build`) and copy the bundle in.
4. Place a `.mcp.json` at the root of the mounted s&box folder:

   ```json
   {
     "mcpServers": {
       "sbox": {
         "command": "node",
         "args": ["/path/to/game/addons/claude-sbox-setup/bridge/dist/bridge.js"],
         "env": { "SBOX_MCP_HOST": "host.docker.internal:6790" }
       }
     }
   }
   ```

5. Open the s&box editor. The "claude-sbox" tab appears in the bottom dock.
6. Click it. A `cmd.exe` prompt appears in the widget.
7. Type your `docker exec -it <your-container> bash` (or whatever drops you into your environment), then `claude`.
8. Claude Code reads `.mcp.json`, the bridge connects to the editor on `host.docker.internal:6790`, and the editor logs `[claude-sbox] sbox-mcp-bridge connected`.

Verify with `bash bridge/scripts/check-setup.sh` from inside the container. Runs 7 checks and reports PASS/FAIL.

If the bridge can't reach the editor, Claude Code still works: it just doesn't have live editor introspection tools.

---

## MCP tool catalog

The canonical, always-current inventory of tools (with arg shapes and example call patterns) ships in this repo at [`skill/references/mcp-tools.md`](skill/references/mcp-tools.md). ~593 tools across these categories:

- **Schema + docs** (live): `schema_*` + `docs_*`. API schema generated locally from the editor's loaded assemblies; prose docs pulled from `Facepunch/sbox-docs` (CC-BY-4.0).
- **Reflection + introspection**: `reflection_*` family (find types/methods by attribute, walk type hierarchies, parse attribute metadata, enum value enumeration).
- **Scene + inspector**: `get_active_scene`, `list_gameobjects`, `set_selection`, `set_property`, `instantiate_prefab`, `batch_transform`, etc.
- **Component lifecycle**: `gameobject_create`, `_destroy`, `_set_parent`, `_add_component`, `_remove_component`, `_set_component_enabled`, `_reorder_component`. Closes the "agent can't add components" gap.
- **Component button invocation**: `invoke_button(component, button)` presses any `[Button]`-annotated method on a component. `list_component_buttons` enumerates first. `set_prefab_ref` assigns a prefab to a GameObject-typed property where `set_property` can't.
- **Physics setup composites**: `add_physics`, `add_collider(shape)` (box/sphere/capsule/hull/model/plane), `add_joint(type)` (8 joint types). Each replaces a multi-call chain.
- **Code-template scaffolders**: `create_player_controller` (first/third-person), `create_npc_controller` (patrol/chase/patrol_chase), `create_game_manager` (modular), `create_trigger_zone` (log/teleport/damage/spawn). Emit fully-formed `.cs` to the project.
- **Prefab override tracking**: `prefab_get_override_map`, `_revert_property_override`, `_apply_property_change_to_source`, `_get_added_gameobjects`. Solves the "silent divergence from source" trap.
- **Project + addon**: `get_active_project`, `list_projects`, `set_active_project`, `list_project_dependencies`, `validate_project`, `query_project_metadata`.
- **Compile + hotload**: `compile_project` + introspection (`compile_check_build_state`, `compile_get_diagnostics`, `compile_list_compilers`); `hotload_*` (last result, queued swaps, trace settings); async-job pattern (`start_compile_project_job` + `poll_job` + `cancel_job`).
- **Asset operations**: read (`find_asset`, `list_assets`), CRUD (`rename_asset`, `move_asset`, `delete_asset`, etc.), native (`asset_query_state`, `asset_query_dependencies`, `asset_render_thumbnail`, `asset_set_in_memory_override`).
- **Cloud asset library**: `asset_search(query, take?)` searches sbox.game's public package library; `asset_fetch(ident)` returns full metadata; `asset_mount(ident, pin_to_project?)` mounts via `Package.MountAsync` and (default) appends the ident to the active project's `.sbproj` `PackageReferences` so it auto-mounts on subsequent loads; `asset_unpin(ident)` is the symmetric inverse.
- **Filesystem reads**: `host_read_file` / `host_grep` / `host_list_directory` over 13+ scoped roots (engine source, addon source, data, content, libraries, etc.). Read engine source even without a container bind mount.
- **Performance + memory + GC**: `get_performance_stats`, `_frame_stats_current`, `_memory_stats`, `_gpu_profiler_stats`, `force_garbage_collection(confirm)`. Detect regressions after edits.
- **Physics traces**: `scene_trace_ray`, `_sphere`, `_box`. Read-only geometric reasoning.
- **UI discovery + drive**: `list_docks`, `list_menus`, `list_shortcuts`, `find_widget` discover; `activate_dock`, `invoke_menu`, `invoke_shortcut`, `click_widget`, `send_keys`, `run_console_command` drive.
- **Qt widget interop**: `widget_get_geometry`, `widget_set_visible`, `widget_set_opacity`, `widget_capture_to_png`, `splitter_save_state`/`_restore_state`.
- **Visual guidance**: `editor_highlight` spotlights UI elements with a speech bubble.
- **Event bus**: `wait_for_*` and `last_*` over 25+ EditorEvents (`scene.play`, `compile.shader`, `content.changed`, `hotloaded`, `editor.created`, `hammer.initialized`, `hammer.selection.changed`, `hammer.mapview.contextmenu`, `asset.nativecontextmenu`, etc.) with composites (`wait_for_scene_state`, `wait_for_asset_ready`, `wait_for_editor_ready`).
- **Editor state**: `editor_state` (mode/scene/multiplayer snapshot), `get_gizmo_state`/`set_gizmo_*`, `list_preferences`/`set_preference`, `list_concmds`/`list_convars`/`set_convar`.
- **Audio mixer**: `audio_get_mixers`, `_set_mixer_volume`, `_set_mixer_solo_mute`, `_get_mixer_info` with meter values.
- **Sound runtime**: `sound_play_event`, `sound_play_file`, `sound_handle_get_active`, `sound_handle_set_pitch/_volume/_position`, `sound_handle_stop`, `sound_handle_follow_parent`. Server-side handle tracking lets the agent address running sounds across calls.
- **Physics runtime mutation**: `rigidbody_apply_force[_at]`, `_apply_impulse[_at]`, `_get_velocity_at_point`, `_smooth_rotate`, `_get_state`, `physics_group_apply_impulse`. The mutating companion to `scene_trace_*`.
- **NavMesh queries**: `navmesh_get_closest_point`, `_get_simple_path`, `_calculate_path` (with status), `_status`. Read-only AI-nav reasoning.
- **Animation / skeleton**: `anim_get_parameter_*` (bool/int/float/vector/rotation), `anim_set_parameter`, `_set_ik_target` / `_clear_ik`, `anim_morph_set/_get/_clear`, `anim_get_bone_transform`, `_get_all_bone_transforms`, `_get_bone_velocity`, `_get_attachment`. Per-GameObject SkinnedModelRenderer introspection + control.
- **Model inspection**: `model_get_info`, `_list_bones`, `_list_attachments`, `_list_hitboxes`, `_list_body_groups`, `_list_lods`. Load any `.vmdl` and walk its structure.
- **Hammer view + entity I/O + visibility**: `hammer_list_mapviews`, `mapview_get_camera`/`_set_camera`/`_get_mouse_position`/`_build_ray`, `hammer_list_entities`, `mapentity_get_keyvalues`/`_set_keyvalue`, `hammer_hide_selection`/`_show_all`/`_isolate_selection`/`_set_node_visibility`. Per-viewport camera + entity-I/O + visibility-isolation.
- **Hammer GameData + node tree ops**: `hammer_list_entity_classes`, `hammer_get_entity_class_schema` (Variables/Inputs/Outputs/Tags/Metadata/EditorHelpers), `hammer_list_mapnode_tree`, `hammer_node_copy`/`_remove`/`_rename`/`_reparent`. Read-side enumeration of every entity class fed by .fgd + managed entities, plus tree-shape mutators.
- **Hammer brush + entity I/O wiring + per-node selection**: `brush_get_face_materials`, `entity_io_validate(source_class, output, target_class, input)` pre-flight checks output→input wiring, `mapentity_set_classname` swaps a Hammer entity's class. `hammer_select_node_by_id` / `_add_node_to_selection` / `_remove_node_from_selection` operate on a single MapNode, and `map_world_summary` returns at-a-glance per-type node counts.
- **Editor save state**: `list_unsaved_scenes` and `list_unsaved_resources` return the same lists the editor's quit-prompt walks; gate `compile_project` / project hot-swap on these. `project_get_paths` and `project_get_publish_info` round out the per-project introspection.
- **NodeGraph depth**: `nodegraph_find_node_by_name`, `_validate_graph` (cycles + unreachable + plug errors), `_get_pin_types`, `_set_reroute_comment`, `_set_node_size`. The deeper-than-create surface.
- **Asset depth**: `asset_get_tags`/`_set_tags`, `_get_compile_status`, `_get_reverse_dependencies`, `_batch_reimport`, `_get_disk_size`. Tag editing + dependency walks + compile-pipeline forensics.
- **Render / texture / scene-camera**: `texture_get_info`, `scene_camera_info`, `screenshot_scene_to_file`, `list_loaded_textures`. Scene-camera + frame-grab observability.
- **Roslyn devtools**: `compile_snippet` (returns diagnostics), `parse_syntax_tree` (AST dump), `execute_csharp` (REPL-style evaluation via reflective `Microsoft.CodeAnalysis.CSharp.Scripting.CSharpScript.EvaluateAsync`), `profiler_start_sampling`/`_stop_sampling`/`_status` (ETW).
- **Cross-reference + heap analysis**: `find_type_usages`, `find_method_overrides`, `find_symbol_definition`, `heap_walk_by_type`.
- **Niche utility**: `console_autocomplete_at`, `console_command_history`, `get_member_default_value`, `gc_force_generation`, `ping_addon_health`, `list_attribute_targets`.
- **Localization**: `game_language_current`, `game_phrase_lookup`, `game_localization_show_missing_keys`, `language_list_supported`, `language_current_info`, `language_get_phrase`.
- **Networking state**: `game_network_mode`, `_connections_list`, `_connection_info`, `_server_data_get/set`. Most require a running multiplayer session.
- **Game input** (running game): `game_action_list`, `game_action_query`, `game_input_global_state`.
- **Auto-generated wrappers**: `auto:<Type>.<Method>` for every `[Menu]`/`[Shortcut]`/`[ConCmd]`/`[Editor.Tool]` discovered at startup (~50–150 depending on loaded addons).
- **Hammer + ModelDoc + AnimGraph**: status + selection + native session queries; `animgraph_play_sequence` / `_get_playback_state` / `_set_playback_time` for per-GameObject playback.
- **Particles**: `particle_get_effect_info`, `_list_active_effects`, `_set_max_particles`, `_set_time_scale`, plus per-effect runtime control.
- **Debug overlay**: `debug_draw_line`/`_normal`/`_sphere`/`_box`/`_capsule`/`_cylinder`/`_text`/`_screen_text`. TTL-driven shape rendering for agent annotations during long ops.
- **Material runtime params**: `material_get_shader_parameters` / `_set_shader_parameter`.
- **Shader compile diagnostics**: `shader_compile_and_check`, `shader_get_compile_results`.
- **Build + auth + workshop**: `start_standalone_export_job`, `account_get_session/_memberships/_refresh`, 5-stage Workshop publish pipeline with strict `confirm:true` gating.
- **VR**: `vr_get_status`, `vr_set_enabled(confirm)`.
- **Library enumeration**: `list_registered_libraries`, `get_library_type_members`.
- **Code editor**: drive the user's IDE (jump to line + column in VS / VS Code / Rider).
- **Persistent cookies**: `cookie_get`/`cookie_set`/`cookie_delete` for cross-session agent memory.
- **Self-introspection**: `dispatcher_recent_calls`, `dispatcher_metrics`.
- **Async-job framework**: `start_*_job` / `poll_job` / `cancel_job` / `list_jobs`.
- **Diagnostic / meta**: `ping`, `list_tools`, `server_info`, `sbox_status`, `sbox_reconnect`. **`doctor`** is the unified readiness probe.
- **Multi-tool batches**: `dispatcher_batch` runs up to 50 sequential tool calls in one HTTP roundtrip, with `{"$ref": "alias.path.to.value"}` substitution.
- **Orientation overrides**: `.vmdl` assets don't carry a semantic "up" direction. `orientation_override_set` persists per-model rotation; `drop_asset_into_scene` auto-applies the stored override.

---

## On-disk caches

Two cache trees sit under `<sbox-public>/game/`:

| Path | Owner | What |
|---|---|---|
| `.sbox-global/cloud/.bin/package.ghage.claude-sbox.{cll,xml}` | Engine patch 0004 | Global snapshot of the addon's cloud package. Seeded on the one-time `package_install`, copied back into every project's `.sbox/cloud/.bin/` at project-load time. Survives `git pull` on sbox-public, project switches, and editor restarts; only wiped if you delete it manually. |
| `.claude-sbox/cache/schema/local-<sha>.json` | Addon runtime | Local-built API schema fingerprinted by (assembly path, size, mtime, xml-mtime). Hot-reload invalidates cleanly. |
| `.claude-sbox/cache/docs-repo/docs/**` | Addon runtime | Unpacked `Facepunch/sbox-docs` tarball + `MANIFEST.json` with the master commit SHA. ~600KB. |
| `.claude-sbox/cache/docs/manifest.txt` + `.claude-sbox/cache/docs/pages/**` | Addon runtime | `sbox.game/llms.txt` mirror + lazy-fetched per-page bodies. |

Both trees live inside `game/` so a container bind-mount of the s&box folder gives Claude Code visibility into the same artifacts the editor produced — no extra config needed.

---

## Companion skill

The Claude Code skill lives in this repo at [`skill/`](skill/). Install instructions are in [Installing the companion skill](#installing-the-companion-skill) above. Contents:

- `SKILL.md`: router. Routes "where is X?" to `editor_highlight`, "do X for me" to `invoke_menu`/`invoke_shortcut`, "set my editor to X" to `set_preference`, and so on.
- `references/mcp-tools.md`: complete tool inventory with arg shapes and example call patterns.
- `references/unity-translation.md`: Unity to s&box anti-pattern table — common Unity reflexes that hallucinate in this engine, and the s&box equivalents.
- `references/ten-rules.md`: the cardinal rules the runtime silently enforces.
- `references/gotchas.md`: surprises that survive a careful schema lookup.

The schema and docs pipelines are live: schema is generated from the running editor, prose docs come from the upstream `Facepunch/sbox-docs` repo on every refresh.

---

## License

MIT. See `LICENSE`.

s&box doc page bodies surfaced through `docs_get` are CC-BY-4.0: sourced from `Facepunch/sbox-docs`. Each response carries `source` and `commit` fields for citation.

---

## Status

In active development. Architecture is feature-complete against the principle stated at the top: auto-gen handles `[Menu]`/`[Shortcut]`/`[ConCmd]`/`[Editor.Tool]` automatically, explicit handlers cover the surfaces that aren't attribute-tagged. v1.5 polish targets: full xterm.js-grade rendering in the dock widget, connection-state UI (NoticeWidget + viewport overlay), and richer NodeGraph/ShaderGraph mutation if there's demand.
