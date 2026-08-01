---
name: pack
description: Build a map pack for a real area and get it inside the device budgets. Use when the user wants to pack a city/region, change zoom levels or simplification, replace the demo pack, mentions Overpass or a Geofabrik .osm.pbf, or when a pack is too big for the Connect IQ store or resource limits.
---

# Building a map pack

Budgets, ceilings, knobs and Overpass etiquette:
**[docs/PACKER.md](../../../docs/PACKER.md)**. Read it before tuning anything.

## Run it

```bash
make pack BBOX=-3.75,40.38,-3.65,40.45 NAME="Madrid"      # west,south,east,north
make pack INPUT=~/Downloads/madrid.osm.pbf NAME="Madrid"  # needs: pip install osmium
```

**Confirm the area with the user first.** This makes a network request and
overwrites `mapdata/active/` and `source/generated/MapIndex.mc`. Anything larger
than a city goes through a Geofabrik extract, not Overpass; add
`EXTRA="--cache foo.osm"` when iterating on the same area.

## Read the size report, do not skim it

`cli.py:report` prints resources used, in-app bytes, and points dropped, and
warns on each ceiling. A warning is a blocker, not a note: an over-budget pack
produces an app that will not install or a map with the detail gutted.

If it is too big, reach for the knobs in PACKER.md in the documented order.
Shrinking the bbox beats every one of them.

## Afterwards

1. Look at it: `cd tools/mappack && python3 -m mappack.preview --zoom 16 --out
   preview.png` (needs Pillow). The preview reproduces the on-watch renderer, so
   if it looks wrong the watch will look wrong.
2. `make test`: the round-trip and generated-artefact tests run against
   whatever is in `mapdata/active/`.
3. **Decide whether the pack gets committed.** The demo pack is committed on
   purpose so the repo builds out of the box, and CI regenerates it with
   `make demo` and fails on any diff. A large personal pack should stay local,
   `.gitignore` has a commented-out line for exactly this. Never quietly commit
   a real pack over the demo.
4. Attribution is not optional. OSM-derived packs are ODbL. A different source
   needs `--attribution` and a licence check before publishing.
