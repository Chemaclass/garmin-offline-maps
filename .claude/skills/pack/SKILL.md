---
name: pack
description: Build a map pack for a real area and get it inside the device budgets. Use when the user wants to pack a city/region, change zoom levels or simplification, replace the demo pack, mentions Overpass or a Geofabrik .osm.pbf, or when a pack is too big for the Connect IQ store or resource limits.
---

# Building a map pack

## Pick the source

```bash
make pack BBOX=-3.75,40.38,-3.65,40.45 NAME="Madrid"   # Overpass, live
make pack INPUT=~/Downloads/madrid-latest.osm.pbf NAME="Madrid"   # needs: pip install osmium
```

`BBOX` is `west,south,east,north`. Anything larger than a city goes through a
[Geofabrik](https://download.geofabrik.de/) extract instead of Overpass — do not
hammer a free public API with a regional query. Add `EXTRA="--cache foo.osm"`
when iterating on the same area so Overpass is hit once.

Confirm the area with the user before running: this makes a network request and
overwrites `mapdata/active/` and `source/generated/MapIndex.mc`.

## Read the size report, do not skim it

`cli.py` prints per-zoom tile/block counts, then:

- **`resources`** — jsonData ids. Connect IQ caps around **255**; the packer
  budgets 200 and warns past 250.
- **`in-app`** — base64 bytes, i.e. what lands in the `.prg`. The store rejects
  `.iq` over **15 MB**; the packer warns past 12 MB.
- **`points … dropped`** — geometry thrown away by the per-tile budget. A warning
  fires past 25%, and it means the map looks visibly gutted at that zoom.

## Knobs, in the order to reach for them

```bash
ZOOMS=12,14                        # drop the top zoom: ~4x smaller, less detail up close
SIMPLIFY=2.0                       # coarser geometry: smaller, slightly angular
EXTRA="--max-points-per-tile 700"  # thins dense tiles, redraws faster on-watch
EXTRA="--buildings"                # adds footprints: expensive, rarely worth it
```

Shrinking the bbox beats every one of them. A 60×60 km metro region is ~11 MB
and ~200 resources — that is the practical ceiling, not a target.

## Afterwards

1. Look at it before flashing it:
   `cd tools/mappack && python3 -m mappack.preview --zoom 16 --out preview.png`
   (needs Pillow). The preview reproduces the on-watch renderer, so if it looks
   wrong, the watch will look wrong.
2. `make test` — the round-trip and generated-artefact tests run against
   whatever is in `mapdata/active/`.
3. Decide whether the pack gets committed. The **demo** pack is committed on
   purpose so the repo builds out of the box, and CI regenerates it with
   `make demo` and fails on any diff. A large personal pack should stay local —
   `.gitignore` has a commented-out `mapdata/active/` line for exactly this.
   Never commit a real pack over the demo without saying so.
4. Attribution is not optional. OSM-derived packs are ODbL; the app carries
   "© OpenStreetMap contributors" and the packer writes it into the pack
   metadata. A different source needs `--attribution` and a licence check.
