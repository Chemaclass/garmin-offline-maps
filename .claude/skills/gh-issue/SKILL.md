---
name: gh-issue
description: Work one GitHub issue end to end - fetch it, branch, implement in the right lane, verify, and open a PR. Use when the user names an issue number, says "work on #12", or asks to pick up an issue.
argument-hint: "[issue-number]"
---

# Work a GitHub issue

## Read the issue and every comment

!`gh issue view ${ARGUMENTS#\#} --json number,url,title,body,labels,assignees,state,comments 2>/dev/null || echo "Provide an issue number"`

Comments are requirements, not commentary. Issues in this repo carry measured
evidence (frame counts, byte budgets, crash stacks) and a later comment often
supersedes the body. When they conflict, the comment wins.

Several issues also record **what has already been ruled out**. Read that
before proposing a fix, or you will re-run an experiment that is written down
as failed.

## Phase 1: which lane

This repo has two halves with completely different feedback loops, and the
issue's labels tell you which one you are in. **Decide this first**: it
determines whether TDD is even possible.

| Label | Lane | Loop | Gate |
|---|---|---|---|
| `packer` | `tools/mappack/` | `make test`, under a second | tests, TDD applies |
| `watch-app`, `rendering` | `source/` | compile, then simulator | `make build` warning-free, then look at it |
| `map-format` | **all three implementations** | see invariant 1 below | contract tests |
| `documentation` | `docs/` | none | links resolve, facts live in one place |
| `device-support` | `manifest.xml`, CI | see the `add-device` skill | build for the new device |

An issue can span lanes. `map-format` always does.

## Phase 2: setup

1. **Self-assign** if unassigned: `gh issue edit <n> --add-assignee @me`

2. **Branch from fresh main.** Prefix from the issue type label:

   | Label | Prefix |
   |---|---|
   | `bug` | `fix/` |
   | `enhancement` | `feat/` |
   | `documentation` | `docs/` |
   | none | `feat/` |

   ```bash
   git checkout main && git fetch origin main && git reset --hard origin/main
   git checkout -b <prefix><n>-<slug>
   ```

   Abort if the worktree is dirty. Never auto-stash: `mapdata/active/**` is
   generated and a stash there is easy to lose track of.

## Phase 3: plan

Read the page that owns the area before touching code.
[docs/README.md](../../../docs/README.md) is the index; every fact lives on
exactly one page. `ARCHITECTURE` for the whole system, `RENDERING` for drawing
and memory, `PACKER` for the Python, `FORMAT` for the bytes, `DEVICES` for
hardware limits with their sources.

Then state, before implementing:

- which lane, and therefore what will verify the change
- which files change
- whether any of the three invariants is in scope
- what you will **not** be able to verify (see Phase 5)

## Phase 4: implement

### The three invariants

Break these and nothing shouts until much later. Full statement in
[docs/README.md](../../../docs/README.md#three-invariants).

1. **The byte format has three implementations**: `pack.py` (writer),
   `decode.py` (reference reader), `TileReader.mc` (on-watch reader).
   `decode.py` is a deliberate line-by-line mirror of the Monkey C. Change one,
   change all three, and update `docs/FORMAT.md`, which is the spec rather than a
   description of it.
2. **Layer ids 0-9 are array indices** shared between `classify.py`'s `L_*` and
   `Palette.mc`, which `preview.py` also *parses* at runtime. Reformatting
   those array literals can break tests even when the colours are fine.
3. **`mapdata/active/**` and `source/generated/MapIndex.mc` are generated.**
   Never hand-edit; regenerate with `make demo` or `make pack`. Same for
   `resources/settings/properties.xml`.

A failure in `tests/contract/` means *"go edit the other side"*, not *"fix this
test"*.

### Packer lane

TDD applies and the loop is fast enough to make it worthwhile. Tests are
grouped by **what they test**, not what they import:

- one module, one behaviour → `tests/unit/test_<module>.py`
- several stages, or writes files → `tests/integration/`
- fails when Python and Monkey C disagree → `tests/contract/`

**stdlib only.** Pillow is optional and import-guarded; osmium is lazy-imported
for `.pbf`. Do not add a dependency; restructure.

### Watch-app lane

There is no test framework for Monkey C. Nothing you write here is covered by
`make test`, which does not compile a single line of `source/`. What stands in:

- `decode.py` proving the format round-trips
- `preview.py` reproducing the renderer in Python (`make serve` to drive it)
- the simulator, which is the only thing that runs the actual code

Conventions, which the compiler will not enforce for you: `import Toybox.X` at
the top, `//!` comments explaining *why*, `hidden var _name` for private state,
**untyped `var`**. Two exceptions only, both forced by the type checker rather
than chosen: Garmin-typed API boundaries (callbacks, downcasts) and values that
get subscripted. Each carries a `//!` saying which. Do not introduce a partial
typing regime beyond those.

Three things the simulator will not tell you, all of which have shipped bugs:

- **No GPS fix and no compass heading.** `onFix` returns at its first guard and
  `pollHeading` never reports a change, so the whole follow path is dead code
  there. Two bugs shipped through that gap in one month.
- **Memory headroom and the watchdog.** The watchdog counts interpreted
  instructions, not milliseconds; see `docs/DEVICES.md`.
- **A downloaded pack is not a compiled-in pack.** Different code path.
  `make catalogue CITY=Berlin` exercises it.

## Phase 5: verify, and be exact about what you ran

```bash
make test                                                    # packer suite
make demo && git diff --exit-code -- mapdata/active source/generated/MapIndex.mc
make lint
```

The middle command is exactly what CI runs. A diff means either a generated
file was hand-edited or the committed pack went stale.

If `source/` changed, build **every** product you can. A change can compile for
one device and not another:

```bash
make build DEVICE=venu3 && make build DEVICE=venu3s
make sim        # and actually look at it
make watch      # onto a watch on USB, if one is connected
```

`make build` is warning-free today. Keep it that way: that is what makes a new
warning worth reading.

**Then say what you actually ran.** Never claim a watch-side change works
without having run it, and never present a simulator result as more than it is.
"Compiles for venu3 and venu3s, runs in the simulator, not tested on hardware"
is a complete and honest statement. Reporting it as verified is not.

## Phase 6: ship

**Changelog: most changes do not earn an entry.** This repo is the opposite of
most. The test is whether someone who installs the app or builds a pack would
experience this differently. Refactors, tests, docs, CI and internal constants
do not qualify. See the `changelog` skill; when in doubt, leave it out.

Commits are conventional with one local deviation: **`ref:` not `refactor:`**.
Reference the issue in the body.

```bash
git commit -m "fix: <subject under ~50 chars>

<why, when the diff does not say it>

Closes #<n>"
```

Never `git commit --amend` on pushed history. Never read, print, regenerate or
commit `developer_key`. It is the app's Connect IQ store identity, and a new
key means a new app with no users.

Then open the PR:

```bash
gh pr create --assignee Chemaclass --label <issue's labels> \
  --title "<subject>" --body "<what changed, what you verified, what you did not>

Closes #<n>"
```

Mirror the issue's labels onto the PR. Note that this repo has historically
pushed straight to `main` and has no branch protection, so a PR here is for
review value, not because anything blocks you.

## Phase 7: CI and merge

```bash
gh pr checks --watch
```

CI has two jobs. **Map packer** always runs: tests, the `make demo` diff, and
preview renders as artefacts. **Connect IQ build** is skipped unless the
`GARMIN_USERNAME`/`GARMIN_PASSWORD` secrets and `CIQ_AGREEMENT_HASH` are set, so
a green CI does **not** mean the watch app compiles. Say so if that job skipped.

Merge once green, then sync:

```bash
gh pr merge <n> --squash --delete-branch
git checkout main && git fetch origin main && git reset --hard origin/main
```

## Checklist

- [ ] Issue **and comments** read, including what is already ruled out
- [ ] Lane identified from labels
- [ ] Self-assigned, branch from fresh `origin/main`
- [ ] Owning doc page read
- [ ] Invariants checked if format, palette or generated files are in scope
- [ ] `make test`, `make demo` diff clean, `make lint`
- [ ] `make build` for every product touched, warning-free
- [ ] Changelog entry **only** if user-visible
- [ ] Docs updated in the same commit, if a documented fact moved
- [ ] Commit references the issue; `ref:` not `refactor:`
- [ ] PR assigned to Chemaclass with the issue's labels
- [ ] Stated plainly what was verified and what was not
