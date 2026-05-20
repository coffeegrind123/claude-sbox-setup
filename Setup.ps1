#requires -Version 5.1
<#
.SYNOPSIS
    Apply claude-sbox's engine patches to a sbox-public checkout.

.DESCRIPTION
    claude-sbox depends on seven small engine modifications to behave
    correctly:

      1. engine/Sandbox.Engine/Systems/Project/Project/Project.Static.cs
         Adds the addon to the engine's built-in addon list IF the source
         clone exists at game/addons/claude-sbox/. Source-clone path only;
         cloud-installed users (the common case) get auto-load via patch 4.

      2. engine/Tools/SboxBuild/Steps/DownloadPublicArtifacts.cs
         Dedupes manifest entries by destination path before the parallel
         download fan-out. Prevents the upstream "being used by another
         process" cascade caused by duplicate-path manifest revisions.

      3. engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs
         Enables publish-compile support for tool-type projects so the addon
         can be packaged through the editor's publish pipeline.

      4. engine/Sandbox.Tools/StartupLoadProject.cs
         Auto-mounts ghage.claude-sbox from a global cache at
         <sbox-public>/game/.sbox-global/cloud/.bin/ on every project load,
         so a one-time `package_install ghage.claude-sbox tools` in the
         dev console makes the addon available for every project, every
         editor restart, with no redownload. Also protects the cache from
         RefreshCloudAssets cross-project eviction. Scoped to claude-sbox
         only; other cloud packages keep default per-project cache behaviour.

      5. engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs
         Skips the unconditional "editor" IgnoreFolders entry at
         publish-compile time when the project type is "tool". Facepunch's
         publish path adds "editor" to IgnoreFolders unconditionally,
         which is correct for game/library addons (Code/Editor/ holds
         editor-only inspectors and tool windows that shouldn't ship to
         players) but actively wrong for tool-type addons -- a tool
         addon is ENTIRELY editor code, almost always namespaced under
         Editor.<X> with all source under Code/Editor/. Adding "editor"
         to IgnoreFolders silently strips the whole codebase, packs only
         Code/Imports.cs into the .cll, and produces an empty (~1KB)
         package that mounts with no [Event] handlers. With this patch
         tool publishes ship real code. Maintainers-only -- only matters
         if you're republishing the addon to sbox.game, not for
         installing it. Touches the same file as patch 3 but a different
         block; both apply cleanly in sequence.

      6. engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs (third
         block in the same file, inside patch 3's "if Type == tool"
         block). Mirrors the in-editor compile's explicit assembly
         references (Sandbox.Tools, Sandbox.Compiling, System.Diagnostics
         .Process, System.Net.WebSockets[.Client], Microsoft.Win32
         .Registry, System.Memory, Sandbox.Bind, Facepunch.ActionGraphs,
         SkiaSharp, Microsoft.CodeAnalysis, Microsoft.CodeAnalysis.CSharp)
         plus AddToolBaseReference for non-toolbase projects. Project
         .Compiling.cs:109-122 adds all of these for the in-editor compile,
         so addon code that uses them works at runtime; the publish-compile
         in this file wasn't adding them and tool publishes failed with
         hundreds of "type or namespace not found" errors. Maintainers-only.

      7. engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs (fourth
         block, immediately after CompileGroup creation). Sets the publish
         CompileGroup's ReferenceProvider so cross-package references like
         `package.toolbase` (from patch 6's AddToolBaseReference) can
         resolve via PackageManager.ActivePackages.Lookup. In-editor compile
         groups get a provider from their owning ActivePackage; the publish
         CompileGroup is fresh and doesn't, so AddToolBaseReference throws
         "Couldn't find reference package.toolbase" without this. Hands the
         group any ActivePackage as the lookup root (they all share the
         same global HashSet). Maintainers-only.

      8. engine/Sandbox.Tools/Utility/Utility.Projects.Compile.cs (fifth
         block, also near the CompileGroup creation). Nulls out the
         AccessControl whitelist for tool-type publishes. The whitelist
         restricts game/library publishes to a curated API surface (no
         Process, File, HttpClient, raw editor types, ...) -- correct for
         sandboxed runtime content but actively wrong for tool addons,
         which by design need full editor + .NET access. In-editor compile
         never applies this whitelist; the publish path was the only place
         enforcing it. Without this patch tool publishes fail with ~700
         "is not allowed when whitelist is enabled" errors. Maintainers-only.

      9. engine/Sandbox.Engine/Services/Packages/PackageManager/
         PackageManager.ActivePackage.cs. The CLOUD-MOUNT counterpart to
         patch 8. When a user installs ghage.claude-sbox from sbox.game,
         the addon is mounted by ActivePackage.CompileCodeArchive, which
         sets group.AccessControl = AccessControl on its own CompileGroup
         and triggers the same whitelist check at mount time -- so users
         who DON'T have the addon source-cloned at game/addons/claude-sbox/
         can't load the addon either. Project.Compiling.cs:56 already sets
         Whitelist=false for tool projects loaded via the source path; this
         patch mirrors that by nulling AccessControl for tool-type packages
         in the cloud-mount path. Patch 8 fixes the publishing side, patch
         9 fixes the consuming side -- both needed for end-to-end cloud
         distribution of a tool addon.

      10. engine/Sandbox.Engine/Services/Packages/PackageManager/
          PackageLoader.cs. Patch 9 fixed the cloud-mount COMPILE-time
          whitelist (CompileCodeArchive); patch 10 fixes the cloud-mount
          DLL-LOAD-time whitelist (LoadAssemblyFromPackage). Facepunch's
          original logic skips access control for tool assemblies only
          when `ap.Package is LocalPackage`; the surrounding comment
          literally says "This is used for tool packages which are
          ALWAYS local." With cloud-installed tool addons the package is
          a REMOTE Package, that branch never fires, and every cloud
          tool addon hits hundreds of "Whitelist Error: X is not allowed
          when whitelist is enabled" plus "Couldn't resolve 'Microsoft
          .CodeAnalysis.CSharp / Facepunch.ActionGraphs / ...'" from
          AccessControl.VerifyAssembly's metadata walker. Patch 10
          extends the skip to remote tool assemblies. End-user-facing --
          every cloud-install user needs this patch applied, paired
          with patch 9.

      11. engine/Sandbox.Tools/StartupLoadProject.cs (second insertion in
          the same file as patch 4, immediately before patch 4's
          InstallAsync of ghage.claude-sbox). Mounts local.toolbase
          FIRST. The published claude-sbox.dll has a direct assembly
          reference on package.toolbase (baked in by patch 6's
          AddToolBaseReference). When the CLR runs the addon's static
          constructors via RunAllStaticConstructors, it asks the
          LoadContext to resolve `package.toolbase.dll`. In the
          unpatched OpenProject sequence local.toolbase is mounted via
          `PackageManager.InstallProjects( IsBuiltIn )` further down --
          AFTER patch 4's auto-mount. Without patch 11 the order is
          wrong and the addon throws System.IO.FileNotFoundException
          for package.toolbase during static-ctor init, even though
          patches 9 + 10 already cleared the whitelist gates.
          PackageManager.InstallAsync is idempotent so the later
          InstallProjects re-install of toolbase becomes a no-op.

    This script applies all seven patches to the parent sbox-public checkout.
    It is idempotent: re-running on a checkout where the patches are already
    applied is a no-op.

    For routine sbox-public updates, prefer .\Safe-Pull.bat — it snapshots
    your state, reverts the patches, runs `git pull`, then re-applies the
    patches automatically. Falling back to plain `git pull` followed by
    re-running this Setup.ps1 also works but skips the safety net.

.PARAMETER DryRun
    Show what would be done without modifying any files.

.PARAMETER Force
    Re-apply patches even if they appear to be already applied. Use this if
    you suspect the in-place patch text has been mangled.

.EXAMPLE
    .\Setup.ps1
    Apply the patches.

.EXAMPLE
    .\Setup.ps1 -DryRun
    Preview without writing.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

# Helper: run `git ...` and return ($exitCode, $stdoutPlusStderr) without
# triggering PowerShell's NativeCommandError termination on non-zero exit.
# We can't just rely on `2>$null` because Windows PowerShell 5.1 still hoists
# the stderr stream into PSes error pipeline regardless of redirection.
function Invoke-Git {
    # Bind ValueFromRemainingArguments to a name that's NOT $Args. The
    # automatic $Args variable exists in every function scope already and
    # binding a typed parameter to that same name is at best confusing
    # (PowerShell silently uses the typed binding) and at worst breaks
    # any subsequent reference that expected the automatic. Rename to
    # $GitArgs.
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs)
    $out = & git @GitArgs 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
}

# ---------------------------------------------------------------------------
# Locate sbox-public root: <root>/game/addons/claude-sbox-setup/Setup.ps1 — walk up 3.
# ---------------------------------------------------------------------------
$setupDir   = Split-Path -Parent $PSCommandPath
$addonsDir  = Split-Path -Parent $setupDir
$gameDir    = Split-Path -Parent $addonsDir
$sboxRoot   = Split-Path -Parent $gameDir
$patchesDir = Join-Path $setupDir 'patches'

Write-Host ""
Write-Host "==> claude-sbox setup" -ForegroundColor Cyan
Write-Host "    setup:       $setupDir"
Write-Host "    sbox-public: $sboxRoot"
Write-Host ""

# ---------------------------------------------------------------------------
# Sanity: directory looks like a sbox-public checkout.
# ---------------------------------------------------------------------------
$enginePath  = Join-Path $sboxRoot 'engine'
$gamePath    = Join-Path $sboxRoot 'game'
$marker1Path = Join-Path $sboxRoot 'engine\Sandbox.Engine\Systems\Project\Project\Project.Static.cs'
$marker2Path = Join-Path $sboxRoot 'engine\Tools\SboxBuild\Steps\DownloadPublicArtifacts.cs'

if (-not (Test-Path $enginePath) -or -not (Test-Path $gamePath)) {
    Write-Host "[XX] $sboxRoot does not look like a sbox-public checkout (missing engine/ or game/)." -ForegroundColor Red
    Write-Host "[XX] Expected layout: <sbox-public>/game/addons/claude-sbox-setup/"
    exit 1
}
if (-not (Test-Path $marker1Path) -or -not (Test-Path $marker2Path)) {
    Write-Host "[XX] Engine source files the patches target are missing." -ForegroundColor Red
    Write-Host "[XX]   $marker1Path"
    Write-Host "[XX]   $marker2Path"
    Write-Host "[XX] Has Facepunch moved them? Open an issue with your sbox-public commit SHA."
    exit 1
}

# ---------------------------------------------------------------------------
# Apply each patch.
# ---------------------------------------------------------------------------
Push-Location $sboxRoot
try {
    # `git apply --check --reverse` succeeds when the patch is *already applied*,
    # because reversing it would land cleanly. We use that as our idempotency probe.
    $patches = Get-ChildItem $patchesDir -Filter '*.patch' -ErrorAction SilentlyContinue | Sort-Object Name
    if ($patches.Count -eq 0) {
        Write-Host "[XX] No patches found under $patchesDir" -ForegroundColor Red
        exit 1
    }

    # --ignore-whitespace lets git apply succeed when Windows' core.autocrlf=true
    # has converted the patch file (and/or the target file) to CRLF. Without it,
    # patches generated on Linux fail on a fresh Windows checkout for cosmetic
    # whitespace reasons. Safe to use unconditionally; we don't ship patches that
    # rely on whitespace correctness.
    $applyFlags = @('--ignore-whitespace')

    $appliedCount = 0
    $skippedCount = 0
    foreach ($p in $patches) {
        Write-Host "    $($p.Name)... " -NoNewline

        # Build the CRLF-normalized variant of the patch up front so both
        # the idempotency probe (below) and the forward-apply fallbacks
        # can use it. The forward tiers used to create this on demand,
        # but the asymmetry between forward (tiered with CRLF fallback)
        # and reverse-check (single LF attempt) was exactly what broke
        # Windows users with autocrlf=true: an already-applied patch
        # failed the strict reverse-check on CRLF mismatch, fell through
        # to the forward tiers, and let patch.exe's fuzzy matcher double-
        # apply it — corrupting the working tree.
        #
        # [System.IO.Path]::GetTempPath() is more reliable than $env:TEMP —
        # it falls back through the same chain (TMP, TEMP, USERPROFILE,
        # then the Windows system temp). $env:TEMP can be empty under
        # SYSTEM service contexts or freshly-spawned non-interactive
        # shells.
        $crlfPatch = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-sbox-" + $p.BaseName + "-crlf.patch")
        $content = [System.IO.File]::ReadAllText($p.FullName)
        # First normalise any pre-existing CRLF back to LF so we don't
        # produce mixed endings, then convert every LF to CRLF wholesale.
        $content = $content.Replace("`r`n", "`n").Replace("`n", "`r`n")
        [System.IO.File]::WriteAllText($crlfPatch, $content, [System.Text.UTF8Encoding]::new($false))

        # Tiered idempotency probe — strict only, LF and CRLF variants.
        #
        # We deliberately do NOT use `--3way --check --reverse` here even
        # though `--3way` is part of the forward apply tiers. The reason:
        # `--3way` consults git's object database to find blobs matching
        # the patch's expected pre- or post-state. For an idempotency
        # check this is unsafe: if the patch was ever applied + committed
        # somewhere in history (which is true for every patch in this
        # repo — they're committed to claude-sbox-setup), `--3way
        # --check --reverse` reports SUCCESS for a freshly-reverted file
        # at HEAD, because the blob "HEAD plus patch" exists in some
        # git object store. That's a false positive: Setup would skip
        # the patch as "already applied" when in reality the file is
        # clean and needs the patch applied fresh. The downstream effect
        # is partial patch coverage — patches stacked on the same file
        # (like 0005-0008 on Utility.Projects.Compile.cs) cascade-fail.
        #
        # Strict `--check --reverse` actually examines the working-tree
        # file's context lines and only succeeds when they match the
        # post-patch state. CRLF normalization on the patch file is the
        # only legitimate variant — covers Windows checkouts where the
        # working tree is CRLF but the LF patch can't context-match.
        if (-not $Force) {
            $checkOk =
                ((Invoke-Git apply --check --reverse @applyFlags $p.FullName).ExitCode -eq 0) -or
                ((Invoke-Git apply --check --reverse @applyFlags $crlfPatch).ExitCode -eq 0)
            if ($checkOk) {
                Write-Host "already applied" -ForegroundColor Yellow
                $skippedCount++
                continue
            }
        }

        if ($DryRun) {
            $r = Invoke-Git apply --check @applyFlags $p.FullName
            if ($r.ExitCode -eq 0) {
                Write-Host "would apply (dry-run)" -ForegroundColor Yellow
            } else {
                Write-Host "WOULD FAIL (dry-run)" -ForegroundColor Red
                Write-Host $r.Output -ForegroundColor DarkGray
            }
            continue
        }

        # Tier 1: git apply (strict context match).
        $r = Invoke-Git apply @applyFlags $p.FullName
        if ($r.ExitCode -eq 0) {
            Write-Host "applied" -ForegroundColor Green
            $appliedCount++
            continue
        }

        # Tier 2: git apply --3way. Uses blob hashes in the patch header to
        # find the original file in git's history and does a 3-way merge.
        # Works when the user's sbox-public has the same upstream blob in
        # its object database, even if HEAD has moved on. Also recovers
        # from line-ending drift if the user's git did autocrlf on checkout.
        $r3 = Invoke-Git apply --3way @applyFlags $p.FullName
        if ($r3.ExitCode -eq 0) {
            Write-Host "applied (3way)" -ForegroundColor Green
            $appliedCount++
            continue
        }

        # Tier 3: re-try with the CRLF-normalized patch variant we built
        # at the top of the loop. Matches Windows working-tree files
        # (autocrlf=true converts LF->CRLF on checkout but the index
        # stays LF, so an LF patch doesn't context-match the CRLF working
        # tree and `does not match index` fires on --3way).
        $rCRLF = Invoke-Git apply @applyFlags $crlfPatch
        if ($rCRLF.ExitCode -eq 0) {
            Write-Host "applied (crlf)" -ForegroundColor Green
            $appliedCount++
            continue
        }
        $rCRLF3 = Invoke-Git apply --3way @applyFlags $crlfPatch
        if ($rCRLF3.ExitCode -eq 0) {
            Write-Host "applied (crlf-3way)" -ForegroundColor Green
            $appliedCount++
            continue
        }

        # Tier 4: fall back to GNU patch.exe with fuzz=5. Ships with Git
        # for Windows under <install>/usr/bin/. We probe PATH first, then
        # locate it relative to git.exe if PATH didn't have it.
        $patchExeSource = $null
        $patchExe = Get-Command patch.exe -ErrorAction SilentlyContinue
        if ($patchExe) { $patchExeSource = $patchExe.Source }
        if (-not $patchExeSource) {
            $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
            if ($gitCmd) {
                $gitDir = Split-Path -Parent $gitCmd.Source
                # Git for Windows layouts: <inst>/cmd/git.exe or <inst>/bin/git.exe -> <inst>/usr/bin/patch.exe
                foreach ($rel in '..\usr\bin\patch.exe', '..\..\usr\bin\patch.exe', '..\..\mingw64\bin\patch.exe') {
                    $cand = Join-Path $gitDir $rel
                    if (Test-Path $cand) { $patchExeSource = (Resolve-Path $cand).Path; break }
                }
            }
        }

        if ($patchExeSource) {
            # Use the CRLF-normalised patch as input — patch.exe tolerates
            # eol mismatches better but matching the target's endings still
            # gives the cleanest result.
            $patchInput = if (Test-Path $crlfPatch) { $crlfPatch } else { $p.FullName }
            $patchOut = & $patchExeSource -p1 --fuzz=5 --no-backup-if-mismatch --silent --input $patchInput 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "applied (fuzzy)" -ForegroundColor Green
                $appliedCount++
                continue
            } else {
                $tier4Output = $patchOut -join "`n"
            }
        }

        # All four tiers failed. Surface diagnostics.
        Write-Host "FAILED" -ForegroundColor Red
        Write-Host ""
        Write-Host "  git apply (strict):"        -ForegroundColor DarkGray
        Write-Host "    $($r.Output.Trim())"      -ForegroundColor DarkGray
        Write-Host "  git apply --3way:"          -ForegroundColor DarkGray
        Write-Host "    $($r3.Output.Trim())"     -ForegroundColor DarkGray
        Write-Host "  git apply (crlf-patch):"    -ForegroundColor DarkGray
        Write-Host "    $($rCRLF.Output.Trim())"  -ForegroundColor DarkGray
        Write-Host "  git apply --3way (crlf):"   -ForegroundColor DarkGray
        Write-Host "    $($rCRLF3.Output.Trim())" -ForegroundColor DarkGray
        if ($patchExeSource) {
            Write-Host "  patch.exe --fuzz=5 ($patchExeSource):"          -ForegroundColor DarkGray
            Write-Host "    $tier4Output"                                 -ForegroundColor DarkGray
        } else {
            Write-Host "  patch.exe: not located (not on PATH and not next to git.exe)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "    Patch did not apply via any tier. Likely upstream sbox-public" -ForegroundColor Red
        Write-Host "    has rewritten the lines this patch targets beyond what fuzzy" -ForegroundColor Red
        Write-Host "    matching can handle. Inspect the patch and the target by hand:" -ForegroundColor Red
        Write-Host "      patch:  $($p.FullName)"
        $tgt = ($(Select-String -Path $p.FullName -Pattern '^\+\+\+ b/' | Select-Object -First 1).Line -replace '^\+\+\+ b/','')
        Write-Host "      target: <sbox-public>/$tgt"
        Write-Host ""
        Write-Host "    To roll back to a known-good state, list available snapshots:" -ForegroundColor Yellow
        Write-Host "        .\Restore-From-Backup.bat -List" -ForegroundColor Yellow
        Write-Host "    then restore one with -Snapshot <name> -Yes." -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    if ($DryRun) {
        Write-Host "==> Dry run complete. No files changed." -ForegroundColor Cyan
    } else {
        Write-Host "==> Done. $appliedCount applied, $skippedCount already in place." -ForegroundColor Cyan

        # ---------------------------------------------------------------------
        # Write the managed `.gitignore` block. Two things this gives us:
        #   1. `.claude-sbox/` (the addon's on-disk cache root for docs / docs-
        #      repo / learn-repo / schema) gets git-ignored. The repo's existing
        #      allowlist-style `.gitignore` already excludes it by default, but
        #      naming it here is documentation-as-config — a future contributor
        #      reading `.gitignore` understands why those dirs exist.
        #   2. `.backups/` (Snapshot-Now's output dir at the setup-repo root)
        #      gets git-ignored. Safe-Pull.ps1's docstring already claims this
        #      exclusion exists but nothing previously wrote it.
        #   3. A literal `claude-sbox` substring lands somewhere in the file,
        #      which is the marker Safe-Pull.ps1 checks for as proof that
        #      Setup ran. Without this marker, fresh installs fail Safe-Pull's
        #      pre-pull verification with "tracked patches missing or
        #      modified: .gitignore (marker not found)".
        # Bracketed so we can find + idempotently update the block on re-runs
        # without duplicating lines or stomping unrelated edits.
        $giPath = Join-Path $sboxRoot '.gitignore'
        # ASCII-safe markers — PowerShell on Windows double-encodes non-ASCII
        # chars on .gitignore writes (UTF-8 em-dash bytes get re-encoded as
        # CP1252 then back to UTF-8), so the canonical em-dash version in
        # this script wouldn't byte-match the file on subsequent re-runs and
        # we'd write duplicate managed blocks. Plain `--` avoids the trap
        # and matches what Setup.sh writes on Linux.
        $beginMarker = '# >>> claude-sbox (managed block -- do not edit between markers) >>>'
        $endMarker   = '# <<< claude-sbox <<<'
        $blockBody = @(
            $beginMarker
            '# Local addon cache (BM25 indexes, docs tarball, learn-mirror tarball, schema dumps).'
            '.claude-sbox/'
            ''
            '# Snapshot output from Snapshot-Now.ps1 / Safe-Pull.ps1 auto-snapshots.'
            'game/addons/claude-sbox-setup/.backups/'
            $endMarker
        ) -join "`n"

        if (-not (Test-Path $giPath)) {
            # Brand new checkout with no .gitignore is rare but defensively
            # handled — create the file with just our block.
            [System.IO.File]::WriteAllText($giPath, $blockBody + "`n", (New-Object System.Text.UTF8Encoding $false))
            Write-Host ""
            Write-Host "==> Wrote managed block to a new .gitignore at $giPath" -ForegroundColor Cyan
        }
        else {
            $existing = [System.IO.File]::ReadAllText($giPath)
            if ($existing -match [regex]::Escape($beginMarker) -and $existing -match [regex]::Escape($endMarker)) {
                # Replace the existing managed block in-place. Lets us bump the
                # body content on Setup re-runs without leaving stale lines.
                $pattern = [regex]::Escape($beginMarker) + '[\s\S]*?' + [regex]::Escape($endMarker)
                $replacement = $blockBody -replace '\$', '$$$$'   # escape $ for [regex]::Replace
                $updated = [regex]::Replace($existing, $pattern, $replacement)
                if ($updated -ne $existing) {
                    [System.IO.File]::WriteAllText($giPath, $updated, (New-Object System.Text.UTF8Encoding $false))
                    Write-Host ""
                    Write-Host "==> Refreshed managed claude-sbox block in $giPath" -ForegroundColor DarkGray
                }
            }
            else {
                # First-time append. Ensure trailing newline before our block.
                $sep = if ($existing.EndsWith("`n")) { "`n" } else { "`n`n" }
                [System.IO.File]::AppendAllText($giPath, $sep + $blockBody + "`n", (New-Object System.Text.UTF8Encoding $false))
                Write-Host ""
                Write-Host "==> Appended managed claude-sbox block to $giPath" -ForegroundColor Cyan
            }
        }

        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "  1. From this directory, run: .\Bootstrap-And-Capture.bat"
        Write-Host "     (downloads engine artifacts + compiles managed DLLs against the"
        Write-Host "     patched engine; the wrapper handles locked-DLL retries that plain"
        Write-Host "     Bootstrap.bat trips on)"
        Write-Host "  2. Launch $sboxRoot\game\sbox-dev.exe with any project."
        Write-Host "  3. Open the developer console and run, ONCE EVER:"
        Write-Host "       package_install ghage.claude-sbox tools"
        Write-Host "     (downloads the addon to a global cache; subsequent project loads"
        Write-Host "     reuse it instantly with no redownload)"
        Write-Host "  4. The in-editor MCP host comes up on http://127.0.0.1:6790."
        Write-Host "  5. Connect Claude Code:"
        Write-Host "       claude mcp add --transport http -s user sbox http://127.0.0.1:6790/mcp"
        Write-Host "     (or http://host.docker.internal:6790/mcp from a devcontainer)"
        Write-Host "  6. For future sbox-public updates, prefer .\Safe-Pull.bat (from this directory)."
        Write-Host "     It snapshots state, reverts patches, pulls, and re-applies in one step."
    }
}
finally {
    Pop-Location
}
