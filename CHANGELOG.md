# Changelog

Notable changes to this project, newest first.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No release has been cut yet — everything below is what exists today. The app
compiles for the Venu 3 and Venu 3S and runs in the simulator, but has **not**
run on hardware, so nothing here is verified on-watch.

### Added

- **Offline vector map for the Venu 3 and Venu 3S.** Pan by dragging, zoom with
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
