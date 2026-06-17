# decompiler-driver

Prebuilt-at-runtime driver that wraps [ICSharpCode.Decompiler](https://www.nuget.org/packages/ICSharpCode.Decompiler)
(the ILSpy engine) so the **claude-sbox** addon can recover C# source from **precompiled** sbox.game
packages.

## Why this exists

Since sbox change **#5038** ("Load precompiled dlls from the manifest, no longer load clls"),
sbox.game packages ship their code as compiled managed assemblies (`.bin/package.*.dll`) instead of
`.cll` source archives. The addon's `package_download` tool decompiles those DLLs back to readable C#
— but s&box's in-editor Roslyn compiler resolves addon references only from `bin/managed/*.dll` +
`Libraries/` and **ignores NuGet**, so the addon can't reference `ICSharpCode.Decompiler` at compile
time.

Same play as `codesearch-driver/`: this is a tiny library compiled by normal `dotnet publish` and
loaded by the addon at runtime via `Assembly.LoadFrom` + reflection. The whole thing runs **in one
process** (no shell-out to `ilspycmd`); only this DLL + `ICSharpCode.Decompiler.dll` + its deps enter
the editor ALC.

## Build + deploy

```
../Build-Decompiler-Driver.bat      # Windows
../Build-Decompiler-Driver.sh       # Linux
```

or from the editor: the **`decompiler_install`** MCP tool. Either runs:

```
dotnet publish ClaudeSbox.Decompiler.Driver.csproj -c Release -o <game>/.claude-sbox/decompiler-driver/runtime
```

Output goes to the game's **global store** `<game>/.claude-sbox/decompiler-driver/runtime/` (sibling
of `codesearch-driver/` + the docs/learn caches), **never** into the addon — the published claude-sbox
package stays source-only. The addon loads `ClaudeSbox.Decompiler.Driver.dll` from there; override with
the `DECOMPILER_DRIVER_DLL` env var.

## Contract

One reflection entrypoint, `Entry.RunAsync(string opJson) -> Task<string>`, JSON in / JSON out
(`{ ok: bool, ... }`):

- `decompile` — `{ dll, outDir?, inline? }` → whole-module single-file decompile (the form proven
  reliable on current sbox.game assemblies; project mode throws on some newer TargetFramework
  metadata). Writes `{outDir}/{assembly}.decompiled.cs`.
- `metadata` — `{ dll }` → reads PE/CLI metadata (no decompile) for `.sbproj` recovery:
  `root_namespace` (dominant top-level namespace), `referenced_assemblies`, `type_count`.
- `status` — reports the loaded ICSharpCode.Decompiler version.

## Note on tooling

These are **managed C# assemblies** (IL), so ILSpy / ICSharpCode.Decompiler is the correct tool.
The `ghidra-re` skill is for **native** binaries — it would only apply as a fallback if a package ever
shipped a native blob, which sbox.game packages don't.
