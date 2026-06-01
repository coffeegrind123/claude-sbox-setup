using System.Text.Json;
using Microsoft.Playwright;

namespace ClaudeSbox.CodeSearch.Driver;

/// <summary>
/// Out-of-Roslyn, in-process codesearch driver. Compiled by normal <c>dotnet publish</c>
/// (NOT by s&amp;box's addon compiler — it lives in the addon's <c>Driver/</c> sibling of
/// <c>Code/</c>, which s&amp;box never compiles), then dropped into the addon's
/// <c>Libraries/codesearch-driver/</c>. The s&amp;box addon loads this DLL at runtime via
/// <c>Assembly.LoadFrom</c> and calls the single <see cref="RunAsync"/> entrypoint through
/// reflection — so the addon never needs a compile-time <c>Microsoft.Playwright</c> reference
/// (which s&amp;box's compiler can't resolve), yet everything still runs in ONE process.
///
/// Only this DLL + <c>Microsoft.Playwright.dll</c> load into the editor's ALC; the node
/// driver and Chromium are spawned by Playwright as CHILD PROCESSES, so the heavy/native
/// surface stays out of the editor.
///
/// Boundary contract — string JSON in, string JSON out (framework <c>Task&lt;string&gt;</c> is
/// shared across the load boundary, so the caller can cast + await directly):
///   in:  { "op": "search|get_file|list_files|status|restart", "timeoutMs": 30000, ...args }
///   out: op-specific object, always with an "ok" bool; on failure { ok:false, error, message }.
///
/// sbox.game is Blazor Server — results stream over a SignalR circuit and are NOT in the raw
/// HTML, so we load the deep-link URL, wait for the server-pushed DOM (never network-idle —
/// the circuit never idles), then scrape. Surface reverse-engineered live 2026-06-01.
/// </summary>
public static class Entry
{
	const string SiteBase = "https://sbox.game";

	static readonly SemaphoreSlim _launchGate = new( 1, 1 );
	static IPlaywright _pw;
	static IBrowser _browser;
	static string _lastError;
	static bool _chromiumInstalled;
	static DateTime _launchedAtUtc;

	/// <summary>The single reflection entrypoint. See class remarks for the JSON contract.</summary>
	public static async Task<string> RunAsync( string opJson )
	{
		try
		{
			using var doc = JsonDocument.Parse( opJson ?? "{}" );
			var root = doc.RootElement;
			var op = Str( root, "op" ) ?? "";
			int timeoutMs = root.TryGetProperty( "timeoutMs", out var tm ) && tm.TryGetInt32( out var t ) ? t : 30_000;
			using var cts = new CancellationTokenSource( timeoutMs + 5_000 );
			var ct = cts.Token;

			return op switch
			{
				"search" => await DoSearch( root, ct ).ConfigureAwait( false ),
				"get_file" => await DoGetFile( root, ct ).ConfigureAwait( false ),
				"list_files" => await DoListFiles( root, ct ).ConfigureAwait( false ),
				"status" => DoStatus(),
				"restart" => await DoRestart().ConfigureAwait( false ),
				_ => Err( "bad_op", $"unknown op '{op}'" ),
			};
		}
		catch ( PlaywrightException e ) when ( IsTimeout( e ) ) { return Err( "timeout", e.Message ); }
		catch ( PlaywrightException e ) when ( IsBrowserMissing( e ) ) { return Err( "browser_unavailable", e.Message ); }
		catch ( PlaywrightException e ) { return Err( "browser_error", e.Message ); }
		catch ( Exception e ) { return Err( "driver_error", $"{e.GetType().Name}: {e.Message}" ); }
	}

	// ───────────────────────── ops ─────────────────────────

	static async Task<string> DoSearch( JsonElement root, CancellationToken ct )
	{
		var query = Str( root, "q" ) ?? "";
		var type = Str( root, "type" );
		var year = Str( root, "year" );
		int limit = root.TryGetProperty( "limit", out var l ) && l.TryGetInt32( out var li ) ? Math.Clamp( li, 1, 100 ) : 20;

		await EnsureBrowser( ct ).ConfigureAwait( false );
		var url = BuildSearchUrl( query, type, year );
		await using var ctx = await _browser.NewContextAsync().ConfigureAwait( false );
		var page = await ctx.NewPageAsync().ConfigureAwait( false );
		await GotoAndAwait( page, url, "div.code-result", allowEmpty: true, ct ).ConfigureAwait( false );
		var scraped = await page.EvaluateAsync<string>( ScrapeSearchJs, limit ).ConfigureAwait( false );

		// Re-emit with an ok flag wrapped around the scraper's {total,hits} shape.
		using var s = JsonDocument.Parse( string.IsNullOrEmpty( scraped ) ? "{\"total\":0,\"hits\":[]}" : scraped );
		return Ok( w =>
		{
			var r = s.RootElement;
			w.WriteNumber( "total", r.TryGetProperty( "total", out var tt ) && tt.ValueKind == JsonValueKind.Number ? tt.GetInt32() : 0 );
			w.WritePropertyName( "hits" );
			if ( r.TryGetProperty( "hits", out var hits ) ) hits.WriteTo( w ); else { w.WriteStartArray(); w.WriteEndArray(); }
		} );
	}

	static async Task<string> DoGetFile( JsonElement root, CancellationToken ct )
	{
		var org = Str( root, "org" ); var package = Str( root, "package" ); var file = Str( root, "file" );
		await EnsureBrowser( ct ).ConfigureAwait( false );
		var url = $"{SiteBase}/{Esc( org )}/{Esc( package )}/source?file={Uri.EscapeDataString( file ?? "" )}";
		await using var ctx = await _browser.NewContextAsync().ConfigureAwait( false );
		var page = await ctx.NewPageAsync().ConfigureAwait( false );
		await GotoAndAwait( page, url, "pre", allowEmpty: false, ct ).ConfigureAwait( false );
		var scraped = await page.EvaluateAsync<string>( ScrapeFileJs ).ConfigureAwait( false );

		using var s = JsonDocument.Parse( string.IsNullOrEmpty( scraped ) ? "{}" : scraped );
		var src = Str( s.RootElement, "source" ) ?? "";
		var lang = Str( s.RootElement, "language" ) ?? "";
		return Ok( w => { w.WriteString( "source", src ); w.WriteString( "language", lang ); } );
	}

	static async Task<string> DoListFiles( JsonElement root, CancellationToken ct )
	{
		var org = Str( root, "org" ); var package = Str( root, "package" );
		await EnsureBrowser( ct ).ConfigureAwait( false );
		var url = $"{SiteBase}/{Esc( org )}/{Esc( package )}/source";
		await using var ctx = await _browser.NewContextAsync().ConfigureAwait( false );
		var page = await ctx.NewPageAsync().ConfigureAwait( false );
		await GotoAndAwait( page, url, "a[href*=\"source?file=\"]", allowEmpty: false, ct ).ConfigureAwait( false );
		var scraped = await page.EvaluateAsync<string>( ScrapeFileTreeJs ).ConfigureAwait( false );

		using var s = JsonDocument.Parse( string.IsNullOrEmpty( scraped ) ? "[]" : scraped );
		return Ok( w => { w.WritePropertyName( "files" ); s.RootElement.WriteTo( w ); } );
	}

	static string DoStatus() => Ok( w =>
	{
		w.WriteBoolean( "browser_launched", _browser is { IsConnected: true } );
		w.WriteBoolean( "chromium_installed", _chromiumInstalled );
		w.WriteString( "launched_at_utc", _launchedAtUtc == default ? null : _launchedAtUtc.ToString( "o" ) );
		w.WriteString( "last_error", _lastError );
	} );

	static async Task<string> DoRestart()
	{
		await Shutdown().ConfigureAwait( false );
		_lastError = null;
		return Ok( w => w.WriteBoolean( "restarted", true ) );
	}

	// ───────────────────────── browser lifecycle ─────────────────────────

	static async Task EnsureBrowser( CancellationToken ct )
	{
		if ( _browser is { IsConnected: true } ) return;
		await _launchGate.WaitAsync( ct ).ConfigureAwait( false );
		try
		{
			if ( _browser is { IsConnected: true } ) return;
			if ( _browser != null ) { try { await _browser.CloseAsync().ConfigureAwait( false ); } catch { } _browser = null; }
			if ( _pw != null ) { try { _pw.Dispose(); } catch { } _pw = null; }

			EnsureChromiumInstalled();
			_pw = await Playwright.CreateAsync().ConfigureAwait( false );
			_browser = await _pw.Chromium.LaunchAsync( new BrowserTypeLaunchOptions
			{
				Headless = true,
				Args = new[] { "--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu" },
			} ).ConfigureAwait( false );
			_launchedAtUtc = DateTime.UtcNow;
			_lastError = null;
		}
		catch ( Exception e ) { _lastError = $"{e.GetType().Name}: {e.Message}"; throw; }
		finally { _launchGate.Release(); }
	}

	static void EnsureChromiumInstalled()
	{
		if ( _chromiumInstalled ) return;
		try { _chromiumInstalled = Program.Main( new[] { "install", "chromium" } ) == 0; } catch { }
	}

	static async Task Shutdown()
	{
		await _launchGate.WaitAsync().ConfigureAwait( false );
		try
		{
			try { if ( _browser != null ) await _browser.CloseAsync().ConfigureAwait( false ); } catch { }
			try { _pw?.Dispose(); } catch { }
			_browser = null; _pw = null; _launchedAtUtc = default;
		}
		finally { _launchGate.Release(); }
	}

	static async Task GotoAndAwait( IPage page, string url, string readySelector, bool allowEmpty, CancellationToken ct )
	{
		await page.GotoAsync( url, new PageGotoOptions { WaitUntil = WaitUntilState.DOMContentLoaded, Timeout = 30_000 } ).ConfigureAwait( false );
		try
		{
			await page.WaitForSelectorAsync( readySelector,
				new PageWaitForSelectorOptions { Timeout = 20_000, State = WaitForSelectorState.Attached } ).ConfigureAwait( false );
		}
		catch ( PlaywrightException e ) when ( IsTimeout( e ) )
		{
			var err = await TryReadBlazorError( page ).ConfigureAwait( false );
			if ( !string.IsNullOrEmpty( err ) ) throw new InvalidOperationException( $"Blazor circuit error: {err}" );
			if ( !allowEmpty ) throw;
		}
	}

	static async Task<string> TryReadBlazorError( IPage page )
	{
		try
		{
			var el = await page.QuerySelectorAsync( "#blazor-error-ui" ).ConfigureAwait( false );
			if ( el == null || !await el.IsVisibleAsync().ConfigureAwait( false ) ) return null;
			return (await el.InnerTextAsync().ConfigureAwait( false ))?.Trim();
		}
		catch { return null; }
	}

	// ───────────────────────── helpers ─────────────────────────

	// Playwright .NET (1.49) has no public TimeoutException type — timeouts arrive as a
	// PlaywrightException whose message starts with "Timeout … exceeded". Classify by message.
	static bool IsTimeout( PlaywrightException e )
		=> (e.Message ?? "").Contains( "Timeout", StringComparison.OrdinalIgnoreCase );

	static bool IsBrowserMissing( PlaywrightException e )
	{
		var m = e.Message ?? "";
		return m.Contains( "doesn't exist", StringComparison.OrdinalIgnoreCase )
			|| m.Contains( "Executable", StringComparison.OrdinalIgnoreCase )
			|| m.Contains( "playwright install", StringComparison.OrdinalIgnoreCase );
	}

	static string BuildSearchUrl( string query, string type, string year )
	{
		var sb = new System.Text.StringBuilder( $"{SiteBase}/codesearch?q={Uri.EscapeDataString( query ?? "" )}" );
		if ( !string.IsNullOrWhiteSpace( type ) ) sb.Append( "&type=" ).Append( Uri.EscapeDataString( type.Trim().ToLowerInvariant() ) );
		if ( !string.IsNullOrWhiteSpace( year ) ) sb.Append( "&year=" ).Append( Uri.EscapeDataString( year.Trim() ) );
		return sb.ToString();
	}

	static string Esc( string s ) => Uri.EscapeDataString( s ?? "" );
	static string Str( JsonElement e, string n ) => e.TryGetProperty( n, out var v ) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

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

	// ───────────────────────── in-page scrapers ─────────────────────────

	const string ScrapeSearchJs = @"
(limit) => {
  const out = { total: 0, hits: [] };
  const m = (document.body.innerText || '').match(/([\d,]+)\s+RESULTS/i);
  if (m) out.total = parseInt(m[1].replace(/,/g, ''), 10) || 0;
  const items = document.querySelectorAll('div.code-result');
  for (const it of items) {
    if (out.hits.length >= limit) break;
    const link = it.querySelector('a[href*=""source?file=""]');
    const href = link ? link.getAttribute('href') : null;
    let pkg = null, file = null;
    if (href) {
      const u = new URL(href, location.origin);
      const parts = u.pathname.split('/').filter(Boolean);
      if (parts.length >= 2) pkg = parts[0] + '.' + parts[1];
      const f = u.searchParams.get('file');
      if (f) file = f;
    }
    // Type badge text is lowercase in the DOM with CSS text-transform:uppercase, so read
    // innerText (honors the transform → 'GAME') and match case-SENSITIVE uppercase. That
    // both catches the badge AND excludes the lowercase 'code' material-icon ligature.
    let kind = null;
    const badge = [...it.querySelectorAll('*')].find(e =>
      e.children.length === 0 && /^(LIBRARY|GAME|EDITOR|CODE|UNIT TEST|UNITTEST)$/.test((e.innerText || '').trim()));
    if (badge) kind = badge.innerText.trim();
    let startLine = 0, snippet = '';
    const pre = it.querySelector('pre, code, [class*=""hljs""]');
    if (pre) { snippet = pre.innerText || ''; }
    else {
      const txt = (it.innerText || '').split('\n');
      const idx = txt.findIndex(l => /^\d+$/.test(l.trim()));
      if (idx >= 0) { snippet = txt.slice(idx).join('\n'); }
      else snippet = it.innerText || '';
    }
    // First leading line-number token in the snippet = the match's start line (works for both branches).
    const lm = snippet.match(/(?:^|\n)\s*(\d+)\s*\n/);
    if (lm) startLine = parseInt(lm[1], 10) || 0;
    out.hits.push({ package: pkg, file: file, kind: kind, url: href, startLine: startLine, snippet: snippet });
  }
  return JSON.stringify(out);
}";

	const string ScrapeFileJs = @"
() => {
  const pre = document.querySelector('pre');
  let source = pre ? (pre.innerText || '') : '';
  let language = '';
  const hl = document.querySelector('pre code[class*=""language-""], pre [class*=""language-""]');
  if (hl) {
    const cls = [...hl.classList].find(c => c.startsWith('language-'));
    if (cls) language = cls.slice('language-'.length);
  }
  return JSON.stringify({ source: source, language: language });
}";

	const string ScrapeFileTreeJs = @"
() => {
  const set = new Set();
  for (const a of document.querySelectorAll('a[href*=""source?file=""]')) {
    try {
      const u = new URL(a.getAttribute('href'), location.origin);
      const f = u.searchParams.get('file');
      if (f) set.add(f);
    } catch (e) {}
  }
  return JSON.stringify([...set].sort());
}";
}
