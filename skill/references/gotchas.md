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

## Misc bridge quirks seen this session

- `screenshot_scene_to_file` writes to **`game_root/screenshots/`**
  (`<sbox>/game/screenshots/sbox.<timestamp>.png`), NOT the project dir.
  Find it with `host_list_directory(scope:"game_root", path:"screenshots",
  glob:"*.png")`, newest mtime, then `Read` the absolute host path.
- `wait_for_scene_play` frequently returns `expired:true` even though Play
  *did* start (the event races the TogglePlay call). Don't trust the wait —
  verify by `list_gameobjects` (runtime objects like the spawned Player
  appear) or `last_scene_play`.
- `Components.Get<T>()` (the C# API, not a bridge tool) **skips disabled
  components by default** — pass `FindMode.EverythingInSelf` to include them.
  A `Get<T>()` that worked while a component was enabled returns null once
  something disables it; that exact trap left a respawn unable to re-enable a
  controller it had just disabled.
