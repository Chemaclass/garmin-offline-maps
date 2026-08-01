# garmin-offline-maps

Offline vector map for Garmin Venu 3 / 3S. Map data is **compiled into the app**
— no phone, no network, no tile server.

| Half | Path | Language | Testable? |
|---|---|---|---|
| Packer | `tools/mappack/` | Python 3.9+, stdlib only | yes — `make test` |
| Watch app | `source/` | Monkey C | only via the SDK, which is not installed here |

**[docs/README.md](docs/README.md) is the index.** Read the relevant page before
non-trivial work: `ARCHITECTURE` (whole system), `RENDERING` (watch-side drawing
and memory), `PACKER` (the Python side), `FORMAT` (the byte spec), `DEVICES`
(hardware limits, with sources), `DEVELOPMENT` (build, test, conventions).

## Three invariants

These break silently. Full detail in [docs/README.md](docs/README.md#three-invariants).

1. **The byte format has three implementations** — `pack.py` (writer),
   `decode.py` (reference reader), `TileReader.mc` (on-watch reader).
   `decode.py` is a deliberate line-by-line mirror of the Monkey C. Change one,
   change all three, and update `docs/FORMAT.md`.
2. **Layer ids 0–9 are shared across languages** — `classify.py`'s `L_*` are
   array indices into `Palette.mc`, which `preview.py` also *parses* at runtime.
3. **`mapdata/active/**` and `source/generated/MapIndex.mc` are generated.**
   Never hand-edit; regenerate with `make demo` or `make pack`. CI fails on any
   diff.

`tests/contract/` guards 1 and 2. A failure there means "go edit the other
side", not "fix this code".

## Commands

```bash
make test                              # packer suite (10 skip without Pillow)
make demo                              # rebuild the committed demo pack
make pack BBOX=w,s,e,n NAME="Madrid"   # hits Overpass
make build DEVICE=venu3                # needs monkeyc on PATH
```

`make build`/`sim`/`package` need the Connect IQ SDK. Everything else does not.
Setup: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#setting-up-the-toolchain).

## Conventions

**Monkey C, as written here:** `import Toybox.X` at the top, `//!` doc comments
explaining *why*, `hidden var _name` for private state, untyped `var` — there
are no `as Type` annotations anywhere in `source/`, so do not introduce a
partial typing regime. Shared constants go in a `module`.

**Python:** stdlib only in `mappack/`. Pillow is optional and import-guarded,
osmium is lazy-imported for `.pbf`. Do not add a dependency — restructure.

**Docs are part of the change.** If the bytes move, `docs/FORMAT.md` moves.
Every fact lives in exactly one page; link rather than restate.

## Repo notes

- Commits: conventional, `ref:` not `refactor:`. Signing key E51B5BF45F85D160.
- User-visible changes get a `CHANGELOG.md` entry. The `changelog` skill has the
  rules on what counts — most work here (refactors, tests, docs) does not.
- `developer_key` is the app's Connect IQ store identity and is gitignored.
  Never read, print, or commit it.
- The Monkey C has never been through `monkeyc` — budget compile fixes on the
  first build, and never claim a watch-side change builds.
- Global CLAUDE.md rules about Eloquent/repositories/`T`-prefixed types/Mockery
  are PHP-project rules and do not apply here.
