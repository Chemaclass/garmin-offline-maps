# garmin-offline-maps

Offline vector map for Garmin Venu 3 / 3S. Map data is **compiled into the app**
— no phone, no network, no tile server. Two halves:

| Half | Where | Language | Testable? |
|---|---|---|---|
| Packer | `tools/mappack/` | Python 3.9+ | yes — `make test` |
| Watch app | `source/` | Monkey C | only via the SDK; CI needs Garmin creds |

Read `docs/FORMAT.md` before touching anything that reads or writes bytes, and
`docs/DEVICES.md` before adding a device or growing memory use.

## The three invariants

These are the things that break silently. Check them on every relevant change.

**1. The format is a three-way contract.** These must agree byte for byte:

- `tools/mappack/mappack/pack.py` + `emit.py` + `varint.py` — the writer
- `tools/mappack/mappack/decode.py` — reference reader, used by the tests
- `source/TileReader.mc` — the on-watch reader

`decode.py` is a deliberate line-by-line mirror of `TileReader.mc`. Change one,
change all three, update `docs/FORMAT.md`, and run `make test` —
`tests/contract/test_tile_format.py` round-trips writer against reader.

**2. Layer ids are shared between Python and Monkey C.** `classify.py`'s
`L_WATER_AREA=0 … L_MOTORWAY=9` must line up index-for-index with the first ten
entries of `Palette.NIGHT` / `Palette.DAY` and with `WIDTH_FAR` / `WIDTH_NEAR`.
`preview.py` scrapes `source/Palette.mc` at runtime, so a palette edit that
breaks its parse breaks the preview tests, not just the colours.

**3. `mapdata/active/**` and `source/generated/MapIndex.mc` are generated.**
Never hand-edit them — regenerate with `make demo` (the committed synthetic
pack) or `make pack`. CI runs `make demo` and fails on any diff, so a hand-edit
shows up as a red build, not as a bug.

## Platform limits that shape the design

Not preferences — measured constraints (sources in `docs/DEVICES.md`):

| Limit | Venu 3 | Consequence in the code |
|---|---|---|
| Watch-app RAM | 768 KB | `TileStore` evicts by **byte budget**, not block count |
| `Application.Storage` | ~128 KB total, 8 KB/value | Only view state lives there, never map data |
| Filesystem API | none | Tiles cannot be side-loaded; they are compiled in |
| Frame budget | ~0.5 s before the watchdog | Render **once** into a `BufferedBitmap`, then blit |
| Palette | 16 entries | Every colour drawn must exist in `Palette.NIGHT`/`DAY` |
| Resource ids | ~255 per type | Packer budget defaults to 200 jsonData blocks |
| Store bundle | 15 MB max `.iq` | Packer warns above 12 MB in-app |

Corollary: every `drawLine` is an interpreted call. Adding per-frame work in
`MapRenderer` is expensive in a way desktop instincts do not predict.

## Commands

```bash
make test                              # 67 tests (10 skip without Pillow)
make lint                              # compileall over the packer
make demo                              # rebuild the committed demo pack
make pack BBOX=w,s,e,n NAME="Madrid"   # hits Overpass — see the skill first
make build DEVICE=venu3                # needs monkeyc on PATH
make sim                               # simulator + side-load
make package                           # .iq store bundle
```

`pip install pillow` unskips the 10 preview tests. `pip install osmium` enables
`make pack INPUT=region.osm.pbf`.

The Connect IQ SDK is **not** installed on this machine as of 2026-08-01 —
see the `sdk` skill. Everything except `build`/`sim`/`package` works without it.

## Conventions

Monkey C, as written here: `import Toybox.X` at the top, `//!` for doc
comments, `hidden var _name` for private state, untyped `var` (no `as Type`
annotations anywhere in `source/`), constants grouped in a `module` when both a
class and its statics need them.

Python: stdlib only in `mappack/` — Pillow is optional and import-guarded, and
osmium is imported lazily for `.pbf` only. Keep it that way; the packer must run
on a bare `python3`.

Docs are part of the change. `docs/FORMAT.md` is the format spec, not a
description of it — if the bytes move, it moves.

## Repo notes

- Commits: conventional, `ref:` not `refactor:`. Signing key E51B5BF45F85D160.
- `developer_key` is gitignored and unrecoverable — regenerating it means a new
  app identity in the Connect IQ store. Never read, print, or commit it.
- No git remote configured yet; `main` is the only branch.
- Global CLAUDE.md rules about Eloquent/repositories/`T`-prefixed types/Mockery
  are PHP-project rules and do not apply here.
