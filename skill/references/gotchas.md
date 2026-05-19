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
