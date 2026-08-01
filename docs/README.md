# Documentation

Start here. Each document has one job.

| Document | Read it when |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | You want the whole system in one pass — both halves, every module, the runtime sequence |
| [RENDERING.md](RENDERING.md) | You are touching the watch-side drawing, panning, or memory behaviour |
| [PACKER.md](PACKER.md) | You are touching `tools/mappack` — OSM in, resources out |
| [FORMAT.md](FORMAT.md) | You are touching bytes. This is the spec three implementations answer to |
| [DEVICES.md](DEVICES.md) | You are adding a device or worried about memory |
| [DEVELOPMENT.md](DEVELOPMENT.md) | You want to build, test, or change something without breaking CI |

## The 30-second version

OpenStreetMap data is quantised into binary vector tiles by a Python packer,
base64'd into Connect IQ `jsonData` resources, and **compiled into the app**.
The watch decodes tiles straight into draw calls, once, into an off-screen
bitmap. No phone, no network, no tile server, at any point.

```
tools/mappack/  (Python, testable)        source/  (Monkey C, needs the SDK)
─────────────────────────────────         ────────────────────────────────
OSM ways                                  MapIndex.mc ──> TileStore ──> TileReader
   │ classify, project, simplify, clip        (generated)     (LRU)      (cursor)
   │ delta+zigzag varints                                                    │
   │ group tiles into blocks                                            MapRenderer
   ▼                                                                        │
mapdata/active/blocks/*.json  ────────────────────────────────────────> MapView
source/generated/MapIndex.mc                                          (BufferedBitmap)
```

## Three invariants

Break these and nothing shouts until much later. Full detail in each document.

1. **The byte format has three implementations** — `pack.py` (writer),
   `decode.py` (reference reader), `TileReader.mc` (on-watch reader). They must
   agree byte for byte. `decode.py` is a deliberate line-by-line mirror of the
   Monkey C, because the watch parser is the one thing CI cannot execute.
2. **Layer ids 0–9 are shared across languages** — `classify.py`'s `L_*`
   constants are array indices into `Palette.mc`. `preview.py` also *parses*
   `Palette.mc` at runtime.
3. **`mapdata/active/**` and `source/generated/MapIndex.mc` are generated** —
   never hand-edited. CI runs `make demo` and fails on any diff.

## Status

The packer, the format and the rendering maths are covered by 67 tests and by a
Python re-implementation of the renderer. The Monkey C has **not** been through
`monkeyc` yet — budget one round of compile fixes on first build.
