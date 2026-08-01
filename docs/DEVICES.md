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

## Supported devices

Twenty-four products, all of which compile. Venu 3 and 3S remain the design
target — the numbers above are theirs — and everything else is the same code at
a different screen size.

| Family | Products |
|---|---|
| Venu | `venu2` `venu2plus` `venu2s` `venu3` `venu3s` `venu441mm` `venu445mm` `venux1` |
| Venu Sq | `venusq2` `venusq2m` |
| vívoactive | `vivoactive5` `vivoactive6` |
| Forerunner | `fr165` `fr165m` `fr170` `fr170m` `fr265` `fr265s` `fr57042mm` `fr57047mm` `fr70` `fr955` `fr965` `fr970` |

Screens run from 320 × 360 (Venu Sq 2) to 454 × 454, plus the 448 × 486
rectangle of the Venu X1. All have 786,432 B of watch-app memory — the same
budget the app was written against — so the tile cache and the off-screen buffer
need no per-device tuning.

### Two gates, and neither is GPS

The map works with no position fix at all; you pan it by hand and GPS only feeds
*follow me*. What actually decides support:

1. **A touchscreen.** Panning is drag-only. Zoom survives on `KEY_UP`/`KEY_DOWN`,
   but a watch you cannot pan is not a map, and a key-based pan scheme does not
   exist yet.
2. **API level ≥ 4.0.0**, which is `Graphics.createBufferedBitmap`. That is the
   real floor and it is what `manifest.xml` now declares. It used to say 4.2.1,
   for a `Dc.drawBitmap2` + `AffineTransform` path the renderer no longer has.

### What that leaves out

- **No touchscreen** — `fr55`, `fr230`, `fr235`, `fr245`, `fr245m`, `fr255`,
  `fr255m`, `fr255s`, `fr255sm`, `fr645`, `fr645m`, `fr735xt`, `fr745`,
  `fr920xt`, `fr935`, `fr945`, `fr945lte`. Nothing else disqualifies most of
  these; they are waiting on key-based panning.
- **API 3.x** — `venu` (Venu 1), `venud`, `venusqm` (Venu Sq Music),
  `vivoactive3m`, `vivoactive3mlte`, `vivoactive4`, `vivoactive4s`, `d2air`.
  All touch, all with **1 MB** of watch-app memory — more than the Venu 3 has.
  Only `createBufferedBitmap` stands in the way, and `MapView.createBuffer`
  already degrades to direct drawing when the buffer is unavailable. Guarding
  it with `Graphics has :createBufferedBitmap` and dropping `minApiLevel` to
  3.3.0 would bring back Venu 1, Venu Sq Music and vívoactive 4 / 4S, at the
  cost of a flickering pan on those models.
- **Too little memory whatever else is true** — `venusq` (Venu Sq, 128 KB),
  `vivoactive3`, `vivoactive3d`, `vivoactive_hr` (128 KB), `vivoactive`,
  `fr630` (64 KB). `TileStore`'s cache budget alone is 90 KB.
- **Lily** — Garmin ships no Connect IQ watch-app support for it; there is no
  Lily device definition in the SDK at all.

Outside the families this app targets, another ~30 touch devices clear both
gates today — the fēnix 7/8, epix, Edge, Descent, Approach S70 and MARQ lines.
They are omitted only because nobody has asked; the code has nothing model
specific in it.

## Adding another device

1. Check it against the two gates above. The device definition is the source of
   truth, not the marketing page — the compatible-devices table lists vívoactive
   3 and 4 as non-touch, and the SDK says otherwise:

   ```bash
   connect-iq-sdk-manager device download --download-all
   # ~/.Garmin/ConnectIQ/Devices/<id>/compiler.json  -> appTypes[].memoryLimit,
   #     resolution, deviceGroup (API level), launcherIcon
   # ~/.Garmin/ConnectIQ/Devices/<id>/simulator.json -> display.isTouch
   ```

2. Add `<iq:product id="..."/>` to `manifest.xml`. CI reads its build list from
   that file, so there is nothing to update in the workflow.
3. If its `launcherIcon` size is not one of the folders `monkey.jungle` already
   wires up, add one — otherwise the build warns and the icon is scaled.
4. Build it: `make build DEVICE=<id>`.
5. Only if the screen is much larger than 454 × 454: a bigger viewport shows
   more tiles at once, raising peak `TileStore` residency. Preview at the new
   size first (`python3 -m mappack.preview --size <px> --zoom 16 --out p.png`).
