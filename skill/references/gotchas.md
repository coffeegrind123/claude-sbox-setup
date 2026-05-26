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
- `set_property` can fail silently. The handler's response includes
  both `previous` and `current` values — if they're equal after a
  write, the write didn't take. Always confirm with a `get_property`
  read-back. The underlying engine bug lives in
  `TypeSerializedProperty.SetValue<T>` (`engine/Sandbox.Tools/Utility/ReflectionSerializedObject.cs:89`):
  when `T` is inferred from the argument (e.g. `JsonNode`), the
  generic falls through to the silent `else return;` branch because
  `JsonNode` is neither `IConvertible` nor assignable to the target
  CLR type. This addon's handler coerces values to the target type
  first to dodge the bug — if you ever see a silent set regress,
  that coercion is the prime suspect.
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

## Bridge tool reliability

- `editor_state` can hard-fail with `NotImplementedException: Unable to
  upgrade delegate methods without declaring types` and **stay broken
  across an editor restart** (observed on claude-sbox v0.0.109) — it's
  not a transient hotload blip, it's the handler tripping the engine's
  hotload upgrader on a delegate it serializes. When this happens,
  route around it: `get_active_scene` (scene name + source path),
  `compile_check_build_state` (build state), `ping` (liveness), and
  `game_action_list` (errors `not_in_play_mode` when stopped, succeeds
  when playing) together reconstruct everything `editor_state` would
  have told you. `doctor` also still works.
- `set_property` only coerces **string-like** values reliably: `string`,
  `Guid`, and enums-as-string work. **`Vector3` AND `bool` both FAIL** with
  `coerce_failed: ... requires an element of type 'Object'/'Boolean', but
  the target element has type 'String'` (the value arrives as a string and
  the coercer won't convert it). For Vector3 every form was rejected
  (`{"x":..}`, `"x,y,z"`, `[x,y,z]`); bool `"true"` is rejected too. So you
  **cannot toggle a `[Property] bool` or set a `Vector3`** from the bridge —
  drive those from code (a sibling test component, or a `[ConCmd]`), or via
  the inspector UI. Combined with no input-injection (`send_keys` doesn't
  reach game input), key-bound toggles aren't bridge-testable; validate
  their effect by other means (e.g. a mirror/replica object).
  So you **cannot drive a player's `Velocity`/`WorldPosition` from the
  bridge** to script a motion test — there's no input-injection path
  either (`send_keys` posts Qt events the game-input layer ignores).
  Validate at-rest invariants (grounded, no drift, no fall-through) via
  `get_property`, and hand dynamic feel tests (WASD/jump/stairs) to the
  user. If you must move something, a sibling test component that sets
  the value in code (then hotload) is the workaround.
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

## set_property can't coerce bool or Vector3

- `set_property` only coerces **string / Guid / enum / number**. Passing a
  JSON `true` for a `bool [Property]` fails with `coerce_failed` ("target
  element has type 'String'" — the bridge stringifies the value). Same for
  `Vector3`. There is no clean per-property path for these: a `[Property]`
  bool doesn't render as an individually `find_widget`-addressable checkbox
  either. Workarounds: toggle a whole component with
  `gameobject_set_component_enabled`; for other bools, change the field's
  default in code + hotload, or drive it from a `[ConCmd]` via
  `run_console_command`. Strings/enums/Guids/numbers set fine.

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
