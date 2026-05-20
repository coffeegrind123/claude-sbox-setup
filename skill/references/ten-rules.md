# Cardinal rules

Ten invariants the s&box runtime enforces. Each one has a silent-failure
mode if you skip it — the compiler won't always catch a violation, but
the gameplay will be broken. Internalise these before writing or
reviewing any gameplay code.

## 1. Gameplay classes extend `Component`

Not `MonoBehaviour`. Not `ScriptableObject`. Not bare `object`. The
only acceptable base class for a gameplay script is `Component`. Mark
it `sealed` unless something specific in the hierarchy demands
inheritance.

## 2. Lifecycle hooks are `protected override void On*()`

Free-standing `void Update()` (or `Start`, `Awake`, etc.) compiles
cleanly and never runs. Every lifecycle hook has to be both
`protected override` AND prefixed with `On`. If your method body
isn't firing, this is almost always why.

## 3. Inspector-visible fields use `[Property]`

Neither `[SerializeField]` nor public-alone exposes a field in s&box.
`[Property]` is the one attribute that both surfaces a member in the
inspector and persists it into the prefab / scene file.

## 4. Replicated state uses `[Sync]`

Only the GameObject's owner is allowed to assign a `[Sync]` field;
every other peer sees the replicated value. Pair with
`[Change(nameof(MyHandler))]` when you need a change callback. This
is the entire client-authority story in one attribute pair.

## 5. Every networked component starts with `if ( IsProxy ) return;`

Any component that reads input or drives movement opens its
lifecycle method with this line. Otherwise every connected client
runs the logic for every player, producing the classic "everyone is
moving everyone" multiplayer bug.

## 6. Traces go through `Scene.Trace`

The builder API: `Scene.Trace.Ray( from, to ).UseHitboxes( true ).WithoutTags( new[]{ "player" } ).Run()`
returns a `SceneTraceResult`. The shape covers rays, boxes, spheres,
capsules, and so on. **Never reach for `Physics.Raycast`** — that's
Unity, and it doesn't exist here.

## 7. UI is Razor + flexbox, full stop

`display: flex` is the implicit default and effectively the only
layout mode the renderer honours. `display: block` does not exist.
The pseudo-states `:intro` and `:outro` animate panel creation and
deletion. Every root panel should override `BuildHash()` to control
when it re-renders.

## 8. Coroutines aren't a thing — use `async Task`

There is no `IEnumerator`-based scheduling. `await Task.DelaySeconds( n )`,
`await Task.Frame()`. Fire-and-forget with `_ = MyTask();`. The
`Component.Task` property scopes cancellation to the GameObject's
lifetime — use it for any awaiter that should die when the component
dies.

## 9. Blocked .NET APIs will not compile

`System.IO.File`, `System.Console`, raw `Thread`, raw sockets,
`System.Net.Http.HttpClient` — none of these are reachable from
sandboxed gameplay code. Use `FileSystem.Data`, `Log`, `async/await`,
and `Http` instead. Editor tool addons have different access rules;
gameplay code does not.

## 10. Look up every API before writing it

The live schema is ground truth. If `schema_search_members` or
`schema_lookup_type` can't find the symbol, then either you're
guessing (in which case, stop) or it's nested on a specific type
(search topical prose with `docs_search` to find the parent).
Guessing leads to "compiles for me locally because IntelliSense
hallucinated it" disasters.
