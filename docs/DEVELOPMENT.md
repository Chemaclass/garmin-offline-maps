# Development

## What works without the Connect IQ SDK

Most of it. The packer, the tests and the preview renderer need only `python3`.

```bash
make test     # the packer suite (10 skip without Pillow)
make lint     # compileall over the packer
make demo     # rebuild the committed demo pack
make pack     # build a pack for a real area
```

Only `make build`, `make sim`, `make watch` and `make package` need the SDK.

```bash
pip install pillow    # unskips the 10 preview tests
pip install osmium    # enables make pack INPUT=*.osm.pbf
```

## Setting up the toolchain

Run `make doctor` at any point. It names which piece is missing instead of
letting `monkeyc` guess. Six things must exist, and they fail with
similar-looking errors:

| Missing | Symptom |
|---|---|
| SDK binaries | `make: monkeyc: No such file or directory` |
| Java runtime | `Unable to locate a Java Runtime` |
| Device definitions | `ERROR: Invalid device id specified: 'venu3'.` |
| Signing key | `make build` stops before compiling; fix with `make key` |
| A 9.1.x SDK for the simulator | the simulator window appears for a second and vanishes, and `monkeydo` still exits 0 |
| `libmtp` | `make watch` says `mtp-detect not found` |

```bash
brew install --cask connectiq              # monkeyc, monkeydo, simulator -- no Garmin login
brew install --cask temurin@21             # JDK 21, matching CI
brew install --cask connectiq-sdk-manager  # device definitions -- free Garmin account
brew install libmtp                        # only for make watch, side-loading over USB
```

Use `temurin@21`, not `temurin`. The unversioned cask is now JDK 26. Only
`temurin@21` needs `sudo` (it is a `.pkg`); the other two are not.

Nothing else is needed. The simulator is a universal binary that links only
macOS system frameworks, so there is no Rosetta step on Apple Silicon and no
runtime to install beyond the JDK, which is the compiler's, not its.

**Device definitions are the step that most often stalls.** The SDK
download does not carry them, and Garmin gates them behind an account. Open
`SdkManager.app`, sign in, download an SDK **and accept the licence agreement**
(an unaccepted agreement is what silently leaves the Devices list empty), then
tick the products in `manifest.xml` (or just Venu 3 and Venu 3S to start; the
build only needs the device you pass to `DEVICE=`). They land in:

```
~/Library/Application Support/Garmin/ConnectIQ/Devices/
```

The headless route CI uses works locally too, and still needs your credentials:

```bash
curl -sSf https://raw.githubusercontent.com/lindell/connect-iq-sdk-manager-cli/master/install.sh | sh
connect-iq-sdk-manager login
connect-iq-sdk-manager device download --manifest=manifest.xml
```

### The simulator needs an older SDK than the compiler

**9.2.0's simulator segfaults on macOS 26.5.2 the moment an app draws.**
`EXC_BAD_ACCESS`, a null dereference every frame, inside Garmin's closed-source
`simulator` binary. Garmin's own sample apps kill it the same way, so it is not
ours to fix. The failure is quiet in exactly the wrong way: the window appears
for about a second and vanishes, `monkeydo` still exits 0, and from the terminal
it looks like the run succeeded.

9.1.0 runs the identical `.prg` without crashing. So the Makefile compiles with
the newest SDK and simulates with the newest one that survives:

```bash
# in SdkManager.app, download 9.1.0 alongside whatever you compile with
ls ~/.Garmin/ConnectIQ/Sdks/          # make sim wants a connectiq-sdk-mac-9.1.* here
```

Two more traps in the same area, both already handled by `make sim` and both
worth knowing before you launch the simulator by hand:

- **Do not use the `connectiq` launcher.** It runs `open -a ConnectIQ.app`, and
  `-a` resolves through LaunchServices by bundle id, so the cask's copy
  hard-linked into `/Applications` can start instead. The simulator locates the
  SDK from its own path, so the wrong bundle finds no `version.txt` and no
  device definitions, then rejects a device with "SDK Version 4.2.0.beta2 or
  greater is required" against a 9.2.0 SDK.
- **Prefer an SdkManager install under `~/.Garmin`** over the cask's, for the
  same reason: the cask's bundle lives where it cannot find its own
  `version.txt`.

If the port stays shut, an instance is wedged:

```bash
pkill -f 'bin/monkeydo'; pkill -f 'MacOS/simulator'
```

### Where the Makefile looks

Nothing needs to be on `PATH`. The Makefile autodetects the Homebrew SDK, so
plain `make build` works once the four pieces above exist.

Do **not** follow the old advice of `SDK_BIN="$(brew --prefix)/bin"`. The cask
links `monkeyc` and `monkeydo` there but *not* `connectiq`, the simulator
launcher, so that path builds fine and then breaks `make sim` with
`connectiq: command not found`. Override only for an SDK outside Homebrew:

```bash
make build SDK_BIN=~/path/to/connectiq-sdk-mac-X.Y.Z/bin
```

## Build and run

```bash
make doctor                 # what is missing, before anything else
make key                    # one-off signing key, gitignored
make build DEVICE=venu3     # -> bin/offline-maps.prg
make build DEVICE=venu3s    # every product in manifest.xml, not just the default
                            # (same output path, so the last build wins)
make sim                    # simulator + side-load
make watch                  # build and side-load onto a watch on USB
make package                # -> bin/offline-maps.iq for the store
```

`make sim` waits for the simulator to open its side-load socket (TCP 1234)
rather than sleeping a fixed interval, and reuses an already-running simulator.
Leave it open between builds; `Ctrl-C` detaches `monkeydo` without closing it.
It also prints everything the app writes with `System.println`, which is the
only log you get.

### On a real watch

```bash
brew install libmtp
make watch                  # or: make watch DEVICE=venu3s
```

That is the loop worth having. The alternative is upload, store review, phone
sync, watch update, for every one-line change; this is a few seconds and needs
neither a phone nor a network. Keep releases for builds worth publishing.

Garmin watches speak **MTP**, which macOS does not mount natively (the Venu 3
has music storage, so it is not a mass-storage device and Finder never shows
it), hence `libmtp` rather than a copy into `/Volumes`. `tools/push-watch.sh`
looks the `GARMIN/APPS` folder id up rather than hardcoding it, and deletes the
previous copy first, because MTP will happily store a second file under the same
name and the watch then lists the app twice.

**The watch must be awake.** It drops off the bus when the screen sleeps, and
`libmtp` reports "No raw devices found" exactly as though it were unplugged.
Quit Garmin Express too: it holds the device. Then check the About screen for
the version you just pushed, which is what `source/Version.mc` is for.

There is no on-watch log to read. `GARMIN/APPS/LOGS/CIQ_LOG.YML` records that an
app died and where, but only after a crash, and `Diag.mc` writes its own
breadcrumbs to `Application.Storage` for the same reason.

**`developer_key` is the app's identity in the Connect IQ store.** The store pins
a published app to the key that signed its first upload; a new key means a new
app. Never print, commit or regenerate it. `make key` only creates it when
missing.

**Fix compile errors on their merits.** Do not restructure working logic just to
silence a message.

## Before you commit

```bash
make test
make demo && git diff --exit-code -- mapdata/active source/generated/MapIndex.mc
```

The second command is exactly what CI runs. A diff means either the committed
pack is stale (commit the regenerated files with your change) or something was
hand-edited.

If the change is user-visible, it also needs a `CHANGELOG.md` entry. See the
`changelog` skill for what qualifies. Most work in this repo does not.

### The three invariants

| # | Contract | Files | Check |
|---|---|---|---|
| 1 | Byte format | `pack.py` + `emit.py` + `varint.py`, `decode.py`, `TileReader.mc`, `FORMAT.md` | `tests/contract/test_tile_format.py` |
| 2 | Layer ids 0–9 | `classify.py`, `Palette.mc` | `tests/contract/test_palette.py` |
| 3 | Generated artefacts | `mapdata/active/**`, `MapIndex.mc` | `make demo` + `git diff` |

Two traps worth naming: `docs/FORMAT.md` is the spec rather than a description
of it, so bytes moving means it moves too; and `preview.py` *parses*
`Palette.mc` at runtime, so reformatting those array literals can break tests
even when the colours are fine.

A failure in `tests/contract/` means "go edit the other side", not "fix this
code". That is why those tests are kept apart from the rest.

## Conventions

**Monkey C, as written here:** `import Toybox.X` at the top, `//!` doc comments
that explain *why*, `hidden var _name` for private state, untyped `var`, shared
constants in a `module` when both a class and its statics need them.

Your own logic stays untyped. Do not introduce a partial typing regime. Two
exceptions, both forced by the checker rather than chosen:

| Exception | Why the checker forces it |
|---|---|
| **API boundaries Garmin types for you** | An untyped callback passed to `Position.enableLocationEvents` or `Timer.start` is rejected, as is `item.isEnabled()` when `onSelect` hands you the base `MenuItem`. |
| **Values you subscript** | `x[i]` on an untyped value warns, and the annotation must sit on every hop from where the container is made to where it is indexed. Miss one and the warning returns. |

Every such site carries a `//!` saying which of the two applies. Annotate the
container, not the arithmetic around it: counters, offsets and coordinates stay
untyped.

One case is neither, and is worth knowing because no annotation can help. A
`Float` reaching `<<` or `>>` raises `UnexpectedTypeError`, which is a
`Lang.Error` rather than a `Lang.Exception`, so **no `catch` can stop it**;
`catch (e instanceof Lang.Error)` does not even compile. Values arriving from JSON are therefore
coerced at the boundary: `source/Num.mc` owns the conversions, and `Pack.use`,
`CityStore.keyName`, `CityDownloader` and `Settings.load` are the callers.

`toNumber()` on its own is not enough, which is the trap. It is partial: on a
`String` it returns `null` for anything unparseable, and on a `Boolean` it does
not exist. A guard that only checks for `null` before calling it can still put a
`null` in the field it was written to protect, and `1 << null` raises the same
uncatchable error. Every conversion in `Num` tests the type first.

The alternative was compiling at `-l 0`, which builds clean but disables type
checking for the whole codebase. Rejected: the checker caught a genuine defect
on its first run (`TileReader.uvarint` had no provable return path), and that is
worth more than a fully annotation-free `source/`.

**Python:** stdlib only in `mappack/`. Pillow is optional and import-guarded;
osmium is imported lazily for `.pbf`. Do not add a dependency; restructure.

**Docs are part of the change.** If the bytes move, `FORMAT.md` moves.

**Commits:** conventional, `ref:` rather than `refactor:`.

## Driving the map without a watch

```bash
make serve                       # then open http://127.0.0.1:8765
make serve PACK=mapdata/berlin   # a pack you built for yourself
```

Serves the Python renderer in a browser with the same interaction model as
`MapView`/`MapDelegate`: dragging slides the rendered image and only re-renders
on release, the way the watch blits its buffer at an offset; `/pan` is a mirror
of `Camera.panPixels`; zoom clamps to the index's `MIN_ZOOM`/`MAX_ZOOM`. The
stats panel reports tiles, segments, missing blocks and whether the render hit
the segment budget.

This exercises the pack, the block and tile decode, the projection, draw order,
the palette and the budgets. It does **not** exercise Monkey C, the heap, or
frame timing: a render that looks fine here can still fail to allocate its
buffer on the device. The Connect IQ simulator is the better tool when it runs;
this is what you use when it does not.

## Exercising the download path

A compiled-in pack and a downloaded one are not the same code path. Blocks
arrive over HTTP, live in `Application.Storage`, and are decoded at runtime,
and `make sim` touches none of that. Bugs have hidden in the difference.

```bash
make catalogue CITY=Berlin      # publishes, then serves on 127.0.0.1:8899
```

Then in the simulator, **Settings > Application Settings**, set `packBaseUrl`
to that URL and pick the city from the app's menu.

Two traps, both of which cost real time:

- **The simulator persists app settings per app.** Changing a default in
  `resources/settings/properties.xml` does not reach an app whose settings it
  has already stored. Change it through the simulator, not the file, which is
  generated by the packer anyway and must not be hand-edited.
- **The simulator produces no GPS fix and no compass heading.** `onFix` returns
  at its first guard and `pollHeading` never reports a change, so the whole
  follow path is dead code here. Two bugs shipped through that gap in a single
  month. Testing it needs the callbacks driven directly; see issue #3.

## Testing

```bash
make test                                                    # everything, 131 tests
cd tools/mappack
python3 -m unittest discover -s tests/unit -t .              # one category
python3 -m unittest tests.contract.test_tile_format -v       # one file
python3 tests/unit/test_geom.py                              # also works directly
```

Tests are grouped by **what they are testing**, not by what they import. Each
directory's `__init__.py` states its own rule.

```
tools/mappack/tests/
├── demo-city.osm       synthetic fixture, generated by make_fixture.py
├── unit/               86 tests, one file per mappack module, single module each
│   ├── test_varint.py      LEB128, zigzag
│   ├── test_geom.py        Mercator, Douglas–Peucker, clipping
│   ├── test_classify.py    OSM tags → layer + minzoom
│   ├── test_osmread.py     OSM XML → tagged ways
│   ├── test_geocode.py     place name → bbox
│   ├── test_citypack.py    downloadable city packs
│   ├── test_publish.py     cities.json → per-city store bundles
│   └── test_pack_budget.py the size ceilings
├── integration/        27 tests, pipeline stages wired together
│   ├── test_pack.py        osmread → classify → geom → pack
│   ├── test_emit.py        pack → emit → resources + generated MapIndex.mc
│   └── test_preview.py     generated artefacts → preview → PNG (needs Pillow)
└── contract/           18 tests, agreements with the Monkey C
    ├── test_tile_format.py pack.py writer vs decode.py, mirror of TileReader.mc
    ├── test_palette.py     classify.py L_* vs Palette.mc SLOT_*, renderer budgets
    └── test_version.py     Version.mc APP vs the newest CHANGELOG.md heading
```

Adding a test: if it exercises one module, it goes in `unit/` in the file named
after that module. If it runs several stages or writes files, `integration/`. If
it fails when Python and Monkey C disagree, `contract/`.

`pack.py`, `emit.py`, `preview.py` and `decode.py` have no `unit/` file on
purpose, everything they do is a pipeline or a cross-language guarantee.

The watch code cannot be unit tested without the SDK. What stands in for it:
`decode.py` proving the format round-trips, and `preview.py` reproducing the
renderer in Python. Look at the output:

```bash
cd tools/mappack && python3 -m mappack.preview --zoom 16 --out preview.png
```

`preview*.png` at the repo root is gitignored; the four in `docs/img/` are what
the README embeds, refresh those only when the rendering genuinely changed.

## CI

`.github/workflows/ci.yml`, two jobs:

- **Map packer**: always runs. Tests, the `make demo` diff check, and preview
  renders uploaded as artefacts.
- **Connect IQ build**: skipped unless `GARMIN_USERNAME` / `GARMIN_PASSWORD`
  secrets and a `CIQ_AGREEMENT_HASH` variable are set. Builds every product and
  the `.iq` bundle.

## Adding a device

The checklist lives in [DEVICES.md § Adding another device](DEVICES.md#adding-another-device).
Watch-app memory versus the buffer size is what decides viability; `MapRenderer`
degrades to direct drawing rather than crashing when it does not fit. Remember
the `for device in venu3 venu3s` loop in CI lists devices literally.

## Agents

`.claude/` carries project config: four agents split along the repo's seams
(`watch-app`, `map-packer`, `contract-auditor`, `build-ops`) and six skills
(`sdk`, `pack`, `contracts`, `preview`, `add-device`, `changelog`).
`settings.json` denies
writes to the generated paths and reads of `developer_key`; a PostToolUse hook
surfaces whichever invariant applies to the file just touched.

Those files deliberately do **not** restate what is here; they point at these
pages. Keep it that way: one fact, one home.
