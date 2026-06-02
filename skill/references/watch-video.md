# Finding & watching a tutorial video (youtube)

`learn_search` surfaces text community tutorials, but a lot of practical s&box
knowledge lives in **YouTube (and other) videos** you can't play. These tools let you
**find** a video by topic and **watch** it: `youtube_watch` turns a video into a
**viewing package** you *can* read — the narration in timestamp order with the
on-screen frame embedded at each caption.

Exposed as **in-editor MCP tools** (`youtube_*`). The pipeline runs out of process —
search/download (yt-dlp) → transcribe (yapsnap, CPU-only, local) → one ffmpeg frame
per caption — and writes the package to the **game folder**, which you then read with
your own file tools (frames are images; JSON-over-MCP can't carry them).

## Tools

- **`youtube_search`** — `{ query, limit?, sort? }`. Keyless YouTube **video search**
  (yt-dlp's InnerTube `ytsearchN:` — no API key/quota). Returns ranked
  `results[{id, title, url, channel, duration, view_count}]`. `sort` = `relevance`
  (default) / `date` / `views`. Videos only. Feed a result's `url` to `youtube_watch`.
- **`youtube_watch`** — `{ input, max_frames?, every?, height?, frame_offset?, dedupe?,
  dedupe_threshold?, keep_video?, model?, yapsnap_args?, include_segments?, timeout_seconds? }`.
  `input` is a video URL or absolute local path. Returns paths + caption `segments[]`.
- **`youtube_status`** — venv ready? deps import? resolved paths + cache count. Read-only.
- **`youtube_install`** — provision the Python venv (yapsnap + yt-dlp + imageio-ffmpeg)
  into `{game}/.claude-sbox/youtube/venv/`. Idempotent; `force:true` recreates.

## Flow

1. `youtube_status`. If `venv_ready:false`, call `youtube_install` once (needs Python 3
   on the host PATH; ffmpeg is bundled via imageio-ffmpeg — no system ffmpeg needed).
   The install runs ~1-2 min; the MCP call may time out while pip works — just re-poll
   `youtube_status` until `venv_ready:true` and `deps.import_ok:true`.
2. (optional) `youtube_search { query: "<topic>" }` to discover a video, then take a
   result's `url`. Skip if the user already gave you a link.
3. `youtube_watch { input: "<url>" }`. First call also downloads the speech model (~once).
   Long/HD videos: raise `timeout_seconds`, lower `height`, or cap `max_frames`.
4. **Read the output from the game folder.** The result gives `output_dir_game_relative`
   (e.g. `.claude-sbox/youtube/youtube-out/<id>`). Read it under your local view of the
   game folder — `<your-game-dir>/<that path>/watch.md`. `watch.md` interleaves each
   caption with its frame, in order = "watching" the video. Open individual
   `frames/NNNN_MM-SS.jpg` for a closer look. The returned `segments[]` already give you
   the narration (`t`, `t_seconds`, `text`, `frame` relative to `output_dir`) without a
   second round-trip.

> Path mapping: the editor reports Windows paths (`C:\…\sbox-public\game\…`); read them
> through your own filesystem view of the same game folder. In this workspace that's
> `~/sbox-public/game/.claude-sbox/youtube/youtube-out/<id>/`.

## Knobs that matter

- `height: 480` — faster download/extract when fidelity isn't critical.
- `dedupe:false` — keep one frame per caption (default drops frames near-identical to the
  previous kept one, so a static talking-head intro doesn't become 50 copies).
- `max_frames: N` — evenly sampled cap when you just want the gist (default 60).
- `frame_offset` — the visual usually lands just after the words (default 0.5s).
- `yapsnap_args: "--diarize --num-speakers 2"` — speaker labels for multi-presenter content.

## Notes / privacy

- yapsnap transcribes **locally** (CPU, no cloud); yt-dlp fetches the video. The only
  thing that leaves the machine is the normal video download. **English audio only**
  (Kroko model).
- Long videos = many captions. Start with `max_frames` / `every` to scan; the inline
  `segments[]` is auto-omitted above ~400 captions (read `watch.json` / `watch.md` then).
- Packages persist under the game store and are reused (`youtube_status.cached_packages`).

## Fallback: standalone CLI

The same engine runs as a CLI for use outside the editor (`game/addons/claude-sbox-setup/youtube/`):
`./youtube-watch "<url>" --json`, then read `./youtube-out/<id>/watch.md`. The launcher
bootstraps its own venv on first run.
