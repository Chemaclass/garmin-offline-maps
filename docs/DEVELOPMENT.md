# Development

## What works without the Connect IQ SDK

Most of it. The packer, the tests and the preview renderer need only `python3`.

```bash
make test     # the packer suite (10 skip without Pillow)
make lint     # compileall over the packer
make demo     # rebuild the committed demo pack
make pack     # build a pack for a real area
```

Only `make build`, `make sim` and `make package` need the SDK.

```bash
pip install pillow    # unskips the 10 preview tests
pip install osmium    # enables make pack INPUT=*.osm.pbf
```

## Setting up the toolchain

Run `make doctor` at any point — it names which piece is missing instead of
letting `monkeyc` guess. Four things must exist, and they fail with
similar-looking errors:

| Missing | Symptom |
|---|---|
| SDK binaries | `make: monkeyc: No such file or directory` |
| Java runtime | `Unable to locate a Java Runtime` |
| Device definitions | `ERROR: Invalid device id specified: 'venu3'.` |
| Signing key | `make build` stops before compiling; fix with `make key` |

```bash
brew install --cask connectiq              # monkeyc, monkeydo, simulator -- no Garmin login
brew install --cask temurin@21             # JDK 21, matching CI
brew install --cask connectiq-sdk-manager  # device definitions -- free Garmin account
```

Use `temurin@21`, not `temurin` — the unversioned cask is now JDK 26. Only
`temurin@21` needs `sudo` (it is a `.pkg`); the other two are not.

**Device definitions are the one step that cannot be scripted for you.** The SDK
download does not carry them, and Garmin gates them behind an account. Open
`SdkManager.app`, sign in, download an SDK **and accept the licence agreement**
— an unaccepted agreement is what silently leaves the Devices list empty — then
tick Venu 3 and Venu 3S. They land in:

```
~/Library/Application Support/Garmin/ConnectIQ/Devices/
```

The headless route CI uses works locally too, and still needs your credentials:

```bash
curl -sSf https://raw.githubusercontent.com/lindell/connect-iq-sdk-manager-cli/master/install.sh | sh
connect-iq-sdk-manager login
connect-iq-sdk-manager device download --manifest=manifest.xml
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
make build DEVICE=venu3     # -> bin/offline-maps-venu3.prg
make build DEVICE=venu3s    # every product in manifest.xml, not just the default
make sim                    # simulator + side-load
make package                # -> bin/offline-maps.iq for the store
```

`make sim` waits for the simulator to open its side-load socket (TCP 1234)
rather than sleeping a fixed interval, and reuses an already-running simulator.
Leave it open between builds; `Ctrl-C` detaches `monkeydo` without closing it.

On the watch: plug in over USB, copy the `.prg` into `GARMIN/APPS/`, eject. The
Venu 3 has music storage, so macOS mounts it over **MTP**, not mass storage —
Finder will not show it. Use [OpenMTP](https://openmtp.ganeshrvel.com/) or
Android File Transfer.

**`developer_key` is the app's identity in the Connect IQ store.** The store pins
a published app to the key that signed its first upload; a new key means a new
app. Never print, commit or regenerate it. `make key` only creates it when
missing.

**Expect real compile errors on the first build.** This Monkey C has never been
through `monkeyc`. Fix each on its merits; do not restructure working logic to
silence a message.

## Before you commit

```bash
make test
make demo && git diff --exit-code -- mapdata/active source/generated/MapIndex.mc
```

The second command is exactly what CI runs. A diff means either the committed
pack is stale (commit the regenerated files with your change) or something was
hand-edited.

If the change is user-visible, it also needs a `CHANGELOG.md` entry — see the
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
code" — that is why those tests are kept apart from the rest.

## Conventions

**Monkey C, as written here:** `import Toybox.X` at the top, `//!` doc comments
that explain *why*, `hidden var _name` for private state, untyped `var`, shared
constants in a `module` when both a class and its statics need them.

Your own logic stays untyped — do not introduce a partial typing regime. The
exception is **API boundaries where Garmin types the signature for you**. The
checker rejects an untyped callback passed to `Position.enableLocationEvents` or
`Timer.start`, and rejects `item.isEnabled()` when `onSelect` hands you the base
`MenuItem`. Five sites carry the minimum annotation for that reason, each with a
`//!` saying so:

| Site | Why |
|---|---|
| `LocationTracker.onPosition` ×2 | `Method(loc as Position.Info) as Void` |
| `OfflineMapsApp.onTick` | `Timer.start` wants `Method() as Void` |
| `MapMenu` `item as ToggleMenuItem` ×2 | only the subtype has `isEnabled()` |

The alternative was compiling at `-l 0`, which builds clean but disables type
checking for the whole codebase. Rejected: the checker caught a genuine defect
on its first run (`TileReader.uvarint` had no provable return path), and that is
worth more than a fully annotation-free `source/`.

**Python:** stdlib only in `mappack/`. Pillow is optional and import-guarded;
osmium is imported lazily for `.pbf`. Do not add a dependency — restructure.

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
frame timing — a render that looks fine here can still fail to allocate its
buffer on the device. The Connect IQ simulator is the better tool when it runs;
this is what you use when it does not.

## Testing

```bash
make test                                                    # everything, 67 tests
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
├── unit/               27 tests — one file per mappack module, single module each
│   ├── test_varint.py      LEB128, zigzag
│   ├── test_geom.py        Mercator, Douglas–Peucker, clipping
│   ├── test_classify.py    OSM tags → layer + minzoom
│   └── test_osmread.py     OSM XML → tagged ways
├── integration/        27 tests — pipeline stages wired together
│   ├── test_pack.py        osmread → classify → geom → pack
│   ├── test_emit.py        pack → emit → resources + generated MapIndex.mc
│   └── test_preview.py     generated artefacts → preview → PNG (needs Pillow)
└── contract/           13 tests — agreements with the Monkey C
    ├── test_tile_format.py pack.py writer vs decode.py, mirror of TileReader.mc
    └── test_palette.py     classify.py L_* vs Palette.mc SLOT_*, renderer budgets
```

Adding a test: if it exercises one module, it goes in `unit/` in the file named
after that module. If it runs several stages or writes files, `integration/`. If
it fails when Python and Monkey C disagree, `contract/`.

`pack.py`, `emit.py`, `preview.py` and `decode.py` have no `unit/` file on
purpose — everything they do is a pipeline or a cross-language guarantee.

The watch code cannot be unit tested without the SDK. What stands in for it:
`decode.py` proving the format round-trips, and `preview.py` reproducing the
renderer in Python. Look at the output:

```bash
cd tools/mappack && python3 -m mappack.preview --zoom 16 --out preview.png
```

`preview*.png` at the repo root is gitignored; the four in `docs/img/` are what
the README embeds — refresh those only when the rendering genuinely changed.

## CI

`.github/workflows/ci.yml`, two jobs:

- **Map packer** — always runs. Tests, the `make demo` diff check, and preview
  renders uploaded as artefacts.
- **Connect IQ build** — skipped unless `GARMIN_USERNAME` / `GARMIN_PASSWORD`
  secrets and a `CIQ_AGREEMENT_HASH` variable are set. Builds every product and
  the `.iq` bundle.

## Adding a device

The checklist lives in [DEVICES.md § Adding another device](DEVICES.md#adding-another-device).
Watch-app memory versus the buffer size is what decides viability; `MapRenderer`
degrades to direct drawing rather than crashing when it does not fit. Remember
the `for device in venu3 venu3s` loop in CI lists devices literally.

## Agents

`.claude/` carries project config: four agents split along the repo's seams
(`watch-app`, `map-packer`, `contract-auditor`, `build-ops`) and five skills
(`sdk`, `pack`, `contracts`, `preview`, `add-device`). `settings.json` denies
writes to the generated paths and reads of `developer_key`; a PostToolUse hook
surfaces whichever invariant applies to the file just touched.

Those files deliberately do **not** restate what is here — they point at these
pages. Keep it that way: one fact, one home.
