# The packer

`tools/mappack` turns OpenStreetMap data into Connect IQ resources plus a
generated Monkey C index. Pure stdlib — Pillow is optional and import-guarded,
osmium is imported lazily for `.pbf` only. Keep it that way: the packer must run
on a bare `python3`.

```bash
make pack BBOX=-3.75,40.38,-3.65,40.45 NAME="Madrid"      # live, via Overpass
make pack INPUT=~/Downloads/madrid.osm.pbf NAME="Madrid"  # needs: pip install osmium
make demo                                                 # the committed synthetic pack
```

## Pipeline

```
osmread.load()          Overpass query or .osm/.osm.xml/.osm.bz2/.osm.gz/.osm.pbf
      │                 XML is stream-parsed, keeping nodes only while ways need them
      ▼  List[Way]
classify.classify()     OSM tags -> Klass(layer 0..9, min zoom, geometry kind)
      │                 returns None to drop the way entirely
      ▼  List[Feature]
geom.project()          lat/lon -> Web Mercator world pixels at a reference zoom
geom.simplify()         iterative Douglas-Peucker (no recursion-limit surprises)
      │
      ▼
pack.build_tiles()      per data zoom: clip into 256 px tiles with a 64-unit buffer
      │                 clip_polyline  = Cohen-Sutherland per segment, stitched
      │                 clip_polygon   = Sutherland-Hodgman
      │                 quantise to EXTENT 1024 (4 units per pixel)
      │                 apply the per-tile point budget
      ▼
pack.encode_tile()      layers ascending, delta + zigzag varints
pack.encode_block()     group 2^log2 x 2^log2 tiles into one block
      │
      ▼
emit.write_pack()       base64 -> blocks/*.json, mapdata.xml, MapIndex.mc
```

## Blocks, and why they exist

Connect IQ runs out of resource ids somewhere around **255 per type**. The demo
pack alone has 122 tiles (2 at z12, 9 at z14, 111 at z16). One resource per tile
would exhaust the budget on a single small town.

So tiles are grouped: a block covers `2^block_log2` tiles per axis — 8×8 at the
default `log2 = 3`. The demo's 122 tiles become **7 resources**.

```
mapdata/active/
├── pack.json                     metadata + the size report's numbers (not compiled in)
├── mapdata.xml                   <jsonData> declarations, one per block
└── blocks/
    └── b16_4011_3088.json        b<dataZoom>_<blockX>_<blockY>
```

Each block file is one base64 string in a one-element JSON array:

```json
["TQEMA/oAwQACBQARAAYAygAHAB0AAQEM8BCACQoVCQ1hNxsGLSgZWDYQLiAaADYlAB8..."]
```

Why base64, and why an array rather than a bare string:
[FORMAT.md § Transport](FORMAT.md#transport).

`choose_block_log2` picks the grouping per zoom, aiming at `SOFT_BLOCK_TARGET`
(24 KB) per block and staying under `MAX_BLOCK_BYTES` (60 KB, because tile
offsets in the directory are `u16`). When a block still overflows,
`_shrink_block` drops its least important layer and re-encodes.

## Generated output

**`source/generated/MapIndex.mc`** — pack metadata as constants, plus a
generated `switch` that maps a block coordinate to a resource id:

```monkeyc
const BLOCK_ORIGIN_X = [250, 1002, 4011];   // per data zoom
const KEY_SHIFT = 10;

function blockResource(z, blockX, blockY) {
    var rx = blockX - BLOCK_ORIGIN_X[slot];   // relative to the pack's origin
    var ry = blockY - BLOCK_ORIGIN_Y[slot];
    var key = (rx << KEY_SHIFT) | ry;
    ...
    case 1024: return Rez.JsonData.b14_1003_772;
}
```

Coordinates are stored relative to the pack origin so the keys stay small, and a
`switch` rather than a dictionary so no heap is spent on a lookup table.

**Neither generated artefact is hand-editable.** CI runs `make demo` and fails on
any diff against what is committed.

## Budgets

`cli.py:report` prints these and warns. They are not advisory — they are the
difference between an app that installs and one that does not.

| Budget | Default | Ceiling | Warns at |
|---|---|---|---|
| jsonData resources | `--resource-budget 200` | ~255 (Connect IQ) | 250 |
| In-app size (base64) | — | 15 MB (store rejects `.iq` above) | 12 MB |
| Points per tile | `--max-points-per-tile 1100` | — | >25% dropped |
| Block bytes | `SOFT_BLOCK_TARGET` 24 KB | `MAX_BLOCK_BYTES` 60 KB | — |
| Features per layer | — | `MAX_FEATURES_PER_LAYER` 255 (`u8` count) | — |

### How much area fits

Rough numbers at the defaults (zooms 12/14/16, roads + water + green, no
buildings). Estimates, except the measured row:

| Area | In-app size | jsonData ids |
|---|---|---|
| 10 × 10 km, a town | ~0.4 MB | ~20 |
| 30 × 30 km, a city and surroundings | ~3 MB | ~70 |
| 60 × 60 km, a metro region | ~11 MB | ~200 |
| **13 × 10 km, central Berlin** *(measured)* | **3.21 MB** | **187** |

The measured row is the one to trust, and it says **density beats area**. Berlin
inside the Ringbahn is a fraction of the 30 × 30 km row's area and still costs
more ids than it predicts, because the resource budget is spent on tiles that
have something in them, not on ground covered. A dense city and an equal area of
farmland are not comparable packs.

At `SIMPLIFY=2.0 --max-points-per-tile 700` that same Berlin box drops to 2.73 MB
and 106 ids. Which is the other lesson: the knobs above move real numbers.

Note that fitting the budgets is necessary, not sufficient. The renderer's own
per-pass segment caps decide how much of a pack is actually *drawn* on screen —
see [RENDERING.md](RENDERING.md) — and a pack can sit comfortably inside every
budget here and still truncate at render time.

Knobs, in the order to reach for them:

```bash
ZOOMS=12,14                        # drop the top zoom: ~4x smaller
SIMPLIFY=2.0                       # coarser geometry
EXTRA="--max-points-per-tile 700"  # thins dense tiles, redraws faster
EXTRA="--buildings"                # adds footprints: expensive, rarely worth it
```

Shrinking the bbox beats all of them.

## The two mirrors

Neither is optional, and neither is a place to be clever.

**`decode.py`** is a line-by-line mirror of `source/TileReader.mc`. It exists so
`tests/contract/test_tile_format.py` can prove the writer's output is what the watch
parser expects — the watch parser being the one thing CI cannot execute. Keep the
correspondence even where idiomatic Python would be shorter.

**`preview.py`** re-implements `source/MapRenderer.mc`: same projection, same
tile lookup, same two-pass draw order, same pen widths, and the palette scraped
live out of `source/Palette.mc`. It reads the *generated* artefacts, so if the
preview looks right, the watch maths is right.

```bash
cd tools/mappack && python3 -m mappack.preview --zoom 16 --out preview.png
```

Change draw order or projection on one side and it changes on the other, or the
preview stops being evidence of anything.

## Overpass etiquette

`osmread.py` sends a `User-Agent` identifying the project and queries only the
tags `classify.py` can use (`OVERPASS_FILTERS`). Anything bigger than a city
should come from a [Geofabrik](https://download.geofabrik.de/) extract instead —
do not point a regional bbox at a free public API. Use `--cache foo.osm` when
iterating on the same area so it is fetched once.
