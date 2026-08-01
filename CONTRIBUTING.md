# Contributing

Thanks for looking. This is a small repo with an unusual shape: half of it is
ordinary Python you can test in a second, and half of it is Monkey C that only a
Garmin toolchain can compile. Knowing which half you are in decides everything
about your feedback loop.

[docs/README.md](docs/README.md) is the documentation index. Every fact lives on
exactly one page. This file owns the *process*, not the facts, and links out for
the rest.

## Pick your lane

| Lane | Where | What you need | Loop |
|---|---|---|---|
| Packer, format, map data | `tools/mappack/` | `python3` | `make test`: under a second |
| Rendering, look of the map | `tools/mappack/mappack/preview.py` | `python3` + Pillow | render a PNG, look at it |
| Watch app | `source/` | the Connect IQ SDK | compile, then the simulator |
| Docs | `docs/` | nothing | - |

The first three lanes cover most of the interesting work, and only the third
needs a Garmin account.

## Setup

**Without the SDK** you get the packer, the whole test suite, and the preview
renderer:

```bash
git clone <this repo> && cd garmin-offline-maps
make test            # should be green immediately
pip install pillow   # optional: unskips the 10 preview tests
```

**With the SDK**, for `source/`: follow
[docs/DEVELOPMENT.md § Setting up the toolchain](docs/DEVELOPMENT.md#setting-up-the-toolchain).
Four pieces must exist and they fail with similar-looking errors, so start here
and let it tell you which one is missing:

```bash
make doctor
```

Device definitions are the only step that cannot be scripted: Garmin gates them
behind a free account and a licence agreement you have to accept by hand.

## The fast loop

You do not need a watch, or even the SDK, to see what the map will look like.
`preview.py` reproduces the on-watch drawing code in Python:

```bash
cd tools/mappack && python3 -m mappack.preview --zoom 16 --out preview.png
```

That is the intended loop for anything about colour, draw order, projection or
simplification. See the `preview` skill, or
[docs/RENDERING.md](docs/RENDERING.md) for what the renderer is actually doing.

To *drive* the map rather than look at a still (pan, zoom, switch themes, watch
the segment budget), there is a browser harness that needs no SDK:

```bash
make serve      # http://127.0.0.1:8765
```

Details and its limits in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#driving-the-map-without-a-watch).

To work with real map data instead of the bundled synthetic pack:

```bash
make pack BBOX=-3.75,40.38,-3.65,40.45 NAME="Madrid"
```

Read [docs/PACKER.md](docs/PACKER.md) first: packs have hard size budgets, and
`make pack` hits the public Overpass API, so be polite with it.

## The three invariants

These break silently, which is why they get their own tests. Full statement in
[docs/README.md § Three invariants](docs/README.md#three-invariants).

1. The byte format has **three** implementations, `pack.py`, `decode.py`,
   `TileReader.mc`. Change one, change all three, and update
   [docs/FORMAT.md](docs/FORMAT.md).
2. Layer ids 0–9 are array indices shared between `classify.py` and `Palette.mc`.
3. `mapdata/active/**` and `source/generated/MapIndex.mc` are **generated**.
   Never hand-edit them.

A failure in `tests/contract/` means *"go edit the other side"*, not *"fix this
test"*. That is the entire reason those tests live in their own directory.

## Before you open a PR

```bash
make test
make demo && git diff --exit-code -- mapdata/active source/generated/MapIndex.mc
make lint
```

The middle command is exactly what CI runs. A diff there means either you
hand-edited a generated file, or the committed pack went stale and should be
regenerated and committed alongside your change.

If you touched `source/`, also build every product: a change can compile for one
device and not the other:

```bash
make build DEVICE=venu3
make build DEVICE=venu3s
make sim                     # side-load into the simulator and actually look at it
```

Add a [CHANGELOG.md](CHANGELOG.md) entry under `[Unreleased]` if the change is
something a user would notice. Most changes here are not.

Update the docs in the same commit. If the bytes move, `docs/FORMAT.md` moves,
docs are part of the change, not a follow-up.

## Commits and PRs

Conventional commits, with one local deviation: **`ref:` rather than
`refactor:`**.

```
feat: heading-up rotation for the scale bar
fix: clamp tile cursor at block end
ref: fold Mercator helpers into one module
docs: correct the temurin cask name
```

Keep the subject under about 50 characters and let the body explain *why* when
the diff does not. One logical change per PR; a PR that renames things and also
changes behaviour is two PRs.

## Conventions

Both halves have a house style, stated in
[docs/DEVELOPMENT.md § Conventions](docs/DEVELOPMENT.md#conventions). The two
that catch people out:

- **Monkey C here is untyped**, except at Garmin API boundaries that the type
  checker will not accept untyped, five annotated sites, each with a `//!`
  saying why. Do not introduce a partial typing regime beyond those.
- **The packer is stdlib-only.** Pillow is optional and import-guarded, osmium is
  lazy-imported for `.pbf`. Do not add a dependency, restructure.

Platform limits in [docs/DEVICES.md](docs/DEVICES.md) are measured, with sources,
not preferences. The watch has ~768 KB of app memory and roughly half a second
before the watchdog fires, so desktop instincts about "just redraw it" do not
transfer.

## If you are an AI agent

`.claude/` is set up for you. Prefer the specialised agents over reading the
whole repo:

| Agent | Owns |
|---|---|
| `map-packer` | anything Python under `tools/mappack` |
| `watch-app` | anything Monkey C under `source/` |
| `contract-auditor` | read-only check of the three invariants |
| `build-ops` | toolchain, monkeyc failures, the simulator, CI |

And the skills, which encode procedures rather than facts: `sdk`, `pack`,
`contracts`, `preview`, `add-device`, `changelog`.

Two rules that matter more for agents than for humans:

- **Never claim a watch-side change builds without running `make build`.**
  `make test` does not compile a single line of `source/`, so a green test suite
  says nothing about the watch app. Say what you verified and what you did not.
- **Never read, print, regenerate or commit `developer_key`.** It is the app's
  identity in the Connect IQ store; replacing it means a new app, and it is not
  recoverable.

## Project status

Recorded in [CHANGELOG.md](CHANGELOG.md): the packer, the byte format and the
rendering maths are covered by tests and by a Python re-implementation of the
renderer. The watch app compiles for all 24 products under Connect IQ SDK 9.2.0
and runs in the simulator.

Memory headroom and frame timing are the two things the simulator will not tell
you, and they are exactly the two the [hardware limits](docs/DEVICES.md) say are
tight.

## Good first contributions

- **Run it on an actual Venu 3 and report what happens.** The single most
  valuable thing anyone can do for this project right now.
- Add a device: see the `add-device` skill and
  [docs/DEVICES.md](docs/DEVICES.md); memory versus buffer size is what decides
  viability.
- Pack a city you know and report where the map looks wrong.
- Improve tag coverage in `classify.py`: plenty of OSM tags still fall through
  to nothing.
