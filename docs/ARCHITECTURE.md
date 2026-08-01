# Architecture

Two halves that meet at a byte format and a generated file.

| Half | Path | Language | Runs on | Tested by |
|---|---|---|---|---|
| Packer | `tools/mappack/` | Python 3.9+, stdlib only | your machine, CI | `make test` |
| Watch app | `source/` | Monkey C | the watch | the simulator, and `preview.py` by proxy |

They meet at:

- **`mapdata/active/blocks/*.json`** — the map data, as Connect IQ resources
- **`source/generated/MapIndex.mc`** — generated Monkey C that maps a tile
  coordinate to a resource id
- **[FORMAT.md](FORMAT.md)** — the byte contract both sides implement

Everything below the packer's output is compiled into the `.prg`. There is no
runtime data path: no network, no filesystem, no companion app.

## Watch-side modules

Roughly in dependency order. Sizes are a hint at where the complexity sits.

| File | Lines | Responsibility |
|---|---|---|
| `OfflineMapsApp.mc` | 76 | `AppBase`. Wires everything, owns the compass timer |
| `Camera.mc` | 109 | Where we are looking: centre, zoom, orientation, follow |
| `Mercator.mc` | 64 | Spherical Web Mercator (EPSG:3857) in slippy-map pixel space |
| `MapIndex.mc` *(generated)* | 86 | Pack metadata + tile coordinate → `Rez.JsonData.*` |
| `TileStore.mc` | 148 | Loads blocks from resources, byte-budgeted LRU cache |
| `TileReader.mc` | 115 | Cursor over one block's bytes. Mirror of `decode.py` |
| `MapRenderer.mc` | 256 | Decodes tiles straight into draw calls, two passes |
| `MapView.mc` | 387 | Off-screen buffer, drag handling, overlay chrome |
| `MapDelegate.mc` | 113 | Touch and key input |
| `MapMenu.mc` | 117 | Menu2, plus the About screen that carries attribution |
| `Palette.mc` | 97 | 16 colours, pen widths. Shared contract with `classify.py` |
| `LocationTracker.mc` | 114 | GPS fixes and heading |
| `Settings.mc` | 62 | Six scalars in `Application.Storage` |

### Startup sequence

```
OfflineMapsApp.onStart
  ├── new Camera()              centre = MapIndex.CENTER_*, zoom = middle data zoom
  ├── Settings.load(camera)     restores centre only if the stored pack name matches
  ├── new TileStore(null)       default 90 KB byte budget
  └── new LocationTracker(onFix)

OfflineMapsApp.getInitialView
  ├── new MapView(camera, store, tracker)
  ├── tracker.start()           Position.LOCATION_CONTINUOUS
  ├── Timer(1000 ms) -> onTick  compass poll, only while headingUp
  └── returns [view, new MapDelegate(...)]
```

`onFix` recentres the camera only when `camera.follow` is set. `onTick` polls
the magnetometer and repaints only when the heading moved more than ~5°
(`0.087` rad) — the map cannot usefully redraw faster than that.

### The frame loop

This is the single most important thing to understand about the watch side.

```
camera changes  ──>  _dirty = true
                          │
onUpdate ─────────────────┤
                          ├── _dirty?  render into the BufferedBitmap  (expensive, once)
                          └── blit the bitmap at (_dragX, _dragY)      (cheap, every frame)
                                    │
                                    └── drawOverlay: marker, buttons, scale bar, status
```

While a finger is down, `_dragX/_dragY` move and the **same** buffer is blitted
at an offset. The re-render happens on release, in `endDrag`. That is what makes
panning feel smooth on a device where every `drawLine` is an interpreted call.

Details and the fallback paths are in [RENDERING.md](RENDERING.md).

### Data path for one tile

```
MapRenderer.drawTile(tileX, tileY)
  └── TileStore.block(zoom, tileX >> log2, tileY >> log2)
        ├── linear scan of the cache (a handful of entries)
        ├── MapIndex.blockResource(z, bx, by)  -> Rez.JsonData.bZZ_X_Y  or null
        ├── evictFor(RESERVE_BYTES)            make room *before* loading
        ├── Application.loadResource(...)      -> ["base64..."]
        └── StringUtil.convertEncodedString    -> ByteArray, cached
  └── TileStore.tileOffset(block, tileX, tileY, log2)   -> byte offset or -1
  └── new TileReader(block, offset)            -> u8/u16/uvarint/svarint cursor
```

`null` block means nothing was packed there. `-1` offset means the block exists
but that tile is empty (open water, say). Both are normal, not errors.

## Packer-side modules

| File | Lines | Responsibility |
|---|---|---|
| `cli.py` | 161 | Argument parsing and the size report |
| `osmread.py` | 196 | Overpass or `.osm`/`.pbf` → flat list of tagged ways |
| `classify.py` | 165 | OSM tags → layer id 0–9 + minimum zoom |
| `geom.py` | 233 | Projection, Douglas–Peucker, Cohen–Sutherland, Sutherland–Hodgman |
| `pack.py` | 413 | Tiles, encodes, groups tiles into blocks |
| `varint.py` | 87 | LEB128 + zigzag primitives |
| `emit.py` | 207 | base64 JSON resources, `mapdata.xml`, `MapIndex.mc` |
| `decode.py` | 95 | Reference reader. Mirror of `TileReader.mc` |
| `preview.py` | 292 | Re-implementation of `MapRenderer.mc` that renders PNGs |

Full pipeline in [PACKER.md](PACKER.md).

## Why it is shaped like this

Four measured platform limits, not preferences. The numbers and their sources
live in [DEVICES.md](DEVICES.md); what each one forced:

| Limit | Consequence in this codebase |
|---|---|
| Watch-app RAM | `TileStore` evicts by **byte budget**, not entry count |
| `Application.Storage` size, and its transient-heap cost | Only six scalars persist; map data never goes there |
| No filesystem API | Tiles cannot be side-loaded over USB — they are compiled in |
| Companion BLE throughput | Streaming a map from the phone is not viable either |

Plus one performance reality: every drawing call is interpreted, and a full
redraw has to stay well under a second to feel responsive — the watchdog itself
only fires around 5 s, so this is a usability ceiling, not a crash ceiling.
Hence the off-screen buffer, the hard segment caps in [RENDERING.md](RENDERING.md),
and decoding geometry straight into draw calls with no intermediate feature
objects. Allocation is the other thing that hurts on this heap.

## What is deliberately absent

- **No protobuf / MVT** — there is no protobuf decoder on Connect IQ; the
  reasoning is in [FORMAT.md](FORMAT.md).
- **No tags, strings, or feature ids in the format.** Layer id and geometry only.
- **No labels.** Text needs a layer the format does not have yet — on the roadmap.
- **No runtime data loading of any kind.** The absence is the product.
