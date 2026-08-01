# Changelog

Notable changes to this project, newest first.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-08-02

First cut. The app compiles for all 24 supported products and runs in the
simulator.

### Fixed

- **The off-screen buffered render now works.** A paletted `BufferedBitmap`
  rejects every primitive `MapRenderer` draws, so the app had been falling back
  to direct drawing on every frame — the opposite of its performance design.
  The buffer is no longer paletted, which costs 8 bpp instead of 4. See
  [docs/RENDERING.md](docs/RENDERING.md#why-the-buffer-is-not-paletted).

### Added

- **Pack a city by name.** `make pack CITY="Madrid"` geocodes the place and
  packs 12 km around its centre, so getting your own city no longer means
  finding bounding-box coordinates first. Ambiguous names print every match
  rather than guessing; `RADIUS_KM` and `CITY_INDEX` pick a bigger area or a
  different match. `BBOX` and `INPUT` still work unchanged.
- **22 more watches.** The app now covers 24 products across the Venu, Venu Sq,
  vívoactive and Forerunner families — Venu 2/2S/2 Plus/3/3S/4/X1, Venu Sq 2,
  vívoactive 5/6 and Forerunner 165/170/265/570/70/955/965/970. `minApiLevel`
  drops to 4.0.0, which is what the renderer actually needs. Support is gated on
  a touchscreen (panning is drag-only) and API 4.0, not on GPS; the models this
  leaves out and why are in
  [docs/DEVICES.md](docs/DEVICES.md#what-that-leaves-out).
- **The About screen names the source repository**, under the map attribution,
  so anyone holding the watch can find where the app comes from.
- **Offline vector map for Garmin watches.** Pan by dragging, zoom with
  the on-screen buttons, anywhere in the packed region — no phone, no network,
  no subscription.
- **Follow me.** Recentres on every GPS fix; one tap on the crosshair to
  re-engage after panning away.
- **North-up or heading-up.** The map turns with you, with a north arrow so you
  can still tell which way is up.
- **Map layers by class** — motorways through service roads, water, rivers,
  parks and forests, railways and paths, each appearing at a sensible zoom.
- **Scale bar, dark and light themes, and a position marker** with a heading
  wedge.
- **Menu** with heading-up, dark theme, an on-screen render-stats overlay, and
  the pack's attribution.
- **`tools/mappack`** — build a map pack for your own area from Overpass or a
  Geofabrik extract, with a size report that warns before you exceed the Connect
  IQ resource and store limits.
- **Preview renderer** — render a pack to PNG and see what the watch will draw
  before spending time flashing it.

[Unreleased]: https://github.com/Chemaclass/garmin-offline-maps/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.1.0
