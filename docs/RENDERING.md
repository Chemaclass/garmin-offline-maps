# Rendering on the watch

Everything here is shaped by a 768 KB heap and by every drawing call being
interpreted. Hardware numbers and their sources: [DEVICES.md](DEVICES.md).

On timing, be precise about which ceiling is which, and about its units.

The **watchdog** counts interpreted instructions, not milliseconds, and kills
the app. A busy loop dies after ~12,000 iterations and 10 ms; a render frame
doing draw calls survives 80 ms, because a `drawLine` is one instruction
however long it paints. Measurement and consequences in
[DEVICES.md](DEVICES.md). This *is* a ceiling you will hit: a dense tile
decodes enough varints to reach it, which is why `TILE_POINT_CAP` bounds a
tile in points rather than in time.

**Responsiveness** is the other ceiling and the softer one. A full redraw
taking a few hundred milliseconds makes the map feel like a slideshow long
before anything is killed. `FRAME_BUDGET_MS` targets this one.

## Render once, blit many

`MapView` owns an off-screen `BufferedBitmap`. The expensive work, decoding
tiles and drawing thousands of segments, runs **only** when `_dirty` is set.

```
camera change (zoom, pan release, GPS recentre, heading step, theme)
      └── _dirty = true

onUpdate
   ├── _dirty ? _renderer.render(bitmap.getDc(), camera, store) : skip
   ├── dc.drawBitmap(_dragX, _dragY, bitmap)
   └── drawOverlay(dc)          marker, buttons, scale bar, status, debug
```

While dragging, `_dragX/_dragY` change and the **same** buffer is blitted at an
offset, no re-render. `endDrag` clears the offset, applies
`camera.panPixels(dx, dy)` and sets `_dirty`.

`endDrag` clears the offset *before* checking `_dragging`, on purpose: a STOP
without a matching START, which happens when a drag begins over a view that is
then popped, would otherwise leave the buffer blitted at a stale offset forever.

## Why 16 colours

Sixteen entries *would* keep a paletted `BufferedBitmap` at 4 bits per pixel:

| Screen | 4 bpp (paletted) | 8 bpp (what we use) |
|---|---|---|
| 454 × 454 (Venu 3) | ~103 KB | ~206 KB |
| 390 × 390 (Venu 3S) | ~76 KB | ~152 KB |

We pay the right-hand column, because a paletted buffer cannot be drawn to at
all; see [below](#why-the-buffer-is-not-paletted). Out of 768 KB of watch-app
memory, which holds code *and* resident data, that is a real cost.

The 16-colour limit still governs everything drawn, because `Palette.mc` is the
app's colour vocabulary and slots 0–9 are a cross-language contract. It is no
longer what sets the buffer's bit depth.

Slots 0–9 are the render layers and must line up index-for-index with
`classify.py`'s `L_*` constants. Slots 10–15 are chrome: background, text, dim,
position, panel, accent.

Switching the theme is a repaint. It used to rebuild the buffer, because a
paletted one bakes its colours in at creation, but the buffer carries no
palette any more: see [why the buffer is not paletted](#why-the-buffer-is-not-paletted).

## Degrading instead of crashing

Three separate failure paths, all handled:

| Failure | Where | Response |
|---|---|---|
| Buffer will not allocate | `createBuffer` | `_useBuffer = false`, draw straight to the screen |
| Reference returns null | `bufferBitmap` | System reclaimed it in the background, rebuild once |
| `OutOfGraphicsMemoryException` | `bufferBitmap`, `onUpdate` | Drop the buffer, fall back permanently |

Direct drawing is slower and flickers while panning, but it works. This is what
lets a tighter device run the app at all; see [DEVICES.md](DEVICES.md) before
adding one.

Note the exception is thrown by the *reference accessors*, not by
`createBufferedBitmap`, which is why the `try` sits where it does.

### Why the buffer is not paletted

It used to be. On the first simulator run it threw on every frame:

```
MapView: buffered draw failed, drawing direct:
Anti aliased primitives cannot be drawn to a paletted buffer
```

The buffer allocated fine and the reference resolved; the throw came from the
draw calls. `dc.setAntiAlias(false)` did not help, and it still threw with the
`fillPolygon` pass skipped entirely, so `drawLine` above pen width 1 is
anti-aliased too. **Every primitive `MapRenderer` draws is rejected by a
paletted target.** The buffer was therefore allocated and never used: the app
was direct-drawing every frame, the opposite of the design above.

`:palette` is now omitted from `createBufferedBitmap`, which costs 8 bpp
instead of 4: the right-hand column of the table above. That is the price of
having the buffered path work at all.

**This makes the memory budget tighter, not looser.** ~206 KB on a Venu 3 out
of 768 KB that also holds code and resident data. If a device cannot afford it,
`createBuffer` fails and the direct-draw fallback takes over, which is what
that path is for. Re-check [DEVICES.md](DEVICES.md) before adding a model.

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
appears. When a pass hits its budget it stops and sets `_passTruncated`.

Three more things worth knowing about the inner loop:

- **Geometry is decoded straight into draw calls.** No intermediate feature
  objects, allocation is the other thing that hurts on this heap.
- **Layer ids ascend**, so the area pass can `return` as soon as it sees the
  first stroke layer, and `layerBytes` lets either pass skip a layer it does not
  want without decoding it.
- **Unknown layer ids are skipped, not fatal**: a pack built by a newer packer
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

`scale` is `2^(displayZoom - dataZoom)`: `MapIndex.dataZoomFor()` picks the
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
  dictionary of objects, fewer allocations, and the cache holds a handful of
  entries so a linear scan is free.
- `removeAt` rebuilds the array by position because `Array.remove()` deletes by
  *value*, which is wrong the moment two blocks share a zoom or an index.

## Interaction

`MapDelegate` extends `InputDelegate`, **not** `BehaviorDelegate`: a
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
`MapView.onHide()` and `AppBase.onStop()`: **not** on every zoom press, which
repeats.

On load, the stored centre is restored only when the stored pack name matches
`MapIndex.PACK_NAME`. Otherwise you would reopen the app pointed at a city that
is no longer compiled in.
