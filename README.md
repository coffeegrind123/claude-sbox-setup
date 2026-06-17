# claude-sbox-setup

Setup scripts, engine patches, Claude Code companion skill, MCP bridge, and reference docs for the **claude-sbox** s&box editor addon ([sbox.game/ghage/claude-sbox](https://sbox.game/ghage/claude-sbox)).

The addon itself is a compiled tool package published to sbox.game. This repo holds everything around it: the engine patches that have to be applied to the sbox-public tree, the `.bat` / `.ps1` / `.sh` helpers (Windows + Linux), the companion `sbox-live` Claude Code skill, the Node MCP bridge, and the package marketing assets.

---

## Quick start

A working claude-sbox install has **two layers**:

1. **Engine patches on sbox-public, recompiled into managed DLLs** — required by *both* install methods below. Cloud install fails with whitelist errors at mount time without patches 9 / 10 / 11; the global auto-mount and toolbase load-order depend on patches 4 / 11; the publish path requires patch 3. The patches touch `.cs` files; the editor loads compiled `.dll`s, so a `Bootstrap` rebuild has to follow the patch step. Apply via `Setup.bat` + `Bootstrap-And-Capture.bat` (Windows) / `./Setup.sh` + `./Bootstrap-And-Capture.sh` (Linux); both idempotent, safe to re-run after every `git pull` on sbox-public.
2. **The addon itself** — install via either method:
   - **Cloud install** (most users): run `package_install ghage.claude-sbox tools` in the editor's developer console. The compiled addon lives in `<sbox-public>/game/.sbox-global/cloud/.bin/` and auto-mounts on every project load (patch 4).
   - **Source-clone install** (contributors): `git clone https://github.com/coffeegrind123/claude-sbox.git` into `<sbox-public>/game/addons/claude-sbox/`. Patch 1 detects the clone and auto-mounts as a built-in addon.

The two install methods are not mutually exclusive — source-clone takes precedence when both are present, so a contributor can switch between testing their local edits and the cloud-published version by deleting / restoring the source dir.

claude-sbox supports two host OSes:

- **Windows** — Facepunch's official [sbox-public](https://github.com/Facepunch/sbox-public). Default path; everything below uses `.bat`/`.ps1`.
- **Linux** — the community [joshuascript/sbox-public](https://github.com/joshuascript/sbox-public) fork. Adds an Anvil-based native-patch layer (LD_PRELOAD shims for case-insensitive filesystem + Vulkan crash fixes) so the engine runs without Proton. Use the `.sh` siblings of every setup script.

Pick your track below.

### What `Setup.bat` / `Setup.sh` actually does

The same script runs for both cloud-install users (no source clone, addon comes from sbox.game) and source-clone developers. It does **not** install the addon — there's no `package_install`-from-script, no `git clone`-of-the-addon-repo. All it does is patch the engine. The addon itself is installed afterward via whichever method you prefer.

| Invocation | What runs |
|---|---|
| `Setup.bat` &nbsp;/&nbsp; `./Setup.sh` | **Apply engine patches.** Runs `git apply` (with strict → `--3way` → CRLF → fuzzy tiers) for every file in `patches/`, writes the managed `.gitignore` block at the sbox-public root, and verifies post-apply state. Idempotent — already-applied patches are detected and skipped. Required step for **both** install paths (cloud and source-clone), because patches 9 / 10 / 11 fix the cloud-mount whitelist + load-order gates that block `package_install ghage.claude-sbox tools` from working. Run once after `git clone sbox-public`; re-run after every `git pull` on sbox-public. |
| `Setup.bat -DryRun` &nbsp;/&nbsp; `./Setup.sh --dry-run` | Show what each patch would do without writing. Useful pre-flight when you want to see whether upstream rewrote any patch context. |
| `Setup.bat -Force` &nbsp;/&nbsp; `./Setup.sh --force` | Bypass the "already applied" idempotency probe. Use only when the in-place patch text was mangled and you need to re-apply from scratch. |

(`-Dev` / `--dev` is accepted as a silent no-op alias — older docs and muscle memory still work but the flag does nothing.)

What the script does **not** do, for either audience:

- It does **not** rebuild the engine DLLs. Setup edits the engine `.cs` source files in place; the editor loads compiled `.dll`s from `game/bin/managed/`. After Setup runs you MUST run `Bootstrap-And-Capture.bat` / `./Bootstrap-And-Capture.sh` to recompile those DLLs against the patched source — otherwise the editor keeps loading the pre-patch DLLs and the patches have no effect.
- It does **not** clone the addon source. If you want the source tree at `<sbox-public>/game/addons/claude-sbox/`, you `git clone` that yourself (see the "Contributors only" step in the Install section below). Patch 1 detects the clone and auto-mounts it as a built-in addon when present.
- It does **not** run `package_install`. The `.cll` and `.xml` for the cloud-published addon get downloaded inside the editor, not from a CLI. Setup tells you the exact command to paste into the editor console as part of its post-apply Next-Steps.
- It does **not** modify any file under `game/addons/claude-sbox/` (cloud install never has this dir; source-clone install owns it and the script never touches it).

So both audiences run the **same** `Setup.bat` + `Bootstrap-And-Capture.bat` sequence to patch and rebuild the engine. The difference between the two install paths is what happens **after** — cloud users open the editor console and run `package_install ghage.claude-sbox tools`; source-clone developers additionally `git clone` the addon source.

### Install — Windows

You need a working [sbox-public](https://github.com/Facepunch/sbox-public) checkout (`git clone --recursive https://github.com/Facepunch/sbox-public`).

**1. Clone this setup repo into `game/addons/`** of your sbox-public checkout:

```sh
cd <sbox-public>/game/addons/
git clone https://github.com/coffeegrind123/claude-sbox-setup.git
```

**2. Apply engine patches + rebuild managed DLLs:**

```powershell
cd claude-sbox-setup
.\Setup.bat
.\Bootstrap-And-Capture.bat
```

`Setup.bat` edits the engine `.cs` files; `Bootstrap-And-Capture.bat` recompiles `game/bin/managed/*.dll` against the patched source (wraps upstream `Bootstrap.bat` with file-lock detection so MSBuild doesn't hit `MSB3021: ... being used by another process` from lingering sbox-dev / VBCSCompiler / dotnet build server). Both idempotent — re-run after every `git pull` on sbox-public. First Bootstrap is slow (~5–15 min depending on NuGet cache); incremental rebuilds afterward are fast.

**3. Launch the editor and install the addon:**

```powershell
..\..\sbox-dev.exe
```

Open any project (a fresh `my_project` is fine), open the developer console, and run **once, ever**:

```
package_install ghage.claude-sbox tools
```

Restart the editor. Patch 0004 (the cloud auto-mount) snapshots the downloaded package into `<sbox-public>/game/.sbox-global/cloud/.bin/` and auto-mounts it on every subsequent project load — no redownload, works offline. The in-editor MCP host comes up on `http://127.0.0.1:6790`.

**4. (Contributors only) clone the addon source:**

Skip this step if you just want to use the addon. Do it if you want to edit addon code, debug with the source visible, or contribute back.

```sh
cd <sbox-public>/game/addons/
git clone https://github.com/coffeegrind123/claude-sbox.git
```

Patch 0001 detects `game/addons/claude-sbox/` and auto-mounts it as a built-in addon. The source clone takes precedence over the cloud version when both are present, so the editor loads your local edits. To fall back to the cloud version, delete the `game/addons/claude-sbox/` dir.

### Install — Linux

You need the joshuascript Linux fork of sbox-public, plus `gcc` (for compiling Anvil's native patches), `python3` (for crash analysis tools), and the .NET 10 SDK.

**1. Clone the Linux fork:**

```sh
git clone https://github.com/joshuascript/sbox-public.git
cd sbox-public
```

**2. Run the fork's bootstrap. This installs [Anvil](https://github.com/joshuascript/anvil) (the LD_PRELOAD shim layer the engine needs on Linux) and builds the managed artifacts:**

```sh
bash bootstrap
```

When it prompts `Build managed artifacts now? [y/N]`, answer **y**.

**3. Clone this setup repo, apply engine patches, rebuild managed DLLs:**

```sh
cd game/addons/
git clone https://github.com/coffeegrind123/claude-sbox-setup.git
cd claude-sbox-setup
./Setup.sh
./Bootstrap-And-Capture.sh
```

`Setup.sh` applies the same 7 engine patches the Windows path uses (cross-platform `git diff` files). Idempotent — re-run after every `git pull` on sbox-public. `Bootstrap-And-Capture.sh` wraps the fork's `bash bootstrap` script with file-lock detection (via `lsof +D`, rare on Linux) and log capture.

**4. Launch the editor via Anvil's wrapper (NOT the `sbox-dev` binary directly — Anvil sets up the LD_PRELOAD chain):**

```sh
bash ../../../anvil/launch/launch-sbox.sh
```

Open any project, open the developer console, and run **once, ever**:

```
package_install ghage.claude-sbox tools
```

The in-editor MCP host comes up on `http://127.0.0.1:6790` — same as Windows.

**5. (Contributors only) clone the addon source:**

Skip this step if you just want to use the addon.

```sh
cd <sbox-public>/game/addons/
git clone https://github.com/coffeegrind123/claude-sbox.git
```

Same semantics as Windows step 4 — patch 0001 detects the clone, source takes precedence over the cloud version, delete the dir to fall back.

#### What's different on Linux

- **Setup scripts**: every `.bat` / `.ps1` has a `.sh` sibling with the same flag names (`--dry-run`, `--force`, `--no-backup`, `--snapshot`, etc.). Procedure semantics are identical.
- **Bootstrap**: the joshuascript fork ships a `bootstrap` script (no extension) instead of `Bootstrap.bat`. Both wrap `SboxBuild.csproj` so the actual build is identical.
- **Snapshots**: written as `.tar.gz` instead of `.zip` (smaller + native tooling). `Restore-From-Backup.sh` reads both formats so cross-platform snapshot recovery works.
- **Terminal dock widget**: the embedded shell uses libutil `forkpty(3)` on Linux instead of ConPTY. Same UX, native PTY.
- **Cloud-package install**: same `package_install ghage.claude-sbox tools` in the developer console. The package itself is platform-agnostic .NET assemblies; only the engine + Anvil shims differ.

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

`Setup.bat` (Windows) / `./Setup.sh` (Linux) applies the engine patches to your sbox-public tree (all reversible, all shipped in `patches/` for inspection). Idempotent — already-applied patches are skipped, so re-running on a patched tree is a no-op. (Item 5 below, formerly patch `0009`, was retired by upstream #5038 — see its entry.)

1. **`Project.Static.cs`**: adds the addon to the engine's built-in addon list **if** a source clone is present at `game/addons/claude-sbox/`. Source-clone branch only; the sbox.game-install flow (the common case) gets auto-load from patch 4 instead.
2. **`DownloadPublicArtifacts.cs`**: dedupes manifest entries by destination path. Fixes an upstream race where parallel artifact downloads fight over the same file when a manifest contains duplicate-path entries (causes confusing "being used by another process" failures during `Bootstrap.bat`).
3. **`Utility.Projects.Compile.cs`** (a single multi-block patch covering five distinct edits to the same publish path; previously split across patches 0003-0008, consolidated since they all touch the same file and a Refresh-Patches regen kept folding them into 0003 anyway):
   * Wraps the publish CompileGroup setup in an `if ( project.Config.Type == "tool" )` branch.
   * Inside that branch, nulls out `compileGroup.AccessControl` — the whitelist restricts game/library publishes to a curated API surface (no `Process`, `File`, `HttpClient`, raw `Editor.*` types), which is correct for sandboxed runtime content where end users may install untrusted code but actively wrong for tool addons whose entire point is to extend the editor. Without this, tool publishes fail with ~700 "is not allowed when whitelist is enabled" errors. The in-editor compile never applies the whitelist; the publish path was the only place enforcing it. Game/library publishes still get the standard whitelist.
   * Sets `compileGroup.ReferenceProvider = PackageManager.ActivePackages.FirstOrDefault()` so cross-package references like `package.toolbase` can resolve via `PackageManager.ActivePackages.Lookup`. In-editor compile groups get a provider from their owning `ActivePackage` (`PackageManager.ActivePackage.cs:229`); the publish CompileGroup is fresh and didn't, so `AddToolBaseReference()` would throw `"Couldn't find reference package.toolbase"` without this wiring.
   * Adds the explicit assembly references the in-editor compile already provides for tool projects — `Sandbox.Tools`, `Sandbox.Compiling`, Roslyn (`Microsoft.CodeAnalysis(.CSharp)`), `Facepunch.ActionGraphs`, `SkiaSharp`, plus net / process / registry / memory bits — and `AddToolBaseReference()` so `Editor.TreeView` / `AssetBrowser` / `ToastWidget` resolve. The publish-compile was missing all of these, so tool publishes failed with hundreds of "type or namespace not found" errors. `Project.Compiling.cs:109-122` is the in-editor mirror.
   * Gates the unconditional `compilerSettings.IgnoreFolders.Add( "editor" )` on `project.Config.Type != "tool"`. The "editor" strip is correct for game/library addons (where `Code/Editor/` holds editor-only inspectors that shouldn't ship to players) but actively wrong for tool addons, which are ENTIRELY editor code and almost always namespaced under `Editor.<X>` with all source under `Code/Editor/`. Without this gate the publisher silently strips the whole codebase, packs only `Code/Imports.cs` into the `.cll`, and produces an empty (~1 KB) package that mounts with no `[Event]` handlers.

   Maintainers-only — only matters if you're republishing the addon, not for installing it.
4. **`StartupLoadProject.cs`**: auto-mounts `ghage.claude-sbox` on every project load from a global cache at `<sbox-public>/game/.sbox-global/cloud/.bin/`, so one-time `package_install ghage.claude-sbox tools` makes the addon available for every project, every editor restart, with no redownload (size-matched pre-stage skips the `.cll` download). Also adds `ghage.claude-sbox` to the `required` set inside `RefreshCloudAssets` so cross-project eviction can't wipe the addon's per-project cache. Scoped to `ghage.claude-sbox` only; all other cloud packages keep the engine's default per-project cache behaviour.
5. **`PackageManager.ActivePackage.cs`** — *RETIRED 2026-06-16 (was `0009`).* Used to null `group.AccessControl` inside `CompileCodeArchive` for tool packages. Upstream [#5038](https://github.com/Facepunch/sbox-public) ("Load precompiled dlls from the manifest, no longer load clls") **deleted `CompileCodeArchive` entirely** — the client no longer Roslyn-compiles `.cll` archives at mount; it loads precompiled `.dll` assemblies straight from the package manifest (`.bin/package.*.dll`). With no mount-time compile, there's no whitelist gate to null, so the patch is gone. The consuming-side whitelist is now enforced only at DLL-load time, handled by patch 6 (`PackageLoader.cs`) below.
6. **`PackageLoader.cs`** (numbered `0010`; now the ONLY consumer-side whitelist gate, since patch 5/`0009` was retired by #5038): extends the "skip access control for tool assemblies" exemption to remote (cloud-mounted) tool packages. Post-#5038 the client loads precompiled `.dll`s straight from the manifest, so the DLL-LOAD-time whitelist in `LoadAssemblyFromPackage` is the single place tool packages get gated. Facepunch's original code gates the skip behind `ap.Package is LocalPackage` with a comment saying "This is used for tool packages which are ALWAYS local" — so cloud tool addons trip the check. Without this patch, the consumer's mount fails with hundreds of "Whitelist Error: X is not allowed when whitelist is enabled" PLUS "Couldn't resolve 'Microsoft.CodeAnalysis.CSharp / Facepunch.ActionGraphs / ...'" errors from `AccessControl.VerifyAssembly`'s metadata walker. Bypassing the whitelist via `TrustUnsafe` skips both. End-user-facing — required for cloud-installed tool addons to load.
7. **`StartupLoadProject.cs`** (numbered `0011`; second insertion in the same file as patch 4, just before patch 4's `InstallAsync` of claude-sbox): mounts `local.toolbase` first. The published `claude-sbox.dll` has a direct assembly reference on `package.toolbase` (baked in by patch 3's `AddToolBaseReference`). When the CLR runs the addon's static constructors via `RunAllStaticConstructors`, it asks the LoadContext to resolve `package.toolbase.dll` — which fails with `System.IO.FileNotFoundException` if toolbase isn't loaded yet. In the unpatched sequence, `local.toolbase` is mounted via `PackageManager.InstallProjects( IsBuiltIn )` further down in the same function — AFTER patch 4's auto-mount point. Without patch 7 the order is wrong and the addon throws even though patches 5 + 6 already cleared the whitelist. `InstallAsync` is idempotent so the later batch re-install is a no-op.

### Routine update procedure

Three independent moving parts: the engine (`sbox-public`), the setup tooling (this repo), and the addon itself (mounted via the editor's package system). Update them in this exact order so each step uses the freshest version of whatever it depends on.

**Linux users**: the same procedure applies, but substitute `./Script.sh` for every `.\Script.bat`/`.ps1` invocation below — same flags, same outputs, same recovery commands. Path separators flip from `\` to `/`. Pre-flight item 1 (closing the editor) is still required on Linux to release file handles, even though Linux's file locks are less aggressive than Windows'.

#### Pre-flight

```powershell
# 1. Close the editor if it's running — DLLs in game\bin\managed\ get
#    file-locked by sbox-dev.exe and Bootstrap will fail.

# 2. (Optional) sanity-check that your state matches a healthy post-
#    Setup tree before pulling.
cd <sbox-public>\game\addons\claude-sbox-setup
.\Safe-Pull.bat -DryRun
#    Healthy output: "[OK] 7/7 tracked patches present" plus the
#    incoming-commit count, then exits without pulling. If the
#    verifier reports markers missing OR finds an unrelated tracked
#    change in engine/, fix that BEFORE running Safe-Pull for real.
#
#    Most common case: markers missing because Setup was never run
#    on this clone, or `git checkout HEAD -- engine/` discarded the
#    applied patches. Fix is:  .\Setup.bat  (idempotent, re-applies
#    only what's missing).
#
#    NOTE: a healthy post-Setup tree DOES have 6 modified files
#    under engine/ — those are the applied patches and you want to
#    keep them. The thing to watch out for is OTHER changes mixed
#    in (e.g. you manually tweaked an engine source while debugging
#    and forgot). DO NOT `git checkout HEAD -- engine/` to "clean
#    up" before Safe-Pull — that wipes the patches Setup just
#    applied, and you'll have to re-run Setup.bat to recover.
```

#### Update tooling FIRST

```powershell
# 3. Pull this repo. Safe-Pull.bat is what we're about to USE — if the
#    script has been improved, we want the improved version. Also
#    brings in any new engine patches added under patches/ since last
#    time (new upstream changes occasionally need new patches).
cd <sbox-public>\game\addons\claude-sbox-setup
git pull
```

#### Pull engine + reapply patches

```powershell
# 4. Snapshot + pull sbox-public + re-apply every patch.
.\Safe-Pull.bat
#    Healthy output ends with "[OK] 7/7 tracked patches present" and
#    "[OK] HEAD is now <sha>". Any "[XX] FAILED" line means a patch
#    couldn't merge against the new upstream — Safe-Pull prints the
#    exact .\Restore-From-Backup.bat command to roll back.
```

#### Rebuild engine DLLs

```powershell
# 5. Compile managed DLLs against the new commit. Slow step (5-15 min
#    depending on whether NuGet caches are warm).
.\Bootstrap-And-Capture.bat
```

#### Refresh the companion skill (when it's changed)

```powershell
# 6. Sync the bundled sbox-live skill source into Claude Code's
#    user-scope skill directory. Skip when the skill/ tree didn't
#    change in step 3, but it's idempotent so re-running is fine.
$src = "<sbox-public>\game\addons\claude-sbox-setup\skill"
$dst = "$env:USERPROFILE\.claude\skills\sbox-live"
Copy-Item "$src\SKILL.md" "$dst\SKILL.md" -Force
Copy-Item "$src\references\*" "$dst\references\" -Force -Recurse
```

#### Restart + verify

```powershell
# 7. Launch the editor. The claude-sbox addon auto-updates on package
#    load — patch 0004 mounts the latest cached version from
#    game\.sbox-global\cloud\.bin\ on every project load. The editor's
#    package system polls sbox.game for newer published versions and
#    refreshes the cache automatically, so this picks up addon
#    updates without a manual `package_install` step.
<sbox-public>\game\sbox-dev.exe

# 8. From your Claude Code host (host shell, devcontainer, etc.):
claude mcp list
#    Look for "sbox    http://127.0.0.1:6790/mcp    Connected".
```

#### Failure recovery

| Where it broke | What it usually means | What to do |
|---|---|---|
| Step 3 `git pull` refuses | Local changes in the setup repo | `git status`, commit / stash, then pull |
| Step 4 — `Tracked patches missing or modified` pre-pull | `.gitignore` marker missing OR an engine file drifted | Re-run `.\Setup.bat` (writes the marker, idempotently re-applies patches) |
| Step 4 — `X patch(es) failed to apply cleanly` post-pull | Upstream rewrote a line a patch depends on | Open the failing `.patch` file + the target side-by-side, hand-merge the hunk, run `.\Refresh-Patches.bat` to recapture, then `.\Setup.bat` to finish |
| Step 4 leaves the engine in `Unmerged paths` state | 3-way merge produced conflict markers | `cd <sbox-public>; git checkout HEAD -- engine/` to reset, then `git stash pop` to restore `.gitignore`, then `.\Setup.bat` for a clean re-apply |
| Step 4 partially completed and you want to roll back fully | Anything | `.\Restore-From-Backup.bat -Snapshot <timestamp> -Yes` (the timestamp is printed at the bottom of the failed Safe-Pull output) |
| Step 5 `MSB3021 ... being used by another process` | Lingering sbox-dev / VBCSCompiler / dotnet build server | Re-run `.\Bootstrap-And-Capture.bat` (it has built-in lock-holder detection); or `.\Prepare-Bootstrap.bat -Yes` directly if you want to inspect first |
| Step 7 editor launches but no addon | Package cache wiped or first-time install on this clone | Developer console → `package_install ghage.claude-sbox tools` |
| Step 8 MCP server not connected | Port 6790 blocked, editor still booting, or addon failed to load | Check editor's Console dock for `[ClaudeSboxMcp]` log lines; verify port 6790 isn't taken (`netstat -ano \| findstr :6790`) |

#### Manual variant (if you prefer to skip Safe-Pull)

```powershell
# Equivalent steps without the safety wrapper. Lose: automatic
# snapshot, overlap-with-patches check, post-pull marker verification.
cd <sbox-public>
git pull
cd game\addons\claude-sbox-setup
git pull
.\Setup.bat
.\Bootstrap-And-Capture.bat
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

Pass `-Dry` to see what would be killed without touching anything. The script stops well-known holder process names (sbox-dev, VBCSCompiler, MSBuild, csc) and then issues `dotnet build-server shutdown` to release dotnet's persistent build server (which doesn't show up as a process to kill but can still hold DLL handles). If a lock persists after running it, use Sysinternals `handle64.exe -nobanner <path>` against the specific DLL to find an unusual holder (Explorer window with `game\bin\managed` focused, an antivirus mid-scan, etc.).

---

## Two channels

### 1. Dock widget

A docked terminal panel next to the Console / Asset Browser, hosting a real interactive PTY session. The backend is cross-platform — `IPty` factory picks `ConPtyBackend` on Windows (Win32 ConPTY) and `UnixPtyBackend` on Linux (libutil `forkpty(3)`). Default shell is `cmd.exe` on Windows, `bash` on Linux: you type whatever lands you in your environment (typically `docker exec -it <your-container> bash`, then `claude`). Rendering uses an xterm.js-grade grid renderer with full ANSI/cursor support so Claude Code's TUI displays correctly.

### 2. In-editor MCP server on `127.0.0.1:6790`

Exposes editor introspection + control as ~597 MCP tools. Localhost-only `HttpListener` hosting **three transports concurrently on the same port**:

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
6. Click it. A shell prompt appears in the widget (`cmd.exe` on Windows, `bash` on Linux).
7. Type your `docker exec -it <your-container> bash` (or whatever drops you into your environment), then `claude`.
8. Claude Code reads `.mcp.json`, the bridge connects to the editor on `host.docker.internal:6790`, and the editor logs `[claude-sbox] sbox-mcp-bridge connected`.

Verify with `bash bridge/scripts/check-setup.sh` from inside the container. Runs 7 checks and reports PASS/FAIL.

If the bridge can't reach the editor, Claude Code still works: it just doesn't have live editor introspection tools.

---

## MCP tool catalog

The canonical, always-current inventory of tools (with arg shapes and example call patterns) ships in this repo at [`skill/references/mcp-tools.md`](skill/references/mcp-tools.md). ~597 tools across these categories:

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

In active development. Architecture is feature-complete against the principle stated at the top: auto-gen handles `[Menu]`/`[Shortcut]`/`[ConCmd]`/`[Editor.Tool]` automatically, explicit handlers cover the surfaces that aren't attribute-tagged. Cross-platform PTY (Windows ConPTY + Linux libutil `forkpty`) and xterm.js-grade grid renderer are in. Open polish targets: connection-state UI (NoticeWidget + viewport overlay), and richer NodeGraph/ShaderGraph mutation if there's demand.
