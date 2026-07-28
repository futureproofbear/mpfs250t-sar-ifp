# Slides

`ai-orchestrated-hardware.md` — a [Marp](https://marp.app/) deck on orchestrating AI agents for
FPGA/firmware development, using this project's SAR image-formation processor as the worked example.

## Deliverables

| file | what it is |
|---|---|
| `ai-orchestrated-hardware.md` | the deck — **Marp markdown**, this is the source of truth |
| `diagrams/*.drawio.svg` | the figures — **draw.io documents saved as SVG** |
| `make_diagrams.py` | regenerates every figure |

Rendered output (`.html`, `.pdf`, `.pptx`, `slide*.png`) is git-ignored: it is build output, not
source.

## The figures are editable

Each `.drawio.svg` is **one file serving two purposes**:

- a valid SVG, so Marp, GitHub and any browser render it directly, and
- a draw.io document — the `mxfile` XML rides in the root `<svg content="...">` attribute, exactly
  as draw.io's own *Editable SVG* export writes it.

Open any of them in draw.io (**File → Open**) and you get shapes, not a picture.

> **Your hand edits are protected.** `make_diagrams.py` checks `git status` per file and REFUSES to
> overwrite any figure with uncommitted local changes:
>
> ```
>   SKIPPED  fig-loop.drawio.svg  (locally modified -- your edit is safe)
> ```
>
> So you can open a figure in draw.io, tweak it, and regenerating the others will not touch yours.
> To fold a tweak back into the generator, edit the spec in the script and commit; to deliberately
> discard local edits and regenerate, pass `--force`.
>
> The generator exists so the visual and the embedded draw.io XML cannot drift apart — drawing them
> separately guarantees they will.

## Rendering

Needs Node. On this machine Node is a portable install and is not on `PATH` by default:

```bash
export PATH="/c/Users/lkwangsi/Tools/node-v22.14.0:$PATH"
npm install -g @marp-team/marp-cli        # once

cd docs/slides
python make_diagrams.py                   # regenerate figures (optional)

# HTML preview — fast, no browser download needed
marp ai-orchestrated-hardware.md --html --allow-local-files -o deck.html

# PDF / PNG — downloads a headless Chromium on first run (slow), and needs --no-stdin
marp ai-orchestrated-hardware.md --pdf   --allow-local-files --no-stdin -o deck.pdf
marp ai-orchestrated-hardware.md --images png --allow-local-files --no-stdin -o slide.png
```

The HTML references the figures by relative path, so keep `diagrams/` beside it. Use the PDF for a
single self-contained file to send onward.

## Keeping it accurate

Every number in the deck comes from a measurement recorded in `docs/SAR_IMPLEMENTATION_RECORD.md`
or `docs/ARCHITECTURE.md`. When a baseline moves, the deck is downstream of those documents and
must be updated with them — run the `doc-accuracy` agent over the doc set at each milestone and
include this file in scope.
