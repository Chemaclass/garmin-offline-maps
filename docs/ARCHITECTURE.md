# Architecture

Two halves that meet at a byte format and a generated file.

| Half | Path | Language | Runs on | Tested by |
|---|---|---|---|---|
| Packer | `tools/mappack/` | Python 3.9+, stdlib only | your machine, CI | `make test` |
| Watch app | `source/` | Monkey C | the watch | the simulator, and `preview.py` by proxy |

They meet at:

- **`mapdata/active/blocks/*.json`**: the map data, as Connect IQ resources
- **`source/generated/MapIndex.mc`**: generated Monkey C that maps a tile
  coordinate to a resource id
- **[FORMAT.md](FORMAT.md)**: the byte contract both sides implement

A map reaches the watch one of two ways, and the app treats them the same
through `Pack.mc`:

- **Built in.** The packer's output is compiled into the `.prg` as jsonData
  resources. No network at any point.
- **Downloaded.** A city is fetched once over the phone from the published
  catalogue and kept in `Application.Storage`. See [CITIES.md](CITIES.md).

Drawing never touches the network either way. `Communications` appears in
exactly two files, both of which only run when the user picks a city.

## Watch-side modules

Roughly in dependency order.

No line counts here on purpose: they went stale on almost every row within a
week and a number nobody trusts is worse than no number.

| File | Responsibility |
|---|---|
| `OfflineMapsApp.mc` | `AppBase`. Wires everything, owns the compass timer and the city download |
| `Camera.mc` | Where we are looking: centre, zoom, orientation, follow |
| `Mercator.mc` | Spherical Web Mercator (EPSG:3857) in slippy-map pixel space |
| `Pack.mc` | The active map, built-in or downloaded. Every other module asks this, not `MapIndex` |
| `MapIndex.mc` *(generated)* | The built-in pack: metadata and tile coordinate → `Rez.JsonData.*` |
| `CityStore.mc` | A downloaded city in `Application.Storage`, one base64 block per value |
| `CityDownloader.mc` | Fetches a city, one block per request, strictly sequential |
| `CityPicker.mc` | Country then city, from the published catalogue |
| `CityList.mc` *(generated)* | Maps the phone dropdown's index back to a catalogue slug |
| `DownloadView.mc` | Download progress, and Back to cancel |
| `TileStore.mc` | Loads blocks through `Pack`, byte-budgeted LRU cache |
| `TileReader.mc` | Cursor over one block's bytes. Mirror of `decode.py` |
| `MapRenderer.mc` | Decodes tiles straight into draw calls, two passes |
| `MapView.mc` | Off-screen buffer, drag handling, overlay chrome |
| `MapDelegate.mc` | Touch and key input |
| `MapMenu.mc` | Menu2, plus the About screen that carries attribution |
| `Onboarding.mc` | First-run card explaining the built-in map is a sample |
| `Palette.mc` | 16 colours, pen widths. Shared contract with `classify.py` |
| `LocationTracker.mc` | GPS fixes and heading |
| `Settings.mc` | A handful of scalars in `Application.Storage` |
| `Diag.mc` | The last failure, so the watch can show it |

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
(`0.087` rad). The map cannot usefully redraw faster than that.

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
        ├── Pack.hasBlock(z, bx, by)           built-in or downloaded, same answer
        ├── evictFor(RESERVE_BYTES)            make room *before* loading
        ├── Pack.blockBase64(z, bx, by)        loadResource, or a Storage value
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
| `geocode.py` | | Place name → centre, via Nominatim |
| `citypack.py` | | Downloadable city packs and the catalogue |
| `publish.py` | | Builds the whole catalogue from `cities.txt` |
| `serve.py` | | Drives the preview renderer in a browser |

Full pipeline in [PACKER.md](PACKER.md).

## Why it is shaped like this

Four measured platform limits, not preferences. The numbers and their sources
live in [DEVICES.md](DEVICES.md); what each one forced:

| Limit | Consequence in this codebase |
|---|---|
| Watch-app RAM | `TileStore` evicts by **byte budget**, not entry count |
| `Application.Storage` size, and its transient-heap cost | A downloaded city has to fit ~128 KB at 8 KB per value, which is why it is an orientation map rather than a street map |
| No filesystem API | Tiles cannot be side-loaded over USB. They are compiled in, or they live in Storage |
| Companion BLE throughput | A city is fetched once, one small block per request. Streaming a map per frame is not viable |

Plus one performance reality: every drawing call is interpreted, and a full
redraw has to stay well under a second to feel responsive. The watchdog itself
only fires around 5 s, so this is a usability ceiling, not a crash ceiling.
Hence the off-screen buffer, the hard segment caps in [RENDERING.md](RENDERING.md),
and decoding geometry straight into draw calls with no intermediate feature
objects. Allocation is the other thing that hurts on this heap.

## What is deliberately absent

- **No protobuf / MVT**: there is no protobuf decoder on Connect IQ; the
  reasoning is in [FORMAT.md](FORMAT.md).
- **No tags, strings, or feature ids in the format.** Layer id and geometry only.
- **No labels.** Text needs a layer the format does not have yet, on the roadmap.
- **No streaming.** A city is downloaded once, deliberately, and then the
  network is never touched again. Drawing a map that needs a phone in range is
  the thing this app exists not to be.
