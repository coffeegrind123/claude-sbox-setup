# Tool families: discovery index

One-line index of every tool family the claude-sbox s&box bridge exposes. Use this when you'd otherwise be tempted to call `list_tools` (which returns ~580 entries). Grep this file for a topical keyword first: it's curated, list_tools isn't.

Rule of thumb: `family_prefix_*` means the editor exposes multiple tools sharing that prefix; `tool_name` (no prefix) means a single tool. **Counts reflect what's currently registered**; `auto_*` and `last_*`/`wait_for_*` grow when new attributes ship.

For full schemas + signatures of any tool, call `ToolSearch query="select:mcp__sbox__<tool>"`.

## Discovery + diagnostic

- `sbox_status` / `sbox_reconnect`: bridge connection probe + force re-list. Bridge-side, always available even if editor is down.
- `ping` / `ping_addon_health`: editor-side liveness + GC/uptime/tool-count snapshot.
- `server_info`: editor + MCP host metadata: version, started_at, tool_count.
- `editor_state`: one-call mode snapshot (edit/play/paused, scene state, project, multiplayer, filesystem scopes, dispatcher metrics, capabilities). Precondition gate before any mode-dependent tool. **Always call this first when you don't know what state the editor is in.**
- `dispatcher_recent_calls` / `dispatcher_metrics`: your own call history + per-tool aggregates. Use to debug "why didn't that work?".
- `schema_freshness`: what assemblies the local schema reflects.

## Ground-truth lookup pipelines (8)

- `schema_*` (7): local API schema from the editor's loaded assemblies. **Most accurate**; reflects exactly the engine + addons running. See `mcp-tools.md` § API schema.
- `docs_*` (4): local BM25 index over the Facepunch/sbox-docs repo. Prose narrative usage docs. See `mcp-tools.md` § Prose docs.
- `learn_*` (4): local BM25 index over a daily mirror of sbox.game/learn community tutorials at `coffeegrind123/sbox-learn-docs`. Faceted (difficulty / topic / content_type / author / tags). See `mcp-tools.md` § Community tutorials.
- `codesearch_*` (5): **real-world source** search across every open-source package on sbox.game — `codesearch_search` / `_get_file` / `_list_files` / `_status` / `_restart`. Plain REST over `public.facepunch.com/sbox/code/search/1/` (no driver/install; the search returns each file's full source). Shows how people *actually call* an API, then pulls the whole file. Results are a capped top-N (~30); `truncated`/`total_*` flag when cut off. **Queries leave the machine.** See `mcp-tools.md` § Code search.
- `forum_*` (4): browse + search the **community forum** at sbox.game/f — `forum_list_categories` (slugs) → `forum_browse_category` (≤50 recent threads) → `forum_read_thread` (posts: author/score/content/ratings, 30/page); `forum_search` (site index, top ~50 + true total). Live discussion: bug reports, dev chat, announcements, Q&A. **The only family using the headless-Chromium driver** (the forum is a Blazor Server SPA with no REST endpoint) — first use needs `codesearch_install_driver`; `forum_driver_outdated` → `codesearch_install_driver force:true` + editor restart. **Queries leave the machine.** See `mcp-tools.md` § Community forum.
- `release_notes` (1): read the **changelog** via REST `public.facepunch.com/sbox/news/platform` — weekly update posts newest-first, each `{version, title, date, url, summary, sections:[{title, content}]}`. `limit` = how many back; `version` = substring filter on version/title. "What changed / when did X land / is this a known issue". No driver. See `mcp-tools.md` § Release notes.
- `youtube_*` (3 + installer): **search + watch tutorial VIDEOS** — `youtube_search` (keyless yt-dlp/InnerTube discovery → ranked videos) / `youtube_watch` (download + transcribe locally with yapsnap + a frame per caption → a viewing package `watch.md` + `frames/` in `<game>/.claude-sbox/youtube/`, which you then Read since frames are images) / `youtube_status` (+ `youtube_install`). Flow: `youtube_search(topic)` → feed a result url to `youtube_watch`. For VIDEO; `learn_*` is for text tutorials. English audio; transcription is local. See `mcp-tools.md` § Watching tutorial videos + `watch-video.md`.
- `reflection_*` (17): live `EditorTypeLibrary` walks: relationships, attribute discovery, type hierarchy, member metadata. Goes beyond signatures into discoverability.

## Reflection / cross-reference

- `reflection_find_types_with_attribute` / `_methods_with_attribute` / `_properties_with_attribute` / `_types_by_base_type` / `_resource_types_with_extension`: discovery.
- `reflection_get_type_hierarchy` / `_get_member_metadata` / `_get_method_signature` / `_get_property_descriptor` / `_get_field_descriptor` / `_get_enum_values` / `_get_intrinsic_types` / `_list_attribute_names` / `_list_members_by_tag` / `_parse_attribute_metadata` / `_get_type_ident` / `_get_member_identity`: introspection.
- `find_type_usages` / `find_method_overrides` / `find_symbol_definition`: cross-reference (which types use X, who overrides Y, where is Z defined).
- `heap_walk_by_type`: GC totals + per-type live-instance counts.
- `list_registered_libraries` / `get_library_type_members`: `[Library]`-tagged types.
- `list_attribute_targets`: counts of types/methods/properties/fields tagged with X.
- `get_member_default_value`: read `[DefaultValue]`.

## Scene / GameObject

- `get_active_scene` / `list_sessions`: what's open.
- `list_gameobjects` / `get_gameobject` / `get_components` / `find_gameobject_by_path` / `find_game_objects_in_radius`: walk + query.
- `gameobject_create` / `_destroy` / `_set_parent` / `_add_component` / `_remove_component` / `_set_component_enabled` / `_reorder_component` / `_get_component_index`: lifecycle.
- `delete_gameobject` / `duplicate_gameobject` / `rename_gameobject` / `reparent_gameobject`: bulk-equivalent shortcuts.
- `instantiate_prefab` / `drop_asset_into_scene`: spawn from asset.
- `batch_transform`: multi-GameObject translate/rotate/scale, single undo.
- `copy_component`: between GameObjects via SerializedObject.
- `frame_selection`: center editor camera.
- `save_scene` / `save_all_scenes` / `list_unsaved_scenes` / `list_unsaved_resources`: persistence.
- `get_scene_bounds` / `get_selection_bounds`: world AABBs.

## Inspector / property writes

- `list_properties` / `get_property` / `set_property`: inspector-visible; goes through editor undo. Always verify `previous`/`current` (see gotchas).
- `list_component_buttons` / `invoke_button`: `[Button]`-tagged component methods (Build Terrain / Reset / etc.).
- `set_prefab_ref`: assign a loaded prefab to a GameObject-typed property (set_property can't).

## Selection

- `get_selection` / `set_selection` / `add_to_selection` / `remove_from_selection` / `toggle_selection` / `deselect_all` / `invert_selection`.
- `select_by_component_type` / `select_by_tag` / `select_children`: bulk selection patterns.

## Prefab overrides

- `prefab_get_instance_status` / `_get_override_map` / `_get_added_gameobjects`: read.
- `prefab_revert_property_override` / `_revert_component_changes` / `_revert_all_changes`: back to source.
- `prefab_apply_property_change_to_source` / `_apply_all_changes_to_source` / `_write_instance_to_prefab`: push to disk (`confirm:true`).

## Assets

- **Find**: `find_asset` / `list_assets` / `list_asset_types`.
- **Browser**: `asset_browser_get_current_folder` / `_navigate` / `_open_parent` / `_set_view_mode` / `_refresh` / `_focus_on_asset` / `_add_pin`.
- **CRUD**: `register_asset_file` / `create_resource` / `compile_resource` / `rename_asset` / `move_asset` / `copy_asset` / `delete_asset` / `reveal_asset_in_explorer` / `open_asset`.
- **State**: `asset_query_state` / `_get_compile_status` / `_get_disk_size` / `_record_opened` / `_delete_orphans`.
- **Deps**: `asset_query_dependencies` / `_get_reverse_dependencies` / `_get_input_dependencies` / `_get_additional_files` / `_get_unrecognized_references`.
- **Compile**: `asset_compilation_control` / `_batch_reimport`.
- **Override**: `asset_set_in_memory_override` / `_clear_in_memory_override`.
- **Thumbnail**: `asset_render_thumbnail` / `_rebuild_thumbnail`.
- **Tags**: `asset_get_tags` / `_set_tags` (mode: add/remove/replace).

## Compile + hotload

- `compile_project` / `wait_for_compiles` / `generate_solution`: synchronous.
- `compile_check_build_state` / `_get_diagnostics` / `_list_compilers` / `_get_assembly_output` / `_mark_for_recompile`: non-blocking introspection.
- `start_compile_project_job` / `poll_job` / `cancel_job` / `list_jobs`: async pattern.
- `compile_snippet` / `parse_syntax_tree`: Roslyn (no execution); diagnostics + AST dump.
- `profiler_start_sampling` / `_stop_sampling` / `_status`: ETW CPU profile.
- `hotload_get_last_result` / `_list_queued_assembly_swaps` / `_get_outgoing_assemblies` / `_check_assembly_ignored` / `_get_upgrader_status` / `_get_trace_settings` / `_set_trace_settings`.

## UI discovery + drive

- **Discover**: `list_docks` / `list_menus` / `list_shortcuts` / `list_widgets` / `find_widget` / `get_focused_widget`.
- **Drive (action)**: `invoke_menu` / `invoke_shortcut` / `click_widget` / `focus_widget` / `send_keys` / `run_console_command`.
- **Drive (visual)**: `menu_open` (cascade animates) vs. `invoke_menu` (silent action). `set_dock_visible` (show/hide; destroys+reconstructs DeleteOnClose docks). `activate_dock` (raise tab).
- `menu_close` / `menu_list_path`: programmatic menu state.
- **Spotlight**: `spotlight` (single + tour mode + pulse) + legacy `editor_highlight` / `editor_dismiss_highlight` / `highlight_status`. **Lead with `spotlight`** for "where is X?" questions.

## Inspector input writes (widget-driven)

When `set_property` doesn't apply (custom widgets, transient inspectors, popup dialogs):

- `set_input_text` (LineEdit/TextEdit/ComboBox; default REPLACE, `append=true`).
- `set_color` (object `{r,g,b,a}` 0-1 floats OR `'#RRGGBB'`/`'#RRGGBBAA'` hex).
- `set_checkbox` (bool OR `'On'`/`'Off'`/`'Partial'` for tri-state).
- `set_slider_value` (auto-coerces float/int/double, clamps to widget range).
- `select_dropdown_option` (`by='text'` OR `by='index'`).
- `set_widget_value`: universal: figures out widget type. Use when you don't know.
- `widget_drag`: synthetic mouse drag (best-effort; some widgets reject Qt synthetic events: see gotchas).

## Widget interop (Qt native)

- `widget_get_geometry` / `_set_geometry` / `_set_visible` / `_set_enabled` / `_set_tooltip` / `_set_window_title` / `_set_opacity` / `_set_focus_policy` / `_query_state` / `_capture_to_png`.
- `get_widget_state`: current value/text/enabled/visible/focused + type-specific fields.
- `inspect_widget`: deep reflection dump (every property + Action field + method signature). Use to discover before driving an unfamiliar widget.
- `splitter_save_state` / `splitter_restore_state`.

## Tree, tabs, file dialogs

- `tree_list_items` / `tree_expand_node` / `tree_select_item` / `tree_select_items` / `tree_unselect_all` / `tree_activate_item`: TreeView/BaseItemWidget driver.
- `tab_list_pages` / `tab_select`: TabWidget/VerticalTabWidget driver.
- `pick_file`: modal **BLOCKS** until user accepts/cancels; mode `open_existing`/`open_any`/`save`/`directory`.
- `file_dialog_status` / `file_dialog_set_path` / `file_dialog_accept` / `file_dialog_cancel`: drive an open FileDialog programmatically.

## Editor preferences + dock layouts

- `list_preferences` / `get_preference` / `set_preference` / `list_changed_preferences` / `reset_preference_to_default` / `export_preferences` / `import_preferences`.
- `save_dock_layout_as_preset` / `load_dock_layout_preset` / `list_dock_layout_presets` / `delete_dock_layout_preset`.

## Undo / Redo

- `undo` / `redo` / `list_undo_history` / `undo_to_checkpoint` (match=exact|prefix|substring).

## Console + convars + log

- `list_concmds` / `list_convars` / `get_convar` / `set_convar` / `console_help` / `console_autocomplete_at` / `console_command_history` / `run_console_command`.
- `tail_log` / `print_log` / `clear_log_buffer`.

## Cookies (cross-session memory)

- `cookie_get` / `cookie_set` / `cookie_delete` / `cookie_namespace` (returns `claude-sbox.` prefix recommendation). Scope: `editor` (per-user) | `project` (per-project).

## Notifications + clipboard + toast

- `notify(message, level?, title?)`: editor toast.
- `clipboard_copy` / `clipboard_paste`.
- `get_auto_toast` / `set_auto_toast`: bridge-emitted toast on/off.

## Performance + memory + GC

- `get_performance_stats` / `get_frame_stats_current` / `get_memory_stats` / `get_gpu_profiler_stats` / `set_gpu_profiler_enabled` / `force_garbage_collection` / `gc_force_generation`.

## Editor camera + window + mouse

- `get_editor_camera` / `set_editor_camera`: scene-view camera.
- `get_editor_window_bounds`: main window screen rect + DPI + focused/hovered widget snapshot.
- `query_mouse_state`: cursor pos + button mask + modifier flags + per-key IsDown.

## Project + addons + mounts

- `get_active_project` / `set_active_project` / `list_projects` / `list_addons` / `load_project` / `validate_project`.
- `list_project_dependencies` / `query_project_metadata` / `project_get_paths` / `project_get_publish_info` / `project_get_publish_status`.
- `list_mounts` / `set_mounted` / `refresh_mount`.

## Standalone build + workshop publish + account auth

- `export_get_default_config` / `export_preferences` / `start_standalone_export_job`: standalone exe build.
- `project_publisher_create` → `_set_change_details` → `project_publish_query_upload_plan` → `_upload_files_job` → `_finalize` (5-stage, `confirm:true` on every destructive call).
- `project_publisher_list_sessions`.
- `account_get_session` / `_get_memberships` / `_check_membership` / `_refresh` / `_get_favorites` / `_get_service_links`: auth precondition.

## Filesystem reads (`host_*`)

Read engine source / addon source / editor caches without a bind mount. **All read-only**, scope-gated. 14 scopes (9 `filesystem_scope` + 5 `absolute_path`).

- `host_list_scopes`: call first to discover what's reachable.
- `host_read_file` / `host_read_binary` / `host_list_directory` / `host_grep` / `host_file_info` / `host_resolve_path` / `host_read_text_around` (lines around a target line).

## Bootstrap

- `bootstrap_engine`: runs `Bootstrap.bat`. Stages `engine` (DLLs: fails if editor open), `shaders`, `content`. Windows-only. 30-min default timeout.
- `bootstrap_tests`: run engine test suite.
- `codesearch_install_driver`: build + deploy the headless-Chromium Playwright driver that the **`forum_*`** tools use (codesearch + release_notes are plain REST and need no driver; the install tool keeps its `codesearch_` name for back-compat). Spawns `claude-sbox-setup/Build-CodeSearch-Driver.{bat,sh}` (`dotnet publish` → the game's global store `<game>/.claude-sbox/codesearch-driver/runtime/`, then `playwright install chromium`). Idempotent (`force:true` to rebuild). Call when `forum_*` return `forum_driver_unavailable`. Needs the .NET SDK on PATH.
- `youtube_install`: provision the youtube Python venv. Spawns `claude-sbox-setup/Build-YouTube-Venv.{bat,sh}` (creates a venv at `<game>/.claude-sbox/youtube/venv/`, pip-installs yapsnap + yt-dlp + imageio-ffmpeg). Idempotent (`force:true` to recreate). Call when `youtube_watch` returns `youtube_venv_unavailable`. Needs Python 3 on PATH (ffmpeg bundled); no editor restart.

## Event bus

28 tracked editor events × `last_<event>` (snapshot) + `wait_for_<event>` (block, default 5000ms timeout, max 60000) + 6 composite tools.

- `list_tracked_events`: current snapshot summary across all events.
- **Composites**: `wait_for_scene_state(target)` / `wait_for_asset_ready(path)` / `wait_for_content_change(pattern?)` / `wait_for_editor_ready(subsystem?)` / `wait_for_package_action(action?)` / `wait_for_compiles`.
- Naming: `.` → `_` (e.g. `wait_for_scene_play`, `last_package_changed_installed`).

## Auto-generated wrappers (`auto_*`)

`[Editor.MenuItem]` / `[Editor.Tool]` / `[Shortcut]` / `[ConCmd]` methods exposed as MCP tools.

- `auto_list` / `auto_register`: list current + re-scan.
- Concrete instances are named `auto_<Type>_<Method>` in MCP (underscore-substituted) but `auto_list` returns `tool: "auto:<Type>.<Method>"` (canonical, dot-form). **Both forms are reachable**; the MCP-layer name is the underscore form. See gotchas.
- 19 currently registered (Editor.EditorScene CRUD, Sandbox.Game screenshots, EnvmapProbe/IndirectLightVolume/NavMesh bake-all, CloudAsset.InstallSingle).

## Scene physics

- `scene_trace_ray` / `_sphere` / `_box`: sweep traces with hit lists, tag filters, ignore lists.
- `scene_camera_info` / `scene_physics_world_info`: read-only scene queries.

## Physics setup composites

- `add_physics(id, mass?, gravity?, ...)`: Rigidbody.
- `add_collider(id, shape, ...)`: `box`/`sphere`/`capsule`/`hull`/`model`/`plane`.
- `add_joint(id, type, connected_id?, ...)`: `ball`/`hinge`/`fixed`/`slider`/`spring`/`upright`/`wheel`/`control`.

## Physics runtime mutation

- `rigidbody_apply_force[_at]` / `_apply_impulse[_at]` / `_get_velocity_at_point` / `_smooth_rotate` / `_get_state`.
- `physics_group_apply_impulse(id, velocity, with_mass?)`: ragdoll-wide.

## Navigation

- `navmesh_get_closest_point` / `_get_simple_path` / `_calculate_path` (status+waypoints) / `_status`.

## Animation

- **Runtime (live SceneModel)**: `anim_get_parameter_{bool,int,float,vector,rotation}` / `_set_parameter`. `anim_set_ik_target` / `_clear_ik`. `anim_morph_set` / `_get` / `_clear`. `anim_get_bone_transform` / `_get_all_bone_transforms` / `_get_bone_velocity` / `_get_attachment`.
- **Playback preview**: `animgraph_get_preview_model` / `_set_preview_model` / `_get_sequences` / `_play_sequence` / `_get_playback_state` / `_set_playback_time` / `_stop_playback`.
- **Animgraph asset READ (`.vanmgrph` KV3 source)**: `animgraph_source_inspect` (nodes, connections, parameters, and state machines with transition conditions resolved to parameter names — this is how you find which transition/sequence drives an animation, e.g. a weapon draw) / `animgraph_source_serialize` (raw KV3→JSON) / `animgraph_list_node_classes` (catalog of native `C*AnimNode` classes + property keys, harvested from disk).
- **Animgraph asset EDIT (`.vanmgrph` KV3 source)**: `animgraph_edit_load` → mutate → `animgraph_edit_verify` (non-destructive serialize+reparse) → `animgraph_edit_save` (backup + write + recompile; `dry_run` supported). Mutations: `animgraph_set_node_property` (e.g. `m_sequenceName`, `m_bLoop`), `animgraph_connect` / `animgraph_disconnect`, `animgraph_add_node` (clone-template, in-graph or from another `.vanmgrph`), `animgraph_delete_node`, `animgraph_set_transition_disabled` (kill a state-machine edge — e.g. stop a draw state being entered). **These edit the source file, NOT `nodegraph_*`** (animgraph is native, not an `IGraph` — see "Action graph + node graph").

## Sound runtime

- `sound_play_event(event_name, position?, ...)` / `sound_play_file(path, ...)`: return `handle_id`.
- `sound_handle_get_active` / `_set_pitch` / `_set_volume` / `_set_position` / `_stop` / `_follow_parent`.
- `play_asset_sound` / `stop_asset_sound`: preview from asset.

## Particles

- `particle_emit_at` / `_clear` / `_reset_emitters` / `_set_paused` / `_get_runtime_state` / `_get_effect_info` / `_list_active_effects` / `_set_max_particles` / `_set_time_scale`.

## Material / shader / texture

- `material_get_shader_parameters` / `material_set_shader_parameter` (in-memory; .vmat untouched).
- `shader_compile_and_check` / `shader_get_compile_results` / `shadergraph_list_parameters`.
- `texture_get_info` / `list_loaded_textures` / `screenshot_scene_to_file`.

## Audio mixer

- `audio_get_mixers` / `_get_mixer_info` / `_set_mixer_volume` / `_set_mixer_max_voices` / `_set_mixer_solo_mute` (`confirm:true`).

## Procedural mesh

- `mesh_create_block` / `mesh_get_info` / `mesh_set_face_material` / `mesh_rebuild`: `Sandbox.MeshComponent` + `PolygonMesh`.

## Model inspection (`.vmdl`)

- `model_get_info` / `model_list_bones` / `_list_attachments` / `_list_hitboxes` / `_list_body_groups` / `_list_lods`. **All take `path`, not `model`** (see gotchas).
- `modeldoc_status` / `modeldoc_get_session_model` / `modeldoc_refresh_game_data` / `open_model_in_editor`.

## Action graph + node graph

- `actiongraph_list` / `_get_metadata` / `_set_metadata` / `_export_json`: `.action` resource CRUD.
- `nodegraph_inspect` / `_serialize` / `_list_node_types` (lazy: see gotchas) / `_find_node_by_name` / `_get_pin_types` / `_validate_graph`.
- `nodegraph_create_node` / `_connect_pins` / `_delete_node` / `_disconnect_pin` / `_save` / `_set_node_position` / `_set_node_size` / `_set_reroute_comment`: mutate.
- `shadergraph_list_parameters`.
- **Scope**: `nodegraph_*` works on managed `Editor.NodeEditor.IGraph` + `GameResource` assets — i.e. **ActionGraph and ShaderGraph only**. It does **not** work on Animation Graphs: the animgraph editor is native C++ and `AnimationGraph` is a native-handle `Resource`. To edit animgraphs use the `animgraph_source_*` / `animgraph_edit_*` family (see "Animation"), which operates on the `.vanmgrph` KV3 source text.

## Code-template scaffolders (emit `.cs`)

- `create_player_controller` (type: first_person/third_person; speeds, jump force, sprint multiplier).
- `create_npc_controller` (behavior: patrol/chase/patrol_chase; speeds, ranges).
- `create_game_manager` (include_score?, include_timer?, include_spawning?).
- `create_trigger_zone` (action: log/teleport/damage/spawn; filter_tag).
- `create_game_project`: bootstrap a fresh `.sbproj`.

## Debug overlay

- `debug_draw_line` / `_normal` / `_sphere` / `_box` / `_capsule` / `_cylinder` / `_text` / `_screen_text`.
- `color`=`{r,g,b,a}` 0-1 (default white). `duration_seconds` default 5, max 600. `overlay:true` for no-depth-test.

## Hammer (level editor)

- **Status**: `hammer_status` / `hammer_reload_map` / `hammer_set_material` / `hammer_show_entity_report`.
- **Selection**: `hammer_get_selection` / `_clear_selection` / `_select_all` / `_invert_selection` / `_set_select_mode` (Groups/Objects/Meshes/Verticies/Edges/Faces).
- **Per-node selection**: `hammer_select_node_by_id` / `_add_node_to_selection` / `_remove_node_from_selection`.
- **Pivot**: `hammer_get_pivot` / `_set_pivot`.
- **Asset queries**: `hammer_select_objects_using_asset` / `_select_faces_using_material` / `_assign_asset_to_selection` / `brush_get_face_materials`.
- **Visibility**: `hammer_hide_selection` / `_show_all` / `_isolate_selection` / `_set_node_visibility`.
- **Per-viewport**: `hammer_list_mapviews` then `mapview_get_camera` / `_set_camera` / `_get_mouse_position` / `_build_ray`.
- **Entities**: `hammer_list_entities(classname_filter?)` then `mapentity_get_keyvalues` / `_set_keyvalue` (Hammer outputs are repeated keys: `OnTrigger,target,Open,0,-1`) / `_set_classname`.
- **Node tree**: `hammer_list_mapnode_tree(type_filter?, name_filter?)` then `hammer_node_copy` / `_remove` / `_rename` / `_reparent` (cycle-checked).
- **Schema**: `hammer_list_entity_classes(name_filter?, category_filter?, class_type?)` then `hammer_get_entity_class_schema(name)` (Variables / Inputs / Outputs / Tags / EditorHelpers / Metadata). Use BEFORE `mapentity_set_keyvalue`.
- **Map summary**: `map_world_summary`: per-type node counts.
- `entity_io_validate(source_class, output, target_class, input)`: type-check entity wiring before applying.

## Game runtime (requires running game)

- `game_action_list` / `_action_query`: InputAction state.
- `game_input_global_state`: held actions count + EscapePressed.
- `game_network_mode` / `_connections_list` / `_connection_info` / `_host_connection`.
- `game_server_data_get` / `_set` (`confirm:true`; visible to all clients).
- `game_language_current` / `_phrase_lookup` / `_localization_show_missing_keys`.

## Localization

- `language_list_supported` / `_current_info` / `_get_phrase(token, data?)`. Switch via `set_convar(name='language', value=...)`.

## VR

- `vr_get_status` / `vr_set_enabled` (`confirm:true`).

## Code editor IDE

- `code_editor_status` / `open_file_in_code_editor(path, line?, column?)` / `open_solution_in_code_editor` / `open_addon_in_code_editor(ident)`.

## Gizmo state

- `get_gizmo_state` / `set_gizmo_mode` (position/rotation/scale) / `_set_gizmo_space` / `_set_gizmo_view_mode` / `_set_gizmo_snap_settings` / `_set_gizmo_scale` / `set_gizmos_enabled` / `set_gizmo_enabled_for_type` / `is_gizmo_enabled_for_type` / `clear_gizmo_disabled_types` / `list_gizmo_disabled_types`.
