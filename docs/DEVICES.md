# Device notes

Numbers here are from Garmin's own device reference and developer forums, not
from guesswork. They are the constraints the app is designed around; if you port
it to another watch, re-check them for that model first.

## Venu 3 / Venu 3S

| | Venu 3 | Venu 3S |
|---|---|---|
| Screen | 454 × 454 AMOLED, round, touch | 390 × 390 AMOLED, round, touch |
| Connect IQ API | 5.2 | 5.2 |
| **Watch-app memory** | **786,432 B (768 KB)** | **786,432 B (768 KB)** |
| Data field memory | 262,144 B | 262,144 B |
| Glance memory | 65,536 B | 65,536 B |
| Keys exposed to CIQ | `enter`, `menu`, `esc` | same |
| Launcher icon | 70 × 70 | 70 × 70 |

Sources:
[Venu 3 device reference](https://developer.garmin.com/connect-iq/articles/device-reference/venu3.html) ·
[Venu 3S device reference](https://developer.garmin.com/connect-iq/articles/device-reference/venu3s.html)

Watch-app memory is the ceiling for code **and** data that is resident at once.
Resources sit at the end of the `.prg` and are not RAM-resident until loaded,
which is exactly why the map lives in `jsonData` resources.

## What is not available here

- **`WatchUi.MapView`** — Garmin's own map widget. Its supported-device list
  covers Edge, fēnix 5 Plus and up, epix, Forerunner 945/955/965/970 and Venu
  X1. Venu 3 and 3S are absent; these watches ship no onboard cartography.
  [docs](https://developer.garmin.com/connect-iq/api-docs/Toybox/WatchUi/MapView.html)
- **Any filesystem API.** There is no File or IO module in Toybox at all, so an
  app cannot read files you copy onto the watch over USB.
  [module index](https://developer.garmin.com/connect-iq/api-docs/)
- **Course or route geometry.** `PersistedContent.Route` exposes only
  `getId`, `getName`, `remove` and `toIntent` — you can hand a route to the
  system, but you cannot read its coordinates.
  [docs](https://developer.garmin.com/connect-iq/api-docs/Toybox/PersistedContent/Route.html)
- **Pinch-zoom or any multi-touch.** `WatchUi` has no pinch events. Zoom is on
  on-screen buttons and the physical keys.

## Storage, and why the map is not in it

`Application.Storage` is documented two different ways by Garmin: the API
reference says values are capped at 32 KB with a device-dependent total, while
the Core Topics guide says 8 KB per value and 128 KB in total. Plan for the
smaller pair.

There is also a sharp edge worth knowing: `setValue` needs far more transient
free heap than the payload. A developer measured a 90 KB object needing roughly
**400 KB of free RAM** to store successfully — the relationship is not linear.
[thread](https://forums.garmin.com/developer/connect-iq/f/discussion/412304/memory-requirements-when-storing-json-from-glance)

So `Settings.mc` keeps Storage to a handful of scalars: theme, orientation,
zoom, last centre, and the pack name that centre belongs to.

## jsonData resources

This is the vehicle the map data actually uses, and Garmin designed it for
exactly this: *"JSON data resources can store relatively large amounts of data
in your app without having to keep it in memory at all times"*, loaded *"on
demand at runtime"*.
[docs](https://developer.garmin.com/connect-iq/articles/core-topics/Resources.html)

Two limits, both empirical rather than documented:

- **Resource ids run out near 255 per type.** Garmin staff confirmed the
  255-field limit for strings (the id field is a byte); developers packing large
  JSON data sets have hit the same ceiling. The packer's `--resource-budget`
  defaults to 200 to leave headroom.
- **A VM bug around repeated load/unload.** One report describes a crash after
  roughly 640 KB cumulatively loaded and released — *"loading and unloading 10
  times a JSON resource of 64 kBytes will crash on the 10th time"*. Garmin
  replied that they had identified it. `TileStore` mitigates by caching
  aggressively and keeping blocks small (24 KB target), but if you see crashes
  after long panning sessions, this is the first thing to suspect.
  [bug report](https://forums.garmin.com/developer/connect-iq/i/bug-reports/loading-unloading-large-json-resources-leads-to-vm-crash-over-time)

## Graphics

Everything the renderer uses is at or below API 5.2, so it is all available:

| API | Level |
|---|---|
| `Graphics.createBufferedBitmap`, `BufferedBitmapReference` | 4.0.0 |
| `Dc.drawBitmap2` with `:transform` | 4.2.1 |
| `Graphics.AffineTransform` | 4.2.0 |
| `Dc.setClip` / `clearClip` | 2.3.0 |
| `Dc.fillPolygon` | 1.0.0 |
| `Dc.setAntiAlias` | 3.2.0 |
| `WatchUi.InputDelegate.onDrag` with `DRAG_TYPE_CONTINUE` | 3.3.0 |

Note there is **no `drawPolygon`** — only `fillPolygon`. Outlines have to be
stroked segment by segment.

### Two real-device gotchas

- A developer reported that after four or five `drawBitmap2` calls combining
  tint **and** rotation on full-screen 454 × 454 bitmaps, the Venu 3 threw
  `System Error, Failed invoking <Symbol>`, while the simulator was fine.
  [thread](https://forums.garmin.com/developer/connect-iq/f/discussion/354206/are-there-drawbitmap2-tint-rotate-limitations-on-devices)
  This is why heading-up rotates the *geometry* while rendering rather than
  rotating a finished bitmap — it avoids the risky path entirely, and avoids
  needing an oversized buffer.
- Primitive drawing is slow. One measurement put the practical ceiling around
  100 `setColor` + `drawPixel` pairs per frame on a fēnix 7 watch face, and
  Garmin's own performance blog acknowledges 700 ms single-screen draws as a
  realistic bad case. The watchdog fires at about 5 seconds.
  `MapRenderer.MAX_SEGMENTS` caps a render at 2600 primitives; if renders come
  out slow on hardware, lower `--max-points-per-tile` when packing before
  touching the renderer.

## Adding another device

1. Add `<iq:product id="..."/>` to `manifest.xml`.
2. Look up its watch-app memory on
   [the compatible devices list](https://developer.garmin.com/connect-iq/compatible-devices/)
   and its device-reference page. Below ~500 KB, expect the off-screen buffer to
   be tight — the renderer already falls back to drawing straight to the screen,
   which flickers while panning but does not crash.
3. If the device is not touch-capable, zoom still works on `KEY_UP`/`KEY_DOWN`,
   but panning needs a key-based scheme that does not exist yet.
4. Build it: `make build DEVICE=<id>`.

Likely-easy candidates, same API family, round and touch:
`vivoactive5`, `venu2`, `venu2s`, `venu2plus`, `fr165`, `fr265`, `fr965`.
