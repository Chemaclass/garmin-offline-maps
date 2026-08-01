---
name: preview
description: Render the map to PNG to see what the watch would draw, and refresh the README screenshots. Use after a rendering, palette, projection, simplification or draw-order change, or when the user asks what the map looks like, wants to eyeball a pack, or wants the docs/img previews regenerated.
---

# Preview renders

`mappack/preview.py` re-implements `source/MapRenderer.mc` in Python over the
real generated artefacts. **It is the only way to check the rendering maths
without a watch**, so treat a preview that looks wrong as a real bug. Background:
[docs/PACKER.md § The two mirrors](../../../docs/PACKER.md#the-two-mirrors).

```bash
pip install pillow      # optional everywhere else; required here

cd tools/mappack
python3 -m mappack.preview --zoom 16 --out preview.png
python3 -m mappack.preview --zoom 15 --heading 40 --out heading-up.png
python3 -m mappack.preview --zoom 15 --day --size 390 --out venu3s-day.png
```

`--size 390` is the Venu 3S screen (default 454, the Venu 3). `--day` switches
palette. `--palette` points at a different `Palette.mc`.

## Then actually look at it

`Read` the PNG. Do not report success because the command exited 0. Things that
only show up visually: roads vanishing at a zoom, a layer drawing over one it
should sit under, tile seams where the clip buffer is wrong, a colour invisible
against its background.

Sweep every zoom the way CI does:

```bash
for z in 12 14 15 16 17; do python3 -m mappack.preview --zoom "$z" --out "preview-z$z.png"; done
```

`preview*.png` at the repo root is gitignored on purpose. The four in
`docs/img/` are what the README embeds — refresh those **only** when the
rendering genuinely changed, since churning them hides real visual regressions
in review.
