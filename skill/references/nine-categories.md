# The Nine-Category Law + engineering contract

A structured map of the **entire s&box documentation surface** (the nine
`sbox.game/dev/doc/*` areas) cross-referenced with the **MCP tool families** that
serve each, plus the non-negotiable engineering rules. Use this to (a) navigate docs
(`docs_search`/`docs_get` against the right area), (b) find the tool family for a
domain, and (c) hold the quality bar on changes.

Adapted from the project's AGENTS.md "Prime Directive". Where AGENTS.md cited a
static API-schema zip, prefer the **live** ground-truth pipeline instead:
`schema_search_members` / `schema_lookup_type` reflect the *exact* engine + addons
running, and are stricter than any snapshot.

## Operating contract (strict-adherence language)

- **MUST** design scene-first (`Scene → GameObject → Component`); favor component
  composition over monolithic managers; one clear responsibility per component.
- **MUST** build in small playable slices with fast validation loops
  (`compile_project` → `wait_for_compiles` → exercise → `tail_log`).
- **MUST** define startup/bootstrap behavior explicitly, with graceful fallbacks for
  UI/resource failures (every icon/texture path needs a visible fallback).
- **MUST** produce diagnosable logs for critical systems (`Log.Info("[TAG] …")`),
  and keep all bulk edits undo-safe (`set_property`/`batch_transform` go through the
  editor undo scope; native mutations should wrap an `UndoScope`).
- **MUST NOT** ship behavior on a guess when the docs define it — ground with
  `schema_*` (signatures) → `docs_*` (semantics) → `learn_*`/`codesearch_*` (usage).
- **MUST NOT** degrade player trust for monetization shortcuts.

## Quality gates (BLOCKERS — cannot be skipped)

- Build/compile errors (`compile_check_build_state` must be clean — note that a
  **whitelist violation is NOT a compile error** and the MCP still says "Success";
  check diagnostics).
- Missing fallback for a critical UI asset/icon.
- Undocumented network authority/ownership behavior.
- Unversioned schema/resource changes.
- No reproducible test/validation path for a changed system.

## The nine categories → docs + MCP tool families

### 1. Scene — `sbox.game/dev/doc/scene/`
*Components, GameObject, GameObjectSystem, Prefabs, Scenes.* Declare load strategy
(replace/additive); reusable entities are prefab-backed; scene-wide orchestration in a
GameObjectSystem.
**Tools:** Scene/GameObject family (`get_active_scene`, `list_gameobjects`,
`gameobject_*`, `scene_get_stats`, `scene_set_timescale`, tags), Selection, Prefab
overrides (`prefab_*`), Inspector writes (`get/set_property`), Scene physics
(`scene_trace_*`, `scene_overlap_*`).

### 2. Code — `sbox.game/dev/doc/code/`
*Basics, Advanced, Libraries, API Whitelist, ConVars, Math Types, Cheat Sheet.*
Hotload-safe patterns first; shared logic in `Libraries/`; respect the whitelist;
engine-native math types.
**Tools:** Compile+hotload (`compile_*`, `hotload_*`, `execute_csharp`,
`compile_snippet`/`parse_syntax_tree`), Reflection/cross-ref (`reflection_*`,
`find_*`), ConVars (`list_convars`/`get_convar`/`set_convar`), code scaffolders
(`create_*`), ground-truth (`schema_*`/`docs_*`/`learn_*`/`codesearch_*`).

### 3. Editor — `sbox.game/dev/doc/editor/`
*ActionGraph, Asset Previews, Custom Editors, Editor Apps/Events/Project/Shortcuts/
Tools/Widgets, Game Exporting, Mapping, Model Editor, Movie Maker, Property
Attributes, Texture Generators, Undo System.* Editor-only logic stays out of runtime;
all bulk edits undo-safe; export checks are release gates.
**Tools:** UI discovery+drive (`list_menus`/`invoke_menu`/`spotlight`/widget_*),
Preferences+dock layouts, Undo (`undo`/`redo`/`undo_to_checkpoint`), Gizmo state,
ActionGraph/NodeGraph (`actiongraph_*`/`nodegraph_*`), Hammer (`hammer_*`/`mapentity_*`),
Model inspection (`model_*`/`modeldoc_*`), standalone export (`start_standalone_export_job`),
`auto_*` menu/tool wrappers, code-editor IDE bridge.

### 4. Assets — `sbox.game/dev/doc/assets/`
*Clothing, File System, Ready-to-use Assets, Resources, Storage (UGC).* Separate
mounted content from runtime/player data; typed resource contracts with schema
versions; enforce UGC ownership boundaries.
**Tools:** Assets family (`find_asset`/`list_assets`, browser, CRUD, state, deps,
compile, tags), resource JSON/metadata (`asset_read_json`, `resource_validate_json`,
`asset_metadata_get/set`), resource enumeration (`resource_list_by_type`,
`surface_list`), cloud+mounts (`list_mounts`/`set_mounted`, `auto_…CloudAsset…`),
filesystem reads (`host_*`).

### 5. Graphics — `sbox.game/dev/doc/graphics/`
*Effects, Post Processing, Shader Graph, Shaders.* Budget particles/beams/decals;
post-process must aid readability, not hide gameplay cues; shaders need fallback paths.
**Tools:** **Lighting+environment** (`lighting_list`, `envmap_bake[_all]`,
`indirect_light_volume_bake[_all]`, `post_process_list`, `fog_list`, `skybox_get`,
`decal_list`/`decal_place`), Material/shader/texture (`material_*`, `shader_*`,
`shadergraph_list_parameters`, `texture_*`), Particles (`particle_*`), Procedural mesh,
Debug overlay (`debug_draw_*`), GPU profiler.

### 6. UI — `sbox.game/dev/doc/ui/`
*HudPainter, Localization, Razor Panels, Styling Panels, VirtualGrid.* Razor is the
default UI architecture; no hardcoded player-facing strings; VirtualGrid for large
lists; **every icon/texture path needs a visible fallback** (a HUD PanelComponent
renders nothing without a ScreenPanel root — see gotchas).
**Tools:** UI discovery+drive, inspector input writes (`set_input_text`/`set_color`/…),
widget interop (`widget_*`/`inspect_widget`), Localization (`language_*`).

### 7. Gameplay — `sbox.game/dev/doc/gameplay/`
*Clutter, Input, Navigation, Terrain, VR.* Action-based frame-rate-independent input;
navmesh/agents before custom hacks; validate terrain early under load; parity-test VR.
**Tools:** **Terrain** (`terrain_get_info`/`_get_height_at`/`_sample_material_at`),
**Navigation** (`navmesh_get_closest_point`/`_calculate_path`/`_status` +
`navmesh_set_config`/`navmesh_generate`), **Clutter** (`clutter_generate`/`_clear`),
Physics setup+runtime (`add_physics`/`add_collider`/`add_joint`, `rigidbody_*`,
`physics_group_apply_impulse`), Animation (`anim_*` incl. bone posing +
`anim_capture_events`, `animgraph_*`, `morph_list`), Sound (`sound_*`), Game runtime
(`game_*`, requires play mode), VR (`vr_*`).

### 8. Networking & Multiplayer — `sbox.game/dev/doc/networking/`
*Connection Permissions, Custom Snapshot Data, Dedicated Servers, Http Requests,
Network Events, Network Helper, Network Visibility, Networked Objects, Ownership,
RPC Messages, Sync Properties, Testing Multiplayer, WebSockets.* Document authority +
transfer rules; validate RPC caller/recipients; deliberate `[Sync]` usage; multi-instance
testing is mandatory.
**Tools:** Game runtime networking reads (`game_network_mode`/`_connections_list`/
`_connection_info`/`_host_connection`, `game_server_data_get/set`). Authoring is in C#
(`[Rpc.*]`, `[Sync]`, ownership APIs) — ground with `docs_search("RPC visibility")` and
verify call sites via `codesearch_search`.

### 9. Services — `sbox.game/dev/doc/services/`
*Achievements, Auth Tokens, Leaderboards, Stats.* Stable semantic stat keys;
achievements driven by verifiable gameplay events; auth tokens for trusted backends.
**Tools:** Account/auth (`account_*`). Stats/achievements/leaderboards are C# service
APIs — ground with `docs_*` + `codesearch_*`.

## Change-notes checklist (apply to non-trivial changes)

- List the touched categories/subcategories above.
- State which rule each touched subcategory satisfied.
- Document exceptions with reason, risk, and rollback.
- Attach evidence: logs (`tail_log`), screenshots (`screenshot_scene_to_file`),
  and/or `run_tests` output.
