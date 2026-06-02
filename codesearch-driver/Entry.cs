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
/// Although named "CodeSearch", this is the shared sbox.game Blazor-scrape driver: the same
/// headless Chromium also serves the forum (<c>/f</c>) and release-notes (<c>/release-notes</c>)
/// ops, since all three live in one Blazor Server app with the same SignalR-circuit constraint.
///
/// Boundary contract — string JSON in, string JSON out (framework <c>Task&lt;string&gt;</c> is
/// shared across the load boundary, so the caller can cast + await directly):
///   in:  { "op": "search|get_file|list_files|forum_index|forum_category|forum_thread|forum_search|release_notes|status|restart", "timeoutMs": 30000, ...args }
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
				// Forum + release-notes ops — same Blazor-scrape infrastructure as codesearch
				// (sbox.game is one Blazor Server app), so they share this driver + Chromium.
				"forum_index" => await DoForumIndex( root, ct ).ConfigureAwait( false ),
				"forum_category" => await DoForumCategory( root, ct ).ConfigureAwait( false ),
				"forum_thread" => await DoForumThread( root, ct ).ConfigureAwait( false ),
				"forum_search" => await DoForumSearch( root, ct ).ConfigureAwait( false ),
				"release_notes" => await DoReleaseNotes( root, ct ).ConfigureAwait( false ),
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

	// ───────────────────────── forum + release-notes ops ─────────────────────────

	// All five reuse the same load-deeplink → wait-for-selector → in-page-scraper → JSON pattern
	// as codesearch. The scrapers return a JSON document we re-emit verbatim under the ok wrapper.

	static async Task<string> DoForumIndex( JsonElement root, CancellationToken ct )
	{
		await EnsureBrowser( ct ).ConfigureAwait( false );
		var url = $"{SiteBase}/f";
		await using var c = await _browser.NewContextAsync().ConfigureAwait( false );
		var page = await c.NewPageAsync().ConfigureAwait( false );
		await GotoAndAwait( page, url, "div.forum", allowEmpty: false, ct ).ConfigureAwait( false );
		var scraped = await page.EvaluateAsync<string>( ScrapeForumIndexJs ).ConfigureAwait( false );
		return WrapScraped( scraped, "{\"categories\":[]}", "categories" );
	}

	static async Task<string> DoForumCategory( JsonElement root, CancellationToken ct )
	{
		var slug = Str( root, "category" );
		if ( string.IsNullOrWhiteSpace( slug ) ) return Err( "bad_request", "forum_category requires 'category' slug" );
		await EnsureBrowser( ct ).ConfigureAwait( false );
		var url = $"{SiteBase}/f/{Esc( slug )}/";
		await using var c = await _browser.NewContextAsync().ConfigureAwait( false );
		var page = await c.NewPageAsync().ConfigureAwait( false );
		await GotoAndAwait( page, url, "a.thread-row", allowEmpty: true, ct ).ConfigureAwait( false );
		var scraped = await page.EvaluateAsync<string>( ScrapeForumCategoryJs ).ConfigureAwait( false );
		return WrapScraped( scraped, "{\"category\":null,\"threads\":[]}", null );
	}

	static async Task<string> DoForumThread( JsonElement root, CancellationToken ct )
	{
		// Accept either a full path (/f/<cat>/<id>/<page>/) or category+thread_id+page.
		var path = Str( root, "path" );
		string url;
		if ( !string.IsNullOrWhiteSpace( path ) )
		{
			if ( path.StartsWith( "http", StringComparison.OrdinalIgnoreCase ) ) url = path;
			else url = SiteBase + (path.StartsWith( "/" ) ? path : "/" + path);
		}
		else
		{
			var cat = Str( root, "category" );
			var id = Str( root, "thread_id" );
			if ( string.IsNullOrWhiteSpace( cat ) || string.IsNullOrWhiteSpace( id ) )
				return Err( "bad_request", "forum_thread requires 'path' OR ('category' + 'thread_id')" );
			int pageNum = root.TryGetProperty( "page", out var pg ) && pg.TryGetInt32( out var pi ) ? Math.Max( 1, pi ) : 1;
			url = $"{SiteBase}/f/{Esc( cat )}/{Esc( id )}/{pageNum}/";
		}
		await EnsureBrowser( ct ).ConfigureAwait( false );
		await using var c = await _browser.NewContextAsync().ConfigureAwait( false );
		var page = await c.NewPageAsync().ConfigureAwait( false );
		await GotoAndAwait( page, url, "div.thread-post", allowEmpty: false, ct ).ConfigureAwait( false );
		var scraped = await page.EvaluateAsync<string>( ScrapeForumThreadJs ).ConfigureAwait( false );
		return WrapScraped( scraped, "{\"thread\":null,\"posts\":[]}", null );
	}

	static async Task<string> DoForumSearch( JsonElement root, CancellationToken ct )
	{
		var q = Str( root, "q" );
		if ( string.IsNullOrWhiteSpace( q ) ) return Err( "bad_request", "forum_search requires 'q'" );
		await EnsureBrowser( ct ).ConfigureAwait( false );
		// The forum search route is /f/🔎/?search=<q> — 🔎 is the literal magnifier emoji
		// (U+1F50E), percent-encoded as %F0%9F%94%8E. Discovered by driving the search box live.
		var url = $"{SiteBase}/f/%F0%9F%94%8E/?search={Uri.EscapeDataString( q )}";
		await using var c = await _browser.NewContextAsync().ConfigureAwait( false );
		var page = await c.NewPageAsync().ConfigureAwait( false );
		await GotoAndAwait( page, url, "div.result", allowEmpty: true, ct ).ConfigureAwait( false );
		var scraped = await page.EvaluateAsync<string>( ScrapeForumSearchJs ).ConfigureAwait( false );
		return WrapScraped( scraped, "{\"total\":0,\"results\":[]}", null );
	}

	static async Task<string> DoReleaseNotes( JsonElement root, CancellationToken ct )
	{
		int limit = root.TryGetProperty( "limit", out var l ) && l.TryGetInt32( out var li ) ? Math.Clamp( li, 1, 100 ) : 10;
		await EnsureBrowser( ct ).ConfigureAwait( false );
		var url = $"{SiteBase}/release-notes";
		await using var c = await _browser.NewContextAsync().ConfigureAwait( false );
		var page = await c.NewPageAsync().ConfigureAwait( false );
		await GotoAndAwait( page, url, "div.changelistgroup", allowEmpty: false, ct ).ConfigureAwait( false );
		var scraped = await page.EvaluateAsync<string>( ScrapeReleaseNotesJs, limit ).ConfigureAwait( false );
		return WrapScraped( scraped, "{\"versions\":[]}", null );
	}

	/// <summary>Parse a scraper's JSON document and re-emit it under the ok wrapper. If
	/// <paramref name="singleArrayProp"/> is set, only that property is forwarded (as an array);
	/// otherwise every top-level property of the scraped object is copied through.</summary>
	static string WrapScraped( string scraped, string fallback, string singleArrayProp )
	{
		using var s = JsonDocument.Parse( string.IsNullOrEmpty( scraped ) ? fallback : scraped );
		return Ok( w =>
		{
			var r = s.RootElement;
			if ( singleArrayProp != null )
			{
				w.WritePropertyName( singleArrayProp );
				if ( r.TryGetProperty( singleArrayProp, out var arr ) ) arr.WriteTo( w );
				else { w.WriteStartArray(); w.WriteEndArray(); }
			}
			else
			{
				foreach ( var prop in r.EnumerateObject() ) prop.WriteTo( w );
			}
		} );
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

	// ───────────────────────── forum + release-notes scrapers ─────────────────────────

	const string ScrapeForumIndexJs = @"
() => {
  const txt = (el) => el ? (el.innerText || '').trim() : '';
  const num = (el) => txt(el).replace(/\s*(threads|posts)\s*$/i, '').trim();
  const slugFromHref = (h) => { try { const u = new URL(h, location.origin); const p = u.pathname.split('/').filter(Boolean); return (p[0] === 'f' && p[1]) ? p[1] : null; } catch (e) { return null; } };
  const out = { categories: [] };
  for (const el of document.querySelectorAll('div.forum')) {
    const bodyLink = el.querySelector('a.body') || el.querySelector('a.icon');
    const href = bodyLink ? bodyLink.getAttribute('href') : null;
    const slug = href ? slugFromHref(href) : null;
    const titleEl = el.querySelector('a.body .title');
    let name = '';
    if (titleEl) { const c = titleEl.cloneNode(true); c.querySelectorAll('.viewers').forEach(v => v.remove()); name = (c.innerText || '').trim(); }
    const lp = el.querySelector('a.lastpost');
    let lastPost = null;
    if (lp) lastPost = { title: txt(lp.querySelector('.title')), time: txt(lp.querySelector('.description')), url: lp.getAttribute('href') };
    // Section label (GAME / DEV / MISC / PACKAGE FORUMS): the headers are <h3>s that sit as
    // siblings of the .children blocks inside one shared .container (order: h3, children, h3,
    // children…). So from this row's .children block, walk back to the nearest preceding <h3>.
    let group = null;
    const block = el.closest('.children') || el.parentElement;
    let sib = block ? block.previousElementSibling : null;
    while (sib) { if (sib.tagName === 'H3') { group = (sib.innerText || '').trim(); break; } sib = sib.previousElementSibling; }
    out.categories.push({
      slug: slug, name: name,
      icon: txt(el.querySelector('a.icon .icon')),
      viewers: txt(el.querySelector('.viewers')),
      description: txt(el.querySelector('a.body .description')),
      threads: num(el.querySelector('.stats .threads')),
      posts: num(el.querySelector('.stats .posts')),
      group: group,
      last_post: lastPost,
    });
  }
  return JSON.stringify(out);
}";

	const string ScrapeForumCategoryJs = @"
() => {
  const txt = (el) => el ? (el.innerText || '').trim() : '';
  const out = { category: { title: (document.title || '').replace(/\s*-\s*s&box.*$/i, '').trim() }, threads: [] };
  for (const a of document.querySelectorAll('a.thread-row')) {
    const href = a.getAttribute('href');
    let threadId = null, cat = null;
    try { const u = new URL(href, location.origin); const p = u.pathname.split('/').filter(Boolean); if (p[0] === 'f') { cat = p[1]; threadId = p[2] ? parseInt(p[2], 10) : null; } } catch (e) {}
    const author = a.querySelector('.thread-meta .username');
    const lastA = a.querySelector('.lastpost .date a.page-link') || a.querySelector('.lastpost .date a');
    const lastUser = a.querySelector('.lastpost .name .username');
    out.threads.push({
      thread_id: threadId, category: cat,
      title: txt(a.querySelector('.thread-title')),
      url: href,
      author: author ? txt(author) : null,
      author_url: author ? author.getAttribute('href') : null,
      created: txt(a.querySelector('.create-time')),
      replies: txt(a.querySelector('.replies')).replace(/\s*posts?\s*$/i, ''),
      views: txt(a.querySelector('.views')).replace(/\s*views?\s*$/i, ''),
      last_post_time: lastA ? txt(lastA) : null,
      last_post_url: lastA ? lastA.getAttribute('href') : null,
      last_post_author: lastUser ? txt(lastUser) : null,
    });
  }
  return JSON.stringify(out);
}";

	const string ScrapeForumThreadJs = @"
() => {
  const txt = (el) => el ? (el.innerText || '').trim() : '';
  const crumbs = [...document.querySelectorAll('.crumb')].map(c => txt(c)).filter(Boolean);
  const out = {
    thread: {
      title: crumbs.length ? crumbs[crumbs.length - 1] : (document.title || '').replace(/\s*-\s*s&box.*$/i, '').trim(),
      category: crumbs.length >= 2 ? crumbs[crumbs.length - 2] : null,
      breadcrumbs: crumbs,
      url: location.pathname,
    },
    posts: [],
  };
  for (const el of document.querySelectorAll('.thread-post')) {
    const userA = el.querySelector('.post-header .username');
    const detail = el.querySelector('.post-header a.detail');
    const idxEl = el.querySelector('.post-header a.index');
    const score = el.querySelector('.post-user .score');
    const metrics = [...el.querySelectorAll('.post-user .metrics span')].map(s => txt(s));
    const content = el.querySelector('.post-content .brix') || el.querySelector('.post-content');
    const ratings = [...el.querySelectorAll('.rating-list .rating-entry')].map(r => ({ icon: txt(r.querySelector('.rating-icon')), count: txt(r.querySelector('.rating-count')) })).filter(r => r.icon || r.count);
    out.posts.push({
      index: idxEl ? txt(idxEl) : (el.id || ''),
      author: userA ? txt(userA) : null,
      author_url: userA ? userA.getAttribute('href') : null,
      author_score: score ? txt(score).replace(/[^\d]/g, '') : null,
      author_join: metrics[0] || null,
      author_postcount: metrics[1] || null,
      time: detail ? txt(detail) : null,
      time_abs: detail ? detail.getAttribute('title') : null,
      content: content ? (content.innerText || '').trim() : '',
      ratings: ratings,
    });
  }
  return JSON.stringify(out);
}";

	const string ScrapeForumSearchJs = @"
() => {
  const txt = (el) => el ? (el.innerText || '').trim() : '';
  const out = { total: 0, results: [] };
  const m = (document.body.innerText || '').match(/Found\s+([\d,]+)\s+Results/i);
  if (m) out.total = parseInt(m[1].replace(/,/g, ''), 10) || 0;
  for (const el of document.querySelectorAll('.result')) {
    const a = el.querySelector('a.title');
    const titleFull = a ? txt(a) : '';
    let title = titleFull, category = null;
    const im = titleFull.match(/^(.*)\s+in\s+([^]+)$/);
    if (im) { title = im[1].trim(); category = im[2].trim(); }
    out.results.push({
      title: title, category: category, title_full: titleFull,
      url: a ? a.getAttribute('href') : null,
      snippet: txt(el.querySelector('.quote')),
      footer: txt(el.querySelector('.footer')),
    });
  }
  return JSON.stringify(out);
}";

	const string ScrapeReleaseNotesJs = @"
(limit) => {
  const txt = (el) => el ? (el.innerText || '').trim() : '';
  const KMAP = { add: 'added', improve: 'improved', fix: 'fixed', remove: 'removed', knownissue: 'known_issues' };
  const out = { versions: [] };
  const groups = document.querySelectorAll('.changelistgroup');
  for (let i = 0; i < groups.length; i++) {
    if (out.versions.length >= limit) break;
    const g = groups[i];
    const v = {
      version: txt(g.querySelector('.version')) || txt(g.querySelector('.meta-column .title')),
      date: txt(g.querySelector('.created')),
      sections: {},
    };
    for (const sec of g.querySelectorAll('.changelistsection')) {
      let kind = 'other';
      for (const k of Object.keys(KMAP)) if (sec.classList.contains(k)) { kind = KMAP[k]; break; }
      const items = [...sec.querySelectorAll('ul.entries li')].map(li => (li.innerText || '').trim()).filter(Boolean);
      if (!v.sections[kind]) v.sections[kind] = [];
      v.sections[kind].push(...items);
    }
    out.versions.push(v);
  }
  return JSON.stringify(out);
}";
}
