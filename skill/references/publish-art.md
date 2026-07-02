# Publishing art — sbox.game store thumbnails + Discord WAYWO

Generating the marketing/store images for an s&box package: the three
**store thumbnails** sbox.game asks for, plus a **Discord WAYWO** showcase
image for the "what are you working on" channel. All are made the same way —
hand-write one self-contained HTML per canvas, then screenshot it.

## Canvases (exact pixel sizes)

| Asset | Size | Ratio | Where it's used |
|---|---|---|---|
| **Square** | `512 × 512` | 1:1 | package grid / icon tile on sbox.game |
| **Wide** | `910 × 512` | ~16:9 | package header / cover banner |
| **Tall** | `512 × 910` | ~9:16 | portrait store slot |
| **WAYWO** | `1200 × 800` | 3:2 landscape | Discord "what are you working on" post (a 2:3 `800×1200` vertical variant if asked) |

In-repo precedent (the convention to match): `projects/my_project_2/thumbnails/`
has `Square.html`/`Wide.html`/`Tall.html` + their `.png`. A worked example of all
four (store set + WAYWO) lives in `projects/7_seconds/thumbnails/`.

## The recipe (HTML → browser-MCP screenshot → crop)

This follows the **claude-design** skill: the HTML *is* the artifact — hand-write
it, don't build a generator. (If `/claude-design` is available, invoke it; its
`references/craft/headless-rendering.md` explains why the browser MCP beats raw
`google-chrome --headless` for this — raw headless **hangs on external fetches**
like a Google-Fonts `<link>` because it blocks on `load`.)

1. **One standalone `.html` per canvas.** A single `.canvas` div sized to the exact
   target. Typical composite for a game: a real in-game screenshot as the
   background (`background-size:cover`, a hint of `filter:blur(3px)` on a
   slightly-scaled `.bg` layer so blurred edges never show), a navy scrim for
   legibility, then the logo lockup / title on top. Put `html,body{margin:0;
   overflow:hidden}` and place `.canvas` at top-left (0,0). Match the game's own
   palette/fonts (read its HUD `.scss`).

2. **Screenshot with the browser MCP** (browser-automation skill):
   ```
   start_browser(headless=false, low_memory=false,
                 window_size="<bigger than canvas>", device_scale_factor=2)
   navigate("file:///abs/path/Wide.html")
   wait(2)                                 # let the webfont settle
   screenshot(save_path="/abs/.raw.png")
   ```
   Make the **window larger than the canvas in both axes** so `.canvas` sits at
   top-left with no scrollbars; the surplus is body background you crop away.
   `device_scale_factor=2` renders 2× for crisp text. The **Tall** canvas (910px
   high) needs a taller window than the others — bump `window_size` height so the
   viewport ≥ 910 css px, or it scrolls/clips.

3. **Crop + downscale with PIL** to the exact size:
   ```python
   from PIL import Image
   im = Image.open(".raw.png").convert("RGB")          # = viewport * 2
   im.crop((0, 0, W*2, H*2)).resize((W, H), Image.LANCZOS).save("Wide.png")
   ```

4. **Verify** by `Read`-ing the final PNG; confirm `identify -format '%wx%h'`
   matches the target exactly.

## Notes

- One browser session renders Square + Wide back-to-back (both fit a ~1120×760
  window); restart taller for Tall (`700×1140`) and for WAYWO (`1440×1040`).
- Keep the same lockup/scrim/rules across all four so the set reads as one brand;
  only the canvas size, background framing (`background-position`), and type scale
  change per aspect.
- Achievement-icon sets use the **same** pipeline: lay all icons out in one HTML
  grid of fixed-size cells, screenshot once, then PIL-crop each cell. Example:
  `projects/7_seconds/icons/Icons.html` → 19 × `128×128` PNGs. Material Symbols
  Rounded (loaded via Google Fonts) gives clean glyphs; the browser MCP loads the
  webfont fine.
