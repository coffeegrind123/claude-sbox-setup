# s&box API gotchas

The catalogue below covers traps that survive even careful schema
lookups — quirks where the documented API doesn't match the runtime,
or where namespacing / parameter conventions break common assumptions.
These are the surprises that send agents into hallucination loops if
they don't know to expect them.

## Namespace placement

- `Color` and `Capsule` live in the **global** namespace, not under
  `Sandbox`. Writing `Sandbox.Color` won't resolve.
- There is no standalone `Log` class; the engine type is
  `Sandbox.Diagnostics.Logger`. The global `Log` instance (which
  routes to that logger) is what gameplay code uses day-to-day.
- `NavigationHost` is exported from `Sandbox.UI.Navigation` — needs
  an explicit `@using Sandbox.UI.Navigation` in Razor files.
- `LobbyConfig` and `LobbyPrivacy` are in `Sandbox.Network`, not
  bare `Sandbox`. You need `using Sandbox.Network;` to reach them.
- Most damage / collision / network listener interfaces are
  **nested on `Component`**: `Component.IDamageable`,
  `Component.ICollisionListener`, `Component.ITriggerListener`,
  `Component.INetworkSpawn`, `Component.INetworkListener`,
  `Component.INetworkVisible`. The one exception is
  `IGameObjectNetworkEvents`, which lives at the top of `Sandbox.`.

## Parameter names + arities the docs lie about

- `ICollisionListener` callbacks take a parameter called `collision`,
  even though many doc snippets you'll find use `other`. The wrong
  name compiles when you write the implementation by hand but breaks
  any tooling that matches by exact identifier.
- `PlayerController.TraceBody` takes **four** arguments, not three —
  the fourth is `heightScale`.
- `SceneTrace.WithoutTags` / `WithAnyTags` / `WithAllTags` accept a
  `string[]` rather than `params string[]`. Pass `new[] { "tag" }`,
  or use the singular `WithTag( string )` overload for one tag.
- `ConVarAttribute` requires a `ConVarFlags` argument in every
  constructor — there is no single-string overload.
- `Game.Random.FromList(list, defVal)` — an extension on
  `System.Random` from `SandboxSystemExtensions` — requires the
  default value parameter. For the common "pick any" case, just use
  `list[ Game.Random.Next( list.Count ) ]`.

## Static facades & helpers

- `FileSystem` itself is a static facade with no methods of its own.
  All actual I/O lives on `BaseFileSystem`, reached via
  `FileSystem.Data` (mutable per-project data) or `FileSystem.Mounted`
  (read-only mounted content).
- `ComponentList.GetOrCreate<T>()` requires a `FindMode` argument.
  For the "create on this GameObject if missing" case, prefer
  `GameObject.GetOrAddComponent<T>()` or `Component.GetOrAddComponent<T>()`.

## Coordinate system + scene topology

- s&box is **Z-up**, not Y-up. `Forward = (1, 0, 0)`,
  `Right = (0, -1, 0)`, `Up = (0, 0, 1)`. Any direction vector you
  copy from Unity / Unreal lore is wrong.
- `Scene` extends `GameObject` — the scene is itself the root
  GameObject (`public partial class Scene : GameObject` in
  `engine/Sandbox.Engine/Scene/Scene/Scene.Editor.cs`). Methods you
  expected on a scene root just work on `Scene`.
- Operators (e.g. `Rotation * Rotation`) are **excluded** from the
  generated API schema. The schema won't show them; they exist
  anyway. Trust the type's `IXmlSerializable`-adjacent docs.

## Editor-side traps (from running this addon)

- `[Dock]`'s first argument is the **target window name** as a
  string — not a type, not a namespace. Use `"Editor"` for the main
  editor window. (See `engine/Sandbox.Tools/Editor/DockAttribute.cs`.)
- `Sandbox.Tools` (the editor addon assembly) is **not** under the
  AccessControl whitelist that game / addon code is under. Inside an
  editor tool addon you can freely use `System.Net.HttpListener`,
  `System.Diagnostics.Process`, and similar. Inside gameplay code,
  you cannot.
- Tool addon hot-reload nukes static state. Anything holding OS
  resources (sockets, file handles, child processes) needs explicit
  teardown wired to `[Event("hotload.success")]`, otherwise you
  leak across reloads.
- The active editor scene is `Editor.SceneEditorSession.Active.Scene`.
  It is **not** `Sandbox.Scene.Active` (no such property) and **not**
  `Scene.All` (that collection filters out editor scenes — see
  `Scene.Static.cs`).
- `set_property` can still report `ok:true` while the value doesn't change —
  the response includes both `previous` and `current`; if they're equal after a
  write, the write didn't take. Always confirm with a read-back. **Two distinct
  causes, don't conflate them:** (1) the property is a **runtime-only** field
  (e.g. `Rigidbody.Velocity`) that no-ops in edit mode — expected, not a bug;
  (2) a genuine coercion miss (now rare — see the "set_property coercion" section
  below; bool/Vector3/float/asset-handles were fixed 2026-06 via a schema
  type-union + `JsonCoerce.Unwrap`). Note: `TypeSerializedProperty.SetValue<T>`
  (`ReflectionSerializedObject.cs:89`) dispatches on `value.GetType()`, so a
  correctly-boxed value sets fine — it was never the culprit; the old failure was
  the transport stringifying untyped `value` args.
- `model_list_body_groups` takes a `path` parameter (e.g.
  `models/citizen/citizen.vmdl`), **not** a `model` parameter.
  Same goes for `model_list_bones`, `model_list_attachments`,
  `model_list_hitboxes`.
- `sdocs_*` queries leave the local machine. The `sdocs_*` family
  proxies to a hosted Meilisearch-backed service at
  `https://sdocs.suiram.dev/api/v1/mcp` — query strings and the
  symbol names you pass in are sent over the network. For symbol
  names extracted from private project source, prefer the local
  `schema_*` family (signatures) or `docs_*` (prose). Reach for
  `sdocs_*` only when the query is a generic concept ("component
  update loop", "razor reactivity") rather than a verbatim
  identifier from your code. Override the base URL via an env var on
  the editor process or through
  `game/data/claude-sbox-config.json` (`claude-sbox.sdocs_base_url`).
- `codesearch_*` queries also leave the machine, and the driver has a
  lifecycle. The tools live-scrape sbox.game/codesearch (a Blazor
  Server SPA) via a headless Chromium, so query strings hit the
  network — same privacy posture as `sdocs_*`: don't pass verbatim
  private-source identifiers. The driver is a prebuilt DLL loaded
  from `<game>/.claude-sbox/codesearch-driver/runtime/`; if a call
  returns `codesearch_driver_unavailable`, run `codesearch_install_driver`
  once (needs the .NET SDK) and retry — it loads lazily, no restart.
  But a `codesearch_install_driver force:true` REBUILD over an
  already-loaded driver needs an **editor restart** to take effect
  (`Assembly.LoadFrom` caches the assembly for the process lifetime).
  Run `codesearch_status` to see `driver_loaded` / `load_error`.
- `auto_*` tool names use underscores **only**. The conceptual
  identity returned by `auto_list` is `auto:Editor.EditorScene.Copy`,
  but the actual MCP tool name is `auto_Editor_EditorScene_Copy`
  because `:` and `.` are illegal characters in MCP tool names. The
  bridge dispatcher accepts both forms; the deferred-tools list
  surfaces the underscore form. When constructing a name from a
  `Type.FullName` plus method name, replace every `.` with `_`.
- `nodegraph_list_node_types` is **lazy** — it only enumerates node
  types that the currently-open graph editor has registered. With no
  `.action` open, expect a single result
  (`Common Nodes/No Operation`). To enumerate ActionGraph node
  types, open an `.action` file first via `open_asset(path)`. The
  same pattern applies to ShaderGraph (`.shdrgraph`). Verified live;
  this is not a bug — node-type registration is editor-state
  dependent.
- `widget_drag` is best-effort. Qt's `MouseEvent` constructor is
  marked `internal`, so a number of widgets reject the synthetic
  press / move / release events the bridge fabricates via
  reflection. For sliders, prefer `set_slider_value`; for gizmos,
  `batch_transform`; for unknown widgets, call `inspect_widget`
  first to see whether `OnMousePress` / `OnMouseMove` /
  `OnMouseRelease` are public on the concrete runtime type.
  Sliders and scrollbar handles work; some custom controls do not.
- `learn_search` rejects an empty/missing `query` *only* when no
  facet filter is also supplied. The combination "empty query + at
  least one of `difficulty`/`topic`/`content_type`/`author`/`tags`"
  is the intended shape for "give me a beginner networking
  tutorial" — the handler falls back to a community-signal score
  (`rating × 10 + log(views) + upvotes − downvotes`) to rank inside
  the filter set. If you forget the filter, expect a 400
  `bad_request` with the message "must provide either 'query' or at
  least one facet filter". This is opposite to `docs_search`, which
  requires `query` unconditionally.
- `bootstrap_engine` with stage `engine` fails while the editor is
  running because `bin/managed/*.dll` are file-locked by the live
  process. The `shaders` and `content` stages are safe with the
  editor up. To rebuild engine DLLs: ask the user to save and close
  the editor first (or call `auto_Editor_EditorScene_SaveAllSessions`
  and dispatch a window-close), then run `bootstrap_engine` with
  `engine`. Default timeout is 1800 seconds (30 min); a fresh build
  with a cold `dotnet restore` can easily blow past that. Windows
  only — `bootstrap_engine` shells out to `Bootstrap.bat` at the
  sbox-public root.
- `gameobject_add_component` can fail with `no_typedesc`
  ("TypeLibrary has no entry for X") on a type that resolved fine
  moments earlier. Trigger: a project **recompile/hotload** in the
  same session leaves a *pre-existing* (already-loaded) type with a
  stale duplicate `TypeDescription`, and the reflection resolver binds
  the old, unregistered copy. Brand-new types created *after* the
  recompile resolve fine; only types that existed before it go stale.
  Retrying the add or using the fully-qualified name does **not** help —
  **only an editor restart clears it** (the scene reloads from disk and
  the TypeLibrary is rebuilt clean). Practical consequence: don't
  remove-then-re-add a pre-existing component across a recompile via the
  bridge. If you must change a component's serialized default, edit the
  code default and either (a) restart so the disk scene reloads, or
  (b) toggle the value in the inspector — don't delete the component
  expecting to re-add it.

## Making runtime-built GameObjects click-selectable in the viewport

A plain `ModelRenderer` registers **no gizmo hitbox**, and the scene editor's
click-to-select is a native pick that doesn't reliably cover GameObjects you
build **procedurally at runtime** (a tool/component spawning meshes). Symptom:
the objects show in the hierarchy and render fine, but you cannot click them in
the viewport to select them. Components that *are* viewport-clickable (e.g.
`SpawnPoint`, `SpriteRenderer`) opt in by registering a hitbox in their own
`DrawGizmos`.

To make your runtime children clickable, register a hitbox per object in a
component's `DrawGizmos` and select on click:

```csharp
protected override void DrawGizmos()
{
    if ( !Scene.IsEditor ) return;
    foreach ( var go in myRuntimeObjects )
    {
        using ( Gizmo.ObjectScope( go, go.WorldTransform ) )
        {
            Gizmo.Hitbox.BBox( renderer.Model.Bounds );   // click anywhere on the prop
            // or: Gizmo.Hitbox.Sprite( Vector3.Zero, 28f, worldspace: false ); // a screen-space label
            if ( Gizmo.WasClicked )
                using ( Scene.Editor?.UndoScope( $"Select {go.Name}" ).Push() )
                    Gizmo.Select();   // selects Gizmo.Object, set by ObjectScope
        }
    }
}
```

- **`Gizmo.Hitbox.Model(model)` does NOT work for runtime-built models** — they
  have no trace mesh, so it produces no clickable area (the object shows a name
  label but the mesh body is dead to clicks). Use `Gizmo.Hitbox.BBox(model.Bounds)`
  (whole prop) or `Gizmo.Hitbox.Sprite(center, pixels, worldspace:false)` (a
  screen-space disc, e.g. over a name label). Both work reliably.
- `Gizmo.Draw.ScreenText(...)` is **purely visual** — registers no hitbox, so a
  text label is never clickable on its own. Pair it with a `Sprite` hitbox.
- `Gizmo.ObjectScope(obj, tx)` sets `Gizmo.Object`; `Gizmo.Select()` then selects
  *that* object. Hover is keyed by path, so a nested ObjectScope's hitbox selects
  the nested object, not the component's own GameObject. Wrap `Select()` in
  `Scene.Editor?.UndoScope(name).Push()` to make it undoable — exactly what the
  engine's own `GameObject.GizmoSelect` does.
- Component `DrawGizmos` runs every editor frame regardless of selection (gated
  only by the viewport's global Gizmos toggle); hitboxes are always live in edit
  mode. They do **not** run in Play (`Scene.IsEditor` is false there).
- `Gizmo.Settings` is **null outside a gizmo draw pass**, so bridge tools
  `get_gizmo_state` / `is_gizmo_enabled_for_type` / `list_gizmo_disabled_types`
  return `no_gizmo` when called cold. That's expected, not a failure.

## Runtime-built GameObjects must be flagged NotSaved, or they serialize as "white boxes"

A component that builds geometry **procedurally at runtime** (spawns child
GameObjects with `ModelRenderer`s whose `Model` is a `Model.Builder` mesh, or
materials made via `Material.Create`/`FromShader`) MUST flag the built root
`GameObjectFlags.NotSaved` immediately after creating it:

```csharp
_root = new GameObject( GameObject, true, "BuiltStuff" );
_root.Flags = GameObjectFlags.NotSaved;   // excludes the whole subtree from disk + Play-clone
```

`GameObjectFlags.NotSaved` (value 2, "Don't save this object to disk, or when
duplicating") propagates to descendants — serialization skips the subtree.

**Why it matters — the failure is silent and confusing.** If the root is *not*
flagged and `save_scene` runs while the geometry is built (e.g. you pressed a
"Build"/"Reload" button, then saved), the editor bakes every runtime
`ModelRenderer` into the `.scene` JSON. A procedural `Model` / runtime `Material`
**cannot round-trip through serialization** — there's no asset path to reload
from — so on the next scene load the renderers come back with a null/default
model and render as plain **white boxes**. Tells: the `.scene` file balloons
from a few hundred lines to tens of thousands; the hierarchy shows the built
children but with no rebuild log line; everything is white/untextured.
- This also fixes the **enter-Play double-geometry** trap: without `NotSaved`,
  the edit-mode build gets cloned into the Play scene *and* the component's
  `OnStart` rebuilds it → two overlapping copies (double colliders). `NotSaved`
  stops the clone; only the component persists and it rebuilds once on load.
- Recovery if a scene is already polluted: recompile with the flag added, press
  the component's rebuild button (it should sweep prior built children by name),
  then `save_scene` — the file shrinks back to just the component. Verify with a
  line count on the `.scene`.
- Don't confuse with `Hidden` (1, hides in hierarchy/inspector) or `EditorOnly`
  (2048, never spawns in game). You want `NotSaved` specifically.

## Hotload discards a field's value when its TYPE changes

Changing a field's type mid-session — e.g. a tracking list from
`List<(GameObject, string, bool)>` to `List<(GameObject, string, bool, Model)>`,
or any other type change — makes the hotloader log

> `Field has changed type, so values of the old type will be discarded`
> `  Member: YourType._field`

and **wipe that field** on the hotload. For a collection populated at runtime
(not from the serialized scene) it becomes **empty** until something rebuilds it.
The trap: code that iterates it (gizmos, per-frame logic) then silently does
nothing — **no error, no exception** — so a feature that worked a moment ago just
stops. This cost a long debugging detour: editor gizmos + a click-to-select
feature went dead after such a hotload, and only a map *reload* (which
repopulates the list) brought them back. Adding/removing fields and plain value
changes hotload fine — only a **type change on an existing field** triggers the
discard. After an unavoidable type change, re-run whatever rebuilds the runtime
data (`[Button] Reload`, re-run the generator) rather than trusting the hotload.

## Bridge tool reliability

- `editor_state` was observed to hard-fail once with `NotImplementedException:
  Unable to upgrade delegate methods without declaring types` and stay broken
  across a restart (**claude-sbox v0.0.109 only** — verified working in current
  builds). If it ever recurs, route around it: `get_active_scene` (scene name +
  source path), `compile_check_build_state` (build state), `ping` (liveness), and
  `game_action_list` (errors `not_in_play_mode` when stopped, succeeds when
  playing) together reconstruct everything `editor_state` would have told you.
  `doctor` also still works.
- `set_property` now coerces **bool / Vector3 / float / Color / asset-handle**
  values correctly (fixed 2026-06 — see the dedicated "set_property coercion"
  section below for the full story and the still-true caveats). The old
  "only string/Guid/enum work" limitation is **gone**; don't drive bools/floats
  from a `[ConCmd]`/sibling-component just to dodge it.
- **No game-input injection** (`send_keys` posts Qt events the game-input layer
  ignores), so you still **cannot script a player-motion test** (WASD/jump/stairs)
  or exercise a key-bound toggle from the bridge — and `Rigidbody.Velocity` /
  `WorldPosition` writes no-op in edit mode (runtime-physics props need Play).
  Validate at-rest invariants (grounded, no drift, no fall-through) via
  `get_property`, and hand dynamic feel tests to the user. To move something for
  a test, a sibling component that sets it in code (then hotload) still works.
- After a burst of source edits, the editor drains a queue of recompiles
  and the scene can repeatedly re-bootstrap (any self-spawning
  `OnActive` scene gets new GameObject ids each pass). Targeted
  `set_property`/`get_property` by id will race this with
  `gameobject_not_found`. Let compiles settle
  (`compile_check_build_state` → `any_building:false`) before grabbing
  ids, and re-list right before you act on them.
- `wait_for_scene_state(target:"playing")` frequently returns
  `matched:false` with the `scene.session.save` event instead — the
  pre-play session save fires first and satisfies the waiter. Don't
  treat that as "didn't enter play"; confirm with `game_action_list`
  (or `find_gameobject_by_path` for a runtime-spawned object).

## Cloud assets + mounting

- `asset_mount` must run on the engine **main thread**, which in
  practice means the editor has to be in **edit mode** — calling it
  while a scene is playing throws `MountAsync threw: DownloadAndMount
  must be called on the main thread!`. Stop play first
  (`auto_Editor_EditorScene_TogglePlay`, confirm via `editor_state`
  / `game_action_list`), then mount.
- Mount idents **one at a time**, not in a parallel tool batch.
  Firing several `asset_mount` calls in one message races the
  main-thread dispatch and they all fail with the same main-thread
  error. Serial calls (each awaiting the previous) succeed and each
  returns the resolved `primary_asset` vmdl/vmat path you then feed to
  `Model.Load`.
- `asset_query_state` / `find_asset` only see the **local project
  Content** scope — they return `asset_not_found` for models that
  live inside a *mounted cloud package*, even when those models load
  fine at runtime. Don't treat that as a missing asset. To verify a
  cloud model resolves, load it at runtime and read it back: enter
  play, then `get_property(renderer, idx, "Model")` should report
  e.g. `Model:v_recoillessrifle`. The mount call's `primary_asset`
  field is the authoritative path.
- Cloud weapon naming convention (Facepunch `sboxweapons` collection):
  `v_*` idents are **rigged first-person viewmodels** that ship with
  an embedded animgraph; bare / `w_*` idents are third-person world
  models with LODs + collision. Mounting a `v_` ident pins it into the
  active `.sbproj` `PackageReferences` (with `pin_to_project:true`) so
  it auto-mounts next session.

## First-person weapons (the sboxweapons animgraph system)

- Bonemerge direction is **arms → onto → weapon**, the opposite of the
  Source 1 convention. The weapon viewmodel owns the skeleton (it has
  baked arm + finger + `camera` bones); set the *arms* renderer's
  `BoneMergeTarget` to the *weapon* renderer, not the reverse. Getting
  this backwards leaves the hands detached.
- When using the **citizen** arms (`v_first_person_arms_citizen`), tell
  the weapon animgraph via `weaponRenderer.Set( "skeleton", 1 )`
  (0 = human, the default). Skipping this misaligns the hands slightly.
- Drive everything through `SkinnedModelRenderer.Set( string, value )`
  overloads (bool / int / float / Rotation / Vector3). Key params:
  `b_grounded`, `b_jump` (self-resetting), `b_sprint`, `move_bob`
  (0–1), `b_attack` (self-resetting, also used by melee which auto-
  chains swings), `b_attack_dry` when empty. Reloading the renderer's
  `Model` re-inits the animgraph and replays the **deploy** animation —
  so a weapon swap that sets a new model gives you the draw anim for
  free.
- The animated `camera` bone (a root bone on each viewmodel) is meant
  to **add onto** your in-game camera for recoil/deploy view-kick.
  Read it with `weaponRenderer.TryGetBoneTransformLocal( "camera", out
  var tx )`; if the viewmodel object is parented to the camera at
  identity local transform, `tx` is already in camera-local space, so
  `cam.WorldPosition += cam.WorldRotation * tx.Position`. Apply it
  *after* you set the base eye transform or it gets overwritten.
- Viewmodels are local cosmetic-only: build the renderer hierarchy at
  runtime (not network-spawned) and gate the owning component on
  `IsProxy` so remote players never spawn one. Put that component on
  the **networked root** (where `IsProxy` is meaningful), not on a
  non-networked child like the camera object.
- **Viewmodel clips into the camera ("I can see through it").** The
  `CameraComponent` default `ZNear` is **10**, which culls the close
  first-person geometry. Lower the *main* camera's `ZNear` (~1). Keep
  the viewmodel in the **main camera** so its shading is unchanged.
  - **Cost:** `ZNear` is the *whole scene's* near plane, so it sets
    depth-buffer precision globally. Dropping it to ~1 on a large map
    degrades depth-driven post effects (GTAO/SSAO, SSR) — see the SSAO
    note below. Lower it only as far as the viewmodel actually needs,
    and prefer pushing the gun back (so it clears a higher `ZNear`)
    over collapsing precision for the entire world.
- **Don't "fix" clipping with a separate depth-clearing viewmodel
  camera unless you replicate post-processing.** A second
  `CameraComponent` (`RenderTags "viewmodel"` + `ClearFlags.Depth` +
  small `ZNear`, main camera gets `RenderExcludeTags "viewmodel"`)
  *does* stop near-plane + wall clipping — but if the project has **no
  post-process components**, that overlay camera skips the engine's
  default tonemap/auto-exposure, so the weapon renders visibly brighter/
  flatter than the tonemapped world. Either keep the viewmodel in the
  main camera (simplest) or re-apply the same tonemap on the overlay.
- **Stop the barrel poking through walls dynamically.** Each frame trace
  forward from the eye and retract the model along the view by
  `reach − hitDistance` (eased). Make `reach` *per-weapon* by measuring
  the weapon's forward extent from `SkinnedModelRenderer.Bounds.Corners`
  projected onto the view dir — a fixed reach leaves long guns (shotgun)
  still clipping. Add the current retract back into the measured reach
  each frame so the value doesn't feed back on itself.
- **FIRE is an ADDITIVE over a base Deploy→Idle/Reload state machine — you
  CANNOT make a shot "replace"/cancel the draw or reload from code params.**
  (Confirmed by decompiling the graph: node comments say "Mix additives onto
  animation" / "Fire additive SM".) `b_attack` layers the fire pose on top of
  whatever the base SM is playing; if the draw is still running, you see the
  draw + a fire twitch, not a clean fire. The base SM only leaves Deploy when
  the **draw clip finishes** (there is no deploy→fire transition). Things that
  do **NOT** work and are dead ends (burned a lot of time here):
  - `b_deploy_skip` is an **entry-only** selector flag. The graph enters Deploy
    the instant you assign `Model`, so setting it *after* (the only time you
    can — the graph doesn't exist before the model) is too late. Holding it
    true every frame doesn't cut an in-progress draw either.
  - `speed_deploy` scales the draw clip but the deploy→idle exit isn't reliably
    tied to it, so cranking it doesn't guarantee the draw is "done" by the fire
    gate.
  - **`UseAnimGraph = false` is NOT a clean escape hatch.** You lose *every*
    layer at once — `move_bob`/walk, jump/land, idle breathing, the additive
    fire, and reload — and the model still plays its default sequence (often the
    draw), so you get a broken viewmodel, not "no draw". Don't go here to kill
    the draw.
  - The honest fix for changing deploy/fire/reload interaction is to **edit the
    animgraph asset** (author fire as absolute, or add/disable the transition),
    not to fight it from C#. Leave the viewmodel graph-driven. You can now do this
    over the bridge without the native editor: `animgraph_source_inspect(path)` to
    find the state/transition that plays the draw, then `animgraph_set_transition_disabled`
    (kill the edge into the deploy state) or `animgraph_set_node_property` (repoint/blank
    the sequence), then `animgraph_edit_save`. See `references/mcp-tools.md` § Animgraph source.
  - Shotgun reload is a real per-shell chain in the model (`reload_entry` →
    `reload_firstshell` → `reload_shell`×N → `reload_exit`); it's sequenced by
    the graph's reload params, not a single `b_reload` bool.
  - To recover the real param/clip names: if the `.vanmgrph` **source** is present,
    `animgraph_source_inspect(path)` gives parameters, sequence-node names, and the
    state machine directly (no decompile). Only if you have **just the compiled
    `.vanmgrph_c`** (find it via the `.vmdl_c` RERL refs) fall back to decompiling it:
    Source 2 resource; the `DATA` block is KV3v3 (magic `02 33 56 4B`), usually
    LZ4-compressed — decode the single block (compressedSize→uncompressedSize) and the
    string table is the tail after `cnt_bin + cnt_int*4 + cnt_8*8` bytes.
- **Setting `b_deploy_skip` BEFORE assigning `Model` also fails — and the reason is
  worth knowing.** You'd think `Set("b_deploy_skip", true)` before `Renderer.Model = x`
  would stick (SkinnedModelRenderer stores params and re-applies them via
  `ApplyStoredAnimParameters` when the SceneObject is created, before the first tick).
  But reassigning `Model` on an **already-enabled** renderer does NOT recreate the
  SceneObject — `ModelRenderer.UpdateObject` just swaps `_sceneObject.Model = x` in
  place, so `OnSceneObjectCreated`/`ApplyStoredAnimParameters` never re-run and the new
  animgraph inits with the param back at its default → deploy plays. (Stored params only
  apply on a *fresh* SceneObject, i.e. the renderer's first enable.)
- **What DOES work to kill the deploy from C# without editing the graph: fast-forward
  the animgraph past it.** On a fresh equip, set `Renderer.PlaybackRate` very high (e.g.
  60) for the first ~2 frames, then restore `1`. 60×dt advances ~1s of graph time per
  frame, so the ~0.5s deploy completes (lands in idle) before it's ever rendered.
  Pair it with a **procedural transform offset** (slide/rotate the model in over ~0.3s,
  same mechanism as the wall-pushback retract) for a clean "programmed draw" that
  replaces the baked swing. The rest of the graph (idle/fire/bob) is untouched.
- **Hiding only the GUN mesh (no arms):** the arms are a *separate* renderer bonemerged
  onto the gun (the `v_` model is gun-only), so just don't enable/load the arms renderer
  — the gun's animgraph is unaffected. (Toggle live by loading/clearing the arms `Model`
  + `Enabled`.)

## Skeletal animation: blending two sequences on one model

- `SkinnedModelRenderer` plays exactly **one** `Sequence` at a time
  (`Sequence.Name`, plus writable `Sequence.Time`/`TimeNormalized`/
  `PlaybackRate`/`Duration`). There is **no** "sample sequence X for bone
  Y" API, so a GoldSrc-style legs/torso split (legs on a walk cycle,
  torso on an aim pose) can't be done by the renderer alone.
- Pattern that works: keep the raw per-frame, **parent-relative local**
  bone transforms at build time (`ModelBuilder.AddFrame` is fed exactly
  these), sample two sequences yourself, merge per bone, FK from identity,
  then write every bone with `SetBoneTransform(bone, modelSpaceTransform)`.
- **Bone space mismatch (verified in engine source) — this WILL bite you:**
  the GET side (`TryGetBoneTransform`/`TryGetBoneTransformAnimation`/
  `GetBoneTransforms(true)`) returns **scene world**, but the SET side
  (`SetBoneTransform` → `SceneModel.SetBoneOverride`) wants **MODEL space**
  ("local coordinates based on the SceneModel's transform" — relative to the
  renderer GameObject, NOT scene world). They are *different spaces*. So a
  read-modify-write of one bone only looks right when the renderer transform
  is near-identity; for a full manual pose, FK from **identity** (roots = the
  bone's own parent-relative local, children accumulate) and write that —
  the GameObject's WorldTransform then orients it. Writing scene-world here
  double-applies the object transform → the model spins and flies off.
  Compute foot-plant / lowest-vertex from your own model-space pose too;
  overrides aren't guaranteed to read back through `GetBoneTransforms`.
- `TryGetBoneTransformLocal` / `Bone.LocalTransform` are parent-relative.
  `BoneCollection.Bone` exposes `Index`, `Parent`, `Children` — GoldSrc
  skeletons are position-indexed (`AllBones[i].Index == i`) and parent-
  before-child, so FK can iterate by index and read `pose[parent.Index]`.
  Validate that assumption and bail if it fails.
- Per-frame `SetBoneTransform` on every bone coexists fine with the
  renderer's own animation (the overrides win for that frame) and with a
  separate foot-plant pass that reads `GetBoneTransforms(true)` after.

## SkinnedModelRenderer: first Model assignment skips the bind pose

- The **first-ever `Model` assignment** to a freshly-created `SkinnedModelRenderer`
  doesn't apply the model's bind pose — the mesh renders in a default/zero pose.
  Symptom: a prop you snap to a bone (e.g. a weapon parented/positioned onto a
  hand) renders **detached / floating** on spawn, even though your placement math
  is provably correct (log the target transform — it's identical before and after).
- Re-assigning the **same** model, or `null`→model, does **NOT** rebuild it (and
  null→model can actively reproduce the broken pose). Only a change to a
  **different valid model and back** forces the bind-pose rebuild — which is why
  "switch weapon and switch back" fixes it by hand.
- Fix: on first load, bounce the renderer through a throwaway valid model
  (`Model.Load("models/dev/box.vmdl")`) for one frame, then set the real model.
  Gate it to the first assignment only (a one-shot countdown) — later genuine
  model changes rebuild on their own, and bouncing them re-introduces a flicker
  or, if you reload the *same* model each frame, re-breaks the pose. Expect a
  1-frame flicker on spawn.
- Debugging tip: world-space bone transforms are confounded by facing (yaw). To
  compare a prop's placement across states, read its `LocalPosition`/`LocalRotation`
  relative to a body object that's already yaw-aligned, or log the prop-to-bone
  delta vector — that's facing-independent.

## Recompiling a shader pinks already-built materials in the editor

Editing/recompiling a `.shader` invalidates the compiled `shader_c` that
**already-built `Material` instances** point at, so anything using that shader
renders **pink (error checkerboard) in the editor scene view** until its
materials are rebuilt. A fresh Play session (or any code path that re-creates
the materials via `Material.Create`) binds the new `shader_c` and looks **fine**
— so the tell is **"pink in editor only, fine in game."** It is *not* a compile
error (the shader compiles); it's a stale handle.

- Don't panic-revert: confirm the shader compiles (`asset_compilation_control(
  path, mode:"compile", full:true)` → `success:true`), then **rebuild the
  materials** — reload/regenerate whatever created them (a map/asset reload
  button, re-enter Play, or re-run the generator). Reverting the shader edit just
  triggers *another* recompile and the same staleness.
- Extra caution with **shared shaders**: one `.shader` is often used by several
  systems (e.g. a "world" shader reused for props and dev materials). A change
  you make for one consumer recompiles it for **all** of them and pinks every
  material in the editor that references it. Check who else uses a shader (grep
  `Material.Create( …, "shaders/foo.shader" )`) before editing it, and prefer a
  separate shader (or a `Feature`/`StaticCombo`) over adding consumer-specific
  logic to a shared one.
- **You can't auto-rebuild on recompile from game code (verified dead-end).** The
  shader-recompile event `EditorEvent.Run("compile.shader")` only dispatches to
  **editor assemblies** (`assembly.IsEditorAssembly`), and a `[Event("hotloaded")]`
  static handler in a *game* project assembly **never fires** (confirmed with a
  diagnostic log). The only hook that works is a project **editor assembly**
  (`Code/Editor/` → `<pkg>.editor`) with `[Event("compile.shader")]`. For a
  dev-time-only annoyance it's not worth it — just rebuild manually.
- **A brand-new `.shader` doesn't index mid-session.** `asset_compilation_control`
  with an `Assets/…` path returns `asset_not_found` — use the **content-relative**
  path (`shaders/foo.shader`, no `Assets/`). And a runtime
  `Material.FromShader("shaders/foo.shader")` evaluated (e.g. in a `static` field)
  **before that shader first compiles** caches an *invalid* material that renders
  nothing — so a freshly-added post/blit shader silently "does nothing" until you
  compile it (correct path) AND hot-reload the C# so the static re-evaluates.
- **A custom post-process / blit shader that fails to *compile* is the silent
  killer — nothing surfaces in-game.** `BasePostProcess.Blit` early-outs on
  `if ( !blit.Material.IsValid() ) return;`, so an invalid material = the whole
  effect is a no-op with **zero error in the game log**. Root cause is usually a
  shader compile failure: `Material.FromShader` returns invalid and no `.shader_c`
  is ever produced.
  - **Fast diagnosis:** `ls` the shader folder — every healthy custom shader has a
    sibling `foo.shader_c`. The one effect "doing nothing" is the `.shader` with
    **no `_c`**. Then `asset_compilation_control("shaders/foo.shader", mode:"compile",
    full:true)` and read `tail_log(min_level:"trace")` — the tool's `success:true`
    is **unreliable**; the real verdict is a `Done N combos` line (good) vs an
    `hlslParser.Parse err: ANTLR - Mismatched Token` warning (bad). `.shader_c` is a
    gitignored build-on-demand artifact, so a source that never parsed simply never
    has one.
  - **`static const` at PS-block scope breaks the VFX HLSL parser.** A line like
    `static const float3 LUMA = float3( ... );` between the `< Attribute(); Default(); >`
    globals and the functions throws the ANTLR mismatched-token error above. Use a
    `#define LUMA float3( ... )` (or a function-local `const`) instead. Verified fix.
  - **Make the material self-healing, not a one-shot `static readonly`.** Engine
    effects cache `static Material Shader = Material.FromShader(...)` safely *because
    engine shaders are always precompiled*; a project shader may not be. Use a lazy
    getter that re-fetches until valid:
    `static Material _m; static Material M => _m is {} && _m.IsValid() ? _m : (_m = Material.FromShader(path));`
    so the effect recovers on its own once the shader compiles, instead of staying
    dead forever from one bad early init.

## Post-process effects are camera-bound; configure the native stack, don't port a renderer

s&box ships the whole post-process stack as components — `Tonemapping`
(HableFilmic/ACES + auto-exposure), `Bloom`, `ColorAdjustments`, `AmbientOcclusion`,
`ScreenSpaceReflections`, `Vignette`, `Sharpen`, `FilmGrain`, `ChromaticAberration`,
`DepthOfField` — plus `GradientFog` / `VolumetricFogController`+`Volume` / `SkyBox2D`
(IBL ambient) / `DirectionalLight.FogMode`+`FogStrength` (god-ray shafts). To match a
"realistic / cinematic" look, CONFIGURE these (and add a custom grade pass) rather than
porting another engine's renderer — a foreign deferred pipeline won't bind to Source 2's
forward renderer anyway; only the *techniques + tuning values* transfer.

- **They only apply on the camera they live on** — gathered via
  `camera.GetComponentsInChildren<BasePostProcess>()`. A runtime/player camera exists
  only in **Play**, so the effects (and any custom pass) show in Play, not the editor
  viewport (which renders through its own camera). Lights/fog/sky are scene-global and
  *do* show in the editor.
- **Custom pass:** subclass `BasePostProcess<T>`, hold the material in a `static
  Material.FromShader(...)`, and in `Render()` set `Attributes.Set(...)` then
  `Blit( BlitMode.WithBackbuffer( mat, Stage.AfterPostProcess, order ), name )`. The
  shader samples `g_tColorBuffer` (the grabbed backbuffer) at
  `i.vPositionSs.xy / g_vRenderTargetSize`. Copy `postprocess/pp_color.shader` as the
  template; `Default3(…)` is valid for `float3 < Attribute >`.
- **SSAO over-darkens bumpy/displacement geometry** (it self-occludes far more than flat
  walls) — tessellated terrain reads murky/"darker than the rest" with edge/grid "lines."
  s&box SSAO is **GTAO** (`gtao_cs.shader`): depth-driven, reading a `NormalsGBuffer` and
  **reconstructing normals from depth derivatives when that normal is zero**. Things that
  matter, in order:
  - **Depth-buffer precision.** GTAO lives or dies on linearized depth. A very low main-camera
    `ZNear` (e.g. the ~1 used to stop viewmodel clipping — see the viewmodel `ZNear` note above)
    collapses precision on a large map, so GTAO bands and over-occludes large/distant surfaces
    (displacements) while close brushwork/props stay clean. Raising `ZNear` toward the 10
    default is the first thing to try; it trades against viewmodel clipping (decouple them if
    you need both — keep the world `ZNear` high, solve the gun clip another way).
  - Radius + intensity: keep modest; large radius darkens terrain more.
  - **Ruled-out (verified dead-ends, don't repeat):** double-sided / coincident world triangles
    are **not** the cause — the color pass shades them identically so it's invisible there, and
    single-siding the geometry changed nothing. Per-material normal smoothing leaves interior
    displacement verts untouched (single-bucket → unchanged), so it isn't corrupting them either.
- **A "panel" component that drives the native effects each frame from `[Property]`
  fields** makes inspector edits live — but then editing the native effect components
  directly "snaps back" (the panel is the source of truth, re-applying every frame). So
  expose EVERY knob on the panel, including tonemap `Mode` and `AutoExposureEnabled`,
  or those become un-changeable. Persist via `Game.Cookies` (the global `Cookie` is
  obsolete → CS0618).

## Runtime alpha-tested textures need colour-bleed, or mips render them dark

When you build a runtime `Texture.Create(...).WithData(rgba).WithMips()` for an
**alpha-tested / masked** material (transparent texels alpha 0) and you set those
transparent texels' RGB to a constant like **black**, bilinear filtering + mip
generation blend that black into the kept (alpha>0.5) edge texels and **darken
the surface toward black** — worse the more transparent the texture is (a mostly-
transparent texture goes near-solid black; a mostly-opaque one looks fine). The
alpha-test (`clip(a-0.5)`) is correct; the *colour* is the problem.

Fix: **alpha-dilate (colour-bleed)** the texture before `Texture.Create` — flood
every transparent texel's RGB with its nearest opaque neighbour's colour (a
multi-source BFS from all opaque texels is O(pixels)); leave alpha at 0 so the
cut-out is unchanged. Now filtering/mips never sample the constant fill colour.
This is the standard "alpha bleeding"/dilation step; do it for any masked runtime
texture, not just at mip 0 (lower mips average the whole image).

## schema_signature can't serialize overloaded members

- `schema_signature(type, member)` on a method with multiple overloads
  fails with "could not serialize tool result: Operation is not valid due
  to the current state of the object." Use `schema_lookup_type` (dump the
  whole type, grep the methods array) or `reflection_get_method_signature`
  instead. `execute_csharp` needs the Roslyn scripting assembly loaded
  (after the first engine compile); on a fresh/headless process it returns
  `scripting_unavailable` — fall back to `compile_snippet` for static checks.

## Live runtime debugging without a debugger (read component state over the bridge)

- When the user reports a runtime bug you can't reproduce (no WASD/mouse
  injection), have them reproduce and **freeze in the bad state**, then read
  the component fields with `get_property` — it's ground truth, better than
  guessing or adding log spam. `get_property` reads any public property
  (`IsOnGround`, `Velocity`, `Health`, even `WorldPosition` off a Component).
- **Read a changing value twice.** If `Velocity` (or any per-tick field) is
  byte-identical across two reads seconds apart, the component's
  `OnFixedUpdate`/`OnUpdate` is **not running** — it's disabled, the
  GameObject is inactive, it's an `IsProxy`, or the scene is paused. That one
  trick localized a "stuck after rocket jump" bug to a *disabled controller*
  (death disabled it; respawn failed to re-enable) — not a movement/collision
  bug at all. `get_components(id)` shows each component's `enabled` flag.
- To unstick / toggle a component live, use `gameobject_set_component_enabled`
  (fires OnEnabled/OnDisabled). This is also the only reliable way to flip a
  component on/off from the bridge — see the bool limitation below.
- **Reproduce a per-asset bug by driving the asset selector, not by waiting for
  RNG.** If a component picks its asset from a string `[Property]` (a model name,
  a sound path) and reloads on change, `set_property` it directly (strings DO
  coerce) to force-load the exact problem asset — even bounce A→B→A to force a
  rebuild when it's already on A. This let a "some downloaded player models are
  black" bug be reproduced on demand (set `PlayerModel.ModelName`) instead of
  re-rolling a random spawn. Pair it with a **temporary decode `Log.Info`** in
  the loader (dump per-texture/per-mesh stats, then read `tail_log`): that proved
  the textures decoded fine and the black was the **toon outline**, not the
  texture pipeline — a conclusion no amount of staring at code would have given.
  Remove the log after.

## set_property coercion: bool / Vector3 / float / asset-handles ALL work (fixed 2026-06)

**This is now fixed** — earlier builds couldn't set bool/Vector3/float/asset-handle
`[Property]`s over the bridge; that limitation is gone. If you hit a stale write,
re-read this whole bullet before assuming it's broken.

- **Root cause (for the record, so nobody re-diagnoses it wrong):** the failure was
  **not** an engine bug in `TypeSerializedProperty.SetValue<T>` (that method dispatches
  on `value.GetType()`, so a correctly-boxed value sets fine). It was the **MCP transport
  stringifying any tool argument whose inputSchema property has no declared `type`** — the
  polymorphic `value` arrived as a JSON *string* (`"false"`, `"3.5"`, `"{\"x\":1}"`), so
  every coercer branch that called `GetBoolean()`/`GetDouble()`/`GetProperty("x")` threw
  `coerce_failed: ... target element has type 'String'`. Only `GetString()`-based branches
  (string/Guid/enum-by-name) survived — which is why those always worked.
- **The fix** (claude-sbox addon): the polymorphic `value` params now declare a JSON-Schema
  type-union (`type: ["boolean","number","string","object","array","null"]`) so the client
  stops stringifying them, plus a defensive `JsonCoerce.Unwrap` re-parses any still-stringified
  payload. Applies to `set_property`, `set_preference`, `cookie_set`,
  `material_set_shader_parameter`, `set_widget_value`, `tab_select`,
  `select_dropdown_option`, `set_color`.
- **What you can now do directly:** set a `[Property] bool` (`value: false`), a
  `[Property] float` (`value: 3.5`), a `Vector3` (`value: {x,y,z}`), a `Color`
  (`{r,g,b,a}`), and an **asset handle** — pass a content path string for a
  `Model`/`Material`/etc. property (`set_property(..., "Model", "models/dev/box.vmdl")`
  resolves via the resource type's static `Load(string)`). enum-by-name / Guid / string
  still work as before. **Always still verify** `previous` vs `current` (good practice).
- **Genuinely-still-true caveats (NOT coercion failures):**
  - **Runtime-only physics props no-op in edit mode.** `Rigidbody.Velocity` /
    `AngularVelocity` accept the write (`ok:true`, no error) but read back unchanged when
    not playing — the `PhysicsBody` doesn't exist until Play. Use a *serialized* field
    (e.g. `MassCenterOverride`) to prove coercion; expect runtime-physics setters to be
    inert at edit time.
  - **`drop_asset_into_scene` still only resolves *project* assets**, not **mounted
    package** assets (returns `asset_not_found`) — but you can now `gameobject_create` +
    `gameobject_add_component(SkinnedModelRenderer)` + `set_property("Model", "<path>")`
    to build a renderer over the bridge, including for a mounted-package model path.
- **Changing a code default does NOT update an already-loaded scene/session.** A
  `[Property]` that's serialized in the `.scene` masks the code default, and the open
  edit session holds the value it deserialized at scene-open. So: editing the code
  default, editing the `.scene` file on disk, and (per above) `set_property` for a float
  all leave the **running** value unchanged. Symptom that wastes turns: "I set X but
  reload/Play still shows the old value." Only a **fresh load** applies a new default —
  i.e. an **editor restart** (re-reads scene/defaults) or the user **dragging the
  inspector slider** (the one reliable way to set a live float). When you change a
  look-critical default, tell the user it needs a restart/slider, don't assume your edit
  took. (And don't let them save the scene first — an in-memory stale value would
  overwrite your disk edit.)

## Custom rendering (Graphics.Draw / SceneCustomObject)

- **`Material.FromShader` / `Texture.Create` are MAIN-THREAD ONLY.** A
  `SceneCustomObject.RenderOverride` (and any hook that ends in `Graphics.Draw`)
  runs on the **render thread**. Creating a material/texture there throws
  `"Create must be called on the main thread!"` *every frame* → log flood +
  visible stall, and the resource stays null so nothing draws. Create eagerly on
  the main thread (component `OnEnabled`) and cache it; the render override must
  only *read* the cached handle. A lazy `=> _mat ??= Material.FromShader(...)`
  getter is the trap — if the first read lands on the render thread it fails
  forever (and silently renders nothing).
- **Runtime textures render PINK unless the shader has a `Default` AND you bind
  them.** A bare `Texture2D g_tColor < Attribute("X"); >` samples the pink error
  texture when unset. Give it `Default4( 1,1,1,1 )` (white fallback, never pink)
  AND bind it: for `Graphics.Draw`, build a `RenderAttributes` on the main thread,
  `attr.Set("X", texture)`, pass it to `Draw`. (`material.Set("X", tex)` also
  works once the material exists.)
- **`Graphics.CameraPosition` / `CameraRotation`** are available inside the render
  override for billboards/camera-facing quads. Vertices are world-space; a minimal
  unlit shader does `Position3WsToPs(v.WorldPosition)` and copies
  `v.Color → i.vVertexColor`. The common `vertexinput.hlsl` has **no** Color field —
  add `float4 Color : COLOR0 < Semantic( None ); >` to your VertexInput yourself.
- **Additive sprite blowout:** stacking many additive sprites saturates toward
  white and washes out per-particle tint. Expose a colour-multiplier knob (scaling
  blue/green down pulls a white core back to orange/yellow) instead of fighting it
  in the texture.

## Component init order: Create() runs OnEnabled *before* you set properties

- `go.Components.Create<T>()` on an **active** GameObject fires `OnEnabled`
  synchronously — so `[Property]` values you assign on the following lines are
  applied *after* the component already initialized with its **defaults**. A
  component that loads/parses something in `OnEnabled` based on a property will
  use the default, not what the factory sets. Symptom seen: a particle component
  loaded its default system name (continuous-emitting) instead of the one set
  right after Create → wrong effect that "lingered" forever. Fix:
  `Components.Create<T>( false )` → set properties → `component.Enabled = true`.
  (Or do the load in `OnStart`, which is deferred to the first tick.) Easy to
  miss when another call site happens to use defaults that match.

## Cloning a prefab reference: base-addon / resource prefabs are DISABLED templates

A prefab `GameObject` you get from a **resource** — e.g. a `Surface`'s
`PrefabCollection.BulletImpact`, or any base-addon impact/effect prefab — is a
**disabled template**. `prefab.Clone( pos, rot )` **inherits that disabled state**,
so the clone is **inert**: it never renders, AND none of its components update —
including `TemporaryEffect`, which means the clone **never self-destructs**, so the
scene hierarchy steadily fills with dead clones. Real symptom hit this session:
spawning a surface's bullet-impact prefab gave "no particles, no decal, and the
hierarchy is riddled with `default-bullet` objects." Fix — clone with an explicit
`StartEnabled`:

```csharp
var go = prefab.Clone( new CloneConfig {
    StartEnabled = true,
    Transform = new global::Transform( pos, rot ),
    Name = "impact",
} );
go.NetworkMode = NetworkMode.Never; // local cosmetic spawned per-peer; don't replicate
```

Note: project prefabs assigned in the **inspector** (a `[Property] GameObject`) are
usually already enabled, so their `.Clone(pos,rot)` works — it's the
**resource-loaded** prefab references (`Surface.PrefabCollection.*`,
`ResourceLibrary.Get<Prefab>`-style) that bite. When the same cosmetic is spawned on
every client via a broadcast RPC, also set `NetworkMode.Never` so the host doesn't
replicate a copy on top.

## Blood / impact effects: there's no C# API — it's the Surface prefab system, tuned on the clone

s&box has **no built-in blood or "TraceAttack" C# system** (grepping the whole engine,
"blood" is only an emoji + an icon). Damage code is expected to spawn the visual itself.
The mechanism is the **`Surface` resource's impact prefabs**:

```csharp
public SurfacePrefabCollection PrefabCollection;  // on every .surface
//   .BulletImpact : GameObject   // prefab spawned on a bullet hit (decals + particles + sound)
//   .BluntImpact  : GameObject   // melee / blunt hit
```

The base addon ships one prefab per material (`prefabs/surface/{metal,wood,glass,…,flesh}_bullet.prefab`)
and the matching `.surface` (`Assets/surfaces/*.surface`). **Blood is just the flesh one**:
`flesh.surface` → `flesh_bullet.prefab`, which is a `TemporaryEffect` (auto-cleanup) + a `Decal`
(random flesh splat) + several `ParticleEffect` children (`impact.flesh.mist` cloud, `blood.squirt`
jet, `blood droplets`). Spawn it for a player hit by cloning that prefab (see the disabled-template
gotcha above for the `StartEnabled` requirement) at the hit point, forward = travel direction.

**Modern particles are component-based, NOT `.vpcf`:** a `ParticleEffect` + emitter
(`ParticleConeEmitter`, …) + renderer (`ParticleSpriteRenderer`) on a GameObject. The legacy `.vpcf`
route still exists (`LegacyParticleSystem` component + `ParticleSystem.Load("…vpcf")` +
`SceneParticles`/`SetControlPoint`), but the base addon's blood/impacts use the component system, so
there is **no blood `.vpcf` to load** — you tune the cloned components.

**Tuning a cloned base-addon effect** (e.g. "the blood cloud lingers / drowns out the spray"): set the
knobs on the clone **right after `Clone()`** — it's synchronous, before the emitters' first tick, so it
takes. Match the right sub-effect by its child GameObject `Name`:

```csharp
foreach ( var pe in go.Components.GetAll<ParticleEffect>( FindMode.EverythingInSelfAndDescendants ) )
    pe.Lifetime = new ParticleFloat( 0.4f, 0.55f );          // base flesh = 2-3s → cloud hovered forever
foreach ( var em in go.Components.GetAll<ParticleConeEmitter>( FindMode.EverythingInSelfAndDescendants ) )
    if ( em.GameObject.Name.Contains( "mist", StringComparison.OrdinalIgnoreCase ) )
        em.Burst = 2;                                         // thin the "cloud"; bump "squirt" similarly
foreach ( var te in go.Components.GetAll<TemporaryEffect>( FindMode.EverythingInSelfAndDescendants ) )
    te.DestroyAfterSeconds = 0.9f;                            // it also WaitForChildEffects, so shorten Lifetime too
```

- `ParticleEffect.Lifetime`, and `ParticleEmitter.Burst`/`Rate`/`Duration` (on the **base** emitter
  class, so `ParticleConeEmitter` inherits them), are all `ParticleFloat` — which has an implicit
  `float` conversion and a `new ParticleFloat(a,b)` **range** ctor (Evaluation=Seed). Assigning an `int`
  works via int→float→ParticleFloat.
- `TemporaryEffect.DestroyAfterSeconds` + `WaitForChildEffects` control the GameObject's self-destruct;
  it waits for child particles, so to actually shorten the effect you must cut the particle `Lifetime`
  too, not just `DestroyAfterSeconds`.
- It's a local cosmetic: clone with `NetworkMode.Never` and spawn it from a broadcast RPC on the
  shooting client / host so every peer makes its own (don't replicate). One effect per *shot*, not per
  pellet, reads better and is cheaper.

## "Whitelist violation(s), build unsuccessful" is NOT a compile error (and the MCP says Success)

The MCP `compile_project` reports `succeeded: true` for a clean **C#** compile, but
s&box runs a **separate access-list (whitelist) gate** when loading the assembly into
the sandbox. A non-whitelisted API call passes the C# compile yet logs
`Whitelist violation(s), build unsuccessful.` (category `Compiler/local.<proj>`) and
the **previous assembly keeps running** — so your new code silently doesn't take
effect (you debug a "bug" in code that never loaded). Always confirm a real load via
`tail_log(min_level:"warning")` after compiling: a *fresh* whitelist error (newer
`seq`/`ts` than your edit) means find the blocked call; *stale* ones with old `seq`
are leftovers from earlier broken intermediate saves and can be ignored.

## A cached `Texture` handle goes invalid after a hotload or asset re-import

A `static Texture _tex` loaded once behind a one-shot latch (`if (!_tried) { _tried = true; _tex = Texture.Load(path); }`) **silently breaks** when the source image is re-imported (you edited/regenerated the PNG) or after some hotloads: the cached handle now points at a disposed texture, so `_tex.IsValid()` is false and your draw early-outs to *nothing* — even though a fresh `Texture.Load` of the same path works (which is why a bridge `texture_get_info` looks healthy while the UI shows blank). Symptom: a HUD icon/material that worked, then vanished right after you reprocessed its image. Fix: make the load **self-healing**, not latched — `if (!_tex.IsValid()) _tex = Texture.Load(path, warnOnMissing:false);` — so it re-acquires whenever the handle is null/stale, and caches once valid (no per-frame churn). Same pattern as the self-healing `Material.FromShader` getter under the shader-recompile gotcha.

## Runtime-generated textures/materials are cached for the whole session

A `[Property]` that feeds `Texture.Create` / `Material.Create` at build time (e.g. a
"normal-map strength" that regenerates normal maps from albedo) **won't visibly change
when you tweak it and rebuild within the same session** — the engine caches the
generated textures/materials, so a rebuild (e.g. a "Reload Map" button that news up a
fresh provider) reuses the first build's results. Symptom: "this slider does nothing."
Only a **fresh process** (editor restart → first-ever generation) picks up the new
value. So for these, treat the slider as restart-only: change the value, restart. (Note:
`set_property` *can* now write the float over the bridge — but it still won't take effect,
because the cached generated asset isn't regenerated mid-session. This is the
**serialization/caching** trap, independent of coercion: the value sets, the *output*
doesn't change until a fresh process.)

## Citizen cosmetics (.clothing) and attaching them to non-citizen skeletons

- s&box cosmetics are `Clothing` **GameResources** (`.clothing`, ext lives in
  `engine/.../Game/Avatar/Clothing.cs`). The core field is `Model` (a `vmdl`); the rich
  `ClothingCategory` enum has `Hat`/`HatBeanie`/`Hair`/`Facial`/… Dressing
  (`ClothingContainer.Dressing.cs`) attaches each item by creating a child
  `SkinnedModelRenderer` with `r.BoneMergeTarget = body` — i.e. **bonemerge, matched by
  bone name**. ~37 hat models ship under `addons/citizen/.../hat/` (always mounted).
- **Bonemerge only works if the skeletons share bone names.** Citizen hats are rigged to
  the *citizen* head bone, so they will NOT bonemerge onto a Valve-biped / GoldSrc
  skeleton (`Bip01 Head`). To wear a citizen hat on a foreign skeleton, don't bonemerge —
  load the hat on its own no-animgraph renderer and **snap it to the head bone each frame**
  by world transform with a tunable local offset (find the bone by name; read its world
  transform from your own FK on an override-driven path, else
  `Renderer.TryGetBoneTransform`). Same pattern works for any prop-on-bone (weapon-in-hand,
  hat-on-head). One global offset usually fits all hats (they share the citizen-head
  rigging); per-item offsets are overkill unless the meshes differ a lot.

## Inverted-hull toon outline: black hull pokes through layered models

A classic toon outline = a second renderer of the same model, every vertex pushed out along its normal, `CullMode FRONT`, drawn solid black → a thin silhouette. On **layered** models (a body mesh hugging just under clothing — common on community GoldSrc/anime player models) the inner mesh's expanded black hull pokes *through* the outer surface as **vantablack patches**, and **no `OutlineWidth` avoids it** (shrinking the hull just thins the patches; tightly-layered meshes sit sub-millimeter apart). The robust fix is **depth**, not width: push the hull **back in depth** in the outline VS so the model's own surface occludes it everywhere except true silhouette edges (where nothing is in front). Source 2 is **reverse-Z** (NDC z: 1=near, 0=far), so *farther* = smaller z: `i.vPositionPs.z -= bias * i.vPositionPs.w;` after `Position3WsToPs`. Expose `bias` as a tunable with a **signed** range so the user can flip it if your reverse-Z assumption is backwards. This makes outline width purely cosmetic (boldness) again. Separately, a model's flat pure-black texels (`black.bmp` straps/boots) render as a black void because `albedo 0 × lighting = 0` regardless of any min-brightness floor — give the lit shader a small **albedo floor** (`max(albedo, ~0.06)`) so they read as dark material that still catches light/rim.

**Also: the outline must alpha-clip the SAME masked/transparent texels as the body, or you get "black instead of transparency."** A masked GoldSrc skin (e.g. `Furrycomm.bmp`, texture flag `0x40`) decodes its color-keyed texels to alpha 0, and the body shader `clip(albedo.a - 0.5)`s them out. But if the outline shader just paints the hull solid black (never samples the texture), the black back-hull shows *through* the body's transparent areas → solid black where it should be see-through. Fix: bind the masked albedo to the outline material and `clip(Tex2DS(g_tColor, g_sAniso, uv).a - 0.5)` in the outline PS too (default the texture white so opaque models never clip). Caveat: a single shared `MaterialOverride` outline clips all meshes against one texture — fine for single-masked-texture models; multi-texture needs per-mesh outline materials.

## Misc bridge quirks seen this session

- `screenshot_scene_to_file` writes to **`game_root/screenshots/`**
  (`<sbox>/game/screenshots/sbox.<timestamp>.png`), NOT the project dir.
  Find it with `host_list_directory(scope:"game_root", path:"screenshots",
  glob:"*.png")`, newest mtime, then `Read` the absolute host path.
- **`screenshot_scene_to_file` renders the camera only — it does NOT include screen-space UI**
  (`ScreenPanel`/HUD panels). And `widget_capture_to_png` of the 3D viewport
  (`Editor.SceneRenderingWidget`) comes back blank (it's a GPU swapchain Qt can't grab), and its
  `save_to` is a path on the *editor host* (Windows here), not the agent's FS. Upshot: **you cannot
  screenshot the in-game HUD.** Don't try to verify UI work with a screenshot — see SKILL.md
  "Believe the user about what's on screen".
- `wait_for_scene_play` frequently returns `expired:true` even though Play
  *did* start (the event races the TogglePlay call). Don't trust the wait —
  verify by `list_gameobjects` (runtime objects like the spawned Player
  appear) or `last_scene_play`.
- `Components.Get<T>()` (the C# API, not a bridge tool) **skips disabled
  components by default** — pass `FindMode.EverythingInSelf` to include them.
  A `Get<T>()` that worked while a component was enabled returns null once
  something disables it; that exact trap left a respawn unable to re-enable a
  controller it had just disabled.

## Writing custom shaders (.shader)

- **No standalone shader compiler tool.** `shader_compile_and_check` reports
  `no_compiler` in this build. To compile a `.shader` you wrote: call
  `asset_compilation_control(path:"shaders/foo.shader", mode:"compile",
  full:true)` then read errors from `tail_log` (compile output is logged as
  `Compiling: ...` → per-line `error: ...` → `Shader compile failed` OR
  `Done N combos in Xms`). The `.shader_c` lands next to the source. Note the
  tool returns `success:true` even when the HLSL fails — trust the log, not the
  return value. A `Stall detected.` warn after a multi-second compile is benign.
- **Don't redeclare the common samplers.** `g_sAniso`, `g_sBilinearClamp`,
  `g_sBilinearWrap`, `g_sTrilinear*`, `g_sPoint*` are already defined in
  `core/shaders/common_samplers.fxc` (pulled in via `common/pixel.hlsl`).
  Redeclaring `SamplerState g_sAniso` is a `redefinition` error — just use them.
- **Per-instance, no-material-dup params = render attributes.** Declare
  `float g_flFoo < Attribute("Foo"); Default(1.0); >;` (also works for
  `float3`/`float4`) and set from C# via
  `renderer.SceneObject.Attributes.Set("Foo", value)` (RenderAttributes.Set has
  float/Vector2-4/bool/Texture/etc overloads). Reads layer global → material →
  SceneObject, so SceneObject wins per-object. Beats minting a Material per
  instance. `Material.Set("Foo", ...)` sets the material-level default.
- **Runtime-settable textures = attribute-bound, not CreateInputTexture2D.**
  `Texture2D g_tFoo < Attribute("Foo"); SrgbRead(true); Default(1.0); >;` lets
  you push a texture per-instance via `Attributes.Set("Foo", texture)`. The
  `Default(scalar)` keeps it safe (white/black) when unset — only sample it
  behind an enable flag so an unbound default is never read for real.
  `CreateInputTexture2D` textures are material-bound (set via `material.Set`)
  and can't be overridden cleanly per-instance (MaterialAccessor only swaps the
  whole Material, not individual params).
- **Custom lighting model:** iterate `Light::Count(m.ScreenPosition)` +
  `Light::From(m.WorldPosition, m.ScreenPosition, i, m.LightmapUV)` → per-light
  `.Color/.Direction/.Attenuation/.Visibility` (Visibility = shadow term).
  Ambient/indirect = `AmbientLight::From(WorldPos, ScreenPos, Normal)` (the
  Source-2 equivalent of Unity's `ShadeSH9`). Under `CUSTOM_MATERIAL_INPUTS`,
  `Material::Init(i)` does NOT fill geometry — set `WorldPosition`
  (= `i.vPositionWithOffsetWs + g_vHighPrecisionLightingOffsetWs`),
  `ScreenPosition`, `Normal`, tangents, `LightmapUV` yourself. View dir =
  `normalize(g_vCameraPositionWs - WorldPos)`. `g_flTime` is the time global.
- **Inverted-hull outline:** offset `i.vPositionWs` along the world normal in
  the VS and recompute `i.vPositionPs = Position3WsToPs(i.vPositionWs)` (that's
  exactly how `VS_CommonProcessing` derives Ps); `RenderState(CullMode, FRONT);`
  in the PS to draw the back hull. Render it as a SECOND `SkinnedModelRenderer`
  with `BoneMergeTarget = mainRenderer` so it follows the main renderer's posed
  bones (including `SetBoneTransform` overrides) for free, with
  `MaterialOverride` = the outline material.

## More shader findings (toon/cel port session)

- **Attribute-bound `Texture2D` shows PINK if never set.** `< Attribute("X"); Default(1.0); >`
  does NOT fall back to a solid color at runtime — an unset attribute texture resolves to the
  engine's missing-texture (pink). If a feature samples it, bind a real fallback from C# every
  frame: `SceneObject.Attributes.Set("X", userTex ?? Texture.White)` (or `Texture.Black` for an
  additive slot). Gate the feature on the user actually supplying a texture.
- **Masked GoldSrc skins → alpha-test or they're black.** GoldSrc "masked" textures (studio flag
  64) decode their transparent texels to alpha 0 (and often black RGB). An opaque shader renders
  those as solid black (e.g. a model's mouth/hair cut-outs). Add `clip(albedo.a - 0.5)` in the PS —
  fully-opaque skins are alpha 1 everywhere so they're never clipped. (Depth/outline passes that
  don't sample the albedo won't alpha-test — feed alpha through if you need clean cut-outs there.)
- **Matcap basis must match the engine's view dir.** s&box/Poiyomi build the view-space matcap
  basis from `viewDir = normalize(CameraPos - WorldPos)` (surface→camera). Using `-V` flips
  `cross(viewDir, up)` and mirrors the matcap horizontally. Sample the matcap with a CLAMP sampler
  (`g_sBilinearClamp`) — grazing-angle UVs drift past [0,1] and a wrap sampler grabs the opposite
  sphere edge. s&box is Z-up, so the matcap "world up" is `(0,0,1)`, not Unity's `(0,1,0)`.
- **Anti-alias fresnel/rim edges with `fwidth`.** A `smoothstep(a,b,ndv)` rim with a narrow `[a,b]`
  band is sub-pixel and aliases hard (worse on low-poly normals). Pad the bounds by
  `fwidth(ndv)*1.5` so the transition is always ~1px soft.
- **Reading a live runtime component's values over the bridge:** once a Play session is actually up,
  `list_gameobjects` shows the spawned objects; drill to the component's GameObject and
  `list_properties(id, component_type)` to read every `[Property]` (incl. the user's live in-editor
  tweaks). Right after a TogglePlay the bridge can still report only the edit scene — re-query a
  beat later. This is the reliable way to capture "bake my current tweaks as defaults".

## A HUD PanelComponent renders NOTHING without a ScreenPanel root

A `PanelComponent` (your Razor HUD) only renders if `FindParentPanel()` finds an
`IRootPanelComponent` — i.e. a **`ScreenPanel`** (screen-space) or `WorldPanel` — on the *same
GameObject* or an ancestor. With no root, `panel.Parent` is null and the whole HUD is invisible —
**but its `OnUpdate`/lifecycle still runs**, so it looks "alive" (logs fire, state updates) while
drawing nothing. Classic head-scratcher: "the HUD code runs but I see no HUD."

- Fix in code so it can't break: in the HUD's `OnEnabled`, `Components.GetOrCreate<ScreenPanel>();`.
  `ScreenPanel.OnEnabled` calls `EnsureParentPanel()` on sibling/descendant `PanelComponent`s, so the
  HUD re-parents to it automatically. This is more robust than wiring the ScreenPanel in the `.scene`.
- Scene-wiring caveat: a `ScreenPanel` added to the edit scene **via the bridge** (`gameobject_add_component`)
  did not reliably persist across a Play toggle (and `save_scene` reported "no unsaved changes"). If you
  must do it in the scene, hand-edit the `.scene` JSON (add the `Sandbox.ScreenPanel` component before
  the PanelComponent) — but prefer the code route above.

## UI fonts: you CANNOT register a custom font at runtime from game code

Proven from engine source (`engine/Sandbox.Engine/Systems/Render/TextRendering/FontManager.cs`
+ `engine/Sandbox.Filesystem/`):

- **Fonts are discovered by scanning `/fonts/**/*.{ttf,otf}` across `FileSystem.Mounted`**
  (`FontManager.LoadAll`). Each face is registered by its **internal SKTypeface family name** —
  i.e. the name baked into the TTF `name` table (ID 1), NOT the filename. So CSS
  `font-family: "Whatever"` must match the font's *internal* family name. Parse the TTF name table
  (or check `Inter-Black.ttf` → family `Inter`) to learn the string to put in CSS.
- A `FileWatch` on `*.ttf`/`*.otf` over `FileSystem.Mounted` **hot-loads** new/changed font files
  while the game runs (`OnFontFilesChanged`), and `LoadAll` is re-run on network init. So dropping a
  `.ttf` into a mounted `/fonts/` folder *on disk* is picked up live — but only the editor/dev disk
  is writable; see below.
- **`FileSystem.Mounted` is a READ-ONLY Zio aggregate** (`AggregateFileSystem` — "This is read
  only"). `Mount`/`CreateAndMount`/`Watch` on `BaseFileSystem` are `internal`. So game code can't
  write into it and can't add its own writable mount.
- The only game-writable filesystems — `FileSystem.Data` and `FileSystem.OrganizationData` — are
  **NOT mounted into `FileSystem.Mounted`** (verified the full mount list in `GameInstanceDll.cs`
  + `GameInstance.cs`). Fonts written there are never discovered. The networked file stores
  (`NetworkedLargeFiles`/`SmallFiles`) ARE mounted + trigger a font reload, but they're private
  engine fields populated only from ProjectSettings/Language — no public API to add arbitrary files.
- There is **no public `AddFont(stream)` / `RegisterTypeface` API** (`FontManager` is internal).

**Consequence:** you cannot feed a runtime-downloaded `.ttf` to the *engine's* font/text system.
Two ways around it:

1. **Bundle** the candidate fonts as project content (`Assets/fonts/`) at dev/build time and select
   among the already-loaded family names at runtime (`families[hash % count]`). Simple, full engine
   text rendering, but every font ships in the package.

2. **Rasterize the font yourself** (what MGE does — see `projects/mge/Code/Text/`). Download the
   `.ttf` with `Http.RequestBytesAsync` (s&box forces UA `facepunch-sbox` + a Referer and forbids
   overriding them — fine for most hosts; verify your API doesn't UA-filter), parse the `glyf`
   outlines in pure C# (`TrueTypeFont.cs`), fill them with an anti-aliased non-zero-winding scanline
   rasterizer (`GlyphRasterizer.cs`), and build a `Texture.Create(w,h,
   ImageFormat.RGBA8888).WithData(bytes).WithMips().Finish()`. Store glyphs **white-alpha** so
   `Style.BackgroundTint` can colour them.
   - **Rasterize each glyph into its OWN texture, displayed whole** (panel `BackgroundSize 100% 100%`,
     panel aspect == texture aspect). Do NOT pack into one strip and window it with `BackgroundPositionX`
     + `Overflow:Hidden` — that clips wider glyphs at the cell edge ("digits cut off"). Per-glyph
     textures can't be clipped. Give each glyph a shared baseline-aligned cell height + a couple px of
     edge padding so the AA fringe survives.
   - This gives true on-the-fly fonts (any font, any time, no bundling) at the cost of a glyph
     rasterizer. Only `Texture.Create` needs the main thread — the parse/raster is plain CPU work that
     can follow an `await`. Worth it when the glyph set is tiny (HUD digits) and the font is chosen at
     runtime (e.g. hashed from the player's model).
   - CFF/OpenType-PostScript outlines (`CFF `/`CFF2` table, no `glyf`) need a separate Type2 charstring
     interpreter — check your catalogue's sfnt version first. (mixfont's are all `glyf`.)

## A mid-session-added `.shader` will NOT bind via runtime `Material.Create` — pink forever (even after restart)

Distinct from the stale-handle pink above, and far nastier: a shader **added (or first compiled) during a running editor session** comes back as the **pink error material** from `Material.Create( name, "shaders/new.shader" )` **even when it compiles cleanly** (`new.shader_c` present, no ANTLR errors) — and **a full editor restart does NOT fix it**. Lost a long session to this; the fix is to not use a new shader at all.

- **Only shaders that were built into the ORIGINAL project load reliably at runtime.** A map's own `goldsrc.shader`/`bsp_prop.shader` (present when the project was first built) resolve fine; a freshly-added `grass.shader` — same `Assets/shaders/` folder, valid `grass.shader_c` on disk — renders pink. The runtime shader registry is populated from the project build; a shader dropped in afterwards isn't in it.
- **Out-of-process compiles don't register it.** `asset_compilation_control(..., mode:"compile")` emits the `.shader_c` but does **not** add the shader to the running editor's runtime registry.
- **The editor's file-watcher won't auto-compile your source edits.** Writing a project `.shader` (via the bridge / any external write) does **not** fire `compile.shader` — `wait_for_compile_shader` just expires. So the documented "edit `goldsrc` → editor recompiles → Reload Map" flow only triggers when the **editor itself** saves the file, not when you write it underneath the editor.
- **Base-addon `DevShader = true` shaders are doubly broken at runtime.** Copying e.g. `foliage.shader` in doesn't help, and DevShaders compile combos on-demand in the editor — so a runtime `Material.Create` + `SetFeature` selecting a combo that was never precompiled returns the error material too. (Removing `DevShader` and recompiling still didn't register it — see above.)
- **Practical rule — for anything built with runtime `Material.Create`, render with a shader that SHIPPED with the project build.** Need a new look? Add a `Feature`/`StaticCombo` to an **existing** project shader (default-off so other consumers' combos are unchanged) rather than a new `.shader` file; or commit the new shader and do a clean project build so it's in the registry from the start. Worked example: `goldsrc.shader` already exposes `F_ALPHATEST` (`clip( Color.a - 0.5 )`), so alpha-cut foliage/grass cards render on it (lit, non-pink) with no new shader — wind/vertex-animation, which it lacks, is the only thing you give up.

### Runtime texture-input names depend on how the shader DECLARES the input
`Material.Set("X", tex)` binds by the **`CreateInputTexture2D` name**, not the `g_t*` HLSL name:
- A custom shader with `CreateInputTexture2D( Color, … )` → `Set("Color", tex)` (e.g. `goldsrc.shader`).
- A standard shader pulling `common/utils/Material.CommonInputs.hlsl` (`complex`/`foliage`) declares `TextureColor`/`TextureNormal`/`TextureRoughness` → `Set("TextureColor", tex)`. Binding the wrong name leaves the input at its `Default` (often white) — **not** pink. Pink = the whole shader/material is invalid (above), not a missing texture.

## Hide a renderer WITHOUT recreating its SceneObject: `SceneObject.RenderingEnabled`, not `Enabled`

Toggling a renderer's `GameObject.Enabled` (or the component `.Enabled`) **destroys and recreates the underlying `SceneObject`/`SceneModel`**. For a `SkinnedModelRenderer` that **re-inits the animgraph at its entry state** — so a viewmodel hidden then shown (e.g. a third-person camera toggle) **replays its deploy/draw animation every time**. It also resets per-`SceneObject` flags (`CastShadows` etc.), which is why those often get re-set every frame.
- **Fix:** to hide without tearing down the animgraph, set `renderer.SceneObject.RenderingEnabled = false/true`. The animgraph keeps running (stays settled in idle), so re-showing is instant with no animation replay. Apply to every renderer involved (e.g. the gun **and** its bonemerged arms). `RenderingEnabled` exists on every `Scene*` object (SceneModel / SceneCustomObject / lights / …).
- Rule of thumb: keep `GameObject.Enabled` tied to **presence** (does it exist at all) and drive **visibility** via `RenderingEnabled`.
- Related: anchor a first-person effect to a model attachment with `SkinnedModelRenderer.GetAttachment("muzzle")` (returns a **world-space** `Transform?`), and if it must track the gun (muzzle flash) update its position every frame from that attachment — a one-shot world-static spawn lags behind when the player moves.

## Per-frame shader params on a runtime material: use `SceneObject.Attributes`, NOT a per-frame `Material.Set`

A `Material` from `Material.Create(...)` reads attributes you `Set` on it **once, before the object first renders** — those bake in (e.g. wind direction/strength set at material-build time work fine). But a **per-frame** `material.Set("X", v)` on that same runtime material is **NOT reliably re-uploaded** to the already-rendering `SceneObject` — the new value is silently dropped. Symptom from a real session: procedural grass on `goldsrc.shader` **swayed in the wind** (params baked once at creation) **but never bent away from the player** — the per-frame player positions were being pushed via `material.Set("GrassActor0", …)` and never reached the shader.
- **Fix:** write per-frame values onto **each renderer's `renderer.SceneObject.Attributes.Set("X", v)`** — the engine's live per-object attribute channel. The shader reads `Attribute("X")` from the **merged** set (SceneObject attributes win over the material default), so dynamic data shows immediately. Same pattern any per-frame shader push should use (e.g. a toon shader updating light/rim params each frame).
- **Rule of thumb:** static look → `Material.Set` at build time; anything that changes per frame → `SceneObject.Attributes`. (For a `Graphics.Draw`/`SceneCustomObject` path the equivalent is a `RenderAttributes` passed to the draw call.)

## A mid-session shader recompile's NEW StaticCombo doesn't load — `mat_reloadshaders` loads it WITHOUT a restart

When you add a `Feature`/`StaticCombo` to an **existing** project shader (one that ships in the build, so it's not the "new shader renders pink" case) and recompile it during a running editor, the engine keeps its **old shader variant table** — the new combo isn't in it. A runtime material's `SetFeature("F_NEW", 1)` then falls back to the old static variant, so the feature silently does nothing (e.g. a grass shader renders but never animates). You do **not** need a full editor restart:
- Run **`mat_reloadshaders shaders/yourshader.shader`** in the editor console (`run_console_command`) — it reloads the shader from the fresh `.shader_c` on disk and registers the new combos.
- Verify with **`mat_print_shader_info shaders/yourshader.shader`**: the Vertex/Pixel "Static combos:" list should now include your new combo (e.g. `S_NEWFEATURE 0..1`). Output goes to the log — read it via `tail_log`.
- Then **rebuild any runtime materials** that use it (the stale-handle "pink after a shader recompile" rule still applies to already-built materials — recreate them, e.g. via your loader's ResetCache + Reload).

## Pasted / downloaded "wav" (or other source) assets can be gzip-compressed — compile fails cryptically
A source asset that won't compile (`asset_get_compile_status` → `is_failed:true`, no `*_c`) may not be the format its extension claims. Check the magic bytes: `head -c4 file.wav | xxd` — `RIFF` = real WAV, **`1f 8b`** = gzip. Fix: `zcat in.wav > out.wav` (verify it now starts `RIFF`), then `register_asset_file` again. The **`register_asset_file` → `asset_get_compile_status`** loop is the way to add raw assets (wav/png/tga) over the bridge and confirm each produced a compiled `*_c` before referencing it from a `.sound`/material.

## `IgnoreGameObject` ignores only the ROOT — an eye-origin trace starts SOLID inside the player's own collider
A trace started at the player's eye (`Weapon_ShootPosition`-style muzzle/spawn/aim traces) begins **inside the player's own collider**. If that collider is a **child** GameObject — which it usually is (a dedicated "Hitbox" child holding the `BoxCollider`, a separate body collider, etc.) — then `Scene.Trace…IgnoreGameObject(player)` does **NOT** skip it: `IgnoreGameObject` excludes only that single object's own colliders, not its descendants'. The trace **starts solid**, returns `fraction 0` / `HitPosition == start`, and any code that does `if (tr.Hit) pos = tr.EndPosition;` silently **collapses the spawn/aim point back onto the eye**.
- **Real symptom (MGE rocket launcher):** the launcher's right-shoulder muzzle offset `(23.5, 12, -3)` was computed correctly, but the brush-only eye→muzzle pullback trace started solid in the player's Hitbox child → spawn snapped to the eye → every rocket fired from dead-center regardless of the offset. The offset value was right; the trace was erasing it. Caught only by logging the *post-trace* spawn position (`rightDist=0` when it should be ~12).
- **Fix:** use **`IgnoreGameObjectHierarchy(player)`** (skips the root AND all child colliders) for any trace originating at/near the player. Belt-and-suspenders: also `.WithoutTags("player","hitbox")` if you tag your hitboxes. Reserve plain `IgnoreGameObject` for cases where you genuinely want only the one object skipped.
- **Tell:** "the offset/aim is in the code but has zero effect at runtime," or a spawn that's always exactly at the origin. Log the value *after* every trace that can rewrite it; a `0.0` lateral component on a supposedly-offset point means a start-solid pullback. This also applies to projectile *movement* traces (ignore the shooter's whole hierarchy, or a point-blank shot hits the shooter's own hitbox child at the muzzle).

## Add a throwaway fire-path / event log to find "value is correct but has no effect" bugs (bridge can't inject input)
The bridge cannot inject fire/mouse/movement, so a gameplay path that only runs on player input (weapon fire, melee, jump) can't be exercised from the MCP. When such a path misbehaves, add a **one-line `Log.Info($"[TAG] …")`** dumping the suspect values at the decision point, recompile, have the human trigger it once, then read it back with **`tail_log(min_level:"info")`** (filter your `[TAG]`). This turns "I think it's X" into ground truth in one round-trip. Log the values *after* every transform/trace that could mutate them (not just at compute time), include any cached-component null-state, and **remove the log once confirmed.** (It's how the rocket-spawn-collapse bug above was localized: the offset logged as 12 but the post-trace `rightDist` logged as 0.)
