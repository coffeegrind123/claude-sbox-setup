using System.Text.Json;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using ICSharpCode.Decompiler;
using ICSharpCode.Decompiler.CSharp;
using ICSharpCode.Decompiler.Metadata;

namespace ClaudeSbox.Decompiler.Driver;

/// <summary>
/// The decompiler driver's single reflection entrypoint. The s&amp;box addon loads this DLL via
/// <c>Assembly.LoadFrom</c> (see <c>DecompilerEngine</c> in the claude-sbox addon) and calls
/// <see cref="RunAsync"/> through reflection — the boundary is pure string JSON, and framework
/// <c>Task&lt;string&gt;</c> is shared across the load boundary, so the awaited cast is valid.
///
/// JSON contract (mirrors the codesearch driver): input <c>{ op, ... }</c>; output
/// <c>{ ok: bool, ... }</c>, with <c>ok:false</c> carrying <c>error</c> + <c>message</c>.
///
/// Ops:
///   • <c>decompile</c> — <c>{ dll, outDir?, inline? }</c>. Decompiles a managed assembly to C#
///     using ICSharpCode.Decompiler's whole-module single-file mode (the form proven reliable on
///     current sbox.game assemblies — project mode throws on some newer TargetFramework metadata).
///     Writes <c>{outDir}/{assembly}.decompiled.cs</c> when <c>outDir</c> is given; returns the
///     source inline when <c>inline:true</c> or no <c>outDir</c>. Resilient to unresolved refs
///     (<see cref="DecompilerSettings.ThrowOnAssemblyResolveErrors"/> = false).
///   • <c>status</c> — reports the loaded ICSharpCode.Decompiler version.
/// </summary>
public static class Entry
{
	/// <summary>The single reflection entrypoint. See class remarks for the JSON contract.</summary>
	public static Task<string> RunAsync( string opJson )
	{
		try
		{
			using var doc = JsonDocument.Parse( opJson ?? "{}" );
			var root = doc.RootElement;
			var op = Str( root, "op" ) ?? "";

			return Task.FromResult( op switch
			{
				"decompile" => DoDecompile( root ),
				"metadata" => DoMetadata( root ),
				"status" => DoStatus(),
				_ => Err( "bad_op", $"unknown op '{op}'" ),
			} );
		}
		catch ( Exception e )
		{
			return Task.FromResult( Err( "driver_error", $"{e.GetType().Name}: {e.Message}" ) );
		}
	}

	// ───────────────────────── ops ─────────────────────────

	static string DoDecompile( JsonElement root )
	{
		var dll = Str( root, "dll" );
		var outDir = Str( root, "outDir" );
		bool inline = root.TryGetProperty( "inline", out var inl ) && inl.ValueKind == JsonValueKind.True;

		// Reference directories for the resolver. Passing the engine's managed assemblies (and the
		// package's own .bin deps) lets ICSharpCode.Decompiler resolve types, which raises output
		// fidelity dramatically — auto-properties, extension-method syntax, object initializers and
		// real conversions instead of <>k__BackingField / static-call / op_Implicit / (ref)-cast
		// fallbacks. Empirically this alone removes the bulk of the recompilation artifacts.
		var refDirs = StrArray( root, "refDirs" );

		// s&box source cleanup (strip [SourceLocation] + generated [Sync]/[ConVar] members, fix the
		// residual decompiler artifacts). Defaults ON; the produced source targets the s&box compiler.
		bool cleanup = !( root.TryGetProperty( "cleanup", out var cu ) && cu.ValueKind == JsonValueKind.False );

		if ( string.IsNullOrEmpty( dll ) || !File.Exists( dll ) )
			return Err( "dll_not_found", $"assembly not found: {dll ?? "(null)"}" );

		string code;
		SboxSourceCleaner.Stats cleanStats = null;
		try
		{
			var settings = new DecompilerSettings { ThrowOnAssemblyResolveErrors = false };

			CSharpDecompiler decompiler;
			if ( refDirs.Count > 0 )
			{
				var resolver = new UniversalAssemblyResolver( dll, settings.ThrowOnAssemblyResolveErrors, null );
				foreach ( var d in refDirs )
					if ( !string.IsNullOrEmpty( d ) && Directory.Exists( d ) )
						resolver.AddSearchDirectory( d );
				decompiler = new CSharpDecompiler( dll, resolver, settings );
			}
			else
			{
				decompiler = new CSharpDecompiler( dll, settings );
			}

			code = decompiler.DecompileWholeModuleAsString();
			if ( cleanup )
				code = SboxSourceCleaner.Clean( code, out cleanStats );
		}
		catch ( Exception e )
		{
			return Err( "decompile_failed", $"{e.GetType().Name}: {e.Message}" );
		}

		var asmName = Path.GetFileNameWithoutExtension( dll );
		string outFile = null;
		if ( !string.IsNullOrEmpty( outDir ) )
		{
			Directory.CreateDirectory( outDir );
			outFile = Path.Combine( outDir, asmName + ".decompiled.cs" );
			File.WriteAllText( outFile, code );
		}

		var lines = 1;
		foreach ( var c in code ) if ( c == '\n' ) lines++;

		var fLines = lines;
		var fFile = outFile;
		var fInline = inline || outFile == null;
		var fRefs = refDirs.Count;
		var fStats = cleanStats;
		return Ok( w =>
		{
			w.WriteString( "assembly", asmName );
			w.WriteNumber( "length", code.Length );
			w.WriteNumber( "lines", fLines );
			w.WriteNumber( "ref_dirs", fRefs );
			if ( fStats != null )
			{
				w.WriteString( "cleanup", fStats.ToString() );
				w.WriteBoolean( "cleaned", true );
			}
			if ( fFile != null ) w.WriteString( "output_file", fFile );
			if ( fInline ) w.WriteString( "source", code );
		} );
	}

	/// <summary>
	/// Recover the .sbproj-relevant bits that ARE present in the compiled assembly: the dominant
	/// top-level namespace (→ RootNamespace) and the referenced assembly names. Read straight from
	/// PE/CLI metadata (no decompile needed). DefineConstants / NoWarn etc. are compile-time-only and
	/// not recoverable — the caller fills those with sensible s&amp;box defaults.
	/// </summary>
	static string DoMetadata( JsonElement root )
	{
		var dll = Str( root, "dll" );
		if ( string.IsNullOrEmpty( dll ) || !File.Exists( dll ) )
			return Err( "dll_not_found", $"assembly not found: {dll ?? "(null)"}" );

		try
		{
			using var fs = File.OpenRead( dll );
			using var pe = new PEReader( fs );
			var mr = pe.GetMetadataReader();

			// Referenced assemblies (raw — caller filters engine/framework refs).
			var refs = new List<string>();
			foreach ( var h in mr.AssemblyReferences )
				refs.Add( mr.GetString( mr.GetAssemblyReference( h ).Name ) );
			refs.Sort( StringComparer.OrdinalIgnoreCase );

			// Dominant top-level namespace across non-nested, non-compiler-generated types → RootNamespace.
			var seg = new Dictionary<string, int>();
			foreach ( var th in mr.TypeDefinitions )
			{
				var td = mr.GetTypeDefinition( th );
				if ( !td.GetDeclaringType().IsNil ) continue;          // skip nested
				var ns = mr.GetString( td.Namespace );
				if ( string.IsNullOrEmpty( ns ) ) continue;
				var name = mr.GetString( td.Name );
				if ( name.StartsWith( "<" ) ) continue;               // compiler-generated
				var first = ns.Split( '.' )[0];
				seg[first] = seg.GetValueOrDefault( first ) + 1;
			}
			string rootNs = null;
			int bestCount = -1;
			foreach ( var kv in seg )
				if ( kv.Value > bestCount ) { bestCount = kv.Value; rootNs = kv.Key; }

			var asmName = mr.IsAssembly ? mr.GetString( mr.GetAssemblyDefinition().Name ) : Path.GetFileNameWithoutExtension( dll );

			var fRefs = refs; var fRoot = rootNs; var fAsm = asmName; var fTypes = seg.Values.Sum();
			return Ok( w =>
			{
				w.WriteString( "assembly", fAsm );
				if ( fRoot != null ) w.WriteString( "root_namespace", fRoot );
				w.WriteNumber( "type_count", fTypes );
				w.WritePropertyName( "referenced_assemblies" );
				w.WriteStartArray();
				foreach ( var r in fRefs ) w.WriteStringValue( r );
				w.WriteEndArray();
			} );
		}
		catch ( Exception e )
		{
			return Err( "metadata_failed", $"{e.GetType().Name}: {e.Message}" );
		}
	}

	static string DoStatus()
	{
		var ver = typeof( CSharpDecompiler ).Assembly.GetName().Version?.ToString() ?? "unknown";
		return Ok( w =>
		{
			w.WriteString( "decompiler", "ICSharpCode.Decompiler" );
			w.WriteString( "version", ver );
			w.WriteBoolean( "available", true );
		} );
	}

	// ───────────────────────── helpers (mirror the codesearch driver) ─────────────────────────

	static string Str( JsonElement e, string n ) => e.TryGetProperty( n, out var v ) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

	static List<string> StrArray( JsonElement e, string n )
	{
		var list = new List<string>();
		if ( e.TryGetProperty( n, out var v ) && v.ValueKind == JsonValueKind.Array )
			foreach ( var item in v.EnumerateArray() )
				if ( item.ValueKind == JsonValueKind.String ) list.Add( item.GetString() );
		return list;
	}

	static string Ok( Action<Utf8JsonWriter> body )
	{
		using var ms = new MemoryStream();
		using ( var w = new Utf8JsonWriter( ms ) )
		{
			w.WriteStartObject();
			w.WriteBoolean( "ok", true );
			body( w );
			w.WriteEndObject();
		}
		return System.Text.Encoding.UTF8.GetString( ms.ToArray() );
	}

	static string Err( string error, string message )
	{
		using var ms = new MemoryStream();
		using ( var w = new Utf8JsonWriter( ms ) )
		{
			w.WriteStartObject();
			w.WriteBoolean( "ok", false );
			w.WriteString( "error", error );
			w.WriteString( "message", message );
			w.WriteEndObject();
		}
		return System.Text.Encoding.UTF8.GetString( ms.ToArray() );
	}
}
