using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace ClaudeSbox.Decompiler.Driver;

/// <summary>
/// Post-processes ICSharpCode.Decompiler output of an s&amp;box package assembly into source that the
/// s&amp;box compiler accepts. Two classes of artifact need fixing:
///
///   1. LOW-FIDELITY DECOMPILATION — produced when the decompiler can't resolve engine types
///      (no reference assemblies). These are best avoided at the source by passing reference dirs to
///      <see cref="CSharpDecompiler"/> (see <c>Entry.DoDecompile</c>); with refs they nearly vanish.
///      The transforms here still clean up the residue (and the whole lot when refs are unavailable):
///        • <c>Type.op_Implicit(x)</c>            → <c>(Type)(x)</c>
///        • <c>(ref x)</c> constrained-call casts → <c>x</c>
///        • <c>obj.set_Prop(v)</c> / <c>get_Prop()</c> → <c>obj.Prop = v</c> / <c>obj.Prop</c>
///        • <c>T v = default; v.A = ..;</c>       → object initializer <c>new T { A = .. }</c>
///        • <c>((Base)this).OnX()</c> base calls  → <c>base.OnX()</c>
///        • ILSpy <c>(??)</c> null-coalescing reconstruction placeholders → removed
///
///   2. IL-BAKED S&amp;BOX CODEGEN — genuinely present in the bytecode, so even a perfect decompile
///      reproduces it; references DON'T help. These collide with the live source generator or are not
///      legal source identifiers, and MUST be stripped:
///        • <c>[SourceLocation("file", n)]</c>     — compiler-injected on every member
///        • <c>[assembly:]</c> / <c>[module:]</c>  — duplicate the compiler's own assembly attributes
///        • <c>&lt;Prop&gt;k__BackingField</c>     — illegal identifier; renamed to <c>__bf_Prop</c>
///        • <c>__X_SyncAttribute__Cached*</c>, <c>__X_ConVarAttribute__Cached*</c>, <c>__X__Attrs</c>
///          — the [Sync]/[ConVar] generator re-emits these, so the source copies are duplicates.
///
/// Every transform is idempotent and order-sensitive only where noted; the pipeline runs them in a
/// fixed order. The pass is whitespace-preserving where practical but optimizes for compilability,
/// not formatting — the s&amp;box editor reformats on save.
/// </summary>
public static class SboxSourceCleaner
{
	public sealed class Stats
	{
		public int AssemblyAttrs, SourceLocations, OpImplicit, RefCasts, NullCoalesce,
			BackingFields, GeneratedFields, AccessorCalls, ObjectInits, BaseCalls;
		public override string ToString() =>
			$"asmAttrs={AssemblyAttrs} sourceLoc={SourceLocations} opImplicit={OpImplicit} " +
			$"refCasts={RefCasts} nullCoalesce={NullCoalesce} backingFields={BackingFields} " +
			$"genFields={GeneratedFields} accessorCalls={AccessorCalls} objectInits={ObjectInits} baseCalls={BaseCalls}";
	}

	public static string Clean( string code, out Stats stats )
	{
		stats = new Stats();
		code = StripAssemblyAndModuleAttributes( code, stats );
		code = StripSourceLocation( code, stats );
		code = ConvertOpImplicit( code, stats );
		code = StripNullCoalescePlaceholders( code, stats );
		code = StripRefCasts( code, stats );
		code = RenameBackingFields( code, stats );
		code = StripGeneratedMembers( code, stats );
		code = ConvertAccessorCalls( code, stats );
		code = FoldObjectInitializers( code, stats );
		code = ConvertBaseCalls( code, stats );
		code = StripGeneratedInterfaces( code, stats );
		code = StripRedundantDefaultValue( code, stats );
		code = FixCompoundRefAssign( code, stats );
		code = FixExplicitInterfaceProps( code, stats );
		code = FixRedundantBoolCoalesce( code, stats );
		return code;
	}

	// ───────────────────────── IL-baked codegen strips ─────────────────────────

	static string StripAssemblyAndModuleAttributes( string code, Stats s )
	{
		var sb = new StringBuilder( code.Length );
		foreach ( var line in SplitLines( code ) )
		{
			var t = line.TrimStart();
			if ( t.StartsWith( "[assembly:" ) || t.StartsWith( "[module:" ) ) { s.AssemblyAttrs++; continue; }
			sb.Append( line ).Append( '\n' );
		}
		return sb.ToString();
	}

	static readonly Regex SourceLocLine = new( @"^\s*\[SourceLocation\([^\]]*\)\]\s*$", RegexOptions.Compiled );
	static readonly Regex SourceLocInline = new( @"\[SourceLocation\([^\]]*\)\]\s*", RegexOptions.Compiled );

	static string StripSourceLocation( string code, Stats s )
	{
		var sb = new StringBuilder( code.Length );
		foreach ( var line in SplitLines( code ) )
		{
			if ( SourceLocLine.IsMatch( line ) ) { s.SourceLocations++; continue; }
			sb.Append( line ).Append( '\n' );
		}
		var outp = SourceLocInline.Replace( sb.ToString(), m => { s.SourceLocations++; return ""; } );
		return outp;
	}

	static readonly Regex BackingField = new( @"<([A-Za-z_][A-Za-z0-9_]*)>k__BackingField", RegexOptions.Compiled );

	static string RenameBackingFields( string code, Stats s ) =>
		BackingField.Replace( code, m => { s.BackingFields++; return "__bf_" + m.Groups[1].Value; } );

	// [SkipHotload]-decorated generator fields: cached delegates + the __X__Attrs Attribute[] arrays.
	static readonly Regex CachedField = new(
		@"^\s*(private|internal|protected|public)\s.*\b__\w+_\w*Attribute__Cached\w*\s*(=\s*[^;]*)?;\s*$",
		RegexOptions.Compiled );
	static readonly Regex AttrsArrayStart = new(
		@"^\s*(private|internal|protected|public)\s+static\s+readonly\s+(?:[\w]+\.)*Attribute\[\]\s+__\w+__Attrs\s*=",
		RegexOptions.Compiled );

	static string StripGeneratedMembers( string code, Stats s )
	{
		var lines = SplitLines( code );
		var outl = new List<string>( lines.Count );
		void PopSkipHotload()
		{
			while ( outl.Count > 0 && outl[^1].Trim().Length == 0 ) outl.RemoveAt( outl.Count - 1 );
			if ( outl.Count > 0 && outl[^1].Trim() == "[SkipHotload]" ) outl.RemoveAt( outl.Count - 1 );
		}
		for ( int i = 0; i < lines.Count; i++ )
		{
			var ln = lines[i];
			if ( CachedField.IsMatch( ln ) ) { PopSkipHotload(); s.GeneratedFields++; continue; }
			if ( AttrsArrayStart.IsMatch( ln ) )
			{
				PopSkipHotload(); s.GeneratedFields++;
				bool sawBrace = false;
				while ( i < lines.Count )
				{
					var cur = lines[i];
					if ( cur.Contains( '{' ) ) sawBrace = true;
					i++;
					if ( sawBrace && Regex.IsMatch( cur, @"\}\s*;\s*$" ) ) break;
					if ( !sawBrace && Regex.IsMatch( cur, @";\s*$" ) ) break; // single-line form
				}
				i--; // for-loop will ++
				continue;
			}
			outl.Add( ln );
		}
		return string.Join( "\n", outl ) + "\n";
	}

	// ───────────────────────── low-fidelity decompile fixups ─────────────────────────

	static readonly Regex OpImplicitCall = new( @"([A-Za-z_][A-Za-z0-9_.]*)\.op_Implicit\(", RegexOptions.Compiled );

	static string ConvertOpImplicit( string code, Stats s )
	{
		var sb = new StringBuilder( code.Length );
		int i = 0;
		while ( true )
		{
			var m = OpImplicitCall.Match( code, i );
			if ( !m.Success ) { sb.Append( code, i, code.Length - i ); break; }
			sb.Append( code, i, m.Index - i );
			var type = m.Groups[1].Value;
			int open = m.Index + m.Length - 1; // the '('
			int close = MatchParen( code, open );
			if ( close < 0 ) { sb.Append( code, m.Index, m.Length ); i = m.Index + m.Length; continue; }
			var arg = code.Substring( open + 1, close - open - 1 );
			sb.Append( '(' ).Append( type ).Append( ")(" ).Append( arg ).Append( ')' );
			s.OpImplicit++;
			i = close + 1;
		}
		return sb.ToString();
	}

	// ILSpy emits "(??)" where it failed to reconstruct a null-coalescing operand; removing the bogus
	// cast leaves a valid "(operand) ?? fallback".
	static string StripNullCoalescePlaceholders( string code, Stats s )
	{
		int n = 0; var outp = code.Replace( "(??)", "" ); for ( int k = code.IndexOf( "(??)" ); k >= 0; k = code.IndexOf( "(??)", k + 1 ) ) n++;
		s.NullCoalesce += n; return outp;
	}

	// (Type)(ref x)  /  ((Type)(ref x.y))  constrained-call casts → drop the ref+parens, keep the value.
	// Skip genuine ref-argument lists: a '(' that follows an identifier / '>' / ']' (a callable).
	static readonly Regex RefCastCtx = new( @"\)\(ref ([\w.]+(?:\[[^\]]*\])?[\w.]*)\)", RegexOptions.Compiled );
	static readonly Regex RefExprCtx = new( @"(?<![\w>\])])\(ref ([\w.]+(?:\[[^\]]*\])?[\w.]*)\)", RegexOptions.Compiled );

	static string StripRefCasts( string code, Stats s )
	{
		code = RefCastCtx.Replace( code, m => { s.RefCasts++; return ")" + m.Groups[1].Value; } );
		code = RefExprCtx.Replace( code, m => { s.RefCasts++; return m.Groups[1].Value; } );
		return code;
	}

	// obj.set_Prop(value) → obj.Prop = value   ;   obj.get_Prop() → obj.Prop
	static readonly Regex SetAccessor = new( @"\.set_([A-Za-z_]\w*)\(", RegexOptions.Compiled );
	static readonly Regex GetAccessor = new( @"\.get_([A-Za-z_]\w*)\(\)", RegexOptions.Compiled );

	static string ConvertAccessorCalls( string code, Stats s )
	{
		var sb = new StringBuilder( code.Length );
		int i = 0;
		while ( true )
		{
			var m = SetAccessor.Match( code, i );
			if ( !m.Success ) { sb.Append( code, i, code.Length - i ); break; }
			var name = m.Groups[1].Value;
			int open = m.Index + m.Length - 1;
			int close = MatchParen( code, open );
			if ( close < 0 || name == "Item" ) { sb.Append( code, i, m.Index + m.Length - i ); i = m.Index + m.Length; continue; }
			var inner = code.Substring( open + 1, close - open - 1 );
			if ( HasTopLevelComma( inner ) ) { sb.Append( code, i, m.Index + m.Length - i ); i = m.Index + m.Length; continue; }
			sb.Append( code, i, m.Index - i );
			sb.Append( '.' ).Append( name ).Append( " = " ).Append( inner );
			s.AccessorCalls++;
			i = close + 1;
		}
		code = sb.ToString();
		code = GetAccessor.Replace( code, m => { s.AccessorCalls++; return "." + m.Groups[1].Value; } );
		return code;
	}

	// T v = default(T);  v.A = ..; ((T)v).B = ..;  →  T v = new T { A = .., B = .. };
	static readonly Regex DefaultDecl = new(
		@"^(\s*)(\S.*?)\s+([A-Za-z_]\w*)\s*=\s*default(?:\([^;]*\))?;\s*$", RegexOptions.Compiled );

	static string FoldObjectInitializers( string code, Stats s )
	{
		var lines = SplitLines( code );
		var outl = new List<string>( lines.Count );
		for ( int i = 0; i < lines.Count; i++ )
		{
			var dm = DefaultDecl.Match( lines[i] );
			if ( !dm.Success ) { outl.Add( lines[i] ); continue; }
			string indent = dm.Groups[1].Value, type = dm.Groups[2].Value.Trim(), var = dm.Groups[3].Value;
			var ev = Regex.Escape( var );
			var propStart = new Regex( @"^\s*(?:\(\([^()]*\)" + ev + @"\)|" + ev + @")\.([A-Za-z_]\w*)\s*=\s*(.*)$" );
			var assigns = new List<(string prop, string val)>();
			int j = i + 1;
			while ( j < lines.Count )
			{
				var pm = propStart.Match( lines[j] );
				if ( !pm.Success ) break;
				string prop = pm.Groups[1].Value, stmt = pm.Groups[2].Value; int k = j;
				while ( Balance( stmt ) != 0 || !stmt.TrimEnd().EndsWith( ";" ) )
				{
					k++; if ( k >= lines.Count ) break;
					stmt += "\n" + lines[k];
				}
				var val = stmt.TrimEnd();
				if ( val.EndsWith( ";" ) ) val = val[..^1].TrimEnd();
				assigns.Add( (prop, val) );
				j = k + 1;
			}
			if ( assigns.Count < 2 ) { outl.Add( lines[i] ); continue; }
			outl.Add( $"{indent}{type} {var} = new {type}" );
			outl.Add( $"{indent}{{" );
			for ( int a = 0; a < assigns.Count; a++ )
			{
				var comma = a < assigns.Count - 1 ? "," : "";
				var vl = assigns[a].val.Split( '\n' );
				outl.Add( $"{indent}\t{assigns[a].prop} = {vl[0]}" + (vl.Length > 1 ? "" : comma) );
				for ( int vi = 1; vi < vl.Length; vi++ )
					outl.Add( vl[vi] + (vi == vl.Length - 1 ? comma : "") );
			}
			outl.Add( $"{indent}}};" );
			s.ObjectInits++;
			i = j - 1;
		}
		return string.Join( "\n", outl ) + "\n";
	}

	// ((Base)this).OnStart() etc. — ILSpy renders base virtual calls as a cast qualifier, which fails
	// for protected members. Convert the known protected Component/Panel hooks to base. calls.
	static readonly Regex BaseCall = new(
		@"\(\([\w.]+\)this\)\.(__rpc_Wrapper|Task|DrawGizmos|Listen|On[A-Z]\w*)\b", RegexOptions.Compiled );

	static string ConvertBaseCalls( string code, Stats s ) =>
		BaseCall.Replace( code, m => { s.BaseCalls++; return "base." + m.Groups[1].Value; } );

	// The s&box generator appends the lifecycle subscriber interfaces (IUpdateSubscriber etc.) to any
	// component that overrides the matching hook (OnUpdate/OnFixedUpdate/OnPreRender/...). The compiled
	// IL carries them explicitly, so the generator's copy collides → CS0528 "already listed in interface
	// list". A component always declares its base class first, so each managed interface is preceded by
	// a comma in the base list — strip "(, )Sandbox.Internal.IXxxSubscriber".
	static readonly Regex GeneratedInterface = new(
		@",\s*(?:Sandbox\.Internal\.|Sandbox\.)?(IUpdateSubscriber|IFixedUpdateSubscriber|IPreRenderSubscriber|ILateUpdateSubscriber)\b",
		RegexOptions.Compiled );

	static string StripGeneratedInterfaces( string code, Stats s )
	{
		var sb = new StringBuilder( code.Length );
		foreach ( var line in SplitLines( code ) )
		{
			// only touch type-declaration lines that carry a base list
			if ( Regex.IsMatch( line, @"^\s*(public|internal|private|protected|sealed|abstract|partial|static|\s)*\b(class|struct|record)\b" )
				&& line.Contains( ':' ) && GeneratedInterface.IsMatch( line ) )
			{
				var fixedLine = GeneratedInterface.Replace( line, _ => { s.BaseCalls++; return ""; } );
				sb.Append( fixedLine ).Append( '\n' );
			}
			else sb.Append( line ).Append( '\n' );
		}
		return sb.ToString();
	}

	// [DefaultValue(x)] on a [Property] member is re-emitted by the generator from the member's
	// initializer, so the IL-baked copy collides → CS0579 "Duplicate DefaultValueAttribute". The
	// decompiler always preserves the `= x` initializer too, so dropping the attribute is loss-free
	// (and matches the s&box editor's own "just set the default value" guidance).
	static readonly Regex DefaultValueAttr = new( @"^\s*\[DefaultValue\([^\]]*\)\]\s*$", RegexOptions.Compiled );

	static string StripRedundantDefaultValue( string code, Stats s )
	{
		var sb = new StringBuilder( code.Length );
		foreach ( var line in SplitLines( code ) )
		{
			if ( DefaultValueAttr.IsMatch( line ) ) { s.GeneratedFields++; continue; }
			sb.Append( line ).Append( '\n' );
		}
		return sb.ToString();
	}

	// ILSpy renders a compound assignment through a ref-returning member as "x /= ref y" — illegal.
	// The ref is meaningless in this position; drop it. (Plain "T x = ref y" ref-locals are untouched
	// because only compound operators are matched.)
	static readonly Regex CompoundRef = new( @"([-+*/%&|^]=)\s+ref\s+", RegexOptions.Compiled );

	static string FixCompoundRefAssign( string code, Stats s ) =>
		CompoundRef.Replace( code, m => { s.RefCasts++; return m.Groups[1].Value + " "; } );

	// Explicit-interface read-only properties come back as "Type IFace.Name { return expr; }" with the
	// get accessor elided → CS0548/CS0551. Restore it as an expression body "Type IFace.Name => expr;".
	static readonly Regex ExplicitIfaceProp = new(
		@"(^[ \t]*[A-Za-z_][\w.<>?\[\],]*[ \t]+[A-Za-z_][\w]*\.[A-Za-z_]\w*)[ \t]*\r?\n[ \t]*\{[ \t]*\r?\n[ \t]*return[ \t]+(.+?);[ \t]*\r?\n[ \t]*\}",
		RegexOptions.Compiled | RegexOptions.Multiline );

	static string FixExplicitInterfaceProps( string code, Stats s ) =>
		ExplicitIfaceProp.Replace( code, m => { s.AccessorCalls++; return $"{m.Groups[1].Value} => {m.Groups[2].Value};"; } );

	// ILSpy sometimes emits "(x?.Flag == true) ?? false" — but "nullable == true" already yields a
	// non-nullable bool (null → false), so the trailing "?? false/true" is both dead and illegal
	// (CS0019 "?? on bool and bool"). Drop it; the "== bool" comparison preserves the intended logic.
	static readonly Regex RedundantBoolCoalesce = new( @"(==\s*(?:true|false)\))\s*\?\?\s*(?:true|false)\b", RegexOptions.Compiled );

	static string FixRedundantBoolCoalesce( string code, Stats s ) =>
		RedundantBoolCoalesce.Replace( code, m => { s.NullCoalesce++; return m.Groups[1].Value; } );

	// ───────────────────────── helpers ─────────────────────────

	static List<string> SplitLines( string code ) => new( code.Replace( "\r\n", "\n" ).Split( '\n' ) );

	static int MatchParen( string s, int open )
	{
		int depth = 0;
		for ( int k = open; k < s.Length; k++ )
		{
			char c = s[k];
			if ( c is '(' or '[' or '{' ) depth++;
			else if ( c is ')' or ']' or '}' ) { depth--; if ( depth == 0 ) return k; }
		}
		return -1;
	}

	static bool HasTopLevelComma( string s )
	{
		int d = 0;
		foreach ( var c in s )
		{
			if ( c is '(' or '[' or '{' ) d++;
			else if ( c is ')' or ']' or '}' ) d--;
			else if ( c == ',' && d == 0 ) return true;
		}
		return false;
	}

	static int Balance( string s )
	{
		int d = 0;
		foreach ( var c in s )
		{
			if ( c is '(' or '[' or '{' ) d++;
			else if ( c is ')' or ']' or '}' ) d--;
		}
		return d;
	}
}
