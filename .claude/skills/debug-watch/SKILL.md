---
name: debug-watch
description: Track down a watch-side crash, freeze or wrong-looking map - the Connect IQ error icon, a black screen, "Code Executed Too Long", or layers that never draw. Use when the app dies or misbehaves on the watch or in the simulator and the cause is not obvious from the code.
---

# Debugging the watch app

The loop is slow and the failure modes are unusual. Most time lost here goes to
guessing instead of measuring, so this skill is mostly about how to get
evidence.

## First: which failure is it?

| Symptom | Almost certainly |
|---|---|
| Connect IQ error icon, black screen, app closes | `Lang.Error` or the watchdog |
| `Error: Watchdog Tripped Error - Code Executed Too Long` | too much interpreted work in one `onUpdate` |
| Map draws some layers and never the rest | the render is being **restarted**, not failing |
| App fine in simulator, broken on the wrist | a path the simulator does not execute |

That third row is worth internalising. **Water drawn and no streets is not a
crash.** The renderer builds the map over many frames, areas before lines, and
`redrawFromScratch()` starts again at the first pass. Anything invalidating
faster than the map completes means it never completes. Two bugs shipped that
way in one month, from the compass at 5 degrees and from GPS at 1 Hz. Before
hunting a drawing bug, count restarts.

## The watchdog counts instructions, not time

Measured on venu3 under the 9.1.0 simulator: a busy loop in `onUpdate` is killed
after ~12,000 iterations, at **10 ms** of wall clock. Ordinary render frames in
this app reach 81 ms and survive, because `drawLine` is one call into native
code however long it paints while varint decoding is thousands of instructions
per feature.

So **a ceiling in milliseconds will not save you**. That was established the
expensive way: ceilings of 600 ms, 250 ms and 150 ms all failed identically, with
the check evaluated every 16 points and never once firing. `TILE_POINT_CAP`
counts points decoded, which is the unit that actually kills the app.
`FRAME_BUDGET_MS` is a responsiveness budget and a different ceiling.

## `Lang.Error` cannot be caught

`UnexpectedTypeError`, `OutOfMemoryError` and an out-of-range subscript are
`Lang.Error`, not `Lang.Exception`. **No `catch` receives one**, and
`catch (e instanceof Lang.Error)` does not compile. They have to be *prevented*.

The usual source is a `Float` reaching `<<` or `>>`. Values arriving from JSON
are coerced at the boundary in `source/Num.mc`; `Pack.use`, `CityStore.keyName`,
`CityDownloader` and `Settings.load` are the callers. `toNumber()` alone is not
enough: it is partial, returns `null` on an unparseable `String`, and does not
exist on `Boolean`, so a guard that only checks for `null` can still store one.

## Getting evidence

### Read the stack, but do not trust it as the cause

A watchdog kill reports wherever the interpreter happened to be, which is
usually the innermost hot loop rather than the thing that was wrong. In the
`TILE_POINT_CAP` bug the stack always pointed at `uvarint`/`drawPolyline`; the
actual defect was a missing bound two frames up.

### Instrument, then revert

There is no debugger. `System.println` reaches the terminal through
`make sim`, and that is the whole toolkit.

```bash
make build DEVICE=venu3
make sim                    # prints System.println; Ctrl-C detaches
```

Add a trace, run, read, **then revert it**. Temporary instrumentation left in a
commit is worse than none. Print something countable rather than a narrative:
frames, restarts, tiles, segments, points. The line that broke the render-restart
bug open was a count of restarts per fix, not a description of what was
happening.

### Change one thing per run

Each cycle is a build plus a simulator launch, so batching changes feels
tempting and costs more than it saves: two changes and an unchanged result tells
you nothing about either. Record what a run ruled out, in the issue, as you go.
A ruled-out hypothesis is worth as much as a fix and this repo's issues are
written that way on purpose.

### A crashed run poisons the next one

`Diag` writes a breadcrumb to `Application.Storage` and `onStart` reads it. After
a crash the next launch enters **safe mode**: it refuses to adopt the downloaded
city and runs the built-in map, printing `safe mode after: <step>`. That is
deliberate, and it means a run following a crash is not a clean test. Check for
that line before drawing conclusions.

## What the simulator will not tell you

Every one of these has shipped a bug.

- **No GPS fix and no compass heading.** `LocationTracker.onPosition` never
  fires, `hasFix()` stays false, `onFix` returns at its first guard, and
  `pollHeading` never reports a change. The entire follow path is dead code.

  `source/DevTools.mc` exists for this: set `ENABLED = true`, rebuild, and it
  injects a jittered fix every second around the **centre of the active pack**
  plus a turning heading. Centred on the pack because `Camera.contains` culls a
  position outside it, which leaves the path just as dead as none at all. Set it
  back to false before committing.

  Then read **`restarts`** on the Stats overlay. Standing still it must stay
  put; one per second is the bug. Against current code the harness measures 1
  restart across ~100 fixes.
- **A downloaded pack is not a compiled-in pack.** Different code path: blocks
  arrive over HTTP, live in `Application.Storage`, and are decoded at runtime.
  `make catalogue CITY=Berlin` serves one so the app can download it.
- **App settings persist per app.** Editing a default in the generated
  `resources/settings/properties.xml` does not reach an app the simulator has
  already stored settings for. Change it through the simulator's own
  Application Settings.
- **Memory headroom.** The graphics pool and the 768 KB heap behave differently
  under a real workload.

## On hardware

```bash
make watch                  # needs libmtp; watch awake, Garmin Express quit
```

`GARMIN/APPS/LOGS/CIQ_LOG.YML` records that an app died and where, but only
after a crash. The About screen shows `Version.APP`, which is the only way to
tell **which build is actually on the wrist**. Check it before debugging a
report: a fix that never shipped and a fix that did not work look identical from
the screen.

## Reporting

Say exactly what you ran. "Compiles for venu3 and venu3s, runs in the simulator,
not tested on hardware" is complete and honest. A simulator run is not evidence
about the watch, and the gaps above are why.
