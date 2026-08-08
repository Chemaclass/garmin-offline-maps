# Changelog

Notable changes to this project, newest first.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Dense maps draw instead of stopping the app.** A street-level city map
  killed the app the moment it started drawing roads. The limit it was
  overrunning was measured in the wrong thing: the watch counts the work done,
  not the time taken, and one piece of map had no limit on that work at all.
  A piece that would overrun is now cut short and the map moves on, so a
  crowded corner costs a little missing detail rather than the whole app.

## [0.3.21] - 2026-08-06

### Fixed

- **The map draws its streets while you are standing on them.** Every GPS fix
  recentred the map and started the drawing again from nothing, and fixes
  arrive every second. The map is built up in stages, water and parks before
  roads, so it never got past the first stage: a screen of water with no
  streets on it, for as long as you stood still. Following now waits until
  you have actually moved, and a fix that lands mid-draw lets the map finish
  first. Measured over 30 fixes: 31 restarts before, 1 after.

## [0.3.20] - 2026-08-03

### Fixed

- **Heading-up mode draws the streets.** The map is built up over several
  frames, water and parks first and roads after, and every turn of the wrist
  started it over from the beginning. On an arm that moves, it never got as far
  as the roads: a map of water and green space and nothing else. A turn now
  waits for the picture to finish before redrawing it.

### Changed

- **Stats now says whether the map has finished drawing.** A map still building
  and a map that has finished with layers missing look identical, and only one
  of them is a fault worth reporting.

## [0.3.19] - 2026-08-02

### Fixed

- **Panning a downloaded city no longer stops the app.** 0.3.18 let a single
  piece of map take as long as it liked, and while turning the map with the
  compass one of them took long enough that the watch cut the app off. Each
  frame now finishes one piece and then checks the clock before starting
  another, which keeps both promises: the map always moves forward, and no
  frame runs away.

## [0.3.18] - 2026-08-02

### Fixed

- **The map finishes drawing and then stops.** 0.3.17 built the map up over
  several frames but could never decide it was done, so it kept redrawing the
  same part for as long as the app was open: the map stayed incomplete and the
  battery paid for it. It now draws a whole piece of map at a time, finishes in
  a handful of frames, and goes quiet.

## [0.3.17] - 2026-08-02

### Fixed

- **The whole map is drawn, not just the part that fit.** A frame has to be
  short or the watch stops the app, and a city needs more drawing than fits in
  one, so the rest used to be thrown away: a downloaded city showed its left
  half and empty space on the right. The map is now built up over a few frames
  instead, each one short, and keeps what the last one drew. You see it fill in
  over a moment and then it is complete.

## [0.3.16] - 2026-08-02

### Fixed

- **A city you are not standing in still shows you the city.** The map followed
  your position even when it was hundreds of kilometres off the downloaded
  area, so it centred on empty space and the screen went dark. It now stays on
  the map you asked for and tells you the marker is elsewhere. Walk into the
  area and it picks you up. The crosshair button behaves the same way: it takes
  you to your position when that is on the map, and to the map when it is not.

### Changed

- **Closing the app puts everything down.** The GPS receiver was already
  switched off; now a download still in progress is cancelled, and the map
  buffer and the decoded map pieces are handed back rather than left for the
  system to collect. Where you were looking, your zoom, and your theme are
  saved as before, so reopening puts you back where you left off.

## [0.3.15] - 2026-08-02

### Added

- **The app says which version it is, where you need it.** The download screen
  now shows the build, and any error drawn on the map is stamped with it. A fix
  that has not reached your watch and a fix that did not work look exactly the
  same from the screen; now they do not. If you report a problem, that line is
  the useful thing to send.

## [0.3.14] - 2026-08-02

### Fixed

- **Zooming out no longer costs more than it draws.** The map asked about
  every tile the screen could hold, including all the empty space around a
  city, and proving each one empty took as long on a slow watch as drawing a
  full one. It now looks only where the map actually reaches. At the widest
  zoom a downloaded city draws about half again as much detail in the same
  time, and the widest zoom was where the app was most likely to be cut off.

### Changed

- **Tidy-up across the app and the packer** with no change in behaviour:
  duplicated drawing collapsed into one place, dead code removed, and
  comments rewritten to explain the code rather than narrate its history.

### Fixed

- **A map now loads one piece per frame instead of three.** Reading a piece of
  map out of storage and unpacking it is the one part of drawing that cannot be
  stopped half way, so however long it takes is time the app has no choice but
  to spend. Three of them in a single frame was the last place a slow watch
  could still be cut off. A city takes a few more frames to fill in and no
  single frame has a cliff in it.

## [0.3.12] - 2026-08-02

### Fixed

- **A tile with nothing in it now counts against the frame.** At the widest
  zoom a screen covers thirty-six tiles, and an empty one was skipped without
  the app ever checking how long it had been drawing. On a watch, which is a
  good deal slower than the simulator this was measured in, that unwatched work
  was enough on its own to get the app cut off. It is the same black screen as
  0.3.11 fixed, from the one path that fix did not cover.

## [0.3.11] - 2026-08-02

### Fixed

- **Downloaded cities work.** Opening one, and then panning around it, ended in
  a black screen and the Connect IQ error icon. This is the fault that has been
  there since downloading was added, and it was four separate things stacked on
  each other, the largest being that the drawing budget counted only the lines
  it managed to draw. With the map off centre nothing was drawn, so nothing was
  counted, so the budget never applied and the app kept working until the watch
  cut it off. Berlin now draws in well under a tenth of a second and survives
  panning between Alexanderplatz and Wedding at every zoom.
- **Your map opens where you left it, or at the city centre.** A single bad GPS
  reading used to be saved as your position and restored on every launch, so a
  downloaded city would open on blank space for good. A stored position outside
  the current map is now ignored.
- **Your position appears immediately.** The app waited for a fresh satellite
  fix and ignored the one the watch already had, so it could sit on "Searching
  for GPS" for a minute with the answer already available.

### Changed

- **Dense maps draw the most important detail first rather than all of it.**
  A crowded view is cut short to keep the app responsive, so a busy city shows
  slightly less at the lowest zoom than it did. Zoom in for the rest.

## [0.3.10] - 2026-08-02

The store build of the watchdog fix. No behaviour changes over 0.3.9: this
carries its own version number so the build on a watch can be told apart from
the one before it, which the About screen now shows.

If you are coming from 0.3.8 or earlier, the release worth reading is
[0.3.8](#038---2026-08-02): downloaded cities no longer crash.

## [0.3.9] - 2026-08-02

### Added

- **The About screen shows the version.** Hold the screen, open About, and the
  build is on the second line. Until now a side-loaded app and a store one were
  indistinguishable on the wrist, which made "did that fix actually reach the
  watch?" unanswerable.

## [0.3.8] - 2026-08-02

### Fixed

- **A downloaded city no longer kills the app.** Opening one ended in a black
  screen and the Connect IQ error icon. The watch was not rejecting anything:
  it was cutting the app off for taking too long. Filling the screen from a
  downloaded map can need a dozen blocks, each read from storage and decoded,
  and doing all of that before drawing a single frame overran the time an app
  is allowed. The map now loads a few blocks per frame and fills in over the
  next moment or two, which is a beat of detail arriving rather than a crash.
  This is the fault behind every black screen reported since 0.3.0.

## [0.3.7] - 2026-08-02

### Fixed

- **The crash report in 0.3.6 could never be read.** It recorded the failing
  step correctly and then walked straight back into it on the next launch, so
  the app died again before drawing anything and the message was never seen.
  After a crash the app now starts on the built-in map and shows what happened.
  Your downloaded city is kept, not deleted; it is just not opened
  automatically. Pick it again from the menu when you want to retry.

### Added

- **The last crash also appears in Garmin Connect**, under the app's settings,
  so it can be read and copied on the phone instead of off the watch face. It
  is empty when nothing has gone wrong.

## [0.3.6] - 2026-08-02

### Added

- **The watch now tells you where it died.** When the app is killed outright,
  the black screen with the Connect IQ icon, nothing can run afterwards to
  report it. The step it was about to take is now saved beforehand, and the
  next launch shows it in red across the bottom of the map: which block, which
  stage, which city. If you hit the black screen, reopen the app and read that
  line back. It is the one way to find out what actually failed.

### Fixed

- **A downloaded city is adopted a moment after the download ends, instead of
  inside it.** The switch used to run in the network callback, while the last
  response and the download screen were both still held, and the first draw of
  a new map is the largest allocation the app ever makes. Running out of memory
  there ends the app instantly, with no chance to recover or explain. It now
  waits for the download to be let go of first.
- **An error on the map is readable.** It was a single small line, which cut
  off exactly the part that named the fault. It now wraps onto its own panel.

## [0.3.5] - 2026-08-02

### Fixed

- **A download that goes wrong now says so.** The reason was recorded while the
  download screen was still in front, and wiped on the way back to the map, so
  a failed download ended in silence and the sample map. Whatever went wrong
  now reaches the screen.
- **A city that arrives incomplete is refused rather than drawn.** A download
  that returned no map blocks, or a block that was not map data, was stored
  anyway and then drawn as a blank map for as long as that city stayed on the
  watch.
- **A downloaded city survives an unreadable setting.** The city dropdown from
  the phone and the city currently active were read under one guard, so a
  problem reading the first threw away the second and dropped you back to the
  sample map with your city still on the watch.
- **A map description that does not add up is refused before it can take the
  app down.** Missing or mismatched zoom tables used to reach the code that
  sets up the view, where nothing could catch them.
- **`make city` builds a per-city listing again.** It failed to start at all
  under the shell macOS ships. A listing can also name the watches it covers
  now, which is what keeps a street-level city under the store's size limit.

## [0.3.4] - 2026-08-02

### Changed

- **Cities show their streets again.** A city ringed by farmland or forest
  could pack as a green field with the road network missing, because the
  landcover used up the space the roads needed. Murcia went from almost no
  visible streets to a full road network at the same size. Re-select your city
  to pick up the better map; already-published cities have been rebuilt.

### Fixed

- **Upgrading from 0.3.0 to 0.3.2 could keep crashing even after the fix.**
  Those versions could save a fractional zoom level, and reading it back
  reproduced the same fault from a value already on the watch. It is now
  converted as it is read.
- **The map recovers its smooth panning.** If the watch was short of memory the
  app fell back to a slower, flickering redraw and stayed there for the rest of
  the session. It now tries again whenever you come back to the map.

## [0.3.3] - 2026-08-02

### Fixed

- **Downloading a city works.** Opening a downloaded map stopped the app dead,
  with a black screen and the Connect IQ error icon. Numbers arriving from the
  downloaded map description could be fractional where whole numbers were
  required, and that failure could not be caught: it ended the app outright.
  They are now converted as they are read, so a downloaded city draws like a
  built-in one.

## [0.3.2] - 2026-08-02

### Fixed

- **The app no longer stops working after downloading a city.** Drawing a
  downloaded map could throw, which took the whole app down and left a black
  screen. Drawing is now guarded end to end: if it fails, the app falls back to
  the map built into it and keeps running.
- **A failure now says what went wrong**, in red along the bottom of the map,
  rather than leaving you to guess. If you see one, the text is worth
  reporting.

## [0.3.1] - 2026-08-02

### Fixed

- **Downloading a city no longer risks taking the app down.** On a watch,
  choosing a city and letting it download ended in a black screen and the
  Connect IQ error icon. Switching maps now falls back to the built-in map if
  anything goes wrong, and forgets the city that failed rather than repeating
  the failure on every launch.

### Changed

- **The city setting on the phone is a dropdown**, listing every city the app
  knows about as "Country: City", instead of a text field you had to type a
  name into. Cities published since the app was last updated still appear in
  the watch's own picker.
- **The Catalogue URL setting is gone.** It had a working default and a wrong
  value silently broke every download.

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

[Unreleased]: https://github.com/Chemaclass/garmin-offline-maps/compare/v0.3.21...HEAD
[0.3.21]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.21
[0.3.20]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.20
[0.3.19]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.19
[0.3.18]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.18
[0.3.17]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.17
[0.3.16]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.16
[0.3.15]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.15
[0.3.14]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.14
[0.3.13]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.13
[0.3.12]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.12
[0.3.11]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.11
[0.3.10]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.10
[0.3.9]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.9
[0.3.8]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.8
[0.3.7]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.7
[0.3.6]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.6
[0.3.5]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.5
[0.3.4]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.4
[0.3.3]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.3
[0.3.2]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.2
[0.3.1]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.1
[0.3.0]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.3.0
[0.2.0]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.2.0
[0.1.0]: https://github.com/Chemaclass/garmin-offline-maps/releases/tag/v0.1.0
