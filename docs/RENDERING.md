# Rendering on the watch

Everything here is shaped by two numbers: **768 KB** of heap and **~0.5 s** per
frame before the watchdog complains. Every drawing call is interpreted.

## Render once, blit many

`MapView` owns an off-screen `BufferedBitmap`. The expensive work — decoding
tiles and drawing thousands of segments — runs **only** when `_dirty` is set.

```
camera change (zoom, pan release, GPS recentre, heading step, theme)
      └── _dirty = true

onUpdate
   ├── _dirty ? _renderer.render(bitmap.getDc(), camera, store) : skip
   ├── dc.drawBitmap(_dragX, _dragY, bitmap)
   └── drawOverlay(dc)          marker, buttons, scale bar, status, debug
```

While dragging, `_dragX/_dragY` change and the **same** buffer is blitted at an
offset — no re-render. `endDrag` clears the offset, applies
`camera.panPixels(dx, dy)` and sets `_dirty`.

`endDrag` clears the offset *before* checking `_dragging`, on purpose: a STOP
without a matching START — which happens when a drag begins over a view that is
then popped — would otherwise leave the buffer blitted at a stale offset forever.

## Why 16 colours

A `BufferedBitmap` is created with a fixed palette. Sixteen entries keeps it at
4 bits per pixel where the device supports it:

| Screen | 4 bpp | 8 bpp |
|---|---|---|
| 454 × 454 (Venu 3) | ~103 KB | ~206 KB |
| 390 × 390 (Venu 3S) | ~76 KB | ~152 KB |

Out of 768 KB, that is the difference between comfortable and not. **Adding a
17th colour to `Palette.mc` is a memory change, not a cosmetic one.**

Slots 0–9 are the render layers and must line up index-for-index with
`classify.py`'s `L_*` constants. Slots 10–15 are chrome: background, text, dim,
position, panel, accent.

Switching the theme calls `MapView.rebuild()` rather than just repainting — the
palette is baked into the buffer at creation.

## Degrading instead of crashing

Three separate failure paths, all handled:

| Failure | Where | Response |
|---|---|---|
| Buffer will not allocate | `createBuffer` | `_useBuffer = false`, draw straight to the screen |
| Reference returns null | `bufferBitmap` | System reclaimed it in the background — rebuild once |
| `OutOfGraphicsMemoryException` | `bufferBitmap`, `onUpdate` | Drop the buffer, fall back permanently |

Direct drawing is slower and flickers while panning, but it works. This is what
lets a tighter device run the app at all — see [DEVICES.md](DEVICES.md) before
adding one.

Note the exception is thrown by the *reference accessors*, not by
`createBufferedBitmap`, which is why the `try` sits where it does.

## Two passes, and hard caps

`MapRenderer.render` draws **all areas everywhere, then all strokes everywhere**.
One pass per tile would let a lake in one tile paint over a road in the tile next
door.

```monkeyc
const MAX_SEGMENTS = 2600;        // whole render
const AREA_SEGMENTS = 900;        // areas get their own, smaller allowance
const MAX_POLYGON_POINTS = 64;    // per polygon
```

Areas need a separate budget because they are drawn first: a city full of parks
and buildings could otherwise spend the entire frame before a single road
appears. When a pass hits its budget it stops and sets `_truncated`.

Three more things worth knowing about the inner loop:

- **Geometry is decoded straight into draw calls.** No intermediate feature
  objects — allocation is the other thing that hurts on this heap.
- **Layer ids ascend**, so the area pass can `return` as soon as it sees the
  first stroke layer, and `layerBytes` lets either pass skip a layer it does not
  want without decoding it.
- **Unknown layer ids are skipped, not fatal** — a pack built by a newer packer
  than the app still renders what the app understands.

## Tile selection under rotation

In heading-up mode the map is rotated, so the screen corners pull in geometry
from further out than the half-extents suggest. The renderer works with the
**circumscribed radius**:

```monkeyc
var radius = Math.sqrt(halfW * halfW + halfH * halfH) / scale;
```

Getting this wrong shows up as wedges of missing map at the corners when you
turn.

`scale` is `2^(displayZoom - dataZoom)` — `MapIndex.dataZoomFor()` picks the
highest packed zoom at or below the display zoom, so intermediate zooms are
rendered by scaling the nearest data zoom rather than by storing every level.

## Memory: the tile cache

`TileStore` is an LRU capped by **bytes**, not entries.

```monkeyc
const DEFAULT_BUDGET = 90000;    // total decoded block bytes held
const RESERVE_BYTES  = 36000;    // headroom freed before the next load
```

The subtlety is `evictFor(RESERVE_BYTES)` running **before** `loadResource`.
Decoding needs the base64 `String` and the resulting `ByteArray` alive at the
same time, so arriving at the load with a full cache is exactly how you get an
out-of-memory in the middle of a pan.

Two implementation notes that look odd and are not:

- Parallel arrays (`_zoom`, `_blockX`, `_blockY`, `_data`, `_used`) rather than a
  dictionary of objects — fewer allocations, and the cache holds a handful of
  entries so a linear scan is free.
- `removeAt` rebuilds the array by position because `Array.remove()` deletes by
  *value*, which is wrong the moment two blocks share a zoom or an index.

## Interaction

`MapDelegate` extends `InputDelegate`, **not** `BehaviorDelegate` — a
BehaviorDelegate turns swipes into page/back behaviours, eating exactly the
gestures panning needs.

| Input | Effect |
|---|---|
| Drag | Pan; `camera.follow` is cleared |
| Tap `+` / `−` | Zoom, clamped to `MapIndex.MIN_ZOOM`/`MAX_ZOOM` |
| Tap crosshair, or `KEY_ENTER` | Recentre on the fix; no fix → jump to pack centre |
| `KEY_UP` / `KEY_DOWN` | Zoom |
| Long press, or `KEY_MENU` | Menu |
| `KEY_ESC` | Falls through so the system closes the app |

Buttons sit on a circle (`BUTTON_ORBIT` = 0.345 of width) so they stay on-screen
on a round display; `hitTest` checks the same three angles (−38°, 38°, 142°) with
a 6 px forgiveness margin.

`camera.panPixels` un-rotates the drag delta before applying it, so panning feels
right in heading-up mode too.

## Persistence timing

`Settings.save` writes six `Application.Storage` values, and each `setValue`
transiently needs several times its payload in free heap. So saving happens in
`MapView.onHide()` and `AppBase.onStop()` — **not** on every zoom press, which
repeats.

On load, the stored centre is restored only when the stored pack name matches
`MapIndex.PACK_NAME`. Otherwise you would reopen the app pointed at a city that
is no longer compiled in.
