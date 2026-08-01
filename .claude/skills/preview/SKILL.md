---
name: preview
description: Render the map to PNG to see what the watch would draw, and refresh the README screenshots. Use after a rendering, palette, projection, simplification or draw-order change, or when the user asks what the map looks like, wants to eyeball a pack, or wants the docs/img previews regenerated.
---

# Preview renders

`tools/mappack/mappack/preview.py` re-implements `source/MapRenderer.mc` in
Python — same Web Mercator projection, same tile lookup, same two-pass draw
order (areas, then strokes), same pen widths, and the palette scraped live out
of `source/Palette.mc`. It renders from the real generated resources in
`mapdata/active/`. **It is the only way to check the rendering maths without a
watch**, so treat a preview that looks wrong as a real bug.

Needs Pillow, which is optional everywhere else in this repo:

```bash
pip install pillow      # without it, 10 of the 67 tests skip
```

## Render

```bash
cd tools/mappack
python3 -m mappack.preview --zoom 16 --out preview.png
python3 -m mappack.preview --zoom 15 --heading 40 --out preview-heading-up.png
python3 -m mappack.preview --zoom 15 --day --size 390 --out preview-venu3s-day.png
```

`--size 390` is the Venu 3S screen; the default is the Venu 3's 454. `--day`
switches to the daylight palette. `--palette` points at a different `Palette.mc`.

Then actually look at the file — `Read` the PNG, do not just confirm the command
exited 0. Things that only show up visually: roads vanishing at a zoom, a layer
drawing over one it should sit under, tile seams where the clip buffer is wrong,
a colour that is invisible against the background.

Sweep every zoom the way CI does:

```bash
for z in 12 14 15 16 17; do python3 -m mappack.preview --zoom "$z" --out "preview-z$z.png"; done
```

`preview*.png` at the repo root is gitignored on purpose; `docs/img/preview*.png`
is the exception and those four are what the README embeds. Only refresh those
when the rendering genuinely changed — they are documentation, and churning them
makes real visual regressions hard to spot in review.
