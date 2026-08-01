---
name: contracts
description: Verify the cross-file invariants before committing — the three MapPack format implementations agreeing byte for byte, layer ids shared between classify.py and Palette.mc, and the generated artefacts being current. Use after any change to the binary format, varints, the packer, the palette, or TileReader.mc, or when a round-trip test fails and it is unclear which side drifted.
---

# Contract check

Three agreements in this repo are enforced by convention and by tests, not by
the type system. Run this before committing anything that touches bytes or
colours. For a deep audit in its own context, hand it to the `contract-auditor`
agent.

## 1. The byte format has three implementations

| Role | File |
|---|---|
| Writer | `tools/mappack/mappack/pack.py`, `emit.py`, `varint.py` |
| Reference reader | `tools/mappack/mappack/decode.py` |
| On-watch reader | `source/TileReader.mc` |
| Spec | `docs/FORMAT.md` |

`decode.py` is a deliberate line-by-line mirror of `TileReader.mc` — the watch
parser is the one thing CI cannot execute, so the mirror plus the round-trip
tests are the proof. Compare field by field:

magic `0x4D` · version `1` · header 9 bytes · directory entry 4 bytes ·
little-endian u16 · LEB128 uvarint · zigzag svarint `(v >> 1) ^ -(v & 1)` ·
block header `magic, version, zoom, blockLog2, blockX:u16, blockY:u16, tileCount` ·
tile directory `localX, localY, payloadOffset:u16` · layer record
`layerId, layerBytes:u16, featureCount` · geometry `POLYLINE=0, POLYGON=1` ·
tile extent 1024 · clip buffer 64.

Change one, change all three, and update `docs/FORMAT.md` — it is the spec, not
a description of the spec.

## 2. Layer ids are shared across languages

`classify.py`: `L_WATER_AREA=0, L_GREEN_AREA=1, L_BUILDING=2, L_WATERWAY=3,
L_RAIL=4, L_PATH=5, L_MINOR=6, L_TERTIARY=7, L_PRIMARY=8, L_MOTORWAY=9`.

These are array indices into `Palette.NIGHT`, `Palette.DAY`, `WIDTH_FAR` and
`WIDTH_NEAR`, and they must match `Palette`'s `SLOT_*` constants and
`LAYER_COUNT = 10`. Two further traps:

- `Palette` has exactly **16** entries because a 16-colour BufferedBitmap is
  4 bpp — ~103 KB at 454×454 instead of ~206 KB out of a 768 KB heap. A 17th
  colour is a memory change, not a cosmetic one.
- `preview.py` **parses** `source/Palette.mc` at runtime. Reformatting those
  array literals can break the preview tests even when the colours are fine.

## 3. Generated artefacts are current

```bash
make demo
git diff --stat -- mapdata/active source/generated/MapIndex.mc
```

Empty diff = good. A diff means either the committed pack is stale (commit the
regenerated files alongside the code change) or something was hand-edited.
This is the exact check CI runs, so a diff here is a red build there.

## Then

```bash
make test    # 67 tests; 10 skip without Pillow (pip install pillow)
make lint
```

`tests/test_format.py` round-trips writer against reference reader;
`tests/test_preview.py` drives the reader over the real generated resources.
If both pass and the demo diff is empty, the contracts hold.
