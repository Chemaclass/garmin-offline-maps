# Changelog

Notable changes to this project, newest first.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No release has been cut yet — everything below is what exists today. The app
compiles for all 24 supported products and runs in the simulator, but has
**not** run on hardware, so nothing here is verified on-watch.

### Fixed

- **The off-screen buffered render now works.** A paletted `BufferedBitmap`
  rejects every primitive `MapRenderer` draws, so the app had been falling back
  to direct drawing on every frame — the opposite of its performance design.
  The buffer is no longer paletted, which costs 8 bpp instead of 4. See
  [docs/RENDERING.md](docs/RENDERING.md#why-the-buffer-is-not-paletted).

### Added

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

[Unreleased]: https://github.com/Chemaclass/garmin-offline-maps
