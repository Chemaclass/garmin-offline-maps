# Documentation

Every fact lives on exactly one page. If you need it somewhere else, link — do
not copy. That rule is why these pages stay short.

| Page | Owns |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | The whole system: both halves, module map, startup, frame loop, data path |
| [RENDERING.md](RENDERING.md) | Watch-side drawing, the buffer, segment caps, the tile cache, interaction |
| [PACKER.md](PACKER.md) | `tools/mappack`: pipeline, blocks, budgets, the two mirrors |
| [FORMAT.md](FORMAT.md) | The byte spec three implementations answer to |
| [DEVICES.md](DEVICES.md) | Hardware limits and API availability, **with sources** |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Toolchain, build, tests, conventions, CI |

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

Break these and nothing shouts until much later.

1. **The byte format has three implementations** — `pack.py` (writer),
   `decode.py` (reference reader), `TileReader.mc` (on-watch reader). They must
   agree byte for byte. `decode.py` is a deliberate line-by-line mirror of the
   Monkey C, because the watch parser is the one thing CI cannot execute.
2. **Layer ids 0–9 are shared across languages** — `classify.py`'s `L_*`
   constants are array indices into `Palette.mc`, which `preview.py` also
   *parses* at runtime.
3. **`mapdata/active/**` and `source/generated/MapIndex.mc` are generated** —
   never hand-edited. CI runs `make demo` and fails on any diff.

`tests/contract/` guards 1 and 2; the `make demo` diff guards 3. A failure there
means "go edit the other side", not "fix this code".

## Status

The packer, the format and the rendering maths are covered by the test suite and
by a Python re-implementation of the renderer. The Monkey C has **not** been through
`monkeyc` yet — budget one round of compile fixes on the first build.
