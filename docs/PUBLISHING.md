# Publishing to the Connect IQ store

## The published listing

Beta, first published 2026-08-02:
**https://apps.garmin.com/apps/296a0177-3634-4515-9da2-7336d5dce3c3**

Three ids are in play and they are **not** three versions of the same thing.
Confusing them is how you publish a second listing by accident.

| Id | What it is |
|---|---|
| `846d5a3e7f114f88b1387ee15adb2afd` | `manifest.xml`. The identity of the app above, the one `make package` builds and the one on the store. **Never change this.** |
| `296a0177-3634-4515-9da2-7336d5dce3c3` | Garmin's own listing UUID, visible in the store URL. Assigned by Garmin, not by us, and not settable. |
| `ffc1e2d055e342408fba8916d21ac79d` | `cities.json`'s berlin. A **different** app: the street-level Berlin listing, which has never been published. |

The third is meant to differ. A per-city listing is its own app with its own
users and ratings, so it needs its own id. It only becomes wrong if it is
changed after that listing goes live.

## One listing per city, and why

The map is **compiled into the app**. That is not a shortcut. The platform
offers no alternative, and [DEVICES.md](DEVICES.md) has the receipts: there is
no `File`, `FileSystem` or `IO` module in Toybox at all, `Application.Storage`
is ~128 KB against a 2.7 MB pack, and BLE moves under 1 KB/s.

An app *can* download a region now, into `Application.Storage`, and that is what
the main listing does: see [CITIES.md](CITIES.md). But ~128 KB buys an
orientation map, not a street map. Street-level detail is 2.7 MB for one city,
so it can only ever be compiled in.

That is the whole reason both models exist, and why deleting this one would
delete the street-level product:

| | Downloaded city | Per-city listing |
|---|---|---|
| Detail | major roads, water, rail, parks | full street network |
| Size | ~70 KB | ~2.7 MB |
| Zooms | one | three |
| Getting another | pick it on the watch | install another app |

## Adding a city

`cities.json` is the registry. Each entry owns a store listing:

```json
"berlin": {
  "app_name": "Offline Maps: Berlin",
  "pack_name": "Berlin",
  "app_id": "ffc1e2d055e342408fba8916d21ac79d",
  "bbox": "13.30,52.47,13.48,52.56",
  "zooms": "12,14,16",
  "simplify": "2.0",
  "extra": "--max-points-per-tile 700 --cache berlin.osm",
  "products": ["venu3", "venu3s", "venu2"]
}
```

`products` is optional, and omitting it means every product in `manifest.xml`.
For a dense city that is not a real option: see the measured table below.

Generate the id once and never change it:

```bash
python3 -c 'import uuid; print(uuid.uuid4().hex)'
```

**`app_id` is the listing's identity.** Change it and you have created a second
listing with no users, no ratings and no upgrade path for anyone already on the
old one. The build refuses ids that are malformed or shared between cities,
because a duplicate would publish one city over another.

`developer_key` is the *developer* identity and is shared by every city. One
key, many app ids. It is gitignored and unrecoverable: losing it means losing
the ability to update every listing you have published.

## Building one

```bash
make city                 # list configured cities
make city CITY=berlin     # -> bin/offline-maps-berlin.iq
```

`tools/build-city.sh` swaps that city's id, name and product list into the
tracked `manifest.xml` and `resources/strings/strings.xml`, packs the region,
builds it, then puts everything back, including the demo pack, so the repo never
keeps another city's identity and CI's `make demo` check stays green. The
restore runs on failure and on interrupt, not just on success.

It fails the build if the packer warns. An over-budget pack does not install, or
installs with the detail gutted, and neither is something to find out after
upload. Knobs, in order, are in [PACKER.md](PACKER.md#budgets).

### The pack is paid for once per product

The store rejects a `.iq` over 15 MB, and the map is compiled into **every**
product in `manifest.xml`. With 24 products the usable pack is roughly 600 KB,
not 15 MB, and a region that fitted comfortably when this app shipped for two
watches will not fit now. `build-city.sh` fails rather than let you discover it
at upload.

Two ways out, and the second is usually the right one for a dense city:

- Shrink the pack with `SIMPLIFY`, `--max-points-per-tile`, or fewer zooms
  ([PACKER.md](PACKER.md#budgets)).
- **Cut the product list for that listing**, with a `products` array in
  `cities.json`. Nothing requires every listing to cover every watch, and a
  listing built for a few screen families keeps the sharper pack.

Berlin, measured rather than estimated:

| Products | `.iq` | |
|---|---|---|
| 24 (the whole manifest) | far over | refused |
| 5 | 20 MB | refused |
| **3** (`venu3`, `venu3s`, `venu2`) | **12 MB** | fits |

So a street-level city costs about 4 MB per watch it supports. Adding a fourth
product means shrinking the pack.

## Uploading

1. Garmin Developer Account, and accept the developer agreement.
2. The dashboard is **apps-developer.garmin.com**. It moved; older guides point
   elsewhere.
3. Upload the `.iq`. It is validated first; only then can you add the
   description and screenshots.
4. Garmin reviews it. The listing stays hidden until approved, and you can
   download it yourself for testing while it is pending.

Read [Garmin's App Review Guidelines](https://developer.garmin.com/connect-iq/app-review-guidelines/)
before the first submission. Two things that bite this app specifically:

- **Attribution.** OpenStreetMap packs are ODbL and must credit
  "© OpenStreetMap contributors". The app carries it in the About screen and the
  packer writes it into every pack, but the listing description should say it
  too. A different source means `--attribution` and checking that source's terms
  yourself. Garmin puts the licensing burden on you.
- **Permissions.** `Positioning` and `Sensor` are declared; the description
  should explain why a map needs them.

## Before the first upload

Side-load the `.prg` and use it for a few minutes first. The buffered render and
the frame budget are the two things the simulator cannot tell you, and
[DEVICES.md](DEVICES.md) says both are tight. A one-star review for a map that
flickers while panning is expensive to undo.
