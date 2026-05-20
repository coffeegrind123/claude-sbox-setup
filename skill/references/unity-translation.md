# Unity → s&box translation table

If you reach for any expression in the left column, **stop**: that's a
Unity reflex misfiring. The right column is what s&box actually exposes.
The runtime won't autocorrect for you — code that calls Unity APIs
either fails to compile or silently does nothing.

If a pattern you need isn't in this table, assume s&box doesn't ship
the Unity equivalent at all and search the live schema
(`schema_search_members`, `schema_lookup_type`) before writing it.

## Class shape & lifecycle

| Unity reflex | s&box |
|---|---|
| `class Foo : MonoBehaviour` | `public sealed class Foo : Component` |
| `void Awake()` | `protected override void OnAwake()` |
| `void Start()` | `protected override void OnStart()` |
| `void Update()` | `protected override void OnUpdate()` |
| `void FixedUpdate()` | `protected override void OnFixedUpdate()` |
| `void OnEnable()` / `OnDisable()` | `protected override void OnEnabled()` / `OnDisabled()` (note the trailing `d`) |
| `void OnDestroy()` | `protected override void OnDestroy()` |

Lifecycle overrides MUST carry both `protected override` and the `On`
prefix. A plain `void Update()` compiles and never runs.

## Inspector & serialization

| Unity reflex | s&box |
|---|---|
| `[SerializeField] float speed` | `[Property] public float Speed { get; set; }` |
| `[HideInInspector]` | `[Hide]` |

`[Property]` is the single annotation that both surfaces a field in
the inspector and persists it to the prefab/scene file. `public`
alone won't serialize.

## Transform & GameObject state

| Unity reflex | s&box |
|---|---|
| `transform.position` | `WorldPosition` (also accessible as `GameObject.WorldPosition`) |
| `transform.localPosition` | `LocalPosition` |
| `transform.rotation` | `WorldRotation` |
| `transform.forward` | `WorldRotation.Forward` |
| `gameObject.SetActive(false)` | `GameObject.Enabled = false` |
| `Destroy(gameObject)` / `Destroy(this)` | `GameObject.Destroy()` / `Component.Destroy()` / `DestroyGameObject()` |
| `Instantiate(prefab, pos, rot)` | `prefab.Clone( pos, rot )` |
| `Instantiate(prefab); NetworkServer.Spawn(...)` | `prefab.Clone( pos ).NetworkSpawn( owner )` |

## Finding objects & components

| Unity reflex | s&box |
|---|---|
| `GetComponent<T>()` inside `Start/Update` | `GetComponent<T>()` works as-is; for ancestor / descendant lookups use `Components.Get<T>( FindMode )` |
| `FindObjectOfType<T>()` / `FindObjectsOfType<T>()` | `Scene.Get<T>()` / `Scene.GetAll<T>()` / `Scene.GetAllComponents<T>()` |
| `GameObject.Find("Name")` | `Scene.Directory.FindByName( "Name" )` |

## Physics & collisions

| Unity reflex | s&box |
|---|---|
| `OnCollisionEnter(Collision c)` | Implement `Component.ICollisionListener.OnCollisionStart( Collision c )` |
| `OnTriggerEnter(Collider c)` | Implement `Component.ITriggerListener.OnTriggerEnter( Collider c )` |
| `Physics.Raycast(...)` | `Scene.Trace.Ray( from, to ).Run()` — a builder that returns `SceneTraceResult` |
| `Physics.OverlapSphere(pos, r)` | `Scene.Trace.Sphere( r, pos, pos ).RunAll()` |
| `Rigidbody.AddForce(f, ForceMode.Impulse)` | `Rigidbody.ApplyImpulse( f )` |
| `Rigidbody.AddForce(f)` | `Rigidbody.ApplyForce( f )` |
| `Rigidbody.velocity` | `Rigidbody.Velocity` (capital `V`) |

## Input

| Unity reflex | s&box |
|---|---|
| `Input.GetKey( KeyCode.W )` | `Input.Down( "forward" )` — action names are strings declared in Project Settings, **not** key codes |
| `Input.GetKeyDown(...)` | `Input.Pressed( "action" )` |
| `Input.GetAxis( "Horizontal" )` / `"Vertical"` | `Input.AnalogMove` (returns a `Vector3`) |
| `Input.mousePosition` | `Mouse.Position` (returns a `Vector2`) |

## Camera & coordinates

| Unity reflex | s&box |
|---|---|
| `Camera.main` | `Scene.Camera` |
| `Camera.main.ScreenPointToRay( Input.mousePosition )` | `Scene.Camera.ScreenPixelToRay( Mouse.Position )` |
| `Vector3.forward = (0, 0, 1)` | `Vector3.Forward = (1, 0, 0)` — **s&box is Z-up.** Audit every literal direction vector you port. |

## Async, timing, logging

| Unity reflex | s&box |
|---|---|
| `StartCoroutine( Foo() )` with `IEnumerator` returns | `async Task Foo()` with `await Task.DelaySeconds(...)`; call as `_ = Foo();` for fire-and-forget |
| `yield return new WaitForSeconds( 1f )` | `await Task.DelaySeconds( 1f )` |
| `yield return null` | `await Task.Frame()` |
| `Debug.Log(x)` / `.LogWarning` / `.LogError` | `Log.Info(x)` / `Log.Warning(x)` / `Log.Error(x)` |
| `Time.time` | `Time.Now` |
| `Time.deltaTime` | `Time.Delta` |
| `Time.fixedDeltaTime` | `Scene.FixedDelta` |
| `Mathf.Lerp / Clamp / Approach` | `MathX.Lerp / Clamp / Approach` |
| `Random.Range(a, b)` | `Game.Random.Next(a, b)` / `Game.Random.NextSingle()` |

## Scene & game state

| Unity reflex | s&box |
|---|---|
| `SceneManager.LoadScene( "name" )` | `Scene.LoadFromFile( "path/to/scene.scene" )` or `Scene.Load( sceneResource )` |
| `DontDestroyOnLoad( go )` | `go.Flags = GameObjectFlags.DontDestroyOnLoad` |
| `Application.isPlaying` | `Game.IsPlaying` (or `!Game.IsEditor`) |

## File I/O & networking

| Unity reflex | s&box |
|---|---|
| `System.IO.File.ReadAllText(...)` | `FileSystem.Data.ReadAllText(...)` / `FileSystem.Mounted.ReadAllText(...)` |
| `UnityEngine.Networking.UnityWebRequest` | `Http.RequestStringAsync(...)` / `Http.RequestJsonAsync<T>(...)` |

## Frame discipline

| Unity reflex | s&box |
|---|---|
| Read input AND move rigidbodies in `Update()` | Read input in `OnUpdate`; mutate rigidbodies in `OnFixedUpdate`. Mixing them produces jitter at non-render framerates. |
