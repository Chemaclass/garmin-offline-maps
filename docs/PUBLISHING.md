# Publishing to the Connect IQ store

## The published listing

Beta, first published 2026-08-02:
**https://apps.garmin.com/apps/296a0177-3634-4515-9da2-7336d5dce3c3**

Garmin's listing UUID is `296a0177-3634-4515-9da2-7336d5dce3c3`, which is not
either app id tracked in this repo. Whatever id sits inside the uploaded `.iq`
is the one every future upload must keep, so record it in `cities.json` before
the next release: a changed id publishes a second listing rather than an update.

## One listing per city, and why

The map is **compiled into the app**. That is not a shortcut. The platform
offers no alternative, and [DEVICES.md](DEVICES.md) has the receipts: there is
no `File`, `FileSystem` or `IO` module in Toybox at all, `Application.Storage`
is ~128 KB against a 2.7 MB pack, and BLE moves under 1 KB/s.

So an app cannot download a region, and cannot free one. Users choose their
coverage the only way the platform allows: **by installing and uninstalling
apps**. The Connect IQ store *is* the delivery mechanism.

That falls out of the architecture rather than fighting it. The packer already
emits exactly one pack per build, so a per-city listing needs no watch-side code
at all.

The alternative, several packs inside one app with a settings picker, is
possible but caps near **two dense cities**: Berlin alone is 106 of the ~255
jsonData resource ids, every user downloads every city, and selecting one frees
nothing. Worth it only for genuinely adjacent regions.

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
  "extra": "--max-points-per-tile 700 --cache berlin.osm"
}
```

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

`tools/build-city.sh` swaps that city's id and name into the tracked
`manifest.xml` and `resources/strings/strings.xml`, packs the region, builds
every product, then puts everything back, including the demo pack, so the repo
never keeps another city's identity and CI's `make demo` check stays green. The
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
- **Cut the product list for that listing.** Nothing requires every listing to
  cover every watch. A city listing built for one screen family is a smaller
  `.iq` and a sharper pack, and a second listing can cover the rest.

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
