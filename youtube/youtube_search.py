#!/usr/bin/env python3
"""
youtube_search — keyless YouTube search via yt-dlp's InnerTube search provider.

yt-dlp's `ytsearchN:<query>` runs the same private InnerTube search the YouTube apps
use — no Data API key, no quota, no signup. We drive it as a *library* (not the CLI)
with `extract_flat` so it only pulls the lightweight search-result entries (no per-video
page fetch), which is fast and cheap. The companion to youtube_watch.py: search → pick a
url → youtube_watch it.

Output: a single JSON object on stdout (everything else → stderr) so the youtube_search
MCP handler can parse it cleanly.

    youtube_search.py "<query>" [--limit N] [--sort relevance|date|views] [--json]

Notes / limits (yt-dlp's search vs the official API):
  • Results are VIDEOS (ytsearch returns videos, not channels/playlists).
  • Server-side filters (duration/upload-date) aren't exposed by ytsearch; --sort uses
    yt-dlp's date/view variants where available, else relevance.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone


def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def entry_age_days(e) -> "int | None":
    """Best-effort age in days from a flat search entry.

    Flat search entries from recent yt-dlp usually carry `timestamp` (epoch seconds);
    some carry `upload_date` (YYYYMMDD). Returns None when neither is present so the
    recency re-rank degrades gracefully (unknown-date videos sort after known-recent ones).
    """
    ts = e.get("timestamp")
    if isinstance(ts, (int, float)) and ts > 0:
        try:
            d = datetime.fromtimestamp(ts, tz=timezone.utc)
            return max(0, (datetime.now(timezone.utc) - d).days)
        except Exception:
            pass
    ud = e.get("upload_date")
    if isinstance(ud, str) and len(ud) == 8 and ud.isdigit():
        try:
            d = datetime.strptime(ud, "%Y%m%d").replace(tzinfo=timezone.utc)
            return max(0, (datetime.now(timezone.utc) - d).days)
        except Exception:
            pass
    return None


def fmt_duration(seconds) -> str:
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return ""
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="youtube-search",
        description="Search YouTube via yt-dlp (keyless InnerTube). Returns ranked video results.",
    )
    ap.add_argument("query", help="Search query.")
    ap.add_argument("--limit", type=int, default=10, help="Max results (default 10).")
    ap.add_argument("--sort", choices=["relevance", "date", "views"], default="relevance",
                    help="Result ordering (default relevance). 'date' = newest, 'views' = most viewed.")
    ap.add_argument("--recent-days", type=int, default=30,
                    help="Soft recency PREFERENCE (default 30): videos uploaded within this many "
                         "days are floated to the top while preserving relevance order within each "
                         "group (not a hard filter — older videos still appear below). 0 disables. "
                         "Ignored for --sort date/views (those have an explicit order).")
    ap.add_argument("--json", action="store_true", help="Print the results JSON to stdout.")
    args = ap.parse_args(argv)

    try:
        import yt_dlp
    except Exception:
        eprint("error: yt-dlp not installed in this environment. Run the install tool.")
        return 3

    limit = max(1, min(args.limit, 50))

    # Recency preference is a soft re-rank applied only to relevance ordering (date/views
    # already impose their own order). When active we fetch a larger candidate pool so
    # there's room to float recent videos up without dropping relevant older ones.
    recent_days = max(0, args.recent_days)
    recency_on = recent_days > 0 and args.sort == "relevance"
    poolsize = min(50, max(limit * 3, 25)) if recency_on else limit

    # yt-dlp search providers. There's no general server-side sort, but it ships a couple
    # of ordered variants; fall back to plain relevance ytsearch otherwise.
    provider = {
        "relevance": "ytsearch",
        "date": "ytsearchdate",   # newest first
        "views": "ytsearch",      # no view-sorted provider; we sort client-side below
    }.get(args.sort, "ytsearch")
    search_term = f"{provider}{poolsize}:{args.query}"

    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,     # search-result entries only — no per-video page fetch
        "skip_download": True,
        "noprogress": True,
        "ignoreerrors": True,
    }

    eprint(f"[youtube-search] {provider}{limit}: {args.query!r}")
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(search_term, download=False)
    except Exception as e:
        eprint(f"error: search failed: {e}")
        return 4

    entries = [e for e in (info or {}).get("entries", []) if e]

    results = []
    for e in entries:
        vid = e.get("id") or ""
        age = entry_age_days(e)
        results.append({
            "id": vid,
            "title": e.get("title") or "",
            "url": e.get("url") or (f"https://www.youtube.com/watch?v={vid}" if vid else ""),
            "channel": e.get("channel") or e.get("uploader") or "",
            "channel_id": e.get("channel_id") or e.get("uploader_id") or "",
            "duration": fmt_duration(e.get("duration")),
            "duration_seconds": e.get("duration"),
            "view_count": e.get("view_count"),
            "live": e.get("live_status") in ("is_live", "is_upcoming"),
            "upload_date": e.get("upload_date"),
            "age_days": age,
            "recent": (age is not None and age <= recent_days) if recent_days > 0 else None,
        })

    # ytsearch has no view-sorted provider; honor --sort views client-side.
    if args.sort == "views":
        results.sort(key=lambda r: r.get("view_count") or 0, reverse=True)

    # Soft recency preference: float videos uploaded within --recent-days to the top while
    # preserving the underlying relevance order within each group (stable sort). Videos with
    # an unknown upload date sort with the "older" group (we can't confirm they're recent),
    # so known-recent videos always win, but nothing relevant is dropped — just reordered.
    recent_hits = 0
    if recency_on:
        recent_hits = sum(1 for r in results if r.get("recent"))
        results.sort(key=lambda r: 0 if r.get("recent") else 1)  # stable: keeps relevance within group

    results = results[:limit]
    manifest = {
        "query": args.query,
        "sort": args.sort,
        "recent_days": recent_days,
        "prefer_recent": recency_on,
        "recent_in_pool": recent_hits,
        "count": len(results),
        "results": results,
    }

    eprint(f"[youtube-search] {len(results)} result(s)")
    if args.json:
        print(json.dumps(manifest, ensure_ascii=False))
    else:
        for i, r in enumerate(results, 1):
            eprint(f"{i:2d}. {r['title']}  [{r['duration']}]  — {r['channel']}  {r['url']}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        eprint("\ninterrupted")
        sys.exit(130)
