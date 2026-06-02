#!/usr/bin/env python3
"""
youtube — turn a tutorial video into something an agent can *watch*.

Pipeline (all out-of-process, stdlib only):

    URL / local file
        │  yt-dlp            download the video (capped height) + pull metadata
        ▼
    <work>/video.<ext>
        │  yapsnap --timestamps   transcribe to "[MM:SS] sentence" plaintext
        ▼
    transcript.txt
        │  parse                  -> [(seconds, text), ...]
        ▼
    segments
        │  ffmpeg -ss             grab one representative frame per caption
        │  (optional ahash dedupe to drop near-identical frames)
        ▼
    frames/NNNN_MM-SS.jpg + watch.json + watch.md

The "viewing package" is `watch.md`: the narration interleaved with frame images,
in timestamp order. An agent Reads watch.md (or the individual frames) to follow a
tutorial it can't otherwise play. `watch.json` is the same data, machine-readable.

yapsnap exposes no Python API, so we drive its CLI. ffmpeg + yt-dlp likewise. The
only hard runtime deps are those three executables; this script itself is stdlib.

Why a per-caption frame: yapsnap emits one timestamp per recognized sentence, which
tracks the spoken narration. Grabbing a frame at each caption boundary lines the
*picture* up with the *words* — exactly what you need to follow "now click here".
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, asdict
from pathlib import Path

# ───────────────────────────── small utilities ─────────────────────────────

def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def which_or_die(name: str, hint: str) -> str:
    p = shutil.which(name)
    if not p:
        eprint(f"error: '{name}' not found on PATH. {hint}")
        sys.exit(3)
    return p


def ensure_ffmpeg() -> str:
    """Return a usable ffmpeg path AND make it discoverable as `ffmpeg` on PATH.

    Prefers a system ffmpeg. Falls back to the binary bundled with the
    `imageio-ffmpeg` wheel (whose file is named e.g. `ffmpeg-win64-*.exe`, not
    `ffmpeg`), so we drop a correctly-named shim into a stable dir and prepend it to
    PATH. That way the child processes that call `ffmpeg` by name — yapsnap (audio
    decode) and yt-dlp (mux) — find it too, with no system ffmpeg required. This is
    what lets a Windows host get by with only Python installed.
    """
    sys_ff = shutil.which("ffmpeg")
    if sys_ff:
        return sys_ff

    try:
        import imageio_ffmpeg
        src = imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        eprint("error: ffmpeg not found on PATH and imageio-ffmpeg is not installed. "
               "Install system ffmpeg (apt/brew/winget) or `pip install imageio-ffmpeg`.")
        sys.exit(3)

    shim_dir = Path(tempfile.gettempdir()) / "youtube-ffmpeg-bin"
    shim_dir.mkdir(parents=True, exist_ok=True)
    shim = shim_dir / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
    try:
        if shim.exists() or shim.is_symlink():
            shim.unlink()
        os.symlink(src, shim)
    except (OSError, NotImplementedError):
        # Windows without symlink privilege, or cross-device: copy instead.
        try:
            shutil.copy2(src, shim)
        except Exception:
            # Last resort: just put imageio's own dir on PATH (won't satisfy callers
            # that need the literal name `ffmpeg`, but our own calls use the path).
            os.environ["PATH"] = str(Path(src).parent) + os.pathsep + os.environ.get("PATH", "")
            return src
    os.environ["PATH"] = str(shim_dir) + os.pathsep + os.environ.get("PATH", "")
    return str(shim)


def run(cmd: list[str], *, capture: bool = False, check: bool = True,
        quiet: bool = False) -> subprocess.CompletedProcess:
    """Run a subprocess. On failure, surface stderr and exit with a clear message.

    When not capturing, child stdout is redirected to OUR stderr (not stdout): yt-dlp
    writes its progress to stdout, and we keep our own stdout pristine for the final
    `--json` manifest so callers (the youtube_* MCP handler) can parse it cleanly.
    """
    if not quiet:
        eprint("  $", " ".join(shlex_quote(c) for c in cmd))
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE if capture else sys.stderr,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
    if check and proc.returncode != 0:
        eprint(f"error: command failed ({proc.returncode}): {' '.join(cmd[:3])} ...")
        if capture and proc.stderr:
            eprint(proc.stderr.strip()[-2000:])
        sys.exit(4)
    return proc


def shlex_quote(s: str) -> str:
    import shlex
    return shlex.quote(s)


def sanitize(name: str) -> str:
    name = re.sub(r"[^\w.\-]+", "_", name).strip("_")
    return name[:80] or "video"


def label_from_seconds(sec: float) -> str:
    """Human label HH-MM-SS (or MM-SS) usable as a filename and a heading."""
    sec = int(round(sec))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}-{m:02d}-{s:02d}" if h else f"{m:02d}-{s:02d}"


def clock_from_seconds(sec: float) -> str:
    """Human clock HH:MM:SS / MM:SS for display."""
    return label_from_seconds(sec).replace("-", ":")


# ───────────────────────────── transcript parsing ─────────────────────────────

# yapsnap --timestamps prints one sentence per line prefixed with a bracketed
# timestamp. The minutes field is NOT clamped to 59 (a 75-minute talk emits
# "[75:30]"), and very long content can carry an hours field "[H:MM:SS]". Accept
# both [M+:SS] and [H+:MM:SS]. With --diarize the line is "SPEAKER_00 [MM:SS]: text",
# so tolerate an optional speaker prefix and the colon after the bracket.
_TS_LINE = re.compile(
    r"^\s*(?:(?P<spk>SPEAKER_\w+)\s*)?"
    r"\[(?P<ts>\d{1,3}(?::\d{2}){1,2})\]\s*:?\s*(?P<text>.*\S)?\s*$"
)


def parse_timestamp(ts: str) -> float:
    parts = [int(p) for p in ts.split(":")]
    if len(parts) == 2:        # MM:SS  (MM may exceed 59)
        m, s = parts
        return m * 60 + s
    h, m, s = parts            # HH:MM:SS
    return h * 3600 + m * 60 + s


@dataclass
class Segment:
    index: int
    t_seconds: float
    t_label: str          # MM:SS / HH:MM:SS for display
    text: str
    frame: str | None = None   # relative path to extracted frame, set later


def parse_transcript(text: str) -> list[Segment]:
    """Parse '[MM:SS] sentence' lines into ordered Segments.

    Lines without a leading timestamp are appended to the previous segment's text
    (yapsnap can wrap a long sentence), so we never silently drop narration.
    """
    segs: list[Segment] = []
    for raw in text.splitlines():
        if not raw.strip():
            continue
        m = _TS_LINE.match(raw)
        if not m:
            if segs:
                segs[-1].text = (segs[-1].text + " " + raw.strip()).strip()
            continue
        sec = parse_timestamp(m.group("ts"))
        body = (m.group("text") or "").strip()
        spk = m.group("spk")
        if spk and body:
            body = f"**{spk}:** {body}"   # surface diarized speaker labels in watch.md
        segs.append(Segment(
            index=len(segs),
            t_seconds=sec,
            t_label=clock_from_seconds(sec),
            text=body,
        ))
    # Re-index after the fact (indices already sequential, but be explicit).
    for i, s in enumerate(segs):
        s.index = i
    return segs


# ───────────────────────────── video / metadata ─────────────────────────────

@dataclass
class VideoMeta:
    source: str
    id: str
    title: str
    duration: float | None
    uploader: str | None
    webpage_url: str | None


def is_url(s: str) -> bool:
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://", s))


def probe_url_meta(ytdlp: str, url: str) -> VideoMeta:
    proc = run([ytdlp, "-J", "--no-warnings", "--skip-download", url],
               capture=True, check=True, quiet=True)
    try:
        info = json.loads(proc.stdout)
    except json.JSONDecodeError:
        info = {}
    # Playlists: take the first entry.
    if info.get("_type") == "playlist" and info.get("entries"):
        info = info["entries"][0]
    return VideoMeta(
        source=url,
        id=str(info.get("id") or sanitize(url)),
        title=info.get("title") or "Untitled",
        duration=info.get("duration"),
        uploader=info.get("uploader") or info.get("channel"),
        webpage_url=info.get("webpage_url") or url,
    )


def download_video(ytdlp: str, url: str, work: Path, height: int) -> Path:
    """Download a single MP4 (<= height) into work/, return its path."""
    out_tmpl = str(work / "video.%(ext)s")
    fmt = (f"bestvideo[height<={height}][ext=mp4]+bestaudio[ext=m4a]/"
           f"bestvideo[height<={height}]+bestaudio/"
           f"best[height<={height}]/best")
    run([
        ytdlp,
        "-f", fmt,
        "--merge-output-format", "mp4",
        "--no-playlist",
        "--no-warnings",
        "-o", out_tmpl,
        url,
    ], check=True)
    vids = sorted(work.glob("video.*"))
    vids = [v for v in vids if v.suffix.lower() in (".mp4", ".mkv", ".webm", ".mov", ".m4v")]
    if not vids:
        eprint("error: yt-dlp produced no video file")
        sys.exit(4)
    return vids[0]


def local_meta(path: Path) -> VideoMeta:
    return VideoMeta(
        source=str(path),
        id=sanitize(path.stem),
        title=path.stem,
        duration=ffprobe_duration(path),
        uploader=None,
        webpage_url=None,
    )


def ffprobe_duration(path: Path) -> float | None:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return None
    proc = run([ffprobe, "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
               capture=True, check=False, quiet=True)
    try:
        return float(proc.stdout.strip())
    except (ValueError, AttributeError):
        return None


# ───────────────────────────── transcription ─────────────────────────────

def transcribe(yapsnap: str, media: Path, work: Path,
               extra_args: list[str]) -> str:
    """Run yapsnap --timestamps and return the transcript text.

    We pin -o so we always know where the output lands, regardless of yapsnap's
    default ./transcripts/ behavior.
    """
    out = work / "transcript.txt"
    cmd = [yapsnap, str(media), "--timestamps", "-o", str(out)]
    cmd += extra_args
    run(cmd, check=True)
    if not out.exists():
        # Fallback: yapsnap may have written to ./transcripts/<name>_transcript.txt
        cand = sorted(Path.cwd().glob("transcripts/*_transcript.txt"))
        if cand:
            out = cand[-1]
        else:
            eprint("error: yapsnap produced no transcript output")
            sys.exit(4)
    return out.read_text(encoding="utf-8", errors="replace")


# ───────────────────────────── frame extraction ─────────────────────────────

def extract_frame(ffmpeg: str, video: Path, t: float, dst: Path) -> bool:
    """Grab a single JPEG at time t. Fast-seek (-ss before -i). Returns success."""
    t = max(0.0, t)
    proc = run([
        ffmpeg, "-nostdin", "-y",
        "-ss", f"{t:.3f}",
        "-i", str(video),
        "-frames:v", "1",
        "-q:v", "2",
        str(dst),
    ], capture=True, check=False, quiet=True)
    return proc.returncode == 0 and dst.exists() and dst.stat().st_size > 0


def ahash(ffmpeg: str, frame: Path) -> int | None:
    """64-bit average hash of a frame, computed by asking ffmpeg for an 8x8 gray
    raw image — no Pillow/numpy needed. Used to drop near-identical frames."""
    proc = subprocess.run([
        ffmpeg, "-nostdin", "-v", "error",
        "-i", str(frame),
        "-vf", "scale=8:8:flags=area,format=gray",
        "-f", "rawvideo", "-",
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    data = proc.stdout
    if proc.returncode != 0 or len(data) < 64:
        return None
    data = data[:64]
    avg = sum(data) / 64.0
    bits = 0
    for i, b in enumerate(data):
        if b >= avg:
            bits |= (1 << i)
    return bits


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


# ───────────────────────────── main pipeline ─────────────────────────────

def build_watch_md(meta: VideoMeta, segments: list[Segment], frames_dir_name: str) -> str:
    lines: list[str] = []
    lines.append(f"# {meta.title}")
    lines.append("")
    meta_bits = []
    if meta.uploader:
        meta_bits.append(f"**Channel:** {meta.uploader}")
    if meta.duration:
        meta_bits.append(f"**Duration:** {clock_from_seconds(meta.duration)}")
    if meta.webpage_url:
        meta_bits.append(f"**Source:** {meta.webpage_url}")
    meta_bits.append(f"**Captions:** {len(segments)}")
    n_frames = sum(1 for s in segments if s.frame)
    meta_bits.append(f"**Frames:** {n_frames}")
    if meta_bits:
        lines.append("  \n".join(meta_bits))
        lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("> Each section is a caption from the video at its timestamp, with "
                 "the frame captured at that moment. Read top-to-bottom to follow the "
                 "tutorial; open a frame image to see exactly what was on screen.")
    lines.append("")
    for s in segments:
        anchor = f"`[{s.t_label}]`"
        lines.append(f"### {anchor}")
        lines.append("")
        if s.frame:
            lines.append(f"![{s.t_label}]({frames_dir_name}/{Path(s.frame).name})")
            lines.append("")
        if s.text:
            lines.append(s.text)
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="youtube",
        description="Transcribe a video with yapsnap and extract a frame per caption "
                    "so an agent can 'watch' it. Produces watch.md + watch.json + frames/.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("input", help="YouTube/other video URL, or a local video file path.")
    ap.add_argument("-o", "--output", default=None,
                    help="Output directory (default: ./youtube-out/<video-id>).")
    ap.add_argument("--height", type=int, default=720,
                    help="Max video height to download (default 720). Lower = faster.")
    ap.add_argument("--frame-offset", type=float, default=0.5,
                    help="Seconds added to each caption time before grabbing the frame "
                         "(default 0.5; the visual usually lands just after the words).")
    ap.add_argument("--every", type=int, default=1, metavar="N",
                    help="Use every Nth caption (default 1 = all).")
    ap.add_argument("--max-frames", type=int, default=0, metavar="N",
                    help="Cap total frames; captions are sampled evenly to fit (0 = no cap).")
    ap.add_argument("--dedupe", dest="dedupe", action="store_true", default=True,
                    help="Drop frames near-identical to the previous kept frame (default on).")
    ap.add_argument("--no-dedupe", dest="dedupe", action="store_false",
                    help="Keep one frame per caption even if visually unchanged.")
    ap.add_argument("--dedupe-threshold", type=int, default=6, metavar="D",
                    help="Max ahash Hamming distance to treat two frames as duplicates "
                         "(default 6; lower = stricter, keeps more frames).")
    ap.add_argument("--keep-video", action="store_true",
                    help="Keep the downloaded video file (default: delete after extraction).")
    ap.add_argument("--model", default=None,
                    help="Pass through to yapsnap --model (custom model dir).")
    ap.add_argument("--yapsnap-args", default="", metavar="STR",
                    help="Extra args passed verbatim to yapsnap (e.g. \"--speed 1.0 --diarize\").")
    ap.add_argument("--json", action="store_true",
                    help="Print the manifest JSON to stdout on completion.")
    args = ap.parse_args(argv)

    # Make this interpreter's console scripts (yapsnap, yt-dlp) resolvable. Running a
    # venv's python directly — as the youtube_* MCP handler does — does NOT put the
    # venv's Scripts/bin dir on PATH the way `activate` would, so `which("yapsnap")`
    # would miss it. Prepend it ourselves.
    _scripts = os.path.dirname(os.path.abspath(sys.executable))
    if _scripts and _scripts not in os.environ.get("PATH", "").split(os.pathsep):
        os.environ["PATH"] = _scripts + os.pathsep + os.environ.get("PATH", "")

    ffmpeg = ensure_ffmpeg()   # also injects ffmpeg onto PATH for yapsnap + yt-dlp
    yapsnap = which_or_die("yapsnap", "pip install yapsnap (or run ./install.sh).")

    src = args.input
    is_remote = is_url(src)
    ytdlp = which_or_die("yt-dlp", "pip install yt-dlp") if is_remote else None

    # Resolve metadata + output dir early so the layout is predictable.
    if is_remote:
        eprint("[1/4] probing video metadata …")
        meta = probe_url_meta(ytdlp, src)
    else:
        p = Path(src).expanduser()
        if not p.exists():
            eprint(f"error: local file not found: {p}")
            return 2
        meta = local_meta(p)

    out_dir = Path(args.output).expanduser() if args.output else \
        Path.cwd() / "youtube-out" / sanitize(meta.id)
    frames_dir = out_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="youtube-") as tmp:
        work = Path(tmp)

        # 1. obtain the video
        if is_remote:
            eprint(f"[2/4] downloading video (<= {args.height}p) …")
            video = download_video(ytdlp, src, work, args.height)
        else:
            video = Path(src).expanduser()
        if meta.duration is None:
            meta.duration = ffprobe_duration(video)

        # 2. transcribe
        eprint("[3/4] transcribing with yapsnap (--timestamps) …")
        extra: list[str] = []
        if args.model:
            extra += ["--model", args.model]
        if args.yapsnap_args.strip():
            import shlex
            extra += shlex.split(args.yapsnap_args)
        transcript_text = transcribe(yapsnap, video, work, extra)
        (out_dir / "transcript.txt").write_text(transcript_text, encoding="utf-8")

        segments = parse_transcript(transcript_text)
        if not segments:
            eprint("error: no timestamped captions parsed from yapsnap output. "
                   "Is the audio speech? See transcript.txt.")
            return 5
        eprint(f"      parsed {len(segments)} captions "
               f"({clock_from_seconds(segments[0].t_seconds)} … "
               f"{clock_from_seconds(segments[-1].t_seconds)})")

        # 3. choose which captions get a frame
        chosen = segments[:: max(1, args.every)]
        if args.max_frames and len(chosen) > args.max_frames:
            step = len(chosen) / float(args.max_frames)
            chosen = [chosen[int(i * step)] for i in range(args.max_frames)]

        # 4. extract frames (+ optional perceptual dedupe)
        eprint(f"[4/4] extracting {len(chosen)} frames "
               f"(offset +{args.frame_offset}s, dedupe={'on' if args.dedupe else 'off'}) …")
        last_hash: int | None = None
        kept = 0
        for n, seg in enumerate(chosen, 1):
            t = seg.t_seconds + args.frame_offset
            if meta.duration:
                t = min(t, max(0.0, meta.duration - 0.05))
            fname = f"{seg.index:04d}_{label_from_seconds(seg.t_seconds)}.jpg"
            dst = frames_dir / fname
            if not extract_frame(ffmpeg, video, t, dst):
                continue
            if args.dedupe:
                h = ahash(ffmpeg, dst)
                if h is not None and last_hash is not None and \
                        hamming(h, last_hash) <= args.dedupe_threshold:
                    dst.unlink(missing_ok=True)   # near-identical to previous kept frame
                    continue
                if h is not None:
                    last_hash = h
            seg.frame = f"frames/{fname}"
            kept += 1
            if n % 25 == 0 or n == len(chosen):
                eprint(f"      {n}/{len(chosen)} captions processed, {kept} frames kept")

        if args.keep_video and is_remote:
            shutil.copy2(video, out_dir / video.name)

    # 5. write the viewing package
    manifest = {
        "tool": "youtube",
        "video": asdict(meta),
        "frame_offset": args.frame_offset,
        "dedupe": args.dedupe,
        "caption_count": len(segments),
        "frame_count": sum(1 for s in segments if s.frame),
        "segments": [asdict(s) for s in segments],
    }
    (out_dir / "watch.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    (out_dir / "watch.md").write_text(
        build_watch_md(meta, segments, "frames"), encoding="utf-8")

    eprint("")
    eprint(f"done. {manifest['frame_count']} frames for {len(segments)} captions.")
    eprint(f"  package : {out_dir}")
    eprint(f"  watch   : {out_dir / 'watch.md'}   <- read this to 'watch' the video")
    eprint(f"  data    : {out_dir / 'watch.json'}")
    if args.json:
        print(json.dumps({
            "output_dir": str(out_dir),
            "watch_md": str(out_dir / "watch.md"),
            "watch_json": str(out_dir / "watch.json"),
            "transcript": str(out_dir / "transcript.txt"),
            "frames_dir": str(frames_dir),
            "caption_count": manifest["caption_count"],
            "frame_count": manifest["frame_count"],
            "title": meta.title,
            "duration": meta.duration,
        }, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        eprint("\ninterrupted")
        sys.exit(130)
