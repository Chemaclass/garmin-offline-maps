# Changelog

Notable changes to this project, newest first.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.3.0] - 2026-08-02

Choosing a city stops being a guessing game, and the catalogue grows without
shipping an app.

### Added

- **Pick a city by country, then city.** Hold the screen, choose "Change city",
  and the watch lists the countries it has maps for, then the cities in the one
  you pick, each with its size. The list comes from the published catalogue, so
  new cities appear without updating the app.
- **Fifteen cities to choose from**, across Germany, Spain, France, the
  Netherlands, Portugal and Austria, and adding more no longer needs a release.
- **A first-run card explains the demo map.** A fresh install opens on a small
  sample map, which looked like a broken map of wherever you happen to be. It
  now says so, and points at the two ways to get your own city: hold the screen
  and choose "Change city", or set City in Garmin Connect. Any tap, swipe or
  button takes it down, and it never returns once a city is downloaded.
- **A project website** at
  [chemaclass.github.io/garmin-offline-maps](https://chemaclass.github.io/garmin-offline-maps/),
  covering what the app does, how downloading a city works, and which cities
  are published.

### Fixed

- **Typing a city is forgiving.** The City setting no longer cares about
  capitals or spaces, so "Berlin" and "New York" resolve rather than silently
  finding nothing. It also links to the published city list.

## [0.2.0] - 2026-08-02

First release with a Settings page, and the first that ran on a watch.

### Added

- **Choose your city from the phone.** The app now has a Settings page in
  Garmin Connect. Type a city and the watch downloads it, with progress on
  screen, and keeps drawing the built-in map until it finishes. One app, any
  published city, one active at a time. A downloaded city is an orientation
  map, major roads, water, rail and parks, because that is what fits the
  watch's ~128 KB of storage; street-level detail still has to be compiled in.
  See [docs/CITIES.md](docs/CITIES.md).

### Changed

- **The bundled demo pack now sits at Berlin's coordinates** rather than
  Madrid's, so the position marker lands on the map when you open the app
  without building a pack of your own. The streets are still invented; only the
  location changed.
- **The stats overlay is readable and shorter.** Four lines at a fixed pitch
  overlapped on a 454 px screen. It is now two: your latitude and longitude,
  then zoom, segments drawn and render time. Spacing scales with the screen.

### Fixed

- **The map now says why your position is not shown.** A missing marker used to
  be silent, which is indistinguishable from a broken app. It now reads
  "Searching for GPS" before the first fix, and "You are outside this map" when
  your position falls outside the packed region.

## [0.1.0] - 2026-08-02

First cut. The app compiles for all 24 supported products and runs in the
simulator.

### Fixed

- **The off-screen buffered render now works.** A paletted `BufferedBitmap`
  rejects every primitive `MapRenderer` draws, so the app had been falling back
  to direct drawing on every frame, the opposite of its performance design.
  The buffer is no longer paletted, which costs 8 bpp instead of 4. See
  [docs/RENDERING.md](docs/RENDERING.md#why-the-buffer-is-not-paletted).

### Added

- **Pack a city by name.** `make pack CITY="Madrid"` geocodes the place and
  packs 12 km around its centre, so getting your own city no longer means
  finding bounding-box coordinates first. Ambiguous names print every match
  rather than guessing; `RADIUS_KM` and `CITY_INDEX` pick a bigger area or a
  different match. `BBOX` and `INPUT` still work unchanged.
- **22 more watches.** The app now covers 24 products across the Venu, Venu Sq,
  vívoactive and Forerunner families: Venu 2/2S/2 Plus/3/3S/4/X1, Venu Sq 2,
  vívoactive 5/6 and Forerunner 165/170/265/570/70/955/965/970. `minApiLevel`
  drops to 4.0.0, which is what the renderer actually needs. Support is gated on
  a touchscreen (panning is drag-only) and API 4.0, not on GPS; the models this
  leaves out and why are in
  [docs/DEVICES.md](docs/DEVICES.md#what-that-leaves-out).
- **The About screen names the source repository**, under the map attribution,
  so anyone holding the watch can find where the app comes from.
- **Offline vector map for Garmin watches.** Pan by dragging, zoom with
  the on-screen buttons, anywhere in the packed region, no phone, no network,
  no subscription.
- **Follow me.** Recentres on every GPS fix; one tap on the crosshair to
  re-engage after panning away.
- **North-up or heading-up.** The map turns with you, with a north arrow so you
  can still tell which way is up.
- **Map layers by class**: motorways through service roads, water, rivers,
  parks and forests, railways and paths, each appearing at a sensible zoom.
- **Scale bar, dark and light themes, and a position marker** with a heading
  wedge.
- **Menu** with heading-up, dark theme, an on-screen render-stats overlay, and
  the pack's attribution.
- **`tools/mappack`**: build a map pack for your own area from Overpass or a
  Geofabrik extract, with a size report that warns before you exceed the Connect
  IQ resource and store limits.
- **Preview renderer**: render a pack to PNG and see what the watch will draw
  before spending time flashing it.

[Unreleased]: https://github.com/Chemaclass/garmin-offline-maps/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.0
[0.2.0]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.2.0
[0.1.0]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.1.0
