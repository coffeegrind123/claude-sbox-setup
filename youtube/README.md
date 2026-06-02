# youtube — let an agent *watch* an s&box tutorial video

`learn_search` finds community tutorials, but a lot of the best s&box knowledge is
on **YouTube** and an agent can't play a video. `youtube` turns a video URL into a
**viewing package** the agent can read:

- **`watch.md`** — the narration, in timestamp order, with the on-screen frame
  embedded at each caption. Read this top-to-bottom to follow the tutorial.
- **`frames/NNNN_MM-SS.jpg`** — one representative frame per caption (near-identical
  frames are de-duplicated). Open any frame to see exactly what was on screen.
- **`watch.json`** — the same data, machine-readable (`segments[]` with
  `t_seconds`, `t_label`, `text`, `frame`).
- **`transcript.txt`** — the raw yapsnap transcript.

## Pipeline

```
URL ──yt-dlp──> video.mp4 ──yapsnap --timestamps──> "[MM:SS] sentence"
                    │                                       │
                    └────────── ffmpeg -ss (per caption) ───┴──> frames/ + watch.md/json
```

[yapsnap](https://github.com/kouhxp/yapsnap) does CPU-only, no-cloud transcription
(streaming Zipformer2 ONNX). It emits a timestamp per sentence; we grab a frame at
each timestamp so the picture lines up with the words.

## Install

```bash
./install.sh           # creates a venv with yapsnap + yt-dlp (ffmpeg must be on PATH)
```

The `youtube` launcher also bootstraps this venv lazily on first run, so you can
skip `install.sh` and just run the tool.

## Usage

```bash
# Basic: a viewing package under ./youtube-out/<video-id>/
./youtube-watch "https://www.youtube.com/watch?v=XXXXXXXXXXX"

# Pick the output dir, grab every caption (no dedupe), cap quality for speed
./youtube-watch "<url>" -o /tmp/tut --no-dedupe --height 480

# A local recording
./youtube-watch ./my-screencast.mp4

# Cap the number of frames (evenly sampled), print a JSON manifest for tooling
./youtube-watch "<url>" --max-frames 60 --json
```

### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `-o, --output DIR` | `./youtube-out/<id>` | where the package is written |
| `--height N` | `720` | max video height to download (lower = faster) |
| `--frame-offset SEC` | `0.5` | seconds after the caption time to grab the frame |
| `--every N` | `1` | use every Nth caption |
| `--max-frames N` | `0` (off) | cap total frames, sampling captions evenly |
| `--dedupe` / `--no-dedupe` | on | drop frames near-identical to the previous kept frame |
| `--dedupe-threshold D` | `6` | ahash Hamming distance for "duplicate" (lower = keep more) |
| `--keep-video` | off | keep the downloaded video file |
| `--model DIR` | — | pass-through to `yapsnap --model` |
| `--yapsnap-args "…"` | — | extra args for yapsnap (e.g. `"--speed 1.0 --diarize"`) |
| `--json` | off | print a manifest of output paths to stdout |

## How an agent uses it

1. Run `./youtube-watch "<url>"` (use `--json` to get paths back programmatically).
2. `Read` the printed `watch.md` — narration + frames inline, in order.
3. Open individual `frames/*.jpg` for any step that needs a closer look.

De-dupe keeps a talking-head intro from becoming 50 identical frames while still
capturing every time the screen actually changes (editor view, code, inspector).
